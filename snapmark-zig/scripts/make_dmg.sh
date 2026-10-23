#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/zig-out/SnapMarkZig.app"
DMG_PATH="$ROOT_DIR/zig-out/SnapMarkZig.dmg"
TMP_DMG="$(mktemp -u /tmp/SnapMarkZig.XXXXXX.dmg)"

if [[ ! -d "$APP_DIR" ]]; then
  echo "App bundle not found at $APP_DIR"
  echo "Run: zig build release"
  exit 1
fi

rm -f "$DMG_PATH"
hdiutil create -volname "SnapMarkZig" -srcfolder "$APP_DIR" -ov -format UDZO "$TMP_DMG" >/dev/null
mv "$TMP_DMG" "$DMG_PATH"

echo "Created DMG: $DMG_PATH"
