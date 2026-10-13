import Foundation
import CoreGraphics
@testable import Jarvis

/// A virtual macOS for Computer Use tests: applications with windows, elements, menus and behaviours (closures that mutate the world when pressed).
/// Every mutating backend call is logged, so tests can prove what was — and was NOT — done.
final class FakeUI: UIBackend, @unchecked Sendable {
    /// Fault injection: every press answers with `error`, either before or after the element's handler ran.
    var pressFailure: (error: BackendError, afterEffect: Bool)?
    struct Element {
        var role: String
        var title: String
        var value: String?
        var enabled = true
        var selected = false
        var focused = false
        var isSecure = false
        var actions: [String] = ["Press"]
        var ancestors: [String] = []
        var inModal = false
        var identifier: String?
        var frame: CGRect?
        /// Runs when the element is pressed (the app's behaviour).
        var onPress: ((FakeUI, Int32) -> Void)?
        var settable = true
    }
    struct Window {
        var title: String
        var frame = CGRect(x: 100, y: 100, width: 600, height: 400)
        var isModal = false
        var isMinimized = false
        var isFocused = true
        var defaultButton: String?
        var cgID: UInt32?
        var elements: [Element] = []
    }
    struct Menu { var title: String; var items: [MenuItem] }
    struct MenuItem { var title: String; var enabled = true; var action: ((FakeUI, Int32) -> Void)? }
    struct App {
        var snap: ApplicationSnapshot
        var windows: [Window] = []
        var menus: [Menu] = []
        var responsive = true
    }

