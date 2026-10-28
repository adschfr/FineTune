// FineTuneTests/CatchAllTapDescriptionTests.swift
//
// The catch-all tap must hold back every non-excluded process on one output stream only,
// stay private to FineTune and never use the process-wide or bundle-ID variants.
// Building a CATapDescription creates no tap, so this needs no Core Audio access.

import Testing
import Foundation
import AudioToolbox
@testable import FineTune

@Suite("Catch-all tap and aggregate descriptions")
@MainActor
struct CatchAllTapDescriptionTests {

    @Test("The tap is exclusive, muted, private and on one stream of the device")
    func tapDescription() {
        let description = CatchAllTapDescription.make(excluding: [5, 11], deviceUID: "uid-tv", stream: 0, observe: false)

        #expect(description.isExclusive)
        #expect(description.muteBehavior == .muted)
        #expect(description.isPrivate)
        #expect(description.processes == [5, 11])
        #expect(description.deviceUID == "uid-tv")
        #expect(description.stream == 0)
        #expect(!description.isMono)
        #expect(!description.isMixdown)
    }

    @Test("Observe mode leaves the audio playing")
    func observeUnmuted() {
        let description = CatchAllTapDescription.make(excluding: [5], deviceUID: "uid-tv", stream: 0, observe: true)
        #expect(description.muteBehavior == .unmuted)
        #expect(description.isExclusive)
    }

    @Test("Each tap gets its own UUID")
    func uniqueUUIDs() {
        let a = CatchAllTapDescription.make(excluding: [5], deviceUID: "uid-tv", stream: 0, observe: false)
        let b = CatchAllTapDescription.make(excluding: [5], deviceUID: "uid-tv", stream: 0, observe: false)
        #expect(a.uuid != b.uuid)
    }

    // processRestoreEnabled is not read back: on macOS 27 the getter printed `false` while
    // `!value` failed, which points to an unnormalized ObjC BOOL. The source guard below
    // ensures the factory never sets it.
    @Test("No bundle-ID matching (macOS 26)")
    func noBundleMatching() {
        let description = CatchAllTapDescription.make(excluding: [5], deviceUID: "uid-tv", stream: 0, observe: false)
        if #available(macOS 26.0, *) {
            #expect(description.bundleIDs.isEmpty)
        }
    }

    @Test("The aggregate is private, not auto-started and plays the tap to the device")
    func aggregateDescription() throws {
        let dict = CatchAllTapDescription.aggregate(deviceUID: "uid-tv", tapUID: "tap-uid-1", tapDriftCompensation: true)

        let name = try #require(dict[kAudioAggregateDeviceNameKey] as? String)
        #expect(name.hasPrefix("FineTune-CatchAll-"))
        #expect(name == CatchAllTapDescription.aggregateName(for: "uid-tv"))
        #expect(dict[kAudioAggregateDeviceIsPrivateKey] as? Bool == true)
        #expect(dict[kAudioAggregateDeviceTapAutoStartKey] as? Bool == false)
        #expect(dict[kAudioAggregateDeviceIsStackedKey] as? Bool == true)
        #expect(dict[kAudioAggregateDeviceMainSubDeviceKey] as? String == "uid-tv")
        #expect(dict[kAudioAggregateDeviceClockDeviceKey] as? String == "uid-tv")

        let subDevices = try #require(dict[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
        #expect(subDevices.count == 1)
        #expect(subDevices[0][kAudioSubDeviceUIDKey] as? String == "uid-tv")

        let taps = try #require(dict[kAudioAggregateDeviceTapListKey] as? [[String: Any]])
        #expect(taps.count == 1)
        #expect(taps[0][kAudioSubTapUIDKey] as? String == "tap-uid-1")
        #expect(taps[0][kAudioSubTapDriftCompensationKey] as? Bool == true)
    }

    @Test("Aggregate names are stable per device and differ between devices")
    func aggregateNames() {
        #expect(CatchAllTapDescription.aggregateName(for: "uid-tv") == CatchAllTapDescription.aggregateName(for: "uid-tv"))
        #expect(CatchAllTapDescription.aggregateName(for: "uid-tv") != CatchAllTapDescription.aggregateName(for: "uid-hdmi2"))
    }

    @Test("The factory file builds exactly one tap description and no process-wide variant")
    func sourceGuard() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FineTune/Audio/CatchAll/CatchAllTapDescription.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        #expect(source.components(separatedBy: "CATapDescription(").count - 1 == 1)
        #expect(!source.contains("GlobalTapButExclude"))
        #expect(!source.contains("bundleIDs"))
        #expect(!source.contains("processRestore"))
        #expect(!source.contains(".mutedWhenTapped"))
    }
}
