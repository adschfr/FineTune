// FineTuneTests/FakeCatchAllCoordinator.swift
//
// A CatchAllCoordinating fake for engine and decorator tests: records every call, answers
// from configurable state, and fires onCoverageMayHaveChanged in the next main-actor turn
// after requestReevaluation, like the real coordinator. Plus a fake claim owner.

import AudioToolbox
import Foundation
@testable import FineTune

@MainActor
final class FakeCatchAllCoordinator: CatchAllCoordinating {
    /// Every call in order, e.g. "setClaim 7 [11] all", "wait grow".
    private(set) var calls: [String] = []

    var isEnabled = true
    var affectsAudio = true
    var catchAllDeviceUIDs: Set<String> = []
    var phases: [String: CatchAllPhase] = [:]
    /// Devices whose catch-all is live or dormant.
    var liveUIDs: Set<String> = []
    /// Processes that play elsewhere than any target (C9).
    var elsewhereProcesses: Set<AudioObjectID> = []
    /// Per device, the processes whose cached Devices may play there.
    var mayPlayProcesses: [String: Set<AudioObjectID>] = [:]
    var runningOutput: Set<AudioObjectID> = []
    var deadProcesses: Set<AudioObjectID> = []
    /// What `changedDevices` returns.
    var changed: Set<String> = []
    /// Targets in `.retiring(caHeld: false)`.
    var retiringTargets: Set<String> = []
    /// What `setClaim` and `removeClaim` return; nil means no list changed.
    var ticket: ApplyTicket?
    /// When false, waits stay pending until `completeWaits()`.
    var appliesAtOnce = true
    private(set) var claims: [ObjectIdentifier: Claim] = [:]
    private var pendingWaits: [CheckedContinuation<Void, Never>] = []
    private var reevaluationScheduled = false

    var onCoverageWillEnd: ((String) -> Bool)?
    var onCoverageMayHaveChanged: (() -> Void)?
    var onClaimsVoided: ((Set<pid_t>) -> Void)?
    var onEvent: ((CatchAllEvent) -> Void)?

    var pendingWaitCount: Int { pendingWaits.count }

    func phase(_ uid: String) -> CatchAllPhase? { phases[uid] }
    func isLive(_ uid: String) -> Bool { liveUIDs.contains(uid) }
    func covers(_ uid: String) -> Bool { affectsAudio && isLive(uid) }

    func playsElsewhere(_ processes: [AudioObjectID], target uid: String) -> Bool {
        processes.contains { elsewhereProcesses.contains($0) }
    }

    func mayPlay(_ processes: [AudioObjectID], on uid: String) -> Bool {
        processes.contains { mayPlayProcesses[uid]?.contains($0) == true }
    }

    func noteDecision(_ app: AudioApp, target uid: String, _ decision: TapDecision) {
        let text = switch decision {
        case .coveredByCatchAll: "covered"
        case .tap(let reasons): "tap " + reasons.map(\.rawValue).sorted().joined(separator: ",")
        }
        calls.append("decision \(app.id) \(uid) \(text)")
    }

    func noteRouting(from previousUIDs: Set<String>, to targetUID: String) {
        calls.append("routing \(previousUIDs.sorted()) -> \(targetUID)")
    }

    /// Coalesced like the real coordinator: one callback per turn.
    func requestReevaluation() {
        calls.append("requestReevaluation")
        guard !reevaluationScheduled else { return }
        reevaluationScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.reevaluationScheduled = false
            self.onCoverageMayHaveChanged?()
        }
    }

    func start() { calls.append("start") }
    func stop() { calls.append("stop") }
    func reconcile() { calls.append("reconcile") }
    func refreshGains() { calls.append("refreshGains") }
    func appsChanged(_ apps: [AudioApp]) { calls.append("appsChanged \(apps.map(\.id).sorted())") }
    func deviceListRefreshed() { calls.append("deviceListRefreshed") }
    func deviceGainChanged(_ deviceID: AudioDeviceID) { calls.append("gain \(deviceID)") }
    func formatChanging(uid: String) { calls.append("formatChanging \(uid)") }
    func formatUnchanged(uid: String) { calls.append("formatUnchanged \(uid)") }
    func formatChanged(uid: String) async { calls.append("formatChanged \(uid)") }

    func changedDevices(owner: ObjectIdentifier, proposed: Claim) -> Set<String> {
        calls.append("changedDevices \(Self.describe(proposed))")
        return changed
    }

    func setClaim(_ owner: any CatchAllClaimOwner, _ claim: Claim) -> ApplyTicket? {
        claims[ObjectIdentifier(owner)] = claim
        calls.append("setClaim \(owner.appPID) \(Self.describe(claim))")
        return ticket
    }

    func removeClaim(_ owner: ObjectIdentifier) -> ApplyTicket? {
        claims[owner] = nil
        calls.append("removeClaim")
        return ticket
    }

    func prepareInclusion(of processes: [AudioObjectID], on uids: Set<String>) {
        calls.append("prepareInclusion \(processes.sorted()) on \(uids.sorted())")
    }

    func waitApplied(_ ticket: ApplyTicket, _ direction: ApplyDirection) async {
        calls.append("wait \(direction)")
        guard !appliesAtOnce else { return }
        await withCheckedContinuation { pendingWaits.append($0) }
    }

    /// Completes every pending wait.
    func completeWaits() {
        let waits = pendingWaits
        pendingWaits.removeAll()
        for wait in waits { wait.resume() }
    }

    func takesRetirementHold(targets: Set<String>) -> Bool { !targets.isDisjoint(with: retiringTargets) }
    func processIsLive(_ process: AudioObjectID) -> Bool { !deadProcesses.contains(process) }
    func isRunningOutput(_ process: AudioObjectID) -> Bool { runningOutput.contains(process) }

    /// "[11, 12] all", "[11] uid-tv" or "none".
    static func describe(_ claim: Claim) -> String {
        let coverage = switch claim.coverage {
        case .none: "none"
        case .allDevices: "all"
        case .device(let uid): uid
        }
        return "\(claim.processes.sorted()) \(coverage)"
    }
}

/// A claim owner without a tap behind it.
@MainActor
final class FakeClaimOwner: CatchAllClaimOwner {
    var appPID: pid_t
    var tapUUIDs: [UUID]
    var targets: Set<String>

    init(pid: pid_t = 1, targets: Set<String> = ["uid-tv"], tapUUIDs: [UUID] = [UUID()]) {
        appPID = pid
        self.targets = targets
        self.tapUUIDs = tapUUIDs
    }
}
