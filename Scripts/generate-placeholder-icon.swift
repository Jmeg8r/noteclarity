#!/usr/bin/env swift
// WHAT: Generates the placeholder AppIcon.appiconset (10 PNGs + Contents.json).
// WHY a script: zero-dependency, reproducible placeholder James can regenerate
// or replace with real artwork later. Run from the repo root:
//   swift Scripts/generate-placeholder-icon.swift
import AppKit

let outDir = URL(fileURLWithPath: "NoteClarity/Resources/Assets.xcassets/AppIcon.appiconset",
                 isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Brand green — matches NppGreen.colorset's light value (#2E9E44-ish).
let green = NSColor(srgbRed: 0.180, green: 0.620, blue: 0.267, alpha: 1)
let greenDark = NSColor(srgbRed: 0.129, green: 0.478, blue: 0.204, alpha: 1)

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
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225

    let gradient = NSGradient(starting: green, ending: greenDark)!
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    gradient.draw(in: path, angle: -90)

    // White "N" glyph, centered, sized to the tile.
    let fontSize = rect.height * 0.62
    let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    let glyph = "N" as NSString
    let gs = glyph.size(withAttributes: attrs)
    glyph.draw(at: NSPoint(x: rect.midX - gs.width / 2, y: rect.midY - gs.height / 2),
               withAttributes: attrs)

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
