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

    /// Runs one scripted task to completion so the proactive layer leaves a pending proposal, plus a critical one (dev/perf only).
    @MainActor static func leaveProposals(context: AppContext) async {
        let runner = DemoAgentRunner(audit: context.audit)
        context.taskEngine.agents = runner
        context.opportunities.settings = { AutonomySettings(mode: .askBeforeActing) }
        guard case .success(let id) = await context.taskEngine.submit(goal: "Fix the failing calculation test", kind: .development, workspacePath: makeProject()) else { return }
        await context.taskEngine.waitUntilFinished(id)
        try? await Task.sleep(for: .milliseconds(600))
        if let root = context.taskEngine.view(id)?.task.workspaceRoot {
            _ = await context.opportunities.ingest(RawFinding(origin: .systemMaintenance, title: "Push the branch to origin", summary: "Committed locally only.", category: .maintenance,
                                                               evidence: [EvidenceItem(kind: .taskResult, summary: "The task changed calc.py", reference: "calc.py")], affectedPaths: ["calc.py"],
                                                               originTaskID: id, projectRoot: root, eventKey: "demo:critical"))
        }
    }

    /// DEMO ONLY (captures; stub-mode temp database): a finished Unity task with the evidence lines the real steps produce, in a Unity-shaped temp project.
    /// V0.13 capture data (SIMULATED, throw-away database): one finished experiment and a few pieces of visual evidence, so the Experiments card can be rendered.
    @MainActor static func seedOperatorDemo(context: AppContext) -> String? {
        guard let repo = context.repository else { return nil }
        let dir = makeProject()
        let spec = ExperimentSpec(question: "Does the bucket model pack import and render in a clean Unity project?", hypothesis: "It imports, compiles, instantiates and renders without pink materials.", kind: .assetImport,
                                  acquisitionID: UUID(), successCriteria: ["the project compiles", "it renders visibly"], failureCriteria: ["compile errors", "pink materials"])
        let facts = [ExperimentFact(statement: "Unity imported and compiled the project without compile errors", factClass: .tested, evidence: "compile state read from the editor"),
                     ExperimentFact(statement: "The subject is visible in the render", factClass: .tested, evidence: "area 12 % of the frame, contrast 0.41"),
                     ExperimentFact(statement: "Probably compatible with URP", factClass: .inferred, evidence: "the pack states built-in materials; URP not tested"),
                     ExperimentFact(statement: "Style fit with the project", factClass: .unknown, evidence: "no picture of the project was compared")]
        let result = ExperimentResult(verdict: .confirmed, summary: "the hypothesis held: the project compiles, an object can be instantiated, it renders visibly, it does not render pink", facts: facts,
                                      successMet: ["the project compiles", "it renders visibly"], failureHit: [], seconds: 41, environmentDeleted: true, pictureHashes: ["a1b2c3d4e5f60718"], projectUntouched: true)
        var rec = ExperimentRecord(id: UUID(), taskID: nil, stepKey: "s1", projectKey: nil, spec: spec, environmentPath: nil, status: "concluded", result: result, cleanupState: "deleted")
        rec.finishedAt = Date()
        try? repo.save(rec)
        try? repo.insert(VisualObservationRecord(taskID: nil, stepKey: "s2", provider: "unity-capture", pictureHash: "a1b2c3d4e5f60718", subject: "ExperimentSubject", query: "is it clearly visible?", outcome: "visible", detail: "area 12 %, contrast 0.41"))
        try? repo.insert(VisualObservationRecord(taskID: nil, stepKey: "s4", provider: "Qwen3-VL-4B (on-device)", pictureHash: "0f9e8d7c6b5a4938", subject: "Save", query: "locate the Save button", outcome: "found", detail: "1 candidate, high confidence", injectionNotes: 1))
        return dir
    }

    @MainActor static func seedUnityTask(context: AppContext) -> String? {
        let fm = FileManager.default
        let dir = NSTemporaryDirectory() + "jarvis-unity-demo-\(UUID().uuidString.prefix(6))"
        for d in ["Assets/Scenes", "ProjectSettings", "Packages"] { try? fm.createDirectory(atPath: dir + "/" + d, withIntermediateDirectories: true) }
        try? "m_EditorVersion: 6000.5.1f1\n".write(toFile: dir + "/ProjectSettings/ProjectVersion.txt", atomically: true, encoding: .utf8)
        try? "{\"dependencies\":{\"com.unity.test-framework\":\"1.7.0\"}}".write(toFile: dir + "/Packages/manifest.json", atomically: true, encoding: .utf8)
        try? "scene".write(toFile: dir + "/Assets/Scenes/FixtureScene.unity", atomically: true, encoding: .utf8)
        guard let repo = context.repository, let root = try? WorkspaceGuard(rootPath: dir).root else { return nil }
        var t = TaskRecord(id: UUID(), title: "Add a BoxCollider to TestCube if it does not have one (SIMULATED)", goal: "Add a BoxCollider to TestCube if it does not have one", kind: .development)
        t.state = .completed; t.workspaceRoot = root; t.finishedAt = Date(); t.startedAt = Date().addingTimeInterval(-42); t.accumulatedSeconds = 42; t.planVersion = 1
        t.progressFraction = 1; t.progressSource = .structuredSteps; t.capabilities = .for(.development, unityProject: true); t.summary = "SIMULATED demo task — 4/4 steps validated."
        try? repo.insert(t)
        let defs: [(StepType, ValidationKind, String, String)] = [
            (.unityInspect, .unityInspected, "Inspect TestCube", "Inspected the editor (Unity 6000.5.1f1 · Built-in · project Demo)"),
            (.unityEdit, .unityState, "Add BoxCollider", "Unity edit: added BoxCollider to TestCube#0; saved Assets/Scenes/FixtureScene.unity — verified in the editor"),
            (.unityCompile, .unityCompiled, "Compile in Unity", "Unity compile: PASS — Unity compilation OK (generation 3, 0 warnings) · domain reloaded"),
            (.unityValidate, .unityState, "Validate", "Unity validation (structural): TestCube has 1 × BoxCollider ✓ · Unity compilation OK · new Console errors: 0")]
        var steps: [TaskStepRecord] = []
        for (i, d) in defs.enumerated() {
            var st = TaskStepRecord(id: UUID(), taskID: t.id, index: i, key: "s\(i + 1)", title: d.2, type: d.0, dependsOn: i == 0 ? [] : ["s\(i)"], validation: d.1)
            st.state = .passed; st.validationEvidence = d.3; st.attempts = 1
            steps.append(st)
        }
        try? repo.insertSteps(steps)
        context.taskEngine.refreshHistory()
        context.preferences.projectRoot = root
        return dir
    }
}
