// FineTune/Audio/CatchAll/CatchAllHarness.swift
//
// Measurements on the user's Mac that decide whether the catch-all may be turned on
// (design §12.3). Runs once at launch when `CatchAllHarness` is set in the fork's defaults,
// with the software-volume output (the TV) as default output. Plays short quiet test tones
// with afplay. Results are logged (category CatchAllHarness, notice level) and written to
// ~/Library/Logs/FineTune Fork/catchall-harness.txt.

import AppKit
import AudioToolbox
import Foundation
import os
import Synchronization

@MainActor
final class CatchAllHarness {
    struct Target {
        let uid: String
        let deviceID: AudioDeviceID
        let selfObject: AudioObjectID
    }

    private let target: Target
    private let backend: any CatchAllBackend
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.finetuneapp.FineTune", category: "CatchAllHarness")
    private var lines: [String] = []
    private let reportURL: URL
    private let toneURL: URL
    private let longToneURL: URL

    init(target: Target, backend: any CatchAllBackend = CoreAudioCatchAllBackend()) {
        self.target = target
        self.backend = backend
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/FineTune Fork", isDirectory: true)
        reportURL = logs.appendingPathComponent("catchall-harness.txt")
        let temp = FileManager.default.temporaryDirectory
        toneURL = temp.appendingPathComponent("finetune-harness-tone.wav")
        longToneURL = temp.appendingPathComponent("finetune-harness-tone-long.wav")
    }

    /// Checks the preconditions and runs `steps`. Clears the request first, so a crash
    /// during the harness does not repeat it on the next launch.
    static func runIfRequested(
        settings: CatchAllSettings,
        defaults: UserDefaults = .standard,
        defaultOutputUID: String?,
        deviceID: (String) -> AudioDeviceID?,
        tier: (AudioDeviceID) -> VolumeControlTier,
        permissionAuthorized: Bool
    ) async {
        guard let steps = settings.harnessSteps else { return }
        defaults.removeObject(forKey: CatchAllSettings.harnessKey)
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.finetuneapp.FineTune", category: "CatchAllHarness")
        guard permissionAuthorized else {
            logger.error("Harness not run: audio capture is not authorized")
            return
        }
        guard let uid = defaultOutputUID, let id = deviceID(uid), tier(id) == .software else {
            logger.error("Harness not run: the default output is not a software-volume device")
            return
        }
        let selfObject = ProcessIdentity.processObject(forPID: getpid())
        guard selfObject != AudioObjectID(kAudioObjectUnknown) else {
            logger.error("Harness not run: FineTune has no Core Audio process object")
            return
        }
        await CatchAllHarness(target: Target(uid: uid, deviceID: id, selfObject: selfObject)).run(steps)
    }

    func run(_ steps: [CatchAllHarnessStep]) async {
        report("Catch-all harness: \(steps.map(\.rawValue).joined(separator: ",")) on \(target.uid), self object \(target.selfObject)")
        do {
            try HarnessTone.write(to: toneURL, seconds: 0.6)
            try HarnessTone.write(to: longToneURL, seconds: 12)
        } catch {
            report("ABORT: could not write test tones: \(error.localizedDescription)")
            save()
            return
        }
        for step in steps {
            report("--- \(step.rawValue)")
            switch step {
            case .h0: await h0Build()
            case .h1: await h1NewProcessCaptured()
            case .h2: await h2ExclusionUpdates()
            case .h3: await h3SelfNotCaptured()
            case .h7: await h7ResumeLatency()
            case .h8: await h8MutedProcessReports()
            }
            save()
        }
        report("Done")
        save()
    }

    // MARK: - Steps

    private func h0Build() async {
        var failures = 0
        for attempt in 1...3 {
            let start = ContinuousClock.now
            do {
                let ca = try build(observe: true, exclusions: [target.selfObject])
                let ms = (ContinuousClock.now - start).milliseconds
                report("build \(attempt): \(format(ms)) ms, tap UID assigned \(ca.assignedTapUID == ca.requestedTapUID ? "= requested" : "≠ requested"), exclusive read-back ok")
                await ca.destroy()
            } catch {
                failures += 1
                report("build \(attempt) FAILED: \(error)")
            }
        }
        verdict(failures == 0, "H0 builds")
    }

