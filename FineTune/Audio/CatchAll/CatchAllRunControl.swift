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
    case ioStoppedAbnormally(String)
}

/// Where the run control learns which processes run output. Behind a protocol so tests
/// drive it without Core Audio.
nonisolated protocol ProcessOutputActivitySource: AnyObject, Sendable {
    func processList() -> [AudioObjectID]
    func isRunningOutput(_ process: AudioObjectID) -> Bool
    func outputDevices(_ process: AudioObjectID) -> ProcessOutputDevices
    /// Starts delivering events on `queue`.
    func start(on queue: DispatchQueue, handler: @escaping @Sendable (ProcessActivityEvent) -> Void)
    func observe(_ process: AudioObjectID, devices: Bool)
    func forget(_ process: AudioObjectID)
    func observeAbnormalStop(of aggregate: AudioDeviceID, uid: String)
    func forgetAbnormalStop(of aggregate: AudioDeviceID)
    func stop()
}

/// Starts and stops the IO of attached catch-alls on its own serial queue, so a blocked
/// main thread never delays a resume. Main attaches, detaches and updates exclusions; this
/// queue owns everything else. All state below is confined to `queue`.
nonisolated final class CatchAllRunControl: @unchecked Sendable {
    let queue: DispatchQueue
    private let source: ProcessOutputActivitySource
    private let backend: any CatchAllBackend
    private let hostTime: @Sendable () -> UInt64
    private let ticksPerSecond: Double
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.finetuneapp.FineTune", category: "CatchAllRun")

    private var logic: CatchAllRunLogic
    private var handles: [String: CatchAllIOHandle] = [:]
    private var observed: Set<AudioObjectID> = []
    private var timer: DispatchSourceTimer?
    private var timerInterval: Double = 0
    private var isStarted = false

    /// Called on `queue`; the owner hops to main.
    var onRebuild: (@Sendable (String, CatchAllRunLogic.RebuildReason) -> Void)?
    var onServiceRestarted: (@Sendable () -> Void)?

    init(
        source: ProcessOutputActivitySource,
        backend: any CatchAllBackend,
        logic: CatchAllRunLogic = CatchAllRunLogic(),
        queue: DispatchQueue = DispatchQueue(label: "com.adschfr.FineTuneFork.catchall", qos: .userInteractive),
        hostTime: @escaping @Sendable () -> UInt64 = { mach_absolute_time() }
    ) {
        self.source = source
        self.backend = backend
        self.logic = logic
        self.queue = queue
        self.hostTime = hostTime
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        ticksPerSecond = 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer)
    }

    // MARK: - Called from main

    func start() {
        queue.async { self.startOnQueue() }
    }

    /// Stops every attached IO and all observation; returns when done.
    func stop() {
        queue.sync {
            for uid in handles.keys { detachOnQueue(uid) }
            source.stop()
            observed.removeAll()
            timer?.cancel()
            timer = nil
            isStarted = false
        }
    }

    func attach(_ handle: CatchAllIOHandle, deviceID: AudioDeviceID, excluded: Set<AudioObjectID>) {
        queue.async {
            self.handles[handle.deviceUID] = handle
            self.source.observeAbnormalStop(of: handle.aggregateID, uid: handle.deviceUID)
            self.apply(self.logic.attach(handle.deviceUID, deviceID: deviceID, excluded: excluded, now: self.now()))
        }
    }

    /// Returns once the queue has stopped the IO and dropped the handle: after that, nothing
    /// here touches it and the caller may destroy it.
    func detach(_ uid: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.detachOnQueue(uid)
                continuation.resume()
            }
        }
    }

    func setExcluded(_ uid: String, _ excluded: Set<AudioObjectID>) {
        queue.async { self.apply(self.logic.setExcluded(uid, excluded, now: self.now())) }
    }

    func prepareInclusion(_ processes: Set<AudioObjectID>, on uids: Set<String>) {
        queue.async { self.apply(self.logic.prepareInclusion(processes, on: uids, now: self.now())) }
    }

    /// Runs `body` on the queue and waits (tests and diagnostics).
    func sync<T>(_ body: (CatchAllRunLogic) -> T) -> T {
        queue.sync { body(logic) }
    }

    // MARK: - Queue

    private func startOnQueue() {
        guard !isStarted else { return }
        isStarted = true
        source.start(on: queue) { [weak self] event in self?.handle(event) }
        refreshProcessList()
    }

    private func handle(_ event: ProcessActivityEvent) {
        switch event {
        case .processListChanged:
            refreshProcessList()
        case .processChanged(let process):
            refresh(process)
        case .serviceRestarted:
            onServiceRestarted?()
        case .ioStoppedAbnormally(let uid):
            guard handles[uid] != nil else { return }
            logger.error("Catch-all IO on \(uid, privacy: .public) stopped abnormally")
            onRebuild?(uid, .ioDead)
        }
    }

    private func refreshProcessList() {
        let list = Set(source.processList())
        let appeared = list.subtracting(observed)
        for process in observed.subtracting(list) { source.forget(process) }
        for process in appeared { source.observe(process, devices: logic.deviceFilterEnabled) }
        observed = list
        apply(logic.setProcesses(list, now: now()))
        // A process can already run output when it first appears
        for process in appeared { refresh(process) }
    }

    private func refresh(_ process: AudioObjectID) {
        guard observed.contains(process) else { return }
        if logic.deviceFilterEnabled {
            apply(logic.setOutputDevices(process, source.outputDevices(process), now: now()))
        }
        apply(logic.setRunningOutput(process, source.isRunningOutput(process), now: now()))
    }

    private func detachOnQueue(_ uid: String) {
        guard let handle = handles.removeValue(forKey: uid) else { return }
        if logic.isRunning(uid) {
            _ = backend.stop(handle.aggregateID, handle.procID)
        }
        source.forgetAbnormalStop(of: handle.aggregateID)
        logic.detach(uid)
        updateTimer()
    }

    private func apply(_ effects: [CatchAllRunLogic.Effect]) {
        for effect in effects {
            switch effect {
            case .start(let uid):
                guard let handle = handles[uid] else { continue }
                handle.state.seedGain.store(true, ordering: .relaxed)
                handle.state.rearmGate.store(true, ordering: .relaxed)
                let started = hostTime()
                let err = backend.start(handle.aggregateID, handle.procID)
                let ms = Double(hostTime() &- started) / ticksPerSecond * 1000
                logger.notice("Catch-all IO on \(uid, privacy: .public) started in \(ms, format: .fixed(precision: 1)) ms (status \(err))")
                apply(logic.startResult(uid, succeeded: err == noErr))
            case .stop(let uid):
                guard let handle = handles[uid] else { continue }
                _ = backend.stop(handle.aggregateID, handle.procID)
                logger.notice("Catch-all IO on \(uid, privacy: .public) suspended")
            case .recheck:
                for process in observed { refresh(process) }
            case .rebuild(let uid, let reason):
                logger.error("Catch-all on \(uid, privacy: .public) needs a rebuild: \(reason.rawValue, privacy: .public)")
                onRebuild?(uid, reason)
            }
        }
        updateTimer()
    }

    /// 2 s checks while an IO runs; a 10 s safety re-read of process states while all are
    /// stopped (for missed notifications); nothing when no catch-all is attached.
    private func updateTimer() {
        let interval: Double = handles.isEmpty ? 0 : (logic.anyRunning ? 2 : 10)
        guard interval != timerInterval else { return }
        timerInterval = interval
        timer?.cancel()
        timer = nil
        guard interval > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(interval > 2 ? 5000 : 500))
        timer.setEventHandler { [weak self] in self?.timerFired() }
        timer.resume()
        self.timer = timer
    }

    private func timerFired() {
        guard logic.anyRunning else {
            for process in observed { refresh(process) }
            return
        }
        tick()
    }

    func tickOnQueueForTesting() {
        queue.sync { tick() }
    }

    private func tick() {
        var lastAudible: [String: Double] = [:]
        var lastCallback: [String: Double] = [:]
        for (uid, handle) in handles {
            lastAudible[uid] = seconds(handle.state.lastAudibleHostTime.load(ordering: .relaxed))
            lastCallback[uid] = seconds(handle.state.lastCallbackHostTime.load(ordering: .relaxed))
        }
        apply(logic.tick(now: now(), lastAudible: lastAudible, lastCallback: lastCallback))
    }

    private func now() -> Double { seconds(hostTime()) }

    private func seconds(_ ticks: UInt64) -> Double { Double(ticks) / ticksPerSecond }
}

