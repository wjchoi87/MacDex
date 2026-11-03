#!/bin/bash
# Copy Vendor binaries into the .app bundle after the build.
# Why post-build instead of an Xcode resources phase:
# Vendor/ is a generated artifact (produced by fetch-vendor.sh, gitignored), so it is not part of Xcode file syncing.
set -euo pipefail
APP="${1:?usage: install-vendor.sh <app-bundle> <project-dir>}"
PROJECT="${2:?usage: install-vendor.sh <app-bundle> <project-dir>}"

"$PROJECT/scripts/fetch-vendor.sh"

DEST="$APP/Contents/Resources"
mkdir -p "$DEST"
rsync -a --delete "$PROJECT/Vendor/bin/"   "$DEST/bin/"
rsync -a --delete "$PROJECT/Vendor/lib/"   "$DEST/lib/"
rsync -a --delete "$PROJECT/Vendor/share/" "$DEST/share/"
mkdir -p "$DEST/LICENSES"
cp "$PROJECT/LICENSES/"*.txt "$DEST/LICENSES/" 2>/dev/null || true
cp "$PROJECT/LICENSES/NOTICE.md" "$DEST/LICENSES/" 2>/dev/null || true

echo "installed vendor into $DEST"
