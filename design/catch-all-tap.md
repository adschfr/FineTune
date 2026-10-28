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
---

## 15. Harness results (2026-10-28, macOS 27.2, LG TV over USB-C/HDMI, build 750)

Measured with the harness of commit `f34a737` and its revision in `382f43e`. The TV's UID is replaced by `<TV>`.

| Step | Result | Verdict |
|---|---|---|
| H0 build | 18.8 / 22.5 / 20.0 ms; Core Audio keeps the requested tap UUID; exclusive read-back matches | pass |
| H1 capture of a new process | tone onset missing p50 9.6 ms, p95 20.1 ms (n=10, all heard). Resolution is about ±1 IO buffer (10.7 ms), so capture starts within about one buffer of the first sample | below the 15 ms target, within measurement error |
| H2 live exclusion updates | 40/40 accepted and read back; exclude effective p95 33 ms, include p95 62.8 ms (one outlier, p50 28.7 ms) | above the 50 ms target for include |
| H3 FineTune's own output | in-process sound and per-app tap output not captured | pass |
| H7 resume of a stopped catch-all | run control starts IO in 12–18 ms; onset lost p50 24 ms, p95 37 ms (silence, never loud) | pass |
| H8 muted process | IsRunningOutput true, output devices contain the TV | pass: the device filter may be enabled |

Facts established on the device (they update §2):

- **F4** holds within about one IO buffer: a process that starts after the catch-all exists is captured almost from its first sample. Processes that already exist when the catch-all is built (e.g. MacWhisper before its start sound) are covered from the first sample by construction.
- **F5** holds: exclusion updates on a live exclusive tap are accepted and take effect in about 30 ms, rarely about 60 ms. Margins: grow `max(2 × 63 ms, 2 buffers)` ≈ 130 ms, shrink 400 ms.
- **F6** holds: FineTune's process object excludes its own output, including per-app aggregates.
- **F8** holds for values, but **Core Audio posts no change notification for `kAudioProcessPropertyIsRunningOutput`**; `kAudioProcessPropertyIsRunning` is notified (probe, first harness run). The run control listens to IsRunning and re-reads IsRunningOutput 10/30/100 ms later.
- **F10/F11**: `AudioDeviceStart` on the catch-all takes 12–18 ms.

Consequence for handover A (a per-app tap takes over a process the catch-all already plays): with a 130 ms grow margin plus the 40 ms gate, a playing sound dips for about 170 ms once. The quiet-point handover (§5 A5) avoids the dip for short sounds and should default to on.

### 15.1 Listening check (2026-10-28, build 752)

Run with the visible harness panel: each step announced with a countdown, the user answered right after it.

| Step | Setup | Expected | User heard | Verdict |
|---|---|---|---|---|
| L0 | three plain tones at 10 %, no catch-all | audible | tone | pass (audio path works) |
| H1M | running muted catch-all, five plain tones at 10 % | nothing | nothing | pass |
| H7M | stopped muted catch-all, five plain tones at 10 %, each after the catch-all suspended (log: five resumes) | nothing, no onset click | nothing | pass |

Plain tones have no fade-in, so a leak at the onset would have been an audible click. The catch-all holds audio back from the first sample, also while it resumes from a stop. Earlier runs could not show this by ear: FineTune merged its own afplay test processes into a "FineTune Fork" app entry and tapped them, fixed in `e22a935`.

## 16. Variant B: catch-all as the normal path on software outputs

The user chose variant B ("catch-all first") on 2026-10-28. For software outputs this section replaces the statement in §1 that per-app taps stay as they are. Where it differs from §3-§14, this section applies, and §16.9 replaces the §13 commits 8-15. It is the lean v1: everything not needed for the user's case or for safety is listed in §16.10. Nothing here is built yet. `AudioEngine.swift` means `FineTune/Audio/Engine/AudioEngine.swift`; all line numbers refer to `bef2b82`.

### 16.1 Decision, scope, behavior changes

**Decision.** On an output D that is eligible for a catch-all (§8.1) and whose catch-all (CA) is live, the CA is the normal processing path. For the user, D is the LG TV.

- CA(D) holds every process that no per-app tap holds, from its first sample, and plays it at `outputProcessingGain(D)` followed by `SoftLimiter`.
- FineTune creates a per-app tap on D only when the app needs per-app processing (§16.2).
- A per-app tap is kept until its process object is gone. v1 never hands an app back to the CA.

**Unchanged**

- Hardware-volume outputs (AirPods, built-in speakers): per-app taps as today, created at once (no deferral, §16.10 rule H).
- Mode `off` (default until the user signs off): `NoopCatchAllCoordinator`, no decorator. Every engine hook is either a call on the Noop (empty set, false, no-op) or a fork function that returns today's result at once when `!catchAll.isEnabled` or `!catchAll.affectsAudio`. Nothing else runs (rows 9 and 19 reshape lines without changing their result); the Noop golden-log test pins this (§16.8). The reentrancy guard and the routing prune are gated too, so the latent double-tap bug of today stays in mode off (§16.10).
- Mode `observe`: every app is tapped as today; CAs observe with zero output; the gate logs the decision it would have made ("would cover").

**The user's normal case** (`settings.json`: no per-app entries, `defaultNewAppVolume` 1, loudness off, no tier overrides, V9): one CA on the TV and no per-app taps. Nothing is claimed, pushed or held. The one audible effect is the silent onset loss of 24-37 ms when a sound starts after 10 s of silence on the TV (§15 H7). Today the same sounds play unprocessed at full scale.

**Behavior changes** (go into `FORK.md` at sign-off)

- Ignored apps on the TV follow the TV volume instead of playing at full scale.
- Call apps: unchanged on the TV, where passthrough never applies (`AudioEngine.swift:605-620`). Only a call app that passthrough leaves untapped on the AirPods now plays its incidental TV-bound output at TV volume.
- Covered apps show no per-app level (`getAudioLevel` returns 0 without a tap, `AudioEngine.swift:731-733`).
- P5: while a TV CA exists, follows-default taps on other outputs use the mixdown.
- TV → AirPods during playback: each playing covered app gets a new tap on the AirPods, with one dropout of about 60-100 ms (V5). Today its existing tap switches with a crossfade.
- Mode on: an EQ change for an app without a tap is persisted (today dropped, `:953-957`); a covered app set back to 100 % (slider, keys, `finetune://reset`) gets no tap.

**Code facts this section relies on**

| # | Fact | Source |
|---|---|---|
| V1 | `applyPersistedSettings` visits only `apps`, i.e. apps with a running process object | `AudioEngine.swift:517-520, 1327` |
| V2 | `onAppsChanged` fires only when the fingerprint of listed apps changes; daemons, other users and FineTune's children are never listed; output that starts while IO already runs changes no fingerprint | `AudioProcessMonitor.swift:261, 277, 289, 338` |
| V3 | The run control learns about output from IsRunning edges with follow-up reads, process appearance, the post-stop recheck and a 10 s safety re-read; Devices only with the device filter on | `CatchAllRunControl.swift:149, 152-173, 201-202, 213-214, 228-230` |
| V4 | `waitUntilReady` spins the main run loop inside a CA build and a per-app `activate`; the tap is registered only afterwards | `AudioObjectID+Readiness.swift:31-43`; `CatchAllTapController.swift:106`; `ProcessTapController.swift:679`; `AudioEngine.swift:1293-1294, 1463-1464` |
| V5 | A new per-app tap mutes its process from tap creation until its IO starts | `ProcessTapController.swift:652, 671, 679, 728, 756` |
| V6 | An app that does not play to the default gets the mixdown and is played to its routed device | `AudioEngine.swift:2088-2092` |
| V7 | `setDevice` returns before creating a tap when the chosen device equals the routing | `AudioEngine.swift:1141, 1176` |
| V8 | `resetAllSettings` clears software device volumes and tier overrides | `SettingsManager.swift:907-910` |
| V9 | The user has no per-app settings, `callPassthroughEnabled` true, `systemSoundsFollowsDefault` false | user's `settings.json` |
| V10 | `setDefaultDevice` does not update `defaultDeviceUID`; only the HAL listener does. FineTune-initiated switches route before that (`setDefaultOutputDevice`, `restoreConfirmedDefault`, `reEvaluateOutputDefault`) | `DeviceVolumeMonitor.swift:418-432, 559-583`; `AudioEngine.swift:1106-1111, 1486-1491, 1511-1518` |
| V11 | The alive watcher is installed only in `handleDeviceConnected`, which fires only when the set of output UIDs changes | `AudioEngine.swift:1803-1807`; `AudioDeviceMonitor.swift:537-551` |

### 16.2 When an app gets a per-app tap

**Policy** (new file `FineTune/Audio/CatchAll/PerAppTapPolicy.swift`, nonisolated, pure):

```swift
nonisolated struct AppTapFacts: Sendable, Equatable {
    var targetCovered: Bool            // C1, from isLive(D) (§16.4)
    var singleMode: Bool               // C2
    var followsDefaultPersisted: Bool  // C3
    var appGain: Float                 // C4: volume × boost
    var muted: Bool                    // C5
    var eqActive: Bool                 // C6
    var autoEQOnTarget: Bool           // C7
    var loudnessOn: Bool               // C8
    var playsElsewhere: Bool           // C9, computed only when targetCovered
}
nonisolated enum TapReason: String, Sendable, CaseIterable {
    case noCatchAll, multiDevice, explicitRouting, appGain, muted, eq, autoEQ, loudness, playsElsewhere
}
nonisolated enum TapDecision: Sendable, Equatable { case coveredByCatchAll, tap(Set<TapReason>) }
```

