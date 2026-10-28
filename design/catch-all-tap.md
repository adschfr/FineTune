<!-- Design review output (2026-10-28): API facts, three designs, two judges, synthesis.
Correction after review: only the test target sets SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
the app target is nonisolated by default, so main-actor types in FineTune/ are annotated explicitly. -->

# Catch-all tap for outputs without hardware volume: implementation design

This design is ready to implement on branch `improve/phase-2-tv-path`. It starts from Design 3 (the risk-first design built around a decorator). It adds the judges' grafts and fixes every fatal flaw named in the reviews. Nothing described here has been built or run yet. All line numbers refer to the working tree at commit `828db61`.

---

## 1. Overview

### What it does

FineTune creates one catch-all tap (CA) for every output whose volume tier is `.software`. In the user's setup that is the LG TV, connected over USB-C to HDMI. The CA is configured as follows:

- It is a private, `CATapMuted`, exclusive device-stream tap, built with `CATapDescription(excludingProcesses:deviceUID:stream:)` on the device's first output stream.
- Its exclusion list contains FineTune's own process object, the process objects of other human users (#418), and every process that a live per-app tap already holds on that device.
- Everything else that plays to the TV is held back from its first sample. That covers system sounds, notifications, dictation sounds, new apps before their per-app tap exists, new helper processes, ignored apps, call-passthrough apps and apps whose per-app tap failed. This audio plays through a private aggregate at the TV's software gain, followed by the existing `SoftLimiter`.

Per-app taps stay exactly as they are. Every per-app controller that the engine's `tapFactory` returns is wrapped in a decorator, `CatchAllAwareTap`. The decorator turns each create, remove, source switch, format rebuild and process-set change into an ordered exclusion update:

- A process is excluded from the CA only while a per-app tap already holds it.
- A per-app tap is destroyed only after the CA captures its processes again.
- While both taps capture a process, the per-app output is held (zeroed through the existing `isMuted` path).

The CA's IO is started and stopped on a dedicated serial queue, which does not depend on the main thread:

- Listeners on each process's `kAudioProcessPropertyIsRunningOutput` and `kAudioProcessPropertyDevices` (output scope) drive the start.
- The IO stops 10 s after the last covered output to the device ends.
- While the IO is stopped, `CATapMuted` keeps covered audio held back. A slow resume therefore loses the start of a sound but never plays it at full scale.

### R1 exceptions, stated explicitly

1. FineTune itself. Its volume feedback pop scales itself (`VolumeFeedbackPlayer.swift:13-22, 83-86`).
2. Other human users' processes (#418).
3. The window between a software device becoming alive and its CA build finishing. That is about 100 ms, and at most the 2 s `waitUntilReady` timeout.
4. Any time FineTune is not running: quit, crash, `kill -9`, or before launch at login.
5. Fail-open states: a CA retired after repeated failures, the circuit breaker, or `CatchAllMode=off`.
6. Per-app taps that fan out to several devices including the TV. They get the app gain but no TV gain. This is an existing gap (`AudioEngine.swift:843-848`).
7. Ineligible devices: more than one output stream, aggregate or virtual devices.

### Decisions taken from the reviews

| Review finding | Resolution in this design |
|---|---|
| D3 fatal: claims came from `tapSourceDeviceUID`, which can run ahead of the live tap (`ProcessTapController.swift:779, 789, 812-814, 836, 851-853`) | Claims are derived from the live tap descriptions through a new read-only `liveCapture` requirement. Before any call that may rebuild a tap, the claim shrinks to `old ∩ requested`. The final claim is set from `liveCapture` only when no transition is in flight (§4.5, §5). |
| D1 fatal: reusing `updateProcesses` hides failed pushes because of the early return at `ProcessTapController.swift:920-921` | The CA has its own push with read-back (§4.6). `updateProcesses` additionally reverts `description.processes` on failure, so `liveCapture` stays truthful (§3.2). |
| D1 fatal: a device-filtered resume can keep a process silent indefinitely | The device filter is conservative (unknown, empty or non-plain devices count as feeding the device). It is never applied while the tap input is audible. A safety probe disables the filter for the session if it ever misses audio (§6.6). |
| D2 fatal: holds during every coverage-changing switch | Rule P5 keeps per-app sources coverage-neutral for the CA device. A hold is taken only if the app may play to an affected CA device (§4.7, §5). |
| D2 fatal: device-agnostic wake | Wake and suspend are device-aware, with the probe as backstop (§6). |
| D3: builds on the run queue put `waitAlive` in front of resumes | Builds stay on main and reuse `waitUntilReady` unchanged (it is main-actor isolated, `AudioObjectID+Readiness.swift:7, 31-43`). The run queue only starts and stops IO (§3.3). |
| Grafts | P5 plus refreshing stream taps after a build (H5); a generous shrink wait; teardown on session resign; hold on helper growth only when the helper already runs output; stop-then-recheck; an `IOStoppedAbnormally` listener; `Synchronization.Atomic` for cross-thread fields; a no-op coordinator by default; a test that every protocol requirement is forwarded; an optional quiet-point handover. |

### Invariants (checked in tests and at runtime)

- **I1 (R1).** Every process in the applied exclusion list of CA(D) is one of three things: FineTune itself, another human user's process, or a process held muted on D by a live per-app tap whose registered claim includes it with coverage of D.
- **I2 (R2).** If a process is captured on D by CA(D) and by a per-app tap T, then T's output is held.
- **I3.** No hold outlasts its deadline (§10).
- **I4.** After quiescence, the applied exclusions equal the computed exclusions.

---

## 2. API facts relied on

Certainty levels: **H** = stated in the headers, **C** = confirmed by FineTune code or an incident, **I** = inferred, **U** = unknown. The harness steps (§12.3) verify everything that is not H.

| # | Fact | Cert. | Source | Runtime check |
|---|---|---|---|---|
| F1 | `initExcludingProcesses:andDeviceUID:withStream:` mixes "all process audio streams destined for the selected device stream except the given processes". The tap format matches that stream. Swift: `init(excludingProcesses:deviceUID:stream:)`, macOS 14.0. | H | `CATapDescription.h:99-111`; `CoreAudio.swiftmodule/arm64e-apple-macos.swiftinterface:460` | H0 |
| F2 | `exclusive == true` means `processes` is the exclusion list. The header does not say the initializer sets it. | H/I | `CATapDescription.h:125-129, 144-148` | Set explicitly; unit test; H0 read-back |
| F3 | `CATapMuted`: "captured by the tap but no audio is sent from the process to the audio hardware". A device-stream tap holds back audio only on that device stream. | H/C | `CATapDescription.h:19-34`; commit `828db61` message | H1m |
| F4 | A process that starts after the exclusive tap exists is captured and muted from its first sample. | I | `CATapDescription.h:103-104` ("All other processes that output audio will be included") | **H1, H1m (gate)** |
| F5 | `kAudioTapPropertyDescription` can be set on a live tap. Latency and atomicity of the change are not documented. | H/U | `AudioHardware.h:2010-2012`; overlay `AudioHardwareTap.setDescription` `swiftinterface:684` | **H2 (gate)** |
| F6 | FineTune's process object comes from `kAudioHardwarePropertyTranslatePIDToProcessObject` with a `pid_t` qualifier, which returns `kAudioObjectUnknown` instead of an error. FineTune's aggregate IO is attributed to that object. | H/I | `AudioHardware.h:589-595, 634`; overlay `swiftinterface:82` | **H3 (gate)** |
| F7 | A process in two `.muted` taps is captured by both and stays muted while any of them exists. Destroying such a tap unmutes the process. | C | Crossfade overlap `ProcessTapController.swift:1025-1110`; commit `086e896` | H12 |
| F8 | `IsRunningOutput` is 1 while the process runs IO with an active output stream. `Devices` (output scope) lists its output devices. Both are expected to hold for muted processes. | H/I | `AudioHardware.h:1953-1955, 1966-1969` | **H8** (gates the device filter) |
| F9 | Listener blocks run on the queue that is passed in. | H | `AudioObjectAddPropertyListenerBlock` usage, `AudioProcessMonitor.swift:382` | - |
| F10 | `AudioDeviceStart` on a stopped private aggregate takes about 25 ms. | C | `HANDOFF.md:40` | H7 |
| F11 | `tapautostart` makes `AudioDeviceStart` "wait until a tapped process begins receiving its first audio". Whether it blocks or re-arms is unknown. v1 does not set it. | H/U | `AudioHardware.h:1630-1640` | H4 |
| F12 | The tap UID can differ from `description.uuid`, as upstream research observed. | U | `AudioHardware.h:2006-2009`; overlay `AudioHardwareTap.uid` `swiftinterface:675-677` | H0 |
| F13 | Private taps and aggregates are private to their creator and not persistent. Expected to be torn down when the process dies. | I | `AudioHardware.h:1600-1609`; `CATapDescription.h:156-160` | H9 |
| F14 | `kAudioHardwarePropertyServiceRestarted`: all client state must be re-established. | H | `AudioHardware.h:573-577` | H10 (optional) |
| F15 | `kAudioDevicePropertyIOStoppedAbnormally` reports IO that stopped outside the normal paths. | H | `AudioHardware.h:926-930` | - |
| F16 | `kAudioDevicePropertyDeviceIsRunningSomewhere` is unusable as a trigger, because FineTune's per-app aggregates keep the TV running. | H/C | `AudioHardware.h:918-920`; `ProcessTapController.swift:391-427` | - |
| F17 | No documented limit on taps or aggregates per process. | U | `AudioHardwareTapping.h`; CrashGuard tracks 64 aggregates, `CrashGuard.swift:13` | H6 |
| F18 | The feedback `NSSound` plays inside FineTune's process. | I | `VolumeFeedbackPlayer.swift:83-86` | H11 |
| F19 | `Synchronization.Atomic` is available from macOS 15.0 (the deployment target is 15.4). | H | `Synchronization.swiftmodule/arm64e-apple-macos.swiftinterface:8-9` | - |

---

## 3. Components and files

