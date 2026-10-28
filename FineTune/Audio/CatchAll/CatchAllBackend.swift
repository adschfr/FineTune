// FineTune/Audio/CatchAll/CatchAllBackend.swift
import AudioToolbox
import CoreAudio
import Foundation
import os

/// Core Audio objects of one catch-all.
nonisolated struct CatchAllResources: @unchecked Sendable {
    var tapID: AudioObjectID = .unknown
    var aggregateID: AudioDeviceID = .unknown
    var procID: AudioDeviceIOProcID?
}

/// Every Core Audio call the catch-all makes, behind a protocol so unit tests never create
/// real taps (that would make macOS ask for permissions).
nonisolated protocol CatchAllBackend: Sendable {
    func deviceID(forUID uid: String) -> AudioDeviceID?
    func firstOutputStreamIndex(of device: AudioDeviceID) throws -> UInt
    /// Sub-tap drift compensation, by the rule of per-app taps: off for Bluetooth and virtual devices.
    func tapDriftCompensation(for device: AudioDeviceID) -> Bool
    func createTap(_ description: CATapDescription) throws -> AudioObjectID
    func readTapUID(_ tap: AudioObjectID) -> String?
    func readTapDescription(_ tap: AudioObjectID) -> CATapDescription?
    func setTapDescription(_ description: CATapDescription, on tap: AudioObjectID) throws
    func createAggregate(_ description: [String: Any]) throws -> AudioDeviceID
    func waitUntilReady(_ aggregate: AudioDeviceID, timeout: TimeInterval) -> Bool
    func nominalSampleRate(_ device: AudioDeviceID) -> Double?
    func createIOProc(on aggregate: AudioDeviceID, clientData: UnsafeMutableRawPointer) throws -> AudioDeviceIOProcID
    func disableHardwareInputs(on aggregate: AudioDeviceID, proc: AudioDeviceIOProcID)
    func start(_ aggregate: AudioDeviceID, _ proc: AudioDeviceIOProcID) -> OSStatus
    func stop(_ aggregate: AudioDeviceID, _ proc: AudioDeviceIOProcID) -> OSStatus
    /// Stops IO and destroys the IO proc, the aggregate and the tap, in that order, off the
    /// calling thread. `completion` runs after the last step.
    func destroy(_ resources: CatchAllResources, completion: @escaping @Sendable () -> Void)
}

nonisolated struct CatchAllBackendError: Error, Equatable {
    let status: OSStatus
}

