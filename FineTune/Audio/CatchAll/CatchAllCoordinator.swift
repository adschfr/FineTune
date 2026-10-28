// FineTune/Audio/CatchAll/CatchAllCoordinator.swift
import AudioToolbox
import Foundation
import os
import Synchronization

/// What the coordinator did, for the listening session's event lines (design §16.8).
nonisolated enum CatchAllEvent: Sendable, Equatable {
    /// The device's catch-all entered a phase (`building` when its build starts).
    case phase(uid: String, CatchAllPhase)
    case buildFailed(uid: String, reason: String)
    /// A new catch-all's list covers every claim and has applied: its initial hold ended.
    case released(uid: String)
    case pushed(uid: String, excluded: [AudioObjectID])
    case pushFailed(uid: String, excluded: [AudioObjectID])
    /// I1: these processes were excluded without a claim and were removed from the list.
    case repaired(uid: String, removed: [AudioObjectID])
    case decision(pid: pid_t, uid: String, TapDecision)
    /// C9: the app's processes play to a device other than the catch-all's.
    case playsElsewhere(pid: pid_t, uid: String)
    /// The coordinator zeroed (`held`) or opened the output of the catch-all on this aggregate.
    case output(uid: String, aggregate: AudioDeviceID, held: Bool)
    /// R1 (§16.3 E13): coverage of the device ends with promotion to per-app taps.
    case retiring(uid: String, CatchAllRetireReason)
    /// The device's entry is gone: R4 ended at the detach, or coverage ended without
    /// promotion (G).
    case ended(uid: String, reason: String)
    /// A make-before-break rebuild (§5 E) took over.
    case rebuilt(uid: String)
    /// A watchdog fired (also logged at `.fault`).
    case watchdog(uid: String, CatchAllWatchdog)
    /// A failure that counts toward backoff and the breaker (§16.6). Not reported for G, for a
    /// device that is not alive, or for an unreadable process list.
    case failure(uid: String, CatchAllFailure)
}

/// Why coverage of a device ends with promotion (R, design §16.3 E13).
nonisolated enum CatchAllRetireReason: String, Sendable, Equatable {
    /// A push failed after its retry, and the rebuild with the desired list failed too (§4.6).
    case pushFailed
    /// Three counted IO failures for one device ID within 2 min.
    case givenUp
    /// The circuit breaker opened.
    case breaker
    /// The run queue did not answer within its 1 s bound.
    case runQueueTimeout
    /// A reconcile found that the device no longer has software volume.
    case tierChanged
    /// A rebuild for another reason (E12, E15, an IO failure) failed.
    case rebuildFailed
    /// The listening session's injected retirement.
    case injected
}

/// Why a catch-all is rebuilt make before break (E, design §5 E). The second half of failure
/// handling adds the callers of the last three: a format change (E15), dead IO, and a new ID
/// or the device alive again (E12).
nonisolated enum CatchAllRebuildReason: String, Sendable, Equatable {
    /// A push failed after its retry, or a list was still missing at its watchdog (§4.6).
    case pushFailed
    case formatChanged
    case ioFailed
    case deviceChanged
}

/// A failure that counts toward backoff and the breaker (design §16.6).
nonisolated enum CatchAllFailure: String, Sendable, Equatable {
    /// A rebuild could not build its new catch-all on an alive device.
    case buildFailed
    /// The run queue did not answer a detach within its bound; once until it has run the
    /// detaches that timed out.
    case runQueueTimeout
}

/// The coordinator's watchdogs (design §16.3 constants, §16.6 "Hold stuck").
nonisolated enum CatchAllWatchdog: String, Sendable, Equatable {
    /// A grow wait, after `max(1 s, G + 0.6 s)`.
    case grow
    /// A shrink wait, after 2 s.
    case shrink
    /// R3 not reached 2 s after R1.
    case retirement
    /// A new catch-all still held for its initial list after the grow watchdog's time.
    case initialList
    /// A rebuilt catch-all that has not taken over 2 s after its attach, or a rebuild that could
    /// not read the process list for 2 s.
    case rebuild
}

// MARK: - Coordinator

/// Owns the catch-alls (design §16.4): which devices get one, their builds, the claims of
/// per-app taps and the pushes that follow from them, the waits of handovers, gain, the I1
/// check and the C9 settle state. Builds and pushes run on main; the run control starts and
/// stops IO on its queue.
///
/// Engine hooks never build inside their handler: `reconcile()` and `requestReevaluation()`
/// share one next-turn task, which runs a pending reconcile first and then
/// `onCoverageMayHaveChanged`. A build's wait spins the main run loop (V4), and so can the
/// callback (`activate`): a turn requested during either runs once it ends, never nested,
/// and a building catch-all is never pushed to.
///
/// Coverage ends in one of two ways. With promotion (R, `retire`, always in the coordinator's
/// own turn): the engine taps every app the catch-all played, then the catch-all is held,
/// detached and destroyed. Without (G): for an absent device and at `stop()`. A push that
/// fails after its retry rebuilds make before break (E, `rebuild`), and a failed rebuild
/// retires. Watchdogs bound every wait, hold and rebuild; a catch-all is destroyed only after
/// the run queue has detached it.
@MainActor
final class CatchAllCoordinator: CatchAllCoordinating {
    /// C9: seconds after the last Devices or IsRunningOutput change before processes that
    /// name no D-like device count as playing elsewhere.
    static let settleDelay: Double = 0.5
    /// C9: seconds the devices of a routing change's `from` set count as D-like.
    static let routingGrace: Double = 2
    /// A grow push whose IO ran fewer than two callbacks counts as applied after this.
    static let stallTimeout: Double = 0.5
    /// A grow push followed by no callback for this long found the IO stopped: the next
    /// start plays the applied list.
    static let idleWindow: Double = 0.1
    /// While a grow wait needs one more callback, it is checked this often.
    static let callbackPoll: Double = 0.01
    /// A flush that could not read the process list tries again after this.
    static let processListRetryDelay: Double = 0.1
    /// E: a rebuilt catch-all takes over after its first IO callback or after this.
    static let firstCallbackWait: Double = 0.2
    /// R4: a held catch-all kept aside for an absent app is destroyed after this, and again
    /// after this while an absent app is still routed to its device (§16.12 item 5).
    static let keepAsideDelay: Double = 30
    /// Watchdogs (§16.3); the grow watchdog is `max(1 s, G + 0.6 s)`.
    static let shrinkWatchdog: Double = 2
    static let retirementWatchdog: Double = 2
    static let rebuildWatchdog: Double = 2
    /// A wait's watchdog does not judge a device while the process list is unreadable, for at
    /// most this long past its time; then it judges with the claims' processes, dead ones
    /// included.
    static let unreadableListGrace: Double = 2
    /// Slack when comparing clock readings with deadlines.
    private static let tolerance: Double = 1e-6

    let isEnabled = true
    var onCoverageWillEnd: ((String) -> Bool)?
    var onCoverageMayHaveChanged: (() -> Void)?
    var onClaimsVoided: ((Set<pid_t>) -> Void)?
    var onEvent: ((CatchAllEvent) -> Void)?

    private let env: CatchAllEnvironment
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.finetuneapp.FineTune", category: "CatchAll")

    private var isStarted = false
    /// The run control runs from `start()` until `stop()`.
    private var runControlStarted = false
    private var selfObject = AudioObjectID.unknown
    /// Opened by repeated failures (design §16.6); closed until the second half of failure
    /// handling counts them.
    private(set) var breakerOpen = false
    /// Devices given up after repeated IO failures (second half of failure handling).
    private(set) var givenUp: Set<AudioDeviceID> = []

    private var devices: [String: CatchAllDevice] = [:]
    /// One counter per device UID, bumped when a claim change alters its list; kept across
    /// rebuilds so an old ticket never waits for a lower number.
    private var generations: [String: UInt64] = [:]
    private var claims: [ObjectIdentifier: ClaimEntry] = [:]
    private var waiters: [Waiter] = []
    private var nextWaiterID = 0
    /// Catch-alls whose coverage ended, until they are destroyed.
    private var ending: [EndingCatchAll] = []
    /// The listed apps' process objects by pid (`appsChanged`); C9 is evaluated per app, on
    /// the same sets the gate asks about.
    private var apps: [pid_t: [AudioObjectID]] = [:]
    private var listed: Set<AudioObjectID> = []
    /// The last ID seen for each output UID, so a routing change away from a device that has
    /// just disappeared still gets its C9 grace.
    private var knownOutputIDs: [String: AudioDeviceID] = [:]
    private var lastIneligibility: [String: CatchAllPlan.Ineligibility] = [:]
    private var decisions: [pid_t: NotedDecision] = [:]
    /// The process list could not be read at the last flush (logged once per streak).
    private var processListUnreadable = false
    /// Detaches that timed out and have not run on the run queue yet; a blocked queue counts
    /// once until it has run them (§16.6).
    private var stuckDetaches = 0
    private var queueTimeoutCounted = false

    // The next-turn task, the flush and the timers
    private var pendingReconcile = false
    private var pendingReevaluation = false
    /// Retirements and rebuilds wait for the next turn: R2 and a build spin the main run loop.
    private var pendingRetirements: [String: CatchAllRetireReason] = [:]
    private var pendingRebuilds: [String: CatchAllRebuildReason] = [:]
    /// Catch-alls kept aside whose time ran out; their check calls the engine, which spins.
    private var pendingKeptChecks: [EndingCatchAll] = []
    private var turn: CatchAllScheduledAction?
    private var flushAction: CatchAllScheduledAction?
    private var checkAction: CatchAllScheduledAction?
    private var settleAction: CatchAllScheduledAction?
    private var watchdogAction: CatchAllScheduledAction?
    /// Builds in progress. Their wait spins the main run loop (V4), which can run scheduled
    /// work inside them.
    private var buildDepth = 0
    /// Turns in progress. The callback can spin the main run loop too (`activate`).
    private var turnDepth = 0

    // C9 settle state
    private var reports: [AudioObjectID: ProcessDeviceReport] = [:]
    private var reportChanged: [AudioObjectID: Double] = [:]
    private var graces: [RoutingGrace] = []
    /// Per device, the apps reported as playing elsewhere (each triggers once).
    private var elsewhere: [String: Set<pid_t>] = [:]

    init(environment: CatchAllEnvironment) {
        env = environment
        // Set once, before the run control starts: its queue reads them while it runs
        env.runControl.onDevicesChanged = { [weak self] reports in self?.handleDeviceReports(reports) }
        env.runControl.onProcessListChanged = { [weak self] in self?.processListChanged() }
    }

    // MARK: State

    var affectsAudio: Bool { env.mode == .on && !breakerOpen }

    var catchAllDeviceUIDs: Set<String> {
        Set(devices.values.filter { !$0.phase.isRetiring }.map { $0.uid })
    }

    func phase(_ uid: String) -> CatchAllPhase? {
        devices[uid]?.phase
    }

    func isLive(_ uid: String) -> Bool {
        let phase = devices[uid]?.phase
        return phase == .live || phase == .dormant
    }

    func covers(_ uid: String) -> Bool {
        affectsAudio && isLive(uid)
    }

