// FineTuneTests/CatchAllRenderTests.swift
//
// The catch-all's IO path: plays held-back audio at the device's software gain, fades in
// after a pause, limits the sum of many processes and outputs zeros while held.

import AudioToolbox
import Foundation
import Synchronization
import Testing
@testable import FineTune

/// A stereo, interleaved Float32 AudioBufferList with one buffer.
private nonisolated final class StereoBuffer {
    let pointer: UnsafeMutablePointer<AudioBufferList>
    let samples: UnsafeMutablePointer<Float>
    let sampleCount: Int

    init(frames: Int, value: Float = 0) {
        sampleCount = frames * 2
        samples = .allocate(capacity: sampleCount)
        samples.initialize(repeating: value, count: sampleCount)
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(sampleCount * 4), mData: samples)
        ))
    }

    deinit {
        samples.deallocate()
        pointer.deallocate()
    }

    func fill(_ value: Float) { samples.update(repeating: value, count: sampleCount) }
    var peak: Float { (0..<sampleCount).map { abs(samples[$0]) }.max() ?? 0 }
    var last: Float { samples[sampleCount - 1] }
}

@Suite("Catch-all render path")
struct CatchAllRenderTests {

    private let frames = 512
    private let rate = 48_000.0

    private func makeState(gain: Float = 0.25, held: Bool = false, observe: Bool = false) -> CatchAllRenderState {
        CatchAllRenderState(sampleRate: rate, targetGain: gain, held: held, observeOnly: observe)
    }

    /// Host ticks for `ms` milliseconds, from the state's 100 ms resume gap.
    private func ticks(_ state: CatchAllRenderState, ms: Double) -> UInt64 {
        UInt64(Double(state.resumeGapHostTicks) * ms / 100)
    }

    /// Renders `count` consecutive buffers about 10.7 ms apart; returns the next host time.
    @discardableResult
    private func render(_ state: CatchAllRenderState, _ input: StereoBuffer, _ output: StereoBuffer,
                        count: Int, from start: UInt64) -> UInt64 {
        var time = start
        for _ in 0..<count {
            CatchAllRender.render(state, input: input.pointer, output: output.pointer, hostTime: time)
            time += ticks(state, ms: 10.7)
        }
        return time
    }

    @Test("After the fade-in the output is input × software gain, starting at the target gain")
    func playsAtSoftwareGain() {
        let state = makeState(gain: 0.25)
        let input = StereoBuffer(frames: frames, value: 0.5)
        let output = StereoBuffer(frames: frames)

        render(state, input, output, count: 3, from: 1_000_000)

        #expect(abs(output.last - 0.125) < 1e-4)
    }

    @Test("The first buffer of a sound is faded, never at full scale")
    func firstBufferFaded() {
        let state = makeState(gain: 1.0)
        let input = StereoBuffer(frames: frames, value: 0.5)
        let output = StereoBuffer(frames: frames, value: 9)

        render(state, input, output, count: 1, from: 1_000_000)

        #expect(output.peak == 0)
    }

    @Test("Held and observe mode output exact zeros but still track audibility")
    func heldAndObserveAreSilent() {
        for state in [makeState(held: true), makeState(observe: true)] {
            let input = StereoBuffer(frames: frames, value: 0.5)
            let output = StereoBuffer(frames: frames, value: 9)

            render(state, input, output, count: 3, from: 1_000_000)

            #expect(output.peak == 0)
            #expect(state.lastAudibleHostTime.load(ordering: .relaxed) != 0)
        }
    }

    @Test("Releasing a hold plays at the current gain")
    func releaseAfterHold() {
        let state = makeState(gain: 0.25, held: true)
        let input = StereoBuffer(frames: frames, value: 0.5)
        let output = StereoBuffer(frames: frames)
        let next = render(state, input, output, count: 2, from: 1_000_000)

        state.setHeld(false)
        render(state, input, output, count: 3, from: next)

        #expect(abs(output.last - 0.125) < 1e-4)
    }

    @Test("A gain change ramps instead of jumping")
    func gainRamps() {
        let state = makeState(gain: 0.25)
        let input = StereoBuffer(frames: frames, value: 0.5)
        let output = StereoBuffer(frames: frames)
        let next = render(state, input, output, count: 3, from: 1_000_000)

        state.setTargetGain(1.0)
        render(state, input, output, count: 1, from: next)

        #expect(output.samples[0] < 0.2)
        #expect(output.last > 0.125 && output.last < 0.5)
    }

    @Test("A pause over 100 ms between callbacks fades the next sound in again")
    func pauseRearmsGate() {
        let state = makeState(gain: 1.0)
        let input = StereoBuffer(frames: frames, value: 0.5)
        let output = StereoBuffer(frames: frames)
        let next = render(state, input, output, count: 3, from: 1_000_000)
        #expect(output.peak > 0.4)

        render(state, input, output, count: 1, from: next + ticks(state, ms: 200))

        #expect(output.peak == 0)
    }

    @Test("A resume request re-arms the fade-in without a pause")
    func rearmRequest() {
        let state = makeState(gain: 1.0)
        let input = StereoBuffer(frames: frames, value: 0.5)
        let output = StereoBuffer(frames: frames)
        let next = render(state, input, output, count: 3, from: 1_000_000)

        state.rearmGate.store(true, ordering: .relaxed)
        render(state, input, output, count: 1, from: next)

        #expect(output.peak == 0)
    }

    @Test("Seeding sets the gain directly after a resume")
    func seedGain() {
        let state = makeState(gain: 0.25)
        let input = StereoBuffer(frames: frames, value: 0.5)
        let output = StereoBuffer(frames: frames)
        let next = render(state, input, output, count: 3, from: 1_000_000)

        state.setTargetGain(1.0)
        state.seedGain.store(true, ordering: .relaxed)
        render(state, input, output, count: 2, from: next)

        #expect(abs(output.samples[0] - 0.5) < 1e-4)
    }

    @Test("The sum of many processes is limited below full scale")
    func limiterCapsSum() {
        let state = makeState(gain: 1.0)
        let input = StereoBuffer(frames: frames, value: 3.0)
        let output = StereoBuffer(frames: frames)

        render(state, input, output, count: 3, from: 1_000_000)

        #expect(output.peak <= 1.0)
        #expect(output.peak > 0.5)
    }

    @Test("No input gives zeros; callbacks are counted and timed")
    func nullInputAndCounters() {
        let state = makeState()
        let output = StereoBuffer(frames: frames, value: 9)

        CatchAllRender.render(state, input: nil, output: output.pointer, hostTime: 5_000_000)

        #expect(output.peak == 0)
        #expect(state.callbackCount.load(ordering: .relaxed) == 1)
        #expect(state.lastCallbackHostTime.load(ordering: .relaxed) == 5_000_000)
        #expect(state.lastAudibleHostTime.load(ordering: .relaxed) == 0)
    }

    @Test("The render file contains no logging, locks, dispatch, allocation or retain calls")
    func rtLint() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FineTune/Audio/CatchAll/CatchAllRender.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let forbidden = ["Logger", "logger.", "print(", "DispatchQueue", "Task", "[weak", "os_unfair_lock",
                         "NSLock", "Mutex", ".append(", "String(", "Array(", "takeUnretainedValue", "takeRetainedValue"]
        for token in forbidden {
            #expect(!source.contains(token), "forbidden in the RT path: \(token)")
        }
    }
}
