#!/usr/bin/env bash
# Builds the SnapMark executable into zig-out/bin/snapmark.
#
# This calls `zig build-exe` directly instead of `zig build`: Zig 0.15.2 cannot
# link its own build runner against the macOS 26 SDK, so on macOS 26 the build
# has to target an older SDK. A macOS 15 SDK is used when one is installed.
#
# SNAPMARK_UNIVERSAL=1 builds for both arm64 and x86_64 and joins them with lipo.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OPTIMIZE="${SNAPMARK_OPTIMIZE:-ReleaseSmall}"
ARCH="$(uname -m)"
[[ "$ARCH" == "arm64" ]] && ARCH="aarch64"

SDK="${SNAPMARK_SDK:-}"
if [[ -z "$SDK" ]]; then
  for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX15*.sdk; do
    [[ -d "$candidate" ]] && SDK="$candidate"
  done
fi
[[ -z "$SDK" ]] && SDK="$(xcrun --show-sdk-path)"

build_arch() {
  zig build-exe "-O$OPTIMIZE" -target "$1-macos.13.0" \
    -L "$SDK/usr/lib" -F "$SDK/System/Library/Frameworks" \
    -isystem "$SDK/usr/include" -iframework "$SDK/System/Library/Frameworks" \
    -I src src/main.zig -cflags -fobjc-arc -Wall -- src/shim.m \
    -lc -lobjc -framework AppKit -framework Foundation -framework CoreGraphics -framework CoreText -framework Carbon \
    --name snapmark -femit-bin="$2"
}

mkdir -p zig-out/bin
if [[ "${SNAPMARK_UNIVERSAL:-0}" == "1" ]]; then
  build_arch aarch64 zig-out/bin/snapmark-arm64
  build_arch x86_64 zig-out/bin/snapmark-x86_64
  lipo -create zig-out/bin/snapmark-arm64 zig-out/bin/snapmark-x86_64 -output zig-out/bin/snapmark
  rm zig-out/bin/snapmark-arm64 zig-out/bin/snapmark-x86_64
  ARCH="universal"
else
  build_arch "$ARCH" zig-out/bin/snapmark
fi

echo "Built zig-out/bin/snapmark ($ARCH, $OPTIMIZE, SDK $(basename "$SDK"))"
