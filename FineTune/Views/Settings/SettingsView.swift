// FineTune/Views/Settings/SettingsView.swift
import SwiftUI

/// Main settings panel with all app-wide configuration options
struct SettingsView: View {
    @Binding var settings: AppSettings
    @ObservedObject var updateManager: UpdateManager
    let launchIconStyle: MenuBarIconStyle
    let onResetAll: () -> Void

    // System sounds control
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor
    let outputDevices: [AudioDevice]

    // Media keys & HUD
    @Bindable var accessibility: AccessibilityPermissionService
    @Bindable var mediaKeyStatus: MediaKeyStatus
    let mediaKeyMonitor: MediaKeyMonitor

    @State private var showResetConfirmation = false
    @State private var isSupportHovered = false
    @State private var isStarHovered = false
    @State private var isLicenseHovered = false

    private var unifiedLoudnessToggleBinding: Binding<Bool> {
        Binding(
            get: { settings.loudnessCompensationEnabled && settings.loudnessEqualizationEnabled },
            set: { isEnabled in
                settings.setUnifiedLoudnessEnabled(isEnabled)
            }
        )
    }

    var body: some View {
        // Scrollable settings content
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                generalSection
                audioSection
                mediaKeysSection
                notificationsSection
                dataSection

                aboutFooter
            }
        }
        .scrollIndicators(.never)
    }

    // MARK: - General Section

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            SectionHeader(title: "General")
                .padding(.bottom, DesignTokens.Spacing.xs)

            SettingsToggleRow(
                icon: "power",
                title: "Launch at Login",
                description: "Start FineTune when you log in",
                isOn: $settings.launchAtLogin
            )

            SettingsIconPickerRow(
                icon: "menubar.rectangle",
                title: "Menu Bar Icon",
                selection: $settings.menuBarIconStyle,
                appliedStyle: launchIconStyle
            )

            SettingsUpdateRow(
                automaticallyChecks: Binding(
                    get: { updateManager.automaticallyChecksForUpdates },
                    set: { updateManager.automaticallyChecksForUpdates = $0 }
                ),
                lastCheckDate: updateManager.lastUpdateCheckDate,
                onCheckNow: { updateManager.checkForUpdates() }
            )
        }
    }

    // MARK: - Audio Section

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            SectionHeader(title: "Audio")
                .padding(.bottom, DesignTokens.Spacing.xs)

            SettingsSliderRow(
                icon: "speaker.wave.2",
                title: "Default Volume",
                description: "Initial volume for new apps",
                value: $settings.defaultNewAppVolume,
                range: 0.1...1.0
            )

            SettingsToggleRow(
                icon: "mic",
                title: "Lock Input Device",
                description: "Prevent auto-switching when devices connect",
                isOn: $settings.lockInputDevice
            )

            // Sound Effects device selection
            SoundEffectsDeviceRow(
                devices: outputDevices,
                selectedDeviceUID: deviceVolumeMonitor.systemDeviceUID,
                defaultDeviceUID: deviceVolumeMonitor.defaultDeviceUID,
                isFollowingDefault: deviceVolumeMonitor.isSystemFollowingDefault,
                onDeviceSelected: { deviceUID in
                    if let device = outputDevices.first(where: { $0.uid == deviceUID }) {
                        deviceVolumeMonitor.setSystemDeviceExplicit(device.id)
                    }
                },
                onSelectFollowDefault: {
                    deviceVolumeMonitor.setSystemFollowDefault()
                }
            )

            // Sound Effects alert volume slider
            SettingsSliderRow(
                icon: "bell.and.waves.left.and.right",
                title: "Alert Volume",
                description: "Volume for alerts and notifications",
                value: Binding(
                    get: { deviceVolumeMonitor.alertVolume },
                    set: { deviceVolumeMonitor.setAlertVolume($0) }
                )
            )
            .task {
                // Poll alert volume for live sync with System Settings.
                // No CoreAudio property listener exists for alert volume —
                // AppleScript is the only read path, so periodic refresh is required.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    deviceVolumeMonitor.refreshAlertVolume()
                }
            }

            SettingsLoudnessCompensationRow(
                isOn: unifiedLoudnessToggleBinding
            )
        }
    }

    // MARK: - Media Keys & HUD Section

    private var mediaKeysSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            SectionHeader(title: "Media Keys & HUD")
                .padding(.bottom, DesignTokens.Spacing.xs)

            // Toggle + inline permission footer in a single glass container.
            // The permission strip only appears while untrusted; it collapses
            // with a brief "granted" flourish when trust flips. Toggle stays
            // interactive even when untrusted so users can pre-configure —
            // `MediaKeyMonitor` only installs the tap when both flags are
            // true, and reconciles automatically on trust flip.
            MediaKeyControlRow(
                isOn: $settings.mediaKeyControlEnabled,
                accessibility: accessibility
            )

            if mediaKeyStatus.isOffline {
                MediaKeyOfflineCard {
                    mediaKeyMonitor.reconcile()
                }
            }

            // HUD style only surfaces once the feature is actually live —
            // hiding it when disabled keeps the section honest about what the
            // toggle controls.
            if settings.mediaKeyControlEnabled && accessibility.isTrustedCached {
                HUDStylePicker(selection: $settings.hudStyle)
            }
        }
    }


    // MARK: - Notifications Section

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            SectionHeader(title: "Notifications")
                .padding(.bottom, DesignTokens.Spacing.xs)

            SettingsToggleRow(
                icon: "bell",
                title: "Device Disconnect Alerts",
                description: "Show notification when device disconnects",
                isOn: $settings.showDeviceDisconnectAlerts
            )
        }
    }

    // MARK: - Data Section

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            SectionHeader(title: "Data")
                .padding(.bottom, DesignTokens.Spacing.xs)

            if showResetConfirmation {
                // Inline confirmation row
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(DesignTokens.Colors.mutedIndicator)
                        .frame(width: DesignTokens.Dimensions.settingsIconWidth)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reset all settings?")
                            .font(DesignTokens.Typography.rowName)
                            .foregroundStyle(DesignTokens.Colors.textPrimary)
                        Text("This cannot be undone")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                    }

                    Spacer()

                    Button("Cancel") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showResetConfirmation = false
                        }
                    }
                    .buttonStyle(.plain)
                    .font(DesignTokens.Typography.pickerText)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)

                    Button("Reset") {
                        onResetAll()
                        showResetConfirmation = false
                    }
                    .buttonStyle(.plain)
                    .font(DesignTokens.Typography.pickerText)
                    .foregroundStyle(DesignTokens.Colors.mutedIndicator)
                }
                .hoverableRow()
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else {
                SettingsButtonRow(
                    icon: "arrow.counterclockwise",
                    title: "Reset All Settings",
                    description: "Clear all volumes, EQ, and device routings",
                    buttonLabel: "Reset",
                    isDestructive: true
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showResetConfirmation = true
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
    }

    // MARK: - About Footer

    private var aboutFooter: some View {
        let startYear = 2026
        let currentYear = Calendar.current.component(.year, from: .now)
        let yearText = startYear == currentYear ? "\(startYear)" : "\(startYear)-\(currentYear)"

        return HStack(spacing: DesignTokens.Spacing.xs) {
            Button {
                NSWorkspace.shared.open(URL(string: "https://github.com/ronitsingh10/FineTune")!)
            } label: {
                Text("\(Image(systemName: isStarHovered ? "star.fill" : "star")) Star on GitHub")
                    .foregroundStyle(isStarHovered ? Color(nsColor: .systemYellow) : DesignTokens.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(DesignTokens.Animation.hover) {
                    isStarHovered = hovering
                }
            }
            .accessibilityLabel("Star FineTune on GitHub")

            Text("·")

            Button {
                NSWorkspace.shared.open(DesignTokens.Links.support)
            } label: {
                Text("\(Image(systemName: isSupportHovered ? "heart.fill" : "heart")) Support FineTune")
                    .foregroundStyle(isSupportHovered ? Color(nsColor: .systemPink) : DesignTokens.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(DesignTokens.Animation.hover) {
                    isSupportHovered = hovering
                }
            }
            .accessibilityLabel("Support FineTune")

            Text("·")

            Text("Copyright © \(yearText) Ronit Singh")

            Text("·")

            Button {
                NSWorkspace.shared.open(DesignTokens.Links.license)
            } label: {
                Text("GPL-3.0")
                    .foregroundStyle(isLicenseHovered ? DesignTokens.Colors.textSecondary : DesignTokens.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(DesignTokens.Animation.hover) {
                    isLicenseHovered = hovering
                }
            }
            .accessibilityLabel("View GPL-3.0 license")
        }
        .font(DesignTokens.Typography.caption)
        .foregroundStyle(DesignTokens.Colors.textTertiary)
        .frame(maxWidth: .infinity)
        .padding(.top, DesignTokens.Spacing.sm)
    }
}

// MARK: - HUD Style Picker

/// Inline picker for `HUDStyle`. Live-applied — no restart required.
struct HUDStylePicker: View {
    @Binding var selection: HUDStyle

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "rectangle.on.rectangle")
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .frame(width: DesignTokens.Dimensions.settingsIconWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text("HUD Style")
                    .font(DesignTokens.Typography.rowName)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Text("Choose how the volume indicator looks")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }

            Spacer()

            HStack(spacing: 4) {
                ForEach(HUDStyle.allCases) { style in
                    HUDStyleOption(style: style, isSelected: selection == style) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selection = style
                        }
                    }
                }
            }
        }
        .hoverableRow()
    }
}