    func takesRetirementHold(targets: Set<String>) -> Bool {
        targets.contains { devices[$0]?.phase == .retiring(caHeld: false) }
    }

    func processIsLive(_ process: AudioObjectID) -> Bool {
        // An unreadable list says nothing about the process: a handover keeps its wait
        env.processList()?.contains(process) ?? true
    }

    func isRunningOutput(_ process: AudioObjectID) -> Bool {
        env.isRunningOutput(process)
    }

    /// The device's catch-all, once built.
    func catchAll(for uid: String) -> CatchAllTapController? {
        devices[uid]?.controller
    }

    /// Handovers waiting for an applied list.
    var pendingWaitCount: Int { waiters.count }

    /// Tests only: puts the device's catch-all into `phase` without what a transition does
    /// (no hold, detach or alive listener). Failure handling enters dormant and retiring
    /// through its own transitions (design §16.3 E12, E13), never through this. What a phase
    /// means for the rest is here: flush and the I1 check skip dormant and retiring
    /// catch-alls, a retiring one keeps its gain, `isLive` and `covers` follow.
    func setPhaseForTesting(_ phase: CatchAllPhase, for uid: String) {
        guard let device = devices[uid], device.phase != phase else { return }
        device.phase = phase
        logger.notice("Catch-all on \(uid, privacy: .public): \(String(describing: phase), privacy: .public)")
        emit(.phase(uid: uid, phase))
        evaluateSettle()
        checkWaiters()
    }

    // MARK: Lifecycle

    /// Starts the run control and builds at once, so the gate that runs right after sees
    /// every catch-all and apps on a covered output need no tap (E1).
    func start() {
        isStarted = true
        if !runControlStarted {
            runControlStarted = true
            env.runControl.start()
        }
        pendingReconcile = true
        // Inside a build's wait or a turn, the reconcile runs once that ends
        guard buildDepth == 0, turnDepth == 0 else { return }
        pendingReconcile = false
        runReconcile()
    }

    /// E19: ends every catch-all's coverage without promotion (G), building ones included (a
    /// build whose wait is running is destroyed when it ends), destroys catch-alls kept aside
    /// once their queued detach has run, completes every wait, cancels the timers and stops
    /// the run control within its 1 s bound. The gate is not called back after this. Never
    /// called from a run-control callback, which runs on its queue. A later `start()` starts
    /// the run control again.
    func stop() {
        isStarted = false
        pendingReconcile = false
        pendingReevaluation = false
        pendingRetirements = [:]
        pendingRebuilds = [:]
        pendingKeptChecks = []
        for device in devices.values.sorted(by: { $0.uid < $1.uid }) {
            endCoverage(device, reason: "stopped")
        }
        for entry in ending where entry.keptAside {
            entry.keptAside = false
            entry.keepTimer?.cancel()
            entry.keepTimer = nil
            destroyIfDone(entry)
        }
        // G completed the waits on every device, so none is expected here; this backstop ends
        // any left over, whose handover would otherwise hang
        let open = waiters
        waiters.removeAll()
        for action in [turn, flushAction, checkAction, settleAction, watchdogAction] { action?.cancel() }
        turn = nil
        flushAction = nil
        checkAction = nil
        settleAction = nil
        watchdogAction = nil
        for waiter in open { waiter.continuation.resume() }
        guard runControlStarted else { return }
        runControlStarted = false
        if !env.runControl.stop() {
            // Each catch-all is destroyed once its queued detach has run, or dies with FineTune (H9)
            logger.fault("Catch-all run control did not stop within its bound")
        }
    }

    func reconcile() {
        pendingReconcile = true
        scheduleTurn()
    }

    func requestReevaluation() {
        pendingReevaluation = true
        scheduleTurn()
    }

    /// E12 checks (a new ID or a device that is not alive) come with the second half of
    /// failure handling; a refresh never builds inside the device monitor's handler.
    func deviceListRefreshed() {
        _ = listedOutputs()
        reconcile()
    }

    // Format changes (E15) come with the second half of failure handling; until then they
    // leave the catch-all as is.
    func formatChanging(uid: String) {}
    func formatUnchanged(uid: String) {}
    func formatChanged(uid: String) async {}

    private func scheduleTurn() {
        // Inside a build's wait or a turn: scheduled when that ends
        guard turn == nil, buildDepth == 0, turnDepth == 0 else { return }
        turn = env.clock.schedule(after: 0) { [weak self] in self?.runTurn() }
    }

    /// Retirements first (a rebuild never replaces a retiring catch-all, and a reconcile leaves
    /// one alone), then the catch-alls kept aside, rebuilds, the reconcile and the gate.
    private func runTurn() {
        turn = nil
        // Scheduled before a build began whose wait now runs it: scheduled again when it ends
        guard buildDepth == 0, turnDepth == 0 else { return }
        turnDepth += 1
        defer {
            turnDepth -= 1
            resumeDeferredTurn()
        }
        let retirements = pendingRetirements
        pendingRetirements = [:]
        for (uid, reason) in retirements.sorted(by: { $0.key < $1.key }) {
            performRetirement(uid, reason)
        }
        let checks = pendingKeptChecks
        pendingKeptChecks = []
        for entry in checks { recheckKeptAside(entry) }
        let rebuilds = pendingRebuilds
        pendingRebuilds = [:]
        for (uid, reason) in rebuilds.sorted(by: { $0.key < $1.key }) {
            performRebuild(uid, reason)
        }
        if pendingReconcile {
            pendingReconcile = false
            runReconcile()
        }
        if pendingReevaluation {
            pendingReevaluation = false
            if isStarted { onCoverageMayHaveChanged?() }
        }
    }

    /// Work requested during a build's wait or a turn runs now that it ended.
    private func resumeDeferredTurn() {
        guard pendingReconcile || pendingReevaluation || !pendingRetirements.isEmpty
                || !pendingRebuilds.isEmpty || !pendingKeptChecks.isEmpty else { return }
        scheduleTurn()
    }

    /// Runs a callback into the engine that may spin the main run loop (`activate`): turns
    /// requested meanwhile, retirements included, run after it.
    private func spinning<T>(_ body: () -> T) -> T {
        turnDepth += 1
        defer {
            turnDepth -= 1
            resumeDeferredTurn()
        }
        return body()
    }

    /// Ends coverage of devices that are no longer listed (G), retires a live catch-all whose
    /// device no longer has software volume (R, in the next turn: `start()` runs this in the
    /// engine's call), and builds a catch-all for every eligible listed device that has none.
    /// A retiring device is left alone until its R4 ends. Dormant devices and a new ID come
    /// with the second half of failure handling.
    private func runReconcile() {
        guard isStarted else { return }
        if !selfObject.isValid { selfObject = env.selfObject() }
        let outputs = listedOutputs().sorted(by: { $0.uid < $1.uid })
        let listedUIDs = Set(outputs.map(\.uid))
        for device in devices.values.sorted(by: { $0.uid < $1.uid }) where !listedUIDs.contains(device.uid) {
            guard device.phase == .live || device.phase == .dormant else { continue }
            endCoverage(device, reason: "absent")
        }
        var built = false
        for output in outputs {
            // A stop() during an earlier build's wait or retirement ends the pass
            guard isStarted else { break }
            let reason = ineligibility(of: output)
            noteEligibility(output.uid, reason)
            if let device = devices[output.uid] {
                if device.phase == .live, env.tier(output.id) != .software {
                    queueRetirement(output.uid, .tierChanged)
                }
                continue
            }
            guard reason == nil else { continue }
            if build(output) { built = true }
        }
        if built { requestReevaluation() }
    }

    /// The outputs FineTune lists; remembers each UID's ID for later C9 graces.
    private func listedOutputs() -> [CatchAllOutput] {
        let outputs = env.listedOutputs()
        for output in outputs { knownOutputIDs[output.uid] = output.id }
        return outputs
    }

    /// The device is gone: no longer listed, or Core Audio no longer resolves its UID (the
    /// device list has not caught up yet). Its coverage ends with G, never R (E11, E13).
    private func isAbsent(_ uid: String) -> Bool {
        !listedOutputs().contains { $0.uid == uid } || env.backend.deviceID(forUID: uid) == nil
    }

    private func ineligibility(of output: CatchAllOutput) -> CatchAllPlan.Ineligibility? {
        let id = output.id
        return CatchAllPlan.ineligibility(CatchAllPlan.DeviceFacts(
            mode: env.mode,
            permissionAuthorized: env.permissionAuthorized(),
            sessionActive: env.sessionActive(),
            selfObjectKnown: selfObject.isValid,
            breakerClosed: !breakerOpen,
            listedAndAlive: env.isAlive(id),
            tier: env.tier(id),
            isAggregate: env.isAggregate(id),
            isVirtual: env.isVirtual(id),
            outputStreamCount: env.outputStreamCount(id),
            optedOut: env.excludedDeviceUIDs.contains(output.uid),
            givenUp: givenUp.contains(id)
        ))
    }

    private func noteEligibility(_ uid: String, _ reason: CatchAllPlan.Ineligibility?) {
        guard lastIneligibility[uid] != reason else { return }
        lastIneligibility[uid] = reason
        if let reason {
            logger.notice("Catch-all on \(uid, privacy: .public): not eligible (\(reason.rawValue, privacy: .public))")
        }
    }

    /// Builds held with the list from the current claims, attaches, and releases once that
    /// list covers every claim and has applied (E1). False when nothing was attached.
    private func build(_ output: CatchAllOutput) -> Bool {
        let uid = output.uid
        guard let processes = readProcesses() else {
            // Without a process list the exclusions are unknown; the next reconcile tries again
            logger.error("Catch-all on \(uid, privacy: .public) not built: the process list could not be read")
            emit(.buildFailed(uid: uid, reason: "process list unreadable"))
            return false
        }
        let device = CatchAllDevice(uid: uid, deviceID: output.id)
        devices[uid] = device
        emit(.phase(uid: uid, .building))
        let exclusions = desiredList(for: uid, processes)
        let generation = generations[uid, default: 0]
        let started = env.clock.now

        buildDepth += 1
        let controller: CatchAllTapController
        do {
            controller = try CatchAllTapController.build(
                deviceUID: uid, exclusions: exclusions, gain: env.gain(output.id),
                held: true, observe: env.mode == .observe, backend: env.backend)
        } catch {
            buildDepth -= 1
            // stop() during the wait: nobody wants this catch-all any more, and nothing counts
            guard isStarted, devices[uid] === device else {
                logger.notice("Catch-all on \(uid, privacy: .public) could not be built after it stopped being wanted: \(String(describing: error), privacy: .public)")
                forget(device)
                return false
            }
            // Backoff and failure counting come with the second half of failure handling (§16.6)
            logger.error("Catch-all on \(uid, privacy: .public) could not be built: \(String(describing: error), privacy: .public)")
            emit(.buildFailed(uid: uid, reason: String(describing: error)))
            forget(device)
            return false
        }
        buildDepth -= 1

        // A stop() during the wait: nobody wants this catch-all any more
        guard isStarted, devices[uid] === device, device.phase == .building else {
            logger.notice("Catch-all on \(uid, privacy: .public) built after it stopped being wanted; destroying it")
            Task { await controller.destroy() }
            forget(device)
            return false
        }

        device.controller = controller
        // The tap was created with this list, so it applies without latency
        device.settledGeneration = generation
        device.holds = [.initialList]
        // Gain follows the listed ID, the one the device monitor keeps the level under and
        // reports changes for (E20); the run control matches process Devices against the ID
        // Core Audio resolved for the UID. The level may have changed during the wait.
        if controller.deviceID != output.id {
            logger.notice("Catch-all on \(uid, privacy: .public): Core Audio resolves device \(controller.deviceID), the device list has \(output.id)")
        }
        controller.setGain(env.gain(output.id))
        device.phase = .live
        let ms = (env.clock.now - started) * 1000
        logger.notice("Catch-all on \(uid, privacy: .public) built in \(ms, format: .fixed(precision: 1)) ms, held, excluding \(exclusions, privacy: .public)")
        emit(.phase(uid: uid, .live))
        device.attached = true
        device.attachedAt = env.clock.now
        env.runControl.attach(controller.ioHandle, deviceID: controller.deviceID, excluded: Set(exclusions))
        // Claims that changed during the wait are pushed now; the release follows when applied
        scheduleFlush()
        releaseIfApplied()
        scheduleWatchdog()
        evaluateSettle()
        resumeDeferredTurn()
        return true
    }

