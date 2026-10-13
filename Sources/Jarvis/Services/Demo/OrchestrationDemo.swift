import Foundation

/// DEV / LIVE-TEST ONLY (V0.12). A scripted stand-in for `AgentRunManager`: answers jobs with canned text so the REAL engine, scheduler, validators, tools, persistence and
/// cancellation paths are exercised without spending a provider request. It honours `exclude`/`pin` and creates real audit runs. Production code never references it.
@MainActor
final class OrchestrationScriptRunner: StepAgentRunner {
    enum Answer { case text(String), fail(ProviderError), block }
    var escalationAllowed = true
    var candidates = [RoutingCandidate(engine: .openCode, model: "opencode/scripted-free"), RoutingCandidate(engine: .claudeCode, model: nil)]
    var script: (AgentJob, Int) async -> Answer
    private(set) var jobs: [(job: AgentJob, candidate: RoutingCandidate, runID: UUID)] = []
    private var cancelled = Set<UUID>()
    private let audit: AuditRecorder

    init(audit: AuditRecorder, script: @escaping (AgentJob, Int) async -> Answer) { self.audit = audit; self.script = script }
    func count(_ type: String) -> Int { jobs.filter { $0.job.type == type }.count }

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
                if let v = job.validator, !(await v(t)).passed {
                    if attempt < job.policy.maxTotalAttempts, job.policy.maxRepairAttempts > 0 { continue }
                    audit.finish(runID, status: .failed, validation: .failed)
                    return .failed(runID: runID, error: nil, validationFailed: true, candidate: cand)
                }
                audit.finish(runID, status: .succeeded, resultText: t, validation: job.validator == nil ? .skipped : .passed)
                return .completed(text: t, runID: runID, candidate: cand, validated: job.validator != nil)
            case .fail(let e):
                audit.finish(runID, status: .failed, error: e)
                return .failed(runID: runID, error: e, validationFailed: false, candidate: cand)
            case .block:
                while !Task.isCancelled && !cancelled.contains(runID) { try? await Task.sleep(for: .milliseconds(10)) }
                audit.finish(runID, status: .cancelled)
                return .cancelled(runID: runID)
            }
        }
        audit.finish(runID, status: .failed)
        return .failed(runID: runID, error: nil, validationFailed: true, candidate: cand)
    }

    func waitForCapacityChange() async { try? await Task.sleep(for: .milliseconds(20)) }
    func cancel(runID: UUID) { cancelled.insert(runID) }
}

enum OrchestrationDemoText {
    static let analysis = "{\"summary\":\"add() subtracts instead of adding\",\"findings\":[\"calc.add returns a - b\"],\"relevantFiles\":[\"calc.py\",\"test_calc.py\"],\"rootCause\":\"wrong operator in add()\"}"
    static let reviewPass = "{\"verdict\":\"pass\",\"summary\":\"The operator is corrected and the tests pass.\",\"issues\":[]}"
    static let fixEdit = "<<<<<<< SEARCH calc.py\n    return a - b\n=======\n    return a + b\n>>>>>>> REPLACE\n"
    /// Edit blocks that move add()'s operator along `ops` (each CodingAgent call advances one step; the last operator is the target).
    static func operatorEdit(_ ops: [String], call i: Int) -> String {
        "<<<<<<< SEARCH calc.py\n    return a \(ops[min(i, ops.count - 2)]) b\n=======\n    return a \(ops[min(i + 1, ops.count - 1)]) b\n>>>>>>> REPLACE\n"
    }
}

extension ResearchFixtureEnv {
    /// One fixture web (a local HTTP server behind virtual public hosts) shared by a live test; nil if the server cannot start.
    @MainActor private static var cached: ResearchFixtureEnv?
    @MainActor static func shared() -> ResearchFixtureEnv? {
        if let cached { return cached }
        cached = try? ResearchFixtureEnv()
        return cached
    }
}

extension TaskDemo {
    /// Puts the calculator fixture back to its buggy state (soak loop only).
    static func resetFixture(_ dir: String) {
        try? "def add(a, b):\n    return a - b\n\ndef mul(a, b):\n    return a * b\n".write(toFile: dir + "/calc.py", atomically: true, encoding: .utf8)
    }
}
