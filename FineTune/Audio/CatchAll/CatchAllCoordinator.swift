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
    /// A counted failure (§16.6): an IO failure counts toward give-up for its device ID, a build
    /// failure and a blocked run queue toward the breaker. Not reported for G, for a device
    /// that is not alive (also 1 s after an IO or build failure, or found so during the 1 s
    /// after a build failure), or for an unreadable process list.
    case failure(uid: String, CatchAllFailure)
    /// The next build on the device waits this many seconds (E14).
    case backoff(uid: String, seconds: Double)
    /// The device ID is given up for the session: three counted IO failures within 10 min,
    /// which count once toward the breaker, or a failure after the last backoff step.
    case givenUp(uid: String, deviceID: AudioDeviceID)
    /// Three failures toward the breaker within 10 min (failed builds, blocked run queues,
    /// give-ups) opened it (also logged at `.fault`): no catch-all for the rest of the session.
    case breakerOpened
}

/// Why coverage of a device ends with promotion (R, design §16.3 E13).
nonisolated enum CatchAllRetireReason: String, Sendable, Equatable {
    /// A push failed after its retry, and the rebuild with the desired list failed too (§4.6).
    case pushFailed
    /// Three counted IO failures for one device ID within 10 min.
    case givenUp
    /// The circuit breaker opened.
    case breaker
    /// The run queue did not answer within its 1 s bound.
    case runQueueTimeout
    /// A reconcile found that the device no longer has software volume.
    case tierChanged
    /// A rebuild for another reason (E12, E15, an IO failure) failed, and the device was still
    /// listed under the same ID and usable 1 s later, without being found otherwise meanwhile.
    case rebuildFailed
    /// The listening session's injected retirement.
    case injected
}

/// Why a catch-all is rebuilt make before break (E, design §5 E). The format hooks (E15) add
/// the callers of `formatChanged` later.
nonisolated enum CatchAllRebuildReason: String, Sendable, Equatable {
    /// A push failed after its retry, or a list was still missing at its watchdog (§4.6).
    case pushFailed
    case formatChanged
    /// The run control reported dead IO or a failed start on an alive device (§16.6).
    case ioFailed
    /// The device is listed under a new ID, or is alive again after it was dormant (E12).
    case deviceChanged
}

