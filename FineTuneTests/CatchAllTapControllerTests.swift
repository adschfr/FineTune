// FineTuneTests/CatchAllTapControllerTests.swift
//
// Build, exclusion push and teardown of the catch-all tap against a recording fake
// backend. No Core Audio objects are created.

import AudioToolbox
import Foundation
import Synchronization
import Testing
@testable import FineTune

/// Records every backend call; can fail any step. Taps count up from 100 and aggregates
/// from 200, each tap with its own exclusion list.
nonisolated final class FakeCatchAllBackend: CatchAllBackend, @unchecked Sendable {
    enum Step: Equatable { case createTap, readBack, createAggregate, ready, ioProc, setDescription }

    private let lock = NSLock()
    private var _log: [String] = []
    private var _ioLog: [String] = []
    private var _tapProcesses: [AudioObjectID: [AudioObjectID]] = [:]
    private var _nextTap: AudioObjectID = 100
    private var _nextAggregate: AudioDeviceID = 200
    private var _aggregate: [String: Any] = [:]
    private var _deviceIDs: [String: AudioDeviceID] = ["uid-tv": 42]
    private var _setTaps: [AudioObjectID] = []
    private var _failSets = 0
    private var _failReadBacks = 0
    private var _onWaitUntilReady: (@Sendable () -> Void)?
    private var _onRecord: (@Sendable (String) -> Void)?
    var failAt: Step?
    var readBackOverride: [AudioObjectID]?

    var log: [String] { lock.withLock { _log } }
    /// Starts and stops with their aggregate, e.g. "start 200".
    var ioLog: [String] { lock.withLock { _ioLog } }
    var aggregateDescription: [String: Any] { lock.withLock { _aggregate } }
    /// Also gets every entry `log` gets, for one ordered log across the fakes.
    var onRecord: (@Sendable (String) -> Void)? {
        get { lock.withLock { _onRecord } }
        set { lock.withLock { _onRecord = newValue } }
    }

    private func record(_ entry: String) {
        let observer = lock.withLock {
            _log.append(entry)
            return _onRecord
        }
        observer?(entry)
    }

    /// The devices `deviceID(forUID:)` resolves.
    var deviceIDs: [String: AudioDeviceID] {
        get { lock.withLock { _deviceIDs } }
        set { lock.withLock { _deviceIDs = newValue } }
    }
    /// The next this many description sets fail.
    var failSets: Int {
        get { lock.withLock { _failSets } }
        set { lock.withLock { _failSets = newValue } }
    }
    /// The next this many read-backs return nothing, although a set before them took effect.
    var failReadBacks: Int {
        get { lock.withLock { _failReadBacks } }
        set { lock.withLock { _failReadBacks = newValue } }
    }
    /// Runs inside `waitUntilReady`, where the real wait spins the main run loop.
    var onWaitUntilReady: (@Sendable () -> Void)? {
        get { lock.withLock { _onWaitUntilReady } }
        set { lock.withLock { _onWaitUntilReady = newValue } }
    }
    /// The ID the next aggregate gets; set it to reuse the ID of a destroyed one, as Core
    /// Audio does.
    var nextAggregate: AudioDeviceID {
        get { lock.withLock { _nextAggregate } }
        set { lock.withLock { _nextAggregate = newValue } }
    }
    /// The most recently created tap.
    var lastTap: AudioObjectID { lock.withLock { _nextTap - 1 } }
    /// Description sets made on `tap`, failed ones included.
    func sets(on tap: AudioObjectID) -> Int { lock.withLock { _setTaps.filter { $0 == tap }.count } }
    /// The exclusion list `tap` holds, whatever its read-back says.
    func processes(on tap: AudioObjectID) -> [AudioObjectID] { lock.withLock { _tapProcesses[tap] ?? [] } }

    func deviceID(forUID uid: String) -> AudioDeviceID? { lock.withLock { _deviceIDs[uid] } }
    func firstOutputStreamIndex(of device: AudioDeviceID) throws -> UInt { 0 }
    func tapDriftCompensation(for device: AudioDeviceID) -> Bool { true }

    func createTap(_ description: CATapDescription) throws -> AudioObjectID {
        record("createTap")
        if failAt == .createTap { throw CatchAllBackendError(status: -50) }
        return lock.withLock {
            let tap = _nextTap
            _nextTap += 1
            _tapProcesses[tap] = description.processes
            return tap
        }
    }

    func readTapUID(_ tap: AudioObjectID) -> String? { "tap-uid-assigned" }

    func readTapDescription(_ tap: AudioObjectID) -> CATapDescription? {
        record("readBack")
        let processes = readBackOverride ?? lock.withLock { _tapProcesses[tap] ?? [] }
        let failOnce = lock.withLock {
            guard _failReadBacks > 0 else { return false }
            _failReadBacks -= 1
            return true
        }
        if failAt == .readBack || failOnce { return nil }
        let description = CATapDescription(excludingProcesses: processes, deviceUID: "uid-tv", stream: 0)
        description.isExclusive = true
        return description
    }

    func setTapDescription(_ description: CATapDescription, on tap: AudioObjectID) throws {
        record("set \(description.processes)")
        let failOnce = lock.withLock {
            _setTaps.append(tap)
            guard _failSets > 0 else { return false }
            _failSets -= 1
            return true
        }
        if failAt == .setDescription || failOnce { throw CatchAllBackendError(status: -10) }
        lock.withLock { _tapProcesses[tap] = description.processes }
    }

    func createAggregate(_ description: [String: Any]) throws -> AudioDeviceID {
        record("createAggregate")
        if failAt == .createAggregate { throw CatchAllBackendError(status: -20) }
        return lock.withLock {
            _aggregate = description
            let aggregate = _nextAggregate
            _nextAggregate += 1
            return aggregate
        }
    }

    func waitUntilReady(_ aggregate: AudioDeviceID, timeout: TimeInterval) -> Bool {
        record("ready")
        onWaitUntilReady?()
        return failAt != .ready
    }

    func nominalSampleRate(_ device: AudioDeviceID) -> Double? { 48_000 }

    func createIOProc(on aggregate: AudioDeviceID, clientData: UnsafeMutableRawPointer) throws -> AudioDeviceIOProcID {
        record("ioProc")
        if failAt == .ioProc { throw CatchAllBackendError(status: -30) }
        return catchAllIOProc
    }

    func disableHardwareInputs(on aggregate: AudioDeviceID, proc: AudioDeviceIOProcID) { record("disableInputs") }
    func start(_ aggregate: AudioDeviceID, _ proc: AudioDeviceIOProcID) -> OSStatus { recordIO("start", aggregate); return noErr }
    func stop(_ aggregate: AudioDeviceID, _ proc: AudioDeviceIOProcID) -> OSStatus { recordIO("stop", aggregate); return noErr }

    private func recordIO(_ entry: String, _ aggregate: AudioDeviceID) {
        lock.withLock {
            _log.append(entry)
            _ioLog.append("\(entry) \(aggregate)")
        }
    }

    func destroy(_ resources: CatchAllResources, completion: @escaping @Sendable () -> Void) {
        record("destroy tap=\(resources.tapID) aggregate=\(resources.aggregateID) proc=\(resources.procID != nil)")
        completion()
    }
}

