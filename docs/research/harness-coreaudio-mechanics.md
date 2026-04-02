# FineTuneHarness: CoreAudio Process Tap Mechanics

> **Section**: Audio Engine & CoreAudio Mechanics
> **Author**: @audio-engineer
> **Task**: TASK-004
> **Date**: 2026-04-02

---

## 1. Architecture Overview

The FineTuneHarness is a standalone macOS app bundle (`com.finetuneapp.FineTuneHarness`) that
systematically tests CoreAudio process tap configurations by sweeping a 12-element matrix of
`stacked x muteMode x isPrivate` combinations. It produces a quantified report of which
configurations cause recording doubling (audio captured twice by ScreenCaptureKit when a
process tap is active).

### 1.1 File Responsibilities

| File | Lines | Purpose |
|------|-------|---------|
| `main.swift` | 647 | Entry point, argument parsing, sweep orchestration, NSApplication lifecycle |
| `TapBuilder.swift` | 616 | Process tap creation (stream-specific, stereo mixdown, global), aggregate device creation, device readiness, cleanup |
| `IOProcCapture.swift` | 337 | IO proc installation with RT-safe capture buffer, diagnostic counters for buffer layout debugging |
| `AudioAnalysis.swift` | 172 | vDSP-based peak/RMS measurement, SCK-vs-IOProc amplitude ratio verdict (PASS/DOUBLED/NO_SIGNAL/ERROR) |
| `AudioSource.swift` | 146 | 1kHz sine WAV generation (16-bit mono, 48kHz), afplay process management, audio process discovery |
| `SCKCapture.swift` | 120 | ScreenCaptureKit system audio capture — the "recording app perspective" |
| `HarnessConfig.swift` | 54 | Sweep matrix configuration (stacked, muteMode, isPrivate), `CATapMuteBehavior` mapping |
| `HarnessLogger.swift` | 41 | Dual-output logging (stdout + `/tmp/finetune_harness.log`), verbose mode |
| `Info.plist` | 24 | App bundle identity, `LSUIElement` (agent app), microphone usage descriptions |
| `FineTuneHarness.entitlements` | 8 | `com.apple.security.device.audio-input` entitlement |

### 1.2 Execution Flow

```
main.swift: NSApplication.run()
  └─ HarnessAppDelegate.applicationDidFinishLaunching()
       └─ runHarness()
            ├─ Arguments.parse()
            ├─ HarnessConfig.sweepMatrix() → 12 configs
            └─ runSweep(configs:captureDuration:)
                 ├─ Pre-flight: afplay exists, SCK permission, microphone permission
                 ├─ TapBuilder.readDefaultOutputDevice()
                 ├─ AudioSource.generateToneWAV(1kHz, 0.5 amplitude)
                 └─ for each config:
                      └─ runSingleConfig()
                           ├─ [1] AudioSource.spawnAfplay() → PID
                           ├─ [2] AudioSource.waitForAfplayAudioProcess() → AudioObjectID
                           ├─ [3] TapBuilder.createStreamSpecificTap() or .createProcessTap()
                           ├─ [4] TapBuilder.readTapUID() → verify UUID
                           ├─ [5] TapBuilder.buildAggregateDescription() + createAggregateDevice()
                           ├─ [6] TapBuilder.waitUntilReady()
                           ├─ [7] IOProcCapture.installIOProc() → unity-gain callback
                           ├─ [8] SCKCapture.startCapture()
                           ├─ [9] AudioDeviceStart()
                           ├─ [10] Sleep for captureDuration
                           ├─ [11] Stop IO proc + SCK
                           └─ [12] AudioAnalysis.evaluate() → TestResult(verdict)
```

### 1.3 Why NSApplication?

The harness requires `NSApplication.run()` (main.swift:644-647) rather than being a pure CLI
tool. This is necessary because:
- ScreenCaptureKit's permission prompt requires an app bundle with a proper `Info.plist`
- `CFRunLoopRunInMode` (used in `waitUntilReady`) requires the main run loop to be running
  for HAL event processing
