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
    let deviceMonitor: MockAudioDeviceMonitor
    let deviceVolume: MockDeviceVolumeProviding
    let processMonitor: StubProcessMonitor
    let taps: FakeTapFactory
    let clock: TestClock
    let running: RunningProcesses
    let tvUID: String
    let speakersUID: String

    /// Publishes the app list the way AudioProcessMonitor does after a change.
    func publish(_ apps: [AudioApp]) {
        processMonitor.activeApps = apps
        processMonitor.onAppsChanged?(apps)
    }
}

@MainActor
private func makeFixture(
    staleCleanupDebounce: Duration = .milliseconds(350),
    staleTapGracePeriod: Duration = .seconds(30),
    healthCheckInterval: Duration = .seconds(2)
) -> Fixture {
    let settings = SettingsManager(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("FineTuneTests-\(UUID().uuidString)"))

    let deviceMonitor = MockAudioDeviceMonitor()
    let tv = AudioDevice(id: AudioDeviceID(42), uid: "uid-tv", name: "LG TV", icon: nil, supportsAutoEQ: false)
    let speakers = AudioDevice(id: AudioDeviceID(43), uid: "uid-speakers", name: "Speakers", icon: nil, supportsAutoEQ: false)
    deviceMonitor.addOutputDevice(tv)
    deviceMonitor.addOutputDevice(speakers)

    let deviceVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
    deviceVolume.autoDetectedTiersByID = [tv.id: .software, speakers.id: .hardware]
    deviceVolume.volumes = [tv.id: 0.25, speakers.id: 0.6]
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
        tapFactory: { app, uids, _ in try taps.make(app: app, deviceUIDs: uids) },
        isProcessRunning: { running.ids.contains($0) },
        currentDate: { clock.now },
        staleCleanupDebounce: staleCleanupDebounce,
        staleTapGracePeriod: staleTapGracePeriod,
        healthCheckInterval: healthCheckInterval,
        startMonitorsAutomatically: false
    )
    return Fixture(engine: engine, settings: settings, deviceMonitor: deviceMonitor, deviceVolume: deviceVolume,
                   processMonitor: processMonitor, taps: taps,
                   clock: clock, running: running, tvUID: tv.uid, speakersUID: speakers.uid)
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