    private func h1NewProcessCaptured() async {
        guard let ca = try? build(observe: true, exclusions: [target.selfObject]), await startIO(ca) else {
            return verdict(false, "H1 (catch-all could not start)")
        }
        var deltas: [Double] = []
        var missed = 0
        for _ in 1...10 {
            let baseline = ca.renderState.lastAudibleHostTime.load(ordering: .relaxed)
            guard let player = HarnessPlayer.start(toneURL, volume: 0.02),
                  let object = await processObject(of: player),
                  let rise = await poll(timeout: 2, { ProcessIdentity.isRunningOutput(object) }) else {
                missed += 1
                continue
            }
            if let heard = await poll(timeout: 1, { ca.renderState.lastAudibleHostTime.load(ordering: .relaxed) > baseline }) {
                deltas.append(max(0, (heard - rise).milliseconds))
            } else {
                missed += 1
            }
            await player.wait()
        }
        report("output start → first audible catch-all buffer: \(stats(deltas)), missed \(missed)")
        await stopIO(ca)
        await ca.destroy()
        verdict(missed == 0 && percentile(deltas, 0.95) <= 25, "H1 new processes captured from the first buffers (p95 ≤ 25 ms)")
    }

    private func h2ExclusionUpdates() async {
        guard let player = HarnessPlayer.start(longToneURL, volume: 0.02), let object = await processObject(of: player) else {
            return verdict(false, "H2 (test tone did not start)")
        }
        defer { player.stop() }
        guard let ca = try? build(observe: true, exclusions: [target.selfObject]), await startIO(ca),
              await poll(timeout: 2, { ca.renderState.lastAudibleHostTime.load(ordering: .relaxed) > 0 }) != nil else {
            return verdict(false, "H2 (catch-all did not hear the tone)")
        }
        var excludeMs: [Double] = []
        var includeMs: [Double] = []
        var rejected = 0
        for _ in 1...20 {
            guard ca.push([target.selfObject, object].sorted()) else { rejected += 1; continue }
            let excluded = ContinuousClock.now
            if let silentSince = await waitForSilence(ca, quiet: 0.05, timeout: 1) {
                excludeMs.append(max(0, (silentSince - excluded).milliseconds))
            }
            guard ca.push([target.selfObject]) else { rejected += 1; continue }
            let included = ContinuousClock.now
            let mark = ca.renderState.lastAudibleHostTime.load(ordering: .relaxed)
            if let heard = await poll(timeout: 1, { ca.renderState.lastAudibleHostTime.load(ordering: .relaxed) > mark }) {
                includeMs.append(max(0, (heard - included).milliseconds))
            }
        }
        report("exclude takes effect: \(stats(excludeMs)); include: \(stats(includeMs)); rejected pushes \(rejected)")
        await stopIO(ca)
        await ca.destroy()
        let p99 = max(percentile(excludeMs, 0.99), percentile(includeMs, 0.99))
        verdict(rejected == 0 && excludeMs.count == 20 && includeMs.count == 20 && p99 < 50,
                "H2 live exclusion updates (all accepted, p99 < 50 ms)")
    }