@Suite("Catch-all tap controller")
@MainActor
struct CatchAllTapControllerTests {

    private func build(_ backend: FakeCatchAllBackend, exclusions: [AudioObjectID] = [5, 11]) throws -> CatchAllTapController {
        try CatchAllTapController.build(deviceUID: "uid-tv", exclusions: exclusions, gain: 0.25,
                                        held: false, observe: false, backend: backend)
    }

    @Test("Build order: tap, read-back, aggregate, ready, IO proc, inputs; IO is not started")
    func buildOrder() throws {
        let backend = FakeCatchAllBackend()

        let controller = try build(backend)

        #expect(backend.log == ["createTap", "readBack", "createAggregate", "ready", "ioProc", "disableInputs"])
        #expect(controller.appliedExclusions == [5, 11])
        #expect(controller.deviceID == 42)
        #expect(controller.renderState.targetGain == 0.25)
    }

    @Test("The aggregate plays the tap UID that Core Audio assigned")
    func aggregateUsesAssignedTapUID() throws {
        let backend = FakeCatchAllBackend()

        _ = try build(backend)

        let taps = try #require(backend.aggregateDescription[kAudioAggregateDeviceTapListKey] as? [[String: Any]])
        #expect(taps.first?[kAudioSubTapUIDKey] as? String == "tap-uid-assigned")
    }

