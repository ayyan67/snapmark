#!/usr/bin/env bash
# Wraps zig-out/bin/snapmark into a signed zig-out/SnapMark.app.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_PATH="$ROOT_DIR/zig-out/bin/snapmark"
APP_DIR="$ROOT_DIR/zig-out/SnapMark.app"
SIGN_IDENTITY="${SNAPMARK_CODESIGN_IDENTITY:--}"
ENTITLEMENTS_PATH="${SNAPMARK_CODESIGN_ENTITLEMENTS:-}"

if [[ ! -x "$BIN_PATH" ]]; then
  echo "Expected binary not found at $BIN_PATH (run scripts/build.sh first)"
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/SnapMark"
cp "$ROOT_DIR/resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP_DIR"
else
  ARGS=(--force --sign "$SIGN_IDENTITY" --options runtime --timestamp)
  [[ -n "$ENTITLEMENTS_PATH" ]] && ARGS+=(--entitlements "$ENTITLEMENTS_PATH")
  codesign "${ARGS[@]}" "$APP_DIR"
fi
codesign --verify --strict "$APP_DIR"

echo "Created $APP_DIR (signed: $SIGN_IDENTITY)"
