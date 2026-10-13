import Foundation
import CoreGraphics

// MARK: - V0.11 General Computer Use — vocabulary
//
// Computer Use is NOT a new authority system (DEC-127). It is the lowest rung of a capability ladder: a goal reaches it only when no stronger,
// structured mechanism exists. Everything it does is a typed `ComputerAction`, planned in short batches, policy-checked, performed through
// OBSERVE → RESOLVE → CHECK POLICY → ACT → OBSERVE → VERIFY, audited, cancelable — inside an ordinary V0.4 task.

/// The ladder, strongest first. A higher rung is ALWAYS used when it can do the job (`CapabilityResolver`).
enum ComputerMechanism: Int, Codable, CaseIterable, Comparable, Sendable {
    case typedCapability = 1      // A  a domain-specific JARVIS capability (V0.4 file/coding tools, V0.6 Unity bridge, Git tool)
    case structuredIntegration    // B  an existing API / structured integration
    case controlledCLI            // C  an approved executable through ManagedProcess (V0.4 command profiles)
    case browserDOM               // D  the V0.9 browser / research capability
    case accessibility            // E  macOS Accessibility (AXUIElement) and NSWorkspace
    case vision                   // F  window-scoped screenshot + semantic targeting (validated by JARVIS)
    case rawCoordinates           // G  a window-relative point, only after vision validated a fresh observation

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    var letter: String { ["A", "B", "C", "D", "E", "F", "G"][rawValue - 1] }
    var label: String {
        switch self {
        case .typedCapability: "typed JARVIS capability"; case .structuredIntegration: "structured integration"; case .controlledCLI: "controlled command"
        case .browserDOM: "browser DOM (V0.9)"; case .accessibility: "Accessibility"; case .vision: "window-scoped vision"; case .rawCoordinates: "window-relative coordinates"
        }
    }
    /// Can Computer Use itself execute this rung? A–D belong to other layers: the resolver hands the goal to them instead.
    var isComputerUse: Bool { self >= .accessibility }
}

struct AppRef: Codable, Equatable, Hashable, Sendable {
    var bundleID: String?
    var name: String?
    init(bundleID: String? = nil, name: String? = nil) { self.bundleID = bundleID; self.name = name }
    var display: String { name ?? bundleID ?? "?" }
}

// MARK: Actions

/// Every action Computer Use can perform. There is deliberately NO "run command", "run script", "evaluate", "click at x,y from a model".
enum ComputerActionKind: String, Codable, CaseIterable, Sendable {
    case observe, launchApplication, activateApplication, quitApplication
    case focusWindow, minimizeWindow, restoreWindow, closeWindow
    case pressElement, selectMenuItem, setText, typeText, pressKey, pressShortcut, scroll
    case openFile, revealFile, openSettingsPane
    case captureWindow, visionPress

    var isReadOnly: Bool { self == .observe || self == .captureWindow }
    var needsTargetElement: Bool { [.pressElement, .setText, .scroll, .visionPress].contains(self) }
    var sendsKeystrokes: Bool { [.typeText, .pressKey, .pressShortcut].contains(self) }
    var label: String {
        switch self {
        case .observe: "Observe"; case .launchApplication: "Launch"; case .activateApplication: "Activate"; case .quitApplication: "Quit"
        case .focusWindow: "Focus window"; case .minimizeWindow: "Minimize"; case .restoreWindow: "Restore"; case .closeWindow: "Close window"
        case .pressElement: "Press"; case .selectMenuItem: "Menu"; case .setText: "Set text"; case .typeText: "Type"; case .pressKey: "Key"; case .pressShortcut: "Shortcut"
        case .scroll: "Scroll"; case .openFile: "Open file"; case .revealFile: "Reveal file"; case .openSettingsPane: "Open Settings pane"
        case .captureWindow: "Capture window"; case .visionPress: "Vision press"
        }
    }
}

enum ChordModifier: String, Codable, CaseIterable, Hashable, Sendable { case command, shift, option, control }

struct KeyChord: Codable, Hashable, Sendable {
    var key: String                   // "s", "f", "return", "escape", "tab", "up", "down", "left", "right", "space", "comma", "1"…
    var modifiers: Set<ChordModifier>
    init(_ key: String, _ modifiers: Set<ChordModifier> = []) { self.key = key.lowercased(); self.modifiers = modifiers }
    var display: String {
        let m = (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "") + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "")
        return m + key.uppercased()
    }
}

