// FineTune/Audio/CatchAll/CatchAllTapController.swift
import AudioToolbox
import Foundation
import os
import Synchronization

/// What the run control needs to start and stop one catch-all's IO.
nonisolated struct CatchAllIOHandle: @unchecked Sendable {
    let deviceUID: String
    let aggregateID: AudioDeviceID
    let procID: AudioDeviceIOProcID
    let state: CatchAllRenderState
}

/// One catch-all tap on one software-volume output: a private exclusive muted tap on the
/// device's output stream and a private aggregate that plays the held-back audio at the
/// device's software gain. Built and changed on main; its IO is started and stopped by the
/// run control.
@MainActor
final class CatchAllTapController {
    enum BuildError: Error, Equatable {
        case deviceNotFound
        case noOutputStream
        case tapFailed(OSStatus)
        case descriptionMismatch
        case aggregateFailed(OSStatus)
        case notReady
        case ioProcFailed(OSStatus)
    }

    let deviceUID: String
    let deviceID: AudioDeviceID
    let renderState: CatchAllRenderState
    let ioHandle: CatchAllIOHandle
    private(set) var appliedExclusions: [AudioObjectID]

    private let backend: any CatchAllBackend
    private let description: CATapDescription
    private var resources: CatchAllResources
    private var isGone = false
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.finetuneapp.FineTune", category: "CatchAll")

    private init(deviceUID: String, deviceID: AudioDeviceID, description: CATapDescription,
                 resources: CatchAllResources, procID: AudioDeviceIOProcID, renderState: CatchAllRenderState,
                 exclusions: [AudioObjectID], backend: any CatchAllBackend) {
        self.deviceUID = deviceUID
        self.deviceID = deviceID
        self.description = description
        self.resources = resources
        self.renderState = renderState
        self.appliedExclusions = exclusions
        self.backend = backend
        self.ioHandle = CatchAllIOHandle(deviceUID: deviceUID, aggregateID: resources.aggregateID, procID: procID, state: renderState)
    }

    /// Builds the tap and aggregate without starting IO. From the tap's creation on, every
    /// process playing to the device except `exclusions` is held back. Any failure tears the
    /// partial resources down in order and throws; nothing stays muted.
    static func build(
        deviceUID: String,
        exclusions: [AudioObjectID],
        gain: Float,
        held: Bool,
        observe: Bool,
        backend: any CatchAllBackend
    ) throws -> CatchAllTapController {
        guard let deviceID = backend.deviceID(forUID: deviceUID) else { throw BuildError.deviceNotFound }
        guard let stream = try? backend.firstOutputStreamIndex(of: deviceID) else { throw BuildError.noOutputStream }

        let description = CatchAllTapDescription.make(excluding: exclusions, deviceUID: deviceUID, stream: stream, observe: observe)
        var resources = CatchAllResources()
        func fail(_ error: BuildError) -> BuildError {
            backend.destroy(resources) {}
            return error
        }

        do {
            resources.tapID = try backend.createTap(description)
        } catch {
            throw BuildError.tapFailed((error as? CatchAllBackendError)?.status ?? -1)
        }

        // Core Audio may assign its own tap UID; the aggregate must reference that one
        let tapUID = backend.readTapUID(resources.tapID) ?? description.uuid.uuidString
        guard let applied = backend.readTapDescription(resources.tapID),
              applied.isExclusive, Set(applied.processes) == Set(exclusions) else {
            throw fail(.descriptionMismatch)
        }

        let aggregate = CatchAllTapDescription.aggregate(
            deviceUID: deviceUID,
            tapUID: tapUID,
            tapDriftCompensation: backend.tapDriftCompensation(for: deviceID)
        )
        do {
            resources.aggregateID = try backend.createAggregate(aggregate)
        } catch {
            throw fail(.aggregateFailed((error as? CatchAllBackendError)?.status ?? -1))
        }
        guard backend.waitUntilReady(resources.aggregateID, timeout: 2.0) else { throw fail(.notReady) }

        let rate = backend.nominalSampleRate(resources.aggregateID) ?? 48_000
        let state = CatchAllRenderState(sampleRate: rate, targetGain: gain, held: held, observeOnly: observe)
        let procID: AudioDeviceIOProcID
        do {
            procID = try backend.createIOProc(on: resources.aggregateID, clientData: Unmanaged.passUnretained(state).toOpaque())
        } catch {
            throw fail(.ioProcFailed((error as? CatchAllBackendError)?.status ?? -1))
        }
        resources.procID = procID
        backend.disableHardwareInputs(on: resources.aggregateID, proc: procID)

        return CatchAllTapController(deviceUID: deviceUID, deviceID: deviceID, description: description,
                                     resources: resources, procID: procID, renderState: state,
                                     exclusions: exclusions, backend: backend)
    }

    /// Sets a new exclusion list on the live tap and reads it back. On failure the stored
    /// description keeps the applied list, so it always matches what the tap holds.
    func push(_ exclusions: [AudioObjectID]) -> Bool {
        guard !isGone else { return false }
        guard exclusions != appliedExclusions else { return true }
        let previous = description.processes
        description.processes = exclusions
        do {
            try backend.setTapDescription(description, on: resources.tapID)
            guard let applied = backend.readTapDescription(resources.tapID),
                  applied.isExclusive, Set(applied.processes) == Set(exclusions) else {
                logger.error("Catch-all on \(self.deviceUID, privacy: .public): exclusion read-back mismatch")
                description.processes = previous
                return false
            }
            appliedExclusions = exclusions
            return true
        } catch {
            logger.error("Catch-all on \(self.deviceUID, privacy: .public): exclusion update failed: \(error.localizedDescription)")
            description.processes = previous
            return false
        }
    }

    func setGain(_ gain: Float) {
        renderState.setTargetGain(gain)
    }

    /// Zeroes the output (covered audio stays held back by the tap), e.g. during a format change.
    func hold() {
        renderState.setHeld(true)
    }

    func release() {
        renderState.setHeld(false)
    }

    var callbackCount: UInt64 {
        renderState.callbackCount.load(ordering: .relaxed)
    }

    /// Stops IO and destroys everything, then returns. The render state stays alive until the
    /// IO proc is destroyed, so no callback can touch freed memory.
    func destroy() async {
        guard !isGone else { return }
        isGone = true
        let resources = resources
        let state = renderState
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            backend.destroy(resources) {
                withExtendedLifetime(state) {}
                continuation.resume()
            }
        }
    }

    /// Drops the controller without destroy calls, after a Core Audio service restart when
    /// its object IDs may already name other objects.
    func forget() {
        isGone = true
    }
}
