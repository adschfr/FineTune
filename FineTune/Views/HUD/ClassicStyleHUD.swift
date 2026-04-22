// FineTune/Views/HUD/ClassicStyleHUD.swift
import SwiftUI

/// 200×200 pre-Tahoe-style volume HUD: 80 pt glyph + 16-tile segment row. Stateless.
struct ClassicStyleHUD: View {
    let volume: Float
    let mute: Bool

    // MARK: - Constants

    static let hasPercentageLabel: Bool = false

    private static let tileCount: Int = 16
    private static let frameSize: CGFloat = 200
    private static let cornerRadius: CGFloat = 16
    private static let iconSize: CGFloat = 80
    private static let tileSize: CGFloat = 7.5
    private static let tileSpacing: CGFloat = 2
    private static let tileSideInset: CGFloat = 20

    // MARK: - Derived state

    private var displayValue: Float {
        mute ? 0 : max(0, min(1, volume))
    }

    private var filledTileCount: Int {
        let clamped = max(0, min(1, displayValue))
        return Int((clamped * Float(Self.tileCount)).rounded())
    }

    private var waveIconName: String {
        switch displayValue {
        case ..<0.01:  return "speaker.fill"
        case ..<0.34:  return "speaker.wave.1.fill"
        case ..<0.67:  return "speaker.wave.2.fill"
        default:       return "speaker.wave.3.fill"
        }
    }

    /// `speaker.slash.fill` sits 2pt high vs the rest of the `speaker.*` glyphs at 80pt.
    private var iconYOffset: CGFloat {
        (mute || displayValue <= 0.001) ? 2 : 0
    }

    private var accessibilityDescription: String {
        if mute { return "Muted" }
        return "Volume \(Int((displayValue * 100).rounded())) percent"
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            iconSection
            tileSection
        }
        .frame(width: Self.frameSize, height: Self.frameSize)
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var iconSection: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 56)
            // Hard-swap — symbolEffect(.replace.*) cross-fades the whole wave glyph on every bin change.
            Image(systemName: mute ? "speaker.slash.fill" : waveIconName)
                .font(.system(size: Self.iconSize, weight: .medium))
                .foregroundStyle(DesignTokens.Colors.hudTileActive)
                .offset(y: iconYOffset)
            Spacer()
        }
        .frame(height: 100)
    }

    private var tileSection: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 40)
            HStack(spacing: Self.tileSpacing) {
                Spacer().frame(width: Self.tileSideInset)
                ForEach(0..<Self.tileCount, id: \.self) { index in
                    Rectangle()
                        .fill(index < filledTileCount
                              ? DesignTokens.Colors.hudTileActive
                              : DesignTokens.Colors.hudTileInactive)
                        .frame(width: Self.tileSize, height: Self.tileSize)
                }
                Spacer().frame(width: Self.tileSideInset)
            }
            .animation(DesignTokens.Animation.quick, value: filledTileCount)
        }
        .frame(height: 80)
    }
}

#Preview("Classic — mid volume") {
    ClassicStyleHUD(volume: 0.5, mute: false)
        .padding()
        .background(Color.black)
}

#Preview("Classic — muted") {
    ClassicStyleHUD(volume: 0.5, mute: true)
        .padding()
        .background(Color.black)
}

#Preview("Classic — max volume") {
    ClassicStyleHUD(volume: 1.0, mute: false)
        .padding()
        .background(Color.black)
}

#Preview("Classic — zero volume") {
    ClassicStyleHUD(volume: 0.0, mute: false)
        .padding()
        .background(Color.black)
}