The project uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (`project.pbxproj:533, 555`). Every type below that runs off main must be declared `nonisolated`, and its HAL listener blocks must be `@Sendable` closures created inside a nonisolated context. The app target uses synchronized folders (`project.pbxproj:54-73`), so new files need no project edits.

### 3.1 New files in `FineTune/Audio/CatchAll/`

| File | Type and isolation | Responsibility |
|---|---|---|
| `CaptureCoverage.swift` | `nonisolated enum TapCoverage { case none, allDevices, device(String) }`; `nonisolated struct TapCapture { processes: Set<AudioObjectID>; coverage: TapCoverage }`; `nonisolated struct Claim { processes; coverage }` (all `Sendable, Hashable`) | Coverage algebra. `covers(uid)`, `intersect`, `Claim.fromLive([TapCapture])` (intersection across live resources; empty input gives the empty claim), `Claim.empty`. |
| `CatchAllPlan.swift` | `nonisolated enum CatchAllPlan` (pure) | `exclusions(deviceUID:selfObject:foreign:claims:live:)`, `changedDevices(before:after:catchAllUIDs:)`, `needsHold(changed:appOutputUIDs:isPlain:)`, `allowsStreamTap(candidate:catchAllDevices:)` (P5), `eligibility(_:) -> Eligibility` with a reason for every rejection. |
| `ProcessIdentity.swift` | `nonisolated enum ProcessIdentity`; `nonisolated final class ProcessCatalog: Sendable` (cache in a `Mutex`, never on the RT path) | `processObject(forPID:)` via TranslatePID with a `pid_t` qualifier; `ownerUID(pid:)` via `sysctl` (same call as `AudioProcessMonitor.swift:176-182`, returning the uid); `classify(uid:currentUID:) -> .current/.otherHuman/.system/.unknown`; `readIsRunningOutput(_:)`. The catalog maps object ID to (pid, owner) and is reset after a service restart. |
| `CatchAllTapDescription.swift` | `nonisolated enum` | The only construction site of the catch-all `CATapDescription` (§4.1) and the aggregate dictionary (§4.2). |
| `CatchAllRender.swift` | `nonisolated final class CatchAllRenderState: @unchecked Sendable`; `nonisolated let catchAllIOProc: AudioDeviceIOProc`; `nonisolated enum CatchAllRender` | The RT path (§11). |
| `CatchAllBackend.swift` | `nonisolated protocol CatchAllBackend: Sendable`; `CoreAudioCatchAllBackend` | `createTap`, `readTapUID`, `readTapDescription`, `setTapDescription`, `createAggregate`, `createIOProc`, `disableHardwareInputs`, `nominalRate`, `start`, `stop`, `destroy(TapResources)`. Tests use `FakeCatchAllBackend`. |
| `CatchAllTapController.swift` | `@MainActor final class` (one per device), behind `@MainActor protocol CatchAllTapControlling` | Build (§4.3), `push(_:) -> PushResult` with read-back, `hold()`/`release()`, `setGain(_:)`, `callbackCount`, `ioHandle`, `destroy() async`, `forget()` (after a service restart). Keeps a `TapResources` for the teardown order (`TapResources.swift:8-14`). |
| `CatchAllRunLogic.swift` | `nonisolated struct` (pure state machine) | `mutating func handle(_ event:, now:) -> [Effect]` (§6). |
| `CatchAllRunControl.swift` | `nonisolated final class CatchAllRunControl: @unchecked Sendable` (state confined to its queue); `nonisolated protocol ProcessOutputActivitySource`; `HALProcessOutputActivitySource` | Owns queue `com.adschfr.FineTuneFork.catchall` (QoS `.userInteractive`), the HAL listeners, `AudioDeviceStart`/`AudioDeviceStop` of attached handles, timers and liveness checks. Posts events to main. |
| `CatchAllSettings.swift` | `nonisolated struct CatchAllSettings` over an injected `UserDefaults` | `mode` (`off`/`observe`/`on`), `excludedDeviceUIDs`, `harnessSteps`, tuning overrides (margins). |
| `CatchAllCoordinator.swift` | `@MainActor protocol CatchAllCoordinating`; `NoopCatchAllCoordinator`; `CatchAllCoordinator` | Eligibility and reconcile, controller ownership, claim registry, push scheduling with tickets, gain, invariant checker, backoff and circuit breaker, session and wake observers, watchdogs. |
| `CatchAllAwareTap.swift` | `@MainActor final class CatchAllAwareTap: ProcessTapControlling` | The decorator: handovers A to D (§5). It forwards every requirement. |
| `CatchAllHarness.swift` | `@MainActor final class` | The manual harness (§12.3). Runs only when `CatchAllHarness` is set and the engine started its monitors. |

Coordinator protocol (the shape the decorator and engine rely on):

```swift
@MainActor protocol CatchAllCoordinating: AnyObject {
    var isEnabled: Bool { get }                 // false only for Noop: engine does not wrap taps
    var affectsAudio: Bool { get }              // mode == .on and at least one live CA
    var catchAllDeviceUIDs: Set<String> { get } // live CAs, input for P5
    var onCatchAllDevicesChanged: (() -> Void)? { get set }
    func start(); func stop(); func reconcile(); func refreshGains()
    func deviceGainChanged(_ deviceID: AudioDeviceID)
    func formatChanging(uid: String); func formatUnchanged(uid: String); func formatChanged(uid: String) async
    // handover API, used by CatchAllAwareTap only
    func changedDevices(owner: ObjectIdentifier, proposed: Claim) -> Set<String>
    func mayPlay(_ app: AudioApp, on uids: Set<String>) -> Bool
    func setClaim(_ owner: CatchAllAwareTap, _ claim: Claim) -> ApplyTicket?   // nil: no list changed
    func removeClaim(_ owner: ObjectIdentifier) -> ApplyTicket?
    func prepareInclusion(of processes: [AudioObjectID], on uids: Set<String>)
    func waitApplied(_ ticket: ApplyTicket, _ direction: ApplyDirection) async  // .grow or .shrink
    func isLive(_ process: AudioObjectID) -> Bool
    func isRunningOutput(_ process: AudioObjectID) -> Bool
}
```

### 3.2 Changed files

| File | Change |
|---|---|
| `ProcessTapControlling.swift` | Add requirement `var liveCapture: [TapCapture] { get }` to the protocol (lines 9-45). In the extension (47-87), add the default `[]`. An empty capture claims nothing and so excludes nothing, which is the safe default. |
| `ProcessTapController.swift` | (a) `liveCapture`: the `TapCapture` of `primaryResources` and `secondaryResources` whose `tapID.isValid`, via `nonisolated static func capture(of: CATapDescription?) -> TapCapture?` (processes from `description.processes`; coverage `.device(uid)` when `description.deviceUID` is set, otherwise `.allDevices`, per `CATapDescription.h:175-179`). (b) In `updateProcesses` (919-947): store `let previous = description.processes` before line 928 and restore it in the `err != noErr` branch (938-941). This code exists only in the fork (`9c11bdf`). About 18 lines in total; the callback is not touched. |
| `AudioEngine.swift` | About 16 hook lines (§8.2 table) plus one new method `refreshTapSourcesForCatchAll()` and the P5 guard. `ignoreApp`, `releaseCallPassthroughTaps`, `cleanupStaleTaps`, `recreateTap`, `syncTapsWithProcessState` and all switch call sites stay unchanged. The decorator sees their calls. |
| `DeviceVolumeProviding.swift` | Add requirement `var onOutputTierChanged: ((AudioDeviceID) -> Void)? { get set }`, with an extension default (`get { nil } set {}`) so the existing mocks keep compiling. |
| `DeviceVolumeMonitor.swift` | Add a stored `onOutputTierChanged`, fired at the end of `applyTierOverrideChange` after `readOneState` (line 1055). Today a tier override notifies nobody (`MenuBarPopupView.swift:746-747`). |
| `FineTuneTests/FakeTapController.swift` | Add `liveCapture`: if activated and not invalidated, `[TapCapture(Set(app.processObjectIDs), tapSourceDeviceUID.map(.device) ?? .allDevices)]`, else `[]`; plus `liveCaptureOverride`. Hold and release already appear in the log as `mute true/false` (`FakeTapController.swift:17-19`). |
| `OrphanedTapCleanup.swift` | Docs commit only: the comment at 7-9 still names `.mutedWhenTapped`. |

### 3.3 Threads and ownership

```
AudioEngine (main) ── owns ──> CatchAllCoordinator (main)
                                 ├─ [deviceUID: CatchAllTapController] (main: build, push, hold, gain, destroy)
                                 ├─ claim registry [ObjectIdentifier: (weak owner, Claim)]
                                 └─ CatchAllRunControl (queue com.adschfr.FineTuneFork.catchall)
                                      ├─ HAL listeners: process list, ServiceRestarted, per process IsRunningOutput + Devices(out),
                                      │  per attached aggregate IOStoppedAbnormally
                                      └─ AudioDeviceStart / AudioDeviceStop of attached CatchAllIOHandle
HAL IO thread ── touches only ──> CatchAllRenderState
```

- **Main** builds, pushes exclusions (the same kind of call `updateProcesses` makes on main today), writes gain and hold atomics, and destroys.
- **The run queue** exclusively starts and stops an attached handle. Main never calls `AudioDeviceStart` or `AudioDeviceStop` on a CA.
- **Detach is a barrier.** `await runControl.detach(uid)` resumes only after the queue has dropped the handle. After that, main destroys it through `TapResources.destroyAsync`, which stops, destroys the IOProc, the aggregate and then the tap (`TapResources.swift:81-126`). `stop()` uses `detachSync` (`queue.sync`), which is safe because the queue never waits on main.
- **The queue posts to main** with `Task { @MainActor in … }`: rebuild requests, process-list changes, service restart, metrics for logging.

### 3.4 Modes and settings

`CatchAllMode` is stored in UserDefaults in the fork's own domain (`com.adschfr.FineTuneFork`). It is not in the `settings.json` shared with upstream, which upstream would re-encode and strip.

