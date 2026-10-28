// FineTune/Audio/CatchAll/CatchAllRunControl.swift
import AudioToolbox
import Darwin
import Foundation
import os
import Synchronization

/// Changes the run control reacts to.
nonisolated enum ProcessActivityEvent: Sendable, Equatable {
    case processListChanged
    case processChanged(AudioObjectID)
    case serviceRestarted
    /// The aggregate of an attached catch-all stopped its IO abnormally.
    case ioStoppedAbnormally(AudioDeviceID)
}

/// Where the run control learns which processes run output. Behind a protocol so tests
/// drive it without Core Audio.
nonisolated protocol ProcessOutputActivitySource: AnyObject, Sendable {
    func processList() -> [AudioObjectID]
    func isRunning(_ process: AudioObjectID) -> Bool
    func isRunningOutput(_ process: AudioObjectID) -> Bool
    /// The process's output devices; nil when they cannot be read.
    func outputDeviceIDs(_ process: AudioObjectID) -> [AudioDeviceID]?
    func classify(_ device: AudioDeviceID) -> OutputDeviceKind
    /// Starts delivering events on `queue`; false when a system listener could not be registered.
    func start(on queue: DispatchQueue, handler: @escaping @Sendable (ProcessActivityEvent) -> Void) -> Bool
    /// This and `observeAbnormalStop` register nothing before `start` or after `stop`.
    func observe(_ process: AudioObjectID, devices: Bool)
    func forget(_ process: AudioObjectID)
    func observeAbnormalStop(of aggregate: AudioDeviceID)
    func forgetAbnormalStop(of aggregate: AudioDeviceID)
    /// Removes every listener; `start` registers the system listeners again.
    func stop()
}

