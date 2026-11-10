// FineTune/Audio/Monitors/AudioDeviceMonitor.swift
import AppKit
import AudioToolbox
import os

@Observable
@MainActor
final class AudioDeviceMonitor: AudioDeviceProviding {
    // MARK: - Output Devices

    private(set) var outputDevices: [AudioDevice] = []

    /// O(1) device lookup by UID
    private(set) var devicesByUID: [String: AudioDevice] = [:]

    /// O(1) device lookup by AudioDeviceID
    private(set) var devicesByID: [AudioDeviceID: AudioDevice] = [:]

    /// Called immediately when output device disappears (passes UID and name)
    var onDeviceDisconnected: ((_ uid: String, _ name: String) -> Void)?

    /// Called when an output device appears (passes UID and name)
    var onDeviceConnected: ((_ uid: String, _ name: String) -> Void)?

    // MARK: - Input Devices

    private(set) var inputDevices: [AudioDevice] = []

    /// O(1) input device lookup by UID
    private(set) var inputDevicesByUID: [String: AudioDevice] = [:]

    /// O(1) input device lookup by AudioDeviceID
    private(set) var inputDevicesByID: [AudioDeviceID: AudioDevice] = [:]

    /// Called immediately when input device disappears (passes UID and name)
    var onInputDeviceDisconnected: ((_ uid: String, _ name: String) -> Void)?

    /// Called when an input device appears (passes UID and name)
    var onInputDeviceConnected: ((_ uid: String, _ name: String) -> Void)?

    /// Returns current output device priority order (highest priority first) for deterministic callback ordering
    var outputPriorityOrder: (() -> [String])?

    /// Returns current input device priority order (highest priority first) for deterministic callback ordering
    var inputPriorityOrder: (() -> [String])?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AudioDeviceMonitor")

    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var knownDeviceUIDs: Set<String> = []
    private var knownInputDeviceUIDs: Set<String> = []