    /// Drops a device whose build did not end in a live catch-all; waits on it complete,
    /// since there is no catch-all left to wait for.
    private func forget(_ device: CatchAllDevice) {
        if devices[device.uid] === device { devices[device.uid] = nil }
        checkWaiters()
        resumeDeferredTurn()
    }

    // MARK: Gain

    func refreshGains() {
        for device in devices.values { applyGain(device) }
    }

    func deviceGainChanged(_ deviceID: AudioDeviceID) {
        for device in devices.values where device.deviceID == deviceID { applyGain(device) }
    }

    private func applyGain(_ device: CatchAllDevice) {
        // A retiring catch-all keeps the level at which per-app taps take over
        guard !device.phase.isRetiring, !device.controllers.isEmpty else { return }
        let gain = env.gain(device.deviceID)
        for controller in device.controllers { controller.setGain(gain) }
    }

    // MARK: Processes

    func appsChanged(_ apps: [AudioApp]) {
        self.apps = Dictionary(apps.map { ($0.id, $0.processObjectIDs) }, uniquingKeysWith: +)
        listed = Set(apps.flatMap(\.processObjectIDs))
        env.runControl.setListed(listed)
        let pids = Set(apps.map(\.id))
        decisions = decisions.filter { pids.contains($0.key) }
        processListChanged()
    }

    /// From the run control and `appsChanged`: forgets dead processes and flushes, which
    /// pushes lists without them (a recycled object ID never inherits an exclusion) and ends
    /// with the I1 check. Newly listed apps get their C9 state.
    private func processListChanged() {
        if let list = env.processList() {
            let live = Set(list)
            reports = reports.filter { live.contains($0.key) }
            reportChanged = reportChanged.filter { live.contains($0.key) }
        }
        scheduleFlush()
        evaluateSettle()
    }

    /// A fresh process list and the other users' processes in it; nil when the list could
    /// not be read.
    private func readProcesses() -> ProcessSnapshot? {
        guard let list = env.processList() else { return nil }
        let live = Set(list)
        return ProcessSnapshot(live: live, foreign: env.foreign(live))
    }

    // MARK: Claims

    func changedDevices(owner: ObjectIdentifier, proposed: Claim) -> Set<String> {
        pruneReleasedOwners()
        let before = activeClaims()
        let after = claims.filter { $0.key != owner && $0.value.owner != nil }.map { $0.value.claim } + [proposed]
        let live = env.processList().map(Set.init)
        return Set(liveDevices().map { $0.uid }.filter {
            claimed($0, by: before, live: live) != claimed($0, by: after, live: live)
        })
    }

    func setClaim(_ owner: any CatchAllClaimOwner, _ claim: Claim) -> ApplyTicket? {
        pruneReleasedOwners()
        let id = ObjectIdentifier(owner)
        let before = activeClaims()
        let previous = claims[id]?.claim
        claims[id] = ClaimEntry(owner: owner, claim: claim)
        let ticket = previous == claim ? nil : claimsChanged(from: before)
        return withRetirementTickets(ticket, targets: owner.targets)
    }

    /// Retirement tickets (§16.4): a target in `.retiring(caHeld: false)` joins the ticket with
    /// its current generation, also when no list changed, so the tap's grow wait (its
    /// retirement hold) ends at R3 and not at once.
    private func withRetirementTickets(_ ticket: ApplyTicket?, targets: Set<String>) -> ApplyTicket? {
        let retiring = targets.filter { devices[$0]?.phase == .retiring(caHeld: false) }
        guard !retiring.isEmpty else { return ticket }
        var generations = ticket?.generations ?? [:]
        for uid in retiring where generations[uid] == nil {
            generations[uid] = self.generations[uid, default: 0]
        }
        return ApplyTicket(generations: generations)
    }

    func removeClaim(_ owner: ObjectIdentifier) -> ApplyTicket? {
        pruneReleasedOwners()
        guard claims[owner] != nil else { return nil }
        let before = activeClaims()
        claims[owner] = nil
        return claimsChanged(from: before)
    }

    func prepareInclusion(of processes: [AudioObjectID], on uids: Set<String>) {
        guard !processes.isEmpty, !uids.isEmpty else { return }
        env.runControl.prepareInclusion(Set(processes), on: uids)
    }

    /// Bumps the generation of each catch-all whose list the change alters and schedules the
    /// flush. A live catch-all counts on any change. A building one counts only when
    /// processes leave its list: its tap already excludes them, so their per-app tap must
    /// stay until the list without them has applied (I1). Processes joining a building one
    /// need no wait, since it stays held until its list covers them (E1).
    private func claimsChanged(from before: [Claim]) -> ApplyTicket? {
        let after = activeClaims()
        // Unreadable: compare whole claims, which can only name more devices
        let live = env.processList().map(Set.init)
        var changed: [String: UInt64] = [:]
        for device in devices.values {
            let old = claimed(device.uid, by: before, live: live)
            let new = claimed(device.uid, by: after, live: live)
            let alters = switch device.phase {
            case .live: old != new
            case .building: !old.isSubset(of: new)
            case .dormant, .retiring: false
            }
            guard alters else { continue }
            let generation = generations[device.uid, default: 0] + 1
            generations[device.uid] = generation
            changed[device.uid] = generation
        }
        scheduleFlush()
        return changed.isEmpty ? nil : ApplyTicket(generations: changed)
    }

    private func activeClaims() -> [Claim] {
        claims.values.compactMap { $0.owner == nil ? nil : $0.claim }
    }

    /// A claim whose owner is gone without removing it is dropped (a decorator was released
    /// without `invalidate`).
    private func pruneReleasedOwners() {
        let released = claims.filter { $0.value.owner == nil }.map { $0.key }
        guard !released.isEmpty else { return }
        for id in released { claims[id] = nil }
        logger.fault("Dropped \(released.count) catch-all claim(s) whose owner went away without removing them")
        scheduleFlush()
    }

    /// The processes the claims hold on `uid`: the live ones, or all of them when the process
    /// list could not be read.
    private func claimed(_ uid: String, by claims: [Claim], live: Set<AudioObjectID>?) -> Set<AudioObjectID> {
        var held: Set<AudioObjectID> = []
        for claim in claims where claim.covers(uid) { held.formUnion(claim.processes) }
        guard let live else { return held }
        return held.intersection(live)
    }

    private func desiredList(for uid: String, _ processes: ProcessSnapshot) -> [AudioObjectID] {
        CatchAllPlan.exclusions(deviceUID: uid, selfObject: selfObject, foreign: processes.foreign,
                                claims: activeClaims(), live: processes.live)
    }

    private func liveDevices() -> [CatchAllDevice] {
        devices.values.filter { $0.phase == .live }.sorted { $0.uid < $1.uid }
    }

    // MARK: Flush

    private func scheduleFlush() {
        guard flushAction == nil else { return }
        flushAction = env.clock.schedule(after: 0) { [weak self] in self?.flush() }
    }

    /// Pushes each live catch-all's desired list where it differs from the applied one, then
    /// checks I1 and the waits. Building, dormant and retiring catch-alls are skipped.
    private func flush() {
        flushAction = nil
        pruneReleasedOwners()
        guard var processes = readProcesses() else {
            retryFlushLater()
            return
        }
        if processListUnreadable {
            processListUnreadable = false
            logger.notice("Catch-all flush: the process list is readable again")
        }
        for device in liveDevices() {
            guard let controller = device.controller else { continue }
            var desired = desiredList(for: device.uid, processes)
            if desired == controller.appliedExclusions {
                noteCurrent(device)
                continue
            }
            if push(device, desired, desired: desired) { continue }
            // §4.6 failure, step 1: once more with a fresh process list. The tap may now hold
            // the list it was sent, and a list equal to the applied one cannot be pushed to
            // confirm what it holds, so that case rebuilds too.
            if let fresh = readProcesses() { processes = fresh }
            desired = desiredList(for: device.uid, processes)
            if desired == controller.appliedExclusions || !push(device, desired, desired: desired) {
                pushStillFails(device)
            }
        }
        checkInvariant(processes)
        checkWaiters()
    }

    /// An unreadable process list says nothing about which processes died: every applied
    /// list stays, and the flush runs again shortly.
    private func retryFlushLater() {
        if !processListUnreadable {
            processListUnreadable = true
            logger.error("Catch-all flush postponed: the process list could not be read")
        }
        guard flushAction == nil else { return }
        flushAction = env.clock.schedule(after: Self.processListRetryDelay) { [weak self] in self?.flush() }
    }

    /// A push failed after its retry (§4.6, §16.6 push row): the catch-all is rebuilt with the
    /// desired list (E) and retired (R) if that fails; its waits complete through either. The
    /// I1 check that ends the flush still removes any exclusion left without a claim. While a
    /// rebuilt catch-all waits to take over, pushes go to it, so a failure fails the rebuild: R.
    private func pushStillFails(_ device: CatchAllDevice) {
        if let rebuild = device.rebuild, case .waiting = rebuild.stage {
            guard !rebuild.failed else { return }
            logger.error("Catch-all on \(device.uid, privacy: .public): exclusion push to the rebuilt catch-all failed after its retry; retiring")
            device.rebuild?.failed = true
            queueRetirement(device.uid, Self.retireReason(after: rebuild.reason))
            return
        }
        logger.error("Catch-all on \(device.uid, privacy: .public): exclusion push failed after its retry; rebuilding")
        rebuild(device.uid, reason: .pushFailed)
    }

    /// The applied list already is the current generation's list: it applied with the last push.
    /// Not while the tap's list is unconfirmed, since the tap may hold another one.
    private func noteCurrent(_ device: CatchAllDevice) {
        guard !device.listUnconfirmed else { return }
        let generation = generations[device.uid, default: 0]
        if let last = device.pushes.indices.last {
            device.pushes[last].generation = max(device.pushes[last].generation, generation)
        } else {
            device.settledGeneration = max(device.settledGeneration, generation)
        }
    }

