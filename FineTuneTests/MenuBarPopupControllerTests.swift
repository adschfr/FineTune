// FineTuneTests/MenuBarPopupControllerTests.swift
import Testing
import AppKit
@testable import FineTune

@Suite("MenuBarPopupController")
@MainActor
struct MenuBarPopupControllerTests {
    @Test("toggle is a no-op when not attached")
    func unattached() {
        let controller = MenuBarPopupController()
        // Should not crash; no-op when no NSStatusItem is attached.
        controller.toggle()
    }

    @Test("toggle posts a left-mouse-down event when attached")
    func toggleWhenAttached() {
        let controller = MenuBarPopupController()
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }

        // Force the system to materialize the button (and its window) so windowNumber is valid.
        _ = statusItem.button?.window?.windowNumber

        controller.attach(statusItem)

        var capturedTypes: [NSEvent.EventType] = []
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            capturedTypes.append(event.type)
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }

        controller.toggle()

        // Allow the run loop to pump the posted event.
        let until = Date().addingTimeInterval(0.5)
        while capturedTypes.isEmpty && Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        #expect(capturedTypes.contains(.leftMouseDown))
    }
}