enum ScrollDirection: String, Codable, Sendable { case up, down, left, right }
struct ScrollSpec: Codable, Equatable, Sendable {
    var direction: ScrollDirection = .down
    /// How many steps (each one page of the scroll area) at most. Bounded by `ComputerLimits.maxScrollAttempts`.
    var maxAttempts = 4
}

enum SettingsPane: String, Codable, CaseIterable, Sendable {
    case accessibility, screenRecording, microphone, general, displays, privacy
    var titleHint: String {
        switch self { case .accessibility: "Accessibility"; case .screenRecording: "Screen"; case .microphone: "Microphone"; case .general: "General"; case .displays: "Displays"; case .privacy: "Privacy" }
    }
}

/// A semantic description of what to act on. Never coordinates: they are derived late, from a fresh observation, by the action layer.
struct ActionTarget: Codable, Equatable, Sendable {
    var app = AppRef()
    var windowTitle: String?            // "contains" match, folded
    var role: String?                   // button, textField, menuItem, tab, checkbox, sidebarItem, scrollArea, window…
    var title: String?                  // visible label (folded, exact or contained, never regex)
    var identifier: String?
    var menuPath: [String] = []         // ["File", "Save"]
    var within: String?                 // an ancestor's title — the context that separates two identical labels ("Sidebar")
    /// Set ONLY from the user's own words ("the second one"); never from a model.
    var occurrence: Int?
    var description: String {
        if !menuPath.isEmpty { return menuPath.joined(separator: " → ") }
        return [role, title.map { "“\($0)”" }, within.map { "in \($0)" }].compactMap { $0 }.joined(separator: " ")
    }
}

/// Observable postconditions. "The event was dispatched" is never success.
enum Check: Codable, Equatable, Sendable {
    case appRunning(bundleID: String)
    case appFrontmost(bundleID: String)
    case windowExists(bundleID: String, titleContains: String)
    case windowGone(bundleID: String, titleContains: String)
    case elementExists(bundleID: String, role: String?, title: String)
    case elementValue(bundleID: String, role: String?, title: String?, equals: String)
    case elementSelected(bundleID: String, role: String?, title: String)
    case stateChanged
    /// A window that was not there before the action (a Settings window, a panel, a sheet).
    case newWindow(bundleID: String)
    case finderShows(name: String)
    case settingsPane(titleContains: String)

    var summary: String {
        switch self {
        case .appRunning(let b): "\(b) is running"; case .appFrontmost(let b): "\(b) is frontmost"
        case .windowExists(_, let t): "a window titled “\(t)” exists"; case .windowGone(_, let t): "the window “\(t)” is gone"
        case .elementExists(_, let r, let t): "\(r ?? "element") “\(t)” exists"; case .elementValue(_, _, let t, let v): "\(t.map { "“\($0)” " } ?? "the field ")has the expected value (\(v.count) chars)"
        case .elementSelected(_, _, let t): "“\(t)” is selected"; case .stateChanged: "the UI state changed"; case .newWindow: "a new window appeared"
        case .finderShows(let n): "Finder shows “\(n)”"; case .settingsPane(let t): "System Settings shows “\(t)”"
        }
    }
}

struct ComputerAction: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var kind: ComputerActionKind
    var target = ActionTarget()
    /// setText / typeText content. Never logged; recorded as classification + length only.
    var text: String?
    var chord: KeyChord?
    var scroll: ScrollSpec?
    var path: String?
    var pane: SettingsPane?
    var checks: [Check] = []
    /// Short phrase for the timeline / Compact HUD ("Opening Xcode"). Never model prose that could carry instructions.
    var summary: String
    /// Where the action came from: the user's own words (deterministic parse) or a model's proposal. A model-proposed medium action asks first.
    var origin: ActionOrigin = .userWords

    enum CodingKeys: String, CodingKey { case id, kind, target, text, chord, scroll, path, pane, checks, summary, origin }
}

enum ActionOrigin: String, Codable, Sendable { case userWords, modelProposal }

/// A short batch of actions (V0.11 plans 1–5 actions, observes, then re-plans). `adaptiveGoal` lets a bounded planner continue after observing.
struct ComputerStepParams: Codable, Equatable, Sendable {
    var actions: [ComputerAction] = []
    var adaptiveGoal: String?
    var maxRounds = 3
}