    private func h3SelfNotCaptured() async {
        // (a) A sound FineTune plays itself
        guard let ca = try? build(observe: true, exclusions: [target.selfObject]), await startIO(ca) else {
            return verdict(false, "H3 (catch-all could not start)")
        }
        let sound = NSSound(contentsOf: toneURL, byReference: true)
        sound?.volume = 0.05
        sound?.play()
        let inProcessHeard = await poll(timeout: 1, { ca.renderState.lastAudibleHostTime.load(ordering: .relaxed) > 0 }) != nil
        sound?.stop()
        await stopIO(ca)
        await ca.destroy()
        report("in-process sound captured: \(inProcessHeard ? "YES" : "no")")

        // (b) The output of a per-app tap (FineTune's aggregate) on an excluded process
        guard let player = HarnessPlayer.start(longToneURL, volume: 0.02), let object = await processObject(of: player) else {
            return verdict(false, "H3 (test tone did not start)")
        }
        defer { player.stop() }
        let app = AudioApp(id: player.pid, processObjectIDs: [object], name: "afplay", icon: NSImage(), bundleID: nil)
        let perApp = ProcessTapController(app: app, targetDeviceUID: target.uid)
        guard let excluding = try? build(observe: true, exclusions: [target.selfObject, object].sorted()),
              (try? perApp.activate()) != nil, await startIO(excluding) else {
            perApp.invalidate()
            return verdict(false, "H3 (per-app tap or catch-all could not start)")
        }
        let perAppHeard = await poll(timeout: 1.5, { excluding.renderState.lastAudibleHostTime.load(ordering: .relaxed) > 0 }) != nil
        perApp.invalidate()
        await stopIO(excluding)
        await excluding.destroy()
        report("per-app tap output captured: \(perAppHeard ? "YES" : "no")")
        verdict(!inProcessHeard && !perAppHeard, "H3 FineTune's own output is not captured")
    }

    private func h7ResumeLatency() async {
        // Muted and held at gain 0: covered test tones are held back and stay silent
        guard let ca = try? build(observe: false, held: true, exclusions: [target.selfObject]) else {
            return verdict(false, "H7 (catch-all could not be built)")
        }
        var logic = CatchAllRunLogic()
        logic.suspendDelay = 1
        let control = CatchAllRunControl(source: HALProcessOutputActivitySource(), backend: backend, logic: logic)
        control.attach(ca.ioHandle, deviceID: target.deviceID, excluded: [target.selfObject])
        control.start()
        var deltas: [Double] = []
        var missed = 0
        for _ in 1...10 {
            // Let the catch-all suspend between runs
            _ = await poll(timeout: 4, { !control.sync { $0.anyRunning } })
            let baseline = ca.renderState.lastAudibleHostTime.load(ordering: .relaxed)
            guard let player = HarnessPlayer.start(toneURL, volume: 0.3),
                  let object = await processObject(of: player),
                  let rise = await poll(timeout: 2, { ProcessIdentity.isRunningOutput(object) }),
                  let heard = await poll(timeout: 1, { ca.renderState.lastAudibleHostTime.load(ordering: .relaxed) > baseline }) else {
                missed += 1
                continue
            }
            deltas.append(max(0, (heard - rise).milliseconds))
            await player.wait()
        }
        await control.detach(target.uid)
        control.stop()
        await ca.destroy()
        report("stopped catch-all: output start → first audible buffer: \(stats(deltas)), missed \(missed) (tones were held, nothing should have been audible)")
        verdict(missed == 0 && percentile(deltas, 0.95) < 50, "H7 resume latency (p95 < 50 ms)")
    }

    private func h8MutedProcessReports() async {
        guard let ca = try? build(observe: false, held: true, exclusions: [target.selfObject]), await startIO(ca) else {
            return verdict(false, "H8 (catch-all could not start)")
        }
        report("H8 plays a held tone at 30 % for 2 s: it must not be audible")
        var running = false
        var reportsDevice = false
        if let player = HarnessPlayer.start(longToneURL, volume: 0.3), let object = await processObject(of: player) {
            running = await poll(timeout: 2, { ProcessIdentity.isRunningOutput(object) }) != nil
            let devices = (try? object.readArray(kAudioProcessPropertyDevices, scope: .output, defaultValue: AudioDeviceID(0))) ?? []
            reportsDevice = devices.contains(target.deviceID)
            report("muted process: IsRunningOutput \(running), output devices \(devices) (TV \(target.deviceID))")
            try? await Task.sleep(for: .seconds(2))
            player.stop()
        }
        await stopIO(ca)
        await ca.destroy()
        verdict(running && reportsDevice, "H8 muted processes report output and device (device filter may be enabled)")
    }

