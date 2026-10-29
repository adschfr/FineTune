// FineTuneTests/CatchAllCoordinatorTests.swift
//
// The coordinator core (design §16.4, §16.8 test 4) against fakes only: which outputs get a
// catch-all and in which phase, gain, claims and the coalesced flush with read-back, applied
// waits, the held start, the I1 repair, the C9 settle rule, the shared next-turn task and
// reentrancy during a build's wait. No Core Audio object is created.

import AppKit
import AudioToolbox
import Foundation
import Synchronization
import Testing
@testable import FineTune

// MARK: - Fakes

/// Timers that run only when a test moves the clock; `runDue()` runs what is due now, like
/// the next main-actor turns.
final class ManualCatchAllClock: CatchAllClock {
    private struct Item {
        let id: Int
        let due: Double
        let action: @MainActor @Sendable () -> Void
    }

    private(set) var now: Double = 1000
    private var items: [Item] = []
    private var nextID = 0

    var pendingCount: Int { items.count }

    func schedule(after delay: Double, _ action: @escaping @MainActor @Sendable () -> Void) -> CatchAllScheduledAction {
        let id = nextID
        nextID += 1
        items.append(Item(id: id, due: now + max(0, delay), action: action))
        return CatchAllScheduledAction { [weak self] in self?.items.removeAll { $0.id == id } }
    }

    func runDue() {
        advance(0)
    }

    /// Moves the clock forward, running each action at its due time, in order.
    func advance(_ seconds: Double) {
        let target = now + seconds
        while let item = items.filter({ $0.due <= target + 1e-9 }).min(by: { ($0.due, $0.id) < ($1.due, $1.id) }) {
            items.removeAll { $0.id == item.id }
            now = max(now, item.due)
            item.action()
        }
        now = max(now, target)
    }
}

/// Records what the coordinator asks of the run control, e.g. "attach uid-tv [5] held=true".
/// While `blocked`, the queue is stuck in a HAL call: `detach` and `stop()` time out, and work
/// queued after a timed-out detach waits for `unblock()`.
nonisolated final class FakeRunControl: CatchAllRunControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [String] = []
    private var _onRecord: (@Sendable (String) -> Void)?
    private var _blocked = false
    private var _stuckDetaches: [String] = []
    private var _queuedWork: [@Sendable () -> Void] = []
    private var _queuedWorkRequests = 0

    var onRebuild: (@Sendable (String, AudioDeviceID, CatchAllRunLogic.RebuildReason) -> Void)?
    var onServiceRestarted: (@Sendable () -> Void)?
    var onDevicesChanged: (@MainActor @Sendable ([AudioObjectID: ProcessDeviceReport]) -> Void)?
    var onProcessListChanged: (@MainActor @Sendable () -> Void)?

    var log: [String] { lock.withLock { _log } }
    /// Also gets every recorded line, for one ordered log across the fakes.
    var onRecord: (@Sendable (String) -> Void)? {
        get { lock.withLock { _onRecord } }
        set { lock.withLock { _onRecord = newValue } }
    }
    var blocked: Bool {
        get { lock.withLock { _blocked } }
        set { lock.withLock { _blocked = newValue } }
    }
    /// How often `afterQueuedWork` was called, run at once or queued: the coordinator has
    /// handled that many detach timeouts.
    var queuedWorkRequests: Int { lock.withLock { _queuedWorkRequests } }

    private func record(_ line: String) {
        let observer = lock.withLock {
            _log.append(line)
            return _onRecord
        }
        observer?(line)
    }

    func start() { record("start") }

    func stop() -> Bool {
        record("stop")
        return !blocked
    }

    func attach(_ handle: CatchAllIOHandle, deviceID: AudioDeviceID, excluded: Set<AudioObjectID>) {
        record("attach \(handle.deviceUID) \(excluded.sorted()) held=\(handle.state.held.load(ordering: .relaxed))")
    }

    func detach(_ handle: CatchAllIOHandle) async -> Bool {
        let line = "detach \(handle.deviceUID) \(handle.aggregateID)"
        let stuck = lock.withLock {
            if _blocked { _stuckDetaches.append(line) }
            return _blocked
        }
        record(stuck ? line + " timed out" : line)
        return !stuck
    }

    func afterQueuedWork(_ action: @escaping @Sendable () -> Void) {
        let runNow = lock.withLock {
            _queuedWorkRequests += 1
            if _blocked { _queuedWork.append(action) }
            return !_blocked
        }
        if runNow { action() }
    }

    /// The queue leaves its HAL call: the detaches that timed out run, then the work queued
    /// after them.
    func unblock() {
        let (detaches, work) = lock.withLock {
            _blocked = false
            defer {
                _stuckDetaches.removeAll()
                _queuedWork.removeAll()
            }
            return (_stuckDetaches, _queuedWork)
        }
        for line in detaches { record("queue ran \(line)") }
        for action in work { action() }
    }

    func setExcluded(_ handle: CatchAllIOHandle, _ excluded: Set<AudioObjectID>) {
        record("excluded \(handle.deviceUID) \(excluded.sorted())")
    }

    func prepareInclusion(_ processes: Set<AudioObjectID>, on uids: Set<String>) {
        record("prepare \(processes.sorted()) on \(uids.sorted())")
    }

    func setListed(_ processes: Set<AudioObjectID>) {
        record("listed \(processes.sorted())")
    }
}

/// The coordinator's IsAlive observations (E12): records each registration and release, e.g.
/// "observe 42" and "unobserve 42", and lets a test fire the handlers of a device as the HAL
/// listener does on main.
nonisolated final class FakeAliveObservers: @unchecked Sendable {
    /// Releases its registration when the coordinator drops it.
    nonisolated private final class Token {
        let release: @Sendable () -> Void
        init(release: @escaping @Sendable () -> Void) { self.release = release }
        deinit { release() }
    }

    private let lock = NSLock()
    private var _log: [String] = []
    private var _handlers: [Int: (device: AudioDeviceID, handler: @MainActor @Sendable () -> Void)] = [:]
    private var _nextID = 0
    private var _onRecord: (@Sendable (String) -> Void)?
    private var _onObserve: (@Sendable (AudioDeviceID) -> Void)?

    var log: [String] { lock.withLock { _log } }
    /// The devices observed now, sorted.
    var observed: [AudioDeviceID] { lock.withLock { _handlers.values.map(\.device).sorted() } }
    /// Also gets every recorded line, for one ordered log across the fakes.
    var onRecord: (@Sendable (String) -> Void)? {
        get { lock.withLock { _onRecord } }
        set { lock.withLock { _onRecord = newValue } }
    }
    /// Runs inside each registration, before the coordinator reads IsAlive (a device that
    /// comes back meanwhile).
    var onObserve: (@Sendable (AudioDeviceID) -> Void)? {
        get { lock.withLock { _onObserve } }
        set { lock.withLock { _onObserve = newValue } }
    }

    private func record(_ line: String) {
        let observer = lock.withLock {
            _log.append(line)
            return _onRecord
        }
        observer?(line)
    }

    func observe(_ device: AudioDeviceID, _ handler: @escaping @MainActor @Sendable () -> Void) -> AnyObject {
        let id = lock.withLock {
            _nextID += 1
            _handlers[_nextID] = (device, handler)
            return _nextID
        }
        record("observe \(device)")
        onObserve?(device)
        return Token { [weak self] in
            guard let self else { return }
            self.lock.withLock { self._handlers[id] = nil }
            self.record("unobserve \(device)")
        }
    }

    /// IsAlive of `device` changed: runs the handlers still registered for it.
    @MainActor
    func fire(_ device: AudioDeviceID) {
        let handlers = lock.withLock { _handlers.sorted { $0.key < $1.key }.filter { $0.value.device == device }.map(\.value.handler) }
        for handler in handlers { handler() }
    }
}

