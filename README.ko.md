# MacDroid — macOS용 네이티브 DeX

[English](README.md) · **한국어**

안드로이드 폰을 맥의 데스크톱으로 씁니다. 초저지연으로 화면을 미러링하거나, 안드로이드 앱을 맥 창처럼 크기 조절되는 창으로 띄울 수 있어요. 삼성 DeX / 안드로이드 DEX 같은 경험을 네이티브로 빠르게 제공합니다.

스트리밍 코어는 [scrcpy](https://github.com/Genymobile/scrcpy)(Apache-2.0)를 기반으로 Metal 렌더링과 VideoToolbox 하드웨어 디코딩을 쓰고, 그 위를 네이티브 SwiftUI/AppKit으로 감쌌습니다. Electron도, 클라우드도 없습니다. 모든 것이 USB나 Wi-Fi로 로컬에서만 동작합니다.

## 기능

- **화면 미러링** — 하드웨어 디코딩(Metal + VideoToolbox)으로 초저지연 미러링, 화질 프리셋(균형 / 선명 / 가볍게)과 세부 설정(코덱, 비트레이트, 해상도, fps)
- **앱 런처** — 폰의 모든 앱을 실제 이름과 아이콘으로 보여 줍니다(기기에서 직접 읽어 약 3초). 더블클릭하면 DeX 데스크톱 안의 창으로 열리고, 우클릭 메뉴로 새 창 / 다시 시작을 할 수 있습니다
- **DeX 데스크톱** — 맥 창 하나 안에 MacDroid만의 데스크톱 셸이 뜹니다. 배경화면, 상태표시줄(알림, Wi-Fi·블루투스·배터리 설정, 밝기·소리, 달력), 맥 스타일의 떠 있는 독, 바탕화면 아이콘과 폴더까지 있어요. 안드로이드 앱은 그 안에서 약 0.1초 만에 창으로 열립니다. 영상 스트림 하나를 MacDroid가 창마다 잘라 그리는 방식이에요. 창에는 맥 스타일 제목줄(닫기·최소화·최대화·뒤로)이 있고, 끌어서 이동·크기 조절·화면 가장자리 분할(스냅)을 할 수 있습니다. 폰 본체의 화면과 전원 상태는 절대 건드리지 않습니다
- **물리 키보드·마우스** — uhid 모드에서는 호버, 게임 키, 폰의 입력기(한글/일본어 등)가 실제 하드웨어 키보드처럼 동작합니다
- **무선** — 6자리 코드로 페어링, IP로 바로 연결, mDNS로 기기 자동 발견, 클릭 한 번으로 USB 연결을 Wi-Fi로 전환
- **파일 전송** — 폰의 Download 폴더로 파일 보내기
- **메뉴바 빠른 미러링** — 메뉴바에서 바로 미러링 시작
- **English / 한국어** — 설정 → 일반에서 앱 언어 변경
- **개인정보 보호** — 원격 수집도, 서버도, 데이터 수집도 없습니다. 모든 통신은 맥과 폰 사이에서만 오갑니다(USB/Wi-Fi를 통한 표준 ADB)

## 설치

### 내려받기 (추천)

1. [Releases](https://github.com/wjchoi87/MacDroid/releases/latest)에서 `MacDroid-<버전>-macos-arm64.zip`을 받습니다(Apple Silicon, macOS 14 이상)
2. 압축을 풀고 **MacDroid.app**을 **응용 프로그램** 폴더로 옮깁니다
3. 처음 실행: 아직 Apple 공증 전이라, MacDroid.app을 **우클릭 → 열기 → 열기** 하세요(또는 시스템 설정 → 개인정보 보호 및 보안 → **그래도 열기**). 처음 한 번만 하면 됩니다
4. **로컬 네트워크** 접근을 물으면 허용하세요(Wi-Fi 기기에 필요)

adb와 scrcpy가 앱에 들어 있어서 따로 설치할 것이 없습니다. CLI(`macdroid-cli-<버전>-macos-arm64.zip`, 선택)는 `/Applications/MacDroid.app` 안의 도구를 씁니다.

### 준비물 (소스에서 빌드할 때)

- macOS 14.0(Sonoma) 이상
- [Xcode](https://developer.apple.com/xcode/) 16 이상(커맨드라인 빌드만으로 충분)
- [Homebrew](https://brew.sh)
- Android SDK `platform-tools`(adb), `build-tools`(aapt2, d8), `platforms/android-*` 하나 — [Android Studio](https://developer.android.com/studio)나 `sdkmanager`로 설치하는 게 가장 쉽습니다
- JDK(`javac`) — 기기에서 도는 작은 앱 인덱서(`Helper/AppIndex`)를 빌드할 때 한 번 씁니다
- 폰: **개발자 옵션 → USB 디버깅**(Wi-Fi로 쓰려면 **무선 디버깅**도)

### 소스에서 빌드

```bash
# 1. 도구 설치
brew install scrcpy xcodegen

# 2. 클론
git clone https://github.com/wjchoi87/MacDroid.git
cd MacDroid

# 3. 앱 아이콘과 Xcode 프로젝트 생성
./scripts/make-iconset.sh
xcodegen

# 4. 빌드(adb / scrcpy / aapt2도 앱 안에 함께 묶입니다)
xcodebuild -project MacDroid.xcodeproj -scheme MacDroid -configuration Release build \
  -derivedDataPath build/DerivedData

# 5. 실행
open build/DerivedData/Build/Products/Release/MacDroid.app
```

릴리스용 압축 파일(앱 + CLI + SHA256SUMS)은 `./scripts/package-release.sh`로 만듭니다. `--publish`를 붙이면 GitHub 릴리스까지 만듭니다.

빌드 스크립트(`scripts/fetch-vendor.sh`, `scripts/build-helper.sh`)가 `adb`, `scrcpy`(dylib 포함), `aapt2`, 앱 인덱서를 앱 안에 묶어 줍니다. 그래서 완성된 앱은 **외부 의존성이 없습니다**. 실제 사용자는 Homebrew, JDK, Android SDK 없이 바로 실행할 수 있어요.

바이너리가 다른 위치에 있다면 직접 지정하세요.

```bash
ADB_SRC=/path/to/adb AAPT2_SRC=/path/to/aapt2 SCRCPY_SRC=/path/to/scrcpy ./scripts/fetch-vendor.sh
```

### 폰 첫 설정

1. 설정 → 휴대전화 정보 → **빌드 번호**를 7번 누릅니다
2. 설정 → 개발자 옵션 → **USB 디버깅**을 켭니다
3. USB를 연결하고 폰에 뜨는 디버깅 허용 알림에서 허용을 누릅니다
4. 무선으로 쓰려면: 개발자 옵션 → **무선 디버깅** → MacDroid에서 페어링

## 사용법

- **미러링** — 기기를 고르고 *화면 미러링*을 누릅니다
- **앱 런처** — 앱을 더블클릭하면 DeX 데스크톱 안에 창으로 열립니다(데스크톱이 없으면 먼저 열림). 이미 열린 앱은 그 창이 앞으로 오고, 우클릭으로 *새 창으로 열기* / *다시 시작*을 할 수 있습니다. Esc나 ⌘W로 런처를 닫습니다
- **DeX 데스크톱** — *DeX 데스크톱*을 누릅니다.
  - 앱은 독(맨 왼쪽 버튼 = 앱 서랍), 바탕화면 아이콘(더블클릭 또는 Enter), 앱 런처에서 열고, 모두 데스크톱 안의 창으로 뜹니다
  - 제목줄을 화면 가장자리로 끌면 분할됩니다(절반, 1/4, 최대화)
  - 왼쪽 아래 홈 버튼은 모든 창을 최소화하고, Esc나 마우스 뒤로가기 버튼은 안드로이드 뒤로가기입니다
  - 바탕화면을 우클릭하면 새 폴더·배경화면 변경이 있고, 바탕화면을 끌면 여러 아이콘을 한 번에 선택합니다(Delete로 지우기)
  - 폰이 잠들면 데스크톱이 멈추고 *폰 깨우기* 버튼이 뜹니다. MacDroid는 폰을 스스로 깨우거나, 재우거나, 화면을 끄지 않습니다
- **무선으로 전환** — USB 기기를 고른 상태에서 *무선으로 전환*을 누르고 케이블을 뽑습니다
- **원클릭 복구** — *연결 복구*(페어링 화면과 빈 화면에 있음)는 adb 서버가 멈췄을 때만 재시작하고, 써 본 무선 기기를 다시 연결하고, 기기를 다시 찾고, 목록을 새로 고칩니다. 그래도 안 보이면 폰과 맥에서 확인할 것을 알려 줍니다. adb 서버가 죽어도 기기 감시가 스스로 복구되고, 페어링 화면에는 닫기 버튼이 있습니다(Esc도 됨)
- **확실한 무선 연결** — 기기가 실제로 `device` 상태를 보고해야 연결된 것으로 칩니다. 남아 있는 `offline` 연결은 시도 전후로 정리하므로, 한 번 실패해도 다음 시도가 망가지지 않습니다
- **자동 발견과 로컬 네트워크 권한** — MacDroid가 Bonjour(`_adb-tls-connect` / `_adb-tls-pairing`)를 직접 찾기 때문에, adb 서버를 누가 띄웠는지와 상관없이 기기를 찾습니다.
  - macOS는 로컬 네트워크 권한이 없는 프로세스(예: 터미널)가 띄운 adb 서버의 LAN 접근을 막습니다
  - MacDroid는 기기에 닿는데 adb 서버는 못 닿으면, MacDroid 권한으로 서버를 다시 띄우고 한 번 더 시도합니다
  - MacDroid 자체가 막혀 있다면 시스템 설정 → 개인정보 보호 및 보안 → 로컬 네트워크에서 켜 주세요
- **설정**
  - 앱 언어(시스템 / English / 한국어, 다시 시작하면 적용)
  - 화질 프리셋, 코덱·비트레이트·해상도·fps, 오디오, 가상 디스플레이 해상도와 DPI, uhid 고급 입력
  - 캡처 fps는 기본 무제한입니다. 가상 디스플레이는 기기가 60Hz로 제한하고, 1080p에서의 부드러움은 주로 비트레이트에 달려 있습니다(기본 20 Mbps)
- 미러링 창 안의 단축키는 scrcpy 단축키 그대로입니다(`MOD+F` 전체화면 등) — `scrcpy --help` 참고
- 미러링·앱 창 세션이 떠 있는 동안에는 폰이 잠들지 않게 합니다(`stay_on_while_plugged_in`). 마지막 세션이 닫히면 원래 설정으로 돌려놓습니다. DeX 데스크톱은 전원 설정을 바꾸지 않습니다

## 에이전트·스크립트용 CLI

같은 빌드에서 의존성 없는 CLI `macdroid`도 만들어집니다. AI 에이전트나 스크립트가 기기를 다룰 수 있고, `캡처 → 판단 → 탭/입력` 자동화 루프가 그대로 됩니다.

```bash
# 빌드(같은 저장소)
xcodebuild -project MacDroid.xcodeproj -scheme macdroid -configuration Debug build \
  -derivedDataPath build/DerivedData
M=build/DerivedData/Build/Products/Debug/macdroid

$M devices --json                       # [{"serial": "...", "state": "device", "connection": "usb"}]
$M info <serial> --json                 # 모델, 안드로이드 버전, 배터리, 화면
$M app list <serial> --json             # 설치된 앱(--labels: 기기 인덱서로 실제 이름, 약 3초)
$M app launch <serial> com.example.app --json
# → {"displayId": 11, "session": "...", "pid": ...}   ← 아래 -d에 displayId 사용
$M screenshot <serial> shot.png -d 11   # 그 가상 디스플레이 캡처
$M tap <serial> 960 400 -d 11           # 그 디스플레이에 탭
$M text <serial> "hello world"          # ASCII 텍스트 입력
$M key <serial> back                    # back/home/enter/wakeup/power/volume_up... 또는 키코드
$M app stop <serial> com.example.app    # (또는: app stop <serial> --all)

# MacDroid에서 DeX 데스크톱을 열어 둔 상태에서
$M desktop <serial> --json              # {"running": true, "displayId": 95, "width": 2880, ...}
$M app open <serial> com.android.settings   # 데스크톱 안에 창으로 열기(약 0.1초)
$M window list <serial> --json          # taskId, package, bounds(맨 앞 창이 먼저)
$M window move <serial> com.android.settings 200 200 1200 1100
$M window maximize|focus|close <serial> <taskId|package>
$M screenshot <serial> desk.png -d 95   # 데스크톱 디스플레이 캡처 / 탭 / 입력

$M notifications <serial> --json        # 폰 알림(key, package, title, text)
$M notifications dismiss <serial> <key>
$M volume <serial> [0-15]               # 미디어 볼륨
$M brightness <serial> [1-255|auto]
$M mirror start <serial>                # 일반 화면 미러링 창
$M mirror stop <serial>
$M push <serial> file.pdf               # → /sdcard/Download/
$M pull <serial> /sdcard/DCIM/photo.jpg .
$M connect 192.168.0.10:5555            # 무선
$M pair 192.168.0.10:37123 123456
```

종료 코드: `0` 성공 · `1` 실행 실패 · `2` 사용법 오류. 모든 조회 명령은 `--json`을 지원합니다.

참고:
- 폰 화면이 꺼져 있거나 잠겨 있으면 안드로이드가 `input`을 조용히 무시합니다 — 먼저 `macdroid key <serial> wakeup`을 실행하세요
- 세션은 전원에 연결된 동안(USB 또는 충전 중) 폰이 잠들지 않게 합니다. 배터리로만 쓰면 결국 안드로이드가 기기를 재웁니다
- `screencap -d`는 논리 디스플레이 id나(일부 제조사 빌드에서는) SurfaceFlinger 토큰을 받습니다 — CLI가 둘 다 자동으로 시도합니다

## 동작 원리

```
┌──────────────┐   USB / Wi-Fi (adb)   ┌──────────────┐
│    macOS     │ ◄───────────────────► │   Android    │
│   MacDroid   │   scrcpy-server       │   virtual    │
│  (SwiftUI +  │   H.264/H.265 +       │  displays    │
│  Metal/VT)   │   ADB protocol        │  + apps      │
└──────────────┘                       └──────────────┘
```

- **스트리밍 코어** — 번들된 `scrcpy`가 SDL3/Metal로 그리고 VideoToolbox로 디코딩합니다. `scrcpy-server`는 ADB를 통해 폰에서 돕니다
- **DeX 데스크톱** — MacDroid가 `scrcpy-server`에 직접 붙습니다(scrcpy 창 없음). 시스템 장식 없는 가상 디스플레이 하나를 H.264로 받아 VideoToolbox로 풀고, 안드로이드 freeform 창마다 그 영상의 해당 부분만 잘라 그립니다(IOSurface + `contentsRect`). 입력은 scrcpy 제어 소켓으로 돌려보내고, 창 위치는 `cmd activity stack list`로 읽습니다
- **DeX 창(app launch / CLI)** — 창마다 `--new-display` + `--start-app`으로 별도 scrcpy를 띄워, 앱마다 자기 가상 디스플레이를 갖습니다
- **앱 아이콘·이름** — 기기에서 도는 인덱서(`Helper/AppIndex`, `app_process`로 실행)가 런처 앱 전체의 실제 이름과 아이콘을 한 번에 돌려줍니다. 실패하면 `pm list` + APK + `aapt2`로 대신합니다
- **기기 감시** — `adb track-devices`를 길이 접두 프레임 파서로 읽습니다

## 후원

MacDroid가 도움이 되셨다면 [GitHub Sponsors](https://github.com/sponsors/wjchoi87)로 개발을 응원해 주세요. 고맙습니다!

## 서드파티 소프트웨어

MacDroid는 다음을 포함하고 사용합니다(모두 Apache-2.0):

- [scrcpy](https://github.com/Genymobile/scrcpy) — 화면 미러링과 제어(Copyright © 2018 Genymobile)
- **adb**(Android Debug Bridge)와 **aapt2** — Copyright © The Android Open Source Project

전체 고지는 [LICENSES/NOTICE.md](LICENSES/NOTICE.md)를 참고하세요.

## 라이선스

Copyright 2026 wjchoi87

Apache License, Version 2.0으로 배포됩니다. [LICENSE](LICENSE)를 참고하세요.