    /// Pushes with read-back and records when. A push of the desired list applies the current
    /// generation; any other list (an I1 repair) applies none newer than the last push. A
    /// failed push leaves the tap's list unconfirmed; one that succeeds confirms it again.
    private func push(_ device: CatchAllDevice, _ list: [AudioObjectID], desired: [AudioObjectID]) -> Bool {
        guard let controller = device.controller else { return false }
        let includes = controller.appliedExclusions.contains { !list.contains($0) }
        guard controller.push(list) else {
            // The controller logged it
            device.listUnconfirmed = true
            emit(.pushFailed(uid: device.uid, excluded: list))
            return false
        }
        device.listUnconfirmed = false
        env.runControl.setExcluded(controller.ioHandle, Set(list))
        let generation = list == desired
            ? generations[device.uid, default: 0]
            : max(device.pushes.last?.generation ?? 0, device.settledGeneration)
        device.pushes.append(PushRecord(generation: generation, time: env.clock.now, callbacks: controller.callbackCount,
                                        includes: includes))
        logger.info("Catch-all on \(device.uid, privacy: .public) excludes \(list, privacy: .public)")
        emit(.pushed(uid: device.uid, excluded: list))
        return true
    }

    /// I1: every applied exclusion is FineTune, another user's process or held by a claim that
    /// covers the device. A violation is logged and repaired at once by pushing without it:
    /// removing an exclusion can double a process, never leave it unprocessed. The repair is
    /// retried once like any push.
    private func checkInvariant(_ processes: ProcessSnapshot) {
        let claims = activeClaims()
        for device in liveDevices() {
            guard let controller = device.controller else { continue }
            var allowed = processes.foreign.union([selfObject])
            for claim in claims where claim.covers(device.uid) { allowed.formUnion(claim.processes) }
            let applied = controller.appliedExclusions
            let offending = applied.filter { !allowed.contains($0) }
            guard !offending.isEmpty else { continue }
            logger.fault("I1 violated on \(device.uid, privacy: .public): \(offending, privacy: .public) excluded without a claim; repairing")
            let repaired = applied.filter { allowed.contains($0) }
            let desired = desiredList(for: device.uid, processes)
            if push(device, repaired, desired: desired) || push(device, repaired, desired: desired) {
                emit(.repaired(uid: device.uid, removed: offending))
            } else {
                pushStillFails(device)
            }
        }
    }

    // MARK: Waits

