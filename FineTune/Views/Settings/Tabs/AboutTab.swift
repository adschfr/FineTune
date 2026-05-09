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
                    label: "Star on GitHub",
                    icon: "star",
                    hoverIcon: "star.fill",
                    hoverColor: .yellow,
                    url: URL(string: "https://github.com/ronitsingh10/FineTune")!
                )
                AboutLinkChip(
                    label: "Support FineTune",
                    icon: "heart",
                    hoverIcon: "heart.fill",
                    hoverColor: .pink,
                    url: DesignTokens.Links.support
                )
                AboutLinkChip(
                    label: "GPL-3.0",
                    icon: "doc.text",
                    hoverIcon: "doc.text.fill",
                    hoverColor: .blue,
                    url: DesignTokens.Links.license
                )
            }

            Text("© \(yearText) Ronit Singh")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.top, 16)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
