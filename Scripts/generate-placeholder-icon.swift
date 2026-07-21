#!/usr/bin/env swift
// WHAT: Generates the AppIcon.appiconset (10 PNGs + Contents.json) — "The
//       Caret" from DESIGN.md: a hard-edged phosphor caret left-of-center with
//       three trailing dimmer text bars and a restrained bloom, on the app's
//       own flat dark editor field. No letter, no document, no pen.
// WHY a script: zero-dependency, reproducible; regenerate from the repo root:
//   swift Scripts/generate-placeholder-icon.swift
import AppKit

let outDir = URL(fileURLWithPath: "NoteClarity/Resources/Assets.xcassets/AppIcon.appiconset",
                 isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// DESIGN.md tokens: field = #161A16 (Phosphor editor background), caret =
// #3FE28A. One fixed appearance for light and dark systems.
let field = NSColor(srgbRed: 0x16 / 255.0, green: 0x1A / 255.0, blue: 0x16 / 255.0, alpha: 1)
let phosphor = NSColor(srgbRed: 0x3F / 255.0, green: 0xE2 / 255.0, blue: 0x8A / 255.0, alpha: 1)

struct IconSize {
    let point: Int
    let scale: Int
    var pixels: Int { point * scale }
    var filename: String { "icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png" }
}

let sizes = [16, 32, 128, 256, 512].flatMap { [IconSize(point: $0, scale: 1), IconSize(point: $0, scale: 2)] }

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .calibratedRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let s = CGFloat(pixels)
    // macOS icon grid: content inset ~10% on each side, continuous-ish corners.
    let inset = s * 0.10
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = tile.width * 0.225

    // Flat field — the hard rule bans gradients in chrome; the icon's field is
    // the same flat surface the app itself shows.
    field.setFill()
    NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius).fill()

    NSGraphicsContext.current?.cgContext.saveGState()
    NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius).addClip()

    // The caret: left-of-center like text at a margin.
    let caretWidth = max(1, tile.width * 0.075)
    let caretHeight = tile.height * 0.52
    let caretX = tile.minX + tile.width * 0.24
    let caretY = tile.midY - caretHeight / 2
    let caret = NSRect(x: caretX, y: caretY, width: caretWidth, height: caretHeight)

    // Restrained bloom behind the caret only; drops below 32 rendered pixels
    // (the 16px test is one green stroke + trailing mass, no glow).
    if pixels >= 32 {
        let bloomRadius = caretHeight * 0.45
        let bloom = NSGradient(colors: [phosphor.withAlphaComponent(0.22),
                                        phosphor.withAlphaComponent(0.0)])!
        bloom.draw(fromCenter: NSPoint(x: caret.midX, y: caret.midY), radius: 0,
                   toCenter: NSPoint(x: caret.midX, y: caret.midY), radius: bloomRadius,
                   options: [])
    }

    // Three trailing text bars, dimmer than the caret, ragged like real lines.
    let barHeight = max(1, tile.height * 0.075)
    let barGap = tile.height * 0.115
    let barX = caret.maxX + tile.width * 0.10
    let widths: [CGFloat] = [0.42, 0.30, 0.36]
    let alphas: [CGFloat] = [0.42, 0.30, 0.22]
    let stackHeight = barHeight * 3 + barGap * 2
    var barY = tile.midY + stackHeight / 2 - barHeight
    for (width, alpha) in zip(widths, alphas) {
        phosphor.withAlphaComponent(alpha).setFill()
        NSRect(x: barX, y: barY, width: tile.width * width, height: barHeight).fill()
        barY -= barHeight + barGap
    }

    // The caret itself: hard-edged, full phosphor, drawn over its bloom.
    phosphor.setFill()
    caret.fill()

    NSGraphicsContext.current?.cgContext.restoreGState()

    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for size in sizes {
    try render(size.pixels).write(to: outDir.appendingPathComponent(size.filename))
    images.append(["size": "\(size.point)x\(size.point)",
                   "idiom": "mac",
                   "filename": size.filename,
                   "scale": "\(size.scale)x"])
    print("wrote \(size.filename) (\(size.pixels)px)")
}

let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("Contents.json"))
print("wrote Contents.json (\(images.count) entries)")
