# MacDroid

맥에서 쓰는 안드로이드 데스크톱 — Samsung DeX / Android DEX 대체.

폰을 USB 또는 Wi-Fi로 연결하면:
- **화면 미러링** — 초저지연 하드웨어 디코딩(scrcpy 기반), 물리 키보드·마우스·한글 IME
- **DeX 모드** — 안드로이드 앱을 각자 독립된 가상 디스플레이 창에서 실행(폰 화면 유지)
- **무선 연결** — 페어링 코드 / IP 직접 / mDNS 자동 발견, USB→무선 원클릭 전환
- **파일 전송** — 드래그 없이 선택해서 폰 Download 폴더로 전송
- **메뉴바 빠른 미러링**

## 기술

- SwiftUI/AppKit 네이티브 셸 (macOS 14+)
- 스트리밍 코어: [scrcpy](https://github.com/Genymobile/scrcpy) (Apache-2.0) — 바이너리 임베드
- adb(AOSP) / aapt2(AOSP) 임베드 — 외부 설치 불필요
- 라이선스 고지: `LICENSES/NOTICE.md`

## 빌드

```bash
# 최초 1회: scrcpy/adb/aapt2 확보 (brew + Android SDK)
brew install scrcpy
# adb, aapt2: ~/Library/Android/sdk (platform-tools, build-tools)

./scripts/make-iconset.sh    # 앱 아이콘 생성 (최초 1회)
xcodegen                     # .xcodeproj 생성
xcodebuild -project MacDroid.xcodeproj -scheme MacDroid -configuration Debug build \
  -derivedDataPath build/DerivedData

# 실행
open build/DerivedData/Build/Products/Debug/MacDroid.app
```

`Vendor/`는 fetch-vendor.sh가 생성(git 제외). 빌드 post-script가 .app으로 복사한다.

## 구조

```
App/Sources/Core      ADB, Scrcpy, AppCatalog — 외부 프로세스 계층
App/Sources/Support   AppState(중앙 상태), ProcessRunner, Binaries
App/Sources/Views     MainView, DeviceDetail, Launcher(DeX), Pair, Settings, Onboarding
scripts/              vendor 번들링, 아이콘 생성
```

## 배포 시 주의

- 로컬 빌드는 미서명. 배포는 Developer ID 서명 + 공증 필요(vendor 바이너리 포함 전체 번들 서명).
- scrcpy/adb/aapt2는 Apache-2.0 — NOTICE 고지 유지.
