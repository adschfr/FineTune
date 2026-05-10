// FineTune/Views/Settings/Tabs/GeneralTab.swift
import SwiftUI

@MainActor
struct GeneralTab: View {
    @Bindable var settings: SettingsManager
    let onResetAll: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showResetConfirmation = false

    var body: some View {
        VStack(spacing: 20) {
            startupCard
            appearanceCard
            menuBarCard
            popupSizeCard
            notificationsCard
            dataCard
        }
    }

    // MARK: - Startup

    private var startupCard: some View {
        SettingsCard(title: "Startup") {
            CardRow(
                icon: "power",
                title: "Launch at Login",
                description: "Start FineTune when you log in"
            ) {
                Toggle("", isOn: $settings.appSettings.launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
    }

    // MARK: - Appearance

    private var appearanceCard: some View {
        SettingsCard(title: "Appearance") {
            CardRow(
                icon: "circle.lefthalf.filled",
                title: "Theme",
                description: "Match macOS, or lock to Light or Dark"
            ) {
                Picker("", selection: $settings.appSettings.appearance) {
                    ForEach(AppearancePreference.allCases) { preference in
                        Text(preference.description).tag(preference)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    // MARK: - Menu Bar

    private var menuBarCard: some View {
        SettingsCard(title: "Menu Bar") {
            CardRow(
                icon: "menubar.rectangle",
                title: "Icon Style",
                description: "How FineTune appears in your menu bar"
            ) {
                IconStyleSegmentedControl(selection: $settings.appSettings.menuBarIconStyle)
            }
        }
    }

    // MARK: - Popup Size

    private var popupSizeCard: some View {
        SettingsCard(title: "Popup Size") {
            CardRow(
                icon: "rectangle.compress.vertical",
                title: "Size",
                description: "Width, padding, and how many rows show before scrolling"
            ) {
                Picker("", selection: $settings.appSettings.popupSize) {
                    ForEach(MenuBarPopupSize.allCases) { size in
                        Text(size.description).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    // MARK: - Notifications

    private var notificationsCard: some View {
        SettingsCard(title: "Notifications") {
            CardRow(
                icon: "bell",
                title: "Device Disconnect Alerts",
                description: "Show notification when device disconnects"
            ) {
                Toggle("", isOn: $settings.appSettings.showDeviceDisconnectAlerts)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
    }

    // MARK: - Data

    private var dataCard: some View {
        SettingsCard(title: "Data") {
            if showResetConfirmation {
                resetConfirmationRow
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                CardRow(
                    icon: "arrow.counterclockwise",
                    title: "Reset All Settings",
                    description: "Clear all volumes, EQ, and device routings"
                ) {
                    Button(role: .destructive) {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            showResetConfirmation = true
                        }
                    } label: {
                        Text("Reset")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                }
                .transition(.opacity)
            }
        }
    }

    private var resetConfirmationRow: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DesignTokens.Colors.mutedIndicator)
                .font(.system(size: 16))
                .frame(width: 28, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text("Reset all settings?")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Text("This cannot be undone")
                    .font(DesignTokens.Typography.rowDescription)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: DesignTokens.Spacing.md)

            Button("Cancel") {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    showResetConfirmation = false
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Reset", role: .destructive) {
                onResetAll()
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    showResetConfirmation = false
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, 10)
        .frame(minHeight: 50)
    }
}
