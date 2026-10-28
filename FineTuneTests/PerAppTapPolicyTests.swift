// FineTuneTests/PerAppTapPolicyTests.swift
//
// Rule C (design §16.2): an app on a covered output gets no per-app tap unless it needs
// per-app processing or plays elsewhere, and every reason that applies is reported. Also the
// pure reads behind C4, C6 and C7.

import Testing
@testable import FineTune

@Suite("Per-app tap policy")
struct PerAppTapPolicyTests {

    /// An app at defaults that follows the default to a covered output.
    private func covered() -> AppTapFacts {
        AppTapFacts(
            targetCovered: true, singleMode: true, followsDefaultPersisted: true, appGain: 1,
            muted: false, eqActive: false, autoEQOnTarget: false, loudnessOn: false,
            playsElsewhere: false
        )
    }

    private func decide(_ change: (inout AppTapFacts) -> Void) -> TapDecision {
        var facts = covered()
        change(&facts)
        return PerAppTapPolicy.decide(facts)
    }

    @Test("An app at defaults on a covered output gets no tap")
    func defaultsCovered() {
        #expect(PerAppTapPolicy.decide(covered()) == .coveredByCatchAll)
    }

    @Test("Each of C2-C9 alone gives a tap with exactly its reason")
    func eachConditionAlone() {
        #expect(decide { $0.singleMode = false } == .tap([.multiDevice]))
        #expect(decide { $0.followsDefaultPersisted = false } == .tap([.explicitRouting]))
        #expect(decide { $0.appGain = 0.5 } == .tap([.appGain]))
        #expect(decide { $0.muted = true } == .tap([.muted]))
        #expect(decide { $0.eqActive = true } == .tap([.eq]))
        #expect(decide { $0.autoEQOnTarget = true } == .tap([.autoEQ]))
        #expect(decide { $0.loudnessOn = true } == .tap([.loudness]))
        #expect(decide { $0.playsElsewhere = true } == .tap([.playsElsewhere]))
    }

    @Test("Without a covering catch-all the app gets a tap with noCatchAll")
    func noCatchAll() {
        #expect(decide { $0.targetCovered = false } == .tap([.noCatchAll]))
        // Processing reasons are reported alongside
        #expect(decide { $0.targetCovered = false; $0.muted = true } == .tap([.noCatchAll, .muted]))
        // C9 is computed only for a covered target, so a stale value is not reported
        #expect(decide { $0.targetCovered = false; $0.playsElsewhere = true } == .tap([.noCatchAll]))
    }

    @Test("C4: unity within 0.001 counts as no gain")
    func unityTolerance() {
        #expect(decide { $0.appGain = 0.9995 } == .coveredByCatchAll)
        #expect(decide { $0.appGain = 1.0005 } == .coveredByCatchAll)
        #expect(decide { $0.appGain = 0.99 } == .tap([.appGain]))
        #expect(decide { $0.appGain = 1.01 } == .tap([.appGain]))
        #expect(decide { $0.appGain = .nan } == .tap([.appGain]))
    }

    @Test("C4: volume 0.5 with boost x2 is unity, the boost alone is not")
    func gainIsVolumeTimesBoost() {
        #expect(PerAppTapPolicy.appGain(volume: 0.5, boost: .x2) == 1)
        #expect(decide { $0.appGain = PerAppTapPolicy.appGain(volume: 0.5, boost: .x2) } == .coveredByCatchAll)
        #expect(decide { $0.appGain = PerAppTapPolicy.appGain(volume: 1, boost: .x2) } == .tap([.appGain]))
        #expect(decide { $0.appGain = PerAppTapPolicy.appGain(volume: 0.25, boost: .x4) } == .coveredByCatchAll)
        #expect(PerAppTapPolicy.isUnityGain(PerAppTapPolicy.appGain(volume: 1, boost: .x1)))
    }

    @Test("C6: EQ counts only when enabled and not flat")
    func eqActive() {
        var gains = Array(repeating: Float(0), count: EQSettings.bandCount)
        gains[3] = 4
        #expect(PerAppTapPolicy.isEQActive(EQSettings(bandGains: gains, isEnabled: true)))
        #expect(!PerAppTapPolicy.isEQActive(EQSettings(isEnabled: true)))
        #expect(!PerAppTapPolicy.isEQActive(EQSettings(bandGains: gains, isEnabled: false)))
        #expect(!PerAppTapPolicy.isEQActive(.flat))

        let flat = PerAppTapPolicy.isEQActive(EQSettings(isEnabled: true))
        let disabled = PerAppTapPolicy.isEQActive(EQSettings(bandGains: gains, isEnabled: false))
        #expect(decide { $0.eqActive = flat } == .coveredByCatchAll)
        #expect(decide { $0.eqActive = disabled } == .coveredByCatchAll)
    }

    @Test("C7: AutoEQ counts only on a supporting device with an enabled selection")
    func autoEQOnTarget() {
        let enabled = AutoEQSelection(profileID: "profile", isEnabled: true)
        let off = AutoEQSelection(profileID: "profile", isEnabled: false)
        #expect(PerAppTapPolicy.isAutoEQOnTarget(deviceSupportsAutoEQ: true, selection: enabled))
        #expect(!PerAppTapPolicy.isAutoEQOnTarget(deviceSupportsAutoEQ: true, selection: off))
        #expect(!PerAppTapPolicy.isAutoEQOnTarget(deviceSupportsAutoEQ: true, selection: nil))

        // A selection on a device without AutoEQ support (the TV) stays covered
        let unsupported = PerAppTapPolicy.isAutoEQOnTarget(deviceSupportsAutoEQ: false, selection: enabled)
        #expect(!unsupported)
        #expect(decide { $0.autoEQOnTarget = unsupported } == .coveredByCatchAll)
    }

    @Test("Explicit routing and multi mode get a tap on a covered output")
    func routingTaps() {
        #expect(decide { $0.singleMode = false; $0.followsDefaultPersisted = false } == .tap([.multiDevice, .explicitRouting]))
    }

    @Test("Every reason that applies is reported")
    func allReasons() {
        func everything(_ facts: inout AppTapFacts) {
            facts.singleMode = false
            facts.followsDefaultPersisted = false
            facts.appGain = 2
            facts.muted = true
            facts.eqActive = true
            facts.autoEQOnTarget = true
            facts.loudnessOn = true
            facts.playsElsewhere = true
        }
        #expect(decide(everything) == .tap(Set(TapReason.allCases).subtracting([.noCatchAll])))
        #expect(decide { everything(&$0); $0.targetCovered = false }
                == .tap(Set(TapReason.allCases).subtracting([.playsElsewhere])))
        #expect(decide { $0.muted = true; $0.loudnessOn = true; $0.playsElsewhere = true }
                == .tap([.muted, .loudness, .playsElsewhere]))
    }
}
