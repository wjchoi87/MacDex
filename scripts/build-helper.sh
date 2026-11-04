#!/bin/bash
# Build the on-device app indexer (Helper/AppIndex) into Vendor/share/macdroid/appindex.jar.
# Why: the phone's launcher list with real labels/icons comes from PackageManager on the device —
# pulling every APK through aapt2 was slow and missed most adaptive icons.
# Requires the Android SDK (platforms/android-*, build-tools/*/d8) and a JDK — same SDK as fetch-vendor.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Helper/AppIndex/src"
OUT_DIR="$ROOT/Vendor/share/macdroid"
OUT="$OUT_DIR/appindex.jar"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

# Up to date: skip
if [[ -f "$OUT" && -z "$(find "$SRC" -name '*.java' -newer "$OUT")" ]]; then
  echo "appindex.jar up to date"
  exit 0
fi

ANDROID_JAR="${ANDROID_JAR:-$(ls "$SDK"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1)}"
D8="${D8:-$(ls "$SDK"/build-tools/*/d8 2>/dev/null | sort -V | tail -1)}"
[[ -f "$ANDROID_JAR" && -x "$D8" ]] || { echo "missing Android SDK android.jar / d8 (set ANDROID_HOME)" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/classes" "$OUT_DIR"
javac --release 11 -cp "$ANDROID_JAR" -d "$TMP/classes" $(find "$SRC" -name '*.java')
"$D8" --min-api 26 --lib "$ANDROID_JAR" --output "$TMP" $(find "$TMP/classes" -name '*.class')
(cd "$TMP" && jar cf "$OUT" classes.dex)
echo "built $OUT"
