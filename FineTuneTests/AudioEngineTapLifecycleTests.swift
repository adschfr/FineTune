// FineTuneTests/AudioEngineTapLifecycleTests.swift
//
// The fork keeps taps of silent apps instead of tearing them down: after 10 s of
// silence the IO proc is suspended, playback resumes it, a changed process set (a new
// browser helper) is pushed into the live tap, and a tap that cannot resume or take the
// new processes is recreated once. These tests drive syncTapsWithProcessState through
// the process monitor's change callback with a test clock and a fake running state.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import FineTune

// MARK: - Fixture

@MainActor
private final class TestClock {
    var now = Date(timeIntervalSinceReferenceDate: 0)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@MainActor
private final class RunningProcesses {
    var ids: Set<AudioObjectID> = []
}

@MainActor
private struct Fixture {
    let engine: AudioEngine
    let settings: SettingsManager
    let processMonitor: StubProcessMonitor
    let taps: FakeTapFactory
    let clock: TestClock
    let running: RunningProcesses
    let tvUID: String

    /// Publishes the app list the way AudioProcessMonitor does after a change.
    func publish(_ apps: [AudioApp]) {
        processMonitor.activeApps = apps
        processMonitor.onAppsChanged?(apps)
    }
}

@MainActor
private func makeFixture() -> Fixture {
    let settings = SettingsManager(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("FineTuneTests-\(UUID().uuidString)"))

    let deviceMonitor = MockAudioDeviceMonitor()
    let tv = AudioDevice(id: AudioDeviceID(42), uid: "uid-tv", name: "LG TV", icon: nil, supportsAutoEQ: false)
    deviceMonitor.addOutputDevice(tv)

    let deviceVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
    deviceVolume.autoDetectedTiersByID = [tv.id: .software]
    deviceVolume.volumes = [tv.id: 0.25]
    deviceVolume.defaultDeviceID = tv.id
    deviceVolume.defaultDeviceUID = tv.uid

    let permission = AudioRecordingPermission()
    permission.status = .authorized

    let processMonitor = StubProcessMonitor()
    let taps = FakeTapFactory()
    let clock = TestClock()
    let running = RunningProcesses()

    let engine = AudioEngine(
        permission: permission,
        settingsManager: settings,
        autoEQProfileManager: AutoEQProfileManager.isolated(),
        deviceProvider: deviceMonitor,
        processMonitor: processMonitor,
        deviceVolumeMonitor: deviceVolume,
        tapFactory: { app, uids, _ in taps.make(app: app, deviceUIDs: uids) },
        isProcessRunning: { running.ids.contains($0) },
        currentDate: { clock.now },
        startMonitorsAutomatically: false
    )
    return Fixture(engine: engine, settings: settings, processMonitor: processMonitor, taps: taps,
                   clock: clock, running: running, tvUID: tv.uid)
}

private let playerPID: pid_t = 6001
private let mainProcess: AudioObjectID = 601
private let helperProcess: AudioObjectID = 602

@MainActor
private func makePlayer(processes: [AudioObjectID] = [mainProcess]) -> AudioApp {
    AudioApp(id: playerPID, processObjectIDs: processes, name: "Browser", icon: NSImage(), bundleID: "com.test.lifecycle")
}

private func approx(_ a: Float?, _ b: Float) -> Bool {
    guard let a else { return false }
    return abs(a - b) < 1e-5
}

/// Starts playback of the player and returns its tap.
@MainActor
private func startPlaying(_ fix: Fixture, _ app: AudioApp = makePlayer()) throws -> FakeTapController {
    fix.running.ids.formUnion(app.processObjectIDs)
    fix.publish([app])
    return try #require(fix.taps.last)
}

/// Stops playback and lets `seconds` pass, publishing at the start and the end like a
/// monitor that saw two unrelated changes.
@MainActor
private func stayIdle(_ fix: Fixture, _ app: AudioApp, for seconds: TimeInterval) {
    fix.running.ids.subtract(app.processObjectIDs)
    fix.publish([app])
    fix.clock.advance(seconds)
    fix.publish([app])
}

// MARK: - Suite

@Suite("AudioEngine tap lifecycle: suspend, resume, process updates, recreate")
@MainActor
struct AudioEngineTapLifecycleTests {

    @Test("A playing app gets one tap on the default output")
    func playingAppIsTapped() throws {
        let fix = makeFixture()

        let tap = try startPlaying(fix)

        #expect(fix.taps.created.count == 1)
        #expect(tap.currentDeviceUIDs == [fix.tvUID])
        #expect(!tap.isSuspended)
    }

    @Test("A tap is not suspended before the app has been silent for 10 s")
    func notSuspendedBeforeDelay() throws {
        let fix = makeFixture()
        let app = makePlayer()
        let tap = try startPlaying(fix, app)

        stayIdle(fix, app, for: 9.9)

        #expect(!tap.isSuspended)
        #expect(!tap.isInvalidated)
    }

    @Test("A tap is suspended, not torn down, once the app has been silent for 10 s")
    func suspendedAfterDelay() throws {
        let fix = makeFixture()
        let app = makePlayer()
        let tap = try startPlaying(fix, app)

        stayIdle(fix, app, for: 10)

        #expect(tap.isSuspended)
        #expect(tap.suspendCount == 1)
        #expect(!tap.isInvalidated)
        #expect(fix.taps.created.count == 1)
    }

