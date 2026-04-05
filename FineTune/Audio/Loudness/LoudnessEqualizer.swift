import Foundation

/// Loudness equalizer that applies K-weighted loudness measurement and
/// asymmetric gain smoothing to keep perceived loudness near a target level.
///
/// Input/output memory layout: interleaved — frame-major ordering.
///   `output[f * channelCount + ch]`
///
/// All mutable state is owned exclusively by the real-time audio thread.
/// The class is marked @unchecked Sendable accordingly.
final class LoudnessEqualizer: @unchecked Sendable {

    // MARK: - Private state

    private var settings: LoudnessEqualizerSettings
    private var currentSampleRate: Float
    private let kFilter: KWeightingFilter
    private let detector: LoudnessDetector
    private var gainComputer: GainComputer
    private let gainSmoother: GainSmoother
    private var currentLinearGain: Float = 1.0

    // MARK: - Init

    init(settings: LoudnessEqualizerSettings, sampleRate: Float, channelCount: Int) {
        self.settings = settings
        self.currentSampleRate = sampleRate
        self.kFilter = KWeightingFilter(sampleRate: sampleRate)
        self.detector = LoudnessDetector(settings: settings, sampleRate: sampleRate)
        self.gainComputer = GainComputer(settings: settings)
        self.gainSmoother = GainSmoother(settings: settings, sampleRate: sampleRate)
        self.currentLinearGain = LoudnessEqualizerMath.dbToLinear(self.gainSmoother.currentGainDb)
    }

    // MARK: - Public API

    /// Whether loudness processing is active.
    var isEnabled: Bool { settings.enabled }

    /// The current settings snapshot.
    var currentSettings: LoudnessEqualizerSettings { settings }

    /// Process audio from an interleaved input buffer to an interleaved output buffer.
    ///
    /// - Parameters:
    ///   - input:        Interleaved input: `input[f * channelCount + ch]`
    ///   - output:       Interleaved output: `output[f * channelCount + ch]`
    ///   - frameCount:   Number of frames per channel.
    ///   - channelCount: Number of channels.
    ///
    /// RT-safe: allocation-free, no logging.
    func process(
        input: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) {
        let enabled = settings.enabled
        if !enabled {
            if input != UnsafePointer(output) {
                memcpy(output, input, frameCount * channelCount * MemoryLayout<Float>.size)
            }
            return
        }

        var linearGain = currentLinearGain

        if channelCount == 2 {
            for frame in 0..<frameCount {
                let base = frame * 2
                let mono = (input[base] + input[base + 1]) * 0.5
                let weighted = kFilter.processSample(mono)

                if let newLevel = detector.ingest(weightedSample: weighted) {
                    let desiredGain = gainComputer.desiredGainDb(forLevelDb: newLevel)
                    let smoothedGain = gainSmoother.process(targetGainDb: desiredGain)
                    linearGain = LoudnessEqualizerMath.dbToLinear(smoothedGain)
                    currentLinearGain = linearGain
                }

                output[base] = input[base] * linearGain
                output[base + 1] = input[base + 1] * linearGain
            }
            return
        }

        let inverseChannelCount = 1.0 / Float(channelCount)
        for f in 0..<frameCount {
            let base = f * channelCount

            // --- Sidechain: downmix to mono (interleaved layout) ---
            var mono: Float = 0
            for ch in 0..<channelCount {
                mono += input[base + ch]
            }
            mono *= inverseChannelCount

            // --- K-weighting ---
            let weighted = kFilter.processSample(mono)

            // --- Detector ---
            if let newLevel = detector.ingest(weightedSample: weighted) {
                let desiredGain = gainComputer.desiredGainDb(forLevelDb: newLevel)
                let smoothedGain = gainSmoother.process(targetGainDb: desiredGain)
                linearGain = LoudnessEqualizerMath.dbToLinear(smoothedGain)
                currentLinearGain = linearGain
            }

            // --- Apply gain to all channels ---
            for ch in 0..<channelCount {
                output[base + ch] = input[base + ch] * linearGain
            }
        }
    }

    /// Replace the current settings and propagate to sub-processors.
    func updateSettings(_ settings: LoudnessEqualizerSettings) {
        let wasEnabled = self.settings.enabled
        self.settings = settings
        gainComputer.settings = settings
        detector.updateSettings(settings, sampleRate: currentSampleRate)
        gainSmoother.updateSettings(settings, sampleRate: currentSampleRate)
        if wasEnabled != settings.enabled || !settings.enabled {
            reset()
        }
    }

    /// Notify the equalizer that the host sample rate has changed.
    func updateSampleRate(_ sampleRate: Float) {
        currentSampleRate = sampleRate
        kFilter.updateSampleRate(sampleRate)
        detector.updateSettings(settings, sampleRate: sampleRate)
        gainSmoother.updateSettings(settings, sampleRate: sampleRate)
    }

    /// Reset all internal state to initial conditions.
    func reset() {
        kFilter.reset()
        detector.reset()
        gainSmoother.reset()
        currentLinearGain = 1.0
    }
}
