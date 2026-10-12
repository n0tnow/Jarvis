import Foundation
import Observation

/// What the UI observes (a value snapshot; the UI never mutates task state).
struct TaskView: Identifiable, Equatable, Sendable {
    var task: TaskRecord
    var steps: [TaskStepRecord]
    var pendingApproval: ApprovalRecord?
    var runningSince: Date?
    var id: UUID { task.id }

    var passedCount: Int { steps.filter { $0.state == .passed }.count }
    var measurableCount: Int { steps.filter { $0.state != .skipped }.count }
    var currentStep: TaskStepRecord? { steps.first { $0.state.isActive || $0.state == .waitingForApproval } ?? steps.first { $0.state == .ready } }

    func elapsed(at now: Date = Date()) -> TimeInterval { task.accumulatedSeconds + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0) }
}

enum TaskSubmitError: Error, Equatable, CustomStringConvertible {
    case workspace(String)
    case empty
    case tooManyActiveTasks(Int)
    case persistenceUnavailable

    var description: String {
        switch self {
        case .workspace(let w): w
        case .empty: "The goal is empty."
        case .tooManyActiveTasks(let n): "JARVIS is already running \(n) task\(n == 1 ? "" : "s"); finish or stop one first."
        case .persistenceUnavailable: "Tasks need the JARVIS database, which is unavailable."
        }
    }
}

struct FileContent: Equatable, Sendable { var text: String? }

/// The autonomous task engine (V0.4): Goal → durable Task → structured Plan → Schedule → Agents/Tools → Validate → Repair/Escalate → Report.
/// It owns orchestration. Routing, supervision, capacity, observation and sanitization stay with the V0.3.x systems it calls.
@MainActor
@Observable
final class TaskEngine {
    struct Limits: Sendable {
        var maxActiveTasks = 2
        var maxConcurrentSteps = 2          // only read-only analysis steps ever run side by side
        var maxCapacityWaits = 40
        var providerTimeout: TimeInterval = 600
    }

    // MARK: Wiring

    let repository: JarvisRepository?
    let artifacts: ArtifactStore?
    let audit: AuditRecorder
    let leases: FileLeaseManager
    var agents: any StepAgentRunner
    /// V0.6: the Unity tool layer (nil = Unity steps fail with `unityUnavailable`). Owns connections, the mutation lock and owned editors.
    var unity: UnityService?
    var limits = Limits()
    /// Called after every persisted change (the store projection / HUD refresh).
    @ObservationIgnored var onChange: (() -> Void)?
    /// Meaningful milestones only (activity feed / log).
    @ObservationIgnored var onEvent: ((String, ActivityKind) -> Void)?
    /// A task reached a terminal state (conversation message, announcement).
    @ObservationIgnored var onFinished: ((TaskView) -> Void)?
    /// Approval requested / resolved (HUD state: awaiting approval).
    @ObservationIgnored var onApprovalChanged: (() -> Void)?
    /// V0.5: review suggestions (model claims) offered to the proactive layer — an event, never an action.
    @ObservationIgnored var onReviewSuggestions: ((TaskRecord, UUID?, UUID?, [ReviewSuggestion]) -> Void)?

    var hub: ExecutionHub? { audit.hub }

    private(set) var views: [UUID: TaskView] = [:]
    private(set) var revision = 0

