// FineTune/Views/MenuBar/MenuBarIconImage+NSImage.swift
// AppKit bridge for MenuBarIconImage — kept separate so the value types
// file (MenuBarIconState.swift) stays AppKit-free and the Equatable
// conformances remain nonisolated under Swift 6 strict concurrency.

import AppKit

@MainActor
extension MenuBarIconImage {
    func nsImage(accessibilityDescription: String = "FineTune") -> NSImage? {
        switch self {
        case .systemSymbol(let name):
            let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)
            image?.isTemplate = true
            return image
        case .asset(let name):
            return NSImage(named: name)
        }
    }
}