/// The real backend.
nonisolated struct CoreAudioCatchAllBackend: CatchAllBackend {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.finetuneapp.FineTune", category: "CatchAll")

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard let devices = try? AudioObjectID.readDeviceList() else { return nil }
        return devices.first { (try? $0.readDeviceUID()) == uid }
    }

    func firstOutputStreamIndex(of device: AudioDeviceID) throws -> UInt {
        try device.firstOutputStreamIndex()
    }

    func tapDriftCompensation(for device: AudioDeviceID) -> Bool {
        !device.isVirtualDevice() && !device.isBluetoothDevice()
    }

    func createTap(_ description: CATapDescription) throws -> AudioObjectID {
        var tapID: AudioObjectID = .unknown
        let err = AudioHardwareCreateProcessTap(description, &tapID)
        guard err == noErr, tapID.isValid else { throw CatchAllBackendError(status: err) }
        return tapID
    }

    func readTapUID(_ tap: AudioObjectID) -> String? {
        try? AudioHardwareTap(id: tap).uid
    }

    func readTapDescription(_ tap: AudioObjectID) -> CATapDescription? {
        try? AudioHardwareTap(id: tap).description
    }

    func setTapDescription(_ description: CATapDescription, on tap: AudioObjectID) throws {
        try AudioHardwareTap(id: tap).setDescription(description)
    }

    func createAggregate(_ description: [String: Any]) throws -> AudioDeviceID {
        var aggregateID: AudioDeviceID = .unknown
        let err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard err == noErr, aggregateID.isValid else { throw CatchAllBackendError(status: err) }
        CrashGuard.trackDevice(aggregateID)
        return aggregateID
    }

    func waitUntilReady(_ aggregate: AudioDeviceID, timeout: TimeInterval) -> Bool {
        aggregate.waitUntilReady(timeout: timeout)
    }

    func nominalSampleRate(_ device: AudioDeviceID) -> Double? {
        guard let rate = try? device.readNominalSampleRate(), rate > 0 else { return nil }
        return rate
    }

    func createIOProc(on aggregate: AudioDeviceID, clientData: UnsafeMutableRawPointer) throws -> AudioDeviceIOProcID {
        var procID: AudioDeviceIOProcID?
        let err = AudioDeviceCreateIOProcID(aggregate, catchAllIOProc, clientData, &procID)
        guard err == noErr, let procID else { throw CatchAllBackendError(status: err) }
        return procID
    }

    /// Marks the wrapped device's hardware input streams unused so they are never powered
    /// on (a duplex output would otherwise count as microphone use). Same as the per-app
    /// path in ProcessTapController.disableHardwareInputStreams, kept separate there to keep
    /// that upstream file unchanged.
    func disableHardwareInputs(on aggregate: AudioDeviceID, proc: AudioDeviceIOProcID) {
        let inputCount = aggregate.streamCount(scope: kAudioObjectPropertyScopeInput)
        let outputCount = aggregate.streamCount(scope: kAudioObjectPropertyScopeOutput)
        guard let flagsArray = Self.inputStreamUsageFlags(inputCount: inputCount, outputCount: outputCount) else { return }

        // AudioHardwareIOProcStreamUsage: { void* mIOProc; UInt32 mNumberStreams; UInt32 mStreamIsOn[]; }
        let headerSize = MemoryLayout<UnsafeMutableRawPointer>.size + MemoryLayout<UInt32>.size
        let totalSize = headerSize + inputCount * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: totalSize, alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment)
        defer { raw.deallocate() }
        raw.storeBytes(of: unsafeBitCast(proc, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(inputCount), toByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
        for (index, isUsed) in flagsArray.enumerated() {
            raw.storeBytes(of: isUsed, toByteOffset: headerSize + index * MemoryLayout<UInt32>.size, as: UInt32.self)
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOProcStreamUsage,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let err = AudioObjectSetPropertyData(aggregate, &address, 0, nil, UInt32(totalSize), raw)
        if err != noErr {
            Self.logger.warning("Could not disable catch-all hardware input streams (\(err))")
        }
    }

    /// 1 for the trailing tap streams the IO proc reads, 0 for leading hardware inputs; nil
    /// when nothing needs disabling (same rule as ProcessTapController.inputStreamUsageFlags).
    static func inputStreamUsageFlags(inputCount: Int, outputCount: Int) -> [UInt32]? {
        guard inputCount > 0, outputCount > 0 else { return nil }
        let usedInputStreams = min(outputCount, inputCount)
        guard inputCount > usedInputStreams else { return nil }
        return (0..<inputCount).map { $0 >= inputCount - usedInputStreams ? 1 : 0 }
    }

    func start(_ aggregate: AudioDeviceID, _ proc: AudioDeviceIOProcID) -> OSStatus {
        AudioDeviceStart(aggregate, proc)
    }

    func stop(_ aggregate: AudioDeviceID, _ proc: AudioDeviceIOProcID) -> OSStatus {
        AudioDeviceStop(aggregate, proc)
    }

    func destroy(_ resources: CatchAllResources, completion: @escaping @Sendable () -> Void) {
        var tapResources = TapResources()
        tapResources.tapID = resources.tapID
        tapResources.aggregateDeviceID = resources.aggregateID
        tapResources.deviceProcID = resources.procID
        tapResources.destroyAsync(completion: completion)
    }
}
