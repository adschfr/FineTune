// FineTune/Views/Settings/Tabs/ShortcutsTab.swift
import SwiftUI

@MainActor
struct ShortcutsTab: View {
    @Bindable var settings: SettingsManager
    @Bindable var accessibility: AccessibilityPermissionService
    @Bindable var mediaKeyStatus: MediaKeyStatus
    let mediaKeyMonitor: MediaKeyMonitor

    var body: some View {
        VStack(spacing: 20) {
            mediaKeysCard
            hotkeysCard
        }
        .onChange(of: settings.appSettings.mediaKeyControlEnabled) { _, _ in
            mediaKeyMonitor.reconcile()
        }
    }

    // MARK: - Media Keys

    private var mediaKeysCard: some View {
        SettingsCard(title: "Media Keys") {
            VStack(spacing: 0) {
                CardRow(
                    icon: "playpause",
                    title: "Media Keys Control",
                    description: "Use F11/F12 (or volume keys) to control FineTune"
                ) {
                    Toggle("", isOn: $settings.appSettings.mediaKeyControlEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }

                if !accessibility.isTrustedCached {
                    CardRowDivider()
                    AccessibilityPromptStrip(accessibility: accessibility)
                }

                if mediaKeyStatus.isOffline {
                    CardRowDivider()
                    MediaKeyOfflineCard {
                        mediaKeyMonitor.reconcile()
                    }
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.vertical, DesignTokens.Spacing.sm)
                }

                if settings.appSettings.mediaKeyControlEnabled && accessibility.isTrustedCached {
                    CardRowDivider()
                    CardRow(
                        icon: "rectangle.on.rectangle",
                        title: "HUD Style",
                        description: "How the volume indicator appears"
                    ) {
                        HUDStyleSegmentedControl(selection: $settings.appSettings.hudStyle)
                    }
                }
            }
        }
    }

    // MARK: - Hotkeys (placeholder)

    private var hotkeysCard: some View {
        SettingsCard(title: "Hotkeys") {
            CardRow(
                icon: "keyboard",
                title: "Custom hotkeys",
                description: "Coming in a future update"
            ) {
                Text("Soon")
                    .font(DesignTokens.Typography.rowDescription)
                    .foregroundStyle(.tertiary)
            }
            .opacity(0.6)
        }
    }
}
