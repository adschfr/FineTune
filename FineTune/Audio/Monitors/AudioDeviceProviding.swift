import AudioToolbox

@MainActor
protocol AudioDeviceProviding: AnyObject {
    var outputDevices: [AudioDevice] { get }
    var inputDevices: [AudioDevice] { get }

    var onDeviceDisconnected: ((_ uid: String, _ name: String) -> Void)? { get set }
    var onDeviceConnected: ((_ uid: String, _ name: String) -> Void)? { get set }
    var onInputDeviceDisconnected: ((_ uid: String, _ name: String) -> Void)? { get set }
    var onInputDeviceConnected: ((_ uid: String, _ name: String) -> Void)? { get set }

    func device(for uid: String) -> AudioDevice?
    func device(for id: AudioDeviceID) -> AudioDevice?
    func inputDevice(for uid: String) -> AudioDevice?

    /// True for a display output that is in Core Audio but left out of `outputDevices`
    /// because macOS no longer lists its screen.
    func isOutputOfAbsentDisplay(_ uid: String) -> Bool

    func start()
    func stop()
}

extension AudioDeviceProviding {
    // Default for providers that do not hide display outputs
    func isOutputOfAbsentDisplay(_ uid: String) -> Bool { false }
}
