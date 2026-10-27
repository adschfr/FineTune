// FineTuneTests/AudioEngineSoftwareVolumeTests.swift
//
// On an output without hardware volume (e.g. a TV over HDMI without DDC) the device
// volume is applied inside each process tap: tap.volume = app volume × boost × the
// device's software gain. These tests pin that composition and the paths that keep it
// current, so a tap never plays a software-volume device at the wrong level.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import FineTune

// MARK: - Fixture

@MainActor
private struct Fixture {
    let engine: AudioEngine
    let deviceMonitor: MockAudioDeviceMonitor
    let deviceVolume: MockDeviceVolumeProviding
    let taps: FakeTapFactory
    let tv: AudioDevice
    let speakers: AudioDevice
}

@MainActor
private func makeFixture(tvVolume: Float = 0.25, tvMuted: Bool = false) -> Fixture {
    let settings = SettingsManager(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("FineTuneTests-\(UUID().uuidString)"))

    let deviceMonitor = MockAudioDeviceMonitor()
    let tv = AudioDevice(id: AudioDeviceID(42), uid: "uid-tv", name: "LG TV", icon: nil, supportsAutoEQ: false)
    let speakers = AudioDevice(id: AudioDeviceID(43), uid: "uid-speakers", name: "Speakers", icon: nil, supportsAutoEQ: false)
    deviceMonitor.addOutputDevice(tv)
    deviceMonitor.addOutputDevice(speakers)

    let deviceVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
    deviceVolume.autoDetectedTiersByID = [tv.id: .software, speakers.id: .hardware]
    deviceVolume.volumes = [tv.id: tvVolume, speakers.id: 0.6]
    deviceVolume.muteStates = [tv.id: tvMuted, speakers.id: false]
    deviceVolume.defaultDeviceID = tv.id
    deviceVolume.defaultDeviceUID = tv.uid

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
        tapFactory: { app, uids, _ in try taps.make(app: app, deviceUIDs: uids) },
        // Fake device IDs must not reach the HAL's alive check (it would install listeners)
        isAlive: { _ in true },
        startMonitorsAutomatically: false
    )
    return Fixture(engine: engine, deviceMonitor: deviceMonitor, deviceVolume: deviceVolume,
                   taps: taps, tv: tv, speakers: speakers)
}

@MainActor
private func makeApp(pid: pid_t = 4242, bundleID: String = "com.test.softwarevolume", isRunningInput: Bool = false) -> AudioApp {
    AudioApp(id: pid, processObjectIDs: [], name: "Player", icon: NSImage(), bundleID: bundleID, isRunningInput: isRunningInput)
}

private func approx(_ a: Float?, _ b: Float) -> Bool {
    guard let a else { return false }
    return abs(a - b) < 1e-5
}

// MARK: - Suite

@Suite("AudioEngine software-volume output (TV over HDMI)")
@MainActor
struct AudioEngineSoftwareVolumeTests {

    @Test("A new tap on the TV starts with app volume × TV volume, set before activation")
    func newTapSeededWithSoftwareGain() throws {
        let fix = makeFixture(tvVolume: 0.25)
        let app = makeApp()
        fix.engine.setVolume(for: app, to: 0.8)

        fix.engine.setDevice(for: app, deviceUID: fix.tv.uid)

        let tap = try #require(fix.taps.last)
        #expect(approx(tap.volumeAtActivate, 0.2))
        #expect(approx(tap.volume, 0.2))
    }

    @Test("A tap created while the TV is muted starts silent")
    func newTapOnMutedTVStartsSilent() throws {
        let fix = makeFixture(tvVolume: 0.25, tvMuted: true)
        let app = makeApp()

        fix.engine.setDevice(for: app, deviceUID: fix.tv.uid)

        let tap = try #require(fix.taps.last)
        #expect(approx(tap.volumeAtActivate, 0))
    }

    @Test("A hardware-volume output keeps the app gain only")
    func hardwareOutputKeepsAppGain() throws {
        let fix = makeFixture()
        let app = makeApp()
        fix.engine.setVolume(for: app, to: 0.8)

        fix.engine.setDevice(for: app, deviceUID: fix.speakers.uid)

        let tap = try #require(fix.taps.last)
        #expect(approx(tap.volumeAtActivate, 0.8))
    }

