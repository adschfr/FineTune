import SwiftUI

/// Settings row for unified loudness compensation + equalization toggle.
struct SettingsLoudnessCompensationRow: View {
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "ear")
                .font(.system(size: DesignTokens.Dimensions.iconSizeSmall))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DesignTokens.Colors.interactiveDefault)
                .frame(width: DesignTokens.Dimensions.settingsIconWidth, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text("Loudness Equalization")
                    .font(DesignTokens.Typography.rowName)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Text("Balances frequency response and volume levels at low listening levels")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .scaleEffect(0.8)
                .labelsHidden()
        }
        .hoverableRow()
    }
}

#Preview("Loudness Compensation Row") {
    VStack(spacing: DesignTokens.Spacing.sm) {
        SettingsLoudnessCompensationRow(
            isOn: .constant(true)
        )
    }
    .padding()
    .frame(width: 450)
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
