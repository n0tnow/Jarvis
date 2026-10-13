import Foundation

// MARK: - Application adapters (small, only where they materially help)
//
// The generic Accessibility layer does the work. An adapter only records what is KNOWN about an application so the planner and the report can be honest about it:
// which safe native shortcuts it has, whether its interface is custom-drawn (→ the window-scoped vision fallback is the realistic route), and which risks are special.
// An adapter never adds an action kind, never lowers a risk and never bypasses a policy.

struct ApplicationAdapter: Sendable {
    var bundleID: String
    var name: String
    /// Semantic navigation that exists as an allowlisted shortcut (preferred over hunting for a control).
    var navigation: [String: KeyChord] = [:]
    /// Most of the interface is drawn by the application itself: Accessibility sees little, so vision is the honest fallback.
    var customDrawn = false
    var notes: String
}

enum AdapterRegistry {
    static let all: [ApplicationAdapter] = [
        ApplicationAdapter(bundleID: "com.apple.finder", name: "Finder",
                           notes: "Open a folder or reveal a file through the typed OpenFile/RevealFile actions (NSWorkspace). Finder's own menu cannot open, trash or duplicate files: that would bypass the file tools and the quarantine."),
        ApplicationAdapter(bundleID: "com.apple.dt.Xcode", name: "Xcode",
                           navigation: ["project": KeyChord("1", [.command]), "source control": KeyChord("2", [.command]), "symbol": KeyChord("3", [.command]), "find": KeyChord("4", [.command]),
                                        "issue": KeyChord("5", [.command]), "test": KeyChord("6", [.command]), "debug": KeyChord("7", [.command]), "breakpoint": KeyChord("8", [.command]), "report": KeyChord("9", [.command])],
                           notes: "Navigators by ⌘1…⌘9, Settings from the application menu. Source edits are never made through the Xcode GUI: V0.4 edits files directly. Build/Run shortcuts are not on the allowlist."),
        ApplicationAdapter(bundleID: "org.blenderfoundation.blender", name: "Blender", customDrawn: true,
                           notes: "Blender draws its own interface: Accessibility exposes the window and the menu bar, not the editors or the 3D viewport. Controls inside the viewport need the window-scoped vision fallback; V0.11 does not attempt modelling."),
        ApplicationAdapter(bundleID: SurfacePolicy.systemSettings, name: "System Settings",
                           notes: "Navigation (panes, sidebar rows) is automatic; switches, checkboxes and pop-ups are the user's — privacy and security settings are never changed by JARVIS."),
        ApplicationAdapter(bundleID: "com.unity3d.UnityEditor5.x", name: "Unity",
                           notes: "Scene, component, compile, test and Console work goes through the V0.6 bridge. Computer Use only brings the editor to the front or looks at a harmless dialog."),
        ApplicationAdapter(bundleID: "com.jarvis.fixture", name: "JARVIS Fixture", notes: "A test dummy that only counts presses."),
    ]

    static func adapter(for bundleID: String?) -> ApplicationAdapter? {
        guard let b = bundleID else { return nil }
        return all.first { $0.bundleID == b || (b.hasPrefix("com.unity3d.UnityEditor") && $0.bundleID.hasPrefix("com.unity3d.UnityEditor")) }
    }
}
