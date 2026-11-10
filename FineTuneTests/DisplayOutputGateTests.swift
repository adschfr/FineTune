// FineTuneTests/DisplayOutputGateTests.swift
//
// A TV or monitor that is disabled in software keeps its audio device in Core Audio while
// macOS no longer lists its screen. The gate decides when such an output counts as
// disconnected. It must fail open: an output that is in use must never disappear because
// of a mismatch, a short gap or sleeping screens.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import FineTune

private let tvUID = "4C2D0F12-0000-0000-0A20-010380593278"
private let tvScreen = DisplayOutputGate.OnlineDisplay(vendor: 0x4C2D, model: 0x120F, uuid: nil)
private let builtIn = DisplayOutputGate.OnlineDisplay(vendor: 0x610, model: 0xA04E, uuid: "11111111-2222-3333-4444-555555555555")
private let delay = DisplayOutputGate.hideDelay

@Suite("Display output gate")
struct DisplayOutputGateTests {

    // MARK: - Reading the UID

    @Test("A display output's UID yields vendor and product")
    func parsesDisplayUID() {
        let key = DisplayOutputGate.displayKey(fromUID: tvUID)
        #expect(key == DisplayOutputGate.DisplayKey(vendor: 0x4C2D, product: 0x0F12))
    }

    @Test("UIDs that name no display yield nothing", arguments: [
        "BuiltInSpeakerDevice",
        "AppleGFXHDAEngineOutputDP:0:{4C2D-0F12}",
        "12-34-56-78-9A-BC:output",
        "4C2D0F1-0000",
        "ZZZZ0F12-0000-0000-0A20-010380593278",
        "00000000-0000-0000-0000-000000000000",
        "",
    ])
    func rejectsOtherUIDs(uid: String) {
        #expect(DisplayOutputGate.displayKey(fromUID: uid) == nil)
    }

    @Test("A screen matches in either byte order of the product, or by its UUID")
    func matchesScreens() throws {
        let key = try #require(DisplayOutputGate.displayKey(fromUID: tvUID))
        #expect(DisplayOutputGate.matches(tvScreen, key: key, uid: tvUID))
        let sameOrder = DisplayOutputGate.OnlineDisplay(vendor: 0x4C2D, model: 0x0F12, uuid: nil)
        #expect(DisplayOutputGate.matches(sameOrder, key: key, uid: tvUID))
        let byUUID = DisplayOutputGate.OnlineDisplay(vendor: 1, model: 2, uuid: tvUID.lowercased())
        #expect(DisplayOutputGate.matches(byUUID, key: key, uid: tvUID))
        #expect(!DisplayOutputGate.matches(builtIn, key: key, uid: tvUID))
        let otherProduct = DisplayOutputGate.OnlineDisplay(vendor: 0x4C2D, model: 0x1234, uuid: nil)
        #expect(!DisplayOutputGate.matches(otherProduct, key: key, uid: tvUID))
    }

    // MARK: - Hiding

    @Test("An output whose screen was never seen online is never hidden")
    func neverSeenStaysVisible() {
        var gate = DisplayOutputGate()
        #expect(gate.update(candidateUIDs: [tvUID], online: [builtIn], now: 0) == nil)
        #expect(gate.update(candidateUIDs: [tvUID], online: [builtIn], now: 100) == nil)
        #expect(gate.hidden.isEmpty)
    }

    @Test("A screen that goes away hides its output after the delay, not before")
    func hidesAfterDelay() {
        var gate = DisplayOutputGate()
        _ = gate.update(candidateUIDs: [tvUID], online: [builtIn, tvScreen], now: 0)
        #expect(gate.seenOnline == [tvUID])

        let next = gate.update(candidateUIDs: [tvUID], online: [builtIn], now: 10)
        #expect(next == 10 + delay)
        #expect(gate.hidden.isEmpty)

        _ = gate.update(candidateUIDs: [tvUID], online: [builtIn], now: 10 + delay - 0.1)
        #expect(gate.hidden.isEmpty)

        #expect(gate.update(candidateUIDs: [tvUID], online: [builtIn], now: 10 + delay) == nil)
        #expect(gate.hidden == [tvUID])
    }

    @Test("A short gap does not hide the output")
    func shortGapKeepsOutput() {
        var gate = DisplayOutputGate()
        _ = gate.update(candidateUIDs: [tvUID], online: [tvScreen], now: 0)
        _ = gate.update(candidateUIDs: [tvUID], online: [], now: 1)
        _ = gate.update(candidateUIDs: [tvUID], online: [tvScreen], now: 2)
        // The gap ended, so a later absence starts a new delay
        let next = gate.update(candidateUIDs: [tvUID], online: [], now: 20)
        #expect(next == 20 + delay)
        #expect(gate.hidden.isEmpty)
    }

