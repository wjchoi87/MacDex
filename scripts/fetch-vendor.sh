#!/bin/bash
# MacDroid vendor bundling: adb, aapt2, scrcpy (+ recursive dylib collection, @loader_path rewrite), scrcpy-server
# Policy: the app must run standalone without external brew/SDK dependencies for end users.
# All bundled binaries are Apache-2.0 (AOSP adb/aapt2, scrcpy) — keep the notices in LICENSES/.
# arm64 requires valid signatures → every Mach-O modified with install_name_tool is re-signed ad-hoc at the end.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
BIN="$VENDOR/bin"; LIB="$VENDOR/lib"; SHARE="$VENDOR/share/scrcpy"

# Cache: skip if already prepared (force refresh: rm -rf Vendor)
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
  [[ -f "$f" ]] || { echo "missing required binary: $f (see README — brew install scrcpy xcodegen + Android SDK platform-tools/build-tools, or set ADB_SRC/AAPT2_SRC/SCRCPY_SRC)" >&2; exit 1; }
done

cp "$ADB_SRC"    "$BIN/adb"
cp "$AAPT2_SRC"  "$BIN/aapt2"
cp "$SCRCPY_SRC" "$BIN/scrcpy"
cp "$SERVER_SRC" "$SHARE/scrcpy-server"
chmod +x "$BIN/"*

# Recursively collect homebrew dependencies of scrcpy/aapt2 (and their dylibs) into lib/
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

# Rewrite load paths: libs use @loader_path/<name>, executables in bin/ use @loader_path/../lib/<name>
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

# Re-sign every modified Mach-O ad-hoc so arm64 can load it
for f in "$BIN"/* "$LIB"/*.dylib; do
  codesign --force --sign - --timestamp=none "$f" 2>/dev/null || true
done

echo "vendor ready:"
du -sh "$VENDOR" || true
echo "dylib count: $(ls "$LIB" | wc -l | tr -d ' ')"
