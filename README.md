# MacDroid — a native DeX for macOS

Turn your Android phone into a desktop on your Mac: mirror the screen with ultra-low latency, or run individual Android apps in their own resizable Mac windows — Samsung DeX / Android DEX style, native and fast.

Built on [scrcpy](https://github.com/Genymobile/scrcpy) (Apache-2.0) for the streaming core with Metal rendering and VideoToolbox hardware decoding, wrapped in a native SwiftUI/AppKit shell. No Electron. No cloud. Everything runs locally over USB or Wi-Fi.

## Features

- **Screen mirroring** — ultra-low-latency mirroring with hardware decoding (Metal + VideoToolbox), quality presets (Balanced / Crisp / Lightweight) and full manual control (codec, bitrate, resolution, fps)
- **DeX mode** — launch Android apps in separate windows, each on its own **independent virtual display**; the phone screen stays untouched, and multiple apps run at the same time. Launching an app that is already running asks whether you want a separate new instance or to restart it
- **Physical keyboard & mouse** — uhid mode gives you hover, game keys, and your phone's IME (Korean/Japanese/…) exactly like a hardware keyboard
- **Wireless** — pair with a 6-digit code, connect directly by IP, discover devices via mDNS, or switch a USB connection to Wi-Fi in one click
- **File transfer** — send files to the phone's Download folder
- **Menu bar quick mirror** — start mirroring right from the menu bar
- **Private by design** — no telemetry, no servers, no data collection. All traffic stays between your Mac and your phone (standard ADB over USB/Wi-Fi)

## Installation

### Requirements

- macOS 14.0 (Sonoma) or later
- [Xcode](https://developer.apple.com/xcode/) 16 or later (a command-line build is enough)
- [Homebrew](https://brew.sh)
- Android SDK `platform-tools` (adb) and `build-tools` (aapt2) — easiest via [Android Studio](https://developer.android.com/studio) or `sdkmanager`
- On the phone: **Developer options → USB debugging** (and **Wireless debugging** for Wi-Fi)

### Build from source

```bash
# 1. Get the tools
brew install scrcpy xcodegen

# 2. Clone
git clone https://github.com/wjchoi87/MacDex.git
cd MacDex

# 3. Generate the app icon and the Xcode project
./scripts/make-iconset.sh
xcodegen

# 4. Build (also bundles adb / scrcpy / aapt2 into the app)
xcodebuild -project MacDroid.xcodeproj -scheme MacDroid -configuration Release build \
  -derivedDataPath build/DerivedData

# 5. Run
open build/DerivedData/Build/Products/Release/MacDroid.app
```

The build script (`scripts/fetch-vendor.sh`) bundles `adb`, `scrcpy` (with its dylib tree) and `aapt2` into the app, so the finished app has **no external dependencies** — end users never need Homebrew or the Android SDK to run it.

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
- **DeX windows** — open the app launcher and double-click any app; it opens in its own window on a virtual display (the phone screen is unaffected). Double-clicking a running app asks whether to open a separate new instance or restart it
- **Go wireless** — with a USB device selected, click *Switch to wireless*, then unplug the cable
- **Settings** — quality presets, codec/bitrate/resolution/fps, audio, virtual display resolution & DPI, uhid advanced input
- Shortcuts inside mirroring windows are scrcpy's own (`MOD+F` fullscreen, …) — see `scrcpy --help`

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
- **DeX windows** — each window is a separate scrcpy instance with `--new-display` + `--start-app`, giving every app its own virtual display
- **App icons & names** — pulled lazily from the device (`pm list` + APK + `aapt2`), cached locally
- **Device tracking** — `adb track-devices` with a proper length-prefixed frame parser

## Third-party software

MacDroid bundles and depends on (all Apache-2.0):

- [scrcpy](https://github.com/Genymobile/scrcpy) — screen mirroring & control (Copyright © 2018 Genymobile)
- **adb** (Android Debug Bridge) and **aapt2** — Copyright © The Android Open Source Project

See [LICENSES/NOTICE.md](LICENSES/NOTICE.md) for full attribution.

## License

Copyright 2026 wjchoi87

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