- AVCaptureDevice microphone permission flow requires a running application

The `LSUIElement = true` in Info.plist makes it an agent app (no dock icon, no menu bar).

---

## 2. CoreAudio Process Tap Mechanics Tested

### 2.1 Sweep Matrix — 12 Configurations

The harness tests every combination of three binary/ternary dimensions:

| Dimension | Values | What it controls |
|-----------|--------|------------------|
| **stacked** | `true`, `false` | `kAudioAggregateDeviceIsStackedKey` — whether all sub-devices receive the same audio mix |
| **muteMode** | `mutedWhenTapped`, `muted`, `unmuted` | `CATapMuteBehavior` — whether the tapped process's audio reaches the physical output |
| **isPrivate** | `true`, `false` | `kAudioAggregateDeviceIsPrivateKey` — whether the aggregate is visible to the system |

This produces 2 × 3 × 2 = 12 configurations (HarnessConfig.swift:38-53).

### 2.2 Tap Creation Strategies

The harness implements three tap creation strategies (TapBuilder.swift:27-97):

#### 2.2.1 Stream-Specific Tap (Primary Path)

```swift
CATapDescription(processes: processObjectIDs, deviceUID: deviceUID, stream: streamIndex)
```

This is the production-preferred path. It targets a specific output stream on a specific device,
preserving the native channel layout (e.g., 7.1 surround). The stream index is resolved by
enumerating the device's **global** stream list and finding the first stream with
`kAudioStreamPropertyDirection == 0` (output) — see `firstOutputStreamIndex()` at
TapBuilder.swift:138-187.

**Critical implementation detail**: `CATapDescription(processes:deviceUID:stream:)` expects a
**global** stream index, not an output-scope-only index. This is undocumented by Apple. The
harness and production code both handle this correctly by reading
`kAudioDevicePropertyStreams` with `kAudioObjectPropertyScopeGlobal` and checking each
stream's direction property.

#### 2.2.2 Stereo Mixdown Tap (Fallback Path)

```swift
CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
```

Falls back when stream-specific creation fails (TapBuilder.swift:57-75). Forces a 2-channel
stereo mix regardless of the device's native format. No device UID is specified — the tap
captures from whatever output the process is using.

#### 2.2.3 Global Tap (Diagnostic Only)

```swift
CATapDescription(stereoGlobalTapButExcludeProcesses: excludeProcessObjectIDs)
```

Captures all system audio except specified processes (TapBuilder.swift:79-97). Not used in the
sweep matrix — present for diagnostic investigation when per-process taps return silence.

### 2.3 Mute Behavior Semantics

The three `CATapMuteBehavior` values control whether the tapped process's audio still reaches
the physical output device:

| Value | Effect | User Experience |
|-------|--------|-----------------|
| `.mutedWhenTapped` | Audio is removed from the device mix while the tap is active | Silent on speakers — audio only via the tap's IO proc output |
| `.muted` | Audio is always muted regardless of tap state | Permanently silent on speakers |
| `.unmuted` | Audio plays normally on the device AND is available via the tap | Audio doubles: speakers + IO proc output both play |

**Production uses `.mutedWhenTapped` exclusively** (ProcessTapController.swift:318,337).
The harness tests all three to validate that `.mutedWhenTapped` prevents recording doubling
while `.unmuted` causes it — confirming the production choice is correct.

### 2.4 Private vs Non-Private Aggregates

**Private aggregates** (`kAudioAggregateDeviceIsPrivateKey = true`):
- Invisible to the system device list
- Cannot become the default output device
- No routing disruption to other apps
- Production always uses private (ProcessTapController.swift:259)

**Non-private aggregates** (`kAudioAggregateDeviceIsPrivateKey = false`):
- Visible as a system audio device
- macOS may auto-switch the default output to it
- Disrupts afplay's routing (audio goes to aggregate instead of original device)

The harness explicitly handles the non-private disruption with save/restore of the default
output device (main.swift:200,415-418). This is a critical workaround: without it, creating a
non-private aggregate causes afplay to route directly to it, bypassing the process tap entirely
and producing silence in the IO proc capture.

