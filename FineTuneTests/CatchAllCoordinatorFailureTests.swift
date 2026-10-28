// FineTuneTests/CatchAllCoordinatorFailureTests.swift
//
// Failure handling of the coordinator, first half (design §16.8 test 5, coordinator side):
// retirement with promotion (R) and its tickets, the end of coverage without promotion (G),
// stop(), the make-before-break rebuild (E), push failures, queued retirements and the
// watchdogs. Fake claim owners and one ordered log per test; no Core Audio object is created.

import AudioToolbox
import Foundation
import Synchronization
import Testing
@testable import FineTune

/// Whether the catch-all's output is held.
private func held(_ controller: CatchAllTapController) -> Bool {
    controller.renderState.held.load(ordering: .relaxed)
}

/// The TV, the AirPods and a second software output.
private func makeTwoDeviceRig() -> CatchAllCoordinatorRig {
    makeCatchAllRig { system in
        system.outputs.append(CatchAllOutput(uid: "uid-tv2", id: 44))
        system.tiers[44] = .software
        system.alive.insert(44)
    }
}

/// One ordered log of what failure handling does, in short lines: the coordinator's events,
/// the run control's detaches and stops, and the backend's destroys. Output changes carry the
/// number of pending waits at that moment, so a wait that ends too early shows.
private func trace(_ rig: CatchAllCoordinatorRig) -> LineLog {
    let log = LineLog()
    let coordinator = rig.coordinator
    let events = rig.events
    rig.runControl.onRecord = { line in
        if line.hasPrefix("detach") || line.hasPrefix("queue ran") || line == "stop" { log.add(line) }
    }
    rig.backend.onRecord = { entry in
        if entry.hasPrefix("destroy") { log.add(entry) }
    }
    coordinator.onEvent = { event in
        events.events.append(event)
        switch event {
        case .retiring(let uid, let reason):
            log.add("retiring \(uid) \(reason.rawValue)")
        case .output(_, let aggregate, let isHeld):
            log.add("\(isHeld ? "hold" : "open") \(aggregate) pending=\(coordinator.pendingWaitCount)")
        case .rebuilt(let uid):
            log.add("rebuilt \(uid)")
        case .ended(let uid, let reason):
            log.add("ended \(uid) \(reason)")
        case .watchdog(let uid, let kind):
            log.add("watchdog \(kind.rawValue) \(uid)")
        case .failure(let uid, let failure):
            log.add("failure \(failure.rawValue) \(uid)")
        default:
            break
        }
    }
    return log
}

/// `waitUntil` with room for a main actor that other suites block for a while: these paths hop
/// through several tasks (wait, detach, destroy).
private func eventually(_ condition: () -> Bool) async -> Bool {
    await waitUntil(timeout: .seconds(10), condition)
}

/// Starts a grow wait; `heldAtEnd` says whether the catch-all was held when it ended. Which of
/// the resumed wait and R4's task runs first is up to the executor, so the ordered logs show the
/// end of a wait through the pending count, which the coordinator changes at once.
private func startWait(_ coordinator: CatchAllCoordinator, _ ticket: ApplyTicket,
                       _ controller: CatchAllTapController) -> CoordinatorTestBox<Bool?> {
    let heldAtEnd = CoordinatorTestBox<Bool?>(nil)
    Task {
        await coordinator.waitApplied(ticket, .grow)
        heldAtEnd.value = held(controller)
    }
    return heldAtEnd
}

@Suite("Catch-all coordinator failure handling")
@MainActor
struct CatchAllCoordinatorFailureTests {

    // MARK: Retirement (R)

    @Test("R logs retiring, onCoverageWillEnd, the CA hold, the retirement tickets, detach and destroy, in this order")
    func retirementOrder() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let tv = try #require(rig.tv)
        let owner = FakeClaimOwner()
        // A grow wait pending when R begins becomes a retirement hold
        let ticket = try #require(coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices)))
        rig.clock.runDue()
        let log = trace(rig)
        let heldAtEnd = startWait(coordinator, ticket, tv)
        #expect(await eventually { coordinator.pendingWaitCount == 1 })
        coordinator.onCoverageWillEnd = { uid in
            log.add("onCoverageWillEnd \(uid) pending=\(coordinator.pendingWaitCount) held=\(held(tv)) "
                    + "retirementHold=\(coordinator.takesRetirementHold(targets: [uid]))")
            return false
        }

        coordinator.retire("uid-tv", reason: .injected)
        #expect(coordinator.phase("uid-tv") == .live)
        rig.clock.runDue()
        // R1 to R3 ran in the coordinator's turn; R4 runs in a task
        log.add("R3 done pending=\(coordinator.pendingWaitCount) caHeld=\(coordinator.phase("uid-tv") == .retiring(caHeld: true)) "
                + "retirementHold=\(coordinator.takesRetirementHold(targets: ["uid-tv"]))")