/// Starts and stops the IO of attached catch-alls on its own serial queue, so a blocked
/// main thread never delays a resume. Main attaches, detaches, updates exclusions and the
/// listed processes; this queue owns everything else. All state below is confined to
/// `queue`. The unit is the handle (aggregate ID): during a rebuild, two handles for one
/// device are attached and each is started, stopped and detached on its own.
nonisolated final class CatchAllRunControl: @unchecked Sendable {
    let queue: DispatchQueue
    /// Observe every process's output devices and report them with `onDevicesChanged` (C9).
    private let observeDevices: Bool
    private let source: ProcessOutputActivitySource
    private let backend: any CatchAllBackend
    private let hostTime: @Sendable () -> UInt64
    private let ticksPerSecond: Double
    /// Longest wait of `detach` and `stop()` for the queue.
    private let waitTimeout: Double
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.finetuneapp.FineTune", category: "CatchAllRun")

    private var logic: CatchAllRunLogic
    private var handles: [AudioDeviceID: CatchAllIOHandle] = [:]
    private var observed: Set<AudioObjectID> = []
    /// Device classification by ID; cleared after a Core Audio restart, which may reuse IDs.
    private var deviceKinds: [AudioDeviceID: OutputDeviceKind] = [:]
    private var timer: DispatchSourceTimer?
    private var timerInterval: Double = 0
    /// Processes are observed and read, and IO is started, only between start() and stop().
    private var isStarted = false
    /// Bumped by every listener registration and by stop(), so a retry scheduled for an
    /// earlier one does nothing.
    private var observationGeneration = 0
    /// Failed listener registrations in a row; sets the retry delay.
    private var listenerFailures = 0
    /// Reports waiting for main: written on the queue, taken by one main task.
    private let pendingReports = Mutex(PendingReports())
    /// Set on `queue`, so calls made on it run inline instead of waiting for it.
    private let queueKey = DispatchSpecificKey<Void>()

    // Callbacks: read on `queue`, so they are set before start(). They may run inside a Core
    // Audio listener block, so the owner hops off the queue before it calls stop().

    /// Called on `queue` with the device UID and aggregate; the owner hops to main. An IO
    /// that died can ask more than once (its listener, then the liveness check every 4 s
    /// until it is detached): the owner deduplicates per aggregate.
    var onRebuild: (@Sendable (String, AudioDeviceID, CatchAllRunLogic.RebuildReason) -> Void)?
    /// Called on `queue` before anything is read from the restarted daemon. The handles
    /// attached until then are dead and get no further start, stop or rebuild; the owner's
    /// hop to main, made in this call, reaches main before any report from the restarted
    /// daemon. The owner then detaches every handle it built before handling this (one
    /// attached later counts as live), sends the listed processes again (a set sent before
    /// this call is dropped), and tolerates a rebuild or start failure for a dead handle
    /// that arrived before this call.
    var onServiceRestarted: (@Sendable () -> Void)?
    /// Called on main with every process whose report changed since the last call.
    var onDevicesChanged: (@MainActor @Sendable ([AudioObjectID: ProcessDeviceReport]) -> Void)?

    init(
        source: ProcessOutputActivitySource,
        backend: any CatchAllBackend,
        logic: CatchAllRunLogic = CatchAllRunLogic(),
        observeDevices: Bool = false,
        queue: DispatchQueue = DispatchQueue(label: "com.adschfr.FineTuneFork.catchall", qos: .userInteractive),
        waitTimeout: Double = 1,
        hostTime: @escaping @Sendable () -> UInt64 = { mach_absolute_time() }
    ) {
        self.source = source
        self.backend = backend
        self.logic = logic
        self.observeDevices = observeDevices
        self.queue = queue
        self.waitTimeout = waitTimeout
        self.hostTime = hostTime
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        ticksPerSecond = 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer)
        queue.setSpecific(key: queueKey, value: ())
    }

    // MARK: - Called from main

    func start() {
        queue.async { self.startOnQueue() }
    }

    /// Stops every attached IO and all observation. Waits at most `waitTimeout`; false when
    /// the queue did not get there in time (the caller then skips destroying and relies on
    /// process exit). Called on the queue itself it runs at once, but never from a callback:
    /// it removes the listener block that may be running it.
    @discardableResult
    func stop() -> Bool {
        guard !isOnQueue else {
            stopOnQueue()
            return true
        }
        let done = DispatchSemaphore(value: 0)
        queue.async {
            self.stopOnQueue()
            done.signal()
        }
        guard done.wait(timeout: .now() + waitTimeout) == .success else {
            logger.fault("Catch-all run queue did not stop within \(self.waitTimeout, format: .fixed(precision: 1)) s")
            return false
        }
        return true
    }

    func attach(_ handle: CatchAllIOHandle, deviceID: AudioDeviceID, excluded: Set<AudioObjectID>) {
        queue.async {
            self.handles[handle.aggregateID] = handle
            // Before start() the source cannot register it; start() registers every handle
            if self.isStarted { self.source.observeAbnormalStop(of: handle.aggregateID) }
            self.apply(self.logic.attach(handle.aggregateID, uid: handle.deviceUID, deviceID: deviceID,
                                         excluded: excluded, now: self.now()))
        }
    }

    /// Stops this handle's IO if it runs and drops it; other handles for the same device stay.
    /// True once the queue has done so: after that nothing here touches the handle and the
    /// caller may destroy it. False when the queue has not got to it within `waitTimeout`:
    /// the detach stays queued, so the caller must not destroy yet (work it puts on `queue`
    /// afterwards runs after the detach).
    func detach(_ handle: CatchAllIOHandle) async -> Bool {
        await withCheckedContinuation { continuation in
            let wait = DetachWait(continuation, timeout: waitTimeout)
            queue.async {
                self.detachOnQueue(handle)
                wait.finish(ran: true)
            }
        }
    }

    func setExcluded(_ handle: CatchAllIOHandle, _ excluded: Set<AudioObjectID>) {
        queue.async { self.apply(self.logic.setExcluded(handle.aggregateID, excluded, now: self.now())) }
    }

    func prepareInclusion(_ processes: Set<AudioObjectID>, on uids: Set<String>) {
        queue.async { self.apply(self.logic.prepareInclusion(processes, on: uids, now: self.now())) }
    }

    /// The process objects FineTune lists as apps (E3: their IO counts without a cap).
    func setListed(_ processes: Set<AudioObjectID>) {
        queue.async { self.setListedOnQueue(processes) }
    }

    /// Runs `body` on the queue and waits (tests and diagnostics).
    func sync<T>(_ body: (CatchAllRunLogic) -> T) -> T {
        isOnQueue ? body(logic) : queue.sync { body(logic) }
    }

    // MARK: - Queue

    private var isOnQueue: Bool { DispatchQueue.getSpecific(key: queueKey) != nil }

    /// Delays before registering the system listeners again after consecutive failures.
    static let listenerRetryDelays: [Double] = [1, 2, 4, 8, 16, 30]

    private func startOnQueue() {
        guard !isStarted else { return }
        isStarted = true
        startSource()
        refreshProcessList()
    }

    private func stopOnQueue() {
        for handle in Array(handles.values) { detachOnQueue(handle) }
        // A restart while stopped goes unnoticed: classify and report everything anew
        resetObservation()
        observationGeneration += 1
        listenerFailures = 0
        _ = logic.setProcesses([], now: now())
        dropPendingReports()
        timer?.cancel()
        timer = nil
        timerInterval = 0
        isStarted = false
    }

    /// Registers the system listeners and the abnormal-stop listener of every attached
    /// handle. If a system listener fails, all of them are registered again after a delay
    /// that grows with each failure in a row.
    private func startSource() {
        observationGeneration += 1
        let registered = source.start(on: queue) { [weak self] event in self?.handle(event) }
        for aggregate in handles.keys where logic.handles[aggregate] != nil {
            source.observeAbnormalStop(of: aggregate)
        }
        guard !registered else {
            if listenerFailures > 0 {
                logger.notice("Catch-all run control registered its Core Audio listeners after \(self.listenerFailures) failure(s)")
            }
            listenerFailures = 0
            return
        }
        let delays = Self.listenerRetryDelays
        let delay = delays[min(listenerFailures, delays.count - 1)]
        listenerFailures += 1
        if listenerFailures == 1 {
            logger.fault("Catch-all run control could not register its Core Audio listeners; retrying in \(delay, format: .fixed(precision: 0)) s")
        } else {
            logger.error("Catch-all run control listeners still not registered after \(self.listenerFailures) attempts; retrying in \(delay, format: .fixed(precision: 0)) s")
        }
        let generation = observationGeneration
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.observationGeneration == generation else { return }
            self.restartObservation()
        }
    }

    private func handle(_ event: ProcessActivityEvent) {
        // A block the HAL queued before stop() removed its listener
        guard isStarted else { return }
        switch event {
        case .processListChanged:
            refreshProcessList()
        case .processChanged(let process):
            refresh(process)
        case .serviceRestarted:
            // The attached aggregates died with the daemon, and their IDs may be reused: they
            // get no start, stop or rebuild from here on (the owner detaches and rebuilds)
            logger.notice("Core Audio restarted: \(self.logic.handles.count) catch-all IO handle(s) dropped")
            logic.serviceRestarted()
            // Until the listeners are registered again, notifications for old IDs read nothing
            // and new IDs are classified afresh; reports from the old daemon never reach main
            observed.removeAll()
            deviceKinds.removeAll()
            dropPendingReports()
            updateTimer()
            onServiceRestarted?()
            // Not from inside the listener block that is running now, which this removes
            queue.async { self.restartObservation() }
        case .ioStoppedAbnormally(let aggregate):
            // A handle dropped by a restart gets no rebuild
            guard let handle = handles[aggregate], logic.handles[aggregate] != nil else { return }
            logger.error("Catch-all IO on \(handle.deviceUID, privacy: .public) (aggregate \(aggregate)) stopped abnormally")
            onRebuild?(handle.deviceUID, aggregate, .ioDead)
        }
    }

    /// After a Core Audio restart every object ID may be new: register the listeners again,
    /// forget what was observed and classified, and read everything from scratch.
    private func restartObservation() {
        guard isStarted else { return }
        resetObservation()
        startSource()
        refreshProcessList()
    }

    /// Removes every listener and forgets what was observed and classified.
    private func resetObservation() {
        source.stop()
        observed.removeAll()
        deviceKinds.removeAll()
    }

    /// Observes new processes and reads them at once, because a process can already run
    /// output when it first appears. `all` reads every process (recheck and re-read);
    /// `edge` is false for the safety re-read.
    private func refreshProcessList(all: Bool = false, edge: Bool = true) {
        guard isStarted else { return }
        let list = Set(source.processList())
        for process in observed.subtracting(list) { source.forget(process) }
        observeAndRead(list.subtracting(observed), observing: list, all: all, edge: edge)
    }

    /// Listed objects whose appearance the queue missed are observed at once.
    private func setListedOnQueue(_ processes: Set<AudioObjectID>) {
        apply(logic.setListed(processes, now: now()))
        let missing = processes.subtracting(observed)
        guard isStarted, !missing.isEmpty else { return }
        observeAndRead(missing, observing: observed.union(missing), all: false, edge: true)
    }

    /// Observes `appeared`, makes `processes` the observed set, then reads run states (of
    /// `appeared`, or of every process when `all`) before the Devices of `appeared`.
    private func observeAndRead(_ appeared: Set<AudioObjectID>, observing processes: Set<AudioObjectID>, all: Bool, edge: Bool) {
        for process in appeared { source.observe(process, devices: readsDevices) }
        observed = processes
        apply(logic.setProcesses(processes, now: now()))
        // Follow-up reads only for the processes this notification brought
        readRunStates((all ? processes : appeared).sorted(), edge: edge, followUp: !all)
        readDevices(appeared.sorted())
    }

    /// Delays of the follow-up reads for a process that runs IO but reports no output yet.
    static let followUpDelays: [Double] = [0.01, 0.03, 0.1]

    private var readsDevices: Bool { observeDevices || logic.deviceFilterEnabled }

    /// A notification for one process: its run state, then its Devices.
    private func refresh(_ process: AudioObjectID) {
        readRunStates([process], edge: true, followUp: true)
        readDevices([process])
    }

    /// Reads and applies IsRunning and IsRunningOutput of every process before any Devices
    /// read, so a resume never waits behind those.
    private func readRunStates(_ processes: [AudioObjectID], edge: Bool, followUp: Bool) {
        for process in processes where observed.contains(process) {
            let output = source.isRunningOutput(process)
            let running = output || source.isRunning(process)
            apply(logic.setRunState(process, running: running, output: output, now: now(), edge: edge))
            // Core Audio notifies IsRunning but not IsRunningOutput, and the two can flip a few
            // milliseconds apart: read again shortly when the process runs but shows no output yet
            guard edge, followUp, running, !output else { continue }
            for delay in Self.followUpDelays {
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.readRunStates([process], edge: true, followUp: false)
                }
            }
        }
    }

    /// Devices of a process are read when it appears and on its own notification; a change of
    /// its IsRunningOutput alone is reported by the run-state read.
    private func readDevices(_ processes: [AudioObjectID]) {
        guard readsDevices else { return }
        for process in processes where observed.contains(process) {
            apply(logic.setOutputDevices(process, readOutputDevices(process), now: now()))
        }
    }

    /// Each device ID is classified once. An unresolvable ID is read again next time: it may
    /// belong to a device that is not published yet.
    private func readOutputDevices(_ process: AudioObjectID) -> ProcessOutputDevices {
        guard let ids = source.outputDeviceIDs(process) else { return .unknown }
        var kinds: [AudioDeviceID: OutputDeviceKind] = [:]
        for id in ids {
            if let kind = deviceKinds[id] {
                kinds[id] = kind
                continue
            }
            let kind = source.classify(id)
            if kind != .unresolvable { deviceKinds[id] = kind }
            kinds[id] = kind
        }
        return .known(kinds)
    }

    /// Drops the handle only if it is still the one attached under its aggregate ID.
    private func detachOnQueue(_ handle: CatchAllIOHandle) {
        let aggregate = handle.aggregateID
        guard handles[aggregate]?.state === handle.state else { return }
        handles[aggregate] = nil
        if logic.isRunning(aggregate) {
            _ = backend.stop(aggregate, handle.procID)
        }
        source.forgetAbnormalStop(of: aggregate)
        logic.detach(aggregate)
        updateTimer()
    }

    private func apply(_ effects: [CatchAllRunLogic.Effect]) {
        for effect in effects {
            switch effect {
            case .start(let aggregate):
                guard let handle = handles[aggregate] else { continue }
                handle.state.seedGain.store(true, ordering: .relaxed)
                handle.state.rearmGate.store(true, ordering: .relaxed)
                let started = hostTime()
                let err = backend.start(aggregate, handle.procID)
                let ms = Double(hostTime() &- started) / ticksPerSecond * 1000
                let reason = logic.neededBy(aggregate, now: seconds(started)) ?? "no process"
                logger.notice("Catch-all IO on \(handle.deviceUID, privacy: .public) (aggregate \(aggregate)) started in \(ms, format: .fixed(precision: 1)) ms for \(reason, privacy: .public) (status \(err))")
                apply(logic.startResult(aggregate, succeeded: err == noErr))
            case .stop(let aggregate):
                guard let handle = handles[aggregate] else { continue }
                _ = backend.stop(aggregate, handle.procID)
                logger.notice("Catch-all IO on \(handle.deviceUID, privacy: .public) (aggregate \(aggregate)) suspended")
            case .recheck:
                refreshProcessList(all: true)
            case .reread:
                refreshProcessList(all: true, edge: false)
            case .poll(let processes):
                for process in processes where observed.contains(process) {
                    apply(logic.setPolledOutput(process, source.isRunningOutput(process), now: now()))
                }
            case .rebuild(let aggregate, let reason):
                guard let handle = handles[aggregate] else { continue }
                logger.error("Catch-all on \(handle.deviceUID, privacy: .public) (aggregate \(aggregate)) needs a rebuild: \(reason.rawValue, privacy: .public)")
                onRebuild?(handle.deviceUID, aggregate, reason)
            case .outputWithoutEdge(let process):
                logger.notice("Process \(process) runs output without edge")
            case .devicesChanged(let process, let report):
                post(process, report)
            }
        }
        updateTimer()
    }

    /// Hands a report to main without waiting for it; reports that arrive before main runs
    /// the task go with it.
    private func post(_ process: AudioObjectID, _ report: ProcessDeviceReport) {
        guard onDevicesChanged != nil else { return }
        let generation: Int? = pendingReports.withLock { pending in
            let first = pending.reports.isEmpty
            pending.reports[process] = report
            return first ? pending.generation : nil
        }
        guard let generation else { return }
        Task { @MainActor in
            let reports = self.pendingReports.withLock { pending in
                // A task from before a restart or stop() takes nothing; a later task carries them
                guard pending.generation == generation else { return [AudioObjectID: ProcessDeviceReport]() }
                let reports = pending.reports
                pending.reports.removeAll()
                return reports
            }
            guard !reports.isEmpty else { return }
            self.onDevicesChanged?(reports)
        }
    }

    /// Drops the reports main has not taken; a report task created before this delivers
    /// nothing, so later reports reach main after anything the owner posted meanwhile.
    private func dropPendingReports() {
        pendingReports.withLock { pending in
            pending.generation += 1
            pending.reports.removeAll()
        }
    }

    /// Interval and first delay from the logic (a 100 ms poll of capped processes while a
    /// catch-all is stopped, else 2 s while an IO runs or the 3 s safety re-read, which keeps
    /// its phase; nothing when no catch-all is attached or before start()).
    private func updateTimer() {
        let current = now()
        let interval = isStarted ? logic.timerInterval(now: current) : 0
        guard interval != timerInterval else { return }
        timerInterval = interval
        timer?.cancel()
        timer = nil
        guard interval > 0 else { return }
        let leeway: DispatchTimeInterval = interval >= logic.rereadInterval ? .seconds(1)
            : interval >= logic.tickInterval ? .milliseconds(500) : .milliseconds(10)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + logic.timerDelay(now: current), repeating: interval, leeway: leeway)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// Runs one timer event now (tests).
    func tickOnQueueForTesting() {
        isOnQueue ? tick() : queue.sync { tick() }
    }

    private func tick() {
        guard isStarted else { return }
        var lastAudible: [AudioDeviceID: Double] = [:]
        var lastCallback: [AudioDeviceID: Double] = [:]
        for (aggregate, handle) in handles {
            lastAudible[aggregate] = seconds(handle.state.lastAudibleHostTime.load(ordering: .relaxed))
            lastCallback[aggregate] = seconds(handle.state.lastCallbackHostTime.load(ordering: .relaxed))
        }
        apply(logic.tick(now: now(), lastAudible: lastAudible, lastCallback: lastCallback))
    }

    private func now() -> Double { seconds(hostTime()) }

    private func seconds(_ ticks: UInt64) -> Double { Double(ticks) / ticksPerSecond }
}