    @Test("A screen that returns shows its output again at once")
    func returnsAtOnce() {
        var gate = DisplayOutputGate(seenOnline: [tvUID])
        _ = gate.update(candidateUIDs: [tvUID], online: [builtIn], now: 0)
        _ = gate.update(candidateUIDs: [tvUID], online: [builtIn], now: delay)
        #expect(gate.hidden == [tvUID])

        _ = gate.update(candidateUIDs: [tvUID], online: [builtIn, tvScreen], now: delay + 0.01)
        #expect(gate.hidden.isEmpty)
    }

    @Test("A remembered output is hidden after the delay when the app starts with the screen off")
    func rememberedAcrossLaunches() {
        var gate = DisplayOutputGate(seenOnline: [tvUID])
        #expect(gate.update(candidateUIDs: [tvUID], online: [builtIn], now: 50) == 50 + delay)
        _ = gate.update(candidateUIDs: [tvUID], online: [builtIn], now: 50 + delay)
        #expect(gate.hidden == [tvUID])
    }

    // MARK: - Screens that cannot be judged

    @Test("While screens sleep nothing is hidden, even if macOS stops listing them, and a running delay restarts")
    func sleepingScreensHideNothing() {
        var gate = DisplayOutputGate(seenOnline: [tvUID])
        _ = gate.update(candidateUIDs: [tvUID], online: [builtIn], now: 0)
        // Screens asleep past the delay
        #expect(gate.update(candidateUIDs: [tvUID], online: [], mayHide: false, now: delay + 5) == nil)
        #expect(gate.hidden.isEmpty)
        // Awake again and still missing: the full delay applies from here
        #expect(gate.update(candidateUIDs: [tvUID], online: [builtIn], now: 100) == 100 + delay)
        #expect(gate.hidden.isEmpty)
    }

    @Test("A hidden output stays hidden while screens sleep and returns as soon as its screen is listed")
    func hiddenOutputReturnsWhileSleeping() {
        var gate = DisplayOutputGate(seenOnline: [tvUID])
        _ = gate.update(candidateUIDs: [tvUID], online: [builtIn], now: 0)
        _ = gate.update(candidateUIDs: [tvUID], online: [builtIn], now: delay)
        _ = gate.update(candidateUIDs: [tvUID], online: [builtIn], mayHide: false, now: delay + 1)
        #expect(gate.hidden == [tvUID])

        _ = gate.update(candidateUIDs: [tvUID], online: [builtIn, tvScreen], mayHide: false, now: delay + 2)
        #expect(gate.hidden.isEmpty)
    }

    @Test("An unreadable screen list changes nothing and restarts a running delay")
    func unreadableListChangesNothing() {
        var gate = DisplayOutputGate(seenOnline: [tvUID])
        _ = gate.update(candidateUIDs: [tvUID], online: [builtIn], now: 0)
        #expect(gate.update(candidateUIDs: [tvUID], online: nil, now: delay + 5) == nil)
        #expect(gate.hidden.isEmpty)
        #expect(gate.update(candidateUIDs: [tvUID], online: [builtIn], now: 100) == 100 + delay)

        _ = gate.update(candidateUIDs: [tvUID], online: [builtIn], now: 100 + delay)
        #expect(gate.hidden == [tvUID])
        _ = gate.update(candidateUIDs: [tvUID], online: nil, now: 200)
        #expect(gate.hidden == [tvUID])
    }

    // MARK: - Bookkeeping

    @Test("An output that leaves Core Audio is dropped from the hidden set")
    func unpluggedIsForgotten() {
        var gate = DisplayOutputGate(seenOnline: [tvUID])
        _ = gate.update(candidateUIDs: [tvUID], online: [], now: 0)
        _ = gate.update(candidateUIDs: [tvUID], online: [], now: delay)
        #expect(gate.hidden == [tvUID])
        _ = gate.update(candidateUIDs: [], online: [], now: delay + 1)
        #expect(gate.hidden.isEmpty)
        // Plugged in again with the screen still off: the delay runs again
        #expect(gate.update(candidateUIDs: [tvUID], online: [], now: 30) == 30 + delay)
        #expect(gate.hidden.isEmpty)
    }