### 2.5 Stacked vs Non-Stacked Aggregates

**Stacked** (`kAudioAggregateDeviceIsStackedKey = true`):
- All sub-devices receive the same audio mix
- The aggregate's output buffer count equals a single device's channel count
- Input buffer layout: `[extra_inputs...] [mapped_tap_buffers]` — the last N input buffers
  correspond to the N output buffers
- Production always uses stacked (ProcessTapController.swift:260)

**Non-stacked**:
- Sub-devices receive different audio streams (for multi-device output)
- Input/output buffer counts may differ in unexpected ways

The buffer mapping logic is identical in harness and production:
```swift
if inputBufferCount > outputBufferCount {
    inputIndex = inputBufferCount - outputBufferCount + outputIndex
}
```
(IOProcCapture.swift:271-281 vs ProcessTapController.swift:1006-1007)

### 2.6 Tap UID Verification

The harness discovered and validates a CoreAudio behavior: the actual UID assigned to a tap
object by `AudioHardwareCreateProcessTap` may differ from the UUID set on `CATapDescription`
before creation (main.swift:380-397). The harness reads back `kAudioTapPropertyUID` and uses
the actual UID for aggregate device construction. This is defensive coding against an
undocumented HAL behavior where the tap UID is reassigned.

Production does **not** perform this verification — it trusts `tapDescription.uuid`. This is a
discrepancy worth investigating (see Section 6.1).

---

## 3. Signal Chain Analysis

### 3.1 Harness Signal Chain

```
AudioSource.generateToneWAV()           1kHz sine, 0.5 amplitude, 48kHz, 16-bit mono
        │
        ▼
afplay (/usr/bin/afplay)                macOS system player, uses CoreAudio default output
        │
        ▼
CoreAudio HAL                           Routes audio to default output device
        │
        ├──► Physical output            Speakers/headphones (muted if mutedWhenTapped)
        │
        └──► Process Tap                Intercepts process audio
              │
              ▼
        Aggregate Device                Combines output device + tap as input sub-device
              │
              ├──► IO Proc (input)      Unity-gain capture → CaptureRingBuffer
              │
              └──► IO Proc (output)     Pass-through copy (input → output, memcpy)
                      │
                      ▼
              Physical output           Audio reaches speakers via aggregate's output sub-device
```

Simultaneously:
```
ScreenCaptureKit                        Captures system audio mix (what a recording app sees)
        │
        ▼
SCKCapture.stream(_:didOutputSampleBuffer:)  Writes to separate CaptureRingBuffer
```

