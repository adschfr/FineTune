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
    private let plainToneURL: URL
    private let panel = HarnessPanel()
    private var verdicts: [String] = []

    init(target: Target, backend: any CatchAllBackend = CoreAudioCatchAllBackend()) {
        self.target = target
        self.backend = backend
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/FineTune Fork", isDirectory: true)
        reportURL = logs.appendingPathComponent("catchall-harness.txt")
        let temp = FileManager.default.temporaryDirectory
        toneURL = temp.appendingPathComponent("finetune-harness-tone.wav")
        longToneURL = temp.appendingPathComponent("finetune-harness-tone-long.wav")
        plainToneURL = temp.appendingPathComponent("finetune-harness-tone-plain.wav")
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
        panel.show()
        report("Catch-all harness: \(steps.map(\.rawValue).joined(separator: ",")) on \(target.uid), self object \(target.selfObject)")
        do {
            try HarnessTone.write(to: toneURL, seconds: 0.6, rampSeconds: HarnessTone.onsetRampSeconds)
            try HarnessTone.write(to: longToneURL, seconds: 12)
            try HarnessTone.write(to: plainToneURL, seconds: 0.4)
        } catch {
            report("ABORT: could not write test tones: \(error.localizedDescription)")
            panel.finish(summary: "Abgebrochen: Testtöne konnten nicht geschrieben werden.")
            save()
            return
        }
        await panel.announce(step: "Vorbereitung", headline: "Prüfe, ob gerade etwas spielt",
                             detail: "Bitte nichts abspielen, bis die Messung fertig ist.", expectation: .info, seconds: 2)
        guard await isQuiet() else {
            report("ABORT: other audio is playing. Stop all playback and request the harness again.")
            panel.finish(summary: "Abgebrochen: Es lief gerade anderer Ton. Wiedergabe stoppen und neu anfordern.")
            save()
            return
        }
        for (index, step) in steps.enumerated() {
            let label = "Schritt \(index + 1) von \(steps.count): \(step.rawValue)"
            report("--- \(step.rawValue)")
            switch step {
            case .l0: await l0Control(label)
            case .h0: await automated(label, "Aufbau der Catch-all", "Kein Ton.", .info) { await h0Build() }
            case .h1: await automated(label, "Neue Prozesse erfassen", "Zehn leise Töne, hörbar ist normal.", .info) { await h1NewProcessCaptured() }
            case .h2: await automated(label, "Ausschlussliste live ändern", "Ein leiser Dauerton, hörbar ist normal.", .info) { await h2ExclusionUpdates() }
            case .h3: await automated(label, "Eigener Ton wird nicht erfasst", "Leise Töne, hörbar ist normal.", .info) { await h3SelfNotCaptured() }
            case .h1m: await h1mHeldRunning(label)
            case .h7: await automated(label, "Wiederanlauf messen", "Zehn zurückgehaltene Töne.", .silent) { await h7ResumeLatency() }
            case .h7m: await h7mHeldStopped(label)
            case .h8: await automated(label, "Gehaltener Prozess meldet Gerät", "Ein zurückgehaltener Ton.", .silent) { await h8MutedProcessReports() }
            }
            save()
        }
        report("Done")
        panel.finish(summary: verdicts.joined(separator: "\n"))
        save()
    }

    /// Runs a measuring step and shows it in the panel while it runs.
    private func automated(_ label: String, _ headline: String, _ detail: String,
                           _ expectation: HarnessPanelModel.Expectation, _ body: () async -> Void) async {
        await panel.announce(step: label, headline: headline, detail: detail, expectation: expectation, seconds: 1)
        panel.playing(true)
        await body()
        panel.playing(false)
    }

    /// Counts down, plays, then asks the user what they heard and records the answer.
    private func listen(_ label: String, headline: String, detail: String,
                        expectation: HarnessPanelModel.Expectation, play: () async -> Void) async -> String {
        await panel.announce(step: label, headline: headline, detail: detail, expectation: expectation)
        panel.playing(true)
        await play()
        let answer = await panel.ask("Was hast du gehört?", options: ["Nichts gehört", "Kurzes Knacken", "Ton gehört"])
        report("\(label): user heard: \(answer)")
        return answer
    }

    // MARK: - Steps

    private func l0Control(_ label: String) async {
        let answer = await listen(label, headline: "Kontrollton",
                                  detail: "Drei kurze Töne bei 10 %, ohne Catch-all. Sie sollten hörbar sein.",
                                  expectation: .audible) {
            for _ in 1...3 {
                if let player = HarnessPlayer.start(plainToneURL, volume: 0.1) { await player.wait() }
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
        verdict(answer == "Ton gehört", "L0 control tones audible (audio path works)")
    }

    private func h1mHeldRunning(_ label: String) async {
        guard let ca = try? build(observe: false, held: true, exclusions: [target.selfObject]), await startIO(ca) else {
            return verdict(false, "H1M (catch-all could not start)")
        }
        let answer = await listen(label, headline: "Laufende Catch-all hält zurück",
                                  detail: "Fünf kurze Töne bei 10 %. Die Catch-all hält sie zurück: Es sollte NICHTS zu hören sein, auch kein Knacken.",
                                  expectation: .silent) {
            for _ in 1...5 {
                if let player = HarnessPlayer.start(plainToneURL, volume: 0.1) { await player.wait() }
                try? await Task.sleep(for: .milliseconds(800))
            }
        }
        await stopIO(ca)
        await ca.destroy()
        verdict(answer == "Nichts gehört", "H1M running catch-all holds plain tones back (user heard nothing)")
    }

    private func h7mHeldStopped(_ label: String) async {
        guard let ca = try? build(observe: false, held: true, exclusions: [target.selfObject]) else {
            return verdict(false, "H7M (catch-all could not be built)")
        }
        var logic = CatchAllRunLogic()
        logic.suspendDelay = 1
        let control = CatchAllRunControl(source: HALProcessOutputActivitySource(), backend: backend, logic: logic)
        control.attach(ca.ioHandle, deviceID: target.deviceID, excluded: [target.selfObject])
        control.start()
        let answer = await listen(label, headline: "Catch-all startet aus dem Stillstand",
                                  detail: "Fünf kurze Töne bei 10 %, jeweils nachdem die Catch-all angehalten hat. Es sollte NICHTS zu hören sein; ein Knacken am Tonanfang wäre ein Leck.",
                                  expectation: .silent) {
            for _ in 1...5 {
                _ = await poll(timeout: 5, { !control.sync { $0.anyRunning } })
                if let player = HarnessPlayer.start(plainToneURL, volume: 0.1) { await player.wait() }
            }
        }
        await control.detach(target.uid)
        control.stop()
        await ca.destroy()
        verdict(answer == "Nichts gehört", "H7M stopped catch-all holds plain tones back, onset included (user heard nothing)")
    }

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
        var missing: [Double] = []
        var failed = 0
        for _ in 1...10 {
            let baseline = ca.renderState.lastAudibleHostTime.load(ordering: .relaxed)
            guard let player = HarnessPlayer.start(toneURL, volume: 0.02),
                  let lost = await missingOnset(ca, after: baseline) else {
                failed += 1
                continue
            }
            missing.append(lost)
            await player.wait()
        }
        report("running catch-all: tone onset missing \(stats(missing)), not heard \(failed)")
        await stopIO(ca)
        await ca.destroy()
        verdict(failed == 0 && percentile(missing, 0.95) <= 15,
                "H1 new processes captured from their first samples (onset missing p95 ≤ 15 ms)")
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
        var missing: [Double] = []
        var failed = 0
        for _ in 1...10 {
            // Let the catch-all suspend between runs
            _ = await poll(timeout: 5, { !control.sync { $0.anyRunning } })
            let baseline = ca.renderState.lastAudibleHostTime.load(ordering: .relaxed)
            guard let player = HarnessPlayer.start(toneURL, volume: 0.05),
                  let lost = await missingOnset(ca, after: baseline) else {
                failed += 1
                continue
            }
            missing.append(lost)
            await player.wait()
        }
        await control.detach(target.uid)
        control.stop()
        await ca.destroy()
        report("stopped catch-all: tone onset lost while resuming \(stats(missing)), not heard \(failed) (tones were held, nothing should have been audible)")
        verdict(failed == 0 && percentile(missing, 0.95) <= 50, "H7 resume from a stopped catch-all (onset lost p95 ≤ 50 ms)")
    }

    private func h8MutedProcessReports() async {
        guard let ca = try? build(observe: false, held: true, exclusions: [target.selfObject]), await startIO(ca) else {
            return verdict(false, "H8 (catch-all could not start)")
        }
        report("H8 plays a held tone at 5 % for 2 s: it must not be audible")
        var running = false
        var reportsDevice = false
        if let player = HarnessPlayer.start(longToneURL, volume: 0.05), let object = await processObject(of: player) {
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

    /// Listens for 1.5 s through an observing catch-all: any other sound on the output would
    /// distort the measurements.
    private func isQuiet() async -> Bool {
        guard let ca = try? build(observe: true, exclusions: [target.selfObject]), await startIO(ca) else {
            report("quiet check: catch-all could not start")
            return false
        }
        let heard = await poll(timeout: 1.5, { ca.renderState.lastAudibleHostTime.load(ordering: .relaxed) > 0 }) != nil
        await stopIO(ca)
        await ca.destroy()
        report("quiet check: \(heard ? "audio playing" : "quiet")")
        return !heard
    }

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

    /// How many milliseconds of a ramped test tone's fade-in the catch-all missed: the ramp
    /// reaches 90 % after 180 ms, so the time from the first audible buffer to the 90 % point
    /// tells how late capture started (about ±1 buffer). nil if the tone was not heard.
    private func missingOnset(_ ca: CatchAllTapController, after baseline: UInt64) async -> Double? {
        let state = ca.renderState
        guard let first = await poll(timeout: 2, { state.lastAudibleHostTime.load(ordering: .relaxed) > baseline }) else {
            return nil
        }
        var samples: [(ContinuousClock.Instant, Float)] = []
        let end = first + .milliseconds(450)
        while ContinuousClock.now < end {
            samples.append((.now, Float(bitPattern: state.lastPeakBits.load(ordering: .relaxed))))
            try? await Task.sleep(for: .milliseconds(1))
        }
        guard let peak = samples.map(\.1).max(), peak > 0,
              let reached = samples.first(where: { $0.1 >= 0.9 * peak })?.0 else { return nil }
        let rampToNinety = HarnessTone.onsetRampSeconds * 0.9 * 1000
        return max(0, rampToNinety - (reached - first).milliseconds)
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
        let line = "\(passed ? "PASS" : "FAIL"): \(what)"
        verdicts.append(line)
        report(line)
    }

    private func report(_ line: String) {
        lines.append(line)
        panel.log(line)
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
    /// Fade-in of the short test tone, used to measure how much of a sound's start is lost.
    static let onsetRampSeconds = 0.2

    static func data(seconds: Double, rampSeconds: Double = 0, sampleRate: Int = 48_000, frequency: Double = 440) -> Data {
        let frames = Int(seconds * Double(sampleRate))
        var data = Data(capacity: 44 + frames * 2)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + frames * 2))
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(frames * 2))
        let rampFrames = rampSeconds * Double(sampleRate)
        for i in 0..<frames {
            let ramp = rampFrames > 0 ? min(1, Double(i) / rampFrames) : 1
            let sample = sin(2 * .pi * frequency * Double(i) / Double(sampleRate)) * 0.8 * ramp
            append(Int16(sample * Double(Int16.max)))
        }
        return data
    }

    static func write(to url: URL, seconds: Double, rampSeconds: Double = 0) throws {
        try data(seconds: seconds, rampSeconds: rampSeconds).write(to: url, options: .atomic)
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
