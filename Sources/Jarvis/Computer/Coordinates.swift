import Foundation
import CoreGraphics

// MARK: - Coordinate safety (DEC-134…)
//
// Three spaces meet here and none is guessed:
//   • AppKit  — origin bottom-left of the PRIMARY display, y up, logical points (NSScreen / NSWindow)
//   • Global  — origin top-left of the PRIMARY display, y down, logical points (Accessibility, CGWindow, CGEvent). Secondary displays may be negative.
//   • Image   — origin top-left of a captured window image, BACKING PIXELS (Retina: points × scale)
//   • Vision  — normalized 0…1, origin bottom-left of the image (Apple Vision bounding boxes)
// A model never supplies an absolute screen coordinate: vision proposes a region of ONE window image; JARVIS converts and validates it.

struct DisplayLayout: Equatable, Sendable {
    var displays: [DisplayInfo]
    var primaryHeight: CGFloat { displays.first(where: \.isPrimary)?.frame.height ?? displays.first?.frame.height ?? 0 }
    /// Menu bar + Dock are excluded: raw coordinates never land on them (spec §98).
    func globalVisibleFrames() -> [CGRect] { displays.map { Coordinates.appKitToGlobal($0.visibleFrame, primaryHeight: primaryHeight) } }
    func globalFrames() -> [CGRect] { displays.map { Coordinates.appKitToGlobal($0.frame, primaryHeight: primaryHeight) } }
    func scale(atGlobal p: CGPoint) -> CGFloat {
        for (d, f) in zip(displays, globalFrames()) where f.contains(p) { return d.scale }
        return displays.first(where: \.isPrimary)?.scale ?? 1
    }
}

enum Coordinates {
    static func appKitToGlobal(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
    static func globalToAppKit(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
    static func appKitToGlobal(_ p: CGPoint, primaryHeight: CGFloat) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }

    /// Backing pixels of a window image → window-relative LOGICAL points (top-left origin).
    static func pixelToWindowPoint(_ px: CGPoint, scale: CGFloat) -> CGPoint {
        scale > 0 ? CGPoint(x: px.x / scale, y: px.y / scale) : px
    }

    /// An Apple Vision bounding box (normalized, bottom-left origin) → a rect in window-relative logical points (top-left origin).
    static func visionBoxToWindowRect(_ box: CGRect, windowSize: CGSize) -> CGRect {
        CGRect(x: box.minX * windowSize.width, y: (1 - box.maxY) * windowSize.height, width: box.width * windowSize.width, height: box.height * windowSize.height)
    }

    static func windowPointToGlobal(_ rel: CGPoint, windowFrame: CGRect) -> CGPoint {
        CGPoint(x: windowFrame.minX + rel.x, y: windowFrame.minY + rel.y)
    }

    enum PointVerdict: Equatable, Sendable { case ok(CGPoint), refused(String) }

    /// The ONLY way a window-relative point becomes a click location.
    static func clickPoint(relative rel: CGPoint, windowFrame: CGRect, layout: DisplayLayout) -> PointVerdict {
        guard rel.x.isFinite, rel.y.isFinite else { return .refused("the point is not a number") }
        guard rel.x >= 1, rel.y >= 1, rel.x <= windowFrame.width - 1, rel.y <= windowFrame.height - 1 else { return .refused("the point is outside the target window") }
        let p = windowPointToGlobal(rel, windowFrame: windowFrame)
        guard layout.globalVisibleFrames().contains(where: { $0.contains(p) }) else { return .refused("the point is off-screen or on the menu bar / Dock") }
        return .ok(p)
    }

    /// Where on a rect to click: its centre, pulled inside by a margin so edge pixels of a custom control are not hit.
    static func centre(of r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
}

// MARK: - Stale-screen protection

/// What a window-scoped screenshot was taken OF. A vision-derived action is only legal while the world still matches it.
struct ScreenObservation: Equatable, Sendable {
    var pid: Int32
    var bundleID: String?
    var windowTitle: String
    var windowFrame: CGRect               // global points at capture time
    var cgWindowID: UInt32?
    var scale: CGFloat
    var pixelSize: CGSize
    var capturedAt: Date
    var fingerprint: UInt64               // 8×8 average hash of the image (no pixels are kept)
    var generation: Int
}

enum StaleVerdict: Equatable, Sendable {
    case fresh
    case stale(String)
    var isFresh: Bool { self == .fresh }
}

enum StaleCheck {
    static let frameTolerance: CGFloat = 1.5
    static let hashTolerance = 8

    /// Validates a past observation against the CURRENT state. Any mismatch is STALE: re-observe, never click on an old picture.
    static func validate(_ obs: ScreenObservation, now: Date = Date(), currentWindow: WindowSnapshot?, frontmostPID: Int32?, currentFingerprint: UInt64?,
                         maxAge: TimeInterval = ComputerLimits.maxObservationAge) -> StaleVerdict {
        if now.timeIntervalSince(obs.capturedAt) > maxAge { return .stale("the screenshot is older than \(Int(maxAge)) s") }
        guard let w = currentWindow else { return .stale("the window is gone") }
        if frontmostPID != obs.pid { return .stale("another application came to the front") }
        if w.title != obs.windowTitle { return .stale("the window title changed") }
        if w.isMinimized { return .stale("the window is minimized") }
        if abs(w.frame.minX - obs.windowFrame.minX) > frameTolerance || abs(w.frame.minY - obs.windowFrame.minY) > frameTolerance
            || abs(w.frame.width - obs.windowFrame.width) > frameTolerance || abs(w.frame.height - obs.windowFrame.height) > frameTolerance {
            return .stale("the window moved or was resized")
        }
        if let h = currentFingerprint, (h ^ obs.fingerprint).nonzeroBitCount > hashTolerance { return .stale("the window content changed") }
        return .fresh
    }
}

/// Everything needed to know whether a resolved AX target is still the same thing (spec §50).
struct ActionFingerprint: Equatable, Sendable {
    var pid: Int32
    var bundleID: String?
    var windowTitle: String
    var windowFrame: CGRect
    var role: String
    var title: String
    var identifier: String?
    var elementFrame: CGRect?
    var generation: Int

    static func of(_ e: UIElementSnapshot, in snap: AXSnapshot) -> ActionFingerprint {
        ActionFingerprint(pid: snap.app.pid, bundleID: snap.app.bundleID, windowTitle: snap.window?.title ?? "", windowFrame: snap.window?.frame ?? .zero,
                          role: e.role, title: e.title, identifier: e.identifier, elementFrame: e.frame, generation: snap.generation)
    }

    /// The same control in a fresher snapshot? (same app, same window, same role/title/identifier, near the same place)
    func stillValid(in snap: AXSnapshot, element: UIElementSnapshot) -> StaleVerdict {
        if snap.app.pid != pid { return .stale("the application restarted") }
        if (snap.window?.title ?? "") != windowTitle { return .stale("the window changed") }
        if let w = snap.window, abs(w.frame.width - windowFrame.width) > 2 || abs(w.frame.height - windowFrame.height) > 2 { return .stale("the window was resized") }
        if element.role != role || element.title != title || element.identifier != identifier { return .stale("the control changed") }
        return .fresh
    }
}