    @Test("Outputs with a UID that names no display are never hidden")
    func unreadableUIDStaysVisible() {
        var gate = DisplayOutputGate(seenOnline: ["AppleHDAEngineOutputDP:1"])
        _ = gate.update(candidateUIDs: ["AppleHDAEngineOutputDP:1"], online: [], now: 0)
        _ = gate.update(candidateUIDs: ["AppleHDAEngineOutputDP:1"], online: [], now: 100)
        #expect(gate.hidden.isEmpty)
    }

    @Test("Reset shows everything again and keeps what was learned")
    func resetShowsAll() {
        var gate = DisplayOutputGate(seenOnline: [tvUID])
        _ = gate.update(candidateUIDs: [tvUID], online: [], now: 0)
        _ = gate.update(candidateUIDs: [tvUID], online: [], now: delay)
        gate.reset()
        #expect(gate.hidden.isEmpty)
        #expect(gate.seenOnline == [tvUID])
    }

    @Test("Two outputs are judged independently")
    func independentOutputs() {
        let other = "10AC4321-0000-0000-0A1F-0104B5462878"
        let otherScreen = DisplayOutputGate.OnlineDisplay(vendor: 0x10AC, model: 0x2143, uuid: nil)
        var gate = DisplayOutputGate()
        _ = gate.update(candidateUIDs: [tvUID, other], online: [tvScreen, otherScreen], now: 0)
        _ = gate.update(candidateUIDs: [tvUID, other], online: [otherScreen], now: 1)
        _ = gate.update(candidateUIDs: [tvUID, other], online: [otherScreen], now: 1 + delay)
        #expect(gate.hidden == [tvUID])
    }
}

// MARK: - Engine

@Suite("Engine and the output of a switched-off display")
@MainActor
struct AbsentDisplayOutputEngineTests {
    private struct Fixture {
        let engine: AudioEngine
        let deviceMonitor: MockAudioDeviceMonitor
        let deviceVolume: MockDeviceVolumeProviding
        let tv: AudioDevice
        let speakers: AudioDevice
    }

    /// The TV is first in priority but left out of the list because its screen is off.
    private func makeFixture() -> Fixture {
        let settings = SettingsManager(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("FineTuneTests-\(UUID().uuidString)"))
        let tv = AudioDevice(id: AudioDeviceID(42), uid: "uid-tv", name: "TV", icon: nil, supportsAutoEQ: false)
        let speakers = AudioDevice(id: AudioDeviceID(43), uid: "uid-speakers", name: "Speakers", icon: nil, supportsAutoEQ: false)
        settings.setDevicePriorityOrder([tv.uid, speakers.uid])

        let deviceMonitor = MockAudioDeviceMonitor()
        deviceMonitor.addOutputDevice(speakers)
        deviceMonitor.absentDisplayOutputUIDs = [tv.uid]

        let deviceVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
        deviceVolume.defaultDeviceID = speakers.id
        deviceVolume.defaultDeviceUID = speakers.uid

        let permission = AudioRecordingPermission()
        permission.status = .authorized
        let taps = FakeTapFactory()
        let engine = AudioEngine(
            permission: permission,
            settingsManager: settings,
            autoEQProfileManager: AutoEQProfileManager.isolated(),
            deviceProvider: deviceMonitor,
            processMonitor: StubProcessMonitor(),
            deviceVolumeMonitor: deviceVolume,
            tapFactory: { app, uids, source in try taps.make(app: app, deviceUIDs: uids, source: source) },
            isAlive: { _ in true },
            processOutputDeviceUIDs: { _ in [] },
            startMonitorsAutomatically: false
        )
        return Fixture(engine: engine, deviceMonitor: deviceMonitor, deviceVolume: deviceVolume, tv: tv, speakers: speakers)
    }

    @Test("When that output becomes the default, the engine goes back to the priority choice")
    func defaultOnAbsentDisplayIsRestored() {
        let fix = makeFixture()
        fix.deviceVolume.defaultDeviceID = fix.tv.id
        fix.deviceVolume.defaultDeviceUID = fix.tv.uid

        fix.deviceVolume.onDefaultDeviceChanged?(fix.tv.uid)

        #expect(fix.deviceVolume.setDefaultDeviceCalls == [fix.speakers.id])
    }

    @Test("A default on a device that is merely not listed yet is left alone")
    func unknownDeviceIsDeferred() {
        let fix = makeFixture()
        fix.deviceVolume.defaultDeviceUID = "uid-not-listed-yet"

        fix.deviceVolume.onDefaultDeviceChanged?("uid-not-listed-yet")

        #expect(fix.deviceVolume.setDefaultDeviceCalls.isEmpty)
    }
}
