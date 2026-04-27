// FineTune/Views/DesignSystem/VisualEffectBackground.swift
import SwiftUI
import AppKit

/// A dark frosted glass background using NSVisualEffectView
/// Provides deeper vibrancy than SwiftUI's built-in materials
/// Updated for macOS 26+ Liquid Glass aesthetic
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Colors

extension Color {
    /// Popup background overlay - uses theme-aware color from DesignTokens
    /// Darker than before for more contrast with floating glass rows
    static var popupBackgroundOverlay: Color { DesignTokens.Colors.popupOverlay }
}

// MARK: - View Extensions

extension View {
    /// Applies a dark glass background using NSVisualEffectView
    /// The primary popup container style - darker to make floating rows pop
    func darkGlassBackground() -> some View {
        self
            .background(Color.popupBackgroundOverlay)
            .background(VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow))
    }

    /// Applies EQ panel glass background (recessed style)
    func eqPanelBackground() -> some View {
        modifier(EQPanelBackgroundModifier())
    }
}

// MARK: - EQ Panel Background Modifier

/// Modifier that applies glass background to EQ panel
/// Locked to recessed style: dark overlay with subtle border
struct EQPanelBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                    .fill(DesignTokens.Colors.recessedBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                    .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
            }
    }
}

// MARK: - Previews

#Preview("Dark Glass Popup Background") {
    VStack(spacing: 16) {
        Text("OUTPUT DEVICES")
            .sectionHeaderStyle()
        Text("Dark frosted glass background")
            .foregroundStyle(.primary)
    }
    .padding(DesignTokens.Spacing.lg)
    .frame(width: 300)
    .darkGlassBackground()
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Dimensions.cornerRadius))
    .environment(\.colorScheme, .dark)
}

#Preview("EQ Panel - Recessed") {
    VStack(spacing: 8) {
        Text("EQ Panel - Recessed")
            .foregroundStyle(.secondary)
        HStack {
            ForEach(0..<5) { _ in
                Rectangle()
                    .fill(.secondary.opacity(0.3))
                    .frame(width: 20, height: 60)
            }
        }
    }
    .padding()
    .eqPanelBackground()
    .padding()
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
