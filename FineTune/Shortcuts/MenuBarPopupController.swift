// FineTune/Shortcuts/MenuBarPopupController.swift
import AppKit
import os

/// Toggles the FluidMenuBarExtra popup from outside the SwiftUI scene chain.
///
/// FluidMenuBarExtra hides its popup window behind a `LocalEventMonitor` that
/// listens for left-mouse-down events on the status item button. We trigger a
/// toggle by capturing the underlying `NSStatusItem` (via the package's
/// `onStatusItemReady` callback) and posting a synthetic `.leftMouseDown` event
/// aimed at the button's window. The event is dispatched through
/// `NSApp.sendEvent`, which is exactly what the package's monitor observes —
/// reusing its existing visible→dismiss / hidden→show toggle logic.
@MainActor
protocol MenuBarPopupControlling: AnyObject {
    func toggle()
}

@MainActor
final class MenuBarPopupController: MenuBarPopupControlling {
    private static let logger = Logger(
        subsystem: "com.finetuneapp.FineTune",
        category: "MenuBarPopupController"
    )

    private weak var statusItem: NSStatusItem?

    func attach(_ statusItem: NSStatusItem) {
        self.statusItem = statusItem
    }

    func toggle() {
        guard let button = statusItem?.button, let window = button.window else {
            Self.logger.debug("toggle called with no attached status item; ignoring")
            return
        }

        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

        let location = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            Self.logger.error("Failed to construct synthetic mouse-down event")
            return
        }

        NSApp.postEvent(event, atStart: false)
    }
}
