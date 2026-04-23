// FineTune/Views/Settings/SettingsIconPickerRow.swift
import SwiftUI

/// Settings row with visual icon selector for menu bar icon style
struct SettingsIconPickerRow: View {
    let icon: String
    let title: String
    @Binding var selection: MenuBarIconStyle

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .frame(width: DesignTokens.Dimensions.settingsIconWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignTokens.Typography.rowName)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Text("Choose your preferred icon style")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }

            Spacer()

            HStack(spacing: 4) {
                ForEach(MenuBarIconStyle.allCases) { style in
                    IconOption(style: style, isSelected: selection == style) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selection = style
                        }
                    }
                }
            }
        }
        .hoverableRow()
    }
}

/// Individual icon option button (compact for inline display)
private struct IconOption: View {
    let style: MenuBarIconStyle
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Group {
                if style.isSystemSymbol {
                    Image(systemName: style.iconName)
                        .font(.system(size: 14))
                } else {
                    Image(style.iconName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                }
            }
            .foregroundStyle(isSelected ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? DesignTokens.Colors.accentPrimary.opacity(0.15) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? DesignTokens.Colors.accentPrimary : Color.clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Previews

#Preview("Icon Picker Row") {
    VStack(spacing: DesignTokens.Spacing.sm) {
        SettingsIconPickerRow(
            icon: "menubar.rectangle",
            title: "Menu Bar Icon",
            selection: .constant(.default)
        )

        SettingsIconPickerRow(
            icon: "menubar.rectangle",
            title: "Menu Bar Icon",
            selection: .constant(.speaker)
        )
    }
    .padding(DesignTokens.Spacing.lg)
    .frame(width: DesignTokens.Dimensions.popupWidth)
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
