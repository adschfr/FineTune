// FineTune/Audio/CatchAll/CatchAllRender.swift
//
// Real-time path of the catch-all tap. Runs on the HAL IO thread: no allocation, locks,
// logging, Objective-C or reference counting here. A unit test checks this file for
// forbidden calls.

import AudioToolbox
import Darwin
import Synchronization

/// State shared between the catch-all's IO proc and the threads that control it.
nonisolated final class CatchAllRenderState: @unchecked Sendable {
    /// Touched only by the IO thread; plain pointer memory has no exclusivity checks.
    struct RTScalars {
        var currentGain: Float
        var gatePhase: UInt8 = 0
        var gateProgress: Float = 0
        var previousCallbackHostTime: UInt64 = 0
    }

    // Written by main or the run queue, read by the IO thread
    let targetGainBits: Atomic<UInt32>
    let held: Atomic<Bool>
    /// Next callback starts at the target gain instead of ramping (after build or resume).
    let seedGain = Atomic<Bool>(true)
    /// Next callback re-arms the fade-in gate.
    let rearmGate = Atomic<Bool>(true)

    // Written by the IO thread, read elsewhere
    let lastCallbackHostTime = Atomic<UInt64>(0)
    let lastAudibleHostTime = Atomic<UInt64>(0)
    /// Input peak of the latest buffer (Float bits), for on-device measurements.
    let lastPeakBits = Atomic<UInt32>(0)
    let callbackCount = Atomic<UInt64>(0)

    let rt: UnsafeMutablePointer<RTScalars>

    let observeOnly: Bool
    let rampCoefficient: Float
    let gateRampSamples: Float
    let preferredStereoLeft: Int
    let preferredStereoRight: Int
    /// A callback gap longer than this (100 ms) counts as a resume and re-arms the gate.
    let resumeGapHostTicks: UInt64

    init(sampleRate: Double, targetGain: Float, held: Bool, observeOnly: Bool,
         preferredStereoLeft: Int = 0, preferredStereoRight: Int = 1) {
        targetGainBits = Atomic(targetGain.bitPattern)
        self.held = Atomic(held)
        self.observeOnly = observeOnly
        // Same 30 ms one-pole ramp and output gate as per-app taps, with a 10 ms fade-in
        rampCoefficient = Float(1 - exp(-1 / (sampleRate * 0.030)))
        gateRampSamples = Float(sampleRate * 0.010)
        self.preferredStereoLeft = preferredStereoLeft
        self.preferredStereoRight = preferredStereoRight
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        resumeGapHostTicks = UInt64(100_000_000 * Double(timebase.denom) / Double(timebase.numer))
        rt = .allocate(capacity: 1)
        rt.initialize(to: RTScalars(currentGain: targetGain))
    }

    deinit {
        rt.deinitialize(count: 1)
        rt.deallocate()
    }

    var targetGain: Float {
        Float(bitPattern: targetGainBits.load(ordering: .acquiring))
    }

    func setTargetGain(_ gain: Float) {
        targetGainBits.store(gain.bitPattern, ordering: .releasing)
    }

    func setHeld(_ value: Bool) {
        held.store(value, ordering: .releasing)
    }
}

nonisolated enum CatchAllRender {
    /// Input above this counts as audible for the run control.
    static let audibleThreshold: Float = 0.0001

    /// One IO cycle: track liveness and audibility, then play the held-back audio at the
    /// device's software gain (ramped, gated, limited), or zeros while held or observing.
    @inline(__always)
    static func render(
        _ state: CatchAllRenderState,
        input: UnsafePointer<AudioBufferList>?,
        output: UnsafeMutablePointer<AudioBufferList>?,
        hostTime: UInt64
    ) {
        guard let output else { return }
        let outputBuffers = UnsafeMutableAudioBufferListPointer(output)
        let rt = state.rt

        let previous = rt.pointee.previousCallbackHostTime
        rt.pointee.previousCallbackHostTime = hostTime
        state.lastCallbackHostTime.store(hostTime, ordering: .relaxed)
        state.callbackCount.wrappingAdd(1, ordering: .relaxed)

        let rearm = state.rearmGate.exchange(false, ordering: .relaxed)
        if rearm || previous == 0 || hostTime &- previous > state.resumeGapHostTicks {
            rt.pointee.gatePhase = 0
            rt.pointee.gateProgress = 0
        }
        if state.seedGain.exchange(false, ordering: .relaxed) {
            rt.pointee.currentGain = state.targetGain
        }

        guard let input else {
            zero(outputBuffers)
            return
        }
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let (peak, frames) = ProcessTapController.inputPeak(inputBuffers)
        state.lastPeakBits.store(peak.bitPattern, ordering: .relaxed)
        if peak > audibleThreshold {
            state.lastAudibleHostTime.store(hostTime, ordering: .relaxed)
        }

        if state.held.load(ordering: .acquiring) || state.observeOnly {
            zero(outputBuffers)
            return
        }

        let gate = ProcessTapController.advanceOutputGate(
            phase: &rt.pointee.gatePhase,
            progress: &rt.pointee.gateProgress,
            maxPeak: peak,
            frameCount: frames,
            rampSamples: state.gateRampSamples
        )
        ProcessTapController.processMappedBuffers(
            inputBuffers: inputBuffers,
            outputBuffers: outputBuffers,
            targetVol: state.targetGain,
            crossfadeMultiplier: 1,
            outputGateMultiplier: gate,
            rampCoefficient: state.rampCoefficient,
            preferredStereoLeft: state.preferredStereoLeft,
            preferredStereoRight: state.preferredStereoRight,
            currentVol: &rt.pointee.currentGain,
            eqProc: nil,
            autoEQProc: nil,
            loudnessEqualizerProc: nil,
            loudnessCompensatorProc: nil
        )
    }

    @inline(__always)
    static func zero(_ buffers: UnsafeMutableAudioBufferListPointer) {
        for buffer in buffers {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
    }
}

/// The catch-all's IO proc. `clientData` is an unretained `CatchAllRenderState` that the
/// controller keeps alive until `AudioDeviceDestroyIOProcID` has returned.
nonisolated let catchAllIOProc: AudioDeviceIOProc = { _, _, input, _, output, _, clientData in
    guard let clientData else { return noErr }
    Unmanaged<CatchAllRenderState>.fromOpaque(clientData)._withUnsafeGuaranteedRef { state in
        CatchAllRender.render(state, input: input, output: output, hostTime: mach_absolute_time())
    }
    return noErr
}
