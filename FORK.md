# FineTune Fork

A maintained fork of [ronitsingh10/FineTune](https://github.com/ronitsingh10/FineTune) based on v1.9.0.
It installs as **FineTune Fork** (`com.adschfr.FineTuneFork`) next to upstream FineTune and shares its
settings in `~/Library/Application Support/FineTune`. Run only one of the two at a time.

## Build and install

```bash
./scripts/install-fork.sh
```

Builds an ad-hoc signed Release (hardened runtime off, so the embedded Sparkle framework loads),
installs it to `/Applications/FineTune Fork.app` and launches it. Requires Xcode. Sparkle updates are
disabled, so the fork never replaces itself with an upstream release.

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
- **No full volume on a software-volume display after it powers back on** (#375).
- **Other macOS users keep their sound** while FineTune runs in one session (#418).
- **System Settings panes are not listed as apps** (#427).
- Call passthrough (#413) is not applied on outputs without hardware volume, where an untapped call
  would play at full scale.

## Upstream pull requests merged

#409 prewarm/streaming detection, #339 AutoEQ for built-in audio, #344 DDC toggle, #347 and parts of
#412 HUD over fullscreen apps, #388 short sounds no longer faded, #406 and #445 HUD/URL/DDC fixes,
#407 percentage commit on click-away, #408 NaN safety net, #410 ISO 226 formula, #423 loudness
headroom, #478 AirPlay selection, #479 nested helper apps and one-channel audio, #446 dropdowns stay
on screen, #314 follow-default routing on reconnect, #413 call passthrough, #396 output format
changes, #383 option to hide the HUD, #438 paired Bluetooth outputs, #473 Bluetooth input guard,
and from #412 the menu bar panel position fix and auto-switch to newly connected outputs.
