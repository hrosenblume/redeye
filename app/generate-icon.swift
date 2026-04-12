#!/usr/bin/swift
import AppKit

// Icon sizes required for macOS .iconset
let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func drawIcon(size: Int) -> Data? {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let g = ctx.cgContext

    let center = CGPoint(x: s / 2, y: s / 2)

    // macOS icon grid: ~10% inset on each side so the icon isn't oversized in the Dock
    let inset = s * 0.10
    let iconSize = s - inset * 2
    let iconRect = CGRect(x: inset, y: inset, width: iconSize, height: iconSize)

    // --- Background: dark rounded rect ---
    let cornerRadius = iconSize * 0.22
    let bgPath = CGPath(roundedRect: iconRect,
                        cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    g.setFillColor(CGColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1.0))
    g.addPath(bgPath)
    g.fillPath()

    // Subtle radial gradient behind the eye for depth
    g.saveGState()
    g.addPath(bgPath)
    g.clip()
    let bgGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.20, green: 0.03, blue: 0.03, alpha: 1.0),
            CGColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1.0),
        ] as CFArray,
        locations: [0.0, 1.0])!
    g.drawRadialGradient(bgGradient,
        startCenter: center, startRadius: 0,
        endCenter: center, endRadius: s * 0.45,
        options: .drawsAfterEndLocation)
    g.restoreGState()

    // --- Outer glow ring ---
    let glowGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.9, green: 0.15, blue: 0.1, alpha: 0.35),
            CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 0.0),
        ] as CFArray,
        locations: [0.0, 1.0])!
    g.drawRadialGradient(glowGradient,
        startCenter: center, startRadius: s * 0.17,
        endCenter: center, endRadius: s * 0.32,
        options: [])

    // --- Iris: radial gradient from bright red to dark red ---
    let irisRadius = s * 0.20
    let irisGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.95, green: 0.20, blue: 0.15, alpha: 1.0),
            CGColor(red: 0.70, green: 0.08, blue: 0.05, alpha: 1.0),
            CGColor(red: 0.45, green: 0.03, blue: 0.02, alpha: 1.0),
        ] as CFArray,
        locations: [0.0, 0.6, 1.0])!

    g.saveGState()
    g.addEllipse(in: CGRect(x: center.x - irisRadius, y: center.y - irisRadius,
                             width: irisRadius * 2, height: irisRadius * 2))
    g.clip()
    g.drawRadialGradient(irisGradient,
        startCenter: center, startRadius: 0,
        endCenter: center, endRadius: irisRadius,
        options: [])
    g.restoreGState()

    // --- Thin bright ring around the iris edge ---
    g.setStrokeColor(CGColor(red: 0.85, green: 0.12, blue: 0.08, alpha: 0.7))
    g.setLineWidth(max(1, s * 0.012))
    g.addEllipse(in: CGRect(x: center.x - irisRadius, y: center.y - irisRadius,
                             width: irisRadius * 2, height: irisRadius * 2))
    g.strokePath()

    // --- Pupil ---
    let pupilRadius = s * 0.08
    g.setFillColor(CGColor(red: 0.02, green: 0.02, blue: 0.04, alpha: 1.0))
    g.fillEllipse(in: CGRect(x: center.x - pupilRadius, y: center.y - pupilRadius,
                              width: pupilRadius * 2, height: pupilRadius * 2))

    // --- Specular highlight (upper-left of pupil) ---
    let hlRadius = s * 0.038
    let hlCenter = CGPoint(x: center.x - s * 0.05, y: center.y + s * 0.055)
    g.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.92))
    g.fillEllipse(in: CGRect(x: hlCenter.x - hlRadius, y: hlCenter.y - hlRadius,
                              width: hlRadius * 2, height: hlRadius * 2))

    // --- Smaller secondary highlight ---
    let hl2Radius = s * 0.017
    let hl2Center = CGPoint(x: center.x + s * 0.06, y: center.y - s * 0.04)
    g.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.5))
    g.fillEllipse(in: CGRect(x: hl2Center.x - hl2Radius, y: hl2Center.y - hl2Radius,
                              width: hl2Radius * 2, height: hl2Radius * 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// --- Main ---
let fm = FileManager.default
let scriptDir = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconsetDir = scriptDir.appendingPathComponent("Redeye.iconset")

try? fm.removeItem(at: iconsetDir)
try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

for (name, px) in sizes {
    guard let data = drawIcon(size: px) else {
        fputs("Failed to render \(name)\n", stderr)
        exit(1)
    }
    try data.write(to: iconsetDir.appendingPathComponent(name))
    print("  \(name) (\(px)x\(px))")
}

// Convert to .icns
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["--convert", "icns", iconsetDir.path]
try task.run()
task.waitUntilExit()

guard task.terminationStatus == 0 else {
    fputs("iconutil failed with status \(task.terminationStatus)\n", stderr)
    exit(1)
}

// Clean up the iconset directory
try? fm.removeItem(at: iconsetDir)

print("Generated Redeye.icns")
