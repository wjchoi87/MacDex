# MacDroid — a native DeX for macOS

**English** · [한국어](README.ko.md)

Turn your Android phone into a desktop on your Mac: mirror the screen with ultra-low latency, or run individual Android apps in their own resizable Mac windows — Samsung DeX / Android DEX style, native and fast.

Built on [scrcpy](https://github.com/Genymobile/scrcpy) (Apache-2.0) for the streaming core with Metal rendering and VideoToolbox hardware decoding, wrapped in a native SwiftUI/AppKit shell. No Electron. No cloud. Everything runs locally over USB or Wi-Fi.

## Features

- **Screen mirroring** — ultra-low-latency mirroring with hardware decoding (Metal + VideoToolbox), quality presets (Balanced / Crisp / Lightweight) and full manual control (codec, bitrate, resolution, fps)
- **App launcher** — every app on your phone with its real name and icon (read on the device in about 3 s); open any of them as a window on the DeX desktop, or as a new window / restart from the right-click menu
- **DeX desktop** — MacDroid's own desktop shell in one Mac window: wallpaper, status bar (notifications, Wi-Fi/Bluetooth/battery pages, brightness/volume, calendar), a floating Mac-style dock, desktop icons and folders. Android apps open as windows inside it in ~0.1 s — all from a single video stream, cropped per window by MacDroid. Windows have Mac title bars (close/minimize/maximize/back), drag, resize and edge snapping. The phone's own screen and power state are never touched
- **Physical keyboard & mouse** — uhid mode gives you hover, game keys, and your phone's IME (Korean/Japanese/…) exactly like a hardware keyboard
- **Wireless** — pair with a 6-digit code, connect directly by IP, discover devices via mDNS, or switch a USB connection to Wi-Fi in one click
- **File transfer** — send files to the phone's Download folder
- **Menu bar quick mirror** — start mirroring right from the menu bar
- **English / 한국어** — switch the app language in Settings → General
- **Private by design** — no telemetry, no servers, no data collection. All traffic stays between your Mac and your phone (standard ADB over USB/Wi-Fi)

## Installation

### Download (recommended)

1. Download `MacDroid-<version>-macos-arm64.zip` from [Releases](https://github.com/wjchoi87/MacDroid/releases/latest) (Apple Silicon, macOS 14+)
2. Unzip and move **MacDroid.app** to **Applications**
3. First launch: MacDroid isn't notarized by Apple yet, so right-click MacDroid.app → **Open** → **Open** (or System Settings → Privacy & Security → **Open Anyway**). You only need to do this once
4. Allow **Local Network** access when asked (needed for Wi-Fi devices)

adb and scrcpy are bundled — nothing else to install. The optional CLI (`macdroid-cli-<version>-macos-arm64.zip`) uses the tools inside `/Applications/MacDroid.app`.

### Requirements (building from source)

- macOS 14.0 (Sonoma) or later
- [Xcode](https://developer.apple.com/xcode/) 16 or later (a command-line build is enough)
- [Homebrew](https://brew.sh)
- Android SDK `platform-tools` (adb), `build-tools` (aapt2, d8) and one `platforms/android-*` — easiest via [Android Studio](https://developer.android.com/studio) or `sdkmanager`
- A JDK (`javac`) — used once to build the small on-device app indexer (`Helper/AppIndex`)
- On the phone: **Developer options → USB debugging** (and **Wireless debugging** for Wi-Fi)

### Build from source

```bash
# 1. Get the tools
brew install scrcpy xcodegen

# 2. Clone
git clone https://github.com/wjchoi87/MacDroid.git
cd MacDroid

# 3. Generate the app icon and the Xcode project
./scripts/make-iconset.sh
xcodegen

# 4. Build (also bundles adb / scrcpy / aapt2 into the app)
xcodebuild -project MacDroid.xcodeproj -scheme MacDroid -configuration Release build \
  -derivedDataPath build/DerivedData

# 5. Run
open build/DerivedData/Build/Products/Release/MacDroid.app
```

To make release zips (app + CLI + SHA256SUMS) run `./scripts/package-release.sh` — add `--publish` to create the GitHub release.

The build scripts (`scripts/fetch-vendor.sh`, `scripts/build-helper.sh`) bundle `adb`, `scrcpy` (with its dylib tree), `aapt2` and the app indexer into the app, so the finished app has **no external dependencies** — end users never need Homebrew, a JDK or the Android SDK to run it.

If your binaries live somewhere unusual, override them:

```bash
ADB_SRC=/path/to/adb AAPT2_SRC=/path/to/aapt2 SCRCPY_SRC=/path/to/scrcpy ./scripts/fetch-vendor.sh
```

### First run on the phone

1. Settings → About phone → tap **Build number** 7 times
2. Settings → Developer options → enable **USB debugging**
3. Plug in USB and accept the debugging prompt on the phone
4. Or go wireless: Developer options → **Wireless debugging** → pair from MacDroid

## Usage

- **Mirror** — select the device, click *Screen mirroring*
- **App launcher** — double-click an app to open it as a window on the DeX desktop (the desktop opens if needed). Opening an app that is already open brings its window to the front; right-click for *Open in new window* / *Restart*. Esc or ⌘W closes the launcher
- **DeX desktop** — click *DeX desktop*. Open apps from the dock (left button = app drawer), desktop icons (double-click or Enter) or the app launcher; they open as windows inside the desktop. Drag a title bar to a screen edge to snap (halves, quarters, maximize). Home (bottom-left) minimizes every window; Esc or the mouse back button = Android back. Right-click the wallpaper for new folders / wallpaper, drag on the wallpaper to select several icons (Delete removes them). If the phone falls asleep the desktop pauses and offers a *Wake phone* button — MacDroid never wakes, sleeps or turns off the phone screen on its own
- **Go wireless** — with a USB device selected, click *Switch to wireless*, then unplug the cable
- **One-click recovery** — *Repair connection* (pair sheet & empty state) restarts the adb server only if it is stuck, reconnects wireless devices you've used before, retries discovery and refreshes the list. If nothing shows up, it tells you what to check on the phone and on the Mac. Device tracking also self-heals if the adb server dies, and the pair sheet has a close button (Esc works too)
- **Reliable wireless connect** — a connection only counts as connected once the device actually reports `device` state; stale `offline` transports are cleaned up before and after every attempt, so a failed try never poisons the next one
- **Auto-discovery & Local Network permission** — MacDroid browses Bonjour itself (`_adb-tls-connect` / `_adb-tls-pairing`), so discovery does not depend on whoever started the adb server. macOS blocks LAN access for an adb server started by a process without Local Network permission (e.g. a terminal): when MacDroid can reach a LAN device but the adb server can't, MacDroid restarts the server under its own permission and retries once. If MacDroid itself is blocked, enable it in System Settings → Privacy & Security → Local Network
- **Settings** — app language (System / English / 한국어, applied after a restart), quality presets, codec/bitrate/resolution/fps, audio, virtual display resolution & DPI, uhid advanced input. Capture fps is unlimited by default; virtual displays are capped at 60 Hz by the device itself, and smoothness at 1080p mostly depends on bitrate (default 20 Mbps)
- Shortcuts inside mirroring windows are scrcpy's own (`MOD+F` fullscreen, …) — see `scrcpy --help`
- While a mirror/app-window session is running, the phone is kept from sleeping (`stay_on_while_plugged_in`); your previous setting is restored when the last session closes. The DeX desktop does not change any power setting

## CLI for agents and scripts

The same build produces `macdroid`, a zero-dependency CLI that lets AI agents and scripts drive the device — the full automation loop `screenshot → decide → tap/text` works:

```bash
# build it (same repo)
xcodebuild -project MacDroid.xcodeproj -scheme macdroid -configuration Debug build \
  -derivedDataPath build/DerivedData
M=build/DerivedData/Build/Products/Debug/macdroid

$M devices --json                       # [{"serial": "...", "state": "device", "connection": "usb"}]
$M info <serial> --json                 # model, Android version, battery, screen
$M app list <serial> --json             # installed apps (--labels: real names via on-device indexer, ~3 s)
$M app launch <serial> com.example.app --json
# → {"displayId": 11, "session": "...", "pid": ...}   ← use displayId for -d below
$M screenshot <serial> shot.png -d 11   # capture that virtual display
$M tap <serial> 960 400 -d 11           # tap on that display
$M text <serial> "hello world"          # ASCII text injection
$M key <serial> back                    # back/home/enter/wakeup/power/volume_up... or a keycode
$M app stop <serial> com.example.app    # (or: app stop <serial> --all)

# with the DeX desktop open in MacDroid
$M desktop <serial> --json              # {"running": true, "displayId": 95, "width": 2880, ...}
$M app open <serial> com.android.settings   # open as a window inside the desktop (~0.1 s)
$M window list <serial> --json          # taskId, package, bounds (front-most first)
$M window move <serial> com.android.settings 200 200 1200 1100
$M window maximize|focus|close <serial> <taskId|package>
$M screenshot <serial> desk.png -d 95   # capture / tap / text on the desktop display

$M notifications <serial> --json        # phone notifications (key, package, title, text)
$M notifications dismiss <serial> <key>
$M volume <serial> [0-15]               # media volume
$M brightness <serial> [1-255|auto]
$M mirror start <serial>                # plain screen mirroring window
$M mirror stop <serial>
$M push <serial> file.pdf               # → /sdcard/Download/
$M pull <serial> /sdcard/DCIM/photo.jpg .
$M connect 192.168.0.10:5555            # wireless
$M pair 192.168.0.10:37123 123456
```

Exit codes: `0` success · `1` runtime failure · `2` usage error. All queries support `--json`.

Notes:
- If the phone screen is off/locked, `input` is silently ignored by Android — run `macdroid key <serial> wakeup` first
- Sessions automatically keep the phone awake while plugged in (USB or charging); on battery Android will still sleep the device eventually
- `screencap -d` accepts either the logical display id or (on some OEM builds) a SurfaceFlinger token — the CLI tries both automatically

## How it works

```
┌──────────────┐   USB / Wi-Fi (adb)   ┌──────────────┐
│    macOS     │ ◄───────────────────► │   Android    │
│   MacDroid   │   scrcpy-server       │   virtual    │
│  (SwiftUI +  │   H.264/H.265 +       │  displays    │
│  Metal/VT)   │   ADB protocol        │  + apps      │
└──────────────┘                       └──────────────┘
```

- **Streaming core** — the bundled `scrcpy` binary renders with SDL3/Metal and decodes via VideoToolbox; `scrcpy-server` runs on the phone through ADB
- **DeX desktop** — MacDroid talks to `scrcpy-server` directly (no scrcpy window): one virtual display without system decorations, H.264 decoded with VideoToolbox, and every Android freeform window is drawn as a crop of that single stream (IOSurface + `contentsRect`). Input goes back over scrcpy's control socket; window positions come from `cmd activity stack list`
- **DeX windows (app launch / CLI)** — each window is a separate scrcpy instance with `--new-display` + `--start-app`, giving every app its own virtual display
- **App icons & names** — an on-device indexer (`Helper/AppIndex`, run with `app_process`) returns every launcher app with its real label and rendered icon in one pass; falls back to `pm list` + APK + `aapt2`
- **Device tracking** — `adb track-devices` with a proper length-prefixed frame parser

## Support

If MacDroid is useful to you, you can support its development through [GitHub Sponsors](https://github.com/sponsors/wjchoi87). Thank you!

## Third-party software

MacDroid bundles and depends on (all Apache-2.0):

- [scrcpy](https://github.com/Genymobile/scrcpy) — screen mirroring & control (Copyright © 2018 Genymobile)
- **adb** (Android Debug Bridge) and **aapt2** — Copyright © The Android Open Source Project

See [LICENSES/NOTICE.md](LICENSES/NOTICE.md) for full attribution.

## License

Copyright 2026 wjchoi87

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
