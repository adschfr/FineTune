// FineTune/Audio/Monitors/DisplayOutputGate.swift
import ColorSync
import CoreGraphics
import Foundation

/// Decides which display outputs (HDMI, DisplayPort) to treat as disconnected because macOS
/// no longer lists their screen while the audio device stays in Core Audio. That happens
/// when a display is disabled in software while its cable stays plugged in: Core Audio still
/// reports the output as alive, and macOS keeps it as the default output.
///
/// Fails open. An output is hidden only when its UID names a display, that display was seen
/// online before (so the match is known to work for this hardware) and it has been missing
/// for `hideDelay`. A screen that returns shows its output again at once.
nonisolated struct DisplayOutputGate {
    /// Vendor and product of a display as the UID of its audio device encodes them.
    struct DisplayKey: Hashable, Sendable {
        let vendor: UInt32
        let product: UInt32
    }

    /// A screen macOS lists as online (active, mirrored or asleep).
    struct OnlineDisplay: Equatable, Sendable {
        let vendor: UInt32
        let model: UInt32
        let uuid: String?
    }

    /// How long a screen must be missing before its output is hidden. Rides out the short
    /// gaps of a mode change or an HDMI handshake.
    static let hideDelay: TimeInterval = 3

    /// Outputs to leave out of the device list right now.
    private(set) var hidden: Set<String> = []
    /// Outputs whose screen was matched at least once. Kept across launches by the owner.
    private(set) var seenOnline: Set<String>
    private var absentSince: [String: TimeInterval] = [:]

    init(seenOnline: Set<String> = []) {
        self.seenOnline = seenOnline
    }

    /// Updates the hidden set.
    /// - Parameters:
    ///   - candidateUIDs: Display outputs currently in Core Audio.
    ///   - online: The online screens, or nil when the list cannot be read. Nil changes
    ///     nothing except that running delays restart.
    ///   - mayHide: False while screens cannot be judged as missing (asleep, just woken).
    ///     Outputs whose screen is online are still shown again; nothing new is hidden and
    ///     running delays restart.
    ///   - now: A monotonic time in seconds.
    /// - Returns: When to call again because a delay is running, if any.
    mutating func update(candidateUIDs: [String], online: [OnlineDisplay]?, mayHide: Bool = true, now: TimeInterval) -> TimeInterval? {
        let candidates = Set(candidateUIDs)
        hidden.formIntersection(candidates)
        absentSince = absentSince.filter { candidates.contains($0.key) }

        guard let online else {
            absentSince.removeAll()
            return nil
        }

        var nextCheck: TimeInterval?
        for uid in candidates {
            guard let key = Self.displayKey(fromUID: uid) else {
                hidden.remove(uid)
                continue
            }
            if online.contains(where: { Self.matches($0, key: key, uid: uid) }) {
                seenOnline.insert(uid)
                hidden.remove(uid)
                absentSince[uid] = nil
            } else if !mayHide {
                absentSince[uid] = nil
            } else if seenOnline.contains(uid), !hidden.contains(uid) {
                let since = absentSince[uid] ?? now
                absentSince[uid] = since
                if now - since >= Self.hideDelay {
                    hidden.insert(uid)
                    absentSince[uid] = nil
                } else {
                    nextCheck = min(nextCheck ?? .infinity, since + Self.hideDelay)
                }
            }
        }
        return nextCheck
    }

    /// Shows every output again and forgets running delays. `seenOnline` stays.
    mutating func reset() {
        hidden.removeAll()
        absentSince.removeAll()
    }

    /// On Apple Silicon the UID of an HDMI or DisplayPort output starts with the display's
    /// EDID vendor and product as eight hex digits, e.g. "4C2D0F12-0000-…". Other formats
    /// name no display and are never hidden.
    static func displayKey(fromUID uid: String) -> DisplayKey? {
        guard let head = uid.split(separator: "-", omittingEmptySubsequences: false).first,
              head.count == 8, head.allSatisfy(\.isHexDigit),
              let vendor = UInt32(head.prefix(4), radix: 16),
              let product = UInt32(head.suffix(4), radix: 16),
              vendor != 0 else { return nil }
        return DisplayKey(vendor: vendor, product: product)
    }

    /// The UID carries the product's two EDID bytes in order, while Core Graphics reports
    /// them as a little-endian number, so both byte orders count. A wrong match only keeps
    /// an output visible.
    static func matches(_ display: OnlineDisplay, key: DisplayKey, uid: String) -> Bool {
        if let uuid = display.uuid, uuid.caseInsensitiveCompare(uid) == .orderedSame { return true }
        guard display.vendor == key.vendor else { return false }
        let model = display.model & 0xFFFF
        let swapped = ((model & 0xFF) << 8) | (model >> 8)
        return model == key.product || swapped == key.product
    }

    /// The screens macOS lists as online, or nil when the list cannot be read.
    static func readOnlineDisplays() -> [OnlineDisplay]? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).map { id in
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map {
                CFUUIDCreateString(nil, $0.takeRetainedValue()) as String
            }
            return OnlineDisplay(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), uuid: uuid)
        }
    }
}
