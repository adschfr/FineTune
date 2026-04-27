// FineTune/Views/DesignSystem/VisualEffectBackground.swift
import SwiftUI
import AppKit

/// A frosted glass background using NSVisualEffectView, Apple's documented
/// translucent material primitive. The default `.popover` material renders
/// as proper light/dark glass and matches the platform Control Center and
/// Notification Center surfaces.
struct VisualEffectBackground: NSViewRepresentable {
    /// Apple's documented material for popover and menu-bar panels. Renders
    /// vibrant translucency in both appearances. The previous `.hudWindow`
    /// default was designed for dark floating overlays and washed out badly
    /// in light mode.
    var material: NSVisualEffectView.Material = .popover
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
    /// Applies the popup's translucent glass background. Adapts to light and
    /// dark via DesignTokens; the underlying NSVisualEffectView uses the
    /// `.popover` material so it tracks system appearance natively.
    /// Name kept for source compatibility; rename pending a follow-up sweep.
    func darkGlassBackground() -> some View {
        self
            .background(Color.popupBackgroundOverlay)
            .background(VisualEffectBackground(material: .popover, blendingMode: .behindWindow))
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
