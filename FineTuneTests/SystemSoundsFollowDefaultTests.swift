// FineTuneTests/SystemSoundsFollowDefaultTests.swift
//
// When the default output vanishes for a moment (a display dropping off HDMI), macOS moves
// the default and the system output to another device. "System sounds follow default" must
// survive that; only a real choice of another device for system sounds turns it off.

import Testing
@testable import FineTune

@Suite("System sounds keep following the default across a device dropout")
struct SystemSoundsFollowDefaultTests {

    @Test("System output equals the live default: still following, even if the cached default lags")
    func matchesLiveDefault() {
        #expect(DeviceVolumeMonitor.classifySystemDeviceChange(
            newSystemUID: "speakers", liveDefaultUID: "speakers", previousSystemDeviceAlive: false
        ) == .stillFollowing)
    }

    @Test("The device system sounds were on went away: macOS moved them, following stays on")
    func previousDeviceVanished() {
        // The default's own change notification has not been applied yet
        #expect(DeviceVolumeMonitor.classifySystemDeviceChange(
            newSystemUID: "speakers", liveDefaultUID: "tv", previousSystemDeviceAlive: false
        ) == .deviceVanished)
    }

    @Test("Another device picked for system sounds while the old one is still there: a user choice")
    func userPickedAnotherDevice() {
        #expect(DeviceVolumeMonitor.classifySystemDeviceChange(
            newSystemUID: "speakers", liveDefaultUID: "tv", previousSystemDeviceAlive: true
        ) == .userChoice)
    }
}
