// FineTune/Shortcuts/ShortcutAction.swift
import Foundation

/// Actions that can be bound to a user-recordable global keyboard shortcut.
///
/// Adding a new action here is a single enum case + a corresponding arm
/// in `ShortcutsRegistry.dispatch(_:)`. The `rawValue` is the persistence key
/// in `AppSettings.customShortcuts` and must be stable across releases.
enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case togglePopup
    case frontmostAppVolumeUp
    case frontmostAppVolumeDown
    case frontmostAppMuteToggle

    var displayName: String {
        switch self {
        case .togglePopup: "Toggle FineTune Popup"
        case .frontmostAppVolumeUp: "Frontmost App Volume Up"
        case .frontmostAppVolumeDown: "Frontmost App Volume Down"
        case .frontmostAppMuteToggle: "Frontmost App Mute Toggle"
        }
    }
}
