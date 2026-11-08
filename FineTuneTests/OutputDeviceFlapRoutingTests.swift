// FineTuneTests/OutputDeviceFlapRoutingTests.swift
//
// A display that drops off HDMI for two seconds disconnects and reconnects while the
// taps are still being moved to the fallback. Every follows-default tap must end on the
// reconnected device, not stay on the fallback while the routing shows the display.

import Foundation
import AppKit
import AudioToolbox
import Testing
@testable import FineTune

@MainActor
private final class FlapState {
    var alive: Set<AudioDeviceID> = []
    var running: Set<AudioObjectID> = []
}

@MainActor
private final class FlapFixture {
    let engine: AudioEngine
    let settings: SettingsManager
    let deviceMonitor = MockAudioDeviceMonitor()
    let deviceVolume: MockDeviceVolumeProviding
    let processMonitor = StubProcessMonitor()
    let taps = FakeTapFactory()
    let state = FlapState()

    let tv = AudioDevice(id: AudioDeviceID(42), uid: "uid-tv", name: "LG TV", icon: nil, supportsAutoEQ: false)
    /// The same display after it came back: same UID, new AudioDeviceID.
    let tvAgain = AudioDevice(id: AudioDeviceID(44), uid: "uid-tv", name: "LG TV", icon: nil, supportsAutoEQ: false)
    let speakers = AudioDevice(id: AudioDeviceID(43), uid: "uid-speakers", name: "Speakers", icon: nil, supportsAutoEQ: false)

    init() {
        settings = SettingsManager(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("FineTuneTests-\(UUID().uuidString)"))
        settings.setDevicePriorityOrder([tv.uid, speakers.uid])
        deviceMonitor.addOutputDevice(tv)
        deviceMonitor.addOutputDevice(speakers)
        state.alive = [tv.id, speakers.id]

        deviceVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
        deviceVolume.autoDetectedTiersByID = [tv.id: .software, tvAgain.id: .software, speakers.id: .hardware]
        deviceVolume.volumes = [tv.id: 0.25, tvAgain.id: 0.25, speakers.id: 0.6]
        deviceVolume.defaultDeviceID = tv.id
        deviceVolume.defaultDeviceUID = tv.uid

        let permission = AudioRecordingPermission()
        permission.status = .authorized
        let taps = self.taps
        let state = self.state
        engine = AudioEngine(
            permission: permission,
            settingsManager: settings,
            autoEQProfileManager: AutoEQProfileManager.isolated(),
            deviceProvider: deviceMonitor,
            processMonitor: processMonitor,
            deviceVolumeMonitor: deviceVolume,
            tapFactory: { app, uids, _ in try taps.make(app: app, deviceUIDs: uids) },
            isAlive: { state.alive.contains($0) },
            isProcessRunning: { state.running.contains($0) },
            startMonitorsAutomatically: false
        )
    }

    func play(_ apps: [AudioApp]) {
        state.running = Set(apps.flatMap(\.processObjectIDs))
        processMonitor.activeApps = apps
        processMonitor.onAppsChanged?(apps)
    }

    func disconnectTV() {
        deviceMonitor.removeOutputDevice(uid: tv.uid)
        state.alive.remove(tv.id)
        deviceVolume.defaultDeviceID = speakers.id
        deviceVolume.defaultDeviceUID = speakers.uid
        deviceMonitor.onDeviceDisconnected?(tv.uid, tv.name)
    }

    func reconnectTV() {
        deviceMonitor.addOutputDevice(tvAgain)
        state.alive.insert(tvAgain.id)
        deviceMonitor.onDeviceConnected?(tvAgain.uid, tvAgain.name)
    }

    /// The tap the engine uses for an app now (a recreated tap replaces the first one).
    func currentTap(for app: AudioApp) -> FakeTapController? {
        taps.created.last { $0.app.id == app.id && !$0.isInvalidated }
    }
}

@MainActor
private func makeApps() -> [AudioApp] {
    [
        AudioApp(id: 7001, processObjectIDs: [801], name: "Firefox", icon: NSImage(), bundleID: "com.test.flap.a"),
        AudioApp(id: 7002, processObjectIDs: [802], name: "WhatsApp", icon: NSImage(), bundleID: "com.test.flap.b"),
        AudioApp(id: 7003, processObjectIDs: [803], name: "MacWhisper", icon: NSImage(), bundleID: "com.test.flap.c"),
    ]
}

@Suite("Display dropping off HDMI: taps end on the display that came back")
@MainActor
struct OutputDeviceFlapRoutingTests {

    @Test("Reconnect while the fallback moves are still running")
    func reconnectDuringFallbackMoves() async throws {
        let fix = FlapFixture()
        let apps = makeApps()
        fix.play(apps)
        let firstTaps = fix.taps.created
        #expect(firstTaps.count == apps.count)
        #expect(firstTaps.allSatisfy { $0.currentDeviceUIDs == [fix.tv.uid] })
        for tap in firstTaps { tap.switchDuration = .milliseconds(50) }

        fix.disconnectTV()
        // The display is back after the first tap moved, the others still wait their turn
        #expect(await waitUntil { firstTaps.contains { $0.currentDeviceUIDs == [fix.speakers.uid] } })
        fix.reconnectTV()

        // Checked right after the passes: the grace period that ends 2 s after the reconnect
        // can heal the routing in this setup, which it did not do on the user's Mac.
        await fix.engine.waitForRoutingPasses()
        for app in apps {
            #expect(fix.currentTap(for: app)?.currentDeviceUIDs == [fix.tv.uid], "\(app.name)")
        }
    }

    @Test("Reconnect before any fallback move ran")
    func reconnectBeforeFallbackMoves() async throws {
        let fix = FlapFixture()
        let apps = makeApps()
        fix.play(apps)
        for tap in fix.taps.created { tap.switchDuration = .milliseconds(50) }

        fix.disconnectTV()
        fix.reconnectTV()

        await fix.engine.waitForRoutingPasses()
        for app in apps {
            #expect(fix.currentTap(for: app)?.currentDeviceUIDs == [fix.tv.uid], "\(app.name)")
        }
    }
}
