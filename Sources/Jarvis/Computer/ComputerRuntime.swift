import Foundation
import AppKit
import Observation

// MARK: - The Computer Use runtime: permissions, the backend, vision gating, the session timeline and the emergency stop
//
// It decides nothing about authority (the task engine and `ComputerPolicy` do). It starts nothing on its own and runs NO timer while idle: the emergency-stop
// sampler exists only while at least one computer session is running.

/// ⌃⌥⌘ held together stops every Computer Use action at once. Modifier flags are read without any macOS permission (like the HUD chords), and only while a session runs.
@MainActor
final class EmergencyStopWatcher {
    struct Sample: Equatable { var control: Bool; var option: Bool; var command: Bool }
    typealias Sampler = @MainActor () -> Sample

    static let interval: TimeInterval = 0.04
    /// Consecutive samples with all three modifiers down before it fires (≈ 80 ms: long enough to ignore a glitch, short enough to feel immediate).
    static let confirmSamples = 2
    static let chordDescription = "⌃⌥⌘ — hold Control, Option and Command together"

    var sampler: Sampler = { EmergencyStopWatcher.systemSample() }
    var onTrigger: () -> Void = {}
    private var timer: Timer?
    private var consecutive = 0
    private var armed = true
    private(set) var triggerCount = 0
    var isRunning: Bool { timer != nil }

    static func systemSample() -> Sample {
        let f = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return Sample(control: f.contains(.control), option: f.contains(.option), command: f.contains(.command))
    }

    func start() {
        guard timer == nil else { return }
        consecutive = 0; armed = true
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        t.tolerance = 0.01
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    func stop() { timer?.invalidate(); timer = nil; consecutive = 0 }

    /// One sampling step (tests call it directly with a scripted sampler).
    func poll() {
        let s = sampler()
        if s.control && s.option && s.command {
            consecutive += 1
            if consecutive >= Self.confirmSamples, armed { armed = false; triggerCount += 1; onTrigger() }
        } else {
            consecutive = 0
            if !s.control && !s.option && !s.command { armed = true }               // released: ready again
        }
    }
}

struct ComputerTimelineEntry: Identifiable, Equatable, Sendable {
    var id = UUID()
    var at = Date()
    var text: String
    var warning: Bool
}

/// Live bookkeeping of one computer task (in memory; the durable facts are the session rows, the step evidence and the report).
@MainActor
final class ComputerTaskState {
    let taskID: UUID
    let token = ComputerStopToken()
    var executor: ComputerExecutor?
    var session: ComputerSessionRecord
    var seq = 0
    var results: [ActionResult] = []
    var pendingSteps: [GoalStep] = []
    var capability: CapabilityChoice?
    var memoryPacket: String?
    var memoryIDs: [UUID] = []
    var memoryRecorded = false
    var fallbacks: [String] = []
    var rounds = 0
    var started = false
    var resumed = false
    var adaptiveGoal: String?
    init(taskID: UUID, goal: String, origin: TaskOrigin) {
        self.taskID = taskID
        session = ComputerSessionRecord(id: taskID, taskID: taskID, goal: goal, status: .running, targetApps: [], planSummary: nil, capability: nil, visionEnabled: false, startedAt: Date(), finishedAt: nil,
                                        failure: nil, resumeCount: 0, memoryIDs: [], origin: origin.rawValue)
    }
}

@MainActor
@Observable
final class ComputerRuntime {
    @ObservationIgnored let backend: UIBackend
    @ObservationIgnored var vision: VisionProposing
    @ObservationIgnored let repository: JarvisRepository?
    /// The empty workspace computer tasks anchor on (JARVIS' own folder; nothing can be read or written through it).
    let workspacePath: String
    @ObservationIgnored var quarantineRoot: String?
    @ObservationIgnored var enabled: () -> Bool = { true }
    @ObservationIgnored var visionEnabled: () -> Bool = { false }
    @ObservationIgnored var pressureNormal: () -> Bool = { true }
    @ObservationIgnored var activity: UserActivityProbe = SystemActivityProbe()
    @ObservationIgnored var onEvent: ((UUID?, ComputerEvent) -> Void)?
    @ObservationIgnored var onEmergencyStop: (() -> Void)?
    /// Test hook: adjusts every executor this runtime makes (timeouts, pauses). Product code never sets it.
    @ObservationIgnored var tuneExecutor: ((ComputerExecutor) -> Void)?
    @ObservationIgnored let watcher = EmergencyStopWatcher()
    @ObservationIgnored private var tokens: [UUID: ComputerStopToken] = [:]

