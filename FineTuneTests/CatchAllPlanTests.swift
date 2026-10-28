// FineTuneTests/CatchAllPlanTests.swift
//
// Pure decisions of the catch-all tap: which processes it excludes, when a handover must
// hold a per-app tap, rule P5 and device eligibility.

import Testing
import Foundation
import AudioToolbox
@testable import FineTune

@Suite("CatchAllPlan: exclusions")
struct CatchAllPlanExclusionTests {

    private let selfObject: AudioObjectID = 5

    @Test("FineTune itself is always excluded, even with no claims")
    func selfAlwaysExcluded() {
        let list = CatchAllPlan.exclusions(deviceUID: "uid-tv", selfObject: selfObject, foreign: [], claims: [], live: [5, 11])
        #expect(list == [5])
    }

    @Test("Other users' live processes are excluded (#418)")
    func foreignExcluded() {
        let list = CatchAllPlan.exclusions(deviceUID: "uid-tv", selfObject: selfObject, foreign: [40, 41], claims: [], live: [5, 40])
        #expect(list == [5, 40])
    }

    @Test("A mixdown claim excludes on every catch-all device, a stream claim only on its device")
    func claimCoverage() {
        let mixdown = Claim(processes: [11], coverage: .allDevices)
        let tvStream = Claim(processes: [12], coverage: .device("uid-tv"))
        let airpodsStream = Claim(processes: [13], coverage: .device("uid-airpods"))
        let live: Set<AudioObjectID> = [5, 11, 12, 13]

        let tv = CatchAllPlan.exclusions(deviceUID: "uid-tv", selfObject: selfObject, foreign: [], claims: [mixdown, tvStream, airpodsStream], live: live)
        let other = CatchAllPlan.exclusions(deviceUID: "uid-hdmi2", selfObject: selfObject, foreign: [], claims: [mixdown, tvStream, airpodsStream], live: live)

        #expect(tv == [5, 11, 12])
        #expect(other == [5, 11])
    }

    @Test("Dead process objects are never pushed")
    func deadObjectsPruned() {
        let claim = Claim(processes: [11, 99], coverage: .allDevices)
        let list = CatchAllPlan.exclusions(deviceUID: "uid-tv", selfObject: selfObject, foreign: [98], claims: [claim], live: [5, 11])
        #expect(list == [5, 11])
    }

    @Test("The list is sorted and unique")
    func sortedUnique() {
        let a = Claim(processes: [30, 12], coverage: .allDevices)
        let b = Claim(processes: [12, 20], coverage: .device("uid-tv"))
        let list = CatchAllPlan.exclusions(deviceUID: "uid-tv", selfObject: selfObject, foreign: [], claims: [a, b], live: [5, 12, 20, 30])
        #expect(list == [5, 12, 20, 30])
    }
}

@Suite("CatchAllPlan: handover decisions")
struct CatchAllPlanHandoverTests {

    @Test("changedDevices lists only catch-all devices whose held set changes")
    func changedDevices() {
        let before = Claim(processes: [11], coverage: .device("uid-tv"))
        let after = Claim(processes: [11], coverage: .allDevices)
        let changed = CatchAllPlan.changedDevices(before: before, after: after, catchAllUIDs: ["uid-tv", "uid-hdmi2"])
        #expect(changed == ["uid-hdmi2"])
        #expect(CatchAllPlan.changedDevices(before: before, after: before, catchAllUIDs: ["uid-tv"]).isEmpty)
        #expect(CatchAllPlan.changedDevices(before: .empty, after: before, catchAllUIDs: ["uid-tv"]) == ["uid-tv"])
    }

    @Test("A tap holds when a changed catch-all device is one of its targets")
    func overlappingTargetsHold() {
        #expect(CatchAllPlan.holds(changed: ["uid-tv"], targets: ["uid-tv"]))
        // During a switch the targets are the old and the new output
        #expect(CatchAllPlan.holds(changed: ["uid-tv"], targets: ["uid-airpods", "uid-tv"]))
        #expect(CatchAllPlan.holds(changed: ["uid-tv", "uid-hdmi2"], targets: ["uid-hdmi2"]))
    }

    @Test("A tap whose targets are all unchanged does not hold, even if it captures the changed device")
    func disjointTargetsDoNotHold() {
        // A mixdown tap on the AirPods changes the TV's list; doubling on the TV is inaudible
        #expect(!CatchAllPlan.holds(changed: ["uid-tv"], targets: ["uid-airpods"]))
        #expect(!CatchAllPlan.holds(changed: ["uid-tv", "uid-hdmi2"], targets: ["uid-airpods", "uid-speakers"]))
    }

