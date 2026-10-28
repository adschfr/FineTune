// FineTune/Audio/CatchAll/CatchAllRunLogic.swift
import AudioToolbox

/// How a device a process plays to is classified (C9 settle rule, design §16.2).
nonisolated enum OutputDeviceKind: Sendable, Equatable {
    case plain
    case aggregateOrVirtual
    /// No readable UID, for example a device that was just removed.
    case unresolvable
}

/// What Core Audio reports as a process's output devices.
nonisolated enum ProcessOutputDevices: Sendable, Equatable {
    case unknown
    case known([AudioDeviceID: OutputDeviceKind])
}

/// What main learns about a process's output for the C9 settle rule: its classified
/// devices together with IsRunningOutput, since an empty list means something else while
/// the process plays.
nonisolated struct ProcessDeviceReport: Sendable, Equatable {
    var devices: ProcessOutputDevices
    var runningOutput: Bool
}

/// When each catch-all's IO runs (design §6, §16.3 E3). Pure: the run control feeds it events
/// and carries out the effects, so every rule is testable with a manual clock.
///
/// A catch-all runs while a process it covers may play to its device, and for 10 s after the
/// last such need or the last audible input. A process needs audio while it runs output, and
/// while it runs IO at all: without limit when FineTune lists it as an app, for `ioOnlyCap`
/// otherwise. While stopped, the muted tap holds covered audio back: a late start loses the
/// beginning of a sound, never plays it unprocessed.
///
/// The unit is the handle, keyed by aggregate ID: a rebuild attaches the new catch-all for a
/// device before it detaches the old one, so two handles can share a device UID.
nonisolated struct CatchAllRunLogic: Sendable {
    enum RebuildReason: String, Sendable, Equatable {
        case startFailed
        case ioDead
    }

    enum Effect: Sendable, Equatable {
        case start(AudioDeviceID)
        case stop(AudioDeviceID)
        /// Re-read the process list and every process from Core Audio (after a stop).
        case recheck
        /// The safety re-read while all are stopped, for missed notifications: the same reads
        /// as `recheck`, but output it finds counts as output without edge.
        case reread
        /// Read IsRunningOutput of these processes, which posts no notification.
        case poll([AudioObjectID])
        case rebuild(AudioDeviceID, RebuildReason)
        /// A covered process's output rose and only a poll or the safety re-read found it.
        case outputWithoutEdge(AudioObjectID)
        /// The process's report for main changed (deduplicated on the pair).
        case devicesChanged(AudioObjectID, ProcessDeviceReport)
    }

    /// One attached catch-all IO.
    struct Handle: Sendable, Equatable {
        var uid: String
        var deviceID: AudioDeviceID
        var excluded: Set<AudioObjectID> = []
        /// Processes about to be un-excluded; treated as covered until the next list.
        var prepared: Set<AudioObjectID> = []
        var running = false
        /// Its start failed: it asked for a rebuild once and is not started again (a rebuild
        /// attaches a new handle).
        var startFailed = false
        var startedAt: Double = 0
        /// Last time the catch-all was needed (a covered process needing audio, or audible input).
        var lastNeeded: Double = 0
        var missedLiveness = 0

        func covers(_ process: AudioObjectID) -> Bool {
            !excluded.contains(process) || prepared.contains(process)
        }
    }

    /// Seconds a catch-all keeps running after it was last needed (the fork's tap suspend delay).
    var suspendDelay: Double = 10
    /// A running IO with no callback for this long while needed counts as a missed check.
    var livenessTimeout: Double = 1
    /// Default of `ioOnlyCap`, overridable through `CatchAllSettings.ioOnlyCap`.
    static let defaultIOOnlyCap: Double = 120

    /// Seconds an unlisted process's IO counts without output (E3); after that its
    /// IsRunningOutput is polled while a catch-all is stopped, and at each tick while one
    /// runs and the process shows output.
    var ioOnlyCap: Double = CatchAllRunLogic.defaultIOOnlyCap
    /// Timer intervals: the check while a catch-all runs, the poll of capped processes
    /// while one is stopped, and the safety re-read while all are stopped (§16.3).
    var tickInterval: Double = 2
    var pollInterval: Double = 0.1
    var rereadInterval: Double = 3
    /// Only start for processes whose output devices include the catch-all's device. Off
    /// until a harness run confirms Core Audio reports devices of muted processes correctly.
    var deviceFilterEnabled = false

    /// Keyed by aggregate ID.
    private(set) var handles: [AudioDeviceID: Handle] = [:]
    private(set) var live: Set<AudioObjectID> = []
    /// Processes FineTune lists as apps: their IO counts without a cap.
    private(set) var listed: Set<AudioObjectID> = []
    /// Processes running IO (IsRunning), with the time it was first seen running.
    private(set) var runningSince: [AudioObjectID: Double] = [:]
    private(set) var runningOutput: Set<AudioObjectID> = []
    private(set) var outputDevices: [AudioObjectID: ProcessOutputDevices] = [:]
    private var reported: [AudioObjectID: ProcessDeviceReport] = [:]
    private var lastReread: Double = 0
    /// Last tick that checked the running catch-alls; the poll for a stopped one runs in between.
    private var lastRunTick: Double = 0

    // MARK: - Events

    mutating func attach(_ aggregate: AudioDeviceID, uid: String, deviceID: AudioDeviceID,
                         excluded: Set<AudioObjectID>, now: Double) -> [Effect] {
        // The safety re-read's phase starts with the first catch-all
        if handles.isEmpty { lastReread = now }
        handles[aggregate] = Handle(uid: uid, deviceID: deviceID, excluded: excluded)
        return startNeeded(now: now)
    }

    mutating func detach(_ aggregate: AudioDeviceID) {
        handles[aggregate] = nil
    }

    mutating func setExcluded(_ aggregate: AudioDeviceID, _ excluded: Set<AudioObjectID>, now: Double) -> [Effect] {
        guard handles[aggregate] != nil else { return [] }
        noteNeeded(now: now)
        handles[aggregate]?.excluded = excluded
        handles[aggregate]?.prepared = []
        return startNeeded(now: now)
    }

    /// `processes` will be un-excluded on the catch-alls of `uids`: start them now if any of
    /// these processes already plays, so the handover never waits for a resume.
    mutating func prepareInclusion(_ processes: Set<AudioObjectID>, on uids: Set<String>, now: Double) -> [Effect] {
        for (aggregate, handle) in handles where uids.contains(handle.uid) {
            handles[aggregate]?.prepared.formUnion(processes)
        }
        return startNeeded(now: now)
    }

    mutating func setProcesses(_ processes: Set<AudioObjectID>, now: Double) -> [Effect] {
        noteNeeded(now: now)
        live = processes
        runningSince = runningSince.filter { processes.contains($0.key) }
        runningOutput.formIntersection(processes)
        outputDevices = outputDevices.filter { processes.contains($0.key) }
        reported = reported.filter { processes.contains($0.key) }
        return startNeeded(now: now)
    }

    mutating func setListed(_ processes: Set<AudioObjectID>, now: Double) -> [Effect] {
        noteNeeded(now: now)
        listed = processes
        return startNeeded(now: now)
    }

    /// After a Core Audio restart every attached aggregate is dead and object IDs may be
    /// reused: the handles go without a stop or rebuild (the owner detaches and rebuilds
    /// them), and every process is forgotten, the listed ones too (main sends them again).
    mutating func serviceRestarted() {
        handles = [:]
        live = []
        listed = []
        runningSince = [:]
        runningOutput = []
        outputDevices = [:]
        reported = [:]
    }

    /// A read of a process's IsRunning and IsRunningOutput. `edge` is false for the safety
    /// re-read, which reports a covered output it finds as output without edge. Starts come
    /// before the report, which goes out when IsRunningOutput changed under known devices.
    mutating func setRunState(_ process: AudioObjectID, running: Bool, output: Bool, now: Double, edge: Bool = true) -> [Effect] {
        noteNeeded(now: now)
        let rose = output && !runningOutput.contains(process)
        if running || output {
            if runningSince[process] == nil { runningSince[process] = now }
        } else {
            runningSince[process] = nil
        }
        if output { runningOutput.insert(process) } else { runningOutput.remove(process) }
        var effects = startNeeded(now: now)
        if rose, !edge, isCovered(process) { effects.append(.outputWithoutEdge(process)) }
        return effects + report(process)
    }

    /// A poll's read of IsRunningOutput (`.poll`); IsRunning stays as last notified.
    mutating func setPolledOutput(_ process: AudioObjectID, _ output: Bool, now: Double) -> [Effect] {
        setRunState(process, running: runningSince[process] != nil, output: output, now: now, edge: false)
    }

    mutating func setOutputDevices(_ process: AudioObjectID, _ devices: ProcessOutputDevices, now: Double) -> [Effect] {
        noteNeeded(now: now)
        outputDevices[process] = devices
        return startNeeded(now: now) + report(process)
    }

    /// A failed start asks for a rebuild once; the handle is not started again.
    mutating func startResult(_ aggregate: AudioDeviceID, succeeded: Bool) -> [Effect] {
        guard !succeeded, handles[aggregate] != nil else { return [] }
        handles[aggregate]?.running = false
        handles[aggregate]?.startFailed = true
        return [.rebuild(aggregate, .startFailed)]
    }

    /// The run control's timer (interval from `timerInterval(now:)`). While a catch-all runs:
    /// liveness, suspend, and a poll of capped processes that run output, whose output can
    /// end without an edge; while another one is stopped, its poll runs in between. While all
    /// are stopped: the poll of capped processes and the safety re-read. `lastAudible` and
    /// `lastCallback` are the times (same clock as `now`) each IO thread last saw audible
    /// input and last ran; 0 if never.
    mutating func tick(now: Double, lastAudible: [AudioDeviceID: Double], lastCallback: [AudioDeviceID: Double]) -> [Effect] {
        guard anyRunning else { return idleTick(now: now) }
        let targets = anyStopped ? pollTargets(now: now) : []
        if !targets.isEmpty, now - lastRunTick < tickInterval { return [.poll(targets)] }
        lastRunTick = now
        var effects: [Effect] = []
        var stopped = false
        for aggregate in handles.keys.sorted() {
            guard var handle = handles[aggregate], handle.running else { continue }
            let needed = needsAudio(aggregate, now: now)
            let audible = lastAudible[aggregate].map { $0 > 0 && now - $0 < suspendDelay } ?? false
            if needed || audible {
                handle.lastNeeded = now
            }

            // IO that should be playing but has not called back for a while is dead
            let callbackStale = lastCallback[aggregate].map { $0 == 0 || now - $0 > livenessTimeout } ?? false
            if needed, now - handle.startedAt > livenessTimeout, callbackStale {
                handle.missedLiveness += 1
                if handle.missedLiveness >= 2 {
                    handle.missedLiveness = 0
                    effects.append(.rebuild(aggregate, .ioDead))
                }
            } else {
                handle.missedLiveness = 0
            }

            if now - handle.lastNeeded >= suspendDelay {
                handle.running = false
                effects.append(.stop(aggregate))
                stopped = true
            }
            handles[aggregate] = handle
        }
        // Stop, then re-read: a process that started during the decision restarts it at once
        if stopped {
            lastReread = now
            effects.append(.recheck)
        } else {
            // Otherwise such output would keep the catch-all running while the IO stays open;
            // while one is stopped, the other capped processes are its poll
            let polled = capped(now: now).filter { anyStopped || runningOutput.contains($0) }
            if !polled.isEmpty { effects.append(.poll(polled)) }
        }
        return effects
    }

    // MARK: - Decisions

    var anyRunning: Bool { handles.values.contains { $0.running } }

    private var anyStopped: Bool { handles.values.contains { !$0.running } }

    func isRunning(_ aggregate: AudioDeviceID) -> Bool { handles[aggregate]?.running ?? false }

    /// Whether some process the catch-all covers needs audio that may go to its device.
    func needsAudio(_ aggregate: AudioDeviceID, now: Double) -> Bool {
        guard let handle = handles[aggregate] else { return false }
        return runningSince.keys.contains { needs($0, from: handle, now: now) }
    }

    /// What makes the catch-all needed, for the start log: the lowest-numbered such process
    /// and its rule, e.g. "process 11 (output)"; nil when nothing does.
    func neededBy(_ aggregate: AudioDeviceID, now: Double) -> String? {
        guard let handle = handles[aggregate],
              let process = runningSince.keys.sorted().first(where: { needs($0, from: handle, now: now) }) else { return nil }
        let rule = runningOutput.contains(process) ? "output" : listed.contains(process) ? "listed IO" : "IO within the cap"
        return "process \(process) (\(rule))"
    }

    /// Covered, unlisted processes whose IO outlasted the cap without output. While a
    /// catch-all is stopped, their IsRunningOutput is polled.
    func pollTargets(now: Double) -> [AudioObjectID] {
        capped(now: now).filter { !runningOutput.contains($0) }
    }

    /// Seconds between the run control's timer events: the poll while a catch-all is stopped
    /// and a capped process exists; otherwise the tick while one runs, else the safety
    /// re-read; 0 (no timer) when nothing is attached.
    func timerInterval(now: Double) -> Double {
        guard !handles.isEmpty else { return 0 }
        if anyStopped, !pollTargets(now: now).isEmpty { return pollInterval }
        return anyRunning ? tickInterval : rereadInterval
    }

    /// Seconds until the first timer event once the interval changed. The safety re-read
    /// keeps its phase, so a switch back from the poll does not push it out.
    func timerDelay(now: Double) -> Double {
        let interval = timerInterval(now: now)
        guard !handles.isEmpty, !anyRunning, pollTargets(now: now).isEmpty else { return interval }
        return min(interval, max(0, lastReread + interval - now))
    }

    /// E3: output always counts; IO without output counts for a listed process, and for an
    /// unlisted one until the cap.
    private func needs(_ process: AudioObjectID, now: Double) -> Bool {
        guard let since = runningSince[process] else { return false }
        return runningOutput.contains(process) || listed.contains(process) || now - since < ioOnlyCap
    }

    /// Covered, unlisted processes whose IO runs longer than the cap: only their output
    /// counts, and Core Audio posts no notification when it changes.
    private func capped(now: Double) -> [AudioObjectID] {
        runningSince.compactMap { process, since in
            !listed.contains(process) && now - since >= ioOnlyCap && isCovered(process) ? process : nil
        }.sorted()
    }

    private func needs(_ process: AudioObjectID, from handle: Handle, now: Double) -> Bool {
        live.contains(process) && handle.covers(process) && needs(process, now: now) && feeds(process, handle)
    }

    private func isCovered(_ process: AudioObjectID) -> Bool {
        live.contains(process) && handles.values.contains { $0.covers(process) }
    }

    private func feeds(_ process: AudioObjectID, _ handle: Handle) -> Bool {
        guard deviceFilterEnabled else { return true }
        switch outputDevices[process] ?? .unknown {
        case .unknown:
            return true
        case .known(let kinds):
            return kinds.isEmpty || kinds.values.contains { $0 != .plain } || kinds[handle.deviceID] != nil
        }
    }

    private mutating func idleTick(now: Double) -> [Effect] {
        guard !handles.isEmpty else { return [] }
        let capped = pollTargets(now: now)
        if capped.isEmpty || now - lastReread >= rereadInterval {
            lastReread = now
            return [.reread]
        }
        return [.poll(capped)]
    }

    /// The pair for main when it changed; only for processes whose devices were read.
    private mutating func report(_ process: AudioObjectID) -> [Effect] {
        guard let devices = outputDevices[process] else { return [] }
        let report = ProcessDeviceReport(devices: devices, runningOutput: runningOutput.contains(process))
        guard reported[process] != report else { return [] }
        reported[process] = report
        return [.devicesChanged(process, report)]
    }

    /// Running catch-alls that are needed right now stay needed up to `now`; called before a
    /// change, so the suspend delay counts from the moment the last need actually ended.
    private mutating func noteNeeded(now: Double) {
        for aggregate in handles.keys where handles[aggregate]?.running == true && needsAudio(aggregate, now: now) {
            handles[aggregate]?.lastNeeded = now
        }
    }

    private mutating func startNeeded(now: Double) -> [Effect] {
        var effects: [Effect] = []
        for (aggregate, handle) in handles.sorted(by: { $0.key < $1.key })
        where !handle.running && !handle.startFailed && needsAudio(aggregate, now: now) {
            handles[aggregate]?.running = true
            handles[aggregate]?.startedAt = now
            handles[aggregate]?.lastNeeded = now
            handles[aggregate]?.missedLiveness = 0
            effects.append(.start(aggregate))
        }
        return effects
    }
}
