// FineTuneTests/ShortcutsRegistryTests.swift
import Testing
import Foundation
import AppKit
import KeyboardShortcuts
@testable import FineTune

@Suite("ShortcutsRegistry")
@MainActor
struct ShortcutsRegistryTests {
    // MARK: - dispatch

    @Test("dispatch(.togglePopup) calls popupController.toggle() exactly once")
    func dispatchTogglePopup() {
        let recorder = RecordingPopupController()
        let registry = makeRegistry(popupController: recorder)

        registry.dispatch(.togglePopup)

        #expect(recorder.toggleCount == 1)
    }

    @Test("dispatch(.frontmostAppVolumeUp) raises volume on the matched app")
    func dispatchFrontmostVolumeUpHappyPath() {
        let app = makeAudioApp(id: 1, bundleID: "com.test.app")
        let resolver = StubTargetResolver(target: "com.test.app")
        let engine = RecordingAudioEngine(apps: [app], initialVolume: 0.5)
        let hud = RecordingHUDController()
        let registry = makeRegistry(
            resolver: resolver,
            audioEngine: engine,
            hud: hud
        )

        registry.dispatch(.frontmostAppVolumeUp)

        let expected: Float = 0.5 + 1.0 / 16.0
        #expect(engine.setVolumeCalls.count == 1)
        #expect(engine.setVolumeCalls.first?.app.bundleID == "com.test.app")
        #expect(engine.setVolumeCalls.first?.volume == expected)
        #expect(hud.successCalls == 1)
        #expect(hud.failureCalls == 0)
    }

    @Test("dispatch(.frontmostAppVolumeDown) clamps at 0")
    func dispatchFrontmostVolumeDownClampsAtZero() {
        let app = makeAudioApp(id: 1, bundleID: "com.test.app")
        let engine = RecordingAudioEngine(apps: [app], initialVolume: 0.0)
        let registry = makeRegistry(
            resolver: StubTargetResolver(target: "com.test.app"),
            audioEngine: engine,
            hud: RecordingHUDController()
        )

        registry.dispatch(.frontmostAppVolumeDown)

        #expect(engine.setVolumeCalls.first?.volume == 0.0)
    }

    @Test("dispatch(.frontmostAppMuteToggle) calls toggleMute and reports new mute state")
    func dispatchFrontmostMuteHappyPath() {
        let app = makeAudioApp(id: 1, bundleID: "com.test.app")
        let engine = RecordingAudioEngine(apps: [app], initialMuted: false)
        let hud = RecordingHUDController()
        let registry = makeRegistry(
            resolver: StubTargetResolver(target: "com.test.app"),
            audioEngine: engine,
            hud: hud
        )

        registry.dispatch(.frontmostAppMuteToggle)

        #expect(engine.toggleMuteCalls.count == 1)
        #expect(hud.successCalls == 1)
    }

    @Test("dispatch falls through to failure HUD when resolver returns nil")
    func dispatchNoTarget() {
        let engine = RecordingAudioEngine(apps: [])
        let hud = RecordingHUDController()
        let registry = makeRegistry(
            resolver: StubTargetResolver(target: nil),
            audioEngine: engine,
            hud: hud
        )

        registry.dispatch(.frontmostAppVolumeUp)

        #expect(engine.setVolumeCalls.isEmpty)
        #expect(hud.failureCalls == 1)
    }

    @Test("dispatch falls through to failure HUD when no matching AudioApp exists")
    func dispatchNoMatchingApp() {
        let engine = RecordingAudioEngine(apps: [])
        let hud = RecordingHUDController()
        let registry = makeRegistry(
            resolver: StubTargetResolver(target: "com.test.notap"),
            audioEngine: engine,
            hud: hud
        )

        registry.dispatch(.frontmostAppVolumeDown)

        #expect(engine.setVolumeCalls.isEmpty)
        #expect(hud.failureCalls == 1)
    }

    // MARK: - name

    @Test("name(for: .togglePopup) is the stable persistence identifier")
    func nameStable() {
        let registry = makeRegistry()
        #expect(registry.name(for: .togglePopup).rawValue == "toggle-popup")
        #expect(registry.name(for: .frontmostAppVolumeUp).rawValue == "frontmost-app-volume-up")
        #expect(registry.name(for: .frontmostAppVolumeDown).rawValue == "frontmost-app-volume-down")
        #expect(registry.name(for: .frontmostAppMuteToggle).rawValue == "frontmost-app-mute-toggle")
    }

    // MARK: - start: load path

    @Test("start() loads stored shortcuts into KeyboardShortcuts")
    func startLoadsStoredShortcuts() {
        let settings = makeIsolatedSettings()
        let stored = ShortcutCodable(keyCode: 9, modifiers: 0x12_0000)
        var app = settings.appSettings
        app.customShortcuts[ShortcutAction.togglePopup.rawValue] = stored
        settings.appSettings = app

        let registry = makeRegistry(settings: settings)
        registry.start()

        let resolved = KeyboardShortcuts.getShortcut(for: registry.name(for: .togglePopup))
        #expect(resolved?.carbonKeyCode == stored.keyCode)
        #expect(resolved?.carbonModifiers == stored.keyboardShortcut.carbonModifiers)

        KeyboardShortcuts.setShortcut(nil, for: registry.name(for: .togglePopup))
    }