    /// Listeners for kAudioDevicePropertyDataSource changes on built-in devices (headphone jack detection)
    @ObservationIgnored private var dataSourceListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]

    /// Fired on the first HAL notification before debounce settles. AudioEngine silences affected taps immediately.
    var onOutputDeviceFormatChanging: ((_ uid: String) -> Void)?
    /// Fired when debounce/stability checks conclude there was no real format change (false alarm).
    var onOutputDeviceFormatUnchanged: ((_ uid: String) -> Void)?
    /// Fired after debounce and format stability when sample rate or bit depth actually changed.
    /// Off-protocol — wired via the `as? AudioDeviceMonitor` cast, like the priority-order closures.
    var onOutputDeviceFormatChanged: ((_ uid: String) -> Void)?

    /// Listeners for kAudioDevicePropertyNominalSampleRate changes on all output devices.
    /// BT A2DP↔SCO switches keep the same AudioObjectID and only change nominal rate; wired/USB
    /// devices also need this so tap aggregates don't run at a stale rate (#395).
    @ObservationIgnored private var sampleRateListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    @ObservationIgnored private var lastKnownSampleRates: [AudioDeviceID: Double] = [:]
    @ObservationIgnored private var formatChangeDebounce: [AudioDeviceID: Task<Void, Never>] = [:]

    /// Listeners for kAudioStreamPropertyPhysicalFormat on output streams (bit depth / format ID).
    @ObservationIgnored private var physicalFormatListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    @ObservationIgnored private var lastKnownFormats: [AudioDeviceID: OutputFormatFingerprint] = [:]

    /// 150 ms debounce — the HAL fires several nominal-rate notifications while BT SCO settles.
    nonisolated static let bluetoothSampleRateDebounceMs = 150
    nonisolated static let wiredSampleRateDebounceMs = 50

    /// Debounces rapid HAL device-list notifications (e.g. Bluetooth connect fires 2-3 in ~20ms).
    /// Querying device properties during the burst produces HALC_ShellObject errors because
    /// HAL proxy objects are mid-transition. 50ms lets the HAL stabilize before we enumerate.
    private var deviceListDebounceTask: Task<Void, Never>?

    // MARK: - Outputs of switched-off displays

    /// Whether the output of a display that macOS no longer lists is left out of the device
    /// list, so it counts as disconnected. Off for a bare monitor; AudioEngine wires the setting.
    @ObservationIgnored var hidesOutputsOfAbsentDisplays: () -> Bool = { false }

    /// Display outputs that are in Core Audio but left out of `outputDevices` right now.
    @ObservationIgnored private(set) var absentDisplayOutputUIDs: Set<String> = []

    @ObservationIgnored private var displayGate = DisplayOutputGate(
        seenOnline: Set(UserDefaults.standard.stringArray(forKey: AudioDeviceMonitor.seenDisplayOutputsKey) ?? [])
    )
    @ObservationIgnored private var displayRecheckTask: Task<Void, Never>?
    @ObservationIgnored private var displayObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    @ObservationIgnored private var screensAsleep = false
    /// Uptime before which screens are not judged, because they come back one by one after a wake.
    @ObservationIgnored private var displayJudgementResumesAt: TimeInterval = 0

    nonisolated static let seenDisplayOutputsKey = "displayOutputsSeenOnline"
    nonisolated static let displayOutputTransports: Set<TransportType> = [.hdmi, .displayPort]
    /// A TV can take several seconds to renegotiate its link after a wake; judging earlier
    /// would move audio off it for nothing.
    nonisolated static let displayWakeGrace: TimeInterval = 10
    /// How often the screen list is checked while an output is hidden.
    nonisolated static let hiddenOutputPollInterval: TimeInterval = 2

    /// True when the output's nominal rate changed to a different valid rate, so each affected
    /// tap's aggregate must be recreated to match. Pure, for testability. `newRate <= 0` is a transient/failed read
    /// (never act, and the caller must not store it as the baseline or the next real read looks like
    /// no change). Fires on ANY change (A2DP↔SCO and within-band) — the aggregate must always match.
    nonisolated static func isMeaningfulRateChange(oldRate: Double, newRate: Double) -> Bool {
        newRate > 0 && newRate != oldRate
    }

    nonisolated static func sampleRateDebounceMs(for deviceID: AudioDeviceID) -> Int {
        deviceID.isBluetoothDevice() ? bluetoothSampleRateDebounceMs : wiredSampleRateDebounceMs
    }

    func start() {
        guard deviceListListenerBlock == nil else { return }

        logger.debug("Starting audio device monitor")

        refresh()

        deviceListListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.scheduleDeviceListRefresh()
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            .system,
            &deviceListAddress,
            .main,
            deviceListListenerBlock!
        )

        if status != noErr {
            logger.error("Failed to add device list listener: \(status)")
        }

        startObservingDisplays()
    }

    func stop() {
        logger.debug("Stopping audio device monitor")

        deviceListDebounceTask?.cancel()
        deviceListDebounceTask = nil
        displayRecheckTask?.cancel()
        displayRecheckTask = nil
        for observer in displayObservers {
            observer.center.removeObserver(observer.token)
        }
        displayObservers.removeAll()

        if let block = deviceListListenerBlock {
            AudioObjectRemovePropertyListenerBlock(.system, &deviceListAddress, .main, block)
            deviceListListenerBlock = nil
        }
        removeAllDataSourceListeners()
        removeAllSampleRateListeners()
        removeAllPhysicalFormatListeners()
    }

    /// O(1) lookup by device UID (output devices)
    func device(for uid: String) -> AudioDevice? {
        devicesByUID[uid]
    }

    /// O(1) lookup by AudioDeviceID (output devices)
    func device(for id: AudioDeviceID) -> AudioDevice? {
        devicesByID[id]
    }

    /// O(1) lookup by device UID (input devices)
    func inputDevice(for uid: String) -> AudioDevice? {
        inputDevicesByUID[uid]
    }

    /// O(1) lookup by AudioDeviceID (input devices)
    func inputDevice(for id: AudioDeviceID) -> AudioDevice? {
        inputDevicesByID[id]
    }

    private func refresh() {
        do {
            let deviceIDs = try AudioObjectID.readDeviceList()
            var outputDeviceList: [AudioDevice] = []
            var inputDeviceList: [AudioDevice] = []

            for deviceID in deviceIDs {
                guard let uid = try? deviceID.readDeviceUID(),
                      let name = try? deviceID.readDeviceName() else {
                    continue
                }

                // FineTune's own internal aggregates (used for process taps) are
                // `kAudioAggregateDeviceIsPrivateKey: true`, but still visible to the
                // creating process. Skip them by name prefix so they don't appear in
                // our own picker. User-created aggregates (Audio MIDI Setup Multi-Output,
                // etc.) pass through.
                if deviceID.isAggregateDevice() && name.hasPrefix("FineTune-") { continue }

                // Respect the driver's own opt-out. `kAudioDevicePropertyIsHidden` is
                // how drivers signal "maintenance/utility device, don't show in
                // pickers" — mirrors what Apple's System Settings does.
                if deviceID.isHidden() { continue }

                // Output devices. Virtual outputs (BlackHole, Loopback, Teams Audio)
                // are NOT filtered out here — users who don't want them in their
                // picker can hide them per-device via the reorder-mode eye toggle.
                if deviceID.hasOutputStreams() {
                    // Try Core Audio icon first (via LRU cache), fall back to SF Symbol
                    let icon = DeviceIconCache.shared.icon(for: uid) {
                        deviceID.readDeviceIcon()
                    } ?? NSImage(systemSymbolName: deviceID.suggestedIconSymbol(), accessibilityDescription: name)

                    let device = AudioDevice(
                        id: deviceID,
                        uid: uid,
                        name: name,
                        icon: icon,
                        supportsAutoEQ: deviceID.supportsAutoEQ()
                    )
                    outputDeviceList.append(device)
                }

                // Input devices. Zombie virtuals (registered but not alive — e.g.
                // Teams Audio when Teams isn't running) are no longer filtered
                // here; the hide toggle provides per-device suppression.
                if deviceID.hasInputStreams() {
                    // Try Core Audio icon first, fall back to smart detection
                    let icon = DeviceIconCache.shared.icon(for: uid) {
                        deviceID.readDeviceIcon()
                    } ?? NSImage(systemSymbolName: deviceID.suggestedInputIconSymbol(),
                                 accessibilityDescription: name)

                    let device = AudioDevice(
                        id: deviceID,
                        uid: uid,
                        name: name,
                        icon: icon,
                        supportsAutoEQ: false
                    )
                    inputDeviceList.append(device)
                }
            }

            // The output of a switched-off display counts as disconnected
            let absentUIDs = absentDisplayOutputs(among: outputDeviceList)
            if !absentUIDs.isEmpty {
                outputDeviceList.removeAll { absentUIDs.contains($0.uid) }
            }

            // Update output devices
            outputDevices = outputDeviceList.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            knownDeviceUIDs = Set(outputDeviceList.map(\.uid))
            devicesByUID = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.uid, $0) })
            devicesByID = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.id, $0) })

            // Update input devices
            inputDevices = inputDeviceList.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            knownInputDeviceUIDs = Set(inputDeviceList.map(\.uid))
            inputDevicesByUID = Dictionary(uniqueKeysWithValues: inputDevices.map { ($0.uid, $0) })
            inputDevicesByID = Dictionary(uniqueKeysWithValues: inputDevices.map { ($0.id, $0) })

            syncDataSourceListeners(outputDeviceIDs: outputDeviceList.map(\.id))
            let outputIDs = Set(outputDeviceList.map(\.id))
            syncSampleRateListeners(outputDeviceIDs: outputIDs)
            syncPhysicalFormatListeners(outputDeviceIDs: outputIDs)

        } catch {
            logger.error("Failed to refresh device list: \(error.localizedDescription)")
        }
    }

    // MARK: - Outputs of switched-off displays

    func isOutputOfAbsentDisplay(_ uid: String) -> Bool {
        absentDisplayOutputUIDs.contains(uid)
    }

    /// Re-reads the device list after the setting changed, so hidden outputs return (or
    /// leave) through the normal connect and disconnect callbacks.
    func displayOutputSettingChanged() {
        handleDeviceListChanged()
    }

    /// Which of the given outputs to leave out because macOS no longer lists their screen.
    /// Schedules a re-read when a screen is missing but its delay has not run out yet.
    private func absentDisplayOutputs(among devices: [AudioDevice]) -> Set<String> {
        displayRecheckTask?.cancel()
        displayRecheckTask = nil

        guard hidesOutputsOfAbsentDisplays() else {
            displayGate.reset()
            absentDisplayOutputUIDs = []
            return []
        }

        let candidates = devices.filter { Self.displayOutputTransports.contains($0.id.readTransportType()) }
        let now = ProcessInfo.processInfo.systemUptime
        let wakeGraceRunning = !screensAsleep && now < displayJudgementResumesAt

        let seenBefore = displayGate.seenOnline
        let hiddenBefore = displayGate.hidden
        let nextCheck = displayGate.update(
            candidateUIDs: candidates.map(\.uid),
            online: DisplayOutputGate.readOnlineDisplays(),
            mayHide: !screensAsleep && !wakeGraceRunning,
            now: now
        )

        if displayGate.seenOnline != seenBefore {
            UserDefaults.standard.set(displayGate.seenOnline.sorted(), forKey: Self.seenDisplayOutputsKey)
        }
        for device in candidates where displayGate.hidden.contains(device.uid) != hiddenBefore.contains(device.uid) {
            if displayGate.hidden.contains(device.uid) {
                logger.notice("Display of \(device.name) is off, treating its output as disconnected")
            } else {
                logger.notice("Display of \(device.name) is back, output available again")
            }
        }

        absentDisplayOutputUIDs = displayGate.hidden
        // Re-read when a delay runs out or, after a wake, once the screens have settled
        scheduleDisplayRecheck(due: nextCheck ?? (wakeGraceRunning ? displayJudgementResumesAt : nil))
        return displayGate.hidden
    }

    /// Re-reads the device list once `due` (uptime) is reached. While an output is hidden it
    /// also polls the screen list, which is cheap, and re-reads as soon as that screen is
    /// online again, in case no notification reaches us. Ends when neither applies.
    private func scheduleDisplayRecheck(due: TimeInterval?) {
        displayRecheckTask?.cancel()
        displayRecheckTask = nil
        guard due != nil || !absentDisplayOutputUIDs.isEmpty else { return }

        displayRecheckTask = Task { @MainActor [weak self] in
            while true {
                let untilDue = due.map { max(0, $0 - ProcessInfo.processInfo.systemUptime) + 0.1 }
                try? await Task.sleep(for: .seconds(min(Self.hiddenOutputPollInterval, untilDue ?? .infinity)))
                guard !Task.isCancelled, let self else { return }
                let dueReached = due.map { ProcessInfo.processInfo.systemUptime >= $0 } ?? false
                if dueReached || self.hiddenScreenIsBack() {
                    self.displayRecheckTask = nil
                    self.handleDeviceListChanged()
                    return
                }
            }
        }
    }

    private func hiddenScreenIsBack() -> Bool {
        guard !absentDisplayOutputUIDs.isEmpty,
              let online = DisplayOutputGate.readOnlineDisplays() else { return false }
        return absentDisplayOutputUIDs.contains { uid in
            guard let key = DisplayOutputGate.displayKey(fromUID: uid) else { return true }
            return online.contains { DisplayOutputGate.matches($0, key: key, uid: uid) }
        }
    }

    /// Screens come and go without a Core Audio notification, so the device list is re-read
    /// on display changes too. While the screens sleep, and shortly after, nothing is hidden.
    private func startObservingDisplays() {
        guard displayObservers.isEmpty else { return }
        let app = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter

        let changed = app.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.hidesOutputsOfAbsentDisplays() else { return }
                self.scheduleDeviceListRefresh()
            }
        }
        let slept = workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.screensAsleep = true
            }
        }
        let woke = workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.screensAsleep = false
                self.displayJudgementResumesAt = ProcessInfo.processInfo.systemUptime + Self.displayWakeGrace
                guard self.hidesOutputsOfAbsentDisplays() else { return }
                self.scheduleDisplayRecheck(due: self.displayJudgementResumesAt)
            }
        }
        displayObservers = [(app, changed), (workspace, slept), (workspace, woke)]
    }

    /// Installs/removes kAudioDevicePropertyDataSource listeners on built-in output devices
    /// so headphone jack plug/unplug triggers a refresh.
    private func syncDataSourceListeners(outputDeviceIDs: [AudioDeviceID]) {
        let builtInIDs = Set(outputDeviceIDs.filter { $0.readTransportType() == .builtIn })
        let currentIDs = Set(dataSourceListeners.keys)

        // Remove listeners for devices no longer present
        for deviceID in currentIDs.subtracting(builtInIDs) {
            removeDataSourceListener(for: deviceID)
        }

        // Add listeners for new built-in devices
        for deviceID in builtInIDs.subtracting(currentIDs) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDataSource,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.scheduleDeviceListRefresh()
                }
            }
            let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block)
            if status == noErr {
                dataSourceListeners[deviceID] = block
            } else {
                logger.warning("Failed to add data source listener for device \(deviceID): \(status)")
            }
        }
    }

    private func removeDataSourceListener(for deviceID: AudioDeviceID) {
        guard let block = dataSourceListeners.removeValue(forKey: deviceID) else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
        // Tolerate kAudioHardwareBadObjectError (-66680): device was already destroyed
        if status != noErr && status != OSStatus(kAudioHardwareBadObjectError) {
            logger.warning("Failed to remove data source listener for device \(deviceID): \(status)")
        }
    }

    private func removeAllDataSourceListeners() {
        for deviceID in dataSourceListeners.keys {
            removeDataSourceListener(for: deviceID)
        }
    }

    // MARK: - Sample rate listeners (A2DP ↔ SCO/HFP and wired)

    /// Installs/removes kAudioDevicePropertyNominalSampleRate listeners on all output devices so
    /// A2DP ↔ SCO/HFP mode switches (which keep the same AudioObjectID, only changing the nominal
    /// rate) and wired format changes trigger tap re-evaluation.
    private func syncSampleRateListeners(outputDeviceIDs: Set<AudioDeviceID>) {
        let currentIDs = Set(sampleRateListeners.keys)

        for deviceID in currentIDs.subtracting(outputDeviceIDs) {
            removeSampleRateListener(for: deviceID)
        }

        for deviceID in outputDeviceIDs.subtracting(currentIDs) {
            guard let uid = devicesByID[deviceID]?.uid else { continue }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.notifyFormatChangePending(forDeviceID: deviceID, uid: uid)
                }
            }
            let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block)
            if status == noErr {
                sampleRateListeners[deviceID] = block
                lastKnownSampleRates[deviceID] = (try? deviceID.readNominalSampleRate()) ?? 0
                if let fingerprint = OutputFormatFingerprint.from(deviceID: deviceID) {
                    lastKnownFormats[deviceID] = fingerprint
                }
            } else {
                logger.warning("Failed to add sample rate listener for device \(deviceID): \(status)")
            }
        }
    }

    private func notifyFormatChangePending(forDeviceID deviceID: AudioDeviceID, uid: String) {
        onOutputDeviceFormatChanging?(uid)
        scheduleFormatChangeCheck(forDeviceID: deviceID, uid: uid)
    }

    /// Debounces rapid HAL notifications — BT uses 150 ms while SCO settles; wired uses 50 ms.
    private func scheduleFormatChangeCheck(forDeviceID deviceID: AudioDeviceID, uid: String) {
        formatChangeDebounce[deviceID]?.cancel()
        let debounceMs = Self.sampleRateDebounceMs(for: deviceID)
        formatChangeDebounce[deviceID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(debounceMs))
            guard !Task.isCancelled, let self else { return }
            await self.checkFormatChange(forDeviceID: deviceID, uid: uid)
        }
    }

    private func checkFormatChange(forDeviceID deviceID: AudioDeviceID, uid: String) async {
        guard await waitForStableOutputFormat(deviceID: deviceID) else {
            onOutputDeviceFormatUnchanged?(uid)
            return
        }

        let newFingerprint = OutputFormatFingerprint.from(deviceID: deviceID)
        let oldFingerprint = lastKnownFormats[deviceID]
        let newRate = newFingerprint?.sampleRate ?? ((try? deviceID.readNominalSampleRate()) ?? 0)
        let oldRate = lastKnownSampleRates[deviceID] ?? 0

        let fingerprintChanged = OutputFormatFingerprint.isMeaningfulChange(old: oldFingerprint, new: newFingerprint)
        let rateChanged = Self.isMeaningfulRateChange(oldRate: oldRate, newRate: newRate)
        guard fingerprintChanged || rateChanged else {
            onOutputDeviceFormatUnchanged?(uid)
            return
        }

        // Skip transient HAL failures BEFORE touching the baseline. Storing a transient 0 would make
        // the next real read (e.g. 24 kHz SCO) look like a cold start and miss the A2DP→call
        // transition — re-introducing the crackle this listener exists to prevent.
        if let newFingerprint {
            lastKnownFormats[deviceID] = newFingerprint
            lastKnownSampleRates[deviceID] = newFingerprint.sampleRate
        } else if newRate > 0 {
            lastKnownSampleRates[deviceID] = newRate
        }

        logger.info("[FORMAT] Output device \(uid, privacy: .public) format stabilized")
        onOutputDeviceFormatChanged?(uid)
    }

    private func waitForStableOutputFormat(deviceID: AudioDeviceID) async -> Bool {
        var lastRate: Double = 0
        var stableReads = 0
        for _ in 0..<8 {
            let rate = (try? deviceID.readNominalSampleRate()) ?? 0
            guard rate > 0 else {
                stableReads = 0
                try? await Task.sleep(for: .milliseconds(25))
                continue
            }
            if lastRate > 0, abs(rate - lastRate) < 0.5 {
                stableReads += 1
                if stableReads >= 2 { return true }
            } else {
                stableReads = 1
            }
            lastRate = rate
            try? await Task.sleep(for: .milliseconds(25))
        }
        return lastRate > 0
    }

    private func removeSampleRateListener(for deviceID: AudioDeviceID) {
        formatChangeDebounce[deviceID]?.cancel()
        formatChangeDebounce.removeValue(forKey: deviceID)
        lastKnownSampleRates.removeValue(forKey: deviceID)

        guard let block = sampleRateListeners.removeValue(forKey: deviceID) else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
        if status != noErr && status != OSStatus(kAudioHardwareBadObjectError) {
            logger.warning("Failed to remove sample rate listener for device \(deviceID): \(status)")
        }
    }

    private func removeAllSampleRateListeners() {
        for deviceID in Array(sampleRateListeners.keys) {
            removeSampleRateListener(for: deviceID)
        }
    }

    // MARK: - Physical format listeners (bit depth)

    /// Installs/removes kAudioStreamPropertyPhysicalFormat listeners on output streams.
    /// Sample-rate listeners miss bit-depth-only changes (e.g. 24→32-bit at 48 kHz).
    private func syncPhysicalFormatListeners(outputDeviceIDs: Set<AudioDeviceID>) {
        var desiredStreams: [AudioObjectID: AudioDeviceID] = [:]
        for deviceID in outputDeviceIDs {
            guard deviceID.readPhysicalFormat() != nil else { continue }
            for streamID in deviceID.readOutputStreamIDs() {
                desiredStreams[streamID] = deviceID
            }
        }

        let currentStreams = Set(physicalFormatListeners.keys)

        for streamID in currentStreams.subtracting(desiredStreams.keys) {
            removePhysicalFormatListener(for: streamID)
        }

        for (streamID, deviceID) in desiredStreams where !currentStreams.contains(streamID) {
            guard let uid = devicesByID[deviceID]?.uid else { continue }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyPhysicalFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.notifyFormatChangePending(forDeviceID: deviceID, uid: uid)
                }
            }
            let status = AudioObjectAddPropertyListenerBlock(streamID, &address, .main, block)
            if status == noErr {
                physicalFormatListeners[streamID] = block
                if lastKnownFormats[deviceID] == nil,
                   let fingerprint = OutputFormatFingerprint.from(deviceID: deviceID) {
                    lastKnownFormats[deviceID] = fingerprint
                }
            } else {
                logger.warning("Failed to add physical format listener for stream \(streamID): \(status)")
            }
        }
    }

    private func removePhysicalFormatListener(for streamID: AudioObjectID) {
        guard let block = physicalFormatListeners.removeValue(forKey: streamID) else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(streamID, &address, .main, block)
        if status != noErr && status != OSStatus(kAudioHardwareBadObjectError) {
            logger.warning("Failed to remove physical format listener for stream \(streamID): \(status)")
        }
    }

    private func removeAllPhysicalFormatListeners() {
        for streamID in Array(physicalFormatListeners.keys) {
            removePhysicalFormatListener(for: streamID)
        }
        formatChangeDebounce.values.forEach { $0.cancel() }
        formatChangeDebounce.removeAll()
        lastKnownFormats.removeAll()
    }

    /// Sorts UIDs by priority order: UIDs in the priority list come first (in priority order),
    /// followed by any remaining UIDs sorted alphabetically for determinism.
    private func sortByPriority(uids: Set<String>, priorityOrder: [String]) -> [String] {
        guard uids.count > 1 else { return Array(uids) }
        var sorted: [String] = []
        for uid in priorityOrder where uids.contains(uid) {
            sorted.append(uid)
        }
        let remaining = uids.subtracting(sorted).sorted()
        sorted.append(contentsOf: remaining)
        return sorted
    }

    /// Coalesces rapid HAL notifications into a single refresh after 50ms of quiet.
    /// Without this, querying device properties mid-burst produces HALC_ShellObject errors
    /// because HAL proxy objects haven't stabilized yet.
    private func scheduleDeviceListRefresh() {
        deviceListDebounceTask?.cancel()
        deviceListDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self else { return }
            self.handleDeviceListChanged()
        }
    }

    private func handleDeviceListChanged() {
        let previousOutputUIDs = knownDeviceUIDs
        let previousInputUIDs = knownInputDeviceUIDs

        // Capture names before refresh removes devices from list
        var outputDeviceNames: [String: String] = [:]
        for device in outputDevices {
            outputDeviceNames[device.uid] = device.name
        }
        var inputDeviceNames: [String: String] = [:]
        for device in inputDevices {
            inputDeviceNames[device.uid] = device.name
        }

        refresh()

        // Handle output device changes
        let currentOutputUIDs = knownDeviceUIDs
        let disconnectedOutputUIDs = previousOutputUIDs.subtracting(currentOutputUIDs)
        for uid in disconnectedOutputUIDs {
            let name = outputDeviceNames[uid] ?? uid
            logger.notice("Output device disconnected: \(name) (\(uid))")
            onDeviceDisconnected?(uid, name)
        }
        let connectedOutputUIDs = currentOutputUIDs.subtracting(previousOutputUIDs)
        let sortedConnectedOutput = sortByPriority(uids: connectedOutputUIDs, priorityOrder: outputPriorityOrder?() ?? [])
        for uid in sortedConnectedOutput {
            if let device = devicesByUID[uid] {
                logger.notice("Output device connected: \(device.name) (\(uid))")
                onDeviceConnected?(uid, device.name)
            }
        }

        // Handle input device changes
        let currentInputUIDs = knownInputDeviceUIDs
        let disconnectedInputUIDs = previousInputUIDs.subtracting(currentInputUIDs)
        for uid in disconnectedInputUIDs {
            let name = inputDeviceNames[uid] ?? uid
            logger.info("Input device disconnected: \(name) (\(uid))")
            onInputDeviceDisconnected?(uid, name)
        }
        let connectedInputUIDs = currentInputUIDs.subtracting(previousInputUIDs)
        let sortedConnectedInput = sortByPriority(uids: connectedInputUIDs, priorityOrder: inputPriorityOrder?() ?? [])
        for uid in sortedConnectedInput {
            if let device = inputDevicesByUID[uid] {
                logger.info("Input device connected: \(device.name) (\(uid))")
                onInputDeviceConnected?(uid, device.name)
            }
        }
    }

}
