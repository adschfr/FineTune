import SwiftUI

/// Combined settings row for loudness compensation toggle and amount slider.
struct SettingsLoudnessCompensationRow: View {
    @Binding var isOn: Bool
    @Binding var amount: Float

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
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

                    Text("Maintains tonal balance at low listening levels")
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

            if isOn {
                HStack(spacing: DesignTokens.Spacing.md) {
                    Color.clear
                        .frame(width: DesignTokens.Dimensions.settingsIconWidth)

                    Spacer(minLength: DesignTokens.Spacing.sm)

                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Text("Strength")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Colors.textTertiary)

                        Slider(
                            value: Binding(
                                get: { Double(amount) },
                                set: { amount = Float($0) }
                            ),
                            in: 0.0...1.0
                        )
                        .frame(width: DesignTokens.Dimensions.settingsSliderWidth)

                        EditablePercentage(
                            percentage: Binding(
                                get: { Int(round(amount * 100)) },
                                set: { amount = Float($0) / 100.0 }
                            ),
                            range: 0...100
                        )
                        .frame(width: DesignTokens.Dimensions.settingsPercentageWidth, alignment: .trailing)
                    }
                }
            }
        }
        .hoverableRow()
    }
}

#Preview("Loudness Compensation Row") {
    VStack(spacing: DesignTokens.Spacing.sm) {
        SettingsLoudnessCompensationRow(
            isOn: .constant(true),
            amount: .constant(0.65)
        )
    }
    .padding()
    .frame(width: 450)
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
