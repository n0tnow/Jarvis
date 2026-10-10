import AppKit

/// Pure Core Graphics drawing for the JARVIS core. Geometry is a fraction of the radius `r`, so it scales to any size.
/// The context is expected to be y-down (flipped view): angles are in degrees, clockwise on screen from 3 o'clock.
struct CoreRenderer {
    let state: JarvisState
    let steps: [StepStatus]
    let tint: NSColor
    /// Seconds since the state was entered (∞ when static).
    let sinceEnter: Double
    /// Absolute animation clock; 0 when static.
    let time: Double

    func draw(in ctx: CGContext, size: CGSize) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let r = min(size.width, size.height) / 2
        ctx.translateBy(x: size.width / 2, y: size.height / 2)

        drawAmbient(ctx, r)
        drawTicks(ctx, r)
        strokeCircle(ctx, r * 0.89, white(0.14), 0.8)
        strokeCircle(ctx, r * 0.50, white(0.10), 0.8)

        switch state {
        case .idle: drawIdle(ctx, r)
        case .listening: drawListening(ctx, r)
        case .thinking: drawThinking(ctx, r)
        case .working: drawWorking(ctx, r)
        case .waitingForApproval: drawWaiting(ctx, r)
        case .completed: drawCompleted(ctx, r)
        case .error: drawError(ctx, r)
        }
    }

    // MARK: Shared layers

    private func drawAmbient(_ ctx: CGContext, _ r: CGFloat) {
        let pulse: Double
        switch state {
        case .thinking: pulse = 0.5 + 0.5 * sin(time * 2 * .pi / 1.6)
        case .idle: pulse = 0.5 + 0.5 * sin(time * 2 * .pi / 6)
        default: pulse = 0.5
        }
        let s = 0.16 + 0.10 * pulse
        let colors = [tint.withAlphaComponent(s).cgColor,
                      tint.withAlphaComponent(s * 0.25).cgColor,
                      tint.withAlphaComponent(0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) else { return }
        ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: r * 0.82, options: [])
    }

    private func drawTicks(_ ctx: CGContext, _ r: CGFloat) {
        let degPerSec: Double
        switch state {
        case .idle: degPerSec = 2
        case .listening: degPerSec = 4
        case .thinking: degPerSec = 14
        case .working: degPerSec = 8
        case .waitingForApproval: degPerSec = 1.5
        case .completed: degPerSec = 3
        case .error: degPerSec = 0
        }
        ctx.saveGState()
        ctx.rotate(by: rad(time * degPerSec))
        let count = 96
        let minor = CGMutablePath(), major = CGMutablePath()
        for i in 0..<count {
            let a = Double(i) / Double(count) * 2 * .pi
            let isMajor = i % 8 == 0
            let inner = r * (isMajor ? 0.925 : 0.945), outer = r * 0.97
            let path = isMajor ? major : minor
            path.move(to: CGPoint(x: cos(a) * inner, y: sin(a) * inner))
            path.addLine(to: CGPoint(x: cos(a) * outer, y: sin(a) * outer))
        }
        stroke(ctx, minor, white(0.20), 0.8)
        stroke(ctx, major, tint.withAlphaComponent(0.65).cgColor, 1.2)
        ctx.restoreGState()
    }

    // MARK: States

    /// Idle: three slow arcs on the main ring. Calm, minimal.
    private func drawIdle(_ ctx: CGContext, _ r: CGFloat) {
        strokeCircle(ctx, r * 0.78, white(0.10), 0.8)
        ctx.saveGState()
        ctx.rotate(by: rad(time * 4))
        for i in 0..<3 {
            let start = Double(i) * 120
            strokeArc(ctx, r * 0.78, start + 8, start + 78, tint(0.65), 1.6)
        }
        ctx.restoreGState()
    }

    /// Listening: radial level bars (demo values — there is no microphone in V0.1).
    private func drawListening(_ ctx: CGContext, _ r: CGFloat) {
        let count = 64
        let bars = CGMutablePath()
        for i in 0..<count {
            let a = Double(i) / Double(count) * 2 * .pi
            let phase = Double(i)
            let level = abs(0.62 * sin(time * 2.6 + phase * 0.55) + 0.38 * sin(time * 1.3 + phase * 1.4))
            let inner = r * 0.56
            let outer = inner + r * (0.04 + 0.20 * level)
            bars.move(to: CGPoint(x: cos(a) * inner, y: sin(a) * inner))
            bars.addLine(to: CGPoint(x: cos(a) * outer, y: sin(a) * outer))
        }
        stroke(ctx, bars, tint(0.9), 2.2, cap: .round)
        strokeCircle(ctx, r * 0.84, tint(0.25), 0.8)
    }

    /// Thinking: counter-rotating dashed rings + pulsing core + one orbiting node.
    private func drawThinking(_ ctx: CGContext, _ r: CGFloat) {
        ctx.saveGState(); ctx.rotate(by: rad(time * 38))
        strokeCircle(ctx, r * 0.78, tint(0.75), 1.6, cap: .round, dash: [3, 12])
        ctx.restoreGState()

        ctx.saveGState(); ctx.rotate(by: rad(-time * 55))
        strokeCircle(ctx, r * 0.64, tint(0.55), 1.2, dash: [18, 10])
        ctx.restoreGState()

        ctx.saveGState(); ctx.rotate(by: rad(time * 120))
        fillDot(ctx, CGPoint(x: r * 0.78, y: 0), 3.5, tint(1))
        ctx.restoreGState()
    }

    /// Working: segmented ring derived from real task steps + scanner arc + orbiting nodes.
    private func drawWorking(_ ctx: CGContext, _ r: CGFloat) {
        drawStepRing(ctx, r, activePulse: 0.6 + 0.4 * (0.5 + 0.5 * sin(time * 2 * .pi / 1.4)))
        ctx.saveGState(); ctx.rotate(by: rad(time * 36))
        strokeArc(ctx, r * 0.64, 0, 42, tint(0.85), 2, cap: .round)
        ctx.restoreGState()

        ctx.saveGState(); ctx.rotate(by: rad(time * 18))
        for i in 0..<3 {
            let a = Double(i) / 3 * 2 * .pi
            fillDot(ctx, CGPoint(x: cos(a) * r * 0.56, y: sin(a) * r * 0.56), 2.5, tint(0.9))
        }
        ctx.restoreGState()
    }

    /// Waiting: step ring held still with a slow "breath", plus four bracket marks signalling a hold.
    private func drawWaiting(_ ctx: CGContext, _ r: CGFloat) {
        drawStepRing(ctx, r, activePulse: 0.55 + 0.45 * (0.5 + 0.5 * sin(time * 2 * .pi / 2.6)))
        for i in 0..<4 {
            let centre = Double(i) * 90 + 45
            strokeArc(ctx, r * 0.64, centre - 12, centre + 12, tint(0.95), 3, cap: .round)
        }
    }

    /// Completed: all segments filled, a single expanding ripple, then calm.
    private func drawCompleted(_ ctx: CGContext, _ r: CGFloat) {
        drawStepRing(ctx, r, activePulse: 1, forceComplete: true)
        strokeCircle(ctx, r * 0.64, tint(0.55), 1.4)
        let duration = 1.4
        if sinceEnter < duration {
            let t = sinceEnter / duration
            strokeCircle(ctx, r * (0.40 + 0.55 * t), tint(0.8 * (1 - t)), 2.2 * (1 - t) + 0.6)
        }
    }

    /// Error: fractured ring with radial slashes at the breaks. Static apart from a very slow dim.
    private func drawError(_ ctx: CGContext, _ r: CGFloat) {
        let dim = 0.9 + 0.1 * sin(time * 2 * .pi / 3)
        for (s, e) in [(-80.0, 20.0), (46, 130), (170, 214), (236, 262)] {
            strokeArc(ctx, r * 0.78, s, e, tint(0.85 * dim), 2.4, cap: .round)
        }
        let slashes = CGMutablePath()
        for angle in [28.0, 138.0, 222.0, 270.0] {
            let a = rad(angle)
            slashes.move(to: CGPoint(x: cos(a) * r * 0.70, y: sin(a) * r * 0.70))
            slashes.addLine(to: CGPoint(x: cos(a) * r * 0.86, y: sin(a) * r * 0.86))
        }
        stroke(ctx, slashes, tint(0.9 * dim), 1.6, cap: .round)
        strokeCircle(ctx, r * 0.64, tint(0.30), 1, dash: [2, 6])
    }

    // MARK: Step ring (working / waiting / completed)

    /// One arc segment per task step. Completed = solid, active = bright + pulsing, pending = faint hairline.
    private func drawStepRing(_ ctx: CGContext, _ r: CGFloat, activePulse: Double, forceComplete: Bool = false) {
        guard !steps.isEmpty else {
            strokeCircle(ctx, r * 0.78, tint(0.5), 1.6, cap: .round)
            return
        }
        let n = Double(steps.count)
        let span = 360 / n
        let gap = min(8.0, span * 0.2)
        for (i, step) in steps.enumerated() {
            let start = -90 + Double(i) * span + gap / 2
            let end = -90 + Double(i + 1) * span - gap / 2
            switch forceComplete ? StepStatus.completed : step {
            case .completed:
                strokeArc(ctx, r * 0.78, start, end, tint(0.9), 3.4, cap: .round)
            case .active:
                strokeArc(ctx, r * 0.78, start, end, white(0.18), 3.4, cap: .round)
                strokeArc(ctx, r * 0.78, start, start + (end - start) * 0.5, tint(activePulse), 3.4, cap: .round)
            case .pending:
                strokeArc(ctx, r * 0.78, start, end, white(0.22), 1.2, cap: .round)
            case .failed:
                strokeArc(ctx, r * 0.78, start, end, NSColor(Theme.Palette.coral).withAlphaComponent(0.9).cgColor, 3, dash: [4, 4])
            }
        }
    }

    // MARK: Primitives

    private func tint(_ alpha: Double) -> CGColor { tint.withAlphaComponent(alpha).cgColor }
    private func white(_ alpha: Double) -> CGColor { NSColor.white.withAlphaComponent(alpha).cgColor }
    private func rad(_ degrees: Double) -> CGFloat { CGFloat(degrees * .pi / 180) }

    private func stroke(_ ctx: CGContext, _ path: CGPath, _ color: CGColor, _ width: CGFloat,
                        cap: CGLineCap = .butt, dash: [CGFloat] = []) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(cap)
        ctx.setLineDash(phase: 0, lengths: dash)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func strokeCircle(_ ctx: CGContext, _ radius: CGFloat, _ color: CGColor, _ width: CGFloat,
                              cap: CGLineCap = .butt, dash: [CGFloat] = []) {
        stroke(ctx, CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil),
               color, width, cap: cap, dash: dash)
    }

    private func strokeArc(_ ctx: CGContext, _ radius: CGFloat, _ startDeg: Double, _ endDeg: Double,
                           _ color: CGColor, _ width: CGFloat, cap: CGLineCap = .butt, dash: [CGFloat] = []) {
        let path = CGMutablePath()
        path.addArc(center: .zero, radius: radius, startAngle: rad(startDeg), endAngle: rad(endDeg), clockwise: false)
        stroke(ctx, path, color, width, cap: cap, dash: dash)
    }

    private func fillDot(_ ctx: CGContext, _ c: CGPoint, _ radius: CGFloat, _ color: CGColor) {
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
    }
}
