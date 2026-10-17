import Foundation
import CoreGraphics

// MARK: - Semantic target resolution (no guessing, no coordinates)

enum TargetResolver {
    /// AX role words → the AX roles they mean.
    static func roles(for word: String?) -> Set<String>? {
        guard let w = word.map(ComputerText.fold), !w.isEmpty else { return nil }
        switch w {
        case "button": return ["button", "menubutton", "popupbutton"]
        case "tab": return ["radiobutton", "tab", "tabbutton", "button"]
        case "textfield", "field", "input", "textarea": return ["textfield", "textarea", "combobox", "searchfield"]
        case "checkbox", "switch", "toggle": return ["checkbox", "switch"]
        case "row", "sidebaritem", "item", "cell": return ["row", "outlinerow", "cell", "statictext", "button"]
        case "menuitem", "menu": return ["menuitem", "menubaritem", "menubutton", "popupbutton"]
        case "link": return ["link"]
        case "scrollarea": return ["scrollarea"]
        case "window": return ["window", "sheet"]
        default: return [w]
        }
    }

    private static func key(_ s: String) -> String {
        ComputerText.menuKey(s).split(whereSeparator: { !($0.isLetter || $0.isNumber) }).joined(separator: " ")
    }

    private enum Match: Int { case none = 0, partial = 1, exact = 2 }

    private static func titleMatch(_ want: String, _ e: UIElementSnapshot) -> Match {
        let w = key(want)
        guard !w.isEmpty else { return .none }
        let candidates = [e.title, e.help, e.value ?? ""].map(key).filter { !$0.isEmpty }
        if candidates.contains(w) { return .exact }
        // a long label that merely starts with / contains the wanted words ("Render Properties" ⊂ "Render Properties tab") is a partial match
        if candidates.contains(where: { $0.hasPrefix(w + " ") || $0.hasSuffix(" " + w) || $0.contains(" " + w + " ") || (w.count >= 4 && w.hasPrefix($0 + " ") && $0.count >= 3) }) { return .partial }
        return .none
    }

    static func resolve(_ t: ActionTarget, in snap: AXSnapshot) -> TargetResolution {
        let first = resolveOnce(t, in: snap)
        // A control with several plausible labels (a video player's Play / Resume / Oynat): look for the others only when the first label found NOTHING; an ambiguous result stays ambiguous.
        guard first.state == .notFound, let alternatives = t.titleAlternatives, !alternatives.isEmpty else { return first }
        for label in alternatives {
            var other = t; other.title = label; other.titleAlternatives = nil
            let r = resolveOnce(other, in: snap)
            if r.state != .notFound { return r }
        }
        return TargetResolution(state: first.state, element: first.element, candidates: first.candidates, reason: first.reason + " (also looked for: \(alternatives.joined(separator: ", ")))")
    }

