// FineTuneTests/CaptureCoverageTests.swift
//
// The catch-all excludes a process only while a per-app tap holds it muted on that output.
// Claims are derived from what live taps capture; these tests pin the coverage algebra and
// the mapping from tap descriptions to captures.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import FineTune

@Suite("Capture coverage algebra")
struct CaptureCoverageTests {

    @Test("covers: none covers nothing, allDevices everything, device only itself")
    func coversTable() {
        #expect(!TapCoverage.none.covers("uid-tv"))
        #expect(TapCoverage.allDevices.covers("uid-tv"))
        #expect(TapCoverage.device("uid-tv").covers("uid-tv"))
        #expect(!TapCoverage.device("uid-airpods").covers("uid-tv"))
    }

    @Test("intersect follows the table all∩all, all∩device, device∩device")
    func intersectTable() {
        #expect(TapCoverage.allDevices.intersect(.allDevices) == .allDevices)
        #expect(TapCoverage.allDevices.intersect(.device("uid-tv")) == .device("uid-tv"))
        #expect(TapCoverage.device("uid-tv").intersect(.allDevices) == .device("uid-tv"))
        #expect(TapCoverage.device("uid-tv").intersect(.device("uid-tv")) == .device("uid-tv"))
        #expect(TapCoverage.device("uid-tv").intersect(.device("uid-airpods")) == .none)
        #expect(TapCoverage.none.intersect(.allDevices) == .none)
    }

    @Test("A claim from live captures is their intersection")
    func claimFromLiveIntersects() {
        let primary = TapCapture(processes: [11, 12], coverage: .device("uid-tv"))
        let secondary = TapCapture(processes: [11, 12, 13], coverage: .allDevices)

        let claim = Claim.fromLive([primary, secondary])

        #expect(claim == Claim(processes: [11, 12], coverage: .device("uid-tv")))
        #expect(claim.covers("uid-tv"))
        #expect(!claim.covers("uid-airpods"))
    }

    @Test("No live capture, or captures on different devices, claim nothing")
    func emptyClaims() {
        #expect(Claim.fromLive([]) == .empty)
        let tv = TapCapture(processes: [11], coverage: .device("uid-tv"))
        let airpods = TapCapture(processes: [11], coverage: .device("uid-airpods"))
        #expect(Claim.fromLive([tv, airpods]).isEmpty)
        #expect(!Claim.fromLive([tv, airpods]).covers("uid-tv"))
    }

    @Test("Disjoint processes claim nothing")
    func disjointProcesses() {
        let a = Claim(processes: [11], coverage: .allDevices)
        let b = Claim(processes: [12], coverage: .allDevices)
        #expect(a.intersect(b) == .empty)
    }
}

@Suite("Live capture of per-app taps")
@MainActor
struct LiveCaptureMappingTests {

    @Test("A stream tap description captures its processes on that device")
    func streamDescription() throws {
        let description = ProcessTapController.makeStreamTapDescription(processes: [11, 12], deviceUID: "uid-tv", stream: 0)

        let capture = try #require(ProcessTapController.capture(of: description))

        #expect(capture == TapCapture(processes: [11, 12], coverage: .device("uid-tv")))
    }

    @Test("A mixdown tap description captures its processes on every device")
    func mixdownDescription() throws {
        let description = ProcessTapController.makeMixdownTapDescription(processes: [21])

        let capture = try #require(ProcessTapController.capture(of: description))

        #expect(capture == TapCapture(processes: [21], coverage: .allDevices))
    }

    @Test("Exclusive descriptions and missing descriptions capture nothing")
    func exclusiveAndMissing() {
        let exclusive = CATapDescription(excludingProcesses: [11], deviceUID: "uid-tv", stream: 0)
        exclusive.isExclusive = true
        #expect(ProcessTapController.capture(of: exclusive) == nil)
        #expect(ProcessTapController.capture(of: nil) == nil)
    }

    @Test("A controller that was never activated has no live capture")
    func inactiveControllerCapturesNothing() {
        let app = AudioApp(id: 777, processObjectIDs: [11], name: "Guard", icon: NSImage(), bundleID: "com.test.capture")
        let controller = ProcessTapController(app: app, targetDeviceUID: "uid-tv")

        #expect(controller.liveCapture.isEmpty)
    }

    @Test("The fake reports its processes on its source device once activated")
    func fakeLiveCapture() throws {
        let app = AudioApp(id: 778, processObjectIDs: [31, 32], name: "Fake", icon: NSImage(), bundleID: "com.test.fake")
        let tap = FakeTapController(app: app, deviceUIDs: ["uid-tv"])
        #expect(tap.liveCapture.isEmpty)

        tap.tapSourceDeviceUID = "uid-tv"
        try tap.activate(initial: TapInitialState())
        #expect(tap.liveCapture == [TapCapture(processes: [31, 32], coverage: .device("uid-tv"))])

        tap.invalidate()
        #expect(tap.liveCapture.isEmpty)
    }
}
