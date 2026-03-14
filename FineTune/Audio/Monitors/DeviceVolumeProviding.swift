import AudioToolbox

@MainActor
protocol DeviceVolumeProviding: AnyObject {
    var defaultDeviceUID: String? { get }
    var defaultInputDeviceUID: String? { get }
    var volumes: [AudioDeviceID: Float] { get }
    var muteStates: [AudioDeviceID: Bool] { get }

    var onVolumeChanged: ((AudioDeviceID, Float) -> Void)? { get set }
    var onMuteChanged: ((AudioDeviceID, Bool) -> Void)? { get set }
    var onDefaultDeviceChanged: ((String) -> Void)? { get set }
    var onDefaultInputDeviceChanged: ((String) -> Void)? { get set }

    @discardableResult
    func setDefaultDevice(_ deviceID: AudioDeviceID) -> Bool
    @discardableResult
    func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool

    func start()
    func stop()

    /// Called after DDC probe completes to refresh volume/mute states.
    /// Default implementation is a no-op (only relevant for DDC-capable monitors).
    func refreshAfterDDCProbe()
}

extension DeviceVolumeProviding {
    func refreshAfterDDCProbe() {}
}
