import Foundation
@testable import Jarvis

/// A scripted stand-in for `AgentRunManager` (routing, supervision and real providers are covered by the V0.3.x tests): it answers jobs
/// with canned text, honours `exclude`/`pin`, runs the job's validator with the same bounded format-repair behaviour, and creates real audit
/// runs so the hub/Observatory/cancellation paths of the engine are exercised for real.
@MainActor
final class ScriptedRunner: StepAgentRunner {
    enum Answer { case text(String), fail(ProviderError), block, rejected(AgentRejection) }

    var escalationAllowed = true
    var candidates = [RoutingCandidate(engine: .openCode, model: "opencode/free-1"), RoutingCandidate(engine: .claudeCode, model: nil)]
    var script: (AgentJob, Int) async -> Answer
    private(set) var jobs: [(job: AgentJob, candidate: RoutingCandidate, runID: UUID)] = []
    private var cancelled = Set<UUID>()
    private let audit: AuditRecorder
    private(set) var capacityWaits = 0

    init(audit: AuditRecorder, script: @escaping (AgentJob, Int) async -> Answer = { _, _ in .text("{}") }) { self.audit = audit; self.script = script }

    func jobs(_ type: String) -> [(job: AgentJob, candidate: RoutingCandidate, runID: UUID)] { jobs.filter { $0.job.type == type } }

    func run(_ job: AgentJob) async -> AgentJobResult {
        var order = candidates
        if let pin = job.pin { order = order.filter { $0 == pin } }
        order = order.filter { !job.exclude.contains($0) }
        guard let cand = order.first else { return .rejected(.noEligibleProvider("no further provider is eligible")) }
        let runID = audit.begin(agentType: job.type, taskID: job.taskID, engine: cand.engine, model: cand.model, decision: nil, prompt: job.prompt, privacy: .normal, label: job.title, owner: .task)
        let index = jobs.filter { $0.job.type == job.type }.count
        jobs.append((job, cand, runID))
        audit.hub?.setPhase(runID, .running, activity: "Scripted")
        var attempt = 0
        while attempt < job.policy.maxTotalAttempts {
            attempt += 1
            switch await script(job, index) {
            case .text(let t):
                if let v = job.validator {
                    let verdict = await v(t)
                    if !verdict.passed {
                        if attempt < job.policy.maxTotalAttempts, job.policy.maxRepairAttempts > 0 { continue }
                        audit.finish(runID, status: .failed, validation: .failed)
                        return .failed(runID: runID, error: nil, validationFailed: true, candidate: cand)
                    }
                }
                audit.finish(runID, status: .succeeded, resultText: t, validation: job.validator == nil ? .skipped : .passed)
                return .completed(text: t, runID: runID, candidate: cand, validated: job.validator != nil)
            case .fail(let e):
                audit.finish(runID, status: .failed, error: e)
                return .failed(runID: runID, error: e, validationFailed: false, candidate: cand)
            case .rejected(let r):
                audit.finish(runID, status: .failed, error: .refused("rejected"))
                return .rejected(r)
            case .block:
                while !Task.isCancelled && !cancelled.contains(runID) { try? await Task.sleep(for: .milliseconds(10)) }
                audit.finish(runID, status: .cancelled)
                return .cancelled(runID: runID)
            }
        }
        audit.finish(runID, status: .failed)
        return .failed(runID: runID, error: nil, validationFailed: true, candidate: cand)
    }

    func waitForCapacityChange() async { capacityWaits += 1; try? await Task.sleep(for: .milliseconds(20)) }
    func cancel(runID: UUID) { cancelled.insert(runID) }
}

enum Scripts {
    static let planFiveSteps = """
    {"summary":"Fix the calculator","steps":[
     {"id":"s1","title":"Inspect the calculator","description":"read calc.py and its tests","type":"analysis","dependsOn":[],"expected":"understanding","validation":"structuredResult","risk":"low"},
     {"id":"s2","title":"Reproduce the failing test","description":"run the unit tests","type":"test","dependsOn":["s1"],"expected":"a failure","validation":"testEvidence","risk":"low"},
     {"id":"s3","title":"Fix add()","description":"change add to add the numbers","type":"codeChange","dependsOn":["s2"],"expected":"add returns the sum","validation":"changedFiles","risk":"medium"},
     {"id":"s4","title":"Run the tests","description":"all tests must pass","type":"test","dependsOn":["s3"],"expected":"tests pass","validation":"testPass","risk":"low"},
     {"id":"s5","title":"Review the diff","description":"review the change","type":"review","dependsOn":["s4"],"expected":"approved","validation":"reviewPass","risk":"low"}]}
    """
    static let analysis = "{\"summary\":\"add() subtracts instead of adding\",\"findings\":[\"calc.add returns a - b\"],\"relevantFiles\":[\"calc.py\",\"test_calc.py\"],\"rootCause\":\"wrong operator in add()\"}"
    static let reviewPass = "{\"verdict\":\"pass\",\"summary\":\"The operator is corrected and the tests pass.\",\"issues\":[]}"
    /// An edit that changes add()'s operator from `from` to `to` (the SEARCH text always matches the CURRENT file, as a real model's would).
    static func addEdit(from: String, to: String) -> String {
        "<<<<<<< SEARCH calc.py\ndef add(a, b):\n    return a \(from) b\n=======\ndef add(a, b):\n    return a \(to) b\n>>>>>>> REPLACE\n"
    }
    /// Operator progression: each CodingAgent call moves to the next operator; the correct one is "+".
    static func operators(_ ops: [String]) -> (Int) -> String { { i in addEdit(from: ops[min(i, ops.count - 2)], to: ops[min(i + 1, ops.count - 1)]) } }

