// FineTune/Audio/CatchAll/PerAppTapPolicy.swift
import Foundation

/// What decides whether an app routed in single mode to an output D gets a per-app tap
/// (rule C, design §16.2). The engine reads each fact; the policy only combines them.
nonisolated struct AppTapFacts: Sendable, Equatable {
    /// C1: D's catch-all is live or dormant (`isLive(D)`), in observe as in on. Whether it
    /// affects audio is the caller's check (`affectsAudio`), so the decision does not depend
    /// on the mode and observe logs what mode on would do.
    var targetCovered: Bool
    /// C2: the app plays to one device.
    var singleMode: Bool
    /// C3: the persisted routing follows the default. Explicit routing gets a tap, also when
    /// it names D, because only tapped apps move back on reconnect.
    var followsDefaultPersisted: Bool
    /// C4: volume × boost.
    var appGain: Float
    /// C5
    var muted: Bool
    /// C6: see `PerAppTapPolicy.isEQActive`.
    var eqActive: Bool
    /// C7: see `PerAppTapPolicy.isAutoEQOnTarget`.
    var autoEQOnTarget: Bool
    /// C8: loudness compensation or equalization.
    var loudnessOn: Bool
    /// C9: the app's process objects play to a device other than D. Computed only when
    /// `targetCovered`.
    var playsElsewhere: Bool
}

/// Why an app gets a per-app tap.
nonisolated enum TapReason: String, Sendable, CaseIterable {
    case noCatchAll
    case multiDevice
    case explicitRouting
    case appGain
    case muted
    case eq
    case autoEQ
    case loudness
    case playsElsewhere
}

nonisolated enum TapDecision: Sendable, Equatable {
    case coveredByCatchAll
    case tap(Set<TapReason>)
}

/// Rule C: an app on a covered output gets no tap unless it needs per-app processing or
/// plays elsewhere. Pure; every reason that applies is reported, for the decision log.
nonisolated enum PerAppTapPolicy {

    /// How far volume × boost may be from 1 and still count as unity (C4).
    static let unityGainTolerance: Float = 0.001

    static func decide(_ facts: AppTapFacts) -> TapDecision {
        var processing: Set<TapReason> = []
        if !facts.singleMode { processing.insert(.multiDevice) }
        if !facts.followsDefaultPersisted { processing.insert(.explicitRouting) }
        if !isUnityGain(facts.appGain) { processing.insert(.appGain) }
        if facts.muted { processing.insert(.muted) }
        if facts.eqActive { processing.insert(.eq) }
        if facts.autoEQOnTarget { processing.insert(.autoEQ) }
        if facts.loudnessOn { processing.insert(.loudness) }

        guard facts.targetCovered else { return .tap(processing.union([.noCatchAll])) }
        if facts.playsElsewhere { processing.insert(.playsElsewhere) }
        return processing.isEmpty ? .coveredByCatchAll : .tap(processing)
    }

    // MARK: - Facts the engine reads

    /// C4 input: the per-app gain the tap would apply.
    static func appGain(volume: Float, boost: BoostLevel) -> Float {
        volume * boost.rawValue
    }

    /// C4: false for a gain that is not finite.
    static func isUnityGain(_ gain: Float) -> Bool {
        abs(gain - 1) <= unityGainTolerance
    }

    /// C6: a disabled EQ, or one with every band at 0 dB, needs no tap.
    static func isEQActive(_ eq: EQSettings) -> Bool {
        eq.isEnabled && !eq.isFlat
    }

    /// C7: the target supports AutoEQ and its selection is enabled, whether or not the
    /// profile is cached yet (the tap gets it once it is loaded).
    static func isAutoEQOnTarget(deviceSupportsAutoEQ: Bool, selection: AutoEQSelection?) -> Bool {
        deviceSupportsAutoEQ && selection?.isEnabled == true
    }
}
