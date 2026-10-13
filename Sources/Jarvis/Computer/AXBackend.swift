import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - The real macOS backend (Accessibility, NSWorkspace, CGEvent aimed at ONE process)
//
// This file and `ScreenCapture.swift` are the ONLY places that touch AXUIElement / CGEvent / CGWindowList (verify.sh enforces it).
// Rules baked in here:
//  • nothing is ever read from a secure text field; text areas and web areas report a LENGTH, not their content (DEC-142);
//  • trees are bounded by depth, node count, children per container and a time budget — never the whole application;
//  • every AX call has a messaging timeout, so a hung application is reported, not waited on;
//  • synthetic events go to a single PID (`postToPid`), in short chunks that check for cancellation between them;
//  • nothing here polls: it answers when asked.

final class AXBackend: UIBackend, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.jarvis.computer.ax", qos: .userInitiated)
    // The following state is touched ONLY on `queue`.
    private var generation = 0
    private var elements: [ElementHandle: AXUIElement] = [:]
    private var secureHandles: Set<ElementHandle> = []
    /// How many times the backend was asked anything (diagnostics: proves that nothing is observed while idle).
    private let counter = NSLock()
    private var calls = 0
    var callCount: Int { counter.lock(); defer { counter.unlock() }; return calls }
    private func tick() { counter.lock(); calls += 1; counter.unlock() }

    init() {}

    // MARK: Permissions (truthful; never prompting)

    func accessibilityTrusted() -> Bool { AXIsProcessTrusted() }
    func screenCaptureAllowed() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Explicit user action only (a button in Settings): asks macOS to show ITS prompt. JARVIS never grants anything to itself.
    static func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
    static func promptForScreenRecording() { _ = CGRequestScreenCaptureAccess() }

    // MARK: Queue helpers

    private func run<T>(_ body: @escaping () -> T) async -> T {
        tick()
        return await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in queue.async { cont.resume(returning: body()) } }
    }
    private func runThrowing<T>(_ body: @escaping () throws -> T) async throws -> T {
        tick()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async { do { cont.resume(returning: try body()) } catch { cont.resume(throwing: error) } }
        }
    }

    // MARK: AX attribute reading

    private func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
    private func str(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }
    private func bool(_ el: AXUIElement, _ name: String) -> Bool? { (attr(el, name) as? Bool) ?? (attr(el, name) as? NSNumber)?.boolValue }
    private func children(_ el: AXUIElement) -> [AXUIElement] { (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    /// A Core Foundation reference of the expected type, or nil (never a forced cast on data that came from another process).
    private func element(_ ref: CFTypeRef?) -> AXUIElement? {
        guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }
    private func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute), CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }
    private func actionNames(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success, let n = names as? [String] else { return [] }
        return n.map { $0.replacingOccurrences(of: "AX", with: "") }.prefix(8).map { $0 }
    }
    private func appElement(_ pid: Int32) -> AXUIElement {
        let e = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(e, Float(ComputerLimits.axResponseTimeout))
        return e
    }

    // MARK: Applications (NSWorkspace lives on the main actor)

    func runningApplications() async -> [ApplicationSnapshot] {
        await MainActor.run {
            NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }.map(Self.snapshot)
        }
    }
    func frontmostApplication() async -> ApplicationSnapshot? {
        await MainActor.run { NSWorkspace.shared.frontmostApplication.map(Self.snapshot) }
    }
    private static func snapshot(_ a: NSRunningApplication) -> ApplicationSnapshot {
        ApplicationSnapshot(pid: a.processIdentifier, bundleID: a.bundleIdentifier, name: a.localizedName ?? a.bundleIdentifier ?? "?", isActive: a.isActive, isHidden: a.isHidden, isFinishedLaunching: a.isFinishedLaunching)
    }

    func installedBundleID(for ref: AppRef) async -> String? {
        if let b = ref.bundleID, !b.hasSuffix(".x") { return await MainActor.run { NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) != nil ? b : nil } }
        if let n = ref.name { return AppCatalog.installed(named: n)?.bundleID }
        return nil
    }

    func launchApplication(bundleID: String) async throws -> Int32 {
        if bundleID.hasSuffix(".x") { throw BackendError.launchFailed("Unity Editor must be opened with a project from Unity Hub; JARVIS only brings a running editor forward") }
        guard let url = await MainActor.run(body: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }) else { throw BackendError.appNotFound(bundleID) }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        do {
            let app = try await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            return app.processIdentifier
        } catch { throw BackendError.launchFailed(error.localizedDescription) }
    }

    func activateApplication(pid: Int32) async -> Bool {
        await run {
            let el = self.appElement(pid)
            _ = AXUIElementSetAttributeValue(el, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
        return await MainActor.run {
            NSRunningApplication(processIdentifier: pid)?.activate()
            return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        }
    }

    func quitApplication(pid: Int32) async -> Bool {
        await MainActor.run { NSRunningApplication(processIdentifier: pid)?.terminate() ?? false }          // a normal quit REQUEST; there is no force quit
    }

    func isResponsive(pid: Int32) async -> Bool {
        await run {
            let e = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(e, 0.8)
            var v: CFTypeRef?
            let r = AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &v)
            return r == .success || r == .noValue || r == .attributeUnsupported
        }
    }

    // MARK: Windows

    private func windowList(_ pid: Int32) -> [(WindowSnapshot, AXUIElement)] {
        let app = appElement(pid)
        guard let list = attr(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        let cg = Self.cgWindows(pid: pid)
        var out: [(WindowSnapshot, AXUIElement)] = []
        for (i, w) in list.enumerated() {
            let role = str(w, kAXRoleAttribute) ?? "AXWindow"
            let sub = str(w, kAXSubroleAttribute)
            let f = frame(w) ?? .zero
            let hasSheet = children(w).contains { str($0, kAXRoleAttribute) == "AXSheet" }
            let modal = (bool(w, kAXModalAttribute) ?? false) || hasSheet || sub == "AXSystemDialog" || (sub == "AXDialog" && (bool(w, kAXModalAttribute) ?? true))
            let title = str(w, kAXTitleAttribute) ?? ""
            let match = cg.first { abs($0.frame.minX - f.minX) < 2.5 && abs($0.frame.minY - f.minY) < 2.5 && abs($0.frame.width - f.width) < 2.5 && abs($0.frame.height - f.height) < 2.5 }
            out.append((WindowSnapshot(index: i, title: String(title.prefix(160)), role: role, subrole: sub, frame: f, isMain: bool(w, kAXMainAttribute) ?? false, isFocused: bool(w, kAXFocusedAttribute) ?? false,
                                       isMinimized: bool(w, kAXMinimizedAttribute) ?? false, isModal: modal, isSheet: role == "AXSheet", cgWindowID: match?.id, identifier: str(w, kAXIdentifierAttribute),
                                       defaultButton: defaultButtonTitle(w)), w))
        }
        return out
    }

    private func defaultButtonTitle(_ window: AXUIElement) -> String? {
        let sheet = children(window).first { str($0, kAXRoleAttribute) == "AXSheet" } ?? window
        guard let b = element(attr(sheet, kAXDefaultButtonAttribute)) else { return nil }
        return str(b, kAXTitleAttribute)
    }

    private static func cgWindows(pid: Int32) -> [(id: UInt32, frame: CGRect)] {
        guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { d in
            guard (d[kCGWindowOwnerPID as String] as? Int32) == pid, (d[kCGWindowLayer as String] as? Int) == 0,
                  let id = d[kCGWindowNumber as String] as? UInt32, let b = d[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            return (id, CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0))
        }
    }

    func windows(pid: Int32) async -> [WindowSnapshot] { await run { self.windowList(pid).map(\.0) } }

    func windowOperation(_ op: WindowOp, pid: Int32, windowIndex: Int) async throws {
        try await runThrowing {
            let wins = self.windowList(pid)
            guard let w = wins.first(where: { $0.0.index == windowIndex })?.1 else { throw BackendError.noWindow }
            switch op {
            case .raise:
                _ = AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
                try Self.check(AXUIElementPerformAction(w, kAXRaiseAction as CFString))
            case .minimize: try Self.check(AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue))
            case .restore: try Self.check(AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse))
            case .close:
                guard let btn = self.element(self.attr(w, kAXCloseButtonAttribute)) else { throw BackendError.unsupported("this window has no close button") }
                try Self.check(AXUIElementPerformAction(btn, kAXPressAction as CFString))
            }
        }
    }

    private static func check(_ e: AXError) throws {
        switch e {
        case .success: return
        case .apiDisabled: throw BackendError.permissionDenied
        case .invalidUIElement: throw BackendError.elementGone
        case .cannotComplete: throw BackendError.timedOut
        case .actionUnsupported, .attributeUnsupported, .notImplemented: throw BackendError.unsupported("the element does not support this")
        default: throw BackendError.actionFailed("AX error \(e.rawValue)")
        }
    }

    // MARK: Tree (bounded)

    private static let skipDescending: Set<String> = ["AXWebArea", "AXTextArea", "AXImage", "AXScrollBar", "AXValueIndicator", "AXMatte", "AXLayoutArea"]
    private static let valueRoles: Set<String> = ["AXTextField", "AXComboBox", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXSlider", "AXStepper", "AXSwitch", "AXDisclosureTriangle", "AXIncrementor", "AXColorWell", "AXProgressIndicator", "AXLevelIndicator"]

    func snapshot(pid: Int32, scope: SnapshotScope, budget: AXBudget) async throws -> AXSnapshot {
        guard AXIsProcessTrusted() else { throw BackendError.permissionDenied }
        let apps = await runningApplications()
        guard let app = apps.first(where: { $0.pid == pid }) else { throw BackendError.appNotFound("pid \(pid)") }
        return try await runThrowing {
            let t0 = Date()
            self.generation += 1
            let gen = self.generation
            for k in self.elements.keys where k.generation < gen - 2 { self.elements[k] = nil; self.secureHandles.remove(k) }
            let wins = self.windowList(pid)
            let chosen: (WindowSnapshot, AXUIElement)?
            switch scope {
            case .window(let i): chosen = wins.first { $0.0.index == i }
            case .modalFirst: chosen = wins.first { $0.0.isModal || $0.0.isSheet } ?? wins.first { $0.0.isFocused || $0.0.isMain } ?? wins.first
            case .frontWindow: chosen = wins.first { $0.0.isFocused || $0.0.isMain } ?? wins.first { !$0.0.isMinimized } ?? wins.first
            }
            var out: [UIElementSnapshot] = []
            var truncated = false
            var focusIndex: Int?
            if let (win, root) = chosen {
                struct Item { var el: AXUIElement; var depth: Int; var parent: Int?; var ancestors: [String]; var modal: Bool }
                // a dialog-type window (alert, panel) is modal as a whole; a normal window with a sheet is modal only below the sheet
                let wholeWindowModal = win.isModal && win.subrole != "AXStandardWindow"
                var frontier: [Item] = [Item(el: root, depth: 0, parent: nil, ancestors: [], modal: wholeWindowModal)]
                var head = 0
                while head < frontier.count {
                    if out.count >= budget.maxNodes || Date().timeIntervalSince(t0) > budget.timeBudget { truncated = true; break }
                    let it = frontier[head]; head += 1
                    let role = self.str(it.el, kAXRoleAttribute) ?? "AXUnknown"
                    let sub = self.str(it.el, kAXSubroleAttribute)
                    let secure = sub == "AXSecureTextField" || role == "AXSecureTextField"
                    var title = self.str(it.el, kAXTitleAttribute) ?? ""
                    var help = self.str(it.el, kAXHelpAttribute) ?? ""
                    let desc = self.str(it.el, kAXDescriptionAttribute) ?? ""
                    if title.isEmpty { title = desc } else if help.isEmpty { help = desc }
                    var value: String?
                    var valueLength: Int?
                    if secure {
                        value = nil                                              // NEVER read
                    } else if role == "AXStaticText" {
                        let v = self.str(it.el, kAXValueAttribute) ?? ""
                        if title.isEmpty { title = String(v.prefix(120)) }
                        valueLength = v.count
                    } else if role == "AXTextArea" || role == "AXWebArea" {
                        valueLength = (self.attr(it.el, kAXNumberOfCharactersAttribute) as? Int)             // a length only
                    } else if Self.valueRoles.contains(role) {
                        if let raw = self.attr(it.el, kAXValueAttribute) {
                            if let s = raw as? String { value = String(s.prefix(120)); valueLength = s.count }
                            else if let n = raw as? NSNumber { value = n.stringValue }
                        }
                    }
                    if title.isEmpty, let ui = self.element(self.attr(it.el, kAXTitleUIElementAttribute)) {
                        title = String((self.str(ui, kAXValueAttribute) ?? self.str(ui, kAXTitleAttribute) ?? "").prefix(120))
                    }
                    // a very large container exposes what is on screen when the application says so (AXVisibleChildren); otherwise only the first children are read
                    var kids = self.children(it.el)
                    if kids.count > budget.maxChildrenPerNode, let visible = self.attr(it.el, "AXVisibleChildren") as? [AXUIElement], !visible.isEmpty { kids = visible }
                    let index = out.count
                    let handle = ElementHandle(pid: pid, generation: gen, index: index)
                    self.elements[handle] = it.el
                    if secure { self.secureHandles.insert(handle) }
                    let isSheet = role == "AXSheet" || sub == "AXSystemDialog"
                    let focused = self.bool(it.el, kAXFocusedAttribute) ?? false
                    if focused, focusIndex == nil { focusIndex = index }
                    out.append(UIElementSnapshot(id: index, role: role, subrole: sub, title: String(title.prefix(160)), help: String(help.prefix(160)), value: value, valueLength: valueLength,
                                                 enabled: self.bool(it.el, kAXEnabledAttribute) ?? true, focused: focused, selected: (self.bool(it.el, kAXSelectedAttribute) ?? false) || ((role == "AXRadioButton" || role == "AXCheckBox") && value == "1"),
                                                 identifier: self.str(it.el, kAXIdentifierAttribute), actions: self.actionNames(it.el), frame: self.frame(it.el), parent: it.parent, depth: it.depth,
                                                 childCount: kids.count, isSecure: secure, ancestorTitles: it.ancestors, handle: handle, inModal: it.modal || isSheet))
                    if it.depth < budget.maxDepth, !Self.skipDescending.contains(role) {
                        let next = String(title.prefix(60))
                        let anc = next.isEmpty ? it.ancestors : Array(([next] + it.ancestors).prefix(4))
                        for k in kids.prefix(budget.maxChildrenPerNode) { frontier.append(Item(el: k, depth: it.depth + 1, parent: index, ancestors: anc, modal: it.modal || isSheet)) }
                        if kids.count > budget.maxChildrenPerNode { truncated = true }
                    }
                }
                if head < frontier.count { truncated = true }
            }
            return AXSnapshot(app: app, windows: wins.map(\.0), windowIndex: chosen?.0.index, elements: out, generation: gen, truncated: truncated, capturedAt: Date(),
                              durationMS: Date().timeIntervalSince(t0) * 1000, focusedElement: focusIndex)
        }
    }

    // MARK: Menus

    private func menuBar(_ pid: Int32) -> AXUIElement? {
        element(attr(appElement(pid), kAXMenuBarAttribute))
    }
    private func menuBarItems(_ pid: Int32) -> [AXUIElement] { menuBar(pid).map { children($0) } ?? [] }

    func menuBarTitles(pid: Int32) async throws -> [String] {
        guard AXIsProcessTrusted() else { throw BackendError.permissionDenied }
        return await run { self.menuBarItems(pid).map { self.str($0, kAXTitleAttribute) ?? "" } }
    }

    private func menuChildren(of item: AXUIElement) -> [AXUIElement] {
        // a menu bar item / menu item owns one AXMenu whose children are the entries
        let menus = children(item).filter { str($0, kAXRoleAttribute) == "AXMenu" }
        return menus.first.map { children($0) } ?? []
    }

    private func menuSnapshot(_ el: AXUIElement) -> MenuItemSnapshot {
        let title = str(el, kAXTitleAttribute) ?? ""
        let mark = str(el, kAXMenuItemMarkCharAttribute) ?? ""
        return MenuItemSnapshot(title: title, enabled: bool(el, kAXEnabledAttribute) ?? true, hasSubmenu: !menuChildren(of: el).isEmpty, isSeparator: title.isEmpty, checked: !mark.isEmpty)
    }

    /// Walks the path (opening nothing but the ancestors that must be opened to read the next level). Returns the items of the LAST level.
    func menuItems(pid: Int32, path: [String]) async throws -> [MenuItemSnapshot] {
        guard AXIsProcessTrusted() else { throw BackendError.permissionDenied }
        return try await runThrowing {
            var level = self.menuBarItems(pid)
            for (i, want) in path.enumerated() {
                guard let hit = level.first(where: { ComputerText.menuKey(self.str($0, kAXTitleAttribute) ?? "") == ComputerText.menuKey(want) }) else { throw BackendError.elementGone }
                if i == path.count - 1 && path.count > 0 { level = self.menuChildren(of: hit) } else { level = self.menuChildren(of: hit) }
            }
            return level.map(self.menuSnapshot)
        }
    }

    func pressMenuPath(pid: Int32, path: [String]) async throws {
        guard AXIsProcessTrusted() else { throw BackendError.permissionDenied }
        try await runThrowing {
            var level = self.menuBarItems(pid)
            var opened: [AXUIElement] = []
            for (i, want) in path.enumerated() {
                guard let hit = level.first(where: { ComputerText.menuKey(self.str($0, kAXTitleAttribute) ?? "") == ComputerText.menuKey(want) }) else {
                    for o in opened.reversed() { _ = AXUIElementPerformAction(o, kAXCancelAction as CFString) }
                    throw BackendError.elementGone
                }
                guard self.bool(hit, kAXEnabledAttribute) ?? true else { throw BackendError.actionFailed("the menu item “\(want)” is disabled") }
                try Self.check(AXUIElementPerformAction(hit, kAXPressAction as CFString))
                if i < path.count - 1 {
                    opened.append(hit)
                    var kids = self.menuChildren(of: hit)
                    var waited = 0.0
                    while kids.isEmpty, waited < 0.5 { Thread.sleep(forTimeInterval: 0.05); waited += 0.05; kids = self.menuChildren(of: hit) }      // the menu builds itself when opened
                    level = kids
                }
            }
        }
    }

    func readValue(_ h: ElementHandle) async throws -> String? {
        try await runThrowing {
            guard let el = self.elements[h] else { throw BackendError.elementGone }
            if self.secureHandles.contains(h) { throw BackendError.secureField }
            if self.str(el, kAXSubroleAttribute) == "AXSecureTextField" { throw BackendError.secureField }
            if let v = self.attr(el, kAXValueAttribute) { return (v as? String).map { String($0.prefix(500)) } ?? (v as? NSNumber)?.stringValue }
            return nil
        }
    }

    // MARK: Element operations (native AX actions first)

    func perform(_ op: ElementOp, on h: ElementHandle) async throws {
        try await runThrowing {
            guard let el = self.elements[h] else { throw BackendError.elementGone }
            switch op {
            case .press:
                let t0 = Date()
                let err = AXUIElementPerformAction(el, kAXPressAction as CFString)
                if err == .actionUnsupported || err == .attributeUnsupported || err == .notImplemented {          // say what the element looked like at that moment (names only — no UI text)
                    var names: CFArray?
                    AXUIElementCopyActionNames(el, &names)
                    let enabled = (self.attr(el, kAXEnabledAttribute) as? Bool).map { $0 ? "enabled" : "disabled" } ?? "enabled unknown"
                    throw BackendError.unsupported("the element does not support this (AXPress returned \(err.rawValue) after \(Int(Date().timeIntervalSince(t0) * 1000)) ms; actions \((names as? [String]) ?? []); \(enabled))")
                }
                try Self.check(err)
            case .confirm: try Self.check(AXUIElementPerformAction(el, kAXConfirmAction as CFString))
            case .showMenu: try Self.check(AXUIElementPerformAction(el, kAXShowMenuAction as CFString))
            case .raise: try Self.check(AXUIElementPerformAction(el, kAXRaiseAction as CFString))
            case .increment: try Self.check(AXUIElementPerformAction(el, kAXIncrementAction as CFString))
            case .decrement: try Self.check(AXUIElementPerformAction(el, kAXDecrementAction as CFString))
            case .cancel: try Self.check(AXUIElementPerformAction(el, kAXCancelAction as CFString))
            case .scrollToVisible: try Self.check(AXUIElementPerformAction(el, "AXScrollToVisible" as CFString))
            case .focus: try Self.check(AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue))
            case .select: try Self.check(AXUIElementSetAttributeValue(el, kAXSelectedAttribute as CFString, kCFBooleanTrue))
            }
        }
    }

    func setValue(_ text: String, on h: ElementHandle) async throws {
        try await runThrowing {
            guard let el = self.elements[h] else { throw BackendError.elementGone }
            if self.secureHandles.contains(h) || self.str(el, kAXSubroleAttribute) == "AXSecureTextField" { throw BackendError.secureField }
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue else { throw BackendError.unsupported("the value cannot be set directly") }
            try Self.check(AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFString))
        }
    }

    // MARK: Synthetic input — aimed at one process, chunked, cancellable

    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "right_bracket": 30, "o": 31, "u": 32, "left_bracket": 33, "i": 34, "p": 35,
        "return": 36, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "comma": 43, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "enter": 76,
        "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    ]

    func postKey(_ chord: KeyChord, toPID pid: Int32) async throws {
        guard AXIsProcessTrusted() else { throw BackendError.permissionDenied }
        guard let code = Self.keyCodes[chord.key] else { throw BackendError.unsupported("unknown key \(chord.key)") }
        var flags: CGEventFlags = []
        if chord.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if chord.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if chord.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if chord.modifiers.contains(.control) { flags.insert(.maskControl) }
        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { throw BackendError.actionFailed("could not build the key event") }
            e.flags = flags
            e.postToPid(pid)
        }
    }

    func typeText(_ text: String, toPID pid: Int32, shouldContinue: @escaping @Sendable () -> Bool) async throws {
        guard AXIsProcessTrusted() else { throw BackendError.permissionDenied }
        let src = CGEventSource(stateID: .privateState)
        var buffer: [UniChar] = []
        func flush() throws {
            guard !buffer.isEmpty else { return }
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { throw BackendError.actionFailed("could not build the text event") }
                e.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer)
                e.postToPid(pid)
            }
            buffer.removeAll()
        }
        for scalar in text.utf16 {
            buffer.append(scalar)
            if buffer.count >= 8 {
                guard shouldContinue(), !Task.isCancelled else { return }          // stop at once: no later key event is sent
                try flush()
                try await Task.sleep(nanoseconds: 6_000_000)
            }
        }
        guard shouldContinue(), !Task.isCancelled else { return }
        try flush()
    }

    func postScroll(direction: ScrollDirection, lines: Int, atGlobal p: CGPoint, toPID pid: Int32) async throws {
        guard AXIsProcessTrusted() else { throw BackendError.permissionDenied }
        let dy: Int32 = direction == .up ? Int32(lines) : direction == .down ? -Int32(lines) : 0
        let dx: Int32 = direction == .left ? Int32(lines) : direction == .right ? -Int32(lines) : 0
        let src = CGEventSource(stateID: .privateState)
        guard let e = CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { throw BackendError.actionFailed("could not build the scroll event") }
        e.location = p
        e.postToPid(pid)
    }

    func postClick(atGlobal p: CGPoint) async throws {
        guard AXIsProcessTrusted() else { throw BackendError.permissionDenied }
        let src = CGEventSource(stateID: .hidSystemState)
        let before = CGEvent(source: nil)?.location                  // where the user's pointer is now
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { throw BackendError.actionFailed("could not build the mouse event") }
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        if let before { CGWarpMouseCursorPosition(before) }          // the pointer goes back where the user had it (no decorative cursor movement)
    }

    func topWindowID(atGlobal p: CGPoint) async -> UInt32? {
        await run {
            guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }      // front-to-back
            // The Dock keeps one invisible full-display window (layer 20) on every screen and the Window Server owns backdrops: neither is "a window covering the application".
            let transparentOwners: Set<String> = ["Dock", "Window Server"]
            for d in info {
                guard let id = d[kCGWindowNumber as String] as? UInt32, let b = d[kCGWindowBounds as String] as? [String: CGFloat], (d[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                      !transparentOwners.contains(d[kCGWindowOwnerName as String] as? String ?? ""), (d[kCGWindowLayer as String] as? Int ?? 0) >= 0 else { continue }
                let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
                if r.contains(p) { return id }
            }
            return nil
        }
    }

    func scrollBy(_ h: ElementHandle, direction: ScrollDirection, step: Double) async throws -> Double {
        try await runThrowing {
            guard let el = self.elements[h] else { throw BackendError.elementGone }
            let name = (direction == .up || direction == .down) ? "AXVerticalScrollBar" : "AXHorizontalScrollBar"
            guard let barEl = self.element(self.attr(el, name)) else { throw BackendError.unsupported("the scroll area has no \(name)") }
            guard let current = (self.attr(barEl, kAXValueAttribute) as? NSNumber)?.doubleValue else { throw BackendError.unsupported("the scroll bar has no value") }
            let delta = (direction == .down || direction == .right) ? step : -step
            let next = min(1, max(0, current + delta))
            if next == current { return current }
            try Self.check(AXUIElementSetAttributeValue(barEl, kAXValueAttribute as CFString, next as CFNumber))
            return next
        }
    }

    // MARK: Workspace (typed destinations only)

    func openFile(path: String, withBundleID bundleID: String?) async throws {
        let url = URL(fileURLWithPath: path)
        if let bundleID, let app = await MainActor.run(body: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            do { _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: cfg) } catch { throw BackendError.launchFailed(error.localizedDescription) }
        } else {
            guard await MainActor.run(body: { NSWorkspace.shared.open(url) }) else { throw BackendError.launchFailed("the system could not open the file") }
        }
    }

    func revealInFinder(path: String) async throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { throw BackendError.actionFailed("the path does not exist") }
        let url = URL(fileURLWithPath: path)
        if isDir.boolValue, let finder = await MainActor.run(body: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: SurfacePolicy.finder) }) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            do { _ = try await NSWorkspace.shared.open([url], withApplicationAt: finder, configuration: cfg) } catch { throw BackendError.launchFailed(error.localizedDescription) }
        } else {
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    func openSettingsPane(_ pane: SettingsPane) async throws {
        var c = URLComponents()
        c.scheme = "x-apple.systempreferences"
        switch pane {
        case .accessibility: c.path = "com.apple.preference.security"; c.query = "Privacy_Accessibility"
        case .screenRecording: c.path = "com.apple.preference.security"; c.query = "Privacy_ScreenCapture"
        case .microphone: c.path = "com.apple.preference.security"; c.query = "Privacy_Microphone"
        case .privacy: c.path = "com.apple.preference.security"
        case .general: c.path = "com.apple.systempreferences.GeneralSettings"
        case .displays: c.path = "com.apple.Displays-Settings.extension"
        }
        guard let url = c.url, await MainActor.run(body: { NSWorkspace.shared.open(url) }) else { throw BackendError.launchFailed("System Settings did not open") }
    }

    // MARK: Screen

    func displays() -> DisplayLayout {
        let read: () -> DisplayLayout = {
            let primary = NSScreen.screens.first
            return DisplayLayout(displays: NSScreen.screens.map { s in
                let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                return DisplayInfo(id: id, frame: s.frame, visibleFrame: s.visibleFrame, scale: s.backingScaleFactor, isPrimary: s == primary)
            })
        }
        return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }

    func captureWindow(cgWindowID: UInt32, windowFrame: CGRect) async throws -> CapturedWindow {
        try await WindowCapture.capture(windowID: cgWindowID, expectedFrame: windowFrame)
    }
}
