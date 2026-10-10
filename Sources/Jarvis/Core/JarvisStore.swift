import Foundation
import Observation

/// Application state: *what JARVIS is doing*. Deliberately free of any window/view
/// concerns (see `HUDState` for those) so it can outlive every window and later be
/// driven by background workers.
@MainActor
@Observable
final class JarvisStore {
    /// How long `.completed` is shown before JARVIS settles back to `.idle`.
    static let completedDisplayDuration: TimeInterval = 6
    static let activityCapacity = 200

    private(set) var state: JarvisState = .idle
    private(set) var stateEnteredAt: Date = .now

    private(set) var tasks: [JarvisTask] = []
    private(set) var activity: [ActivityEvent] = []
    private(set) var pendingApproval: ApprovalRequest?

    // Display-only context for the Full HUD (demo-seeded in V0.1).
    private(set) var project: ProjectSummary?
    private(set) var agents: [AgentSlot] = []
    private(set) var tools: [ToolSlot] = []

    @ObservationIgnored private var returnToIdleTask: Task<Void, Never>?

    init() {}

    // MARK: Seeding (used by Services/Demo; later by persistence)

    func load(tasks: [JarvisTask], activity: [ActivityEvent], project: ProjectSummary?, agents: [AgentSlot], tools: [ToolSlot]) {
        self.tasks = tasks
        self.activity = activity
        self.project = project
        self.agents = agents
        self.tools = tools
    }

    func replaceTasks(_ tasks: [JarvisTask]) {
        self.tasks = tasks
    }

    // MARK: Derived

    /// First task the user can still control (running / paused / awaiting approval).
    var activeTask: JarvisTask? { tasks.first { $0.status.isActive } }

    // MARK: State

    func setState(_ newState: JarvisState) {
        returnToIdleTask?.cancel()
        returnToIdleTask = nil
        guard newState != state else { return }
        state = newState
        stateEnteredAt = .now
        if newState == .completed { scheduleReturnToIdle() }
    }

    private func scheduleReturnToIdle() {
        returnToIdleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.completedDisplayDuration))
            guard !Task.isCancelled, let self, self.state == .completed else { return }
            self.setState(.idle)
        }
    }

    // MARK: Activity

    func log(_ message: String, kind: ActivityKind = .info) {
        activity.append(ActivityEvent(timestamp: .now, message: message, kind: kind))
        if activity.count > Self.activityCapacity {
            activity.removeFirst(activity.count - Self.activityCapacity)
        }
    }

    // MARK: Task controls (demo-level in V0.1)

    private func mutateActiveTask(_ body: (inout JarvisTask) -> Void) {
        guard let idx = tasks.firstIndex(where: { $0.status.isActive }) else { return }
        body(&tasks[idx])
    }

    func pauseActiveTask() {
        guard let task = activeTask, task.status == .running else { return }
        mutateActiveTask { $0.pause() }
        if state == .working { setState(.idle) }
        log("Paused: \(task.title)", kind: .warning)
    }

    func resumeActiveTask() {
        guard let task = activeTask, task.status == .paused else { return }
        mutateActiveTask { $0.resume() }
        setState(.working)
        log("Resumed: \(task.title)", kind: .info)
    }

    func stopActiveTask() {
        guard let task = activeTask else { return }
        mutateActiveTask { $0.cancel() }
        pendingApproval = nil
        if state != .error { setState(.idle) }
        log("Stopped: \(task.title)", kind: .warning)
    }

    func completeActiveTask() {
        guard let task = activeTask else { return }
        pendingApproval = nil
        mutateActiveTask { $0.complete() }
        log("Completed: \(task.title)", kind: .success)
    }

    func failActiveTask() {
        guard let task = activeTask else { return }
        pendingApproval = nil
        mutateActiveTask { $0.fail() }
        log("Failed: \(task.title)", kind: .error)
    }

    // MARK: Approval

    func requestApproval(_ request: ApprovalRequest) {
        pendingApproval = request
        mutateActiveTask {
            if $0.status == .paused { $0.resume() }
            $0.awaitApproval()
        }
        setState(.waitingForApproval)
        log("Approval requested: \(request.title)", kind: .warning)
    }

    func resolveApproval(approved: Bool) {
        guard let request = pendingApproval else { return }
        pendingApproval = nil
        if approved {
            mutateActiveTask { $0.resume() }
            setState(.working)
            log("Approved: \(request.title)", kind: .success)
        } else {
            mutateActiveTask { $0.cancel() }
            setState(.idle)
            log("Denied: \(request.title)", kind: .warning)
        }
    }

    /// Drops an outstanding approval request without a decision (e.g. the dev tools leaving the
    /// approval state) and returns a task that was blocked on it to running, so nothing is left stranded.
    func clearPendingApproval() {
        pendingApproval = nil
        mutateActiveTask { if $0.status == .waiting { $0.resume() } }
    }
}