`decide`: `processing` is the set of reasons from C2-C8. Not `targetCovered` gives `.tap(processing ∪ [.noCatchAll])`. Otherwise `processing` empty and no C9 gives `.coveredByCatchAll`, else `.tap(processing ∪ [.playsElsewhere if set])`.

**Rule C.** App A (pid p, identifier i, process objects P), routed in single mode to D, gets no tap if all hold:

| # | Condition | Source |
|---|---|---|
| C1 | `catchAll.covers(D)` (mode on, breaker closed, CA(D) live or dormant) | coordinator, §16.4 |
| C2 | `volumeState.getDeviceSelectionMode(p) == .single` | `VolumeState.swift:126` |
| C3 | `settingsManager.isFollowingDefault(i)`; persisted explicit routing gets a tap, also when it names D or while the app is moved to the default, because only tapped apps move back on reconnect (`AudioEngine.swift:1702-1720`) | `SettingsManager.swift:281-283` |
| C4 | `abs(getVolume(p) * getBoost(p).rawValue - 1) <= 0.001`. The state is seeded with `defaultNewAppVolume` when a pid is first seen, so changing that default affects only pids seen afterwards | `VolumeState.swift:33-34, 63, 204-207` |
| C5 | `!volumeState.getMute(p)` | `VolumeState.swift:95` |
| C6 | `!eq.isEnabled \|\| eq.isFlat`, `eq = settingsManager.getEQSettings(i)` | `EQSettings.swift:17, 47` |
| C7 | not (D supports AutoEQ and its selection is enabled), whether or not the profile is cached | `AudioEngine.swift:1040-1041` |
| C8 | `!loudnessCompensationEnabled && !loudnessEqualizationEnabled` | `SettingsManager.swift:44-45` |
| C9 | `!catchAll.playsElsewhere(P, target: D)` | settle rule below |

**C9 settle rule.** A device-stream CA captures only streams addressed to D (F1). An app that follows the TV default but plays to an aggregate, a virtual or another device escapes it; today the mixdown tap catches it (V6).

- The run queue observes `kAudioProcessPropertyDevices` (output scope) for every process and posts each change to main, each listed ID classified as plain, aggregate or virtual, or unresolvable. Commit 9 splits `hasNonPlain`, which merges the last two (`CatchAllRunLogic.swift:5-9`, `CatchAllRunControl.swift:276-284`). No Devices read happens on main.
- *D-like* devices are D's currently listed `AudioDeviceID` and, for 2 s after each routing or default change, every device in `noteRouting`'s `from` set. macOS moves streams asynchronously, so a switch alone never creates a tap.
- P is *foreign* for D at once when some object lists an aggregate or virtual device that is not D-like. It becomes foreign after 500 ms when no object lists a D-like device and some object lists another device or an unresolvable ID (a just-removed device has no readable UID), or reads empty or unknown while its IsRunningOutput is 1. P that lists D plus only plain devices stays covered; today's stream tap on D leaves its other streams alone too (`:2088-2092`).
- `playsElsewhere(P, D)` is true while P is foreign. The coordinator calls `onCoverageMayHaveChanged` when P becomes foreign (also when a grace window ends), so the gate runs again.
- A C9 tap always uses the mixdown (§16.5 row 25). A stream tap would leave the elsewhere-bound stream uncaptured.

**Where the rule is checked.** Only where FineTune creates a tap on its own initiative or after a setter on an untapped app:

- `applyPersistedSettings`, single-device branch, after the routing (`:1404`) and the switch block (`:1408-1423`), before `ensureTapExists` (`:1426`): `if taps[app.id] == nil, catchAllSkipsTap(for: app, deviceUID: deviceUID) { continue }`. A skipped app stays out of `appliedPIDs`, so every later call checks it again; such a call runs on each IsRunning edge of a listed app (`AudioProcessMonitor.swift:338-343`), so row 19 writes the observed `followsDefault` (`:1381, 1396`) and `appDeviceRouting` (`:1404`) only on change. An app with a tap is never skipped, so `:1430-1443` keep applying saved volume and mute. The routing is set, so the row renders (`MenuBarPopupView.swift:918`).
- `catchAllReevaluateUntapped(app)` after `setVolume`, `setBoost`, `setMute`, `setEQSettings` without a tap and a same-device `setDevice` (V7): when `affectsAudio`, the app has no tap and is routed in single mode, it runs the gate at its routing and creates the tap if decided, also for a silent app.

**Ungated, as today:** ignored apps (`:1329`), call passthrough (`:1333`), the multi path (`:1345-1371`), `setDevice` to another device (`:1176`), `updateTapForCurrentMode` (`:1271`), `recreateTap` (`:2367, 2372`, only for pids that have a tap), every switch site, and R2 (§16.3 E13).

**Settings without per-app effect on a covered app:** pins; `autoEQPreampEnabled` (only with AutoEQ, C7); device volume and mute (the CA applies them); user EQ presets; `systemSoundsFollowsDefault` (alert routing, E2). Handled before the gate: `ignoredApps`, call passthrough, `appSelectedDeviceUIDs`. Handled by eligibility: tier overrides, `CatchAllExcludedDeviceUIDs`.

**Re-evaluation.** Every existing `applyPersistedSettings` call checks skipped apps again: startup (`:382`), permission granted (`:406`), `onAppsChanged` (`:453`), `reconcileCallPassthrough` (`:643`), `unignoreApp` (`:650`), `start()` (`:742`), `handleSettingsReset` (`:810`). New triggers are `reevaluateCatchAllCoverage()` (no-op unless `affectsAudio`) from `routeFollowsDefaultApps` (before `:1558`) and the AutoEQ and loudness setters, and the coordinator's own changes (after a reconcile, or when C9 settles). None runs the gate in the caller: the coordinator's one coalesced next-turn task runs a pending `reconcile()` first, then `onCoverageMayHaveChanged`, whose handler runs `applyPersistedSettings`. So no `activate` and no build spins the run loop inside a device or default-change handler, where nested default callbacks would see half-updated priority state (`:1987-2003`, `:1820-1851`). While a FineTune-initiated default change has not reached `DeviceVolumeMonitor` yet (V10), `applyPersistedSettings` reads the intended target instead of the stale default (row 19).

**Removal.** A tap is never removed because a rule became true; only as today (stale cleanup after 30 s, `ignoreApp`, passthrough release, replacement in `recreateTap`).

### 16.3 Lifecycle events that differ from today

| Constant | Value | Source |
|---|---|---|
| G, grow margin | 130 ms | §15 (2 × the 62.8 ms include outlier) |
| S, shrink margin | 400 ms | §15 |
| Per-app fade | 40 ms gate, re-armed on the unmute edge | `ProcessTapController.swift:754, 1695-1700` |
| Suspend delay | 10 s | `CatchAllRunLogic.swift:45` |
| `ioOnlyCap` (unlisted processes only) | 120 s, then a 100 ms poll while the CA is stopped | new |
| Safety re-read while all CAs are stopped | 3 s, leeway 1 s (was 10 s, 5 s) | `CatchAllRunControl.swift:214, 221` |
| C9 settle, grace | 500 ms, 2 s | new |
| Watchdogs | grow `max(1 s, G + 0.6 s)`, retirement 2 s, shrink 2 s, format 2 s | §10 |
| Detach and `stop()` wait | 1 s | §10 |

"Hold" means the decorator forces the inner `isMuted`; "applied" is §4.6.

