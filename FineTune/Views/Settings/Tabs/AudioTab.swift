// FineTune/Views/Settings/Tabs/AudioTab.swift
import SwiftUI

@MainActor
struct AudioTab: View {
    @Bindable var settings: SettingsManager
    @Bindable var audioEngine: AudioEngine
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor

    /// Memoized sorted output devices for the system-sounds picker.
    @State private var sortedOutputDevices: [AudioDevice] = []

    private var unifiedLoudnessToggleBinding: Binding<Bool> {
        Binding(
            get: {
                settings.appSettings.loudnessCompensationEnabled
                    && settings.appSettings.loudnessEqualizationEnabled
            },
            set: { isEnabled in
                settings.appSettings.setUnifiedLoudnessEnabled(isEnabled)
            }
        )
    }

    var body: some View {
        VStack(spacing: 20) {
            defaultsCard
            devicesCard
            loudnessCard
        }
        .onAppear { updateSortedDevices() }
        .onChange(of: audioEngine.outputDevices) { _, _ in updateSortedDevices() }
        .onChange(of: settings.appSettings.lockInputDevice) { oldValue, newValue in
            if !oldValue && newValue {
                audioEngine.handleInputLockEnabled()
            }
        }
        .onChange(of: settings.appSettings.loudnessCompensationEnabled) { _, newValue in
            audioEngine.setLoudnessCompensationEnabled(newValue)
        }
        .onChange(of: settings.appSettings.loudnessEqualizationEnabled) { _, newValue in
            audioEngine.setLoudnessEqualizationEnabled(newValue)
        }
    }

    // MARK: - Defaults

    private var defaultsCard: some View {
        SettingsCard(title: "Defaults") {
            CardRow(
                icon: "speaker.wave.2",
                title: "Default Volume",
                description: "Initial volume for new apps"
            ) {
                VolumeSlider(
                    $settings.appSettings.defaultNewAppVolume,
                    range: 0.1...1.0,
                    width: 160
                )
            }
        }
    }

    // MARK: - Devices

    private var devicesCard: some View {
        SettingsCard(title: "Devices") {
            VStack(spacing: 0) {
                CardRow(
                    icon: "mic",
                    title: "Lock Input Device",
                    description: "Prevent auto-switching when devices connect"
                ) {
                    Toggle("", isOn: $settings.appSettings.lockInputDevice)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }

                CardRowDivider()

                CardRow(
                    icon: "speaker.wave.1",
                    title: "System Sounds",
                    description: "Where alerts and effects play"
                ) {
                    SystemSoundsDevicePicker(
                        devices: sortedOutputDevices,
                        selectedDeviceUID: deviceVolumeMonitor.systemDeviceUID,
                        defaultDeviceUID: deviceVolumeMonitor.defaultDeviceUID,
                        isFollowingDefault: deviceVolumeMonitor.isSystemFollowingDefault,
                        onDeviceSelected: { deviceUID in
                            if let device = sortedOutputDevices.first(where: { $0.uid == deviceUID }) {
                                deviceVolumeMonitor.setSystemDeviceExplicit(device.id)
                            }
                        },
                        onSelectFollowDefault: {
                            deviceVolumeMonitor.setSystemFollowDefault()
                        }
                    )
                }

                CardRowDivider()

                CardRow(
                    icon: "bell.and.waves.left.and.right",
                    title: "Alert Volume",
                    description: "Volume for alerts and notifications"
                ) {
                    VolumeSlider(
                        Binding(
                            get: { deviceVolumeMonitor.alertVolume },
                            set: { deviceVolumeMonitor.setAlertVolume($0) }
                        ),
                        range: 0...1,
                        width: 160
                    )
                }
                .task {
                    // No CoreAudio listener for alert volume — must poll via AppleScript.
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        deviceVolumeMonitor.refreshAlertVolume()
                    }
                }
            }
        }
    }

    // MARK: - Loudness

    private var loudnessCard: some View {
        SettingsCard(title: "Loudness") {
            CardRow(
                icon: "ear",
                title: "Loudness Compensation",
                description: "Boost low frequencies at low volume"
            ) {
                Toggle("", isOn: unifiedLoudnessToggleBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
    }

    private func updateSortedDevices() {
        sortedOutputDevices = audioEngine.prioritySortedOutputDevices
    }
}
