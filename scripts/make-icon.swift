import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (name, pixels) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale); transform.concat()
    let background = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 196, yRadius: 196)
    NSGradient(starting: NSColor(red: 0.37, green: 0.52, blue: 0.42, alpha: 1), ending: NSColor(red: 0.18, green: 0.31, blue: 0.25, alpha: 1))!.draw(in: background, angle: -70)
    for (x, y, alpha) in [(270.0, 260.0, 0.30), (235.0, 320.0, 0.55), (200.0, 380.0, 1.0)] {
        NSColor(white: 0.96, alpha: alpha).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 545, height: 330), xRadius: 55, yRadius: 55).fill()
    }
    NSColor(red: 0.32, green: 0.47, blue: 0.38, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 261, y: 443, width: 13, height: 204), xRadius: 6, yRadius: 6).fill()
    for (width, y) in [(300.0, 606.0), (230.0, 546.0), (270.0, 486.0)] {
        NSColor(red: 0.32, green: 0.47, blue: 0.38, alpha: 0.40).setFill()
        NSBezierPath(roundedRect: NSRect(x: 317, y: y, width: width, height: 18), xRadius: 9, yRadius: 9).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
}
