#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/zig-out/SnapMark.app"
DMG_PATH="$ROOT_DIR/zig-out/SnapMark.dmg"

if [[ ! -d "$APP_DIR" ]]; then
  echo "App bundle not found at $APP_DIR (run scripts/make_app.sh first)"
  exit 1
fi

# Stage the app next to an Applications link so the DMG opens as drag-to-install.
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT
cp -R "$APP_DIR" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create -volname "SnapMark" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null
echo "Created $DMG_PATH"