/// The system as the coordinator sees it: the TV (software volume) and AirPods (hardware),
/// FineTune's own process object 5, and processes 11-13.
final class CatchAllTestSystem {
    var outputs = [CatchAllOutput(uid: "uid-tv", id: 42), CatchAllOutput(uid: "uid-air", id: 43)]
    var tiers: [AudioDeviceID: VolumeControlTier] = [42: .software, 43: .hardware]
    var alive: Set<AudioDeviceID> = [42, 43]
    var aggregates: Set<AudioDeviceID> = []
    var virtuals: Set<AudioDeviceID> = []
    var streamCounts: [AudioDeviceID: Int] = [:]
    var gains: [AudioDeviceID: Float] = [42: 0.25]
    var processes: [AudioObjectID] = [5, 11, 12, 13]
    /// False: reading the process list fails.
    var processListReadable = true
    /// The next this many reads of the process list fail, then it reads again (a transient
    /// failure).
    var failingReads = 0
    var selfObject: AudioObjectID = 5
    var foreign: Set<AudioObjectID> = []
    var runningOutput: Set<AudioObjectID> = []
    var permission = true
    var excluded: Set<String> = []

    func readProcessList() -> [AudioObjectID]? {
        if failingReads > 0 {
            failingReads -= 1
            return nil
        }
        return processListReadable ? processes : nil
    }
}

final class CatchAllEventLog {
    var events: [CatchAllEvent] = []
}

final class CoordinatorTestBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

struct CatchAllCoordinatorRig {
    let coordinator: CatchAllCoordinator
    let system: CatchAllTestSystem
    let backend: FakeCatchAllBackend
    let runControl: FakeRunControl
    let clock: ManualCatchAllClock
    let events: CatchAllEventLog
    let aliveObservers: FakeAliveObservers

    var tv: CatchAllTapController? { coordinator.catchAll(for: "uid-tv") }

    /// Posts a process's Devices (nil: unreadable) and IsRunningOutput, as the run control does.
    func report(_ process: AudioObjectID, _ devices: [AudioDeviceID: OutputDeviceKind]?, running: Bool) {
        let report = ProcessDeviceReport(devices: devices.map { .known($0) } ?? .unknown, runningOutput: running)
        runControl.onDevicesChanged?([process: report])
    }

    var pushes: [String] { backend.log.filter { $0.hasPrefix("set") } }
}

func makeCatchAllRig(mode: CatchAllMode = .on, configure: (CatchAllTestSystem) -> Void = { _ in }) -> CatchAllCoordinatorRig {
    let system = CatchAllTestSystem()
    configure(system)
    let backend = FakeCatchAllBackend()
    backend.deviceIDs = Dictionary(uniqueKeysWithValues: system.outputs.map { ($0.uid, $0.id) })
    let runControl = FakeRunControl()
    let clock = ManualCatchAllClock()
    let aliveObservers = FakeAliveObservers()
    let coordinator = CatchAllCoordinator(environment: CatchAllEnvironment(
        mode: mode,
        excludedDeviceUIDs: system.excluded,
        backend: backend,
        runControl: runControl,
        clock: clock,
        processList: { system.readProcessList() },
        selfObject: { system.selfObject },
        foreign: { $0.intersection(system.foreign) },
        isRunningOutput: { system.runningOutput.contains($0) },
        listedOutputs: { system.outputs },
        isAlive: { system.alive.contains($0) },
        tier: { system.tiers[$0] ?? .hardware },
        isAggregate: { system.aggregates.contains($0) },
        isVirtual: { system.virtuals.contains($0) },
        outputStreamCount: { system.streamCounts[$0] ?? 1 },
        gain: { system.gains[$0] ?? 1 },
        permissionAuthorized: { system.permission },
        observeAlive: { aliveObservers.observe($0, $1) },
        tapExists: { _ in true }
    ))
    let events = CatchAllEventLog()
    coordinator.onEvent = { events.events.append($0) }
    return CatchAllCoordinatorRig(coordinator: coordinator, system: system, backend: backend,
                                  runControl: runControl, clock: clock, events: events,
                                  aliveObservers: aliveObservers)
}

/// Whether the catch-all's output is held (an atomic cannot go into `#expect` directly).
private func isHeld(_ controller: CatchAllTapController) -> Bool {
    controller.renderState.held.load(ordering: .relaxed)
}

private func makeApp(_ pid: pid_t, processes: [AudioObjectID]) -> AudioApp {
    AudioApp(id: pid, processObjectIDs: processes, name: "App \(pid)", icon: NSImage(), bundleID: "com.test.\(pid)")
}

// MARK: - Tests

@Suite("Catch-all coordinator")
@MainActor
struct CatchAllCoordinatorTests {

    // MARK: Phases and modes

    @Test("Mode on: live and dormant cover; retiring covers nothing but keeps affectsAudio")
    func phasesInModeOn() {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()

        #expect(coordinator.phase("uid-tv") == .live)
        #expect(coordinator.isLive("uid-tv"))
        #expect(coordinator.covers("uid-tv"))
        #expect(coordinator.affectsAudio)
        #expect(coordinator.catchAllDeviceUIDs == ["uid-tv"])
        // Hardware volume: no catch-all
        #expect(coordinator.phase("uid-air") == nil)
        #expect(!coordinator.isLive("uid-air"))
        #expect(!coordinator.covers("uid-air"))

        coordinator.setPhaseForTesting(.dormant, for: "uid-tv")
        #expect(coordinator.isLive("uid-tv"))
        #expect(coordinator.covers("uid-tv"))
        #expect(coordinator.catchAllDeviceUIDs == ["uid-tv"])

        coordinator.setPhaseForTesting(.retiring(caHeld: false), for: "uid-tv")
        #expect(!coordinator.isLive("uid-tv"))
        #expect(!coordinator.covers("uid-tv"))
        #expect(coordinator.affectsAudio)
        #expect(coordinator.catchAllDeviceUIDs.isEmpty)
        #expect(coordinator.takesRetirementHold(targets: ["uid-tv", "uid-air"]))
        #expect(!coordinator.takesRetirementHold(targets: ["uid-air"]))

        coordinator.setPhaseForTesting(.retiring(caHeld: true), for: "uid-tv")
        #expect(!coordinator.takesRetirementHold(targets: ["uid-tv"]))
        #expect(rig.events.events.contains(.phase(uid: "uid-tv", .retiring(caHeld: true))))
    }

    @Test("Observe: the catch-all is live but covers nothing and plays silence")
    func observeMode() throws {
        let rig = makeCatchAllRig(mode: .observe)
        rig.coordinator.start()

        #expect(rig.coordinator.isLive("uid-tv"))
        #expect(!rig.coordinator.covers("uid-tv"))
        #expect(!rig.coordinator.affectsAudio)
        #expect(try #require(rig.tv).renderState.observeOnly)
    }

