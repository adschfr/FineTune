// FineTune/Audio/CatchAll/CatchAllCoordinator.swift
import AudioToolbox
import Foundation
import os

/// What the coordinator did, for the listening session's event lines (design §16.8).
nonisolated enum CatchAllEvent: Sendable, Equatable {
    /// The device's catch-all entered a phase (`building` when its build starts).
    case phase(uid: String, CatchAllPhase)
    case buildFailed(uid: String, reason: String)
    /// A new catch-all's list covers every claim and has applied: its output is open.
    case released(uid: String)
    case pushed(uid: String, excluded: [AudioObjectID])
    case pushFailed(uid: String, excluded: [AudioObjectID])
    /// I1: these processes were excluded without a claim and were removed from the list.
    case repaired(uid: String, removed: [AudioObjectID])
    case decision(pid: pid_t, uid: String, TapDecision)
    /// C9: the app's processes play to a device other than the catch-all's.
    case playsElsewhere(pid: pid_t, uid: String)
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
    /// The run control runs from the first `start()`; stopping it comes with G (failure handling).
    private var runControlStarted = false
    private var selfObject = AudioObjectID.unknown
    /// Opened by repeated failures (design §16.6, failure handling); closed until then.
    private(set) var breakerOpen = false
    /// Devices given up after repeated IO failures (failure handling).
    private(set) var givenUp: Set<AudioDeviceID> = []

    private var devices: [String: CatchAllDevice] = [:]
    /// One counter per device UID, bumped when a claim change alters its list; kept across
    /// rebuilds so an old ticket never waits for a lower number.
    private var generations: [String: UInt64] = [:]
    private var claims: [ObjectIdentifier: ClaimEntry] = [:]
    private var waiters: [Waiter] = []
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

    // The next-turn task, the flush and the timers
    private var pendingReconcile = false
    private var pendingReevaluation = false
    private var turn: CatchAllScheduledAction?
    private var flushAction: CatchAllScheduledAction?
    private var checkAction: CatchAllScheduledAction?
    private var settleAction: CatchAllScheduledAction?
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

    /// Stops building, the next-turn task and the C9 timers; the gate is not called back
    /// after this, and a build whose wait is running is destroyed when it ends. Ending each
    /// catch-all's coverage (G, bounded by the detach timeout), the bounded run-control stop
    /// and completing the waits come with failure handling. Until then a catch-all lasts until
    /// FineTune exits, which tears it down (H9), and claims, flushes and waits keep working on
    /// it.
    func stop() {
        isStarted = false
        pendingReconcile = false
        pendingReevaluation = false
        turn?.cancel()
        turn = nil
        settleAction?.cancel()
        settleAction = nil
    }

    func reconcile() {
        pendingReconcile = true
        scheduleTurn()
    }

    func requestReevaluation() {
        pendingReevaluation = true
        scheduleTurn()
    }

    /// E12 checks (a new ID or a device that is not alive) come with failure handling; a
    /// refresh never builds inside the device monitor's handler.
    func deviceListRefreshed() {
        _ = listedOutputs()
        reconcile()
    }

    // Format changes (E15) come with failure handling; until then they leave the catch-all as is.
    func formatChanging(uid: String) {}
    func formatUnchanged(uid: String) {}
    func formatChanged(uid: String) async {}

    private func scheduleTurn() {
        // Inside a build's wait or a turn: scheduled when that ends
        guard turn == nil, buildDepth == 0, turnDepth == 0 else { return }
        turn = env.clock.schedule(after: 0) { [weak self] in self?.runTurn() }
    }

    private func runTurn() {
        turn = nil
        // Scheduled before a build began whose wait now runs it: scheduled again when it ends
        guard buildDepth == 0, turnDepth == 0 else { return }
        turnDepth += 1
        defer {
            turnDepth -= 1
            resumeDeferredTurn()
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

    /// A reconcile or re-evaluation requested during a build's wait or a turn runs now that
    /// it ended.
    private func resumeDeferredTurn() {
        guard pendingReconcile || pendingReevaluation else { return }
        scheduleTurn()
    }

    /// Builds a catch-all for every eligible listed device that has none. Ending coverage of
    /// an existing one (G, R, dormant, a new ID) comes with failure handling.
    private func runReconcile() {
        guard isStarted else { return }
        if !selfObject.isValid { selfObject = env.selfObject() }
        var built = false
        for output in listedOutputs().sorted(by: { $0.uid < $1.uid }) {
            // A stop() during an earlier build's wait ends the pass
            guard isStarted else { break }
            let reason = ineligibility(of: output)
            noteEligibility(output.uid, reason)
            guard reason == nil, devices[output.uid] == nil else { continue }
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
            // Backoff and failure counting come with failure handling (design §16.6)
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
        env.runControl.attach(controller.ioHandle, deviceID: controller.deviceID, excluded: Set(exclusions))
        // Claims that changed during the wait are pushed now; the release follows when applied
        scheduleFlush()
        releaseIfApplied()
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
        guard let controller = device.controller, !device.phase.isRetiring else { return }
        controller.setGain(env.gain(device.deviceID))
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
        guard previous != claim else { return nil }
        return claimsChanged(from: before)
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
            // §4.6 failure, step 1: once more with a fresh process list
            if let fresh = readProcesses() { processes = fresh }
            desired = desiredList(for: device.uid, processes)
            if desired == controller.appliedExclusions {
                noteCurrent(device)
            } else if !push(device, desired, desired: desired) {
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

    /// A push failed after its retry. Failure handling rebuilds the catch-all with the desired
    /// list (E), then retires it (R), and its waits complete there (§4.6). Until then the I1
    /// check that ends the flush removes any exclusion left without a claim, and the next
    /// flush tries the list again.
    private func pushStillFails(_ device: CatchAllDevice) {
        logger.error("Catch-all on \(device.uid, privacy: .public): exclusion push failed after its retry")
    }

    /// The applied list already is the current generation's list: it applied with the last push.
    private func noteCurrent(_ device: CatchAllDevice) {
        let generation = generations[device.uid, default: 0]
        if let last = device.pushes.indices.last {
            device.pushes[last].generation = max(device.pushes[last].generation, generation)
        } else {
            device.settledGeneration = max(device.settledGeneration, generation)
        }
    }

    /// Pushes with read-back and records when. A push of the desired list applies the current
    /// generation; any other list (an I1 repair) applies none newer than the last push.
    private func push(_ device: CatchAllDevice, _ list: [AudioObjectID], desired: [AudioObjectID]) -> Bool {
        guard let controller = device.controller else { return false }
        guard controller.push(list) else {
            // The controller logged it
            emit(.pushFailed(uid: device.uid, excluded: list))
            return false
        }
        env.runControl.setExcluded(controller.ioHandle, Set(list))
        let generation = list == desired
            ? generations[device.uid, default: 0]
            : max(device.pushes.last?.generation ?? 0, device.settledGeneration)
        device.pushes.append(PushRecord(generation: generation, time: env.clock.now, callbacks: controller.callbackCount))
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
        guard !isApplied(ticket, direction, now: env.clock.now) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(Waiter(ticket: ticket, direction: direction, continuation: continuation))
            scheduleCheck(now: env.clock.now)
        }
    }

    private func isApplied(_ ticket: ApplyTicket, _ direction: ApplyDirection, now: Double) -> Bool {
        ticket.generations.allSatisfy { uid, generation in
            // Without a catch-all there is nothing to wait for
            guard let device = devices[uid] else { return true }
            guard let controller = device.controller else { return false }
            if generation <= device.settledGeneration { return true }
            guard let record = device.pushes.first(where: { $0.generation >= generation }) else { return false }
            switch direction {
            case .grow: return growState(record, controller, now: now).isApplied
            case .shrink: return now - record.time + Self.tolerance >= env.shrinkMargin
            }
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

    /// Settles pushes, resumes the waits that applied, releases new catch-alls whose list
    /// applied and schedules the next check.
    private func checkWaiters() {
        checkAction?.cancel()
        checkAction = nil
        let now = env.clock.now
        for device in devices.values { settle(device, now: now) }
        var done: [Waiter] = []
        waiters.removeAll { waiter in
            guard isApplied(waiter.ticket, waiter.direction, now: now) else { return false }
            done.append(waiter)
            return true
        }
        releaseIfApplied()
        for waiter in done { waiter.continuation.resume() }
        scheduleCheck(now: now)
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

    private func scheduleCheck(now: Double) {
        checkAction?.cancel()
        checkAction = nil
        guard !waiters.isEmpty || devices.values.contains(where: { $0.holds.contains(.initialList) }) else { return }
        var next: Double?
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
        }
        // Waits for a list not pushed yet are checked by the flush that pushes it
        guard let next else { return }
        checkAction = env.clock.schedule(after: next - now) { [weak self] in self?.checkWaiters() }
    }

    /// Opens a new catch-all's output once it excludes FineTune and every live process a
    /// claim holds on its device, and every push since the build has applied (E1). Other
    /// exclusions double nothing (dead or foreign processes, or ones the I1 check removes),
    /// so they never keep it held.
    private func releaseIfApplied() {
        let pending = devices.values.filter { $0.holds.contains(.initialList) && $0.phase == .live && $0.controller != nil }
        guard !pending.isEmpty, let list = env.processList() else { return }
        let live = Set(list)
        let claims = activeClaims()
        let now = env.clock.now
        for device in pending.sorted(by: { $0.uid < $1.uid }) {
            guard let controller = device.controller else { continue }
            let required = claimed(device.uid, by: claims, live: live).union([selfObject])
            guard required.isSubset(of: controller.appliedExclusions),
                  device.pushes.allSatisfy({ growState($0, controller, now: now).isApplied }) else { continue }
            release(device, from: .initialList)
            logger.notice("Catch-all on \(device.uid, privacy: .public) released: its exclusion list applied")
            emit(.released(uid: device.uid))
        }
    }

    /// Ends one reason to hold; the output opens when none is left.
    private func release(_ device: CatchAllDevice, from reason: CatchAllHoldReason) {
        device.holds.remove(reason)
        guard device.holds.isEmpty else { return }
        device.controller?.release()
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
private final class CatchAllDevice {
    let uid: String
    /// The listed ID (the device monitor's): gain is read and followed by it.
    let deviceID: AudioDeviceID
    var phase: CatchAllPhase = .building
    var controller: CatchAllTapController?
    /// Why its output is held; it opens when this is empty.
    var holds: Set<CatchAllHoldReason> = []
    /// Every generation up to this one applied in both directions.
    var settledGeneration: UInt64 = 0
    /// Pushes that have not applied in both directions, oldest first.
    var pushes: [PushRecord] = []

    init(uid: String, deviceID: AudioDeviceID) {
        self.uid = uid
        self.deviceID = deviceID
    }
}

/// Why a catch-all's output is held. Failure handling adds the format and retirement holds,
/// so ending one never opens an output another still holds.
nonisolated private enum CatchAllHoldReason: Hashable {
    /// A new catch-all until its list covers every claim and has applied (E1).
    case initialList
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
    let ticket: ApplyTicket
    let direction: ApplyDirection
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
