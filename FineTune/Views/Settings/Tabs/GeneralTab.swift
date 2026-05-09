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
            menuBarCard
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
