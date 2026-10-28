// Renders resources/AppIcon.icns. Run from the repo root:
//   swift scripts/make_icon.swift
import AppKit

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icon grid: the tile is 824/1024 of the canvas.
    let tile = NSRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(starting: NSColor(srgbRed: 0.33, green: 0.56, blue: 1.0, alpha: 1),
               ending: NSColor(srgbRed: 0.36, green: 0.27, blue: 0.93, alpha: 1))!.draw(in: path, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    let name = NSImage(systemSymbolName: "pencil.and.scribble", accessibilityDescription: nil) != nil
        ? "pencil.and.scribble" : "scribble"
    if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = symbol.size
        symbol.draw(in: NSRect(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2,
                               width: size.width, height: size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "resources/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote resources/AppIcon.icns" : "iconutil failed")
