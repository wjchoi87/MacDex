#!/bin/bash
# Build MacDroid.app + the macdroid CLI (Release) and package them for a GitHub release.
#   ./scripts/package-release.sh            → dist/MacDroid-<version>-macos-arm64.zip, dist/macdroid-cli-<version>-macos-arm64.zip
#   ./scripts/package-release.sh --publish  → also creates the GitHub release v<version> with those files (needs gh)
# The app is signed with the local self-signed identity (no Apple notarization) — first launch needs
# right-click → Open (or System Settings → Privacy & Security → Open Anyway). See README "Install".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' project.yml)"
[[ -n "$VERSION" ]] || { echo "MARKETING_VERSION not found in project.yml" >&2; exit 1; }
DERIVED="$ROOT/build/DerivedData"
PRODUCTS="$DERIVED/Build/Products/Release"
DIST="$ROOT/dist"

xcodegen generate >/dev/null
for scheme in MacDroid macdroid; do
  xcodebuild -project MacDroid.xcodeproj -scheme "$scheme" -configuration Release build \
    -derivedDataPath "$DERIVED" -quiet
done

rm -rf "$DIST"
mkdir -p "$DIST"
APP_ZIP="$DIST/MacDroid-$VERSION-macos-arm64.zip"
CLI_ZIP="$DIST/macdroid-cli-$VERSION-macos-arm64.zip"
# ditto keeps the bundle's symlinks, extended attributes and code signature intact
ditto -c -k --sequesterRsrc --keepParent "$PRODUCTS/MacDroid.app" "$APP_ZIP"
# CLI는 파일 하나 — 경로 없이 'macdroid'만 들어가게 임시 폴더에서 묶는다
STAGE="$(mktemp -d)"
cp "$PRODUCTS/macdroid" "$STAGE/macdroid"
ditto -c -k "$STAGE" "$CLI_ZIP"
rm -rf "$STAGE"
(cd "$DIST" && shasum -a 256 ./*.zip > SHA256SUMS.txt)

echo "MacDroid $VERSION"
ls -lh "$DIST"
cat "$DIST/SHA256SUMS.txt"

if [[ "${1:-}" == "--publish" ]]; then
  NOTES="$ROOT/scripts/release-notes.md"
  [[ -f "$NOTES" ]] || { echo "missing $NOTES" >&2; exit 1; }
  sed "s/<version>/$VERSION/g" "$NOTES" > "$DIST/release-notes.md"
  gh release create "v$VERSION" "$APP_ZIP" "$CLI_ZIP" "$DIST/SHA256SUMS.txt" \
    --title "MacDroid $VERSION" --notes-file "$DIST/release-notes.md"
fi
