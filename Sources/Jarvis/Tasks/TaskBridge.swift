import Foundation

extension JarvisTask {
    /// Read-only projection of an engine task for the existing HUD surfaces (Compact card, Dashboard, Tasks, center stage).
    /// Progress is derived by the existing `JarvisTask` rules from the step list: skipped steps are not measurable work and are left out.
    init(view v: TaskView, activeAgents: Int, agentLine: (active: String, waiting: String?)? = nil, operatorLine: String? = nil) {
        let steps = v.steps.filter { $0.state != .skipped }.map { s -> TaskStep in
            let status: StepStatus
            switch s.state {
            case .passed: status = .completed
            case .failed: status = .failed
            case .running, .verifying, .waitingForApproval: status = .active
            default: status = .pending
            }
            return TaskStep(id: s.id, title: s.title, status: status)
        }
        let status: TaskStatus
        switch v.task.state {
        case .created, .planning, .ready, .running: status = .running
        case .waitingForApproval: status = .waiting
        case .completed: status = .completed
        case .failed: status = .failed
        case .cancelled: status = .cancelled
        case .interrupted: status = .interrupted
        }
        self.init(id: v.task.id, title: v.task.title, details: v.task.goal, status: status, createdAt: v.task.createdAt, startedAt: v.task.startedAt,
                  completedAt: v.task.finishedAt, steps: steps, accumulatedRunTime: v.task.accumulatedSeconds, runningSince: v.runningSince,
                  engine: EngineTaskInfo(progressFraction: v.task.progressFraction, activity: v.task.activity, activeAgents: activeAgents,
                                         failureReason: v.task.failureReason, summary: v.task.summary, stepCount: steps.count, agentLine: agentLine?.active, waitingLine: agentLine?.waiting, operatorLine: operatorLine))
    }
}

/// Couples the task engine to the HUD: projects engine tasks into `JarvisStore` (Compact/Dashboard/Tasks read them there) and keeps
/// the visual state (working / waiting for approval / completed / error) honest. It never changes a task — only the engine does.
@MainActor
final class TaskBridge {
    private let engine: TaskEngine
    private let store: JarvisStore
    private let hub: ExecutionHub
    private var ownsWorking = false
    private var errorReset: Task<Void, Never>?
    private var lastApproval: UUID?

    init(engine: TaskEngine, store: JarvisStore, hub: ExecutionHub) {
        self.engine = engine; self.store = store; self.hub = hub
        store.taskControl = engine
        engine.onChange = { [weak self] in self?.sync() }
        engine.onApprovalChanged = { [weak self] in self?.sync() }
    }

    func sync() {
        let views = engine.orderedViews.prefix(40)
        let active = hub.activeRuns
        store.setEngineTasks(views.map { v in
            JarvisTask(view: v, activeAgents: active.filter { $0.taskID == v.id }.count, agentLine: engine.compactAgentLine(v), operatorLine: engine.compactOperatorLine(v))
        })
        // HUD state: only changes the engine itself caused.
        let live = engine.activeViews
        let waiting = live.first { $0.task.state == .waitingForApproval }
        if let w = waiting, let a = w.pendingApproval {
            if lastApproval != a.id {
                lastApproval = a.id
                store.setEngineApproval(ApprovalRequest(id: a.id, title: a.action, detail: a.reason), id: a.id)
            }
            if store.state != .waitingForApproval { store.setState(.waitingForApproval) }
            ownsWorking = true
        } else {
            if lastApproval != nil { lastApproval = nil; store.setEngineApproval(nil, id: nil) }
            let running = live.contains { [.planning, .ready, .running].contains($0.task.state) }
            if running {
                if [.idle, .completed, .error, .waitingForApproval].contains(store.state) { store.setState(.working) }
                ownsWorking = true
            } else if ownsWorking {
                ownsWorking = false
                if store.state == .working || store.state == .waitingForApproval { store.setState(.idle) }
            }
        }
    }

    /// A task finished: the visual state reflects it for a moment (completed → idle by the store; error → idle after a while).
    func finished(_ v: TaskView) {
        sync()
        switch v.task.state {
        case .completed: store.setState(.completed)
        case .failed:
            store.setState(.error)
            errorReset?.cancel()
            errorReset = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, let self, self.store.state == .error else { return }
                self.store.setState(.idle)
            }
        default: break
        }
    }
}