/// A failure that counts (design §16.6): an IO failure toward give-up, the others toward the
/// breaker.
nonisolated enum CatchAllFailure: String, Sendable, Equatable {
    /// A first build or a rebuild could not build its catch-all on an alive device; 1 s after
    /// the failure and only if the device is then still listed under the same ID and alive,
    /// and was not found otherwise meanwhile.
    case buildFailed
    /// The run control reported dead IO or a failed start on an alive device; once per
    /// aggregate, 1 s after the report and only if the device is then still listed under the
    /// same ID and alive. Counts toward give-up only.
    case ioFailed
    /// The run queue did not answer a detach within its bound; once until it has run the
    /// detaches that timed out. Not for G, a device that went dormant, nor a rebuilt catch-all
    /// that failed before it took over.
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
/// fails after its retry rebuilds make before break (E, `rebuild`). A failed rebuild leaves the
/// old catch-all serving for 1 s and then retires it if the device is still alive under its
/// ID; otherwise the E12 check decides. Watchdogs bound every wait, hold and rebuild; a
/// catch-all is destroyed only after the run queue has detached it.
///
/// A device that is listed but not alive keeps its catch-all dormant (E12): held, detached and
/// still covering, until IsAlive or a 2 s check finds it alive again and it is rebuilt; a new
/// listed ID that is alive rebuilds at once. Dead IO reported by the run control rebuilds.
/// Failures on alive devices count (§16.6), an IO or build failure only if the device is still
/// alive under its ID 1 s later (a build failure only if it stayed so): three IO failures
/// within 10 min give the device ID up, failed builds and some retirements back off
/// 5/30/120 s, and three failed builds, blocked run queues or give-ups within 10 min open the
/// breaker, which retires every catch-all for the rest of the session.
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
    /// A flush that could not read the process list tries again after this, and so does a
    /// first build for the rebuild watchdog's time.
    static let processListRetryDelay: Double = 0.1
    /// Then a first build that could not read the process list tries again after this.
    static let unreadableBuildRetry: Double = 2
    /// E: a rebuilt catch-all takes over after its first IO callback or after this.
    static let firstCallbackWait: Double = 0.2
    /// R4: a held catch-all kept aside for an absent app is destroyed after this, and again
    /// after this while an absent app is still routed to its device (§16.12 item 5).
    static let keepAsideDelay: Double = 30
    /// Watchdogs (§16.3); the grow watchdog is `max(1 s, G + 0.6 s)`.
    static let shrinkWatchdog: Double = 2
    static let retirementWatchdog: Double = 2
    static let rebuildWatchdog: Double = 2
    /// E12: while a catch-all is dormant, its listed ID and alive state are read this often.
    static let dormantCheckInterval: Double = 2
    /// E14: the next build waits this long after successive failures; one more gives up.
    static let backoffDelays: [Double] = [5, 30, 120]
    /// The backoff starts over once a catch-all on the device has stayed live this long.
    static let backoffResetTime: Double = 600
    /// Give-up: this many counted IO failures for one device ID within the window. The give-up
    /// counts once toward the breaker. The window is the breaker's, so IO failures that never
    /// reach the breaker still fail open at the rate that opened it before they stopped
    /// counting toward it.
    static let giveUpCount = 3
    static let giveUpWindow: Double = 600
    /// A failure on a device that reads alive counts, a failed build backs off, and a failed
    /// rebuild retires, only if the device is still listed under the same ID and alive this long
    /// after it (and, for a build, was not found otherwise meanwhile): on an HDMI link drop or a
    /// display sleep the IO may stop, and a build fail, before IsAlive turns false.
    static let failureSettle: Double = 1
    /// Breaker: this many failed builds, blocked run queues and give-ups within the window. IO
    /// failures count toward give-up only.
    static let breakerCount = 3
    static let breakerWindow: Double = 600
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
    /// Opened by three counted failures within 10 min (design §16.6); open for the session.
    private(set) var breakerOpen = false
    /// Device IDs given up for the session (repeated IO failures, or a failure after the last
    /// backoff step). A new ID under the same UID gets a new chance.
    private(set) var givenUp: Set<AudioDeviceID> = []

    // Failure counting (§16.6, E14)
    /// When each failure toward the breaker happened.
    private var failureTimes: [Double] = []
    /// When each counted IO failure happened, per device ID, for give-up.
    private var ioFailureTimes: [AudioDeviceID: [Double]] = [:]
    /// Aggregates whose IO failure was reported (reports repeat), each a candidate for one
    /// count; forgotten when destroyed, since aggregate IDs are reused.
    private var countedAggregates: Set<AudioDeviceID> = []
    /// The checks that count a reported IO failure once it settled.
    private var ioFailureChecks: [Int: CatchAllScheduledAction] = [:]
    private var nextIOFailureCheck = 0
    /// Per UID, a failed build, rebuild or rebuilt catch-all whose count, backoff and R wait
    /// until it settled (`failureSettle`); nothing is built or rebuilt there meanwhile.
    private var failureSettles: [String: FailureSettle] = [:]
    private var backoffs: [String: Backoff] = [:]
    /// A first build found the process list unreadable: the reconcile runs again.
    private var buildRetry: CatchAllScheduledAction?
    /// When the first build of the current streak found the list unreadable.
    private var buildListUnreadableSince: Double?
    /// Devices whose build found the list unreadable in the current streak (logged once each).
    private var unreadableAtBuild: Set<String> = []
    /// A build in the running reconcile found the list unreadable, so the streak goes on.
    private var buildFoundListUnreadable = false

    // E12
    /// IsAlive observed per UID: for a dormant catch-all, and for a listed device without one
    /// that is not alive and not ruled out otherwise (`updateAliveWatch`).
    private var aliveWatches: [String: AliveWatch] = [:]
    /// Dormant catch-alls whose detach has not run on the run queue yet; destroyed only after.
    private var dormantDetaches: Set<ObjectIdentifier> = []
    private var dormantCheckAction: CatchAllScheduledAction?

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
    /// Detaches that timed out and have not run on the run queue yet (§16.6). It is one serial
    /// queue: while any waits, no catch-all is built or rebuilt on any device, and the blocked
    /// queue counts once until it has run them.
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
        // Called on the run queue. Hopped with DispatchQueue.main.async, so it stays FIFO with
        // the onServiceRestarted hop, which must use the main queue too; the run control's
        // report tasks (onDevicesChanged, onProcessListChanged) are not ordered against it.
        env.runControl.onRebuild = { [weak self] uid, aggregate, reason in
            guard let self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.reportIOFailure(uid, aggregate: aggregate, reason) }
            }
        }
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
    /// the run control again. Counted failures, backoff steps, given-up IDs and the breaker
    /// stay for the session; a running backoff ends here, and a failure that has not settled
    /// is not counted and backs nothing off.
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
        for action in [turn, flushAction, checkAction, settleAction, watchdogAction, dormantCheckAction] { action?.cancel() }
        turn = nil
        flushAction = nil
        checkAction = nil
        settleAction = nil
        watchdogAction = nil
        dormantCheckAction = nil
        aliveWatches.removeAll()
        for uid in backoffs.keys {
            backoffs[uid]?.timer?.cancel()
            backoffs[uid]?.timer = nil
        }
        for check in ioFailureChecks.values { check.cancel() }
        ioFailureChecks.removeAll()
        cancelFailureSettles()
        endUnreadableBuildStreak()
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

    /// The device monitor read its list again. The reconcile it schedules runs the E12 checks
    /// (a new ID, a device that is not alive, one alive again) and moves IsAlive observations
    /// to new IDs; nothing is built inside the device monitor's handler.
    func deviceListRefreshed() {
        _ = listedOutputs()
        reconcile()
    }

    // Format changes (E15) come in a later commit; until then they leave the catch-all as is.
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

    /// Ends coverage of devices that are no longer listed (G), runs the E12 check for every
    /// other catch-all and retires a live one whose device, alive under its ID, no longer has
    /// software volume (R, in the next turn: `start()` runs this in the engine's call), and
    /// builds a catch-all for every eligible listed device that has none, unless its backoff
    /// runs, its last failure has not settled or a detach waits behind a blocked run queue. A
    /// device without one that is not alive is observed until it is (E14). A retiring device
    /// is left alone until its R4 ends. A pass in which no build found the process list
    /// unreadable ends such a streak.
    private func runReconcile() {
        guard isStarted else { return }
        buildFoundListUnreadable = false
        defer {
            if !buildFoundListUnreadable { endUnreadableBuildStreak() }
        }
        if !selfObject.isValid { selfObject = env.selfObject() }
        let outputs = listedOutputs().sorted(by: { $0.uid < $1.uid })
        let listedUIDs = Set(outputs.map(\.uid))
        for device in devices.values.sorted(by: { $0.uid < $1.uid }) where !listedUIDs.contains(device.uid) {
            guard device.phase == .live || device.phase == .dormant else { continue }
            endCoverage(device, reason: "absent")
        }
        aliveWatches = aliveWatches.filter { listedUIDs.contains($0.key) }
        var built = false
        for output in outputs {
            // A stop() during an earlier build's wait or retirement ends the pass
            guard isStarted else { break }
            let reason = ineligibility(of: output)
            noteEligibility(output.uid, reason)
            if let device = devices[output.uid] {
                // E12 first: the tier of a device that died or changed its ID is not judged, since
                // it may read differently until the device is alive under its ID again
                if checkDevice(device) == .unchanged, device.phase == .live, env.tier(output.id) != .software {
                    queueRetirement(output.uid, .tierChanged)
                }
                continue
            }
            updateAliveWatch(output, reason)
            guard reason == nil, mayBuild(output.uid) else { continue }
            if build(output) { built = true }
        }
        if built { requestReevaluation() }
    }

    /// No backoff runs for the device, its last failure has settled (whether it backs off is not
    /// known before), and no detach waits behind a blocked run queue: it is one serial queue,
    /// so a new catch-all on any device would attach behind it and stay silent.
    private func mayBuild(_ uid: String) -> Bool {
        if backoffs[uid]?.timer != nil {
            logger.info("Catch-all on \(uid, privacy: .public) not built: its backoff runs")
            return false
        }
        if failureSettles[uid] != nil {
            logger.info("Catch-all on \(uid, privacy: .public) not built: its last failure has not settled")
            return false
        }
        if stuckDetaches > 0 {
            logger.info("Catch-all on \(uid, privacy: .public) not built: the run queue has not run a detach that timed out")
            return false
        }
        return true
    }

    /// The outputs FineTune lists; remembers each UID's ID for later C9 graces.
    private func listedOutputs() -> [CatchAllOutput] {
        let outputs = env.listedOutputs()
        for output in outputs { knownOutputIDs[output.uid] = output.id }
        return outputs
    }

    /// The device went away during R or a rebuild: no longer listed, or Core Audio no longer
    /// resolves its UID (the device list has not caught up yet). Its coverage ends with G,
    /// never R (E11, E13). Outside R and a rebuild, the E12 check keeps a listed device whose
    /// UID does not resolve dormant instead.
    private func isAbsent(_ uid: String) -> Bool {
        !listedOutputs().contains { $0.uid == uid } || env.backend.deviceID(forUID: uid) == nil
    }

    /// Alive under its listed ID, and Core Audio resolves its UID.
    private func deviceUsable(_ uid: String, _ id: AudioDeviceID) -> Bool {
        env.isAlive(id) && env.backend.deviceID(forUID: uid) != nil
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
    /// list covers every claim and has applied (E1). False when nothing was attached. A build
    /// that fails on an alive device counts and backs off (E14) once that settled; one on a
    /// device that is not alive counts nothing, and the device is built once IsAlive reports it
    /// alive. A device that died during the wait goes dormant once its catch-all is attached
    /// (E12).
    private func build(_ output: CatchAllOutput) -> Bool {
        let uid = output.uid
        guard let processes = readProcesses() else {
            // Without a process list the exclusions are unknown, and counts nothing
            buildFoundListUnreadable = true
            if unreadableAtBuild.insert(uid).inserted {
                logger.error("Catch-all on \(uid, privacy: .public) not built: the process list could not be read")
                emit(.buildFailed(uid: uid, reason: "process list unreadable"))
            }
            retryBuildLater()
            return false
        }
        unreadableAtBuild.removeAll()
        buildListUnreadableSince = nil
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
            logger.error("Catch-all on \(uid, privacy: .public) could not be built: \(String(describing: error), privacy: .public)")
            emit(.buildFailed(uid: uid, reason: String(describing: error)))
            forget(device)
            if deviceUsable(uid, output.id) {
                // A device that is leaving may fail the build before IsAlive turns false
                settleFailure(uid, deviceID: output.id, countsBuild: true, cause: "its build failed")
            } else {
                logger.notice("Catch-all on \(uid, privacy: .public): the device is not alive; nothing counted, built once it is")
                observeAlive(uid, output.id)
            }
            return false
        }
        buildDepth -= 1

        // A stop() during the wait, or the breaker opened: nobody wants this catch-all any more
        guard isStarted, !breakerOpen, devices[uid] === device, device.phase == .building else {
            logger.notice("Catch-all on \(uid, privacy: .public) built after it stopped being wanted; destroying it")
            Task { await controller.destroy() }
            forget(device)
            return false
        }
        // A detach timed out during the wait: this one would attach behind it on the same queue
        // and stay silent (§16.6). The queue's catch-up reconciles.
        guard stuckDetaches == 0 else {
            logger.error("Catch-all on \(uid, privacy: .public) built while the run queue has not run a detach that timed out; destroying it")
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
        stopObservingAlive(uid)
        noteLive(device)
        let ms = (env.clock.now - started) * 1000
        logger.notice("Catch-all on \(uid, privacy: .public) built in \(ms, format: .fixed(precision: 1)) ms, held, excluding \(exclusions, privacy: .public)")
        emit(.phase(uid: uid, .live))
        device.attached = true
        device.attachedAt = env.clock.now
        env.runControl.attach(controller.ioHandle, deviceID: controller.deviceID, excluded: Set(exclusions))
        // No listener reports a device that died or changed its ID during the wait: E12 now
        checkDevice(device)
        // Claims that changed during the wait are pushed now; the release follows when applied
        scheduleFlush()
        releaseIfApplied()
        scheduleWatchdog()
        evaluateSettle()
        resumeDeferredTurn()
        return true
    }

    /// A first build could not read the process list. The device may have nothing else that
    /// reconciles it (its IsAlive observation ended when the reconcile found it alive), so the
    /// reconcile runs again: 100 ms apart for the rebuild watchdog's time, then every 2 s while
    /// the list stays unreadable.
    private func retryBuildLater() {
        guard buildRetry == nil else { return }
        let now = env.clock.now
        let since = buildListUnreadableSince ?? now
        buildListUnreadableSince = since
        let delay = now + Self.tolerance < since + Self.rebuildWatchdog
            ? Self.processListRetryDelay : Self.unreadableBuildRetry
        buildRetry = env.clock.schedule(after: delay) { [weak self] in
            self?.buildRetry = nil
            self?.reconcile()
        }
    }

    /// No build is left that could not read the process list: a later one starts a new streak
    /// with its 100 ms retries.
    private func endUnreadableBuildStreak() {
        buildRetry?.cancel()
        buildRetry = nil
        buildListUnreadableSince = nil
        unreadableAtBuild.removeAll()
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

    /// The devices whose ticket the change would carry (`alters`), so a handover holds on every
    /// device it then waits for (§16.4 hold rule). An owner without a claim yet has no targets
    /// here, and no process can leave a list through its first claim.
    func changedDevices(owner: ObjectIdentifier, proposed: Claim) -> Set<String> {
        pruneReleasedOwners()
        let before = activeClaims()
        let after = claims.filter { $0.key != owner && $0.value.owner != nil }.map { $0.value.claim } + [proposed]
        let targets = claims[owner]?.owner?.targets ?? []
        let live = env.processList().map(Set.init)
        return Set(devices.values.filter {
            alters($0, from: claimed($0.uid, by: before, live: live), to: claimed($0.uid, by: after, live: live),
                   targets: targets)
        }.map(\.uid))
    }

    func setClaim(_ owner: any CatchAllClaimOwner, _ claim: Claim) -> ApplyTicket? {
        pruneReleasedOwners()
        let id = ObjectIdentifier(owner)
        let before = activeClaims()
        let previous = claims[id]?.claim
        claims[id] = ClaimEntry(owner: owner, claim: claim)
        let ticket = previous == claim ? nil : claimsChanged(from: before, targets: owner.targets)
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
        guard let entry = claims[owner] else { return nil }
        let before = activeClaims()
        claims[owner] = nil
        return claimsChanged(from: before, targets: entry.owner?.targets ?? [])
    }

    func prepareInclusion(of processes: [AudioObjectID], on uids: Set<String>) {
        guard !processes.isEmpty, !uids.isEmpty else { return }
        env.runControl.prepareInclusion(Set(processes), on: uids)
    }

    /// Bumps the generation of each catch-all whose list the change alters and schedules the
    /// flush. `targets` are those of the owner whose claim changed.
    private func claimsChanged(from before: [Claim], targets: Set<String>) -> ApplyTicket? {
        let after = activeClaims()
        // Unreadable: compare whole claims, which can only name more devices
        let live = env.processList().map(Set.init)
        var changed: [String: UInt64] = [:]
        for device in devices.values {
            guard alters(device, from: claimed(device.uid, by: before, live: live),
                         to: claimed(device.uid, by: after, live: live), targets: targets) else { continue }
            let generation = generations[device.uid, default: 0] + 1
            generations[device.uid] = generation
            changed[device.uid] = generation
            // Only its rebuild or a settling failure gave it this ticket: the wait ends with them
            if device.phase == .dormant, !targets.contains(device.uid) {
                device.shrinksForRebuild.insert(generation)
            }
        }
        scheduleFlush()
        return changed.isEmpty ? nil : ApplyTicket(generations: changed)
    }

    /// Whether a claim change from `old` to `new` processes on the device gives it a ticket;
    /// `targets` are the changing tap's outputs. A live catch-all counts on any change. A
    /// building one counts only when processes leave its list: its tap already excludes them,
    /// so their per-app tap must stay until a list without them has applied (I1). Processes
    /// joining one need no wait: a building one stays held until its list covers them (E1),
    /// and a dormant one plays nothing and is rebuilt from the current claims (§16.4).
    ///
    /// A dormant one counts when processes leave its list, in mode on, for a tap that plays to
    /// it, and for any tap once its rebuild is requested, postponed or building, or a failure
    /// on it settles: its tap still excludes them until the takeover of its rebuild, R or G,
    /// which may be hours away. A tap that plays to it is held by the hold rule and plays to a
    /// dead device while it waits. A tap that plays elsewhere (a mixdown claim covers every
    /// catch-all device, P5) keeps processing its app there instead while the device is dead,
    /// since the dormant tap captures only what plays to its device; once the device is alive
    /// again (a rebuild or a settling failure says so), the dormant tap or the catch-all being
    /// built may still exclude the process, which would then play unprocessed on the device
    /// until a new list applies, so that tap waits for the rebuild, R or G, or until the device
    /// stays dormant after all (`isApplied`). In observe a dormant tap holds nothing back.
    private func alters(_ device: CatchAllDevice, from old: Set<AudioObjectID>, to new: Set<AudioObjectID>,
                        targets: Set<String>) -> Bool {
        switch device.phase {
        case .live: old != new
        case .building: !old.isSubset(of: new)
        case .dormant:
            env.mode == .on && (targets.contains(device.uid) || awaitsRebuild(device)) && !old.isSubset(of: new)
        case .retiring: false
        }
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
    /// desired list (E) and retired (R) if that fails and the failure stands; its waits complete
    /// through either. While a failure on the device settles, its end decides instead (`rebuild`).
    /// The I1 check that ends the flush still removes any exclusion left without a claim. While
    /// a rebuilt catch-all waits to take over, pushes go to it, so a failure fails the rebuild: R.
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
            // It plays nothing, and its rebuild starts from the current claims (§16.4): a grow
            // wait ends at once. Its tap still excludes a process whose claim ended, since no
            // push goes to a dormant catch-all, and once the device is alive again that process
            // would play unprocessed until a rebuilt catch-all's tap exists. So in mode on a
            // shrink wait ends only at the takeover of the rebuild from dormant, R3 or G (one
            // pushed before the device died ends S after that push); a claim change gives a
            // dormant device a ticket only for a tap that plays to it, which the hold rule holds,
            // so it plays to a dead device meanwhile, or once its rebuild is requested or a
            // failure on it settles (`alters`). The device bounds it: G once it is no longer
            // listed, stop(), and once it is alive the rebuild and its watchdog, or R. In observe
            // its tap holds nothing back, so no wait on it protects anything.
            guard direction == .shrink, env.mode == .on else { return true }
            // A tap that plays elsewhere waited only because the device was about to be alive
            // again. Once no rebuild, settling failure or R is left and the device is still
            // dormant, nothing plays to it, and the tap would protect nothing until it wakes.
            if device.shrinksForRebuild.contains(generation), !awaitsRebuild(device), pendingRetirements[uid] == nil {
                return true
            }
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
            endAbsent(device)
            return
        }
        guard env.mode == .on else {
            // Observe decides as mode on does: a detach timeout counts as R4's would, and the
            // same backoff and IsAlive observation follow
            endCoverage(device, reason: "retired in observe (\(reason.rawValue))", timeoutCounts: true)
            coverageEnded(device, retired: reason)
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
        cancelBackoffReset(device)
        // From dormant: E12 ends for it until R4 is over
        stopObservingAlive(uid)
        stopDormantCheckIfIdle()
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
        coverageEnded(device, retired: reason)
        checkWaiters()
    }

    /// After R4, or after the G that a retirement is in observe. A push failure, a failed
    /// rebuild and a blocked run queue back off (E14), apart from one that a settled failure
    /// backed off already (`failureSettled`); tierChanged (ineligible anyway), injected
    /// (the next reconcile may build again), give-up and the breaker do not. The E12
    /// entry points ignored the device while it retired, so it is checked again: one that is
    /// not alive is observed until it is. Nothing is built here; that waits for the backoff's
    /// end or the next reconcile.
    private func coverageEnded(_ device: CatchAllDevice, retired reason: CatchAllRetireReason) {
        let uid = device.uid
        let output = listedOutputs().first { $0.uid == uid }
        switch reason {
        case .pushFailed, .rebuildFailed, .runQueueTimeout:
            guard !device.backoffSettles else { break }
            backOff(uid, deviceID: output?.id ?? device.deviceID, after: "retired (\(reason.rawValue))")
        case .givenUp, .breaker, .tierChanged, .injected:
            break
        }
        guard isStarted, let output else { return }
        updateAliveWatch(output, ineligibility(of: output))
    }

    // MARK: End without promotion (G)

    /// G (design §5 G, §16.4): for an absent device, at `stop()`, and for every retirement in
    /// observe. No callback and nothing counted: each catch-all is held first (one atomic
    /// store; §5 G detaches before the handovers, and a detach can wait behind a blocked run
    /// queue), then the entry goes, so its waits complete (grow waiters release, shrink waiters
    /// invalidate), and each catch-all is detached within the bound and destroyed once its
    /// queued detach has run. A detach timeout counts only for a retirement in observe
    /// (`timeoutCounts`).
    private func endCoverage(_ device: CatchAllDevice, reason: String, timeoutCounts: Bool = false) {
        guard devices[device.uid] === device else { return }
        for controller in device.controllers where !controller.renderState.held.load(ordering: .relaxed) {
            setHeld(controller, true, uid: device.uid)
        }
        let entries = takeControllers(device, keepAside: false, timeoutCounts: timeoutCounts)
        removeEntry(device)
        logger.notice("Catch-all on \(device.uid, privacy: .public) ended without promotion (\(reason, privacy: .public))")
        emit(.ended(uid: device.uid, reason: reason))
        checkWaiters()
        evaluateSettle()
        guard !entries.isEmpty else { return }
        Task { await self.detachAndDestroy(entries) }
    }

    /// G for a device that went away during R or a rebuild (E11). While its UID is still listed
    /// (Core Audio no longer resolves it, and the device list has not caught up), no device-list
    /// change may follow to run the gate: it runs now, so the apps the catch-all played get
    /// their taps, and a reconcile builds again (uncounted while the UID does not resolve).
    private func endAbsent(_ device: CatchAllDevice) {
        endCoverage(device, reason: "absent")
        guard isStarted, listedOutputs().contains(where: { $0.uid == device.uid }) else { return }
        logger.notice("Catch-all on \(device.uid, privacy: .public) ended while its UID is still listed; reconciling and re-running the gate")
        reconcile()
        requestReevaluation()
    }

    /// Drops the device's entry and the work queued for it.
    private func removeEntry(_ device: CatchAllDevice) {
        guard devices[device.uid] === device else { return }
        devices[device.uid] = nil
        pendingRetirements[device.uid] = nil
        pendingRebuilds[device.uid] = nil
        cancelRebuildDeferral(device)
        cancelBackoffReset(device)
        stopObservingAlive(device.uid)
        stopDormantCheckIfIdle()
    }

    // MARK: Ending catch-alls

    /// Takes the device's catch-alls out of service: the current one and, while a rebuild
    /// waits to take over, the one it replaces. From here they are only detached and destroyed.
    /// A detach timeout counts for R and for the G of a retirement in observe, not for other G.
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
            } else if dormantDetaches.contains(ObjectIdentifier(entry.controller)) {
                // Detached when it went dormant, and that detach has not run yet: destroyed once it has
                continue
            }
            entry.detached = true
            destroyIfDone(entry)
        }
    }

    /// The ending catch-all is destroyed once the run queue has run its detach.
    private func detachTimedOut(_ entry: EndingCatchAll) {
        queueBlocked(entry.uid, aggregate: entry.controller.ioHandle.aggregateID, counts: entry.timeoutCounts,
                     then: "destroying it once the queued detach has run")
        env.runControl.afterQueuedWork {
            Task { @MainActor in self.queuedDetachRan(entry) }
        }
    }

    private func queuedDetachRan(_ entry: EndingCatchAll) {
        queueCaughtUp(entry.uid)
        entry.detached = true
        destroyIfDone(entry)
    }

    /// A detach of a catch-all on `uid` did not run within the run control's bound (§16.6). A
    /// blocked run queue counts once (never for G, a device that went dormant, a rebuilt
    /// catch-all that failed before it took over, or after `stop()`) until it has run every
    /// detach that timed out: the old and the new catch-all of a rebuild wait on the same one.
    /// It is one serial queue, so every live catch-all depends on it, a stopped one cannot
    /// start, and its covered audio would stay silent: each one retires (R), also one built
    /// after G while that G's detach still waited, or the new one of a rebuild. A dormant one
    /// stays dormant, since it plays nothing; a rebuild of it once the device is alive retires
    /// it instead (`performRebuild`). A live one whose device has a failure that has not
    /// settled is left to that end, since the device may be dying and R2 would tap every app
    /// there for nothing: it retires if the device is still usable then and goes dormant
    /// otherwise (`failureSettled`). A build whose wait runs now finds the queued detach once it
    /// returns (`build`, `performRebuild`). Until the queue has run every such detach, no
    /// catch-all is built or rebuilt on any device.
    private func queueBlocked(_ uid: String, aggregate: AudioDeviceID, counts: Bool, then action: String) {
        logger.fault("Catch-all on \(uid, privacy: .public) (aggregate \(aggregate)): the run queue did not detach it within its bound; \(action, privacy: .public)")
        stuckDetaches += 1
        if counts, isStarted, !queueTimeoutCounted {
            queueTimeoutCounted = true
            noteFailure(uid, .runQueueTimeout)
        }
        for device in devices.values.sorted(by: { $0.uid < $1.uid })
        where device.phase == .live && failureSettles[device.uid] == nil {
            queueRetirement(device.uid, .runQueueTimeout)
        }
    }

    /// The run queue ran a detach that had timed out (`afterQueuedWork`, hopped back to main).
    /// Once it ran every one, the reconcile may build again.
    private func queueCaughtUp(_ uid: String) {
        logger.notice("Catch-all on \(uid, privacy: .public): its queued detach has run")
        stuckDetaches -= 1
        guard stuckDetaches == 0 else { return }
        queueTimeoutCounted = false
        if isStarted { reconcile() }
    }

    private func destroyIfDone(_ entry: EndingCatchAll) {
        guard entry.detached, !entry.keptAside, !entry.destroying else { return }
        entry.destroying = true
        let controller = entry.controller
        Task {
            await controller.destroy()
            self.ending.removeAll { $0 === entry }
            // Aggregate IDs are reused: a later aggregate with this ID counts its own IO failure
            self.countedAggregates.remove(controller.ioHandle.aggregateID)
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
    /// already and dropped. A dormant device is rebuilt only once it is alive (E12); after the
    /// breaker nothing is rebuilt. While a failed rebuild on the device settles, the request is
    /// left to its end, which retires the catch-all or runs the E12 check (`failureSettled`).
    func rebuild(_ uid: String, reason: CatchAllRebuildReason, aggregate: AudioDeviceID? = nil) {
        guard !breakerOpen, let device = devices[uid], device.phase == .live || device.phase == .dormant else { return }
        if let aggregate {
            // While the new catch-all builds, the one in service is the one being replaced
            let replacing = device.rebuild.map { !$0.isWaiting } ?? false
            guard aggregate == device.controller?.ioHandle.aggregateID, !replacing else { return }
        }
        if failureSettles[uid] != nil {
            logger.notice("Catch-all on \(uid, privacy: .public): rebuild (\(reason.rawValue, privacy: .public)) left to the failure that has not settled")
            return
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
    /// fails, the old one serves on and `rebuildFailed` decides: R once the failure stood, G if
    /// the device went away, dormant if it is not alive. A live device that is not alive goes
    /// dormant without a build (E12). While a detach on any device waits behind the blocked
    /// run queue, the new catch-all would attach behind it and stay silent: R instead (§16.6),
    /// since per-app taps need no run queue, also when that detach timed out during the
    /// build's wait. A device that died or changed its ID during the wait is checked again once
    /// the new catch-all is attached (E12).
    ///
    /// From dormant (E12 step 4) the device stays dormant while the new catch-all builds: no
    /// push involves it, so nothing reaches the dormant one, and claims that end wait as on a
    /// building one. It turns live at the new one's attach, which from then on gets the pushes;
    /// waits on the device end at the takeover as in any rebuild. The dormant one is not
    /// attached, so it is not detached again; it is destroyed after the takeover, or once its
    /// own detach has run.
    private func performRebuild(_ uid: String, _ reason: CatchAllRebuildReason) {
        guard isStarted, !breakerOpen, let device = devices[uid],
              device.phase == .live || device.phase == .dormant, device.rebuild == nil else { return }
        let startPhase = device.phase
        if startPhase == .dormant, let output = listedOutputs().first(where: { $0.uid == uid }),
           !deviceUsable(uid, output.id) {
            // Not alive again after all: it stays dormant (a UID no longer listed is G below). A
            // postponed attempt ends here, so the next one can start once the device is alive.
            logger.notice("Catch-all on \(uid, privacy: .public): not rebuilt, device \(output.id) is not alive; it stays dormant")
            cancelRebuildDeferral(device)
            observeAlive(uid, output.id)
            // A shrink of a tap on the device keeps waiting for the rebuild once it is alive, R
            // or G; one of a tap that plays elsewhere ends
            checkWaiters()
            return
        }
        guard !isAbsent(uid), let output = listedOutputs().first(where: { $0.uid == uid }) else {
            // Absent: G, as the next reconcile would do
            endAbsent(device)
            return
        }
        if startPhase == .live, !env.isAlive(output.id) {
            enterDormant(device, listedID: output.id, why: "device \(output.id) is not alive when its rebuild (\(reason.rawValue)) starts")
            return
        }
        if stuckDetaches > 0 {
            logger.error("Catch-all on \(uid, privacy: .public): not rebuilt (\(reason.rawValue, privacy: .public)), the run queue has not run a detach that timed out; retiring")
            performRetirement(uid, .runQueueTimeout)
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
            guard isStarted, devices[uid] === device, device.rebuild != nil else {
                logger.notice("Catch-all on \(uid, privacy: .public) could not be rebuilt after it stopped being wanted: \(String(describing: error), privacy: .public)")
                return
            }
            rebuildFailed(device, String(describing: error))
            return
        }
        buildDepth -= 1

        // stop(), G, a retirement or the breaker during the wait: nobody wants the new catch-all
        guard isStarted, !breakerOpen, devices[uid] === device, device.phase == startPhase, device.rebuild != nil,
              pendingRetirements[uid] == nil else {
            logger.notice("Catch-all on \(uid, privacy: .public) rebuilt after it stopped being wanted; destroying it")
            // R or G follows in each case and ends the waits, a dormant device's included
            if devices[uid] === device { device.rebuild = nil }
            Task { await controller.destroy() }
            return
        }
        // A detach timed out during the wait (the dormant one's, say): the new one would attach
        // behind it on the same queue and stay silent. R, as before a build
        guard stuckDetaches == 0 else {
            logger.error("Catch-all on \(uid, privacy: .public) rebuilt (\(reason.rawValue, privacy: .public)) while the run queue has not run a detach that timed out; destroying it and retiring")
            device.rebuild = nil
            Task { await controller.destroy() }
            performRetirement(uid, .runQueueTimeout)
            return
        }
        let now = env.clock.now
        device.rebuild?.outgoing = device.controller
        device.rebuild?.outgoingAttached = device.attached
        device.rebuild?.outgoingState = OutgoingState(
            attachedAt: device.attachedAt, deviceID: device.deviceID, settledGeneration: device.settledGeneration,
            pushes: device.pushes, listUnconfirmed: device.listUnconfirmed, initialEscalated: device.initialEscalated)
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
        if startPhase == .dormant {
            // Live from the attach on; the rebuild hold keeps the new one silent until it takes over
            device.holds.remove(.dormant)
            device.phase = .live
            stopObservingAlive(uid)
            stopDormantCheckIfIdle()
            noteLive(device)
            logger.notice("Catch-all on \(uid, privacy: .public) live again on device \(output.id)")
            emit(.phase(uid: uid, .live))
        }
        env.runControl.attach(controller.ioHandle, deviceID: controller.deviceID, excluded: Set(exclusions))
        // The E12 check skipped the device while the build ran, and the attach dropped its
        // IsAlive observation: a death or a new ID during the wait is caught now
        checkDevice(device)
        // Claims that changed during the wait are pushed to the new catch-all
        scheduleFlush()
        checkWaiters()
    }

    /// The new catch-all could not be built. A device that went away meanwhile (the build found
    /// no device for the UID) ends with G (E11). One that is listed but not alive keeps the old
    /// catch-all as a dormant one (E12): nothing counted, no R and no backoff; it is rebuilt
    /// once alive. On a device that reads alive the old one serves on as it was, live or
    /// dormant, since a device that is leaving may fail the build before IsAlive turns false,
    /// and R2 on a dying device would tap every app there for nothing: the failure settles
    /// first (`failureSettled`), with nothing built or rebuilt on the device meanwhile. Still
    /// listed under the same ID and usable then, and not found otherwise meanwhile, it counts
    /// (E14), the old one retires (R) and the next build backs off; otherwise the E12 check
    /// decides, uncounted. A device that stays dormant ends the shrink waits that waited only
    /// for this rebuild (`isApplied`).
    private func rebuildFailed(_ device: CatchAllDevice, _ message: String) {
        let reason = device.rebuild?.reason ?? .pushFailed
        device.rebuild = nil
        logger.error("Catch-all on \(device.uid, privacy: .public) could not be rebuilt: \(message, privacy: .public)")
        emit(.buildFailed(uid: device.uid, reason: message))
        guard !isAbsent(device.uid) else {
            endAbsent(device)
            return
        }
        let id = listedOutputs().first { $0.uid == device.uid }?.id ?? device.deviceID
        guard env.isAlive(id) else {
            if device.phase == .live {
                enterDormant(device, listedID: id, why: "device \(id) is not alive after a failed rebuild")
            } else {
                logger.notice("Catch-all on \(device.uid, privacy: .public): device \(id) is not alive after a failed rebuild; it stays dormant")
                observeAlive(device.uid, id)
                // A shrink of a tap on the device keeps waiting for the rebuild once it is alive,
                // R or G; one of a tap that plays elsewhere ends
                checkWaiters()
            }
            return
        }
        logger.notice("Catch-all on \(device.uid, privacy: .public): the old catch-all serves until the failed rebuild settled")
        // A rebuild asked for during this one is decided with it
        device.rebuildAgain = nil
        settleFailure(device.uid, deviceID: id, countsBuild: true, cause: "its rebuild failed", failedRebuild: reason)
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
            guard let self, let device, self.devices[device.uid] === device,
                  device.phase == .live || device.phase == .dormant, device.rebuildDeferral != nil else { return }
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
        device.shrinksForRebuild.removeAll()
        if device.holds.remove(.initialList) != nil {
            logger.notice("Catch-all on \(device.uid, privacy: .public) released: its exclusion list applied")
            emit(.released(uid: device.uid))
        }
        release(device, from: .rebuild)
        logger.notice("Catch-all on \(device.uid, privacy: .public): the rebuilt catch-all took over (\(rebuild.reason.rawValue, privacy: .public))")
        emit(.rebuilt(uid: device.uid))
        if let old = rebuild.outgoing {
            let entry = EndingCatchAll(uid: device.uid, controller: old, attached: rebuild.outgoingAttached)
            entry.timeoutCounts = true
            ending.append(entry)
            Task { await self.detachAndDestroy([entry]) }
        }
        if let again = device.rebuildAgain {
            device.rebuildAgain = nil
            self.rebuild(device.uid, reason: again)
        }
    }

    // MARK: IO failures (§16.6)

    /// A report from the run control (`onRebuild`, hopped to main): the catch-all's IO died or
    /// would not start; both are handled alike. Dropped while stopped, after the breaker, for an
    /// unknown UID, a building or retiring device, one whose retirement is queued, and for an
    /// aggregate that is not the catch-all in service or is being replaced (reports repeat,
    /// §16.12 item 10). A dormant catch-all is detached, so a report about it is late: only
    /// whether the device is alive again matters. Then E12 first: a device that is not alive
    /// goes dormant, and a new alive ID is rebuilt, both uncounted. Otherwise the catch-all is
    /// rebuilt at once (E), and the failure counts toward give-up once per aggregate if the
    /// device is still listed under the same ID and alive 1 s later. A report about a rebuilt
    /// catch-all that waits to take over fails its rebuild: that catch-all goes, the one it
    /// replaces serves on as before the rebuild, and the failure settles as a failed rebuild's
    /// does (`failureSettled`): R and the backoff if the device is then still listed under the
    /// same ID and usable and was not found otherwise meanwhile, else the E12 check.
    func reportIOFailure(_ uid: String, aggregate: AudioDeviceID, _ reason: CatchAllRunLogic.RebuildReason) {
        guard isStarted, !breakerOpen, let device = devices[uid], pendingRetirements[uid] == nil else { return }
        switch device.phase {
        case .building, .retiring:
            return
        case .dormant:
            checkDevice(device)
            return
        case .live:
            break
        }
        let replacing = device.rebuild.map { !$0.isWaiting } ?? false
        guard aggregate == device.controller?.ioHandle.aggregateID, !replacing else { return }
        guard checkDevice(device) == .unchanged else { return }
        logger.error("Catch-all on \(uid, privacy: .public) (aggregate \(aggregate)): IO failure (\(reason.rawValue, privacy: .public))")
        if countedAggregates.insert(aggregate).inserted {
            settleIOFailure(uid, deviceID: device.deviceID, aggregate: aggregate)
        }
        if let rebuild = device.rebuild, rebuild.isWaiting {
            // The new catch-all's IO failed before it took over. The run control never retries a
            // failed start, so it would take over silent: the rebuild failed. Its device may be
            // leaving, as for a failed build, so the one it replaces serves on until that settled.
            // A push failure or watchdog that failed the rebuild already queued R.
            guard !rebuild.failed else { return }
            logger.error("Catch-all on \(uid, privacy: .public): the rebuilt catch-all failed before it took over; the one it replaces serves until the failure settled")
            // First: the dormant one put back observes IsAlive, whose read may ask for a rebuild
            settleFailure(uid, deviceID: device.deviceID, countsBuild: false,
                          cause: "its rebuilt catch-all failed before it took over", failedRebuild: rebuild.reason)
            dropFailedRebuild(device)
            return
        }
        rebuild(uid, reason: .ioFailed, aggregate: aggregate)
    }

    /// A rebuilt catch-all that waits to take over failed: it is detached within the bound and
    /// destroyed once its queued detach has run, like any catch-all that ends. The one it
    /// replaces is back in service as before the rebuild, with the device's record of it (ID,
    /// pushes, the confirmed list), so a wait resolves against what that tap applied; claims
    /// that changed meanwhile went only to the failed one and are pushed now. One replaced from
    /// dormant is dormant again: held, detached and observed.
    private func dropFailedRebuild(_ device: CatchAllDevice) {
        guard let rebuild = device.rebuild, rebuild.isWaiting, let failed = device.controller,
              let old = rebuild.outgoing, let saved = rebuild.outgoingState else { return }
        let uid = device.uid
        // Its detach timeout counts nothing, as one on a device that went dormant: the device may
        // be dying, and a HAL call on it may be what blocks the run queue. If the failure stands,
        // R4's detach of the one it replaced waits behind the same queue and counts then.
        let entry = EndingCatchAll(uid: uid, controller: failed, attached: device.attached)
        ending.append(entry)
        device.rebuild = nil
        device.rebuildAgain = nil
        device.holds.remove(.rebuild)
        device.controller = old
        device.attached = rebuild.outgoingAttached
        device.attachedAt = saved.attachedAt
        device.deviceID = saved.deviceID
        device.settledGeneration = saved.settledGeneration
        device.pushes = saved.pushes
        device.listUnconfirmed = saved.listUnconfirmed
        device.initialEscalated = saved.initialEscalated
        if device.attached {
            logger.notice("Catch-all on \(uid, privacy: .public): the catch-all the failed one would have replaced serves again")
            scheduleFlush()
        } else {
            // It was dormant when the rebuild began
            device.holds.insert(.dormant)
            device.phase = .dormant
            cancelBackoffReset(device)
            logger.notice("Catch-all on \(uid, privacy: .public) dormant again: its rebuilt catch-all failed before it took over")
            emit(.phase(uid: uid, .dormant))
            scheduleDormantCheck()
            observeAlive(uid, listedOutputs().first { $0.uid == uid }?.id ?? device.deviceID)
        }
        Task { await self.detachAndDestroy([entry]) }
        checkWaiters()
    }

    /// An IO failure counts only once it settled: on an HDMI link drop the IO may stop before
    /// IsAlive turns false, and a link that flaps at wake must not give the device up or open
    /// the breaker. The rebuild does not wait for it.
    private func settleIOFailure(_ uid: String, deviceID id: AudioDeviceID, aggregate: AudioDeviceID) {
        nextIOFailureCheck += 1
        let key = nextIOFailureCheck
        ioFailureChecks[key] = env.clock.schedule(after: Self.failureSettle) { [weak self] in
            guard let self else { return }
            self.ioFailureChecks[key] = nil
            self.ioFailureSettled(uid, deviceID: id, aggregate: aggregate)
        }
    }

    private func ioFailureSettled(_ uid: String, deviceID id: AudioDeviceID, aggregate: AudioDeviceID) {
        guard isStarted, !breakerOpen else { return }
        guard listedOutputs().contains(CatchAllOutput(uid: uid, id: id)), env.isAlive(id) else {
            logger.notice("Catch-all on \(uid, privacy: .public) (aggregate \(aggregate)): IO failure not counted, device \(id) is no longer listed under this ID or not alive")
            return
        }
        noteFailure(uid, .ioFailed, deviceID: id)
    }

    /// A failed build, a failed rebuild, or a rebuilt catch-all whose IO failed before it took
    /// over, on a device that reads alive: the failure counts toward the breaker (`countsBuild`),
    /// backs off and, after a failed rebuild (`failedRebuild`), retires the catch-all that serves
    /// meanwhile only once it settled, as an IO failure counts. Until then nothing is built or
    /// rebuilt on the device, so one failure is not followed by another that would count for
    /// it, and a push failure or IO report meanwhile is decided with it (`rebuild`).
    private func settleFailure(_ uid: String, deviceID id: AudioDeviceID, countsBuild: Bool, cause: String,
                               failedRebuild: CatchAllRebuildReason? = nil) {
        if let pending = failureSettles[uid] {
            failureSettles[uid]?.countsBuild = pending.countsBuild || countsBuild
            failureSettles[uid]?.failedRebuild = pending.failedRebuild ?? failedRebuild
            return
        }
        let check = env.clock.schedule(after: Self.failureSettle) { [weak self] in self?.failureSettled(uid) }
        failureSettles[uid] = FailureSettle(deviceID: id, countsBuild: countsBuild, cause: cause,
                                            failedRebuild: failedRebuild, check: check)
    }

    /// If the device is still listed under the same ID and usable, as the build required at the
    /// failure, and was not found otherwise meanwhile, the failure stood: the catch-all that
    /// served meanwhile retires with the failed rebuild's reason (queued first, so the breaker
    /// this count may open keeps that reason), the failure counts, and the next build backs off,
    /// counted from the failure; R4 backs off no further. Otherwise nothing counts and nothing
    /// retires (a UID Core Audio no longer resolves is going away, E11; a device that died and
    /// came back failed for its link): the E12 check decides for a catch-all (dormant, a rebuild
    /// on a new alive ID or once alive again, G for a UID no longer listed), and a reconcile
    /// without one builds on an alive ID or observes a device that is not alive (E14). If the
    /// check finds the catch-all unchanged (listed again under its own ID), the failed rebuild
    /// is asked for again, so no request left to the settle is lost. A shrink wait that waited
    /// only for this end, and finds the device dormant, ends (`isApplied`).
    private func failureSettled(_ uid: String) {
        guard let settle = failureSettles.removeValue(forKey: uid), isStarted, !breakerOpen else { return }
        let id = settle.deviceID
        guard !settle.diedMeanwhile, listedOutputs().contains(CatchAllOutput(uid: uid, id: id)), deviceUsable(uid, id) else {
            let why = settle.diedMeanwhile
                ? "the device was not alive meanwhile"
                : "device \(id) is no longer listed under this ID, alive and resolved"
            logger.notice("Catch-all on \(uid, privacy: .public): \(settle.cause, privacy: .public), not counted: \(why, privacy: .public)")
            guard let device = devices[uid] else {
                reconcile()
                return
            }
            if checkDevice(device) == .unchanged, let reason = settle.failedRebuild {
                rebuild(uid, reason: reason)
            }
            checkWaiters()
            return
        }
        if let reason = settle.failedRebuild, let device = devices[uid] {
            device.backoffSettles = true
            queueRetirement(uid, Self.retireReason(after: reason))
        }
        if settle.countsBuild, noteFailure(uid, .buildFailed) { return }
        backOff(uid, deviceID: id, after: settle.cause, elapsed: Self.failureSettle)
    }

    /// The device was found not usable while a failure on it settles: the failure did not stand,
    /// even if the device reads alive at the end (`failureSettled`).
    private func noteNotUsableWhileSettling(_ uid: String) {
        guard failureSettles[uid]?.diedMeanwhile == false else { return }
        failureSettles[uid]?.diedMeanwhile = true
        logger.notice("Catch-all on \(uid, privacy: .public): the device is not usable while its last failure settles; that failure will not count")
    }

    private func cancelFailureSettles() {
        for settle in failureSettles.values { settle.check.cancel() }
        failureSettles.removeAll()
    }

    // MARK: Dormant devices (E12)

    /// What the E12 check found.
    private enum DeviceCheck {
        /// Alive under the same ID, or left to a rebuild whose build is running.
        case unchanged
        /// No longer listed: the reconcile it requested ends it with G.
        case gone
        /// Not alive, or Core Audio does not resolve the UID while it is listed.
        case dormant
        /// A new alive ID, or alive again after it was dormant: a rebuild is requested, or left to
        /// a failure on the device that has not settled.
        case rebuilding
    }

    /// E12, for a live or dormant catch-all (a retiring or building one is left alone; the
    /// device is checked again once R4 is over). From the IO and start failure reports, every
    /// reconcile (and so every device-list refresh), the 2 s check, the IsAlive listener and
    /// the attach of a built or rebuilt catch-all, whose wait no check could see into.
    /// G only for a UID that is no longer listed; a listed device that is not alive, or whose
    /// UID Core Audio cannot resolve, keeps its catch-all dormant; a new listed ID that is
    /// alive, or the device alive again, rebuilds through E on the listed ID.
    @discardableResult
    private func checkDevice(_ device: CatchAllDevice) -> DeviceCheck {
        guard isStarted, devices[device.uid] === device, device.phase == .live || device.phase == .dormant else {
            return .unchanged
        }
        if let rebuild = device.rebuild, !rebuild.isWaiting { return .unchanged }
        let uid = device.uid
        guard let output = listedOutputs().first(where: { $0.uid == uid }) else {
            reconcile()
            return .gone
        }
        let usable = deviceUsable(uid, output.id)
        if device.phase == .dormant {
            guard usable else {
                noteNotUsableWhileSettling(uid)
                // Moves the observation when the listed ID changed
                observeAlive(uid, output.id)
                return .dormant
            }
            logger.notice("Catch-all on \(uid, privacy: .public): device \(output.id) is alive again; rebuilding")
            rebuild(uid, reason: .deviceChanged)
            return .rebuilding
        }
        guard usable else {
            let why = env.isAlive(output.id) ? "Core Audio does not resolve the listed UID" : "device \(output.id) is not alive"
            enterDormant(device, listedID: output.id, why: why)
            return .dormant
        }
        guard output.id == device.deviceID else {
            // An IsAlive listener would never fire on an alive device
            logger.notice("Catch-all on \(uid, privacy: .public): listed under a new ID \(output.id) (was \(device.deviceID)); rebuilding")
            rebuild(uid, reason: .deviceChanged)
            return .rebuilding
        }
        return .unchanged
    }

    /// E12 step 2. The catch-all is held with a reason of its own (so ending another reason
    /// never opens it), then detached within the run control's bound, as in R4; its resources
    /// stay, and nothing is counted or called back, a detach timeout included: a HAL call on
    /// the aggregate whose device just died may be what blocks the run queue. `covers` stays
    /// true, so no `activate` waits on a dead device; grow waits on it end at once and claims
    /// that add processes give it no ticket, since it plays nothing and its rebuild starts
    /// from the current claims, while in mode on a shrink of a tap that plays to it, or of any
    /// tap once that rebuild is requested or a failure on it settles, waits for the rebuild, R
    /// or G (`alters`, `isApplied`). A rebuild waiting to take over ends: the catch-all it would
    /// replace goes, and the new one turns dormant. A failure on the device that settles no
    /// longer counts. From here IsAlive of the listed ID is observed, and the 2 s check runs.
    private func enterDormant(_ device: CatchAllDevice, listedID: AudioDeviceID, why: String) {
        guard device.phase == .live else { return }
        let uid = device.uid
        noteNotUsableWhileSettling(uid)
        if let rebuild = device.rebuild, let old = rebuild.outgoing {
            if !old.renderState.held.load(ordering: .relaxed) { setHeld(old, true, uid: uid) }
            let entry = EndingCatchAll(uid: uid, controller: old, attached: rebuild.outgoingAttached)
            ending.append(entry)
            Task { await self.detachAndDestroy([entry]) }
        }
        device.rebuild = nil
        device.rebuildAgain = nil
        cancelRebuildDeferral(device)
        pendingRebuilds[uid] = nil
        device.holds.insert(.dormant)
        if let controller = device.controller, !controller.renderState.held.load(ordering: .relaxed) {
            setHeld(controller, true, uid: uid)
        }
        device.phase = .dormant
        cancelBackoffReset(device)
        logger.notice("Catch-all on \(uid, privacy: .public) dormant: \(why, privacy: .public); held and detached, resources kept")
        emit(.phase(uid: uid, .dormant))
        if let controller = device.controller, device.attached {
            device.attached = false
            detachDormant(uid, controller)
        }
        checkWaiters()
        scheduleDormantCheck()
        // Last: the read right after registering may already find it alive and rebuild
        observeAlive(uid, listedID)
    }

    /// Detaches a dormant catch-all within the run control's bound. A timeout counts nothing,
    /// since the dead device may be what blocks the queue; the catch-all stays dormant (nothing
    /// plays to a dead device, so R2 would only activate taps there) and is destroyed, when its
    /// coverage ends, only once the run queue has run that detach. A device alive again before
    /// then retires instead of being rebuilt (`performRebuild`); every live catch-all, one
    /// built or rebuilt on the device before the timeout included, attached behind the blocked
    /// queue and retires at it (`queueBlocked`).
    private func detachDormant(_ uid: String, _ controller: CatchAllTapController) {
        dormantDetaches.insert(ObjectIdentifier(controller))
        Task {
            if await self.env.runControl.detach(controller.ioHandle) {
                self.dormantDetachRan(controller)
                return
            }
            self.queueBlocked(uid, aggregate: controller.ioHandle.aggregateID, counts: false,
                              then: "it stays dormant and is destroyed only once the queued detach has run")
            self.env.runControl.afterQueuedWork {
                Task { @MainActor in
                    self.queueCaughtUp(uid)
                    self.dormantDetachRan(controller)
                }
            }
        }
    }

    /// A dormant catch-all's detach has run; one whose coverage ended meanwhile waited for it.
    private func dormantDetachRan(_ controller: CatchAllTapController) {
        guard dormantDetaches.remove(ObjectIdentifier(controller)) != nil else { return }
        for entry in ending where entry.controller === controller {
            entry.detached = true
            destroyIfDone(entry)
        }
    }

    /// Observes IsAlive of `id` for `uid`, moving an observation of another ID, and reads it once
    /// right after registering: a device that came back between the check and the registration
    /// is caught.
    private func observeAlive(_ uid: String, _ id: AudioDeviceID) {
        guard aliveWatches[uid]?.id != id else { return }
        stopObservingAlive(uid)
        let token = env.observeAlive(id) { [weak self] in self?.aliveChanged(uid, id) }
        aliveWatches[uid] = AliveWatch(id: id, token: token)
        logger.notice("Catch-all on \(uid, privacy: .public): observing IsAlive of device \(id)")
        if env.isAlive(id) { aliveChanged(uid, id) }
    }

    private func stopObservingAlive(_ uid: String) {
        aliveWatches[uid] = nil
    }

    /// E14: a listed device without a catch-all that is not alive is observed until it is,
    /// unless a reason that does not depend on the device rules it out (every reason before
    /// `.notAlive` passed; opted out, given up). A dead device's own facts (tier, kind, stream
    /// count) are not judged: they may read differently until it is alive again, and the
    /// reconcile its return triggers judges them. Any other device without one is not observed.
    /// A failed build that settles did not fail for good when the device is not alive now.
    private func updateAliveWatch(_ output: CatchAllOutput, _ reason: CatchAllPlan.Ineligibility?) {
        if reason == .notAlive { noteNotUsableWhileSettling(output.uid) }
        if reason == .notAlive, !env.excludedDeviceUIDs.contains(output.uid), !givenUp.contains(output.id) {
            observeAlive(output.uid, output.id)
        } else {
            stopObservingAlive(output.uid)
        }
    }

    /// IsAlive of an observed device changed, or the read after registering found it alive. A
    /// dormant catch-all is rebuilt once the device is alive (a retiring one is left alone); a
    /// device without one is reconciled, which builds it.
    private func aliveChanged(_ uid: String, _ id: AudioDeviceID) {
        guard isStarted, aliveWatches[uid]?.id == id else { return }
        if let device = devices[uid] {
            checkDevice(device)
            return
        }
        guard deviceUsable(uid, id) else { return }
        logger.notice("Device \(id) for \(uid, privacy: .public) is alive; reconciling")
        reconcile()
    }

    /// The 2 s check runs only while some catch-all is dormant.
    private func scheduleDormantCheck() {
        guard dormantCheckAction == nil, isStarted, devices.values.contains(where: { $0.phase == .dormant }) else { return }
        dormantCheckAction = env.clock.schedule(after: Self.dormantCheckInterval) { [weak self] in
            self?.runDormantCheck()
        }
    }

    private func stopDormantCheckIfIdle() {
        guard !devices.values.contains(where: { $0.phase == .dormant }) else { return }
        dormantCheckAction?.cancel()
        dormantCheckAction = nil
    }

    /// Reads each dormant device's listed ID and alive state again: alive rebuilds, a new ID
    /// moves the observation, a UID no longer listed is ended by the reconcile.
    private func runDormantCheck() {
        dormantCheckAction = nil
        for device in devices.values.sorted(by: { $0.uid < $1.uid }) where device.phase == .dormant {
            checkDevice(device)
        }
        scheduleDormantCheck()
    }

    // MARK: Counting, backoff and the breaker (§16.6, E14)

    /// Counts a failure: an IO failure toward give-up for its device ID only, a build failure
    /// and a blocked run queue toward the breaker. A give-up counts once toward the breaker, so
    /// a device that returns under a new ID (a TV power cycle) can get a catch-all again before
    /// the breaker ends it for the session. Called only for failures that count: a build or
    /// rebuild failure or an IO failure (once per aggregate) on a device still alive under its
    /// ID once it settled, a blocked run queue (once per episode). Never for G, a device that
    /// is not alive, an unreadable process list or a push failure by itself.
    /// True when it gave the device up or opened the breaker: R follows instead of what the
    /// caller would do next.
    @discardableResult
    private func noteFailure(_ uid: String, _ failure: CatchAllFailure, deviceID: AudioDeviceID? = nil) -> Bool {
        let now = env.clock.now
        logger.error("Catch-all on \(uid, privacy: .public): counted failure (\(failure.rawValue, privacy: .public))")
        emit(.failure(uid: uid, failure))
        guard failure == .ioFailed else { return countTowardBreaker(now) }
        guard let deviceID else { return false }
        let times = (ioFailureTimes[deviceID] ?? []).filter { now - $0 < Self.giveUpWindow } + [now]
        guard times.count >= Self.giveUpCount else {
            ioFailureTimes[deviceID] = times
            return false
        }
        ioFailureTimes[deviceID] = nil
        giveUp(uid, deviceID, "\(times.count) IO failures within \(Int(Self.giveUpWindow)) s")
        queueRetirement(uid, .givenUp)
        countTowardBreaker(now)
        return true
    }

    /// True when this count opened the breaker.
    @discardableResult
    private func countTowardBreaker(_ now: Double) -> Bool {
        failureTimes = failureTimes.filter { now - $0 < Self.breakerWindow } + [now]
        guard failureTimes.count >= Self.breakerCount else { return false }
        openBreaker(failureTimes.count)
        return true
    }

    /// The device ID gets no catch-all for the rest of the session (`CatchAllPlan` makes it
    /// ineligible); a new ID under the same UID does. A give-up after the last backoff step adds
    /// no count toward the breaker: the failure before it counted already, if it counts at all.
    private func giveUp(_ uid: String, _ id: AudioDeviceID, _ why: String) {
        guard givenUp.insert(id).inserted else { return }
        logger.error("Catch-all on \(uid, privacy: .public): device \(id) given up for this session (\(why, privacy: .public))")
        emit(.givenUp(uid: uid, deviceID: id))
    }

    /// `affectsAudio` is false from here, so the gate taps every app. Every live or dormant
    /// catch-all retires (R, each in the coordinator's turn; retirement holds still apply), and
    /// nothing is built or rebuilt for the rest of the session: pending rebuilds, deferrals,
    /// backoffs and the observation of devices without a catch-all are dropped (a failure that
    /// settles later counts nothing).
    private func openBreaker(_ count: Int) {
        guard !breakerOpen else { return }
        breakerOpen = true
        logger.fault("Catch-all breaker open: \(count) failures within \(Int(Self.breakerWindow / 60)) min; per-app taps for the rest of the session")
        emit(.breakerOpened)
        pendingRebuilds = [:]
        for device in devices.values {
            cancelRebuildDeferral(device)
            device.rebuildAgain = nil
        }
        for uid in backoffs.keys {
            backoffs[uid]?.timer?.cancel()
            backoffs[uid]?.timer = nil
        }
        aliveWatches = aliveWatches.filter { devices[$0.key]?.phase == .dormant }
        for device in devices.values.sorted(by: { $0.uid < $1.uid }) where device.phase == .live || device.phase == .dormant {
            queueRetirement(device.uid, .breaker)
        }
    }

    /// E14: the next build on `uid` waits 5 s, then 30 s, then 120 s after successive
    /// failures; the one after the 120 s step gives the listed ID up. One timer reconciles
    /// when the wait ends; `elapsed` of it passed since the failure already.
    private func backOff(_ uid: String, deviceID: AudioDeviceID, after cause: String, elapsed: Double = 0) {
        guard !breakerOpen else { return }
        var backoff = backoffs[uid] ?? Backoff()
        backoff.timer?.cancel()
        guard backoff.step < Self.backoffDelays.count else {
            backoffs[uid] = nil
            giveUp(uid, deviceID, "\(cause) after the last backoff step")
            return
        }
        let delay = Self.backoffDelays[backoff.step]
        backoff.step += 1
        backoff.timer = env.clock.schedule(after: max(0, delay - elapsed)) { [weak self] in self?.backoffEnded(uid) }
        backoffs[uid] = backoff
        logger.error("Catch-all on \(uid, privacy: .public): \(cause, privacy: .public); the next build waits \(delay, format: .fixed(precision: 0)) s")
        emit(.backoff(uid: uid, seconds: delay))
    }

    private func backoffEnded(_ uid: String) {
        backoffs[uid]?.timer = nil
        reconcile()
    }

    /// A catch-all on the device went live: once it has stayed live 10 min, the device's
    /// backoff starts over.
    private func noteLive(_ device: CatchAllDevice) {
        cancelBackoffReset(device)
        guard backoffs[device.uid] != nil else { return }
        device.backoffReset = env.clock.schedule(after: Self.backoffResetTime) { [weak self, weak device] in
            guard let self, let device, self.devices[device.uid] === device, device.phase == .live else { return }
            device.backoffReset = nil
            self.backoffs[device.uid] = nil
            self.logger.notice("Catch-all on \(device.uid, privacy: .public) live for \(Int(Self.backoffResetTime / 60)) min; its backoff starts over")
        }
    }

    private func cancelBackoffReset(_ device: CatchAllDevice) {
        device.backoffReset?.cancel()
        device.backoffReset = nil
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
    /// retiring is left to that, which its own watchdog bounds, without a fault, and so is a
    /// dormant one, which the device bounds (`isApplied`). A device is not judged yet while the
    /// process list is unreadable (up to `unreadableListGrace` past the watchdog) or while a
    /// push the wait depends on is younger than its margin (grow: any push, G; shrink: one that
    /// removed exclusions, S). A wait that still waits is judged again later, so every wait
    /// ends in bounded time, apart from a shrink on a device that stays dormant.
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

    /// A rebuild of the device is in progress, queued or deferred, or a failure on it settles,
    /// whose end may rebuild it (`failureSettled`).
    private func awaitsRebuild(_ device: CatchAllDevice) -> Bool {
        isRebuilding(device) || failureSettles[device.uid] != nil
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
    /// Starts the device's backoff over once the catch-all has stayed live 10 min.
    var backoffReset: CatchAllScheduledAction?
    /// It retires for a failure that settled and backed off already (`failureSettled`), so R4
    /// backs off no further.
    var backoffSettles = false
    /// Generations a claim change gave the dormant catch-all only because its rebuild was
    /// underway or a failure on it settled, for a tap that plays elsewhere (`alters`): their
    /// shrink waits end once neither is left and the device is still dormant (`isApplied`).
    /// Cleared at a takeover, after which they resolve against the new catch-all.
    var shrinksForRebuild: Set<UInt64> = []

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
/// holds. The format hold (E15) comes later.
nonisolated private enum CatchAllHoldReason: Hashable {
    /// A new catch-all until its list covers every claim and has applied (E1).
    case initialList
    /// A rebuilt catch-all until it takes over from the one it replaces (E).
    case rebuild
    /// From R3 on; nothing ends it.
    case retirement
    /// The device is listed but not alive (E12); ends when a rebuild's new catch-all attaches.
    case dormant
}

/// E14: how many backoff steps the device has taken, and the wait that runs.
private struct Backoff {
    var step = 0
    /// Reconciles when the wait ends; nil while no wait runs.
    var timer: CatchAllScheduledAction?
}

/// A failed build, rebuild or rebuilt catch-all whose count, backoff and R wait until it settled.
private struct FailureSettle {
    /// The listed ID at the failure; nothing counts if the device is not alive under it then.
    let deviceID: AudioDeviceID
    /// It also counts toward the breaker (a failed build), not only backs off.
    var countsBuild: Bool
    let cause: String
    /// The reason of a failed rebuild whose old catch-all serves meanwhile: it retires once the
    /// failure stood.
    var failedRebuild: CatchAllRebuildReason?
    /// The device was found not usable meanwhile (an HDMI link that renegotiates at wake): the
    /// failure did not stand, whatever the device reads at the end.
    var diedMeanwhile = false
    let check: CatchAllScheduledAction
}

/// An IsAlive observation (E12) of one listed device ID, until the token is released.
private struct AliveWatch {
    let id: AudioDeviceID
    let token: AnyObject
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
    /// The device's record of `outgoing` at the new one's attach, put back if the new one fails
    /// before it takes over.
    var outgoingState: OutgoingState?
    /// The new catch-all cannot take over (a push to it failed, or its watchdog fired): R follows.
    var failed = false

    var isWaiting: Bool {
        if case .waiting = stage { return true }
        return false
    }
}

/// What a device records about the catch-all in service (`CatchAllDevice`), kept for the one a
/// rebuild replaces while the new one waits to take over.
private struct OutgoingState {
    let attachedAt: Double
    let deviceID: AudioDeviceID
    let settledGeneration: UInt64
    let pushes: [PushRecord]
    let listUnconfirmed: Bool
    let initialEscalated: Bool
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
    /// A detach timeout counts toward the breaker (R, E and a retirement in observe; not other
    /// G, a device that went dormant, nor a rebuilt catch-all that failed before it took over).
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
