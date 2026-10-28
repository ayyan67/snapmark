#!/usr/bin/env bash
# Checks the clipboard round trip: puts a Retina screenshot on the clipboard,
# runs SnapMark in self-test mode (draws an arrow, copies), and verifies the
# copied PNG has exactly the screenshot's pixel size and DPI, with untouched
# opaque corners (no padding or transparent border).
#
# Note: this replaces whatever is on the clipboard.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${1:-$ROOT_DIR/zig-out/bin/snapmark}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

screencapture -x -R 100,100,700,450 "$WORK/in.png"
osascript -e "set the clipboard to (read (POSIX file \"$WORK/in.png\") as «class PNGf»)"

SNAPMARK_SELFTEST=1 "$BIN" 2>&1 | grep selftest_copy

osascript -e "set f to open for access (POSIX file \"$WORK/out.png\") with write permission" \
          -e "write (the clipboard as «class PNGf») to f" -e "close access f"

python3 -I - "$WORK/in.png" "$WORK/out.png" <<'PY'
import struct, sys, zlib

def read_png(path):
    data = open(path, "rb").read()
    pos, chunks = 8, {}
    idat = b""
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IDAT":
            idat += body
        else:
            chunks.setdefault(kind, body)
        pos += 12 + length
    w, h, depth, color = struct.unpack(">IIBB", chunks[b"IHDR"][:10])
    dpi = None
    if b"pHYs" in chunks:
        ppu, _, unit = struct.unpack(">IIB", chunks[b"pHYs"])
        dpi = round(ppu * 0.0254) if unit == 1 else None
    return w, h, depth, color, dpi, idat

def corner_alphas(w, h, depth, color, idat):
    if color != 6 or depth != 8:
        return None  # no alpha channel: corners are opaque by definition
    raw = zlib.decompress(idat)
    bpp, stride = 4, w * 4
    rows, prev = [], bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line
    return [rows[y][x * 4 + 3] for y, x in ((0, 0), (0, w - 1), (h - 1, 0), (h - 1, w - 1))]

iw, ih, *_rest, idpi, _ = read_png(sys.argv[1])
ow, oh, depth, color, odpi, idat = read_png(sys.argv[2])
alphas = corner_alphas(ow, oh, depth, color, idat)
print(f"input  {iw}x{ih} dpi={idpi}")
print(f"output {ow}x{oh} dpi={odpi} corner_alpha={alphas}")
ok = (iw, ih) == (ow, oh) and (alphas is None or all(a == 255 for a in alphas))
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PY
