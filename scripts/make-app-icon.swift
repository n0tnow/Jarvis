// Draws JARVIS' TEMPORARY application icon (the same ice-cyan "core" ring as the menu-bar mark on the HUD's ink background) into an .iconset folder. No external image, no generator model.
// Replace it any time by dropping a finished Resources/AppIcon.icns into the repository: scripts/package-app.sh prefers that file and skips this script.
// Usage: swift scripts/make-app-icon.swift <output.iconset>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ink = NSColor(red: 0.020, green: 0.035, blue: 0.060, alpha: 1), cyan = NSColor(red: 0.47, green: 0.82, blue: 0.96, alpha: 1)
    // macOS icon grid: the artwork occupies ~80 % of the canvas.
    let inset = s * 0.10, body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.06, green: 0.10, blue: 0.16, alpha: 1), ink])!.draw(in: shape, angle: -90)
    NSColor.white.withAlphaComponent(0.10).setStroke(); shape.lineWidth = max(1, s * 0.004); shape.stroke()
    let c = NSPoint(x: s / 2, y: s / 2)
    for (r, a, w) in [(0.30, 0.95, 0.030), (0.215, 0.55, 0.014), (0.10, 1.0, 0.0)] as [(CGFloat, CGFloat, CGFloat)] {
        let rect = NSRect(x: c.x - s * r, y: c.y - s * r, width: s * r * 2, height: s * r * 2)
        let p = NSBezierPath(ovalIn: rect)
        if w == 0 { cyan.withAlphaComponent(a).setFill(); p.fill() } else { cyan.withAlphaComponent(a).setStroke(); p.lineWidth = s * w; p.stroke() }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: out).appendingPathComponent("icon_\(name).png"))
}
print("wrote \(out)")
