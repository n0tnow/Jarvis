import AppKit
import Observation

/// Minimal user settings, persisted in UserDefaults.
@MainActor
@Observable
final class Preferences {
    private enum Key {
        static let reduceMotion = "prefs.reduceMotion"
        static let showDeveloperControls = "prefs.showDeveloperControls"
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

    /// Mirrors System Settings ▸ Accessibility ▸ Display ▸ Reduce motion.
    private(set) var systemReduceMotion: Bool

    /// Launch at Login is intentionally NOT implemented in V0.1 (see docs/ROADMAP.md).
    let launchAtLoginIsAvailable = false

    var effectiveReduceMotion: Bool { reduceMotion || systemReduceMotion }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reduceMotion = defaults.bool(forKey: Key.reduceMotion)
        showDeveloperControls = defaults.object(forKey: Key.showDeveloperControls) as? Bool ?? true
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