| Mode | Behavior |
|---|---|
| `off` (default until the last commit) | `NoopCatchAllCoordinator`, no decorator. Code paths are identical to today. |
| `observe` | CAs are built `.unmuted` and their output is permanently zero. Claims and pushes run, the run control starts and stops IO, and metrics are logged. Nothing becomes audible or silent. The decorator never holds. |
| `on` | Full feature. |

The mode is read at launch. The kill switch is `defaults write com.adschfr.FineTuneFork CatchAllMode -string off` followed by a relaunch. It works even in a crash loop because the coordinator is never constructed. `CatchAllExcludedDeviceUIDs` (array) opts single devices out.

---

## 4. Tap description and exclusion list

### 4.1 Factory

```swift
nonisolated enum CatchAllTapDescription {
    static func make(excluding: [AudioObjectID], deviceUID: String, stream: UInt, observe: Bool) -> CATapDescription {
        let d = CATapDescription(excludingProcesses: excluding, deviceUID: deviceUID, stream: stream) // CATapDescription.h:99-111
        d.uuid = UUID()
        d.name = "FineTune Catch-All"
        d.isPrivate = true                               // CATapDescription.h:156-160
        d.isExclusive = true                             // implied by the initializer, set explicitly (144-148)
        d.muteBehavior = observe ? .unmuted : .muted     // CATapDescription.h:19-34
        return d
    }
}
```

- **Never** use `initStereo/MonoGlobalTapButExcludeProcesses` (`CATapDescription.h:58-66, 76-83`). With `.muted` they would hold back every non-excluded process on every device, AirPods and built-in speakers included, and one mixed stream cannot be routed back to each process's own device.
- **Never** set `bundleIDs` or `processRestoreEnabled` (macOS 26, `CATapDescription.h:131-136, 162-167`). Excluding by bundle ID would exclude a relaunch or a new helper before a per-app tap holds it.
- `stream` comes from `deviceID.firstOutputStreamIndex()`, the global stream index that this initializer expects (`AudioDeviceID+Streams.swift:69-87`). It is re-read on every build.
- No `#available` check is needed: the initializer is macOS 14.0 and `AudioHardwareCreateProcessTap` is macOS 14.2.

### 4.2 Aggregate dictionary

| Key | Value |
|---|---|
| `kAudioAggregateDeviceNameKey` | `"FineTune-CatchAll-<8 hex of UID hash>"`. The prefix hides it from FineTune's own picker (`AudioDeviceMonitor.swift:179`). |
| `kAudioAggregateDeviceUIDKey` | `UUID().uuidString` |
| main and clock sub-device | `deviceUID` |
| `kAudioAggregateDeviceIsPrivateKey` | `true` (`AudioHardware.h:1600-1609`) |
| `kAudioAggregateDeviceIsStackedKey` | `ProcessTapController.planAggregate(outputUIDs: [uid], …).isStacked` (`ProcessTapController.swift:337-368`), which is `true` for a plain device, the same as per-app TV taps today |
| `kAudioAggregateDeviceTapAutoStartKey` | `false` in v1, so `AudioDeviceStart` can never block the run queue. Harness H4 decides strategy B (§6.8). |
| sub-device list | `[[kAudioSubDeviceUIDKey: uid, kAudioSubDeviceDriftCompensationKey: false]]` |
| tap list | `[[kAudioSubTapUIDKey: readBackTapUID, kAudioSubTapDriftCompensationKey: !isVirtual && !isBluetooth]]`, the rule per-app TV taps use today (`ProcessTapController.swift:402-408`) |

### 4.3 Build sequence (`CatchAllTapController.build`, main)

1. Require that `selfObject` is resolved and that `streamCount(output) == 1` (eligibility, §8.1).
2. `stream = try deviceID.firstOutputStreamIndex()`. Build the description (§4.1) with the exclusions from §4.4.
3. `AudioHardwareCreateProcessTap`. The process set is muted from this moment.
4. Read back `AudioHardwareTap(id:).uid` (`swiftinterface:675-677`). Fall back to `description.uuid` and log `.notice` if they differ.
5. Read back `AudioHardwareTap(id:).description` (678-680). Require `isExclusive` and `Set(processes) == Set(exclusions)`. Otherwise destroy and throw `.descriptionMismatch`.
6. Create the aggregate, call `CrashGuard.trackDevice` (`CrashGuard.swift:66`), then `waitUntilReady(timeout: 2.0)` (`AudioObjectID+Readiness.swift:31-43`, main-actor isolated).
7. Read the aggregate's nominal rate. Create `CatchAllRenderState`: ramp coefficient `1 - exp(-1/(rate*0.030))` (the per-app formula, `ProcessTapController.swift:698-699`), gate ramp of 10 ms, target gain seeded, `seedGain = true`, `held` as requested.
8. `AudioDeviceCreateIOProcID(aggID, catchAllIOProc, Unmanaged.passUnretained(state).toOpaque(), &procID)`.
9. Disable the hardware input streams, reusing `ProcessTapController.inputStreamUsageFlags` (486-493). The 25-line property write from `disableHardwareInputStreams` (501-537) is duplicated in the backend rather than refactored, to keep the upstream diff small.
10. **Do not start.** Return a `CatchAllIOHandle(uid, deviceID, aggregateID, procID, state)` that the coordinator attaches to the run control.

Any failure tears the partial resources down in `TapResources` order and throws.

### 4.4 Exclusion list E(D)

```
E(D) = sortedUnique( {self}
                    ∪ (foreign ∩ live)
                    ∪ ( ⋃ { c.processes | c ∈ claims of live owners, c.coverage.covers(D) } ∩ live ) )
```

- `self` is `ProcessIdentity.processObject(forPID: getpid())` (`AudioHardware.h:589-595`). If it is `kAudioObjectUnknown`, no CA is built. Without the self exclusion, the CA would capture FineTune's per-app output (double gain) and its own output (a loop).
- `foreign` contains processes whose owner uid is in `501..<0x8000_0000` and differs from `getuid()`. `nobody` (4294967294), system accounts below 501 and unknown owners stay included. So `systemsoundserverd`, notification, dictation and Siri sounds are captured. These are the daemons that `AudioProcessMonitor` hides (`AudioProcessMonitor.swift:31-66, 286`), which fixes incident 2.
- `live` is a fresh `AudioObjectID.readProcessList()` (`AudioObjectID+System.swift:15-20`) at push time. A dead ID is never pushed, and a recycled ID cannot inherit an exclusion.

### 4.5 Claims from live capture

- One claim exists per decorator, keyed by `ObjectIdentifier`. The registry holds the owner weakly, and a claim whose owner has disappeared is dropped (with a `.fault` log, because it means a decorator was deallocated without `invalidate`).
- **Subset rule.** A stored claim is always a subset of what the tap currently holds muted:
  - At rest (no transition in flight), `claim = Claim.fromLive(inner.liveCapture)`, the intersection across live resources.
  - Before any inner call that may rebuild a tap (`switchDevice`, `updateDevices`, `refreshTapSource`, `recreateForOutputRateChange`), `claim = claim ∩ Claim(claim.processes, coverage(requested))`.
  - "Requested" is the argument source, or `inner.tapSourceDeviceUID` for `recreateForOutputRateChange`, because that call rebuilds with whatever `updateDevices` stored earlier (`ProcessTapController.swift:779, 1332`).
  - A requested stream source can fall back to mixdown (`ProcessTapController.swift:620-638`). That only widens the actual capture, so `old ∩ requested` stays a subset of both the old and the new capture.
- **Coverage algebra.** `all ∩ all = all`; `all ∩ device(x) = device(x)`; `device(x) ∩ device(y)` is `device(x)` if `x == y`, otherwise `none`.

### 4.6 Push and the definition of "applied"

- **Coalescing.** `setClaim` and `removeClaim` mark the plan dirty and return an `ApplyTicket(generation, devices)`. A single `Task { @MainActor }` per main-actor turn runs `flush()`.
- **flush()**, per CA whose desired list differs from its applied list:
  1. `description.processes = list`, then `try AudioHardwareTap(id:).setDescription(description)` (`swiftinterface:684`). This is equivalent to the raw call at `ProcessTapController.swift:928-937`.
  2. Read back and compare the processes and `isExclusive`.
  3. Record the host time at which the push returned and the CA's `callbackCount`.
  4. `runControl.setExcluded(uid, Set(list))`.
- **Applied** means all of the following:
  - the set returned `noErr`;
  - the read-back matches;
  - the direction's margin has elapsed;
  - if the CA's IO is running, its `callbackCount` advanced by at least 2 after the set returned, or 500 ms passed (then the push is logged as stalled and liveness takes over).
- **Margins.** Grow (excluding, where the gap is audible): 50 ms until harness H2 has run, then `max(2 × p99(L), 2 IO buffers)`. Shrink (un-excluding, where the per-app tap still mutes the process so a longer wait costs nothing audible): 400 ms, then `max(400 ms, 4 × p99(L))`. Both can be overridden through UserDefaults.
- **Failure.** If the set fails or the read-back does not match:
  1. Retry once with a fresh `live` list.
  2. Then do a make-before-break rebuild with the desired list (§5 E). Its tickets complete when the new CA is attached.
  3. If the rebuild fails, retire the CA (§5 G, fail open) and count one circuit-breaker failure.
  4. Waiters always complete; callers have no failure branch.
- **Invariant checker** (after every flush and every process-list change):
  - `applied(D) − {self} − foreign ⊆ ⋃ claims covering D` (I1);
  - for every decorator with no transition in flight, `claim ⊆ Claim.fromLive(inner.liveCapture)`.
  - A violation is logged at `.fault` and repaired at once by pushing without the offending IDs. Removing an exclusion can cause doubling but never unprocessed audio.

### 4.7 Rule P5 (keep per-app capture neutral for CA devices)

In `preferredTapSourceDeviceUID` (`AudioEngine.swift:2074-2078`, code added in the fork by `828db61`), add after line 2076:

```swift
guard CatchAllPlan.allowsStreamTap(candidate: defaultUID, catchAllDevices: catchAll.catchAllDeviceUIDs) else { return nil }
```

