// FineTuneTests/DeviceVolumeSoftwareStateTests.swift
//
// Software-volume state in DeviceVolumeMonitor, persisted per device UID. A display
// that powers back on can reappear with a new AudioDeviceID and enumerate as present
// but not alive; its gain must come from the saved level, never unity (#375).

import Testing
import Foundation
import AudioToolbox
@testable import FineTune

@MainActor
private struct Fixture {
    let monitor: DeviceVolumeMonitor
    let settings: SettingsManager
    let display: AudioDevice
}

/// The display uses an ID no Core Audio object has, so the HAL reports it as not alive
/// and without hardware volume: a software-tier display that is still reconnecting.
@MainActor
private func makeFixture() -> Fixture {
    let settings = SettingsManager(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("FineTuneTests-\(UUID().uuidString)"))
    let devices = MockAudioDeviceMonitor()
    let display = AudioDevice(id: AudioDeviceID(900_001), uid: "uid-display", name: "LG TV", icon: nil, supportsAutoEQ: false)
    devices.addOutputDevice(display)
    let monitor = DeviceVolumeMonitor(deviceMonitor: devices, settingsManager: settings)
    return Fixture(monitor: monitor, settings: settings, display: display)
}

@Suite("DeviceVolumeMonitor software-volume state (#375)")
@MainActor
struct DeviceVolumeSoftwareStateTests {

    @Test("Fixture: the display is a software-tier device that is not alive")
    func fixtureAssumptions() {
        let fix = makeFixture()

        #expect(fix.monitor.outputVolumeBackend(for: fix.display.id) == .software)
        #expect(!fix.display.id.isDeviceAlive())
    }

    @Test("A display that is not alive yet is seeded from its saved level")
    func notAliveDisplaySeededFromSavedLevel() {
        let fix = makeFixture()
        fix.settings.setSoftwareDeviceVolume(for: fix.display.uid, to: 0.2)

        fix.monitor.refreshOutputDeviceStates()

        #expect(fix.monitor.volumes[fix.display.id] == 0.2)
        #expect(fix.monitor.muteStates[fix.display.id] == false)
        #expect(fix.monitor.outputProcessingGain(for: fix.display.id) == 0.2)
    }

    @Test("A saved mute seeds a silent gain")
    func savedMuteSeedsSilentGain() {
        let fix = makeFixture()
        fix.settings.setSoftwareDeviceVolume(for: fix.display.uid, to: 0.2)
        fix.settings.setSoftwareDeviceMuteState(for: fix.display.uid, to: true)

        fix.monitor.refreshOutputDeviceStates()

        #expect(fix.monitor.muteStates[fix.display.id] == true)
        #expect(fix.monitor.outputProcessingGain(for: fix.display.id) == 0)
    }

    @Test("Before any state read, the gain falls back to the UID's saved level")
    func gainFallsBackToSavedLevel() {
        let fix = makeFixture()
        fix.settings.setSoftwareDeviceVolume(for: fix.display.uid, to: 0.2)

        #expect(fix.monitor.volumes[fix.display.id] == nil)
        #expect(fix.monitor.outputProcessingGain(for: fix.display.id) == 0.2)
    }

    @Test("Before any state read, a saved mute keeps the gain at zero")
    func gainFallsBackToSavedMute() {
        let fix = makeFixture()
        fix.settings.setSoftwareDeviceVolume(for: fix.display.uid, to: 0.2)
        fix.settings.setSoftwareDeviceMuteState(for: fix.display.uid, to: true)

        #expect(fix.monitor.outputProcessingGain(for: fix.display.id) == 0)
    }

    @Test("While the display is not alive, an existing state is kept")
    func existingStateKeptWhileNotAlive() {
        let fix = makeFixture()
        fix.settings.setSoftwareDeviceVolume(for: fix.display.uid, to: 0.2)
        fix.monitor.refreshOutputDeviceStates()

        fix.settings.setSoftwareDeviceVolume(for: fix.display.uid, to: 0.9)
        fix.monitor.refreshOutputDeviceStates()

        #expect(fix.monitor.volumes[fix.display.id] == 0.2)
    }

    @Test("A volume write is stored under the UID and drives the gain")
    func volumeWritePersistsUnderUID() {
        let fix = makeFixture()
        var reported: [Float] = []
        fix.monitor.onVolumeChanged = { _, volume in reported.append(volume) }

        fix.monitor.setVolume(for: fix.display.id, to: 0.35)

        #expect(fix.settings.getSoftwareDeviceVolume(for: fix.display.uid) == 0.35)
        #expect(fix.monitor.outputProcessingGain(for: fix.display.id) == 0.35)
        #expect(reported == [0.35])
    }

    @Test("Mute silences the gain and unmute restores the level from before")
    func muteAndUnmuteRestoreLevel() {
        let fix = makeFixture()
        fix.monitor.setVolume(for: fix.display.id, to: 0.35)

        fix.monitor.setMute(for: fix.display.id, to: true)
        #expect(fix.monitor.outputProcessingGain(for: fix.display.id) == 0)
        #expect(fix.settings.getSoftwareDeviceMuteState(for: fix.display.uid))

        fix.monitor.setMute(for: fix.display.id, to: false)
        #expect(fix.monitor.outputProcessingGain(for: fix.display.id) == 0.35)
        #expect(!fix.settings.getSoftwareDeviceMuteState(for: fix.display.uid))
    }
}