/// Individual HUD-style option button. The thumbnail renders a scaled
/// caricature of the actual HUD geometry (pill-with-slider for Tahoe,
/// square with glyph+ticks for Classic) so the picker is self-documenting
/// without needing a separate preview surface.
private struct HUDStyleOption: View {
    let style: HUDStyle
    let isSelected: Bool
    let onSelect: () -> Void

    private var label: String {
        switch style {
        case .tahoe: return "Tahoe"
        case .classic: return "Classic"
        }
    }

    var body: some View {
        Button(action: onSelect) {
            thumbnail
                .frame(width: 52, height: 22)
                .frame(width: 60, height: 26)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? DesignTokens.Colors.accentPrimary.opacity(0.15) : Color.clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? DesignTokens.Colors.accentPrimary : Color.clear, lineWidth: 1.5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch style {
        case .tahoe: tahoeThumbnail
        case .classic: classicThumbnail
        }
    }

    private var tahoeThumbnail: some View {
        // Pill silhouette with a slider-track + thumb at ~55% — the reader
        // instantly reads "horizontal pill with a slider", matching the
        // shipped Tahoe HUD geometry at miniature scale.
        let tint = isSelected ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary
        return RoundedRectangle(cornerRadius: 8)
            .fill(Color.primary.opacity(0.08))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(tint.opacity(0.5), lineWidth: 0.75)
            }
            .overlay(alignment: .leading) {
                HStack(spacing: 3) {
                    Circle()
                        .fill(tint.opacity(0.7))
                        .frame(width: 3, height: 3)
                    Capsule()
                        .fill(tint.opacity(0.35))
                        .frame(height: 1.5)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(tint)
                                .frame(width: 14, height: 1.5)
                        }
                }
                .padding(.horizontal, 5)
            }
    }

    private var classicThumbnail: some View {
        // Square silhouette with a centered speaker glyph and a row of
        // segment ticks beneath — mirrors the 200×200 Classic HUD layout.
        let tint = isSelected ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary
        return RoundedRectangle(cornerRadius: 5)
            .fill(Color.primary.opacity(0.08))
            .frame(width: 22, height: 22)
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(tint.opacity(0.5), lineWidth: 0.75)
            }
            .overlay {
                VStack(spacing: 2) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundStyle(tint.opacity(0.8))
                    HStack(spacing: 1) {
                        ForEach(0..<4) { idx in
                            RoundedRectangle(cornerRadius: 0.5)
                                .fill(idx < 2 ? tint : tint.opacity(0.3))
                                .frame(width: 2, height: 2)
                        }
                    }
                }
            }
    }
}

// MARK: - Previews

// Note: Preview requires mock DeviceVolumeMonitor which isn't available
// Use live testing instead