        #expect(await eventually { log.all.contains { $0.hasPrefix("destroy") } })
        #expect(log.all == [
            "retiring uid-tv injected",
            "onCoverageWillEnd uid-tv pending=1 held=false retirementHold=true",
            "hold 200 pending=1",
            "R3 done pending=0 caHeld=true retirementHold=false",
            "detach uid-tv 200",
            "ended uid-tv injected",
            "destroy tap=100 aggregate=200 proc=true",
        ])
        #expect(await eventually { heldAtEnd.value == true })
        #expect(coordinator.phase("uid-tv") == nil)
        #expect(!coordinator.covers("uid-tv"))
        withExtendedLifetime(owner) {}
    }

    @Test("Retirement tickets: during R2 setClaim names the retiring target even when no list changed; after R3 waits end at once and no claim gets one")
    func retirementTickets() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        let owner = FakeClaimOwner()
        let elsewhere = FakeClaimOwner(pid: 2, targets: ["uid-air"])
        let claim = Claim(processes: [11], coverage: .allDevices)
        _ = coordinator.setClaim(owner, claim)
        rig.clock.advance(1)
        let tickets = CoordinatorTestBox<[ApplyTicket?]>([])
        coordinator.onCoverageWillEnd = { _ in
            // The engine's taps: one on the device with an unchanged claim, one elsewhere
            tickets.value.append(coordinator.setClaim(owner, claim))
            tickets.value.append(coordinator.setClaim(elsewhere, Claim(processes: [12], coverage: .device("uid-air"))))
            return false
        }

        coordinator.retire("uid-tv", reason: .injected)
        rig.clock.runDue()

        #expect(tickets.value.count == 2)
        let ticket = try #require(tickets.value.first ?? nil)
        #expect(ticket.generations == ["uid-tv": 1])
        #expect(tickets.value[1] == nil)
        // After R3: no hold, no ticket, and a wait on the retirement ticket ends at once
        #expect(coordinator.phase("uid-tv") == .retiring(caHeld: true))
        #expect(!coordinator.takesRetirementHold(targets: ["uid-tv"]))
        #expect(coordinator.setClaim(owner, Claim(processes: [11, 13], coverage: .allDevices)) == nil)
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .grow); done.value = true }
        #expect(await eventually { done.value })
        withExtendedLifetime([owner, elsewhere]) {}
    }

    @Test("A grow wait registered while its target is retiring(caHeld: false) is a retirement hold, even for an applied generation")
    func waitBetweenR1AndR3() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        let owner = FakeClaimOwner()
        let ticket = try #require(coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices)))
        rig.clock.advance(1)
        coordinator.setPhaseForTesting(.retiring(caHeld: false), for: "uid-tv")

        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .grow); done.value = true }
        #expect(await eventually { coordinator.pendingWaitCount == 1 })
        rig.clock.advance(0.5)
        await settle()
        #expect(!done.value)

        coordinator.setPhaseForTesting(.retiring(caHeld: true), for: "uid-tv")
        #expect(await eventually { done.value })
        withExtendedLifetime(owner) {}
    }

    @Test("A wait on a dormant catch-all ends at once")
    func dormantWait() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        let owner = FakeClaimOwner()
        let ticket = try #require(coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices)))
        coordinator.setPhaseForTesting(.dormant, for: "uid-tv")

        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .grow); done.value = true }
        #expect(await eventually { done.value })
        withExtendedLifetime(owner) {}
    }

    @Test("R2 returning true keeps the held catch-all 30 s after R4, calls onCoverageWillEnd again first, and waits again while it returns true")
    func keptAside() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let tv = try #require(rig.tv)
        let log = trace(rig)
        let answers = CoordinatorTestBox([true, true, false])
        coordinator.onCoverageWillEnd = { uid in
            log.add("onCoverageWillEnd \(uid)")
            return answers.value.removeFirst()
        }
        let callbacks = { log.all.filter { $0.hasPrefix("onCoverageWillEnd") }.count }

        coordinator.retire("uid-tv", reason: .injected)
        rig.clock.runDue()

        // R4 ends at the detach: the entry is gone, the catch-all stays held
        #expect(await eventually { log.all.contains("ended uid-tv injected") })
        #expect(coordinator.phase("uid-tv") == nil)
        #expect(held(tv))
        rig.clock.advance(29.9)
        await settle()
        #expect(callbacks() == 1)

        rig.clock.advance(0.1)
        #expect(callbacks() == 2)
        await settle()
        #expect(!log.all.contains { $0.hasPrefix("destroy") })

        rig.clock.advance(30)
        #expect(callbacks() == 3)
        #expect(await eventually { log.all.contains { $0.hasPrefix("destroy") } })
        #expect(Array(log.all.suffix(2)) == ["onCoverageWillEnd uid-tv", "destroy tap=100 aggregate=200 proc=true"])
    }

    @Test("A kept-aside catch-all goes without a callback once a new one covers the device, and at once on stop()")
    func keptAsideEnds() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let log = trace(rig)
        let calls = CoordinatorTestBox(0)
        coordinator.onCoverageWillEnd = { _ in
            calls.value += 1
            return true
        }

        coordinator.retire("uid-tv", reason: .injected)
        rig.clock.runDue()
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        // Without backoff yet, the next reconcile builds the device again
        coordinator.reconcile()
        rig.clock.runDue()
        #expect(coordinator.phase("uid-tv") == .live)

        rig.clock.advance(30)
        #expect(await eventually { log.all.contains("destroy tap=100 aggregate=200 proc=true") })
        #expect(calls.value == 1)

        coordinator.retire("uid-tv", reason: .injected)
        rig.clock.runDue()
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        #expect(calls.value == 2)
        coordinator.stop()
        #expect(await eventually { log.all.contains("destroy tap=101 aggregate=201 proc=true") })
        #expect(calls.value == 2)
    }

    @Test("A reconcile that finds the device without software volume retires its live catch-all (R) and builds none")
    func tierChanged() async {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let calls = LineLog()
        coordinator.onCoverageWillEnd = { uid in
            calls.add(uid)
            return false
        }

        rig.system.tiers[42] = .hardware
        coordinator.reconcile()
        rig.clock.runDue()

        #expect(calls.all == ["uid-tv"])
        #expect(rig.events.events.contains(.retiring(uid: "uid-tv", .tierChanged)))
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        coordinator.reconcile()
        rig.clock.runDue()
        #expect(coordinator.phase("uid-tv") == nil)
        #expect(rig.backend.log.filter { $0 == "createTap" }.count == 1)
    }

    @Test("In observe a retirement is G: no callback and no retiring phase")
    func observeRetirementIsG() async {
        let rig = makeCatchAllRig(mode: .observe)
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let calledBack = CoordinatorTestBox(false)
        coordinator.onCoverageWillEnd = { _ in
            calledBack.value = true
            return true
        }

        coordinator.retire("uid-tv", reason: .injected)
        rig.clock.runDue()

        #expect(coordinator.phase("uid-tv") == nil)
        #expect(!calledBack.value)
        #expect(rig.events.events.contains(.ended(uid: "uid-tv", reason: "retired in observe (injected)")))
        #expect(!rig.events.events.contains { if case .retiring = $0 { true } else { false } })
        #expect(await eventually { rig.backend.log.contains { $0.hasPrefix("destroy") } })
    }

    @Test("A reconcile during R4 leaves the retiring device alone: no G for it and no new build until R4 ended")
    func reconcileDuringR4() async {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let log = trace(rig)

        coordinator.retire("uid-tv", reason: .injected)
        rig.clock.runDue()
        // R4's detach runs in a task; these reconciles run before it, with the TV listed and gone
        coordinator.reconcile()
        rig.clock.runDue()
        #expect(coordinator.phase("uid-tv") == .retiring(caHeld: true))
        #expect(rig.backend.log.filter { $0 == "createTap" }.count == 1)
        rig.system.outputs.removeAll { $0.uid == "uid-tv" }
        coordinator.reconcile()
        rig.clock.runDue()
        #expect(coordinator.phase("uid-tv") == .retiring(caHeld: true))

        #expect(await eventually { log.all.contains { $0.hasPrefix("destroy") } })
        #expect(log.all == [
            "retiring uid-tv injected",
            "hold 200 pending=0",
            "detach uid-tv 200",
            "ended uid-tv injected",
            "destroy tap=100 aggregate=200 proc=true",
        ])
    }

    @Test("A retirement whose device went away before its turn is G: no callback, no retiring phase")
    func retirementOfVanishedDevice() async {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let calledBack = CoordinatorTestBox(false)
        coordinator.onCoverageWillEnd = { _ in
            calledBack.value = true
            return false
        }

        coordinator.retire("uid-tv", reason: .runQueueTimeout)
        rig.system.outputs.removeAll { $0.uid == "uid-tv" }
        rig.clock.runDue()

        #expect(!calledBack.value)
        #expect(coordinator.phase("uid-tv") == nil)
        #expect(rig.events.events.contains(.ended(uid: "uid-tv", reason: "absent")))
        #expect(!rig.events.events.contains { if case .retiring = $0 { true } else { false } })
        #expect(await eventually { rig.backend.log.contains { $0.hasPrefix("destroy") } })
    }

    @Test("A kept-aside catch-all whose device went away is destroyed when its time runs out, without a callback")
    func keptAsideDeviceGone() async {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let log = trace(rig)
        let calls = CoordinatorTestBox(0)
        coordinator.onCoverageWillEnd = { _ in
            calls.value += 1
            return true
        }

        coordinator.retire("uid-tv", reason: .injected)
        rig.clock.runDue()
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        rig.system.outputs.removeAll { $0.uid == "uid-tv" }
        rig.clock.advance(30)

        #expect(await eventually { log.all.contains("destroy tap=100 aggregate=200 proc=true") })
        #expect(calls.value == 1)
    }

    // MARK: Queued retirements

    @Test("A retirement requested during a build's wait runs in the coordinator's next turn")
    func retirementQueuedDuringBuild() async {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let calls = LineLog()
        coordinator.onCoverageWillEnd = { uid in
            calls.add(uid)
            return false
        }
        rig.backend.onWaitUntilReady = {
            MainActor.assumeIsolated { coordinator.retire("uid-tv", reason: .injected) }
        }

        coordinator.start()
        rig.backend.onWaitUntilReady = nil

        #expect(coordinator.phase("uid-tv") == .live)
        #expect(calls.all.isEmpty)
        rig.clock.runDue()
        #expect(calls.all == ["uid-tv"])
        #expect(coordinator.phase("uid-tv") == .retiring(caHeld: true))
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
    }

    @Test("A retirement requested while R2 spins runs in the next turn, never nested")
    func retirementQueuedDuringCallback() {
        let rig = makeTwoDeviceRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let log = LineLog()
        coordinator.onCoverageWillEnd = { uid in
            log.add("callback \(uid)")
            if uid == "uid-tv" {
                coordinator.retire("uid-tv2", reason: .injected)
                log.add("uid-tv2 live=\(coordinator.phase("uid-tv2") == .live)")
            }
            return false
        }

        coordinator.retire("uid-tv", reason: .injected)
        #expect(log.all.isEmpty)
        rig.clock.runDue()

        // uid-tv2 was still live inside the first callback: its R2 ran after it, in a turn of its own
        #expect(log.all == ["callback uid-tv", "uid-tv2 live=true", "callback uid-tv2"])
        #expect(coordinator.phase("uid-tv") == .retiring(caHeld: true))
        #expect(coordinator.phase("uid-tv2") == .retiring(caHeld: true))
    }

    // MARK: End without promotion (G) and stop()

    @Test("An absent device gives G: no callback, nothing counted; the catch-all is held, its waits complete, then detach and destroy")
    func absentDevice() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let owner = FakeClaimOwner()
        let ticket = try #require(coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices)))
        rig.clock.runDue()
        let log = trace(rig)
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .grow); done.value = true }
        #expect(await eventually { coordinator.pendingWaitCount == 1 })
        let calledBack = CoordinatorTestBox(false)
        coordinator.onCoverageWillEnd = { _ in
            calledBack.value = true
            return true
        }

        rig.system.outputs.removeAll { $0.uid == "uid-tv" }
        coordinator.reconcile()
        rig.clock.runDue()

        #expect(coordinator.phase("uid-tv") == nil)
        #expect(await eventually { done.value })
        #expect(await eventually { log.all.contains { $0.hasPrefix("destroy") } })
        // Held while the wait is still pending, then the wait ends, then detach and destroy
        #expect(log.all == ["hold 200 pending=1", "ended uid-tv absent", "detach uid-tv 200",
                            "destroy tap=100 aggregate=200 proc=true"])
        #expect(!calledBack.value)
        #expect(!rig.events.events.contains { if case .failure = $0 { true } else { false } })
        withExtendedLifetime(owner) {}
    }

    @Test("stop() ends every catch-all with G, completes every wait and stops the run control once; start() starts it again")
    func stopEndsEverything() async throws {
        let rig = makeTwoDeviceRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let owner = FakeClaimOwner(targets: ["uid-tv", "uid-tv2"])
        let grow = try #require(coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices)))
        rig.clock.runDue()
        let log = trace(rig)
        let done = CoordinatorTestBox(0)
        Task { await coordinator.waitApplied(grow, .grow); done.value += 1 }
        #expect(await eventually { coordinator.pendingWaitCount == 1 })
        let shrink = try #require(coordinator.removeClaim(ObjectIdentifier(owner)))
        Task { await coordinator.waitApplied(shrink, .shrink); done.value += 1 }
        #expect(await eventually { coordinator.pendingWaitCount == 2 })

        coordinator.stop()
        coordinator.stop()

        #expect(await eventually { done.value == 2 })
        #expect(coordinator.phase("uid-tv") == nil)
        #expect(coordinator.phase("uid-tv2") == nil)
        #expect(rig.clock.pendingCount == 0)
        #expect(await eventually { log.all.filter { $0.hasPrefix("destroy") }.count == 2 })
        let lines = log.all
        #expect(Array(lines.prefix(5)) == [
            "hold 200 pending=2", "ended uid-tv stopped", "hold 201 pending=2", "ended uid-tv2 stopped", "stop",
        ])
        #expect(lines.filter { $0 == "stop" }.count == 1)
        for aggregate in [200, 201] {
            let detach = try #require(lines.firstIndex { $0.hasPrefix("detach") && $0.hasSuffix(" \(aggregate)") })
            let destroy = try #require(lines.firstIndex { $0.contains("aggregate=\(aggregate) ") })
            #expect(detach < destroy)
        }

        coordinator.start()
        #expect(rig.runControl.log.filter { $0 == "start" || $0 == "stop" } == ["start", "stop", "start"])
        #expect(coordinator.phase("uid-tv") == .live)
        withExtendedLifetime(owner) {}
    }

    @Test("A detach that times out never destroys before the queued detach has run")
    func detachTimeout() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let log = trace(rig)
        rig.runControl.blocked = true

        coordinator.retire("uid-tv", reason: .injected)
        rig.clock.runDue()

        // R4 ends at the timed-out detach
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        rig.clock.advance(60)
        await settle()
        #expect(!log.all.contains { $0.hasPrefix("destroy") })

        rig.runControl.unblock()
        #expect(await eventually { log.all.contains { $0.hasPrefix("destroy") } })
        #expect(log.all == [
            "retiring uid-tv injected",
            "hold 200 pending=0",
            "detach uid-tv 200 timed out",
            "failure runQueueTimeout uid-tv",
            "ended uid-tv injected",
            "queue ran detach uid-tv 200",
            "destroy tap=100 aggregate=200 proc=true",
        ])
    }

    @Test("G with a blocked run queue counts nothing and destroys nothing before the queued detach ran")
    func detachTimeoutAtG() async {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let log = trace(rig)
        rig.runControl.blocked = true

        rig.system.outputs.removeAll { $0.uid == "uid-tv" }
        coordinator.reconcile()
        rig.clock.runDue()
        #expect(await eventually { log.all.contains("detach uid-tv 200 timed out") })
        rig.clock.advance(60)
        await settle()
        #expect(!log.all.contains { $0.hasPrefix("destroy") })

        rig.runControl.unblock()
        #expect(await eventually { log.all.contains { $0.hasPrefix("destroy") } })
        #expect(log.all == [
            "hold 200 pending=0",
            "ended uid-tv absent",
            "detach uid-tv 200 timed out",
            "queue ran detach uid-tv 200",
            "destroy tap=100 aggregate=200 proc=true",
        ])
    }

    // MARK: Rebuild (E) and push failures

    @Test("E: a push that fails after its retry rebuilds make before break; generations stay, and the old one is held, the new opened, then the old detached and destroyed")
    func rebuildAfterPushFailure() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let old = try #require(rig.tv)
        let owners = [FakeClaimOwner(), FakeClaimOwner(pid: 2), FakeClaimOwner(pid: 3)]
        rig.backend.failSets = 2
        let first = try #require(coordinator.setClaim(owners[0], Claim(processes: [11], coverage: .allDevices)))
        #expect(first.generations == ["uid-tv": 1])
        let log = trace(rig)
        let done = CoordinatorTestBox(0)
        Task { await coordinator.waitApplied(first, .grow); done.value += 1 }
        #expect(await eventually { coordinator.pendingWaitCount == 1 })

        // The push and its retry fail; the next turn builds the new catch-all held with [5, 11]
        rig.clock.runDue()
        let new = try #require(rig.tv)
        #expect(new !== old)
        #expect(new.appliedExclusions == [5, 11])
        #expect(rig.runControl.log.contains("attach uid-tv [5, 11] held=true"))
        #expect(held(new))
        #expect(!held(old))

        // A claim during the rebuild gets the next generation and goes to the new catch-all
        let second = try #require(coordinator.setClaim(owners[1], Claim(processes: [12], coverage: .allDevices)))
        #expect(second.generations == ["uid-tv": 2])
        Task { await coordinator.waitApplied(second, .grow); done.value += 1 }
        #expect(await eventually { coordinator.pendingWaitCount == 2 })
        rig.clock.runDue()
        #expect(new.appliedExclusions == [5, 11, 12])
        #expect(old.appliedExclusions == [5])
        rig.clock.advance(0.19)
        await settle()
        #expect(done.value == 0)

        // No IO callback: it takes over after 200 ms, and both waits resolve against it
        rig.clock.advance(0.01)
        #expect(await eventually { done.value == 2 })
        #expect(await eventually { log.all.contains { $0.hasPrefix("destroy") } })
        #expect(log.all == [
            "hold 200 pending=2",
            "open 201 pending=2",
            "rebuilt uid-tv",
            "detach uid-tv 200",
            "destroy tap=100 aggregate=200 proc=true",
        ])
        #expect(held(old))
        #expect(!held(new))
        let third = try #require(coordinator.setClaim(owners[2], Claim(processes: [13], coverage: .allDevices)))
        #expect(third.generations == ["uid-tv": 3])
        withExtendedLifetime(owners) {}
    }

    @Test("E takes over at the new catch-all's first IO callback once its list applied")
    func rebuildAtFirstCallback() throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.rebuild("uid-tv", reason: .formatChanged)
        rig.clock.runDue()
        let new = try #require(rig.tv)
        #expect(held(new))

        rig.clock.advance(0.05)
        #expect(held(new))
        new.renderState.callbackCount.store(1, ordering: .relaxed)
        rig.clock.advance(0.01)
        #expect(!held(new))
        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
    }

    @Test("One rebuild per device at a time: a push failure during one is served by it, another reason runs once more after it took over")
    func rebuildCoalesced() {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let builds = { rig.backend.log.filter { $0 == "createTap" }.count }

        coordinator.rebuild("uid-tv", reason: .formatChanged)
        coordinator.rebuild("uid-tv", reason: .formatChanged)
        rig.clock.runDue()
        #expect(builds() == 2)

        coordinator.rebuild("uid-tv", reason: .pushFailed)
        coordinator.rebuild("uid-tv", reason: .ioFailed)
        coordinator.rebuild("uid-tv", reason: .formatChanged)
        rig.clock.runDue()
        #expect(builds() == 2)
        rig.clock.advance(0.2)
        #expect(builds() == 3)
        rig.clock.advance(0.2)
        #expect(builds() == 3)
        #expect(rig.events.events.filter { $0 == .rebuilt(uid: "uid-tv") }.count == 2)
    }

    @Test("A push that fails after its retry and a rebuild that fails retire the catch-all (R); the waits complete at R3")
    func pushFailureRetires() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let tv = try #require(rig.tv)
        let owner = FakeClaimOwner()
        rig.backend.failSets = 2
        rig.backend.failAt = .createTap
        let ticket = try #require(coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices)))
        let log = trace(rig)
        let heldAtEnd = startWait(coordinator, ticket, tv)
        #expect(await eventually { coordinator.pendingWaitCount == 1 })
        coordinator.onCoverageWillEnd = { uid in
            log.add("onCoverageWillEnd \(uid) pending=\(coordinator.pendingWaitCount)")
            return false
        }

        rig.clock.runDue()
        log.add("turn done pending=\(coordinator.pendingWaitCount)")

        #expect(await eventually { log.all.contains { $0.hasPrefix("destroy") } })
        #expect(log.all == [
            "failure buildFailed uid-tv",
            "retiring uid-tv pushFailed",
            "onCoverageWillEnd uid-tv pending=1",
            "hold 200 pending=1",
            "turn done pending=0",
            "detach uid-tv 200",
            "ended uid-tv pushFailed",
            "destroy tap=100 aggregate=200 proc=true",
        ])
        #expect(await eventually { heldAtEnd.value == true })
        #expect(rig.events.events.contains { if case .buildFailed(uid: "uid-tv", _) = $0 { true } else { false } })
        withExtendedLifetime(owner) {}
    }

    @Test("A new catch-all still held because its first push failed twice is rebuilt, and the new one opens once its list applied")
    func heldNewCatchAllRebuilt() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let backend = rig.backend
        let owner = FakeClaimOwner()
        backend.onWaitUntilReady = {
            MainActor.assumeIsolated {
                // A per-app tap created during the build's wait; the push after the build fails twice
                _ = coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices))
                backend.failSets = 2
            }
        }
        coordinator.start()
        backend.onWaitUntilReady = nil
        let old = try #require(rig.tv)
        #expect(held(old))
        let log = trace(rig)

        rig.clock.runDue()
        let new = try #require(rig.tv)
        #expect(new !== old)
        #expect(new.appliedExclusions == [5, 11])
        #expect(held(new))
        rig.clock.advance(0.2)

        #expect(!held(new))
        #expect(held(old))
        #expect(rig.events.events.contains(.released(uid: "uid-tv")))
        #expect(await eventually { log.all.contains { $0.hasPrefix("destroy") } })
        #expect(log.all == [
            "hold 200 pending=0",
            "open 201 pending=0",
            "rebuilt uid-tv",
            "detach uid-tv 200",
            "destroy tap=100 aggregate=200 proc=true",
        ])
        withExtendedLifetime(owner) {}
    }

    @Test("A rebuild whose device goes away during its build ends with G: no R2, nothing counted")
    func rebuildOfVanishingDevice() async {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let backend = rig.backend
        // Still listed, but Core Audio no longer resolves the UID, and the build fails at its wait
        backend.onWaitUntilReady = { backend.deviceIDs = [:] }
        backend.failAt = .ready
        let calledBack = CoordinatorTestBox(false)
        coordinator.onCoverageWillEnd = { _ in
            calledBack.value = true
            return false
        }

        coordinator.rebuild("uid-tv", reason: .ioFailed)
        rig.clock.runDue()

        #expect(!calledBack.value)
        #expect(coordinator.phase("uid-tv") == nil)
        #expect(rig.events.events.contains { if case .buildFailed(uid: "uid-tv", _) = $0 { true } else { false } })
        #expect(rig.events.events.contains(.ended(uid: "uid-tv", reason: "absent")))
        #expect(!rig.events.events.contains { if case .failure = $0 { true } else { false } })
        #expect(!rig.events.events.contains { if case .retiring = $0 { true } else { false } })
        #expect(await eventually { backend.log.contains("destroy tap=100 aggregate=200 proc=true") })
    }

    @Test("A rebuild whose build fails after stop() ran during its wait retires nothing and counts nothing")
    func rebuildFailsAfterStop() async {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let backend = rig.backend
        backend.onWaitUntilReady = { MainActor.assumeIsolated { coordinator.stop() } }
        backend.failAt = .ready
        let calledBack = CoordinatorTestBox(false)
        coordinator.onCoverageWillEnd = { _ in
            calledBack.value = true
            return false
        }

        coordinator.rebuild("uid-tv", reason: .ioFailed)
        rig.clock.runDue()
        backend.onWaitUntilReady = nil

        #expect(!calledBack.value)
        #expect(coordinator.phase("uid-tv") == nil)
        #expect(rig.events.events.contains(.ended(uid: "uid-tv", reason: "stopped")))
        #expect(!rig.events.events.contains { if case .failure = $0 { true } else { false } })
        #expect(!rig.events.events.contains { if case .buildFailed = $0 { true } else { false } })
        #expect(!rig.events.events.contains { if case .retiring = $0 { true } else { false } })
        #expect(rig.runControl.log.filter { $0 == "stop" }.count == 1)
        #expect(await eventually { backend.log.contains("destroy tap=100 aggregate=200 proc=true") })
    }

    @Test("A first build that fails after stop() ran during its wait reports no build failure")
    func buildFailsAfterStop() {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        rig.backend.onWaitUntilReady = { MainActor.assumeIsolated { coordinator.stop() } }
        rig.backend.failAt = .ready

        coordinator.start()
        rig.backend.onWaitUntilReady = nil

        #expect(coordinator.phase("uid-tv") == nil)
        #expect(rig.events.events.contains(.ended(uid: "uid-tv", reason: "stopped")))
        #expect(!rig.events.events.contains { if case .buildFailed = $0 { true } else { false } })
    }

    @Test("A detach timeout on the catch-all a rebuild replaced retires the device; the blocked queue counts once, and nothing is destroyed before the queued detaches ran")
    func detachTimeoutAtRebuild() async {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.rebuild("uid-tv", reason: .formatChanged)
        rig.clock.runDue()
        let log = trace(rig)
        rig.runControl.blocked = true

        // The new catch-all takes over after 200 ms; the old one's detach times out
        rig.clock.advance(0.2)
        #expect(await eventually { log.all.contains("failure runQueueTimeout uid-tv") })
        rig.clock.runDue()
        #expect(await eventually { log.all.contains("ended uid-tv runQueueTimeout") })
        rig.clock.advance(60)
        await settle()
        #expect(!log.all.contains { $0.hasPrefix("destroy") })

        rig.runControl.unblock()
        #expect(await eventually { log.all.filter { $0.hasPrefix("destroy") }.count == 2 })
        #expect(Array(log.all.prefix(11)) == [
            "hold 200 pending=0",
            "open 201 pending=0",
            "rebuilt uid-tv",
            "detach uid-tv 200 timed out",
            "failure runQueueTimeout uid-tv",
            "retiring uid-tv runQueueTimeout",
            "hold 201 pending=0",
            "detach uid-tv 201 timed out",
            "ended uid-tv runQueueTimeout",
            "queue ran detach uid-tv 200",
            "queue ran detach uid-tv 201",
        ])
        #expect(log.all.filter { $0.hasPrefix("failure") }.count == 1)
    }

    @Test("Rebuild reports repeat for one aggregate: one about the catch-all being replaced, already replaced or unknown is dropped")
    func rebuildReportsDeduplicated() throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let old = try #require(rig.tv).ioHandle.aggregateID
        let builds = { rig.backend.log.filter { $0 == "createTap" }.count }
        // A repeat while the new catch-all builds
        rig.backend.onWaitUntilReady = {
            MainActor.assumeIsolated { coordinator.rebuild("uid-tv", reason: .ioFailed, aggregate: old) }
        }

        coordinator.rebuild("uid-tv", reason: .ioFailed, aggregate: old)
        coordinator.rebuild("uid-tv", reason: .ioFailed, aggregate: old)
        rig.clock.runDue()
        rig.backend.onWaitUntilReady = nil
        #expect(builds() == 2)
        let new = try #require(rig.tv).ioHandle.aggregateID
        #expect(new != old)

        // While the new one waits to take over, after it took over, and for an unknown aggregate
        coordinator.rebuild("uid-tv", reason: .ioFailed, aggregate: old)
        rig.clock.advance(0.2)
        #expect(rig.events.events.filter { $0 == .rebuilt(uid: "uid-tv") }.count == 1)
        coordinator.rebuild("uid-tv", reason: .ioFailed, aggregate: old)
        coordinator.rebuild("uid-tv", reason: .ioFailed, aggregate: 999)
        rig.clock.advance(1)
        #expect(builds() == 2)

        // A report about the catch-all in service rebuilds it
        coordinator.rebuild("uid-tv", reason: .ioFailed, aggregate: new)
        rig.clock.runDue()
        #expect(builds() == 3)
    }

    @Test("E: the new catch-all takes over only once it excludes no live process without a claim and its inclusions are past S")
    func rebuildTakeoverWaitsForInclusion() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        let owner = FakeClaimOwner()
        _ = coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices))
        rig.clock.advance(1)
        let old = try #require(rig.tv)
        #expect(old.appliedExclusions == [5, 11])
        // The claim ends while the new catch-all builds with 11 excluded, and the flush after its
        // attach cannot read the process list
        let shrink = CoordinatorTestBox<ApplyTicket?>(nil)
        let system = rig.system
        rig.backend.onWaitUntilReady = {
            MainActor.assumeIsolated {
                shrink.value = coordinator.removeClaim(ObjectIdentifier(owner))
                system.processListReadable = false
            }
        }
        coordinator.rebuild("uid-tv", reason: .formatChanged)
        rig.clock.runDue()
        rig.backend.onWaitUntilReady = nil
        let new = try #require(rig.tv)
        #expect(new !== old)
        #expect(new.appliedExclusions == [5, 11])
        let ticket = try #require(shrink.value)
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .shrink); done.value = true }
        #expect(await eventually { coordinator.pendingWaitCount == 1 })

        // The first IO callback, and the list readable again before the flush retries: the new
        // catch-all still excludes 11, so it does not take over
        rig.clock.advance(0.055)
        system.processListReadable = true
        new.renderState.callbackCount.store(1, ordering: .relaxed)
        rig.clock.advance(0.01)
        #expect(!rig.events.events.contains(.rebuilt(uid: "uid-tv")))

        // The retry at 100 ms pushes the inclusion; it takes over S after that push, not G
        rig.clock.advance(0.035)
        #expect(new.appliedExclusions == [5])
        rig.clock.advance(0.39)
        #expect(!rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        #expect(held(new))
        rig.clock.advance(0.01)
        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        #expect(!held(new))
        #expect(held(old))
        #expect(await eventually { done.value })
        withExtendedLifetime(owner) {}
    }

    @Test("E: a takeover check that cannot read the process list once tries again 100 ms later, not at its watchdog")
    func rebuildTakeoverRetriesUnreadableList() throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.rebuild("uid-tv", reason: .formatChanged)
        rig.clock.runDue()
        let new = try #require(rig.tv)
        #expect(held(new))

        // The first IO callback; the poll after it reads no process list, once. No push
        // deadline is left to check it again.
        new.renderState.callbackCount.store(1, ordering: .relaxed)
        rig.system.failingReads = 1
        rig.clock.advance(0.01)
        #expect(rig.system.failingReads == 0)
        #expect(held(new))
        #expect(!rig.events.events.contains(.rebuilt(uid: "uid-tv")))

        rig.clock.advance(0.1)
        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        #expect(!held(new))
        rig.clock.advance(3)
        #expect(!rig.events.events.contains { if case .watchdog = $0 { true } else { false } })
        #expect(!rig.events.events.contains { if case .retiring = $0 { true } else { false } })
    }

    @Test("A rebuild that cannot read the process list tries again while the old catch-all serves; nothing counts")
    func rebuildDeferred() throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let old = try #require(rig.tv)
        let builds = { rig.backend.log.filter { $0 == "createTap" }.count }
        rig.system.processListReadable = false

        coordinator.rebuild("uid-tv", reason: .formatChanged)
        rig.clock.runDue()
        rig.clock.advance(1.5)
        #expect(builds() == 1)
        #expect(rig.tv === old)
        #expect(!held(old))

        rig.system.processListReadable = true
        rig.clock.advance(0.1)
        #expect(builds() == 2)
        rig.clock.advance(0.2)
        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        #expect(!rig.events.events.contains { if case .failure = $0 { true } else { false } })
        #expect(!rig.events.events.contains { if case .retiring = $0 { true } else { false } })
        #expect(!rig.events.events.contains { if case .buildFailed = $0 { true } else { false } })
    }

    // MARK: Watchdogs

    @Test("Grow watchdog: a wait whose exclusion is in force but not confirmed ends after max(1 s, G + 0.6 s)")
    func growWatchdogInForce() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let tv = try #require(rig.tv)
        tv.renderState.callbackCount.store(10, ordering: .relaxed)
        rig.system.processListReadable = false
        let owner = FakeClaimOwner()
        let ticket = try #require(coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices)))
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .grow); done.value = true }
        #expect(await eventually { coordinator.pendingWaitCount == 1 })

        // The flush reads no process list until 0.7 s, then pushes; one IO callback follows
        rig.clock.advance(0.65)
        rig.system.processListReadable = true
        rig.clock.advance(0.1)
        #expect(tv.appliedExclusions == [5, 11])
        tv.renderState.callbackCount.store(11, ordering: .relaxed)
        rig.clock.advance(0.24)
        await settle()
        #expect(!done.value)

        rig.clock.advance(0.01)
        #expect(await eventually { done.value })
        #expect(rig.events.events.contains(.watchdog(uid: "uid-tv", .grow)))
        #expect(!rig.events.events.contains { if case .retiring = $0 { true } else { false } })
        withExtendedLifetime(owner) {}
    }

    @Test("Grow watchdog: with the process list unreadable it judges 2 s late; a missing exclusion then takes the push-failure path and ends only at R3, never released into doubling")
    func growWatchdogMissing() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let tv = try #require(rig.tv)
        rig.system.processListReadable = false
        let owner = FakeClaimOwner()
        let ticket = try #require(coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices)))
        let log = trace(rig)
        let heldAtEnd = startWait(coordinator, ticket, tv)
        #expect(await eventually { coordinator.pendingWaitCount == 1 })
        coordinator.onCoverageWillEnd = { uid in
            log.add("onCoverageWillEnd \(uid) pending=\(coordinator.pendingWaitCount)")
            return false
        }

        // Which processes live is unknown: not judged at 1 s, but at 1 s + 2 s
        rig.clock.advance(2.99)
        await settle()
        #expect(log.all.isEmpty)
        rig.clock.advance(0.01)
        #expect(log.all == ["watchdog grow uid-tv"])

        // The rebuild cannot read the process list either: it tries again for 2 s, then R;
        // nothing counts
        rig.clock.advance(1.99)
        #expect(log.all == ["watchdog grow uid-tv"])
        rig.clock.advance(0.01)
        log.add("watchdog done pending=\(coordinator.pendingWaitCount)")
        #expect(log.all == [
            "watchdog grow uid-tv",
            "watchdog rebuild uid-tv",
            "retiring uid-tv pushFailed",
            "onCoverageWillEnd uid-tv pending=1",
            "hold 200 pending=1",
            "watchdog done pending=0",
        ])
        #expect(await eventually { heldAtEnd.value == true })
        #expect(rig.backend.log.filter { $0 == "createTap" }.count == 1)
        withExtendedLifetime(owner) {}
    }

    @Test("Grow watchdog: a flush already queued runs first, and a list pushed less than G ago is not judged yet")
    func growWatchdogFlushesFirst() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let tv = try #require(rig.tv)
        rig.system.processListReadable = false
        let owner = FakeClaimOwner()
        let ticket = try #require(coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices)))
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .grow); done.value = true }
        #expect(await eventually { coordinator.pendingWaitCount == 1 })

        // At 1 s the watchdog and the flush's retry are due together; the push goes first
        rig.clock.advance(0.95)
        rig.system.processListReadable = true
        rig.clock.advance(0.05)
        #expect(tv.appliedExclusions == [5, 11])
        await settle()
        #expect(!done.value)

        // The push applied after G (the IO is stopped), with no rebuild
        rig.clock.advance(0.13)
        #expect(await eventually { done.value })
        #expect(rig.backend.log.filter { $0 == "createTap" }.count == 1)
        #expect(!rig.events.events.contains { if case .retiring = $0 { true } else { false } })
        withExtendedLifetime(owner) {}
    }

    @Test("A wait stops waiting for a device its watchdog found in force, and is judged again while it waits for another")
    func watchdogRejudges() async throws {
        let rig = makeCatchAllRig { system in
            system.outputs.append(CatchAllOutput(uid: "uid-tv2", id: 44))
            system.tiers[44] = .software
            system.alive.insert(44)
            system.foreign = [13]
        }
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        #expect(rig.tv?.appliedExclusions == [5, 13])
        rig.system.processListReadable = false
        let owners = [FakeClaimOwner(), FakeClaimOwner(pid: 2, targets: ["uid-tv2"])]
        // The TV already excludes 13 (another user's process); the second TV lacks 11
        let first = try #require(coordinator.setClaim(owners[0], Claim(processes: [13], coverage: .device("uid-tv"))))
        let second = try #require(coordinator.setClaim(owners[1], Claim(processes: [11], coverage: .device("uid-tv2"))))
        let ticket = ApplyTicket(generations: first.generations.merging(second.generations) { $1 })
        #expect(ticket.devices == ["uid-tv", "uid-tv2"])
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .grow); done.value = true }
        #expect(await eventually { coordinator.pendingWaitCount == 1 })

        rig.clock.advance(2.99)
        #expect(!rig.events.events.contains { if case .watchdog = $0 { true } else { false } })
        rig.clock.advance(0.01)
        #expect(rig.events.events.contains(.watchdog(uid: "uid-tv", .grow)))
        #expect(rig.events.events.contains(.watchdog(uid: "uid-tv2", .grow)))

        // The second TV's rebuild cannot read the list: R after 2 s more. No flush ran, so the
        // TV's generation never applied, yet the wait ends at the second TV's R3.
        rig.clock.advance(1.99)
        await settle()
        #expect(!done.value)
        rig.clock.advance(0.01)
        #expect(rig.events.events.contains(.retiring(uid: "uid-tv2", .pushFailed)))
        #expect(await eventually { done.value })
        #expect(coordinator.phase("uid-tv") == .live)
        withExtendedLifetime(owners) {}
    }

    @Test("Shrink watchdog: a wait whose inclusion is in force ends after 2 s, before S has passed")
    func shrinkWatchdog() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        let owner = FakeClaimOwner()
        _ = coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices))
        rig.clock.advance(1)
        let tv = try #require(rig.tv)
        #expect(tv.appliedExclusions == [5, 11])
        rig.system.processListReadable = false
        let ticket = try #require(coordinator.removeClaim(ObjectIdentifier(owner)))
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .shrink); done.value = true }
        #expect(await eventually { coordinator.pendingWaitCount == 1 })

        // The flush reads no process list until 1.7 s, then pushes the inclusion
        rig.clock.advance(1.65)
        rig.system.processListReadable = true
        rig.clock.advance(0.1)
        #expect(tv.appliedExclusions == [5])
        rig.clock.advance(0.24)
        await settle()
        #expect(!done.value)

        rig.clock.advance(0.01)
        #expect(await eventually { done.value })
        #expect(rig.events.events.contains(.watchdog(uid: "uid-tv", .shrink)))
    }

    /// `judged`: the watchdog's time (2 s) or its last chance with an unreadable list (2 s more).
    @Test("Shrink watchdog: an inclusion pushed when the wait is judged ends it only G after the push, since Core Audio may not apply it before",
          arguments: [2.0, 4.0])
    func shrinkWatchdogYoungInclusion(judged: Double) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        let owner = FakeClaimOwner()
        _ = coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices))
        rig.clock.advance(1)
        let tv = try #require(rig.tv)
        #expect(tv.appliedExclusions == [5, 11])
        rig.system.processListReadable = false
        let ticket = try #require(coordinator.removeClaim(ObjectIdentifier(owner)))
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .shrink); done.value = true }
        #expect(await eventually { coordinator.pendingWaitCount == 1 })

        // The list reads again 50 ms before; the flush's retry and the watchdog are then due
        // together, and the inclusion is pushed first
        rig.clock.advance(judged - 0.05)
        rig.system.processListReadable = true
        rig.clock.advance(0.05)
        #expect(tv.appliedExclusions == [5])
        await settle()
        #expect(!done.value)
        #expect(!rig.events.events.contains { if case .watchdog = $0 { true } else { false } })

        rig.clock.advance(0.12)
        await settle()
        #expect(!done.value)
        rig.clock.advance(0.01)
        #expect(await eventually { done.value })
        #expect(rig.events.events.contains(.watchdog(uid: "uid-tv", .shrink)))
        withExtendedLifetime(owner) {}
    }

    @Test("Retirement watchdog: R3 is forced 2 s after R1 while R2 has not returned, and its tickets complete then")
    func retirementWatchdog() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let tv = try #require(rig.tv)
        let owner = FakeClaimOwner()
        let ticket = try #require(coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices)))
        rig.clock.runDue()
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .grow); done.value = true }
        #expect(await eventually { coordinator.pendingWaitCount == 1 })
        let seen = LineLog()
        let clock = rig.clock
        coordinator.onCoverageWillEnd = { uid in
            // A callback whose spin lasts 2 s
            clock.advance(1.99)
            seen.add("caHeld=\(coordinator.phase(uid) == .retiring(caHeld: true)) pending=\(coordinator.pendingWaitCount) held=\(held(tv))")
            clock.advance(0.01)
            seen.add("caHeld=\(coordinator.phase(uid) == .retiring(caHeld: true)) pending=\(coordinator.pendingWaitCount) held=\(held(tv))")
            return false
        }

        coordinator.retire("uid-tv", reason: .injected)
        rig.clock.runDue()

        #expect(seen.all == ["caHeld=false pending=1 held=false", "caHeld=true pending=0 held=true"])
        #expect(rig.events.events.contains(.watchdog(uid: "uid-tv", .retirement)))
        // The grow wait's watchdog passed during R2 and left it to the retirement, without a fault
        #expect(!rig.events.events.contains(.watchdog(uid: "uid-tv", .grow)))
        #expect(await eventually { done.value })
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        withExtendedLifetime(owner) {}
    }

    @Test("Initial-list watchdog: a new catch-all still held after max(1 s, G + 0.6 s) takes the push-failure path")
    func initialListWatchdog() throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let system = rig.system
        let owner = FakeClaimOwner()
        rig.backend.onWaitUntilReady = {
            MainActor.assumeIsolated {
                _ = coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices))
                system.processListReadable = false
            }
        }
        coordinator.start()
        rig.backend.onWaitUntilReady = nil
        let tv = try #require(rig.tv)
        #expect(held(tv))

        rig.clock.advance(0.99)
        #expect(!rig.events.events.contains(.watchdog(uid: "uid-tv", .initialList)))
        rig.clock.advance(0.01)
        #expect(rig.events.events.contains(.watchdog(uid: "uid-tv", .initialList)))

        // The rebuild cannot read the process list either: it tries again for 2 s, then R,
        // and the catch-all stays held; nothing counts
        rig.clock.advance(1.99)
        #expect(!rig.events.events.contains { if case .retiring = $0 { true } else { false } })
        rig.clock.advance(0.01)
        #expect(rig.events.events.contains(.watchdog(uid: "uid-tv", .rebuild)))
        #expect(rig.events.events.contains(.retiring(uid: "uid-tv", .pushFailed)))
        #expect(!rig.events.events.contains { if case .failure = $0 { true } else { false } })
        #expect(held(tv))
        withExtendedLifetime(owner) {}
    }

    @Test("Rebuild watchdog: a rebuilt catch-all that has not taken over 2 s after its attach is retired with the one it replaces")
    func rebuildWatchdog() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let old = try #require(rig.tv)
        let log = trace(rig)
        coordinator.rebuild("uid-tv", reason: .formatChanged)
        rig.clock.runDue()
        let new = try #require(rig.tv)
        #expect(new !== old)
        // Without a process list its list cannot be confirmed, so it never takes over
        rig.system.processListReadable = false

        rig.clock.advance(1.99)
        #expect(log.all.isEmpty)
        rig.clock.advance(0.01)

        #expect(await eventually { log.all.filter { $0.hasPrefix("destroy") }.count == 2 })
        let lines = log.all
        #expect(Array(lines.prefix(4)) == [
            "watchdog rebuild uid-tv",
            "retiring uid-tv rebuildFailed",
            "hold 201 pending=0",
            "hold 200 pending=0",
        ])
        #expect(held(old))
        #expect(held(new))
        for aggregate in [200, 201] {
            let detach = try #require(lines.firstIndex { $0 == "detach uid-tv \(aggregate)" })
            let destroy = try #require(lines.firstIndex { $0.contains("aggregate=\(aggregate) ") })
            #expect(detach < destroy)
        }
    }

    @Test("Rebuild watchdog: a rebuilt catch-all that is ready when the watchdog is due takes over instead of retiring")
    func rebuildWatchdogLetsReadyTakeoverWin() throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.rebuild("uid-tv", reason: .formatChanged)
        rig.clock.runDue()
        let new = try #require(rig.tv)
        new.renderState.callbackCount.store(1, ordering: .relaxed)
        rig.system.processListReadable = false

        // Readable again at 1.95 s; the next retry would come only after the watchdog's 2 s
        rig.clock.advance(1.95)
        #expect(held(new))
        rig.system.processListReadable = true
        rig.clock.advance(0.05)

        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        #expect(!held(new))
        #expect(!rig.events.events.contains { if case .watchdog = $0 { true } else { false } })
        #expect(!rig.events.events.contains { if case .retiring = $0 { true } else { false } })
    }

    @Test("The rebuild watchdog does not fire while the device retires; the retirement bounds it")
    func rebuildWatchdogQuietDuringRetirement() async {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.rebuild("uid-tv", reason: .formatChanged)
        rig.clock.runDue()
        let clock = rig.clock
        // R2 spins 2.5 s, past the rebuilt catch-all's 2 s
        coordinator.onCoverageWillEnd = { _ in
            clock.advance(2.5)
            return false
        }

        coordinator.retire("uid-tv", reason: .injected)
        rig.clock.runDue()

        #expect(rig.events.events.contains(.watchdog(uid: "uid-tv", .retirement)))
        #expect(!rig.events.events.contains(.watchdog(uid: "uid-tv", .rebuild)))
        #expect(!rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        #expect(await eventually { rig.backend.log.filter { $0.hasPrefix("destroy") }.count == 2 })
    }
}
