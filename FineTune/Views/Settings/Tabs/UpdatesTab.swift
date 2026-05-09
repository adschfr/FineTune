// FineTune/Views/Settings/Tabs/UpdatesTab.swift
import SwiftUI

@MainActor
struct UpdatesTab: View {
    @ObservedObject var updateManager: UpdateManager

    private var lastCheckDescription: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        if let date = updateManager.lastUpdateCheckDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Version \(version) · \(formatter.localizedString(for: date, relativeTo: .now))"
        }
        return "Version \(version) · Never checked"
    }

    private var automaticallyChecksBinding: Binding<Bool> {
        Binding(
            get: { updateManager.automaticallyChecksForUpdates },
            set: { updateManager.automaticallyChecksForUpdates = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 20) {
            SettingsCard(title: "Software Updates") {
                VStack(spacing: 0) {
                    CardRow(
                        icon: "arrow.down.circle",
                        title: "Automatic updates",
                        description: "Check for new versions automatically"
                    ) {
                        Toggle("", isOn: automaticallyChecksBinding)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }

                    CardRowDivider()

                    CardRow(
                        icon: "clock",
                        title: "Last checked",
                        description: lastCheckDescription
                    ) {
                        Button("Check Now") {
                            updateManager.checkForUpdates()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}
