// FineTuneTests/CatchAllCoordinatorFormatTests.swift
//
// Format and rate changes of the coordinator (design §16.3 E15, §16.12 item 3, §16.8 test 5):
// the format hold, its 2 s watchdog, formatUnchanged during the coordinator's own rebuild, the
// make-before-break rebuild after formatChanged and when that call returns, and the run
// control's rate report. Fake claim owners, fake IsAlive observations and one ordered log per
// test; no Core Audio object is created.

import AudioToolbox
import Foundation
import Synchronization
import Testing
@testable import FineTune

/// Whether the catch-all's output is held.
private func held(_ controller: CatchAllTapController) -> Bool {
    controller.renderState.held.load(ordering: .relaxed)
}

/// `waitUntil` with room for a main actor that other suites block for a while.
private func eventually(_ condition: () -> Bool) async -> Bool {
    await waitUntil(condition)
}

/// Catch-alls built so far, failed builds included.
private func builds(_ rig: CatchAllCoordinatorRig) -> Int {
    rig.backend.log.filter { $0 == "createTap" }.count
}

private func failures(_ rig: CatchAllCoordinatorRig) -> [CatchAllEvent] {
    rig.events.events.filter { if case .failure = $0 { true } else { false } }
}

private func formatSteps(_ rig: CatchAllCoordinatorRig) -> [CatchAllFormatStep] {
    rig.events.events.compactMap { if case .format(_, let step) = $0 { step } else { nil } }
}

/// One ordered log in short lines: format steps, output changes, takeovers, watchdogs,
/// retirements and ends, counted failures, builds, attaches, detaches and destroys.
private func formatTrace(_ rig: CatchAllCoordinatorRig) -> LineLog {
    let log = LineLog()
    let events = rig.events
    rig.runControl.onRecord = { line in
        if line.hasPrefix("attach") || line.hasPrefix("detach") { log.add(line) }
    }
    rig.backend.onRecord = { entry in
        if entry == "createTap" || entry.hasPrefix("destroy") { log.add(entry) }
    }
    rig.coordinator.onEvent = { event in
        events.events.append(event)
        switch event {
        case .format(let uid, let step):
            log.add("format \(step.rawValue) \(uid)")
        case .output(_, let aggregate, let isHeld):
            log.add("\(isHeld ? "hold" : "open") \(aggregate)")
        case .rebuilt(let uid):
            log.add("rebuilt \(uid)")
        case .watchdog(let uid, let kind):
            log.add("watchdog \(kind.rawValue) \(uid)")
        case .retiring(let uid, let reason):
            log.add("retiring \(uid) \(reason.rawValue)")
        case .ended(let uid, let reason):
            log.add("ended \(uid) \(reason)")
        case .failure(let uid, let failure):
            log.add("failure \(failure.rawValue) \(uid)")
        default:
            break
        }
    }
    return log
}

/// The lines that follow at once from a call, without the detaches and destroys, which run in
/// tasks of their own.
private func syncLines(_ log: LineLog) -> [String] {
    log.all.filter { !$0.hasPrefix("detach") && !$0.hasPrefix("destroy") }
}

/// Calls `formatChanged` in a task, as the engine's format handler does (row 9); the box turns
/// true once the call returned.
private func changeFormat(_ coordinator: CatchAllCoordinator, _ uid: String = "uid-tv") -> CoordinatorTestBox<Bool> {
    let returned = CoordinatorTestBox(false)
    Task {
        await coordinator.formatChanged(uid: uid)
        returned.value = true
    }
    return returned
}

/// The TV's catch-all goes dormant: the device stays listed but is no longer alive, and a
/// device-list refresh runs the E12 check in the coordinator's next turn.
private func makeDormant(_ rig: CatchAllCoordinatorRig) {
    rig.system.alive.remove(42)
    rig.coordinator.deviceListRefreshed()
    rig.clock.runDue()
}

/// A run-control report hopped to main: waits until the coordinator handled it.
private func report(_ rig: CatchAllCoordinatorRig, _ aggregate: AudioDeviceID,
                    _ reason: CatchAllRunLogic.RebuildReason = .rateMismatch) async {
    let done = CoordinatorTestBox(false)
    rig.runControl.onRebuild?("uid-tv", aggregate, reason)
    // The coordinator's hop is queued first, so this one runs after it
    DispatchQueue.main.async { MainActor.assumeIsolated { done.value = true } }
    _ = await eventually { done.value }
}

/// Runs `body` from a block of the main run loop rather than from a main-queue job, so a run
/// loop spun inside it (`spin`, a build's wait, V4) also runs main-actor tasks, such as the
/// engine's format handler.
private func onRunLoop(_ body: @escaping @MainActor @Sendable () -> Void) async {
    let done = CoordinatorTestBox(false)
    performOnRunLoop {
        body()
        done.value = true
    }
    _ = await eventually { done.value }
}

/// Posts `body` as a block of the main run loop, again until it runs where a spin drains the
/// main queue.
nonisolated private func performOnRunLoop(_ body: @escaping @MainActor @Sendable () -> Void) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
        MainActor.assumeIsolated {
            let drains = CoordinatorTestBox(false)
            Task { drains.value = true }
            spin(timeout: 0.05) { drains.value }
            guard drains.value else { return performOnRunLoop(body) }
            body()
        }
    }
    CFRunLoopWakeUp(CFRunLoopGetMain())
}

/// A build's wait spinning the main run loop, as the real one does (V4), until `condition`
/// holds or `timeout` passes.
private func spin(timeout: TimeInterval = 5, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
    }
}

@Suite("Catch-all coordinator format changes")
@MainActor
struct CatchAllCoordinatorFormatTests {

    // MARK: Hold and release

    @Test("formatChanging holds a live catch-all at once and formatUnchanged releases it; no watchdog fires after")
    func changingThenUnchanged() throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let tv = try #require(rig.tv)
        #expect(!held(tv))
        let log = formatTrace(rig)

        coordinator.formatChanging(uid: "uid-tv")
        #expect(held(tv))
        rig.clock.advance(1.5)
        #expect(held(tv))
        coordinator.formatUnchanged(uid: "uid-tv")
        #expect(!held(tv))
        rig.clock.advance(5)