    private(set) var permissions: ComputerPermissions
    private(set) var revision = 0
    private(set) var timeline: [ComputerTimelineEntry] = []
    private(set) var currentTaskID: UUID?
    private(set) var currentApp: String?
    private(set) var currentActivity: String?
    private(set) var lastObservation: String?
    private(set) var lastActionLine: String?
    private(set) var lastVerification: String?
    private(set) var lastCapability: String?
    private(set) var visionSuspended = false
    private(set) var lastEmergencyStop: Date?
    private(set) var emergencyStopCount = 0
    var isStubbed = false

    var activeSessions: Int { tokens.count }
    var isActive: Bool { !tokens.isEmpty }

    init(backend: UIBackend, repository: JarvisRepository?, workspacePath: String, vision: VisionProposing = AppleVisionOCR()) {
        self.backend = backend; self.repository = repository; self.workspacePath = workspacePath; self.vision = vision
        permissions = ComputerPermissions(accessibility: backend.accessibilityTrusted() ? .granted : .missing, screenRecording: backend.screenCaptureAllowed() ? .granted : .missing)
        watcher.onTrigger = { [weak self] in self?.emergencyStop(reason: "emergency shortcut (⌃⌥⌘)") }
    }

    // MARK: Permissions (truthful; refreshed when asked, never polled)

    @discardableResult
    func refreshPermissions() -> ComputerPermissions {
        let p = ComputerPermissions(accessibility: backend.accessibilityTrusted() ? .granted : .missing, screenRecording: backend.screenCaptureAllowed() ? .granted : .missing)
        if p != permissions { permissions = p; revision &+= 1 }
        return p
    }

    /// Explicit user actions only (buttons in Settings). JARVIS can ask macOS to show ITS prompt and open the right pane; only the user can grant.
    func guideToAccessibility() {
        if backend is AXBackend { AXBackend.promptForAccessibility() }
        Task { try? await backend.openSettingsPane(.accessibility) }
    }
    func guideToScreenCapture() {
        if backend is AXBackend { AXBackend.promptForScreenRecording() }
        Task { try? await backend.openSettingsPane(.screenRecording) }
    }

    /// The vision fallback is usable when the user turned it on AND memory pressure allows (under pressure JARVIS prefers AX-only; correctness never depends on vision).
    func visionAllowed() -> Bool {
        if visionSuspended, pressureNormal() { visionSuspended = false }
        return enabled() && visionEnabled() && !visionSuspended && pressureNormal()
    }

    func onMemoryPressure() { visionSuspended = true; revision &+= 1 }
    func onPressureCleared() { visionSuspended = false; revision &+= 1 }

    // MARK: Executors

    func makeExecutor(token: ComputerStopToken, taskID: UUID) -> ComputerExecutor {
        let ex = ComputerExecutor(backend: backend, vision: vision)
        ex.stop = token
        ex.activity = activity
        ex.quarantineRoot = quarantineRoot
        ex.visionAllowed = { [weak self] in self?.visionAllowed() ?? false }
        ex.events = { [weak self] e in self?.record(e, taskID: taskID) }
        tuneExecutor?(ex)
        return ex
    }

    // MARK: Sessions

    func sessionStarted(taskID: UUID, goal: String, token: ComputerStopToken) {
        tokens[taskID] = token
        currentTaskID = taskID
        timeline.removeAll()
        lastObservation = nil; lastActionLine = nil; lastVerification = nil; lastCapability = nil; currentApp = nil
        if !isStubbed, !watcher.isRunning { watcher.start() }
        record(.sessionStarted(goal: goal), taskID: taskID)
        revision &+= 1
    }

    func sessionEnded(taskID: UUID, summary: String, cancelled: Bool) {
        tokens[taskID] = nil
        if tokens.isEmpty { watcher.stop() }                                       // nothing samples while idle
        record(cancelled ? .sessionCancelled(summary) : .sessionCompleted(summary), taskID: taskID)
        currentActivity = nil
        revision &+= 1
    }

    /// Every computer action stops NOW: tokens are set first (so an in-flight executor sends nothing more), then the engine cancels the tasks.
    func emergencyStop(reason: String) {
        let t0 = Date()
        for token in tokens.values { token.stop(reason) }
        lastEmergencyStop = t0; emergencyStopCount += 1
        record(.sessionCancelled("emergency stop — \(reason)"), taskID: currentTaskID)
        onEmergencyStop?()
        revision &+= 1
    }