**E1. Startup, mode on, TV default.** `catchAll.start()` runs after `deviceVolumeMonitor.start()` (`:366`) and before `applyPersistedSettings` (`:382`). It builds CA(TV) on main in about 20 ms (§15 H0) with the persisted gain (#375) and E = {self} ∪ foreign ∪ claims, attaches it **held**, and releases it once its applied list equals the list desired from the current claims (at once if none changed). The gate then decides `.coveredByCatchAll` for every TV app. A tap created by `onAppsChanged` during the build spin (V4) sees phase `building`, is created as today and kept; the held attach prevents doubling until its exclusion applies.

**E2. Unlisted sounds** (system sounds, notifications, dictation daemons, harness tones, V2). Only the run queue sees them. They play through the CA at TV gain when they play to the TV; after 10 s of silence the CA starts in 12-18 ms and the onset loses 24-37 ms, silently (§15 H7, F10). System alerts go to the system alert device (V9); if that is not the TV, they are unaffected.

**E3. Output that starts inside running IO** (MacWhisper with the microphone running).

- A covered process with IsRunning 1 counts as needing audio. For a listed app (`appsChanged`) this has no cap, which is today's cost: its tap never suspends while IsRunning is 1 (`AudioEngine.swift:2183-2185`). The CA runs, so a later start or stop sound loses nothing.
- An unlisted process counts for `ioOnlyCap`, then the run queue polls its IsRunningOutput every 100 ms while the CA is stopped. Worst case after the cap: a silent onset loss of about 120 ms.
- Every output rise found by a poll or the safety re-read is logged "output without edge".

**E4. A customized app starts, or a covered app's setting changes.** The CA plays the onset at app gain 1 × TV gain. The gate decides `.tap`; decorator A holds before `activate` (TV is a target and in `changed`), pushes E(TV) ∪ P, waits for grow, releases with the fade. A playing app dips once for about 170 ms; a silent one hears nothing. A persisted per-app mute is audible at TV volume until then (Q4).

**E5. Back to defaults** (100 %, unmute, flat EQ, x1, System Audio, settings reset). The tap stays and plays at unity × TV gain. Without a tap, setting 100 % creates none.

**E6. App quits.** Covered: nothing audible. When `catchAll.isEnabled`, the routing of untapped absent pids gets the same 30 s grace cleanup as taps (row 26), so a briefly absent call app keeps its routing. Tapped: as today, then B; dead objects make `removeClaim` return nil and the tap is invalidated at once.

**E7. A covered app plays elsewhere.** The Devices listener reports a foreign device; under the settle rule the gate decides `.tap([.playsElsewhere])` with the mixdown, and decorator A holds the TV part. Until the tap exists, audio to the other device is unprocessed unless the CA also captures it: for an aggregate or virtual device (which may contain the TV) for the Devices post plus `activate`, like today's first playback of a new process; for another plain device or an unresolvable ID 500 ms longer. Today an app already tapped while silent has no such window.

**E8. Default TV → AirPods** (no rule H in v1).

1. macOS moves follows-default apps natively.
2. `routeFollowsDefaultApps(AirPods)`: `catchAllWillRoute` passes the apps' previous routing and the monitor's default as `from` (C9 treats the TV as D-like for 2 s) and records AirPods as the intended default; the routing loop runs; before the early return at `:1558`, `reevaluateCatchAllCoverage()` schedules the gate.
3. In the next turn every playing covered app gets `.tap([.noCatchAll])` on the AirPods, with the mixdown under P5. The AirPods are not in `changed`, so there is no hold; each app has the V5 dropout. S8 lets the user judge it (Q1).
4. Existing taps switch as today; under P5 their claims cover the TV before and after, so no push and no hold.
5. Silent covered apps get their tap at their next IO start. A CrossOver game still bound to the TV gets a mixdown tap and moves to the AirPods, as today.

**E9. Default AirPods → TV.** Taps switch with a crossfade; the mixdown claim covers the TV before and after (P5), so no push and no hold. Untapped apps are evaluated against the target TV even while `defaultDeviceUID` is stale (V10) and decide `.coveredByCatchAll`; Devices still naming the AirPods is ignored for 2 s. Exception: a `stream(fallback)` tap from a time without CA grows TV coverage, so decorator C holds and it dips once (E11).

**E10. macOS auto-switch that FineTune reverts** (case 1, `:1987-2007`). Only `restoreConfirmedDefault` → `routeFollowsDefaultApps(TV)` runs. The monitor already names the AirPods (`DeviceVolumeMonitor.swift:578-583`), so they are in `noteRouting`'s `from` set and a transient AirPods listing counts as D for 2 s. Covered apps stay covered; no AirPods taps.

**E11. TV disconnect and reconnect** (power cycle, new `AudioDeviceID`).

- Off: `catchAll.reconcile()` after `:1579`, run in the coordinator's next turn. The UID is absent, so G: detach, destroy (errors ignored), grow waiters release, shrink waiters invalidate, nothing counted. Taps switch to the fallback as today. `reEvaluateOutputDefault` (`:1682`) → `routeFollowsDefaultApps(fallback)` gives every playing covered app a tap there right after G, `stream(fallback)` when it already plays there (no CA exists, P5 allows it), otherwise mixdown.
- On: `refreshOutputDeviceStates` (`:1692`), `refreshAllTapOutputStates` (`:1693`), then `catchAll.reconcile()`, requested before the default action (`:1809-1827`) and run after the handler, before the scheduled gate: CA(TV) with the new ID and the persisted gain, attached held until applied. Mixdown taps switch back without a hold; each `stream(fallback)` tap dips once (C). These apps keep their taps until they quit (Q6).
- Exposure: from the TV becoming alive until the build ends (about 20 ms, at most 2 s), untapped TV-bound audio is unprocessed, as today.

**E12. TV listed but not alive** (HDMI link drop, display sleep), or listed under the same UID with a new ID and no connect event (V11). G is not used. Checked at an IO failure, a start failure, a reconcile and every device-list refresh (`deviceListRefreshed`, a new callback at the end of `AudioDeviceMonitor.handleDeviceListChanged`, `AudioDeviceMonitor.swift:521`; that monitor fires connect and disconnect only when the UID set changes, `AudioDeviceMonitor.swift:537-551`):

1. Listed ID differs from the stored ID and is alive: rebuild through E at once; if that fails, R. An IsAlive listener would never fire on an alive device.
2. Listed ID not alive and a CA object exists: phase `dormant`. CA(D) held and detached from the run control, resources kept, nothing counted. Covered audio is silent because D plays nothing; for an unchanged ID the muted tap also holds it (for a new ID unverified, since the tap is built from the UID, `CatchAllTapDescription.swift:15-23`). `covers(D)` stays true, so no `activate` blocks on a dead device.
3. The coordinator registers its own `kAudioDevicePropertyDeviceIsAlive` listener on the listed ID and reads IsAlive once right after registering. A 2 s main-thread check and every list refresh re-read the listed ID and alive state while dormant and move the listener when the ID changed.
4. Alive: rebuild through E on the listed ID. If that fails: R.

Without a CA object (a failed build, E14, E20) D never goes dormant: `covers(D)` stays false.

**E13. Retirement with promotion, R (fail-open, mode on).** Reasons: push failure after the retry and a rebuild; give-up (3 counted IO failures for one ID within 2 min); breaker; run-queue timeout; tier found changed at a reconcile; failed rebuild after E12; injected (listening session only).

1. **R1.** `phase(D) = .retiring(caHeld: false)`: `covers(D)` false, gain frozen, flush skips D, pending grow waiters on D become retirement holds, `reconcile` ignores D until R4 ends.
2. **R2.** Synchronous `onCoverageWillEnd(D)` → `catchAllCoverageEnding(D)`: every present, untapped, non-ignored single-mode app in `processMonitor.activeApps` that is routed to D, or whose cached Devices name D or a non-plain device (`mayPlay`; for example a CrossOver game still on the TV after its AirPods tap failed), gets `ensureTapExists` on D, **silent apps included**: their suspended `.muted` taps then hold their next onset, as today (`ProcessTapController.swift:569-573`, `AudioEngine.swift:2095-2097`). An app routed elsewhere is not marked applied, so the next pass moves its tap to its routing (`:1408-1420`); a failed switch leaves it on D. The decorator takes a retirement hold before `activate` because `phase(D) == .retiring`, whatever `affectsAudio` is, and `setClaim` returns a retirement ticket. The callback returns true when an untapped app routed to D is absent within its 30 s grace (row 26).
3. **R3.** One main-actor turn: `CA(D).hold()`, phase `.retiring(caHeld: true)`, complete all retirement tickets on D. Overlap or gap is at most one IO buffer; an overlap is faded in. After R3 no tap takes a hold on D and grow waits on D complete at once.
4. **R4.** `detach(D)` with a 1 s timeout; destroy only after the queued detach has actually run (§16.7). If R2 returned true, the held, detached CA is kept aside and destroyed 30 s later (`stop()` destroys it at once; R4 still ends at the detach): until then its muted tap keeps a returning absent app silent until that app's tap exists (created on its return, `covers(D)` is false), at the cost of silent unlisted sounds on D for that time.
5. Then: give-up keeps D off until a device, mode or relaunch event; IO and push failures back off 5/30/120 s; after the breaker, no rebuild this session.

Result: today's per-app taps, also for silent apps; an app whose `activate` throws plays unprocessed (today's result for a failed tap); system sounds unprocessed, as today. In observe every retirement is G (all apps are tapped). G is used only for an absent UID, `stop()` and a service restart without the device.

**E14. CA build fails.** `covers(D)` stays false and the gate creates today's taps. `notReady` blocks main up to 2 s, during which the tap already holds uncovered TV audio silent. Backoff 5/30/120 s, then give-up. A failure while D is listed but not alive is not counted: the coordinator installs the E12 alive listener (read once after registering) and builds when D is alive. After a later build, existing taps stay.

**E15. Format or rate change on the TV.** `formatChanging` holds the CA (`:2407`); `formatUnchanged` releases it (after the in-flight guard `:2414`; the coordinator also ignores it while its own rebuild for that UID runs); `formatChanged` runs inside `handleOutputDeviceFormatChanged` right after `outputFormatChangeInFlight.insert` (`:2424`) and before the per-app recreation, only when called from the `onOutputDeviceFormatChanged` closure (`:471-475`). So the guard at `:2414` and the health monitor's skip at `:2288` protect the per-app taps on D during the CA rebuild, and a single tap's rate mismatch (`:2290-2297`) does not rebuild the CA. Rebuild through E: new CA built held, attached, first callback or 200 ms and its list applied, hold old, release new, detach and destroy old. 2 s watchdog.

**E16. Settings reset** (`:786-813`). After `:799`: `catchAll.refreshGains(); catchAll.reconcile()` (V8). Taps stay (E5).

**E17. Ignore, unignore.** Ignoring a tapped app on the TV runs B: hold, include, shrink wait, invalidate; a dip of about one exclusion latency (30-60 ms), then TV volume through the CA. An untapped app loses its routing and the CA keeps playing it. Unignore runs `applyPersistedSettings` and the gate.

**E18. Modes.** `off`: Noop, unwrapped factory, every fork function returns at once. `observe`: CAs built unmuted with zero output; `isLive` true, `covers` false; every app tapped; claims and pushes run; the gate logs "would cover". The mode is read at launch. Kill switch: `defaults write com.adschfr.FineTuneFork CatchAllMode -string off`, relaunch.

**E19. Quit and `stop()`.** Before the tap loop (`:766`), `catchAll.stop()` retires every CA with G (bounded wait, §16.7) and completes the waiters; taps are then invalidated without a handover. On process death the private taps disappear, which H9 must confirm before mode on.

