// FineTune/Audio/CatchAll/CatchAllCoordinating.swift
import AudioToolbox
import Foundation

// MARK: - Types shared with the engine and the decorator

/// Where a device's catch-all is in its life (design §16.4).
nonisolated enum CatchAllPhase: Sendable, Equatable {
    /// Being built on main; not attached, no pushes.
    case building
    /// Attached to the run control and pushed to.
    case live
    /// The device is listed but not alive: held, detached, resources kept (§16.3 E12).
    case dormant
    /// Coverage is ending (§16.3 E13); `caHeld` once its output is zeroed.
    case retiring(caHeld: Bool)

    var isRetiring: Bool {
        if case .retiring = self { return true }
        return false
    }
}

/// What a handover waits for after a claim change: `.grow` after processes were excluded
/// (margin G and two IO callbacks), `.shrink` after they were un-excluded (margin S).
nonisolated enum ApplyDirection: Sendable, Equatable {
    case grow
    case shrink
}

/// Per catch-all device, the generation of its exclusion list a handover waits for.
nonisolated struct ApplyTicket: Sendable, Hashable {
    var generations: [String: UInt64]

    var devices: Set<String> { Set(generations.keys) }
}

/// A per-app tap that registers what it holds (the decorator, `CatchAllAwareTap`).
@MainActor
protocol CatchAllClaimOwner: AnyObject {
    /// For `onClaimsVoided` (E20).
    var appPID: pid_t { get }
    /// The UUIDs of its live Core Audio taps, checked after a service restart (E20).
    var tapUUIDs: [UUID] { get }
    /// The tap's output UIDs; retirement tickets are keyed on them.
    var targets: Set<String> { get }
}

/// The engine's and the decorator's view of the catch-alls (design §16.4).
@MainActor
protocol CatchAllCoordinating: AnyObject {
    /// False only for the Noop: the engine does not wrap taps.
    var isEnabled: Bool { get }
    /// Mode on and breaker closed; no phase involved.
    var affectsAudio: Bool { get }
    /// Devices whose catch-all is building, live or dormant (input for P5).
    var catchAllDeviceUIDs: Set<String> { get }
    func phase(_ uid: String) -> CatchAllPhase?
    /// Live or dormant, in observe as in on.
    func isLive(_ uid: String) -> Bool
    /// `affectsAudio && isLive(uid)`.
    func covers(_ uid: String) -> Bool
    /// C9: these processes play to a device other than `uid` (settle rule, §16.2).
    func playsElsewhere(_ processes: [AudioObjectID], target uid: String) -> Bool
    /// The cached Devices of these processes name `uid` or a device that is not plain (R2).
    func mayPlay(_ processes: [AudioObjectID], on uid: String) -> Bool
    /// The gate's decision for an app, logged when it changes.
    func noteDecision(_ app: AudioApp, target uid: String, _ decision: TapDecision)
    /// A routing or default change: the `from` devices count as D-like for 2 s (C9).
    func noteRouting(from previousUIDs: Set<String>, to targetUID: String)
    /// Synchronous, R2; true when an absent app was routed to the device.
    var onCoverageWillEnd: ((String) -> Bool)? { get set }
    /// Runs in the coordinator's next turn, after a pending reconcile.
    var onCoverageMayHaveChanged: (() -> Void)? { get set }
    /// Fires `onCoverageMayHaveChanged` in the next turn.
    func requestReevaluation()
    /// E20: recreate the taps of these processes.
    var onClaimsVoided: ((Set<pid_t>) -> Void)? { get set }
    /// Listening session only.
    var onEvent: ((CatchAllEvent) -> Void)? { get set }
    func start()
    func stop()
    /// Runs in the coordinator's next turn.
    func reconcile()
    func refreshGains()
    /// The processes FineTune lists as apps (E3).
    func appsChanged(_ apps: [AudioApp])
    func deviceListRefreshed()
    func deviceGainChanged(_ deviceID: AudioDeviceID)
    /// E15, from the engine's format guard: the device's building or live catch-all is held at
    /// once (covered audio silent, never loud) until `formatUnchanged`; until the takeover of a
    /// catch-all built after `formatChanged`; until any takeover of the coordinator's own
    /// rebuild once it ignored `formatUnchanged`; or until dormancy, R or G. A 2 s watchdog ends
    /// a hold that neither of the other two calls followed, and does not run while a rebuild
    /// `formatChanged` asked for runs. A dormant or retiring catch-all is not held.
    func formatChanging(uid: String)
    /// Ends the format hold, unless the coordinator's own rebuild of the device runs: building
    /// and attaching an aggregate can make the engine's guard cancel, and that rebuild's
    /// takeover then ends the hold.
    func formatUnchanged(uid: String)
    /// Rebuilds the device's catch-all make before break, so its tap and aggregate follow the
    /// new stream format; a rebuild that runs already is followed by another. Returns once a
    /// catch-all built after the change took over, the rebuild failed (R, a failure that
    /// settles, dormant, G, `stop()`) or a bound passed. Returns at once before `start()`, after
    /// the breaker, without a catch-all, for a retiring one or one whose retirement is queued,
    /// for a dormant one (unless its rebuild builds) and while a failure on the device settles.
    /// Never builds inside the call.
    func formatChanged(uid: String) async