After capture completes, `AudioAnalysis.evaluate()` compares IO proc peak vs SCK peak.
A ratio ≥ 1.5 means the SCK capture saw approximately double the amplitude — indicating
the audio appeared twice in the system mix (once from original output, once from the
aggregate's output).

### 3.2 Production Signal Chain

```
App (e.g., Spotify)                     Audio-producing process
        │
        ▼
CoreAudio HAL
        │
        └──► Process Tap (mutedWhenTapped)
              │
              ▼
        Aggregate Device (private, stacked)
              │
              ├──► IO Proc (input)      Volume ramp → EQ → AutoEQ → SoftLimiter
              │
              └──► IO Proc (output)     Processed audio to speakers
```

### 3.3 Key Differences

| Aspect | Harness | Production |
|--------|---------|------------|
| **Processing** | Unity-gain (memcpy) | Volume ramp, 10-band EQ, AutoEQ, SoftLimiter |
| **Channel mapping** | None — direct buffer copy | PreferredStereoChannels, 2→N upmix, N→2 downmix |
| **Crossfade** | None | Dual IO proc with equal-power crossfade |
| **Peak metering** | Running max across all callbacks | Smoothed exponential decay for VU meter |
| **Mute behavior** | Tests all three modes | `.mutedWhenTapped` only |
| **Private** | Tests both | Always private |
| **Stacked** | Tests both | Always stacked |
| **Tap UID** | Verified against HAL | Trusted from description |
| **Health monitoring** | Callback count + first-non-zero tracking | `_lastRenderHostTime` health check |
| **Buffer diagnostics** | Delayed snapshot (callback #100) | None |

---

## 4. Improvements to Existing Capabilities

### 4.1 Bugs and Limitations

#### 4.1.1 CaptureRingBuffer is Not Actually a Ring Buffer

Despite the name, `CaptureRingBuffer` (IOProcCapture.swift:11-55) is a linear buffer that
stops writing when full. It has no wrap-around logic — `writeIndex` is only incremented, never
wrapped to 0. This means captures longer than the buffer capacity silently lose audio from the
end of the capture window. The buffer is sized for `48000 * 2 * (captureDuration + 2.0)`
samples (main.swift:506), which provides headroom, but the naming is misleading and the
behavior is fragile if sample rates exceed 48kHz (e.g., 96kHz devices would overflow halfway
through the capture).

**Fix**: Either rename to `CaptureLinearBuffer` or implement true ring semantics with atomic
read/write indices.

#### 4.1.2 Hardcoded 48kHz Assumption

The buffer capacity calculation (main.swift:506) and the SCK configuration
(SCKCapture.swift:60) both hardcode 48kHz. The harness reads and logs the actual device sample
rate (main.swift:456-462) but never uses it for buffer sizing. If the default output device
runs at 96kHz or 192kHz, the IO proc capture buffer will be half or quarter capacity.

**Fix**: Query the aggregate device's actual sample rate after creation and size the buffer
accordingly.

#### 4.1.3 Thread.sleep in Audio Process Discovery

`AudioSource.waitForAfplayAudioProcess()` (AudioSource.swift:77-85) polls with
`Thread.sleep(forTimeInterval: 0.1)` on what appears to be the main thread. While this works
in practice because the NSApplication run loop continues processing events, it blocks the
calling async context unnecessarily. The harness also uses `Thread.sleep(forTimeInterval: 1.0)`
(main.swift:235) to wait for afplay to start producing audio — a fixed delay with no
verification.

**Fix**: Use `Task.sleep` for async-friendly waiting. Validate afplay is actually producing
audio by checking `kAudioProcessPropertyIsRunning` in a poll loop rather than a fixed 1s delay.

#### 4.1.4 Diagnostic Peak Scan Uses Fixed Tuple Instead of Array

IOProcCapture.swift:72-82 uses tuples of 8 elements for diagnostic storage:
```swift
private nonisolated(unsafe) static var _diagInputPeaks: (Float, Float, ...) = (0,0,0,0,0,0,0,0)
```

This is RT-safe (no allocation), but the switch-case assignment at lines 192-221 is verbose
and error-prone. A pre-allocated `UnsafeMutablePointer<Float>` with capacity 8 would be
equally RT-safe, more readable, and indexable.

#### 4.1.5 No Cleanup on Signal/Crash

Unlike production (which has `CrashGuard.swift` for signal-safe aggregate cleanup), the
harness has no signal handler. If the harness is interrupted (Ctrl+C, kill), aggregate devices
and process taps are leaked. This can leave orphaned aggregates in the system until reboot.

**Fix**: Install a `SIGINT`/`SIGTERM` handler that calls `TapBuilder.cleanup()` on the current
resources, similar to production's CrashGuard approach.

### 4.2 Missing Error Handling

#### 4.2.1 SCK Permission Failure is Silent for Analysis

When SCK permission is denied, the harness proceeds with IO proc only (main.swift:99-105).
The analysis then receives empty SCK samples, producing `ratio = 0` which maps to `NO_SIGNAL`
only if IO proc peak is also < 0.01. If IO proc peak is valid but SCK is empty, the ratio
becomes `0 / ioPeak = 0`, which is `< 1.5`, producing a `PASS` verdict — a false positive.
The doubling check is meaningless without SCK data.

**Fix**: `AudioAnalysis.evaluate()` should return a distinct verdict (e.g., `.sckUnavailable`)
when SCK samples are empty but IO proc samples are valid.

#### 4.2.2 No Timeout on afplay Audio Output

The harness waits up to 5s for afplay to appear in the audio process list
(AudioSource.swift:76), then waits a fixed 1s for audio to start (main.swift:235). If afplay
starts slowly (e.g., resource contention on loaded machine), the capture window may begin
before audio is flowing, producing NO_SIGNAL results that are timing artifacts rather than
real tap failures.

### 4.3 Incomplete Test Scenarios

#### 4.3.1 Only Single-Process Taps

The harness always creates a tap for a single process (`[afplayAudioObjectID]`). FineTune
creates taps for arbitrary process lists (one per app). Multi-process taps may have different
buffer layout or channel count behaviors that are untested.

#### 4.3.2 No Multi-Tap Interference Testing

The harness runs one tap at a time, cleaning up between configs. Production runs many taps
concurrently (one per audio-producing app). Concurrent tap creation, the order of aggregate
device creation, and potential resource contention between taps are all untested.

#### 4.3.3 No Device Switch During Capture

The harness uses a static device throughout the sweep. Production performs crossfade device
switches while audio is flowing. The harness cannot validate that tap resources survive a
device change or that the transition is glitch-free.

---

## 5. New Research Directions

### 5.1 Aggregate Device Lifecycle Stress Testing

**What**: Create and destroy aggregate devices in rapid succession (< 100ms between cycles).
Measure how often `AudioHardwareCreateAggregateDevice` fails and what error codes appear.

**Why**: Production creates aggregates on app launch and destroys them when apps stop audio.
Fast app switching (Cmd+Tab between Spotify and a game) can trigger rapid create/destroy cycles.
The 2s inter-config pause in the harness (main.swift:166-171) was added because 1s was
insufficient — this suggests HAL cleanup is non-trivial and timing-sensitive.

**How**: New sweep dimension: inter-cycle delay from 0ms to 2000ms in 100ms steps. Record
success/failure rate and `OSStatus` codes.

### 5.2 Sample Rate Switching Under Tap

**What**: Change the output device's sample rate while a process tap is active. Monitor
whether the IO proc callback receives correctly resampled data or garbage.

**Why**: Bluetooth profile switches (A2DP at 44.1kHz ↔ HFP at 8kHz) change sample rate
mid-stream. HDMI devices may also switch when display goes to sleep.

**How**: Create tap on a device, start IO proc, then use
`AudioObjectSetPropertyData` with `kAudioDevicePropertyNominalSampleRate` to change rate.
Capture audio before and after, compare for discontinuity.

### 5.3 Bluetooth Profile Transition Testing

**What**: Force a Bluetooth profile switch (A2DP → HFP → A2DP) while a tap is active.

**Why**: Profile switches change the device UID, channel count, and sample rate simultaneously.
Production must detect this and recreate the tap. The harness could validate that the old tap
fails gracefully and the new tap captures correctly.

**How**: Use `blueutil` or IOBluetooth APIs to force profile switch. Monitor tap status via
`kAudioTapPropertyFormat` and `kAudioDevicePropertyDeviceIsAlive`.

### 5.4 Multi-Tap Interference and Resource Limits

**What**: Create N taps simultaneously for N different processes, each with their own aggregate
device. Measure at what N the HAL starts failing or returning degraded audio.

**Why**: Power users may have 10+ audio-producing apps. We don't know the HAL's resource
limits for concurrent process taps.

**How**: Spawn N instances of afplay, create N taps, run all IO procs concurrently. Measure
per-tap peak levels and callback timing (should be consistent across taps). Increase N until
failures appear.

### 5.5 Latency Measurement

**What**: Measure the end-to-end latency from when afplay sends audio to when the IO proc
receives it via the tap.

**Why**: Latency affects the quality of EQ processing and crossfade timing. If tap latency
varies by device type (USB vs Bluetooth vs Built-in), production may need device-type-specific
warmup periods.

**How**: Generate a click/impulse at a known time. Record `mach_absolute_time()` when the IO
proc first sees the impulse. Compare to the expected arrival time based on buffer size.

### 5.6 Coefficient Stability Validation

**What**: Feed known test signals (white noise, swept sine) through the harness with EQ
processing enabled. Verify output matches expected frequency response.

**Why**: Biquad coefficients that produce poles near or outside the unit circle cause
exponentially growing output. This is currently validated only by code inspection
(BiquadMath.swift). The harness could provide empirical validation.

**How**: Add an optional EQ processing stage to the IO proc callback (replacing unity-gain).
Feed known signals, capture output, perform FFT analysis to verify frequency response.

### 5.7 Volume Ramp Verification

**What**: Verify that the exponential volume ramp produces smooth transitions without audible
artifacts. Test with step changes from 0→1, 1→0, and 0.5→0.5 (no change).

**Why**: The production ramp coefficient (`rampCoefficient`) determines how quickly volume
changes take effect. If it's too aggressive, it produces audible clicks. Too slow, and volume
changes feel laggy.

**How**: Set up tap with known volume, change volume mid-capture, analyze the captured waveform
for discontinuities (derivative exceeding a threshold). Test with various ramp coefficients.

### 5.8 Hot-Plug Resilience Testing

**What**: Disconnect the output device (USB unplug, Bluetooth power off) while the tap is
active. Verify the harness (and by extension production) handles `kAudioHardwareBadObjectError`
without crashing.

**Why**: USB disconnect mid-stream is a real user scenario. Production handles this in
`AudioEngine`'s device change listener, but the cleanup path during an active IO proc callback
has never been tested empirically.

**How**: Use a USB audio device. Start tap, start IO proc, physically unplug. Verify: no
crash, IO proc stops receiving callbacks, aggregate device reports not alive, cleanup succeeds.

---

## 6. Production Implications

### 6.1 Tap UID Mismatch — Unverified in Production

The harness reads back `kAudioTapPropertyUID` after tap creation and compares it to the UUID
set on `CATapDescription` (main.swift:380-397). It logs a warning if they differ and uses the
actual UID for aggregate construction.

**Production does not perform this check.** `ProcessTapController.createProcessTap()` creates
the tap description, sets a UUID, calls `AudioHardwareCreateProcessTap`, and then passes
`tapDescription.uuid` directly to `buildAggregateDescription()`. If CoreAudio ever assigns a
different UID, the aggregate would reference a non-existent tap, likely producing silence.

**Risk level**: Low — the harness log comment says "may differ" but it's unclear if this was
ever actually observed. The check is defensive. However, adding a `readTapUID` verification
in production is cheap and eliminates an undocumented failure mode.

### 6.2 Buffer Layout Diagnostics — Missing in Production

The harness's delayed diagnostic snapshot (IOProcCapture.swift:182-260) captures buffer counts,
byte sizes, channel counts, and peak amplitudes at callback #100. This was clearly essential
during debugging — the comment at line 181 says "allow tap routing to fully settle."

**Production has no equivalent.** If a user reports silence or distortion, there's no
diagnostic data about what the HAL is actually delivering to the IO proc. Adding a one-shot
diagnostic log (first callback, or on demand) to `ProcessTapController.processAudioCallback`
would be valuable for debugging, provided it only fires once (to avoid RT-safety violations).

**Caveat**: Any logging in the callback must be restricted to a single atomic flag check, with
the actual log happening asynchronously. The harness's approach of writing to pre-allocated
`nonisolated(unsafe)` storage and reading from the main thread after capture is the correct
pattern.

### 6.3 Device Readiness — CFRunLoopRunInMode vs Thread.sleep

The harness's `waitUntilReady()` (TapBuilder.swift:259-306) uses `CFRunLoopRunInMode(.defaultMode, 0.01, false)`
to poll for device readiness. The comment at lines 257-258 explicitly warns:

> "Thread.sleep does NOT process HAL events and causes race conditions."

This is a significant finding. If production's aggregate device readiness check uses
`Thread.sleep` or `Task.sleep` instead of `CFRunLoopRunInMode`, it may be vulnerable to the
same race condition the harness discovered.

**Production should verify** that its aggregate device initialization path processes HAL events
while waiting for the device to become alive.

### 6.4 Non-Private Aggregate Default Device Hijacking

The harness discovered that creating a non-private aggregate can cause macOS to auto-switch the
default output device to the aggregate (main.swift:197-201). This disrupts audio routing for
all apps, not just the tapped process.

**Production always uses private aggregates**, so this is not a current issue. But it's
important institutional knowledge: if FineTune ever needs non-private aggregates (e.g., for a
virtual device feature), the default device must be saved and restored.

### 6.5 2s Cleanup Delay Between Taps

The harness needed to increase the inter-config pause from 1s to 2s (main.swift:166-171)
because aggregate device teardown and process tap cleanup need time for the HAL to fully
release resources. This has implications for production:

- Rapid app switching (Spotify stops → browser starts audio) creates a destroy-then-create
  cycle for the tap. If destruction hasn't fully completed when the new tap is created, the
  new aggregate may fail.
- Production uses `TapResources.destroyAsync()` which dispatches cleanup to a background
  queue. The async path may create new taps before old ones are fully destroyed.

**Recommendation**: Production should track whether a previous destroy is still in flight and
delay new tap creation if so, or add a verification step after aggregate creation to confirm
the new device is alive.

### 6.6 Recording Doubling — The Core Finding

The harness's primary purpose is to validate that FineTune's tap configuration does **not**
cause recording doubling. The expected results:

| Config | Expected Verdict | Rationale |
|--------|-----------------|-----------|
| stacked=T, mute=mutedWhenTapped, priv=T | **PASS** | Production config — audio removed from device mix |
| stacked=T, mute=unmuted, priv=T | **DOUBLED** | Audio plays on both device and aggregate output |
| stacked=T, mute=muted, priv=T | **PASS** | Audio never reaches device, only via tap |
| Any, mute=unmuted, priv=F | **DOUBLED** (or **NO_SIGNAL**) | Non-private + unmuted = worst case |

The harness confirms that production's choice of `mutedWhenTapped + private + stacked` is the
correct combination to prevent recording doubling while still allowing the user to hear audio.

### 6.7 Missing Production Test: What If mutedWhenTapped Fails?

The harness tests what happens when the mute mode is wrong, but doesn't test the failure mode
where `.mutedWhenTapped` is specified but CoreAudio doesn't honor it. This could happen with:
- Older macOS versions with different mute behavior semantics
- Third-party audio drivers that don't implement mute correctly
- Edge cases during device transitions

Production should have a fallback or detection mechanism: if a recording app (SCK) captures
doubled audio while FineTune is active, that's a bug in CoreAudio's mute behavior, not in
FineTune. But FineTune gets blamed. The harness could be extended to run as a periodic health
check on user systems.

---

## 7. Summary Table — Harness Findings and Production Actions

| Finding | Section | Production Impact | Recommended Action |
|---------|---------|-------------------|--------------------|
| Tap UID may differ from description UUID | 6.1 | Silent aggregate failure | Add `readTapUID` verification |
| Buffer layout diagnostics essential for debugging | 6.2 | No diagnostics on user reports | Add one-shot diagnostic to callback |
| `CFRunLoopRunInMode` required for device readiness | 6.3 | Potential race condition | Verify production readiness path |
| Non-private aggregates hijack default device | 6.4 | Currently mitigated (private only) | Document as institutional knowledge |
| 2s HAL cleanup needed between tap cycles | 6.5 | Rapid app switch may fail | Gate new taps on previous destroy completion |
| `mutedWhenTapped + private + stacked` prevents doubling | 6.6 | Production config validated | No change needed |
| Recording doubling detection missing in production | 6.7 | Blamed for CoreAudio bugs | Consider periodic self-check |
| 48kHz hardcoded in buffer sizing | 4.1.2 | N/A (harness only) | Fix in harness |
| No signal handler for crash cleanup | 4.1.5 | N/A (harness only) | Add SIGINT handler |
| SCK unavailable produces false PASS | 4.2.1 | N/A (harness only) | Add `.sckUnavailable` verdict |
