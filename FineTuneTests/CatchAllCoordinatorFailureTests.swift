// FineTuneTests/CatchAllCoordinatorFailureTests.swift
//
// Failure handling of the coordinator (design §16.8 test 5, coordinator side): retirement with
// promotion (R) and its tickets, the end of coverage without promotion (G), stop(), the
// make-before-break rebuild (E), push failures, queued retirements, the watchdogs, dormant
// devices (E12), IO failure reports, failure counting, backoff, give-up and the breaker. Fake
// claim owners, fake IsAlive observations and one ordered log per test; no Core Audio object
// is created.

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
/// number of pending waits at that moment, so a wait that ends too early shows. `e12` adds
/// attaches, phase changes, IsAlive observations, backoffs, give-ups and the breaker.
private func trace(_ rig: CatchAllCoordinatorRig, e12: Bool = false) -> LineLog {
    let log = LineLog()
    let coordinator = rig.coordinator
    let events = rig.events
    rig.runControl.onRecord = { line in
        if line.hasPrefix("detach") || line.hasPrefix("queue ran") || line == "stop" || (e12 && line.hasPrefix("attach")) {
            log.add(line)
        }
    }
    rig.backend.onRecord = { entry in
        if entry.hasPrefix("destroy") { log.add(entry) }
    }
    if e12 { rig.aliveObservers.onRecord = { log.add($0) } }
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
        case .phase(let uid, let phase) where e12:
            log.add("phase \(uid) \(phase)")
        case .backoff(let uid, let seconds) where e12:
            log.add("backoff \(uid) \(Int(seconds))")
        case .givenUp(let uid, let deviceID) where e12:
            log.add("givenUp \(uid) \(deviceID)")
        case .breakerOpened where e12:
            log.add("breaker open")
        default:
            break
        }
    }
    return log
}

/// The TV's catch-all goes dormant: the device stays listed but is no longer alive, and a
/// device-list refresh runs the E12 check in the coordinator's next turn.
private func makeDormant(_ rig: CatchAllCoordinatorRig, _ device: AudioDeviceID = 42) {
    rig.system.alive.remove(device)
    rig.coordinator.deviceListRefreshed()
    rig.clock.runDue()
}

/// Lists the TV under a new ID with software volume, alive or not; Core Audio resolves its UID
/// to it.
private func relist(_ rig: CatchAllCoordinatorRig, as id: AudioDeviceID, alive: Bool) {
    rig.system.outputs = rig.system.outputs.map { $0.uid == "uid-tv" ? CatchAllOutput(uid: "uid-tv", id: id) : $0 }
    rig.system.tiers[id] = .software
    if alive { rig.system.alive.insert(id) } else { rig.system.alive.remove(id) }
    rig.backend.deviceIDs["uid-tv"] = id
}

/// A run-control report hopped to main: waits until the coordinator handled it.
private func reportIO(_ rig: CatchAllCoordinatorRig, _ uid: String, _ aggregate: AudioDeviceID,
                      _ reason: CatchAllRunLogic.RebuildReason = .ioDead) async {
    let done = CoordinatorTestBox(false)
    rig.runControl.onRebuild?(uid, aggregate, reason)
    // The coordinator's hop is queued first, so this one runs after it
    DispatchQueue.main.async { MainActor.assumeIsolated { done.value = true } }
    _ = await eventually { done.value }
}

/// Reports an IO failure on the TV's catch-all in service, lets its rebuild, if any, take over
/// after 200 ms, and lets the failure settle: it counts 1 s after the report.
private func failIO(_ rig: CatchAllCoordinatorRig) async throws {
    let aggregate = try #require(rig.tv).ioHandle.aggregateID
    await reportIO(rig, "uid-tv", aggregate)
    rig.clock.runDue()
    rig.clock.advance(CatchAllCoordinator.failureSettle)
}

/// Starts the coordinator with one failed first build of the TV, or two 5 s apart: failures
/// toward the breaker, each counted 1 s after it. The build after the backoff succeeds.
private func failFirstBuilds(_ rig: CatchAllCoordinatorRig, _ count: Int) {
    rig.backend.failAt = .createTap
    rig.coordinator.start()
    if count > 1 { rig.clock.advance(5) }
    rig.backend.failAt = nil
    rig.clock.advance(count > 1 ? 30 : 5)
}

/// Catch-alls built so far, failed builds included.
private func builds(_ rig: CatchAllCoordinatorRig) -> Int {
    rig.backend.log.filter { $0 == "createTap" }.count
}