**E20. coreaudiod restart** (`ServiceRestarted`). Forget the CAs without destroy calls, reset the catalog and the Devices classification, re-resolve self. **Keep a claim only if every tap UUID of its owner resolves** in the restarted daemon (`kAudioHardwarePropertyTranslateUIDToTap`); void the others and pass their pids to `onClaimsVoided`, which schedules a recreate for each at once (the health monitor skips suspended and user-muted taps, `:2261-2267`). `setClaim` applies the same check to owners registered before the restart, because `liveCapture` trusts a stale `tapID` (`ProcessTapController.swift:954-959`). A stale object ID can therefore never exclude another process, and a tap created before the coordinator saw the restart keeps its exclusion (no lasting doubling). Rebuild with {self} ∪ foreign ∪ kept claims at the next device-list refresh (at most 1 s), on the listed ID, so `outputProcessingGain` finds the level (it returns 1.0 for an ID the device monitor does not know, `DeviceVolumeMonitor.swift:189-203`). If the rebuild fails: R, and while D is not alive the E12 alive listener builds later; never dormant.

### 16.4 What remains from variant A

**Kept unchanged (built):** `CaptureCoverage`, `liveCapture` and the revert in `updateProcesses`; `ProcessIdentity`, `ProcessCatalog`; `CatchAllTapDescription`, `CatchAllRender`, `CatchAllBackend`, `CatchAllTapController`; `CatchAllPlan.exclusions`, `changedDevices`, `allowsStreamTap` (P5) and `ineligibility`, whose existing `.notAlive` (`CatchAllPlan.swift:85, 101`) is the uncounted reason; `CatchAllSettings` and the harness (H9 added); invariants I1, I3, I4.

**Changed**

- **I2** now reads: if CA(D) and a per-app tap T capture a process on D **and D is one of T's targets**, T's output is held. Doubling across devices is inaudible.
- **Hold rule:** `CatchAllPlan.holds(changed:targets:) = !changed.isDisjoint(with: targets)` replaces `needsHold` (`CatchAllPlan.swift:44-51`). Targets are the tap's output UIDs, old and new during a switch. `mayPlay` and the `processOutputDeviceUIDs` reads leave the decorator.
- **Run control:** the IsRunning rule (E3), the listed set, Devices observed for every process under a new `observeDevices` flag (not `deviceFilterEnabled`, `CatchAllRunControl.swift:149, 161`) and classified as plain, aggregate or virtual, or unresolvable (C9), the 3 s safety re-read, new callbacks next to `:51-52`. The device filter stays off.
- **Coordinator** (§3.1 listing replaced; the runtime I1 checker with repair is new work, not built):

```swift
enum CatchAllPhase: Equatable { case building, live, dormant, retiring(caHeld: Bool) }
@MainActor protocol CatchAllClaimOwner: AnyObject {           // CatchAllAwareTap adopts it (commit 13)
    var appPID: pid_t { get }                                 // for onClaimsVoided
    var tapUUIDs: [UUID] { get }                              // E20 check
}
@MainActor protocol CatchAllCoordinating: AnyObject {
    var isEnabled: Bool { get }                 // false only for Noop
    var affectsAudio: Bool { get }              // mode == .on && breaker closed; no phase involved
    var catchAllDeviceUIDs: Set<String> { get } // CAs building, live or dormant (input for P5)
    func phase(_ uid: String) -> CatchAllPhase?
    func isLive(_ uid: String) -> Bool          // live or dormant, in observe and on
    func covers(_ uid: String) -> Bool          // affectsAudio && isLive(uid)
    func playsElsewhere(_ processes: [AudioObjectID], target uid: String) -> Bool
    func mayPlay(_ processes: [AudioObjectID], on uid: String) -> Bool  // cached Devices name D or a non-plain device (R2)
    func noteDecision(_ app: AudioApp, target uid: String, _ decision: TapDecision)  // .notice on change
    func noteRouting(from previousUIDs: Set<String>, to targetUID: String)
    var onCoverageWillEnd: ((String) -> Bool)? { get set }      // synchronous, R2; true: an absent app was routed to D
    var onCoverageMayHaveChanged: (() -> Void)? { get set }     // next turn, after a pending reconcile
    func requestReevaluation()                                  // fires onCoverageMayHaveChanged next turn
    var onClaimsVoided: ((Set<pid_t>) -> Void)? { get set }     // E20: recreate these taps
    var onEvent: ((CatchAllEvent) -> Void)? { get set }         // listening session only
    func start(); func stop(); func reconcile(); func refreshGains()  // reconcile runs in the next turn
    func appsChanged(_ apps: [AudioApp])                        // listed processes for E3
    func deviceListRefreshed()                                  // E12, E20
    func deviceGainChanged(_ deviceID: AudioDeviceID)
    func formatChanging(uid: String); func formatUnchanged(uid: String); func formatChanged(uid: String) async
    // decorator only
    func changedDevices(owner: ObjectIdentifier, proposed: Claim) -> Set<String>  // live CAs only
    func setClaim(_ owner: any CatchAllClaimOwner, _ claim: Claim) -> ApplyTicket?  // nil: no list changed, no target retiring
    func removeClaim(_ owner: ObjectIdentifier) -> ApplyTicket?
    func prepareInclusion(of processes: [AudioObjectID], on uids: Set<String>)
    func waitApplied(_ ticket: ApplyTicket, _ direction: ApplyDirection) async
    func takesRetirementHold(targets: Set<String>) -> Bool      // some target in .retiring(caHeld: false)
    func processIsLive(_ process: AudioObjectID) -> Bool
    func isRunningOutput(_ process: AudioObjectID) -> Bool
}
```

  Also: one generation counter per device; waiters on a dormant D complete at once (its rebuild uses the current claims); nested reconcile during a spin is deferred, retirements are queued; claims checked by tap UUID after a restart (E20). Retirement tickets: `setClaim` with a target in `.retiring(caHeld: false)` returns a ticket whose `.grow` wait ends at R3 (or the 2 s retirement watchdog), also when no list changed (§5 A step 6 would otherwise release at once); any grow wait on D registered between R1 and R3 is one, and a wait on D in `.retiring(caHeld: true)` completes at once.
- **Decorator, handovers A-D (§5):** unchanged except the hold rule, retirement holds (A step 6 awaits the retirement ticket) and `processIsLive` in D.
- **F:** build with E from the current claims, attached held until applied; existing taps stay; no source refresh.
- **E:** unchanged, except that C′ is released only once its applied list equals the desired list.
- **G:** only absent UID, `stop()`, restart without the device, and every retirement in observe.
- **P5:** unchanged, plus the C9 mixdown guard.

**Dropped:** the quiet point (A5); `refreshTapSourcesForCatchAll` (H5) and `onCatchAllDevicesChanged`; the device-filter probe (§6.6) and strategy B; the activity hint from `onAppsChanged`; design 2's lazy demotion, served-state maps, `cancelRemoval` and I5-I8; harness steps H5, H6, H11, H12 (H10 stays optional and manual).

### 16.5 Engine hooks

All private-state code goes into one `// MARK: - Catch-all (fork)` section at the end of `AudioEngine.swift` (about 90 lines). Hooks inside existing functions are one or two lines (about 35 in all). Rows marked 14 or 15 land in that commit (§16.9).