    @ObservationIgnored var contexts: [UUID: TaskContext] = [:]
    @ObservationIgnored var runners: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var decisions: [UUID: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var activityToken: NSObjectProtocol?

    init(repository: JarvisRepository?, artifacts: ArtifactStore?, audit: AuditRecorder, leases: FileLeaseManager, agents: any StepAgentRunner) {
        self.repository = repository; self.artifacts = artifacts; self.audit = audit; self.leases = leases; self.agents = agents
    }

    // MARK: Per-task in-memory context

    @MainActor
    final class TaskContext {
        var record: TaskRecord
        var steps: [TaskStepRecord]
        let workspace: WorkspaceGuard
        var tools: ProjectTools
        var profiles: ProjectProfiles
        var results: [String: String] = [:]                 // step key → rendered result (analysis) for later steps
        var evidence: [String] = []                         // validation evidence lines (real command results, review verdicts)
        var changes: [TaskFileChange] = []
        var originals: [String: FileContent] = [:]          // path → content BEFORE the task's first change (nil text = did not exist)
        var finals: [String: FileContent] = [:]             // path → latest content written by the task (nil text = deleted)
        var approvedDirty: Set<String> = []
        var candidates: [String: [RoutingCandidate]] = [:]  // step key → engines used, in order
        var lastFailureTail: [String: String] = [:]
        var runningSince: Date?
        var cancelRequested = false
        var hardFailure: (FailureCategory, String)?
        var repairCount = 0, escalationCount = 0
        var capacityWaits = 0
        var waitingRestored = false
        /// Cumulative diff restored from the last checkpoint after a restart (the "before" contents are not kept in memory then).
        var restoredDiff: String?
        /// Code steps whose edits were verified on disk after an interruption: they pass without asking the provider again.
        var recoveredApplied: Set<String> = []
        /// The application is quitting: nothing may be recorded as failed/cancelled because of it.
        var terminating = false
        // V0.6 Unity state (in memory; the durable facts are the step evidence, the checkpoint and the report).
        let unityProject: Bool
        var unityBaseline: UnityConsoleBaseline?
        var unityInstallApproved = false
        var unityUpgradeApproved = false
        var unityApprovedDirty: Set<String> = []
        var unityFacts: [String] = []
        var unityProposed: [String: [UnityEditAction]] = [:]
        var unityProposalRuns: [String: UUID] = [:]

        init(record: TaskRecord, steps: [TaskStepRecord], workspace: WorkspaceGuard, tools: ProjectTools, profiles: ProjectProfiles) {
            self.record = record; self.steps = steps; self.workspace = workspace; self.tools = tools; self.profiles = profiles
            self.unityProject = UnityProjectDetector.isUnityProject(root: workspace.root)
        }
        func step(_ key: String) -> TaskStepRecord? { steps.first { $0.key == key } }
        func index(_ key: String) -> Int? { steps.firstIndex { $0.key == key } }
    }

    // MARK: Queries

    var orderedViews: [TaskView] { views.values.sorted { $0.task.createdAt > $1.task.createdAt } }
    var activeViews: [TaskView] { orderedViews.filter { $0.task.state.isActive } }
    var activeCount: Int { contexts.values.filter { $0.record.state.isActive }.count }
    func view(_ id: UUID) -> TaskView? { views[id] }
    func isRunnerActive(_ id: UUID) -> Bool { runners[id] != nil }

    // MARK: Submit

    /// Creates the durable task FIRST, then starts working on it. Returns as soon as the task is persisted.
    @discardableResult
    func submit(goal rawGoal: String, kind: TaskKind, workspacePath: String, constraints: [String] = [], preference: ProviderPreference? = nil,
                title: String? = nil, destructiveRequested: Bool = false, id: UUID? = nil, origin: TaskOrigin = .userTask,
                originTaskID: UUID? = nil, originOpportunityID: UUID? = nil, autonomyDepth: Int = 0, scope: TaskScope? = nil) async -> Result<UUID, TaskSubmitError> {
        let goal = rawGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return .failure(.empty) }
        guard let repository else { return .failure(.persistenceUnavailable) }
        // Idempotent creation (V0.5: a proposal/auto-action may be delivered twice, e.g. around a crash): the same id never makes a second task.
        if let id, (try? repository.engineTask(id)) != nil { return .success(id) }
        if activeCount >= limits.maxActiveTasks { return .failure(.tooManyActiveTasks(activeCount)) }
        let ws: WorkspaceGuard
        do { ws = try WorkspaceGuard(rootPath: workspacePath) } catch { return .failure(.workspace(String(describing: error))) }

        let profile = TaskClassifier.profile(for: goal)
        var record = TaskRecord(id: id ?? UUID(), title: Self.makeTitle(title ?? goal), goal: String(goal.prefix(1500)), kind: kind)
        record.origin = origin; record.originTaskID = originTaskID; record.originOpportunityID = originOpportunityID; record.autonomyDepth = autonomyDepth; record.scope = scope
        record.category = kind == .development ? .repositoryModification : .research
        record.risk = destructiveRequested ? .high : (kind == .development ? .medium : .low)
        record.destructiveRequested = destructiveRequested && kind == .development
        record.privacy = profile.privacy
        record.workspaceRoot = ws.root
        record.capabilities = .for(kind, unityProject: UnityProjectDetector.isUnityProject(root: ws.root))
        record.constraints = constraints
        record.preference = preference
        record.activity = "Created"
        do { try repository.insert(record) } catch { return .failure(.persistenceUnavailable) }
        let ctx = TaskContext(record: record, steps: [], workspace: ws, tools: ProjectTools(workspace: ws, capabilities: record.capabilities), profiles: ProfileDiscovery.discover(ws))
        contexts[record.id] = ctx
        publish(ctx)
        note("Task created: \(record.title)", .info, taskID: record.id)
        startRunner(ctx)
        return .success(record.id)
    }

