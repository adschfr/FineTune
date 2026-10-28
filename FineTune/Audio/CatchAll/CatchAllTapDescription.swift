// FineTune/Audio/CatchAll/CatchAllTapDescription.swift
import AudioToolbox
import Foundation

/// The only place that builds the catch-all's tap description and aggregate dictionary.
nonisolated enum CatchAllTapDescription {
    /// Starts with "FineTune-", so FineTune's own device picker hides the aggregate.
    static let aggregateNamePrefix = "FineTune-CatchAll-"

    /// A private exclusive tap on one output stream of `deviceUID`: it captures every
    /// process playing to that stream except `excluding`, and with `.muted` holds their audio
    /// back from the device from the first sample. Observe mode leaves the audio playing and
    /// only measures. A process-wide variant without a device would also hold back audio on
    /// every other output (AirPods, built-in speakers), so it is never used.
    static func make(excluding: [AudioObjectID], deviceUID: String, stream: UInt, observe: Bool) -> CATapDescription {
        let description = CATapDescription(excludingProcesses: excluding, deviceUID: deviceUID, stream: stream)
        description.uuid = UUID()
        description.name = "FineTune Catch-All"
        description.isPrivate = true
        description.isExclusive = true
        description.muteBehavior = observe ? .unmuted : .muted
        return description
    }

    /// A private aggregate that plays the catch-all tap to `deviceUID`. Not auto-started: the
    /// run control starts and stops its IO.
    static func aggregate(deviceUID: String, tapUID: String, tapDriftCompensation: Bool) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: aggregateName(for: deviceUID),
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceClockDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: deviceUID, kAudioSubDeviceDriftCompensationKey: false]
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: tapDriftCompensation]
            ],
        ]
    }

    /// Stable per device, so logs can tell the catch-alls of several outputs apart.
    static func aggregateName(for deviceUID: String) -> String {
        let hash = deviceUID.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }  // FNV-1a
        return aggregateNamePrefix + String(format: "%08x", hash)
    }
}