    func waitApplied(_ ticket: ApplyTicket, _ direction: ApplyDirection) async {
        let now = env.clock.now
        guard !isApplied(ticket, direction, now: now) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            nextWaiterID += 1
            waiters.append(Waiter(id: nextWaiterID, ticket: ticket, direction: direction, registered: now,
                                  deadline: now + watchdogLimit(direction), continuation: continuation))
            scheduleCheck(now: now)
            scheduleWatchdog()
        }
    }

    private func isApplied(_ ticket: ApplyTicket, _ direction: ApplyDirection, now: Double) -> Bool {
        ticket.generations.allSatisfy { isApplied(uid: $0.key, generation: $0.value, direction, now: now) }
    }

    /// The waiter's ticket applied, apart from the devices its watchdog found in force.
    private func isApplied(_ waiter: Waiter, now: Double) -> Bool {
        waiter.ticket.generations.allSatisfy {
            waiter.inForce.contains($0.key) || isApplied(uid: $0.key, generation: $0.value, waiter.direction, now: now)
        }
    }

    private func isApplied(uid: String, generation: UInt64, _ direction: ApplyDirection, now: Double) -> Bool {
        // Without a catch-all there is nothing to wait for
        guard let device = devices[uid] else { return true }
        switch device.phase {
        case .dormant:
            // It plays nothing, and its rebuild starts from the current claims (§16.4)
            return true
        case .retiring(let caHeld):
            // Every wait on it is a retirement hold: it ends at R3, when the output is zeroed
            return caHeld
        case .building, .live:
            break
        }
        // During a rebuild the wait ends once the new catch-all has taken over (E)
        guard device.rebuild?.isWaiting != true, let controller = device.controller else { return false }
        if generation <= device.settledGeneration { return true }
        guard let record = device.pushes.first(where: { $0.generation >= generation }) else { return false }
        switch direction {
        case .grow: return growState(record, controller, now: now).isApplied
        case .shrink: return now - record.time + Self.tolerance >= env.shrinkMargin
        }
    }

    /// Margin G, then two callbacks after the push if the IO runs; a push followed by no
    /// callback found the IO stopped, one followed by a single callback stalls after 500 ms.
    private func growState(_ record: PushRecord, _ controller: CatchAllTapController, now: Double) -> GrowState {
        let elapsed = now - record.time + Self.tolerance
        guard elapsed >= env.growMargin else { return .waiting }
        let advanced = controller.callbackCount &- record.callbacks
        if advanced >= 2 { return .applied }
        if advanced == 0 && elapsed >= Self.idleWindow { return .applied }
        if elapsed >= Self.stallTimeout { return .stalled }
        return .waitingForCallbacks
    }

    /// Settles pushes, lets rebuilt catch-alls take over, resumes the waits that applied,
    /// releases new catch-alls whose list applied and schedules the next check. A takeover or
    /// release that could not read the process list is checked again shortly, since no later
    /// push deadline or callback may come to check it before its watchdog.
    private func checkWaiters() {
        checkAction?.cancel()
        checkAction = nil
        let now = env.clock.now
        for device in devices.values { settle(device, now: now) }
        var unreadable = false
        let rebuilding = devices.values.filter { $0.rebuild?.isWaiting == true }.sorted { $0.uid < $1.uid }
        if !rebuilding.isEmpty {
            let live = env.processList().map(Set.init)
            if live == nil, rebuilding.contains(where: { $0.rebuild?.failed == false }) { unreadable = true }
            for device in rebuilding { completeRebuildIfReady(device, now: now, live: live) }
        }
        var done: [Waiter] = []
        waiters.removeAll { waiter in
            guard isApplied(waiter, now: now) else { return false }
            done.append(waiter)
            return true
        }
        if !releaseIfApplied() { unreadable = true }
        for waiter in done { waiter.continuation.resume() }
        scheduleCheck(now: now, retryRead: unreadable)
        scheduleWatchdog()
    }

    /// Drops the oldest pushes that applied in both directions.
    private func settle(_ device: CatchAllDevice, now: Double) {
        guard let controller = device.controller else { return }
        while let record = device.pushes.first {
            let grow = growState(record, controller, now: now)
            guard grow.isApplied, now - record.time + Self.tolerance >= env.shrinkMargin else { return }
            if grow == .stalled {
                logger.notice("Catch-all on \(device.uid, privacy: .public): push applied without IO callbacks within \(Self.stallTimeout, format: .fixed(precision: 1)) s")
            }
            device.settledGeneration = max(device.settledGeneration, record.generation)
            device.pushes.removeFirst()
        }
    }

    /// `retryRead`: a takeover or release found the process list unreadable and tries again.
    private func scheduleCheck(now: Double, retryRead: Bool = false) {
        checkAction?.cancel()
        checkAction = nil
        guard !waiters.isEmpty || devices.values.contains(where: {
            $0.holds.contains(.initialList) || $0.rebuild?.isWaiting == true
        }) else { return }
        var next: Double? = retryRead ? now + Self.processListRetryDelay : nil
        for device in devices.values {
            guard let controller = device.controller else { continue }
            for record in device.pushes {
                let deadlines = [env.growMargin, env.shrinkMargin, Self.idleWindow, Self.stallTimeout].map { record.time + $0 }
                for deadline in deadlines where deadline > now + Self.tolerance {
                    next = min(next ?? deadline, deadline)
                }
                if growState(record, controller, now: now) == .waitingForCallbacks {
                    next = min(next ?? now + Self.callbackPoll, now + Self.callbackPoll)
                }
            }
            // A rebuilt catch-all takes over after its first callback or 200 ms
            if let rebuild = device.rebuild, !rebuild.failed, case .waiting(let since, let callbacks) = rebuild.stage,
               controller.callbackCount == callbacks, since + Self.firstCallbackWait > now + Self.tolerance {
                next = min(next ?? now + Self.callbackPoll, now + Self.callbackPoll, since + Self.firstCallbackWait)
            }
        }
        // Waits for a list not pushed yet are checked by the flush that pushes it
        guard let next else { return }
        checkAction = env.clock.schedule(after: next - now) { [weak self] in self?.checkWaiters() }
    }

    /// Opens a new catch-all's output once it excludes FineTune and every live process a
    /// claim holds on its device, and every push since the build has applied (E1). Other
    /// exclusions double nothing (dead or foreign processes, or ones the I1 check removes),
    /// so they never keep it held. False when one waits for its release and the process list
    /// could not be read.
    @discardableResult
    private func releaseIfApplied() -> Bool {
        let pending = devices.values.filter { $0.holds.contains(.initialList) && $0.phase == .live && $0.controller != nil }
        guard !pending.isEmpty else { return true }
        guard let list = env.processList() else { return false }
        let live = Set(list)
        let claims = activeClaims()
        let now = env.clock.now
        for device in pending.sorted(by: { $0.uid < $1.uid }) {
            guard let controller = device.controller,
                  listApplied(device, controller, live: live, claims: claims, now: now) else { continue }
            release(device, from: .initialList)
            logger.notice("Catch-all on \(device.uid, privacy: .public) released: its exclusion list applied")
            emit(.released(uid: device.uid))
        }
        return true
    }

    /// The catch-all excludes FineTune and every live process a claim holds on its device, and
    /// every push to it has applied (E1, E).
    private func listApplied(_ device: CatchAllDevice, _ controller: CatchAllTapController,
                             live: Set<AudioObjectID>, claims: [Claim], now: Double) -> Bool {
        let required = claimed(device.uid, by: claims, live: live).union([selfObject])
        return required.isSubset(of: controller.appliedExclusions)
            && device.pushes.allSatisfy { growState($0, controller, now: now).isApplied }
    }

    /// Ends one reason to hold; the output opens when none is left.
    private func release(_ device: CatchAllDevice, from reason: CatchAllHoldReason) {
        device.holds.remove(reason)
        guard device.holds.isEmpty, let controller = device.controller else { return }
        setHeld(controller, false, uid: device.uid)
    }

    /// Zeroes or opens a catch-all's output (one atomic store) and reports it.
    private func setHeld(_ controller: CatchAllTapController, _ held: Bool, uid: String) {
        if held { controller.hold() } else { controller.release() }
        emit(.output(uid: uid, aggregate: controller.ioHandle.aggregateID, held: held))
    }

    // MARK: Retirement (R, §16.3 E13)

    /// Ends coverage of `uid` with promotion to per-app taps (R). R1 stops covering; R2 lets the
    /// engine tap every app the catch-all played, silent ones included; R3 zeroes the
    /// catch-all and completes the retirement tickets in one turn; R4 detaches it within the
    /// bound and destroys it once its queued detach has run, 30 s later when an absent app
    /// was routed to the device. In observe every app is tapped already, so this is G, and so
    /// it is for a device that went away meanwhile. It runs in the coordinator's next turn
    /// (§16.7): R2 spins the main run loop (`activate`), never inside the caller's handler, a
    /// build's wait or another turn.
    func retire(_ uid: String, reason: CatchAllRetireReason) {
        queueRetirement(uid, reason)
    }

    private func queueRetirement(_ uid: String, _ reason: CatchAllRetireReason) {
        guard pendingRetirements[uid] == nil else { return }
        pendingRetirements[uid] = reason
        logger.notice("Catch-all on \(uid, privacy: .public): retirement (\(reason.rawValue, privacy: .public)) runs in the next turn")
        scheduleTurn()
    }

    private func performRetirement(_ uid: String, _ reason: CatchAllRetireReason) {
        // Gone, or retiring already. Never building here: a build's wait queues the request.
        guard let device = devices[uid], device.phase == .live || device.phase == .dormant else { return }
        // The device went away since the request: nothing to promote to (E11)
        if isAbsent(uid) {
            endCoverage(device, reason: "absent")
            return
        }
        guard env.mode == .on else {
            endCoverage(device, reason: "retired in observe (\(reason.rawValue))")
            return
        }
        // R1: covers(D) false, gain frozen, flush and I1 skip it, its waits become retirement
        // holds, and a reconcile leaves it alone until R4 ends. A rebuild waiting to take
        // over never does; R4 ends both catch-alls.
        device.phase = .retiring(caHeld: false)
        device.retiringSince = env.clock.now
        device.rebuild?.failed = true
        device.rebuildAgain = nil
        cancelRebuildDeferral(device)
        pendingRebuilds[uid] = nil
        logger.notice("Catch-all on \(uid, privacy: .public) retiring: \(reason.rawValue, privacy: .public)")
        emit(.retiring(uid: uid, reason))
        emit(.phase(uid: uid, .retiring(caHeld: false)))
        evaluateSettle()
        scheduleWatchdog()
        // R2: the engine taps every app the catch-all played; a tap it creates on the device
        // takes a retirement hold and gets a retirement ticket
        let absentRouted = spinning { onCoverageWillEnd?(uid) ?? false }
        // stop() ended it during the callback (G)
        guard devices[uid] === device else { return }
        // R3, unless the retirement watchdog forced it during the callback
        holdForRetirement(device)
        // R4
        if absentRouted {
            logger.notice("Catch-all on \(uid, privacy: .public): an absent app was routed here; its held catch-all stays \(Self.keepAsideDelay, format: .fixed(precision: 0)) s")
        }
        let entries = takeControllers(device, keepAside: absentRouted, timeoutCounts: true)
        Task {
            await self.detachAndDestroy(entries)
            self.finishRetirement(device, reason)
        }
    }

    /// R3 in one turn: the catch-all's output is zeroed (a hold reason of its own, so no other
    /// reason reopens it), the phase says so, and the retirement tickets complete, so per-app
    /// taps open only after the catch-all closed: at most one buffer of overlap or gap.
    private func holdForRetirement(_ device: CatchAllDevice) {
        guard device.phase == .retiring(caHeld: false) else { return }
        device.holds.insert(.retirement)
        for controller in device.controllers { setHeld(controller, true, uid: device.uid) }
        device.phase = .retiring(caHeld: true)
        logger.notice("Catch-all on \(device.uid, privacy: .public) held for retirement")
        emit(.phase(uid: device.uid, .retiring(caHeld: true)))
        checkWaiters()
    }

    /// R4 ended at the detach: the entry goes, and a later reconcile may build the device again.
    private func finishRetirement(_ device: CatchAllDevice, _ reason: CatchAllRetireReason) {
        // stop() ended it meanwhile (G)
        guard devices[device.uid] === device else { return }
        removeEntry(device)
        logger.notice("Catch-all on \(device.uid, privacy: .public) retired (\(reason.rawValue, privacy: .public))")
        emit(.ended(uid: device.uid, reason: reason.rawValue))
        coverageEnded(device.uid, retired: reason)
        checkWaiters()
    }

    /// Seam for the second half of failure handling: backoff (5/30/120 s), give-up and the
    /// breaker start here. Until then the device has no entry after R4, and the next reconcile
    /// builds it again if it is eligible.
    private func coverageEnded(_ uid: String, retired reason: CatchAllRetireReason) {}

    /// Seam for the second half of failure handling, which counts the failure here toward
    /// backoff and the breaker (§16.6). For now it is only reported. Called only for failures
    /// that count: never for G, a device that is not alive or an unreadable process list.
    private func noteFailure(_ uid: String, _ failure: CatchAllFailure) {
        emit(.failure(uid: uid, failure))
    }

    // MARK: End without promotion (G)

    /// G (design §5 G, §16.4): for an absent device, at `stop()`, and for every retirement in
    /// observe. No callback and nothing counted: each catch-all is held first (one atomic
    /// store; §5 G detaches before the handovers, and a detach can wait behind a blocked run
    /// queue), then the entry goes, so its waits complete (grow waiters release, shrink waiters
    /// invalidate), and each catch-all is detached within the bound and destroyed once its
    /// queued detach has run.
    private func endCoverage(_ device: CatchAllDevice, reason: String) {
        guard devices[device.uid] === device else { return }
        for controller in device.controllers where !controller.renderState.held.load(ordering: .relaxed) {
            setHeld(controller, true, uid: device.uid)
        }
        let entries = takeControllers(device, keepAside: false, timeoutCounts: false)
        removeEntry(device)
        logger.notice("Catch-all on \(device.uid, privacy: .public) ended without promotion (\(reason, privacy: .public))")
        emit(.ended(uid: device.uid, reason: reason))
        checkWaiters()
        evaluateSettle()
        guard !entries.isEmpty else { return }
        Task { await self.detachAndDestroy(entries) }
    }

    /// Drops the device's entry and the work queued for it.
    private func removeEntry(_ device: CatchAllDevice) {
        guard devices[device.uid] === device else { return }
        devices[device.uid] = nil
        pendingRetirements[device.uid] = nil
        pendingRebuilds[device.uid] = nil
        cancelRebuildDeferral(device)
    }

    // MARK: Ending catch-alls

    /// Takes the device's catch-alls out of service: the current one and, while a rebuild
    /// waits to take over, the one it replaces. From here they are only detached and destroyed.
    /// A detach timeout counts for R, not for G.
    private func takeControllers(_ device: CatchAllDevice, keepAside: Bool, timeoutCounts: Bool) -> [EndingCatchAll] {
        var entries: [EndingCatchAll] = []
        if let controller = device.controller {
            let entry = EndingCatchAll(uid: device.uid, controller: controller, attached: device.attached)
            if keepAside { keep(entry) }
            entries.append(entry)
        }
        // One held tap keeps an absent app silent; the replaced one goes at once
        if let rebuild = device.rebuild, let old = rebuild.outgoing {
            entries.append(EndingCatchAll(uid: device.uid, controller: old, attached: rebuild.outgoingAttached))
        }
        for entry in entries { entry.timeoutCounts = timeoutCounts }
        device.controller = nil
        device.attached = false
        device.rebuild = nil
        device.rebuildAgain = nil
        device.pushes = []
        ending.append(contentsOf: entries)
        return entries
    }

    /// Detaches each catch-all within the run control's bound, then destroys it once its
    /// queued detach has run and no keep-aside holds it. A detach that timed out stays queued:
    /// the destroy waits until the run queue confirms it ran, so no start or stop there ever
    /// hits destroyed IDs (§16.7).
    private func detachAndDestroy(_ entries: [EndingCatchAll]) async {
        for entry in entries {
            if entry.attached {
                guard await env.runControl.detach(entry.controller.ioHandle) else {
                    detachTimedOut(entry)
                    continue
                }
            }
            entry.detached = true
            destroyIfDone(entry)
        }
    }

    /// A blocked run queue counts once (and never for G or after `stop()`) until it has run the
    /// detaches that timed out: the old and the new catch-all of a rebuild wait on the same one.
    private func detachTimedOut(_ entry: EndingCatchAll) {
        let aggregate = entry.controller.ioHandle.aggregateID
        logger.fault("Catch-all on \(entry.uid, privacy: .public) (aggregate \(aggregate)): the run queue did not detach it within its bound; destroying it once the queued detach has run")
        stuckDetaches += 1
        if entry.timeoutCounts, isStarted, !queueTimeoutCounted {
            queueTimeoutCounted = true
            noteFailure(entry.uid, .runQueueTimeout)
        }
        env.runControl.afterQueuedWork {
            Task { @MainActor in self.queuedDetachRan(entry) }
        }
        // The replaced catch-all of a rebuild: the new one depends on the same blocked queue (§16.6)
        if let device = entry.device, devices[entry.uid] === device, device.phase == .live {
            queueRetirement(entry.uid, .runQueueTimeout)
        }
    }

    private func queuedDetachRan(_ entry: EndingCatchAll) {
        logger.notice("Catch-all on \(entry.uid, privacy: .public): its queued detach has run")
        stuckDetaches -= 1
        if stuckDetaches == 0 { queueTimeoutCounted = false }
        entry.detached = true
        destroyIfDone(entry)
    }

    private func destroyIfDone(_ entry: EndingCatchAll) {
        guard entry.detached, !entry.keptAside, !entry.destroying else { return }
        entry.destroying = true
        let controller = entry.controller
        Task {
            await controller.destroy()
            self.ending.removeAll { $0 === entry }
        }
    }

    /// R4 with an absent app routed to the device (§16.6, §16.12 item 5): the held, detached
    /// catch-all stays, so its muted tap keeps a returning app silent until the app's tap
    /// exists. Unlisted sounds on the device are silent meanwhile.
    private func keep(_ entry: EndingCatchAll) {
        entry.keptAside = true
        entry.keepTimer = env.clock.schedule(after: Self.keepAsideDelay) { [weak self] in
            self?.keptAsideExpired(entry)
        }
    }

    private func keptAsideExpired(_ entry: EndingCatchAll) {
        entry.keepTimer = nil
        guard entry.keptAside else { return }
        // The check calls the engine, which spins: it runs in the next turn
        pendingKeptChecks.append(entry)
        scheduleTurn()
    }

    /// The keep-aside time ran out. The engine taps the apps that returned meanwhile, silent
    /// ones included, without a hold (the kept catch-all is held); while an absent app is still
    /// routed to the device, the catch-all stays another 30 s. A new catch-all covering the
    /// device plays a returning app itself, and nothing plays to a device that went away, so
    /// then nothing is tapped.
    private func recheckKeptAside(_ entry: EndingCatchAll) {
        guard entry.keptAside else { return }
        if !isLive(entry.uid), !isAbsent(entry.uid), spinning({ onCoverageWillEnd?(entry.uid) ?? false }), entry.keptAside {
            logger.notice("Catch-all on \(entry.uid, privacy: .public): an absent app is still routed here; its held catch-all stays another \(Self.keepAsideDelay, format: .fixed(precision: 0)) s")
            keep(entry)
            return
        }
        entry.keptAside = false
        destroyIfDone(entry)
    }

    // MARK: Rebuild (E, §5 E)

    /// Rebuilds the device's catch-all make before break (E) in the coordinator's next turn,
    /// since the build spins. One rebuild per device at a time: a push failure during one is
    /// served by it (the new catch-all gets the desired list); any other reason runs once more
    /// after it took over, because its catch-all may have been built from stale facts.
    /// `aggregate` names the catch-all a report is about; reports repeat for one aggregate
    /// (§16.12 item 10), so one about an aggregate that is replaced or being replaced is served
    /// already and dropped.
    func rebuild(_ uid: String, reason: CatchAllRebuildReason, aggregate: AudioDeviceID? = nil) {
        guard let device = devices[uid], device.phase == .live else { return }
        if let aggregate {
            // While the new catch-all builds, the one in service is the one being replaced
            let replacing = device.rebuild.map { !$0.isWaiting } ?? false
            guard aggregate == device.controller?.ioHandle.aggregateID, !replacing else { return }
        }
        if device.rebuild != nil {
            if reason != .pushFailed, device.rebuildAgain == nil { device.rebuildAgain = reason }
            return
        }
        // A deferred rebuild tries again on its own
        guard pendingRebuilds[uid] == nil, device.rebuildDeferral == nil else { return }
        pendingRebuilds[uid] = reason
        scheduleTurn()
    }

    /// E steps 1-2: builds the new catch-all held with the list desired from the current
    /// claims and attaches it. The device's generation counter stays, so every older ticket
    /// resolves against the new catch-all; its waits end once it has taken over. If the build
    /// fails: R on the old one; if the device went away: G.
    private func performRebuild(_ uid: String, _ reason: CatchAllRebuildReason) {
        guard isStarted, let device = devices[uid], device.phase == .live, device.rebuild == nil else { return }
        guard !isAbsent(uid), let output = listedOutputs().first(where: { $0.uid == uid }) else {
            // Absent: G, as the next reconcile would do
            endCoverage(device, reason: "absent")
            return
        }
        guard let processes = readProcesses() else {
            deferRebuild(device, reason)
            return
        }
        cancelRebuildDeferral(device)
        logger.notice("Catch-all on \(uid, privacy: .public): rebuilding (\(reason.rawValue, privacy: .public))")
        device.rebuild = RebuildState(reason: reason)
        let exclusions = desiredList(for: uid, processes)
        let generation = generations[uid, default: 0]

        buildDepth += 1
        let controller: CatchAllTapController
        do {
            controller = try CatchAllTapController.build(
                deviceUID: uid, exclusions: exclusions, gain: env.gain(output.id),
                held: true, observe: env.mode == .observe, backend: env.backend)
        } catch {
            buildDepth -= 1
            // stop() during the wait ended the device with G: nothing is retired or counted
            guard isStarted, devices[uid] === device else {
                logger.notice("Catch-all on \(uid, privacy: .public) could not be rebuilt after it stopped being wanted: \(String(describing: error), privacy: .public)")
                return
            }
            rebuildFailed(device, String(describing: error))
            return
        }
        buildDepth -= 1

        // stop(), G or a retirement during the wait: nobody wants the new catch-all
        guard isStarted, devices[uid] === device, device.phase == .live, device.rebuild != nil,
              pendingRetirements[uid] == nil else {
            logger.notice("Catch-all on \(uid, privacy: .public) rebuilt after it stopped being wanted; destroying it")
            if devices[uid] === device { device.rebuild = nil }
            Task { await controller.destroy() }
            return
        }
        let now = env.clock.now
        device.rebuild?.outgoing = device.controller
        device.rebuild?.outgoingAttached = device.attached
        device.rebuild?.stage = .waiting(since: now, callbacks: controller.callbackCount)
        device.controller = controller
        device.listUnconfirmed = false
        device.attached = true
        device.attachedAt = now
        device.initialEscalated = false
        device.deviceID = output.id
        // The tap was created with this generation's list, so it applies without latency; the
        // pushes recorded so far went to the old catch-all
        device.settledGeneration = max(device.settledGeneration, generation)
        device.pushes = []
        device.holds.insert(.rebuild)
        controller.setGain(env.gain(output.id))
        logger.notice("Catch-all on \(uid, privacy: .public) rebuilt, held, excluding \(exclusions, privacy: .public)")
        env.runControl.attach(controller.ioHandle, deviceID: controller.deviceID, excluded: Set(exclusions))
        // Claims that changed during the wait are pushed to the new catch-all
        scheduleFlush()
        checkWaiters()
    }

    /// The new catch-all could not be built: R on the old one (fail open), and the failure
    /// counts while the device is alive (E14). A device that went away meanwhile (the build
    /// found no device for the UID) ends with G and counts nothing (E11).
    private func rebuildFailed(_ device: CatchAllDevice, _ message: String) {
        let reason = device.rebuild?.reason ?? .pushFailed
        device.rebuild = nil
        logger.error("Catch-all on \(device.uid, privacy: .public) could not be rebuilt: \(message, privacy: .public)")
        emit(.buildFailed(uid: device.uid, reason: message))
        guard !isAbsent(device.uid) else {
            endCoverage(device, reason: "absent")
            return
        }
        if env.isAlive(device.deviceID) { noteFailure(device.uid, .buildFailed) }
        performRetirement(device.uid, Self.retireReason(after: reason))
    }

    /// Without a process list the new catch-all's exclusions are unknown. That is no build
    /// failure and counts nothing: the old catch-all keeps serving and the rebuild tries again
    /// shortly. Once the list stayed unreadable for the rebuild watchdog's time: R.
    private func deferRebuild(_ device: CatchAllDevice, _ reason: CatchAllRebuildReason) {
        let now = env.clock.now
        let since = device.rebuildDeferral?.since ?? now
        device.rebuildDeferral?.retry.cancel()
        guard now + Self.tolerance < since + Self.rebuildWatchdog else {
            device.rebuildDeferral = nil
            fire(.rebuild, device.uid, "the process list stayed unreadable; retiring")
            performRetirement(device.uid, Self.retireReason(after: reason))
            return
        }
        if device.rebuildDeferral == nil {
            logger.error("Catch-all on \(device.uid, privacy: .public): rebuild (\(reason.rawValue, privacy: .public)) postponed: the process list could not be read")
        }
        let retry = env.clock.schedule(after: Self.processListRetryDelay) { [weak self, weak device] in
            guard let self, let device, self.devices[device.uid] === device, device.phase == .live,
                  device.rebuildDeferral != nil else { return }
            self.pendingRebuilds[device.uid] = reason
            self.scheduleTurn()
        }
        device.rebuildDeferral = RebuildDeferral(since: since, retry: retry)
    }

    private func cancelRebuildDeferral(_ device: CatchAllDevice) {
        device.rebuildDeferral?.retry.cancel()
        device.rebuildDeferral = nil
    }

    private static func retireReason(after reason: CatchAllRebuildReason) -> CatchAllRetireReason {
        reason == .pushFailed ? .pushFailed : .rebuildFailed
    }

    /// E steps 3-5: once the new catch-all has had its first callback (or 200 ms) and its list
    /// covers every claim and has applied, the old one is held and then the new one opens:
    /// two atomic stores, at most one buffer of silence and never an overlap. The old one is
    /// then detached and destroyed. Waits on the device resolve against the new one from here.
    /// The old one may be the only tap still holding a process whose claim ended while the new
    /// one was built, so the new one must also exclude no live process without a claim, and
    /// each push that removed exclusions must be past margin S.
    private func completeRebuildIfReady(_ device: CatchAllDevice, now: Double, live: Set<AudioObjectID>?) {
        guard device.phase == .live, let rebuild = device.rebuild, !rebuild.failed,
              case .waiting(let since, let callbacks) = rebuild.stage,
              let controller = device.controller, let live else { return }
        let calledBack = controller.callbackCount != callbacks
        let claims = activeClaims()
        guard calledBack || now + Self.tolerance >= since + Self.firstCallbackWait,
              listApplied(device, controller, live: live, claims: claims, now: now),
              device.pushes.allSatisfy({ !$0.includes || now - $0.time + Self.tolerance >= env.shrinkMargin }),
              excludesOnlyClaimed(device.uid, controller.appliedExclusions, live: live,
                                  foreign: env.foreign(live), claims: claims) else { return }
        if let old = rebuild.outgoing { setHeld(old, true, uid: device.uid) }
        device.rebuild = nil
        if device.holds.remove(.initialList) != nil {
            logger.notice("Catch-all on \(device.uid, privacy: .public) released: its exclusion list applied")
            emit(.released(uid: device.uid))
        }
        release(device, from: .rebuild)
        logger.notice("Catch-all on \(device.uid, privacy: .public): the rebuilt catch-all took over (\(rebuild.reason.rawValue, privacy: .public))")
        emit(.rebuilt(uid: device.uid))
        if let old = rebuild.outgoing {
            let entry = EndingCatchAll(uid: device.uid, controller: old, attached: rebuild.outgoingAttached)
            entry.device = device
            entry.timeoutCounts = true
            ending.append(entry)
            Task { await self.detachAndDestroy([entry]) }
        }
        if let again = device.rebuildAgain {
            device.rebuildAgain = nil
            self.rebuild(device.uid, reason: again)
        }
    }

    // MARK: Watchdogs

    /// The grow watchdog, `max(1 s, G + 0.6 s)` (§16.3).
    private var growWatchdog: Double { max(1, env.growMargin + 0.6) }

    private func watchdogLimit(_ direction: ApplyDirection) -> Double {
        direction == .grow ? growWatchdog : Self.shrinkWatchdog
    }

    /// Schedules the coordinator tick at the next watchdog deadline; it runs only while a
    /// wait, a retirement before R3, an initial hold or a rebuild is pending.
    private func scheduleWatchdog() {
        watchdogAction?.cancel()
        watchdogAction = nil
        var deadlines = waiters.map(\.deadline)
        for device in devices.values {
            if device.phase == .retiring(caHeld: false), let since = device.retiringSince {
                deadlines.append(since + Self.retirementWatchdog)
            }
            if let since = rebuildWaitingSince(device) {
                deadlines.append(since + Self.rebuildWatchdog)
            }
            if device.phase == .live, !isRebuilding(device), device.holds.contains(.initialList), !device.initialEscalated {
                deadlines.append(device.attachedAt + growWatchdog)
            }
        }
        guard let next = deadlines.min() else { return }
        watchdogAction = env.clock.schedule(after: max(0, next - env.clock.now)) { [weak self] in
            self?.runWatchdogs()
        }
    }

    /// When a rebuilt catch-all was attached, while it waits to take over on a live device. A
    /// retirement ends it, and the retirement watchdog bounds that.
    private func rebuildWaitingSince(_ device: CatchAllDevice) -> Double? {
        guard device.phase == .live, let rebuild = device.rebuild, !rebuild.failed,
              case .waiting(let since, _) = rebuild.stage else { return nil }
        return since
    }

    /// Ends what is stuck (§16.6 "Hold stuck"): R3 for a retirement, R for a rebuild that did
    /// not take over, the push-failure path for a new catch-all still held, and each wait. A
    /// flush already queued runs first, so no wait is judged on a list about to be pushed, and
    /// then the regular check, so a takeover, release or wait that is ready now wins.
    private func runWatchdogs() {
        watchdogAction = nil
        if let pending = flushAction {
            pending.cancel()
            flush()
        }
        checkWaiters()
        let now = env.clock.now
        func due(_ deadline: Double) -> Bool { now + Self.tolerance >= deadline }
        for device in devices.values.sorted(by: { $0.uid < $1.uid }) {
            if device.phase == .retiring(caHeld: false), let since = device.retiringSince,
               due(since + Self.retirementWatchdog) {
                fire(.retirement, device.uid, "R3 not reached; holding the catch-all and completing its retirement tickets")
                holdForRetirement(device)
            }
            if let since = rebuildWaitingSince(device), let rebuild = device.rebuild, due(since + Self.rebuildWatchdog) {
                fire(.rebuild, device.uid, "the rebuilt catch-all did not take over; retiring")
                device.rebuild?.failed = true
                queueRetirement(device.uid, Self.retireReason(after: rebuild.reason))
            }
            // A rebuild already queued, postponed or running is what this would ask for: it
            // attaches a new catch-all (a new attach time) or ends in R or G
            if device.phase == .live, !isRebuilding(device), device.holds.contains(.initialList),
               !device.initialEscalated, due(device.attachedAt + growWatchdog) {
                fire(.initialList, device.uid, "a new catch-all is still held for its list; rebuilding")
                device.initialEscalated = true
                pushStillFails(device)
            }
        }
        checkStuckWaits(now: now)
        scheduleWatchdog()
    }

    /// A wait past its watchdog stops waiting for each late device whose applied list already
    /// holds the change (grow: the claims' live processes are excluded; shrink: no live
    /// process is excluded without a claim). A missing change goes through the push-failure
    /// path and is never released into doubling. A device that is building, rebuilding or
    /// retiring is left to that, which its own watchdog bounds, without a fault. A device is
    /// not judged yet while the process list is unreadable (up to `unreadableListGrace` past
    /// the watchdog) or while a push the wait depends on is younger than its margin (grow: any
    /// push, G; shrink: one that removed exclusions, S). A wait that still waits is judged
    /// again later, so every wait ends in bounded time.
    private func checkStuckWaits(now: Double) {
        guard waiters.contains(where: { now + Self.tolerance >= $0.deadline }) else { return }
        let live = env.processList().map(Set.init)
        let foreign = live.map { env.foreign($0) } ?? []
        let claims = activeClaims()
        var done: [Waiter] = []
        var stuck: Set<String> = []
        for index in waiters.indices where now + Self.tolerance >= waiters[index].deadline {
            var waiter = waiters[index]
            let limit = watchdogLimit(waiter.direction)
            let lastChance = waiter.registered + limit + Self.unreadableListGrace
            let kind: CatchAllWatchdog = waiter.direction == .grow ? .grow : .shrink
            var next = now + limit
            var waiting = false
            for (uid, generation) in waiter.ticket.generations.sorted(by: { $0.key < $1.key })
            where !waiter.inForce.contains(uid) && !isApplied(uid: uid, generation: generation, waiter.direction, now: now) {
                guard let device = devices[uid], device.phase == .live, !isRebuilding(device),
                      pendingRetirements[uid] == nil, let controller = device.controller else {
                    waiting = true
                    continue
                }
                if live == nil, now + Self.tolerance < lastChance {
                    waiting = true
                    next = min(next, lastChance)
                    continue
                }
                // A read-back shows a push at once, but Core Audio applies it up to G later (G is
                // twice the measured p99 latency, for an exclusion and an inclusion alike). The
                // grow guard waits G past the push. The shrink guard waits S, as the shrink wait
                // itself does: an inclusion judged too early leaves the process in neither tap,
                // unprocessed at full scale, while waiting longer at most lengthens a silent gap
                // (the held per-app tap keeps it muted). Each guard waits a bounded time past the
                // push, so it also holds past the last chance.
                let margin = waiter.direction == .grow ? env.growMargin : env.shrinkMargin
                if let pushed = youngestRelevantPush(device, waiter.direction),
                   now + Self.tolerance < pushed + margin {
                    waiting = true
                    next = min(next, pushed + margin)
                    continue
                }
                if listInForce(device, controller, waiter.direction, live: live, foreign: foreign, claims: claims) {
                    fire(kind, uid, "the list is in force; the wait no longer waits for it")
                    waiter.inForce.insert(uid)
                } else {
                    fire(kind, uid, "the list lacks the change; rebuilding")
                    stuck.insert(uid)
                    waiting = true
                }
            }
            if waiting {
                waiter.deadline = next
                waiters[index] = waiter
            } else {
                done.append(waiter)
            }
        }
        waiters.removeAll { waiter in done.contains { $0.id == waiter.id } }
        for uid in stuck.sorted() {
            if let device = devices[uid] { pushStillFails(device) }
        }
        for waiter in done { waiter.continuation.resume() }
    }

    /// When the newest push that a wait in `direction` depends on returned: any push for grow,
    /// one that removed exclusions for shrink (an inclusion not applied yet leaves the process
    /// in neither tap once its per-app tap goes).
    private func youngestRelevantPush(_ device: CatchAllDevice, _ direction: ApplyDirection) -> Double? {
        switch direction {
        case .grow: device.pushes.last?.time
        case .shrink: device.pushes.last(where: \.includes)?.time
        }
    }

    /// A rebuild of the device is in progress, queued or deferred.
    private func isRebuilding(_ device: CatchAllDevice) -> Bool {
        device.rebuild != nil || device.rebuildDeferral != nil || pendingRebuilds[device.uid] != nil
    }

    /// Whether the device's applied list already holds what a wait in `direction` needs.
    private func listInForce(_ device: CatchAllDevice, _ controller: CatchAllTapController, _ direction: ApplyDirection,
                             live: Set<AudioObjectID>?, foreign: Set<AudioObjectID>, claims: [Claim]) -> Bool {
        switch direction {
        case .grow:
            let applied = Set(controller.appliedExclusions)
            return claimed(device.uid, by: claims, live: live).union([selfObject]).isSubset(of: applied)
        case .shrink:
            return excludesOnlyClaimed(device.uid, controller.appliedExclusions, live: live, foreign: foreign, claims: claims)
        }
    }

    /// Every exclusion of a live process (each one while the list is unreadable) is FineTune,
    /// another user's process or held by a claim that covers the device: none is left
    /// unprocessed.
    private func excludesOnlyClaimed(_ uid: String, _ applied: [AudioObjectID], live: Set<AudioObjectID>?,
                                     foreign: Set<AudioObjectID>, claims: [Claim]) -> Bool {
        var allowed = foreign.union([selfObject])
        for claim in claims where claim.covers(uid) { allowed.formUnion(claim.processes) }
        return applied.allSatisfy { allowed.contains($0) || live?.contains($0) == false }
    }

    private func fire(_ watchdog: CatchAllWatchdog, _ uid: String, _ action: String) {
        logger.fault("Catch-all \(watchdog.rawValue, privacy: .public) watchdog on \(uid, privacy: .public): \(action, privacy: .public)")
        emit(.watchdog(uid: uid, watchdog))
    }

    // MARK: C9 settle state

    /// Devices and IsRunningOutput per process from the run control, posted on change.
    private func handleDeviceReports(_ reports: [AudioObjectID: ProcessDeviceReport]) {
        let now = env.clock.now
        for (process, report) in reports {
            self.reports[process] = report
            reportChanged[process] = now
        }
        evaluateSettle()
    }

    func playsElsewhere(_ processes: [AudioObjectID], target uid: String) -> Bool {
        guard isLive(uid) else { return false }
        return settleState(processes, uid: uid, now: env.clock.now) == .foreign
    }

    func mayPlay(_ processes: [AudioObjectID], on uid: String) -> Bool {
        let target = deviceID(forUID: uid)
        return processes.contains { process in
            guard case .known(let kinds)? = reports[process]?.devices else { return false }
            return kinds.contains { id, kind in id == target || kind != .plain }
        }
    }

    func noteRouting(from previousUIDs: Set<String>, to targetUID: String) {
        let ids = Set(previousUIDs.compactMap { deviceID(forUID: $0) })
        guard !ids.isEmpty else { return }
        graces.append(RoutingGrace(devices: ids, until: env.clock.now + Self.routingGrace))
        evaluateSettle()
    }

    /// The settle rule for a process set and a catch-all device (§16.2, §16.12 item 8): foreign
    /// at once for an aggregate or virtual device that is not D-like; after 500 ms since the
    /// last change when nothing lists a D-like device and something lists another device, an
    /// unresolvable ID, or an empty or unknown list while it runs output.
    private func settleState(_ processes: some Sequence<AudioObjectID>, uid: String, now: Double) -> SettleState {
        var dLike = Set(graces.filter { $0.until > now + Self.tolerance }.flatMap(\.devices))
        if let id = deviceID(forUID: uid) { dLike.insert(id) }
        var listsDLike = false
        var nonPlainElsewhere = false
        var otherDevice = false
        var lastChange = -Double.infinity
        for process in processes {
            guard let report = reports[process] else { continue }
            lastChange = max(lastChange, reportChanged[process] ?? now)
            switch report.devices {
            case .unknown:
                if report.runningOutput { otherDevice = true }
            case .known(let kinds):
                if kinds.isEmpty, report.runningOutput { otherDevice = true }
                for (id, kind) in kinds {
                    if dLike.contains(id) {
                        listsDLike = true
                    } else if kind == .aggregateOrVirtual {
                        nonPlainElsewhere = true
                    } else {
                        otherDevice = true
                    }
                }
            }
        }
        if nonPlainElsewhere { return .foreign }
        guard !listsDLike, otherDevice else { return .covered }
        let settlesAt = lastChange + Self.settleDelay
        return now + Self.tolerance >= settlesAt ? .foreign : .settling(until: settlesAt)
    }

    /// Evaluates each listed app's process set, the set the gate asks about, for every live
    /// or dormant catch-all; asks for a re-evaluation of the gate when one became foreign,
    /// and schedules the next settle or grace end. Unlisted processes (FineTune, daemons,
    /// other users) are never asked about, so they trigger nothing.
    private func evaluateSettle() {
        settleAction?.cancel()
        settleAction = nil
        guard isStarted else { return }
        let now = env.clock.now
        graces.removeAll { $0.until <= now + Self.tolerance }
        var next = graces.map(\.until).min()
        var becameForeign = false
        let pids = Set(apps.keys)
        for uid in elsewhere.keys where !isLive(uid) { elsewhere[uid] = nil }
        for uid in devices.keys.sorted() where isLive(uid) {
            var flagged = (elsewhere[uid] ?? []).intersection(pids)
            for (pid, processes) in apps.sorted(by: { $0.key < $1.key }) {
                switch settleState(processes, uid: uid, now: now) {
                case .foreign:
                    guard flagged.insert(pid).inserted else { continue }
                    becameForeign = true
                    logger.notice("App \(pid) plays elsewhere than \(uid, privacy: .public)")
                    emit(.playsElsewhere(pid: pid, uid: uid))
                case .settling(let until):
                    flagged.remove(pid)
                    next = min(next ?? until, until)
                case .covered:
                    flagged.remove(pid)
                }
            }
            elsewhere[uid] = flagged
        }
        if let next {
            settleAction = env.clock.schedule(after: max(0, next - now)) { [weak self] in self?.evaluateSettle() }
        }
        if becameForeign { requestReevaluation() }
    }

    /// The listed ID of `uid`, else the last one seen for it (a device that just
    /// disappeared), else its catch-all's.
    private func deviceID(forUID uid: String) -> AudioDeviceID? {
        listedOutputs().first { $0.uid == uid }?.id ?? knownOutputIDs[uid] ?? devices[uid]?.deviceID
    }

    // MARK: Decisions

    func noteDecision(_ app: AudioApp, target uid: String, _ decision: TapDecision) {
        let noted = NotedDecision(uid: uid, decision: decision)
        guard decisions[app.id] != noted else { return }
        decisions[app.id] = noted
        let text = switch decision {
        case .coveredByCatchAll: affectsAudio ? "covered by the catch-all" : "would cover"
        case .tap(let reasons): "tap (\(reasons.map(\.rawValue).sorted().joined(separator: ", ")))"
        }
        logger.notice("\(app.name, privacy: .public) (pid \(app.id)) on \(uid, privacy: .public): \(text, privacy: .public)")
        emit(.decision(pid: app.id, uid: uid, decision))
    }

    private func emit(_ event: CatchAllEvent) {
        onEvent?(event)
    }
}