enum ComputerLimits {
    static let maxActionsPerBatch = 5
    static let maxRounds = 4
    static let maxScrollAttempts = 8
    static let maxRetries = 2
    static let maxTextLength = 2_000
    static let maxTreeNodes = 250
    static let maxTreeDepth = 9
    static let treeTimeBudget: TimeInterval = 1.5
    static let launchTimeout: TimeInterval = 20
    static let windowTimeout: TimeInterval = 6
    static let verifyTimeout: TimeInterval = 4
    static let axResponseTimeout: TimeInterval = 1.5
    static let visionTimeout: TimeInterval = 20
    /// A screenshot older than this can never justify a click.
    static let maxObservationAge: TimeInterval = 6
}

// MARK: - Snapshots (what Computer Use SEES — session observations, never durable memory)

struct DisplayInfo: Equatable, Sendable {
    var id: UInt32
    /// AppKit coordinates (origin bottom-left of the primary display, y up).
    var frame: CGRect
    /// AppKit coordinates without the menu bar and the Dock.
    var visibleFrame: CGRect
    var scale: CGFloat
    var isPrimary: Bool
}

struct ApplicationSnapshot: Equatable, Sendable {
    var pid: Int32
    var bundleID: String?
    var name: String
    var isActive: Bool
    var isHidden: Bool
    var isFinishedLaunching = true
    var ref: AppRef { AppRef(bundleID: bundleID, name: name) }
}

struct WindowSnapshot: Equatable, Sendable {
    var index: Int                     // position in the application's AX window list at observation time
    var title: String
    var role: String                   // AXWindow / AXSheet / AXDialog…
    var subrole: String?
    var frame: CGRect                  // global points, top-left origin
    var isMain: Bool
    var isFocused: Bool
    var isMinimized: Bool
    var isModal: Bool
    var isSheet: Bool
    var cgWindowID: UInt32?
    var identifier: String?
    /// Title of the button Return would press (dialogs).
    var defaultButton: String?
}

struct UIElementSnapshot: Equatable, Sendable, Identifiable {
    var id: Int                         // index within its snapshot
    var role: String
    var subrole: String?
    var title: String
    var help: String
    var value: String?                  // bounded; nil for secure fields and long documents
    var valueLength: Int?
    var enabled: Bool
    var focused: Bool
    var selected: Bool
    var identifier: String?
    var actions: [String]
    var frame: CGRect?
    var parent: Int?
    var depth: Int
    var childCount: Int
    var isSecure: Bool
    /// Titles of the ancestors, nearest first (context for disambiguation; bounded).
    var ancestorTitles: [String] = []
    var handle: ElementHandle
    /// The element is inside a sheet/dialog.
    var inModal = false
}

struct ElementHandle: Hashable, Sendable {
    var pid: Int32
    var generation: Int
    var index: Int
}

struct AXSnapshot: Sendable {
    var app: ApplicationSnapshot
    var windows: [WindowSnapshot]
    var windowIndex: Int?              // which window the elements belong to
    var elements: [UIElementSnapshot]
    var generation: Int
    var truncated: Bool
    var capturedAt: Date
    var durationMS: Double
    var focusedElement: Int?
    var hasModal: Bool { windows.contains { $0.isModal || $0.isSheet } }
    var window: WindowSnapshot? { windowIndex.flatMap { i in windows.first { $0.index == i } } }
    var nodeCount: Int { elements.count }

    /// A cheap fingerprint of what is visible (labels/values/focus), for "did anything change?" checks. Contains no text.
    var stateHash: Int { hash(includeFrames: false) }
    /// With frames: also notices content that MOVED (scrolling) without any label changing.
    func hash(includeFrames: Bool) -> Int {
        var h = Hasher()
        h.combine(windows.count)
        for w in windows { h.combine(w.title); h.combine(w.isFocused); h.combine(w.isMinimized); h.combine(Int(w.frame.origin.x)); h.combine(Int(w.frame.origin.y)) }
        for e in elements {
            h.combine(e.role); h.combine(e.title); h.combine(e.value); h.combine(e.selected); h.combine(e.enabled); h.combine(e.focused)
            if includeFrames, let f = e.frame { h.combine(Int(f.minX)); h.combine(Int(f.minY)) }
        }
        return h.finalize()
    }
}

struct MenuItemSnapshot: Equatable, Sendable {
    var title: String
    var enabled: Bool
    var hasSubmenu: Bool
    var isSeparator: Bool
    var checked: Bool
}

// MARK: - Resolution, results

/// Interpretable states — no fake probabilities (spec §20).
enum ResolutionState: String, Codable, Sendable {
    case exact, strong, ambiguous, notFound, stale
    var isActionable: Bool { self == .exact || self == .strong }
    var label: String { rawValue.uppercased().replacingOccurrences(of: "NOTFOUND", with: "NOT_FOUND") }
}