/// Starts playback of the player and a second app used as a control.
@MainActor
private func startTwoApps(_ fix: Fixture) throws -> (AudioApp, FakeTapController, AudioApp, FakeTapController) {
    let player = makePlayer()
    let other = AudioApp(id: 6002, processObjectIDs: [701], name: "Other", icon: NSImage(), bundleID: "com.test.lifecycle.other")
    fix.running.ids = [mainProcess, 701]
    fix.publish([player, other])
    let playerTap = try #require(fix.taps.created.first { $0.app.id == player.id })
    let otherTap = try #require(fix.taps.created.first { $0.app.id == other.id })
    return (player, playerTap, other, otherTap)
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

        #expect(await waitUntil { fix.taps.created.count == 2 && oldTap.isInvalidated })
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

        #expect(await waitUntil { fix.taps.created.count == 2 && oldTap.isInvalidated })
        let newTap = try #require(fix.taps.last)
        #expect(newTap.currentDeviceUIDs == [fix.tvUID])
        #expect(approx(newTap.volumeAtActivate, 0.25))
    }

    @Test("A recreate silences the old tap, starts the new one, and only then releases the old")
    func recreateIsMakeBeforeBreak() async throws {
        let fix = makeFixture()
        let app = makePlayer()
        let oldTap = try startPlaying(fix, app)
        stayIdle(fix, app, for: 10)
        oldTap.resumeError = FakeTapError()

        fix.running.ids.insert(mainProcess)
        fix.publish([app])
        #expect(await waitUntil { oldTap.isInvalidated })

        let silenced = try #require(fix.taps.position(of: "mute true 0"))
        let started = try #require(fix.taps.position(of: "activate 1"))
        let released = try #require(fix.taps.position(of: "invalidate 0"))
        #expect(silenced < started)
        #expect(started < released)
    }

    @Test("If the replacement cannot be built, the old tap stays and keeps working")
    func failedReplacementKeepsOldTap() async throws {
        let fix = makeFixture()
        let app = makePlayer()
        let oldTap = try startPlaying(fix, app)
        stayIdle(fix, app, for: 10)
        oldTap.resumeError = FakeTapError()
        fix.taps.failCreations = true

        fix.running.ids.insert(mainProcess)
        fix.publish([app])
        await settle()

        #expect(!oldTap.isInvalidated)
        #expect(!oldTap.isMuted)
        // Still registered: TV volume changes reach it
        fix.deviceVolume.setVolume(for: AudioDeviceID(42), to: 0.5)
        #expect(approx(oldTap.volume, 0.5))
    }

    @Test("A recreated tap follows the current routing when the old output is gone")
    func recreateUsesCurrentRouting() async throws {
        let fix = makeFixture()
        let app = makePlayer()
        let oldTap = try startPlaying(fix, app)
        stayIdle(fix, app, for: 10)
        oldTap.resumeError = FakeTapError()

        // The TV disappeared and the speakers became the default before anything rerouted
        fix.deviceMonitor.removeOutputDevice(uid: fix.tvUID)
        fix.deviceVolume.defaultDeviceID = AudioDeviceID(43)
        fix.deviceVolume.defaultDeviceUID = fix.speakersUID
        fix.running.ids.insert(mainProcess)
        fix.publish([app])

        #expect(await waitUntil { fix.taps.created.count == 2 })
        let newTap = try #require(fix.taps.last)
        #expect(newTap.currentDeviceUIDs == [fix.speakersUID])
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

    // Stale cleanup: upstream drops taps of apps that are not playing; the fork keeps
    // them (suspended) for as long as the app has a Core Audio process object. A second
    // app that vanishes at the same time is the control: once its tap is gone, the
    // cleanup has run and its grace period has passed, however slow the machine is.

    @Test("A silent app that is still present keeps its tap past the stale-cleanup grace period")
    func silentPresentAppKeepsTap() async throws {
        let fix = makeFixture(staleCleanupDebounce: .milliseconds(5), staleTapGracePeriod: .milliseconds(20))
        let (silent, silentTap, _, controlTap) = try startTwoApps(fix)

        fix.running.ids = []
        fix.publish([silent])

        #expect(await waitUntil(timeout: .seconds(10)) { controlTap.isInvalidated })
        #expect(!silentTap.isInvalidated)
    }

    @Test("A tap is removed once its app has no Core Audio process object left")
    func vanishedAppLosesTap() async throws {
        let fix = makeFixture(staleCleanupDebounce: .milliseconds(5), staleTapGracePeriod: .milliseconds(20))
        let tap = try startPlaying(fix)

        fix.running.ids = []
        fix.publish([])

        #expect(await waitUntil(timeout: .seconds(10)) { tap.isInvalidated })
    }

    @Test("An app that comes back within the grace period keeps its tap")
    func returningAppKeepsTap() async throws {
        let fix = makeFixture(staleCleanupDebounce: .milliseconds(5), staleTapGracePeriod: .seconds(1))
        let (returning, returningTap, _, controlTap) = try startTwoApps(fix)

        fix.publish([])
        try await Task.sleep(for: .milliseconds(100))
        fix.publish([returning])

        #expect(await waitUntil(timeout: .seconds(10)) { controlTap.isInvalidated })
        #expect(!returningTap.isInvalidated)
    }

    // Health monitor: runs only while a tap is active, drives the 10 s suspension and
    // recreates taps whose IO stopped.

    @Test("Health monitoring does not run while there is no active tap")
    func healthMonitorIdleWithoutActiveTaps() throws {
        let fix = makeFixture(healthCheckInterval: .milliseconds(10))

        fix.engine.startHealthMonitoring()
        #expect(!fix.engine.isHealthMonitorRunning)

        _ = try startPlaying(fix)
        #expect(fix.engine.isHealthMonitorRunning)
    }

    @Test("Health monitoring suspends a silent tap without another app-list change")
    func healthMonitorSuspendsSilentTap() async throws {
        let fix = makeFixture(healthCheckInterval: .milliseconds(10))
        let app = makePlayer()
        let tap = try startPlaying(fix, app)
        fix.engine.startHealthMonitoring()

        fix.running.ids = []
        fix.publish([app])  // the only app-list change
        fix.clock.advance(10)

        #expect(await waitUntil(timeout: .seconds(10)) { tap.isSuspended })
    }

    @Test("Health monitoring stops once every tap is suspended and restarts on playback")
    func healthMonitorStopsWhenIdleAndRestarts() async throws {
        let fix = makeFixture(healthCheckInterval: .milliseconds(10))
        let app = makePlayer()
        let tap = try startPlaying(fix, app)
        fix.engine.startHealthMonitoring()
        stayIdle(fix, app, for: 10)
        #expect(tap.isSuspended)

        #expect(await waitUntil(timeout: .seconds(10)) { !fix.engine.isHealthMonitorRunning })

        fix.running.ids.insert(mainProcess)
        fix.publish([app])
        #expect(!tap.isSuspended)
        #expect(fix.engine.isHealthMonitorRunning)
    }

    @Test("A playing tap without callbacks is recreated on the TV with the TV gain")
    func healthMonitorRecreatesDeadTap() async throws {
        let fix = makeFixture(healthCheckInterval: .milliseconds(10))
        let tap = try startPlaying(fix)
        tap.healthCheckEligible = true
        tap.hasRecentCallback = false

        fix.engine.startHealthMonitoring()

        #expect(await waitUntil(timeout: .seconds(10)) { fix.taps.created.count == 2 && tap.isInvalidated })
        let newTap = try #require(fix.taps.last)
        #expect(newTap.currentDeviceUIDs == [fix.tvUID])
        #expect(approx(newTap.volumeAtActivate, 0.25))
    }

    @Test("A muted app's tap is not recreated for missing callbacks")
    func healthMonitorSkipsMutedTap() async throws {
        let fix = makeFixture(healthCheckInterval: .milliseconds(10))
        let (player, playerTap, _, controlTap) = try startTwoApps(fix)
        fix.engine.setMute(for: player, to: true)
        for tap in [playerTap, controlTap] {
            tap.healthCheckEligible = true
            tap.hasRecentCallback = false
        }

        fix.engine.startHealthMonitoring()

        #expect(await waitUntil(timeout: .seconds(10)) { controlTap.isInvalidated })
        #expect(!playerTap.isInvalidated)
    }
}
