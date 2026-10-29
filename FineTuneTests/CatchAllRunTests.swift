// FineTuneTests/CatchAllRunTests.swift
//
// When the catch-all's IO runs: started as soon as a covered process plays or runs IO
// (listed without a cap, unlisted for 120 s, then polled), suspended 10 s after the last
// need, never while its input is audible, restarted by a re-read after a stop, rebuilt when
// its IO dies; each handle on its own. First the pure logic, then the queue driver with fakes.

import AudioToolbox
import Foundation
import Synchronization
import Testing
@testable import FineTune

extension CatchAllRunLogic {
    /// A process whose IO runs exactly while it outputs.
    mutating func setRunningOutput(_ process: AudioObjectID, _ output: Bool, now: Double) -> [Effect] {
        setRunState(process, running: output, output: output, now: now)
    }
}

@Suite("Catch-all run logic")
struct CatchAllRunLogicTests {

    private let tv: AudioDeviceID = 200

    private func attached(excluded: Set<AudioObjectID> = [5], live: Set<AudioObjectID> = [5, 11, 12]) -> CatchAllRunLogic {
        var logic = CatchAllRunLogic()
        _ = logic.setProcesses(live, now: 0)
        _ = logic.attach(tv, uid: "uid-tv", deviceID: 42, excluded: excluded, now: 0)
        return logic
    }

    @Test("A covered process starting output starts the catch-all")
    func coveredOutputStarts() {
        var logic = attached()
        #expect(logic.setRunningOutput(11, true, now: 1) == [.start(tv)])
        #expect(logic.isRunning(tv))
        #expect(logic.neededBy(tv, now: 1) == "process 11 (output)")
    }

    @Test("Excluded processes (self, foreign, claimed) never start it, with IO, listed, found without edge or capped; nor do dead ones")
    func excludedNeverStart() {
        var logic = attached(excluded: [5, 12, 13], live: [5, 11, 12, 13])
        _ = logic.setListed([5, 12], now: 0)
        #expect(logic.setRunState(5, running: true, output: false, now: 1).isEmpty)
        #expect(logic.setRunState(12, running: true, output: true, now: 1, edge: false).isEmpty)
        // Unlisted IO without output, past the cap: still never polled
        #expect(logic.setRunState(13, running: true, output: false, now: 1).isEmpty)
        // Not in the process list
        #expect(logic.setRunningOutput(99, true, now: 1).isEmpty)
        #expect(logic.pollTargets(now: 500).isEmpty)
        #expect(logic.timerInterval(now: 500) == 3)
        #expect(!logic.isRunning(tv))
    }

