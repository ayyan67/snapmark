# SnapMark

SnapMark is a lightweight desktop annotation tool built with Tauri, React, and Konva. It is designed for fast clipboard-driven screenshot markup.

## Prerequisites

- Node.js 18+
- pnpm
- Rust toolchain (for Tauri backend)

## Development

```bash
pnpm install
pnpm tauri dev
```

## Build

```bash
pnpm build
pnpm tauri build
```

## Keyboard Shortcuts

- `Cmd/Ctrl+V`: Paste image from clipboard
- `Cmd/Ctrl+C`: Copy annotated canvas to clipboard
- `Cmd/Ctrl+Z`: Undo
- `Cmd/Ctrl+Shift+Z`: Redo
- `Backspace/Delete`: Delete selected shape
- `Esc`: Hide window
- `1..7`: Switch tools (Select, Pen, Circle, Rectangle, Arrow, Line, Text)
- `Cmd/Ctrl+Shift+A`: Global shortcut to show window and trigger paste flow