    @Test("App volume and boost changes keep the TV gain in the product")
    func appVolumeAndBoostKeepSoftwareGain() throws {
        let fix = makeFixture(tvVolume: 0.25)
        let app = makeApp()
        fix.engine.setDevice(for: app, deviceUID: fix.tv.uid)
        let tap = try #require(fix.taps.last)

        fix.engine.setVolume(for: app, to: 0.8)
        #expect(approx(tap.volume, 0.2))

        fix.engine.setBoost(for: app, to: .x2)
        #expect(approx(tap.volume, 0.4))
    }

    @Test("A TV volume change reaches the live tap")
    func tvVolumeChangeReachesTap() throws {
        let fix = makeFixture(tvVolume: 0.25)
        let app = makeApp()
        fix.engine.setVolume(for: app, to: 0.8)
        fix.engine.setDevice(for: app, deviceUID: fix.tv.uid)
        let tap = try #require(fix.taps.last)

        fix.deviceVolume.setVolume(for: fix.tv.id, to: 0.5)

        #expect(approx(tap.volume, 0.4))
        #expect(approx(tap.currentDeviceVolume, 0.5))
    }

    @Test("Muting the TV silences the tap, unmuting restores the level")
    func tvMuteDrivesTapGain() throws {
        let fix = makeFixture(tvVolume: 0.25)
        let app = makeApp()
        fix.engine.setVolume(for: app, to: 0.8)
        fix.engine.setDevice(for: app, deviceUID: fix.tv.uid)
        let tap = try #require(fix.taps.last)

        fix.deviceVolume.setMute(for: fix.tv.id, to: true)
        #expect(approx(tap.volume, 0))
        #expect(tap.isDeviceMuted)

        fix.deviceVolume.setMute(for: fix.tv.id, to: false)
        #expect(approx(tap.volume, 0.2))
        #expect(!tap.isDeviceMuted)
    }

    @Test("A suspended tap still follows TV volume changes, so it resumes at the current level")
    func suspendedTapFollowsTVVolume() throws {
        let fix = makeFixture(tvVolume: 0.25)
        let app = makeApp()
        fix.engine.setVolume(for: app, to: 0.8)
        fix.engine.setDevice(for: app, deviceUID: fix.tv.uid)
        let tap = try #require(fix.taps.last)
        tap.suspend()

        fix.deviceVolume.setVolume(for: fix.tv.id, to: 0.1)

        #expect(approx(tap.volume, 0.08))
    }

    @Test("Hardware volume changes do not alter the tap gain")
    func hardwareVolumeChangeLeavesTapGain() throws {
        let fix = makeFixture()
        let app = makeApp()
        fix.engine.setVolume(for: app, to: 0.8)
        fix.engine.setDevice(for: app, deviceUID: fix.speakers.uid)
        let tap = try #require(fix.taps.last)

        fix.deviceVolume.setVolume(for: fix.speakers.id, to: 0.3)

        #expect(approx(tap.volume, 0.8))
        #expect(approx(tap.currentDeviceVolume, 0.3))
    }

    @Test("A TV volume change leaves taps on other outputs alone")
    func tvVolumeChangeIsScopedToTV() throws {
        let fix = makeFixture(tvVolume: 0.25)
        let onTV = makeApp(pid: 5001, bundleID: "com.test.ontv")
        let onSpeakers = makeApp(pid: 5002, bundleID: "com.test.onspeakers")
        fix.engine.setDevice(for: onTV, deviceUID: fix.tv.uid)
        fix.engine.setDevice(for: onSpeakers, deviceUID: fix.speakers.uid)
        let speakersTap = try #require(fix.taps.created.first { $0.app.id == onSpeakers.id })
        let before = speakersTap.volume

        fix.deviceVolume.setVolume(for: fix.tv.id, to: 0.9)

        #expect(approx(speakersTap.volume, before))
        #expect(approx(speakersTap.currentDeviceVolume, 0.6))
        #expect(!speakersTap.isDeviceMuted)
    }

