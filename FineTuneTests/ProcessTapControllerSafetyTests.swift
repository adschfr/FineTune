// FineTuneTests/ProcessTapControllerSafetyTests.swift
//
// Guards for the fork's spike fix: every tap keeps its processes muted for the tap's
// whole lifetime (CATapMuted), so audio that starts before the IO proc runs, or while
// the tap is suspended, never reaches the device unprocessed. Upstream uses
// .mutedWhenTapped; a merge that brings it back must fail here.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import FineTune

@Suite("Process tap descriptions keep the app muted for the tap's lifetime (#268, #273, #455)")
@MainActor
struct ProcessTapDescriptionTests {

    @Test("Stream tap: muted, private, scoped to the app's processes and device")
    func streamTapDescription() {
        let description = ProcessTapController.makeStreamTapDescription(processes: [11, 12], deviceUID: "uid-tv", stream: 0)

        #expect(description.muteBehavior == .muted)
        #expect(description.isPrivate)
        #expect(!description.isExclusive)
        #expect(description.processes == [11, 12])
        #expect(description.deviceUID == "uid-tv")
    }

    @Test("Mixdown fallback tap: muted, private, scoped to the app's processes")
    func mixdownTapDescription() {
        let description = ProcessTapController.makeMixdownTapDescription(processes: [21])

        #expect(description.muteBehavior == .muted)
        #expect(description.isPrivate)
        #expect(!description.isExclusive)
        #expect(description.isMixdown)
        #expect(description.processes == [21])
    }

    @Test("Each description gets its own UUID")
    func descriptionsHaveDistinctUUIDs() {
        let first = ProcessTapController.makeMixdownTapDescription(processes: [21])
        let second = ProcessTapController.makeMixdownTapDescription(processes: [21])

        #expect(first.uuid != second.uuid)
    }
}

@Suite("ProcessTapController lifecycle guards before activation")
@MainActor
struct ProcessTapControllerLifecycleGuardTests {

    private func makeApp(pid: pid_t = 777, processes: [AudioObjectID] = [11]) -> AudioApp {
        AudioApp(id: pid, processObjectIDs: processes, name: "Guard", icon: NSImage(), bundleID: "com.test.guard")
    }

    @Test("suspend() does nothing on a tap that was never activated")
    func suspendRequiresActivation() {
        let controller = ProcessTapController(app: makeApp(), targetDeviceUID: "uid-tv")

        controller.suspend()

        #expect(!controller.isSuspended)
    }

    @Test("resume() on a tap that is not suspended is a no-op")
    func resumeWithoutSuspendIsNoOp() throws {
        let controller = ProcessTapController(app: makeApp(), targetDeviceUID: "uid-tv")

        try controller.resume()

        #expect(!controller.isSuspended)
    }

    @Test("updateProcesses adopts a changed process list before activation without Core Audio")
    func updateProcessesBeforeActivation() {
        let controller = ProcessTapController(app: makeApp(processes: [11]), targetDeviceUID: "uid-tv")

        let accepted = controller.updateProcesses(for: makeApp(processes: [11, 12]))

        #expect(accepted)
        #expect(controller.app.processObjectIDs == [11, 12])
    }

    @Test("updateProcesses ignores an app with a different PID")
    func updateProcessesIgnoresOtherApp() {
        let controller = ProcessTapController(app: makeApp(pid: 777, processes: [11]), targetDeviceUID: "uid-tv")

        let accepted = controller.updateProcesses(for: makeApp(pid: 778, processes: [31]))

        #expect(accepted)
        #expect(controller.app.id == 777)
        #expect(controller.app.processObjectIDs == [11])
    }
}
