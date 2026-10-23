// Draws the VoiceBar app icon and writes Icon/AppIcon.icns.
// Run: swiftc Icon/make_icon.swift -o /tmp/make_icon && /tmp/make_icon   (from macos/)
import AppKit

let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Rounded-square body on Apple's icon grid (824 pt inside a 1024 pt canvas).
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

// Coral to violet, top left to bottom right.
NSGradient(colors: [
    NSColor(srgbRed: 1.00, green: 0.55, blue: 0.35, alpha: 1),
    NSColor(srgbRed: 0.93, green: 0.30, blue: 0.55, alpha: 1),
    NSColor(srgbRed: 0.45, green: 0.30, blue: 0.95, alpha: 1),
])!.draw(in: shape, angle: -45)

// Soft highlight across the top half.
NSGraphicsContext.saveGraphicsState()
shape.addClip()
NSGradient(starting: NSColor.white.withAlphaComponent(0.22), ending: .clear)!
    .draw(in: NSRect(x: 100, y: 512, width: 824, height: 412), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Sound waves either side of the microphone, fading outwards.
let centre = NSPoint(x: 512, y: 500)
for (i, radius) in [230.0, 310.0].enumerated() {
    NSColor.white.withAlphaComponent(i == 0 ? 0.85 : 0.5).setStroke()
    for start in [-38.0, 142.0] {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: centre, radius: radius, startAngle: start, endAngle: start + 76)
        arc.lineWidth = 34
        arc.lineCapStyle = .round
        arc.stroke()
    }
}

// The microphone itself, a white SF Symbol.
let config = NSImage.SymbolConfiguration(pointSize: 330, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)!
    .withSymbolConfiguration(config)!
mic.draw(in: NSRect(x: centre.x - mic.size.width / 2, y: centre.y - mic.size.height / 2,
                    width: mic.size.width, height: mic.size.height))

// Three small sparkles for fun.
NSColor.white.setFill()
for (x, y, r) in [(745.0, 770.0, 26.0), (800.0, 700.0, 14.0), (250.0, 760.0, 18.0)] {
    let star = NSBezierPath()
    for k in 0..<8 {
        let angle = Double(k) * .pi / 4
        let len = k.isMultiple(of: 2) ? r : r * 0.32
        let p = NSPoint(x: x + len * cos(angle), y: y + len * sin(angle))
        k == 0 ? star.move(to: p) : star.line(to: p)
    }
    star.close()
    star.fill()
}

NSGraphicsContext.current = nil

// Write every size iconutil expects, then pack them into AppIcon.icns.
let dir = URL(fileURLWithPath: "Icon")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let full = NSImage(size: NSSize(width: size, height: size))
full.addRepresentation(rep)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSGraphicsContext.current?.imageInterpolation = .high
        full.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.current = nil
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try out.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", dir.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "wrote Icon/AppIcon.icns" : "iconutil failed")