    @Test("Mode off builds nothing")
    func modeOff() {
        let rig = makeCatchAllRig(mode: .off)
        rig.coordinator.start()

        #expect(rig.coordinator.phase("uid-tv") == nil)
        #expect(!rig.coordinator.affectsAudio)
        #expect(rig.backend.log.isEmpty)
    }

    @Test("While building, a catch-all counts for P5 but is neither live nor covering")
    func buildingPhase() {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let seen = LineLog()
        rig.backend.onWaitUntilReady = {
            MainActor.assumeIsolated {
                seen.add("building=\(coordinator.phase("uid-tv") == .building) live=\(coordinator.isLive("uid-tv")) "
                         + "covers=\(coordinator.covers("uid-tv")) p5=\(coordinator.catchAllDeviceUIDs.sorted())")
            }
        }

        coordinator.start()

        #expect(seen.all == [#"building=true live=false covers=false p5=["uid-tv"]"#])
        #expect(coordinator.phase("uid-tv") == .live)
    }

    @Test("An output that is not eligible gets no catch-all", arguments: [
        "hardware", "notAlive", "aggregate", "virtual", "twoStreams", "optedOut", "noPermission", "selfUnknown",
    ])
    func ineligible(reason: String) {
        let rig = makeCatchAllRig { system in
            switch reason {
            case "hardware": system.tiers[42] = .hardware
            case "notAlive": system.alive.remove(42)
            case "aggregate": system.aggregates.insert(42)
            case "virtual": system.virtuals.insert(42)
            case "twoStreams": system.streamCounts[42] = 2
            case "optedOut": system.excluded = ["uid-tv"]
            case "noPermission": system.permission = false
            case "selfUnknown": system.selfObject = .unknown
            default: Issue.record("unknown case \(reason)")
            }
        }

        rig.coordinator.start()

        #expect(rig.coordinator.phase("uid-tv") == nil)
        #expect(!rig.backend.log.contains("createTap"))
    }

    // MARK: Gain

    @Test("Gain: seeded from the device's level, followed on change, frozen while retiring")
    func gain() throws {
        let rig = makeCatchAllRig()
        rig.coordinator.start()
        let tv = try #require(rig.tv)
        #expect(tv.renderState.targetGain == 0.25)

        rig.system.gains[42] = 0.5
        rig.coordinator.deviceGainChanged(42)
        #expect(tv.renderState.targetGain == 0.5)

        rig.system.gains[42] = 0.6
        rig.coordinator.deviceGainChanged(43)
        #expect(tv.renderState.targetGain == 0.5)
        rig.coordinator.refreshGains()
        #expect(tv.renderState.targetGain == 0.6)

        rig.coordinator.setPhaseForTesting(.retiring(caHeld: false), for: "uid-tv")
        rig.system.gains[42] = 0.9
        rig.coordinator.deviceGainChanged(42)
        rig.coordinator.refreshGains()
        #expect(tv.renderState.targetGain == 0.6)
    }

    @Test("A level change during the build's wait reaches the new catch-all")
    func gainChangedDuringBuild() throws {
        let rig = makeCatchAllRig()
        let system = rig.system
        rig.backend.onWaitUntilReady = { MainActor.assumeIsolated { system.gains[42] = 0.4 } }

        rig.coordinator.start()

        #expect(try #require(rig.tv).renderState.targetGain == 0.4)
    }

    @Test("Gain goes by the listed ID even when Core Audio resolves the UID to another one")
    func gainByListedID() throws {
        let rig = makeCatchAllRig()
        rig.backend.deviceIDs["uid-tv"] = 99
        rig.system.gains[99] = 1

        rig.coordinator.start()
        let tv = try #require(rig.tv)
        #expect(tv.deviceID == 99)
        #expect(tv.renderState.targetGain == 0.25)

        rig.system.gains[42] = 0.5
        rig.coordinator.deviceGainChanged(42)
        #expect(tv.renderState.targetGain == 0.5)
    }

    // MARK: Claims and flush

    @Test("Claim changes are pushed once per turn with read-back; each changed list gets the next generation")
    func flushCoalescing() throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let owners = (1...5).map { FakeClaimOwner(pid: pid_t($0)) }

        let first = try #require(coordinator.setClaim(owners[0], Claim(processes: [11], coverage: .allDevices)))
        let second = try #require(coordinator.setClaim(owners[1], Claim(processes: [12], coverage: .device("uid-tv"))))
        #expect(first.generations == ["uid-tv": 1])
        #expect(second.generations == ["uid-tv": 2])
        #expect(rig.pushes.isEmpty)

        rig.clock.runDue()
        #expect(rig.pushes == ["set [5, 11, 12]"])
        #expect(rig.tv?.appliedExclusions == [5, 11, 12])
        #expect(rig.runControl.log.last == "excluded uid-tv [5, 11, 12]")

        // No list changes: the same claim, a process another claim holds, another device, a dead process
        #expect(coordinator.setClaim(owners[0], Claim(processes: [11], coverage: .allDevices)) == nil)
        #expect(coordinator.setClaim(owners[2], Claim(processes: [11], coverage: .device("uid-tv"))) == nil)
        #expect(coordinator.setClaim(owners[3], Claim(processes: [13], coverage: .device("uid-air"))) == nil)
        #expect(coordinator.setClaim(owners[4], Claim(processes: [99], coverage: .allDevices)) == nil)
        #expect(coordinator.removeClaim(ObjectIdentifier(owners[2])) == nil)

