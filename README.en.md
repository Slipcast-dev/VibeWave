[Русский](README.md) · **English**

![VibeWave — a minimal MP3/FLAC player for macOS](docs/assets/vibewave-banner-en.svg)

[![Version 1.0.0](docs/assets/badges/version.svg)](https://github.com/Slipcast-dev/VibeWave/releases/tag/v1.0.0)
![macOS 13+](docs/assets/badges/macos.svg)
![Apple Silicon + Intel](docs/assets/badges/architecture.svg)
![Russian and English](docs/assets/badges/languages.svg)
![Swift 5.8+](docs/assets/badges/swift.svg)
[![Stars](docs/assets/badges/stars.svg)](https://github.com/Slipcast-dev/VibeWave/stargazers)
[![Downloads](docs/assets/badges/downloads.svg)](https://github.com/Slipcast-dev/VibeWave/releases)

# VibeWave

A lightweight local audio player for **macOS 13+** that plays MP3 and FLAC. Windows 95–style interface, 10-band equalizer, Russian and English. No accounts, no network features, no third-party dependencies.

[Download v1.0.0](https://github.com/Slipcast-dev/VibeWave/releases/tag/v1.0.0) · [Full documentation (Russian)](DOCUMENTATION.md) · [Changelog (Russian)](CHANGELOG.md) · [CI](https://github.com/Slipcast-dev/VibeWave/actions)

## Features

- Play, pause, stop, previous/next track, seeking, volume and balance.
- **Equalizer:** 10 bands (32 Hz – 16 kHz, ±12 dB), preamp and 9 presets; the **EQ** button sits to the right of the playback controls.
- Compact Windows 95–style player: time display, scrolling title, kbps/kHz and level meter, with the playlist below.
- “All Music”: playlists, folders and music outside playlists in one list, grouped by playlist or not.
- Music folders (MP3 and FLAC, including subfolders) with scan progress and cancel.
- Your own playback order by dragging rows; moving tracks between playlists.
- A temporary queue outside playlists: opening music never creates a playlist on its own.
- **Russian and English interface:** the language follows the system; the **RU ▾ / EN ▾** button switches it without a restart.
- One universal build for **Apple Silicon** and **Intel**.
- A custom retro window frame with working minimize, zoom and close buttons.

## Screenshots

<p>
  <img src="docs/assets/interface-windows95-en.png" width="440" alt="VibeWave window with test tracks">
</p>
<p>
  <img src="docs/assets/equalizer-en.png" width="490" alt="VibeWave equalizer with the Rock preset">
</p>

Screenshots are rendered with test data, not a real music library.

## Installation

![Release info: Apple Silicon and Intel, ad hoc signature](docs/assets/release-banner-en.svg)

**[Release v1.0.0 and downloads](https://github.com/Slipcast-dev/VibeWave/releases/tag/v1.0.0)** are available to members of this private repository. One build runs on **Apple Silicon (M1 and later)** and **Intel** Macs with macOS 13+.

- `VibeWave-1.0.0-macos-universal.dmg` — disk image: open it and drag VibeWave to Applications.
- `VibeWave-1.0.0-macos-universal.pkg` — installer that puts VibeWave in `/Applications`.
- `VibeWave-1.0.0-macos-universal.zip` — the app in a ZIP archive.
- `SHA256SUMS.txt` — checksums. Verify in the download folder: `shasum -a 256 -c SHA256SUMS.txt`.

The app has a local **ad hoc** signature and is not notarized by Apple. On first launch macOS shows a warning: allow it in System Settings → Privacy & Security. Do not turn off macOS protection entirely.

## Building from source

You need macOS 13+ and Swift 5.8 or later from Xcode or the Command Line Tools. From the project folder:

```sh
zsh scripts/build-app.sh
open dist/VibeWave.app
```

The script builds a **universal** app: the `arm64` (Apple Silicon) and `x86_64` (Intel) slices are combined in one `dist/VibeWave.app`. It picks SwiftPM or the plain compiler, generates the icon and verifies the ad hoc signature. For a quick build for the current Mac only: `VIBEWAVE_ARCHS="$(uname -m)" zsh scripts/build-app.sh`.

Installers from the finished build:

```sh
zsh scripts/package-release.sh
```

The DMG, PKG, ZIP and `SHA256SUMS.txt` appear in `.release/v<version>-universal/`. Installing without Gatekeeper warnings requires a Developer ID and Apple notarization. The local build runs without App Sandbox; macOS system protection stays on.

## Usage

1. Click **“+ File”** at the bottom left, or drop MP3/FLAC files onto the window.
2. To create a playlist, open **“Library”** and click **`+`** next to “Playlists”.
3. Select a playlist and add music to it. Drag a track from the queue onto a playlist, or choose **“Add to Playlist”** from the context menu.
4. **“Library”** shows All Music, playlists and folders. The **“View ▾”** menu switches between “Single List” and “By Playlist”. Add folders with **“+ Folder”** or by dragging them from Finder; while files are being added, progress and a **“Cancel”** button appear at the bottom right.
5. Drag a **track row** and drop it before another row, or in the empty area at the bottom to move it to the end. “Move Up/Move Down” are also in the context menu.
6. Click the time display to switch between elapsed and remaining time.
7. **EQ** at the right end of the ⏮ ▶ ❚❚ ■ ⏭ row opens the equalizer: bands, preamp, “On”, “Presets ▾” and “Reset”. Changes are heard immediately and are saved.
8. **RU ▾ / EN ▾** next to “View” chooses the language: “System”, “Русский” or “English”. By default VibeWave uses the macOS language: Russian if it comes before English in the language list, otherwise English.

**Keyboard shortcuts:** Space — play/pause; `⌘O` — add files; `⌘W` — close the window; `⌘M` — minimize; `⌘Q` — quit. After closing the window, click the Dock icon to open it again.

## Data

Playlists, folders and the manual All Music order are saved to:

```text
~/Library/Application Support/VibeWave/library.json
```

Audio files stay where they are: removing a track or playlist never deletes music from disk. The queue outside playlists lives in memory until you quit. The JSON is written atomically, and a damaged library is never silently overwritten. A library from the earlier “Тихо” app is read automatically and left unchanged.

View, language, equalizer and window settings are stored in the standard macOS preferences for `local.vibewave.player`.

## Checks

```sh
zsh scripts/check.sh
# With full Xcode installed:
swift test
```

Regression checks use a temporary library and test audio files and never touch your music or playlists. `VIBEWAVE_CHECK_ARCH=x86_64` checks the Intel slice on Apple Silicon through Rosetta.

The stars and downloads badges are refreshed with `zsh scripts/update-badges.sh`. The repository is private, so external badge services cannot see it; the numbers are captured when the script runs.

## Project layout

```text
Assets/                       source icon and its origin
Resources/Info.plist           app properties template
Sources/VibeWaveCore/          models, storage, file scanning, equalizer, RU/EN strings
Sources/VibeWave/              model, import, playback, window and interface
Tests/VibeWaveCoreTests/       XCTest for the core
Checks/                       integration checks and audio fixtures
scripts/                      build, checks, installers, badges
docs/                         architecture, testing, banners and screenshots
dist/VibeWave.app              built app, not tracked by Git
```

## Working with the repository

- [Contributing (Russian)](CONTRIBUTING.md)
- [Security (Russian)](SECURITY.md)
- [Code of conduct (Russian)](CODE_OF_CONDUCT.md)
- [Report a bug](https://github.com/Slipcast-dev/VibeWave/issues/new/choose)

GitHub Actions on an Intel macOS runner runs the core tests, the universal build, signature and slice checks, regression checks and installer packaging (nothing is published). Actions are pinned by SHA and the workflow can only read the source. Sound, gestures and Dock behavior are checked locally.

No open-source license has been chosen yet; this project is not declared open source. The repository is private: [Slipcast-dev/VibeWave](https://github.com/Slipcast-dev/VibeWave).
