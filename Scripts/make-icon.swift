// Renders the app icon into an .iconset directory:
//   swift Scripts/make-icon.swift <output.iconset> <source.png>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let source = NSImage(contentsOfFile: CommandLine.arguments[2])!

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)
    let inset = size * 0.085
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.width * 0.2237)

    // The original Metrolist artwork, masked to the macOS icon shape.
    NSGraphicsContext.current?.imageInterpolation = .high
    path.addClip()
    // The source has a plain black field, so it can be enlarged to give the glyph more presence.
    source.draw(in: rect.insetBy(dx: -rect.width * 0.11, dy: -rect.height * 0.11), from: .zero, operation: .sourceOver, fraction: 1)
    // A soft top light and a hairline rim, so the black tile's edge is visible on a dark Dock.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0.0)])!
        .draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: 90)
    NSColor.white.withAlphaComponent(0.22).setStroke()
    let rim = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.004, dy: size * 0.004), xRadius: rect.width * 0.2237, yRadius: rect.width * 0.2237)
    rim.lineWidth = max(1, size * 0.008)
    rim.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try render(points * scale).write(to: output.appendingPathComponent(name))
}
