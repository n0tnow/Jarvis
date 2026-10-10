import AppKit

/// Draws the menu bar glyph for each `JarvisState`. Template images (system tints them for light/dark
/// menu bars). Every state has a *distinct shape*, so state is readable without colour:
///
///   idle      ring + centre dot          listening  ring + level bars
///   thinking  ring + travelling arc      working    ring + cycling dots
///   approval  ring + pause bars          complete   ring + check
///   error     triangle + exclamation
enum MenuBarIconRenderer {
    static let size = NSSize(width: 18, height: 18)

    /// Number of animation frames for animated states (kept low: the timer runs at ~3 Hz).
    static let frameCount = 4

    /// Images are tiny and there are only ~20 of them; caching avoids re-rasterizing on every animation tick.
    private static var cache: [String: NSImage] = [:]

    static func image(for state: JarvisState, frame: Int = 0) -> NSImage {
        let key = "\(state.rawValue)-\(frame)"
        if let cached = cache[key] { return cached }
        let image = render(state, frame: frame)
        cache[key] = image
        return image
    }

    private static func render(_ state: JarvisState, frame: Int) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let c = NSPoint(x: rect.midX, y: rect.midY)
            switch state {
            case .idle:
                ring(c, 7.2)
                dot(c, 1.6)
            case .listening:
                ring(c, 7.2)
                let heights: [[CGFloat]] = [[2.5, 5, 3], [4.5, 3, 5], [3, 5.5, 2.5], [5, 3.5, 4.5]]
                bars(c, heights[frame % heights.count])
            case .thinking:
                ring(c, 7.2, alpha: 0.35)
                let start = CGFloat(frame) * 90
                let path = NSBezierPath()
                path.appendArc(withCenter: c, radius: 7.2, startAngle: start, endAngle: start + 100)
                path.lineWidth = 1.8
                path.lineCapStyle = .round
                path.stroke()
                dot(c, 1.3)
            case .working:
                ring(c, 7.2)
                for i in 0..<3 {
                    let angle = (CGFloat(i) * 120 + 90) * .pi / 180
                    let p = NSPoint(x: c.x + cos(angle) * 3.3, y: c.y + sin(angle) * 3.3)
                    dot(p, i == frame % 3 ? 1.8 : 1.0)
                }
            case .waitingForApproval:
                ring(c, 7.2)
                NSBezierPath(roundedRect: NSRect(x: c.x - 2.8, y: c.y - 3, width: 1.8, height: 6), xRadius: 0.5, yRadius: 0.5).fill()
                NSBezierPath(roundedRect: NSRect(x: c.x + 1.0, y: c.y - 3, width: 1.8, height: 6), xRadius: 0.5, yRadius: 0.5).fill()
            case .completed:
                ring(c, 7.2)
                let check = NSBezierPath()
                check.move(to: NSPoint(x: c.x - 3, y: c.y))
                check.line(to: NSPoint(x: c.x - 0.8, y: c.y - 2.4))
                check.line(to: NSPoint(x: c.x + 3.2, y: c.y + 2.6))
                check.lineWidth = 1.6
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                check.stroke()
            case .error:
                let tri = NSBezierPath()
                tri.move(to: NSPoint(x: c.x, y: c.y + 7.6))
                tri.line(to: NSPoint(x: c.x + 7.6, y: c.y - 5.6))
                tri.line(to: NSPoint(x: c.x - 7.6, y: c.y - 5.6))
                tri.close()
                tri.lineWidth = 1.4
                tri.lineJoinStyle = .round
                tri.stroke()
                NSBezierPath(roundedRect: NSRect(x: c.x - 0.7, y: c.y - 2.2, width: 1.4, height: 4.4), xRadius: 0.5, yRadius: 0.5).fill()
                dot(NSPoint(x: c.x, y: c.y - 3.9), 0.8)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: Primitives

    private static func ring(_ c: NSPoint, _ r: CGFloat, alpha: CGFloat = 1) {
        let path = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        path.lineWidth = 1.4
        NSColor.black.withAlphaComponent(alpha).setStroke()
        path.stroke()
        NSColor.black.setStroke()
    }

    private static func dot(_ c: NSPoint, _ r: CGFloat) {
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
    }

    private static func bars(_ c: NSPoint, _ heights: [CGFloat]) {
        let width: CGFloat = 1.6, gap: CGFloat = 1.4
        let total = CGFloat(heights.count) * width + CGFloat(heights.count - 1) * gap
        var x = c.x - total / 2
        for h in heights {
            NSBezierPath(roundedRect: NSRect(x: x, y: c.y - h / 2, width: width, height: h), xRadius: 0.8, yRadius: 0.8).fill()
            x += width + gap
        }
    }
}
