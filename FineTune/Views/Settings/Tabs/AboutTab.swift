// FineTune/Views/Settings/Tabs/AboutTab.swift
import AppKit
import SwiftUI

@MainActor
struct AboutTab: View {
    private var versionShort: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private var yearText: String {
        let startYear = 2026
        let currentYear = Calendar.current.component(.year, from: .now)
        return startYear == currentYear ? "\(startYear)" : "\(startYear)-\(currentYear)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)

                Text("FineTune")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Text("Version \(versionShort) (\(buildNumber))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                AboutLinkChip(
                    label: "Donate",
                    icon: "heart.fill",
                    hoverIcon: "heart.fill",
                    hoverColor: .pink,
                    url: DesignTokens.Links.support,
                    isPrimary: true
                )
                AboutLinkChip(
                    label: "Star on GitHub",
                    icon: "star",
                    hoverIcon: "star.fill",
                    hoverColor: .yellow,
                    url: URL(string: "https://github.com/ronitsingh10/FineTune")!
                )
            }

            footer
                .padding(.top, 16)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                NSWorkspace.shared.open(DesignTokens.Links.license)
            } label: {
                Text("GPL-3.0")
            }
            .buttonStyle(.plain)

            Text("·")
            Text("© \(yearText) Ronit Singh")
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
    }
}
