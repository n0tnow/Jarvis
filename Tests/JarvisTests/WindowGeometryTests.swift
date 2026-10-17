import Testing
import SwiftUI
import AppKit
@testable import Jarvis

// V1.0 stabilisation fix 3 — the Full HUD opens as a normal window filling the usable screen, remembers the person's frame, recovers from a missing monitor,
// and only its header moves the window (content keeps text selection, scrolling and clicks).

@Suite("Fix 3 · Full HUD window geometry")
struct FullHUDFramePolicyTests {
    let main = CGRect(x: 0, y: 90, width: 2560, height: 1320)          // visibleFrame of a screen with a Dock at the bottom
    let side = CGRect(x: 2560, y: 0, width: 1920, height: 1055)

    @Test("first open fills the usable area of the target screen with a small inset (never beyond it)")
    func firstOpen() {
        let f = FullHUDFramePolicy.resolve(saved: nil, screens: [main], preferred: main)
        #expect(f == main.insetBy(dx: FullHUDFramePolicy.inset, dy: FullHUDFramePolicy.inset))
        #expect(main.contains(f))
    }

    @Test("a frame the person chose is restored; one that no longer fits is clamped onto its screen")
    func restore() {
        let chosen = CGRect(x: 300, y: 200, width: 1500, height: 900)
        #expect(FullHUDFramePolicy.resolve(saved: chosen, screens: [main], preferred: main) == chosen)
        let tooBig = CGRect(x: 100, y: 100, width: 5000, height: 3000)
        let clamped = FullHUDFramePolicy.resolve(saved: tooBig, screens: [main], preferred: main)
        #expect(main.contains(clamped))
    }

    @Test("a saved frame on a disconnected monitor never leaves the window off-screen")
    func disconnectedMonitor() {
        let onSide = CGRect(x: 3000, y: 100, width: 1400, height: 800)
        let f = FullHUDFramePolicy.resolve(saved: onSide, screens: [main], preferred: main)
        #expect(f == FullHUDFramePolicy.filling(main))
        // still connected: stays where it was
        #expect(FullHUDFramePolicy.resolve(saved: onSide, screens: [main, side], preferred: main) == onSide)
        // partly off-screen: pulled back inside
        let hanging = CGRect(x: 2000, y: 100, width: 1400, height: 800)
        let pulled = FullHUDFramePolicy.resolve(saved: hanging, screens: [main], preferred: main)
        #expect(main.contains(pulled))
    }

    @Test("the minimum size is enforced and a saved frame is encoded/decoded safely")
    func minimumAndCoding() {
        let tiny = CGRect(x: 400, y: 400, width: 200, height: 100)
        let f = FullHUDFramePolicy.resolve(saved: tiny, screens: [main], preferred: main)
        #expect(f.width >= FullHUDFramePolicy.minimum.width && f.height >= FullHUDFramePolicy.minimum.height)
        let r = CGRect(x: 10, y: 20, width: 1200, height: 800)
        #expect(FullHUDFramePolicy.decode(FullHUDFramePolicy.encode(r)) == r)
        #expect(FullHUDFramePolicy.decode("garbage") == nil && FullHUDFramePolicy.decode("1 2 0 0") == nil && FullHUDFramePolicy.decode(nil) == nil)
    }

    @Test("a small screen is respected: the minimum never exceeds the usable area")
    func smallScreen() {
        let small = CGRect(x: 0, y: 25, width: 1024, height: 700)
        let f = FullHUDFramePolicy.resolve(saved: nil, screens: [small], preferred: small)
        #expect(small.contains(f))
    }
}

@Suite("Fix 3 · only the header moves the window")
@MainActor
struct WindowDragTests {
    private func makeApp() -> AppContext {
        AppContext(seedDemoData: false, stubIntelligence: true, dataDirectory: JarvisPaths.liveTestsRoot.appendingPathComponent("unit-drag-\(UUID().uuidString)", isDirectory: true))
    }
    private func views<T: NSView>(of type: T.Type, in v: NSView) -> [T] { (v as? T).map { [$0] } ?? [] + v.subviews.flatMap { views(of: type, in: $0) } }

    @Test("the Full HUD has exactly one drag region and it is the header; the window itself is not movable by its background")
    func oneDragRegion() {
        let app = makeApp()
        let host = NSHostingView(rootView: FullHUDView().environment(app).frame(width: 1400, height: 800))
        host.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)
        let window = FullHUDWindow(contentRect: host.frame, styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isMovableByWindowBackground = false
        window.contentView = host
        for _ in 0..<4 { RunLoop.current.run(until: Date().addingTimeInterval(0.04)); host.layoutSubtreeIfNeeded() }
        let drags = views(of: WindowDragRegion.DragView.self, in: host)
        #expect(drags.count == 1, "found \(drags.count) drag regions")
        if let d = drags.first {
            let f = d.convert(d.bounds, to: host)
            #expect(f.height <= Theme.Grid.headerHeight + 2 && f.width > 600, "the drag region is the header strip: \(f)")
            #expect(host.isFlipped ? f.minY <= 2 : f.maxY >= host.bounds.height - 2, "it sits at the top of the window")
            #expect(d.mouseDownCanMoveWindow == false)               // it moves the window explicitly (performDrag), not through background dragging
        }
        #expect(window.isMovableByWindowBackground == false)
    }

    @Test("source guard: nothing makes the whole window draggable and no gesture steals content drags")
    func sourceGuard() throws {
        var url = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { url.deleteLastPathComponent() }
        let en = FileManager.default.enumerator(at: url.appendingPathComponent("Sources/Jarvis"), includingPropertiesForKeys: nil)!
        var offenders: [String] = []
        for case let f as URL in en where f.pathExtension == "swift" {
            let t = try String(contentsOf: f, encoding: .utf8)
            if t.contains("isMovableByWindowBackground = true") { offenders.append("\(f.lastPathComponent): isMovableByWindowBackground = true") }
            if f.path.contains("/UI/FullHUD/"), t.contains("DragGesture") { offenders.append("\(f.lastPathComponent): DragGesture in Full HUD content") }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    @Test("source guard: conversation, report and detail text is selectable")
    func textIsSelectable() throws {
        var url = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { url.deleteLastPathComponent() }
        let root = url.appendingPathComponent("Sources/Jarvis/UI")
        for rel in ["FullHUD/ConversationPanel.swift", "FullHUD/System/ReadinessSectionView.swift", "Components/HUDCard.swift", "Components/DesignSystem.swift"] {
            let t = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            #expect(t.contains(".textSelection(.enabled)"), "\(rel)")
        }
    }
}
