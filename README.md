# SnapMark

A small macOS tool for marking up screenshots. Take a screenshot to the clipboard,
press `Cmd+Shift+A`, and the window comes up with the image already pasted. Draw
arrows, boxes, circles, lines, freehand strokes, or text on it, press `Cmd+C`, and paste
the result into Slack, an issue, or a message. Nothing is written to disk.

The repo has two implementations of the same app:

| | `/` (root) | `snapmark-zig/` |
|---|---|---|
| UI | React 18 + Konva in a WKWebView | AppKit, drawn with Core Graphics |
| Shell | Tauri 2 (Rust) | Zig, with an Objective-C shim for AppKit |
| Status | Original, complete | Rewrite covering the same features; the Tauri version stays as the fallback until parity is signed off |

## Why there is a native rewrite

A tool like this gets opened many times a day for a few seconds each time, so launch
time and idle memory matter more than they would for most apps. The Tauri version
runs its UI in a system WebView, which means three extra WebKit processes alongside the
app and an 18 MB executable for what is a single-canvas program. The Zig version was
written to see how much of that goes away with a native AppKit UI, and the build has a
benchmark step (`zig build bench`) because measuring that was the point.

## Measurements

| | Tauri (`SnapMark.app`) | Zig (`snapmark-zig`) |
|---|---|---|
| Launch to window on screen, median of 10 | 202 ms (195 to 216) | 123 ms (119 to 137) |
| First launch after a fresh build | 819 ms | not measured comparably |
| RSS, app process | 103 MB | 76 MB |
| RSS, WebKit helper processes | 105 MB (3 processes) | none |
| RSS, total | 208 MB | 76 MB |
| Executable size | 18 MB | 119 KB |

How these were measured (MB and KB here are binary units, MiB and KiB):

- Machine: Apple M3 Pro, 18 GB RAM, macOS 26.6. Both apps built in release mode
  (`pnpm tauri build --bundles app`; Zig with `-OReleaseSmall`) and launched by running
  the executable directly, one app at a time, with an empty canvas.
- `bench/launchbench.swift` spawns the executable and polls
  `CGWindowListCopyWindowInfo` every 1 ms until a window owned by that process is on
  screen. For Tauri this is when the native window appears; the web content paints
  after that, so the real time until the Tauri UI is usable is somewhat longer than the
  number shown.
- RSS is read with `ps -o rss` 5 seconds after the window appears. WKWebView's
  content, networking, and GPU processes are XPC services rather than children of the
  app, so the harness records which `com.apple.WebKit.*` processes are new since the
  launch and sums them separately.
- Each app was launched 11 times. The table reports the median of runs 2 to 11; run 1
  is excluded as the only one that might hit a cold cache. Tauri's run 1 was its first
  launch after building and took 819 ms. The Zig binary had already been launched
  during setup, so it has no comparable first-launch number.
- RSS includes shared system framework pages, so it overstates private memory for both
  apps. It is still a fair side-by-side comparison, since both load AppKit.

To reproduce:

```bash
swiftc -O bench/launchbench.swift -o /tmp/launchbench
/tmp/launchbench src-tauri/target/release/bundle/macos/SnapMark.app/Contents/MacOS/snapmark 11 5
/tmp/launchbench snapmark-zig/zig-out/bin/snapmark-zig 11 5
```

## Features (both versions)

- Paste the clipboard image as the canvas background (`Cmd+V`), or show the window and
  paste in one step with the global shortcut `Cmd+Shift+A`
- Menu bar icon to bring the window back (the Zig version also pastes on click)
- Tools: select, pen, circle, rectangle, arrow, line, text (keys `1` to `7`)
- Hold Shift while dragging for a perfect circle or square
- Select, move, and resize shapes; delete with Backspace or Delete
- Color and stroke-width controls
- Undo and redo (`Cmd+Z`, `Cmd+Shift+Z`)
- Copy the annotated image back to the clipboard as PNG (`Cmd+C`)
- `Esc` hides the window

## Tauri version (repo root)

```
src/              React UI: Konva canvas, toolbar, zustand store, clipboard hooks
src-tauri/src/    Rust: clipboard image read/write (arboard + image), global shortcut, tray icon
```

Clipboard images move between Rust and the WebView as base64 PNG. The Rust side reads
the clipboard as RGBA, encodes it to PNG, and sends it to the UI; copying goes the
other way.

Requires Node 18+, pnpm, and a Rust toolchain.

```bash
pnpm install
pnpm tauri dev      # development
pnpm tauri build    # release bundle in src-tauri/target/release/bundle/
```

## Zig version (`snapmark-zig/`)

```
src/main.zig      entry point; exported callbacks the shim calls (input, draw, keys)
src/state.zig     app state: shape list, selection, undo/redo history, tool state
src/shapes.zig    shape union (pen, circle, rect, arrow, line, text) with u64 ids
src/math.zig      hit-testing, bounds, resize-handle geometry
src/drawing.zig   Core Graphics rendering of the background image and shapes
src/shim.m        Objective-C: NSApplication, window, canvas NSView, toolbar,
                  NSPasteboard, status item, Carbon global hotkey, text field
src/bridge.h      the C interface between the two
```

The app logic lives in Zig and has no AppKit dependency. AppKit calls into it through a
small C interface (`bridge.h`): the view forwards mouse and key events and asks Zig to
draw into a `CGContext` it provides.

Requires Zig 0.15.2 and the Xcode command line tools.

```bash
cd snapmark-zig
zig build run          # build and launch
zig build release      # ad-hoc-signed .app in zig-out/
zig build dmg          # .dmg in zig-out/
zig build bench        # startup / RSS / CPU harness
```

On macOS 26, Zig 0.15.2 cannot link against the macOS 26 SDK, so `zig build` fails
while linking its own build runner (undefined `_abort`, `_bzero`, and so on). Until a
Zig release fixes that, the binary can be built directly against a macOS 15 SDK, if
the command line tools have one installed:

```bash
cd snapmark-zig
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk
mkdir -p zig-out/bin
zig build-exe -OReleaseSmall -target aarch64-macos.15.0 \
  -L $SDK/usr/lib -F $SDK/System/Library/Frameworks \
  -isystem $SDK/usr/include -iframework $SDK/System/Library/Frameworks \
  -I src src/main.zig -cflags -fobjc-arc -- src/shim.m \
  -lc -lobjc -framework AppKit -framework Foundation -framework CoreGraphics \
  -framework CoreText -framework Carbon -framework ApplicationServices \
  --name snapmark-zig -femit-bin=zig-out/bin/snapmark-zig
```

See `snapmark-zig/README.md` for signing options.