    func stopAll(reason: String) { for token in tokens.values { token.stop(reason) } }

    func shutdown() { stopAll(reason: "JARVIS is quitting"); tokens.removeAll(); watcher.stop() }

    // MARK: Events → timeline (bounded; labels and counts only)

    func record(_ e: ComputerEvent, taskID: UUID?) {
        let line = OutputSanitizer.sanitize(e.summary)
        // verification polls observe repeatedly: identical consecutive lines are collapsed so the timeline and the activity feed stay readable and bounded
        if case .observed = e, timeline.last?.text == line { return }
        timeline.append(ComputerTimelineEntry(text: line, warning: e.isWarning))
        if timeline.count > 120 { timeline.removeFirst(timeline.count - 120) }
        switch e {
        case .observed(let app, _, _, _): currentApp = app; lastObservation = line
        case .appResolved(let app, _): currentApp = app
        case .actionExecuted(let a, let m): lastActionLine = a; lastCapability = "Used \(m.label)"
        case .verificationPassed(let a): lastVerification = "Verified · \(a)"
        case .verificationFailed(let a): lastVerification = "Not verified · \(a)"
        case .visionFallback: lastCapability = "Vision fallback (window-scoped)"
        case .actionProposed(let a): currentActivity = a
        default: break
        }
        onEvent?(taskID, e)
        revision &+= 1
    }
}

/// Automated and capture runs: no real UI is ever reachable (no permission, nothing running).
final class DisabledUIBackend: UIBackend, @unchecked Sendable {
    func accessibilityTrusted() -> Bool { false }
    func screenCaptureAllowed() -> Bool { false }
    func runningApplications() async -> [ApplicationSnapshot] { [] }
    func frontmostApplication() async -> ApplicationSnapshot? { nil }
    func installedBundleID(for ref: AppRef) async -> String? { nil }
    func launchApplication(bundleID: String) async throws -> Int32 { throw BackendError.permissionDenied }
    func activateApplication(pid: Int32) async -> Bool { false }
    func quitApplication(pid: Int32) async -> Bool { false }
    func isResponsive(pid: Int32) async -> Bool { false }
    func windows(pid: Int32) async -> [WindowSnapshot] { [] }
    func windowOperation(_ op: WindowOp, pid: Int32, windowIndex: Int) async throws { throw BackendError.permissionDenied }
    func snapshot(pid: Int32, scope: SnapshotScope, budget: AXBudget) async throws -> AXSnapshot { throw BackendError.permissionDenied }
    func menuBarTitles(pid: Int32) async throws -> [String] { throw BackendError.permissionDenied }
    func menuItems(pid: Int32, path: [String]) async throws -> [MenuItemSnapshot] { throw BackendError.permissionDenied }
    func pressMenuPath(pid: Int32, path: [String]) async throws { throw BackendError.permissionDenied }
    func readValue(_ h: ElementHandle) async throws -> String? { throw BackendError.permissionDenied }
    func perform(_ op: ElementOp, on h: ElementHandle) async throws { throw BackendError.permissionDenied }
    func setValue(_ text: String, on h: ElementHandle) async throws { throw BackendError.permissionDenied }
    func postKey(_ chord: KeyChord, toPID pid: Int32) async throws { throw BackendError.permissionDenied }
    func typeText(_ text: String, toPID pid: Int32, shouldContinue: @escaping @Sendable () -> Bool) async throws { throw BackendError.permissionDenied }
    func postScroll(direction: ScrollDirection, lines: Int, atGlobal p: CGPoint, toPID pid: Int32) async throws { throw BackendError.permissionDenied }
    func postClick(atGlobal p: CGPoint) async throws { throw BackendError.permissionDenied }
    func topWindowID(atGlobal p: CGPoint) async -> UInt32? { nil }
    func scrollBy(_ h: ElementHandle, direction: ScrollDirection, step: Double) async throws -> Double { throw BackendError.permissionDenied }
    func openFile(path: String, withBundleID bundleID: String?) async throws { throw BackendError.permissionDenied }
    func revealInFinder(path: String) async throws { throw BackendError.permissionDenied }
    func openSettingsPane(_ pane: SettingsPane) async throws { throw BackendError.permissionDenied }
    func displays() -> DisplayLayout { DisplayLayout(displays: []) }
    func captureWindow(cgWindowID: UInt32, windowFrame: CGRect) async throws -> CapturedWindow { throw BackendError.captureUnavailable("stubbed run") }
}