    @Test("No changed device or no target means no hold")
    func emptySetsDoNotHold() {
        #expect(!CatchAllPlan.holds(changed: [], targets: ["uid-tv"]))
        #expect(!CatchAllPlan.holds(changed: ["uid-tv"], targets: []))
        #expect(!CatchAllPlan.holds(changed: [], targets: []))
    }

    @Test("P5: a stream source only with no catch-all or when it is the single catch-all device")
    func allowsStreamTap() {
        #expect(CatchAllPlan.allowsStreamTap(candidate: "uid-airpods", catchAllDevices: []))
        #expect(CatchAllPlan.allowsStreamTap(candidate: "uid-tv", catchAllDevices: ["uid-tv"]))
        #expect(!CatchAllPlan.allowsStreamTap(candidate: "uid-airpods", catchAllDevices: ["uid-tv"]))
        #expect(!CatchAllPlan.allowsStreamTap(candidate: "uid-tv", catchAllDevices: ["uid-tv", "uid-hdmi2"]))
    }
}

@Suite("CatchAllPlan: eligibility")
struct CatchAllPlanEligibilityTests {

    private func facts() -> CatchAllPlan.DeviceFacts {
        CatchAllPlan.DeviceFacts(
            mode: .on, permissionAuthorized: true, sessionActive: true, selfObjectKnown: true,
            breakerClosed: true, listedAndAlive: true, tier: .software, isAggregate: false,
            isVirtual: false, outputStreamCount: 1, optedOut: false, givenUp: false
        )
    }

    @Test("A live single-stream software output is eligible, in observe and on")
    func eligible() {
        #expect(CatchAllPlan.ineligibility(facts()) == nil)
        var observe = facts()
        observe.mode = .observe
        #expect(CatchAllPlan.ineligibility(observe) == nil)
    }

    @Test("Each failed condition names its reason")
    func reasons() {
        func check(_ change: (inout CatchAllPlan.DeviceFacts) -> Void, _ reason: CatchAllPlan.Ineligibility) {
            var f = facts()
            change(&f)
            #expect(CatchAllPlan.ineligibility(f) == reason)
        }
        check({ $0.mode = .off }, .modeOff)
        check({ $0.permissionAuthorized = false }, .noPermission)
        check({ $0.sessionActive = false }, .sessionInactive)
        check({ $0.selfObjectKnown = false }, .selfObjectUnknown)
        check({ $0.breakerClosed = false }, .breakerOpen)
        check({ $0.listedAndAlive = false }, .notAlive)
        check({ $0.tier = .hardware }, .hasHardwareVolume)
        check({ $0.tier = .ddc }, .hasHardwareVolume)
        check({ $0.isAggregate = true }, .aggregate)
        check({ $0.isVirtual = true }, .virtualDevice)
        check({ $0.outputStreamCount = 2 }, .notSingleStream)
        check({ $0.outputStreamCount = 0 }, .notSingleStream)
        check({ $0.optedOut = true }, .optedOut)
        check({ $0.givenUp = true }, .givenUp)
    }
}

@Suite("Process identity")
struct ProcessIdentityTests {

    @Test("Owner classification: current user, other humans, system accounts, unknown")
    func classify() {
        #expect(ProcessOwner.classify(uid: 501, currentUID: 501) == .currentUser)
        #expect(ProcessOwner.classify(uid: 502, currentUID: 501) == .otherHuman)
        #expect(ProcessOwner.classify(uid: 0, currentUID: 501) == .system)
        #expect(ProcessOwner.classify(uid: 205, currentUID: 501) == .system)
        #expect(ProcessOwner.classify(uid: 4_294_967_294, currentUID: 501) == .system)  // nobody
        #expect(ProcessOwner.classify(uid: nil, currentUID: 501) == .unknown)
    }

    @Test("The catalog caches lookups and reports other users' processes as foreign")
    func catalog() {
        let lookups = LookupCounter()
        let catalog = ProcessCatalog(
            readPID: { object in lookups.count(); return pid_t(object) },
            readOwnerUID: { pid in pid == 40 ? 502 : (pid == 41 ? 0 : 501) },
            currentUID: 501
        )

        #expect(catalog.foreign(among: [11, 40, 41]) == [40])
        #expect(catalog.entry(for: 40) == ProcessCatalog.Entry(pid: 40, owner: .otherHuman))
        #expect(lookups.value == 3)

        catalog.prune(keeping: [11])
        _ = catalog.entry(for: 40)
        #expect(lookups.value == 4)
    }

    @Test("An object without a PID has no entry")
    func noPID() {
        let catalog = ProcessCatalog(readPID: { _ in nil }, readOwnerUID: { _ in 501 }, currentUID: 501)
        #expect(catalog.entry(for: 11) == nil)
        #expect(catalog.foreign(among: [11]).isEmpty)
    }
}

private nonisolated final class LookupCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func count() { lock.withLock { _value += 1 } }
}
