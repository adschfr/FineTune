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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                mediaKeysSection
                hotkeysSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .onChange(of: settings.appSettings.mediaKeyControlEnabled) { _, _ in
            mediaKeyMonitor.reconcile()
        }
    }

    // MARK: - Media Keys

    private var mediaKeysSection: some View {
        SettingsSection("Media Keys") {
            SettingsRow(
                "Media Keys Control",
                description: "Use F11/F12 (or volume keys) to control FineTune"
            ) {
                Toggle("", isOn: $settings.appSettings.mediaKeyControlEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            if !accessibility.isTrustedCached {
                SettingsRowDivider()
                AccessibilityPromptStrip(accessibility: accessibility)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            if mediaKeyStatus.isOffline {
                SettingsRowDivider()
                MediaKeyOfflineCard {
                    mediaKeyMonitor.reconcile()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            if settings.appSettings.mediaKeyControlEnabled && accessibility.isTrustedCached {
                SettingsRowDivider()
                SettingsRow(
                    "HUD Style",
                    description: "How the volume indicator appears"
                ) {
                    HUDStyleSegmentedControl(selection: $settings.appSettings.hudStyle)
                }

                SettingsRowDivider()
                SettingsRow(
                    "Volume Step",
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

    // MARK: - Hotkeys

    private var hotkeysSection: some View {
        SettingsSection("Hotkeys") {
            ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                if index > 0 { SettingsRowDivider() }
                SettingsRow(action.displayName) {
                    KeyboardShortcuts.Recorder(
                        for: shortcutsRegistry.name(for: action),
                        onChange: shortcutsRegistry.recordCallback(for: action)
                    )
                }
            }
        }
    }
}