| # | Site (`AudioEngine.swift`) | Line | Change | C |
|---|---|---|---|---|
| 1 | Stored properties | next to 25, 60-62 | `let catchAll: any CatchAllCoordinating`; `@ObservationIgnored private var catchAllTapsBeingCreated: Set<pid_t> = []`; `@ObservationIgnored private var catchAllRouteTargetUID: String?` | 14 |
| 2 | `init` | 235-251, before 307 | parameter `catchAll: (any CatchAllCoordinating)? = nil`; default `startMonitorsAutomatically && s.mode != .off && s.harnessSteps == nil && s.pendingH9 == nil ? CatchAllCoordinator.live(…) : NoopCatchAllCoordinator()` with `s = CatchAllSettings()`. Test engines get Noop | 14 |
| 3 | Tap factory | 307-328 | when `catchAll.isEnabled`, wrap: `CatchAllAwareTap(inner: try base(app, uids, src), targets: Set(uids), requestedSource: src, coordinator: coordinator)` | 14 |
| 4 | DDC probe callback | 353-356 | `self?.catchAll.reconcile()` | 14 |
| 5 | Startup Task | after 366; 369 | `self.catchAll.start()`; harness condition `\|\| CatchAllSettings().pendingH9 != nil` (commit 8); listening session start (commit 16) | 8/14/16 |
| 6 | `observePermissionGranted` | between 405 and 406 | `self.catchAll.start()` | 14 |
| 7 | `onVolumeChanged`, `onMuteChanged` | 419, 435 | first statement `self?.catchAll.deviceGainChanged(deviceID)` | 14 |
| 8 | `onAppsChanged` | 449-455 | first statement `self?.catchAll.appsChanged(apps)` | 14 |
| 9 | `onOutputDeviceFormatChanged` closure; `handleOutputDeviceFormatChanged` | 473; 2422, after 2424 | closure calls `handleOutputDeviceFormatChanged(uid: uid, rebuildCatchAll: true)`; new parameter defaulting to false (the health monitor at 2296 keeps it); `if rebuildCatchAll { await catchAll.formatChanged(uid: uid) }` | 14 |
| 10 | End of `wireCallbacks` | before 512 | `catchAll.onCoverageWillEnd = { [weak self] in self?.catchAllCoverageEnding($0) ?? false }`; `catchAll.onCoverageMayHaveChanged = { [weak self] in self?.catchAllRunGate() }`; `catchAll.onClaimsVoided = { [weak self] in $0.forEach { self?.scheduleTapRecreation(for: $0) } }`; `(deviceMonitor as? AudioDeviceMonitor)?.onOutputDeviceListRefreshed = { [weak self] in self?.catchAll.deviceListRefreshed() }` | 14 |
| 11 | `start()`, `stop()` | before 742; before 766 | `catchAll.start()`; `catchAll.stop()` | 14 |
| 12 | `handleSettingsReset` | after 799 | `catchAll.refreshGains(); catchAll.reconcile()` | 14 |
| 13 | `setVolume` | 817 | `if !catchAllReevaluateUntapped(app), let deviceUID = appDeviceRouting[app.id] { ensureTapExists(…) }` | 15 |
| 14 | `setBoost`, `setMute` | after 835; after 945 | `catchAllReevaluateUntapped(app)` | 15 |
| 15 | `setEQSettings` | 954 | `guard let tap = taps[app.id] else { catchAllEQWithoutTap(settings, for: app); return }`: persists and re-evaluates only when `affectsAudio` | 15 |
| 16 | AutoEQ and loudness setters | after 977, 984, 1005, 1013 | `reevaluateCatchAllCoverage()` (`AudioTab.swift:44-49` sets the flag first) | 15 |
| 17 | `setDevice` | before 1141 | `if appDeviceRouting[app.id] == deviceUID { catchAllReevaluateUntapped(app) }` (V7) | 15 |
| 18 | `ensureTapWithDevices` | after 1280; after 1294 | `guard catchAllBeginCreation(app.id) else { return }; defer { catchAllEndCreation(app.id) }`; `catchAllDidRegister(tap, app, deviceUIDs)` | 14 |
| 19 | `applyPersistedSettings` | 1382, 1397; 1381, 1396, 1404 | `deviceVolumeMonitor.defaultDeviceUID` → `catchAllDefaultOutputUID()`; write `followsDefault` and `appDeviceRouting` only on change (same result) | 15 |
| 20 | Gate | before 1426 | `if taps[app.id] == nil, catchAllSkipsTap(for: app, deviceUID: deviceUID) { continue }` | 15 |
| 21 | `ensureTapExists` | after 1450; after 1464 | as row 18 | 14 |
| 22 | `routeFollowsDefaultApps` | start of body (1546, before the loop overwrites the routing); before 1558 | `catchAllWillRoute(to: targetUID)`; `reevaluateCatchAllCoverage()` (schedules) | 15 |
| 23 | `handleDeviceDisconnected` | after 1579 | `catchAll.reconcile()` | 14 |
| 24 | `handleDeviceConnected` | after 1693 | `catchAll.reconcile()` (before the default action at 1809) | 14 |
| 25 | `preferredTapSourceDeviceUID` | after 2090 | `guard CatchAllPlan.allowsStreamTap(candidate: defaultUID, catchAllDevices: catchAll.catchAllDeviceUIDs), !catchAll.playsElsewhere(app.processObjectIDs, target: defaultUID) else { return nil }` (Noop: empty set, false) | 14 |
| 26 | `cleanupStaleTaps` | 2100 | stale set `Set(taps.keys).union(catchAll.isEnabled ? Set(appDeviceRouting.keys) : []).subtracting(activePIDs)`; the existing 30 s task (2133-2154) prunes routing of untapped pids | 15 |
| 27 | `prepareTapsForOutputFormatChange` | 2407 | `catchAll.formatChanging(uid: uid)` | 14 |
| 28 | `cancelTapsOutputFormatChangePreparation` | after 2414 | `catchAll.formatUnchanged(uid: uid)` | 14 |

Unchanged and seen through the decorator: `isCallPassthrough`, `ignoreApp`, `releaseCallPassthroughTaps`, `syncTapsWithProcessState`, the health monitor, `recreateTap`, `effectiveVolume`, every switch site (1133, 1167, 1261, 1414, 1566, 1648, 1662, 1730, 2441). `DeviceVolumeProviding` and `DeviceVolumeMonitor` are not touched.

**Fork section, essential bodies**

```swift
func catchAllSkipsTap(for app: AudioApp, deviceUID: String) -> Bool {
    guard catchAll.isEnabled else { return false }                      // off: nothing read
    let live = catchAll.isLive(deviceUID)                               // observe logs "would cover"
    let eq = settingsManager.getEQSettings(for: app.persistenceIdentifier)
    let facts = AppTapFacts(
        targetCovered: live,
        singleMode: volumeState.getDeviceSelectionMode(for: app.id) == .single,
        followsDefaultPersisted: settingsManager.isFollowingDefault(for: app.persistenceIdentifier),
        appGain: volumeState.getVolume(for: app.id) * volumeState.getBoost(for: app.id).rawValue,
        muted: volumeState.getMute(for: app.id),
        eqActive: eq.isEnabled && !eq.isFlat,
        autoEQOnTarget: deviceMonitor.device(for: deviceUID)?.supportsAutoEQ == true
            && settingsManager.getAutoEQSelection(for: deviceUID)?.isEnabled == true,
        loudnessOn: settingsManager.appSettings.loudnessCompensationEnabled
            || settingsManager.appSettings.loudnessEqualizationEnabled,
        playsElsewhere: live && catchAll.playsElsewhere(app.processObjectIDs, target: deviceUID))
    let decision = PerAppTapPolicy.decide(facts)
    catchAll.noteDecision(app, target: deviceUID, decision)
    return catchAll.affectsAudio && decision == .coveredByCatchAll    // == covers(D) && covered
}

@discardableResult
func catchAllReevaluateUntapped(_ app: AudioApp) -> Bool {             // true: the gate handled it
    guard catchAll.affectsAudio, taps[app.id] == nil, let uid = appDeviceRouting[app.id],
          volumeState.getDeviceSelectionMode(for: app.id) == .single else { return false }
    if !catchAllSkipsTap(for: app, deviceUID: uid) {
        ensureTapExists(for: app, deviceUID: uid)
        if taps[app.id] != nil { appliedPIDs.insert(app.id) }
    }
    return true
}

func catchAllCoverageEnding(_ uid: String) -> Bool {                   // R2, also with the breaker open
    guard catchAll.isEnabled else { return false }
    for app in processMonitor.activeApps where taps[app.id] == nil
        && volumeState.getDeviceSelectionMode(for: app.id) == .single
        && !settingsManager.isIgnored(app.persistenceIdentifier) {
        let routed = appDeviceRouting[app.id] == uid
        guard routed || catchAll.mayPlay(app.processObjectIDs, on: uid) else { continue }
        ensureTapExists(for: app, deviceUID: uid)                      // retirement hold in the decorator
        if routed, taps[app.id] != nil { appliedPIDs.insert(app.id) }  // others move to their routing next pass
    }
    let present = Set(processMonitor.activeApps.map(\.id))
    return appDeviceRouting.contains { $0.value == uid && taps[$0.key] == nil && !present.contains($0.key) }
}

func catchAllWillRoute(to targetUID: String) {                         // before the routing loop
    guard catchAll.isEnabled else { return }
    let previous = Set(followsDefault.compactMap { appDeviceRouting[$0] })
        .union([deviceVolumeMonitor.defaultDeviceUID].compactMap { $0 })  // HAL-driven: already the new UID
    catchAll.noteRouting(from: previous, to: targetUID)
    guard catchAll.affectsAudio else { return }
    catchAllRouteTargetUID = targetUID == deviceVolumeMonitor.defaultDeviceUID ? nil : targetUID
}

func catchAllDefaultOutputUID() -> String? {                           // V10
    let monitorUID = deviceVolumeMonitor.defaultDeviceUID
    guard catchAll.affectsAudio, let target = catchAllRouteTargetUID else { return monitorUID }
    if target == monitorUID { catchAllRouteTargetUID = nil }
    return target
}
```

`reevaluateCatchAllCoverage()` is `guard catchAll.affectsAudio else { return }; catchAll.requestReevaluation()`; `catchAllRunGate()` is `guard catchAll.affectsAudio else { return }; applyPersistedSettings()`. `catchAllEQWithoutTap` persists through `settingsManager.setEQSettings` and calls `catchAllReevaluateUntapped` when `affectsAudio`. `catchAllBeginCreation` returns `true` when `!isEnabled`, otherwise `catchAllTapsBeingCreated.insert(pid).inserted`; every writer of `taps[pid]` for a pid without a tap goes through it (`recreateTap` removes the old tap first, `:2363`). `catchAllDidRegister` (only when enabled) calls `applyTapOutputState` again, so a volume or mute set by a nested setter during the spin reaches the tap. If the selection mode is still single and `appDeviceRouting[app.id]` changed meanwhile, it switches the tap there in a Task with the pattern of `:1408-1420`; only a changed selection mode runs `updateTapForCurrentMode(for:)`, which reads the stale default for follows-default apps (`:1235`, V10).

**Other files:** `CatchAllRunLogic.swift`, `CatchAllRunControl.swift` (E3, `observeDevices`, refresh order, detach and stop timeouts, `onDevicesChanged` and event posts); `CatchAllPlan.swift:44-51`; `CatchAllSettings.swift` (H9 and its pending key, `CatchAllIOOnlyCapSeconds`, margin overrides, `CatchAllListening`); `CatchAllHarness.swift` (H9, alert-device line, ms timestamps); `AudioDeviceMonitor.swift` (`onOutputDeviceListRefreshed` at the end of `handleDeviceListChanged`, commit 14); new `PerAppTapPolicy.swift`, `CatchAllCoordinator.swift`, `CatchAllAwareTap.swift`, `CatchAllListening.swift`; tests: `FakeCatchAllCoordinator`, `FakeTapController.onActivate`.

### 16.6 Failure modes and fail-open

Every failure ends in one of three states: covered audio silent for a bounded time (unbounded only when the run queue or main never returns: silent, never loud), one short dip, or today's per-app taps (through R, or because `covers` is false). No path leaves a process excluded without a tap that holds it (I1 checker with repair), and none releases a per-app tap while the CA plays the same process on one of its targets.

