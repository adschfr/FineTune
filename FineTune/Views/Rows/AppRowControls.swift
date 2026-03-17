// FineTune/Views/Rows/AppRowControls.swift
import SwiftUI

/// Shared controls for app rows: mute button, volume slider, percentage, VU meter, device picker, EQ button.
/// Used by both AppRow (active apps) and InactiveAppRow (pinned inactive apps).
struct AppRowControls: View {
    let volume: Float
    let isMuted: Bool
    let audioLevel: Float
    let devices: [AudioDevice]
    let selectedDeviceUID: String
    let selectedDeviceUIDs: Set<String>
    let isFollowingDefault: Bool
    let defaultDeviceUID: String?
    let deviceSelectionMode: DeviceSelectionMode
    let boost: BoostLevel
    let isEQExpanded: Bool
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onBoostChange: (BoostLevel) -> Void
    let onDeviceSelected: (String) -> Void
    let onDevicesSelected: (Set<String>) -> Void
    let onDeviceModeChange: (DeviceSelectionMode) -> Void
    let onSelectFollowDefault: () -> Void
    let onEQToggle: () -> Void

    @State private var dragOverrideValue: Double?
    @State private var isEQButtonHovered = false
    @State private var isBoostButtonHovered = false

    private var sliderValue: Double {
        dragOverrideValue ?? VolumeMapping.gainToSlider(volume)
    }

    private var showMutedIcon: Bool { isMuted || sliderValue == 0 }

    private var boostButtonColor: Color {
        if boost.isBoosted {
            return DesignTokens.Colors.accentPrimary
        } else if isBoostButtonHovered {
            return DesignTokens.Colors.interactiveHover
        } else {
            return DesignTokens.Colors.textTertiary
        }
    }

    private var eqButtonColor: Color {
        if isEQExpanded {
            return DesignTokens.Colors.interactiveActive
        } else if isEQButtonHovered {
            return DesignTokens.Colors.interactiveHover
        } else {
            return DesignTokens.Colors.interactiveDefault
        }
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            // Mute button
            MuteButton(isMuted: showMutedIcon) {
                if showMutedIcon {
                    if volume == 0 {
                        onVolumeChange(1.0)
                    }
                    onMuteChange(false)
                } else {
                    onMuteChange(true)
                }
            }

            // Volume slider
            LiquidGlassSlider(
                value: Binding(
                    get: { sliderValue },
                    set: { newValue in
                        dragOverrideValue = newValue
                        let gain = VolumeMapping.sliderToGain(newValue)
                        onVolumeChange(gain)
                        if isMuted {
                            onMuteChange(false)
                        }
                    }
                ),
                showUnityMarker: false,
                onEditingChanged: { editing in
                    if !editing {
                        dragOverrideValue = nil
                    }
                }
            )
            .frame(width: DesignTokens.Dimensions.sliderWidth)
            .opacity(showMutedIcon ? 0.5 : 1.0)

            // Editable volume percentage (shows slider position, not raw gain)
            EditablePercentage(
                percentage: Binding(
                    get: {
                        Int(round(sliderValue * 100))
                    },
                    set: { newPercentage in
                        let sliderPos = Double(newPercentage) / 100.0
                        let gain = VolumeMapping.sliderToGain(sliderPos)
                        onVolumeChange(gain)
                    }
                ),
                range: 0...100
            )

            // Boost button
            Button {
                onBoostChange(boost.next)
            } label: {
                Text(boost.label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(boostButtonColor)
                    .frame(
                        minWidth: DesignTokens.Dimensions.minTouchTarget,
                        minHeight: DesignTokens.Dimensions.minTouchTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isBoostButtonHovered = $0 }
            .help("Volume boost: \(boost.label)")
            .accessibilityLabel("Volume boost \(boost.label)")
            .animation(DesignTokens.Animation.hover, value: isBoostButtonHovered)

            // VU Meter
            VUMeter(level: audioLevel, isMuted: showMutedIcon)

            // Device picker
            DevicePicker(
                devices: devices,
                selectedDeviceUID: selectedDeviceUID,
                selectedDeviceUIDs: selectedDeviceUIDs,
                isFollowingDefault: isFollowingDefault,
                defaultDeviceUID: defaultDeviceUID,
                mode: deviceSelectionMode,
                onModeChange: onDeviceModeChange,
                onDeviceSelected: onDeviceSelected,
                onDevicesSelected: onDevicesSelected,
                onSelectFollowDefault: onSelectFollowDefault,
                showModeToggle: true
            )

            // EQ button
            Button {
                onEQToggle()
            } label: {
                ZStack {
                    Image(systemName: "slider.vertical.3")
                        .opacity(isEQExpanded ? 0 : 1)
                        .rotationEffect(.degrees(isEQExpanded ? 90 : 0))

                    Image(systemName: "xmark")
                        .opacity(isEQExpanded ? 1 : 0)
                        .rotationEffect(.degrees(isEQExpanded ? 0 : -90))
                }
                .font(.system(size: 12))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(eqButtonColor)
                .frame(
                    minWidth: DesignTokens.Dimensions.minTouchTarget,
                    minHeight: DesignTokens.Dimensions.minTouchTarget
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isEQExpanded ? "Close Equalizer" : "Equalizer")
            .onHover { isEQButtonHovered = $0 }
            .help(isEQExpanded ? "Close Equalizer" : "Equalizer")
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isEQExpanded)
            .animation(DesignTokens.Animation.hover, value: isEQButtonHovered)
        }
        .frame(width: DesignTokens.Dimensions.controlsWidth)
    }
}
