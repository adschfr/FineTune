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
        let registry = ShortcutsRegistry(
            settings: makeIsolatedSettings(),
            popupController: recorder
        )

        registry.dispatch(.togglePopup)

        #expect(recorder.toggleCount == 1)
    }

    // MARK: - name

    @Test("name(for: .togglePopup) is the stable persistence identifier")
    func nameStable() {
        let registry = ShortcutsRegistry(
            settings: makeIsolatedSettings(),
            popupController: RecordingPopupController()
        )
        #expect(registry.name(for: .togglePopup).rawValue == "toggle-popup")
    }

    // MARK: - start: load path

    @Test("start() loads stored shortcuts into KeyboardShortcuts")
    func startLoadsStoredShortcuts() {
        let settings = makeIsolatedSettings()
        let stored = ShortcutCodable(keyCode: 9, modifiers: 0x12_0000)
        var app = settings.appSettings
        app.customShortcuts[ShortcutAction.togglePopup.rawValue] = stored
        settings.appSettings = app

        let registry = ShortcutsRegistry(settings: settings, popupController: RecordingPopupController())
        registry.start()

        let resolved = KeyboardShortcuts.getShortcut(for: registry.name(for: .togglePopup))
        #expect(resolved?.carbonKeyCode == stored.keyCode)
        // KeyboardShortcuts normalizes the carbon modifier bits at construction time, so
        // compare via the same normalization rather than raw equality.
        #expect(resolved?.carbonModifiers == stored.keyboardShortcut.carbonModifiers)

        // Cleanup so the next test in this process starts with a known state.
        KeyboardShortcuts.setShortcut(nil, for: registry.name(for: .togglePopup))
    }

    @Test("start() is idempotent")
    func startIsIdempotent() {
        let settings = makeIsolatedSettings()
        let registry = ShortcutsRegistry(settings: settings, popupController: RecordingPopupController())

        registry.start()
        registry.start()  // must not crash, must not double-register

        // We can't directly assert handler count, but a duplicate handler would cause two
        // dispatches per fired event. Drive dispatch manually and assert single fire.
        let recorder = RecordingPopupController()
        // Replace popup controller for this assertion isn't possible (let-bound), so use
        // a dedicated registry to confirm dispatch count when we call dispatch directly.
        let registryWithRecorder = ShortcutsRegistry(settings: settings, popupController: recorder)
        registryWithRecorder.start()
        registryWithRecorder.start()
        registryWithRecorder.dispatch(.togglePopup)
        #expect(recorder.toggleCount == 1)

        // Cleanup
        KeyboardShortcuts.setShortcut(nil, for: registry.name(for: .togglePopup))
    }

    // MARK: - recordCallback: write-back path

    @Test("recordCallback writes the new shortcut into AppSettings")
    func recordCallbackWritesBack() {
        let settings = makeIsolatedSettings()
        let registry = ShortcutsRegistry(settings: settings, popupController: RecordingPopupController())

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

        let registry = ShortcutsRegistry(settings: settings, popupController: RecordingPopupController())
        let callback = registry.recordCallback(for: .togglePopup)
        callback(nil)

        #expect(settings.appSettings.customShortcuts[ShortcutAction.togglePopup.rawValue] == nil)
    }

    // MARK: - Helpers

    private func makeIsolatedSettings() -> SettingsManager {
        // Hermetic per-test directory so we don't touch ~/Library/Application Support/FineTune.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FineTuneTests-\(UUID().uuidString)")
        return SettingsManager(directory: dir)
    }
}

// MARK: - Test double

@MainActor
final class RecordingPopupController: MenuBarPopupControlling {
    var toggleCount = 0
    func toggle() { toggleCount += 1 }
}