    @Test("A failure at any step tears down what exists and creates nothing more", arguments: [
        FakeCatchAllBackend.Step.readBack, .createAggregate, .ready, .ioProc,
    ])
    func failureTearsDown(step: FakeCatchAllBackend.Step) {
        let backend = FakeCatchAllBackend()
        backend.failAt = step

        #expect(throws: CatchAllTapController.BuildError.self) { try build(backend) }

        let destroys = backend.log.filter { $0.hasPrefix("destroy") }
        #expect(destroys.count == 1)
        #expect(destroys.first?.contains("tap=100") == true)
        #expect(backend.log.last?.hasPrefix("destroy") == true)
        #expect(!backend.log.contains("start"))
    }

    @Test("A tap that cannot be created leaves nothing to tear down")
    func tapFailure() {
        let backend = FakeCatchAllBackend()
        backend.failAt = .createTap

        #expect(throws: CatchAllTapController.BuildError.tapFailed(-50)) { try build(backend) }
        #expect(backend.log == ["createTap"])
    }

    @Test("A read-back that differs from the requested exclusions fails the build")
    func readBackMismatch() {
        let backend = FakeCatchAllBackend()
        backend.readBackOverride = [5]

        #expect(throws: CatchAllTapController.BuildError.descriptionMismatch) { try build(backend) }
    }

    @Test("A push sets the new list and verifies it")
    func pushVerifies() throws {
        let backend = FakeCatchAllBackend()
        let controller = try build(backend)

        #expect(controller.push([5, 11, 12]))

        #expect(controller.appliedExclusions == [5, 11, 12])
        #expect(backend.log.suffix(2) == ["set [5, 11, 12]", "readBack"])
    }

    @Test("An unchanged list is not pushed")
    func unchangedNotPushed() throws {
        let backend = FakeCatchAllBackend()
        let controller = try build(backend)
        let before = backend.log.count

        #expect(controller.push([5, 11]))
        #expect(backend.log.count == before)
    }

    @Test("A failed or mismatched push keeps the applied list")
    func failedPushKeepsList() throws {
        let backend = FakeCatchAllBackend()
        let controller = try build(backend)

        backend.failAt = .setDescription
        #expect(!controller.push([5, 11, 12]))
        #expect(controller.appliedExclusions == [5, 11])

        backend.failAt = nil
        backend.readBackOverride = [5]
        #expect(!controller.push([5, 11, 12]))
        #expect(controller.appliedExclusions == [5, 11])
    }

    @Test("Gain and hold reach the render state")
    func gainAndHold() throws {
        let controller = try build(FakeCatchAllBackend())

        controller.setGain(0.5)
        controller.hold()
        let heldAfterHold = controller.renderState.held.load(ordering: .relaxed)
        #expect(controller.renderState.targetGain == 0.5)
        #expect(heldAfterHold)

        controller.release()
        let heldAfterRelease = controller.renderState.held.load(ordering: .relaxed)
        #expect(!heldAfterRelease)
    }

    @Test("Destroy tears down every resource once")
    func destroyOnce() async throws {
        let backend = FakeCatchAllBackend()
        let controller = try build(backend)

        await controller.destroy()
        await controller.destroy()

        #expect(backend.log.filter { $0.hasPrefix("destroy") } == ["destroy tap=100 aggregate=200 proc=true"])
        #expect(!controller.push([5]))
    }

    @Test("Forget drops the controller without destroy calls")
    func forget() async throws {
        let backend = FakeCatchAllBackend()
        let controller = try build(backend)

        controller.forget()
        await controller.destroy()

        #expect(!backend.log.contains { $0.hasPrefix("destroy") })
    }
}
