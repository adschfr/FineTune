// FineTune/Audio/CatchAll/CatchAllHarness.swift
//
// Measurements on the user's Mac that decide whether the catch-all may be turned on
// (design §12.3). Runs once at launch when `CatchAllHarness` is set in the fork's defaults,
// with the software-volume output (the TV) as default output. Plays short quiet test tones
// with afplay. Results are logged (category CatchAllHarness, notice level) and written to
// ~/Library/Logs/FineTune Fork/catchall-harness.txt. H9 kills FineTune and asks for its
// answer in the next launch, which appends to that report.

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
    private let killToneURL: URL
    private let defaults: UserDefaults
    private let panel = HarnessPanel()
    private var verdicts: [String] = []

    init(target: Target, backend: any CatchAllBackend = CoreAudioCatchAllBackend(), defaults: UserDefaults = .standard) {
        self.target = target
        self.backend = backend
        self.defaults = defaults
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/FineTune Fork", isDirectory: true)
        reportURL = logs.appendingPathComponent("catchall-harness.txt")
        let temp = FileManager.default.temporaryDirectory
        toneURL = temp.appendingPathComponent("finetune-harness-tone.wav")
        longToneURL = temp.appendingPathComponent("finetune-harness-tone-long.wav")
        plainToneURL = temp.appendingPathComponent("finetune-harness-tone-plain.wav")
        killToneURL = temp.appendingPathComponent("finetune-harness-tone-kill.wav")
    }

    /// Checks the preconditions and runs `steps`. Clears the request first, so a crash
    /// during the harness does not repeat it on the next launch. A pending H9 answer comes
    /// first and is the only thing that runs in that launch.
    static func runIfRequested(
        settings: CatchAllSettings,
        defaults: UserDefaults = .standard,
        defaultOutputUID: String?,
        deviceID: (String) -> AudioDeviceID?,
        tier: (AudioDeviceID) -> VolumeControlTier,
        permissionAuthorized: Bool
    ) async {
        if let pending = settings.pendingH9 {
            CatchAllSettings.clearPendingH9(in: defaults)
            defaults.removeObject(forKey: CatchAllSettings.harnessKey)
            // Only the question runs, so no device, self object or permission is needed
            let unknown = AudioObjectID(kAudioObjectUnknown)
            let harness = CatchAllHarness(target: Target(uid: pending.deviceUID, deviceID: unknown, selfObject: unknown),
                                          defaults: defaults)
            await harness.answerKillCheck(pending)
            return
        }
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
        await CatchAllHarness(target: Target(uid: uid, deviceID: id, selfObject: selfObject), defaults: defaults).run(steps)
    }

    func run(_ steps: [CatchAllHarnessStep]) async {
        // The H9 kill ends the run, whatever order the caller passed
        let steps = CatchAllHarnessStep.killCheckLast(steps)
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
            case .h9: await h9KillCheck(label)
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
        // Nothing is listed here: a process holding IO open without output must not keep
        // the catch-all running between the tones
        logic.ioOnlyCap = 1
        let control = CatchAllRunControl(source: HALProcessOutputActivitySource(), backend: backend, logic: logic)
        control.attach(ca.ioHandle, deviceID: target.deviceID, excluded: [target.selfObject])
        control.start()
        var notSuspended = 0
        let answer = await listen(label, headline: "Catch-all startet aus dem Stillstand",
                                  detail: "Fünf kurze Töne bei 10 %, jeweils nachdem die Catch-all angehalten hat. Es sollte NICHTS zu hören sein; ein Knacken am Tonanfang wäre ein Leck.",
                                  expectation: .silent) {
            for tone in 1...5 {
                // A tone into a running catch-all would pass without testing a resume
                let suspended = await poll(timeout: 5, { !control.sync { $0.anyRunning } }) != nil
                if !suspended {
                    notSuspended += 1
                    report("tone \(tone): catch-all did not suspend within 5 s")
                }
                guard let player = HarnessPlayer.start(plainToneURL, volume: 0.1) else { continue }
                // afplay needs tens of ms to open its IO: a catch-all running now was started by another process
                if suspended, control.sync({ $0.anyRunning }) {
                    notSuspended += 1
                    report("tone \(tone): catch-all was already running when the tone started")
                }
                await player.wait()
            }
        }
        await release(ca, from: control)
        verdict(answer == "Nichts gehört" && notSuspended == 0,
                "H7M stopped catch-all holds plain tones back, onset included (user heard nothing, every tone after a suspend)")
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
        // Nothing is listed here: a process holding IO open without output must not keep
        // the catch-all running between the tones
        logic.ioOnlyCap = 1
        let control = CatchAllRunControl(source: HALProcessOutputActivitySource(), backend: backend, logic: logic)
        control.attach(ca.ioHandle, deviceID: target.deviceID, excluded: [target.selfObject])
        control.start()
        var missing: [Double] = []
        var failed = 0
        var notSuspended = 0
        for _ in 1...10 {
            // Let the catch-all suspend between runs; a run on a running catch-all measures no resume
            guard await poll(timeout: 5, { !control.sync { $0.anyRunning } }) != nil else {
                notSuspended += 1
                continue
            }
            let baseline = ca.renderState.lastAudibleHostTime.load(ordering: .relaxed)
            guard let player = HarnessPlayer.start(toneURL, volume: 0.05) else {
                failed += 1
                continue
            }
            // afplay needs tens of ms to open its IO: a catch-all running now was started by another process
            if control.sync({ $0.anyRunning }) {
                notSuspended += 1
                await player.wait()
                continue
            }
            guard let lost = await missingOnset(ca, after: baseline) else {
                failed += 1
                continue
            }
            missing.append(lost)
            await player.wait()
        }
        await release(ca, from: control)
        report("stopped catch-all: tone onset lost while resuming \(stats(missing)), not heard \(failed), not suspended \(notSuspended) (tones were held, nothing should have been audible)")
        verdict(failed == 0 && notSuspended == 0 && percentile(missing, 0.95) <= 50, "H7 resume from a stopped catch-all (onset lost p95 ≤ 50 ms)")
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

    /// Kills FineTune with SIGKILL while a muted catch-all holds a tone. Returns only when
    /// the check failed before or instead of the kill; the answer comes in the next launch.
    private func h9KillCheck(_ label: String) async {
        await panel.announce(step: label, headline: "FineTune wird hart beendet",
                             detail: "Ein langer Ton bei 10 % startet (so laut wie die Kontrolltöne), die Catch-all hält ihn zurück. Es sollte NICHTS zu hören sein. Danach zählt die Anzeige 5 s herunter, bei null wird FineTune hart beendet (kill -9). Dann sollte der Ton sofort leise hörbar werden und 3 s später enden. FineTune startet von selbst neu und fragt, wann der Ton hörbar wurde. Falls der TV danach stumm bleibt: Mac neu starten.",
                             expectation: .silent)
        // The bundle ID can be registered at several paths, so the relaunch opens this one
        let appPath = Bundle.main.bundleURL.path
        do {
            try HarnessTone.write(to: killToneURL, seconds: 20)
        } catch {
            return verdict(false, "H9 (could not write the test tone)")
        }
        guard let ca = try? build(observe: false, held: true, exclusions: [target.selfObject]) else {
            return verdict(false, "H9 (catch-all could not be built)")
        }
        // Ends the check without a kill: nothing stays held or playing
        func fail(_ reason: String, _ player: HarnessPlayer?) async {
            player?.stop()
            panel.playing(false)
            await stopIO(ca)
            await ca.destroy()
            verdict(false, "H9 (\(reason))")
        }
        guard await startIO(ca) else { return await fail("catch-all could not start", nil) }

        // A direct child of FineTune: no per-app tap takes it, only the catch-all holds it
        let baseline = ca.renderState.lastAudibleHostTime.load(ordering: .relaxed)
        guard let player = HarnessPlayer.start(killToneURL, volume: 0.1) else {
            return await fail("test tone did not start", nil)
        }
        panel.playing(true)
        guard await poll(timeout: 2, { ca.renderState.lastAudibleHostTime.load(ordering: .relaxed) > baseline }) != nil else {
            return await fail("catch-all did not capture the tone", player)
        }
        report("catch-all holds the tone (afplay pid \(player.pid))")
        let alertUID = Self.systemAlertDeviceUID()
        report("system alert device: \(alertUID ?? "unknown") (\(alertUID == target.uid ? "= target" : "≠ target"))")

        await panel.countdown("Gleich wird FineTune beendet", seconds: 5)
        let killTime = Date()
        do {
            try CatchAllSettings.storePendingH9(CatchAllPendingH9(killTime: killTime, deviceUID: target.uid), in: defaults)
        } catch {
            return await fail("pending record could not be stored", player)
        }
        defaults.synchronize()
        report("kill -9 at \(HarnessClock.format(killTime)), tone stops 3 s later, relaunch \(appPath)")
        save()
        let arguments = HarnessKillHelper.arguments(fineTunePID: getpid(), tonePID: player.pid, appPath: appPath)
        let helper: pid_t
        do {
            helper = try HarnessKillHelper.spawn(arguments)
        } catch {
            CatchAllSettings.clearPendingH9(in: defaults)
            return await fail("helper did not start: \(error.localizedDescription)", player)
        }
        try? await Task.sleep(for: .seconds(3))
        // Still running, so the kill did not happen
        CatchAllSettings.clearPendingH9(in: defaults)
        HarnessKillHelper.reap(helper)
        await fail("FineTune was still running 3 s after the kill", player)
    }

    /// The second half of H9, in the launch after the kill: asks at once when the held tone
    /// became audible and appends the answer to the report saved before the kill.
    private func answerKillCheck(_ pending: CatchAllPendingH9) async {
        panel.show()
        let killed = HarnessClock.format(pending.killTime)
        report("--- H9 after relaunch: killed at \(killed) on \(pending.deviceUID)")
        guard pending.isFresh(at: Date()) else {
            // Too late to tell how fast the tone came back: nothing is asked or counted
            report("H9 not counted: relaunched more than \(Int(CatchAllPendingH9.maxAge)) s after the kill")
            panel.finish(summary: "H9 nicht gewertet: FineTune startete erst lange nach dem Beenden um \(killed) neu. Gate G1 bleibt offen, die Catch-all bleibt aus. H9 bitte erneut anfordern. Falls der TV stumm bleibt: Mac neu starten.")
            save(appending: true)
            return
        }
        await panel.announce(step: "H9 nach dem Neustart", headline: "Wann wurde der Ton hörbar?",
                             detail: "Die Catch-all hielt einen Ton zurück, als FineTune hart beendet wurde.",
                             expectation: .info, seconds: 0)
        let answer = await panel.ask("FineTune wurde um \(killed) beendet. Wann wurde der Ton hörbar?",
                                     options: ["sofort (unter 1 s)", "später", "gar nicht", "unsicher"])
        report("H9: tone audible after the kill: \(answer)")
        let passed = answer == "sofort (unter 1 s)"
        verdict(passed, "H9 held tone audible at once after kill -9 (the catch-all dies with FineTune)")
        let outcome = passed
            ? "Gate G1 bestanden."
            : "Gate G1 nicht bestanden, die Catch-all bleibt aus. Falls der TV stumm bleibt: Mac neu starten."
        panel.finish(summary: (verdicts + [outcome]).joined(separator: "\n"))
        save(appending: true)
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

    /// Detaches the catch-all and stops the run control, then destroys the catch-all once the
    /// queue has let go of it. A stuck queue leaves it to die with the process.
    private func release(_ ca: CatchAllTapController, from control: CatchAllRunControl) async {
        let detached = await control.detach(ca.ioHandle)
        guard control.stop() || detached else {
            return report("run queue did not respond: catch-all not destroyed")
        }
        await ca.destroy()
    }

    /// UID of the device macOS plays alerts and notification sounds on, nil if unreadable.
    private static func systemAlertDeviceUID() -> String? {
        guard let id = try? AudioDeviceID.readSystemOutputDevice(), id != AudioDeviceID.unknown else { return nil }
        return try? id.readDeviceUID()
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

    /// Logs the line and adds it with the wall-clock time to the panel and the report.
    private func report(_ line: String) {
        let stamped = "\(HarnessClock.format(Date())) \(line)"
        lines.append(stamped)
        panel.log(stamped)
        logger.notice("\(line, privacy: .public)")
    }

    /// Writes the report; `appending` adds this launch's lines to the existing file (the H9
    /// answer after the part saved before the kill).
    private func save(appending: Bool = false) {
        try? FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + "\n"
        guard appending, let file = try? FileHandle(forWritingTo: reportURL) else {
            try? text.write(to: reportURL, atomically: true, encoding: .utf8)
            return
        }
        defer { try? file.close() }
        _ = try? file.seekToEnd()
        try? file.write(contentsOf: Data(text.utf8))
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

/// Wall-clock time of harness lines, HH:mm:ss.SSS.
nonisolated enum HarnessClock {
    static func format(_ date: Date, timeZone: TimeZone = .current) -> String {
        // Whole milliseconds first, so a rounded-up value carries into the seconds
        let millis = (date.timeIntervalSinceReferenceDate * 1000).rounded()
        let seconds = (millis / 1000).rounded(.down)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let time = calendar.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSinceReferenceDate: seconds))
        return String(format: "%02ld:%02ld:%02ld.%03ld", time.hour ?? 0, time.minute ?? 0, time.second ?? 0, Int(millis - seconds * 1000))
    }
}

/// The H9 helper: a shell in its own session that kills FineTune, stops the tone 3 s later
/// and relaunches the killed bundle by its path. The values are positional parameters, never
/// part of the script.
nonisolated enum HarnessKillHelper {
    static let shell = "/bin/sh"
    static let script = #"kill -9 "$1"; sleep 3; kill "$2" 2>/dev/null; sleep 1; exec /usr/bin/open "$3""#

    /// argv for `shell`: `-c script`, then $0 = h9, $1 = FineTune, $2 = tone, $3 = the app's
    /// bundle path (absolute, so open never reads it as an option).
    static func arguments(fineTunePID: pid_t, tonePID: pid_t, appPath: String) -> [String] {
        [shell, "-c", script, "h9", String(fineTunePID), String(tonePID), appPath]
    }

    /// Starts `arguments` with posix_spawn in a new session (it survives FineTune's death),
    /// with default signal handling and /dev/null as its only inherited descriptors.
    static func spawn(_ arguments: [String]) throws -> pid_t {
        func check(_ status: Int32) throws {
            guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EINVAL) }
        }
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }

        var noSignals = sigset_t()
        var allSignals = sigset_t()
        sigemptyset(&noSignals)
        sigfillset(&allSignals)
        try check(posix_spawnattr_setsigmask(&attributes, &noSignals))
        try check(posix_spawnattr_setsigdefault(&attributes, &allSignals))
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)))
        for descriptor: Int32 in 0...2 {
            try check(posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == 0 ? O_RDONLY : O_WRONLY, 0))
        }

        let argv = arguments.map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + environment).forEach { free($0) } }
        var pid = pid_t()
        try check(posix_spawn(&pid, arguments[0], &actions, &attributes, argv, environment))
        return pid
    }

    /// Collects the helper's exit status in the background when FineTune outlived the kill.
    static func reap(_ pid: pid_t) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
        }
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
