// FineTuneTests/BluetoothDeviceDiscoveryTests.swift
//
// Which paired Bluetooth devices appear as connectable outputs. Only the pure parts are
// tested: nothing here may touch IOBluetooth, which would ask for the Bluetooth permission.

import Testing
@testable import FineTune

@Suite("Bluetooth paired device discovery")
struct BluetoothDeviceDiscoveryTests {
    private typealias Device = BluetoothDeviceMonitor.RawPairedDevice

    // MARK: - Class of Device

    @Test("Audio hardware with a speaker is recognized from its device class", arguments: [
        UInt32(0x00), 0x01, 0x02, 0x05, 0x06, 0x07, 0x08, 0x0A, 0x0F,
    ])
    func recognizesAudioOutputs(minor: UInt32) {
        #expect(BluetoothDeviceMonitor.isAudioOutputClass(major: 0x04, minor: minor))
    }

    @Test("Audio/Video hardware without a speaker is not an output", arguments: [
        UInt32(0x04), 0x0B, 0x0C, 0x0D, 0x0E,
    ])
    func rejectsAudioHardwareWithoutSpeaker(minor: UInt32) {
        #expect(!BluetoothDeviceMonitor.isAudioOutputClass(major: 0x04, minor: minor))
    }

    @Test("Other paired peripherals are not outputs by class", arguments: [
        UInt32(0x00), 0x01, 0x02, 0x05, 0x07, 0x1F,
    ])
    func rejectsOtherMajorClasses(major: UInt32) {
        #expect(!BluetoothDeviceMonitor.isAudioOutputClass(major: major, minor: 0x06))
    }

    // MARK: - Order

    @Test("An address listed twice appears once, whatever its letter case")
    func removesDuplicateAddresses() {
        let devices = [
            Device(mac: "aa-bb-cc-00-11-22", name: "Headphones", iconName: "headphones"),
            Device(mac: "AA-BB-CC-00-11-22", name: "Headphones", iconName: "headphones"),
        ]
        #expect(BluetoothDeviceMonitor.orderedUnique(devices) == [devices[0]])
    }

    @Test("Devices sort by name, and devices with the same name keep one order")
    func sortsDeterministically() {
        let speaker = Device(mac: "10-00-00-00-00-03", name: "speaker", iconName: "hifispeaker")
        let budsB = Device(mac: "10-00-00-00-00-02", name: "Buds", iconName: "headphones")
        let budsA = Device(mac: "10-00-00-00-00-01", name: "Buds", iconName: "headphones")

        #expect(BluetoothDeviceMonitor.orderedUnique([speaker, budsB, budsA]) == [budsA, budsB, speaker])
        #expect(BluetoothDeviceMonitor.orderedUnique([budsA, speaker, budsB]) == [budsA, budsB, speaker])
    }

    // MARK: - Icon

    @Test("A known product name decides the icon before the device class")
    func nameWinsOverClass() {
        #expect(BluetoothDeviceMonitor.suggestedIconName(for: "AirPods Pro", audioMinorClass: 0x05) == "airpodspro")
        #expect(BluetoothDeviceMonitor.suggestedIconName(for: "Kitchen HomePod mini") == "homepodmini")
    }

    @Test("Without a known name the device class tells speakers from headphones")
    func classDecidesGenericIcon() {
        #expect(BluetoothDeviceMonitor.suggestedIconName(for: "Box", audioMinorClass: 0x05) == "hifispeaker")
        #expect(BluetoothDeviceMonitor.suggestedIconName(for: "Box", audioMinorClass: 0x0A) == "hifispeaker")
        #expect(BluetoothDeviceMonitor.suggestedIconName(for: "Box", audioMinorClass: 0x08) == "car")
        #expect(BluetoothDeviceMonitor.suggestedIconName(for: "Box", audioMinorClass: 0x06) == "headphones")
        #expect(BluetoothDeviceMonitor.suggestedIconName(for: "Box") == "headphones")
    }
}
