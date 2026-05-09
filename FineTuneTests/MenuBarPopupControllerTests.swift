// FineTuneTests/MenuBarPopupControllerTests.swift
import Testing
import AppKit
@testable import FineTune

@Suite("MenuBarPopupController")
@MainActor
struct MenuBarPopupControllerTests {
    @Test("toggle is a no-op when no matching status item exists")
    func noMatchingItem() {
        // Use a deliberately unique accessibility title so no real status item
        // (e.g. one materialized by another concurrently-running test) can match.
        let controller = MenuBarPopupController(accessibilityTitle: "FineTuneTest-NoSuchItem-\(UUID().uuidString)")
        controller.toggle()  // must not crash; logs a debug message and returns
    }

    @Test("toggle posts a left-mouse-down event when a matching status item exists")
    func toggleWithMatchingItem() {
        let title = "FineTuneTest-Match-\(UUID().uuidString)"
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.setAccessibilityTitle(title)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }

        // Force the system to materialize the button window so windowNumber is valid.
        _ = statusItem.button?.window?.windowNumber

        let controller = MenuBarPopupController(accessibilityTitle: title)

        var capturedTypes: [NSEvent.EventType] = []
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            capturedTypes.append(event.type)
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }

        controller.toggle()

        // Pump the run loop until the posted event is delivered, with a generous timeout.
        let until = Date().addingTimeInterval(0.5)
        while capturedTypes.isEmpty && Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        #expect(capturedTypes.contains(.leftMouseDown))
    }
}
