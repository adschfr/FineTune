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
        tapFactory: { app, uids, _ in taps.make(app: app, deviceUIDs: uids) },
        startMonitorsAutomatically: false
    )
    return Fixture(engine: engine, deviceVolume: deviceVolume, taps: taps, tv: tv, speakers: speakers)
}

@MainActor
private func makeApp(pid: pid_t = 4242, bundleID: String = "com.test.softwarevolume") -> AudioApp {
    AudioApp(id: pid, processObjectIDs: [], name: "Player", icon: NSImage(), bundleID: bundleID)
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
    }
}