/// Core Audio notifications for the run control: the process list, each process's
/// IsRunningOutput (and output devices when the device filter is on), service restarts
/// and abnormal IO stops of catch-all aggregates. Confined to the run control's queue.
nonisolated final class HALProcessOutputActivitySource: ProcessOutputActivitySource, @unchecked Sendable {
    private var queue: DispatchQueue?
    private var handler: (@Sendable (ProcessActivityEvent) -> Void)?
    private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var processListeners: [AudioObjectID: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)]] = [:]
    private var aggregateListeners: [AudioDeviceID: (AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = [:]

    func processList() -> [AudioObjectID] {
        (try? AudioObjectID.readProcessList()) ?? []
    }

    func isRunningOutput(_ process: AudioObjectID) -> Bool {
        ProcessIdentity.isRunningOutput(process)
    }

    func outputDevices(_ process: AudioObjectID) -> ProcessOutputDevices {
        guard let ids = try? process.readArray(kAudioProcessPropertyDevices, scope: .output, defaultValue: AudioDeviceID(0)) else {
            return .unknown
        }
        let hasNonPlain = ids.contains { id in
            id.isAggregateDevice() || id.isVirtualDevice() || (try? id.readDeviceUID()) == nil
        }
        return .known(Set(ids), hasNonPlain: hasNonPlain)
    }

    func start(on queue: DispatchQueue, handler: @escaping @Sendable (ProcessActivityEvent) -> Void) {
        self.queue = queue
        self.handler = handler
        addSystemListener(kAudioHardwarePropertyProcessObjectList) { handler(.processListChanged) }
        addSystemListener(kAudioHardwarePropertyServiceRestarted) { handler(.serviceRestarted) }
    }

    func observe(_ process: AudioObjectID, devices: Bool) {
        guard let queue, let handler, processListeners[process] == nil else { return }
        var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        var selectors = [(kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal)]
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

    func observeAbnormalStop(of aggregate: AudioDeviceID, uid: String) {
        guard let queue, let handler, aggregateListeners[aggregate] == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOStoppedAbnormally,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler(.ioStoppedAbnormally(uid)) }
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

    private func addSystemListener(_ selector: AudioObjectPropertySelector, _ action: @escaping @Sendable () -> Void) {
        guard let queue else { return }
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in action() }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr {
            systemListeners.append((address, block))
        }
    }
}