    // MARK: - Helpers

    private func build(observe: Bool, held: Bool = true, exclusions: [AudioObjectID]) throws -> CatchAllTapController {
        try CatchAllTapController.build(deviceUID: target.uid, exclusions: exclusions, gain: 0,
                                        held: held, observe: observe, backend: backend)
    }

    private func startIO(_ ca: CatchAllTapController) async -> Bool {
        guard backend.start(ca.ioHandle.aggregateID, ca.ioHandle.procID) == noErr else { return false }
        return await poll(timeout: 1, { ca.callbackCount > 0 }) != nil
    }

    private func stopIO(_ ca: CatchAllTapController) async {
        _ = backend.stop(ca.ioHandle.aggregateID, ca.ioHandle.procID)
    }

    private func processObject(of player: HarnessPlayer) async -> AudioObjectID? {
        var object = AudioObjectID(kAudioObjectUnknown)
        _ = await poll(timeout: 2, {
            object = ProcessIdentity.processObject(forPID: player.pid)
            return object != AudioObjectID(kAudioObjectUnknown)
        })
        return object == AudioObjectID(kAudioObjectUnknown) ? nil : object
    }

    /// Polls every millisecond; returns the instant `condition` first held, or nil on timeout.
    private func poll(timeout: Double, _ condition: () -> Bool) async -> ContinuousClock.Instant? {
        let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
        while ContinuousClock.now < deadline {
            if condition() { return .now }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return nil
    }

    /// The instant the catch-all last heard input, once it has heard nothing for `quiet` seconds.
    private func waitForSilence(_ ca: CatchAllTapController, quiet: Double, timeout: Double) async -> ContinuousClock.Instant? {
        var last = ca.renderState.lastAudibleHostTime.load(ordering: .relaxed)
        var lastChange = ContinuousClock.now
        let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
        while ContinuousClock.now < deadline {
            let current = ca.renderState.lastAudibleHostTime.load(ordering: .relaxed)
            if current != last {
                last = current
                lastChange = .now
            } else if ContinuousClock.now - lastChange > .milliseconds(Int(quiet * 1000)) {
                return lastChange
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return nil
    }

    private func stats(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "no samples" }
        return "n=\(values.count) p50 \(format(percentile(values, 0.5))) ms, p95 \(format(percentile(values, 0.95))) ms, max \(format(values.max() ?? 0)) ms"
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .infinity }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded(.up)))]
    }

    private func format(_ value: Double) -> String { String(format: "%.1f", value) }

    private func verdict(_ passed: Bool, _ what: String) {
        report("\(passed ? "PASS" : "FAIL"): \(what)")
    }

    private func report(_ line: String) {
        lines.append(line)
        logger.notice("\(line, privacy: .public)")
    }

    private func save() {
        try? FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: reportURL, atomically: true, encoding: .utf8)
    }
}

private extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}

/// A 440 Hz sine test tone as 16-bit mono WAV.
nonisolated enum HarnessTone {
    static func data(seconds: Double, sampleRate: Int = 48_000, frequency: Double = 440) -> Data {
        let frames = Int(seconds * Double(sampleRate))
        var data = Data(capacity: 44 + frames * 2)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + frames * 2))
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(frames * 2))
        for i in 0..<frames {
            let sample = sin(2 * .pi * frequency * Double(i) / Double(sampleRate)) * 0.8
            append(Int16(sample * Double(Int16.max)))
        }
        return data
    }

    static func write(to url: URL, seconds: Double) throws {
        try data(seconds: seconds).write(to: url, options: .atomic)
    }
}

/// An afplay process playing a test tone.
@MainActor
final class HarnessPlayer {
    let process: Process
    var pid: pid_t { process.processIdentifier }

    private init(process: Process) { self.process = process }

    static func start(_ file: URL, volume: Double) -> HarnessPlayer? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = ["-v", String(volume), file.path]
        do { try process.run() } catch { return nil }
        return HarnessPlayer(process: process)
    }

    func wait() async {
        while process.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }
}