// MARK: - Coordinator state

/// One device's catch-all.
@MainActor
private final class CatchAllDevice {
    let uid: String
    /// The listed ID (the device monitor's): gain is read and followed by it.
    var deviceID: AudioDeviceID
    var phase: CatchAllPhase = .building
    /// The catch-all in service; during a rebuild the new one from its attach on.
    var controller: CatchAllTapController?
    /// `controller` is attached to the run control (a dormant one is not).
    var attached = false
    /// When `controller` was attached; the initial-list watchdog counts from here.
    var attachedAt: Double = 0
    /// Why its output is held; it opens when this is empty.
    var holds: Set<CatchAllHoldReason> = []
    /// Every generation up to this one applied in both directions.
    var settledGeneration: UInt64 = 0
    /// Pushes to `controller` that have not applied in both directions, oldest first.
    var pushes: [PushRecord] = []
    /// A push to `controller` failed. A read-back can fail after the set took effect, so its
    /// tap may hold the list it was sent or `appliedExclusions`. Until a push to it succeeds or
    /// a rebuild replaces it, no generation is noted as current on the recorded list, so a wait
    /// on a later claim change ends only with a confirmed push, the takeover, R3 or G. A
    /// failure that its retry does not clear rebuilds or retires.
    var listUnconfirmed = false
    /// A make-before-break rebuild in progress (E).
    var rebuild: RebuildState?
    /// A rebuild asked for during `rebuild`; it runs once that one took over.
    var rebuildAgain: CatchAllRebuildReason?
    /// A rebuild that could not read the process list and tries again shortly.
    var rebuildDeferral: RebuildDeferral?
    /// The initial-list watchdog fired; a rebuild's attach resets it.
    var initialEscalated = false
    /// When R1 began.
    var retiringSince: Double?

