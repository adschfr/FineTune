// FineTuneTests/CatchAllSettingsTests.swift
//
// Catch-all settings live in the fork's defaults domain and default to off; the harness
// runs only for explicitly requested steps. Uses an isolated defaults suite.

import Foundation
import Testing
@testable import FineTune

@Suite("Catch-all settings and harness parsing")
struct CatchAllSettingsTests {

    private func makeDefaults() -> UserDefaults {
        let name = "FineTuneTests-CatchAll-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Mode is off unless set, and an unknown value counts as off")
    func modeDefaultsOff() {
        let defaults = makeDefaults()
        #expect(CatchAllSettings(defaults: defaults).mode == .off)

        defaults.set("loud", forKey: CatchAllSettings.modeKey)
        #expect(CatchAllSettings(defaults: defaults).mode == .off)

        defaults.set("observe", forKey: CatchAllSettings.modeKey)
        #expect(CatchAllSettings(defaults: defaults).mode == .observe)
        defaults.set("on", forKey: CatchAllSettings.modeKey)
        #expect(CatchAllSettings(defaults: defaults).mode == .on)
    }

    @Test("Excluded devices come from a string array")
    func excludedDevices() {
        let defaults = makeDefaults()
        #expect(CatchAllSettings(defaults: defaults).excludedDeviceUIDs.isEmpty)
        defaults.set(["uid-tv", "uid-hdmi2"], forKey: CatchAllSettings.excludedDevicesKey)
        #expect(CatchAllSettings(defaults: defaults).excludedDeviceUIDs == ["uid-tv", "uid-hdmi2"])
    }

    @Test("No harness unless requested")
    func harnessNotRequested() {
        #expect(CatchAllSettings(defaults: makeDefaults()).harnessSteps == nil)
    }

    @Test("Harness steps: all, a list, case and spaces, unknown names ignored")
    func harnessSteps() {
        #expect(CatchAllHarnessStep.parse("all") == CatchAllHarnessStep.allCases)
        #expect(CatchAllHarnessStep.parse("ALL") == CatchAllHarnessStep.allCases)
        #expect(CatchAllHarnessStep.parse("H0,H2") == [.h0, .h2])
        #expect(CatchAllHarnessStep.parse(" h1 , H8 ") == [.h1, .h8])
        #expect(CatchAllHarnessStep.parse("H0,H99") == [.h0])
        #expect(CatchAllHarnessStep.parse("nothing") == nil)
        #expect(CatchAllHarnessStep.parse("") == nil)
    }

    @Test("The test tone is a 16-bit mono 48 kHz WAV of the requested length")
    func toneFormat() {
        let data = HarnessTone.data(seconds: 0.5)
        #expect(data.count == 44 + 24_000 * 2)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        let channels = UInt16(data[22]) | UInt16(data[23]) << 8
        let rate = UInt32(data[24]) | UInt32(data[25]) << 8 | UInt32(data[26]) << 16 | UInt32(data[27]) << 24
        let bits = UInt16(data[34]) | UInt16(data[35]) << 8
        #expect(channels == 1 && rate == 48_000 && bits == 16)
    }

    @Test("The onset tone fades in linearly over 200 ms")
    func toneRamp() {
        let data = HarnessTone.data(seconds: 0.5, rampSeconds: HarnessTone.onsetRampSeconds)
        func peak(fromMs: Int, toMs: Int) -> Int {
            (fromMs * 48..<toMs * 48).map { i -> Int in
                let offset = 44 + i * 2
                return abs(Int(Int16(bitPattern: UInt16(data[offset]) | UInt16(data[offset + 1]) << 8)))
            }.max() ?? 0
        }
        let full = Double(Int16.max) * 0.8
        #expect(Double(peak(fromMs: 0, toMs: 10)) < full * 0.06)
        #expect(abs(Double(peak(fromMs: 95, toMs: 105)) / full - 0.5) < 0.05)
        #expect(Double(peak(fromMs: 250, toMs: 300)) > full * 0.99)
    }
}
