#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIG_APP="$ROOT_DIR/zig-out/SnapMarkZig.app"
ZIG_DMG="$ROOT_DIR/zig-out/SnapMarkZig.dmg"
TAURI_APP_DEFAULT="$ROOT_DIR/../src-tauri/target/release/bundle/macos/SnapMark.app"
TAURI_APP="${TAURI_APP_PATH:-$TAURI_APP_DEFAULT}"
REPORT_PATH="$ROOT_DIR/zig-out/acceptance-report.md"

OPEN_APPS=0
if [[ "${1:-}" == "--open" ]]; then
  OPEN_APPS=1
fi

if [[ ! -d "$ZIG_APP" ]]; then
  echo "Missing Zig app bundle: $ZIG_APP"
  echo "Run: zig build release"
  exit 1
fi

if [[ ! -f "$ZIG_DMG" ]]; then
  echo "Missing Zig DMG: $ZIG_DMG"
  echo "Run: zig build dmg"
  exit 1
fi

mkdir -p "$ROOT_DIR/zig-out"

zig_app_size="$(du -sh "$ZIG_APP" | awk '{print $1}')"
zig_dmg_size="$(du -sh "$ZIG_DMG" | awk '{print $1}')"
zig_signer="$(codesign -dv --verbose=4 "$ZIG_APP" 2>&1 | rg '^Authority=' | head -n 1 | cut -d'=' -f2- || true)"
if [[ -z "$zig_signer" ]]; then
  zig_signer="ad-hoc or unsigned metadata"
fi

tauri_exists="no"
tauri_app_size="n/a"
if [[ -d "$TAURI_APP" ]]; then
  tauri_exists="yes"
  tauri_app_size="$(du -sh "$TAURI_APP" | awk '{print $1}')"
fi

if [[ $OPEN_APPS -eq 1 ]]; then
  open "$ZIG_APP"
  if [[ "$tauri_exists" == "yes" ]]; then
    open "$TAURI_APP"
  fi
fi

cat >"$REPORT_PATH" <<EOF
# SnapMark Zig Phase 6 Acceptance Report

Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

## Artifact Summary

| Artifact | Exists | Size | Path |
|---|---|---|---|
| Zig .app | yes | $zig_app_size | \`$ZIG_APP\` |
| Zig .dmg | yes | $zig_dmg_size | \`$ZIG_DMG\` |
| Tauri fallback .app | $tauri_exists | $tauri_app_size | \`$TAURI_APP\` |

## Signing Summary

- Zig app signer: \`$zig_signer\`
- Verify command: \`codesign --verify --deep --strict --verbose=2 "$ZIG_APP"\`

## Side-By-Side Manual Checklist

1. Launch Zig app and Tauri app (if available).
2. Paste screenshot in both apps and verify image fidelity.
3. Draw all tools: pen, circle (+Shift), rect (+Shift), arrow, line, text.
4. Select, move, resize, delete, and validate undo/redo behavior.
5. Validate shortcuts: Cmd/Ctrl+Z, Cmd/Ctrl+Shift+Z, Cmd/Ctrl+C/V, Esc, Delete/Backspace, 1..7.
6. Validate menu bar and global hotkey: Cmd+Shift+A should show window and paste clipboard.
7. Copy result and paste into Slack or Messages; confirm PNG roundtrip.
8. Confirm fallback remains available: existing Tauri app still launches when needed.

## Signoff Gate

- Keep Tauri as primary fallback until this checklist is signed off.
- Promote Zig build only after parity and stability are confirmed.
EOF

echo "Wrote acceptance report: $REPORT_PATH"
