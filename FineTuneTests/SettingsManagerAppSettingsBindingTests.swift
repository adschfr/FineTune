// FineTuneTests/SettingsManagerAppSettingsBindingTests.swift
import Foundation
import Testing
@testable import FineTune

@MainActor
@Suite("SettingsManager.appSettings — direct binding setter")
struct SettingsManagerAppSettingsBindingTests {

    @Test("Direct assignment to appSettings persists the new value")
    func directAssignmentPersists() async {
        let manager = SettingsManager(directory: Self.makeTempDirectory())
        var newSettings = manager.appSettings
        newSettings.defaultNewAppVolume = 0.42
        newSettings.lockInputDevice = true

        manager.appSettings = newSettings

        #expect(manager.appSettings.defaultNewAppVolume == 0.42)
        #expect(manager.appSettings.lockInputDevice == true)
    }

    @Test("Direct assignment forwards launch-at-login change to the login item")
    func directAssignmentForwardsLaunchAtLogin() async {
        let loginItem = RecordingLaunchAtLogin()
        let manager = SettingsManager(directory: Self.makeTempDirectory(), launchAtLogin: loginItem)
        var newSettings = manager.appSettings
        newSettings.launchAtLogin = true

        manager.appSettings = newSettings
        #expect(manager.appSettings.launchAtLogin == true)
        #expect(loginItem.calls == [.register])

        newSettings.launchAtLogin = false
        manager.appSettings = newSettings
        #expect(loginItem.calls == [.register, .unregister])
    }

    @Test("Direct assignment is equivalent to updateAppSettings for the same input")
    func directAssignmentEquivalentToUpdate() async {
        let managerA = SettingsManager(directory: Self.makeTempDirectory())
        let managerB = SettingsManager(directory: Self.makeTempDirectory())

        var modified = managerA.appSettings
        modified.defaultNewAppVolume = 0.7
        modified.mediaKeyControlEnabled = true
        modified.showDeviceDisconnectAlerts = false

        managerA.appSettings = modified
        managerB.updateAppSettings(modified)

        #expect(managerA.appSettings == managerB.appSettings)
    }

    @Test("Reset unregisters the login item")
    func resetUnregistersLoginItem() async {
        let loginItem = RecordingLaunchAtLogin()
        let manager = SettingsManager(directory: Self.makeTempDirectory(), launchAtLogin: loginItem)

        manager.resetAllSettings()

        #expect(loginItem.calls == [.unregister])
    }

    private static func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FineTuneTests-\(UUID().uuidString)")
    }
}

@MainActor
final class RecordingLaunchAtLogin: LaunchAtLoginControlling {
    enum Call: Equatable { case register, unregister }
    private(set) var calls: [Call] = []

    func register() throws { calls.append(.register) }
    func unregister() throws { calls.append(.unregister) }
}