A stream source is allowed only when the set of CA devices is empty or equals `{defaultUID}`. Every per-app capture is then either the process-wide mixdown or a stream on the single CA device, and both cover that device. With the TV as the CA device:

- default TV gives `stream(TV)` (when the app plays there);
- default AirPods gives the mixdown.

TV↔AirPods default switches therefore never change a per-app claim on the TV, and need no hold and no wait.

The trade-off is that follows-default apps on a multichannel non-TV default lose stream capture while a TV CA exists.

---

## 5. Handover protocols

Notation: T is the per-app tap (decorator plus inner), P its processes, D a CA device. **Hold** means `holdCount += 1; inner.isMuted = true`. **Release** means `holdCount -= 1; if holdCount == 0 { inner.isMuted = userMuted }`. The decorator's `isMuted` getter and setter use `userMuted`, so `setMute` (`AudioEngine.swift:929-932`), `applyTapOutputState` (880), the health check (2253) and `recreateTap` (2348, 2363) behave as today. A hold zeroes both roles (`ProcessTapController.swift:1736-1741`). The secondary still advances crossfade progress first (1716). The unmute edge re-arms the 40 ms gate (1676-1680). Holds are taken only when `coordinator.affectsAudio`; in observe mode they never happen.

`mayPlay(app, D)` uses the engine's `processOutputDeviceUIDs` (`AudioEngine.swift:261-265`, injectable). It returns true if the set is empty, contains D, or contains a device that is not plain (aggregate, virtual or unknown).

### A. Per-app tap created (CA → per-app, grow)

Entry: `ensureTapExists` (`AudioEngine.swift:1449`), `ensureTapWithDevices` (1279), the replacement in `recreateTap` (2353-2358). All of these call `tap.activate(initial:)` on the decorator.

1. `proposed = Claim(Set(app.processObjectIDs), coverage(requestedSource))`, where the requested source is the `preferredSource` argument the factory received. `changed = coordinator.changedDevices(owner, proposed)`.
2. If `!changed.isEmpty && mayPlay(app, changed)`: hold **before** activate. `activate` seeds `_outputGateWasMuted` from `_isMuted` (`ProcessTapController.swift:753`), so the release is an unmute edge.
3. `try inner.activate(initial:)`. On a throw, release the hold and rethrow. Nothing is registered and P stays in the CA at TV gain; today it would play unprocessed.
4. `claim = Claim.fromLive(inner.liveCapture)`, the actual capture including a mixdown fallback. `ticket = setClaim(self, claim)`. The engine registers the tap in the same turn (1450).
5. *(Optional quiet point, commit 13.)* Before step 4's `setClaim`, wait in a Task until `inner.audioLevel < 0.001` for 100 ms, at most 1.5 s. The peak is computed while held (1709-1712), so a short sound finishes in the CA without a dip.
6. In a Task: `await waitApplied(ticket, .grow)`; if the decorator is not retired, release.

Why this order:

- Excluding P before T exists would leave P in no tap (full scale on the TV).
- Releasing T before the exclusion has applied would play P twice.

The gap lasts from the HAL applying the exclusion until the release, about the grow margin minus L, plus the 40 ms fade-in. For a recreate (old claim identical) `changed` is empty: no hold, no wait.

Incident 1 (the MacWhisper start sound 81 ms before its tap) now plays through the CA at TV volume from its first sample. If the per-app tap arrives while the sound is still playing, there is one dip of about the grow margin, or none with the quiet point.

### B. Per-app tap removed (per-app → CA, shrink)

Entry: `invalidate()` or `invalidateAsync()` via `ignoreApp` (`AudioEngine.swift:571`), `releaseCallPassthroughTaps` (618), stale cleanup (2132), the old tap in `recreateTap` (2341, 2376), and `stop()` (753).