    // Decorator only

    /// The devices whose ticket would carry the change if `owner`'s claim became `proposed`: a
    /// live catch-all whose list changes, a building one whose list loses processes, and in
    /// mode on a dormant one whose list loses processes when it is among the owner's targets,
    /// its rebuild is requested, postponed or building, or a failure on it settles (a shrink on
    /// it waits for its rebuild, R or G, or, for a tap on another device, until the device
    /// stays dormant after all).
    func changedDevices(owner: ObjectIdentifier, proposed: Claim) -> Set<String>
    /// nil: no list changed and no target is retiring.
    func setClaim(_ owner: any CatchAllClaimOwner, _ claim: Claim) -> ApplyTicket?
    func removeClaim(_ owner: ObjectIdentifier) -> ApplyTicket?
    /// Start stopped catch-alls on `uids` now if one of `processes` plays (before a shrink).
    func prepareInclusion(of processes: [AudioObjectID], on uids: Set<String>)
    func waitApplied(_ ticket: ApplyTicket, _ direction: ApplyDirection) async
    /// Some target is in `.retiring(caHeld: false)`.
    func takesRetirementHold(targets: Set<String>) -> Bool
    func processIsLive(_ process: AudioObjectID) -> Bool
    func isRunningOutput(_ process: AudioObjectID) -> Bool
}

// MARK: - Noop

/// Mode off: no catch-all, no decorator; every call returns today's answer at once.
@MainActor
final class NoopCatchAllCoordinator: CatchAllCoordinating {
    let isEnabled = false
    let affectsAudio = false
    var catchAllDeviceUIDs: Set<String> { [] }
    var onCoverageWillEnd: ((String) -> Bool)?
    var onCoverageMayHaveChanged: (() -> Void)?
    var onClaimsVoided: ((Set<pid_t>) -> Void)?
    var onEvent: ((CatchAllEvent) -> Void)?

    func phase(_ uid: String) -> CatchAllPhase? { nil }
    func isLive(_ uid: String) -> Bool { false }
    func covers(_ uid: String) -> Bool { false }
    func playsElsewhere(_ processes: [AudioObjectID], target uid: String) -> Bool { false }
    func mayPlay(_ processes: [AudioObjectID], on uid: String) -> Bool { false }
    func noteDecision(_ app: AudioApp, target uid: String, _ decision: TapDecision) {}
    func noteRouting(from previousUIDs: Set<String>, to targetUID: String) {}
    func requestReevaluation() {}
    func start() {}
    func stop() {}
    func reconcile() {}
    func refreshGains() {}
    func appsChanged(_ apps: [AudioApp]) {}
    func deviceListRefreshed() {}
    func deviceGainChanged(_ deviceID: AudioDeviceID) {}
    func formatChanging(uid: String) {}
    func formatUnchanged(uid: String) {}
    func formatChanged(uid: String) async {}
    func changedDevices(owner: ObjectIdentifier, proposed: Claim) -> Set<String> { [] }
    func setClaim(_ owner: any CatchAllClaimOwner, _ claim: Claim) -> ApplyTicket? { nil }
    func removeClaim(_ owner: ObjectIdentifier) -> ApplyTicket? { nil }
    func prepareInclusion(of processes: [AudioObjectID], on uids: Set<String>) {}
    func waitApplied(_ ticket: ApplyTicket, _ direction: ApplyDirection) async {}
    func takesRetirementHold(targets: Set<String>) -> Bool { false }
    func processIsLive(_ process: AudioObjectID) -> Bool { false }
    func isRunningOutput(_ process: AudioObjectID) -> Bool { false }
}

// MARK: - Environment

/// An output FineTune lists.
nonisolated struct CatchAllOutput: Sendable, Equatable {
    var uid: String
    var id: AudioDeviceID
}

