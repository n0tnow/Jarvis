import Foundation

/// Developer-only scripted agents for the V0.4 task engine (captures, smoke tests): they answer jobs with canned text for a tiny
/// calculator project, so the REAL engine (plans, steps, tool runs, validation, approvals, leases, checkpoints) can be exercised
/// without any provider. Never used by the product path; only wired by `DevCapture` / `SmokeTest` (which run on a temporary database).
@MainActor
final class DemoAgentRunner: StepAgentRunner {
    var escalationAllowed = true
    /// Job types that wait until cancelled (to show a task that is mid-run).
    var blocking: Set<String> = []
    private let audit: AuditRecorder
    private var cancelled = Set<UUID>()
    private(set) var jobs: [String] = []

    init(audit: AuditRecorder) { self.audit = audit }

    static let plan = """
    {"summary":"Fix the calculator","steps":[
     {"id":"s1","title":"Inspect the calculator","description":"read calc.py and its tests","type":"analysis","dependsOn":[],"expected":"understanding","validation":"structuredResult"},
     {"id":"s2","title":"Reproduce the failing test","description":"run the unit tests","type":"test","dependsOn":["s1"],"expected":"a failure","validation":"testEvidence"},
     {"id":"s3","title":"Fix add()","description":"make add return the sum","type":"codeChange","dependsOn":["s2"],"expected":"add returns the sum","validation":"changedFiles","risk":"medium"},
     {"id":"s4","title":"Run the tests","description":"all tests must pass","type":"test","dependsOn":["s3"],"expected":"tests pass","validation":"testPass"},
     {"id":"s5","title":"Review the diff","description":"review the change","type":"review","dependsOn":["s4"],"expected":"approved","validation":"reviewPass"}]}
    """
    static let deletePlan = """
    {"summary":"Remove the legacy module","steps":[
     {"id":"s1","title":"Inspect the project","description":"read the project","type":"analysis","dependsOn":[],"expected":"understanding","validation":"structuredResult"},
     {"id":"s2","title":"Delete legacy module","description":"remove old/legacy.py as the user asked","type":"delete","dependsOn":["s1"],"expected":"file removed","validation":"fileRemoved","risk":"high","targets":["old/legacy.py"]}]}
    """

    var escalate = false
    func answer(_ job: AgentJob) -> String {
        switch job.type {
        case "PlannerAgent": return job.prompt.contains("legacy") ? Self.deletePlan : Self.plan
        case "AnalysisAgent": return "{\"summary\":\"add() subtracts instead of adding\",\"findings\":[\"calc.add returns a - b\"],\"relevantFiles\":[\"calc.py\"],\"rootCause\":\"wrong operator\"}"
        case "CodingAgent": return "<<<<<<< SEARCH calc.py\n    return a - b\n=======\n    return a + b\n>>>>>>> REPLACE\n"
        default: return "{\"verdict\":\"pass\",\"summary\":\"The operator is corrected and the tests pass.\",\"issues\":[]}"
        }
    }

    func run(_ job: AgentJob) async -> AgentJobResult {
        let cand = RoutingCandidate(engine: .openCode, model: "opencode/demo-free")
        let runID = audit.begin(agentType: job.type, taskID: job.taskID, engine: cand.engine, model: cand.model, decision: nil, prompt: job.prompt, privacy: .normal, label: job.title, owner: .task)
        jobs.append(job.type)
        audit.hub?.setPhase(runID, .running, activity: "Working")
        if blocking.contains(job.type) {
            while !Task.isCancelled && !cancelled.contains(runID) { try? await Task.sleep(for: .milliseconds(50)) }
            audit.finish(runID, status: .cancelled)
            return .cancelled(runID: runID)
        }
        try? await Task.sleep(for: .milliseconds(400))
        let text = answer(job)
        if let v = job.validator, !(await v(text)).passed { audit.finish(runID, status: .failed, validation: .failed); return .failed(runID: runID, error: nil, validationFailed: true, candidate: cand) }
        audit.finish(runID, status: .succeeded, resultText: text)
        return .completed(text: text, runID: runID, candidate: cand, validated: true)
    }

    func waitForCapacityChange() async { try? await Task.sleep(for: .milliseconds(100)) }
    func cancel(runID: UUID) { cancelled.insert(runID) }
}

enum TaskDemo {
    /// A throw-away project (temporary directory) with one bug and a failing unit test. Never the JARVIS repository.
    static func makeProject(withLegacyFile: Bool = false) -> String {
        let dir = NSTemporaryDirectory() + "jarvis-task-demo-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir + "/old", withIntermediateDirectories: true)
        func write(_ p: String, _ t: String) { FileManager.default.createFile(atPath: dir + "/" + p, contents: Data(t.utf8)) }
        write("calc.py", "def add(a, b):\n    return a - b\n")
        write("test_calc.py", "import unittest\nfrom calc import add\n\nclass T(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(add(2, 3), 5)\n\nif __name__ == '__main__':\n    unittest.main()\n")
        if withLegacyFile { write("old/legacy.py", "print('legacy')\n") }
        return (realpath(dir, nil).map { String(cString: $0) }) ?? dir
    }

    /// Parks `count` scripted tasks on a blocked coding agent (dev/perf only; stubbed runs use a temporary database).
    @MainActor static func park(context: AppContext, count: Int) async {
        let runner = DemoAgentRunner(audit: context.audit)
        runner.blocking = ["CodingAgent"]
        context.taskEngine.agents = runner
        for i in 0..<min(count, context.taskEngine.limits.maxActiveTasks) {
            _ = await context.taskEngine.submit(goal: "Fix the failing calculation test (demo \(i + 1))", kind: .development, workspacePath: makeProject())
        }
    }
}
