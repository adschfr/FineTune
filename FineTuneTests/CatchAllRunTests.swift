// FineTuneTests/CatchAllRunTests.swift
//
// When the catch-all's IO runs: started as soon as a covered process plays, suspended 10 s
// after the last need, never while its input is audible, restarted by a re-read after a
// stop, rebuilt when its IO dies. First the pure logic, then the queue driver with fakes.

import AudioToolbox
import Foundation
import Synchronization
import Testing
@testable import FineTune

@Suite("Catch-all run logic")
struct CatchAllRunLogicTests {

    private let tv = "uid-tv"

    private func attached(excluded: Set<AudioObjectID> = [5], live: Set<AudioObjectID> = [5, 11, 12]) -> CatchAllRunLogic {
        var logic = CatchAllRunLogic()
        _ = logic.setProcesses(live, now: 0)
        _ = logic.attach(tv, deviceID: 42, excluded: excluded, now: 0)
        return logic
    }

    @Test("A covered process starting output starts the catch-all")
    func coveredOutputStarts() {
        var logic = attached()
        #expect(logic.setRunningOutput(11, true, now: 1) == [.start(tv)])
        #expect(logic.isRunning(tv))
    }

    @Test("Excluded processes, FineTune itself and dead processes do not start it")
    func excludedDoNotStart() {
        var logic = attached(excluded: [5, 12])
        #expect(logic.setRunningOutput(5, true, now: 1).isEmpty)
        #expect(logic.setRunningOutput(12, true, now: 1).isEmpty)
        #expect(logic.setRunningOutput(99, true, now: 1).isEmpty)
        #expect(!logic.isRunning(tv))
    }

    @Test("Attaching while a covered process already plays starts at once")
    func attachWhilePlaying() {
        var logic = CatchAllRunLogic()
        _ = logic.setProcesses([5, 11], now: 0)
        _ = logic.setRunningOutput(11, true, now: 0)
        #expect(logic.attach(tv, deviceID: 42, excluded: [5], now: 0) == [.start(tv)])
    }

    @Test("Shrinking the exclusion list while the process plays starts the catch-all")
    func shrinkStarts() {
        var logic = attached(excluded: [5, 11])
        _ = logic.setRunningOutput(11, true, now: 1)
        #expect(logic.setExcluded(tv, [5], now: 2) == [.start(tv)])
    }

    @Test("Preparing an inclusion starts the catch-all before the list changes")
    func prepareInclusionStarts() {
        var logic = attached(excluded: [5, 11])
        _ = logic.setRunningOutput(11, true, now: 1)
        #expect(logic.prepareInclusion([11], on: [tv], now: 2) == [.start(tv)])
    }

    @Test("Suspends exactly 10 s after the last covered output, then re-reads")
    func suspendAfterDelay() {
        var logic = attached()
        _ = logic.setRunningOutput(11, true, now: 0)
        _ = logic.setRunningOutput(11, false, now: 3)
        let callbacks = [tv: 100.0]

        #expect(logic.tick(now: 12.9, lastAudible: [:], lastCallback: callbacks).isEmpty)
        #expect(logic.tick(now: 13, lastAudible: [:], lastCallback: callbacks) == [.stop(tv), .recheck])
        #expect(!logic.isRunning(tv))
    }

    @Test("Never suspends while the catch-all's input is audible")
    func audibleKeepsRunning() {
        var logic = attached()
        _ = logic.setRunningOutput(11, true, now: 0)
        _ = logic.setRunningOutput(11, false, now: 1)

        #expect(logic.tick(now: 20, lastAudible: [tv: 19], lastCallback: [tv: 20]).isEmpty)
        #expect(logic.tick(now: 29.9, lastAudible: [tv: 19], lastCallback: [tv: 29.9]).isEmpty)
        #expect(logic.tick(now: 30, lastAudible: [tv: 19], lastCallback: [tv: 30]) == [.stop(tv), .recheck])
    }

    @Test("A re-read that finds output after the stop starts it again")
    func recheckRestarts() {
        var logic = attached()
        _ = logic.setRunningOutput(11, true, now: 0)
        _ = logic.setRunningOutput(11, false, now: 0)
        _ = logic.tick(now: 10, lastAudible: [:], lastCallback: [tv: 10])

        #expect(logic.setRunningOutput(12, true, now: 10) == [.start(tv)])
    }

    @Test("A failed start asks for a rebuild")
    func startFailure() {
        var logic = attached()
        _ = logic.setRunningOutput(11, true, now: 0)
        #expect(logic.startResult(tv, succeeded: false) == [.rebuild(tv, .startFailed)])
        #expect(!logic.isRunning(tv))
    }

