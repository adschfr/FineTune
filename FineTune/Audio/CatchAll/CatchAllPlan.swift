// FineTune/Audio/CatchAll/CatchAllPlan.swift
import AudioToolbox

/// How the catch-all runs. `off` keeps today's behavior exactly (no catch-all, no decorator).
/// `observe` builds catch-alls unmuted with silent output to measure without audible effect.
nonisolated enum CatchAllMode: String, Sendable, CaseIterable {
    case off
    case observe
    case on
}

/// Pure decisions of the catch-all: exclusion lists, when a per-app handover must hold its
/// output, which devices get a catch-all. No Core Audio access, so everything is testable.
nonisolated enum CatchAllPlan {

    /// The exclusion list of the catch-all on `deviceUID`: FineTune itself, other users'
    /// processes (#418) and every process a live per-app tap holds on that device. Only
    /// process objects that still exist are listed, so a recycled ID never inherits an
    /// exclusion. Sorted for stable comparison with the applied list.
    static func exclusions(
        deviceUID: String,
        selfObject: AudioObjectID,
        foreign: Set<AudioObjectID>,
        claims: [Claim],
        live: Set<AudioObjectID>
    ) -> [AudioObjectID] {
        var excluded: Set<AudioObjectID> = [selfObject]
        excluded.formUnion(foreign.intersection(live))
        for claim in claims where claim.covers(deviceUID) {
            excluded.formUnion(claim.processes.intersection(live))
        }
        return excluded.sorted()
    }

    /// Catch-all devices whose exclusion list changes when a tap's claim goes from `before`
    /// to `after`.
    static func changedDevices(before: Claim, after: Claim, catchAllUIDs: Set<String>) -> Set<String> {
        catchAllUIDs.filter { uid in
            let held: (Claim) -> Set<AudioObjectID> = { $0.covers(uid) ? $0.processes : [] }
            return held(before) != held(after)
        }
    }

    /// Whether a per-app tap must hold its output during a handover: only if a changed
    /// catch-all device is one of its targets (its output UIDs, old and new during a switch).
    /// Doubling on a device the tap does not play to is inaudible (I2, design §16.4).
    static func holds(changed: Set<String>, targets: Set<String>) -> Bool {
        !changed.isDisjoint(with: targets)
    }

    /// A stream tap captures only its device. While catch-alls exist, a per-app tap may use a
    /// stream source only if that is the single catch-all device; otherwise it must use the
    /// mixdown, so its claim covers every catch-all device and default switches never
    /// change a catch-all's exclusion list (rule P5).
    static func allowsStreamTap(candidate: String, catchAllDevices: Set<String>) -> Bool {
        catchAllDevices.isEmpty || catchAllDevices == [candidate]
    }

    // MARK: - Eligibility

    /// What decides whether an output gets a catch-all.
    struct DeviceFacts: Sendable {
        var mode: CatchAllMode
        var permissionAuthorized: Bool
        var sessionActive: Bool
        var selfObjectKnown: Bool
        var breakerClosed: Bool
        var listedAndAlive: Bool
        var tier: VolumeControlTier
        var isAggregate: Bool
        var isVirtual: Bool
        var outputStreamCount: Int
        var optedOut: Bool
        var givenUp: Bool
    }

    enum Ineligibility: String, Sendable, Equatable {
        case modeOff
        case noPermission
        case sessionInactive
        case selfObjectUnknown
        case breakerOpen
        case notAlive
        case hasHardwareVolume
        case aggregate
        case virtualDevice
        case notSingleStream
        case optedOut
        case givenUp
    }

    /// nil when the device is eligible, otherwise the first reason it is not.
    static func ineligibility(_ facts: DeviceFacts) -> Ineligibility? {
        if facts.mode == .off { return .modeOff }
        if !facts.permissionAuthorized { return .noPermission }
        if !facts.sessionActive { return .sessionInactive }
        if !facts.selfObjectKnown { return .selfObjectUnknown }
        if !facts.breakerClosed { return .breakerOpen }
        if !facts.listedAndAlive { return .notAlive }
        if facts.tier != .software { return .hasHardwareVolume }
        if facts.isAggregate { return .aggregate }
        if facts.isVirtual { return .virtualDevice }
        if facts.outputStreamCount != 1 { return .notSingleStream }
        if facts.optedOut { return .optedOut }
        if facts.givenUp { return .givenUp }
        return nil
    }
}
