// FineTuneTests/CatchAllSettingsTests.swift
//
// Catch-all settings live in the fork's defaults domain and default to off; the harness
// runs only for explicitly requested steps, and the H9 kill check only when named. Uses an
// isolated defaults suite. Nothing here spawns the H9 helper or plays a tone.

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
        let allButKill = CatchAllHarnessStep.allCases.filter { $0 != .h9 }
        #expect(CatchAllHarnessStep.parse("all") == allButKill)
        #expect(CatchAllHarnessStep.parse("ALL") == allButKill)
        #expect(CatchAllHarnessStep.parse("H0,H2") == [.h0, .h2])
        #expect(CatchAllHarnessStep.parse("l0,h1m,H7M") == [.l0, .h1m, .h7m])
        #expect(CatchAllHarnessStep.allCases.first == .l0)
        #expect(CatchAllHarnessStep.parse(" h1 , H8 ") == [.h1, .h8])
        #expect(CatchAllHarnessStep.parse("H0,H99") == [.h0])
        #expect(CatchAllHarnessStep.parse("nothing") == nil)
        #expect(CatchAllHarnessStep.parse("") == nil)
    }

    @Test("H9 runs only when named, and always last")
    func killCheckLast() {
        #expect(CatchAllHarnessStep.allCases.contains(.h9))
        #expect(CatchAllHarnessStep.parse("all")?.contains(.h9) == false)
        #expect(CatchAllHarnessStep.parse("H9") == [.h9])
        #expect(CatchAllHarnessStep.parse("h9") == [.h9])
        #expect(CatchAllHarnessStep.parse("H9,L0") == [.l0, .h9])
        #expect(CatchAllHarnessStep.parse("H1M,H9,H0,H9") == [.h1m, .h0, .h9])
        #expect(CatchAllHarnessStep.killCheckLast([.h9, .h2, .h1]) == [.h2, .h1, .h9])
        #expect(CatchAllHarnessStep.killCheckLast([.h2, .h1]) == [.h2, .h1])
    }

    @Test("The pending H9 record round-trips; clear removes it, garbage reads as nil")
    func pendingKillCheck() throws {
        let defaults = makeDefaults()
        #expect(CatchAllSettings(defaults: defaults).pendingH9 == nil)

        let record = CatchAllPendingH9(killTime: Date(timeIntervalSinceReferenceDate: 783_342_800.123), deviceUID: "uid-tv")
        try CatchAllSettings.storePendingH9(record, in: defaults)
        #expect(CatchAllSettings(defaults: defaults).pendingH9 == record)

        CatchAllSettings.clearPendingH9(in: defaults)
        #expect(CatchAllSettings(defaults: defaults).pendingH9 == nil)
        #expect(defaults.object(forKey: CatchAllSettings.pendingH9Key) == nil)

        defaults.set(Data("not a record".utf8), forKey: CatchAllSettings.pendingH9Key)
        #expect(CatchAllSettings(defaults: defaults).pendingH9 == nil)
        defaults.set("uid-tv", forKey: CatchAllSettings.pendingH9Key)
        #expect(CatchAllSettings(defaults: defaults).pendingH9 == nil)
    }

    @Test("A pending H9 answer counts only shortly after the kill")
    func pendingKillCheckAge() {
        let killTime = Date(timeIntervalSinceReferenceDate: 783_342_800)
        let record = CatchAllPendingH9(killTime: killTime, deviceUID: "uid-tv")
        #expect(record.isFresh(at: killTime.addingTimeInterval(10)))
        #expect(record.isFresh(at: killTime.addingTimeInterval(CatchAllPendingH9.maxAge)))
        #expect(!record.isFresh(at: killTime.addingTimeInterval(CatchAllPendingH9.maxAge + 1)))
        #expect(!record.isFresh(at: killTime.addingTimeInterval(-60)))
    }

    @Test("The harness starts for requested steps or a pending H9 answer, not otherwise")
    func harnessRequested() throws {
        let defaults = makeDefaults()
        #expect(!CatchAllSettings(defaults: defaults).harnessRequested)
        defaults.set("nothing", forKey: CatchAllSettings.harnessKey)
        #expect(!CatchAllSettings(defaults: defaults).harnessRequested)
        defaults.set("H0", forKey: CatchAllSettings.harnessKey)
        #expect(CatchAllSettings(defaults: defaults).harnessRequested)

        defaults.removeObject(forKey: CatchAllSettings.harnessKey)
        try CatchAllSettings.storePendingH9(CatchAllPendingH9(killTime: Date(), deviceUID: "uid-tv"), in: defaults)
        #expect(CatchAllSettings(defaults: defaults).harnessRequested)
        CatchAllSettings.clearPendingH9(in: defaults)
        #expect(!CatchAllSettings(defaults: defaults).harnessRequested)
    }

    @Test("The H9 helper gets FineTune's pid, the tone's pid and the app's path as parameters")
    func killHelperArguments() {
        let argv = HarnessKillHelper.arguments(fineTunePID: 4242, tonePID: 5151, appPath: "/Applications/Example Fork.app")
        #expect(argv.first == "/bin/sh")
        #expect(argv.dropFirst().first == "-c")
        #expect(argv.count == 7)
        let script = argv.count > 2 ? argv[2] : ""
        #expect(script == #"kill -9 "$1"; sleep 3; kill "$2" 2>/dev/null; sleep 1; exec /usr/bin/open "$3""#)
        #expect(!script.contains("4242") && !script.contains("5151") && !script.contains("Example"))
        #expect(Array(argv.dropFirst(3)) == ["h9", "4242", "5151", "/Applications/Example Fork.app"])
    }

    @Test("Harness lines carry the local wall-clock time with milliseconds")
    func clockTime() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        let date = Date(timeIntervalSince1970: 1_761_650_000.123)
        #expect(HarnessClock.format(date, timeZone: utc) == "11:13:20.123")
        #expect(HarnessClock.format(date, timeZone: berlin) == "12:13:20.123")
        #expect(HarnessClock.format(Date(timeIntervalSince1970: 1_761_650_000), timeZone: utc) == "11:13:20.000")
        #expect(HarnessClock.format(Date(timeIntervalSince1970: 1_761_650_009.999), timeZone: utc) == "11:13:29.999")
        // Rounds to whole milliseconds, carrying into the seconds
        #expect(HarnessClock.format(Date(timeIntervalSince1970: 1_761_652_799.9996), timeZone: utc) == "12:00:00.000")
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