1. `retired = true`. From then on, in-flight transitions never store claims or release.
2. `ticket = coordinator.removeClaim(self)`. If nil (no CA, another claim still covers P on every D, or all of P's IDs are dead): invalidate the inner tap now, which is today's behavior.
3. Otherwise, in the same main-actor turn and before the flush:
   - hold (T keeps P muted and captured, outputs zero);
   - `prepareInclusion(P, on: changed)`. The run queue starts any stopped CA(D) for which a process in P runs output that feeds D, treating P as covered.
4. In a Task (which keeps the decorator alive): `await waitApplied(ticket, .shrink)`, then `await inner.invalidateAsync()`. `invalidate()` returns at once; `invalidateAsync()` awaits the whole sequence, so `recreateTap` still awaits teardown (2341, 2376).

Why this order:

- Destroying T first unmutes P while no tap captures it.
- Un-excluding P while T's output is open plays P twice.

The gap lasts from the hold until the CA's inclusion applies, about L, overlapping the ~25 ms CA start. The 400 ms margin is not audible.

### C. Source switch or rebuild on a live per-app tap

Entry: `switchDevice`, `updateDevices`, `refreshTapSource`, `recreateForOutputRateChange` (call sites `AudioEngine.swift:1119, 1153, 1247, 1400, 1552, 1634, 1648, 1716, 2427`).

1. `requested = coverage(source)` (§4.5). `inFlight += 1`.
2. `transitional = claim ∩ Claim(claim.processes, requested)`. `changed` is the set of CA devices whose lists change through the shrink now or through the expected grow afterwards.
3. If `!changed.isEmpty && mayPlay(app, changed)`: hold.
4. If `transitional != claim`:
   - `claim = transitional`;
   - `ticket = setClaim`;
   - `prepareInclusion`;
   - `await waitApplied(ticket, .shrink)`.
5. `try await inner.<call>`. The error is rethrown after step 6.
6. `inFlight -= 1`. If `inFlight == 0 && !retired`:
   - `claim = Claim.fromLive(inner.liveCapture)`;
   - `ticket = setClaim`;
   - if held, `await waitApplied(ticket, .grow)`.
7. If held: release.

Concurrent switches on one tap are possible, for example `routeFollowsDefaultApps` (1552) and `handleDeviceDisconnected` (1634). Each one shrinks, and the last to finish sets the final claim from live capture. A call that `ProcessTapController` cancels returns normally (812-814, 851-853) without changing the final state. Under P5, steps 3 and 4 almost never fire.

### D. Process-set change

Entry: `updateProcesses(for:)` from `syncTapsWithProcessState` (`AudioEngine.swift:2164-2166`).

1. `added = new − old`, `removed = old − new`, `liveRemoved = removed.filter(coordinator.isLive)`.
2. If `affectsAudio && !liveRemoved.isEmpty`: return `false` without calling the inner tap. The engine then schedules a recreate (2165), which runs A for the new tap and B for the old one, so the departing live process is never in no tap. This case is rare and is logged at `.notice`.
3. If a CA exists, some added process returns `isRunningOutput` (HAL read), and `mayPlay(app, all CA UIDs)`: hold. A helper with no output has nothing to double.
4. `ok = inner.updateProcesses(new)`. If `!ok`: `claim = claim ∩ Claim(new, claim.coverage)`, release, return `false` (the engine recreates).
5. If `inFlight > 0`: `claim = claim ∩ Claim(new, claim.coverage)`, return `true`. The transition's final step picks up the added processes and releases.
6. Otherwise `claim = fromLive(liveCapture)`, `setClaim`, and in a Task `await waitApplied(.grow)`, then release.

Residual: a helper that starts output between step 3 and the exclusion being applied is doubled for at most L.

### E. CA rebuild (make-before-break)

Entry: format change, push failure, dead IO, `IOStoppedAbnormally`, rate mismatch.

1. Build C′ with the current E(D), `held = true` and the gain seeded (main).
2. Attach C′ to the run control. The queue starts it if `shouldRun`.
3. Wait until C′ has at least one callback, or 200 ms, or until it is not running.
4. `C.hold()`, then `C′.release()`. These are two atomic stores in this order: at most one buffer of silence, never an overlap.
5. `await detach(C)`, then destroy C.

Both taps are `.muted`, so covered processes stay held throughout. A process excluded by only one of them is held by its per-app tap. If C′ fails: on a push failure C is retired (fail open); on a format change or dead IO C is retired as well.

### F. A CA appears while per-app taps exist

Triggers: startup, device connect, tier change, second software device.

1. Build with E(D) from the current claims. Taps whose live capture is a stream on another device do not cover D, so their processes stay in CA(D).
2. `onCatchAllDevicesChanged` makes the engine call `refreshTapSourcesForCatchAll()`. For every tap whose `tapSourceDeviceUID` differs from the P5 result, it runs `refreshTapSource(newSource)` and then `applyTapOutputState` (same pattern as `AudioEngine.swift:1116-1125`), which goes through C (grow).

Residual R2 edge: until step 2 completes, a process that outputs to D and to its stream device at the same time is doubled on D.

### G. A CA disappears

Triggers: disconnect, tier change, mode off, session resign, give-up, `stop()`.

1. Detach, then destroy.
2. Complete the pending handovers for that device:
   - grow waiters release now (no CA, so no doubling);
   - shrink waiters invalidate now (the process returns to direct output, which is the state without the feature).

---

## 6. IO lifecycle and resume detection

### 6.1 States per attached CA

`stopped` (IOProc not running; covered processes held by `CATapMuted`), `running`, plus an orthogonal `held` flag (output zeroed). Only the run queue moves between `stopped` and `running`.

### 6.2 Run decision

```
covered(p, D)  = p is live and p ∉ excluded(D)        // excluded(D) from setExcluded: self, foreign, claims
feeds(p, D)    = devices(p) unreadable or empty
                 or devices(p) contains D's AudioDeviceID
                 or devices(p) contains a device that is aggregate, virtual or unresolvable
                 or deviceFilterDisabled(D)
shouldRun(D)   = ∃ p: covered(p, D) ∧ isRunningOutput(p) ∧ feeds(p, D)
                 ∨ (running ∧ lastAudibleHostTime(D) within 10 s)
```

The second term means a running CA is never stopped while its own tap input is audible, whatever `Devices` reports. The tap input is the ground truth for "something is destined for D".

### 6.3 Events on the run queue

- **System object:** `kAudioHardwarePropertyProcessObjectList`. For each new process the queue registers the `IsRunningOutput` (global scope) and `Devices` (output scope) listeners **and then reads both values immediately**, because a process can already be outputting when it first appears. It also classifies the process through the catalog. Removed processes get their listeners removed (tolerating `kAudioHardwareBadObjectError`, as at `AudioProcessMonitor.swift:405-407`).
- **System object:** `kAudioHardwarePropertyServiceRestarted`, posted to main (§10).
- **Per attached aggregate:** `kAudioDevicePropertyIOStoppedAbnormally`, which posts a rebuild.
- **From main:** `attach`, `detach`, `setExcluded`, `prepareInclusion`.
- `IsRunning` (`AudioHardware.h:1957-1961`) and `IsRunningSomewhere` (918-920) are not used. Main is not involved: `AudioProcessMonitor` listens on `.main` and runs a full NSWorkspace and sysctl refresh (`AudioProcessMonitor.swift:196-201, 244-346, 382`), and `activate()` can block main for up to 2 s (`ProcessTapController.swift:679`), which happens exactly when a new app starts.

### 6.4 Resume path and latency (R4)

When `shouldRun(D)` becomes true while D is stopped, the queue:

1. sets `seedGain = true` and `rearmGate = true` in the render state;
2. calls `AudioDeviceStart(aggregateID, procID)`;
3. records the listener time and stores the `AudioDeviceStart` return time.

The callback stores the first callback time and the first audible time, and the queue logs the delta at `.notice`, which is persisted. (Info-level logs are not persisted, which is why earlier log searches found nothing.)

Latency budget:

| Component | Time |
|---|---|
| Listener dispatch | 1-5 ms |
| `AudioDeviceStart` | about 25 ms (`HANDOFF.md:40`) |
| First buffer | about 10 ms |
| **Total** | **about 35-40 ms** |

The first buffer fades in over 10 ms. If the queue is busy, a resume waits behind it; that costs silence, never loudness.

### 6.5 Suspend (R3)

- While running, a 2 s queue tick (leeway 0.5 s) evaluates `shouldRun`. When it has been false continuously for 10 s (the fork's `tapSuspendDelay`, `AudioEngine.swift:82`), the queue calls `AudioDeviceStop`.
- **Stop-then-recheck:** the queue then re-reads `IsRunningOutput` and `Devices` of every covered process from the HAL. If `shouldRun` is true, it starts again immediately, which closes the race with a process that started during the decision.
- Suspend is driven by process IO, never by signal silence alone. A covered process that keeps its output IO running while silent produces no new `IsRunningOutput` edge when it becomes audible again, so a silence-based stop would mute it indefinitely.
- That cost exists only while such a process already keeps D running.
- While stopped, the only timers are those in §6.6. The main health loop is not changed.

### 6.6 Safety re-read and device-filter probe (R9)

- **Safety re-read.** While a CA is stopped, a 10 s timer (5 s leeway) re-reads `IsRunningOutput` and `Devices` of the covered processes, as a guard against missed notifications. Missed notifications are documented in `AudioProcessMonitor.swift:210-212`. Worst case: a covered sound is held silent for about 10 s.
- **Probe.** When a covered process has run output for 30 s or more while `feeds` filtered it out (Devices names only other plain devices), the queue starts D for 1.5 s:
  - if the tap input is audible, D stays running, `deviceFilterDisabled(D) = true` for the session, and a `.fault` is logged;
  - otherwise it stops, and the probe repeats every 30 s while the condition holds.

  This bounds the damage of a wrong `Devices` value to about 30 s and makes it heal itself. H8 checks the property before the filter is trusted at all. If H8 fails, `deviceFilterDisabled` defaults to true.

### 6.7 Liveness (on the queue, independent of main)

While running and `shouldRun`:

- `lastCallbackHostTime` older than 1 s on two consecutive 2 s ticks posts `rebuild(D, .ioDead)`;
- an aggregate nominal rate that differs from the device rate twice posts `rebuild(D, .rateMismatch)`;
- `AudioDeviceStart` returning an error posts `rebuild(D, .startFailed)`.

### 6.8 Strategy B (only if H4 confirms it)

The condition is that `AudioDeviceStart` on a `tapautostart` aggregate returns without blocking, runs no IO and holds no power assertion while armed, and re-arms after `AudioDeviceStop`. If so:

- the CA aggregate gets `tapautostart = true`;
- every stop becomes `AudioDeviceStop` followed by `AudioDeviceStart`;
- the HAL then starts IO at the first covered sample with no listener latency. The listeners stay as the fallback.

---

## 7. Gain, mute and limiter

- **Target gain.** `deviceVolumeMonitor.outputProcessingGain(for: deviceID)` (`DeviceVolumeMonitor.swift:189-204`). It returns the software volume, 0 when muted, and the persisted UID-keyed level for an `AudioDeviceID` that has no state yet (#375). This is the same factor per-app taps multiply into `effectiveVolume` (`AudioEngine.swift:850`), so the TV gain is applied exactly once per process.
- **Wiring.**
  - `onVolumeChanged` (405-419) and `onMuteChanged` (421-433) call `catchAll.deviceGainChanged(deviceID)`. The software paths of `setVolume` and `setMute` fire them (`DeviceVolumeMonitor.swift:412, 481-495`).
  - `refreshGains()` is also called after `handleSettingsReset` (`AudioEngine.swift:785`), in the DDC probe callback (353-356), from every reconcile, and on `onOutputTierChanged`.
- **Volume keys and HUD** need no change: `MediaKeyMonitor.handle` (`MediaKeyMonitor.swift:231-258`) and the HUD writer (`FineTuneApp.swift:127-145`) go through `setVolume` and `setMute`.
- **RT behavior.**
  - Main stores `targetGainBits` atomically. The callback ramps `currentGain` with the 30 ms one-pole coefficient inside `processMappedBuffers` (`ProcessTapController.swift:1550`), so volume-key steps are click-free.
  - `seedGain` sets `currentGain = target` on the first callback after a build or resume, so playback never ramps down from 1.0 (the same idea as 746-748).
  - Mute is a gain of 0, reached in about 30 ms.
- **Limiter.** `processMappedBuffers` ends every buffer with `SoftLimiter.processBuffer` (1637-1638). This matters because the CA sums many processes.
- **DSP.** None in v1: no per-app gain, boost, EQ, AutoEQ or loudness. HDMI and DisplayPort do not support AutoEQ. Processes get per-app control through handover A.
- **Feedback pop.** FineTune is excluded, and the `NSSound` volume already follows the software mapping (`VolumeFeedbackPlayer.swift:13-22, 83-86`). H11 verifies that the pop is not captured.
- **Tier changes.** The engine's `onOutputTierChanged` handler calls `refreshAllTapOutputStates()` (903-907) and `catchAll.reconcile()`. This also fixes per-app taps keeping a stale software gain after a tier override.

---

## 8. Device lifecycle

### 8.1 Eligibility (`CatchAllPlan.eligibility`, every reason logged at `.notice`)

All of the following must hold:

- the mode is `observe` or `on`;
- audio-capture permission is authorized;
- the login session is active;
- `selfObject` is known;
- the circuit breaker is closed;
- the device is in `deviceMonitor.outputDevices` and alive (`isAliveCheck`, `AudioEngine.swift:31, 258`);
- `outputVolumeBackend == .software`, overrides included (`DeviceVolumeMonitor.swift:159-166`);
- it is not an aggregate (`AudioDeviceID+Classification.swift:8-19`) and not virtual (21-23);
- `streamCount(output) == 1` (`AudioDeviceID+Streams.swift:58-67`);
- its UID is not in `CatchAllExcludedDeviceUIDs`;
- its `AudioDeviceID` is not in the give-up set.

AirPods and built-in speakers are hardware tier and never qualify.

### 8.2 Reconcile and engine hooks

`reconcile()` (main, keyed by UID with the `AudioDeviceID` stored at build):

1. A CA whose device is ineligible, gone, or has a different `AudioDeviceID` is retired (§5 G).
2. An eligible device without a CA gets a build (§5 F), then attach and initial push.
3. If the set of live CAs changed, `onCatchAllDevicesChanged` fires.
4. Build failures back off 5 s, 30 s and 120 s, then wait for the next device or tier event.

| Engine site | Line | Hook |
|---|---|---|
| `init` parameters | 235-251 | `catchAll: (any CatchAllCoordinating)? = nil`. If nil: `startMonitorsAutomatically && CatchAllSettings(.standard).mode != .off ? CatchAllCoordinator.live(…) : NoopCatchAllCoordinator()`. Expose `var catchAllCoordinator` for tests. |
| `tapFactory` | 307-328 | When `catchAll.isEnabled`, wrap the chosen factory: `{ app, uids, src in CatchAllAwareTap(inner: try base(app, uids, src), requestedSource: src, coordinator: catchAll) }` |
| startup Task | between 366 and 368 | `self.catchAll.start()` (after `deviceVolumeMonitor.start()`, before `applyPersistedSettings()`, so playing apps are covered before their per-app taps exist) |
| permission granted | 391-392 | `catchAll.start()` before `applyPersistedSettings()` |
| `start()` | before 728 | `catchAll.start()` |
| DDC probe callback | 353-356 | `self?.catchAll.reconcile()` |
| `onVolumeChanged` / `onMuteChanged` | 406 / 422 | `self.catchAll.deviceGainChanged(deviceID)` |
| `wireCallbacks` | near 489 | `deviceVolumeMonitor.onOutputTierChanged = { … refreshAllTapOutputStates(); catchAll.reconcile() }`; `catchAll.onCatchAllDevicesChanged = { [weak self] in self?.refreshTapSourcesForCatchAll() }` |
| `stop()` | before 752 | `catchAll.stop()` (retire every CA, complete pending handovers; the taps are then invalidated with no handover) |
| `handleSettingsReset` | after 785 | `catchAll.refreshGains()` |
| `handleDeviceDisconnected` | after 1565 | `catchAll.reconcile()` |
| `handleDeviceConnected` | after 1679 | `catchAll.reconcile()` (built before the default switch at 1795-1813; the alive-watcher re-entry at 1849-1882 covers late-alive devices) |
| `preferredTapSourceDeviceUID` | after 2076 | P5 guard (§4.7) |
| `prepareTapsForOutputFormatChange` | 2393 | `catchAll.formatChanging(uid:)` |
| `cancelTapsOutputFormatChangePreparation` | after 2400 | `catchAll.formatUnchanged(uid:)` |
| `handleOutputDeviceFormatChanged` | before 2434 | `await catchAll.formatChanged(uid:)` |
| harness (commit 7) | after 368 | `if let steps = CatchAllSettings(.standard).harnessSteps { CatchAllHarness(…).run(steps) }` |

The coordinator observes `NSWorkspace.sessionDidResignActive`, `sessionDidBecomeActive` and `didWake` itself (pattern at `MediaKeyMonitor.swift:160-170`):

- **resign:** retire all CAs (#418: system-account daemons may serve the other session);
- **become active:** reconcile;
- **wake:** reconcile and a liveness check.

### 8.3 Scenarios

| Scenario | Behavior |
|---|---|
| TV disappears | Reconcile at the top of `handleDeviceDisconnected` retires the CA. Errors from the dead device are ignored. Per-app fallback switching is unchanged. Nothing plays to a gone device. |
| TV reappears with a new `AudioDeviceID` | `refreshOutputDeviceStates` (1678) runs first, so the build seeds the persisted gain (#375). Exposure window: from the device becoming alive until the build finishes (about 100 ms, at most 2 s). Apps without per-app taps play unprocessed there, as today. A device that is present but not alive is handled by the alive watcher. |
| Format or sample-rate change | `formatChanging` holds the CA (covered audio silent, never loud). `formatUnchanged` releases it. `formatChanged` rebuilds (§5 E) with a re-read stream index, because the tap format follows the stream (`CATapDescription.h:107-110`). A hold watchdog releases after 2 s if no change follows. |
| Default goes to AirPods and back | CA(TV) is unchanged and goes idle (no feeding output, stops after 10 s). Follows-default taps go to the mixdown under P5, so a CrossOver game that stays on the TV remains covered by its per-app tap. When the AirPods disconnect, `stream(TV)` is allowed again. Both transitions are coverage-neutral. |
| Several software devices | One CA each, with E(D) per device. P5 forces mixdown everywhere, so claims cover every CA device. Timers and probes are per device. |
| Tier override software → hardware or DDC | The CA is retired and its processes play at hardware volume. Hardware → software builds one. A DDC display reads as software until its probe completes, so a short-lived CA may exist at startup. The user's TV has no DDC (`HANDOFF.md:17`). |
| coreaudiod restart | §10. |

---

## 9. Interaction with per-app taps, passthrough, ignored apps, daemons

| Case | Per-app tap | In CA(TV)? | Result on the TV |
|---|---|---|---|
| App with a mixdown per-app tap | Yes (claim `allDevices`) | Excluded | Per-app gain × TV gain, as today |
| App with a `stream(TV)` tap | Yes (claim `device(TV)`) | Excluded | As today |
| App with a `stream(X)` tap from before the CA existed | Yes (claim `device(X)`) | Included until H5 refreshes it to mixdown | TV-bound audio at TV gain, no doubling unless it outputs to both |
| Suspended per-app tap (silent app) | Yes; still holds P muted | Excluded | Resumes as today (`AudioEngine.swift:2169-2177`) |
| New app before its tap (incident 1) | Not yet | Included | TV gain from the first sample, then handover A |
| New helper before `updateProcesses` | Partially | Helper included | Helper at TV gain, then handover D |
| Ignored app (`ignoreApp`, 567-576) | Removed through B | Included | **Behavior change:** TV gain instead of full scale (today "natural volume", 565-566). On AirPods: native. |
| Call passthrough | Never on software devices (594-597). On AirPods the tap is released through B. | Included | Its TV output (if any) at TV gain. AirPods output untouched, AEC intact. CA(TV) stays stopped (`feeds` is false). |
| Filtered daemons: systemsoundserverd, notifications, dictation, Siri (`AudioProcessMonitor.swift:31-66, 286`) | Never | Included | TV gain (fixes incident 2) |
| Other human users (`AudioProcessMonitor.swift:261`) | Never | Excluded (#418), CA retired on session resign | Unprocessed (stated exception) |
| FineTune's own process, per-app aggregates, feedback pop | n/a | Excluded | Already processed once |
| App whose per-app tap creation failed | No | Included | TV gain (today: unprocessed) |
| Multi-device app with the TV in its set | Yes (mixdown) | Excluded | App gain without TV gain (existing gap, `AudioEngine.swift:843-848`) |

---

## 10. Failure modes and kill switch

Every failure ends in one of two states: covered audio held back for a bounded time, or fail-open to today's behavior. No path leaves a process excluded but untapped, and none leaves audio silent permanently.

| Failure | Detection | Response |
|---|---|---|
| CA cannot be built (no `selfObject`, stream index, tap, aggregate, IOProc, read-back mismatch, not ready within 2 s) | Build throws | Partial teardown in `TapResources` order, `.error` log, today's behavior on that device, backoff 5/30/120 s, one breaker count |
| Exclusion push fails | `setDescription` error or read-back mismatch | Retry with a fresh live list, then rebuild (§5 E), then retire (G). Waiters always complete. |
| CA IO dead while covered output plays | Queue liveness (§6.7), `IOStoppedAbnormally`, start error | Rebuild (E). Three failed rebuilds for one `AudioDeviceID` within 2 min: retire, `.error`, give-up set until reconnect, tier change, mode change or relaunch |
| Missed resume notification | Safety re-read, stop-then-recheck, probe (§6.6) | Bounded silence (about 10 s; about 30 s for a wrong `Devices`) |
| Run queue blocked in a HAL call | Every main→queue await (`detach`, `prepareInclusion`) has a 1 s timeout | `.fault`, breaker opens, CA resources destroyed from a utility queue via `TapResources.destroyAsync` (fail open) |
| Per-app hold stuck (lost Task) | Coordinator tick (0.5 s, runs only while holds exist); deadlines: grow 1 s, quiet point 2 s, shrink 2 s | Grow: force release (worst case brief doubling). Shrink: force invalidate after un-exclusion. `.fault`. |
| CA format hold stuck | 2 s watchdog | Release |
| Circuit breaker | 3 failures of the above within 10 min | Retire all CAs for the session, `.fault`, decorators become inert, optional notification |
| Main thread hangs | Not detectable in-process | Per-app and CA IO keep running at the last gain. The queue keeps resuming and suspending. Pushes, handovers and gain changes wait for main, so new processes stay processed by the CA. |
| HAL IO thread stalls while the process lives | Queue liveness | Covered audio silent until the rebuild (needs main) |
| coreaudiod restart (`AudioHardware.h:573-577`) | `ServiceRestarted` listener | Forget every CA without destroy calls (IDs may now name other objects), `CrashGuard.untrackDevice` on the old aggregate IDs, reset the catalog, re-resolve `selfObject`, rebuild. Per-app taps recover through the existing health monitor (`AudioEngine.swift:2288-2298`). |
| FineTune quit, crash, `kill -9` | n/a | Private taps and aggregates are not persistent beyond their creator (`AudioHardware.h:1600-1609`; `CATapDescription.h:156-160`). Expected: coreaudiod drops them and the TV plays at full scale, as without FineTune. CrashGuard tracks the CA aggregate (`CrashGuard.swift:23-39, 58-61`) but cannot run on SIGKILL. `OrphanedTapCleanup` cannot see another process's private aggregates (`OrphanedTapCleanup.swift:13-31`). H9 confirms. |
| Process object ID reuse | Pruning against a fresh process list on every push | Never inherits an exclusion |

**Kill switch:** `defaults write com.adschfr.FineTuneFork CatchAllMode -string off`, then relaunch. This gives `NoopCatchAllCoordinator` and no decorator, exactly today's code. `CatchAllExcludedDeviceUIDs` opts out single devices.

---

## 11. RT safety

**IO proc.** The CA uses a C proc registered with `AudioDeviceCreateIOProcID` and `clientData = Unmanaged.passUnretained(state).toOpaque()`. Inside it calls `Unmanaged<CatchAllRenderState>.fromOpaque(clientData)._withUnsafeGuaranteedRef { CatchAllRender.render($0, input, output) }`. That avoids per-cycle ARC traffic and weak loads (per-app blocks capture `[weak self]`, `ProcessTapController.swift:728-738`).

**`CatchAllRenderState`** (`nonisolated final class`):

- **Cross-thread fields:** `let` properties of type `Atomic` (`import Synchronization`): `targetGainBits: UInt32`, `held: Bool`, `seedGain: Bool`, `rearmGate: Bool` (written by main or the queue); `lastCallbackHostTime`, `lastAudibleHostTime` and `callbackCount: UInt64` (written by the IO thread). All use `.relaxed` ordering, except `held` and `targetGainBits`, which use `.releasing`/`.acquiring`.
- **RT-only scalars:** in `let rt: UnsafeMutablePointer<RTScalars>`, allocated once in `init` and freed in `deinit`. Pointer memory has no dynamic exclusivity checks. Fields: `currentGain`, `gatePhase`, `gateProgress`, `previousCallbackHostTime`.
- **Immutable config:** `observeOnly`, `rampCoefficient`, `gateRampSamples` (10 ms), preferred stereo channels.
- **Harness ring (optional, preallocated):** 4096 × (hostTime, peak) with an atomic write index, enabled only by immutable config.

**`render` order:**

1. Read `now = mach_absolute_time()`. If `now − previous > 100 ms`, re-arm the gate (as at `ProcessTapController.swift:1673-1681`). Store the timestamps and increment `callbackCount`.
2. Consume `seedGain` (`currentGain = target`) and `rearmGate`.
3. `peak = ProcessTapController.inputPeak(input)` (1431-1449). If `peak > 0.0001`, store `lastAudibleHostTime`.
4. If `held || observeOnly`: `memset` every output buffer and return.
5. `gate = ProcessTapController.advanceOutputGate(...)` (1458-1483).
6. `ProcessTapController.processMappedBuffers(...)` (1485-1640) with crossfade 1, all processors nil, and `&rt.pointee.currentGain`. This includes gain ramp, channel mapping, zero-fill and `SoftLimiter`.

**No** allocation, locks, logging, ObjC, Swift collections, `String`, `Task` or dispatch on this path. All three helpers are nonisolated, allocation-free statics that already run on the HAL thread.

**Lifetime.** The controller holds the state strongly and passes it to the `TapResources.destroyAsync` completion closure. It is released only after `AudioDeviceDestroyIOProcID` has returned, which waits for an in-flight callback (`TapResources.swift:9-10, 94-124`).

**Per-app path.** Unchanged. The hold reuses `isMuted` (`ProcessTapController.swift:1736-1741`).

**Off the IO thread.** `AudioDeviceStart`/`Stop` (queue), `setDescription` and builds (main), listeners and logging (queue or main).

**Guard test.** A unit test greps `CatchAllRender.swift` for forbidden tokens: `Logger`, `logger.`, `print(`, `DispatchQueue`, `Task`, `[weak`, `os_unfair_lock`, `NSLock`, `Mutex`, `.append(`, `String(`, `Array(`, `takeUnretainedValue`, `takeRetainedValue`. This follows the style of `ProcessTapControllerSafetyTests.swift:41-51`.

---

## 12. Test plan

### 12.1 Rules

- No unit test creates a tap or aggregate. Building a `CATapDescription` creates no tap, as the existing tests already rely on (`ProcessTapControllerSafetyTests.swift:19-38`).
- `CoreAudioCatchAllBackend` and `HALProcessOutputActivitySource` are only instantiated by `CatchAllCoordinator.live(…)`, which the engine calls only when `startMonitorsAutomatically` is true. All 9 real test engines pass `false`.
- A guard test asserts that an engine built that way has a `NoopCatchAllCoordinator` and an unwrapped factory.
- `scripts/test.sh` also fails on any TCC prompt (`scripts/test.sh:57-64`).
- Settings tests use an injected `UserDefaults(suiteName:)`, never `.standard`.

### 12.2 Unit tests (Swift Testing, fakes only)

1. **CaptureCoverageTests:** the intersection table; `fromLive` (intersection across primary and secondary, empty input gives empty); `covers`.
2. **LiveCaptureMappingTests:** `ProcessTapController.capture(of:)` for a stream description (`device("uid-tv")`) and a mixdown description (`allDevices`); `FakeTapController.liveCapture` defaults; the protocol default `[]`.
3. **CatchAllPlanTests:**
   - Exclusions: self first; foreign included; system, nobody and unknown owners not excluded; mixdown claims exclude on every device; `device(TV)` only on the TV; `device(AirPods)` not on the TV; dead IDs pruned; sorted and unique.
   - `allowsStreamTap`: empty set allows; `{TV}` allows only TV; two devices allow nothing.
   - `needsHold`: empty, unreadable, aggregate and disjoint cases.
   - Eligibility matrix with every rejection reason.
4. **ProcessIdentityTests:** classification table; an unknown self object prevents any build.
5. **CatchAllTapDescriptionTests:**
   - `isExclusive`, `muteBehavior == .muted` (`.unmuted` only in observe), `isPrivate`, processes, `deviceUID`, `stream`, `!isMono`, `!isMixdown`, a unique UUID;
   - under `#available(macOS 26, *)`: empty `bundleIDs` and `!isProcessRestoreEnabled`;
   - the aggregate dictionary (prefix, private, `tapautostart` false, read-back tap UID used, clock and main sub-device);
   - source guard: exactly one `CATapDescription(` in the file, no `GlobalTapButExclude`, `bundleIDs`, `processRestore` or `.mutedWhenTapped`;
   - the existing `ProcessTapController` guard stays at 2 constructions (`ProcessTapControllerSafetyTests.swift:46`).
6. **CatchAllRenderTests** (synthetic `AudioBufferList`s, like `ProcessingPipelineTests`): the seeded first frame equals input × target; ramp to a new target; held and observe give exact zeros; a gap over 100 ms or `rearmGate` gives a 10 ms fade-in; a summed input of 3.0 is limited below 1.0; 2→2, 8→8, mono→stereo; NULL input zeroes the output; counters and timestamps advance; forbidden-token lint.
7. **CatchAllTapControllerTests** (`FakeCatchAllBackend`, recording):
   - build order: tap → UID → description read-back → aggregate → ready → IOProc → inputs disabled → no start;
   - a failure at each step tears down in order;
   - a push uses the stored description and verifies the read-back;
   - a mismatch reports failure;
   - `forget()` makes no destroy calls.
8. **CatchAllRunLogicTests** (pure, manual clock):
   - a covered `IsRunningOutput` rise starts; excluded, self and foreign rises do not;
   - a registration read of 1 starts;
   - `setExcluded` shrink with a running process starts;
   - `prepareInclusion` starts;
   - suspend exactly 10 s after the last feeding output; never while audible;
   - stop-then-recheck restarts;
   - safety re-read after a dropped notification;
   - device filter: unreadable, empty and aggregate count as feeding; the probe disables the filter when audible;
   - liveness posts a rebuild after 2 missed ticks;
   - no timers while stopped other than the safety re-read;
   - per-device independence.
9. **CatchAllRunControlTests:** the driver with `FakeActivitySource`, fake start and stop closures and a test queue: `detach` is a barrier (no start or stop after it returns), and a start error is posted.
10. **CatchAllCoordinatorTests** (fake controllers, run control and clock):
    - builds only for eligible devices; Noop for mode off;
    - gain 0.25 at build, updated on volume and mute (mute gives 0), persisted gain on a new `AudioDeviceID` (#375);
    - reconnect with a new ID rebuilds; disconnect retires; tier override retires and builds;
    - format changes: changing holds, unchanged releases, changed rebuilds in the order "build held → attach → hold old → release new → detach old → destroy old";
    - push failure leads to retry, then rebuild, then retire, with waiters completed;
    - circuit breaker after 3 failures; queue watchdog fails open;
    - session resign retires and become active rebuilds; `ServiceRestarted` rebuilds without destroy calls;
    - the invariant checker repairs a seeded violation.
11. **CatchAllAwareTapTests** (`FakeTapController` + fake coordinator, one ordered log):
    - create: `mute true → activate → exclude [P] → applied → mute false`;
    - remove: `mute true → include → applied → invalidate`;
    - no CA: no `mute` events, immediate invalidate;
    - recreate: no hold, no wait for either tap;
    - all IDs dead: immediate invalidate;
    - user mute survives hold and release, and the getter returns the user mute;
    - switch under P5: no hold;
    - switch with coverage loss: shrink applied before the inner switch;
    - two concurrent switches: the final claim equals the live capture;
    - `updateProcesses`: hold only when the added helper runs output; failure keeps `old ∩ new`; a removed live process returns `false` without calling the inner tap.

    Each order test fails if the two critical steps are swapped.
12. **Forwarding test:** a `RecordingTapController` records every `ProcessTapControlling` requirement. The test calls each one through the decorator and asserts it was recorded. A source check counts the requirements in `ProcessTapControlling.swift` (lines 9-45 plus `liveCapture`), so a new upstream requirement fails until it is forwarded.
13. **CatchAllHandoverModelTests** (seeded random, simulated HAL):
    - the fake backend applies pushes after 0-40 ms; the fake taps switch with delays and optional mixdown fallback;
    - random sequences of create, remove, switch, helper added or removed, rebuild and push failure, for 4 apps on 2 software devices;
    - after every simulated step: I1; I2 (with L ≤ margin); I3; I4 at quiescence.
14. **Engine tests** (fixture `AudioEngineSoftwareVolumeTests.swift:27-63` plus an injected fake coordinator):
    - `catchAll.start()` runs before `applyPersistedSettings` creates taps;
    - volume and mute reach `deviceGainChanged`;
    - `ignoreApp`, call passthrough to the speakers, stale cleanup and recreate all go through the decorator;
    - `stop()` calls `catchAll.stop()` before invalidating taps;
    - P5: follows-default app with AirPods default and the TV CA present gets mixdown; with TV default gets `stream(TV)`; two CA devices give mixdown;
    - `onCatchAllDevicesChanged` refreshes a `stream(X)` tap;
    - `onOutputTierChanged` triggers reconcile and refreshes tap gains;
    - the Noop guard test.

    All existing tests stay green unchanged.

### 12.3 Manual harness (commit 7, run only by the user after consent)

- **How to run.** Make the TV the default output, set the TV volume to about 10 %, then `defaults write com.adschfr.FineTuneFork CatchAllHarness -string all` and relaunch FineTune Fork. The harness reuses FineTune's existing audio-capture grant (`AudioRecordingPermission.swift:79`), so no new prompt is expected; if one appears, stop.
- **Logs.** `/usr/bin/log show --last 15m --predicate 'subsystem == "com.adschfr.FineTuneFork" AND category == "CatchAllHarness"'`. Results go into `HANDOFF.md`.
- **Test sounds.** Steps marked "muted" build a temporary muted CA with gain 0, so covered sounds are silent on the TV for the step. Tones come from `afplay -v 0.02` on a generated 440 Hz WAV.

| Step | Mode | Measures | Pass |
|---|---|---|---|
| H0 | observe | Build time, tap format, tap UID vs UUID (F12), read-back `isExclusive` and processes | Build OK, read-back matches |
| H1 | observe | 20×: afplay object appears, `IsRunningOutput` rises, first CA buffer with the tone | Tone in the CA input within one buffer of the rise **(gate)** |
| H1m | muted | afplay `-v 0.3` with the CA running and with the CA stopped | Nothing audible (by ear); the CA input shows the sound when running **(gate)** |
| H2 | observe | 50× exclude and include of a continuous afplay; latency from set return to tone gone or back; buffers with a partial tone | `noErr`, read-back matches, p99 < 50 ms; sets the margins **(gate)** |
| H2b | observe | Two afplay processes, exclude one | No zero buffer during the update |
| H3 | observe | (a) an in-process tone; (b) a per-app `ProcessTapController` on an afplay that is excluded from the CA, playing to the TV | CA input below threshold in both **(gate)** |
| H4 | observe, separate CA with `tapautostart` | Does `AudioDeviceStart` (called on a background queue with a timeout) block; callbacks before audio; re-arm after stop; user runs `pmset -g assertions` | Report only; decides §6.8 |
| H6 | observe | 12 inclusive taps plus the CA | All creations succeed |
| H7 | on/muted | 30×: CA stopped, afplay starts; listener → start return → first callback → first audible | p95 < 50 ms (R4) |
| H8 | muted | afplay held: `IsRunningOutput`, `Devices(out)` contains the TV ID, TV `IsRunningSomewhere` | First two true, otherwise the device filter defaults off **(gate)** |
| H9 | muted, manual | The user runs `kill -9 <pid>` while a held tone runs | Tone audible within 1 s; relaunch clean |
| H10 | optional, manual | `sudo killall coreaudiod` | `ServiceRestarted` logged, CA rebuilt |
| H11 | observe | Volume key pop | Pop not in the CA input |
| H12 | observe | afplay in a per-app `.muted` tap and in the CA (not excluded) | Both inputs carry it (F7) |

The feature is stopped and redesigned if H1, H1m, H2 or H3 fails.

### 12.4 Live TV test plan (after commit 14, mode `observe` for one day, then `on`, TV at 10 %)

1. **Observe day:** check the logs for `.fault`, invariant violations, resume latency and push latency. Nothing may change audibly.
2. `osascript -e 'beep'`, a notification with a sound, `afplay /System/Library/Sounds/Tink.aiff`: all quiet and consistent with the TV volume.
3. MacWhisper dictation start sound (incident 1): quiet from the first sample.
4. Volume keys and mute while a system sound plays: follows immediately.
5. First playback of a new app (QuickTime): no loud start, dip of 100 ms or less; per-app volume after the handover.
6. Ignore a playing app: continues at TV volume after a dip. Unignore: per-app volume again.
7. A new browser tab with video: no doubled audio.
8. AirPods connect and disconnect during music; the logs show CA(TV) stopping 10 s after the last TV output.
9. TV power cycle: the first sound after reconnect is not loud; the log shows a rebuild with the persisted gain.
10. Change the sample rate in Audio MIDI Setup: short dip, no crackle.
11. 15 s after silence: `pmset -g assertions` shows no assertion held for FineTune; `ps -o %cpu -p <pid>` near 0.
12. `kill -9` FineTune: sounds unprocessed (expected); relaunch restores coverage.
13. Logs: `/usr/bin/log show --last 30m --predicate 'subsystem == "com.adschfr.FineTuneFork" AND category BEGINSWITH "CatchAll"'`. Resume latency below 50 ms, no `.fault`.

---

## 13. Commit plan

Every commit builds, passes `./scripts/test.sh` with no TCC prompt, and leaves behavior unchanged while `CatchAllMode` defaults to `off`. New files go in `FineTune/Audio/CatchAll/` and the tests in `FineTuneTests/`.

1. **feat(audio): report live tap capture.** `CaptureCoverage.swift`; `liveCapture` requirement and default in `ProcessTapControlling.swift`; `liveCapture` and `capture(of:)` in `ProcessTapController.swift`; the revert on failure in `updateProcesses`; `FakeTapController.liveCapture`. Tests 1 and 2.
2. **feat(catchall): exclusion planner and process identity.** `CatchAllPlan.swift`, `ProcessIdentity.swift` (including `ProcessCatalog` and the `pid_t`-qualified TranslatePID read). Tests 3 and 4.
3. **feat(catchall): tap and aggregate description factories.** `CatchAllTapDescription.swift`. Test 5.
4. **feat(catchall): RT render path.** `CatchAllRender.swift`. Test 6 plus the lint.
5. **feat(catchall): catch-all tap controller and Core Audio backend.** `CatchAllBackend.swift`, `CatchAllTapController.swift`, `FakeCatchAllBackend`. Test 7. Not wired.
6. **feat(catchall): run control off the main thread.** `CatchAllRunLogic.swift`, `CatchAllRunControl.swift` (HAL activity source with process list, `IsRunningOutput`, `Devices`, `ServiceRestarted` and `IOStoppedAbnormally` listeners; safety re-read; probe; liveness). Tests 8 and 9.
7. **feat(catchall): settings, observe mode and harness.** `CatchAllSettings.swift`, `CatchAllHarness.swift`, one engine line after 368 (only inside the `startMonitorsAutomatically` Task). Tests for settings parsing and harness step parsing.
   - **Gate:** the user runs §12.3 after consent; results go into `HANDOFF.md`; margins and the device filter default are set from H2 and H8.
8. **feat(catchall): coordinator.** `CatchAllCoordinator.swift` (live and Noop): eligibility, reconcile, claim registry, push tickets, applied waits, gain, invariant checker, backoff, give-up, breaker, watchdogs, session and wake observers, rebuild E, service restart. Test 10.
9. **feat(catchall): CatchAllAwareTap decorator.** `CatchAllAwareTap.swift` with handovers A to D and the transition counter. Tests 11, 12 and 13.
10. **feat(engine): wire the catch-all into AudioEngine.** Every hook in the §8.2 table except P5; `onOutputTierChanged` in `DeviceVolumeProviding` and `DeviceVolumeMonitor`. Test 14 (except P5). Mode default stays `off`.
11. **feat(engine): keep per-app taps covering catch-all devices.** The P5 guard and `refreshTapSourcesForCatchAll()` (H5). P5 tests.
12. **feat(catchall): quiet-point handover (default off).** Step A5 with the deadline. Tests with fake audio levels.
13. **feat(ui): catch-all switch in the Audio tab** (optional). A row next to "Skip Apps on Calls" (`AudioTab.swift:114-122`) writes `CatchAllMode` (`on`/`off`; switching on from a Noop launch says a relaunch is needed). A binding test.
14. **Live phase** (no commit): observe day, then `on`, then §12.4.
15. **feat(catchall): enable by default; docs(fork).** Default `CatchAllMode` becomes `on` after the user's sign-off on the TV. `FORK.md` describes the feature, the R1 exceptions, the changed meaning of ignore on software outputs and the kill switch. `HANDOFF.md` gets the decisions and harness results. The `.mutedWhenTapped` comment in `OrphanedTapCleanup.swift:7-9` is fixed.

Upstream friction (R11): new folder; one protocol requirement with a default; about 18 lines in `ProcessTapController` outside the callback; about 16 hook lines in `AudioEngine`, several in code that only the fork has (`preferredTapSourceDeviceUID` from `828db61`); one callback in `DeviceVolumeProviding` with a default. No project-file edits.

---

## 14. Open risks

| Risk | Severity | Mitigation or decision |
|---|---|---|
| F4 fails: new processes are not captured and muted from their first sample | High | Gate H1 and H1m. If capture lags, the CA still fixes incidents 2 and 3 but not 1; document that or stop. |
| F5 fails: live exclusion updates are rejected, slow or not atomic | High | Gate H2. Every update is read back. If updates are rejected, every change uses rebuild E (an aggregate build on main per change); acceptable only if handovers are rare under P5. |
| F6 fails: FineTune's aggregate IO is attributed to another process object | High | Gate H3, in observe mode where it is harmless. No CA is built without a resolved self object. |
| A bookkeeping bug leaves a process excluded but untapped | High | Claims come only from live capture with `old ∩ requested`; ordered pushes; the runtime invariant checker repairs by un-excluding; the model test and the forwarding test. |
| Covered audio held silent (dead or stopped CA, missed resume, stuck hold) | High | IO-driven suspend, stop-then-recheck, safety re-read, probe, queue liveness, `IOStoppedAbnormally`, hold watchdogs, give-up and breaker fail open. |
| Grow gap audible at every new app's first playback | Medium | Margin tuned from H2, 40 ms fade-in, optional quiet point (commit 12). Open question: whether the quiet point should default to on. |
| Resume above 50 ms clips the start of short sounds after 10 s idle | Medium | Dedicated queue, read right after registration, H7; strategy B if H4 allows it. |
| Device filter (`Devices`) wrong for muted processes | Medium | H8 decides the default; probe self-heals within about 30 s per session. |
| `NSSound` feedback leaves FineTune's process | Low | H11. If captured, exclude that process or drop the self-scaling for software devices. |
| Ignored apps on the TV now follow the TV volume | Medium (behavior change) | Documented in `FORK.md`. Open question for the user. |
| Other tap users (Audio Hijack, SoundSource, or upstream FineTune at the same time) mute a process that the CA then plays | Medium | Kill switch and per-device opt-out; `HANDOFF.md` already forbids running both FineTune builds (`HANDOFF.md:10`). |
| Crash or kill returns the TV to full scale | Medium | Inherent to private taps; H9 verifies that nothing stays muted. Open question: a launchd `KeepAlive` agent. |
| Exposure window after the TV reappears (until the build finishes) | Medium | Reconcile runs before routing and the default switch; build time is logged. |
| Multi-stream, aggregate or virtual software devices uncovered; multi-device apps get no TV gain | Medium | Logged as ineligible. Follow-ups: per-stream CAs, per-sub-device gain. |
| P5 costs multichannel stream capture on a non-TV default while a TV CA exists | Low | Stated trade-off; mixdown is what explicitly routed apps use today (`AudioEngine.swift:2075`). |
| Tap drift compensation on a same-device tap (rule from `ProcessTapController.swift:402-408`) | Low | Kept for consistency with per-app TV taps; revisit if the live test shows crackle (#363). |
| Tap or aggregate limits with about 10 per-app taps | Low | H6. Build failures fail open. |
| Process object ID reuse | Low | Prune against a fresh process list on every push and every process-list change. |