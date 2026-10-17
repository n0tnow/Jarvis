import AppKit
import SwiftUI

/// Where the Full HUD window opens (V1.0 stabilisation fix 3). Pure geometry, unit-tested.
///
/// First open: a NORMAL resizable window filling the usable area of the target screen (`visibleFrame`: below the menu bar / notch, beside the Dock) with a small inset — NOT macOS full screen.
/// Later opens: the frame the person chose by moving/resizing, kept on a screen that exists now (a disconnected monitor never leaves the window off-screen).
enum FullHUDFramePolicy {
    static let inset: CGFloat = 6
    static let minimum = NSSize(width: 1040, height: 680)

    static func filling(_ visible: CGRect) -> CGRect { visible.insetBy(dx: inset, dy: inset) }

    /// - Parameters:
    ///   - saved: the frame the person last chose, if any.
    ///   - screens: the visible frames of the screens that exist now.
    ///   - preferred: the visible frame of the target screen (menu-bar item / pointer).
    static func resolve(saved: CGRect?, screens: [CGRect], preferred: CGRect, minimum: NSSize = FullHUDFramePolicy.minimum) -> CGRect {
        let floor = NSSize(width: min(minimum.width, preferred.width - 2 * inset), height: min(minimum.height, preferred.height - 2 * inset))
        guard let saved, saved.width > 0, saved.height > 0 else { return filling(preferred) }
        // The screen the saved frame mostly lives on; none (disconnected monitor, corrupted value) → the target screen, filled.
        var best: (area: CGFloat, frame: CGRect)?
        for s in screens {
            let i = s.intersection(saved)
            let a = i.isNull ? 0 : i.width * i.height
            if a > (best?.area ?? 0) { best = (a, s) }
        }
        guard let host = best, host.area >= min(saved.width * saved.height * 0.4, 200 * 200) else { return filling(preferred) }
        let v = host.frame
        let w = min(max(saved.width, floor.width), v.width)
        let h = min(max(saved.height, floor.height), v.height)
        let x = min(max(saved.minX, v.minX), v.maxX - w)
        let y = min(max(saved.minY, v.minY), v.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func encode(_ r: CGRect) -> String { "\(Int(r.minX)) \(Int(r.minY)) \(Int(r.width)) \(Int(r.height))" }
    static func decode(_ s: String?) -> CGRect? {
        guard let p = s?.split(separator: " ").compactMap({ Double($0) }), p.count == 4, p[2] > 0, p[3] > 0 else { return nil }
        return CGRect(x: p[0], y: p[1], width: p[2], height: p[3])
    }
}

/// The ONLY part of the Full HUD that moves the window: a header region that starts a native window drag (double-click zooms). Everything else — text, cards, lists, scrollers,
/// controls — keeps its own mouse behaviour (text selection, scrolling, buttons, sliders). `NSWindow.isMovableByWindowBackground` is off.
struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.zoom(nil); return }
            window?.performDrag(with: event)
        }
        override func accessibilityRole() -> NSAccessibility.Role? { .group }
        override func accessibilityLabel() -> String? { "Window title bar" }
    }
}

extension View {
    /// Makes this view's background the window's drag handle (header chrome only).
    func windowDragHandle() -> some View { background(WindowDragRegion()) }
}
