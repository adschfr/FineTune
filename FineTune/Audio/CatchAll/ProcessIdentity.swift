// FineTune/Audio/CatchAll/ProcessIdentity.swift
import AudioToolbox
import Darwin
import Synchronization

/// Whose a Core Audio process is. Other human users' processes stay out of the catch-all
/// (#418: holding them back would silence their session). System accounts, `nobody` and
/// unknown owners are covered: system sounds and notifications must follow the TV volume.
nonisolated enum ProcessOwner: Sendable, Equatable {
    case currentUser
    case otherHuman
    case system
    case unknown

    /// First regular user ID on macOS, and the start of the reserved high range.
    private static let firstHumanUID: uid_t = 501
    private static let reservedUIDs: uid_t = 0x8000_0000

    static func classify(uid: uid_t?, currentUID: uid_t) -> ProcessOwner {
        guard let uid else { return .unknown }
        if uid == currentUID { return .currentUser }
        if uid >= firstHumanUID && uid < reservedUIDs { return .otherHuman }
        return .system
    }
}

/// Core Audio and kernel lookups for process objects. Never called on the IO thread.
nonisolated enum ProcessIdentity {

    /// The process object of `pid`, or `kAudioObjectUnknown` if it has none.
    static func processObject(forPID pid: pid_t) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object
        )
        return err == noErr ? object : AudioObjectID(kAudioObjectUnknown)
    }

    /// The real user ID a process runs as, or nil if the kernel does not know the PID.
    static func ownerUID(pid: pid_t) -> uid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ucred.cr_uid
    }

    /// True while the process runs IO with at least one active output stream.
    static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        (try? object.readBool(kAudioProcessPropertyIsRunningOutput)) ?? false
    }
}

/// Caches who owns each process object, so pushes and run decisions do not repeat kernel
/// lookups. Reset after a Core Audio service restart, when object IDs may be reused.
nonisolated final class ProcessCatalog: Sendable {
    struct Entry: Sendable, Equatable {
        var pid: pid_t
        var owner: ProcessOwner
    }

    private let readPID: @Sendable (AudioObjectID) -> pid_t?
    private let readOwnerUID: @Sendable (pid_t) -> uid_t?
    private let currentUID: uid_t
    private let entries = Mutex<[AudioObjectID: Entry]>([:])

    init(
        readPID: @escaping @Sendable (AudioObjectID) -> pid_t? = { try? $0.readProcessPID() },
        readOwnerUID: @escaping @Sendable (pid_t) -> uid_t? = { ProcessIdentity.ownerUID(pid: $0) },
        currentUID: uid_t = getuid()
    ) {
        self.readPID = readPID
        self.readOwnerUID = readOwnerUID
        self.currentUID = currentUID
    }

    /// The entry for `object`, read and cached on first use. nil if the object has no PID.
    func entry(for object: AudioObjectID) -> Entry? {
        if let cached = entries.withLock({ $0[object] }) { return cached }
        guard let pid = readPID(object) else { return nil }
        let entry = Entry(pid: pid, owner: ProcessOwner.classify(uid: readOwnerUID(pid), currentUID: currentUID))
        entries.withLock { $0[object] = entry }
        return entry
    }

    /// The processes among `objects` that belong to other human users.
    func foreign(among objects: some Sequence<AudioObjectID>) -> Set<AudioObjectID> {
        Set(objects.filter { entry(for: $0)?.owner == .otherHuman })
    }

    /// Drops entries for objects that no longer exist.
    func prune(keeping live: Set<AudioObjectID>) {
        entries.withLock { $0 = $0.filter { live.contains($0.key) } }
    }

    func reset() {
        entries.withLock { $0.removeAll() }
    }
}