    @Test("No callbacks for two checks while audio is expected asks for a rebuild")
    func deadIO() {
        var logic = attached()
        _ = logic.setRunningOutput(11, true, now: 0)

        #expect(logic.tick(now: 2, lastAudible: [:], lastCallback: [tv: 0]).isEmpty)
        #expect(logic.tick(now: 4, lastAudible: [:], lastCallback: [tv: 0]) == [.rebuild(tv, .ioDead)])
        #expect(logic.tick(now: 6, lastAudible: [:], lastCallback: [tv: 5.9]).isEmpty)
    }

    @Test("A process that disappears no longer keeps the catch-all needed")
    func vanishedProcess() {
        var logic = attached()
        _ = logic.setRunningOutput(11, true, now: 0)
        _ = logic.setProcesses([5, 12], now: 1)
        #expect(!logic.needsAudio(tv))
    }

    @Test("With the device filter on, output to another plain device does not start it")
    func deviceFilter() {
        var logic = attached()
        logic.deviceFilterEnabled = true
        _ = logic.setOutputDevices(11, .known([77], hasNonPlain: false), now: 0)
        #expect(logic.setRunningOutput(11, true, now: 0).isEmpty)

        _ = logic.setOutputDevices(12, .known([77], hasNonPlain: true), now: 0)
        #expect(logic.setRunningOutput(12, true, now: 0) == [.start(tv)])
    }

    @Test("With the device filter on, unknown or empty device lists count as feeding")
    func deviceFilterConservative() {
        var unknown = attached()
        unknown.deviceFilterEnabled = true
        #expect(unknown.setRunningOutput(11, true, now: 0) == [.start(tv)])

        var empty = attached()
        empty.deviceFilterEnabled = true
        _ = empty.setOutputDevices(11, .known([], hasNonPlain: false), now: 0)
        #expect(empty.setRunningOutput(11, true, now: 0) == [.start(tv)])
    }

    @Test("Each device is decided on its own")
    func perDevice() {
        var logic = attached(excluded: [5, 11])
        _ = logic.attach("uid-hdmi2", deviceID: 43, excluded: [5], now: 0)
        #expect(logic.setRunningOutput(11, true, now: 1) == [.start("uid-hdmi2")])
        #expect(!logic.isRunning(tv))
    }
}

// MARK: - Driver

nonisolated final class FakeActivitySource: ProcessOutputActivitySource, @unchecked Sendable {
    private let lock = NSLock()
    private var _processes: [AudioObjectID] = []
    private var _running: Set<AudioObjectID> = []
    private var _observed: Set<AudioObjectID> = []
    private var handler: (@Sendable (ProcessActivityEvent) -> Void)?

    var observed: Set<AudioObjectID> { lock.withLock { _observed } }

    func set(processes: [AudioObjectID], running: Set<AudioObjectID>) {
        lock.withLock { _processes = processes; _running = running }
    }

    func send(_ event: ProcessActivityEvent) {
        let handler = lock.withLock { self.handler }
        handler?(event)
    }

    func processList() -> [AudioObjectID] { lock.withLock { _processes } }
    func isRunningOutput(_ process: AudioObjectID) -> Bool { lock.withLock { _running.contains(process) } }
    func outputDevices(_ process: AudioObjectID) -> ProcessOutputDevices { .unknown }
    func start(on queue: DispatchQueue, handler: @escaping @Sendable (ProcessActivityEvent) -> Void) {
        lock.withLock { self.handler = { event in queue.async { handler(event) } } }
    }
    func observe(_ process: AudioObjectID, devices: Bool) { lock.withLock { _ = _observed.insert(process) } }
    func forget(_ process: AudioObjectID) { lock.withLock { _ = _observed.remove(process) } }
    func observeAbnormalStop(of aggregate: AudioDeviceID, uid: String) {}
    func forgetAbnormalStop(of aggregate: AudioDeviceID) {}
    func stop() { lock.withLock { handler = nil } }
}

