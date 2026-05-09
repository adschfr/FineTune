// FineTune/Views/Settings/Components/CardRow.swift
import SwiftUI

@MainActor
struct CardRow<Trailing: View>: View {
    let icon: String
    let title: String
    let description: String?
    @ViewBuilder let trailing: () -> Trailing

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    init(
        icon: String,
        title: String,
        description: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.icon = icon
        self.title = title
        self.description = description
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .font(.system(size: 16))
                .frame(width: 28, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                if let description {
                    Text(description)
                        .font(DesignTokens.Typography.rowDescription)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: DesignTokens.Spacing.md)

            trailing()
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, 10)
        .frame(minHeight: 50)
        .background(isHovered ? Color.white.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : DesignTokens.Animation.hover) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Card Row Divider

struct CardRowDivider: View {
    var body: some View {
        Divider()
            .opacity(0.3)
            .padding(.horizontal, DesignTokens.Spacing.md)
    }
}

// MARK: - Previews

#Preview("Card Row") {
    SettingsCard(title: "Devices") {
        VStack(spacing: 0) {
            CardRow(
                icon: "mic",
                title: "Lock Input Device",
                description: "Prevent auto-switching when devices connect"
            ) {
                Toggle("", isOn: .constant(true)).labelsHidden()
            }
            CardRowDivider()
            CardRow(
                icon: "speaker.wave.2",
                title: "Default Volume",
                description: "Initial volume for new apps"
            ) {
                Text("100%")
                    .font(DesignTokens.Typography.percentage)
                    .foregroundStyle(.secondary)
            }
        }
    }
    .padding(24)
    .frame(width: 520, height: 220)
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
