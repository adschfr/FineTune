/// Abstraction over process tap controllers for testability.
///
/// **Threading:** The protocol surface is `@MainActor` — AudioEngine and tests
/// interact with controllers from main. The concrete class straddles main and the
/// CoreAudio HAL I/O thread, but the audio callback never goes through this
/// protocol; it reads `nonisolated(unsafe)` atomic fields directly on the concrete
/// type via a `void *` userdata pointer.
@MainActor
protocol ProcessTapControlling: AnyObject, Sendable {
    var app: AudioApp { get }
    var volume: Float { get set }
    var isMuted: Bool { get set }
    var currentDeviceVolume: Float { get set }
    var isDeviceMuted: Bool { get set }
    var audioLevel: Float { get }
    var currentDeviceUID: String? { get }
    var currentDeviceUIDs: [String] { get }

    func activate(initial: TapInitialState) throws
    func invalidate()
    func invalidateAsync() async
    func updateEQSettings(_ settings: EQSettings)
    func updateAutoEQProfile(_ profile: AutoEQProfile?)
    func setAutoEQPreampEnabled(_ enabled: Bool)
    /// - listeningVolume: device × app volume (phon estimation).
    /// - digitalGain: gain already applied in the tap before the compensator (digital headroom).
    func updateLoudnessCompensation(listeningVolume: Float, digitalGain: Float, enabled: Bool)
    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings)
    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool, autoEQProfile: AutoEQProfile?) async throws
    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool, autoEQProfile: AutoEQProfile?) async throws
    func hasRecentAudioCallback(within seconds: Double) -> Bool
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool
    func hasOutputSampleRateMismatch() -> Bool
    func prepareForOutputFormatChange()
    func cancelOutputFormatChangePreparation()

    var tapSourceDeviceUID: String? { get }
    func refreshTapSource(_ preferredDeviceUID: String?) async throws
    func recreateForOutputRateChange() async throws

    var isSuspended: Bool { get }
    func suspend()
    func resume() throws
    func updateProcesses(for newApp: AudioApp) -> Bool

    /// What the tap's live Core Audio taps hold muted right now (primary and, during a
    /// device switch, secondary). The catch-all only excludes processes a live tap holds.
    var liveCapture: [TapCapture] { get }
}

extension ProcessTapControlling {
    /// Convenience activation with default state. Production callers must pass an
    /// `initial:` populated from persisted settings — defaults leave the first audio
    /// callbacks running with no EQ/AutoEQ/Loudness and unity volume ramp.
    func activate() throws {
        try activate(initial: TapInitialState())
    }

    /// Convenience: defaults sourceDeviceDead to false, autoEQProfile to nil.
    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?, autoEQProfile: AutoEQProfile?) async throws {
        try await switchDevice(to: newDeviceUID, preferredTapSourceDeviceUID: preferredTapSourceDeviceUID, sourceDeviceDead: false, autoEQProfile: autoEQProfile)
    }

    /// Convenience: defaults sourceDeviceDead to false, autoEQProfile to nil.
    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?, autoEQProfile: AutoEQProfile?) async throws {
        try await updateDevices(to: newDeviceUIDs, preferredTapSourceDeviceUID: preferredTapSourceDeviceUID, sourceDeviceDead: false, autoEQProfile: autoEQProfile)
    }

    func invalidateAsync() async {
        invalidate()
    }

    func refreshTapSource(_ preferredDeviceUID: String?) async throws {
        // Default no-op for mocks that don't override
    }

    func recreateForOutputRateChange() async throws {
        // Default no-op for mocks that don't override
    }

    // Defaults for mocks that don't model suspension or process-set changes
    var isSuspended: Bool { false }
    func suspend() {}
    func resume() throws {}
    func updateProcesses(for newApp: AudioApp) -> Bool { true }

    /// Claims nothing, so the catch-all excludes nothing for this tap.
    var liveCapture: [TapCapture] { [] }

    func hasOutputSampleRateMismatch() -> Bool { false }

    func prepareForOutputFormatChange() {}

    func cancelOutputFormatChangePreparation() {}
}