    init(uid: String, deviceID: AudioDeviceID) {
        self.uid = uid
        self.deviceID = deviceID
    }

    /// The catch-all in service and, while a rebuild waits to take over, the one it replaces.
    var controllers: [CatchAllTapController] {
        [controller, rebuild?.outgoing].compactMap { $0 }
    }
}

/// Why a catch-all's output is held, so ending one reason never opens an output another still
/// holds. The second half of failure handling adds the format hold (E15).
nonisolated private enum CatchAllHoldReason: Hashable {
    /// A new catch-all until its list covers every claim and has applied (E1).
    case initialList
    /// A rebuilt catch-all until it takes over from the one it replaces (E).
    case rebuild
    /// From R3 on; nothing ends it.
    case retirement
}

/// A make-before-break rebuild (E). From its attach on, the new catch-all is the device's
/// `controller`; the one it replaces stays here until it is held and detached.
private struct RebuildState {
    enum Stage {
        /// The new catch-all's build is waiting (it spins); the old one still serves.
        case building
        /// Attached held: takes over after its first callback (or 200 ms) and its list applied.
        case waiting(since: Double, callbacks: UInt64)
    }

    let reason: CatchAllRebuildReason
    var stage: Stage = .building
    var outgoing: CatchAllTapController?
    var outgoingAttached = false
    /// The new catch-all cannot take over (a push to it failed, or its watchdog fired): R follows.
    var failed = false

