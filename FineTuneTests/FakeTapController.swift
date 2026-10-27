// FineTuneTests/FakeTapController.swift
//
// A ProcessTapControlling fake that models the fork's tap lifecycle: suspend/resume,
// process-set updates and the gain the tap was started with. Engine tests use it to
// assert what a real tap would play with, without touching Core Audio.

import Foundation
@testable import FineTune

struct FakeTapError: Error {}

@MainActor
final class FakeTapController: ProcessTapControlling {
    private(set) var app: AudioApp

    var volume: Float = 1.0
    var isMuted = false {
        didSet { onEvent?("mute \(isMuted)") }
    }
    var currentDeviceVolume: Float = 1.0
    var isDeviceMuted = false
    var audioLevel: Float = 0.0
    private(set) var currentDeviceUIDs: [String]
    var currentDeviceUID: String? { currentDeviceUIDs.first }
    var tapSourceDeviceUID: String?

    /// `volume` at the moment `activate` ran: the gain of the first IO cycle.
    private(set) var volumeAtActivate: Float?
    private(set) var isMutedAtActivate: Bool?
    private(set) var isInvalidated = false

    /// Reports lifecycle events ("activate", "mute true", "invalidate") to the factory's log.
    var onEvent: ((String) -> Void)?

    private(set) var isSuspended = false
    private(set) var suspendCount = 0
    private(set) var resumeCount = 0
    /// When set, `resume()` throws instead of restarting IO.
    var resumeError: Error?

    /// What `updateProcesses(for:)` reports back; false means Core Audio rejected it.
    var updateProcessesResult = true
    private(set) var updateProcessesCalls: [AudioApp] = []

    init(app: AudioApp, deviceUIDs: [String]) {
        self.app = app
        self.currentDeviceUIDs = deviceUIDs
    }

    func activate(initial: TapInitialState) throws {
        volumeAtActivate = volume
        isMutedAtActivate = isMuted
        onEvent?("activate")
    }

    func invalidate() {
        isInvalidated = true
        onEvent?("invalidate")
    }

    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        suspendCount += 1
    }

    func resume() throws {
        guard isSuspended else { return }
        if let resumeError { throw resumeError }
        isSuspended = false
        resumeCount += 1
    }

    func updateProcesses(for newApp: AudioApp) -> Bool {
        updateProcessesCalls.append(newApp)
        if updateProcessesResult { app = newApp }
        return updateProcessesResult
    }

    func updateEQSettings(_ settings: EQSettings) {}
    func updateAutoEQProfile(_ profile: AutoEQProfile?) {}
    func setAutoEQPreampEnabled(_ enabled: Bool) {}
    func updateLoudnessCompensation(listeningVolume: Float, digitalGain: Float, enabled: Bool) {}
    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings) {}

    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool, autoEQProfile: AutoEQProfile?) async throws {
        currentDeviceUIDs = [newDeviceUID]
    }

    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool, autoEQProfile: AutoEQProfile?) async throws {
        currentDeviceUIDs = newDeviceUIDs
    }

    func hasRecentAudioCallback(within seconds: Double) -> Bool { true }
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool { false }
}

/// Collects every tap a test engine's factory hands out, with an ordered event log
/// such as ["create 0", "activate 0", "mute true 0", "create 1", ..., "invalidate 0"].
@MainActor
final class FakeTapFactory {
    private(set) var created: [FakeTapController] = []
    private(set) var log: [String] = []
    var last: FakeTapController? { created.last }
    /// When true, creating a tap fails like a Core Audio error would.
    var failCreations = false

    func make(app: AudioApp, deviceUIDs: [String]) throws -> FakeTapController {
        if failCreations { throw FakeTapError() }
        let index = created.count
        let tap = FakeTapController(app: app, deviceUIDs: deviceUIDs)
        log.append("create \(index)")
        tap.onEvent = { [weak self] event in self?.log.append("\(event) \(index)") }
        created.append(tap)
        return tap
    }

    /// Position of `event` in the log, for ordering assertions.
    func position(of event: String) -> Int? {
        log.firstIndex(of: event)
    }
}

/// Gives tasks the engine scheduled on the main actor time to run, so a test can assert
/// that something did not happen afterwards (e.g. no tap recreation).
@MainActor
func settle() async {
    try? await Task.sleep(for: .milliseconds(50))
}

/// Polls `condition` on the main actor until it holds or `timeout` passes. For
/// engine paths that hop through an unstructured Task (e.g. tap recreation).
@MainActor
func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