    /// The happy path: every job type answers correctly. `coding` supplies the n-th CodingAgent answer.
    static func standard(plan: String = planFiveSteps, coding: @escaping (Int) -> String = { _ in TaskFixtures.fixEdit }) -> (AgentJob, Int) async -> ScriptedRunner.Answer {
        { job, index in
            switch job.type {
            case "PlannerAgent": return .text(plan)
            case "AnalysisAgent": return .text(Scripts.analysis)
            case "CodingAgent": return .text(coding(index))
            case "ReviewAgent": return .text(reviewPass)
            default: return .fail(.generic)
            }
        }
    }
}

/// Engine + persistence over a temp SQLite database. `restart()` rebuilds every in-memory service over the SAME database (what a relaunch does).
@MainActor
final class TaskHarness {
    let paths = JarvisPaths.temporary("taskh")
    let database: JarvisDatabase
    let repo: JarvisRepository
    let artifacts: ArtifactStore
    var audit: AuditRecorder
    var hub: ExecutionHub
    var leases: FileLeaseManager
    var runner: ScriptedRunner
    var engine: TaskEngine
    var finished: [TaskView] = []
    /// Objects the engine only references weakly (HUD bridge…) must outlive the test body.
    var keepAlive: [AnyObject] = []

    init(script: @escaping (AgentJob, Int) async -> ScriptedRunner.Answer = Scripts.standard()) {
        try! paths.ensureDirectories()
        database = try! JarvisDatabase(url: paths.database)
        repo = JarvisRepository(database: database)
        artifacts = ArtifactStore(paths: paths, database: database)
        audit = AuditRecorder(repository: repo)
        hub = ExecutionHub(repository: repo, artifacts: artifacts, audit: audit)
        audit.hub = hub
        leases = FileLeaseManager(repository: repo)
        runner = ScriptedRunner(audit: audit, script: script)
        engine = TaskEngine(repository: repo, artifacts: artifacts, audit: audit, leases: leases, agents: runner)
        engine.onFinished = { [weak self] v in self?.finished.append(v) }
    }

    /// A relaunch: new audit/hub/leases/runner/engine over the same database, with launch reconciliation.
    func restart(script: ((AgentJob, Int) async -> ScriptedRunner.Answer)? = nil) {
        audit = AuditRecorder(repository: repo)
        hub = ExecutionHub(repository: repo, artifacts: artifacts, audit: audit)
        audit.hub = hub
        leases = FileLeaseManager(repository: repo)
        runner = ScriptedRunner(audit: audit, script: script ?? runner.script)
        engine = TaskEngine(repository: repo, artifacts: artifacts, audit: audit, leases: leases, agents: runner)
        engine.onFinished = { [weak self] v in self?.finished.append(v) }
        audit.reconcileStaleRuns()
        engine.reconcileOnLaunch()
        engine.restoreWaitingTasks()
    }

    @discardableResult
    func submit(_ goal: String = "Fix the failing calculation test", project: String, kind: TaskKind = .development, destructive: Bool = false) async -> UUID {
        switch await engine.submit(goal: goal, kind: kind, workspacePath: project, destructiveRequested: destructive) {
        case .success(let id): return id
        case .failure(let e): fatalError("submit failed: \(e)")
        }
    }

    func run(_ goal: String = "Fix the failing calculation test", project: String, kind: TaskKind = .development) async -> TaskView {
        let id = await submit(goal, project: project, kind: kind)
        await engine.waitUntilFinished(id)
        return engine.view(id)!
    }

    var persistedActiveLeases: Int { (try? repo.activeLeases().count) ?? -1 }
    var persistedPendingApprovals: Int { (try? repo.pendingApprovals().count) ?? -1 }
    func approvalStates(_ id: UUID) -> [ApprovalState] { ((try? repo.approvals(taskID: id)) ?? []).map(\.state) }
    func fileChanges(_ id: UUID) -> [TaskFileChange] { (try? repo.taskFileChanges(taskID: id)) ?? [] }
    func task(_ id: UUID) -> TaskRecord { (try! repo.engineTask(id))! }
    func steps(_ id: UUID) -> [TaskStepRecord] { try! repo.steps(taskID: id) }

    /// Polls a condition (tests only) — the engine itself never polls.
    func waitUntil(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; try? await Task.sleep(for: .milliseconds(15)) }
        return condition()
    }
}
