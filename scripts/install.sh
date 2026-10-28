#!/usr/bin/env bash
# Builds SnapMark, replaces /Applications/SnapMark.app, and launches it.
# The previous copy is moved to the Trash, not deleted.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${SNAPMARK_INSTALL_DIR:-/Applications}/SnapMark.app"

"$ROOT_DIR/scripts/build.sh"
"$ROOT_DIR/scripts/make_app.sh"

# Quit any running copy (the native build and the old Tauri build).
osascript -e 'tell application id "com.snapmark.annotator" to quit' >/dev/null 2>&1 || true
pkill -x SnapMark >/dev/null 2>&1 || true
pkill -x snapmark >/dev/null 2>&1 || true
sleep 0.5

if [[ -e "$DEST" ]]; then
  osascript -e "tell application \"Finder\" to delete (POSIX file \"$DEST\" as alias)" >/dev/null \
    || { echo "Could not move the old $DEST to the Trash"; exit 1; }
fi
ditto "$ROOT_DIR/zig-out/SnapMark.app" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
open "$DEST"

echo "Installed $DEST"