    private static func resolveOnce(_ t: ActionTarget, in snap: AXSnapshot) -> TargetResolution {
        let wantedRoles = roles(for: t.role)
        var scored: [(UIElementSnapshot, Match)] = []
        for e in snap.elements {
            if let r = wantedRoles, !r.contains(ComputerPolicy.shortRole(e.role)) && !(e.subrole.map { r.contains(ComputerPolicy.shortRole($0)) } ?? false) { continue }
            if let id = t.identifier, !id.isEmpty {
                if e.identifier == id { scored.append((e, .exact)) }
                continue
            }
            guard let title = t.title, !title.isEmpty else { continue }
            let m = titleMatch(title, e)
            if m != .none { scored.append((e, m)) }
        }
        if let within = t.within.map(key), !within.isEmpty {
            let inside = scored.filter { s in s.0.ancestorTitles.contains { key($0).contains(within) } }
            if !inside.isEmpty { scored = inside }
        }
        guard !scored.isEmpty else {
            return TargetResolution(state: .notFound, element: nil, candidates: [], reason: "no \(t.role ?? "element") labelled “\(t.title ?? t.identifier ?? "?")” in \(snap.window?.title ?? snap.app.name)")
        }
        let exact = scored.filter { $0.1 == .exact }.map(\.0)
        let pool = exact.isEmpty ? scored.map(\.0) : exact
        // Prefer controls that can actually be acted on over decorative labels with the same text.
        let actionable = pool.filter { !$0.actions.isEmpty || $0.enabled && ["button", "radiobutton", "checkbox", "menuitem", "textfield", "row", "link", "popupbutton", "tab"].contains(ComputerPolicy.shortRole($0.role)) }
        let finalPool = actionable.isEmpty ? pool : actionable
        if finalPool.count == 1 { return TargetResolution(state: exact.isEmpty ? .strong : .exact, element: finalPool[0], candidates: finalPool, reason: exact.isEmpty ? "one element contains the label" : "one element has exactly that label") }
        if let n = t.occurrence, n >= 1, n <= finalPool.count {
            let ordered = finalPool.sorted { ($0.frame?.minY ?? 0, $0.frame?.minX ?? 0) < ($1.frame?.minY ?? 0, $1.frame?.minX ?? 0) }
            return TargetResolution(state: .strong, element: ordered[n - 1], candidates: ordered, reason: "occurrence \(n) of \(finalPool.count), as you said")
        }
        // Context that separates them: exactly one is inside the modal / is focused.
        let modal = finalPool.filter(\.inModal)
        if modal.count == 1, snap.hasModal { return TargetResolution(state: .strong, element: modal[0], candidates: finalPool, reason: "only the one in the open dialog is reachable") }
        let focused = finalPool.filter(\.focused)
        if focused.count == 1 { return TargetResolution(state: .strong, element: focused[0], candidates: finalPool, reason: "only one of them has the focus") }
        return TargetResolution(state: .ambiguous, element: nil, candidates: Array(finalPool.prefix(5)), reason: "\(finalPool.count) elements match “\(t.title ?? t.identifier ?? "?")” equally — need more context (which window/section?)")
    }

    // MARK: Windows

    struct WindowResolution { var state: ResolutionState; var window: WindowSnapshot?; var reason: String }

    static func resolveWindow(title: String?, in windows: [WindowSnapshot]) -> WindowResolution {
        let visible = windows.filter { !$0.isMinimized || title != nil }
        guard !visible.isEmpty else { return WindowResolution(state: .notFound, window: nil, reason: "the application has no window") }
        if let t = title.map(key), !t.isEmpty {
            let exact = visible.filter { key($0.title) == t }
            if exact.count == 1 { return WindowResolution(state: .exact, window: exact[0], reason: "title matches exactly") }
            let part = visible.filter { key($0.title).contains(t) }
            if exact.isEmpty, part.count == 1 { return WindowResolution(state: .strong, window: part[0], reason: "title contains the words") }
            let pool = exact.isEmpty ? part : exact
            if pool.isEmpty { return WindowResolution(state: .notFound, window: nil, reason: "no window titled “\(title ?? "")”") }
            if let f = pool.first(where: { $0.isFocused || $0.isMain }), pool.filter({ $0.isFocused || $0.isMain }).count == 1 { return WindowResolution(state: .strong, window: f, reason: "the only matching window with the focus") }
            return WindowResolution(state: .ambiguous, window: nil, reason: "\(pool.count) windows match “\(title ?? "")”")
        }
        // No title: the modal one wins (it must be dealt with first), then the focused/main one.
        if let m = visible.first(where: { $0.isModal || $0.isSheet }) { return WindowResolution(state: .strong, window: m, reason: "a dialog is open — it comes first") }
        if let f = visible.first(where: \.isFocused) ?? visible.first(where: \.isMain) { return WindowResolution(state: .strong, window: f, reason: "the focused window") }
        if visible.count == 1 { return WindowResolution(state: .strong, window: visible[0], reason: "the only window") }
        return WindowResolution(state: .ambiguous, window: nil, reason: "\(visible.count) windows and none is focused")
    }
}