| Failure | Detection | Response | Worst audible result |
|---|---|---|---|
| Build fails, device alive | build throws | teardown; `covers` false; backoff 5/30/120 s, give-up; 1 breaker count | `notReady`: uncovered TV audio silent ≤ 2 s |
| Device listed but not alive, or new ID under the same UID | `isAliveCheck`, listed ID ≠ stored ID at an IO failure, reconcile or device-list refresh | E12: new alive ID rebuilds E at once; not alive: dormant (only with a CA), alive listener read once, rebuild E, else R; never counted | silent while not alive, as today; new ID: until the list refresh and rebuild, silent or unprocessed (unmeasured) |
| Device UID absent | reconcile | G | as today |
| Push fails or read-back differs (`CatchAllTapController.swift:126-146`) | `push` false | retry with fresh list, rebuild E, then R; waiters complete | handover delayed, never unprocessed |
| CA IO dead, `IOStoppedAbnormally`, start error | 2 liveness ticks, listener, status | rebuild E; 3 counted within 2 min: give-up and R | covered audio silent ~4 s plus rebuild |
| IsRunning edge missed | follow-ups, stop-then-recheck, 3 s re-read | none | covered sound silent ≤ ~4 s |
| Unlisted output inside IO after the cap | 100 ms poll | none | silent onset loss ≤ ~120 ms |
| Covered app plays elsewhere | Devices listener, settle rule | mixdown tap | aggregate or virtual: as today's first playback; plain or unresolvable: 500 ms longer |
| Exclusion slower than G | applied needs margin and 2 callbacks; grow watchdog | release | doubled (≤ +6 dB) for the excess |
| Hold stuck (lost Task) | coordinator tick, only while holds exist | grow: release; retirement: CA hold, then release; shrink: invalidate after inclusion or CA gone | brief doubling or silence, `.fault` |
| Reentrancy during a spin (V4) | creation guard, phases, deferred reconcile, queued retirements | nested effects re-applied after registration | none |
| Run queue blocked in a HAL call | 1 s timeout on `detach` and `stop()` (other calls are `queue.async`) | `.fault`, breaker count, R; destroy only after the queued detach ran | as R; if the queue never returns, covered audio stays silent |
| Breaker (3 counted failures within 10 min) | counter | `affectsAudio` false; R for every CA (retirement holds still apply); no rebuild this session | one R gap |
| `activate` fails in R2 | throw | logged | that app unprocessed, as today for a failed tap |
| Format change | hooks (E15) | hold, release or E; 2 s watchdog | covered audio silent ≤ 2 s |
| coreaudiod restart | `ServiceRestarted` | E20: claims kept only for resolving tap UUIDs, voided taps recreated; R if the rebuild fails | unprocessed in the restart window, as today |
| App absent from the process list at R | R2 return value | destroy deferred 30 s, held CA | returning app silent until its tap; unlisted sounds on D silent ≤ 30 s |
| Quit, crash, `kill -9` | none | private taps die with the process (H9 gates mode on) | TV at full scale until relaunch |
| Main thread hangs | none | CA IO and run queue continue at the last gain | holds in flight silent for the hang |
| Other tap users (SoundSource, upstream FineTune) | none | kill switch, `CatchAllExcludedDeviceUIDs` | a process muted by another tool |

**Residuals in v1:** a customized app's first 100-300 ms at TV gain, a persisted mute briefly audible (Q4); one dropout per playing app on TV → AirPods (Q1); apps keep taps until they quit after resets, AirPods sessions and TV power cycles during playback, and `stream(fallback)` taps dip once on return (Q6); an unlisted daemon with open IO costs CA IO for 120 s, then 100 ms polls; a covered app that starts on an aggregate or virtual device is unprocessed there until its tap exists (Devices post plus `activate`, as at today's first playback of a new process), on another plain device or an unresolvable ID 500 ms longer.

### 16.7 RT and threading

- **HAL IO thread:** no change. `CatchAllRender` and its lint test stay. A per-app hold uses the existing `isMuted`, a plain `nonisolated(unsafe)` Bool (`ProcessTapController.swift:60, 218-220`); the IO thread re-arms the 40 ms gate on the unmute edge (`:1695-1700`). The CA hold is the atomic `renderState.held`. R3 is one atomic store plus plain word-sized stores in one main-actor turn; the aggregates run independent IO cycles, so overlap or gap is at most one buffer.
- **Run queue** (`com.adschfr.FineTuneFork.catchall`): IsRunning, IsRunningOutput and Devices listeners for every process. `refresh` reads IsRunning and IsRunningOutput and applies start effects first, then reads Devices; device classification is cached per `AudioDeviceID` and cleared on `ServiceRestarted`, so a resume never waits behind 1 + 3k HAL reads. Timers: 2 s tick while a CA runs; 100 ms poll only while a CA is stopped and a capped unlisted process exists; 3 s re-read (1 s leeway) while all are stopped. The interval comes from a pure `CatchAllRunLogic.timerInterval(now:)`. Devices changes and start or suspend times go to main through `Task { @MainActor … }`, coalesced; the queue never waits for main.
- **Timeouts:** `detach` resumes a one-shot continuation (`Mutex<CheckedContinuation?>`) from the queue or from a 1 s `DispatchSourceTimer`. On timeout the coordinator completes R but destroys the CA only when the queued `detachOnQueue` has run, so no `backend.stop` or `start` hits destroyed IDs (`CatchAllRunControl.swift:175-196`). `stop()` uses `queue.async` and a semaphore wait of 1 s instead of `queue.sync` (`:78-87`); on timeout it skips destroy and relies on process exit (H9).
- **Main:** builds, pushes, `activate`, gate decisions and C9 lookups (no HAL reads), the E12 IsAlive reads and the E20 tap-UUID check. Builds and `activate` spin the run loop (V4), hence the creation guard, one build per device and deferred nested reconciles. Engine hooks never spin inside device or default-change handlers: `reconcile()` (rows 4, 12, 23, 24) and `requestReevaluation()` only schedule the coordinator's next-turn task (reconcile first, then the gate), so builds, R and its R2 run in the coordinator's own turn. `onCoverageWillEnd` is the only synchronous callback into the engine. A 2 s main check runs only while a CA is dormant.
- **Isolation** (app target nonisolated by default, test target MainActor): `PerAppTapPolicy`, `CatchAllPlan`, `CatchAllRunLogic` nonisolated; coordinator and decorator `@MainActor`.
- **Helper processes** (`afplay`, `osascript`, the H9 `/bin/sh` helper) are started only by the harness and the listening session, never by tests or normal operation.

### 16.8 Tests

**Rules** (§12.1, MEMORY "test runs and TCC"): no unit test creates a tap or aggregate, spawns a process or plays sound; real backends exist only in `CatchAllCoordinator.live`; `./scripts/test.sh` fails on any TCC prompt (`scripts/test.sh:57-63`); settings tests use `UserDefaults(suiteName:)`. Existing tests outside the CatchAll suites stay green unchanged; commit 9 rewrites `followUpReadCatchesLateOutput` (`CatchAllRunTests.swift:326-343`, the IsRunning edge now starts the CA) and commit 10 replaces the `needsHold` tests (`CatchAllPlanTests.swift:71-91`).

**Unit tests (Swift Testing, fakes only)**

1. **`CatchAllRunTests`** (pure logic, manual clock): IsRunning without output starts for a listed process with no cap; an unlisted one counts for 120 s, then poll effects at 100 ms, and a poll that finds output starts; `timerInterval` gives 3 s while all are stopped and the re-read restarts a missed resume; poll and re-read rises are flagged "output without edge"; a Devices change emits `devicesChanged`, an identical read does not; start effects precede the Devices read; no suspend while output runs; excluded, self and foreign never start.
2. **`PerAppTapPolicyTests`:** each of C2-C9 alone turns covered into tap; C1 false gives `noCatchAll`; gain 0.9995 covered, 0.99 tap, 0.5 × x2 covered; EQ enabled and flat covered, disabled with gains covered; AutoEQ selection on a device without support covered; explicit routing to D and multi mode tap; every reason reported.
3. **`CatchAllPlanTests`:** `holds` for disjoint, overlapping and empty sets.
4. **`CatchAllCoordinatorTests`** (injected: fake backend and run control, clock, process list, self object, device facts (listed, alive, ID, tier, aggregate, virtual, stream count), Devices feed): `isLive`, `covers`, `affectsAudio` per mode and phase, with a single retiring CA keeping `affectsAudio` true; gain seeded, followed, frozen; flush coalescing, generation, applied waits; a new CA attaches held and releases only after its initial list applies; I1 repair; `playsElsewhere` true at once for an aggregate or virtual device, after 500 ms for another plain ID, an unresolvable ID, or an empty or unknown list while IsRunningOutput is 1; false for D plus plain devices and for an empty list while silent; every `from` device counts as D for 2 s; re-evaluation callback when P becomes foreign; `mayPlay` for D, non-plain and other lists; retirement tickets per the "Also" rules; `reconcile` and `requestReevaluation` share one next-turn task, reconcile first; reentrancy: the fake backend's `waitUntilReady` calls `reconcile` and the flush through `MainActor.assumeIsolated`, giving one build per device and no push to a building CA.
5. **`CatchAllCoordinatorFailureTests`** (fake claim owners, one ordered log; coordinator side only): R with one CA logs `retiring → onCoverageWillEnd → CA hold → retirement tickets complete → detach → destroy` and fails if a ticket completes before the CA hold or destroy precedes the detach; `takesRetirementHold` true between R1 and R3, false after; R2 returning true defers destroy by 30 s; absent UID gives G without callback or count; listed-not-alive with a CA gives dormant (no destroy, no callback, no count), alive again rebuilds, a failed rebuild runs R; a new listed ID that is already alive rebuilds at once (device-list refresh); IsAlive already true when the listener is registered rebuilds; a failed build while not alive leaves `covers` false, is not dormant and builds when alive; 3 counted failures give give-up and R; breaker runs R for every CA; format changing, unchanged and changed in E order, `formatUnchanged` ignored during the rebuild; `ServiceRestarted` forgets without destroy, keeps a claim whose tap UUIDs resolve, voids and reports the others, builds after the list refresh; detach timeout never destroys before the queued detach; watchdogs fire.
6. **`CatchAllAwareTapTests`** (`FakeTapController`, `FakeCatchAllCoordinator`, one ordered log): create on a live CA target `mute true → activate → exclude → applied → mute false`; on the AirPods with a mixdown claim covering the TV: exclusion pushed, no mute; on a retiring target `mute true → activate → (R3) → mute false`, released only when the coordinator completes the ticket; a tap created after R3 takes no hold; remove `mute true → include → applied → invalidate`; dead processes invalidate at once; P5 switch without push; a coverage-losing switch shrinks first; two concurrent switches end with claim = `liveCapture`; D rules; user mute survives a hold.
7. **Forwarding test:** every requirement in `ProcessTapControlling.swift:9-48` reaches the inner tap; a source count fails on a new upstream requirement.

