// FineTune/Audio/CatchAll/CaptureCoverage.swift
import AudioToolbox

/// Which output a tap captures: nothing, every device (process-wide mixdown tap) or the
/// output stream of one device (stream tap).
nonisolated enum TapCoverage: Sendable, Hashable {
    case none
    case allDevices
    case device(String)

    func covers(_ deviceUID: String) -> Bool {
        switch self {
        case .none: false
        case .allDevices: true
        case .device(let uid): uid == deviceUID
        }
    }

    /// The output both captures have in common.
    func intersect(_ other: TapCoverage) -> TapCoverage {
        switch (self, other) {
        case (.none, _), (_, .none): .none
        case (.allDevices, let coverage), (let coverage, .allDevices): coverage
        case (.device(let a), .device(let b)): a == b ? .device(a) : .none
        }
    }
}

/// The processes one live Core Audio tap holds muted, and on which output.
nonisolated struct TapCapture: Sendable, Hashable {
    var processes: Set<AudioObjectID>
    var coverage: TapCoverage
}

/// What the catch-all may exclude because a per-app tap holds it. Always a subset of what
/// that tap holds muted, so excluding it never lets a process play unprocessed.
nonisolated struct Claim: Sendable, Hashable {
    var processes: Set<AudioObjectID>
    var coverage: TapCoverage

    static let empty = Claim(processes: [], coverage: .none)

    var isEmpty: Bool { processes.isEmpty || coverage == .none }

    func covers(_ deviceUID: String) -> Bool {
        !isEmpty && coverage.covers(deviceUID)
    }

    func intersect(_ other: Claim) -> Claim {
        let processes = processes.intersection(other.processes)
        let coverage = coverage.intersect(other.coverage)
        guard !processes.isEmpty, coverage != .none else { return .empty }
        return Claim(processes: processes, coverage: coverage)
    }

    /// What every live resource of a tap holds. The intersection, so a claim never relies on
    /// a resource (e.g. a crossfade's secondary tap) that may go away first.
    static func fromLive(_ captures: [TapCapture]) -> Claim {
        guard let first = captures.first else { return .empty }
        return captures.dropFirst().reduce(Claim(processes: first.processes, coverage: first.coverage)) {
            $0.intersect(Claim(processes: $1.processes, coverage: $1.coverage))
        }
    }
}