        #expect(log.all == ["format held uid-tv", "hold 200", "format released uid-tv", "open 200"])
        #expect(builds(rig) == 1)
        // A second unchanged finds no hold
        coordinator.formatUnchanged(uid: "uid-tv")
        #expect(log.all.count == 4)
    }

    @Test("formatChanged rebuilds in E order: the new catch-all built held with the current list and attached, after 200 ms the old one held and the new one opened, the old one detached and destroyed. The format hold ends at the takeover, never before, and the call returns then, never building inside itself")
    func changedRebuildsInEOrder() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        let owner = FakeClaimOwner()
        _ = coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices))
        rig.clock.advance(1)
        let old = try #require(rig.tv)
        #expect(old.appliedExclusions == [5, 11])
        let log = formatTrace(rig)

        coordinator.formatChanging(uid: "uid-tv")
        let returned = changeFormat(coordinator)
        #expect(await eventually { coordinator.pendingFormatChangeCount == 1 })
        // The call only asked: the turn builds
        #expect(builds(rig) == 1)
        rig.clock.runDue()
        #expect(builds(rig) == 2)
        let new = try #require(rig.tv)
        #expect(new !== old)
        #expect(new.appliedExclusions == [5, 11])
        #expect(held(old) && held(new))

        rig.clock.advance(0.19)
        await settle()
        #expect(held(old) && held(new))
        #expect(!returned.value)
        #expect(coordinator.pendingFormatChangeCount == 1)

        rig.clock.advance(0.01)
        #expect(!held(new))
        #expect(held(old))
        #expect(coordinator.pendingFormatChangeCount == 0)
        #expect(await eventually { returned.value })
        #expect(await eventually { log.all.contains { $0.hasPrefix("destroy") } })
        #expect(log.all == [
            "format held uid-tv",
            "hold 200",
            "format rebuilding uid-tv",
            "createTap",
            "attach uid-tv [5, 11] held=true",
            "hold 200",
            "open 201",
            "rebuilt uid-tv",
            "detach uid-tv 200",
            "destroy tap=100 aggregate=200 proc=true",
        ])
        // The format watchdog ended with the call: nothing fires later
        rig.clock.advance(5)
        #expect(!rig.events.events.contains(.watchdog(uid: "uid-tv", .format)))
        #expect(failures(rig).isEmpty)
        withExtendedLifetime(owner) {}
    }

    @Test("formatChanged takes over at the new catch-all's first IO callback once its list applied")
    func changedTakesOverAtFirstCallback() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.formatChanging(uid: "uid-tv")
        let returned = changeFormat(coordinator)
        #expect(await eventually { coordinator.pendingFormatChangeCount == 1 })
        rig.clock.runDue()
        let new = try #require(rig.tv)

        rig.clock.advance(0.05)
        #expect(held(new))
        new.renderState.callbackCount.store(1, ordering: .relaxed)
        rig.clock.advance(0.01)
        #expect(!held(new))
        #expect(await eventually { returned.value })
    }

    // MARK: formatChanged bounds

    @Test("A failed rebuild returns formatChanged at once: on an alive device the failure settles with the old catch-all still held and then retires it, never opened; on a device that died the catch-all goes dormant uncounted, and its rebuild once alive opens without a format hold",
          arguments: ["settle", "dormant"])
    func changedRebuildFails(path: String) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let system = rig.system
        coordinator.start()
        rig.clock.runDue()
        let old = try #require(rig.tv)
        let log = formatTrace(rig)
        coordinator.formatChanging(uid: "uid-tv")
        if path == "settle" {
            rig.backend.failAt = .createTap
        } else {
            rig.backend.onWaitUntilReady = { MainActor.assumeIsolated { _ = system.alive.remove(42) } }
            rig.backend.failAt = .ready
        }
        let returned = changeFormat(coordinator)
        #expect(await eventually { coordinator.pendingFormatChangeCount == 1 })

        rig.clock.runDue()
        rig.backend.onWaitUntilReady = nil
        rig.backend.failAt = nil
        #expect(coordinator.pendingFormatChangeCount == 0)
        #expect(await eventually { returned.value })
        #expect(held(old))
        #expect(rig.tv === old)

        if path == "settle" {
            #expect(coordinator.phase("uid-tv") == .live)
            rig.clock.advance(CatchAllCoordinator.failureSettle)
            #expect(await eventually { log.all.contains { $0.hasPrefix("destroy") } })
            #expect(log.all == [
                "format held uid-tv",
                "hold 200",
                "format rebuilding uid-tv",
                "createTap",
                "failure buildFailed uid-tv",
                "retiring uid-tv rebuildFailed",
                "hold 200",
                "detach uid-tv 200",
                "ended uid-tv rebuildFailed",
                "destroy tap=100 aggregate=200 proc=true",
            ])
        } else {
            #expect(coordinator.phase("uid-tv") == .dormant)
            #expect(failures(rig).isEmpty)
            // Alive again: rebuilt from dormant, and the new one opens at its takeover
            system.alive.insert(42)
            rig.aliveObservers.fire(42)
            rig.clock.runDue()
            let new = try #require(rig.tv)
            #expect(new !== old)
            rig.clock.advance(0.2)
            #expect(!held(new))
            #expect(!syncLines(log).contains("open 200"))
            #expect(failures(rig).isEmpty)
        }
    }

    @Test("formatChanged on a dormant catch-all returns at once and builds nothing; formatChanging takes no hold there")
    func changedWhileDormant() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        makeDormant(rig)
        #expect(coordinator.phase("uid-tv") == .dormant)
        #expect(await eventually { rig.runControl.log.contains("detach uid-tv 200") })
        let log = formatTrace(rig)

        coordinator.formatChanging(uid: "uid-tv")
        coordinator.formatUnchanged(uid: "uid-tv")
        let returned = changeFormat(coordinator)
        #expect(await eventually { returned.value })
        rig.clock.advance(5)

        #expect(log.all.isEmpty)
        #expect(builds(rig) == 1)
        #expect(coordinator.phase("uid-tv") == .dormant)
    }

    @Test("formatChanged returns once its bound passed, here during a build that outlasts it, and reports it as a watchdog; the rebuild goes on and the format hold ends at its takeover")
    func changedReturnsAtBound() async throws {
        #expect(CatchAllCoordinator.formatChangeBound == CatchAllCoordinator.rebuildWatchdog + 2)
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let clock = rig.clock
        coordinator.start()
        rig.clock.runDue()
        let old = try #require(rig.tv)
        coordinator.formatChanging(uid: "uid-tv")
        let returned = changeFormat(coordinator)
        #expect(await eventually { coordinator.pendingFormatChangeCount == 1 })
        rig.backend.onWaitUntilReady = {
            MainActor.assumeIsolated { clock.advance(CatchAllCoordinator.formatChangeBound) }
        }

        rig.clock.runDue()
        rig.backend.onWaitUntilReady = nil
        #expect(coordinator.pendingFormatChangeCount == 0)
        #expect(await eventually { returned.value })
        #expect(rig.events.events.contains(.watchdog(uid: "uid-tv", .formatChange)))
        let new = try #require(rig.tv)
        #expect(new !== old)
        #expect(held(old) && held(new))

        rig.clock.advance(0.2)
        #expect(!held(new))
        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
    }

    @Test("stop() and G return a waiting formatChanged call at once, without its bound",
          arguments: ["stop", "absent"])
    func changeEndsWithCoverage(path: String) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.formatChanging(uid: "uid-tv")
        let returned = changeFormat(coordinator)
        #expect(await eventually { coordinator.pendingFormatChangeCount == 1 })
        // The rebuilt catch-all waits to take over
        rig.clock.runDue()
        #expect(builds(rig) == 2)
        #expect(coordinator.pendingFormatChangeCount == 1)

        if path == "stop" {
            coordinator.stop()
        } else {
            rig.system.outputs.removeAll { $0.uid == "uid-tv" }
            coordinator.deviceListRefreshed()
            rig.clock.runDue()
            #expect(coordinator.phase("uid-tv") == nil)
        }
        #expect(coordinator.pendingFormatChangeCount == 0)
        #expect(await eventually { returned.value })
        #expect(!rig.events.events.contains(.watchdog(uid: "uid-tv", .formatChange)))
    }

    // MARK: formatUnchanged during the coordinator's own rebuild

    @Test("formatUnchanged is ignored while the coordinator's own rebuild runs, at each stage: requested, postponed, building, waiting to take over; that rebuild's takeover ends the format hold",
          arguments: ["requested", "postponed", "building", "waiting"])
    func unchangedIgnoredDuringRebuild(stage: String) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let old = try #require(rig.tv)
        coordinator.formatChanging(uid: "uid-tv")
        #expect(held(old))

        coordinator.rebuild("uid-tv", reason: .ioFailed)
        switch stage {
        case "requested":
            coordinator.formatUnchanged(uid: "uid-tv")
            rig.clock.runDue()
        case "postponed":
            rig.system.processListReadable = false
            rig.clock.runDue()
            #expect(builds(rig) == 1)
            coordinator.formatUnchanged(uid: "uid-tv")
            rig.system.processListReadable = true
            rig.clock.advance(CatchAllCoordinator.processListRetryDelay)
        case "building":
            rig.backend.onWaitUntilReady = {
                MainActor.assumeIsolated { coordinator.formatUnchanged(uid: "uid-tv") }
            }
            rig.clock.runDue()
            rig.backend.onWaitUntilReady = nil
        default:
            rig.clock.runDue()
            coordinator.formatUnchanged(uid: "uid-tv")
        }
        #expect(builds(rig) == 2)
        let new = try #require(rig.tv)
        #expect(held(old) && held(new))
        #expect(formatSteps(rig) == [.held, .unchangedIgnored])

        rig.clock.advance(0.2)
        #expect(!held(new))
        #expect(held(old))
        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        rig.clock.advance(5)
        #expect(!held(new))
        #expect(!rig.events.events.contains(.watchdog(uid: "uid-tv", .format)))
    }

    @Test("A takeover ends the format hold only in place of a formatUnchanged it ignored or for the rebuild formatChanged asked for: after a formatChanging during another rebuild, the catch-all that took over stays held until formatUnchanged, the rebuild after formatChanged or the format watchdog",
          arguments: ["unchanged", "changed", "watchdog"])
    func takeoverKeepsHoldWithoutVerdict(verdict: String) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.rebuild("uid-tv", reason: .ioFailed)
        rig.clock.runDue()
        let new = try #require(rig.tv)
        // A change begins while the rebuilt catch-all waits to take over; it may postdate it
        rig.clock.advance(0.05)
        coordinator.formatChanging(uid: "uid-tv")
        rig.clock.advance(0.15)
        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        #expect(rig.tv === new)
        #expect(held(new))

        switch verdict {
        case "unchanged":
            coordinator.formatUnchanged(uid: "uid-tv")
            #expect(!held(new))
            #expect(formatSteps(rig) == [.held, .released])
        case "changed":
            let returned = changeFormat(coordinator)
            #expect(await eventually { coordinator.pendingFormatChangeCount == 1 })
            rig.clock.runDue()
            let third = try #require(rig.tv)
            #expect(third !== new)
            rig.clock.advance(0.2)
            #expect(!held(third))
            #expect(held(new))
            #expect(await eventually { returned.value })
        default:
            rig.clock.advance(1.84)
            #expect(held(new))
            rig.clock.advance(0.01)
            #expect(rig.events.events.contains(.watchdog(uid: "uid-tv", .format)))
            #expect(!held(new))
        }
    }

    // MARK: The format watchdog

    @Test("The format watchdog releases a hold that nothing followed 2 s after the last formatChanging, which re-arms it, and fires once")
    func watchdogReleases() throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let tv = try #require(rig.tv)
        let log = formatTrace(rig)

        coordinator.formatChanging(uid: "uid-tv")
        rig.clock.advance(1)
        coordinator.formatChanging(uid: "uid-tv")
        rig.clock.advance(1.99)
        #expect(held(tv))
        rig.clock.advance(0.01)
        #expect(!held(tv))
        rig.clock.advance(10)

        #expect(log.all == ["format held uid-tv", "hold 200", "format held uid-tv", "watchdog format uid-tv", "open 200"])
        #expect(CatchAllCoordinator.formatWatchdog == 2)
    }

    @Test("While a rebuild waits to take over, the format watchdog opens the catch-all it replaces, which serves; the new one stays held for the rebuild")
    func watchdogDuringWaitingRebuild() throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let old = try #require(rig.tv)
        coordinator.formatChanging(uid: "uid-tv")
        rig.clock.advance(0.5)
        coordinator.rebuild("uid-tv", reason: .ioFailed)
        rig.clock.runDue()
        let new = try #require(rig.tv)
        // The takeover cannot read the process list; the rebuild watchdog is due 2 s after the attach
        rig.system.processListReadable = false

        rig.clock.advance(1.5)
        #expect(rig.events.events.contains(.watchdog(uid: "uid-tv", .format)))
        #expect(!held(old))
        #expect(held(new))
        #expect(!rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        rig.clock.advance(0.5)
        #expect(rig.events.events.contains(.watchdog(uid: "uid-tv", .rebuild)))
    }

    @Test("A catch-all whose own initial list never applied stays held while its rebuild waits and once that rebuild failed: neither the format watchdog nor formatUnchanged opens it, which would play a claimed process a second time",
          arguments: ["watchdog", "unchanged"])
    func initialHoldOutlastsRebuild(path: String) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let owner = FakeClaimOwner()
        // A tap created during the first build's wait (V4) claims 11: the first list lacks it
        rig.backend.onWaitUntilReady = {
            MainActor.assumeIsolated { _ = coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices)) }
        }
        coordinator.start()
        rig.backend.onWaitUntilReady = nil
        let first = try #require(rig.tv)
        #expect(first.appliedExclusions == [5])
        #expect(held(first))
        let log = formatTrace(rig)
        // Every push to it fails, so the push-failure path rebuilds it with the claim
        rig.backend.failAt = .setDescription
        if path == "watchdog" { coordinator.formatChanging(uid: "uid-tv") }
        rig.clock.runDue()
        let second = try #require(rig.tv)
        #expect(second !== first)
        #expect(second.appliedExclusions == [5, 11])
        #expect(held(first) && held(second))

        if path == "watchdog" {
            // The takeover cannot read the process list; the format and rebuild watchdogs are due together
            rig.system.processListReadable = false
            rig.clock.advance(CatchAllCoordinator.formatWatchdog)
            #expect(rig.events.events.contains(.watchdog(uid: "uid-tv", .format)))
            rig.system.processListReadable = true
        } else {
            coordinator.formatChanging(uid: "uid-tv")
            // The rebuilt catch-all's IO fails before it takes over: the first one serves again
            await report(rig, 201, .ioDead)
            #expect(rig.tv === first)
            coordinator.formatUnchanged(uid: "uid-tv")
            #expect(formatSteps(rig).last == .released)
        }
        #expect(held(first))
        rig.clock.advance(5)
        await settle()
        #expect(held(first))
        #expect(!log.all.contains("open 200"))
        withExtendedLifetime(owner) {}
    }

    @Test("The format watchdog is cancelled by formatUnchanged, R, G, dormancy and stop(): it never fires, and after R, G, dormancy or stop() the catch-all is never opened",
          arguments: ["unchanged", "retire", "absent", "dormant", "stop"])
    func watchdogCancelled(path: String) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let tv = try #require(rig.tv)
        let log = formatTrace(rig)

        coordinator.formatChanging(uid: "uid-tv")
        rig.clock.advance(1)
        switch path {
        case "unchanged":
            coordinator.formatUnchanged(uid: "uid-tv")
        case "retire":
            coordinator.retire("uid-tv", reason: .injected)
            rig.clock.runDue()
        case "absent":
            rig.system.outputs.removeAll { $0.uid == "uid-tv" }
            coordinator.deviceListRefreshed()
            rig.clock.runDue()
        case "dormant":
            makeDormant(rig)
            #expect(coordinator.phase("uid-tv") == .dormant)
        default:
            coordinator.stop()
        }
        rig.clock.advance(5)
        await settle()

        #expect(!rig.events.events.contains(.watchdog(uid: "uid-tv", .format)))
        #expect(held(tv) == (path != "unchanged"))
        #expect(log.all.filter { $0.hasPrefix("open") } == (path == "unchanged" ? ["open 200"] : []))
    }

    @Test("formatChanged hands the format hold to the rebuild's own bounds: the format watchdog no longer fires, and a rebuild that cannot read the process list retires the catch-all at its own bound, never opened, which also returns the call")
    func changedCancelsWatchdog() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let tv = try #require(rig.tv)
        let log = formatTrace(rig)

        coordinator.formatChanging(uid: "uid-tv")
        rig.clock.advance(1)
        rig.system.processListReadable = false
        let returned = changeFormat(coordinator)
        #expect(await eventually { coordinator.pendingFormatChangeCount == 1 })
        rig.clock.runDue()
        // The format watchdog would have fired 2 s after formatChanging
        rig.clock.advance(1.5)
        #expect(!rig.events.events.contains(.watchdog(uid: "uid-tv", .format)))
        #expect(held(tv))
        #expect(!returned.value)

        // 2 s after the first postponed attempt: R
        rig.clock.advance(0.6)
        #expect(await eventually { returned.value })
        #expect(rig.events.events.contains(.watchdog(uid: "uid-tv", .rebuild)))
        #expect(rig.events.events.contains(.retiring(uid: "uid-tv", .rebuildFailed)))
        #expect(held(tv))
        #expect(!log.all.contains { $0.hasPrefix("open") })
        #expect(builds(rig) == 1)
    }

    @Test("Once formatChanged handed the format hold to its rebuild, a later formatChanging (whose formatUnchanged the engine drops while its handler runs) does not arm the format watchdog again: the catch-all from before the change is never opened, and the rebuild's own bound ends the hold")
    func changingAgainDuringFormatRebuild() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let system = rig.system
        coordinator.start()
        rig.clock.runDue()
        let old = try #require(rig.tv)
        let log = formatTrace(rig)

        coordinator.formatChanging(uid: "uid-tv")
        // The rebuild cannot read the process list at first: postponed
        rig.system.processListReadable = false
        let returned = changeFormat(coordinator)
        #expect(await eventually { coordinator.pendingFormatChangeCount == 1 })
        rig.clock.runDue()
        #expect(builds(rig) == 1)
        rig.clock.advance(0.1)
        coordinator.formatChanging(uid: "uid-tv")
        // The next attempt builds; its takeover then cannot read the list
        rig.system.processListReadable = true
        rig.backend.onWaitUntilReady = { MainActor.assumeIsolated { system.processListReadable = false } }
        rig.clock.advance(0.1)
        rig.backend.onWaitUntilReady = nil
        #expect(builds(rig) == 2)
        let new = try #require(rig.tv)

        // Past 2 s after the second formatChanging, before the rebuild watchdog (2 s after the attach)
        rig.clock.advance(1.95)
        #expect(!rig.events.events.contains(.watchdog(uid: "uid-tv", .format)))
        #expect(held(old) && held(new))
        #expect(!returned.value)
        rig.clock.advance(0.1)
        #expect(rig.events.events.contains(.watchdog(uid: "uid-tv", .rebuild)))
        #expect(await eventually { returned.value })
        #expect(held(old))
        #expect(!log.all.contains { $0.hasPrefix("open") })
    }

    @Test("A formatChanging during the build or wait of the rebuild formatChanged asked for, which our own attach can raise and whose formatUnchanged the engine drops while its format handler runs, leaves the hold to that rebuild: its takeover opens the new catch-all, and no format watchdog fires",
          arguments: ["building", "waiting"])
    func changingDuringFormatRebuildEndsAtTakeover(stage: String) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let old = try #require(rig.tv)
        coordinator.formatChanging(uid: "uid-tv")
        let returned = changeFormat(coordinator)
        #expect(await eventually { coordinator.pendingFormatChangeCount == 1 })
        if stage == "building" {
            rig.backend.onWaitUntilReady = {
                MainActor.assumeIsolated { coordinator.formatChanging(uid: "uid-tv") }
            }
            rig.clock.runDue()
            rig.backend.onWaitUntilReady = nil
        } else {
            rig.clock.runDue()
            rig.clock.advance(0.1)
            coordinator.formatChanging(uid: "uid-tv")
        }
        let new = try #require(rig.tv)
        #expect(new !== old)
        #expect(held(old) && held(new))

        rig.clock.advance(stage == "building" ? 0.2 : 0.1)
        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        #expect(!held(new))
        #expect(held(old))
        #expect(await eventually { returned.value })
        rig.clock.advance(5)
        #expect(!held(new))
        #expect(!rig.events.events.contains(.watchdog(uid: "uid-tv", .format)))
        #expect(formatSteps(rig) == [.held, .rebuilding, .held])
    }

    // MARK: Phases

    @Test("A format hold taken while the first catch-all builds keeps it held after its initial list applied, until formatUnchanged")
    func holdWhileBuilding() throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        rig.backend.onWaitUntilReady = {
            MainActor.assumeIsolated { coordinator.formatChanging(uid: "uid-tv") }
        }
        coordinator.start()
        rig.backend.onWaitUntilReady = nil
        rig.clock.runDue()
        let tv = try #require(rig.tv)

        #expect(rig.events.events.contains(.released(uid: "uid-tv")))
        #expect(held(tv))
        #expect(formatSteps(rig) == [.held])
        coordinator.formatUnchanged(uid: "uid-tv")
        #expect(!held(tv))
        #expect(formatSteps(rig) == [.held, .released])
    }

    @Test("formatChanged while the first catch-all builds rebuilds it once attached: held until a catch-all built after the change took over, and the call returns then; a formatUnchanged after it during the wait is ignored",
          arguments: [false, true])
    func changedWhileBuilding(unchangedDuringWait: Bool) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let returned = CoordinatorTestBox(false)
        rig.backend.onWaitUntilReady = {
            MainActor.assumeIsolated {
                coordinator.formatChanging(uid: "uid-tv")
                Task {
                    await coordinator.formatChanged(uid: "uid-tv")
                    returned.value = true
                }
                // The engine's format handler runs while the wait spins
                spin { coordinator.pendingFormatChangeCount == 1 }
                // The rebuild it asked for has not started: the guard's verdict waits for it
                if unchangedDuringWait { coordinator.formatUnchanged(uid: "uid-tv") }
            }
        }

        await onRunLoop { coordinator.start() }
        rig.backend.onWaitUntilReady = nil
        let first = try #require(rig.tv)
        #expect(coordinator.pendingFormatChangeCount == 1)
        #expect(held(first))
        #expect(builds(rig) == 1)

        rig.clock.runDue()
        #expect(builds(rig) == 2)
        let second = try #require(rig.tv)
        #expect(held(second))
        rig.clock.advance(0.2)
        #expect(!held(second))
        #expect(held(first))
        #expect(await eventually { returned.value })
        #expect(formatSteps(rig) == [.held, .rebuilding] + (unchangedDuringWait ? [.unchangedIgnored] : []))
    }

    @Test("formatChanged while a dormant catch-all's rebuild builds (from a run-loop spin, V4) asks for another rebuild once that one took over, as for a first build, and returns at its takeover")
    func changedWhileDormantRebuildBuilds() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        makeDormant(rig)
        #expect(coordinator.phase("uid-tv") == .dormant)
        #expect(await eventually { rig.runControl.log.contains("detach uid-tv 200") })
        let returned = CoordinatorTestBox(false)
        rig.backend.onWaitUntilReady = {
            MainActor.assumeIsolated {
                Task {
                    await coordinator.formatChanged(uid: "uid-tv")
                    returned.value = true
                }
                // The engine's format handler runs while the wait spins
                spin { returned.value || coordinator.pendingFormatChangeCount == 1 }
            }
        }

        // Alive again: the rebuild from dormant builds in the next turn
        rig.system.alive.insert(42)
        rig.aliveObservers.fire(42)
        await onRunLoop { rig.clock.runDue() }
        rig.backend.onWaitUntilReady = nil
        #expect(builds(rig) == 2)
        #expect(coordinator.phase("uid-tv") == .live)
        #expect(coordinator.pendingFormatChangeCount == 1)
        #expect(!returned.value)

        // Its takeover asks for the rebuild after the change
        rig.clock.advance(0.2)
        #expect(builds(rig) == 3)
        #expect(!returned.value)
        rig.clock.advance(0.2)
        #expect(await eventually { returned.value })
        #expect(!held(try #require(rig.tv)))
        #expect(formatSteps(rig) == [.rebuilding])
    }

    @Test("A dormant catch-all's rebuild that fails because the device died again during its build drops the formatChanged that came meanwhile, as entering dormant does: the rebuild once the device is alive reads the format anyway, its takeover asks for no other, and it does not stand in for the verdict on a change that begins during its wait")
    func dormantRebuildFailsDropsFormatChange() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let system = rig.system
        coordinator.start()
        rig.clock.runDue()
        makeDormant(rig)
        #expect(coordinator.phase("uid-tv") == .dormant)
        #expect(await eventually { rig.runControl.log.contains("detach uid-tv 200") })
        let returned = CoordinatorTestBox(false)
        rig.backend.onWaitUntilReady = {
            MainActor.assumeIsolated {
                Task {
                    await coordinator.formatChanged(uid: "uid-tv")
                    returned.value = true
                }
                // The engine's format handler runs while the wait spins
                spin { returned.value || coordinator.pendingFormatChangeCount == 1 }
                // Then the device dies again, and the new aggregate never gets ready
                _ = system.alive.remove(42)
            }
        }
        rig.backend.failAt = .ready

        // Alive again: the rebuild from dormant builds in the next turn, and fails
        system.alive.insert(42)
        rig.aliveObservers.fire(42)
        await onRunLoop { rig.clock.runDue() }
        rig.backend.onWaitUntilReady = nil
        rig.backend.failAt = nil
        #expect(builds(rig) == 2)
        #expect(coordinator.phase("uid-tv") == .dormant)
        #expect(await eventually { returned.value })

        // Alive again: one rebuild. A change that begins during its wait is not one formatChanged
        // asked it for, so its takeover keeps the format hold until the verdict
        system.alive.insert(42)
        rig.aliveObservers.fire(42)
        rig.clock.runDue()
        #expect(builds(rig) == 3)
        let new = try #require(rig.tv)
        coordinator.formatChanging(uid: "uid-tv")
        rig.clock.advance(0.2)
        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        #expect(held(new))
        coordinator.formatUnchanged(uid: "uid-tv")
        #expect(!held(new))
        // Nothing asks for another rebuild
        rig.clock.advance(1)
        #expect(builds(rig) == 3)
        #expect(rig.tv === new)
        #expect(formatSteps(rig) == [.rebuilding, .held, .released])
        #expect(failures(rig).isEmpty)
    }

    @Test("A dormant or retiring catch-all takes no format hold, and formatChanged on it returns at once without a build",
          arguments: ["dormant", "retiring"])
    func noHoldWhileDormantOrRetiring(phase: String) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        if phase == "dormant" {
            makeDormant(rig)
            #expect(await eventually { rig.runControl.log.contains("detach uid-tv 200") })
            coordinator.formatChanging(uid: "uid-tv")
            coordinator.formatUnchanged(uid: "uid-tv")
            let returned = changeFormat(coordinator)
            #expect(await eventually { returned.value })
            // Alive again: the rebuild opens at its takeover, no format hold left
            rig.system.alive.insert(42)
            rig.aliveObservers.fire(42)
            rig.clock.runDue()
            rig.clock.advance(0.2)
            #expect(!held(try #require(rig.tv)))
        } else {
            let seen = LineLog()
            coordinator.onCoverageWillEnd = { uid in
                // R2: retiring, not yet held
                coordinator.formatChanging(uid: uid)
                coordinator.formatUnchanged(uid: uid)
                seen.add("\(coordinator.phase(uid).map { String(describing: $0) } ?? "nil")")
                return false
            }
            coordinator.retire("uid-tv", reason: .injected)
            rig.clock.runDue()
            #expect(seen.all == ["retiring(caHeld: false)"])
            let returned = changeFormat(coordinator)
            #expect(await eventually { returned.value })
        }
        #expect(formatSteps(rig).isEmpty)
        #expect(builds(rig) == (phase == "dormant" ? 2 : 1))
    }

    @Test("Before start() and once the breaker is open, the format hooks do nothing")
    func nothingUnstartedOrAfterBreaker() async throws {
        // Not started
        let unstarted = makeCatchAllRig()
        unstarted.coordinator.formatChanging(uid: "uid-tv")
        unstarted.coordinator.formatUnchanged(uid: "uid-tv")
        let returnedUnstarted = changeFormat(unstarted.coordinator)
        #expect(await eventually { returnedUnstarted.value })
        #expect(unstarted.backend.log.isEmpty)
        #expect(unstarted.events.events.isEmpty)

        // The breaker opens through three failed builds of a second software output, while the
        // TV's catch-all is still live: the hooks reach it before its retirement runs
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let tv = try #require(rig.tv)
        rig.system.outputs.append(CatchAllOutput(uid: "uid-tv2", id: 44))
        rig.system.tiers[44] = .software
        rig.system.alive.insert(44)
        rig.backend.deviceIDs["uid-tv2"] = 44
        rig.backend.failAt = .createTap
        let seen = LineLog()
        let events = rig.events
        coordinator.onEvent = { event in
            events.events.append(event)
            guard event == .breakerOpened else { return }
            coordinator.formatChanging(uid: "uid-tv")
            coordinator.formatUnchanged(uid: "uid-tv")
            seen.add("live=\(coordinator.phase("uid-tv") == .live) held=\(held(tv))")
        }
        coordinator.deviceListRefreshed()
        rig.clock.runDue()
        rig.clock.advance(40)

        #expect(seen.all == ["live=true held=false"])
        #expect(formatSteps(rig).isEmpty)
        #expect(rig.events.events.contains(.retiring(uid: "uid-tv", .breaker)))
        let returned = changeFormat(coordinator)
        #expect(await eventually { returned.value })
        #expect(formatSteps(rig).isEmpty)
    }

    // MARK: Coalescing and settles

    @Test("formatChanged during a rebuild for another reason is coalesced: the device ends on a catch-all built after the change; the takeover of the one built before keeps the format hold, and the hold and the call end at the next takeover",
          arguments: ["building", "waiting"])
    func changedDuringOtherRebuild(stage: String) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let log = formatTrace(rig)
        let returned = CoordinatorTestBox(false)
        let change: @MainActor @Sendable () -> Void = {
            coordinator.formatChanging(uid: "uid-tv")
            Task {
                await coordinator.formatChanged(uid: "uid-tv")
                returned.value = true
            }
        }

        coordinator.rebuild("uid-tv", reason: .ioFailed)
        if stage == "building" {
            rig.backend.onWaitUntilReady = {
                MainActor.assumeIsolated {
                    change()
                    spin { coordinator.pendingFormatChangeCount == 1 }
                }
            }
            await onRunLoop { rig.clock.runDue() }
            rig.backend.onWaitUntilReady = nil
        } else {
            rig.clock.runDue()
            change()
            #expect(await eventually { coordinator.pendingFormatChangeCount == 1 })
        }
        let second = try #require(rig.tv)
        #expect(held(second))

        // The one built before the change takes over held; the next one builds at once
        rig.clock.advance(0.2)
        #expect(held(second))
        #expect(builds(rig) == 3)
        #expect(coordinator.pendingFormatChangeCount == 1)
        let third = try #require(rig.tv)
        #expect(third !== second)

        rig.clock.advance(0.2)
        #expect(rig.tv === third)
        #expect(!held(third))
        #expect(held(second))
        #expect(await eventually { returned.value })
        let changed = stage == "building"
            ? ["createTap", "format held uid-tv", "hold 200", "format rebuilding uid-tv", "attach uid-tv [5] held=true"]
            : ["createTap", "attach uid-tv [5] held=true", "format held uid-tv", "hold 200", "format rebuilding uid-tv"]
        #expect(syncLines(log) == changed + [
            "hold 200",
            "rebuilt uid-tv",
            "createTap",
            "attach uid-tv [5] held=true",
            "hold 201",
            "open 202",
            "rebuilt uid-tv",
        ])
        #expect(!rig.events.events.contains(.watchdog(uid: "uid-tv", .format)))
    }

    @Test("formatChanged while a failed rebuild settles leaves the rebuild to the settle and returns at once; the format watchdog then bounds the hold")
    func changedLeftToSettle() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let tv = try #require(rig.tv)
        coordinator.formatChanging(uid: "uid-tv")
        rig.backend.failAt = .createTap
        coordinator.rebuild("uid-tv", reason: .ioFailed)
        rig.clock.runDue()
        #expect(builds(rig) == 2)

        let returned = changeFormat(coordinator)
        #expect(await eventually { returned.value })
        #expect(formatSteps(rig) == [.held, .leftToSettle])
        #expect(held(tv))

        // IsAlive flaps during each settle, so neither failure stands: the device rebuilds
        // again after each, and each rebuild fails
        rig.clock.advance(0.5)
        rig.aliveObservers.fire(42)
        rig.clock.advance(0.5)
        #expect(builds(rig) == 3)
        rig.clock.advance(0.5)
        rig.aliveObservers.fire(42)
        rig.clock.advance(0.49)
        #expect(held(tv))
        rig.clock.advance(0.01)
        #expect(rig.events.events.contains(.watchdog(uid: "uid-tv", .format)))
        #expect(!held(tv))
        #expect(rig.tv === tv)
        #expect(failures(rig).isEmpty)
        coordinator.stop()
    }

    @Test("After formatChanged's own rebuild failed into a settle, a further formatChanged is left to that settle and returns at once; no format watchdog runs then, and the settle's end bounds the hold: R once the failure stood, or else the takeover of the rebuild it asks for, which opens",
          arguments: ["stands", "flaps"])
    func changedAgainWhileOwnRebuildSettles(path: String) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let old = try #require(rig.tv)
        coordinator.formatChanging(uid: "uid-tv")
        rig.backend.failAt = .createTap
        let first = changeFormat(coordinator)
        #expect(await eventually { coordinator.pendingFormatChangeCount == 1 })
        rig.clock.runDue()
        rig.backend.failAt = nil
        #expect(await eventually { first.value })

        rig.clock.advance(0.5)
        let second = changeFormat(coordinator)
        #expect(await eventually { second.value })
        #expect(formatSteps(rig) == [.held, .rebuilding, .leftToSettle])
        #expect(held(old))
        // IsAlive flaps during the settle, so the failure does not stand
        if path == "flaps" { rig.aliveObservers.fire(42) }

        rig.clock.advance(0.5)
        if path == "stands" {
            #expect(rig.events.events.contains(.retiring(uid: "uid-tv", .rebuildFailed)))
            #expect(held(old))
        } else {
            #expect(builds(rig) == 3)
            let new = try #require(rig.tv)
            #expect(held(old) && held(new))
            rig.clock.advance(0.2)
            #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
            #expect(!held(new))
            #expect(held(old))
            #expect(failures(rig).isEmpty)
        }
        rig.clock.advance(5)
        await settle()
        #expect(!rig.events.events.contains(.watchdog(uid: "uid-tv", .format)))
    }

    // MARK: The rate check (§16.12 item 3)

    @Test("A rate mismatch report rebuilds the catch-all like a format change, counts nothing, and is acted on once per aggregate: a repeat, and a report about the replaced aggregate, do nothing")
    func rateMismatchRebuilds() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let old = try #require(rig.tv)

        await report(rig, 200)
        await report(rig, 200)
        #expect(formatSteps(rig) == [.rateMismatch])
        rig.clock.runDue()
        #expect(builds(rig) == 2)
        let new = try #require(rig.tv)
        #expect(new !== old)
        rig.clock.advance(0.2)
        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        #expect(!held(new))

        await report(rig, 200)
        rig.clock.advance(5)
        #expect(builds(rig) == 2)
        #expect(formatSteps(rig) == [.rateMismatch])
        #expect(failures(rig).isEmpty)
        #expect(!rig.events.events.contains { if case .backoff = $0 { true } else { false } })
        #expect(coordinator.givenUp.isEmpty)

        // The new aggregate reports its own
        await report(rig, 201)
        rig.clock.runDue()
        #expect(builds(rig) == 3)
        #expect(formatSteps(rig) == [.rateMismatch, .rateMismatch])
    }

    @Test("An aggregate ID is forgotten once its catch-all is destroyed: a later catch-all that reuses the ID reports its own rate")
    func reusedAggregateReportsRateAgain() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        await report(rig, 200)
        rig.clock.runDue()
        rig.clock.advance(0.2)
        #expect(try #require(rig.tv).ioHandle.aggregateID == 201)
        #expect(await eventually { rig.backend.log.contains("destroy tap=100 aggregate=200 proc=true") })
        await settle()
        // Core Audio hands the destroyed catch-all's ID to the next one
        rig.backend.nextAggregate = 200
        coordinator.rebuild("uid-tv", reason: .ioFailed)
        rig.clock.runDue()
        rig.clock.advance(0.2)
        #expect(try #require(rig.tv).ioHandle.aggregateID == 200)

        await report(rig, 200)
        rig.clock.runDue()
        #expect(builds(rig) == 4)
        #expect(formatSteps(rig) == [.rateMismatch, .rateMismatch])
    }

    @Test("A rate report about a rebuilt catch-all that waits to take over after a push failure asks for one more rebuild after the takeover: it rebuilds as a format change, which a rebuild that runs never serves")
    func rateReportDuringPushRebuild() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.rebuild("uid-tv", reason: .pushFailed)
        rig.clock.runDue()
        #expect(builds(rig) == 2)

        await report(rig, 201)
        #expect(formatSteps(rig) == [.rateMismatch])
        rig.clock.advance(0.2)
        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        #expect(builds(rig) == 3)
        rig.clock.advance(0.2)
        #expect(try #require(rig.tv).ioHandle.aggregateID == 202)
        #expect(failures(rig).isEmpty)
    }

    @Test("A rate mismatch report about a retiring catch-all, or one whose retirement is queued, does nothing; one about a dormant catch-all only runs the E12 check, as an IO report does: still dead it stays dormant, alive again it is rebuilt at once, uncounted",
          arguments: ["dormant", "dormantAlive", "queued", "retiring"])
    func rateMismatchIgnored(phase: String) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        switch phase {
        case "dormant":
            makeDormant(rig)
            await report(rig, 200)
            rig.clock.advance(1)
            #expect(coordinator.phase("uid-tv") == .dormant)
        case "dormantAlive":
            makeDormant(rig)
            // Alive again before IsAlive or the 2 s check said so
            rig.system.alive.insert(42)
            await report(rig, 200)
            rig.clock.runDue()
            #expect(builds(rig) == 2)
            #expect(coordinator.phase("uid-tv") == .live)
            rig.clock.advance(1)
            #expect(formatSteps(rig).isEmpty)
            #expect(failures(rig).isEmpty)
            return
        case "queued":
            coordinator.retire("uid-tv", reason: .injected)
            await report(rig, 200)
            rig.clock.runDue()
        default:
            coordinator.onCoverageWillEnd = { uid in
                coordinator.reportIOFailure(uid, aggregate: 200, .rateMismatch)
                return false
            }
            coordinator.retire("uid-tv", reason: .injected)
            rig.clock.runDue()
        }
        rig.clock.advance(1)
        #expect(builds(rig) == 1)
        #expect(formatSteps(rig).isEmpty)
        #expect(failures(rig).isEmpty)
    }

    // MARK: Modes

    @Test("Mode off: the Noop and an unstarted mode-off coordinator ignore the format hooks, and formatChanged returns at once")
    func modeOff() async {
        let noop = NoopCatchAllCoordinator()
        noop.formatChanging(uid: "uid-tv")
        noop.formatUnchanged(uid: "uid-tv")
        await noop.formatChanged(uid: "uid-tv")
        #expect(noop.phase("uid-tv") == nil)

        let rig = makeCatchAllRig(mode: .off)
        rig.coordinator.start()
        rig.coordinator.formatChanging(uid: "uid-tv")
        rig.coordinator.formatUnchanged(uid: "uid-tv")
        let returned = changeFormat(rig.coordinator)
        #expect(await eventually { returned.value })
        rig.clock.advance(5)
        #expect(rig.backend.log.isEmpty)
        #expect(rig.events.events.isEmpty)
    }

    @Test("In observe the format hold follows the other holds: the catch-all, which covers nothing, is held and released the same way, and formatChanged rebuilds it")
    func observeMode() async throws {
        let rig = makeCatchAllRig(mode: .observe)
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let tv = try #require(rig.tv)
        #expect(tv.renderState.observeOnly)
        #expect(!coordinator.covers("uid-tv"))
        let log = formatTrace(rig)

        coordinator.formatChanging(uid: "uid-tv")
        #expect(held(tv))
        coordinator.formatUnchanged(uid: "uid-tv")
        #expect(!held(tv))
        coordinator.formatChanging(uid: "uid-tv")
        let returned = changeFormat(coordinator)
        #expect(await eventually { coordinator.pendingFormatChangeCount == 1 })
        rig.clock.runDue()
        let new = try #require(rig.tv)
        #expect(new.renderState.observeOnly)
        rig.clock.advance(0.2)
        #expect(!held(new))
        #expect(await eventually { returned.value })
        #expect(syncLines(log) == [
            "format held uid-tv", "hold 200", "format released uid-tv", "open 200",
            "format held uid-tv", "hold 200", "format rebuilding uid-tv",
            "createTap", "attach uid-tv [5] held=true", "hold 200", "open 201", "rebuilt uid-tv",
        ])
    }
}