    var isWaiting: Bool {
        if case .waiting = stage { return true }
        return false
    }
}

/// A rebuild postponed because the process list could not be read.
private struct RebuildDeferral {
    /// When the first attempt found the list unreadable; R follows the rebuild watchdog's time later.
    let since: Double
    /// The next attempt.
    let retry: CatchAllScheduledAction
}

/// A catch-all whose coverage ended (R4, G, or the replaced one of a rebuild), until it is
/// destroyed: once its queued detach has run and no keep-aside holds it.
@MainActor
private final class EndingCatchAll {
    let uid: String
    let controller: CatchAllTapController
    /// Attached when its coverage ended, so the run control must detach it first.
    let attached: Bool
    /// For the replaced catch-all of a rebuild: the device that still serves the UID.
    weak var device: CatchAllDevice?
    /// A detach timeout counts toward backoff and the breaker (R and E; not G).
    var timeoutCounts = false
    /// The run queue has detached it (or it was never attached).
    var detached = false
    /// Held for an absent app (R4); destroyed when this ends.
    var keptAside = false
    var keepTimer: CatchAllScheduledAction?
    var destroying = false

    init(uid: String, controller: CatchAllTapController, attached: Bool) {
        self.uid = uid
        self.controller = controller
        self.attached = attached
    }
}

nonisolated private struct ProcessSnapshot {
    var live: Set<AudioObjectID>
    var foreign: Set<AudioObjectID>
}

nonisolated private struct PushRecord {
    /// The push applies every generation up to this one.
    var generation: UInt64
    var time: Double
    /// The catch-all's callback count when the push returned.
    var callbacks: UInt64
    /// The push removed exclusions: their processes are captured only after margin S.
    var includes: Bool
}

nonisolated private enum GrowState: Equatable {
    case waiting
    case waitingForCallbacks
    case applied
    /// Applied after the stall timeout without a second callback (logged).
    case stalled

    var isApplied: Bool { self == .applied || self == .stalled }
}

private struct ClaimEntry {
    weak var owner: (any CatchAllClaimOwner)?
    var claim: Claim
}

private struct Waiter {
    let id: Int
    let ticket: ApplyTicket
    let direction: ApplyDirection
    /// When the wait began.
    let registered: Double
    /// When its watchdog judges it next: first after the watchdog's time, then again while
    /// it waits for a rebuild, a retirement or a build, or for a judgeable list.
    var deadline: Double
    /// Devices its watchdog found with the change in force: the wait no longer waits for them.
    var inForce: Set<String> = []
    let continuation: CheckedContinuation<Void, Never>
}

nonisolated private struct RoutingGrace {
    var devices: Set<AudioDeviceID>
    var until: Double
}

nonisolated private enum SettleState: Equatable {
    case covered
    case settling(until: Double)
    case foreign
}

nonisolated private struct NotedDecision: Equatable {
    var uid: String
    var decision: TapDecision
}

// MARK: - Live bindings

extension CatchAllCoordinator {
    /// The coordinator on Core Audio. Only the engine calls this, and only in mode observe or
    /// on; unit tests inject fakes through `init(environment:)`.
    static func live(
        settings: CatchAllSettings = CatchAllSettings(),
        deviceMonitor: any AudioDeviceProviding,
        deviceVolumeMonitor: any DeviceVolumeProviding,
        permissionAuthorized: @escaping @MainActor () -> Bool
    ) -> CatchAllCoordinator {
        let backend = CoreAudioCatchAllBackend()
        var logic = CatchAllRunLogic()
        logic.ioOnlyCap = settings.ioOnlyCap
        let runControl = CatchAllRunControl(source: HALProcessOutputActivitySource(), backend: backend,
                                            logic: logic, observeDevices: true)
        let catalog = ProcessCatalog()
        return CatchAllCoordinator(environment: CatchAllEnvironment(
            mode: settings.mode,
            excludedDeviceUIDs: settings.excludedDeviceUIDs,
            growMargin: settings.growMargin,
            shrinkMargin: settings.shrinkMargin,
            backend: backend,
            runControl: runControl,
            clock: SystemCatchAllClock(),
            processList: { try? AudioObjectID.readProcessList() },
            selfObject: { ProcessIdentity.processObject(forPID: getpid()) },
            foreign: { live in
                catalog.prune(keeping: live)
                return catalog.foreign(among: live)
            },
            isRunningOutput: { ProcessIdentity.isRunningOutput($0) },
            listedOutputs: { deviceMonitor.outputDevices.map { CatchAllOutput(uid: $0.uid, id: $0.id) } },
            isAlive: { $0.isDeviceAlive() },
            tier: { deviceVolumeMonitor.outputVolumeBackend(for: $0) },
            isAggregate: { $0.isAggregateDevice() },
            isVirtual: { $0.isVirtualDevice() },
            outputStreamCount: { $0.streamCount(scope: kAudioObjectPropertyScopeOutput) },
            gain: { deviceVolumeMonitor.outputProcessingGain(for: $0) },
            permissionAuthorized: permissionAuthorized,
            // Session observers are deferred until a second account uses the Mac (design §16.10)
            sessionActive: { true },
            observeAlive: { DeviceAliveObservation(device: $0, handler: $1) },
            tapExists: { CatchAllTapLookup.exists($0) }
        ))
    }
}

/// Main-actor timers on the system's monotonic clock.
@MainActor
final class SystemCatchAllClock: CatchAllClock {
    var now: Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    func schedule(after delay: Double, _ action: @escaping @MainActor @Sendable () -> Void) -> CatchAllScheduledAction {
        let task = Task { @MainActor in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            action()
        }
        return CatchAllScheduledAction { task.cancel() }
    }
}

/// Observes a device's IsAlive on the main queue until released.
nonisolated final class DeviceAliveObservation {
    private static let address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private let device: AudioDeviceID
    private let block: AudioObjectPropertyListenerBlock
    private let registered: Bool

    init(device: AudioDeviceID, handler: @escaping @MainActor @Sendable () -> Void) {
        self.device = device
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { handler() }
        }
        self.block = block
        var address = Self.address
        registered = AudioObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr
    }

    deinit {
        guard registered else { return }
        var address = Self.address
        // The device may already be gone; nothing to undo then
        _ = AudioObjectRemovePropertyListenerBlock(device, &address, .main, block)
    }
}

/// Whether a tap UID resolves in the running Core Audio daemon.
nonisolated enum CatchAllTapLookup {
    static func exists(_ uid: UUID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToTap,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = uid.uuidString as CFString
        var tap = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafeMutablePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &tap)
        }
        return err == noErr && tap != kAudioObjectUnknown
    }
}
