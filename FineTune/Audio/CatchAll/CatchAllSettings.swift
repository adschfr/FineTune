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

    /// Harness steps to run once at launch (e.g. "all" or "H0,H1"), nil when not requested.
    var harnessSteps: [CatchAllHarnessStep]? {
        guard let value = defaults.string(forKey: Self.harnessKey) else { return nil }
        return CatchAllHarnessStep.parse(value)
    }
}

/// Measurements on the user's Mac that decide whether the catch-all can be turned on
/// (design §12.3). Each step names what it verifies.
nonisolated enum CatchAllHarnessStep: String, CaseIterable, Sendable {
    /// Build an observing catch-all: build time, assigned tap UID, exclusive read-back.
    case h0 = "H0"
    /// A process that starts after the catch-all exists is captured from its first buffer.
    case h1 = "H1"
    /// Exclusion updates on a live tap: accepted, read back, and how fast they take effect.
    case h2 = "H2"
    /// FineTune's own output (in-process sound, per-app tap output) is not captured.
    case h3 = "H3"
    /// Resume latency of a stopped catch-all when a covered process starts playing.
    case h7 = "H7"
    /// Core Audio reports IsRunningOutput and the output device of a muted process.
    case h8 = "H8"

    /// "all", or a comma-separated list of step names; unknown names are ignored. nil if
    /// nothing valid remains.
    static func parse(_ value: String) -> [CatchAllHarnessStep]? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased() == "all" { return allCases }
        let steps = trimmed.split(separator: ",").compactMap {
            CatchAllHarnessStep(rawValue: $0.trimmingCharacters(in: .whitespaces).uppercased())
        }
        return steps.isEmpty ? nil : steps
    }
}
