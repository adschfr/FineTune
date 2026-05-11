// FineTune/Views/Settings/Tabs/ShortcutsTab.swift
import SwiftUI
import KeyboardShortcuts

@MainActor
struct ShortcutsTab: View {
    @Bindable var settings: SettingsManager
    @Bindable var accessibility: AccessibilityPermissionService
    @Bindable var mediaKeyStatus: MediaKeyStatus
    let mediaKeyMonitor: MediaKeyMonitor
    let shortcutsRegistry: ShortcutsRegistry

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

                    CardRowDivider()
                    CardRow(
                        icon: "speaker.wave.2",
                        title: "Volume Step",
                        description: "How much each keypress changes the volume"
                    ) {
                        Picker("", selection: $settings.appSettings.volumeHotkeyStep) {
                            ForEach(VolumeHotkeyStep.allCases) { step in
                                Text(step.description).tag(step)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
        }
    }

    // MARK: - Hotkeys

    private var hotkeysCard: some View {
        SettingsCard(title: "Hotkeys") {
            VStack(spacing: 0) {
                ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                    if index > 0 { CardRowDivider() }
                    CardRow(
                        icon: "keyboard",
                        title: action.displayName,
                        description: "Press a key combination to record"
                    ) {
                        KeyboardShortcuts.Recorder(
                            for: shortcutsRegistry.name(for: action),
                            onChange: shortcutsRegistry.recordCallback(for: action)
                        )
                    }
                }
            }
        }
    }
}
