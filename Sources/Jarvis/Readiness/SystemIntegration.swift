import AppKit
import ServiceManagement
import UserNotifications

// MARK: - macOS integration for the installed app (V0.15, DEC-239…241)
//
// Launch at Login, native notifications and the single-instance rule. All three are USER-CONTROLLED, reversible, and use only the modern supported APIs: no login-item plist is written by
// hand, no launch daemon, no helper tool, no sudo. Nothing here grants any authority.

// MARK: Launch at Login

enum LaunchAtLogin {
    static var status: LoginItemStatus {
        guard AppInfo.isApplicationBundle else { return .unsupported }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .disabled          // macOS answers “not found” for an app that has never been registered; registering works (tested reversibly)
        case .notRegistered: return .disabled
        @unknown default: return .unsupported
        }
    }

    /// Registers or unregisters THIS app as a login item through `SMAppService`. Returns an error text, or nil on success. The user can always see and remove it in System Settings → General → Login Items.
    @discardableResult
    static func set(_ on: Bool) -> String? {
        guard AppInfo.isApplicationBundle else { return "Launch at Login works only for the installed JARVIS.app (this is a development binary)." }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return "macOS did not change the login item: \(error.localizedDescription)"
        }
    }

    static func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}

// MARK: Notifications

/// Long-task completion, failure and decision requests — nothing else. The body never contains project content: a notification can be seen on a locked screen.
@MainActor
final class JarvisNotifier {
    private(set) var status: PermissionStatus = .notDetermined
    private(set) var posted = 0
    @ObservationIgnored var enabled: () -> Bool = { false }
    /// Tests replace the delivery; production uses the notification center. Never called when `enabled()` is false.
    @ObservationIgnored var deliver: (String, String, String) async -> Void = { title, body, id in
        guard AppInfo.isApplicationBundle else { return }
        let c = UNMutableNotificationContent(); c.title = title; c.body = body; c.sound = nil
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    /// Reads the current permission without asking.
    func refreshStatus() async {
        guard AppInfo.isApplicationBundle else { status = .unsupported; return }
        let s = await UNUserNotificationCenter.current().notificationSettings()
        status = Self.map(s.authorizationStatus)
    }

    /// Explicit user action only (the Allow Notifications button or switching task notifications on).
    func requestAuthorization() async -> Bool {
        guard AppInfo.isApplicationBundle else { return false }
        let ok = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
        await refreshStatus()
        return ok
    }

    static func map(_ s: UNAuthorizationStatus) -> PermissionStatus {
        switch s { case .authorized, .provisional, .ephemeral: .granted; case .denied: .denied; case .notDetermined: .notDetermined; @unknown default: .unsupported }
    }

    /// `completed`: finished fine; false = could not finish; nil = a decision is needed. Generic wording by design.
    func post(completed: Bool?, language: ReplyLanguage, id: String = UUID().uuidString) async {
        guard enabled(), status == .granted else { return }
        let body = completed.map { DailyPhrasebook.notified(completed: $0, language) } ?? (language == .tr ? "JARVIS bir kararınızı bekliyor." : "JARVIS needs a decision from you.")
        posted += 1
        await deliver("JARVIS", body, id)
    }
}

// MARK: Single instance

enum SingleInstance {
    static let showNotification = Notification.Name("dev.jarvis.Jarvis.showFromSecondLaunch")

    /// A plain Finder / Spotlight / Dock / login launch has no `--flag` arguments. Developer and live-test runs (which start deliberate extra copies) are never single-instance restricted.
    static func isPlainLaunch(_ arguments: [String] = CommandLine.arguments) -> Bool {
        !arguments.dropFirst().contains { $0.hasPrefix("--") }
    }

    /// If another copy of this app is already running, asks it to show itself and returns true (the caller then exits). Uses the Launch Services running-application list, not a lock file.
    @MainActor
    static func handOverToRunningInstance(bundleID: String = AppInfo.bundleIdentifier, myPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> Bool {
        guard isPlainLaunch() else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { $0.processIdentifier != myPID && !$0.isTerminated }
        guard let existing = others.first else { return false }
        DistributedNotificationCenter.default().postNotificationName(showNotification, object: nil, userInfo: nil, deliverImmediately: true)
        existing.activate()
        return true
    }
}

// MARK: Opening the right System Settings pane (PrivacySettingsPane — distinct from Computer Use's SettingsPane) (fixed list; no URL comes from anywhere else)

enum PrivacySettingsPane {
    case microphone, accessibility, screenRecording, notifications, loginItems
    var url: URL {
        switch self {
        case .microphone: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .screenRecording: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        case .notifications: URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        case .loginItems: URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        }
    }
    @MainActor func open() { NSWorkspace.shared.open(url) }
}
