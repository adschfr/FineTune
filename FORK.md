# FineTune Fork

A maintained fork of [ronitsingh10/FineTune](https://github.com/ronitsingh10/FineTune) based on v1.9.0,
maintained by [adschfr](https://github.com/adschfr) since 2026-10-21. It installs as **FineTune Fork** (`com.adschfr.FineTuneFork`) next to upstream FineTune and shares its
settings in `~/Library/Application Support/FineTune`. Run only one of the two at a time.

## Build and install

```bash
./scripts/install-fork.sh
```

Builds a Release, installs it to `/Applications/FineTune Fork.app` and launches it. Requires Xcode.
With an Apple Development certificate in the keychain (a free Personal Team in Xcode is enough) the
app is signed with it, so macOS keeps its audio capture permission across builds. Without one it is
signed ad hoc, and the permission has to be granted again after every build. Hardened runtime stays
off, so the embedded Sparkle framework loads. Sparkle updates are disabled, so the fork never
replaces itself with an upstream release.

```bash
./scripts/test.sh
```

Runs the unit tests with their own DerivedData in `build/test`. Debug builds use the bundle ID
`com.adschfr.FineTuneFork.dev`, and the test host starts a minimal app (`AppEntry.swift`) instead of
FineTune, so a test run does not create taps, request permissions or touch the installed fork.

## Fixes in this fork

- **No full-volume blast when playback starts** (#170, #268, #273, #455). Taps use `CATapMuted`, so
  audio that starts before the IO proc runs is held back instead of playing unprocessed. Taps of silent
  apps are kept and their IO proc is stopped after 10 s, then restarted when the app plays again,
  instead of being rebuilt from scratch.
- **Mac can sleep while nothing plays** (#465). Suspended taps do not hold the output device running.
- **New helper processes are covered** (#248, #373). When an app starts another audio process
  (a new browser tab, `afplay` in a terminal, Spotify video), the existing tap is updated in place.
- **Promoted tap no longer stays silent after a device switch** (#461).
- **Suspended taps resume within milliseconds.** On macOS 27.2 a running process posts no IsRunning
  change when it starts output, so the monitor also listens to its output-scope Devices list.
- **Short output dropouts no longer strand apps on the fallback.** Device-switch passes run one at a
  time and read the routing per tap when they reach it.
- **An output whose display is switched off counts as disconnected.** A display disabled in macOS keeps
  its audio device in Core Audio and stays the default output. FineTune matches the audio device to the
  online screens and falls back along the priority list until the screen returns. Fails open: unknown UID
  formats, screens never seen online, sleeping screens and short gaps change nothing.
- **Paired Bluetooth outputs stay listed when their cached service records are missing**, as after a
  restart. The Class of Device decides first, without a lookup; the records are only asked for a device
  whose class does not say audio output. The problem was found in the 2026-11-04 follow-up to #438.
- **System sounds keep following the default across a dropout.**
- **No full volume on a software-volume display after it powers back on** (#375).
- **Other macOS users keep their sound** while FineTune runs in one session (#418).
- **System Settings panes are not listed as apps** (#427).
- Call passthrough (#413) is not applied on outputs without hardware volume, where an untapped call
  would play at full scale.

## Parked: catch-all tap

FineTune taps each app on its own. Sound from anything without a tap (the first moment of a new app,
ignored apps, a tap that failed) reaches an output without a volume control at full level. The catch-all
was meant to close that gap with one extra tap per such output that holds back everything else.

It reached about 7,000 lines of app code plus tests and ran only in tests, never in a release.
Development was paused in November 2026: the remaining work was large, the benefit was limited to rare
moments, and a tap that holds back other apps' audio can itself cause silence or doubled sound when
something goes wrong. The code, its tests and the design notes are kept on the branch
[`park/catch-all`](https://github.com/adschfr/FineTune/tree/park/catch-all).

## Upstream pull requests merged

#409 prewarm/streaming detection, #339 AutoEQ for built-in audio, #344 DDC toggle, #347 and parts of
#412 HUD over fullscreen apps, #388 short sounds no longer faded, #406 and #445 HUD/URL/DDC fixes,
#407 percentage commit on click-away, #408 NaN safety net, #410 ISO 226 formula, #423 loudness
headroom, #478 AirPlay selection, #479 nested helper apps and one-channel audio, #446 dropdowns stay
on screen, #314 follow-default routing on reconnect, #413 call passthrough, #396 output format
changes, #383 option to hide the HUD, #438 paired Bluetooth outputs, #473 Bluetooth input guard,
and from #412 the menu bar panel position fix and auto-switch to newly connected outputs.

## Credits, license and support

FineTune was created by [Ronit Singh](https://github.com/ronitsingh10/FineTune) and is licensed under
the GNU General Public License v3 ([LICENSE](LICENSE)). This fork modifies it: changes by adschfr since
2026-10-21, each one dated in the git history. The fork is released under the same license, and the
original copyright notices stay in place.

If the fork helps you, you can support its maintenance on [Ko-fi](https://ko-fi.com/adschfr). To support
the original app, see [ronitsingh10/FineTune](https://github.com/ronitsingh10/FineTune).
