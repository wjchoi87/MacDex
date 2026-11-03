#!/bin/bash
# 빌드 후 Vendor 바이너리를 .app 번들로 복사.
# Xcode 리소스 페이즈가 아니라 post-build에서 복사하는 이유:
# Vendor/는 fetch-vendor.sh가 생성하는 산출물(.gitignore 대상)이라 Xcode 파일 동기화 대상이 아님.
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
