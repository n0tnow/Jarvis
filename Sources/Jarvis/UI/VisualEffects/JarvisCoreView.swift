import AppKit
import SwiftUI

/// The JARVIS core: an original concentric-geometry visualization that reacts to `JarvisState`.
///
/// Resource model: the animation clock lives in `CoreNSView` (a capped `CADisplayLink`) which exists ONLY while
/// `isAnimating` is true (HUD visible and Reduce Motion off). Otherwise it draws a single static frame.
struct JarvisCoreView: View {
    let state: JarvisState
    let stateEnteredAt: Date
    let steps: [StepStatus]
    let isAnimating: Bool
    var maxFPS: Double = 24
    /// Large variant shows the state glyph + label in the centre; the mini variant is bare geometry.
    var showsCenterLabel = true

    var body: some View {
        CoreCanvas(state: state, stateEnteredAt: stateEnteredAt, steps: steps, isAnimating: isAnimating, maxFPS: maxFPS)
            .overlay { if showsCenterLabel { centerLabel } }
            .aspectRatio(1, contentMode: .fit)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("JARVIS core")
            .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let done = steps.filter { $0 == .completed }.count
        let base = "\(state.label.capitalized), \(state.summary)"
        return steps.isEmpty ? base : "\(base). \(done) of \(steps.count) steps complete"
    }

    private var centerLabel: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            VStack(spacing: Theme.Spacing.xs) {
                Image(systemName: state.symbolName)
                    .font(.system(size: max(14, side * 0.075), weight: .light))
                    .foregroundStyle(state.tint)
                Text(side < 340 ? state.shortLabel : state.label)
                    .font(.system(size: max(10.5, side * 0.04), weight: .semibold, design: .monospaced))
                    .tracking(side < 340 ? 1 : 2)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(Color.jarvisPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if side > 300 {
                    Text(state.summary)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Color.jarvisSecondary)
                }
            }
            .frame(width: side * 0.5)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}

// MARK: - AppKit bridge

private struct CoreCanvas: NSViewRepresentable {
    let state: JarvisState
    let stateEnteredAt: Date
    let steps: [StepStatus]
    let isAnimating: Bool
    let maxFPS: Double

    func makeNSView(context: Context) -> CoreNSView { CoreNSView() }

    func updateNSView(_ view: CoreNSView, context: Context) {
        view.state = state
        view.stateEnteredAt = stateEnteredAt
        view.steps = steps
        view.tint = NSColor(state.tint)
        view.maxFPS = maxFPS
        view.isAnimating = isAnimating
    }
}
