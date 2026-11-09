<p align="center">
  <img src=".github/assets/icon.png" width="160" alt="AudioMixer icon">
</p>

<h1 align="center">AudioMixer</h1>

<p align="center">
  Per-app volume control for macOS, inspired by the Windows Volume Mixer.<br>
  Lives in the menu bar. Turn any app down — or boost it up to <b>+24 dB</b>.
</p>

<p align="center">
  <a href="https://github.com/Zahorrr/AudioMixer/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/Zahorrr/AudioMixer"></a>
  <img alt="macOS 14.2+" src="https://img.shields.io/badge/macOS-14.2%2B-black?logo=apple">
  <img alt="Apple Silicon & Intel" src="https://img.shields.io/badge/Apple%20Silicon%20%26%20Intel-universal-555">
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue">
</p>

<p align="center">
  <img src=".github/assets/screenshot.png" width="720" alt="AudioMixer screenshot">
</p>

---

## Install

Paste this in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/Zahorrr/AudioMixer/main/install.sh | bash
```

It downloads the latest release, installs it in `/Applications` and launches it.

Prefer a regular installer? Download **AudioMixer.pkg** from the [latest release](https://github.com/Zahorrr/AudioMixer/releases/latest) — see the note below about the "unidentified developer" warning.

### First launch

The first time you change an app's volume, macOS asks for permission to **capture audio from other apps**. Allow it
(*System Settings › Privacy & Security › Screen & System Audio Recording*). Without it, the app you adjust goes silent.

### "Apple could not verify AudioMixer…"

AudioMixer isn't signed with a paid Apple Developer ID, so macOS warns you when you open a **downloaded** `.pkg`. Either:

- open **System Settings › Privacy & Security**, scroll down and click **Open Anyway**, or
- remove the quarantine flag before opening it:
  ```bash
  xattr -d com.apple.quarantine ~/Downloads/AudioMixer.pkg
  ```

The `curl` install above doesn't trigger this warning.

## Features

- **One fader per app** using audio, Windows-mixer style, with a live level meter
- **Boost above 100 %** — +6 / +12 / +18 / +24 dB, with a soft limiter to keep peaks clean
- **Per-app mute**, plus master volume and mute for the current output device
- **Clean list** — helper processes (Chrome, Claude, Electron apps, Safari's WebKit…) are grouped under their app, system processes are hidden, and you can hide any app with a right click
- **Remembers your levels** per app and re-applies them at launch
- **Zero impact at 100 %** — untouched apps are never re-routed, so no added latency
- Left click the menu bar icon to open the mixer · right click for **Language** (English / Français) and **Quit**
- **Launches at login** by default (can be turned off in the mixer)

## How it works

No kernel extension, no virtual audio driver. AudioMixer uses the **Core Audio process taps** API introduced in macOS 14.2:

1. A `CATapDescription` with `muteBehavior = .mutedWhenTapped` captures an app's audio and silences it at the source.
2. A private aggregate device combines the current output device with that tap.
3. An IOProc applies the gain (smoothed per buffer, soft-clipped near 0 dBFS) and plays the result back.

When an app sits at 100 % and is playing, an *unmuted* tap is used only to feed the level meter — the audio itself is left alone.

## Build from source

Requires the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/Zahorrr/AudioMixer.git
cd AudioMixer
scripts/build.sh install   # build for this Mac, install in /Applications, launch
scripts/build.sh pkg       # universal build + dist/AudioMixer.pkg
```

| File | Role |
|---|---|
| `Sources/AppTap.swift` | Process tap + aggregate device + real-time render (gain, limiter, peak meter) |
| `Sources/MixerModel.swift` | App discovery & filtering, per-app state, tap lifecycle, persistence, language |
| `Sources/MixerView.swift` | SwiftUI mixer: vertical faders, meters, mute buttons |
| `Sources/CoreAudioHelpers.swift` | Core Audio property helpers, process → app resolution |
| `Sources/AudioMixerApp.swift` | Menu bar item, popover, right-click menu |
| `Resources/` | `Info.plist` and app icon |
| `scripts/` | `swiftc` build, ad-hoc signing, install, `.pkg` packaging |

## Known limitations

- Audio is re-routed to the **default output device**; an app sending audio to another device isn't handled.
- Taps use a stereo mixdown, played on the first two channels of the output.
- Ad-hoc signed: macOS may ask for the audio permission again after an update.

## Credits

Inspired by [BackgroundMusic](https://github.com/kyleneideck/BackgroundMusic), which pioneered per-app volume on macOS with a virtual audio driver.

## License

MIT — see [LICENSE](LICENSE).
