# Changelog

FineTune Fork versions follow YEAR.MONTH.N: the year and month of the release, then a running number within that month starting at 0. The current version is in [VERSION](VERSION). The first fork release was 1.9.0-fork.1, based on FineTune 1.9.0 by Ronit Singh.

## Unreleased

### Added

- **A TV or monitor whose screen is switched off no longer keeps the sound.** When a display is disabled in macOS while its cable stays plugged in, macOS still offers it as an audio output and keeps it as the default. FineTune now treats that output as disconnected after 3 seconds: apps move to the next device in your priority list, and they move back when the screen returns. Nothing is hidden while the screens sleep. Turn it off under Settings → Audio → **Disconnect Outputs of Switched-Off Displays** if you use a display for sound only. A display that is merely set to another input is still seen as on.

### Fixed

- **Paired Bluetooth headphones stay in the list after a restart.** macOS can forget what a disconnected device offers until it has connected once, and FineTune then left it out of **Paired**. FineTune now reads the device class that is stored with the pairing. Bluetooth speakers get a speaker icon instead of headphones.
- The notes under **Headphones as output only** in Settings → Audio are laid out like the rest of the row, and the status line only shows while the option is on.

### Changed

- The unfinished catch-all tap was removed from the code. It was never active in a release.

## 2026.11.0 (2026-11-08)

### Fixed

- **Sound starts at once when an app plays again.** After 10 seconds of silence FineTune pauses an app's tap and wakes it when the app plays again. On macOS 27.2 the signal FineTune waited for never arrives for an app that is already running, such as Firefox, so sound started up to 10 seconds late, or only after a volume key press. FineTune now also listens to a signal that arrives within milliseconds.
- **A short output dropout no longer leaves apps on the wrong device.** When a TV or monitor drops off HDMI for a moment, FineTune moves the apps to the fallback output and back. If the display came back while apps were still being moved, some stayed on the fallback, for example the MacBook speakers, while FineTune showed the display as the output. Moves now run one after another and always go to the latest target.
- **System sounds keep following the default output across a dropout.** FineTune took macOS moving system sounds during a dropout for a user choice and turned "follow default" off for good, so alerts stayed on the MacBook speakers. If this happened to you, pick **System Audio** (follows the macOS default) for **System Sounds** in Settings → Audio once.
- Tap and device events are kept in the system log, so a reported problem can be traced afterwards.

### Changed

- Version numbers follow YEAR.MONTH.N.

### Known issues

- **Sound on Bluetooth headphones sometimes starts only after a volume key press.** Seen once after AirPods reconnected; the cause is not found yet. If it happens to you, note the time and [open an issue](https://github.com/adschfr/FineTune/issues). FineTune now keeps the events needed to trace it.
- **Screen recordings with system audio contain the sound twice**, which makes it sound tinny or hollow. Recorders such as CleanShot X or OBS capture each app's audio before FineTune mutes it at the output, and they also capture FineTune's processed copy, which arrives about 26 ms later. macOS gives an app no way to hide its audio from recorders. While recording, quit FineTune Fork, or ignore the app you record (edit mode, eye icon). On an output without its own volume control, such as a TV over HDMI, an ignored app plays at full volume. Reported upstream as [ronitsingh10/FineTune#118](https://github.com/ronitsingh10/FineTune/issues/118) and [ronitsingh10/FineTune#292](https://github.com/ronitsingh10/FineTune/issues/292).

## 1.9.0-fork.1 (2026-10-29)

First release of the fork, based on FineTune 1.9.0.

- No full-volume blast when playback starts: audio that starts before FineTune processes it is held back instead of playing unprocessed.
- The Mac can sleep while nothing plays: silent apps keep their tap, but it stops running after 10 seconds.
- New helper processes, such as a new browser tab, join the app's existing tap.
- Safer on outputs without their own volume control: no full volume after a display powers back on, and call passthrough stays off where an untapped call would play at full scale.
- Over 20 upstream pull requests merged, among them AirPlay selection, Bluetooth fixes, output format changes and the HUD over full-screen apps.

The full list with issue numbers is in [FORK.md](FORK.md).