**8. Engine tests** (fixture of `AudioEngineTapLifecycleTests.swift:72-90`, which injects `isProcessRunning` and `currentDate`, plus `processOutputDeviceUIDs` and `FakeCatchAllCoordinator`, which fires `onCoverageMayHaveChanged` in the next turn after `requestReevaluation`; `MockDeviceVolumeProviding.setDefaultDevice` leaves the default stale, `DeviceVolumeTierTests.swift:194`):

- covered app at defaults: no factory call, routing set; then `appSettings.loudnessCompensationEnabled = true` and `setLoudnessCompensationEnabled(true)` (row 16, through `applyPersistedSettings`) give exactly one factory call after one turn, which shows the pid was not marked applied;
- observe, live CA, app at defaults: `noteDecision(.coveredByCatchAll)` and exactly one factory call;
- `setVolume` ≠ 1, `setBoost`, `setMute(true)`, `setEQSettings` (persisted), same-device explicit routing, multi mode, loudness, AutoEQ each create exactly one tap, also for a silent app where the setter is per app; `setVolume(1)` and `setMute(false)` on a covered app (URL reset) create none;
- reset keeps taps; saved volume and mute still reach an existing tap;
- `playsElsewhere` creates one tap with the mixdown source;
- `setDefaultOutputDevice(AirPods)` with a stale monitor default: routing AirPods, no factory call inside the call, one tap per playing covered app on the AirPods (mixdown) after one turn; AirPods → TV and the case-1 restore: no factory call, routing TV; a default change arriving with the monitor already updated passes the previous routing in `noteRouting`'s `from`;
- `onCoverageWillEnd(TV)` creates taps synchronously for running and silent covered apps routed to the TV and for an untapped app routed to the AirPods whose Devices name the TV (not marked applied), not for ignored ones; it returns true for an absent untapped pid routed to the TV;
- `onClaimsVoided` schedules one recreate per pid;
- reentrancy: `FakeTapController.onActivate` fires `onAppsChanged`, `setVolume`, `setMute` and `setDevice` for the same pid; one tap is registered, carries the nested volume and mute, and is switched to the nested routing without `updateTapForCurrentMode`;
- routing of a quit untapped app is pruned after the 30 s grace, not at the 350 ms pass; a pid that reappears keeps it;
- wiring order: `catchAll.start()` before the first `applyPersistedSettings`; gain hooks; reset calls `refreshGains` and `reconcile`; reconcile requested on connect before the default action, no factory call inside the handler; the format closure passes `rebuildCatchAll: true`, the health monitor false; `stop()` before the tap loop;
- **Noop golden log** (mode off): a scripted run (start, app plays, `setVolume`, `setEQSettings` without a tap, default switch, disconnect, stale cleanup, reset, a reentrant creation) produces the factory calls and tap events of `bef2b82`; `setEQSettings` without a tap persists nothing.

**9. Harness and listening, pure parts:** H9 is not part of `all`; the pending-H9 record round-trips; S-step parsing; injection is refused without a session token.

