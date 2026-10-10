import AppKit
import QuartzCore

/// Ambient neural-network background (Full HUD only). Isolated from SwiftUI: its own Core Graphics drawing
/// driven by a `CADisplayLink` that
///   • exists only while `isAnimating` (HUD visible ∧ Reduce Motion off) and the view is in a window,
///   • runs at a per-state frame rate (6 fps idle … 18 fps thinking),
///   • is torn down when hidden. When not animating it draws ONE static frame (graph only, no motion).
/// The graph is generated once (deterministic seed); frames only animate intensity, signals and tiny drift.
final class NeuralNetworkNSView: NSView {
    var state: JarvisState = .idle {
        didSet {
            guard state != oldValue else { return }
            enteredAt = Date()
            simulation.burst(for: state, graph: graph)
            applyFrameRate()
            if !isAnimating { needsDisplay = true }
        }
    }
    var tint: NSColor = .white { didSet { if !isAnimating { needsDisplay = true } } }
    var isAnimating = false {
        didSet {
            guard isAnimating != oldValue else { return }
            if !isAnimating { simulation.reset() }
            updateDisplayLink()
            needsDisplay = true
        }
    }

    private let graph = NeuralGraph.generate()
    private var simulation: NeuralSimulation
    private var enteredAt = Date()
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    // Test / smoke-test hooks
    var isDisplayLinkActive: Bool { displayLink != nil }
    private(set) var currentFPS: Double = 0
    var nodeCount: Int { graph.nodes.count }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // purely decorative: never intercepts input

    override init(frame: NSRect) {
        simulation = NeuralSimulation(nodeCount: graph.nodes.count)
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    deinit { displayLink?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDisplayLink()
    }

    private var profile: NeuralProfile { .profile(for: state, sinceEnter: Date().timeIntervalSince(enteredAt)) }

    private func updateDisplayLink() {
        if isAnimating && window != nil {
            guard displayLink == nil else { return }
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            lastTimestamp = 0
            applyFrameRate()
        } else {
            displayLink?.invalidate()
            displayLink = nil
            currentFPS = 0
        }
    }

    private func applyFrameRate() {
        guard let link = displayLink else { return }
        let fps = max(4, profile.fps)
        currentFPS = fps
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(min(fps, 8)), maximum: Float(fps), preferred: Float(fps))
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTimestamp == 0 ? 0 : now - lastTimestamp
        lastTimestamp = now
        let p = profile
        if abs(p.fps - currentFPS) > 0.5 { applyFrameRate() }   // e.g. completed → calm after the settle window
        simulation.step(dt: dt, profile: p, graph: graph)
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, bounds.width > 1, bounds.height > 1 else { return }
        let size = bounds.size
        let t = isAnimating ? Date.timeIntervalSinceReferenceDate : 0
        let drift = isAnimating ? 1.0 : 0.0
        let colour = tint

        // Node screen positions (tiny sinusoidal drift scaled by depth = parallax).
        func position(_ n: NeuralGraph.Node) -> CGPoint {
            let amp = 6.0 * n.depth * drift
            return CGPoint(x: n.x * size.width + sin(t * 0.21 + n.phase) * amp,
                           y: n.y * size.height + cos(t * 0.17 + n.phase * 1.3) * amp)
        }
        let points = graph.nodes.map(position)

        // Dimmer behind the centre so the network never competes with the core or central text.
        func visibility(_ p: CGPoint) -> CGFloat {
            let dx = (p.x / size.width - 0.5) / 0.5, dy = (p.y / size.height - 0.5) / 0.5
            let r = min(1, (dx * dx + dy * dy).squareRoot() / 0.85)
            return 0.38 + 0.62 * r * r * (3 - 2 * r)   // smoothstep
        }

        // Edges: one batched stroke.
        ctx.setLineWidth(0.6)
        ctx.setStrokeColor(colour.withAlphaComponent(0.12).cgColor)
        ctx.beginPath()
        for e in graph.edges {
            ctx.move(to: points[e.a]); ctx.addLine(to: points[e.b])
        }
        ctx.strokePath()

        // Nodes: one batched fill for the resting dots…
        ctx.setFillColor(colour.withAlphaComponent(0.26).cgColor)
        for (i, p) in points.enumerated() {
            let r = 1.3 + 1.1 * graph.nodes[i].depth
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
        // …plus a glow for energised nodes only.
        for (i, e) in simulation.energy.enumerated() where e > 0.04 {
            let p = points[i]
            let r = 2.0 + 3.5 * e
            ctx.setFillColor(colour.withAlphaComponent(CGFloat(0.42 * e) * visibility(p)).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }

        // Signals: short fading trail + head.
        ctx.setLineCap(.round)
        for pulse in simulation.pulses {
            let e = graph.edges[pulse.edge]
            let from = pulse.forward ? points[e.a] : points[e.b]
            let to = pulse.forward ? points[e.b] : points[e.a]
            func lerp(_ f: Double) -> CGPoint { CGPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f) }
            let head = lerp(pulse.progress), tail = lerp(max(0, pulse.progress - 0.22))
            let v = visibility(head), s = CGFloat(pulse.strength)
            ctx.setLineWidth(1.1)
            ctx.setStrokeColor(colour.withAlphaComponent(0.32 * s * v).cgColor)
            ctx.beginPath(); ctx.move(to: tail); ctx.addLine(to: head); ctx.strokePath()
            ctx.setFillColor(colour.withAlphaComponent(0.70 * s * v).cgColor)
            ctx.fillEllipse(in: CGRect(x: head.x - 1.8, y: head.y - 1.8, width: 3.6, height: 3.6))
        }
    }
}
