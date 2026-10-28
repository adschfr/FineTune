// FineTune/Audio/CatchAll/CatchAllRunLogic.swift
import AudioToolbox

/// What Core Audio reports as a process's output devices.
nonisolated enum ProcessOutputDevices: Sendable, Equatable {
    case unknown
    /// `hasNonPlain`: one of them is an aggregate, virtual or unresolvable device.
    case known(Set<AudioDeviceID>, hasNonPlain: Bool)
}

/// When each catch-all's IO runs (design §6). Pure: the run control feeds it events and
/// carries out the effects, so every rule is testable with a manual clock.
///
/// A catch-all runs while a process it covers runs output that may go to its device, and
/// for 10 s after the last such output or the last audible input. While stopped, the muted
/// tap holds covered audio back: a late start loses the beginning of a sound, never plays
/// it unprocessed.
nonisolated struct CatchAllRunLogic: Sendable {
    enum RebuildReason: String, Sendable, Equatable {
        case startFailed
        case ioDead
    }

    enum Effect: Sendable, Equatable {
        case start(String)
        case stop(String)
        /// Re-read the running state of all processes from Core Audio (after a stop).
        case recheck
        case rebuild(String, RebuildReason)
    }

    struct Device: Sendable, Equatable {
        var deviceID: AudioDeviceID
        var excluded: Set<AudioObjectID> = []
        /// Processes about to be un-excluded; treated as covered until the next list.
        var prepared: Set<AudioObjectID> = []
        var running = false
        var startedAt: Double = 0
        /// Last time the device was needed (feeding output or audible input).
        var lastNeeded: Double = 0
        var missedLiveness = 0
    }

    /// Seconds a catch-all keeps running after it was last needed (the fork's tap suspend delay).
    var suspendDelay: Double = 10
    /// A running IO with no callback for this long while needed counts as a missed check.
    var livenessTimeout: Double = 1
    /// Only start for processes whose output devices include the catch-all's device. Off
    /// until a harness run confirms Core Audio reports devices of muted processes correctly.
    var deviceFilterEnabled = false

    private(set) var devices: [String: Device] = [:]
    private(set) var live: Set<AudioObjectID> = []
    private(set) var runningOutput: Set<AudioObjectID> = []
    private(set) var outputDevices: [AudioObjectID: ProcessOutputDevices] = [:]

    // MARK: - Events

    mutating func attach(_ uid: String, deviceID: AudioDeviceID, excluded: Set<AudioObjectID>, now: Double) -> [Effect] {
        devices[uid] = Device(deviceID: deviceID, excluded: excluded)
        return startNeeded(now: now)
    }

    mutating func detach(_ uid: String) {
        devices[uid] = nil
    }

    mutating func setExcluded(_ uid: String, _ excluded: Set<AudioObjectID>, now: Double) -> [Effect] {
        guard devices[uid] != nil else { return [] }
        noteNeeded(now: now)
        devices[uid]?.excluded = excluded
        devices[uid]?.prepared = []
        return startNeeded(now: now)
    }

    /// `processes` will be un-excluded on `uids`: start those catch-alls now if any of them
    /// already plays, so the handover never waits for a resume.
    mutating func prepareInclusion(_ processes: Set<AudioObjectID>, on uids: Set<String>, now: Double) -> [Effect] {
        for uid in uids where devices[uid] != nil {
            devices[uid]?.prepared.formUnion(processes)
        }
        return startNeeded(now: now)
    }

    mutating func setProcesses(_ processes: Set<AudioObjectID>, now: Double) -> [Effect] {
        noteNeeded(now: now)
        live = processes
        runningOutput.formIntersection(processes)
        outputDevices = outputDevices.filter { processes.contains($0.key) }
        return startNeeded(now: now)
    }

    mutating func setRunningOutput(_ process: AudioObjectID, _ running: Bool, now: Double) -> [Effect] {
        noteNeeded(now: now)
        if running { runningOutput.insert(process) } else { runningOutput.remove(process) }
        return startNeeded(now: now)
    }

    mutating func setOutputDevices(_ process: AudioObjectID, _ devices: ProcessOutputDevices, now: Double) -> [Effect] {
        noteNeeded(now: now)
        outputDevices[process] = devices
        return startNeeded(now: now)
    }

    mutating func startResult(_ uid: String, succeeded: Bool) -> [Effect] {
        guard !succeeded, devices[uid] != nil else { return [] }
        devices[uid]?.running = false
        return [.rebuild(uid, .startFailed)]
    }

    /// Periodic check while a catch-all runs. `lastAudible` and `lastCallback` are the
    /// times (same clock as `now`) the IO thread last saw audible input and last ran; 0 if never.
    mutating func tick(now: Double, lastAudible: [String: Double], lastCallback: [String: Double]) -> [Effect] {
        var effects: [Effect] = []
        var stopped = false
        for uid in devices.keys.sorted() {
            guard var device = devices[uid], device.running else { continue }
            let needed = needsAudio(uid)
            let audible = lastAudible[uid].map { $0 > 0 && now - $0 < suspendDelay } ?? false
            if needed || audible {
                device.lastNeeded = now
            }

            // IO that should be playing but has not called back for a while is dead
            let callbackStale = lastCallback[uid].map { $0 == 0 || now - $0 > livenessTimeout } ?? false
            if needed, now - device.startedAt > livenessTimeout, callbackStale {
                device.missedLiveness += 1
                if device.missedLiveness >= 2 {
                    device.missedLiveness = 0
                    effects.append(.rebuild(uid, .ioDead))
                }
            } else {
                device.missedLiveness = 0
            }

            if now - device.lastNeeded >= suspendDelay {
                device.running = false
                effects.append(.stop(uid))
                stopped = true
            }
            devices[uid] = device
        }
        // Stop, then re-read: a process that started during the decision restarts it at once
        if stopped { effects.append(.recheck) }
        return effects
    }

    // MARK: - Decisions

    var anyRunning: Bool { devices.values.contains { $0.running } }

    func isRunning(_ uid: String) -> Bool { devices[uid]?.running ?? false }

    /// Whether some process the catch-all covers runs output that may go to its device.
    func needsAudio(_ uid: String) -> Bool {
        guard let device = devices[uid] else { return false }
        return runningOutput.contains { process in
            let covered = live.contains(process) && (!device.excluded.contains(process) || device.prepared.contains(process))
            return covered && feeds(process, device)
        }
    }

    private func feeds(_ process: AudioObjectID, _ device: Device) -> Bool {
        guard deviceFilterEnabled else { return true }
        switch outputDevices[process] ?? .unknown {
        case .unknown:
            return true
        case .known(let ids, let hasNonPlain):
            return ids.isEmpty || hasNonPlain || ids.contains(device.deviceID)
        }
    }

    /// Running catch-alls that are needed right now stay needed up to `now`; called before a
    /// change, so the suspend delay counts from the moment the last output actually ended.
    private mutating func noteNeeded(now: Double) {
        for uid in devices.keys where devices[uid]?.running == true && needsAudio(uid) {
            devices[uid]?.lastNeeded = now
        }
    }

    private mutating func startNeeded(now: Double) -> [Effect] {
        var effects: [Effect] = []
        for uid in devices.keys.sorted() where !(devices[uid]?.running ?? true) && needsAudio(uid) {
            devices[uid]?.running = true
            devices[uid]?.startedAt = now
            devices[uid]?.lastNeeded = now
            devices[uid]?.missedLiveness = 0
            effects.append(.start(uid))
        }
        return effects
    }
}
