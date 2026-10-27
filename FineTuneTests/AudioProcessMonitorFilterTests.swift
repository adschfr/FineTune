// FineTuneTests/AudioProcessMonitorFilterTests.swift
//
// Processes the monitor must never list or tap: audio processes of other logged-in
// users (tapping them silences their session, #418), System Settings panes (#427) and
// system daemons.

import Foundation
import Testing
@testable import FineTune

@Suite("AudioProcessMonitor: processes of other users are skipped (#418)")
struct AudioProcessMonitorOwnershipTests {

    @Test("This process belongs to the current user")
    func ownProcessIsOwned() {
        #expect(AudioProcessMonitor.isOwnedByCurrentUser(getpid()))
    }

    @Test("A process of another user (launchd, root) is not ours")
    func rootProcessIsNotOwned() {
        #expect(!AudioProcessMonitor.isOwnedByCurrentUser(1))
    }

    @Test("An unknown PID counts as ours, so a failed lookup never hides an app")
    func unknownPIDCountsAsOwned() {
        #expect(AudioProcessMonitor.isOwnedByCurrentUser(pid_t(Int32.max - 1)))
    }
}

@Suite("AudioProcessMonitor: system processes and Settings panes are not apps (#427)")
@MainActor
struct AudioProcessMonitorDaemonFilterTests {

    @Test("System Settings panes are filtered", arguments: [
        "com.apple.Sound-Settings.extension",
        "com.apple.Bluetooth-Settings.extension",
    ])
    func settingsPanesAreFiltered(bundleID: String) {
        #expect(AudioProcessMonitor.isSystemDaemon(bundleID: bundleID, name: "Settings"))
    }

    @Test("Apps are kept, including a third-party bundle that ends like a Settings pane", arguments: [
        "com.apple.Music",
        "com.spotify.client",
        "org.example.Audio-Settings.extension",
    ])
    func appsAreKept(bundleID: String) {
        #expect(!AudioProcessMonitor.isSystemDaemon(bundleID: bundleID, name: "Player"))
    }

    @Test("Daemons are filtered by bundle ID prefix or by process name")
    func daemonsAreFiltered() {
        #expect(AudioProcessMonitor.isSystemDaemon(bundleID: "com.apple.systemsound.server", name: "x"))
        #expect(AudioProcessMonitor.isSystemDaemon(bundleID: nil, name: "systemsoundserverd"))
        #expect(AudioProcessMonitor.isSystemDaemon(bundleID: nil, name: "coreaudiod"))
    }
}