private func failures(_ rig: CatchAllCoordinatorRig) -> [CatchAllEvent] {
    rig.events.events.filter { if case .failure = $0 { true } else { false } }
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

/// Runs `body` from a block of the main run loop rather than from a main-queue job, as a build
/// that starts outside one does. A run loop spun inside it (`spin`, a build's wait, V4) then
/// also runs main-actor tasks, such as a detach that returns meanwhile; inside a main-queue job
/// libdispatch does not drain the main queue again. A block performed by a run loop that a
/// main-queue job spins is such a case: it tries again later.
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

    @Test("A grow wait on a dormant catch-all ends at once")
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

    @Test("Generations survive R4: an older ticket resolves against the catch-all built again, and new tickets count on")
    func generationsSurviveRetirement() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let owners = [FakeClaimOwner(), FakeClaimOwner(pid: 2)]
        let first = try #require(coordinator.setClaim(owners[0], Claim(processes: [11], coverage: .allDevices)))
        #expect(first.generations == ["uid-tv": 1])
        rig.clock.advance(1)
        coordinator.onCoverageWillEnd = { _ in false }
        coordinator.retire("uid-tv", reason: .injected)
        rig.clock.runDue()
        #expect(await eventually { coordinator.phase("uid-tv") == nil })

        // Without backoff yet, the next reconcile builds the device again with the claim's list
        coordinator.reconcile()
        rig.clock.runDue()
        #expect(coordinator.phase("uid-tv") == .live)
        #expect(rig.tv?.appliedExclusions == [5, 11])
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(first, .grow); done.value = true }
        #expect(await eventually { done.value || coordinator.pendingWaitCount == 1 })
        #expect(done.value)
        let second = try #require(coordinator.setClaim(owners[1], Claim(processes: [12], coverage: .allDevices)))
        #expect(second.generations == ["uid-tv": 2])
        withExtendedLifetime(owners) {}
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

    /// `atStop`: the keep-aside ends at stop() instead of at its expiry.
    @Test("A kept-aside catch-all whose detach timed out is destroyed only after the queued detach ran, when its keep-aside ends at expiry or at stop()",
          arguments: [false, true])
    func keptAsideDetachTimeout(atStop: Bool) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let log = trace(rig)
        rig.runControl.blocked = true
        // R2 finds an absent app routed here; at expiry it is no longer
        let answers = CoordinatorTestBox(atStop ? [true] : [true, false])
        coordinator.onCoverageWillEnd = { _ in answers.value.removeFirst() }

        coordinator.retire("uid-tv", reason: .injected)
        rig.clock.runDue()
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        #expect(log.all.contains("detach uid-tv 200 timed out"))

        if atStop {
            coordinator.stop()
        } else {
            rig.clock.advance(30)
        }
        #expect(answers.value.isEmpty)
        await settle()
        #expect(!log.all.contains { $0.hasPrefix("destroy") })

        rig.runControl.unblock()
        #expect(await eventually { log.all.contains { $0.hasPrefix("destroy") } })
        let ran = try #require(log.all.firstIndex(of: "queue ran detach uid-tv 200"))
        let destroy = try #require(log.all.firstIndex(of: "destroy tap=100 aggregate=200 proc=true"))
        #expect(ran < destroy)
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

    @Test("A push that fails after its retry and a rebuild that fails retire the catch-all (R) once the failure settled with the device still alive under its ID; the old one serves until then, and the waits complete at R3")
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
        #expect(log.all.isEmpty)
        #expect(rig.tv === tv)
        #expect(!held(tv))
        // The grow watchdog judges the wait at the same moment: the list lacks 11, and the
        // rebuild it asks for is left to the settle, whose R ends the wait
        rig.clock.advance(CatchAllCoordinator.failureSettle)
        log.add("settled pending=\(coordinator.pendingWaitCount)")

        #expect(await eventually { log.all.contains { $0.hasPrefix("destroy") } })
        #expect(log.all == [
            "watchdog grow uid-tv",
            "failure buildFailed uid-tv",
            "retiring uid-tv pushFailed",
            "onCoverageWillEnd uid-tv pending=1",
            "hold 200 pending=1",
            "settled pending=0",
            "detach uid-tv 200",
            "ended uid-tv pushFailed",
            "destroy tap=100 aggregate=200 proc=true",
        ])
        #expect(builds(rig) == 2)
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

    @Test("A push whose read-back failed twice leaves the tap's list unconfirmed: a claim change back to the recorded list ends no wait before the rebuild takes over, and the rebuilt list counts again")
    func unconfirmedListAfterFailedPush() async throws {
        let rig = makeCatchAllRig { $0.foreign = [13] }
        let coordinator = rig.coordinator
        let system = rig.system
        let events = rig.events
        coordinator.start()
        rig.clock.runDue()
        let old = try #require(rig.tv)
        #expect(old.appliedExclusions == [5, 13])
        let owners = [FakeClaimOwner(), FakeClaimOwner(pid: 2)]
        // Both sets of [5, 11, 13] take effect, but neither reads back. The process list then
        // cannot be read for a while, so the rebuild that follows is postponed.
        rig.backend.failReadBacks = 2
        coordinator.onEvent = { event in
            events.events.append(event)
            if case .pushFailed = event { system.processListReadable = false }
        }
        let grow = try #require(coordinator.setClaim(owners[0], Claim(processes: [11], coverage: .allDevices)))
        let done = CoordinatorTestBox(0)
        Task { await coordinator.waitApplied(grow, .grow); done.value += 1 }
        #expect(await eventually { coordinator.pendingWaitCount == 1 })
        rig.clock.runDue()
        #expect(old.appliedExclusions == [5, 13])
        #expect(rig.backend.processes(on: 100) == [5, 11, 13])
        #expect(rig.tv === old)

        // The per-app tap goes, so the desired list is the recorded one again, while the tap
        // still excludes 11: neither wait may end on that
        system.processListReadable = true
        let shrink = try #require(coordinator.removeClaim(ObjectIdentifier(owners[0])))
        Task { await coordinator.waitApplied(shrink, .shrink); done.value += 1 }
        #expect(await eventually { coordinator.pendingWaitCount == 2 })
        rig.clock.runDue()
        await settle()
        #expect(done.value == 0)
        #expect(rig.backend.processes(on: 100) == [5, 11, 13])

        // The rebuild runs 100 ms later and takes over 200 ms after that; both waits end then
        rig.clock.advance(0.1)
        let new = try #require(rig.tv)
        #expect(new !== old)
        #expect(new.appliedExclusions == [5, 13])
        rig.clock.advance(0.19)
        await settle()
        #expect(done.value == 0)
        rig.clock.advance(0.01)
        #expect(await eventually { done.value == 2 })
        #expect(held(old))
        #expect(!held(new))

        // The rebuilt catch-all's list is confirmed: a claim change that leaves it as it is (another
        // user's process is excluded anyway) ends its wait at once
        let unchanged = try #require(coordinator.setClaim(owners[1], Claim(processes: [13], coverage: .allDevices)))
        rig.clock.runDue()
        Task { await coordinator.waitApplied(unchanged, .grow); done.value += 1 }
        #expect(await eventually { done.value == 3 })
        withExtendedLifetime(owners) {}
    }

    @Test("A push that fails once and whose retry finds nothing left to push rebuilds, since the tap may hold the list it was sent")
    func retryWithNothingToPushRebuilds() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let system = rig.system
        let events = rig.events
        coordinator.start()
        rig.clock.runDue()
        let old = try #require(rig.tv)
        let owner = FakeClaimOwner()
        // The set of [5, 11] takes effect but does not read back, and 11 quits before the retry
        // reads the process list again: the desired list is the recorded [5] again
        rig.backend.failReadBacks = 1
        coordinator.onEvent = { event in
            events.events.append(event)
            if case .pushFailed = event { system.processes = [5, 12, 13] }
        }
        let ticket = try #require(coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices)))
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .grow); done.value = true }
        #expect(await eventually { coordinator.pendingWaitCount == 1 })
        rig.clock.runDue()

        // The old tap still excludes 11, which a recycled object ID would inherit; the new one
        // is built without it
        #expect(rig.pushes == ["set [5, 11]"])
        #expect(rig.backend.processes(on: 100) == [5, 11])
        let new = try #require(rig.tv)
        #expect(new !== old)
        #expect(new.appliedExclusions == [5])
        await settle()
        #expect(!done.value)
        rig.clock.advance(0.2)
        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        #expect(await eventually { done.value })
        withExtendedLifetime(owner) {}
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

    @Test("Shrink watchdog: with the process list unreadable, a wait whose list is in force ends at its last chance, 2 s after its time")
    func shrinkWatchdog() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        let owner = FakeClaimOwner()
        _ = coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices))
        rig.clock.advance(1)
        let tv = try #require(rig.tv)
        #expect(tv.appliedExclusions == [5, 11])
        // 11 quits: the flush pushes the list without it, and the claim stays
        rig.system.processes = [5, 12, 13]
        rig.runControl.onProcessListChanged?()
        rig.clock.advance(1)
        #expect(tv.appliedExclusions == [5])
        // The claim goes while the process list cannot be read, so its change is never pushed
        rig.system.processListReadable = false
        let ticket = try #require(coordinator.removeClaim(ObjectIdentifier(owner)))
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .shrink); done.value = true }
        #expect(await eventually { coordinator.pendingWaitCount == 1 })

        // Not judged at 2 s but at 2 s + 2 s, where the applied list excludes no process
        // without a claim
        rig.clock.advance(3.99)
        await settle()
        #expect(!done.value)
        #expect(!rig.events.events.contains { if case .watchdog = $0 { true } else { false } })
        rig.clock.advance(0.01)
        #expect(await eventually { done.value })
        #expect(rig.events.events.contains(.watchdog(uid: "uid-tv", .shrink)))
        #expect(rig.backend.log.filter { $0 == "createTap" }.count == 1)
        withExtendedLifetime(owner) {}
    }

    /// `judged`: the watchdog's time (2 s) or its last chance with an unreadable list (2 s more).
    @Test("Shrink watchdog: an inclusion pushed when the wait is judged ends it only S after the push, as the shrink wait itself does",
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

        // Past G it still waits: an inclusion judged too early would leave 11 in neither tap
        rig.clock.advance(0.39)
        await settle()
        #expect(!done.value)
        rig.clock.advance(0.01)
        #expect(await eventually { done.value })
        #expect(rig.backend.log.filter { $0 == "createTap" }.count == 1)
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

    @Test("Initial-list watchdog: quiet while the rebuild of a new catch-all still held is postponed; the rebuild's own bound ends it with R")
    func initialListWatchdogQuietWhileRebuildDeferred() throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let system = rig.system
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
        let tv = try #require(rig.tv)
        #expect(held(tv))
        // The list becomes unreadable with the first push, so the rebuild that follows the
        // failed retry is postponed
        backend.onRecord = { entry in
            guard entry.hasPrefix("set") else { return }
            MainActor.assumeIsolated { system.processListReadable = false }
        }

        rig.clock.runDue()
        #expect(rig.pushes.count == 2)
        #expect(rig.tv === tv)
        #expect(held(tv))

        // The initial-list watchdog would only ask for the rebuild that is already postponed
        rig.clock.advance(1)
        #expect(!rig.events.events.contains { if case .watchdog = $0 { true } else { false } })
        rig.clock.advance(0.99)
        #expect(!rig.events.events.contains { if case .retiring = $0 { true } else { false } })
        rig.clock.advance(0.01)
        #expect(rig.events.events.contains(.watchdog(uid: "uid-tv", .rebuild)))
        #expect(rig.events.events.contains(.retiring(uid: "uid-tv", .pushFailed)))
        #expect(!rig.events.events.contains(.watchdog(uid: "uid-tv", .initialList)))
        #expect(!rig.events.events.contains { if case .failure = $0 { true } else { false } })
        #expect(rig.backend.log.filter { $0 == "createTap" }.count == 1)
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

    // MARK: Dormant devices (E12)

    /// `unresolvable`: the TV stays listed and alive, but Core Audio no longer resolves its UID.
    @Test("Listed but not alive, or listed with a UID Core Audio cannot resolve: the catch-all goes dormant, held before its detach, with no destroy, callback or count, and it still covers; the 2 s check rebuilds it once usable",
          arguments: [false, true])
    func dormantEntry(unresolvable: Bool) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let tv = try #require(rig.tv)
        let log = trace(rig, e12: true)
        let calledBack = CoordinatorTestBox(false)
        coordinator.onCoverageWillEnd = { _ in
            calledBack.value = true
            return false
        }

        if unresolvable {
            rig.backend.deviceIDs = [:]
        } else {
            rig.system.alive.remove(42)
        }
        coordinator.deviceListRefreshed()
        // Nothing happens inside the device monitor's handler
        #expect(coordinator.phase("uid-tv") == .live)
        rig.clock.runDue()

        #expect(coordinator.phase("uid-tv") == .dormant)
        #expect(await eventually { log.all.contains("detach uid-tv 200") })
        #expect(log.all == ["hold 200 pending=0", "phase uid-tv dormant", "observe 42", "detach uid-tv 200"])
        #expect(held(tv))
        #expect(rig.tv === tv)
        #expect(coordinator.isLive("uid-tv"))
        #expect(coordinator.covers("uid-tv"))
        #expect(coordinator.catchAllDeviceUIDs == ["uid-tv"])
        rig.clock.advance(10)
        await settle()
        #expect(!log.all.contains { $0.hasPrefix("destroy") })
        #expect(!calledBack.value)
        #expect(failures(rig).isEmpty)
        #expect(coordinator.phase("uid-tv") == .dormant)

        // Usable again without an IsAlive call: the 2 s check rebuilds it
        if unresolvable {
            rig.backend.deviceIDs = ["uid-tv": 42]
        } else {
            rig.system.alive.insert(42)
        }
        rig.clock.advance(1.99)
        #expect(builds(rig) == 1)
        rig.clock.advance(0.01)
        #expect(builds(rig) == 2)
        #expect(coordinator.phase("uid-tv") == .live)
    }

    @Test("A dormant catch-all whose UID is no longer listed ends with G: unobserved, nothing counted, destroyed without a second detach")
    func dormantUnlisted() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        makeDormant(rig)
        #expect(await eventually { rig.runControl.log.contains("detach uid-tv 200") })
        let log = trace(rig, e12: true)

        rig.system.outputs.removeAll { $0.uid == "uid-tv" }
        coordinator.deviceListRefreshed()
        rig.clock.runDue()

        #expect(coordinator.phase("uid-tv") == nil)
        #expect(await eventually { log.all.contains { $0.hasPrefix("destroy") } })
        #expect(log.all == ["unobserve 42", "ended uid-tv absent", "destroy tap=100 aggregate=200 proc=true"])
        #expect(rig.runControl.log.filter { $0.hasPrefix("detach") } == ["detach uid-tv 200"])
        #expect(failures(rig).isEmpty)
        #expect(rig.aliveObservers.observed.isEmpty)
    }

    @Test("Alive again (IsAlive listener): rebuilt through E on the listed ID; the dormant catch-all is not detached again and goes after the takeover")
    func aliveAgainRebuilds() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let old = try #require(rig.tv)
        makeDormant(rig)
        #expect(await eventually { rig.runControl.log.contains("detach uid-tv 200") })
        let log = trace(rig, e12: true)

        rig.system.alive.insert(42)
        rig.aliveObservers.fire(42)
        // The rebuild runs in the coordinator's next turn
        #expect(builds(rig) == 1)
        rig.clock.runDue()
        let new = try #require(rig.tv)
        #expect(new !== old)
        #expect(held(new))
        #expect(coordinator.phase("uid-tv") == .live)
        rig.clock.advance(0.2)

        #expect(await eventually { log.all.contains { $0.hasPrefix("destroy") } })
        #expect(log.all == [
            "unobserve 42",
            "phase uid-tv live",
            "attach uid-tv [5] held=true",
            "hold 200 pending=0",
            "open 201 pending=0",
            "rebuilt uid-tv",
            "destroy tap=100 aggregate=200 proc=true",
        ])
        #expect(!held(new))
        #expect(rig.runControl.log.filter { $0.hasPrefix("detach") } == ["detach uid-tv 200"])
        #expect(failures(rig).isEmpty)
        #expect(rig.aliveObservers.observed.isEmpty)
    }

    @Test("A rebuild from dormant keeps the device dormant while it builds and makes it live at the attach: from then on claims get tickets, pushes go only to the new catch-all, and waits end at the takeover")
    func dormantRebuildTurnsLiveAtAttach() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let backend = rig.backend
        let clock = rig.clock
        coordinator.start()
        rig.clock.runDue()
        makeDormant(rig)
        let owners = [FakeClaimOwner(), FakeClaimOwner(pid: 2)]
        let seen = LineLog()
        backend.onWaitUntilReady = {
            MainActor.assumeIsolated {
                // A per-app tap created during the build's wait, and the flush a spin runs
                let ticket = coordinator.setClaim(owners[0], Claim(processes: [11], coverage: .allDevices))
                clock.runDue()
                seen.add("dormant=\(coordinator.phase("uid-tv") == .dormant) ticket=\(ticket != nil) sets=\(backend.sets(on: 100))")
            }
        }

        rig.system.alive.insert(42)
        rig.aliveObservers.fire(42)
        rig.clock.runDue()
        backend.onWaitUntilReady = nil

        #expect(seen.all == ["dormant=true ticket=false sets=0"])
        let new = try #require(rig.tv)
        #expect(coordinator.phase("uid-tv") == .live)
        #expect(new.appliedExclusions == [5, 11])
        #expect(backend.processes(on: 100) == [5])
        let ticket = try #require(coordinator.setClaim(owners[1], Claim(processes: [12], coverage: .allDevices)))
        #expect(ticket.generations == ["uid-tv": 1])
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .grow); done.value = true }
        #expect(await eventually { coordinator.pendingWaitCount == 1 })
        rig.clock.runDue()
        #expect(new.appliedExclusions == [5, 11, 12])
        #expect(backend.sets(on: 100) == 0)

        rig.clock.advance(0.19)
        await settle()
        #expect(!done.value)
        rig.clock.advance(0.01)
        #expect(await eventually { done.value })
        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        #expect(!held(new))
        withExtendedLifetime(owners) {}
    }

    @Test("A rebuild from dormant that fails while the device reads alive keeps the catch-all dormant until the failure settled; still alive under its ID then, the failure counts, R runs from dormant with no second detach, and the next build backs off 5 s from the failure")
    func dormantRebuildFails() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        makeDormant(rig)
        #expect(await eventually { rig.runControl.log.contains("detach uid-tv 200") })
        let log = trace(rig, e12: true)
        coordinator.onCoverageWillEnd = { uid in
            log.add("onCoverageWillEnd \(uid) retirementHold=\(coordinator.takesRetirementHold(targets: [uid]))")
            return false
        }
        rig.backend.failAt = .createTap

        rig.system.alive.insert(42)
        rig.aliveObservers.fire(42)
        rig.clock.runDue()
        rig.backend.failAt = nil
        #expect(coordinator.phase("uid-tv") == .dormant)
        #expect(log.all.isEmpty)
        rig.clock.advance(CatchAllCoordinator.failureSettle)

        #expect(await eventually { log.all.contains { $0.hasPrefix("destroy") } })
        #expect(log.all == [
            "failure buildFailed uid-tv",
            "backoff uid-tv 5",
            "unobserve 42",
            "retiring uid-tv rebuildFailed",
            "phase uid-tv retiring(caHeld: false)",
            "onCoverageWillEnd uid-tv retirementHold=true",
            "hold 200 pending=0",
            "phase uid-tv retiring(caHeld: true)",
            "ended uid-tv rebuildFailed",
            "destroy tap=100 aggregate=200 proc=true",
        ])
        #expect(rig.runControl.log.filter { $0.hasPrefix("detach") } == ["detach uid-tv 200"])
        #expect(coordinator.phase("uid-tv") == nil)
        coordinator.reconcile()
        rig.clock.advance(3.99)
        #expect(builds(rig) == 2)
        rig.clock.advance(0.01)
        #expect(builds(rig) == 3)
        #expect(coordinator.phase("uid-tv") == .live)
    }

    @Test("A new listed ID that is already alive rebuilds at once at a device-list refresh, without dormancy or count, on the new ID")
    func newAliveIDRebuilds() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let old = try #require(rig.tv)
        let log = trace(rig, e12: true)

        relist(rig, as: 52, alive: true)
        rig.system.alive.remove(42)
        rig.system.gains[52] = 0.5
        coordinator.deviceListRefreshed()
        #expect(builds(rig) == 1)
        rig.clock.runDue()

        let new = try #require(rig.tv)
        #expect(new !== old)
        #expect(new.deviceID == 52)
        #expect(new.renderState.targetGain == 0.5)
        rig.clock.advance(0.2)
        #expect(await eventually { log.all.contains { $0.hasPrefix("destroy") } })
        #expect(log.all == [
            "attach uid-tv [5] held=true",
            "hold 200 pending=0",
            "open 201 pending=0",
            "rebuilt uid-tv",
            "detach uid-tv 200",
            "destroy tap=100 aggregate=200 proc=true",
        ])
        #expect(failures(rig).isEmpty)
        #expect(rig.aliveObservers.log.isEmpty)
    }

    @Test("A device that comes back between the check and the registration is caught by the IsAlive read right after registering, and rebuilt; the dormant catch-all goes only after its detach ran")
    func aliveAtRegistration() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let system = rig.system
        coordinator.start()
        rig.clock.runDue()
        let log = trace(rig, e12: true)
        rig.aliveObservers.onObserve = { device in
            MainActor.assumeIsolated { _ = system.alive.insert(device) }
        }

        makeDormant(rig)
        // No listener call: the read after registering found it alive; the rebuild ran in the
        // turn after, and takes over before the dormant one's detach has run
        #expect(coordinator.phase("uid-tv") == .live)
        rig.clock.advance(0.2)

        #expect(await eventually { log.all.contains { $0.hasPrefix("destroy") } })
        #expect(log.all == [
            "hold 200 pending=0",
            "phase uid-tv dormant",
            "observe 42",
            "unobserve 42",
            "phase uid-tv live",
            "attach uid-tv [5] held=true",
            "hold 200 pending=0",
            "open 201 pending=0",
            "rebuilt uid-tv",
            "detach uid-tv 200",
            "destroy tap=100 aggregate=200 proc=true",
        ])
        #expect(failures(rig).isEmpty)
    }

    @Test("A dormant catch-all whose detach timed out counts nothing, since the dead device may block the queue itself; alive again before the queue ran that detach, the device retires (R) instead of rebuilding behind it, and the catch-all is destroyed only once the queued detach ran")
    func dormantDetachTimeout() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let log = trace(rig, e12: true)
        coordinator.onCoverageWillEnd = { uid in
            log.add("onCoverageWillEnd \(uid)")
            return false
        }
        rig.runControl.blocked = true

        makeDormant(rig)
        #expect(await eventually { rig.runControl.queuedWorkRequests == 1 })
        rig.system.alive.insert(42)
        rig.aliveObservers.fire(42)
        rig.clock.runDue()
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        #expect(builds(rig) == 1)
        await settle()
        #expect(!log.all.contains { $0.hasPrefix("destroy") })

        rig.runControl.unblock()
        #expect(await eventually { log.all.contains { $0.hasPrefix("destroy") } })
        #expect(log.all == [
            "hold 200 pending=0",
            "phase uid-tv dormant",
            "observe 42",
            "detach uid-tv 200 timed out",
            "unobserve 42",
            "retiring uid-tv runQueueTimeout",
            "phase uid-tv retiring(caHeld: false)",
            "onCoverageWillEnd uid-tv",
            "hold 200 pending=0",
            "phase uid-tv retiring(caHeld: true)",
            "ended uid-tv runQueueTimeout",
            "backoff uid-tv 5",
            "queue ran detach uid-tv 200",
            "destroy tap=100 aggregate=200 proc=true",
        ])
        #expect(failures(rig).isEmpty)
        // The queue's reconcile finds the backoff running; the backoff's own one builds
        rig.clock.runDue()
        #expect(builds(rig) == 1)
        rig.clock.advance(5)
        #expect(builds(rig) == 2)
        #expect(coordinator.phase("uid-tv") == .live)
    }

    @Test("A rebuild from dormant postponed by an unreadable process list, whose device is not alive at the retry, stays dormant: a shrink wait held for it keeps waiting, the device rebuilds once alive again, and the wait ends at the takeover")
    func dormantDeferralEndsWhenNotAlive() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let owner = FakeClaimOwner()
        _ = coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices))
        rig.clock.advance(1)
        makeDormant(rig)
        rig.system.processListReadable = false

        rig.system.alive.insert(42)
        rig.aliveObservers.fire(42)
        rig.clock.runDue()
        #expect(builds(rig) == 1)
        // The rebuild is postponed while the device is alive: a claim that ends waits for it
        let ticket = try #require(coordinator.removeClaim(ObjectIdentifier(owner)))
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .shrink); done.value = true }
        #expect(await eventually { coordinator.pendingWaitCount == 1 })
        // The link drops again before the retry 100 ms later: the dormant tap still excludes 11
        rig.system.alive.remove(42)
        rig.clock.advance(0.1)
        #expect(coordinator.phase("uid-tv") == .dormant)
        rig.clock.advance(10)
        await settle()
        #expect(!done.value)

        rig.system.processListReadable = true
        rig.system.alive.insert(42)
        rig.aliveObservers.fire(42)
        rig.clock.runDue()
        #expect(builds(rig) == 2)
        #expect(coordinator.phase("uid-tv") == .live)
        await settle()
        #expect(!done.value)
        rig.clock.advance(0.2)
        #expect(await eventually { done.value })
        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        #expect(failures(rig).isEmpty)
        withExtendedLifetime(owner) {}
    }

    @Test("A rebuild that starts on a live catch-all whose device is no longer alive puts it dormant without a build: nothing counted, no R")
    func liveRebuildOnDeadDevice() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let log = trace(rig, e12: true)

        coordinator.rebuild("uid-tv", reason: .formatChanged)
        rig.system.alive.remove(42)
        rig.clock.runDue()

        #expect(coordinator.phase("uid-tv") == .dormant)
        #expect(builds(rig) == 1)
        #expect(await eventually { log.all.contains("detach uid-tv 200") })
        #expect(log.all == ["hold 200 pending=0", "phase uid-tv dormant", "observe 42", "detach uid-tv 200"])
        #expect(failures(rig).isEmpty)
    }

    /// `fromDormant`: the rebuild starts from a dormant catch-all that is alive again;
    /// otherwise from a live one.
    @Test("A rebuild whose build fails because the device died during it keeps the catch-all dormant: no R, nothing counted, no backoff; alive again, it is rebuilt. A shrink wait held for the rebuild ends S after a push that reached the catch-all before it went dormant, otherwise at the takeover",
          arguments: [false, true])
    func rebuildFailsOnDeadDevice(fromDormant: Bool) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let system = rig.system
        let backend = rig.backend
        coordinator.start()
        rig.clock.runDue()
        let owner = FakeClaimOwner()
        _ = coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices))
        rig.clock.advance(1)
        if fromDormant {
            makeDormant(rig)
            #expect(await eventually { rig.runControl.log.contains("detach uid-tv 200") })
            system.alive.insert(42)
        }
        let log = trace(rig, e12: true)
        let calledBack = CoordinatorTestBox(false)
        coordinator.onCoverageWillEnd = { _ in
            calledBack.value = true
            return false
        }
        let clock = rig.clock
        backend.onWaitUntilReady = {
            MainActor.assumeIsolated {
                _ = system.alive.remove(42)
                // The spin runs the flush the claim change scheduled; its check finds the rebuild
                // still running, so only the end of the rebuild can end the wait
                clock.runDue()
            }
        }
        backend.failAt = .ready

        if fromDormant {
            rig.aliveObservers.fire(42)
        } else {
            coordinator.rebuild("uid-tv", reason: .formatChanged)
        }
        // A claim that ends while the rebuild is requested waits for it
        let ticket = try #require(coordinator.removeClaim(ObjectIdentifier(owner)))
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .shrink); done.value = true }
        #expect(await eventually { coordinator.pendingWaitCount == 1 })
        rig.clock.runDue()
        backend.onWaitUntilReady = nil
        backend.failAt = nil

        #expect(builds(rig) == 2)
        #expect(coordinator.phase("uid-tv") == .dormant)
        #expect(coordinator.covers("uid-tv"))
        await settle()
        #expect(!done.value)
        rig.clock.advance(60)
        if fromDormant {
            // Nothing was pushed to the dormant catch-all: its tap still excludes 11
            await settle()
            #expect(!done.value)
        } else {
            // The spin's flush pushed the list without 11 while the catch-all was still live
            #expect(await eventually { done.value })
        }
        #expect(builds(rig) == 2)
        #expect(!calledBack.value)
        #expect(failures(rig).isEmpty)
        #expect(!log.all.contains { $0.hasPrefix("retiring") || $0.hasPrefix("backoff") })
        #expect(await eventually { rig.runControl.log.contains("detach uid-tv 200") })
        #expect(rig.runControl.log.filter { $0.hasPrefix("detach") } == ["detach uid-tv 200"])

        system.alive.insert(42)
        rig.aliveObservers.fire(42)
        rig.clock.runDue()
        #expect(builds(rig) == 3)
        #expect(coordinator.phase("uid-tv") == .live)
        rig.clock.advance(0.2)
        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        #expect(await eventually { done.value })
        withExtendedLifetime(owner) {}
    }

    /// `buildFails`: the device dies during the first build's wait; otherwise it is not alive
    /// at start, so nothing is built.
    @Test("Without a catch-all a device never goes dormant: a build that fails while it is not alive, or none built because it was not alive, counts nothing, leaves covers false, and builds once IsAlive reports it alive",
          arguments: [false, true])
    func notAliveWithoutCatchAll(buildFails: Bool) async throws {
        let rig = makeCatchAllRig { if !buildFails { $0.alive.remove(42) } }
        let coordinator = rig.coordinator
        let system = rig.system
        let log = trace(rig, e12: true)
        if buildFails {
            rig.backend.onWaitUntilReady = { MainActor.assumeIsolated { _ = system.alive.remove(42) } }
            rig.backend.failAt = .ready
        }

        coordinator.start()
        rig.backend.onWaitUntilReady = nil
        rig.backend.failAt = nil
        rig.clock.runDue()

        #expect(coordinator.phase("uid-tv") == nil)
        #expect(!coordinator.covers("uid-tv"))
        #expect(rig.aliveObservers.observed == [42])
        rig.clock.advance(60)
        #expect(builds(rig) == (buildFails ? 1 : 0))

        system.alive.insert(42)
        rig.aliveObservers.fire(42)
        #expect(coordinator.phase("uid-tv") == nil)
        rig.clock.runDue()

        #expect(coordinator.phase("uid-tv") == .live)
        #expect(coordinator.covers("uid-tv"))
        #expect(rig.aliveObservers.observed.isEmpty)
        #expect(failures(rig).isEmpty)
        #expect(!log.all.contains { $0.hasPrefix("backoff") })
        #expect(!log.all.contains("phase uid-tv dormant"))
    }

    @Test("The 2 s check runs only while a catch-all is dormant: it moves the observation to a new listed ID and stops once the device is live again")
    func dormantCheck() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        // Live: no check is scheduled, and a listed ID that changes to a dead one goes
        // unnoticed until a reconcile
        #expect(rig.clock.pendingCount == 0)
        relist(rig, as: 52, alive: false)
        rig.clock.advance(10)
        #expect(coordinator.phase("uid-tv") == .live)
        relist(rig, as: 42, alive: true)

        makeDormant(rig)
        #expect(rig.aliveObservers.observed == [42])
        #expect(rig.clock.pendingCount == 1)
        let log = trace(rig, e12: true)
        relist(rig, as: 52, alive: false)
        rig.clock.advance(1.99)
        #expect(rig.aliveObservers.observed == [42])
        rig.clock.advance(0.01)
        #expect(rig.aliveObservers.observed == [52])
        // The old ID's listener is gone
        rig.system.alive.insert(42)
        rig.aliveObservers.fire(42)
        rig.clock.runDue()
        #expect(coordinator.phase("uid-tv") == .dormant)

        rig.system.alive.insert(52)
        rig.aliveObservers.fire(52)
        rig.clock.runDue()
        #expect(coordinator.phase("uid-tv") == .live)
        #expect(rig.tv?.deviceID == 52)
        rig.clock.advance(0.2)
        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        #expect(Array(log.all.prefix(2)) == ["unobserve 42", "observe 52"])

        // Live again: the check stopped, so a new dead ID goes unnoticed again
        #expect(rig.clock.pendingCount == 0)
        relist(rig, as: 62, alive: false)
        rig.clock.advance(10)
        #expect(coordinator.phase("uid-tv") == .live)
        #expect(rig.aliveObservers.observed.isEmpty)
    }

    @Test("While a device retires, the E12 entry points return early: R from dormant drops the observation and the 2 s check, and after R4 the next reconcile builds again")
    func e12IgnoredWhileRetiring() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let system = rig.system
        let observers = rig.aliveObservers
        let backend = rig.backend
        coordinator.start()
        rig.clock.runDue()
        makeDormant(rig)
        #expect(await eventually { rig.runControl.log.contains("detach uid-tv 200") })
        let log = trace(rig, e12: true)
        coordinator.onCoverageWillEnd = { uid in
            // Inside R2: alive again, an IO failure report and a device-list refresh
            system.alive.insert(42)
            observers.fire(42)
            coordinator.reportIOFailure(uid, aggregate: 200, .startFailed)
            coordinator.deviceListRefreshed()
            log.add("R2 observed=\(observers.observed) builds=\(backend.log.filter { $0 == "createTap" }.count)")
            return false
        }

        coordinator.retire("uid-tv", reason: .injected)
        rig.clock.runDue()

        // The refresh's reconcile ran after R2, with the device still retiring; the 2 s check
        // stopped at R1
        #expect(coordinator.phase("uid-tv") == .retiring(caHeld: true))
        #expect(rig.clock.pendingCount == 0)
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        #expect(await eventually { log.all.contains { $0.hasPrefix("destroy") } })
        #expect(log.all == [
            "unobserve 42",
            "retiring uid-tv injected",
            "phase uid-tv retiring(caHeld: false)",
            "R2 observed=[] builds=1",
            "hold 200 pending=0",
            "phase uid-tv retiring(caHeld: true)",
            "ended uid-tv injected",
            "destroy tap=100 aggregate=200 proc=true",
        ])
        // No backoff after an injected retirement
        #expect(rig.clock.pendingCount == 0)
        #expect(builds(rig) == 1)
        #expect(failures(rig).isEmpty)
        coordinator.reconcile()
        rig.clock.runDue()
        #expect(coordinator.phase("uid-tv") == .live)
    }

    @Test("Entering dormant ends the grow waits on the device at once; while it is dormant a claim that adds processes gives it no ticket, and a grow wait ends at once")
    func dormantEndsWaits() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let owners = [FakeClaimOwner(), FakeClaimOwner(pid: 2)]
        let ticket = try #require(coordinator.setClaim(owners[0], Claim(processes: [11], coverage: .allDevices)))
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .grow); done.value = true }
        #expect(await eventually { coordinator.pendingWaitCount == 1 })

        // The flush pushes first, but G has not passed: only the dormancy ends the wait
        makeDormant(rig)

        #expect(coordinator.phase("uid-tv") == .dormant)
        #expect(await eventually { done.value })
        #expect(coordinator.setClaim(owners[1], Claim(processes: [12], coverage: .allDevices)) == nil)
        let late = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .grow); late.value = true }
        #expect(await eventually { late.value })
        withExtendedLifetime(owners) {}
    }

    @Test("Once a rebuild from dormant is requested the device is alive: claims that end get a ticket, before and during the build, and their waits end at the takeover, after the new catch-all's list without them has applied")
    func dormantRebuildShrinkWaits() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let backend = rig.backend
        coordinator.start()
        rig.clock.runDue()
        let owners = [FakeClaimOwner(), FakeClaimOwner(pid: 2)]
        _ = coordinator.setClaim(owners[0], Claim(processes: [11], coverage: .allDevices))
        _ = coordinator.setClaim(owners[1], Claim(processes: [12], coverage: .allDevices))
        rig.clock.advance(1)
        makeDormant(rig)

        rig.system.alive.insert(42)
        rig.aliveObservers.fire(42)
        // Requested: the dormant tap and the one about to be built still exclude 12
        let first = try #require(coordinator.removeClaim(ObjectIdentifier(owners[1])))
        let firstDone = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(first, .shrink); firstDone.value = true }
        #expect(await eventually { coordinator.pendingWaitCount == 1 })
        let second = CoordinatorTestBox<ApplyTicket?>(nil)
        backend.onWaitUntilReady = {
            // A handover B during the build's wait: the new tap was created excluding 11
            MainActor.assumeIsolated { second.value = coordinator.removeClaim(ObjectIdentifier(owners[0])) }
        }
        rig.clock.runDue()
        backend.onWaitUntilReady = nil

        let secondTicket = try #require(second.value)
        let secondDone = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(secondTicket, .shrink); secondDone.value = true }
        #expect(await eventually { coordinator.pendingWaitCount == 2 })
        let new = try #require(rig.tv)
        #expect(coordinator.phase("uid-tv") == .live)
        // Built with [5, 11]; the flush after the attach pushed the list without 11
        #expect(backend.sets(on: 101) == 1)
        #expect(new.appliedExclusions == [5])
        #expect(held(new))
        rig.clock.advance(0.39)
        await settle()
        #expect(!firstDone.value && !secondDone.value)
        rig.clock.advance(0.01)
        #expect(await eventually { firstDone.value && secondDone.value })
        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        #expect(!held(new))
        withExtendedLifetime(owners) {}
    }

    @Test("A device without a catch-all that is not alive is observed without judging its own facts, which may read differently while it is dead; one opted out is not observed")
    func notAliveObservedWithoutDeviceFacts() async throws {
        let rig = makeCatchAllRig { system in
            system.alive.remove(42)
            // A dead HDMI device may report no output stream
            system.streamCounts[42] = 0
            system.outputs.append(CatchAllOutput(uid: "uid-tv2", id: 44))
            system.tiers[44] = .software
            system.excluded = ["uid-tv2"]
        }
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        #expect(rig.aliveObservers.observed == [42])

        rig.system.streamCounts[42] = 1
        rig.system.alive.insert(42)
        rig.aliveObservers.fire(42)
        rig.clock.runDue()
        #expect(coordinator.phase("uid-tv") == .live)
        #expect(rig.aliveObservers.observed.isEmpty)
    }

    @Test("A catch-all built after G while G's detach still waited is retired once that detach times out, since it attached behind the same blocked queue; G counts nothing, R's own detach counts the episode once")
    func buildAfterGBehindBlockedQueue() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.onCoverageWillEnd = { _ in false }
        rig.runControl.blocked = true

        rig.system.outputs.removeAll { $0.uid == "uid-tv" }
        coordinator.deviceListRefreshed()
        rig.clock.runDue()
        #expect(coordinator.phase("uid-tv") == nil)
        // Listed again before G's detach has timed out: the gate cannot know yet
        rig.system.outputs.insert(CatchAllOutput(uid: "uid-tv", id: 42), at: 0)
        coordinator.deviceListRefreshed()
        rig.clock.runDue()
        #expect(coordinator.phase("uid-tv") == .live)
        #expect(builds(rig) == 2)

        #expect(await eventually { rig.runControl.log.contains("detach uid-tv 200 timed out") })
        rig.clock.runDue()
        #expect(rig.events.events.contains(.retiring(uid: "uid-tv", .runQueueTimeout)))
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        #expect(failures(rig) == [.failure(uid: "uid-tv", .runQueueTimeout)])
        rig.runControl.unblock()
        #expect(await eventually { rig.backend.log.filter { $0.hasPrefix("destroy") }.count == 2 })
    }

    // MARK: IO failures, counting, backoff and the breaker

    @Test("An IO failure report rebuilds the catch-all and counts once per aggregate however often it repeats, 1 s after the first report; startFailed and ioDead alike")
    func ioFailureCountsOncePerAggregate() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let first = try #require(rig.tv).ioHandle.aggregateID

        await reportIO(rig, "uid-tv", first, .ioDead)
        await reportIO(rig, "uid-tv", first, .ioDead)
        await reportIO(rig, "uid-tv", first, .startFailed)
        #expect(builds(rig) == 1)
        rig.clock.runDue()
        #expect(builds(rig) == 2)

        // Repeats while the new one waits to take over, and after it took over
        await reportIO(rig, "uid-tv", first)
        rig.clock.advance(0.2)
        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        await reportIO(rig, "uid-tv", first)
        rig.clock.runDue()
        #expect(builds(rig) == 2)
        #expect(failures(rig).isEmpty)
        rig.clock.advance(0.8)
        #expect(failures(rig) == [.failure(uid: "uid-tv", .ioFailed)])

        // A report about the catch-all in service counts again and rebuilds it
        let second = try #require(rig.tv).ioHandle.aggregateID
        await reportIO(rig, "uid-tv", second, .startFailed)
        rig.clock.runDue()
        #expect(builds(rig) == 3)
        rig.clock.advance(1)
        #expect(failures(rig).count == 2)
        #expect(!coordinator.breakerOpen)
        #expect(coordinator.givenUp.isEmpty)
    }

    @Test("An IO failure report for a device that is no longer alive puts its catch-all dormant, uncounted and without a rebuild")
    func ioFailureWhileNotAlive() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        rig.system.alive.remove(42)

        await reportIO(rig, "uid-tv", 200, .startFailed)

        #expect(coordinator.phase("uid-tv") == .dormant)
        rig.clock.advance(10)
        #expect(builds(rig) == 1)
        #expect(failures(rig).isEmpty)
        #expect(coordinator.covers("uid-tv"))
    }

    @Test("Three counted IO failures for one device ID within 10 min give the ID up for the session and retire its catch-all; each report rebuilt at once, and the breaker stays closed (the give-up counts once toward it)")
    func giveUp() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let log = trace(rig, e12: true)
        coordinator.onCoverageWillEnd = { _ in false }

        for _ in 0..<3 {
            let aggregate = try #require(rig.tv).ioHandle.aggregateID
            await reportIO(rig, "uid-tv", aggregate)
            rig.clock.runDue()
            rig.clock.advance(0.2)
        }
        #expect(failures(rig).isEmpty)
        #expect(builds(rig) == 4)
        rig.clock.advance(1)

        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        #expect(coordinator.givenUp == [42])
        #expect(log.all.filter { $0.hasPrefix("failure") } == Array(repeating: "failure ioFailed uid-tv", count: 3))
        let givenUp = try #require(log.all.firstIndex(of: "givenUp uid-tv 42"))
        let retiring = try #require(log.all.firstIndex(of: "retiring uid-tv givenUp"))
        #expect(givenUp < retiring)
        coordinator.reconcile()
        rig.clock.advance(600)
        #expect(builds(rig) == 4)
        #expect(!coordinator.breakerOpen)
    }

    @Test("Three failures toward the breaker within 10 min open it: affectsAudio is false at once, every live or dormant catch-all retires with its retirement holds, and nothing is built or rebuilt again")
    func breaker() async throws {
        let rig = makeCatchAllRig { system in
            // The other two are not alive yet: only the TV's first builds fail
            system.outputs += [CatchAllOutput(uid: "uid-tv2", id: 44), CatchAllOutput(uid: "uid-tv3", id: 45)]
            system.tiers[44] = .software
            system.tiers[45] = .software
        }
        let coordinator = rig.coordinator
        failFirstBuilds(rig, 2)
        #expect(failures(rig) == Array(repeating: .failure(uid: "uid-tv", .buildFailed), count: 2))
        rig.system.alive.formUnion([44, 45])
        rig.aliveObservers.fire(44)
        rig.aliveObservers.fire(45)
        rig.clock.runDue()
        #expect(coordinator.catchAll(for: "uid-tv2")?.ioHandle.aggregateID == 201)
        makeDormant(rig, 45)
        #expect(coordinator.phase("uid-tv3") == .dormant)
        let log = trace(rig, e12: true)
        let traced = coordinator.onEvent
        coordinator.onEvent = { event in
            traced?(event)
            guard event == .breakerOpened else { return }
            log.add("at open affectsAudio=\(coordinator.affectsAudio) covers=\(coordinator.covers("uid-tv2")) "
                    + "live=\(coordinator.phase("uid-tv2") == .live)")
        }
        coordinator.onCoverageWillEnd = { uid in
            log.add("onCoverageWillEnd \(uid) affectsAudio=\(coordinator.affectsAudio) retirementHold=\(coordinator.takesRetirementHold(targets: [uid]))")
            return false
        }

        // The TV's rebuild fails: its old catch-all serves until the failure settled, which counts
        // it, opens the breaker and retires the TV with the rebuild's reason
        rig.backend.failAt = .createTap
        coordinator.rebuild("uid-tv", reason: .formatChanged)
        let built = builds(rig)
        rig.clock.runDue()
        rig.backend.failAt = nil
        #expect(coordinator.affectsAudio)
        #expect(coordinator.phase("uid-tv") == .live)
        rig.clock.advance(CatchAllCoordinator.failureSettle)

        // At once, before any retirement it causes
        #expect(log.all.contains("at open affectsAudio=false covers=false live=true"))
        #expect(coordinator.breakerOpen)
        #expect(await eventually {
            coordinator.phase("uid-tv") == nil && coordinator.phase("uid-tv2") == nil && coordinator.phase("uid-tv3") == nil
        })
        #expect(builds(rig) == built + 1)
        #expect(log.all.filter { $0.hasPrefix("onCoverageWillEnd") } == [
            "onCoverageWillEnd uid-tv affectsAudio=false retirementHold=true",
            "onCoverageWillEnd uid-tv2 affectsAudio=false retirementHold=true",
            "onCoverageWillEnd uid-tv3 affectsAudio=false retirementHold=true",
        ])
        #expect(log.all.filter { $0.hasPrefix("retiring") } == [
            "retiring uid-tv rebuildFailed", "retiring uid-tv2 breaker", "retiring uid-tv3 breaker",
        ])
        #expect(log.all.filter { $0 == "breaker open" }.count == 1)
        #expect(coordinator.givenUp.isEmpty)

        // No build or rebuild for the rest of the session
        coordinator.reconcile()
        coordinator.rebuild("uid-tv", reason: .formatChanged)
        rig.system.alive.insert(45)
        rig.aliveObservers.fire(45)
        rig.clock.advance(1000)
        #expect(builds(rig) == built + 1)
        #expect(coordinator.catchAllDeviceUIDs.isEmpty)
    }

    @Test("R for a push failure, a failed rebuild or a blocked run queue backs the next build off 5 s, 30 s, then 120 s; the next one gives the device up")
    func backoffSteps() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.onCoverageWillEnd = { _ in false }
        let log = trace(rig, e12: true)

        let steps: [(CatchAllRetireReason, Double)] = [(.pushFailed, 5), (.rebuildFailed, 30), (.runQueueTimeout, 120)]
        for (index, (reason, delay)) in steps.enumerated() {
            coordinator.retire("uid-tv", reason: reason)
            rig.clock.runDue()
            #expect(await eventually { coordinator.phase("uid-tv") == nil })
            // A reconcile before the backoff ends builds nothing; the backoff's own one does
            coordinator.reconcile()
            rig.clock.advance(delay - 0.01)
            #expect(builds(rig) == index + 1)
            rig.clock.advance(0.01)
            #expect(builds(rig) == index + 2)
            #expect(coordinator.phase("uid-tv") == .live)
        }
        coordinator.retire("uid-tv", reason: .pushFailed)
        rig.clock.runDue()
        #expect(await eventually { coordinator.phase("uid-tv") == nil })

        #expect(coordinator.givenUp == [42])
        coordinator.reconcile()
        rig.clock.advance(1000)
        #expect(builds(rig) == 4)
        #expect(log.all.filter { $0.hasPrefix("backoff") || $0.hasPrefix("givenUp") } == [
            "backoff uid-tv 5", "backoff uid-tv 30", "backoff uid-tv 120", "givenUp uid-tv 42",
        ])
        #expect(!coordinator.breakerOpen)
        #expect(failures(rig).isEmpty)
        // A given-up ID that stops being alive is not observed: it would never be built anyway
        rig.system.alive.remove(42)
        coordinator.reconcile()
        rig.clock.runDue()
        #expect(rig.aliveObservers.observed.isEmpty)
    }

    @Test("The backoff starts over once a catch-all has stayed live 10 min; a shorter stretch keeps the step")
    func backoffReset() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.onCoverageWillEnd = { _ in false }
        func retire() async {
            coordinator.retire("uid-tv", reason: .pushFailed)
            rig.clock.runDue()
            _ = await eventually { coordinator.phase("uid-tv") == nil }
        }

        await retire()
        rig.clock.advance(5)
        #expect(builds(rig) == 2)
        // Live 599 s: the next step, 30 s
        rig.clock.advance(599)
        await retire()
        rig.clock.advance(29.99)
        #expect(builds(rig) == 2)
        rig.clock.advance(0.01)
        #expect(builds(rig) == 3)
        // Live 600 s: back to 5 s
        rig.clock.advance(600)
        await retire()
        rig.clock.advance(4.99)
        #expect(builds(rig) == 3)
        rig.clock.advance(0.01)
        #expect(builds(rig) == 4)
        #expect(rig.events.events.filter { if case .backoff = $0 { true } else { false } } == [
            .backoff(uid: "uid-tv", seconds: 5), .backoff(uid: "uid-tv", seconds: 30), .backoff(uid: "uid-tv", seconds: 5),
        ])
    }

    @Test("R for injected or tierChanged sets no backoff: the next reconcile builds at once")
    func noBackoffAfterInjectedOrTier() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.onCoverageWillEnd = { _ in false }

        coordinator.retire("uid-tv", reason: .injected)
        rig.clock.runDue()
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        coordinator.reconcile()
        rig.clock.runDue()
        #expect(builds(rig) == 2)

        rig.system.tiers[42] = .hardware
        coordinator.reconcile()
        rig.clock.runDue()
        #expect(rig.events.events.contains(.retiring(uid: "uid-tv", .tierChanged)))
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        rig.system.tiers[42] = .software
        coordinator.reconcile()
        rig.clock.runDue()
        #expect(builds(rig) == 3)
        #expect(coordinator.phase("uid-tv") == .live)
        #expect(!rig.events.events.contains { if case .backoff = $0 { true } else { false } })
    }

    @Test("A first build that fails on an alive device counts 1 s later and backs off 5 s, then 30 s, counted from the failure: a reconcile before the end builds nothing, the backoff's own reconcile does")
    func firstBuildBackoff() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        rig.backend.failAt = .createTap

        coordinator.start()
        #expect(builds(rig) == 1)
        #expect(failures(rig).isEmpty)
        coordinator.reconcile()
        rig.clock.advance(1)
        #expect(failures(rig) == [.failure(uid: "uid-tv", .buildFailed)])
        rig.clock.advance(3.99)
        #expect(builds(rig) == 1)
        rig.clock.advance(0.01)
        #expect(builds(rig) == 2)

        rig.backend.failAt = nil
        coordinator.reconcile()
        rig.clock.advance(29.99)
        #expect(builds(rig) == 2)
        rig.clock.advance(0.01)
        #expect(builds(rig) == 3)
        #expect(coordinator.phase("uid-tv") == .live)
        #expect(rig.events.events.filter { if case .backoff = $0 { true } else { false } } == [
            .backoff(uid: "uid-tv", seconds: 5), .backoff(uid: "uid-tv", seconds: 30),
        ])
        #expect(failures(rig).count == 2)
        #expect(!coordinator.breakerOpen)
    }

    /// `unblockFirst`: the run queue catches up before the backoff ends; otherwise after.
    @Test("After an R whose detach timed out, nothing is built on the device until the run queue has run that detach, before and after its backoff ends",
          arguments: [true, false])
    func noBuildBeforeQueuedDetach(unblockFirst: Bool) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.onCoverageWillEnd = { _ in false }
        rig.runControl.blocked = true

        coordinator.retire("uid-tv", reason: .runQueueTimeout)
        rig.clock.runDue()
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        #expect(failures(rig) == [.failure(uid: "uid-tv", .runQueueTimeout)])

        if unblockFirst {
            rig.clock.advance(2)
            rig.runControl.unblock()
            #expect(await eventually { rig.backend.log.contains { $0.hasPrefix("destroy") } })
            // The queue's reconcile finds the backoff still running
            rig.clock.runDue()
            #expect(builds(rig) == 1)
            rig.clock.advance(2.99)
            #expect(builds(rig) == 1)
            rig.clock.advance(0.01)
            #expect(builds(rig) == 2)
        } else {
            // The backoff's reconcile finds the detach still queued
            rig.clock.advance(60)
            #expect(builds(rig) == 1)
            rig.runControl.unblock()
            #expect(await eventually { rig.backend.log.contains { $0.hasPrefix("destroy") } })
            #expect(builds(rig) == 1)
            rig.clock.runDue()
            #expect(builds(rig) == 2)
        }
        #expect(coordinator.phase("uid-tv") == .live)
    }

    @Test("A rebuild failure on a device still alive under its ID 1 s later retires it then with the rebuild's reason; as the third failure it opens the breaker at the same moment, and nothing is built again")
    func rebuildFailureOpensBreaker() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.onCoverageWillEnd = { _ in false }
        failFirstBuilds(rig, 2)
        #expect(failures(rig).count == 2)
        #expect(coordinator.phase("uid-tv") == .live)

        rig.backend.failAt = .createTap
        coordinator.rebuild("uid-tv", reason: .formatChanged)
        rig.clock.runDue()
        rig.backend.failAt = nil
        #expect(!rig.events.events.contains { if case .retiring = $0 { true } else { false } })
        #expect(coordinator.phase("uid-tv") == .live)
        #expect(!coordinator.breakerOpen)

        rig.clock.advance(CatchAllCoordinator.failureSettle)
        #expect(rig.events.events.filter { if case .retiring = $0 { true } else { false } } == [.retiring(uid: "uid-tv", .rebuildFailed)])
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        #expect(coordinator.breakerOpen)
        #expect(coordinator.givenUp.isEmpty)
        coordinator.reconcile()
        rig.clock.advance(600)
        #expect(builds(rig) == 4)
    }

    /// `gap`: seconds between one counted IO failure and the next report.
    @Test("Give-up counts the IO failures of the last 10 min, the breaker's window: three 70 s apart give the ID up, three 301 s apart do not; IO failures do not count toward the breaker, which the give-up alone leaves closed",
          arguments: [69.0, 300.0])
    func giveUpWindow(gap: Double) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.onCoverageWillEnd = { _ in false }

        try await failIO(rig)
        rig.clock.advance(gap)
        try await failIO(rig)
        rig.clock.advance(gap)
        try await failIO(rig)

        // Each report rebuilt at once
        #expect(failures(rig).count == 3)
        #expect(builds(rig) == 4)
        #expect(!coordinator.breakerOpen)
        if gap < 100 {
            #expect(coordinator.givenUp == [42])
            #expect(await eventually { coordinator.phase("uid-tv") == nil })
        } else {
            #expect(coordinator.givenUp.isEmpty)
            #expect(coordinator.phase("uid-tv") == .live)
        }
    }

    /// `last`: seconds after the first failed build at which the third one fails.
    @Test("The breaker counts the failures of the last 10 min: three failed builds within 599 s open it, spread over 601 s they leave it closed",
          arguments: [599.0, 601.0])
    func breakerWindow(last: Double) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.onCoverageWillEnd = { _ in false }
        let start = rig.clock.now
        failFirstBuilds(rig, 1)

        // Failed rebuilds retire the catch-all once they settled; each backoff's build succeeds
        for at in [300, last] {
            rig.clock.advance(start + at - rig.clock.now)
            rig.backend.failAt = .createTap
            coordinator.rebuild("uid-tv", reason: .formatChanged)
            rig.clock.runDue()
            rig.backend.failAt = nil
            rig.clock.advance(CatchAllCoordinator.failureSettle)
            #expect(await eventually { coordinator.phase("uid-tv") == nil })
            rig.clock.advance(30)
        }

        #expect(failures(rig) == Array(repeating: .failure(uid: "uid-tv", .buildFailed), count: 3))
        #expect(coordinator.breakerOpen == (last < 600))
        #expect(coordinator.givenUp.isEmpty)
    }

    @Test("An aggregate ID is forgotten once its catch-all is destroyed: a later catch-all that reuses the ID counts its own IO failure")
    func reusedAggregateCountsAgain() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()

        try await failIO(rig)
        #expect(await eventually { rig.backend.log.contains("destroy tap=100 aggregate=200 proc=true") })
        await settle()
        // Core Audio hands the destroyed catch-all's ID to the next one
        rig.backend.nextAggregate = 200
        coordinator.rebuild("uid-tv", reason: .formatChanged)
        rig.clock.runDue()
        rig.clock.advance(0.2)
        #expect(try #require(rig.tv).ioHandle.aggregateID == 200)

        await reportIO(rig, "uid-tv", 200)
        rig.clock.advance(1)
        #expect(failures(rig) == [.failure(uid: "uid-tv", .ioFailed), .failure(uid: "uid-tv", .ioFailed)])
    }

    @Test("An IO failure report for a device listed under a new alive ID rebuilds on the new ID without counting")
    func ioFailureNewAliveID() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()

        relist(rig, as: 52, alive: true)
        await reportIO(rig, "uid-tv", 200)
        rig.clock.runDue()
        rig.clock.advance(0.2)

        #expect(try #require(rig.tv).deviceID == 52)
        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        #expect(failures(rig).isEmpty)
        #expect(coordinator.phase("uid-tv") == .live)
    }

    @Test("stop() drops every IsAlive observation and ends running backoffs: no listener and no timer is left")
    func stopEndsObservationsAndBackoffs() async throws {
        let rig = makeTwoDeviceRig()
        let coordinator = rig.coordinator
        rig.system.alive.remove(42)
        rig.backend.failAt = .createTap

        coordinator.start()
        rig.backend.failAt = nil
        // The TV is not alive and observed; the second TV's build failed, settles and backs off
        #expect(rig.aliveObservers.observed == [42])
        #expect(rig.clock.pendingCount == 1)
        rig.clock.advance(CatchAllCoordinator.failureSettle)
        #expect(rig.events.events.contains(.backoff(uid: "uid-tv2", seconds: 5)))
        #expect(rig.clock.pendingCount == 1)

        coordinator.stop()
        #expect(rig.aliveObservers.observed.isEmpty)
        #expect(rig.clock.pendingCount == 0)
    }

    // MARK: Recheck of 12b

    @Test("A dormant catch-all's detach that times out after the device was rebuilt from dormant retires the rebuilt catch-all, which attached behind the blocked queue; the dormant detach counts nothing, R's own counts the episode once, and nothing is destroyed before the queue ran the detaches")
    func dormantDetachTimesOutAfterRebuild() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.onCoverageWillEnd = { _ in false }
        rig.runControl.blocked = true

        makeDormant(rig)
        // Alive again before the dormant detach has returned: the gate on queued detaches
        // cannot know yet
        rig.system.alive.insert(42)
        rig.aliveObservers.fire(42)
        rig.clock.runDue()
        #expect(coordinator.phase("uid-tv") == .live)
        #expect(builds(rig) == 2)

        #expect(await eventually { rig.runControl.queuedWorkRequests == 1 })
        #expect(failures(rig).isEmpty)
        rig.clock.runDue()
        #expect(rig.events.events.contains(.retiring(uid: "uid-tv", .runQueueTimeout)))
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        #expect(failures(rig) == [.failure(uid: "uid-tv", .runQueueTimeout)])
        await settle()
        #expect(!rig.backend.log.contains { $0.hasPrefix("destroy") })

        rig.runControl.unblock()
        #expect(await eventually { rig.backend.log.filter { $0.hasPrefix("destroy") }.count == 2 })
    }

    /// `fromDormant`: the dormant catch-all's own detach times out during the wait of its
    /// rebuild; otherwise G's detach times out during the wait of the device's next first build.
    @Test("A build whose wait sees an earlier detach on the device time out never attaches: a first build is destroyed and the device built once the queue ran that detach; a rebuild from dormant is destroyed and the device retires. Neither timeout counts (G, dormant)",
          .serialized, arguments: [false, true])
    func queueTimeoutDuringBuild(fromDormant: Bool) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let system = rig.system
        let clock = rig.clock
        let runControl = rig.runControl
        let observers = rig.aliveObservers
        coordinator.start()
        rig.clock.runDue()
        coordinator.onCoverageWillEnd = { _ in false }
        runControl.blocked = true
        rig.backend.onWaitUntilReady = {
            // The earlier detach returns, timed out, while the wait spins
            MainActor.assumeIsolated { spin { runControl.queuedWorkRequests == 1 } }
        }

        await onRunLoop {
            if fromDormant {
                system.alive.remove(42)
                coordinator.deviceListRefreshed()
                clock.runDue()
                system.alive.insert(42)
                observers.fire(42)
                clock.runDue()
            } else {
                // G, then the TV is listed again before G's detach has returned
                let tv = system.outputs.removeFirst()
                coordinator.deviceListRefreshed()
                clock.runDue()
                system.outputs.insert(tv, at: 0)
                coordinator.deviceListRefreshed()
                clock.runDue()
            }
        }
        rig.backend.onWaitUntilReady = nil

        #expect(runControl.queuedWorkRequests == 1)
        #expect(builds(rig) == 2)
        #expect(runControl.log.filter { $0.hasPrefix("attach") }.count == 1)
        #expect(await eventually { rig.backend.log.contains { $0.hasPrefix("destroy tap=101 ") } })
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        #expect(rig.events.events.contains { if case .retiring = $0 { true } else { false } } == fromDormant)
        #expect(!fromDormant || rig.events.events.contains(.retiring(uid: "uid-tv", .runQueueTimeout)))
        #expect(failures(rig).isEmpty)

        runControl.unblock()
        #expect(await eventually { rig.backend.log.contains { $0.hasPrefix("destroy tap=100 ") } })
        // After R the backoff runs; after G the queue's reconcile builds at once
        rig.clock.advance(fromDormant ? 5 : 0)
        #expect(builds(rig) == 3)
        #expect(coordinator.phase("uid-tv") == .live)
    }

    /// `fromDormant`: the device dies again while it is rebuilt from dormant, and its IsAlive call
    /// comes during the build; otherwise it dies during its first build, which no listener reports.
    @Test("A device that dies during a build that succeeds goes dormant once the new catch-all is attached: held and detached, observed again, nothing counted; alive again, it is rebuilt",
          arguments: [false, true])
    func diesDuringBuild(fromDormant: Bool) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let system = rig.system
        let observers = rig.aliveObservers
        if fromDormant {
            coordinator.start()
            rig.clock.runDue()
            makeDormant(rig)
            #expect(await eventually { rig.runControl.log.contains("detach uid-tv 200") })
            system.alive.insert(42)
            observers.fire(42)
        }
        rig.backend.onWaitUntilReady = {
            MainActor.assumeIsolated {
                // The link drops again; an IsAlive call cannot rebuild a device whose build runs
                _ = system.alive.remove(42)
                observers.fire(42)
            }
        }
        if fromDormant {
            rig.clock.runDue()
        } else {
            coordinator.start()
            rig.clock.runDue()
        }
        rig.backend.onWaitUntilReady = nil

        let tv = try #require(rig.tv)
        #expect(builds(rig) == (fromDormant ? 2 : 1))
        #expect(coordinator.phase("uid-tv") == .dormant)
        #expect(held(tv))
        #expect(coordinator.covers("uid-tv"))
        #expect(observers.observed == [42])
        let aggregate = tv.ioHandle.aggregateID
        #expect(await eventually { rig.runControl.log.contains("detach uid-tv \(aggregate)") })
        #expect(failures(rig).isEmpty)

        system.alive.insert(42)
        observers.fire(42)
        rig.clock.runDue()
        #expect(builds(rig) == (fromDormant ? 3 : 2))
        #expect(coordinator.phase("uid-tv") == .live)
        #expect(observers.observed.isEmpty)
    }

    /// `path`: R finds the UID unresolvable at its turn, a rebuild does, or a rebuild's build
    /// fails because the UID stopped resolving during its wait.
    @Test("R or a rebuild that finds the listed UID unresolvable ends with G, then runs the gate and reconciles, since no device-list change may follow: once the UID resolves the device is built again",
          arguments: ["retirement", "rebuild", "rebuildFails"])
    func absentWhileListed(path: String) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let backend = rig.backend
        let events = rig.events
        coordinator.start()
        rig.clock.runDue()
        let gate = CoordinatorTestBox(0)
        let calledBack = CoordinatorTestBox(false)
        coordinator.onCoverageMayHaveChanged = { gate.value += 1 }
        coordinator.onCoverageWillEnd = { _ in
            calledBack.value = true
            return false
        }
        coordinator.onEvent = { event in
            events.events.append(event)
            // Core Audio resolves the UID again right after the G
            if case .ended = event {
                backend.onWaitUntilReady = nil
                backend.failAt = nil
                backend.deviceIDs = ["uid-tv": 42]
            }
        }

        switch path {
        case "retirement":
            coordinator.retire("uid-tv", reason: .pushFailed)
            backend.deviceIDs = [:]
        case "rebuild":
            coordinator.rebuild("uid-tv", reason: .formatChanged)
            backend.deviceIDs = [:]
        default:
            backend.onWaitUntilReady = { backend.deviceIDs = [:] }
            backend.failAt = .ready
            coordinator.rebuild("uid-tv", reason: .formatChanged)
        }
        rig.clock.runDue()

        #expect(events.events.contains(.ended(uid: "uid-tv", reason: "absent")))
        #expect(!calledBack.value)
        #expect(gate.value == 1)
        #expect(builds(rig) == (path == "rebuildFails" ? 3 : 2))
        #expect(coordinator.phase("uid-tv") == .live)
        #expect(failures(rig).isEmpty)
    }

    @Test("In observe a retirement for a push failure is G and backs the next build off as in mode on")
    func observeRetirementBacksOff() async {
        let rig = makeCatchAllRig(mode: .observe)
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()

        coordinator.retire("uid-tv", reason: .pushFailed)
        rig.clock.runDue()

        #expect(rig.events.events.contains(.ended(uid: "uid-tv", reason: "retired in observe (pushFailed)")))
        #expect(rig.events.events.contains(.backoff(uid: "uid-tv", seconds: 5)))
        coordinator.reconcile()
        rig.clock.advance(4.99)
        #expect(builds(rig) == 1)
        rig.clock.advance(0.01)
        #expect(builds(rig) == 2)
        #expect(coordinator.phase("uid-tv") == .live)
    }

    @Test("changedDevices names exactly the devices whose ticket a claim change carries: a building catch-all when processes leave its list, and a dormant one when processes of a tap on it leave, also before its rebuild is requested")
    func changedDevicesMatchTickets() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let owner = FakeClaimOwner()
        let other = FakeClaimOwner(pid: 2)
        let id = ObjectIdentifier(owner)
        let elsewhere = Claim(processes: [11], coverage: .device("uid-air"))
        _ = coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices))
        let duringBuild = LineLog()
        rig.backend.onWaitUntilReady = {
            MainActor.assumeIsolated {
                // The building catch-all is created excluding 11; the change would include it
                duringBuild.add("\(coordinator.changedDevices(owner: id, proposed: elsewhere).sorted())")
            }
        }
        coordinator.start()
        rig.backend.onWaitUntilReady = nil
        rig.clock.runDue()
        #expect(duringBuild.all == ["[\"uid-tv\"]"])

        makeDormant(rig)
        // Dormant, its rebuild not requested: processes joining name nothing, processes leaving
        // carry a ticket for it and name it
        #expect(coordinator.changedDevices(owner: ObjectIdentifier(other), proposed: Claim(processes: [12], coverage: .allDevices)).isEmpty)
        #expect(coordinator.setClaim(other, Claim(processes: [12], coverage: .allDevices)) == nil)
        let changed = coordinator.changedDevices(owner: id, proposed: elsewhere)
        let ticket = try #require(coordinator.setClaim(owner, elsewhere))
        #expect(changed == ["uid-tv"])
        #expect(Set(ticket.generations.keys) == changed)
        withExtendedLifetime([owner, other]) {}
    }

    // MARK: Mutation killers (12b safety rules)

    @Test("A device that dies while a rebuilt catch-all waits to take over goes dormant: the replaced catch-all is held before its detach and destroyed after it, the new one stays held and dormant, nothing counted")
    func dormantWhileRebuildWaits() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let old = try #require(rig.tv)
        coordinator.rebuild("uid-tv", reason: .formatChanged)
        rig.clock.runDue()
        let new = try #require(rig.tv)
        #expect(new !== old)
        // The replaced catch-all still plays while the new one waits to take over
        #expect(!held(old))
        #expect(held(new))
        let log = trace(rig, e12: true)

        makeDormant(rig)

        #expect(coordinator.phase("uid-tv") == .dormant)
        #expect(held(old))
        #expect(held(new))
        #expect(rig.tv === new)
        #expect(coordinator.covers("uid-tv"))
        #expect(await eventually {
            log.all.contains("destroy tap=100 aggregate=200 proc=true") && log.all.contains("detach uid-tv 201")
        })
        let hold = try #require(log.all.firstIndex(of: "hold 200 pending=0"))
        let detach = try #require(log.all.firstIndex(of: "detach uid-tv 200"))
        let destroy = try #require(log.all.firstIndex(of: "destroy tap=100 aggregate=200 proc=true"))
        #expect(hold < detach && detach < destroy)
        await settle()
        #expect(!log.all.contains { $0.hasPrefix("destroy tap=101") })
        #expect(failures(rig).isEmpty)
    }

    @Test("After a rebuild on a new listed ID the catch-all follows that ID: its gain changes apply, and the next refresh rebuilds nothing")
    func newIDRebuildFollowsListedID() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()

        relist(rig, as: 52, alive: true)
        rig.system.alive.remove(42)
        rig.system.gains[52] = 0.5
        coordinator.deviceListRefreshed()
        rig.clock.runDue()
        rig.clock.advance(0.2)
        let new = try #require(rig.tv)
        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        #expect(builds(rig) == 2)

        rig.system.gains[52] = 0.75
        coordinator.deviceGainChanged(52)
        #expect(new.renderState.targetGain == 0.75)
        coordinator.deviceListRefreshed()
        rig.clock.runDue()
        #expect(builds(rig) == 2)
        #expect(rig.tv === new)
    }

    @Test("G of the last dormant catch-all stops the 2 s check at once")
    func dormantCheckStopsAtG() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        makeDormant(rig)
        #expect(rig.clock.pendingCount == 1)

        rig.system.outputs.removeAll { $0.uid == "uid-tv" }
        coordinator.deviceListRefreshed()
        rig.clock.runDue()

        #expect(coordinator.phase("uid-tv") == nil)
        #expect(rig.clock.pendingCount == 0)
    }

    @Test("While a device retires, a new alive listed ID rebuilds nothing; after R4 the next reconcile builds on the new ID")
    func newIDWhileRetiring() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let backend = rig.backend
        coordinator.start()
        rig.clock.runDue()
        let log = LineLog()
        coordinator.onCoverageWillEnd = { _ in
            // Inside R2: the device is listed under a new alive ID, and the device monitor refreshes
            relist(rig, as: 52, alive: true)
            coordinator.deviceListRefreshed()
            log.add("R2 builds=\(backend.log.filter { $0 == "createTap" }.count)")
            return false
        }

        coordinator.retire("uid-tv", reason: .injected)
        rig.clock.runDue()

        #expect(log.all == ["R2 builds=1"])
        #expect(coordinator.phase("uid-tv") == .retiring(caHeld: true))
        #expect(builds(rig) == 1)
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        #expect(builds(rig) == 1)
        coordinator.reconcile()
        rig.clock.runDue()
        #expect(builds(rig) == 2)
        #expect(rig.tv?.deviceID == 52)
        #expect(coordinator.phase("uid-tv") == .live)
    }

    @Test("An IO failure report for a catch-all whose retirement is queued is dropped: nothing counted, no rebuild")
    func ioFailureWhileRetirementQueued() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.onCoverageWillEnd = { _ in false }

        coordinator.retire("uid-tv", reason: .injected)
        await reportIO(rig, "uid-tv", 200)
        rig.clock.runDue()

        #expect(failures(rig).isEmpty)
        #expect(builds(rig) == 1)
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        #expect(rig.events.events.filter { if case .retiring = $0 { true } else { false } } == [.retiring(uid: "uid-tv", .injected)])
    }

    @Test("A failure that settles during a rebuild's wait and opens the breaker stops the rebuilds still queued in the same turn: no other device is built")
    func breakerStopsQueuedRebuilds() async throws {
        let rig = makeCatchAllRig { system in
            // The other two are not alive yet: only the TV's first builds fail
            system.outputs += [CatchAllOutput(uid: "uid-tv2", id: 44), CatchAllOutput(uid: "uid-tv3", id: 45)]
            system.tiers[44] = .software
            system.tiers[45] = .software
        }
        let coordinator = rig.coordinator
        let clock = rig.clock
        coordinator.onCoverageWillEnd = { _ in false }
        failFirstBuilds(rig, 2)
        rig.system.alive.formUnion([44, 45])
        rig.aliveObservers.fire(44)
        rig.aliveObservers.fire(45)
        rig.clock.runDue()
        #expect(coordinator.phase("uid-tv2") == .live && coordinator.phase("uid-tv3") == .live)
        // The third failure toward the breaker: it settles 1 s later
        rig.backend.failAt = .createTap
        coordinator.rebuild("uid-tv", reason: .formatChanged)
        rig.clock.runDue()
        rig.backend.failAt = nil
        #expect(!coordinator.breakerOpen)

        rig.backend.onWaitUntilReady = {
            // It settles during the second TV's rebuild wait
            MainActor.assumeIsolated { clock.advance(1) }
        }
        coordinator.rebuild("uid-tv2", reason: .formatChanged)
        coordinator.rebuild("uid-tv3", reason: .formatChanged)
        let built = builds(rig)
        rig.clock.runDue()
        rig.backend.onWaitUntilReady = nil
        // The wait moved the clock on: the retirements queued meanwhile are due now
        rig.clock.runDue()

        #expect(coordinator.breakerOpen)
        // Only the second TV's rebuild ran; the third's, queued for the same turn, built nothing
        #expect(builds(rig) == built + 1)
        #expect(await eventually { coordinator.catchAllDeviceUIDs.isEmpty && coordinator.phase("uid-tv2") == nil && coordinator.phase("uid-tv3") == nil })
        #expect(builds(rig) == built + 1)
        #expect(rig.events.events.filter { if case .retiring = $0 { true } else { false } } == [
            .retiring(uid: "uid-tv", .rebuildFailed), .retiring(uid: "uid-tv2", .breaker), .retiring(uid: "uid-tv3", .breaker),
        ])
    }

    @Test("A first build whose wait sees the breaker open is destroyed and never attached: no catch-all after the breaker")
    func breakerDuringFirstBuild() async throws {
        let rig = makeCatchAllRig { system in
            // The second TV is not alive yet: it gets its first build later
            system.outputs.append(CatchAllOutput(uid: "uid-tv2", id: 44))
            system.tiers[44] = .software
        }
        let coordinator = rig.coordinator
        let clock = rig.clock
        coordinator.onCoverageWillEnd = { _ in false }
        failFirstBuilds(rig, 2)
        // Two IO failures toward give-up, and a third whose count has not settled
        try await failIO(rig)
        try await failIO(rig)
        let aggregate = try #require(rig.tv).ioHandle.aggregateID
        await reportIO(rig, "uid-tv", aggregate)
        rig.clock.runDue()
        rig.clock.advance(0.2)
        #expect(failures(rig).count == 4)
        #expect(!coordinator.breakerOpen)
        let tap = rig.backend.lastTap + 1
        rig.backend.onWaitUntilReady = {
            // The third IO failure settles during the second TV's build wait: the give-up is the
            // third failure toward the breaker
            MainActor.assumeIsolated { clock.advance(1) }
        }

        rig.system.alive.insert(44)
        rig.aliveObservers.fire(44)
        rig.clock.runDue()
        rig.backend.onWaitUntilReady = nil
        // The wait moved the clock on: the retirements queued meanwhile are due now
        rig.clock.runDue()

        #expect(coordinator.breakerOpen)
        #expect(coordinator.phase("uid-tv2") == nil)
        #expect(coordinator.catchAll(for: "uid-tv2") == nil)
        #expect(!rig.runControl.log.contains { $0.hasPrefix("attach uid-tv2") })
        #expect(await eventually { coordinator.catchAllDeviceUIDs.isEmpty })
        #expect(await eventually { rig.backend.log.contains { $0.hasPrefix("destroy tap=\(tap) ") } })
    }

    @Test("A catch-all rebuilt from dormant starts the backoff reset again: live 10 min after the rebuild, the backoff starts over")
    func backoffResetAfterDormantRebuild() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.onCoverageWillEnd = { _ in false }

        coordinator.retire("uid-tv", reason: .pushFailed)
        rig.clock.runDue()
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        rig.clock.advance(5)
        #expect(builds(rig) == 2)
        // Dormant for a minute, then alive again: rebuilt from dormant
        makeDormant(rig)
        rig.clock.advance(60)
        rig.system.alive.insert(42)
        rig.aliveObservers.fire(42)
        rig.clock.runDue()
        rig.clock.advance(0.2)
        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        rig.clock.advance(600)

        coordinator.retire("uid-tv", reason: .pushFailed)
        rig.clock.runDue()
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        #expect(rig.events.events.filter { if case .backoff = $0 { true } else { false } } == [
            .backoff(uid: "uid-tv", seconds: 5), .backoff(uid: "uid-tv", seconds: 5),
        ])
    }

    @Test("An IO failure report about an aggregate that is not the catch-all in service counts nothing and rebuilds nothing: an unknown one, or the one a rebuild for another reason replaced")
    func ioFailureForOtherAggregate() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()

        await reportIO(rig, "uid-tv", 999)
        rig.clock.runDue()
        #expect(failures(rig).isEmpty)
        #expect(builds(rig) == 1)

        coordinator.rebuild("uid-tv", reason: .formatChanged)
        rig.clock.runDue()
        rig.clock.advance(0.2)
        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        await reportIO(rig, "uid-tv", 200)
        rig.clock.runDue()
        #expect(failures(rig).isEmpty)
        #expect(builds(rig) == 2)
    }

    @Test("An IO failure report about a dormant catch-all runs the E12 check: a device alive again is rebuilt at once, uncounted")
    func ioFailureReportOnDormant() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        makeDormant(rig)
        #expect(await eventually { rig.runControl.log.contains("detach uid-tv 200") })

        // Alive again before its listener fired; a late report about the dormant catch-all
        rig.system.alive.insert(42)
        await reportIO(rig, "uid-tv", 200)
        rig.clock.runDue()

        #expect(builds(rig) == 2)
        #expect(coordinator.phase("uid-tv") == .live)
        #expect(failures(rig).isEmpty)
    }

    @Test("A rebuild from dormant that finds the listed UID unresolvable at its turn keeps the catch-all dormant, not G; usable again, the 2 s check rebuilds it")
    func dormantRebuildUnresolvable() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        makeDormant(rig)
        #expect(await eventually { rig.runControl.log.contains("detach uid-tv 200") })

        rig.system.alive.insert(42)
        rig.aliveObservers.fire(42)
        // Before the rebuild's turn, Core Audio stops resolving the UID while the device stays listed
        rig.backend.deviceIDs = [:]
        rig.clock.runDue()

        #expect(coordinator.phase("uid-tv") == .dormant)
        #expect(coordinator.covers("uid-tv"))
        #expect(builds(rig) == 1)
        #expect(!rig.events.events.contains { if case .ended = $0 { true } else { false } })

        rig.backend.deviceIDs = ["uid-tv": 42]
        rig.clock.advance(2)
        #expect(builds(rig) == 2)
        #expect(coordinator.phase("uid-tv") == .live)
    }

    // MARK: Lead decisions after 12b (dormant shrink, IO settle, global queue gate, give-up count)

    /// `end`: what ends the wait: the takeover of the rebuild once the device is alive, G for a
    /// UID no longer listed, R, or stop().
    @Test("A claim of a tap on the TV that ends while its catch-all is dormant and its rebuild is not requested gets a ticket: its shrink wait lasts while the device stays dormant, unjudged by the shrink watchdog, and ends at the takeover of the rebuild once the device is alive, at G, at R3 or at stop(); a grow wait on the same ticket ends at once",
          arguments: ["takeover", "absent", "retired", "stopped"])
    func dormantShrinkWaits(end: String) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.onCoverageWillEnd = { _ in false }
        let owner = FakeClaimOwner()
        _ = coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices))
        rig.clock.advance(1)
        makeDormant(rig)
        #expect(await eventually { rig.runControl.log.contains("detach uid-tv 200") })

        // The display sleeps and the user ignores the app: its tap goes (B), while the dormant
        // tap still excludes 11
        let ticket = try #require(coordinator.removeClaim(ObjectIdentifier(owner)))
        #expect(ticket.devices == ["uid-tv"])
        let grown = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .grow); grown.value = true }
        #expect(await eventually { grown.value })
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .shrink); done.value = true }
        #expect(await eventually { coordinator.pendingWaitCount == 1 })
        rig.clock.advance(60)
        await settle()
        #expect(!done.value)
        #expect(coordinator.phase("uid-tv") == .dormant)
        #expect(!rig.events.events.contains { if case .watchdog = $0 { true } else { false } })

        switch end {
        case "takeover":
            rig.system.alive.insert(42)
            rig.aliveObservers.fire(42)
            rig.clock.runDue()
            #expect(coordinator.phase("uid-tv") == .live)
            // Built without 11; the wait ends once it has taken over
            #expect(rig.tv?.appliedExclusions == [5])
            rig.clock.advance(0.19)
            await settle()
            #expect(!done.value)
            rig.clock.advance(0.01)
        case "absent":
            rig.system.outputs.removeAll { $0.uid == "uid-tv" }
            coordinator.deviceListRefreshed()
            rig.clock.runDue()
        case "retired":
            coordinator.retire("uid-tv", reason: .injected)
            rig.clock.runDue()
        default:
            coordinator.stop()
        }
        #expect(await eventually { done.value })
        #expect(failures(rig).isEmpty)
        withExtendedLifetime(owner) {}
    }

    /// `then`: the device 1 s after the report: still alive under its ID, no longer alive (the
    /// link dropped after the IO stopped), listed under a new alive ID, or the coordinator stopped.
    @Test("An IO failure report rebuilds at once, but the failure counts only 1 s later, and only if the device is then still listed under the same ID and alive; stop() drops the count",
          arguments: ["alive", "dead", "newID", "stopped"])
    func ioFailureCountSettles(then: String) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let aggregate = try #require(rig.tv).ioHandle.aggregateID

        await reportIO(rig, "uid-tv", aggregate)
        rig.clock.runDue()
        #expect(builds(rig) == 2)
        rig.clock.advance(0.2)
        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        rig.clock.advance(0.79)
        #expect(failures(rig).isEmpty)

        switch then {
        case "dead":
            rig.system.alive.remove(42)
        case "newID":
            relist(rig, as: 52, alive: true)
        case "stopped":
            coordinator.stop()
            #expect(rig.clock.pendingCount == 0)
        default:
            break
        }
        rig.clock.advance(0.01)
        #expect(failures(rig) == (then == "alive" ? [.failure(uid: "uid-tv", .ioFailed)] : []))
    }

    @Test("The run queue is one serial queue: a detach that times out on one device retires every live catch-all and leaves a dormant one dormant; until the queue has run it nothing is built or rebuilt on any device, and a dormant one alive again retires; then the reconcile builds again")
    func blockedQueueIsGlobal() async throws {
        let rig = makeCatchAllRig { system in
            system.outputs += [CatchAllOutput(uid: "uid-tv2", id: 44), CatchAllOutput(uid: "uid-tv3", id: 45)]
            system.tiers[44] = .software
            system.tiers[45] = .software
            system.alive.formUnion([44, 45])
        }
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.onCoverageWillEnd = { _ in false }
        makeDormant(rig, 45)
        #expect(await eventually { rig.runControl.log.contains("detach uid-tv3 202") })
        rig.runControl.blocked = true

        // G on the TV, whose detach times out
        let tv = rig.system.outputs.removeFirst()
        coordinator.deviceListRefreshed()
        rig.clock.runDue()
        #expect(await eventually { rig.runControl.queuedWorkRequests == 1 })
        rig.clock.runDue()

        // The second TV attached behind the same queue: it retires. The dormant one stays
        #expect(rig.events.events.contains(.retiring(uid: "uid-tv2", .runQueueTimeout)))
        #expect(await eventually { coordinator.phase("uid-tv2") == nil })
        #expect(coordinator.phase("uid-tv3") == .dormant)

        // While the detaches wait: the TV listed again, the backoffs ending, the dormant one
        // alive again, which retires instead of being rebuilt behind the queue
        rig.system.outputs.insert(tv, at: 0)
        coordinator.deviceListRefreshed()
        rig.clock.runDue()
        rig.system.alive.insert(45)
        rig.aliveObservers.fire(45)
        rig.clock.runDue()
        #expect(rig.events.events.contains(.retiring(uid: "uid-tv3", .runQueueTimeout)))
        #expect(await eventually { coordinator.phase("uid-tv3") == nil })
        rig.clock.advance(60)
        #expect(builds(rig) == 3)
        #expect(coordinator.catchAllDeviceUIDs.isEmpty)
        #expect(failures(rig) == [.failure(uid: "uid-tv2", .runQueueTimeout)])

        rig.runControl.unblock()
        #expect(await eventually { rig.backend.log.filter { $0.hasPrefix("destroy") }.count == 3 })
        rig.clock.runDue()
        #expect(builds(rig) == 6)
        #expect(coordinator.catchAllDeviceUIDs == ["uid-tv", "uid-tv2", "uid-tv3"])
    }

    @Test("A give-up counts once toward the breaker, its IO failures not at all: after one failed build the give-up leaves it closed, the TV back under a new ID gets a catch-all again, and the next failed build opens it")
    func giveUpCountsOnceTowardBreaker() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.onCoverageWillEnd = { _ in false }
        failFirstBuilds(rig, 1)

        for _ in 0..<3 { try await failIO(rig) }
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        #expect(coordinator.givenUp == [42])
        #expect(!coordinator.breakerOpen)

        // A power cycle: the TV is back under a new ID
        relist(rig, as: 52, alive: true)
        coordinator.deviceListRefreshed()
        rig.clock.runDue()
        #expect(coordinator.phase("uid-tv") == .live)
        #expect(rig.tv?.deviceID == 52)

        rig.backend.failAt = .createTap
        coordinator.rebuild("uid-tv", reason: .formatChanged)
        rig.clock.runDue()
        rig.backend.failAt = nil
        #expect(!coordinator.breakerOpen)
        rig.clock.advance(CatchAllCoordinator.failureSettle)
        #expect(rig.events.events.contains(.retiring(uid: "uid-tv", .rebuildFailed)))
        #expect(coordinator.breakerOpen)
    }

    // MARK: Review findings after 12b

    @Test("Detaches that time out for a device that went dormant count nothing, since the dead device may block the run queue itself: the dormant catch-all's own and the one its waiting rebuild replaced")
    func dormantTimeoutsCountNothing() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.rebuild("uid-tv", reason: .formatChanged)
        rig.clock.runDue()
        #expect(rig.tv?.ioHandle.aggregateID == 201)
        rig.runControl.blocked = true

        makeDormant(rig)

        #expect(await eventually { rig.runControl.queuedWorkRequests == 2 })
        #expect(rig.runControl.log.contains("detach uid-tv 200 timed out"))
        #expect(rig.runControl.log.contains("detach uid-tv 201 timed out"))
        await settle()
        #expect(failures(rig).isEmpty)
        #expect(coordinator.phase("uid-tv") == .dormant)
        rig.runControl.unblock()
        #expect(await eventually { rig.backend.log.contains { $0.hasPrefix("destroy tap=100 ") } })
    }

    @Test("In observe a retirement's detach that times out counts the blocked run queue, as R4's would in mode on")
    func observeRetirementTimeoutCounts() async throws {
        let rig = makeCatchAllRig(mode: .observe)
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        rig.runControl.blocked = true

        coordinator.retire("uid-tv", reason: .pushFailed)
        rig.clock.runDue()

        #expect(await eventually { rig.runControl.queuedWorkRequests == 1 })
        #expect(failures(rig) == [.failure(uid: "uid-tv", .runQueueTimeout)])
    }

    @Test("A reconcile judges the tier of a live catch-all's device only once the E12 check found it alive under its ID: a device that died while its catch-all was idle and reads another tier goes dormant, not retired")
    func deadDeviceTierNotJudged() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.onCoverageWillEnd = { _ in false }

        // No IO failure reports it; the next device-list refresh does
        rig.system.alive.remove(42)
        rig.system.tiers[42] = .hardware
        coordinator.deviceListRefreshed()
        rig.clock.runDue()

        #expect(coordinator.phase("uid-tv") == .dormant)
        #expect(!rig.events.events.contains { if case .retiring = $0 { true } else { false } })
        #expect(rig.aliveObservers.observed == [42])
    }

    @Test("A first build that cannot read the process list tries again by itself, since the device may have no other trigger: 100 ms apart for 2 s, then every 2 s, until stop()")
    func buildRetriesUnreadableList() async throws {
        let rig = makeCatchAllRig { $0.alive.remove(42) }
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        #expect(rig.aliveObservers.observed == [42])

        // The TV wakes; the reconcile IsAlive asks for ends its observation and cannot read the
        // list once
        rig.system.alive.insert(42)
        rig.system.failingReads = 1
        rig.aliveObservers.fire(42)
        rig.clock.runDue()
        #expect(rig.system.failingReads == 0)
        #expect(coordinator.phase("uid-tv") == nil)
        #expect(rig.aliveObservers.observed.isEmpty)
        rig.clock.advance(0.1)
        #expect(coordinator.phase("uid-tv") == .live)
        #expect(builds(rig) == 1)

        // Unreadable for longer
        let slow = makeCatchAllRig { $0.failingReads = 1_000 }
        slow.coordinator.start()
        slow.clock.advance(2)
        #expect(1_000 - slow.system.failingReads >= 15)
        slow.clock.advance(1)
        let before = slow.system.failingReads
        slow.clock.advance(10)
        #expect((4...6).contains(before - slow.system.failingReads))
        slow.coordinator.stop()
        #expect(slow.clock.pendingCount == 0)
    }

    @Test("An IO failure report about a rebuilt catch-all that waits to take over fails the rebuild: it never takes over silent and is detached and destroyed, the one it replaces serves on, and R follows once the failure settled with the device still alive under its ID, without another build")
    func ioFailureOfWaitingRebuild() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let old = try #require(rig.tv)
        coordinator.rebuild("uid-tv", reason: .formatChanged)
        rig.clock.runDue()
        let new = try #require(rig.tv)
        #expect(new !== old)
        let played = CoordinatorTestBox<Bool?>(nil)
        coordinator.onCoverageWillEnd = { _ in
            played.value = !held(old)
            return false
        }

        // The run queue could not start the new one
        await reportIO(rig, "uid-tv", new.ioHandle.aggregateID, .startFailed)
        #expect(rig.tv === old)
        #expect(await eventually { rig.backend.log.contains("destroy tap=101 aggregate=201 proc=true") })
        #expect(rig.runControl.log.filter { $0.hasPrefix("detach") } == ["detach uid-tv 201"])
        rig.clock.advance(0.2)
        #expect(!rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        #expect(!rig.events.events.contains { if case .retiring = $0 { true } else { false } })
        #expect(!held(old))

        rig.clock.advance(0.8)
        #expect(rig.events.events.contains(.retiring(uid: "uid-tv", .rebuildFailed)))
        #expect(played.value == true)
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        #expect(builds(rig) == 2)
    }

    // MARK: Mutation killers (12b final)

    @Test("A device that dies during R2 is left alone by the E12 check of the reconcile a device-list refresh asks for: it stays retiring and covers nothing, it never goes dormant, and after R4 it is observed until alive, then built")
    func diesDuringRetirement() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let system = rig.system
        coordinator.start()
        rig.clock.runDue()
        coordinator.onCoverageWillEnd = { _ in
            // Inside R2: the link drops while the device stays listed, and the device monitor refreshes
            system.alive.remove(42)
            coordinator.deviceListRefreshed()
            return false
        }

        coordinator.retire("uid-tv", reason: .injected)
        rig.clock.runDue()

        // The refresh's reconcile ran after R2, in the same turn, with the device still retiring
        #expect(coordinator.phase("uid-tv") == .retiring(caHeld: true))
        #expect(!coordinator.covers("uid-tv"))
        #expect(!rig.events.events.contains(.phase(uid: "uid-tv", .dormant)))
        #expect(rig.aliveObservers.observed.isEmpty)
        #expect(rig.clock.pendingCount == 0)
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        // Checked again after R4: not alive, so observed until it is
        #expect(rig.aliveObservers.observed == [42])
        #expect(failures(rig).isEmpty)

        system.alive.insert(42)
        rig.aliveObservers.fire(42)
        rig.clock.runDue()
        #expect(builds(rig) == 2)
        #expect(coordinator.phase("uid-tv") == .live)
    }

    @Test("A rebuild the IsAlive handler asks for while a retirement of the dormant device is queued never runs: the turn runs R first, which drops it, so nothing is built or attached for the retiring device")
    func aliveAgainWhileRetirementQueued() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.onCoverageWillEnd = { _ in false }
        makeDormant(rig)
        #expect(await eventually { rig.runControl.log.contains("detach uid-tv 200") })

        // Both before the coordinator's turn: R is queued, then IsAlive reports the device alive
        coordinator.retire("uid-tv", reason: .injected)
        rig.system.alive.insert(42)
        rig.aliveObservers.fire(42)
        rig.clock.runDue()

        #expect(builds(rig) == 1)
        #expect(rig.runControl.log.filter { $0.hasPrefix("attach") }.count == 1)
        #expect(rig.events.events.contains(.retiring(uid: "uid-tv", .injected)))
        #expect(await eventually { coordinator.phase("uid-tv") == nil })
        #expect(builds(rig) == 1)
        #expect(rig.runControl.log.filter { $0.hasPrefix("detach") } == ["detach uid-tv 200"])
    }

    @Test("An IO failure report about the catch-all a rebuild for another reason replaces, handled while the new one builds, is dropped: nothing counted once it would have settled, no second rebuild")
    func ioFailureWhileRebuildBuilds() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let old = try #require(rig.tv).ioHandle.aggregateID
        rig.backend.onWaitUntilReady = {
            MainActor.assumeIsolated { coordinator.reportIOFailure("uid-tv", aggregate: old, .ioDead) }
        }

        coordinator.rebuild("uid-tv", reason: .formatChanged)
        rig.clock.runDue()
        rig.backend.onWaitUntilReady = nil
        rig.clock.advance(0.2)

        #expect(rig.events.events.filter { $0 == .rebuilt(uid: "uid-tv") }.count == 1)
        rig.clock.advance(1)
        #expect(failures(rig).isEmpty)
        #expect(builds(rig) == 2)
    }

    @Test("An IO failure report on a dormant device runs the E12 check whichever aggregate it names, since its detached catch-all reports nothing current: alive again, the device is rebuilt at once, uncounted")
    func ioFailureReportOnDormantAnyAggregate() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        makeDormant(rig)
        #expect(await eventually { rig.runControl.log.contains("detach uid-tv 200") })

        rig.system.alive.insert(42)
        await reportIO(rig, "uid-tv", 999)
        rig.clock.runDue()

        #expect(builds(rig) == 2)
        #expect(coordinator.phase("uid-tv") == .live)
        #expect(failures(rig).isEmpty)
    }

    /// `path`: as in `absentWhileListed`, but Core Audio keeps not resolving the UID, so the
    /// reconcile after G builds nothing and asks for no re-evaluation of its own.
    @Test("G for a device whose listed UID stays unresolvable runs the gate itself, although the reconcile after it builds nothing: the apps the catch-all played get their taps",
          arguments: ["retirement", "rebuild", "rebuildFails"])
    func absentWhileListedStaysUnresolvable(path: String) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let backend = rig.backend
        coordinator.start()
        rig.clock.runDue()
        let gate = CoordinatorTestBox(0)
        coordinator.onCoverageMayHaveChanged = { gate.value += 1 }
        coordinator.onCoverageWillEnd = { _ in false }

        switch path {
        case "retirement":
            coordinator.retire("uid-tv", reason: .pushFailed)
            backend.deviceIDs = [:]
        case "rebuild":
            coordinator.rebuild("uid-tv", reason: .formatChanged)
            backend.deviceIDs = [:]
        default:
            backend.onWaitUntilReady = { backend.deviceIDs = [:] }
            backend.failAt = .ready
            coordinator.rebuild("uid-tv", reason: .formatChanged)
        }
        rig.clock.runDue()
        backend.onWaitUntilReady = nil
        backend.failAt = nil

        #expect(rig.events.events.contains(.ended(uid: "uid-tv", reason: "absent")))
        // The reconcile ran and could not build
        #expect(rig.events.events.filter { if case .buildFailed = $0 { true } else { false } }.count == (path == "rebuildFails" ? 2 : 1))
        #expect(coordinator.phase("uid-tv") == nil)
        #expect(!coordinator.covers("uid-tv"))
        #expect(gate.value == 1)
        #expect(failures(rig).isEmpty)
    }

    // MARK: Recheck of D1 to D4

    /// `mode`: on, or observe, where a dormant tap holds nothing back.
    @Test("A dormant catch-all carries a shrink ticket only for a tap that plays to it, in mode on: the mixdown claim of a tap on the AirPods that ends gets none, so that tap goes at once instead of processing its app there until the TV wakes; in observe no claim gets one",
          arguments: [CatchAllMode.on, .observe])
    func dormantShrinkOnlyForTargets(mode: CatchAllMode) async throws {
        let rig = makeCatchAllRig(mode: mode)
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let onTV = FakeClaimOwner()
        let onAirPods = FakeClaimOwner(pid: 2, targets: ["uid-air"])
        _ = coordinator.setClaim(onTV, Claim(processes: [11], coverage: .allDevices))
        // P5: while the TV has a catch-all, a tap on the AirPods uses the mixdown
        _ = coordinator.setClaim(onAirPods, Claim(processes: [12], coverage: .allDevices))
        rig.clock.advance(1)
        makeDormant(rig)
        #expect(coordinator.phase("uid-tv") == .dormant)

        // The AirPods tap of a call app is released, or its app ignored
        #expect(coordinator.changedDevices(owner: ObjectIdentifier(onAirPods), proposed: .empty).isEmpty)
        #expect(coordinator.removeClaim(ObjectIdentifier(onAirPods)) == nil)
        // A tap on the TV waits, held by the hold rule
        let changed = coordinator.changedDevices(owner: ObjectIdentifier(onTV), proposed: .empty)
        let ticket = coordinator.removeClaim(ObjectIdentifier(onTV))
        #expect(changed == (mode == .on ? ["uid-tv"] : []))
        #expect(ticket?.devices == (mode == .on ? ["uid-tv"] : nil))
        withExtendedLifetime([onTV, onAirPods]) {}
    }

    /// `mode`: on, or observe, where a dormant tap holds nothing back.
    @Test("A shrink ticket the TV got while live, whose push never reached its catch-all before it went dormant, waits on the dormant catch-all in mode on and ends at once in observe",
          arguments: [CatchAllMode.on, .observe])
    func dormantShrinkWaitInObserve(mode: CatchAllMode) async throws {
        let rig = makeCatchAllRig(mode: mode)
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let owner = FakeClaimOwner()
        _ = coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices))
        rig.clock.advance(1)
        let ticket = try #require(coordinator.removeClaim(ObjectIdentifier(owner)))
        // Dormant before the flush pushed the list without 11
        coordinator.setPhaseForTesting(.dormant, for: "uid-tv")

        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .shrink); done.value = true }
        if mode == .on {
            #expect(await eventually { coordinator.pendingWaitCount == 1 })
            rig.clock.advance(60)
            await settle()
            #expect(!done.value)
            coordinator.stop()
        }
        #expect(await eventually { done.value })
        withExtendedLifetime(owner) {}
    }

    /// `path`: a first build fails; a rebuild fails; a rebuilt catch-all fails to start before it
    /// takes over; or one of the last two from dormant, once the device is alive again. `then`:
    /// the device 0.5 s after the failure: still alive under its ID, no longer alive (the link
    /// dropped after the build or start failed), listed under a new alive ID, no longer listed,
    /// or the coordinator stopped.
    @Test("A failure on a device that reads alive is decided 1 s later: still listed under the same ID and usable, it counts, a catch-all that served meanwhile retires (R) and the next build backs off from the failure; otherwise the E12 check decides (dormant, a rebuild on the new ID, G) with nothing counted, no R, no backoff and no callback. Until then the old catch-all serves as it was, a failed new one is destroyed, nothing is built or rebuilt there, and stop() drops it",
          arguments: ["build", "rebuild", "waitingRebuild", "dormantRebuild", "dormantWaitingRebuild"],
          ["alive", "dead", "newID", "unlisted", "stopped"])
    func failureSettles(path: String, then: String) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let calledBack = CoordinatorTestBox(false)
        coordinator.onCoverageWillEnd = { _ in
            calledBack.value = true
            return false
        }
        let startFails = ["waitingRebuild", "dormantWaitingRebuild"].contains(path)
        if path != "build" {
            coordinator.start()
            rig.clock.runDue()
        }
        if path.hasPrefix("dormant") {
            makeDormant(rig)
            #expect(await eventually { rig.runControl.log.contains("detach uid-tv 200") })
        }
        switch path {
        case "build":
            rig.backend.failAt = .createTap
            coordinator.start()
            rig.backend.failAt = nil
        case "rebuild", "dormantRebuild":
            rig.backend.failAt = .createTap
            if path == "rebuild" {
                coordinator.rebuild("uid-tv", reason: .formatChanged)
            } else {
                rig.system.alive.insert(42)
                rig.aliveObservers.fire(42)
            }
            rig.clock.runDue()
            rig.backend.failAt = nil
        default:
            if path == "waitingRebuild" {
                coordinator.rebuild("uid-tv", reason: .formatChanged)
            } else {
                rig.system.alive.insert(42)
                rig.aliveObservers.fire(42)
            }
            rig.clock.runDue()
            #expect(rig.tv?.ioHandle.aggregateID == 201)
            #expect(coordinator.phase("uid-tv") == .live)
            await reportIO(rig, "uid-tv", 201, .startFailed)
            #expect(await eventually { rig.backend.log.contains("destroy tap=101 aggregate=201 proc=true") })
        }
        let built = builds(rig)
        // The old catch-all serves as it was: live and playing, or dormant and held
        switch path {
        case "build":
            #expect(coordinator.phase("uid-tv") == nil)
        case "rebuild", "waitingRebuild":
            #expect(coordinator.phase("uid-tv") == .live)
            #expect(rig.tv?.ioHandle.aggregateID == 200)
            #expect(rig.tv.map(held) == false)
        default:
            #expect(coordinator.phase("uid-tv") == .dormant)
            #expect(rig.tv?.ioHandle.aggregateID == 200)
            #expect(rig.tv.map(held) == true)
        }

        // Nothing is built or rebuilt meanwhile, whatever asks for it
        coordinator.reconcile()
        coordinator.rebuild("uid-tv", reason: .formatChanged)
        rig.aliveObservers.fire(42)
        rig.clock.advance(0.5)
        #expect(builds(rig) == built)
        #expect(!calledBack.value)
        switch then {
        case "dead":
            rig.system.alive.remove(42)
        case "newID":
            relist(rig, as: 52, alive: true)
        case "unlisted":
            rig.system.outputs.removeAll { $0.uid == "uid-tv" }
        case "stopped":
            coordinator.stop()
            #expect(rig.clock.pendingCount == 0)
        default:
            break
        }
        rig.clock.advance(0.5)

        let backoffs = { rig.events.events.filter { if case .backoff = $0 { true } else { false } } }
        let retirements = rig.events.events.filter { if case .retiring = $0 { true } else { false } }
        guard then == "alive" else {
            #expect(failures(rig).isEmpty)
            #expect(backoffs().isEmpty)
            #expect(retirements.isEmpty)
            #expect(!calledBack.value)
            switch then {
            case "dead":
                // Dormant with its catch-all, observed without one; alive again, built at once,
                // no backoff in the way
                #expect(coordinator.phase("uid-tv") == (path == "build" ? nil : .dormant))
                #expect(rig.aliveObservers.observed == [42])
                rig.system.alive.insert(42)
                rig.aliveObservers.fire(42)
                rig.clock.runDue()
                #expect(builds(rig) == built + 1)
                #expect(coordinator.phase("uid-tv") == .live)
            case "newID":
                #expect(builds(rig) == built + 1)
                #expect(rig.tv?.deviceID == 52)
            case "unlisted":
                #expect(coordinator.phase("uid-tv") == nil)
                #expect(rig.events.events.contains(.ended(uid: "uid-tv", reason: "absent")) == (path != "build"))
            default:
                #expect(coordinator.phase("uid-tv") == nil)
            }
            return
        }
        // A rebuilt catch-all that failed to start counts its IO failure toward give-up only
        #expect(failures(rig) == [.failure(uid: "uid-tv", startFails ? CatchAllFailure.ioFailed : .buildFailed)])
        if path != "build" {
            #expect(retirements == [.retiring(uid: "uid-tv", .rebuildFailed)])
            #expect(calledBack.value)
            #expect(await eventually { coordinator.phase("uid-tv") == nil })
        }
        // R4 backs off no further
        #expect(backoffs() == [.backoff(uid: "uid-tv", seconds: 5)])
        rig.clock.advance(3.99)
        #expect(builds(rig) == built)
        rig.clock.advance(0.01)
        #expect(builds(rig) == built + 1)
        #expect(coordinator.phase("uid-tv") == .live)
    }

    @Test("A reconcile in which no build finds the process list unreadable ends that streak: a build that finds it unreadable later tries again 100 ms after, not 2 s, and reports it again")
    func unreadableBuildStreakEnds() async throws {
        let rig = makeCatchAllRig { $0.alive.remove(42) }
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        // The TV wakes and its build cannot read the list; it dies again before the retry
        rig.system.alive.insert(42)
        rig.system.failingReads = 1
        rig.aliveObservers.fire(42)
        rig.clock.runDue()
        #expect(rig.system.failingReads == 0)
        #expect(coordinator.phase("uid-tv") == nil)
        rig.system.alive.remove(42)
        rig.clock.advance(0.1)
        #expect(rig.aliveObservers.observed == [42])
        #expect(rig.clock.pendingCount == 0)

        // An hour later it wakes again, and its build cannot read the list once
        rig.clock.advance(3600)
        rig.system.alive.insert(42)
        rig.system.failingReads = 1
        rig.aliveObservers.fire(42)
        rig.clock.runDue()
        #expect(rig.system.failingReads == 0)
        #expect(coordinator.phase("uid-tv") == nil)
        rig.clock.advance(0.1)
        #expect(coordinator.phase("uid-tv") == .live)
        #expect(builds(rig) == 1)
        #expect(rig.events.events.filter { $0 == .buildFailed(uid: "uid-tv", reason: "process list unreadable") }.count == 2)
    }

    // MARK: Failures decided after the settle, dormant shrinks during a rebuild (D5, D6)

    /// `late`: a push failure, or an IO report about the old catch-all, 0.5 s into the settle of a
    /// failed rebuild. `end`: the device at the settle's end, still alive under its ID or no
    /// longer alive.
    @Test("A push failure or IO report during the settle of a failed rebuild is decided with it at its end, never on its own: nothing is rebuilt meanwhile; still alive under its ID, the catch-all retires once and the wait the push failure left ends at R3; no longer alive, it goes dormant, uncounted and without R",
          arguments: ["pushFailure", "ioReport"], ["alive", "dead"])
    func laterFailureDecidedAtSettle(late: String, end: String) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let tv = try #require(rig.tv)
        let calledBack = CoordinatorTestBox(0)
        coordinator.onCoverageWillEnd = { _ in
            calledBack.value += 1
            return false
        }
        rig.backend.failAt = .createTap
        coordinator.rebuild("uid-tv", reason: .formatChanged)
        rig.clock.runDue()
        rig.backend.failAt = nil
        rig.clock.advance(0.5)

        let owner = FakeClaimOwner()
        let done = CoordinatorTestBox(false)
        if late == "pushFailure" {
            rig.backend.failSets = 2
            let ticket = try #require(coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices)))
            Task { await coordinator.waitApplied(ticket, .grow); done.value = true }
            #expect(await eventually { coordinator.pendingWaitCount == 1 })
            rig.clock.runDue()
            #expect(rig.events.events.filter { $0 == .pushFailed(uid: "uid-tv", excluded: [5, 11]) }.count == 2)
        } else {
            await reportIO(rig, "uid-tv", tv.ioHandle.aggregateID)
            rig.clock.runDue()
        }
        // Left to the settle: nothing rebuilt, nothing retired
        #expect(builds(rig) == 2)
        #expect(rig.tv === tv)
        #expect(calledBack.value == 0)
        if end == "dead" { rig.system.alive.remove(42) }
        rig.clock.advance(0.5)

        let retirements = { rig.events.events.filter { if case .retiring = $0 { true } else { false } } }
        if end == "alive" {
            #expect(retirements() == [.retiring(uid: "uid-tv", .rebuildFailed)])
            #expect(await eventually { coordinator.phase("uid-tv") == nil })
            #expect(calledBack.value == 1)
        } else {
            #expect(coordinator.phase("uid-tv") == .dormant)
            #expect(retirements().isEmpty)
            #expect(calledBack.value == 0)
        }
        // A grow wait ends at R3, or at once on a dormant catch-all
        if late == "pushFailure" { #expect(await eventually { done.value }) }
        // The IO report counts toward give-up on its own, 1 s after it, if the device is alive then
        rig.clock.advance(1)
        #expect(builds(rig) == 2)
        var counted: [CatchAllEvent] = []
        if end == "alive" {
            counted.append(.failure(uid: "uid-tv", .buildFailed))
            if late == "ioReport" { counted.append(.failure(uid: "uid-tv", .ioFailed)) }
        }
        #expect(failures(rig) == counted)
        withExtendedLifetime(owner) {}
    }

    /// `late`: what is left to the settle 0.5 s after the failure: a push failure (its wait's
    /// watchdog is due only 0.5 s after the settle), or an IO report about the old catch-all.
    @Test("A failed rebuild on a new listed ID whose old ID is listed again before the settle ends finds the catch-all unchanged: nothing counted and no R, and the rebuild is asked for again at once, so a push failure or IO report left to the settle is served by it",
          arguments: ["pushFailure", "ioReport"])
    func failedRebuildAskedAgainWhenUnchanged(late: String) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.onCoverageWillEnd = { _ in false }
        // The TV is listed under a new alive ID (V11), and its rebuild there fails
        relist(rig, as: 52, alive: true)
        rig.backend.failAt = .createTap
        coordinator.deviceListRefreshed()
        rig.clock.runDue()
        rig.backend.failAt = nil
        #expect(builds(rig) == 2)
        #expect(rig.tv?.deviceID == 42)
        rig.clock.advance(0.5)

        let owner = FakeClaimOwner()
        let done = CoordinatorTestBox(false)
        if late == "pushFailure" {
            rig.backend.failSets = 2
            let ticket = try #require(coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices)))
            Task { await coordinator.waitApplied(ticket, .grow); done.value = true }
            #expect(await eventually { coordinator.pendingWaitCount == 1 })
        } else {
            await reportIO(rig, "uid-tv", 200)
        }
        rig.clock.runDue()
        #expect(builds(rig) == 2)

        // The old ID is back before the settle ends: the catch-all on it is unchanged
        relist(rig, as: 42, alive: true)
        rig.clock.advance(0.5)
        #expect(builds(rig) == 3)
        #expect(rig.tv?.appliedExclusions == (late == "pushFailure" ? [5, 11] : [5]))
        rig.clock.advance(0.2)
        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        if late == "pushFailure" { #expect(await eventually { done.value }) }
        #expect(failures(rig).isEmpty)
        #expect(!rig.events.events.contains { if case .retiring = $0 { true } else { false } })
        withExtendedLifetime(owner) {}
    }

    /// `state`: the dormant TV's rebuild when the claim of the tap on the AirPods ends: not
    /// requested, requested by IsAlive, postponed by an unreadable process list, or building.
    @Test("Once the rebuild of a dormant catch-all is requested, postponed or building, the mixdown claim of a tap on another device that ends gets a ticket for it, since the device is alive and the catch-all being built may still exclude the process: the shrink wait ends at the takeover. Without a rebuild it gets none",
          arguments: ["none", "requested", "postponed", "building"])
    func dormantShrinkDuringRebuild(state: String) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let system = rig.system
        coordinator.start()
        rig.clock.runDue()
        // P5: while the TV has a catch-all, a tap on the AirPods uses the mixdown
        let onAirPods = FakeClaimOwner(pid: 2, targets: ["uid-air"])
        let id = ObjectIdentifier(onAirPods)
        _ = coordinator.setClaim(onAirPods, Claim(processes: [12], coverage: .allDevices))
        rig.clock.advance(1)
        makeDormant(rig)
        #expect(await eventually { rig.runControl.log.contains("detach uid-tv 200") })

        // The AirPods tap of a call app is released
        let changed = CoordinatorTestBox<Set<String>?>(nil)
        let ticket = CoordinatorTestBox<ApplyTicket?>(nil)
        let release: @MainActor @Sendable () -> Void = {
            changed.value = coordinator.changedDevices(owner: id, proposed: .empty)
            ticket.value = coordinator.removeClaim(id)
        }
        if state != "none" {
            // The TV wakes; IsAlive asks for its rebuild
            system.alive.insert(42)
            if state == "postponed" { system.processListReadable = false }
            if state == "building" { rig.backend.onWaitUntilReady = { MainActor.assumeIsolated { release() } } }
            rig.aliveObservers.fire(42)
            if state != "requested" { rig.clock.runDue() }
            rig.backend.onWaitUntilReady = nil
        }
        if state != "building" { release() }
        guard state != "none" else {
            #expect(changed.value == [])
            #expect(ticket.value == nil)
            withExtendedLifetime(onAirPods) {}
            return
        }
        let applied = try #require(ticket.value)
        #expect(applied.devices == ["uid-tv"])
        #expect(changed.value == applied.devices)
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(applied, .shrink); done.value = true }
        #expect(await eventually { coordinator.pendingWaitCount == 1 })
        system.processListReadable = true
        rig.clock.runDue()

        // The takeover: 200 ms after the attach (100 ms later for the postponed one), or S after
        // the push without 12 to a catch-all built with it
        let takeover: Double = switch state {
        case "requested": 0.2
        case "postponed": 0.3
        default: 0.4
        }
        rig.clock.advance(takeover - 0.01)
        await settle()
        #expect(!done.value)
        #expect(!rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        rig.clock.advance(0.01)
        #expect(rig.events.events.contains(.rebuilt(uid: "uid-tv")))
        #expect(await eventually { done.value })
        #expect(rig.tv?.appliedExclusions == [5])
        withExtendedLifetime(onAirPods) {}
    }

    @Test("The catch-all a failed rebuilt one would have replaced serves on with its own record: a shrink pushed to it just before the rebuild ends S after that push, not at once, and a claim that changed while the rebuilt one waited is pushed to it")
    func failedRebuildRestoresOldRecord() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.onCoverageWillEnd = { _ in false }
        let owners = [FakeClaimOwner(), FakeClaimOwner(pid: 2)]
        _ = coordinator.setClaim(owners[0], Claim(processes: [11], coverage: .allDevices))
        rig.clock.advance(1)
        let old = try #require(rig.tv)

        // 11's tap goes: the list without it is pushed, and a rebuild attaches in the same instant
        let shrink = try #require(coordinator.removeClaim(ObjectIdentifier(owners[0])))
        rig.clock.runDue()
        #expect(old.appliedExclusions == [5])
        coordinator.rebuild("uid-tv", reason: .formatChanged)
        rig.clock.runDue()
        let new = try #require(rig.tv)
        #expect(new !== old)
        // While the rebuilt one waits, 12 gets a tap; the push goes to the rebuilt one only
        let grow = try #require(coordinator.setClaim(owners[1], Claim(processes: [12], coverage: .allDevices)))
        rig.clock.runDue()
        #expect(new.appliedExclusions == [5, 12])
        #expect(old.appliedExclusions == [5])

        await reportIO(rig, "uid-tv", new.ioHandle.aggregateID, .startFailed)
        #expect(rig.tv === old)
        let shrunk = CoordinatorTestBox(false)
        let grown = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(shrink, .shrink); shrunk.value = true }
        Task { await coordinator.waitApplied(grow, .grow); grown.value = true }
        #expect(await eventually { coordinator.pendingWaitCount == 2 })
        rig.clock.runDue()
        #expect(old.appliedExclusions == [5, 12])
        rig.clock.advance(0.39)
        await settle()
        #expect(grown.value)
        #expect(!shrunk.value)
        rig.clock.advance(0.01)
        #expect(await eventually { shrunk.value })
        withExtendedLifetime(owners) {}
    }

    // MARK: Review findings after D5 and D6

    /// `path`: how the rebuild of the dormant TV, requested when it woke, ends with the TV dead
    /// again: its turn finds it so (requested), the retry after an unreadable process list does
    /// (postponed), its build fails because the TV died during it (buildFailsDead), or its build
    /// fails while the TV reads alive and the TV is dead when that failure settled
    /// (settleEndsDead).
    @Test("A shrink ticket a dormant catch-all got only because its rebuild was underway, for a tap on another device, ends once that rebuild ended with the device still dormant, and not before; the ticket of a tap on the device waits on for the next rebuild, R or G",
          arguments: ["requested", "postponed", "buildFailsDead", "settleEndsDead"])
    func rebuildShrinkEndsWhenStillDormant(path: String) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let system = rig.system
        let backend = rig.backend
        coordinator.start()
        rig.clock.runDue()
        coordinator.onCoverageWillEnd = { _ in false }
        // P5: while the TV has a catch-all, a tap on the AirPods uses the mixdown
        let onTV = FakeClaimOwner()
        let onAirPods = FakeClaimOwner(pid: 2, targets: ["uid-air"])
        _ = coordinator.setClaim(onTV, Claim(processes: [11], coverage: .allDevices))
        _ = coordinator.setClaim(onAirPods, Claim(processes: [12], coverage: .allDevices))
        rig.clock.advance(1)
        makeDormant(rig)
        #expect(await eventually { rig.runControl.log.contains("detach uid-tv 200") })

        // The TV wakes; IsAlive asks for its rebuild
        system.alive.insert(42)
        if path == "postponed" { system.processListReadable = false }
        rig.aliveObservers.fire(42)
        if path == "postponed" { rig.clock.runDue() }
        // The AirPods tap of a call app is released, and the app on the TV is ignored
        let airPods = try #require(coordinator.removeClaim(ObjectIdentifier(onAirPods)))
        let tv = try #require(coordinator.removeClaim(ObjectIdentifier(onTV)))
        #expect(airPods.devices == ["uid-tv"])
        let airPodsDone = CoordinatorTestBox(false)
        let tvDone = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(airPods, .shrink); airPodsDone.value = true }
        Task { await coordinator.waitApplied(tv, .shrink); tvDone.value = true }
        #expect(await eventually { coordinator.pendingWaitCount == 2 })
        system.processListReadable = true

        switch path {
        case "requested":
            system.alive.remove(42)
            rig.clock.runDue()
        case "postponed":
            system.alive.remove(42)
            rig.clock.advance(0.09)
            await settle()
            #expect(!airPodsDone.value)
            rig.clock.advance(0.01)
        case "buildFailsDead":
            let clock = rig.clock
            backend.failAt = .ready
            backend.onWaitUntilReady = {
                MainActor.assumeIsolated {
                    // The spin runs the flush the claim changes scheduled; its check finds the
                    // rebuild still running, so only the end of the rebuild can end the wait
                    clock.runDue()
                    _ = system.alive.remove(42)
                }
            }
            rig.clock.runDue()
            backend.onWaitUntilReady = nil
            backend.failAt = nil
        default:
            backend.failAt = .ready
            rig.clock.runDue()
            backend.failAt = nil
            rig.clock.advance(0.5)
            system.alive.remove(42)
            rig.clock.advance(0.49)
            await settle()
            #expect(!airPodsDone.value)
            rig.clock.advance(0.01)
        }
        #expect(await eventually { airPodsDone.value })
        #expect(coordinator.phase("uid-tv") == .dormant)
        #expect(coordinator.pendingWaitCount == 1)
        rig.clock.advance(60)
        await settle()
        #expect(!tvDone.value)
        coordinator.stop()
        #expect(await eventually { tvDone.value })
        #expect(failures(rig).isEmpty)
        #expect(!rig.events.events.contains { if case .retiring = $0 { true } else { false } })
        withExtendedLifetime([onTV, onAirPods]) {}
    }

    /// `path`: the TV wakes and its rebuild from dormant fails while it reads alive, or the
    /// rebuilt catch-all fails to start before it takes over and the TV is dormant again. `end`:
    /// the TV when that failure settled: still alive under its ID (R), or no longer alive.
    @Test("While a failure settles on a dormant catch-all whose device reads alive, the mixdown claim of a tap on another device that ends gets a ticket for it, as during a rebuild, since the dormant tap still excludes the process: its shrink wait ends at R3 if the failure stood, not before R even when another device's report checks the waits first, and at the settle's end if the device stays dormant",
          arguments: ["dormantRebuild", "dormantWaitingRebuild"], ["alive", "dead"])
    func dormantShrinkDuringSettle(path: String, end: String) async throws {
        let rig = makeTwoDeviceRig()
        let coordinator = rig.coordinator
        let system = rig.system
        coordinator.start()
        rig.clock.runDue()
        let pendingAtR2 = CoordinatorTestBox<Int?>(nil)
        coordinator.onCoverageWillEnd = { uid in
            if uid == "uid-tv" { pendingAtR2.value = coordinator.pendingWaitCount }
            return false
        }
        // P5: while the TVs have a catch-all, a tap on the AirPods uses the mixdown
        let onAirPods = FakeClaimOwner(pid: 2, targets: ["uid-air"])
        let id = ObjectIdentifier(onAirPods)
        _ = coordinator.setClaim(onAirPods, Claim(processes: [12], coverage: .allDevices))
        rig.clock.advance(1)
        makeDormant(rig)
        #expect(await eventually { rig.runControl.log.contains("detach uid-tv 200") })

        // The TV wakes, and its catch-all cannot be rebuilt, or not started, while it reads alive
        system.alive.insert(42)
        if path == "dormantRebuild" { rig.backend.failAt = .createTap }
        rig.aliveObservers.fire(42)
        rig.clock.runDue()
        rig.backend.failAt = nil
        if path == "dormantWaitingRebuild" {
            #expect(rig.tv?.ioHandle.aggregateID == 202)
            await reportIO(rig, "uid-tv", 202, .startFailed)
        }
        #expect(coordinator.phase("uid-tv") == .dormant)
        // The other TV's IO report reaches main right after the settle's end, before R runs
        let other = try #require(coordinator.catchAll(for: "uid-tv2")).ioHandle.aggregateID
        _ = rig.clock.schedule(after: CatchAllCoordinator.failureSettle) {
            _ = system.alive.remove(44)
            coordinator.reportIOFailure("uid-tv2", aggregate: other, .ioDead)
        }

        // The AirPods tap of a call app is released
        rig.clock.advance(0.3)
        let changed = coordinator.changedDevices(owner: id, proposed: .empty)
        let ticket = try #require(coordinator.removeClaim(id))
        #expect(changed == ["uid-tv", "uid-tv2"])
        #expect(ticket.devices == ["uid-tv", "uid-tv2"])
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .shrink); done.value = true }
        #expect(await eventually { coordinator.pendingWaitCount == 1 })
        // The other TV's part applies S after its push; the TV's waits for the settle's end
        rig.clock.advance(0.69)
        await settle()
        #expect(!done.value)
        if end == "dead" { system.alive.remove(42) }
        rig.clock.advance(0.01)

        if end == "alive" {
            #expect(rig.events.events.contains(.retiring(uid: "uid-tv", .rebuildFailed)))
            #expect(pendingAtR2.value == 1)
        } else {
            #expect(coordinator.phase("uid-tv") == .dormant)
            #expect(pendingAtR2.value == nil)
        }
        #expect(coordinator.phase("uid-tv2") == .dormant)
        #expect(await eventually { done.value })
        withExtendedLifetime(onAirPods) {}
    }

    /// `end`: the TV when the failure settled: still alive under its ID, or no longer alive.
    @Test("A rebuilt catch-all that fails to start while the run queue is blocked counts nothing when its detach times out, and the one it would have replaced is left to the settle, not retired at once: still alive under its ID then, it retires and its own R4 detach counts the blocked queue once; no longer alive, it goes dormant and nothing counts",
          arguments: ["alive", "dead"])
    func failedRebuildDetachTimeout(end: String) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.onCoverageWillEnd = { _ in false }
        let old = try #require(rig.tv)
        coordinator.rebuild("uid-tv", reason: .formatChanged)
        rig.clock.runDue()
        let new = try #require(rig.tv)
        #expect(new !== old)
        let retirements = { rig.events.events.filter { if case .retiring = $0 { true } else { false } } }

        // The display sleeps: the run queue is stuck in a HAL call on the TV, and the new
        // catch-all does not start
        rig.runControl.blocked = true
        await reportIO(rig, "uid-tv", new.ioHandle.aggregateID, .startFailed)
        #expect(rig.tv === old)
        #expect(await eventually { rig.runControl.queuedWorkRequests == 1 })
        #expect(rig.runControl.log.contains("detach uid-tv 201 timed out"))
        rig.clock.runDue()
        #expect(failures(rig).isEmpty)
        #expect(retirements().isEmpty)
        #expect(coordinator.phase("uid-tv") == .live)
        #expect(!held(old))

        if end == "dead" { rig.system.alive.remove(42) }
        rig.clock.advance(CatchAllCoordinator.failureSettle)
        #expect(await eventually { rig.runControl.log.contains("detach uid-tv 200 timed out") })
        if end == "alive" {
            #expect(retirements() == [.retiring(uid: "uid-tv", .rebuildFailed)])
            #expect(await eventually { failures(rig).count == 2 })
            #expect(failures(rig) == [.failure(uid: "uid-tv", .ioFailed), .failure(uid: "uid-tv", .runQueueTimeout)])
        } else {
            #expect(coordinator.phase("uid-tv") == .dormant)
            await settle()
            #expect(failures(rig).isEmpty)
            #expect(retirements().isEmpty)
        }
        rig.runControl.unblock()
        #expect(await eventually { rig.backend.log.contains { $0.hasPrefix("destroy tap=101 ") } })
        if end == "alive" {
            #expect(await eventually { rig.backend.log.contains { $0.hasPrefix("destroy tap=100 ") } })
        } else {
            // A dormant catch-all keeps its resources
            await settle()
            #expect(!rig.backend.log.contains { $0.hasPrefix("destroy tap=100 ") })
        }
    }

    /// `path`: a first build fails while the TV reads alive, a rebuild of its live catch-all
    /// does, or its rebuild from dormant does. 0.4 s later the coordinator finds the TV not alive
    /// (a reconcile, a device-list refresh, its IsAlive listener), and 0.7 s after the failure
    /// IsAlive reports it alive again under the same ID: an HDMI link that renegotiates at wake.
    @Test("A failure on a device the coordinator found not alive while the failure settled did not stand, although the device is alive under its ID again at the settle's end: nothing counted, no R and no backoff, and the device is built or rebuilt at once",
          arguments: ["build", "rebuild", "dormantRebuild"])
    func failureSettleAfterFlap(path: String) async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let system = rig.system
        let calledBack = CoordinatorTestBox(false)
        coordinator.onCoverageWillEnd = { _ in
            calledBack.value = true
            return false
        }
        if path != "build" {
            coordinator.start()
            rig.clock.runDue()
        }
        if path == "dormantRebuild" {
            makeDormant(rig)
            #expect(await eventually { rig.runControl.log.contains("detach uid-tv 200") })
        }
        rig.backend.failAt = .createTap
        switch path {
        case "build":
            coordinator.start()
        case "rebuild":
            coordinator.rebuild("uid-tv", reason: .formatChanged)
            rig.clock.runDue()
        default:
            system.alive.insert(42)
            rig.aliveObservers.fire(42)
            rig.clock.runDue()
        }
        rig.backend.failAt = nil
        let built = builds(rig)

        rig.clock.advance(0.4)
        system.alive.remove(42)
        switch path {
        case "build":
            coordinator.reconcile()
        case "rebuild":
            coordinator.deviceListRefreshed()
        default:
            rig.aliveObservers.fire(42)
        }
        rig.clock.runDue()
        #expect(coordinator.phase("uid-tv") == (path == "build" ? nil : .dormant))
        rig.clock.advance(0.3)
        system.alive.insert(42)
        rig.aliveObservers.fire(42)
        rig.clock.runDue()
        // Left to the settle
        #expect(builds(rig) == built)

        rig.clock.advance(0.3)
        #expect(failures(rig).isEmpty)
        #expect(!rig.events.events.contains { if case .backoff = $0 { true } else { false } })
        #expect(!rig.events.events.contains { if case .retiring = $0 { true } else { false } })
        #expect(!calledBack.value)
        #expect(builds(rig) == built + 1)
        #expect(coordinator.phase("uid-tv") == .live)
    }
}
