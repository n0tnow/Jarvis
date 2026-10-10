import AppKit
import QuartzCore

/// AppKit-backed canvas for the JARVIS core.
///
/// Why not a SwiftUI `Canvas` in a `TimelineView`? Profiling showed SwiftUI's per-tick graph invalidation
/// cost ~25% of a core even with an *empty* canvas. This view draws with Core Graphics and is driven by a
/// `CADisplayLink` that is capped to `maxFPS` and exists only while `isAnimating` is true and the view is in a window.
/// When not animating it draws one static frame and consumes nothing.
final class CoreNSView: NSView {
    var state: JarvisState = .idle { didSet { invalidateStaticFrame(); applyFrameRate() } }
    var stateEnteredAt: Date = .now { didSet { invalidateStaticFrame() } }
    var steps: [StepStatus] = [] { didSet { invalidateStaticFrame() } }
    var tint: NSColor = .white { didSet { invalidateStaticFrame() } }
    var maxFPS: Double = 24 { didSet { applyFrameRate() } }
    var isAnimating = false {
        didSet {
            guard isAnimating != oldValue else { return }
            updateDisplayLink()
            needsDisplay = true
        }
    }

    private var displayLink: CADisplayLink?

    /// True only while a display link exists (used by the smoke test to prove animation stops when hidden).
    var isDisplayLinkActive: Bool { displayLink != nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { false }

    override init(frame: NSRect) {
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

    private func invalidateStaticFrame() {
        // While animating, the display link redraws anyway; when static we redraw once per change.
        if !isAnimating { needsDisplay = true }
    }

    private func updateDisplayLink() {
        if isAnimating && window != nil {
            guard displayLink == nil else { return }
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            applyFrameRate()
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    private func applyFrameRate() {
        // Slow-moving states (idle/waiting/error) don't need a high frame rate; saves CPU for the neural layer.
        let target: Double
        switch state {
        case .idle, .error: target = 10
        case .waitingForApproval: target = 12
        case .completed: target = 20
        case .listening, .thinking, .working: target = maxFPS
        }
        let fps = Float(min(maxFPS, target))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: min(8, fps), maximum: fps, preferred: fps)
    }

    @objc private func tick(_ link: CADisplayLink) {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let now = Date()
        CoreRenderer(
            state: state,
            steps: steps,
            tint: tint,
            sinceEnter: isAnimating ? now.timeIntervalSince(stateEnteredAt) : .infinity,
            time: isAnimating ? now.timeIntervalSinceReferenceDate : 0
        ).draw(in: ctx, size: bounds.size)
    }
}
