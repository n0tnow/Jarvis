import AppKit
import SwiftUI

/// Native NSVisualEffectView wrapper — the real macOS blur material behind HUD surfaces.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.material = material
        view.blendingMode = blending
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// Glass surface for a whole HUD: blur + deep-ink tint (for legibility) + hairline edge.
struct HUDSurface: View {
    var cornerRadius: CGFloat = Theme.Radius.xl
    var showsGrid = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            VisualEffectBackground(material: .hudWindow, blending: .behindWindow)
            LinearGradient(
                colors: [Theme.Palette.ink.opacity(0.74), Theme.Palette.ink.opacity(0.88)],
                startPoint: .top, endPoint: .bottom
            )
            if showsGrid { TechnicalGrid() }
        }
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(Theme.Opacity.strokeStrong), Color.white.opacity(Theme.Opacity.hairline)],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            )
        )
    }
}

/// Very faint static grid. A `Canvas` only re-renders on size changes, so this costs nothing at idle.
struct TechnicalGrid: View {
    var spacing: CGFloat = 48

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            context.stroke(path, with: .color(Theme.Palette.accent.opacity(0.035)), lineWidth: 0.5)

            // Soft vignette so the centre reads brighter than the edges.
            let rect = CGRect(origin: .zero, size: size)
            context.fill(
                Path(rect),
                with: .radialGradient(
                    Gradient(colors: [Theme.Palette.accent.opacity(0.07), .clear]),
                    center: CGPoint(x: size.width / 2, y: size.height * 0.46),
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.55
                )
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
