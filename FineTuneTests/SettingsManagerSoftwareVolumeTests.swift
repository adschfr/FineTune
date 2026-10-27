// FineTuneTests/SettingsManagerSoftwareVolumeTests.swift
//
// The level of a software-volume output (e.g. a TV over HDMI) lives only in
// settings.json, keyed by device UID. It must survive a restart, be sanitized on
// load, and an unreadable file must be kept as a backup instead of being lost.

import Foundation
import Testing
@testable import FineTune

@Suite("SettingsManager: software-volume levels on disk")
@MainActor
struct SettingsManagerSoftwareVolumeTests {

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FineTuneTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("Level, mute and the level before mute survive a save and reload")
    func softwareStateSurvivesRestart() throws {
        let directory = try makeDirectory()
        let manager = SettingsManager(directory: directory)
        manager.setSoftwareDeviceVolume(for: "uid-tv", to: 0.27)
        manager.setSoftwareDeviceSavedVolume(for: "uid-tv", to: 0.4)
        manager.setSoftwareDeviceMuteState(for: "uid-tv", to: true)
        manager.flushSync()

        let reloaded = SettingsManager(directory: directory)

        #expect(reloaded.getSoftwareDeviceVolume(for: "uid-tv") == 0.27)
        #expect(reloaded.getSoftwareDeviceSavedVolume(for: "uid-tv") == 0.4)
        #expect(reloaded.getSoftwareDeviceMuteState(for: "uid-tv"))
    }

    @Test("Stored levels are sanitized on load: negative dropped, above 1 clamped")
    func storedLevelsAreSanitized() throws {
        let directory = try makeDirectory()
        let json = """
        {
          "version": 12,
          "softwareDeviceVolumes": { "uid-negative": -0.5, "uid-loud": 1.7, "uid-ok": 0.3 },
          "softwareDeviceSavedVolumes": { "uid-negative": -1, "uid-loud": 2.5, "uid-ok": 0.6 }
        }
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("settings.json"))

        let manager = SettingsManager(directory: directory)

        #expect(manager.getSoftwareDeviceVolume(for: "uid-negative") == nil)
        #expect(manager.getSoftwareDeviceVolume(for: "uid-loud") == 1.0)
        #expect(manager.getSoftwareDeviceVolume(for: "uid-ok") == 0.3)
        #expect(manager.getSoftwareDeviceSavedVolume(for: "uid-negative") == nil)
        #expect(manager.getSoftwareDeviceSavedVolume(for: "uid-loud") == 1.0)
        #expect(manager.getSoftwareDeviceSavedVolume(for: "uid-ok") == 0.6)
    }

    @Test("An unreadable settings file is kept as settings.backup.json")
    func unreadableFileIsBackedUp() throws {
        let directory = try makeDirectory()
        let original = Data(#"{"softwareDeviceVolumes": {"uid-tv": 0.27"#.utf8)  // truncated write
        try original.write(to: directory.appendingPathComponent("settings.json"))

        _ = SettingsManager(directory: directory)

        let backup = try Data(contentsOf: directory.appendingPathComponent("settings.backup.json"))
        #expect(backup == original)
    }
}
