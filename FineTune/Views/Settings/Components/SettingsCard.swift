// FineTune/Views/Settings/Components/SettingsCard.swift
import SwiftUI

@MainActor
struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(DesignTokens.Typography.cardHeader)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.top, DesignTokens.Spacing.md)
                .padding(.bottom, DesignTokens.Spacing.sm)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCardBackground()
    }
}

// MARK: - Previews

#Preview("Settings Card") {
    VStack(spacing: 20) {
        SettingsCard(title: "Startup") {
            Text("Card body content goes here.")
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .padding(DesignTokens.Spacing.md)
        }

        SettingsCard(title: "Devices") {
            VStack(spacing: 0) {
                Text("Row 1").padding(DesignTokens.Spacing.md)
                Divider().opacity(0.3).padding(.horizontal, DesignTokens.Spacing.md)
                Text("Row 2").padding(DesignTokens.Spacing.md)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    .padding(24)
    .frame(width: 520, height: 320)
    .background(Color(nsColor: .windowBackgroundColor))
    .environment(\.colorScheme, .dark)
}
