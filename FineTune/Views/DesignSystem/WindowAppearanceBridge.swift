// FineTune/Views/DesignSystem/WindowAppearanceBridge.swift
import SwiftUI
import AppKit

/// Bridges a SwiftUI body's resolved `NSAppearance?` to its host `NSWindow`'s
/// `.appearance` property. Insert as an invisible (`.frame(width: 0, height: 0)`)
/// background or overlay in views that own a window's appearance.
///
/// Why a bridge: `.preferredColorScheme(...)` only changes SwiftUI's color
/// resolution. The underlying NSWindow / NSPanel keeps its own NSAppearance,
/// which is what governs `NSVisualEffectView` material rendering. Without this
/// bridge, applying `.preferredColorScheme(.light)` would change SwiftUI Colors
/// but leave a `.regularMaterial` background rendering as dark glass.
struct WindowAppearanceBridge: NSViewRepresentable {
    /// The desired `NSAppearance` to apply to the host window. `nil` means
    /// "inherit from the application", which is correct for the System mode.
    let appearance: NSAppearance?

    func makeNSView(context: Context) -> WindowAppearanceTrackerView {
        WindowAppearanceTrackerView()
    }

    func updateNSView(_ nsView: WindowAppearanceTrackerView, context: Context) {
        nsView.desiredAppearance = appearance
    }
}

/// Private NSView subclass that retains the desired appearance and re-applies
/// it on `viewDidMoveToWindow`. This catches the case where the initial
/// `updateNSView` runs before SwiftUI has parented the hosting view into a
/// window — when the window finally arrives, we still apply the correct value.
final class WindowAppearanceTrackerView: NSView {
    var desiredAppearance: NSAppearance? {
        didSet { window?.appearance = desiredAppearance }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.appearance = desiredAppearance
    }
}
