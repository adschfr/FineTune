// FineTuneTests/MenuBarDeviceIconResolverTests.swift

import Testing
import AudioToolbox
@testable import FineTune

@Suite("MenuBarDeviceIconResolver")
struct MenuBarDeviceIconResolverTests {
    private func device(id: AudioDeviceID, uid: String, name: String) -> AudioDevice {
        AudioDevice(id: id, uid: uid, name: name, icon: nil, supportsAutoEQ: true)
    }

    private func resolve(
        priorityOrder: [String],
        outputDevices: [AudioDevice],
        defaultDeviceID: AudioDeviceID = 999,
        unavailableUIDs: Set<String> = []
    ) -> String {
        MenuBarDeviceIconResolver.resolveSymbol(
            priorityOrder: priorityOrder,
            outputDevices: outputDevices,
            defaultDeviceID: defaultDeviceID,
            isDeviceAvailable: { !unavailableUIDs.contains($0.uid) },
            symbolForDevice: { device in
                if device.name.contains("AirPods") { return "airpodspro" }
                if device.name.contains("HomePod") { return "homepod" }
                if device.name.contains("Display") { return "display" }
                if device.name.contains("HDMI") { return "tv" }
                return "headphones"
            },
            symbolForDefaultID: { _ in "speaker.wave.2" }
        )
    }

    @Test("AirPods/Bluetooth priority returns headphone-style symbol")
    func airPodsPriority() {
        let devices = [
            device(id: 1, uid: "speakers", name: "MacBook Pro Speakers"),
            device(id: 2, uid: "airpods", name: "AirPods Pro")
        ]

        #expect(resolve(priorityOrder: ["airpods", "speakers"], outputDevices: devices) == "airpodspro")
    }

    @Test("Current default output takes precedence over saved priority")
    func defaultOutputTakesPrecedence() {
        let devices = [
            device(id: 1, uid: "speakers", name: "MacBook Pro Speakers"),
            device(id: 2, uid: "airpods", name: "AirPods Pro")
        ]

        #expect(
            resolve(
                priorityOrder: ["speakers", "airpods"],
                outputDevices: devices,
                defaultDeviceID: 2
            ) == "airpodspro"
        )
    }

    @Test("HomePod/AirPlay priority returns HomePod-style symbol")
    func homePodPriority() {
        let devices = [
            device(id: 1, uid: "speakers", name: "MacBook Pro Speakers"),
            device(id: 2, uid: "homepod", name: "HomePod")
        ]

        #expect(resolve(priorityOrder: ["homepod", "speakers"], outputDevices: devices) == "homepod")
    }

    @Test("HDMI or display priority returns display-style symbol")
    func displayPriority() {
        let devices = [
            device(id: 1, uid: "hdmi", name: "HDMI Output"),
            device(id: 2, uid: "studio-display", name: "Studio Display")
        ]

        #expect(resolve(priorityOrder: ["hdmi"], outputDevices: devices) == "tv")
        #expect(resolve(priorityOrder: ["studio-display"], outputDevices: devices) == "display")
    }

    @Test("Unavailable priority device falls back to next connected priority device")
    func unavailablePriorityFallsBack() {
        let devices = [
            device(id: 1, uid: "airpods", name: "AirPods Pro"),
            device(id: 2, uid: "homepod", name: "HomePod")
        ]

        #expect(
            resolve(
                priorityOrder: ["airpods", "homepod"],
                outputDevices: devices,
                unavailableUIDs: ["airpods"]
            ) == "homepod"
        )
    }

    @Test("Unavailable default output falls back to connected priority device")
    func unavailableDefaultFallsBackToPriority() {
        let devices = [
            device(id: 1, uid: "speakers", name: "MacBook Pro Speakers"),
            device(id: 2, uid: "airpods", name: "AirPods Pro")
        ]

        #expect(
            resolve(
                priorityOrder: ["speakers", "airpods"],
                outputDevices: devices,
                defaultDeviceID: 2,
                unavailableUIDs: ["airpods"]
            ) == "headphones"
        )
    }

    @Test("No output devices falls back to default device then hard fallback")
    func noOutputDevicesFallbacks() {
        #expect(resolve(priorityOrder: [], outputDevices: [], defaultDeviceID: 42) == "speaker.wave.2")

        let symbol = MenuBarDeviceIconResolver.resolveSymbol(
            priorityOrder: [],
            outputDevices: [],
            defaultDeviceID: .unknown,
            isDeviceAvailable: { _ in true },
            symbolForDevice: { _ in "unused" },
            symbolForDefaultID: { _ in "unused" }
        )
        #expect(symbol == MenuBarDeviceIconResolver.fallbackSymbol)
    }

    @Test("Override-aware device symbol wins over the derived symbol")
    func overrideAwareSymbolWins() {
        let d = device(id: 2, uid: "airpods", name: "AirPods Pro")
        #expect(MenuBarDeviceIconResolver.symbol(for: d, override: "gamecontroller.fill") == "gamecontroller.fill")
    }

    @Test("Nil override falls back to the device-derived symbol")
    func nilOverrideFallsBack() {
        // 0xFFFFFFFE is never assigned by the HAL, so the fake ID deterministically
        // reads as unreadable name + unknown transport on any machine.
        let d = device(id: 0xFFFF_FFFE, uid: "airpods", name: "AirPods Pro")
        #expect(
            MenuBarDeviceIconResolver.symbol(for: d, override: nil)
                == AudioDeviceID.iconSymbol(forName: "", transport: .unknown)
        )
    }

    @Test("resolveSymbol surfaces an override through the injected closure")
    func resolveSymbolWithOverrideClosure() {
        let overrides = ["airpods": "gamecontroller.fill"]
        let devices = [device(id: 2, uid: "airpods", name: "AirPods Pro")]
        let symbol = MenuBarDeviceIconResolver.resolveSymbol(
            priorityOrder: ["airpods"],
            outputDevices: devices,
            defaultDeviceID: 2,
            isDeviceAvailable: { _ in true },
            symbolForDevice: { MenuBarDeviceIconResolver.symbol(for: $0, override: overrides[$0.uid]) },
            symbolForDefaultID: { _ in "speaker.wave.2" }
        )
        #expect(symbol == "gamecontroller.fill")
    }

    @Test("Invalid default ID returns the fallback without consulting the override")
    func defaultIDInvalidReturnsFallback() {
        var consulted = false
        let symbol = MenuBarDeviceIconResolver.symbol(forDefaultID: .unknown, override: { _ in
            consulted = true
            return "nope"
        })
        #expect(symbol == MenuBarDeviceIconResolver.fallbackSymbol)
        #expect(!consulted)
    }

    @Test("Default ID with unreadable UID falls through to the derived symbol")
    func defaultIDUnreadableUIDFallsThrough() {
        #expect(
            MenuBarDeviceIconResolver.symbol(forDefaultID: 0xFFFF_FFFE, override: { _ in "nope" })
                == AudioDeviceID.iconSymbol(forName: "", transport: .unknown)
        )
    }
}
