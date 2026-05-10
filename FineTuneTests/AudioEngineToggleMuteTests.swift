// FineTuneTests/AudioEngineToggleMuteTests.swift
import Testing
import Foundation
import AppKit
@testable import FineTune

@Suite("AudioEngine.toggleMute")
@MainActor
struct AudioEngineToggleMuteTests {
    @Test("toggleMute flips an unmuted app to muted")
    func toggleUnmutedToMuted() {
        let (engine, app) = makeEngineWithApp(initiallyMuted: false)

        engine.toggleMute(for: app)

        #expect(engine.volumeState.getMute(for: app.id) == true)
    }

    @Test("toggleMute flips a muted app to unmuted")
    func toggleMutedToUnmuted() {
        let (engine, app) = makeEngineWithApp(initiallyMuted: true)

        engine.toggleMute(for: app)

        #expect(engine.volumeState.getMute(for: app.id) == false)
    }

    private func makeEngineWithApp(initiallyMuted: Bool) -> (AudioEngine, AudioApp) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: tempDir)
        let deviceMonitor = MockAudioDeviceMonitor()
        let mockVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
        let engine = AudioEngine(
            settingsManager: settings,
            deviceProvider: deviceMonitor,
            deviceVolumeMonitor: mockVolume,
            startMonitorsAutomatically: false
        )
        let app = AudioApp(
            id: 42424,
            processObjectIDs: [],
            name: "TestApp",
            icon: NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil) ?? NSImage(),
            bundleID: "com.test.toggleMute"
        )
        engine.volumeState.setMute(for: app.id, to: initiallyMuted, identifier: app.persistenceIdentifier)
        return (engine, app)
    }
}