    @Test("Attaching while a covered process already plays starts at once")
    func attachWhilePlaying() {
        var logic = CatchAllRunLogic()
        _ = logic.setProcesses([5, 11], now: 0)
        _ = logic.setRunningOutput(11, true, now: 0)
        #expect(logic.attach(tv, uid: "uid-tv", deviceID: 42, excluded: [5], now: 0) == [.start(tv)])
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
        #expect(logic.prepareInclusion([11], on: ["uid-tv"], now: 2) == [.start(tv)])
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

    @Test("Never suspends while covered output runs, also past the cap")
    func noSuspendWhileOutput() {
        var logic = attached()
        _ = logic.setRunningOutput(11, true, now: 0)
        var effects: [CatchAllRunLogic.Effect] = []
        for now in stride(from: 2.0, through: 600, by: 2) {
            effects += logic.tick(now: now, lastAudible: [:], lastCallback: [tv: now])
        }
        // Past the cap its output is polled, nothing else
        #expect(effects.allSatisfy { $0 == .poll([11]) })
        #expect(logic.isRunning(tv))
    }

    @Test("While it runs, a capped process's output is polled, so output that ends without an edge lets it suspend")
    func cappedOutputPolledWhileRunning() {
        var logic = attached()
        #expect(logic.setRunState(11, running: true, output: true, now: 0) == [.start(tv)])
        #expect(logic.tick(now: 100, lastAudible: [:], lastCallback: [tv: 100]).isEmpty)
        #expect(logic.tick(now: 200, lastAudible: [:], lastCallback: [tv: 200]) == [.poll([11])])

        // The output ended while the IO stays open: no notification, only the poll sees it
        _ = logic.setPolledOutput(11, false, now: 200)
        #expect(logic.tick(now: 202, lastAudible: [:], lastCallback: [tv: 202]).isEmpty)
        #expect(logic.tick(now: 210, lastAudible: [:], lastCallback: [tv: 210]) == [.stop(tv), .recheck])
    }

    @Test("A Core Audio restart drops every handle and process, the listed ones too, without effects")
    func serviceRestartedForgets() {
        var logic = attached()
        _ = logic.setListed([11], now: 0)
        _ = logic.setRunState(11, running: true, output: false, now: 0)
        #expect(logic.isRunning(tv))

        logic.serviceRestarted()
        #expect(logic.handles.isEmpty)
        #expect(logic.live.isEmpty && logic.listed.isEmpty && logic.runningSince.isEmpty)
        #expect(logic.timerInterval(now: 1) == 0)
        #expect(logic.tick(now: 20, lastAudible: [:], lastCallback: [:]).isEmpty)
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

    @Test("The stop asks for a recheck, and a read that finds output then starts it again")
    func recheckRestarts() {
        var logic = attached()
        _ = logic.setRunningOutput(11, true, now: 0)
        _ = logic.setRunningOutput(11, false, now: 0)
        #expect(logic.tick(now: 10, lastAudible: [:], lastCallback: [tv: 10]) == [.stop(tv), .recheck])

        #expect(logic.setRunningOutput(12, true, now: 10) == [.start(tv)])
    }

    @Test("IO without output needs audio without a cap for a listed process")
    func listedIOWithoutCap() {
        var logic = attached()
        _ = logic.setListed([11], now: 0)
        #expect(logic.setRunState(11, running: true, output: false, now: 0) == [.start(tv)])
        #expect(logic.needsAudio(tv, now: 1_000))
        #expect(logic.neededBy(tv, now: 1_000) == "process 11 (listed IO)")
        #expect(logic.tick(now: 1_000, lastAudible: [:], lastCallback: [tv: 1_000]).isEmpty)
        #expect(logic.pollTargets(now: 1_000).isEmpty)
    }

    @Test("IO without output counts 120 s for an unlisted process, then it is polled every 100 ms")
    func unlistedIOCapped() {
        var logic = attached()
        #expect(logic.setRunState(11, running: true, output: false, now: 0) == [.start(tv)])
        #expect(logic.needsAudio(tv, now: 119.9))
        #expect(logic.neededBy(tv, now: 119.9) == "process 11 (IO within the cap)")
        #expect(!logic.needsAudio(tv, now: 120))
        #expect(logic.neededBy(tv, now: 120) == nil)

        _ = logic.tick(now: 119, lastAudible: [:], lastCallback: [tv: 119])
        #expect(logic.tick(now: 129, lastAudible: [:], lastCallback: [tv: 129]) == [.stop(tv), .recheck])
        #expect(logic.timerInterval(now: 129) == 0.1)
        #expect(logic.tick(now: 129.1, lastAudible: [:], lastCallback: [:]) == [.poll([11])])
        // The safety re-read still runs every 3 s
        #expect(logic.tick(now: 132, lastAudible: [:], lastCallback: [:]) == [.reread])

        // A poll that finds output starts the catch-all and flags the missing edge
        #expect(logic.setPolledOutput(11, true, now: 132.1) == [.start(tv), .outputWithoutEdge(11)])
        #expect(logic.timerInterval(now: 132.1) == 2)
    }

    @Test("While one catch-all runs, the capped processes of a stopped one are polled every 100 ms")
    func pollWhileAnotherRuns() {
        // The TV covers 11, a second output covers 12
        var logic = attached(excluded: [5, 12])
        let hdmi: AudioDeviceID = 201
        _ = logic.attach(hdmi, uid: "uid-hdmi2", deviceID: 43, excluded: [5, 11], now: 0)
        #expect(logic.setRunState(11, running: true, output: false, now: 0) == [.start(tv)])
        #expect(logic.tick(now: 130, lastAudible: [:], lastCallback: [tv: 130]) == [.stop(tv), .recheck])
        #expect(logic.setRunningOutput(12, true, now: 131) == [.start(hdmi)])

        #expect(logic.timerInterval(now: 131) == 0.1)
        #expect(logic.tick(now: 131.1, lastAudible: [:], lastCallback: [hdmi: 131.1]) == [.poll([11])])
        // The running one is still checked every 2 s
        #expect(logic.tick(now: 132, lastAudible: [:], lastCallback: [hdmi: 132]) == [.poll([11])])
        #expect(logic.setPolledOutput(11, true, now: 132.1) == [.start(tv), .outputWithoutEdge(11)])
        #expect(logic.timerInterval(now: 132.1) == 2)
    }

    @Test("Back from the poll, the safety re-read keeps its phase")
    func rereadKeepsPhase() {
        var logic = attached()
        #expect(logic.timerDelay(now: 0) == 3)
        _ = logic.setRunState(11, running: true, output: false, now: 0)
        _ = logic.tick(now: 119, lastAudible: [:], lastCallback: [tv: 119])
        _ = logic.tick(now: 129, lastAudible: [:], lastCallback: [tv: 129])
        #expect(logic.tick(now: 132, lastAudible: [:], lastCallback: [:]) == [.reread])

        // The capped IO ends: the next re-read is due 3 s after the last one, not 3 s from now
        _ = logic.setRunState(11, running: false, output: false, now: 134)
        #expect(logic.timerInterval(now: 134) == 3)
        #expect(logic.timerDelay(now: 134) == 1)
    }

    @Test("Listing a capped process makes its IO count again")
    func listingLiftsCap() {
        var logic = attached()
        _ = logic.setRunState(11, running: true, output: false, now: 0)
        _ = logic.tick(now: 119, lastAudible: [:], lastCallback: [tv: 119])
        _ = logic.tick(now: 129, lastAudible: [:], lastCallback: [tv: 129])
        #expect(logic.setListed([11], now: 130) == [.start(tv)])
    }

    @Test("Timer: 3 s re-read while all are stopped, 2 s tick while one runs, none without a catch-all")
    func timerIntervals() {
        var logic = CatchAllRunLogic()
        #expect(logic.timerInterval(now: 0) == 0)
        _ = logic.setProcesses([5, 11], now: 0)
        _ = logic.attach(tv, uid: "uid-tv", deviceID: 42, excluded: [5], now: 0)
        #expect(logic.timerInterval(now: 0) == 3)
        _ = logic.setRunningOutput(11, true, now: 1)
        #expect(logic.timerInterval(now: 1) == 2)
        logic.detach(tv)
        #expect(logic.timerInterval(now: 1) == 0)
    }

    @Test("The safety re-read restarts a missed resume and flags the output without edge")
    func rereadRestartsMissedResume() {
        var logic = attached()
        #expect(logic.tick(now: 3, lastAudible: [:], lastCallback: [:]) == [.reread])
        #expect(logic.setRunState(11, running: true, output: true, now: 3, edge: false) == [.start(tv), .outputWithoutEdge(11)])
        // Output that follows a notification is not flagged
        #expect(logic.setRunState(12, running: true, output: true, now: 4).isEmpty)
    }

    @Test("A Devices report goes out once per changed pair, including an output change under an empty list")
    func devicesReports() {
        var logic = attached()
        let tvOnly = ProcessOutputDevices.known([42: .plain])
        #expect(logic.setOutputDevices(11, tvOnly, now: 0) == [.devicesChanged(11, ProcessDeviceReport(devices: tvOnly, runningOutput: false))])
        #expect(logic.setOutputDevices(11, tvOnly, now: 1).isEmpty)
        let withAggregate = ProcessOutputDevices.known([42: .plain, 300: .aggregateOrVirtual])
        #expect(logic.setOutputDevices(11, withAggregate, now: 2) == [.devicesChanged(11, ProcessDeviceReport(devices: withAggregate, runningOutput: false))])

        // An output change under an unchanged empty list goes out after the start, without a Devices read
        let empty = ProcessOutputDevices.known([:])
        _ = logic.setOutputDevices(12, empty, now: 3)
        #expect(logic.setRunState(12, running: true, output: true, now: 4)
                == [.start(tv), .devicesChanged(12, ProcessDeviceReport(devices: empty, runningOutput: true))])
        #expect(logic.setOutputDevices(12, empty, now: 4).isEmpty)
        // A poll's output change is reported too
        #expect(logic.setPolledOutput(12, false, now: 5) == [.devicesChanged(12, ProcessDeviceReport(devices: empty, runningOutput: false))])
    }

    @Test("Two handles for one device start and stop on their own; detaching one keeps the other")
    func handlesPerAggregate() {
        var logic = attached()
        let rebuilt: AudioDeviceID = 201
        _ = logic.attach(rebuilt, uid: "uid-tv", deviceID: 42, excluded: [5], now: 0)
        #expect(logic.setRunningOutput(11, true, now: 1) == [.start(tv), .start(rebuilt)])

        _ = logic.setExcluded(rebuilt, [5, 11], now: 2)
        #expect(logic.tick(now: 12, lastAudible: [:], lastCallback: [tv: 12, rebuilt: 12]) == [.stop(rebuilt), .recheck])
        #expect(logic.isRunning(tv))

        logic.detach(tv)
        #expect(logic.handles.keys.sorted() == [rebuilt])
        #expect(logic.setExcluded(rebuilt, [5], now: 13) == [.start(rebuilt)])
    }

    @Test("A failed start asks for a rebuild once; later events do not start that handle again")
    func startFailure() {
        var logic = attached()
        _ = logic.setRunningOutput(11, true, now: 0)
        #expect(logic.startResult(tv, succeeded: false) == [.rebuild(tv, .startFailed)])
        #expect(!logic.isRunning(tv))

        #expect(logic.setRunningOutput(12, true, now: 1).isEmpty)
        #expect(logic.setListed([11], now: 2).isEmpty)
        #expect(logic.setExcluded(tv, [5], now: 3).isEmpty)
        #expect(logic.tick(now: 4, lastAudible: [:], lastCallback: [:]) == [.reread])
        #expect(!logic.isRunning(tv))

        // The rebuilt handle starts
        logic.detach(tv)
        #expect(logic.attach(201, uid: "uid-tv", deviceID: 42, excluded: [5], now: 5) == [.start(201)])
    }

    @Test("No callbacks for two checks while audio is expected asks for a rebuild")
    func deadIO() {
        var logic = attached()
        _ = logic.setRunningOutput(11, true, now: 0)

        #expect(logic.tick(now: 2, lastAudible: [:], lastCallback: [tv: 0]).isEmpty)
        #expect(logic.tick(now: 4, lastAudible: [:], lastCallback: [tv: 0]) == [.rebuild(tv, .ioDead)])
        #expect(logic.tick(now: 6, lastAudible: [:], lastCallback: [tv: 5.9]).isEmpty)
    }

    /// One timer event as the run control runs it: `tick`, then the rate check of the targets
    /// it names, with `mismatched` read as differing. Returns both effect lists and the targets.
    private func timerEvent(_ logic: inout CatchAllRunLogic, at now: Double, callbacks: [AudioDeviceID: Double],
                            mismatched: Set<AudioDeviceID> = []) -> (tick: [CatchAllRunLogic.Effect], targets: [AudioDeviceID], rate: [CatchAllRunLogic.Effect]) {
        let tick = logic.tick(now: now, lastAudible: [:], lastCallback: callbacks)
        let targets = logic.rateCheckTargets(now: now, lastCallback: callbacks)
        let rate = logic.rateChecked(mismatched.intersection(targets), now: now)
        return (tick, targets, rate)
    }

    @Test("A rate that differs on two liveness ticks in a row asks for one rebuild: one tick does not, a match in between starts over, and the aggregate is never read or asks again")
    func rateMismatch() {
        var logic = attached()
        _ = logic.setRunningOutput(11, true, now: 0)

        var event = timerEvent(&logic, at: 2, callbacks: [tv: 2], mismatched: [tv])
        #expect(event.targets == [tv])
        #expect(event.tick.isEmpty && event.rate.isEmpty)
        // A match (or a failed read, which the run control passes as one) starts over
        #expect(timerEvent(&logic, at: 4, callbacks: [tv: 4]).rate.isEmpty)
        #expect(timerEvent(&logic, at: 6, callbacks: [tv: 6], mismatched: [tv]).rate.isEmpty)
        event = timerEvent(&logic, at: 8, callbacks: [tv: 8], mismatched: [tv])
        #expect(event.tick.isEmpty)
        #expect(event.rate == [.rebuild(tv, .rateMismatch)])
        // Asked once: not read again, and never asks again even when named
        event = timerEvent(&logic, at: 10, callbacks: [tv: 10], mismatched: [tv])
        #expect(event.targets.isEmpty && event.rate.isEmpty)
        for now in [12.0, 14.0] {
            _ = logic.tick(now: now, lastAudible: [:], lastCallback: [tv: now])
            #expect(logic.rateChecked([tv], now: now).isEmpty)
        }
        #expect(logic.isRunning(tv))
    }

    @Test("The rate is checked only after a liveness tick, once, and only for running catch-alls whose IO called back within the liveness timeout: a stale one is not read and starts over, a stopped one is no target, a stop starts the count over, a detached one is gone")
    func rateCheckRunningOnly() {
        // The TV covers 11; the rebuilt one excludes it and stays stopped
        var logic = attached()
        let rebuilt: AudioDeviceID = 201
        _ = logic.attach(rebuilt, uid: "uid-tv", deviceID: 42, excluded: [5, 11], now: 0)
        #expect(logic.rateCheckTargets(now: 1, lastCallback: [tv: 1, rebuilt: 1]).isEmpty)
        #expect(logic.setRunningOutput(11, true, now: 1) == [.start(tv)])
        // No tick at this time yet
        #expect(logic.rateCheckTargets(now: 2, lastCallback: [tv: 2]).isEmpty)
        #expect(logic.rateChecked([tv], now: 2).isEmpty)

        var event = timerEvent(&logic, at: 3, callbacks: [tv: 3, rebuilt: 0], mismatched: [tv, rebuilt])
        #expect(event.targets == [tv])
        // Each tick is checked once
        #expect(logic.rateChecked([tv], now: 3).isEmpty)
        // A callback older than the liveness timeout: not read, and the count starts over
        event = timerEvent(&logic, at: 5, callbacks: [tv: 3.9], mismatched: [tv])
        #expect(event.targets.isEmpty)
        #expect(timerEvent(&logic, at: 7, callbacks: [tv: 6], mismatched: [tv]).rate.isEmpty)
        #expect(timerEvent(&logic, at: 9, callbacks: [tv: 8], mismatched: [tv]).rate == [.rebuild(tv, .rateMismatch)])
    }

    @Test("A stop starts the count over: the tick that suspends the catch-all checks no rate, and a mismatch before the stop does not add to one after the restart")
    func rateCheckStopRestarts() {
        var logic = attached()
        _ = logic.setRunningOutput(11, true, now: 1)
        #expect(timerEvent(&logic, at: 3, callbacks: [tv: 3], mismatched: [tv]).rate.isEmpty)
        _ = logic.setRunningOutput(11, false, now: 4)
        let suspended = timerEvent(&logic, at: 14, callbacks: [tv: 14], mismatched: [tv])
        #expect(suspended.tick == [.stop(tv), .recheck])
        #expect(suspended.targets.isEmpty)
        #expect(logic.setRunningOutput(11, true, now: 15) == [.start(tv)])
        #expect(timerEvent(&logic, at: 17, callbacks: [tv: 17], mismatched: [tv]).rate.isEmpty)
        #expect(timerEvent(&logic, at: 19, callbacks: [tv: 19], mismatched: [tv]).rate == [.rebuild(tv, .rateMismatch)])

        logic.detach(tv)
        #expect(timerEvent(&logic, at: 21, callbacks: [tv: 21], mismatched: [tv]).targets.isEmpty)
    }

    @Test("The poll of a stopped catch-all between liveness ticks checks no rate: only the ticks 2 s apart count")
    func rateCheckSkipsPolls() {
        // As in pollWhileAnotherRuns: the TV covers 11 (capped, stopped), a second output covers 12
        var logic = attached(excluded: [5, 12])
        let hdmi: AudioDeviceID = 201
        _ = logic.attach(hdmi, uid: "uid-hdmi2", deviceID: 43, excluded: [5, 11], now: 0)
        _ = logic.setRunState(11, running: true, output: false, now: 0)
        #expect(logic.tick(now: 130, lastAudible: [:], lastCallback: [tv: 130]) == [.stop(tv), .recheck])
        #expect(logic.setRunningOutput(12, true, now: 131) == [.start(hdmi)])

        var event = timerEvent(&logic, at: 131.1, callbacks: [hdmi: 131.1], mismatched: [hdmi])
        #expect(event.tick == [.poll([11])])
        #expect(event.targets.isEmpty)
        #expect(timerEvent(&logic, at: 131.2, callbacks: [hdmi: 131.2], mismatched: [hdmi]).targets.isEmpty)
        event = timerEvent(&logic, at: 132, callbacks: [hdmi: 132], mismatched: [hdmi])
        #expect(event.tick == [.poll([11])])
        #expect(event.targets == [hdmi])
        #expect(event.rate.isEmpty)
        #expect(timerEvent(&logic, at: 132.1, callbacks: [hdmi: 132.1], mismatched: [hdmi]).rate.isEmpty)
        event = timerEvent(&logic, at: 134, callbacks: [hdmi: 134], mismatched: [hdmi])
        #expect(event.tick == [.poll([11])])
        #expect(event.rate == [.rebuild(hdmi, .rateMismatch)])
    }

    @Test("A process that disappears no longer keeps the catch-all needed")
    func vanishedProcess() {
        var logic = attached()
        _ = logic.setRunningOutput(11, true, now: 0)
        _ = logic.setProcesses([5, 12], now: 1)
        #expect(!logic.needsAudio(tv, now: 1))
    }

    @Test("With the device filter on, output to another plain device does not start it")
    func deviceFilter() {
        var logic = attached()
        logic.deviceFilterEnabled = true
        _ = logic.setOutputDevices(11, .known([77: .plain]), now: 0)
        #expect(!logic.setRunningOutput(11, true, now: 0).contains(.start(tv)))

        _ = logic.setOutputDevices(12, .known([77: .aggregateOrVirtual]), now: 0)
        #expect(logic.setRunningOutput(12, true, now: 0).contains(.start(tv)))
    }

    @Test("With the device filter on, unknown, empty or unresolvable device lists count as feeding")
    func deviceFilterConservative() {
        var unknown = attached()
        unknown.deviceFilterEnabled = true
        #expect(unknown.setRunningOutput(11, true, now: 0) == [.start(tv)])

        var empty = attached()
        empty.deviceFilterEnabled = true
        _ = empty.setOutputDevices(11, .known([:]), now: 0)
        #expect(empty.setRunningOutput(11, true, now: 0).contains(.start(tv)))

        var unresolvable = attached()
        unresolvable.deviceFilterEnabled = true
        _ = unresolvable.setOutputDevices(11, .known([77: .unresolvable]), now: 0)
        #expect(unresolvable.setRunningOutput(11, true, now: 0).contains(.start(tv)))
    }

    @Test("Each device is decided on its own")
    func perDevice() {
        var logic = attached(excluded: [5, 11])
        _ = logic.attach(201, uid: "uid-hdmi2", deviceID: 43, excluded: [5], now: 0)
        #expect(logic.setRunningOutput(11, true, now: 1) == [.start(201)])
        #expect(!logic.isRunning(tv))
    }
}

// MARK: - Driver

nonisolated final class FakeActivitySource: ProcessOutputActivitySource, @unchecked Sendable {
    private let lock = NSLock()
    private var _processes: [AudioObjectID] = []
    private var _running: Set<AudioObjectID> = []
    private var _runningIO: Set<AudioObjectID> = []
    private var _devices: [AudioObjectID: [AudioDeviceID]] = [:]
    private var _kinds: [AudioDeviceID: OutputDeviceKind] = [:]
    private var _classified: [AudioDeviceID: Int] = [:]
    private var _observed: Set<AudioObjectID> = []
    private var _devicesObserved: Set<AudioObjectID> = []
    private var _abnormalStops: Set<AudioDeviceID> = []
    private var _starts = 0
    private var _stops = 0
    private var _failingStarts = 0
    private var _outputReads: [AudioObjectID: Int] = [:]
    private var _onDevicesRead: (@Sendable (AudioObjectID) -> Void)?
    private var handler: (@Sendable (ProcessActivityEvent) -> Void)?

    var observed: Set<AudioObjectID> { lock.withLock { _observed } }
    /// Processes observed together with their output devices.
    var devicesObserved: Set<AudioObjectID> { lock.withLock { _devicesObserved } }
    var abnormalStops: Set<AudioDeviceID> { lock.withLock { _abnormalStops } }
    var starts: Int { lock.withLock { _starts } }
    var stops: Int { lock.withLock { _stops } }
    func classifications(of device: AudioDeviceID) -> Int { lock.withLock { _classified[device] ?? 0 } }
    func outputReads(of process: AudioObjectID) -> Int { lock.withLock { _outputReads[process] ?? 0 } }
    /// The next this many starts report a system listener that could not be registered.
    var failingStarts: Int {
        get { lock.withLock { _failingStarts } }
        set { lock.withLock { _failingStarts = newValue } }
    }
    /// Runs on every Devices read, before it returns.
    var onDevicesRead: (@Sendable (AudioObjectID) -> Void)? {
        get { lock.withLock { _onDevicesRead } }
        set { lock.withLock { _onDevicesRead = newValue } }
    }

    /// `running`: processes with active output; `runningIO`: processes that report IsRunning
    /// (defaults to the ones with output).
    func set(processes: [AudioObjectID], running: Set<AudioObjectID>, runningIO: Set<AudioObjectID>? = nil) {
        lock.withLock { _processes = processes; _running = running; _runningIO = runningIO ?? running }
    }

    /// Output devices per process (without an entry: unreadable) and their kinds (default plain).
    func set(devices: [AudioObjectID: [AudioDeviceID]], kinds: [AudioDeviceID: OutputDeviceKind] = [:]) {
        lock.withLock { _devices = devices; _kinds = kinds }
    }

    func send(_ event: ProcessActivityEvent) {
        let handler = lock.withLock { self.handler }
        handler?(event)
    }

    func processList() -> [AudioObjectID] { lock.withLock { _processes } }
    func isRunning(_ process: AudioObjectID) -> Bool { lock.withLock { _runningIO.contains(process) } }
    func isRunningOutput(_ process: AudioObjectID) -> Bool {
        lock.withLock {
            _outputReads[process, default: 0] += 1
            return _running.contains(process)
        }
    }

    func outputDeviceIDs(_ process: AudioObjectID) -> [AudioDeviceID]? {
        let (ids, hook) = lock.withLock { (_devices[process], _onDevicesRead) }
        hook?(process)
        return ids
    }

    func classify(_ device: AudioDeviceID) -> OutputDeviceKind {
        lock.withLock {
            _classified[device, default: 0] += 1
            return _kinds[device] ?? .plain
        }
    }

    func start(on queue: DispatchQueue, handler: @escaping @Sendable (ProcessActivityEvent) -> Void) -> Bool {
        lock.withLock {
            _starts += 1
            self.handler = { event in queue.async { handler(event) } }
            guard _failingStarts > 0 else { return true }
            _failingStarts -= 1
            return false
        }
    }

    /// Like the HAL source: nothing is registered before start or after stop.
    func observe(_ process: AudioObjectID, devices: Bool) {
        lock.withLock {
            guard handler != nil else { return }
            _observed.insert(process)
            if devices { _devicesObserved.insert(process) }
        }
    }

    func forget(_ process: AudioObjectID) {
        lock.withLock {
            _observed.remove(process)
            _devicesObserved.remove(process)
        }
    }

    func observeAbnormalStop(of aggregate: AudioDeviceID) {
        lock.withLock {
            guard handler != nil else { return }
            _abnormalStops.insert(aggregate)
        }
    }
    func forgetAbnormalStop(of aggregate: AudioDeviceID) { lock.withLock { _ = _abnormalStops.remove(aggregate) } }

    /// Like the HAL source: every listener goes.
    func stop() {
        lock.withLock {
            _stops += 1
            handler = nil
            _observed.removeAll()
            _devicesObserved.removeAll()
            _abnormalStops.removeAll()
        }
    }
}

nonisolated final class HostClock: @unchecked Sendable {
    private let value = Mutex<UInt64>(1_000_000_000)
    func now() -> UInt64 { value.withLock { $0 } }
    /// `now()` in seconds, the run control's clock.
    var seconds: Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(now()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
    func advance(seconds: Double) {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = UInt64(seconds * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
        value.withLock { $0 += ticks }
    }
}

/// Nominal rates by device for the run control's rate reader; a missing one fails to read.
nonisolated final class FakeRates: Sendable {
    private let table: Mutex<[AudioDeviceID: Double]>
    init(_ rates: [AudioDeviceID: Double]) { table = Mutex(rates) }
    func set(_ device: AudioDeviceID, _ rate: Double?) { table.withLock { $0[device] = rate } }
    func rate(_ device: AudioDeviceID) -> Double? { table.withLock { $0[device] } }
}

nonisolated final class LineLog: @unchecked Sendable {
    private let lines = Mutex<[String]>([])
    var all: [String] { lines.withLock { $0 } }
    func add(_ line: String) { lines.withLock { $0.append(line) } }
}

/// One line per process: "11 [42] output".
private func describe(_ reports: [AudioObjectID: ProcessDeviceReport]) -> String {
    reports.keys.sorted().map { process in
        let report = reports[process]!
        let devices = switch report.devices {
        case .unknown: "unknown"
        case .known(let kinds): kinds.keys.sorted().map { "\($0)" }.joined(separator: ",")
        }
        return "\(process) [\(devices)] \(report.runningOutput ? "output" : "silent")"
    }.joined(separator: "; ")
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
        let rebuilds: LineLog

        func flush() { control.queue.sync {} }

        func startAttached() {
            control.attach(handle, deviceID: 42, excluded: [5])
            control.start()
            flush()
        }
    }

    private func makeRig(processes: [AudioObjectID] = [5, 11], running: Set<AudioObjectID> = [],
                         logic: CatchAllRunLogic = CatchAllRunLogic(), observeDevices: Bool = false,
                         waitTimeout: Double = 1) -> Rig {
        let source = FakeActivitySource()
        source.set(processes: processes, running: running)
        let backend = FakeCatchAllBackend()
        let clock = HostClock()
        let control = CatchAllRunControl(source: source, backend: backend, logic: logic, observeDevices: observeDevices,
                                         queue: DispatchQueue(label: "test.catchall"), waitTimeout: waitTimeout,
                                         hostTime: { clock.now() })
        let rebuilds = LineLog()
        control.onRebuild = { uid, aggregate, reason in rebuilds.add("\(uid) \(aggregate) \(reason.rawValue)") }
        let handle = makeHandle(aggregate: 200)
        return Rig(control: control, source: source, backend: backend, clock: clock, state: handle.state, handle: handle, rebuilds: rebuilds)
    }

    private func makeHandle(aggregate: AudioDeviceID) -> CatchAllIOHandle {
        let state = CatchAllRenderState(sampleRate: 48_000, targetGain: 0.25, held: false, observeOnly: false)
        state.seedGain.store(false, ordering: .relaxed)
        state.rearmGate.store(false, ordering: .relaxed)
        return CatchAllIOHandle(deviceUID: "uid-tv", aggregateID: aggregate, procID: catchAllIOProc, state: state)
    }

    /// Lets main run what the queue posted to it, up to 1 s until `condition` holds.
    private func waitForMain(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A process that already plays when observation starts starts an attached catch-all")
    func startsForPlayingProcess() {
        let rig = makeRig(running: [11])
        rig.startAttached()

        #expect(rig.backend.log == ["start"])
        #expect(rig.source.observed == [5, 11])
        let seeded = rig.state.seedGain.load(ordering: .relaxed)
        let rearmed = rig.state.rearmGate.load(ordering: .relaxed)
        #expect(seeded && rearmed)
    }

    @Test("A running-output notification starts it; an excluded process does not")
    func notificationStarts() {
        let rig = makeRig()
        rig.startAttached()

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
        rig.startAttached()

        rig.source.set(processes: [5, 11, 12], running: [12])
        rig.source.send(.processListChanged)
        rig.flush()

        #expect(rig.source.observed.contains(12))
        #expect(rig.backend.log == ["start"])
    }

    @Test("After 10 s without need it stops, re-reads, and restarts if output appeared")
    func stopRecheckRestart() {
        let rig = makeRig(running: [11])
        rig.startAttached()
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

    @Test("Output that began without a notification restarts the catch-all at the stop's recheck")
    func stopRecheckFindsUnnotifiedOutput() {
        let rig = makeRig(running: [11])
        rig.startAttached()
        rig.source.set(processes: [5, 11], running: [])
        rig.source.send(.processChanged(11))
        rig.flush()

        // Output starts again, but no notification arrives before the suspend decision
        rig.source.set(processes: [5, 11], running: [11])
        rig.clock.advance(seconds: 10)
        rig.state.lastCallbackHostTime.store(rig.clock.now(), ordering: .relaxed)
        rig.control.tickOnQueueForTesting()
        #expect(rig.backend.log == ["start", "stop", "start"])
    }

    @Test("Detach is a barrier: it stops a running IO and nothing touches the handle afterwards")
    func detachBarrier() async {
        let rig = makeRig(running: [11])
        rig.startAttached()

        let detached = await rig.control.detach(rig.handle)
        #expect(detached)
        #expect(rig.backend.log == ["start", "stop"])

        rig.source.set(processes: [5, 11, 12], running: [11, 12])
        rig.source.send(.processListChanged)
        rig.flush()
        #expect(rig.backend.log == ["start", "stop"])
    }

    @Test("Two handles for one device run on their own; detaching the old one keeps the new one")
    func makeBeforeBreak() async {
        let rig = makeRig(running: [11])
        let rebuilt = makeHandle(aggregate: 201)
        rig.control.attach(rig.handle, deviceID: 42, excluded: [5])
        rig.control.start()
        rig.control.attach(rebuilt, deviceID: 42, excluded: [5])
        rig.flush()
        #expect(rig.backend.ioLog == ["start 200", "start 201"])

        let detached = await rig.control.detach(rig.handle)
        #expect(detached)
        #expect(rig.backend.ioLog == ["start 200", "start 201", "stop 200"])
        let (attached, running) = rig.control.sync { ($0.handles.keys.sorted(), $0.isRunning(201)) }
        #expect(attached == [201])
        #expect(running)
        #expect(rig.source.abnormalStops == [201])

        // A handle that is already detached is not detached again
        let again = await rig.control.detach(rig.handle)
        #expect(again)
        #expect(rig.backend.ioLog.count == 3)

        // The new handle still suspends and resumes on its own
        rig.source.set(processes: [5, 11], running: [])
        rig.source.send(.processChanged(11))
        rig.flush()
        rig.clock.advance(seconds: 10)
        rebuilt.state.lastCallbackHostTime.store(rig.clock.now(), ordering: .relaxed)
        rig.control.tickOnQueueForTesting()
        rig.source.set(processes: [5, 11], running: [11])
        rig.source.send(.processChanged(11))
        rig.flush()
        #expect(rig.backend.ioLog == ["start 200", "start 201", "stop 200", "stop 201", "start 201"])
    }

    @Test("An IsRunning edge starts the catch-all before the process reports output")
    func isRunningEdgeStarts() async {
        // Core Audio notifies IsRunning but not IsRunningOutput
        let rig = makeRig()
        rig.startAttached()

        rig.source.set(processes: [5, 11], running: [], runningIO: [11])
        rig.source.send(.processChanged(11))
        rig.flush()
        #expect(rig.backend.log == ["start"])

        // The follow-up reads still learn the output, so it counts once the cap is over
        rig.source.set(processes: [5, 11], running: [11], runningIO: [11])
        for _ in 0..<100 where rig.control.sync({ $0.runningOutput }).isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let output = rig.control.sync { $0.runningOutput }
        #expect(output == [11])
        #expect(rig.backend.log == ["start"])
    }

    @Test("After the cap, a poll that finds output resumes the catch-all")
    func pollResumes() async {
        var logic = CatchAllRunLogic()
        logic.ioOnlyCap = 1
        logic.suspendDelay = 1
        let rig = makeRig(logic: logic)
        rig.startAttached()
        rig.source.set(processes: [5, 11], running: [], runningIO: [11])
        rig.source.send(.processChanged(11))
        rig.flush()
        #expect(rig.backend.log == ["start"])

        rig.clock.advance(seconds: 2)
        rig.state.lastCallbackHostTime.store(rig.clock.now(), ordering: .relaxed)
        rig.control.tickOnQueueForTesting()
        #expect(rig.backend.log == ["start", "stop"])
        let now = rig.clock.seconds
        let interval = rig.control.sync { $0.timerInterval(now: now) }
        #expect(interval == 0.1)

        // Let the follow-up reads of the IsRunning edge pass, then output starts without a
        // notification: the 100 ms timer polls 11 alone and resumes
        try? await Task.sleep(for: .milliseconds(150))
        rig.flush()
        let readsOf5 = rig.source.outputReads(of: 5)
        rig.source.set(processes: [5, 11], running: [11], runningIO: [11])
        for _ in 0..<100 where rig.backend.log.count < 3 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(rig.backend.log == ["start", "stop", "start"])
        #expect(rig.source.outputReads(of: 5) == readsOf5)
    }

    @Test("The safety re-read restarts a missed resume")
    func rereadRestartsMissedResume() {
        let rig = makeRig()
        rig.startAttached()

        rig.source.set(processes: [5, 11], running: [11])
        rig.control.tickOnQueueForTesting()
        #expect(rig.backend.log == ["start"])
    }

    @Test("A process whose appearance was missed is observed by the re-read and starts the catch-all")
    func rereadFindsMissedProcess() {
        let rig = makeRig()
        rig.startAttached()

        rig.source.set(processes: [5, 11, 12], running: [12])
        rig.control.tickOnQueueForTesting()
        #expect(rig.source.observed == [5, 11, 12])
        #expect(rig.backend.log == ["start"])
    }

    @Test("Listing a process the queue has not seen observes it; its IO counts without a cap")
    func setListedObservesMissing() {
        let rig = makeRig()
        rig.startAttached()

        rig.source.set(processes: [5, 11], running: [], runningIO: [13])
        rig.control.setListed([11, 13])
        rig.flush()
        #expect(rig.source.observed == [5, 11, 13])
        #expect(rig.backend.log == ["start"])
        let listed = rig.control.sync { $0.listed }
        #expect(listed == [11, 13])
    }

    @Test("A service restart drops the dead handles first, then registers the listeners again, forgets observed processes, classifications and listed ones, and reads anew")
    func serviceRestart() async {
        let rig = makeRig(running: [11], observeDevices: true)
        rig.source.set(devices: [5: [42], 11: [42]])
        let events = LineLog()
        rig.control.onServiceRestarted = { events.add("restarted") }
        rig.control.onRebuild = { _, aggregate, reason in events.add("rebuild \(aggregate) \(reason.rawValue)") }
        rig.startAttached()
        rig.control.setListed([11])
        rig.source.send(.processChanged(11))
        rig.flush()
        #expect(rig.backend.ioLog == ["start 200"])
        #expect(rig.source.classifications(of: 42) == 1)

        // The restarted daemon's 7 plays: nothing may reach the dead aggregate 200
        rig.source.set(processes: [7, 11], running: [7])
        rig.source.send(.serviceRestarted)
        rig.flush()
        rig.flush()  // the re-registration the event queued
        #expect(events.all == ["restarted"])
        #expect(rig.backend.ioLog == ["start 200"])
        #expect(rig.source.starts == 2)
        #expect(rig.source.stops == 1)
        #expect(rig.source.observed == [7, 11])
        #expect(rig.source.abnormalStops.isEmpty)
        #expect(rig.source.classifications(of: 42) == 2)
        let (attached, listed) = rig.control.sync { ($0.handles.keys.sorted(), $0.listed) }
        #expect(attached.isEmpty)
        #expect(listed.isEmpty)

        // The owner detaches the dead handle (no stop) and attaches the rebuilt one
        let detached = await rig.control.detach(rig.handle)
        #expect(detached)
        let rebuilt = makeHandle(aggregate: 300)
        rig.control.attach(rebuilt, deviceID: 42, excluded: [5])
        rig.flush()
        #expect(rig.backend.ioLog == ["start 200", "start 300"])
        #expect(rig.source.abnormalStops == [300])
    }

    @Test("Events queued behind a service restart neither rebuild the dead aggregate nor read old process IDs")
    func eventsQueuedBehindRestart() {
        let rig = makeRig(running: [11])
        let events = LineLog()
        rig.control.onServiceRestarted = { events.add("restarted") }
        rig.control.onRebuild = { _, aggregate, reason in events.add("rebuild \(aggregate) \(reason.rawValue)") }
        rig.startAttached()
        let reads = rig.source.outputReads(of: 11)

        // The HAL queued these before the re-registration removed their listeners
        let gate = DispatchSemaphore(value: 0)
        rig.control.queue.async { gate.wait() }
        rig.source.send(.serviceRestarted)
        rig.source.send(.ioStoppedAbnormally(200))
        rig.source.send(.processChanged(11))
        gate.signal()
        rig.flush()
        rig.flush()  // the re-registration the restart queued
        #expect(events.all == ["restarted"])
        // Only the read after the re-registration
        #expect(rig.source.outputReads(of: 11) == reads + 1)
    }

    @Test("Reports from the restarted daemon reach main after the owner's restart hop, older ones never")
    func restartOrdersReports() async {
        let rig = makeRig(observeDevices: true)
        rig.source.set(devices: [5: [], 11: [42]])
        let batches = LineLog()
        rig.control.onDevicesChanged = { reports in batches.add(describe(reports)) }
        rig.control.onServiceRestarted = { _ = Task { @MainActor in batches.add("restarted") } }
        // Main stays busy with this test until the wait below, so the first report task waits
        rig.startAttached()

        rig.source.set(processes: [7], running: [])
        rig.source.set(devices: [7: [43]])
        rig.source.send(.serviceRestarted)
        rig.flush()
        rig.flush()  // the re-registration and reads the restart queued
        await waitForMain { batches.all.count >= 2 }
        #expect(batches.all == ["restarted", "7 [43] silent"])
    }

    @Test("Before start() and after stop() nothing is observed, read or started, also by a timer event")
    func nothingWhileNotStarted() {
        let rig = makeRig(running: [11])
        rig.control.attach(rig.handle, deviceID: 42, excluded: [5])
        rig.control.setListed([11])
        rig.flush()
        rig.control.tickOnQueueForTesting()
        #expect(rig.source.observed.isEmpty)
        #expect(rig.source.abnormalStops.isEmpty)
        #expect(rig.backend.log.isEmpty)

        rig.control.start()
        rig.flush()
        #expect(rig.source.observed == [5, 11])
        #expect(rig.source.abnormalStops == [200])
        #expect(rig.backend.log == ["start"])

        #expect(rig.control.stop())
        rig.control.attach(rig.handle, deviceID: 42, excluded: [5])
        rig.flush()
        rig.control.tickOnQueueForTesting()
        #expect(rig.source.observed.isEmpty)
        #expect(rig.backend.log == ["start", "stop"])

        rig.control.start()
        rig.flush()
        #expect(rig.source.observed == [5, 11])
        #expect(rig.source.abnormalStops == [200])
        #expect(rig.backend.log == ["start", "stop", "start"])
    }

    @Test("A failed listener registration is registered again after a delay")
    func listenerRetry() async {
        let rig = makeRig(running: [11])
        rig.source.failingStarts = 1
        rig.startAttached()
        #expect(rig.backend.log == ["start"])

        for _ in 0..<200 where rig.source.starts < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        rig.flush()
        #expect(rig.source.starts == 2)
        #expect(rig.source.stops == 1)
        #expect(rig.source.observed == [5, 11])
        #expect(rig.source.abnormalStops == [200])
        #expect(rig.backend.log == ["start"])
    }

    @Test("A retry scheduled before stop() and start() does nothing")
    func staleListenerRetry() async {
        let rig = makeRig(running: [11])
        rig.source.failingStarts = 1
        rig.startAttached()
        #expect(rig.control.stop())
        rig.control.start()
        rig.flush()
        #expect(rig.source.starts == 2)

        // The retry was due 1 s after the failed start
        try? await Task.sleep(for: .milliseconds(1_500))
        rig.flush()
        #expect(rig.source.starts == 2)
        #expect(rig.source.stops == 1)
    }

    @Test("stop() and sync() called on the run queue itself run at once")
    func callsOnQueueRunInline() {
        let rig = makeRig(running: [11])
        rig.startAttached()
        let (stopped, running) = rig.control.queue.sync { (rig.control.stop(), rig.control.sync { $0.anyRunning }) }
        #expect(stopped)
        #expect(!running)
        #expect(rig.backend.log == ["start", "stop"])
    }

    @Test("Follow-up reads follow notifications only, not the post-stop recheck")
    func followUpsOnlyAfterNotifications() async {
        // FineTune itself (5, excluded) runs IO without output; reading it starts nothing.
        // The timer's real 2 s tick must not run between the clock advance and the manual
        // tick: it would stop and recheck first, and the manual tick would re-read again.
        // With one handle and nothing capped, the interval only sets the timer's period.
        var logic = CatchAllRunLogic()
        logic.tickInterval = 3_600
        let rig = makeRig(logic: logic)
        rig.source.set(processes: [5, 11], running: [11], runningIO: [5, 11])
        rig.startAttached()
        for _ in 0..<100 where rig.source.outputReads(of: 5) < 4 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        rig.flush()
        // The read on appearance and three follow-ups
        #expect(rig.source.outputReads(of: 5) == 4)

        rig.source.set(processes: [5, 11], running: [], runningIO: [5])
        rig.source.send(.processChanged(11))
        rig.flush()
        rig.clock.advance(seconds: 10)
        rig.state.lastCallbackHostTime.store(rig.clock.now(), ordering: .relaxed)
        rig.control.tickOnQueueForTesting()
        #expect(rig.backend.log == ["start", "stop"])
        try? await Task.sleep(for: .milliseconds(200))
        rig.flush()
        // The recheck's read only
        #expect(rig.source.outputReads(of: 5) == 5)
    }

    @Test("Devices are observed for every process; main gets one coalesced report per changed pair")
    func devicesReportsOnMain() async {
        let rig = makeRig(observeDevices: true)
        rig.source.set(devices: [5: [], 11: [42]])
        let batches = LineLog()
        rig.control.onDevicesChanged = { reports in batches.add(describe(reports)) }
        rig.startAttached()
        #expect(rig.source.devicesObserved == [5, 11])
        await waitForMain { !batches.all.isEmpty }
        #expect(batches.all == ["5 [] silent; 11 [42] silent"])

        // The same read again: no report
        rig.source.send(.processChanged(11))
        rig.flush()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(batches.all.count == 1)

        // Output under an unchanged list changes the pair
        rig.source.set(processes: [5, 11], running: [11])
        rig.source.send(.processChanged(11))
        rig.flush()
        await waitForMain { batches.all.count == 2 }
        #expect(batches.all == ["5 [] silent; 11 [42] silent", "11 [42] output"])
    }

    @Test("Main gets a batch's reports before its process list change, as the queue posted them")
    func reportsBeforeListChange() async {
        let rig = makeRig(observeDevices: true)
        rig.source.set(devices: [5: [], 11: [42]])
        let calls = LineLog()
        rig.control.onDevicesChanged = { reports in calls.add(describe(reports)) }
        rig.control.onProcessListChanged = { calls.add("list changed") }
        // Main runs nothing before the await, so the first refresh's reports and its list
        // change go to main in one batch
        rig.startAttached()
        await waitForMain { calls.all.count == 2 }
        #expect(calls.all == ["5 [] silent; 11 [42] silent", "list changed"])
    }

    @Test("Main hears once per batch that processes appeared or disappeared, never for an unchanged list")
    func processListChangesOnMain() async {
        let rig = makeRig()
        let changes = LineLog()
        rig.control.onProcessListChanged = { changes.add("changed") }
        rig.startAttached()
        await waitForMain { !changes.all.isEmpty }
        #expect(changes.all == ["changed"])

        // The same list again: nothing
        rig.source.send(.processListChanged)
        rig.flush()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(changes.all.count == 1)

        // A process quits and another appears: one call
        rig.source.set(processes: [5, 12], running: [])
        rig.source.send(.processListChanged)
        rig.flush()
        await waitForMain { changes.all.count == 2 }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(changes.all.count == 2)
    }

    @Test("A refresh starts the catch-all before it reads Devices")
    func startBeforeDevicesRead() {
        let rig = makeRig(observeDevices: true)
        rig.startAttached()
        let backend = rig.backend
        let reads = LineLog()
        rig.source.onDevicesRead = { process in reads.add("\(process) after \(backend.ioLog.joined(separator: ","))") }

        rig.source.set(processes: [5, 11], running: [11])
        rig.source.send(.processChanged(11))
        rig.flush()
        #expect(reads.all == ["11 after start 200"])
    }

    @Test("A re-read applies every run state before it reads any Devices, and only of new processes")
    func rereadStartsBeforeDevicesReads() {
        let rig = makeRig(observeDevices: true)
        rig.startAttached()
        let backend = rig.backend
        let reads = LineLog()
        rig.source.onDevicesRead = { process in reads.add("\(process) after \(backend.ioLog.joined(separator: ","))") }

        // 12 and 13 appeared unnoticed; only 13 plays
        rig.source.set(processes: [5, 11, 12, 13], running: [13])
        rig.control.tickOnQueueForTesting()
        #expect(reads.all == ["12 after start 200", "13 after start 200"])
    }

    @Test("After stop() a pending report is dropped; after start() main gets every report again")
    func reportsAfterStopAndStart() async {
        let rig = makeRig(observeDevices: true)
        rig.source.set(devices: [5: [], 11: [42]])
        let batches = LineLog()
        rig.control.onDevicesChanged = { reports in batches.add(describe(reports)) }
        rig.startAttached()
        #expect(rig.control.stop())
        try? await Task.sleep(for: .milliseconds(50))
        #expect(batches.all.isEmpty)

        rig.control.start()
        rig.flush()
        await waitForMain { !batches.all.isEmpty }
        #expect(batches.all == ["5 [] silent; 11 [42] silent"])
        #expect(rig.source.classifications(of: 42) == 2)
    }

    @Test("A detach that times out tells the caller the queued detach has not run yet")
    func detachTimeout() async {
        let rig = makeRig(running: [11], waitTimeout: 0.05)
        rig.startAttached()
        let gate = DispatchSemaphore(value: 0)
        rig.control.queue.async { gate.wait() }

        let detached = await rig.control.detach(rig.handle)
        #expect(!detached)
        #expect(rig.backend.log == ["start"])

        gate.signal()
        rig.flush()
        #expect(rig.backend.log == ["start", "stop"])
    }

    @Test("stop() waits at most its timeout for a blocked queue")
    func stopTimeout() {
        let rig = makeRig(running: [11], waitTimeout: 0.05)
        rig.startAttached()
        let gate = DispatchSemaphore(value: 0)
        rig.control.queue.async { gate.wait() }

        #expect(!rig.control.stop())
        gate.signal()
        rig.flush()
        #expect(rig.backend.log == ["start", "stop"])
        #expect(rig.control.stop())
    }

    @Test("An abnormal IO stop asks for a rebuild of that handle only")
    func abnormalStop() {
        let rig = makeRig()
        rig.startAttached()

        rig.source.send(.ioStoppedAbnormally(200))
        rig.source.send(.ioStoppedAbnormally(999))
        rig.flush()

        #expect(rig.rebuilds.all == ["uid-tv 200 ioDead"])
    }

    @Test("At each liveness tick of a running catch-all, the rate check reads the aggregate's and the device's nominal rate through its reader on the run queue; two mismatches in a row ask for one rebuild, a failed read counts as a match, and a stopped or detached catch-all, or one that asked already, is not read")
    func rateCheck() async {
        let source = FakeActivitySource()
        source.set(processes: [5, 11], running: [])
        let clock = HostClock()
        let rates = FakeRates([200: 48_000, 42: 48_000])
        let reads = LineLog()
        let control = CatchAllRunControl(
            source: source, backend: FakeCatchAllBackend(), queue: DispatchQueue(label: "test.catchall.rate"),
            hostTime: { clock.now() },
            nominalRate: { device in
                reads.add("\(device) on \(String(cString: __dispatch_queue_get_label(nil)))")
                return rates.rate(device)
            })
        let rebuilds = LineLog()
        control.onRebuild = { uid, aggregate, reason in rebuilds.add("\(uid) \(aggregate) \(reason.rawValue)") }
        let handle = makeHandle(aggregate: 200)
        control.attach(handle, deviceID: 42, excluded: [5])
        control.start()
        control.queue.sync {}
        /// One liveness tick 2 s later, with a fresh callback.
        func tick() {
            clock.advance(seconds: 2)
            handle.state.lastCallbackHostTime.store(clock.now(), ordering: .relaxed)
            control.tickOnQueueForTesting()
        }

        // Stopped: nothing is read
        tick()
        #expect(reads.all.isEmpty)

        source.set(processes: [5, 11], running: [11])
        source.send(.processChanged(11))
        control.queue.sync {}
        tick()
        #expect(reads.all == ["200 on test.catchall.rate", "42 on test.catchall.rate"])

        // The device changed its rate, the aggregate kept the old one: one mismatch
        rates.set(42, 44_100)
        tick()
        // A failed read of the aggregate counts as a match and starts over
        rates.set(200, nil)
        tick()
        rates.set(200, 48_000)
        tick()
        #expect(rebuilds.all.isEmpty)
        tick()
        #expect(rebuilds.all == ["uid-tv 200 rateMismatch"])
        #expect(reads.all.count == 9)
        // Asked once: no further reads
        tick()
        tick()
        #expect(rebuilds.all == ["uid-tv 200 rateMismatch"])
        #expect(reads.all.count == 9)

        let detached = await control.detach(handle)
        #expect(detached)
        tick()
        #expect(reads.all.count == 9)
    }

    @Test("A liveness tick reports dead IO before it reads any rate, and never reads the rate of a catch-all whose IO has not called back within the liveness timeout")
    func rateReadsAfterLiveness() async {
        let source = FakeActivitySource()
        source.set(processes: [5, 11], running: [11])
        let clock = HostClock()
        let rates = FakeRates([200: 48_000, 42: 48_000, 201: 48_000, 43: 48_000])
        // One ordered log for the reads and the reports, both on the queue
        let log = LineLog()
        let control = CatchAllRunControl(
            source: source, backend: FakeCatchAllBackend(), queue: DispatchQueue(label: "test.catchall.order"),
            hostTime: { clock.now() },
            nominalRate: { device in
                log.add("read \(device)")
                return rates.rate(device)
            })
        control.onRebuild = { uid, aggregate, reason in log.add("rebuild \(aggregate) \(reason.rawValue)") }
        // Two catch-alls run for process 11: the TV's IO dies, the other's keeps calling back
        let dying = makeHandle(aggregate: 200)
        let other = makeHandle(aggregate: 201)
        control.attach(dying, deviceID: 42, excluded: [5])
        control.attach(other, deviceID: 43, excluded: [5])
        control.start()
        control.queue.sync {}

        clock.advance(seconds: 2)
        dying.state.lastCallbackHostTime.store(clock.now(), ordering: .relaxed)
        other.state.lastCallbackHostTime.store(clock.now(), ordering: .relaxed)
        control.tickOnQueueForTesting()
        #expect(log.all == ["read 200", "read 42", "read 201", "read 43"])

        // From here only the other one calls back: two stale ticks report the TV's dead IO
        for _ in 0..<2 {
            clock.advance(seconds: 2)
            other.state.lastCallbackHostTime.store(clock.now(), ordering: .relaxed)
            control.tickOnQueueForTesting()
        }
        #expect(log.all == ["read 200", "read 42", "read 201", "read 43",
                            "read 201", "read 43",
                            "rebuild 200 ioDead", "read 201", "read 43"])
    }
}