struct TargetResolution: Sendable {
    var state: ResolutionState
    var element: UIElementSnapshot?
    var candidates: [UIElementSnapshot]
    var reason: String
}

enum ActionStatus: String, Codable, Sendable {
    case verified                 // acted and the postcondition holds (or already held)
    case notVerified              // acted but the expected state was not observed in time
    case blocked                  // policy: this action has no code path / needs authority that does not exist
    case approvalDenied
    case permissionRequired
    case ambiguous
    case notFound
    case stale
    case timedOut
    case cancelled
    case appUnresponsive
    case modalPresent
    case userInterference
    case failed

    var isSuccess: Bool { self == .verified }
    var failureCategory: FailureCategory {
        switch self {
        case .verified: .toolFailed
        case .blocked: .securityBlocked
        case .approvalDenied: .approvalDenied
        case .permissionRequired: .permissionRequired
        case .ambiguous: .ambiguousTarget
        case .notFound, .stale, .notVerified, .modalPresent, .userInterference, .failed: .computerActionFailed
        case .timedOut, .appUnresponsive: .computerTimeout
        case .cancelled: .cancelled
        }
    }
}

struct VerificationResult: Codable, Equatable, Sendable {
    var passed: Bool
    var checks: [String]               // human summaries of what was checked
    var detail: String
}

struct ActionResult: Sendable {
    var action: ComputerAction
    var status: ActionStatus
    var mechanism: ComputerMechanism
    var risk: RiskClass
    var resolution: ResolutionState?
    var verification: VerificationResult?
    var detail: String
    var attempts: Int
    var durationMS: Double
    var approvalID: UUID?
    var app: String?
    var window: String?
    var targetDescription: String
    var textClass: TextClass?
    var textLength: Int?
    /// Why a blocked/failed action failed, when a more specific reason than the status implies is known (secure field → interaction required).
    var category: FailureCategory? = nil
}

// MARK: - Events (bounded; never AX dumps or text)

enum ComputerEvent: Sendable {
    case sessionStarted(goal: String)
    case permissionMissing(String)
    case appResolved(String, running: Bool)
    case windowResolved(String)
    case observed(app: String, windows: Int, nodes: Int, truncated: Bool)
    case targetResolved(String, ResolutionState)
    case actionProposed(String)
    case actionExecuted(String, ComputerMechanism)
    case verificationPassed(String)
    case verificationFailed(String)
    case visionFallback(String)
    case approvalRequired(String)
    case blocked(String)
    case userInterference(String)
    case sessionCancelled(String)
    case sessionCompleted(String)

    var summary: String {
        switch self {
        case .sessionStarted(let g): "Computer session started · \(g.prefix(80))"
        case .permissionMissing(let p): "Permission required · \(p)"
        case .appResolved(let a, let r): "Resolved \(a) · \(r ? "running" : "not running")"
        case .windowResolved(let w): "Window · \(w)"
        case .observed(let a, let w, let n, let t): "Observed \(a) · \(w) window\(w == 1 ? "" : "s") · \(n) element\(n == 1 ? "" : "s")\(t ? " (bounded)" : "")"
        case .targetResolved(let t, let s): "Resolved \(t) · \(s.label)"
        case .actionProposed(let a): "Proposed · \(a)"
        case .actionExecuted(let a, let m): "\(a) · via \(m.label)"
        case .verificationPassed(let a): "Verified · \(a)"
        case .verificationFailed(let a): "Not verified · \(a)"
        case .visionFallback(let r): "Vision fallback · \(r)"
        case .approvalRequired(let a): "Approval required · \(a)"
        case .blocked(let r): "Blocked · \(r)"
        case .userInterference(let r): "Paused for you · \(r)"
        case .sessionCancelled(let r): "Computer session stopped · \(r)"
        case .sessionCompleted(let r): "Computer session finished · \(r)"
        }
    }
    var isWarning: Bool {
        switch self { case .permissionMissing, .verificationFailed, .blocked, .userInterference, .sessionCancelled, .approvalRequired: true; default: false }
    }
}

// MARK: - Text classification

enum TextClass: String, Codable, Sendable {
    case plain, url, pathLike, sensitive, commandLike
}

/// A user-visible permission state. `unknown` is never shown as granted.
enum PermissionState: String, Codable, Sendable { case granted, missing }

struct ComputerPermissions: Equatable, Sendable {
    var accessibility: PermissionState
    var screenRecording: PermissionState
}