/// What the coordinator uses of `CatchAllRunControl`, so tests drive it without a queue.
nonisolated protocol CatchAllRunControlling: AnyObject, Sendable {
    var onRebuild: (@Sendable (String, AudioDeviceID, CatchAllRunLogic.RebuildReason) -> Void)? { get set }
    var onServiceRestarted: (@Sendable () -> Void)? { get set }
    var onDevicesChanged: (@MainActor @Sendable ([AudioObjectID: ProcessDeviceReport]) -> Void)? { get set }
    var onProcessListChanged: (@MainActor @Sendable () -> Void)? { get set }
    func start()
    @discardableResult func stop() -> Bool
    func attach(_ handle: CatchAllIOHandle, deviceID: AudioDeviceID, excluded: Set<AudioObjectID>)
    func detach(_ handle: CatchAllIOHandle) async -> Bool
    /// Runs `action` on the run queue after the work queued so far, e.g. a detach that timed out.
    func afterQueuedWork(_ action: @escaping @Sendable () -> Void)
    func setExcluded(_ handle: CatchAllIOHandle, _ excluded: Set<AudioObjectID>)
    func prepareInclusion(_ processes: Set<AudioObjectID>, on uids: Set<String>)
    func setListed(_ processes: Set<AudioObjectID>)
}

extension CatchAllRunControl: CatchAllRunControlling {}

/// Time and timers of the coordinator, injected so tests run on a manual clock.
@MainActor
protocol CatchAllClock: AnyObject {
    /// Seconds on a monotonic clock.
    var now: Double { get }
    /// Runs `action` on main after `delay` seconds; 0 runs it in a later main-actor turn,
    /// never inside this call.
    @discardableResult
    func schedule(after delay: Double, _ action: @escaping @MainActor @Sendable () -> Void) -> CatchAllScheduledAction
}

/// Cancels a scheduled action that has not run yet.
@MainActor
final class CatchAllScheduledAction {
    private var cancelAction: (@MainActor () -> Void)?

    init(cancel: @escaping @MainActor () -> Void) {
        cancelAction = cancel
    }

    func cancel() {
        cancelAction?()
        cancelAction = nil
    }
}

/// Everything the coordinator reads from or drives in the system, injected so unit tests run
/// without Core Audio. `CatchAllCoordinator.live` binds the real pieces.
@MainActor
struct CatchAllEnvironment {
    var mode: CatchAllMode
    var excludedDeviceUIDs: Set<String> = []
    var growMargin: TimeInterval = CatchAllSettings.defaultGrowMargin
    var shrinkMargin: TimeInterval = CatchAllSettings.defaultShrinkMargin
    var backend: any CatchAllBackend
    var runControl: any CatchAllRunControlling
    var clock: any CatchAllClock
    /// A fresh read of the process object list; nil when it could not be read.
    var processList: @MainActor () -> [AudioObjectID]?
    /// FineTune's own process object, `.unknown` while it has none.
    var selfObject: @MainActor () -> AudioObjectID
    /// The processes among these that belong to other human users (#418).
    var foreign: @MainActor (Set<AudioObjectID>) -> Set<AudioObjectID>
    /// A read of a process's IsRunningOutput.
    var isRunningOutput: @MainActor (AudioObjectID) -> Bool
    /// The outputs FineTune lists (`AudioDeviceProviding.outputDevices`).
    var listedOutputs: @MainActor () -> [CatchAllOutput]
    var isAlive: @MainActor (AudioDeviceID) -> Bool
    var tier: @MainActor (AudioDeviceID) -> VolumeControlTier
    var isAggregate: @MainActor (AudioDeviceID) -> Bool
    var isVirtual: @MainActor (AudioDeviceID) -> Bool
    var outputStreamCount: @MainActor (AudioDeviceID) -> Int
    /// The device's software gain (`outputProcessingGain`: the volume, 0 when muted, the
    /// persisted level for an ID without state yet, #375).
    var gain: @MainActor (AudioDeviceID) -> Float
    var permissionAuthorized: @MainActor () -> Bool
    var sessionActive: @MainActor () -> Bool = { true }
    /// Calls `handler` on main when the device's IsAlive changes, for as long as the returned
    /// token lives (E12).
    var observeAlive: @MainActor (AudioDeviceID, @escaping @MainActor @Sendable () -> Void) -> AnyObject
    /// Whether a tap with this UID exists in the current Core Audio daemon (E20).
    var tapExists: @MainActor (UUID) -> Bool
}
