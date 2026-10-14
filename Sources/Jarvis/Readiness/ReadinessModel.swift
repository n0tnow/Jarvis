import Foundation

// MARK: - Readiness (V0.15, DEC-238): “what is ready?”
//
// A READ-ONLY picture of the installed pieces. Building it never starts a model, a provider, an MCP server, Unity, a browser or a download, never prompts for a permission, never reads a credential
// store and never spends quota. “Installed”, “available”, “signed in”, “healthy” and “running” are different facts and are shown as different states.

enum ReadinessCategory: String, CaseIterable, Identifiable, Sendable {
    case core = "Core", intelligence = "Intelligence", localAI = "Local AI", voice = "Voice", computer = "Computer Use", unity = "Unity", mcp = "MCPs", permissions = "Permissions", startup = "Startup"
    var id: String { rawValue }
}

enum ReadinessState: Equatable, Sendable {
    case ready                          // verified by a safe check that actually ran
    case available                      // present, but nothing verified it yet (e.g. an executable that has not been probed)
    case notInstalled
    case signInRequired
    case permissionNeeded
    case optionalAbsent                 // not installed, and nothing needs it right now
    case notRunning                     // installed; idle by design (Unity, MCP servers, models)
    case off                            // a feature the user can switch on (Voice, Push-to-Talk) that is currently switched OFF
    case degraded(String)
    case stale(String)                  // last known state is old
    case unknown                        // not checked yet
    case unavailable(String)

    var label: String {
        switch self {
        case .ready: "READY"
        case .available: "AVAILABLE"
        case .notInstalled: "NOT INSTALLED"
        case .signInRequired: "SIGN-IN REQUIRED"
        case .permissionNeeded: "PERMISSION NEEDED"
        case .optionalAbsent: "OPTIONAL · NOT SET UP"
        case .notRunning: "NOT RUNNING"
        case .off: "OFF"
        case .degraded: "DEGRADED"
        case .stale: "STALE"
        case .unknown: "NOT CHECKED"
        case .unavailable: "UNAVAILABLE"
        }
    }
    /// Something the user may want to act on (shown as a warning in Settings). Optional-and-absent, idle and not-yet-checked are not warnings.
    var needsAttention: Bool {
        switch self {
        case .notInstalled, .signInRequired, .permissionNeeded, .degraded, .unavailable, .stale: true
        case .ready, .available, .optionalAbsent, .notRunning, .unknown, .off: false
        }
    }
    var isGood: Bool { self == .ready || self == .available || self == .notRunning }
    var detailNote: String? {
        switch self { case .degraded(let s), .stale(let s), .unavailable(let s): s; default: nil }
    }
}

/// The only things a Set Up / Open Settings / Recheck button can do. A closed list: there is no text field, URL or command anywhere in it.
enum SetupAction: String, CaseIterable, Identifiable, Sendable {
    case recheck
    case allowMicrophone, openMicrophoneSettings
    case allowAccessibility, openAccessibilitySettings
    case allowScreenRecording, openScreenRecordingSettings
    case allowNotifications, openNotificationSettings
    case installLocalModelRuntime, installSpeechRecognizer, installNaturalVoice, installVisionHelper, installMemoryHelper
    case chooseLocalModelFolder
    /// Explicit click: switches Voice (and Push-to-Talk) ON in Settings. It opens no microphone — that happens only while the key is held.
    case turnOnVoice
    var id: String { rawValue }

    var title: String {
        switch self {
        case .recheck: "Recheck"
        case .allowMicrophone: "Allow Microphone"
        case .openMicrophoneSettings: "Open Microphone Settings"
        case .allowAccessibility: "Allow Accessibility"
        case .openAccessibilitySettings: "Open Accessibility Settings"
        case .allowScreenRecording: "Allow Screen Recording"
        case .openScreenRecordingSettings: "Open Screen Recording Settings"
        case .allowNotifications: "Allow Notifications"
        case .openNotificationSettings: "Open Notification Settings"
        case .installLocalModelRuntime: "Set Up Local Model Runtime"
        case .installSpeechRecognizer: "Set Up Whisper"
        case .installNaturalVoice: "Set Up Natural Voice"
        case .installVisionHelper: "Set Up Visual Model"
        case .installMemoryHelper: "Set Up Memory Search"
        case .chooseLocalModelFolder: "Select Existing Model Folder"
        case .turnOnVoice: "Turn On Voice"
        }
    }
    /// Actions that download or install files (explicit click, preflight, progress, cancel).
    var isInstall: Bool {
        switch self { case .installLocalModelRuntime, .installSpeechRecognizer, .installNaturalVoice, .installVisionHelper, .installMemoryHelper: true; default: false }
    }
}

struct ReadinessItem: Identifiable, Equatable, Sendable {
    var id: String
    var category: ReadinessCategory
    var name: String
    var state: ReadinessState
    var detail: String = ""
    /// Required for JARVIS to be usable at all (core) — everything else is optional.
    var required = false
    var action: SetupAction?
    var checkedAt: Date?
    /// What is known about the files regardless of the state: true = found on disk, false = not found, nil = unknown. (A provider can be present yet NOT CHECKED.)
    var installed: Bool?
}

enum ReadinessSummary: Equatable, Sendable {
    case ready                      // core fine, at least one way to think, nothing needs attention
    case usable(gaps: Int)          // core fine; optional pieces missing or attention items present
    case notReady(String)           // a required piece is missing

    var headline: String {
        switch self {
        case .ready: "Ready"
        case .usable(let n): "Ready, with \(n) thing\(n == 1 ? "" : "s") to look at"
        case .notReady(let why): "Not ready: \(why)"
        }
    }
}

struct ReadinessSnapshot: Equatable, Sendable {
    var items: [ReadinessItem]
    var at: Date
    func items(in c: ReadinessCategory) -> [ReadinessItem] { items.filter { $0.category == c } }
    func item(_ id: String) -> ReadinessItem? { items.first { $0.id == id } }
    var attention: [ReadinessItem] { items.filter { $0.state.needsAttention } }

    var summary: ReadinessSummary {
        if let broken = items.first(where: { $0.required && $0.state.needsAttention }) { return .notReady(broken.name.lowercased()) }
        let providers = items.filter { $0.id.hasPrefix("provider.") || $0.id == "local.qwen" }
        let canThink = providers.contains { $0.state == .ready }
        let gaps = attention.count + (canThink ? 0 : 1)
        return gaps == 0 ? .ready : .usable(gaps: gaps)
    }
}