    var apps: [Int32: App] = [:]
    var frontmost: Int32?
    var trusted = true
    var screenAllowed = true
    var installed: [String: String] = [:]           // bundle id → name (not running)
    var log: [String] = []
    var layout = DisplayLayout(displays: [DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 850), scale: 2, isPrimary: true)])
    var nextPID: Int32 = 500
    /// Called before every backend call (tests use it to cancel, move windows, steal focus…).
    var beforeCall: ((String) -> Void)?
    var launchDelayCalls = 0                        // the app appears only after this many `runningApplications` polls
    private var pendingLaunch: [(bundle: String, name: String, polls: Int)] = []
    private var handles: [ElementHandle: (pid: Int32, win: Int, el: Int)] = [:]
    private var generation = 0
    var captureImage: ((FakeUI, Int32, Int) -> CGImage?)?
    var captureScale: CGFloat = 2
    var fingerprintOverride: UInt64?

    // MARK: Setup helpers

    @discardableResult
    func addApp(_ name: String, bundle: String, windows: [Window] = [], menus: [Menu] = [], front: Bool = false) -> Int32 {
        let pid = nextPID; nextPID += 1
        apps[pid] = App(snap: ApplicationSnapshot(pid: pid, bundleID: bundle, name: name, isActive: false, isHidden: false), windows: windows, menus: menus)
        if front { frontmost = pid }
        return pid
    }
    func pid(_ bundle: String) -> Int32? { apps.first { $0.value.snap.bundleID == bundle }?.key }
    func record(_ s: String) { log.append(s) }
    func logged(_ prefix: String) -> [String] { log.filter { $0.hasPrefix(prefix) } }

    // MARK: Permissions

    func accessibilityTrusted() -> Bool { trusted }
    func screenCaptureAllowed() -> Bool { screenAllowed }

    // MARK: Applications

    func runningApplications() async -> [ApplicationSnapshot] {
        beforeCall?("runningApplications")
        for i in pendingLaunch.indices { pendingLaunch[i].polls -= 1 }
        for p in pendingLaunch where p.polls <= 0 {
            let pid = addApp(p.name, bundle: p.bundle, windows: [Window(title: p.name, elements: [])])
            frontmost = pid
        }
        pendingLaunch.removeAll { $0.polls <= 0 }
        return apps.values.map { var s = $0.snap; s.isActive = frontmost == s.pid; return s }
    }
    func frontmostApplication() async -> ApplicationSnapshot? {
        beforeCall?("frontmost")
        return frontmost.flatMap { apps[$0] }.map { var s = $0.snap; s.isActive = true; return s }
    }
    func installedBundleID(for ref: AppRef) async -> String? {
        if let b = ref.bundleID { return installed[b] != nil || pid(b) != nil ? b : nil }
        return installed.first { ComputerText.fold($0.value) == ComputerText.fold(ref.name ?? "") }?.key
    }
    func launchApplication(bundleID: String) async throws -> Int32 {
        beforeCall?("launch")
        record("launch \(bundleID)")
        guard let name = installed[bundleID] else { throw BackendError.appNotFound(bundleID) }
        pendingLaunch.append((bundleID, name, max(1, launchDelayCalls)))
        return 0
    }
    func activateApplication(pid: Int32) async -> Bool {
        beforeCall?("activate")
        record("activate \(pid)")
        if stealFocusFrom == pid { return false }
        frontmost = pid
        return true
    }
    var stealFocusFrom: Int32?
    func quitApplication(pid: Int32) async -> Bool { record("quit \(pid)"); apps[pid] = nil; return true }
    func isResponsive(pid: Int32) async -> Bool { apps[pid]?.responsive ?? false }

    // MARK: Windows

    func windows(pid: Int32) async -> [WindowSnapshot] {
        beforeCall?("windows")
        return (apps[pid]?.windows ?? []).enumerated().map { (i, w) in
            WindowSnapshot(index: i, title: w.title, role: "AXWindow", subrole: nil, frame: w.frame, isMain: w.isFocused, isFocused: w.isFocused, isMinimized: w.isMinimized, isModal: w.isModal, isSheet: false,
                           cgWindowID: w.cgID ?? UInt32(1000 + Int(pid) * 10 + i), identifier: nil, defaultButton: w.defaultButton)
        }
    }
    func windowOperation(_ op: WindowOp, pid: Int32, windowIndex: Int) async throws {
        beforeCall?("windowOp")
        record("window \(op.rawValue) \(windowIndex)")
        guard var a = apps[pid], a.windows.indices.contains(windowIndex) else { throw BackendError.noWindow }
        switch op {
        case .raise: for i in a.windows.indices { a.windows[i].isFocused = i == windowIndex }
        case .minimize: a.windows[windowIndex].isMinimized = true; a.windows[windowIndex].isFocused = false
        case .restore: a.windows[windowIndex].isMinimized = false
        case .close: a.windows.remove(at: windowIndex)
        }
        apps[pid] = a
    }

    // MARK: Observation

    func snapshot(pid: Int32, scope: SnapshotScope, budget: AXBudget) async throws -> AXSnapshot {
        beforeCall?("snapshot")
        guard trusted else { throw BackendError.permissionDenied }
        guard let a = apps[pid] else { throw BackendError.appNotFound("\(pid)") }
        generation += 1
        let wins = await windows(pid: pid)
        let wi: Int? = {
            switch scope {
            case .window(let i): return i
            case .modalFirst: return a.windows.firstIndex { $0.isModal } ?? a.windows.firstIndex { $0.isFocused } ?? (a.windows.isEmpty ? nil : 0)
            case .frontWindow: return a.windows.firstIndex { $0.isFocused } ?? (a.windows.isEmpty ? nil : 0)
            }
        }()
        var out: [UIElementSnapshot] = []
        var focus: Int?
        if let wi {
            for (i, e) in a.windows[wi].elements.prefix(budget.maxNodes).enumerated() {
                let h = ElementHandle(pid: pid, generation: generation, index: i)
                handles[h] = (pid, wi, i)
                if e.focused, focus == nil { focus = i }
                out.append(UIElementSnapshot(id: i, role: e.role, subrole: e.isSecure ? "AXSecureTextField" : nil, title: e.title, help: "", value: e.isSecure ? nil : e.value, valueLength: e.value?.count,
                                             enabled: e.enabled, focused: e.focused, selected: e.selected, identifier: e.identifier, actions: e.actions, frame: e.frame ?? CGRect(x: 120 + i * 4, y: 140 + i * 30, width: 80, height: 24),
                                             parent: nil, depth: 1, childCount: 0, isSecure: e.isSecure, ancestorTitles: e.ancestors, handle: h, inModal: e.inModal || a.windows[wi].isModal))
            }
        }
        return AXSnapshot(app: a.snap, windows: wins, windowIndex: wi, elements: out, generation: generation, truncated: false, capturedAt: Date(), durationMS: 1, focusedElement: focus)
    }
    func menuBarTitles(pid: Int32) async throws -> [String] { ["Apple"] + (apps[pid]?.menus.map(\.title) ?? []) }
    func menuItems(pid: Int32, path: [String]) async throws -> [MenuItemSnapshot] {
        guard let a = apps[pid], let first = path.first else { return [] }
        let all = ["Apple"] + a.menus.map(\.title)
        _ = all
        guard let m = a.menus.first(where: { ComputerText.menuKey($0.title) == ComputerText.menuKey(first) }) else { throw BackendError.elementGone }
        return m.items.map { MenuItemSnapshot(title: $0.title, enabled: $0.enabled, hasSubmenu: false, isSeparator: $0.title.isEmpty, checked: false) }
    }
    func pressMenuPath(pid: Int32, path: [String]) async throws {
        beforeCall?("menu")
        guard let a = apps[pid], path.count == 2 else { throw BackendError.elementGone }
        guard let m = a.menus.first(where: { ComputerText.menuKey($0.title) == ComputerText.menuKey(path[0]) }),
              let item = m.items.first(where: { ComputerText.menuKey($0.title) == ComputerText.menuKey(path[1]) }) else { throw BackendError.elementGone }
        record("menu \(path.joined(separator: " > "))")
        item.action?(self, pid)
    }
    func readValue(_ h: ElementHandle) async throws -> String? {
        guard let loc = handles[h], let e = apps[loc.pid]?.windows[loc.win].elements[loc.el] else { throw BackendError.elementGone }
        if e.isSecure { throw BackendError.secureField }
        return e.value
    }

    // MARK: Element operations

    func perform(_ op: ElementOp, on h: ElementHandle) async throws {
        beforeCall?("perform")
        guard let loc = handles[h], apps[loc.pid]?.windows.indices.contains(loc.win) == true, let e = apps[loc.pid]?.windows[loc.win].elements[safe: loc.el] else { throw BackendError.elementGone }
        record("\(op.rawValue) \(e.role) “\(e.title)”")
        switch op {
        case .press, .confirm:
            if let f = pressFailure, !f.afterEffect { throw f.error }          // refused BEFORE anything happened
            e.onPress?(self, loc.pid)
            if let f = pressFailure, f.afterEffect { throw f.error }           // the handler ran, then the application answered "not supported" (JARVIS-V13-7)
        case .select: apps[loc.pid]?.windows[loc.win].elements[loc.el].selected = true; e.onPress?(self, loc.pid)
        case .focus:
            for i in apps[loc.pid]!.windows[loc.win].elements.indices { apps[loc.pid]!.windows[loc.win].elements[i].focused = i == loc.el }
        default: break
        }
    }
    func setValue(_ text: String, on h: ElementHandle) async throws {
        beforeCall?("setValue")
        guard let loc = handles[h], let e = apps[loc.pid]?.windows[loc.win].elements[safe: loc.el] else { throw BackendError.elementGone }
        if e.isSecure { throw BackendError.secureField }
        guard e.settable else { throw BackendError.unsupported("not settable") }
        record("setValue \(text.count) chars")
        apps[loc.pid]!.windows[loc.win].elements[loc.el].value = text
    }

    // MARK: Synthetic input

    func postKey(_ chord: KeyChord, toPID pid: Int32) async throws { beforeCall?("key"); record("key \(chord.display) → \(pid)") }
    func typeText(_ text: String, toPID pid: Int32, shouldContinue: @escaping @Sendable () -> Bool) async throws {
        var sent = 0
        for ch in text {
            beforeCall?("typeChunk")
            guard shouldContinue(), !Task.isCancelled else { return }
            record("type \(ch)")
            sent += 1
            if let wi = apps[pid]?.windows.firstIndex(where: { $0.isFocused }), let ei = apps[pid]?.windows[wi].elements.firstIndex(where: { $0.focused }) {
                apps[pid]!.windows[wi].elements[ei].value = (apps[pid]!.windows[wi].elements[ei].value ?? "") + String(ch)
            }
        }
    }
    func postScroll(direction: ScrollDirection, lines: Int, atGlobal p: CGPoint, toPID pid: Int32) async throws {
        beforeCall?("scroll"); record("scroll \(direction.rawValue)"); onScroll?(self, pid)
    }
    var onScroll: ((FakeUI, Int32) -> Void)?
    var onClick: ((FakeUI, CGPoint, Int32) -> Void)?
    func postClick(atGlobal p: CGPoint) async throws { beforeCall?("click"); let pid = frontmost ?? 0; record("click \(Int(p.x)),\(Int(p.y)) → \(pid)"); onClick?(self, p, pid) }
    /// Topmost window at a point: the front application's windows containing it (a test may override it to simulate occlusion).
    var topWindowOverride: UInt32??
    func topWindowID(atGlobal p: CGPoint) async -> UInt32? {
        if let o = topWindowOverride { return o }
        guard let f = frontmost, let a = apps[f] else { return nil }
        for (i, w) in a.windows.enumerated() where !w.isMinimized && w.frame.contains(p) { return w.cgID ?? UInt32(1000 + Int(f) * 10 + i) }
        return nil
    }
    func scrollBy(_ h: ElementHandle, direction: ScrollDirection, step: Double) async throws -> Double { throw BackendError.unsupported("the fake has no scroll bar") }

    // MARK: Workspace

    func openFile(path: String, withBundleID bundleID: String?) async throws {
        beforeCall?("openFile"); record("openFile \((path as NSString).lastPathComponent)")
        onOpen?(self, path, bundleID)
    }
    var onOpen: ((FakeUI, String, String?) -> Void)?
    func revealInFinder(path: String) async throws {
        record("reveal \((path as NSString).lastPathComponent)")
        let name = (path as NSString).lastPathComponent
        if let f = pid("com.apple.finder") { apps[f]!.windows = [Window(title: name)]; frontmost = f }
    }
    func openSettingsPane(_ pane: SettingsPane) async throws {
        record("pane \(pane.rawValue)")
        let p = pid(SurfacePolicy.systemSettings) ?? addApp("System Settings", bundle: SurfacePolicy.systemSettings)
        apps[p]!.windows = [Window(title: pane == .general ? "General" : "Privacy & Security")]
        frontmost = p
    }

    // MARK: Screen

    func displays() -> DisplayLayout { layout }
    func captureWindow(cgWindowID: UInt32, windowFrame: CGRect) async throws -> CapturedWindow {
        beforeCall?("capture")
        guard screenAllowed else { throw BackendError.captureUnavailable("no permission") }
        record("capture \(cgWindowID)")
        let pid = Int32((Int(cgWindowID) - 1000) / 10), idx = (Int(cgWindowID) - 1000) % 10
        let img = captureImage?(self, pid, idx) ?? FakeUI.blankImage(width: Int(windowFrame.width * captureScale), height: Int(windowFrame.height * captureScale))
        return CapturedWindow(image: img, scale: captureScale, windowFrame: windowFrame, fingerprint: fingerprintOverride ?? WindowCapture.fingerprint(of: img), capturedAt: Date(), duration: 0.01)
    }
    static func blankImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// A scripted vision provider: returns proposals for labels it "recognises".
struct ScriptedVision: VisionProposing {
    var name = "scripted vision"
    var boxes: [String: [CGRect]]
    var onPrepare: (@Sendable (String) async -> Void)?
    func prepare(label: String) async { await onPrepare?(label) }
    func propose(label: String, image: CGImage, scale: CGFloat) async -> [VisionProposal] {
        (boxes[ComputerText.menuKey(label)] ?? []).map { VisionProposal(label: label, box: $0, reason: "scripted", source: name) }
    }
}
