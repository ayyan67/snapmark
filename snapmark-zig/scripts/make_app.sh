#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_PATH="$ROOT_DIR/zig-out/bin/snapmark-zig"
APP_DIR="$ROOT_DIR/zig-out/SnapMarkZig.app"
SIGN_IDENTITY="${SNAPMARK_CODESIGN_IDENTITY:--}"
ENTITLEMENTS_PATH="${SNAPMARK_CODESIGN_ENTITLEMENTS:-}"

if [[ ! -x "$BIN_PATH" ]]; then
  echo "Expected binary not found at $BIN_PATH"
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/SnapMarkZig"
chmod +x "$APP_DIR/Contents/MacOS/SnapMarkZig"
cp "$ROOT_DIR/resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [[ -f "$ROOT_DIR/resources/icon_16x16.png" ]]; then
  cp "$ROOT_DIR/resources/icon_16x16.png" "$APP_DIR/Contents/Resources/icon_16x16.png"
fi

if [[ -n "$ENTITLEMENTS_PATH" ]]; then
  if [[ ! -f "$ENTITLEMENTS_PATH" ]]; then
    echo "Entitlements file not found: $ENTITLEMENTS_PATH"
    exit 1
  fi
fi

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$APP_DIR"
else
  CODESIGN_ARGS=(--force --deep --sign "$SIGN_IDENTITY" --options runtime --timestamp)
  if [[ -n "$ENTITLEMENTS_PATH" ]]; then
    CODESIGN_ARGS+=(--entitlements "$ENTITLEMENTS_PATH")
  fi
  codesign "${CODESIGN_ARGS[@]}" "$APP_DIR"
fi

codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "Created app bundle: $APP_DIR"
echo "Code signed app with identity: $SIGN_IDENTITY"
