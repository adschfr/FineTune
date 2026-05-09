// FineTune/Views/Settings/SettingsRootView.swift
import SwiftUI

@MainActor
struct SettingsRootView: View {
    @Bindable var settings: SettingsManager
    @Bindable var audioEngine: AudioEngine
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor
    @Bindable var accessibility: AccessibilityPermissionService
    @Bindable var mediaKeyStatus: MediaKeyStatus
    let mediaKeyMonitor: MediaKeyMonitor
    @ObservedObject var updateManager: UpdateManager

    enum Section: String, Hashable, CaseIterable, Identifiable {
        case general, audio, shortcuts, updates, about
        var id: Self { self }

        var label: String {
            switch self {
            case .general: return "General"
            case .audio: return "Audio"
            case .shortcuts: return "Shortcuts"
            case .updates: return "Updates"
            case .about: return "About"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .audio: return "speaker.wave.2"
            case .shortcuts: return "command"
            case .updates: return "arrow.triangle.2.circlepath"
            case .about: return "info.circle"
            }
        }
    }

    @State private var selection: Section = .general

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.label, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            ScrollView {
                content
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 540)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .general:
            GeneralTab(
                settings: settings,
                onResetAll: {
                    audioEngine.handleSettingsReset()
                    deviceVolumeMonitor.setSystemFollowDefault()
                }
            )
        case .audio:
            AudioTab(
                settings: settings,
                audioEngine: audioEngine,
                deviceVolumeMonitor: deviceVolumeMonitor
            )
        case .shortcuts:
            ShortcutsTab(
                settings: settings,
                accessibility: accessibility,
                mediaKeyStatus: mediaKeyStatus,
                mediaKeyMonitor: mediaKeyMonitor
            )
        case .updates:
            UpdatesTab(updateManager: updateManager)
        case .about:
            AboutTab()
        }
    }
}