    @Test("Playback resumes the suspended tap instead of creating a new one")
    func playbackResumesSuspendedTap() async throws {
        let fix = makeFixture()
        let app = makePlayer()
        let tap = try startPlaying(fix, app)
        stayIdle(fix, app, for: 10)

        fix.running.ids.insert(mainProcess)
        fix.publish([app])
        await settle()

        #expect(!tap.isSuspended)
        #expect(tap.resumeCount == 1)
        #expect(fix.taps.created.count == 1)
        #expect(!tap.isInvalidated)
    }

    @Test("After playback the silence timer starts over")
    func silenceTimerRestartsAfterPlayback() throws {
        let fix = makeFixture()
        let app = makePlayer()
        let tap = try startPlaying(fix, app)
        fix.running.ids = []
        fix.publish([app])
        fix.clock.advance(8)

        // Plays briefly, then is silent again: the earlier 8 s must not count.
        fix.running.ids.insert(mainProcess)
        fix.publish([app])
        stayIdle(fix, app, for: 5)

        #expect(!tap.isSuspended)
    }

    @Test("A new helper process is pushed into the live tap")
    func newHelperProcessUpdatesTapInPlace() async throws {
        let fix = makeFixture()
        let tap = try startPlaying(fix)
        let withHelper = makePlayer(processes: [mainProcess, helperProcess])

        fix.running.ids.insert(helperProcess)
        fix.publish([withHelper])
        await settle()

        #expect(tap.updateProcessesCalls.map(\.processObjectIDs) == [[mainProcess, helperProcess]])
        #expect(tap.app.processObjectIDs == [mainProcess, helperProcess])
        #expect(fix.taps.created.count == 1)
        #expect(!tap.isInvalidated)
    }

    @Test("A tap that rejects the new process set is recreated with it")
    func rejectedProcessUpdateRecreatesTap() async throws {
        let fix = makeFixture()
        let oldTap = try startPlaying(fix)
        oldTap.updateProcessesResult = false
        let withHelper = makePlayer(processes: [mainProcess, helperProcess])

        fix.running.ids.insert(helperProcess)
        fix.publish([withHelper])

        #expect(await waitUntil { fix.taps.created.count == 2 })
        #expect(oldTap.isInvalidated)
        let newTap = try #require(fix.taps.last)
        #expect(newTap.app.processObjectIDs == [mainProcess, helperProcess])
        #expect(newTap.currentDeviceUIDs == [fix.tvUID])
        // App volume 1.0 × TV 0.25, set before the new tap starts
        #expect(approx(newTap.volumeAtActivate, 0.25))
    }

    @Test("A tap that fails to resume is recreated on the same output")
    func failedResumeRecreatesTap() async throws {
        let fix = makeFixture()
        let app = makePlayer()
        let oldTap = try startPlaying(fix, app)
        stayIdle(fix, app, for: 10)
        oldTap.resumeError = FakeTapError()

        fix.running.ids.insert(mainProcess)
        fix.publish([app])

        #expect(await waitUntil { fix.taps.created.count == 2 })
        #expect(oldTap.isInvalidated)
        let newTap = try #require(fix.taps.last)
        #expect(newTap.currentDeviceUIDs == [fix.tvUID])
        #expect(approx(newTap.volumeAtActivate, 0.25))
    }

    @Test("A muted app is still muted when its tap is recreated")
    func recreatedTapKeepsAppMute() async throws {
        let fix = makeFixture()
        let app = makePlayer()
        let oldTap = try startPlaying(fix, app)
        fix.engine.setMute(for: app, to: true)
        stayIdle(fix, app, for: 10)
        oldTap.resumeError = FakeTapError()

        fix.running.ids.insert(mainProcess)
        fix.publish([app])

        #expect(await waitUntil { fix.taps.created.count == 2 })
        let newTap = try #require(fix.taps.last)
        #expect(newTap.isMutedAtActivate == true)
    }

    @Test("A suspended tap takes a new helper process and stays suspended until playback")
    func suspendedTapTakesNewHelper() async throws {
        let fix = makeFixture()
        let app = makePlayer()
        let tap = try startPlaying(fix, app)
        stayIdle(fix, app, for: 10)
        let withHelper = makePlayer(processes: [mainProcess, helperProcess])

        fix.publish([withHelper])
        await settle()

        #expect(tap.app.processObjectIDs == [mainProcess, helperProcess])
        #expect(tap.isSuspended)
        #expect(tap.resumeCount == 0)
        #expect(fix.taps.created.count == 1)

        fix.running.ids.insert(helperProcess)
        fix.publish([withHelper])
        #expect(tap.resumeCount == 1)
    }

    @Test("A saved app volume and the TV volume both apply when playback starts")
    func startupAppliesSavedVolumeAndTVGain() throws {
        let fix = makeFixture()
        let app = makePlayer()
        fix.settings.setVolume(for: app.persistenceIdentifier, to: 0.8)

        let tap = try startPlaying(fix, app)

        #expect(approx(tap.volumeAtActivate, 0.2))
        #expect(approx(tap.volume, 0.2))
    }

    @Test("Repeated changes while a recreate is pending recreate the tap only once")
    func recreateIsDeduplicated() async throws {
        let fix = makeFixture()
        let oldTap = try startPlaying(fix)
        oldTap.updateProcessesResult = false
        let withHelper = makePlayer(processes: [mainProcess, helperProcess])
        fix.running.ids.insert(helperProcess)

        fix.publish([withHelper])
        fix.publish([withHelper])
        fix.publish([withHelper])

        #expect(await waitUntil { fix.taps.created.count == 2 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(fix.taps.created.count == 2)
    }
}