    @Test("start() is idempotent")
    func startIsIdempotent() {
        let settings = makeIsolatedSettings()
        let registry = makeRegistry(settings: settings)

        registry.start()
        registry.start()

        let recorder = RecordingPopupController()
        let registryWithRecorder = makeRegistry(settings: settings, popupController: recorder)
        registryWithRecorder.start()
        registryWithRecorder.start()
        registryWithRecorder.dispatch(.togglePopup)
        #expect(recorder.toggleCount == 1)

        KeyboardShortcuts.setShortcut(nil, for: registry.name(for: .togglePopup))
    }

    // MARK: - recordCallback: write-back path

    @Test("recordCallback writes the new shortcut into AppSettings")
    func recordCallbackWritesBack() {
        let settings = makeIsolatedSettings()
        let registry = makeRegistry(settings: settings)

        let callback = registry.recordCallback(for: .togglePopup)
        let newShortcut = KeyboardShortcuts.Shortcut(carbonKeyCode: 11, carbonModifiers: 0x12_0000)
        callback(newShortcut)

        let stored = settings.appSettings.customShortcuts[ShortcutAction.togglePopup.rawValue]
        #expect(stored?.keyCode == 11)
        #expect(stored?.modifiers == UInt(newShortcut.carbonModifiers))
    }

    @Test("recordCallback clears the entry when given nil")
    func recordCallbackClearsOnNil() {
        let settings = makeIsolatedSettings()
        var app = settings.appSettings
        app.customShortcuts[ShortcutAction.togglePopup.rawValue] = ShortcutCodable(keyCode: 9, modifiers: 0)
        settings.appSettings = app

        let registry = makeRegistry(settings: settings)
        let callback = registry.recordCallback(for: .togglePopup)
        callback(nil)

        #expect(settings.appSettings.customShortcuts[ShortcutAction.togglePopup.rawValue] == nil)
    }

    // MARK: - Helpers

    private func makeRegistry(
        settings: SettingsManager? = nil,
        popupController: (any MenuBarPopupControlling)? = nil,
        resolver: (any TargetAppResolving)? = nil,
        audioEngine: (any AudioEngineDispatching)? = nil,
        hud: (any PerAppHUDPresenting)? = nil
    ) -> ShortcutsRegistry {
        ShortcutsRegistry(
            settings: settings ?? makeIsolatedSettings(),
            popupController: popupController ?? RecordingPopupController(),
            resolver: resolver ?? StubTargetResolver(target: nil),
            audioEngine: audioEngine ?? RecordingAudioEngine(apps: []),
            hud: hud ?? RecordingHUDController()
        )
    }

    private func makeIsolatedSettings() -> SettingsManager {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FineTuneTests-\(UUID().uuidString)")
        return SettingsManager(directory: dir)
    }

    private func makeAudioApp(id: pid_t, bundleID: String?) -> AudioApp {
        AudioApp(
            id: id,
            processObjectIDs: [],
            name: "Test \(id)",
            icon: NSImage(systemSymbolName: "speaker", accessibilityDescription: nil) ?? NSImage(),
            bundleID: bundleID
        )
    }
}

// MARK: - Test doubles

@MainActor
final class RecordingPopupController: MenuBarPopupControlling {
    var toggleCount = 0
    func toggle() { toggleCount += 1 }
}

@MainActor
final class StubTargetResolver: TargetAppResolving {
    var target: String?
    init(target: String?) { self.target = target }
    func resolveTargetBundleID() -> String? { target }
}

@MainActor
final class RecordingAudioEngine: AudioEngineDispatching {
    var apps: [AudioApp]
    private var volume: Float
    private var muted: Bool
    var setVolumeCalls: [(app: AudioApp, volume: Float)] = []
    var toggleMuteCalls: [AudioApp] = []

    init(apps: [AudioApp], initialVolume: Float = 0.5, initialMuted: Bool = false) {
        self.apps = apps
        self.volume = initialVolume
        self.muted = initialMuted
    }

    func setVolume(for app: AudioApp, to volume: Float) {
        self.volume = volume
        setVolumeCalls.append((app, volume))
    }

    func toggleMute(for app: AudioApp) {
        muted.toggle()
        toggleMuteCalls.append(app)
    }

    func currentVolume(for app: AudioApp) -> Float { volume }
    func isMuted(for app: AudioApp) -> Bool { muted }
}

@MainActor
final class RecordingHUDController: PerAppHUDPresenting {
    var successCalls = 0
    var failureCalls = 0

    func showPerAppVolumeHUD(app: AudioApp, level: Float) { successCalls += 1 }
    func showPerAppMuteHUD(app: AudioApp, isMuted: Bool) { successCalls += 1 }
    func showPerAppNotControlledHUD(displayName: String?, bundleID: String?, icon: NSImage?) {
        failureCalls += 1
    }
}
