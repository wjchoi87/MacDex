#!/bin/bash
# MacDroid vendor 번들링: adb, aapt2, scrcpy(+dylib 재귀 수집, @loader_path 재작성), scrcpy-server
# 정책: 앱이 외부 brew/SDK 의존 없이 단독 실행되어야 한다(사용자에게 brew 설치를 요구하지 않음).
# 모든 바이너리는 Apache-2.0(AOSP adb/aapt2, scrcpy)로 재배포 가능 → LICENSES/에 고지 유지.
# arm64는 서명 필수 → install_name_tool로 고친 모든 Mach-O는 마지막에 ad-hoc 재서명한다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
BIN="$VENDOR/bin"; LIB="$VENDOR/lib"; SHARE="$VENDOR/share/scrcpy"

# 캐시: 이미 있으면 스킵 (강제 갱신: rm -rf Vendor)
if [[ -x "$BIN/scrcpy" && -x "$BIN/adb" && -f "$SHARE/scrcpy-server" ]]; then
  echo "vendor cache OK: $VENDOR"
  exit 0
fi

rm -rf "$VENDOR"
mkdir -p "$BIN" "$LIB" "$SHARE"

ADB_SRC="${ADB_SRC:-$HOME/Library/Android/sdk/platform-tools/adb}"
AAPT2_SRC="${AAPT2_SRC:-$(ls "$HOME"/Library/Android/sdk/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1)}"
SCRCPY_SRC="${SCRCPY_SRC:-$(command -v scrcpy)}"
SERVER_SRC="${SERVER_SRC:-/opt/homebrew/share/scrcpy/scrcpy-server}"

for f in "$ADB_SRC" "$AAPT2_SRC" "$SCRCPY_SRC" "$SERVER_SRC"; do
  [[ -f "$f" ]] || { echo "필요한 소스 없음: $f" >&2; exit 1; }
done

cp "$ADB_SRC"    "$BIN/adb"
cp "$AAPT2_SRC"  "$BIN/aapt2"
cp "$SCRCPY_SRC" "$BIN/scrcpy"
cp "$SERVER_SRC" "$SHARE/scrcpy-server"
chmod +x "$BIN/"*

# scrcpy/aapt2(및 전이 dylib)의 homebrew 의존을 lib/으로 재귀 수집
collect_deps() {
  local target="$1"
  otool -L "$target" 2>/dev/null | tail -n +2 | awk '{print $1}' | while read -r dep; do
    case "$dep" in
      @rpath/*|@loader_path/*|@executable_path/*|/usr/lib/*|/System/*) continue ;;
    esac
    [[ -f "$dep" ]] || continue
    base="$(basename "$dep")"
    dest="$LIB/$base"
    if [[ ! -f "$dest" ]]; then
      cp "$dep" "$dest"
      collect_deps "$dest"
    fi
  done
}
collect_deps "$BIN/scrcpy"
collect_deps "$BIN/aapt2" || true

# 로드 경로 재작성: lib 들은 @loader_path/<name>, bin/의 실행파일은 @loader_path/../lib/<name>
fixup() {
  local file="$1" prefix="$2"
  otool -L "$file" 2>/dev/null | tail -n +2 | awk '{print $1}' | while read -r dep; do
    case "$dep" in
      @*|/usr/lib/*|/System/*) continue ;;
    esac
    base="$(basename "$dep")"
    [[ -f "$LIB/$base" ]] || continue
    install_name_tool -change "$dep" "$prefix$base" "$file"
  done
}
for lib in "$LIB"/*.dylib; do
  install_name_tool -id "@loader_path/$(basename "$lib")" "$lib"
  fixup "$lib" "@loader_path/"
done
for exe in scrcpy aapt2; do
  fixup "$BIN/$exe" "@loader_path/../lib/"
done

# arm64 로드를 위해 수정된 모든 Mach-O를 ad-hoc 재서명
for f in "$BIN"/* "$LIB"/*.dylib; do
  codesign --force --sign - --timestamp=none "$f" 2>/dev/null || true
done

echo "vendor 준비 완료:"
du -sh "$VENDOR" || true
echo "dylib 수: $(ls "$LIB" | wc -l | tr -d ' ')"