nonisolated final class HostClock: @unchecked Sendable {
    private let value = Mutex<UInt64>(1_000_000_000)
    func now() -> UInt64 { value.withLock { $0 } }
    func advance(seconds: Double) {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = UInt64(seconds * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
        value.withLock { $0 += ticks }
    }
}

nonisolated final class RebuildRecorder: @unchecked Sendable {
    private let reasons = Mutex<[String]>([])
    var all: [String] { reasons.withLock { $0 } }
    func record(_ uid: String, _ reason: CatchAllRunLogic.RebuildReason) {
        reasons.withLock { $0.append("\(uid) \(reason.rawValue)") }
    }
}

@Suite("Catch-all run control")
@MainActor
struct CatchAllRunControlTests {

    private struct Rig {
        let control: CatchAllRunControl
        let source: FakeActivitySource
        let backend: FakeCatchAllBackend
        let clock: HostClock
        let state: CatchAllRenderState
        let handle: CatchAllIOHandle
        let rebuilds: RebuildRecorder

        func flush() { control.queue.sync {} }
    }

    private func makeRig(processes: [AudioObjectID] = [5, 11], running: Set<AudioObjectID> = []) -> Rig {
        let source = FakeActivitySource()
        source.set(processes: processes, running: running)
        let backend = FakeCatchAllBackend()
        let clock = HostClock()
        let control = CatchAllRunControl(source: source, backend: backend,
                                         queue: DispatchQueue(label: "test.catchall"), hostTime: { clock.now() })
        let rebuilds = RebuildRecorder()
        control.onRebuild = { uid, reason in rebuilds.record(uid, reason) }
        let state = CatchAllRenderState(sampleRate: 48_000, targetGain: 0.25, held: false, observeOnly: false)
        state.seedGain.store(false, ordering: .relaxed)
        state.rearmGate.store(false, ordering: .relaxed)
        let handle = CatchAllIOHandle(deviceUID: "uid-tv", aggregateID: 200, procID: catchAllIOProc, state: state)
        return Rig(control: control, source: source, backend: backend, clock: clock, state: state, handle: handle, rebuilds: rebuilds)
    }

    @Test("A process that already plays when observation starts starts an attached catch-all")
    func startsForPlayingProcess() {
        let rig = makeRig(running: [11])
        rig.control.attach(rig.handle, deviceID: 42, excluded: [5])
        rig.control.start()
        rig.flush()

        #expect(rig.backend.log == ["start"])
        #expect(rig.source.observed == [5, 11])
        let seeded = rig.state.seedGain.load(ordering: .relaxed)
        let rearmed = rig.state.rearmGate.load(ordering: .relaxed)
        #expect(seeded && rearmed)
    }

    @Test("A running-output notification starts it; an excluded process does not")
    func notificationStarts() {
        let rig = makeRig()
        rig.control.attach(rig.handle, deviceID: 42, excluded: [5])
        rig.control.start()
        rig.flush()

        rig.source.set(processes: [5, 11], running: [5])
        rig.source.send(.processChanged(5))
        rig.flush()
        #expect(rig.backend.log.isEmpty)

        rig.source.set(processes: [5, 11], running: [5, 11])
        rig.source.send(.processChanged(11))
        rig.flush()
        #expect(rig.backend.log == ["start"])
    }

    @Test("A new process is observed and read immediately")
    func newProcessReadImmediately() {
        let rig = makeRig()
        rig.control.attach(rig.handle, deviceID: 42, excluded: [5])
        rig.control.start()
        rig.flush()

        rig.source.set(processes: [5, 11, 12], running: [12])
        rig.source.send(.processListChanged)
        rig.flush()

        #expect(rig.source.observed.contains(12))
        #expect(rig.backend.log == ["start"])
    }

    @Test("After 10 s without need it stops, re-reads, and restarts if output appeared")
    func stopRecheckRestart() {
        let rig = makeRig(running: [11])
        rig.control.attach(rig.handle, deviceID: 42, excluded: [5])
        rig.control.start()
        rig.flush()
        rig.source.set(processes: [5, 11], running: [])
        rig.source.send(.processChanged(11))
        rig.flush()

        rig.clock.advance(seconds: 10)
        rig.state.lastCallbackHostTime.store(rig.clock.now(), ordering: .relaxed)
        rig.control.tickOnQueueForTesting()
        #expect(rig.backend.log == ["start", "stop"])

        rig.source.set(processes: [5, 11], running: [11])
        rig.source.send(.processChanged(11))
        rig.flush()
        #expect(rig.backend.log == ["start", "stop", "start"])
    }

    @Test("Detach is a barrier: it stops a running IO and nothing touches the handle afterwards")
    func detachBarrier() async {
        let rig = makeRig(running: [11])
        rig.control.attach(rig.handle, deviceID: 42, excluded: [5])
        rig.control.start()
        rig.flush()

        await rig.control.detach("uid-tv")
        #expect(rig.backend.log == ["start", "stop"])

        rig.source.set(processes: [5, 11, 12], running: [11, 12])
        rig.source.send(.processListChanged)
        rig.flush()
        #expect(rig.backend.log == ["start", "stop"])
    }

    @Test("An abnormal IO stop asks for a rebuild")
    func abnormalStop() {
        let rig = makeRig()
        rig.control.attach(rig.handle, deviceID: 42, excluded: [5])
        rig.control.start()
        rig.flush()

        rig.source.send(.ioStoppedAbnormally("uid-tv"))
        rig.flush()

        #expect(rig.rebuilds.all == ["uid-tv ioDead"])
    }
}