**H9, gate G1** (commit 8, only after the user's consent, TV default): a muted harness CA holds the long tone at `afplay -v 0.1`, the level of the L0 control tones the user heard in §15.1; after the kill it plays at that level unscaled. The panel counts down to the kill. A `/bin/sh -c` helper started with `posix_spawn` and `POSIX_SPAWN_SETSID` sends SIGKILL to FineTune at the shown time, stops the tone 3 s later and relaunches the killed bundle by its path with `/usr/bin/open` (LaunchServices has `com.adschfr.FineTuneFork` registered at several paths, so `open -b` could start another copy). The relaunched app reads `CatchAllHarnessPendingH9`, clears it and asks at once (a record older than 2 min is reported but not counted): "FineTune wurde um HH:mm:ss.SSS beendet. Wann wurde der Ton hörbar?" ("sofort (unter 1 s)", "später", "gar nicht", "unsicher"). Pass only on "sofort". Otherwise variant B stops here, and the panel tells the user to restart the Mac if TV audio stays silent. The same run logs the system alert device (`kAudioHardwarePropertyDefaultSystemOutputDevice`).

**Listening session** (commit 16, mode on, `CatchAllListening`, live coordinator, TV at about 10 %). It uses the existing panel: each step announced with a countdown and the expected result, coordinator events as `HH:mm:ss.SSS` lines, the answer asked right after the step ("ok", "zu laut", "Lücke", "doppelt/Echo", "Knacken", "anderes").

| Step | Action | Expected |
|---|---|---|
| S0 | plain afplay tone | audible at TV volume; "CA start" line |
| S1 | `osascript -e 'beep'`, panel names the alert device | quiet if the alert device is the TV, otherwise unchanged |
| S2 | 12 s countdown (CA suspends), then a plain tone | not loud; "CA start" with ms (re-measures resume after commit 9) |
| S3 | user starts and stops a MacWhisper dictation | start and stop sounds quiet and complete; IsRunning, CA start and output lines |
| S4 | user starts Music or QuickTime | "covered, no tap"; no gap |
| S5 | session calls `setVolume(app, 0.5)` at the marker | one dip ≤ 200 ms, then half loudness; hold and release lines |
| S6 | back to 100 % | no change; "tap kept" |
| S7 | user presses volume down twice and up twice during a tone | smooth steps |
| S8 | (AirPods present) user switches TV → AirPods → TV during music | one short dropout on the AirPods, never loud; back on the TV no dip. Answers Q1 |
| S9 | session injects R on the TV (session token only) | at most a very short gap, not loud, no echo; music continues at TV volume |
| S10 | nothing playing; user power-cycles the TV, then a tone | not loud; "retired (device gone)" and "built" |

Pass: no "zu laut" or "doppelt/Echo"; dips only in S5, S8 and S9 within the stated bounds; no silence beyond the H7 onset loss elsewhere.

**Live phase** (no commit): a read-only check whether an aggregate or multi-output device containing the TV exists; optionally a few hours in observe with a log review (`/usr/bin/log show --predicate 'subsystem == "com.adschfr.FineTuneFork" AND category BEGINSWITH "CatchAll"'`: "would cover", push and resume latency, output without edge, `.fault`, I1 repairs); the listening session; one week in mode on with the kill switch documented. Results go into `HANDOFF.md`.

### 16.9 Commit plan

Commits 1-7 and the harness are done (`d818f55` … `bef2b82`). Each commit builds, passes `./scripts/test.sh` without a TCC prompt, and leaves behavior unchanged while `CatchAllMode` is `off`.

8. **feat(catchall): H9 kill check.** H9 step and pending record in `CatchAllSettings` and `CatchAllHarness`, excluded from `all`; engine condition at `:369` extended (row 5); ms timestamps and the alert-device line in the panel. Test 9 (H9 parts). **Gate G1** after consent: continue only on "sofort".
9. **feat(catchall): run control for covered IO.** IsRunning rule with listed set, cap and poll; `observeDevices` and `onDevicesChanged`; refresh order and classification cache, with `hasNonPlain` split into aggregate or virtual and unresolvable (`CatchAllRunControl.swift:280-282`); 3 s re-read with the leeway at `:221`; `timerInterval` in the logic; bounded `detach` and `stop`. Test 1. Not wired; the harness (`CatchAllHarness.swift:174, 305`) now uses this logic, so the §15 H7 and §15.1 H7M results predate it.
10. **feat(catchall): per-app tap policy and target hold rule.** `PerAppTapPolicy.swift`, `holds`, margin and cap settings. Tests 2-3.
11. **feat(catchall): coordinator core.** Protocol with `CatchAllClaimOwner`, Noop, live coordinator (phases incl. dormant, `isLive`, `covers`, `CatchAllPlan.ineligibility`, reconcile and reevaluation in one next-turn task, build held until applied, gain, claims, retirement tickets, flush with read-back, generation, waits, I1 checker, C9 settle state, `mayPlay`, `noteDecision`, `noteRouting`, `onEvent`); `FakeCatchAllCoordinator` and a fake claim owner in the test target. Test 4.
12. **feat(catchall): failure handling with fail-open.** R with the deferred destroy, G, E12 (immediate rebuild for a new alive ID, dormant only with a CA, alive listener read once, `deviceListRefreshed`, 2 s check), E rebuild, counting without non-alive failures, breaker, format hooks, `ServiceRestarted` with the tap-UUID check and `onClaimsVoided`, watchdogs, queued retirements. Test 5 (coordinator side, fake owners).
13. **feat(catchall): CatchAllAwareTap decorator.** A-D, hold rule, retirement holds and tickets, `userMuted`/`holdCount`, forwarding; adopts `CatchAllClaimOwner`. Tests 6-7, including the decorator side of R.
14. **feat(engine): wire the coordinator, mode off by default.** Rows 1-12, 18, 21, 23-25, 27-28 (row 9 adds the `rebuildCatchAll` parameter); `AudioDeviceMonitor.onOutputDeviceListRefreshed`; fork functions `catchAllCoverageEnding`, `reevaluateCatchAllCoverage`, `catchAllRunGate`, creation guard, `catchAllDidRegister`; `FakeTapController.onActivate`. Engine tests for wiring, reentrancy and the Noop golden log. Mode on now behaves like variant A; observe is usable.
15. **feat(engine): catch-all first on software outputs.** Rows 13-17, 19-20, 22, 26; the remaining fork functions. Remaining engine tests.
16. **feat(catchall): listening session.** `CatchAllListening.swift` on the existing panel, S0-S10, token-guarded R injection, `onEvent` lines. Test 9 (session parts).
- **Live phase** (§16.8).
17. **docs(fork):** `FORK.md` (catch-all first, the tap rule, ignored apps on the TV, P5, the AirPods dropout and other residuals, the kill switch); fix the `.mutedWhenTapped` comment (`OrphanedTapCleanup.swift:7-9`); flip the `CatchAllMode` default only if the user answers Q5 with yes after the week.

### 16.10 Later (one commit each, only when the trigger occurs)

- **Rule H** (defer AirPods taps until the app's next IO start). Trigger: the S8 dropout bothers the user. Constraints from the review: an entry stores its source UID and is valid only while `covers(source)`; only for hardware-tier targets; cleared on routing to a covered or software device and in `onCoverageWillEnd`; never pruned by `cleanupStaleTaps`; absence from `activeApps` counts as idle.
- **Handover model test** (seeded random). Trigger: first commit after v1.
- **Mode-independent reentrancy guard** (fixes today's double tap in mode off). Trigger: the user wants the fix outside the feature; own test.
- **Panel timeline, level traces, click marks.** Trigger: Q7 answered yes; panel-only commit.
- **Live log panel with "Jetzt war etwas".** Trigger: an incident in the mode-on week that the user cannot time.
- **H2 at n = 200 and a tuned G.** Trigger: a customized app on the TV, or a doubling report.
- **H13** (`say -a` to another device or an aggregate). Trigger: the live-phase check finds an aggregate or multi-output device containing the TV.
- **Settings drift test** with the full field partition. Trigger: the next upstream merge.
- **Row hint for covered apps** (needs an observed coverage counter, since the coordinator's phases are not observed). Trigger: Q3 answered yes.
- **Audio-tab switch.** Trigger: Q5 asks for it.
- **`onOutputTierChanged`.** Trigger: the user uses tier overrides.
- **Session-resign and wake observers.** Trigger: a second user account on the Mac.
- **Poll back-off to 1 s after 10 min.** Trigger: wakeups show up in power measurements.
- **Quiet point, H5 source refresh, device filter, strategy B.** Trigger: dips or power cost the user notices.
- **Prewarm taps for customized apps** (Q4), **hand-back to the CA** (Q6). Trigger: the user's answer.
- **C9 sticky set** (keep a `.playsElsewhere` result per process object across empty reads). Trigger: hand-back to the CA (Q6).

### 16.11 Open questions for the user

- **Q1.** On TV → AirPods during playback, v1 gives each playing app a new tap with a dropout of about 60-100 ms (never loud). Alternative: keep it playing natively until its next stop (rule H). Recommendation: ship v1 without rule H, let the user judge the dropout in S8, add rule H only if it bothers them.
- **Q2.** Should ignored apps on the TV follow the TV volume instead of playing at full scale? Recommendation: yes, documented in `FORK.md`; keeping them at full scale would mean excluding them without a tap, the path this feature removes. Call apps on the TV are already processed today.
- **Q3.** Covered apps show no per-app meter. Recommendation: never the CA level (it mixes in system sounds); a dimmed meter with a hint after v1 if wanted.
- **Q4.** Create taps for customized apps as soon as their process appears? Recommendation: no for v1; the user has none, and prewarming blocks main up to 2 s per app (`ProcessTapController.swift:679`). The residual plays at TV volume, never at full scale.
- **Q5.** After the week in mode on, make the catch-all the default, and add an Audio-tab switch? Recommendation: flip the default in the docs commit; no switch, since the mode is read at launch (`CatchAllSettings.swift:19-22`) and a switch would not roll back faster than the kill switch.
- **Q6.** Apps keep their taps until they quit after a reset, an AirPods session or a TV power cycle during playback. Recommendation: acceptable for v1; a kept tap at defaults sounds like the CA, and hand-back is what made design 2's demotion unsafe.
- **Q7.** Do the listening checks need a graphical timeline, or are the existing panel, ms event lines and categorized answers enough? Recommendation: start with the existing panel and ask before the listening session.

**Answers (2026-10-28).** The user accepted every recommendation above: Q1 v1 without rule H, judged in S8; Q2 yes; Q3 no per-app meter for covered apps in v1; Q4 no prewarming; Q5 default on after the week in mode on, no Audio-tab switch; Q6 taps kept until the app quits; Q7 the existing panel first. Build order as in §16.9, starting with commit 8 (H9). The H9 run itself needs the user's consent at the time.

### 16.12 Corrections from the final check (2026-10-28)

A third read-only review of §16 against the code found the following. Each item names the commit that implements the fix; where it contradicts the text above, this subsection applies.

1. **Run control keyed by UID (fatal, commit 9).** `attach` and `detach(uid)` key handles and logic state by device UID (`CatchAllRunControl.swift:89-106, 175-183`; `CatchAllRunLogic.swift:59-66`). Every make-before-break rebuild E (E12, E15, push or IO failure) attaches C′ under the same UID, and the later `detach(uid)` for C removes C′: the live CA ends up detached and covered audio stays silent. Fix: the run control's unit becomes the handle (aggregate ID). `detach` names the handle and removes only a match, or an atomic `replace(uid, old:, new:)` runs on the queue. A dormant C that is already detached is not detached again. Test: attach A and B for one UID, detach A, B stays attached and running.
2. **Missed process appearance (major, commit 9).** `observed` grows only in `refreshProcessList`, and the safety re-read and the recheck iterate `observed` only (`CatchAllRunControl.swift:136-154, 201-202, 227-230`). A covered app whose appearance was missed never starts a stopped CA. Fix: the re-read and the recheck call `refreshProcessList()` (one list read); `appsChanged` forwards listed process objects and the run control observes any it lacks; on `.serviceRestarted` the source re-registers its system listeners, clears `observed` and refreshes.
3. **Lost CA format rebuild (major, commits 12 and 14).** Row 9 runs `formatChanged` after the in-flight guard (`AudioEngine.swift:2422-2425`), so a rate change that arrives while another format handling for the TV runs never rebuilds the CA, and variant B has no CA rate check. Fix: when the guard returns and `rebuildCatchAll` is true, record the UID and run `formatChanged` from the in-flight call's `defer`. The CA liveness tick rebuilds through E when the aggregate's nominal rate differs from the device rate on two ticks.
4. **Tap UUIDs and targets for claims (major, commits 13 and 14).** Nothing provides `CatchAllClaimOwner.tapUUIDs`; an empty list would keep every stale claim at E20. Add `var liveTapUUIDs: [UUID] { get }` to `ProcessTapControlling` (default `[]`), implemented by `ProcessTapController` from the `tapDescription.uuid` of each valid primary or secondary resource (`ProcessTapController.swift:424, 665`) and by `FakeTapController`. An owner with a non-empty claim and an empty UUID list is voided at E20. Add `var targets: Set<String> { get }` to `CatchAllClaimOwner`; retirement tickets are keyed on it. The forwarding test's requirement count changes.
5. **Absent app that returns silent after R (major, commit 12).** When the deferred-destroy timer fires, call `onCoverageWillEnd(D)` again before destroying; it taps present, untapped, routed apps, silent ones included, without a hold because the kept CA is held. While it returns true, the destroy waits another 30 s.
6. **E20 rebuild trigger (minor, commit 12).** No periodic device-list refresh exists. On `ServiceRestarted` the coordinator requests a re-evaluation at once and, if no list refresh arrived after 1 s, rebuilds with `backend.deviceID(forUID:)` and the UID-keyed persisted gain. `deviceListRefreshed` only schedules into the coordinator's next-turn task and never builds inside `handleDeviceListChanged`.
7. **Phase guards (minor, commit 12).** Every E12 entry point (run-queue failure posts, start failures, `deviceListRefreshed`, the dormant timer, the IsAlive listener) returns early for a retiring device and re-checks after R4. Entering retiring from dormant removes the alive listener and stops the 2 s check. Flush and the I1 checker skip dormant and retiring CAs; a push failure on a dormant CA is not acted on.
8. **C9 when output starts with an empty Devices list (minor, commits 9 and 11).** The run queue posts IsRunningOutput together with the Devices classification, deduplicated on the pair, and the 500 ms settle timer starts when either value changes.
9. **Commit boundaries and test seams (minor).** Retirement tickets, the dormant waiter rule and their test-4 assertions move to commit 12 and test 5. The coordinator's injected environment gains `isAlive(AudioDeviceID)`, `observeAlive(AudioDeviceID, handler) -> token` and `tapExists(UUID) -> Bool`. Engine wiring tests use an unstarted `AudioDeviceMonitor()` to reach rows 9, 10, 27 and 28. `enum CatchAllEvent: Sendable` is declared in `CatchAllCoordinator.swift` (commit 11).