    static func makeTitle(_ goal: String) -> String {
        let one = goal.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let t = one.count > 72 ? String(one.prefix(70)) + "…" : one
        return Redactor.redact(t)
    }

    // MARK: Runner lifecycle

    func startRunner(_ ctx: TaskContext) {
        let id = ctx.record.id
        guard runners[id] == nil else { return }
        beginActivityAssertion()
        runners[id] = Task { @MainActor [weak self] in
            await self?.runTask(ctx)
            self?.runners[id] = nil
            self?.endActivityAssertionIfIdle()
        }
    }

    /// Prevents App Nap while tasks run (system sleep stays allowed). Needs no permission.
    private func beginActivityAssertion() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "JARVIS is executing a task")
    }
    private func endActivityAssertionIfIdle() {
        guard runners.isEmpty, let t = activityToken else { return }
        ProcessInfo.processInfo.endActivity(t); activityToken = nil
    }

    /// Waits until no runner is active (tests, shutdown).
    func waitUntilIdle() async {
        while let t = runners.values.first { await t.value }
    }

    /// Test hook: abandon every runner exactly as a crash would — nothing further is written.
    func cancelAllRunnersForTests() { for r in runners.values { r.cancel() } }

    func waitUntilFinished(_ id: UUID) async {
        if let t = runners[id] { await t.value }
    }

    // MARK: Main flow

    private func runTask(_ ctx: TaskContext) async {
        // 1. Plan (once; a resumed task keeps its persisted plan).
        if ctx.record.planVersion == 0 {
            guard transition(ctx, to: .planning, activity: "Planning") else { return }
            guard await planPhase(ctx) else { if !ctx.terminating { await finalizeFailure(ctx) }; return }
        }
        if ctx.cancelRequested || Task.isCancelled { await finalizeCancelled(ctx); return }
        // 2. Git baseline BEFORE any write (user's own uncommitted work).
        if ctx.record.kind == .development, ctx.record.gitBaseline == nil {
            let b = await GitTool.baseline(workspace: ctx.workspace)
            mutate(ctx) { $0.gitBaseline = b }
            if b.isRepository, !(b.dirtyPaths + b.untrackedPaths).isEmpty {
                note("Workspace already has \((b.dirtyPaths + b.untrackedPaths).count) uncommitted change(s) — they will not be overwritten", .warning, taskID: ctx.record.id)
            }
        }
        if ctx.record.state == .planning { guard transition(ctx, to: .ready, activity: "Plan accepted") else { return } }
        if ctx.record.state != .running { guard transition(ctx, to: .running, activity: "Running") else { return } }
        await checkpoint(ctx, reason: "plan accepted")
        // 3. Execute.
        await scheduleLoop(ctx)
        // 4. Terminal state.
        if ctx.terminating { return }
        if ctx.cancelRequested || Task.isCancelled { await finalizeCancelled(ctx); return }
        if ctx.hardFailure != nil { await finalizeFailure(ctx); return }
        let counted = ctx.steps.filter { $0.state != .skipped }
        if !counted.isEmpty, counted.allSatisfy({ $0.state == .passed }) { await finalizeSuccess(ctx) }
        else {
            ctx.hardFailure = (.validationFailed, "The plan stopped before every step passed.")
            await finalizeFailure(ctx)
        }
    }

    // MARK: Scheduler (event-driven: wakes only when a step finishes)

    enum StepOutcome: Sendable { case passed, skipped, failed(FailureCategory, String), cancelled }

    private func scheduleLoop(_ ctx: TaskContext) async {
        await withTaskGroup(of: (String, StepOutcome).self) { group in
            var inflight: [String: StepType] = [:]
            while true {
                if ctx.cancelRequested || Task.isCancelled || ctx.hardFailure != nil { break }
                for step in readySteps(ctx) where inflight.count < limits.maxConcurrentSteps && canRunAlongside(step.type, inflight) {
                    inflight[step.key] = step.type
                    let key = step.key
                    group.addTask { @MainActor [weak self] in
                        guard let self else { return (key, .cancelled) }
                        return (key, await self.executeStep(ctx, key: key))
                    }
                }
                if inflight.isEmpty { break }
                guard let (key, outcome) = await group.next() else { break }
                inflight[key] = nil
                switch outcome {
                case .passed, .skipped: break
                case .cancelled: if !ctx.cancelRequested { ctx.hardFailure = (.cancelled, "A step was cancelled.") }
                case .failed(let cat, let why): ctx.hardFailure = ctx.hardFailure ?? (cat, why)
                }
            }
            if ctx.cancelRequested || Task.isCancelled { group.cancelAll() }
            for await _ in group {}                                  // drain: every started step really finishes before we finalize
        }
    }

    /// Pending steps whose dependencies all passed (a skipped dependency counts as satisfied: it had nothing to do).
    private func readySteps(_ ctx: TaskContext) -> [TaskStepRecord] {
        let done = Set(ctx.steps.filter { $0.state == .passed || $0.state == .skipped }.map(\.key))
        return ctx.steps.filter { ($0.state == .pending || $0.state == .ready) && $0.dependsOn.allSatisfy(done.contains) }
    }

    /// Only read-only analysis steps run side by side; anything that writes, builds, tests or reviews the result runs alone.
    private func canRunAlongside(_ type: StepType, _ inflight: [String: StepType]) -> Bool {
        if inflight.isEmpty { return true }
        return type == .analysis && inflight.values.allSatisfy { $0 == .analysis }
    }

    // MARK: Persisted mutation helpers

    /// Applies a state transition through the state machine; illegal transitions are rejected and logged, never applied.
    @discardableResult
    func transition(_ ctx: TaskContext, to new: TaskState, activity: String? = nil, failure: (FailureCategory, String)? = nil) -> Bool {
        let old = ctx.record.state
        guard old == new || TaskStateMachine.canMove(old, to: new) else {
            Log.app.error("rejected task transition \(old.rawValue, privacy: .public) → \(new.rawValue, privacy: .public)")
            return false
        }
        let now = Date()
        // Active run time (survives restarts): count while planning/running only.
        if let since = ctx.runningSince, !(new == .planning || new == .running || new == .ready) {
            ctx.record.accumulatedSeconds += max(0, now.timeIntervalSince(since)); ctx.runningSince = nil
        }
        if ctx.runningSince == nil, new == .planning || new == .running { ctx.runningSince = now }
        ctx.record.state = new
        if new == .running, ctx.record.startedAt == nil { ctx.record.startedAt = now }
        if new.isTerminal { ctx.record.finishedAt = now }
        if let activity { ctx.record.activity = activity }
        if let failure { ctx.record.failureCategory = failure.0; ctx.record.failureReason = failure.1 }
        ctx.record.updatedAt = now
        persist(ctx)
        publish(ctx)
        if old != new { note("\(ctx.record.title): \(new.label.lowercased())", Self.kind(for: new), taskID: ctx.record.id) }
        return true
    }

    private static func kind(for s: TaskState) -> ActivityKind {
        switch s { case .completed: .success; case .failed: .error; case .cancelled, .interrupted, .waitingForApproval: .warning; default: .info }
    }

    func mutate(_ ctx: TaskContext, _ body: (inout TaskRecord) -> Void) {
        body(&ctx.record)
        ctx.record.updatedAt = Date()
        persist(ctx); publish(ctx)
    }

    @discardableResult
    func setStep(_ ctx: TaskContext, _ key: String, to new: TaskStepState, failure: (FailureCategory, String)? = nil, evidence: String? = nil, result: String? = nil) -> Bool {
        guard let i = ctx.index(key) else { return false }
        let old = ctx.steps[i].state
        guard old == new || TaskStateMachine.canMove(old, to: new) else {
            Log.app.error("rejected step transition \(old.rawValue, privacy: .public) → \(new.rawValue, privacy: .public) (\(key, privacy: .public))")
            return false
        }
        let now = Date()
        ctx.steps[i].state = new
        if new == .running, ctx.steps[i].startedAt == nil { ctx.steps[i].startedAt = now }
        if new.isTerminal || new == .interrupted { ctx.steps[i].finishedAt = now }
        if let failure { ctx.steps[i].failureCategory = failure.0; ctx.steps[i].failureReason = failure.1 }
        if let evidence { ctx.steps[i].validationEvidence = evidence }
        if let result { ctx.steps[i].resultSummary = result }
        try? repository?.update(ctx.steps[i])
        refreshProgress(ctx)
        if old != new, new == .passed || new == .failed || new == .waitingForApproval || new == .skipped {
            note("Step \(i + 1)/\(ctx.steps.count) \(new == .waitingForApproval ? "awaiting approval" : new.label.lowercased()): \(ctx.steps[i].title)", new == .failed ? .warning : .info, taskID: ctx.record.id)
        }
        return true
    }

    func updateStep(_ ctx: TaskContext, _ key: String, _ body: (inout TaskStepRecord) -> Void) {
        guard let i = ctx.index(key) else { return }
        body(&ctx.steps[i])
        try? repository?.update(ctx.steps[i])
        publish(ctx)
    }

    /// Progress is derived ONLY from validated step state (passed weight / total weight). Provider prose never reaches this.
    func refreshProgress(_ ctx: TaskContext) {
        let steps = ctx.steps.map { s -> AgentStep in
            let st: StepState = s.state == .passed ? .done : s.state == .skipped ? .skipped : s.state.isActive ? .active : s.state == .failed ? .failed : .pending
            return AgentStep(index: s.index, title: s.title, weight: s.weight, state: st)
        }
        let p = ProgressCalculator.compute(steps)
        ctx.record.progressFraction = p.fraction
        ctx.record.progressSource = p.source
        ctx.record.currentStepKey = ctx.steps.first { $0.state.isActive || $0.state == .waitingForApproval }?.key
        ctx.record.updatedAt = Date()
        persist(ctx); publish(ctx)
    }

    func persist(_ ctx: TaskContext) { try? repository?.update(ctx.record) }

    func publish(_ ctx: TaskContext) {
        let pending = (try? repository?.approvals(taskID: ctx.record.id))?.last { $0.state == .pending }
        views[ctx.record.id] = TaskView(task: ctx.record, steps: ctx.steps, pendingApproval: pending, runningSince: ctx.runningSince)
        revision += 1
        onChange?()
    }

    func note(_ message: String, _ kind: ActivityKind, taskID: UUID?) {
        audit.activity(kind.rawValue, message, taskID: taskID)
        onEvent?(message, kind)
    }

    // MARK: Cancellation (propagates downward through the EXISTING cancellation paths)

    /// STOP a task: no new steps start; active agent runs and tool processes are cancelled through `AgentRunManager`/`ManagedProcess`;
    /// leases are released; the terminal state, a partial report and a checkpoint are persisted.
    func cancel(_ taskID: UUID) {
        guard let ctx = contexts[taskID], ctx.record.state.isStoppable else {
            // A task that is not loaded (e.g. interrupted before this launch): cancel it in storage.
            if let r = try? repository?.engineTask(taskID), r.state == .interrupted || r.state == .created {
                var rec = r; rec.state = .cancelled; rec.cancelRequested = true; rec.finishedAt = Date(); rec.activity = "Cancelled"
                try? repository?.update(rec)
                note("Task stopped: \(rec.title)", .warning, taskID: taskID)
                refreshHistory()
            }
            return
        }
        ctx.cancelRequested = true
        mutate(ctx) { $0.cancelRequested = true; $0.activity = "Stopping…" }
        // Waiting approvals resolve as cancelled.
        if let pending = (try? repository?.approvals(taskID: taskID))?.filter({ $0.state == .pending }) {
            for var a in pending { a.state = .cancelled; a.decidedAt = Date(); a.decidedBy = "cancel"; try? repository?.update(a); decisions.removeValue(forKey: a.id)?.resume(returning: false) }
        }
        for run in hub?.activeRuns.filter({ audit.record($0.id)?.taskID == taskID }) ?? [] { agents.cancel(runID: run.id) }
        if let root = ctx.record.workspaceRoot { unity?.cancelPendingRequests(for: root) }      // V0.6: nothing waits for the editor after STOP
        runners[taskID]?.cancel()
        if runners[taskID] == nil { Task { @MainActor in await self.finalizeCancelled(ctx) } }          // never started / already idle
    }

    /// Stop addressed by an Observatory run id (the task owning that run).
    func cancelTask(owningRun runID: UUID) -> Bool {
        guard let tid = audit.record(runID)?.taskID ?? hub?.run(runID)?.taskID, contexts[tid] != nil else { return false }
        cancel(tid); return true
    }

    func cancelAll() { for id in contexts.keys { cancel(id) } }

    // MARK: Approvals

    /// Resolves a pending approval (HUD buttons / tests). Returns false if it is unknown or already decided.
    @discardableResult
    func decide(_ approvalID: UUID, approved: Bool, by: String = "user") -> Bool {
        guard var a = (try? repository?.pendingApprovals())?.first(where: { $0.id == approvalID }) ?? nil else { return false }
        guard TaskStateMachine.canMove(a.state, to: approved ? .approved : .denied) else { return false }
        a.state = approved ? .approved : .denied; a.decidedAt = Date(); a.decidedBy = by
        try? repository?.update(a)
        note("\(approved ? "Approved" : "Denied"): \(a.action)", approved ? .success : .warning, taskID: a.taskID)
        if let cont = decisions.removeValue(forKey: approvalID) { cont.resume(returning: approved) }
        else if let ctx = contexts[a.taskID] { publish(ctx) }
        onApprovalChanged?()
        return true
    }

    var pendingApprovals: [ApprovalRecord] { (try? repository?.pendingApprovals()) ?? [] }

    /// Bounded memory: old finished tasks are re-read from SQLite on demand (`refreshHistory`).
    func trimViews() {
        guard views.count > 60 else { return }
        let old = views.values.filter { $0.task.state.isTerminal && contexts[$0.id] == nil }.sorted { $0.task.createdAt < $1.task.createdAt }.prefix(views.count - 50)
        for v in old { views[v.id] = nil }
    }

    // MARK: History for the UI

    func refreshHistory(limit: Int = 30) {
        guard let repository, let recent = try? repository.engineTasks(limit: limit) else { return }
        for t in recent where contexts[t.id] == nil {
            views[t.id] = TaskView(task: t, steps: (try? repository.steps(taskID: t.id)) ?? [], pendingApproval: (try? repository.approvals(taskID: t.id))?.last { $0.state == .pending })
        }
        revision += 1
        onChange?()
    }
}
