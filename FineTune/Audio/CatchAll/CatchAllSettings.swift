// FineTune/Audio/CatchAll/CatchAllSettings.swift
import Foundation

/// Catch-all settings in the fork's own defaults domain, not in the settings.json shared
/// with upstream FineTune (which would drop unknown keys). Read at launch.
///
/// Kill switch: `defaults write com.adschfr.FineTuneFork CatchAllMode -string off`, relaunch.
nonisolated struct CatchAllSettings {
    static let modeKey = "CatchAllMode"
    static let excludedDevicesKey = "CatchAllExcludedDeviceUIDs"
    static let harnessKey = "CatchAllHarness"
    static let pendingH9Key = "CatchAllHarnessPendingH9"
    static let growMarginKey = "CatchAllGrowMarginMs"
    static let shrinkMarginKey = "CatchAllShrinkMarginMs"
    static let ioOnlyCapKey = "CatchAllIOOnlyCapSeconds"

    /// G: the wait after a push that excludes processes before it counts as applied (design
    /// §4.6, §16.3); twice the slowest live update measured in §15.
    static let defaultGrowMargin: TimeInterval = 0.130
    /// S: the same after a push that un-excludes processes. The per-app tap still holds them,
    /// so a longer wait costs nothing audible.
    static let defaultShrinkMargin: TimeInterval = 0.400

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `off` unless set; an unknown value also counts as off.
    var mode: CatchAllMode {
        defaults.string(forKey: Self.modeKey).flatMap(CatchAllMode.init(rawValue:)) ?? .off
    }

    /// Outputs that never get a catch-all.
    var excludedDeviceUIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.excludedDevicesKey) ?? [])
    }

    /// G in seconds; the key holds milliseconds.
    var growMargin: TimeInterval {
        Self.positive(defaults.double(forKey: Self.growMarginKey) / 1000) ?? Self.defaultGrowMargin
    }

    /// S in seconds; the key holds milliseconds.
    var shrinkMargin: TimeInterval {
        Self.positive(defaults.double(forKey: Self.shrinkMarginKey) / 1000) ?? Self.defaultShrinkMargin
    }

    /// Seconds an unlisted process's IO without output counts as needing the catch-all before
    /// its output is polled instead (E3, `CatchAllRunLogic.ioOnlyCap`).
    var ioOnlyCap: TimeInterval {
        Self.positive(defaults.double(forKey: Self.ioOnlyCapKey)) ?? CatchAllRunLogic.defaultIOOnlyCap
    }

    /// nil for a missing, non-numeric, non-positive or infinite value (`double(forKey:)`
    /// reads the first two as 0), so the caller uses its default.
    private static func positive(_ value: Double) -> Double? {
        value.isFinite && value > 0 ? value : nil
    }

    /// Harness steps to run once at launch (e.g. "all" or "H0,H1"), nil when not requested.
    var harnessSteps: [CatchAllHarnessStep]? {
        guard let value = defaults.string(forKey: Self.harnessKey) else { return nil }
        return CatchAllHarnessStep.parse(value)
    }

    /// Whether the harness runs at this launch: steps are requested or an H9 answer is pending.
    var harnessRequested: Bool {
        harnessSteps != nil || pendingH9 != nil
    }

    /// The kill check H9 waiting for its answer in the launch after the kill, nil when none
    /// is pending or the stored data is unreadable.
    var pendingH9: CatchAllPendingH9? {
        guard let data = defaults.data(forKey: Self.pendingH9Key) else { return nil }
        return try? PropertyListDecoder().decode(CatchAllPendingH9.self, from: data)
    }

    static func storePendingH9(_ record: CatchAllPendingH9, in defaults: UserDefaults) throws {
        defaults.set(try PropertyListEncoder().encode(record), forKey: pendingH9Key)
    }

    static func clearPendingH9(in defaults: UserDefaults) {
        defaults.removeObject(forKey: pendingH9Key)
    }
}

/// Written right before H9 kills FineTune: when it was killed and on which output, so the
/// relaunched app can ask at once when the held tone became audible.
nonisolated struct CatchAllPendingH9: Codable, Equatable, Sendable {
    /// The relaunch takes seconds. A record found later (FineTune started by hand, or an older
    /// copy came up and ignored it) no longer tells how fast the tone came back.
    static let maxAge: TimeInterval = 120

    let killTime: Date
    let deviceUID: String

    /// Whether an answer asked at `now` still counts for gate G1.
    func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(killTime)
        return age >= 0 && age <= Self.maxAge
    }
}

/// Measurements on the user's Mac that decide whether the catch-all can be turned on
/// (design §12.3). Each step names what it verifies.
nonisolated enum CatchAllHarnessStep: String, CaseIterable, Sendable {
    /// Listening control: three plain tones that must be audible (checks the audio path).
    case l0 = "L0"
    /// Build an observing catch-all: build time, assigned tap UID, exclusive read-back.
    case h0 = "H0"
    /// A process that starts after the catch-all exists is captured from its first buffer.
    case h1 = "H1"
    /// Exclusion updates on a live tap: accepted, read back, and how fast they take effect.
    case h2 = "H2"
    /// FineTune's own output (in-process sound, per-app tap output) is not captured.
    case h3 = "H3"
    /// Listening: plain tones held back by a running muted catch-all must be inaudible.
    case h1m = "H1M"
    /// Resume latency of a stopped catch-all when a covered process starts playing.
    case h7 = "H7"
    /// Listening: plain tones held back by a stopped muted catch-all must be inaudible,
    /// including their onset while it resumes.
    case h7m = "H7M"
    /// Core Audio reports IsRunningOutput and the output device of a muted process.
    case h8 = "H8"
    /// Kill check, the gate for mode on: FineTune is killed with SIGKILL while a muted
    /// catch-all holds a tone, which must become audible at once. The kill ends the run, so
    /// H9 always runs last and is not part of "all".
    case h9 = "H9"

    /// "all" (every step except H9), or a comma-separated list of step names; unknown names
    /// are ignored and H9 moves to the end. nil if nothing valid remains.
    static func parse(_ value: String) -> [CatchAllHarnessStep]? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased() == "all" { return allCases.filter { $0 != .h9 } }
        let steps = trimmed.split(separator: ",").compactMap {
            CatchAllHarnessStep(rawValue: $0.trimmingCharacters(in: .whitespaces).uppercased())
        }
        return steps.isEmpty ? nil : killCheckLast(steps)
    }

    /// `steps` with H9 moved to the end (once), the order of the others kept.
    static func killCheckLast(_ steps: [CatchAllHarnessStep]) -> [CatchAllHarnessStep] {
        steps.filter { $0 != .h9 } + (steps.contains(.h9) ? [.h9] : [])
    }
}