        let third = try #require(coordinator.removeClaim(ObjectIdentifier(owners[0])))
        #expect(third.generations == ["uid-tv": 3])
        rig.clock.runDue()
        #expect(rig.pushes == ["set [5, 11, 12]", "set [5, 12]"])
        withExtendedLifetime(owners) {}
    }

    @Test("changedDevices names live catch-alls whose list the proposed claim would change")
    func changedDevicesLiveOnly() {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let owner = FakeClaimOwner()
        let other = FakeClaimOwner(pid: 2)
        let mixdown = Claim(processes: [11], coverage: .allDevices)
        let duringBuild = LineLog()
        rig.backend.onWaitUntilReady = {
            MainActor.assumeIsolated {
                duringBuild.add("\(coordinator.changedDevices(owner: ObjectIdentifier(owner), proposed: mixdown).sorted())")
            }
        }
        coordinator.start()

        #expect(duringBuild.all == ["[]"])
        let id = ObjectIdentifier(owner)
        #expect(coordinator.changedDevices(owner: id, proposed: mixdown) == ["uid-tv"])
        #expect(coordinator.changedDevices(owner: id, proposed: Claim(processes: [11], coverage: .device("uid-air"))).isEmpty)
        #expect(coordinator.changedDevices(owner: id, proposed: Claim(processes: [99], coverage: .allDevices)).isEmpty)
        _ = coordinator.setClaim(other, mixdown)
        #expect(coordinator.changedDevices(owner: id, proposed: mixdown).isEmpty)
        withExtendedLifetime([owner, other]) {}
    }

    @Test("prepareInclusion goes to the run control")
    func prepareInclusion() {
        let rig = makeCatchAllRig()
        rig.coordinator.prepareInclusion(of: [12, 11], on: ["uid-tv"])
        rig.coordinator.prepareInclusion(of: [], on: ["uid-tv"])

        #expect(rig.runControl.log == [#"prepare [11, 12] on ["uid-tv"]"#])
    }

    @Test("appsChanged forwards the listed processes, and a process that died leaves the list")
    func appsChangedPrunesDead() {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        let owner = FakeClaimOwner()
        _ = coordinator.setClaim(owner, Claim(processes: [11, 12], coverage: .allDevices))
        rig.clock.runDue()
        #expect(rig.tv?.appliedExclusions == [5, 11, 12])

        rig.system.processes = [5, 11, 13]
        coordinator.appsChanged([makeApp(7, processes: [11, 13])])
        #expect(rig.runControl.log.contains("listed [11, 13]"))
        rig.clock.runDue()

        #expect(rig.tv?.appliedExclusions == [5, 11])
        withExtendedLifetime(owner) {}
    }

    // MARK: Applied waits

    @Test("A grow wait ends after G when the IO did not run since the push")
    func growWaitIdle() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let owner = FakeClaimOwner()
        let ticket = try #require(coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices)))
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .grow); done.value = true }
        #expect(await waitUntil { coordinator.pendingWaitCount == 1 })

        rig.clock.runDue()
        rig.clock.advance(0.129)
        await settle()
        #expect(!done.value)

        rig.clock.advance(0.001)
        #expect(await waitUntil { done.value })
        withExtendedLifetime(owner) {}
    }

    @Test("While the IO runs, a grow wait also needs two callbacks after the push, or ends as stalled after 500 ms")
    func growWaitCallbacks() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let state = try #require(rig.tv).renderState
        state.callbackCount.store(10, ordering: .relaxed)
        let owners = [FakeClaimOwner(), FakeClaimOwner(pid: 2)]

        let ticket = try #require(coordinator.setClaim(owners[0], Claim(processes: [11], coverage: .allDevices)))
        rig.clock.runDue()
        let first = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .grow); first.value = true }
        #expect(await waitUntil { coordinator.pendingWaitCount == 1 })
        state.callbackCount.store(11, ordering: .relaxed)
        rig.clock.advance(0.13)
        await settle()
        #expect(!first.value)
        state.callbackCount.store(12, ordering: .relaxed)
        rig.clock.advance(0.01)
        #expect(await waitUntil { first.value })

        let stalledTicket = try #require(coordinator.setClaim(owners[1], Claim(processes: [12], coverage: .allDevices)))
        rig.clock.runDue()
        let second = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(stalledTicket, .grow); second.value = true }
        #expect(await waitUntil { coordinator.pendingWaitCount == 1 })
        state.callbackCount.store(13, ordering: .relaxed)
        rig.clock.advance(0.499)
        await settle()
        #expect(!second.value)
        rig.clock.advance(0.001)
        #expect(await waitUntil { second.value })
        withExtendedLifetime(owners) {}
    }

    @Test("A shrink wait ends after S, whatever the IO does")
    func shrinkWait() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        let owner = FakeClaimOwner()
        _ = coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices))
        rig.clock.advance(1)

        let ticket = try #require(coordinator.removeClaim(ObjectIdentifier(owner)))
        rig.clock.runDue()
        #expect(rig.tv?.appliedExclusions == [5])
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .shrink); done.value = true }
        #expect(await waitUntil { coordinator.pendingWaitCount == 1 })
        try #require(rig.tv).renderState.callbackCount.store(50, ordering: .relaxed)
        rig.clock.advance(0.399)
        await settle()
        #expect(!done.value)

        rig.clock.advance(0.001)
        #expect(await waitUntil { done.value })
        withExtendedLifetime(owner) {}
    }

    @Test("A wait does not end before the flush has pushed its generation")
    func waitNeedsPush() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let owner = FakeClaimOwner()
        let ticket = try #require(coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices)))
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .grow); done.value = true }
        #expect(await waitUntil { coordinator.pendingWaitCount == 1 })
        await settle()
        #expect(!done.value)
        #expect(rig.tv?.appliedExclusions == [5])

        // The flush is due now, the margin 130 ms after it
        rig.clock.advance(0.13)
        #expect(await waitUntil { done.value })
        #expect(rig.tv?.appliedExclusions == [5, 11])
        withExtendedLifetime(owner) {}
    }

    // MARK: Held start

    @Test("A new catch-all attaches held and opens at once when it was built with the desired list")
    func releasedAtOnce() throws {
        let rig = makeCatchAllRig()
        let owner = FakeClaimOwner()
        // No catch-all yet: nothing to wait for
        #expect(rig.coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices)) == nil)

        rig.coordinator.start()

        let tv = try #require(rig.tv)
        #expect(tv.appliedExclusions == [5, 11])
        #expect(rig.runControl.log.contains("attach uid-tv [5, 11] held=true"))
        #expect(!isHeld(tv))
        #expect(rig.events.events.contains(.released(uid: "uid-tv")))
        withExtendedLifetime(owner) {}
    }

    @Test("A claim set during the build keeps the new catch-all held until its list has applied")
    func heldUntilApplied() throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let owner = FakeClaimOwner()
        let tickets = LineLog()
        rig.backend.onWaitUntilReady = {
            MainActor.assumeIsolated {
                // A per-app tap created during the build's wait (V4): no live catch-all, no ticket
                let ticket = coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices))
                tickets.add(ticket == nil ? "nil" : "ticket")
            }
        }

        coordinator.start()
        let tv = try #require(rig.tv)
        #expect(tickets.all == ["nil"])
        #expect(tv.appliedExclusions == [5])
        #expect(isHeld(tv))

        rig.clock.runDue()
        #expect(tv.appliedExclusions == [5, 11])
        rig.clock.advance(0.129)
        #expect(isHeld(tv))
        rig.clock.advance(0.001)
        #expect(!isHeld(tv))

        let released = try #require(rig.events.events.firstIndex(of: .released(uid: "uid-tv")))
        let pushed = try #require(rig.events.events.firstIndex(of: .pushed(uid: "uid-tv", excluded: [5, 11])))
        #expect(pushed < released)
    }

    // MARK: I1

    @Test("I1: an exclusion left without a claim after a push failed twice is repaired in the same flush; the wait ends when the rebuild with the desired list takes over")
    func invariantRepair() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        let owners = [FakeClaimOwner(), FakeClaimOwner(pid: 2)]
        _ = coordinator.setClaim(owners[0], Claim(processes: [11], coverage: .allDevices))
        rig.clock.advance(1)
        #expect(rig.tv?.appliedExclusions == [5, 11])
        let excludedBefore = rig.runControl.log.filter { $0.hasPrefix("excluded") }

        // 11 leaves and 12 joins in one turn; the push of [5, 12] and its retry fail
        rig.backend.failSets = 2
        let old = try #require(rig.tv)
        _ = coordinator.removeClaim(ObjectIdentifier(owners[0]))
        let ticket = try #require(coordinator.setClaim(owners[1], Claim(processes: [12], coverage: .allDevices)))
        rig.clock.runDue()

        #expect(old.appliedExclusions == [5])
        #expect(Array(rig.events.events.suffix(4)) == [
            .pushFailed(uid: "uid-tv", excluded: [5, 12]),
            .pushFailed(uid: "uid-tv", excluded: [5, 12]),
            .pushed(uid: "uid-tv", excluded: [5]),
            .repaired(uid: "uid-tv", removed: [11]),
        ])
        // The run control hears only about lists that applied
        #expect(rig.runControl.log.filter { $0.hasPrefix("excluded") } == excludedBefore + ["excluded uid-tv [5]"])

        // The push failed after its retry, so the next turn rebuilt with [5, 12] (E), and the wait
        // ends when the new catch-all takes over. Which generation the repair recorded is moot
        // here: the rebuild resets the pushes before any wait could resolve against it.
        let rebuilt = try #require(rig.tv)
        #expect(rebuilt !== old)
        #expect(rebuilt.appliedExclusions == [5, 12])
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .grow); done.value = true }
        #expect(await waitUntil { coordinator.pendingWaitCount == 1 })
        await settle()
        #expect(!done.value)
        rig.clock.advance(0.2)
        #expect(await waitUntil { done.value })
        withExtendedLifetime(owners) {}
    }

    @Test("A failed push is retried once in the same flush, and its wait ends after G from the retry")
    func pushRetried() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let owner = FakeClaimOwner()
        rig.backend.failSets = 1

        let ticket = try #require(coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices)))
        rig.clock.runDue()

        #expect(rig.pushes == ["set [5, 11]", "set [5, 11]"])
        #expect(rig.tv?.appliedExclusions == [5, 11])
        #expect(Array(rig.events.events.suffix(2)) == [
            .pushFailed(uid: "uid-tv", excluded: [5, 11]),
            .pushed(uid: "uid-tv", excluded: [5, 11]),
        ])
        #expect(rig.runControl.log.filter { $0.hasPrefix("excluded") } == ["excluded uid-tv [5, 11]"])
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .grow); done.value = true }
        #expect(await waitUntil { coordinator.pendingWaitCount == 1 })
        rig.clock.advance(0.129)
        await settle()
        #expect(!done.value)
        rig.clock.advance(0.001)
        #expect(await waitUntil { done.value })
        withExtendedLifetime(owner) {}
    }

    @Test("A push whose read-back failed is confirmed by its retry: a later claim change that leaves the list as it is ends its wait at once")
    func retryConfirmsList() async throws {
        let rig = makeCatchAllRig { $0.foreign = [13] }
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let owners = [FakeClaimOwner(), FakeClaimOwner(pid: 2)]
        rig.backend.failReadBacks = 1
        _ = coordinator.setClaim(owners[0], Claim(processes: [11], coverage: .allDevices))
        rig.clock.runDue()
        #expect(rig.pushes == ["set [5, 11, 13]", "set [5, 11, 13]"])
        #expect(rig.tv?.appliedExclusions == [5, 11, 13])
        rig.clock.advance(1)

        // Another user's process is excluded anyway: claiming it changes no list
        let ticket = try #require(coordinator.setClaim(owners[1], Claim(processes: [13], coverage: .allDevices)))
        rig.clock.runDue()
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .grow); done.value = true }
        #expect(await waitUntil { done.value })
        #expect(rig.pushes.count == 2)
        #expect(rig.backend.log.filter { $0 == "createTap" }.count == 1)
        withExtendedLifetime(owners) {}
    }

    @Test("I1: other users' processes stay excluded; a list that holds them is pushed once")
    func invariantAllowsForeign() {
        let rig = makeCatchAllRig { $0.foreign = [13] }
        let coordinator = rig.coordinator
        coordinator.start()
        #expect(rig.tv?.appliedExclusions == [5, 13])
        let owner = FakeClaimOwner()

        _ = coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices))
        rig.clock.runDue()
        rig.runControl.onProcessListChanged?()
        rig.clock.runDue()
        rig.clock.advance(1)

        #expect(rig.pushes == ["set [5, 11, 13]"])
        #expect(!rig.events.events.contains { if case .repaired = $0 { true } else { false } })
        withExtendedLifetime(owner) {}
    }

    @Test("A claim whose owner went away without removing it is dropped at the next process-list change")
    func releasedOwnerPruned() {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        var owner: FakeClaimOwner? = FakeClaimOwner()
        _ = coordinator.setClaim(owner!, Claim(processes: [11], coverage: .allDevices))
        rig.clock.runDue()
        #expect(rig.tv?.appliedExclusions == [5, 11])

        owner = nil
        rig.runControl.onProcessListChanged?()
        rig.clock.runDue()

        #expect(rig.tv?.appliedExclusions == [5])
        #expect(!rig.events.events.contains { if case .repaired = $0 { true } else { false } })
    }

    @Test("Generations count per device: a claim on one device bumps only that one")
    func generationsPerDevice() throws {
        let rig = makeCatchAllRig { system in
            system.outputs.append(CatchAllOutput(uid: "uid-tv2", id: 44))
            system.tiers[44] = .software
            system.alive.insert(44)
        }
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let owners = [FakeClaimOwner(), FakeClaimOwner(pid: 2), FakeClaimOwner(pid: 3)]

        let first = try #require(coordinator.setClaim(owners[0], Claim(processes: [11], coverage: .device("uid-tv"))))
        let second = try #require(coordinator.setClaim(owners[1], Claim(processes: [12], coverage: .allDevices)))
        let third = try #require(coordinator.setClaim(owners[2], Claim(processes: [13], coverage: .device("uid-tv2"))))

        #expect(first.generations == ["uid-tv": 1])
        #expect(second.generations == ["uid-tv": 2, "uid-tv2": 1])
        #expect(third.generations == ["uid-tv2": 2])
        rig.clock.runDue()
        #expect(rig.tv?.appliedExclusions == [5, 11, 12])
        #expect(coordinator.catchAll(for: "uid-tv2")?.appliedExclusions == [5, 12, 13])
        withExtendedLifetime(owners) {}
    }

    @Test("A process leaving a building catch-all's list gets a ticket; its shrink wait ends S after the push that follows the build")
    func shrinkDuringBuild() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let owner = FakeClaimOwner()
        _ = coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices))
        let tickets = CoordinatorTestBox<[ApplyTicket?]>([])
        rig.backend.onWaitUntilReady = {
            MainActor.assumeIsolated {
                // The tap already excludes 11; its per-app tap goes away (B)
                tickets.value.append(coordinator.removeClaim(ObjectIdentifier(owner)))
            }
        }

        coordinator.start()
        let ticket = try #require(tickets.value.first ?? nil)
        #expect(ticket.generations == ["uid-tv": 1])
        let tv = try #require(rig.tv)
        #expect(tv.appliedExclusions == [5, 11])
        // 11 is excluded, so nothing is doubled: the output opens at once
        #expect(!isHeld(tv))

        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .shrink); done.value = true }
        #expect(await waitUntil { coordinator.pendingWaitCount == 1 })
        rig.clock.runDue()
        #expect(tv.appliedExclusions == [5])
        rig.clock.advance(0.399)
        await settle()
        #expect(!done.value)
        rig.clock.advance(0.001)
        #expect(await waitUntil { done.value })
    }

    @Test("A shrink ticket for a build that then fails ends at once: no catch-all is left")
    func shrinkDuringFailedBuild() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let backend = rig.backend
        let owner = FakeClaimOwner()
        _ = coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices))
        let tickets = CoordinatorTestBox<[ApplyTicket?]>([])
        backend.onWaitUntilReady = {
            MainActor.assumeIsolated {
                tickets.value.append(coordinator.removeClaim(ObjectIdentifier(owner)))
                backend.failAt = .ioProc
            }
        }

        coordinator.start()

        let ticket = try #require(tickets.value.first ?? nil)
        #expect(coordinator.phase("uid-tv") == nil)
        #expect(rig.events.events.contains { if case .buildFailed(uid: "uid-tv", _) = $0 { true } else { false } })
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .shrink); done.value = true }
        #expect(await waitUntil { done.value })
        #expect(coordinator.pendingWaitCount == 0)
    }

    @Test("A new catch-all whose list holds a dead or foreign process beyond the claims still opens")
    func releaseIgnoresExtraExclusions() throws {
        let rig = makeCatchAllRig { $0.foreign = [13] }
        let coordinator = rig.coordinator
        let system = rig.system
        rig.backend.onWaitUntilReady = {
            // 13 quits during the wait: the built list [5, 13] holds a dead process
            MainActor.assumeIsolated { system.processes = [5, 11, 12] }
        }

        coordinator.start()

        let tv = try #require(rig.tv)
        #expect(tv.appliedExclusions == [5, 13])
        #expect(!isHeld(tv))
        rig.clock.runDue()
        #expect(tv.appliedExclusions == [5])
    }

    @Test("The flush skips a retiring catch-all; a claim on it gets only a retirement ticket")
    func retiringSkipped() {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.setPhaseForTesting(.retiring(caHeld: false), for: "uid-tv")
        let owner = FakeClaimOwner()

        let ticket = coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices))
        #expect(ticket?.generations == ["uid-tv": 0])
        rig.clock.runDue()

        #expect(rig.pushes.isEmpty)
        #expect(rig.tv?.appliedExclusions == [5])
        withExtendedLifetime(owner) {}
    }

    @Test("An unreadable process list keeps every applied list, never builds, and the flush tries again")
    func unreadableProcessList() async throws {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let owners = [FakeClaimOwner(), FakeClaimOwner(pid: 2)]
        _ = coordinator.setClaim(owners[0], Claim(processes: [11], coverage: .allDevices))
        rig.clock.runDue()
        #expect(rig.tv?.appliedExclusions == [5, 11])

        rig.system.processListReadable = false
        #expect(coordinator.processIsLive(11))
        #expect(coordinator.processIsLive(99))
        let ticket = try #require(coordinator.setClaim(owners[1], Claim(processes: [12], coverage: .allDevices)))
        rig.runControl.onProcessListChanged?()
        rig.clock.runDue()
        #expect(rig.tv?.appliedExclusions == [5, 11])

        rig.system.processListReadable = true
        rig.clock.advance(0.1)
        #expect(rig.tv?.appliedExclusions == [5, 11, 12])
        rig.clock.advance(0.13)
        let done = CoordinatorTestBox(false)
        Task { await coordinator.waitApplied(ticket, .grow); done.value = true }
        #expect(await waitUntil { done.value })
        withExtendedLifetime(owners) {}
    }

    @Test("No catch-all is built while the process list cannot be read")
    func unreadableProcessListAtBuild() {
        let rig = makeCatchAllRig { $0.processListReadable = false }

        rig.coordinator.start()

        #expect(rig.coordinator.phase("uid-tv") == nil)
        #expect(!rig.backend.log.contains("createTap"))
        #expect(rig.events.events.contains(.buildFailed(uid: "uid-tv", reason: "process list unreadable")))
    }

    @Test("The flush and the I1 check skip a dormant or retiring catch-all",
          arguments: [CatchAllPhase.dormant, .retiring(caHeld: false)])
    func inactiveSkipped(phase: CatchAllPhase) {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        let owner = FakeClaimOwner()
        _ = coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices))
        rig.clock.runDue()
        coordinator.setPhaseForTesting(phase, for: "uid-tv")
        let pushes = rig.pushes

        // A dormant catch-all's tap still excludes 11: the shrink gets a ticket that waits for
        // its rebuild, R or G. A retiring one gives none
        let ticket = coordinator.removeClaim(ObjectIdentifier(owner))
        #expect(ticket?.devices == (phase == .dormant ? Set(["uid-tv"]) : nil))
        rig.clock.runDue()

        #expect(rig.pushes == pushes)
        #expect(rig.tv?.appliedExclusions == [5, 11])
        #expect(!rig.events.events.contains { if case .repaired = $0 { true } else { false } })
        withExtendedLifetime(owner) {}
    }

    // MARK: C9

    @Test("C9: an aggregate or virtual device that is not D-like makes the processes foreign at once")
    func elsewhereAtOnce() {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        coordinator.appsChanged([makeApp(7, processes: [11]), makeApp(8, processes: [12])])
        rig.clock.runDue()
        let reevaluations = LineLog()
        coordinator.onCoverageMayHaveChanged = { reevaluations.add("reevaluate") }

        rig.report(11, [77: .aggregateOrVirtual], running: true)
        rig.report(12, [42: .plain, 77: .aggregateOrVirtual], running: false)

        #expect(coordinator.playsElsewhere([11], target: "uid-tv"))
        #expect(coordinator.playsElsewhere([12], target: "uid-tv"))
        #expect(reevaluations.all.isEmpty)
        rig.clock.runDue()
        #expect(reevaluations.all == ["reevaluate"])
        #expect(rig.events.events.contains(.playsElsewhere(pid: 7, uid: "uid-tv")))
        #expect(rig.events.events.contains(.playsElsewhere(pid: 8, uid: "uid-tv")))
    }

    @Test("C9: another plain device or an unresolvable ID makes them foreign after 500 ms, then the gate runs again")
    func elsewhereAfterSettle() {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        coordinator.appsChanged([makeApp(7, processes: [11]), makeApp(8, processes: [12])])
        rig.clock.runDue()
        let reevaluations = LineLog()
        coordinator.onCoverageMayHaveChanged = { reevaluations.add("reevaluate") }

        rig.report(11, [43: .plain], running: true)
        rig.report(12, [99: .unresolvable], running: true)
        rig.clock.advance(0.499)
        #expect(!coordinator.playsElsewhere([11], target: "uid-tv"))
        #expect(!coordinator.playsElsewhere([12], target: "uid-tv"))
        #expect(reevaluations.all.isEmpty)

        rig.clock.advance(0.001)
        #expect(coordinator.playsElsewhere([11], target: "uid-tv"))
        #expect(coordinator.playsElsewhere([12], target: "uid-tv"))
        #expect(reevaluations.all == ["reevaluate"])
    }

    @Test("C9: an empty or unknown list counts only while the process runs output, 500 ms after the pair changed")
    func elsewhereEmptyList() {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()

        rig.report(11, [:], running: false)
        rig.report(12, nil, running: false)
        rig.clock.advance(1)
        #expect(!coordinator.playsElsewhere([11], target: "uid-tv"))
        #expect(!coordinator.playsElsewhere([12], target: "uid-tv"))

        rig.report(11, [:], running: true)
        rig.report(12, nil, running: true)
        rig.clock.advance(0.499)
        #expect(!coordinator.playsElsewhere([11], target: "uid-tv"))
        #expect(!coordinator.playsElsewhere([12], target: "uid-tv"))
        rig.clock.advance(0.001)
        #expect(coordinator.playsElsewhere([11], target: "uid-tv"))
        #expect(coordinator.playsElsewhere([12], target: "uid-tv"))
    }

    @Test("C9: D plus plain devices stays covered, also across the processes of one app")
    func elsewhereWithTarget() {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()

        rig.report(11, [42: .plain, 43: .plain], running: true)
        rig.report(12, [43: .plain], running: true)
        rig.clock.advance(1)

        #expect(!coordinator.playsElsewhere([11], target: "uid-tv"))
        #expect(!coordinator.playsElsewhere([11, 12], target: "uid-tv"))
        #expect(coordinator.playsElsewhere([12], target: "uid-tv"))
        // Only an output with a catch-all is asked about
        #expect(!coordinator.playsElsewhere([12], target: "uid-air"))
    }

    @Test("C9: the devices a routing change came from count as D-like for 2 s")
    func routingGrace() {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        coordinator.appsChanged([makeApp(7, processes: [11])])
        rig.clock.runDue()
        let reevaluations = LineLog()
        coordinator.onCoverageMayHaveChanged = { reevaluations.add("reevaluate") }

        coordinator.noteRouting(from: ["uid-air"], to: "uid-tv")
        rig.report(11, [43: .plain], running: true)
        rig.clock.advance(1.999)
        #expect(!coordinator.playsElsewhere([11], target: "uid-tv"))
        #expect(reevaluations.all.isEmpty)

        rig.clock.advance(0.001)
        #expect(coordinator.playsElsewhere([11], target: "uid-tv"))
        #expect(reevaluations.all == ["reevaluate"])
    }

    @Test("C9: a routing change away from a device that is no longer listed still gives it the grace")
    func routingGraceForRemovedDevice() {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        coordinator.appsChanged([makeApp(7, processes: [11])])
        rig.clock.runDue()

        // The AirPods disconnect; their streams still name the old ID, now unresolvable
        rig.system.outputs.removeAll { $0.uid == "uid-air" }
        coordinator.noteRouting(from: ["uid-air"], to: "uid-tv")
        rig.report(11, [43: .unresolvable], running: true)
        rig.clock.advance(1.999)
        #expect(!coordinator.playsElsewhere([11], target: "uid-tv"))

        rig.clock.advance(0.001)
        #expect(coordinator.playsElsewhere([11], target: "uid-tv"))
    }

    @Test("C9: an app settles when its whole process set does, and the gate runs then, not earlier")
    func elsewherePerApp() {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        coordinator.appsChanged([makeApp(7, processes: [11, 12])])
        rig.clock.runDue()
        let reevaluations = LineLog()
        coordinator.onCoverageMayHaveChanged = { reevaluations.add("reevaluate") }

        rig.report(11, [43: .plain], running: true)
        rig.clock.advance(0.3)
        rig.report(12, [:], running: false)
        rig.clock.advance(0.2)
        #expect(!coordinator.playsElsewhere([11, 12], target: "uid-tv"))
        #expect(reevaluations.all.isEmpty)

        rig.clock.advance(0.3)
        #expect(coordinator.playsElsewhere([11, 12], target: "uid-tv"))
        #expect(reevaluations.all == ["reevaluate"])
        #expect(rig.events.events.filter { if case .playsElsewhere = $0 { true } else { false } } == [
            .playsElsewhere(pid: 7, uid: "uid-tv"),
        ])
    }

    @Test("C9: processes no app lists (FineTune, daemons) never trigger the gate")
    func elsewhereUnlistedIgnored() {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        coordinator.appsChanged([makeApp(7, processes: [11])])
        rig.clock.runDue()
        let reevaluations = LineLog()
        coordinator.onCoverageMayHaveChanged = { reevaluations.add("reevaluate") }

        // FineTune's own process runs the catch-all's aggregate; a daemon plays elsewhere
        rig.report(5, [200: .aggregateOrVirtual], running: true)
        rig.report(13, [43: .plain], running: true)
        rig.clock.advance(1)

        #expect(reevaluations.all.isEmpty)
        #expect(!rig.events.events.contains { if case .playsElsewhere = $0 { true } else { false } })
    }

    @Test("C9: an app listed after its report is evaluated at once")
    func elsewhereNewlyListed() {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        rig.clock.runDue()
        let reevaluations = LineLog()
        coordinator.onCoverageMayHaveChanged = { reevaluations.add("reevaluate") }
        rig.report(11, [77: .aggregateOrVirtual], running: true)
        rig.clock.runDue()
        #expect(reevaluations.all.isEmpty)

        coordinator.appsChanged([makeApp(7, processes: [11])])
        rig.clock.runDue()

        #expect(reevaluations.all == ["reevaluate"])
    }

    @Test("mayPlay: the cached Devices name the device or a device that is not plain")
    func mayPlay() {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        coordinator.start()
        #expect(!coordinator.mayPlay([11], on: "uid-tv"))

        rig.report(11, [42: .plain], running: false)
        rig.report(12, [43: .plain], running: true)
        rig.report(13, [77: .aggregateOrVirtual], running: false)
        rig.report(14, [99: .unresolvable], running: false)
        rig.report(15, [:], running: true)
        rig.report(16, nil, running: true)

        #expect(coordinator.mayPlay([11], on: "uid-tv"))
        #expect(!coordinator.mayPlay([12], on: "uid-tv"))
        #expect(coordinator.mayPlay([12], on: "uid-air"))
        #expect(coordinator.mayPlay([13], on: "uid-tv"))
        #expect(coordinator.mayPlay([14], on: "uid-tv"))
        #expect(!coordinator.mayPlay([15], on: "uid-tv"))
        #expect(!coordinator.mayPlay([16], on: "uid-tv"))
        #expect(coordinator.mayPlay([12, 11], on: "uid-tv"))
    }

    // MARK: Decisions

    @Test("A decision is reported only when it changes for the app")
    func decisionsOnChange() {
        let rig = makeCatchAllRig()
        let app = makeApp(7, processes: [11])

        rig.coordinator.noteDecision(app, target: "uid-tv", .coveredByCatchAll)
        rig.coordinator.noteDecision(app, target: "uid-tv", .coveredByCatchAll)
        rig.coordinator.noteDecision(app, target: "uid-tv", .tap([.appGain]))

        #expect(rig.events.events == [
            .decision(pid: 7, uid: "uid-tv", .coveredByCatchAll),
            .decision(pid: 7, uid: "uid-tv", .tap([.appGain])),
        ])
    }

    // MARK: Next turn and reentrancy

    @Test("reconcile and requestReevaluation share one next-turn task, which builds before it calls back")
    func sharedTurn() {
        let rig = makeCatchAllRig { $0.permission = false }
        let coordinator = rig.coordinator
        coordinator.start()
        #expect(coordinator.phase("uid-tv") == nil)
        rig.system.permission = true
        let backend = rig.backend
        let log = LineLog()
        coordinator.onCoverageMayHaveChanged = { log.add("reevaluate built=\(backend.log.contains("createTap"))") }

        coordinator.reconcile()
        coordinator.requestReevaluation()
        coordinator.reconcile()
        #expect(rig.clock.pendingCount == 1)
        #expect(backend.log.isEmpty)

        rig.clock.runDue()
        #expect(log.all == ["reevaluate built=true"])
        #expect(coordinator.phase("uid-tv") == .live)
        // The build's own re-evaluation request is served by this turn, not by an extra one
        #expect(rig.clock.pendingCount == 0)
    }

    @Test("A build's wait that runs reconcile, a claim change and the flush: one build per device, no push to the building catch-all")
    func reentrancy() throws {
        let rig = makeCatchAllRig { system in
            system.outputs.append(CatchAllOutput(uid: "uid-tv2", id: 44))
            system.tiers[44] = .software
            system.alive.insert(44)
        }
        let coordinator = rig.coordinator
        let backend = rig.backend
        let clock = rig.clock
        let owner = FakeClaimOwner()
        let misses = LineLog()
        backend.onWaitUntilReady = {
            MainActor.assumeIsolated {
                let building = backend.lastTap
                coordinator.reconcile()
                _ = coordinator.setClaim(owner, Claim(processes: [11], coverage: .allDevices))
                // What a spin of the main run loop runs: the next turn and the flush
                clock.runDue()
                if backend.sets(on: building) > 0 { misses.add("pushed to building tap \(building)") }
            }
        }

        coordinator.start()

        let log = backend.log
        #expect(log.filter { $0 == "createTap" }.count == 2)
        // The nested reconcile waited: the second build starts after the first one ended
        let secondBuild = try #require(log.indices.last { log[$0] == "createTap" })
        let firstBuildEnd = try #require(log.firstIndex(of: "disableInputs"))
        #expect(firstBuildEnd < secondBuild)
        #expect(misses.all.isEmpty)

        clock.runDue()
        #expect(backend.log.filter { $0 == "createTap" }.count == 2)
        #expect(coordinator.phase("uid-tv") == .live)
        #expect(coordinator.phase("uid-tv2") == .live)
        #expect(rig.tv?.appliedExclusions == [5, 11])
        #expect(coordinator.catchAll(for: "uid-tv2")?.appliedExclusions == [5, 11])
        withExtendedLifetime(owner) {}
    }

    @Test("A turn requested while the callback spins runs after it, never nested")
    func turnDuringCallback() {
        let rig = makeCatchAllRig { $0.permission = false }
        let coordinator = rig.coordinator
        let backend = rig.backend
        let clock = rig.clock
        let system = rig.system
        coordinator.start()
        let depth = CoordinatorTestBox(0)
        let log = LineLog()
        coordinator.onCoverageMayHaveChanged = {
            depth.value += 1
            defer { depth.value -= 1 }
            log.add("callback depth=\(depth.value) built=\(backend.log.contains("createTap"))")
            guard log.all.count == 1 else { return }
            // What an activate's spin can run: a reconcile, a re-evaluation and the next turns
            system.permission = true
            coordinator.reconcile()
            coordinator.requestReevaluation()
            clock.runDue()
            log.add("after spin built=\(backend.log.contains("createTap"))")
        }

        coordinator.requestReevaluation()
        clock.runDue()

        #expect(log.all == [
            "callback depth=1 built=false",
            "after spin built=false",
            "callback depth=1 built=true",
        ])
        #expect(coordinator.phase("uid-tv") == .live)
    }

    @Test("After stop() the gate is not called back, and a build whose wait ran stop() is destroyed")
    func stopDuringBuild() async {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        let calledBack = CoordinatorTestBox(false)
        coordinator.onCoverageMayHaveChanged = { calledBack.value = true }
        rig.backend.onWaitUntilReady = { MainActor.assumeIsolated { coordinator.stop() } }

        coordinator.start()
        coordinator.requestReevaluation()
        rig.clock.advance(1)

        #expect(coordinator.phase("uid-tv") == nil)
        #expect(!rig.runControl.log.contains { $0.hasPrefix("attach") })
        #expect(await waitUntil { rig.backend.log.contains { $0.hasPrefix("destroy") } })
        #expect(!calledBack.value)
    }

    @Test("The run control's callbacks are set once, before it starts; it starts once per start() after a stop()")
    func runControlWiring() {
        let rig = makeCatchAllRig()
        let coordinator = rig.coordinator
        #expect(rig.runControl.onDevicesChanged != nil)
        #expect(rig.runControl.onProcessListChanged != nil)

        coordinator.start()
        coordinator.start()
        coordinator.stop()
        coordinator.start()

        #expect(rig.runControl.log.filter { $0 == "start" || $0 == "stop" } == ["start", "stop", "start"])
    }

    // MARK: Noop and fake

    @Test("Noop: not enabled, answers empty, false and nil, never calls back and never suspends")
    func noop() async {
        let noop = NoopCatchAllCoordinator()
        let owner = FakeClaimOwner()
        let app = makeApp(7, processes: [11])
        let calledBack = CoordinatorTestBox(false)
        noop.onCoverageMayHaveChanged = { calledBack.value = true }
        noop.onCoverageWillEnd = { _ in
            calledBack.value = true
            return true
        }
        noop.onEvent = { _ in calledBack.value = true }

        #expect(!noop.isEnabled)
        #expect(!noop.affectsAudio)
        #expect(noop.catchAllDeviceUIDs.isEmpty)
        #expect(noop.phase("uid-tv") == nil)
        #expect(!noop.isLive("uid-tv"))
        #expect(!noop.covers("uid-tv"))
        #expect(!noop.playsElsewhere([11], target: "uid-tv"))
        #expect(!noop.mayPlay([11], on: "uid-tv"))
        #expect(noop.changedDevices(owner: ObjectIdentifier(owner), proposed: Claim(processes: [11], coverage: .allDevices)).isEmpty)
        #expect(noop.setClaim(owner, Claim(processes: [11], coverage: .allDevices)) == nil)
        #expect(noop.removeClaim(ObjectIdentifier(owner)) == nil)
        #expect(!noop.takesRetirementHold(targets: ["uid-tv"]))
        #expect(!noop.processIsLive(11))
        #expect(!noop.isRunningOutput(11))

        noop.start()
        noop.reconcile()
        noop.requestReevaluation()
        noop.refreshGains()
        noop.appsChanged([app])
        noop.deviceListRefreshed()
        noop.deviceGainChanged(42)
        noop.formatChanging(uid: "uid-tv")
        noop.formatUnchanged(uid: "uid-tv")
        noop.noteDecision(app, target: "uid-tv", .coveredByCatchAll)
        noop.noteRouting(from: ["uid-air"], to: "uid-tv")
        noop.prepareInclusion(of: [11], on: ["uid-tv"])
        noop.stop()

        let ranMeanwhile = CoordinatorTestBox(false)
        Task { ranMeanwhile.value = true }
        await noop.formatChanged(uid: "uid-tv")
        await noop.waitApplied(ApplyTicket(generations: ["uid-tv": 1]), .grow)
        #expect(!ranMeanwhile.value)

        await settle()
        #expect(ranMeanwhile.value)
        #expect(!calledBack.value)
    }

    @Test("The fake coordinator calls back once in the next turn after requestReevaluation")
    func fakeReevaluates() async {
        let fake = FakeCatchAllCoordinator()
        let count = CoordinatorTestBox(0)
        fake.onCoverageMayHaveChanged = { count.value += 1 }

        fake.requestReevaluation()
        fake.requestReevaluation()
        #expect(count.value == 0)

        #expect(await waitUntil { count.value == 1 })
        await settle()
        #expect(count.value == 1)
        #expect(fake.calls == ["requestReevaluation", "requestReevaluation"])
    }
}