    @Test("A suspended tap follows TV mute and unmute")
    func suspendedTapFollowsTVMute() throws {
        let fix = makeFixture(tvVolume: 0.25)
        let app = makeApp()
        fix.engine.setVolume(for: app, to: 0.8)
        fix.engine.setDevice(for: app, deviceUID: fix.tv.uid)
        let tap = try #require(fix.taps.last)
        tap.suspend()

        fix.deviceVolume.setMute(for: fix.tv.id, to: true)
        #expect(approx(tap.volume, 0))

        fix.deviceVolume.setMute(for: fix.tv.id, to: false)
        #expect(approx(tap.volume, 0.2))
    }

    @Test("When the TV comes back with a new device ID, its taps get the TV volume again (#375)")
    func tvReappearingRestoresGain() throws {
        let fix = makeFixture(tvVolume: 0.25)
        let app = makeApp()
        fix.engine.setVolume(for: app, to: 0.8)
        fix.engine.setDevice(for: app, deviceUID: fix.tv.uid)
        let tap = try #require(fix.taps.last)
        tap.volume = 0.8  // stale gain, as if the TV's state had been lost

        // Power-on: same UID, new AudioDeviceID, state seeded from the saved level
        let tvAgain = AudioDevice(id: AudioDeviceID(900_044), uid: fix.tv.uid, name: "LG TV", icon: nil, supportsAutoEQ: false)
        fix.deviceMonitor.addOutputDevice(tvAgain)
        fix.deviceVolume.autoDetectedTiersByID[tvAgain.id] = .software
        fix.deviceVolume.volumes[tvAgain.id] = 0.25
        fix.deviceMonitor.onDeviceConnected?(fix.tv.uid, "LG TV")

        #expect(approx(tap.volume, 0.2))
    }

    @Test("When the default output changes to the TV, a following app ends at app volume × TV volume")
    func defaultChangeToTVAppliesSoftwareGain() async throws {
        let fix = makeFixture(tvVolume: 0.25)
        fix.deviceVolume.defaultDeviceID = fix.speakers.id
        fix.deviceVolume.defaultDeviceUID = fix.speakers.uid
        let app = makeApp()
        fix.engine.setVolume(for: app, to: 0.8)
        fix.engine.setDevice(for: app, deviceUID: nil)
        let tap = try #require(fix.taps.last)
        #expect(tap.currentDeviceUIDs == [fix.speakers.uid])
        #expect(approx(tap.volume, 0.8))

        fix.deviceVolume.defaultDeviceID = fix.tv.id
        fix.deviceVolume.defaultDeviceUID = fix.tv.uid
        fix.deviceVolume.onDefaultDeviceChanged?(fix.tv.uid)

        #expect(await waitUntil { tap.currentDeviceUIDs == [fix.tv.uid] && approx(tap.volume, 0.2) })
    }

    @Test("Moving a playing app from the speakers to the TV ends at app volume × TV volume")
    func explicitSwitchToTVAppliesSoftwareGain() async throws {
        let fix = makeFixture(tvVolume: 0.25)
        let app = makeApp()
        fix.engine.setVolume(for: app, to: 0.8)
        fix.engine.setDevice(for: app, deviceUID: fix.speakers.uid)
        let tap = try #require(fix.taps.last)

        fix.engine.setDevice(for: app, deviceUID: fix.tv.uid)

        #expect(await waitUntil { tap.currentDeviceUIDs == [fix.tv.uid] && approx(tap.volume, 0.2) })
        #expect(fix.taps.created.count == 1)
    }

    @Test("A call app pinned to the speakers while the TV is the default output stays tapped")
    func callOnSpeakersWithTVDefaultStaysTapped() throws {
        // Without its tap the process plays to the default output, here the TV, at full scale.
        withKnownIssue("Passthrough checks the tap's target, not the default output an untapped process plays to") {
            let fix = makeFixture(tvVolume: 0.25)
            let idle = makeApp()
            let processMonitor = try #require(fix.engine.processMonitor as? StubProcessMonitor)
            processMonitor.activeApps = [idle]
            fix.engine.setDevice(for: idle, deviceUID: fix.speakers.uid)
            let tap = try #require(fix.taps.last)

            let onCall = makeApp(isRunningInput: true)
            processMonitor.activeApps = [onCall]
            processMonitor.onAppsChanged?([onCall])

            #expect(!tap.isInvalidated)
        }
    }
}
