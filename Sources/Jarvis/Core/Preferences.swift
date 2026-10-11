import AppKit
import Observation

/// Minimal user settings, persisted in UserDefaults.
@MainActor
@Observable
final class Preferences {
    private enum Key {
        static let reduceMotion = "prefs.reduceMotion"
        static let showDeveloperControls = "prefs.showDeveloperControls"
        static let globalShortcuts = "prefs.globalShortcutsEnabled"
        static let providerPreference = "prefs.providerPreference"
        static let claudePath = "prefs.claudePathOverride"
        static let codexPath = "prefs.codexPathOverride"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var motionObserver: NSObjectProtocol?

    var reduceMotion: Bool {
        didSet { defaults.set(reduceMotion, forKey: Key.reduceMotion) }
    }

    /// Developer controls (state simulator) — ON by default in V0.1 because the demo state machine is the point.
    var showDeveloperControls: Bool {
        didSet { defaults.set(showDeveloperControls, forKey: Key.showDeveloperControls) }
    }

    /// Global ⌥⌘ / ⌥⌘⌘ shortcuts (permission-free modifier polling). On by default; this is the off switch.
    var globalShortcutsEnabled: Bool {
        didSet { defaults.set(globalShortcutsEnabled, forKey: Key.globalShortcuts) }
    }

    /// Which intelligence provider answers reasoning requests (Auto = first READY of Claude Code, Codex).
    var providerPreference: ProviderPreference {
        didSet { defaults.set(providerPreference.rawValue, forKey: Key.providerPreference) }
    }
    /// Optional user-chosen executable locations (the GUI app's PATH is not the Terminal's).
    var claudePathOverride: String { didSet { defaults.set(claudePathOverride, forKey: Key.claudePath) } }
    var codexPathOverride: String { didSet { defaults.set(codexPathOverride, forKey: Key.codexPath) } }

    /// Mirrors System Settings ▸ Accessibility ▸ Display ▸ Reduce motion.
    private(set) var systemReduceMotion: Bool

    /// Launch at Login is intentionally NOT implemented in V0.1 (see docs/ROADMAP.md).
    let launchAtLoginIsAvailable = false

    var effectiveReduceMotion: Bool { reduceMotion || systemReduceMotion }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reduceMotion = defaults.bool(forKey: Key.reduceMotion)
        showDeveloperControls = defaults.object(forKey: Key.showDeveloperControls) as? Bool ?? true
        globalShortcutsEnabled = defaults.object(forKey: Key.globalShortcuts) as? Bool ?? true
        providerPreference = ProviderPreference(rawValue: defaults.string(forKey: Key.providerPreference) ?? "") ?? .auto
        claudePathOverride = defaults.string(forKey: Key.claudePath) ?? ""
        codexPathOverride = defaults.string(forKey: Key.codexPath) ?? ""
        systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
    }
}