/// What `post` hands to main, with the generation that `dropPendingReports` advances.
nonisolated private struct PendingReports {
    var generation = 0
    var reports: [AudioObjectID: ProcessDeviceReport] = [:]
}

/// Resumes a waiting `detach` exactly once: from the queue when the detach ran, or from
/// its own timer when the queue did not get there in time.
nonisolated private final class DetachWait: @unchecked Sendable {
    private let continuation: Mutex<CheckedContinuation<Bool, Never>?>
    private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))

    init(_ continuation: CheckedContinuation<Bool, Never>, timeout: Double) {
        self.continuation = Mutex(continuation)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { self.finish(ran: false) }
        timer.resume()
    }

    func finish(ran: Bool) {
        // Cancelling also releases the handler, which holds this object
        timer.cancel()
        continuation.withLock { $0.take() }?.resume(returning: ran)
    }
}

/// Core Audio notifications for the run control: the process list, each process's
/// IsRunning (and output devices when observed), service restarts and abnormal IO stops of
/// catch-all aggregates. Confined to the run control's queue.
nonisolated final class HALProcessOutputActivitySource: ProcessOutputActivitySource, @unchecked Sendable {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.finetuneapp.FineTune", category: "CatchAllRun")
    private var queue: DispatchQueue?
    private var handler: (@Sendable (ProcessActivityEvent) -> Void)?
    private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var processListeners: [AudioObjectID: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)]] = [:]
    private var aggregateListeners: [AudioDeviceID: (AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = [:]

    func processList() -> [AudioObjectID] {
        (try? AudioObjectID.readProcessList()) ?? []
    }

    func isRunning(_ process: AudioObjectID) -> Bool {
        process.readProcessIsRunning()
    }

    func isRunningOutput(_ process: AudioObjectID) -> Bool {
        ProcessIdentity.isRunningOutput(process)
    }

    func outputDeviceIDs(_ process: AudioObjectID) -> [AudioDeviceID]? {
        try? process.readArray(kAudioProcessPropertyDevices, scope: .output, defaultValue: AudioDeviceID(0))
    }

    func classify(_ device: AudioDeviceID) -> OutputDeviceKind {
        guard (try? device.readDeviceUID()) != nil else { return .unresolvable }
        return device.isAggregateDevice() || device.isVirtualDevice() ? .aggregateOrVirtual : .plain
    }

    func start(on queue: DispatchQueue, handler: @escaping @Sendable (ProcessActivityEvent) -> Void) -> Bool {
        self.queue = queue
        self.handler = handler
        let list = addSystemListener(kAudioHardwarePropertyProcessObjectList) { handler(.processListChanged) }
        let restart = addSystemListener(kAudioHardwarePropertyServiceRestarted) { handler(.serviceRestarted) }
        return list && restart
    }

    func observe(_ process: AudioObjectID, devices: Bool) {
        guard let queue, let handler, processListeners[process] == nil else { return }
        var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        // IsRunningOutput itself posts no change notifications (measured on macOS 27.2);
        // IsRunning does, so it triggers the re-read. IsRunningOutput stays registered in case
        // a later macOS posts it.
        var selectors = [(kAudioProcessPropertyIsRunning, kAudioObjectPropertyScopeGlobal),
                         (kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal)]
        if devices { selectors.append((kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput)) }
        for (selector, scope) in selectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { _, _ in handler(.processChanged(process)) }
            if AudioObjectAddPropertyListenerBlock(process, &address, queue, block) == noErr {
                listeners.append((address, block))
            }
        }
        processListeners[process] = listeners
    }

    func forget(_ process: AudioObjectID) {
        guard let queue, let listeners = processListeners.removeValue(forKey: process) else { return }
        for (address, block) in listeners {
            var address = address
            // The process may already be gone (kAudioHardwareBadObjectError); nothing to undo then
            _ = AudioObjectRemovePropertyListenerBlock(process, &address, queue, block)
        }
    }

    func observeAbnormalStop(of aggregate: AudioDeviceID) {
        guard let queue, let handler, aggregateListeners[aggregate] == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOStoppedAbnormally,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler(.ioStoppedAbnormally(aggregate)) }
        if AudioObjectAddPropertyListenerBlock(aggregate, &address, queue, block) == noErr {
            aggregateListeners[aggregate] = (address, block)
        }
    }

    func forgetAbnormalStop(of aggregate: AudioDeviceID) {
        guard let queue, let (address, block) = aggregateListeners.removeValue(forKey: aggregate) else { return }
        var mutableAddress = address
        _ = AudioObjectRemovePropertyListenerBlock(aggregate, &mutableAddress, queue, block)
    }

    func stop() {
        guard let queue else { return }
        for process in Array(processListeners.keys) { forget(process) }
        for aggregate in Array(aggregateListeners.keys) { forgetAbnormalStop(of: aggregate) }
        for (address, block) in systemListeners {
            var address = address
            _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
        systemListeners.removeAll()
        handler = nil
    }

    private func addSystemListener(_ selector: AudioObjectPropertySelector, _ action: @escaping @Sendable () -> Void) -> Bool {
        guard let queue else { return false }
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in action() }
        let err = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        guard err == noErr else {
            // The run control logs the failure as a fault once and retries
            logger.error("Could not observe system property \(selector): status \(err)")
            return false
        }
        systemListeners.append((address, block))
        return true
    }
}
