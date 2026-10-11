import Foundation
@testable import Jarvis

/// V0.4 harness + the V0.5 decision layer (OpportunityEngine, ProposalService) over the same temp database.
@MainActor
final class ProactiveHarness {
    let base: TaskHarness
    var opportunities: OpportunityEngine
    var proposals: ProposalService
    var settings = AutonomySettings()
    var now = Date()

    var engine: TaskEngine { base.engine }
    var repo: JarvisRepository { base.repo }
    var runner: ScriptedRunner { base.runner }

    init(mode: AutonomyMode = .askBeforeActing, script: ((AgentJob, Int) async -> ScriptedRunner.Answer)? = nil) {
        base = TaskHarness(script: script ?? ProactiveScripts.standard())
        settings.mode = mode
        opportunities = OpportunityEngine(repository: base.repo, audit: base.audit, tasks: base.engine)
        proposals = ProposalService(repository: base.repo, engine: opportunities)
        wire()
    }

    private func wire() {
        opportunities.settings = { [unowned self] in self.settings }
        opportunities.clock = { [unowned self] in self.now }
        proposals.clock = { [unowned self] in self.now }
        let previous = base.engine.onFinished
        base.engine.onFinished = { [weak self] v in
            previous?(v)
            guard let self else { return }
            Task { @MainActor in await self.opportunities.taskFinished(v) }
        }
        base.engine.onReviewSuggestions = { [weak self] task, step, run, suggestions in
            guard let self else { return }
            Task { @MainActor in await self.opportunities.reviewSuggestions(task: task, stepID: step, runID: run, suggestions: suggestions) }
        }
    }

    /// A relaunch of every in-memory service over the same database.
    func restart() async {
        base.restart(script: nil)
        opportunities = OpportunityEngine(repository: base.repo, audit: base.audit, tasks: base.engine)
        proposals = ProposalService(repository: base.repo, engine: opportunities)
        wire()
        await opportunities.reconcileOnLaunch()
    }

    /// Lets the proactive reaction to a finished task (it runs in its own Task) complete, including any automatic task it started.
    func settle(_ seconds: Double = 0.4, until condition: (() -> Bool)? = nil) async {
        if let c = condition {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if c() { break }; try? await Task.sleep(for: .milliseconds(20)) }
        } else { try? await Task.sleep(for: .seconds(seconds)) }
        await base.engine.waitUntilIdle()
    }

    func runUserTask(project: String, goal: String = "Fix the failing calculation test") async -> TaskView {
        let v = await base.run(goal, project: project)
        await settle()
        return v
    }

    func proposal(_ id: UUID) -> ProposalRecord? { (try? repo.proposal(id)) ?? nil }
    func opportunity(_ id: UUID) -> OpportunityRecord? { (try? repo.opportunity(id)) ?? nil }
    func approval(_ proposalID: UUID) -> ApprovalRecord? { (try? repo.proposalApproval(proposalID)) ?? nil }
    func allOpportunities() -> [OpportunityRecord] { (try? repo.opportunities(limit: 200)) ?? [] }
    func allProposals() -> [ProposalRecord] { (try? repo.proposals(limit: 200)) ?? [] }
    func allTasks() -> [TaskRecord] { ((try? repo.engineTasks(limit: 100)) ?? []).sorted { $0.createdAt < $1.createdAt } }
}

enum ProactiveScripts {
    /// Plan for a regression-test proposal (analysis → codeChange → test → review).
    static let testPlan = """
    {"summary":"Add a regression test","steps":[
     {"id":"s1","title":"Inspect the tests","description":"read the existing tests","type":"analysis","dependsOn":[],"expected":"x","validation":"structuredResult"},
     {"id":"s2","title":"Add the regression test","description":"add one test","type":"codeChange","dependsOn":["s1"],"expected":"test added","validation":"changedFiles","risk":"medium"},
     {"id":"s3","title":"Run the tests","description":"all pass","type":"test","dependsOn":["s2"],"expected":"pass","validation":"testPass"},
     {"id":"s4","title":"Review","description":"review","type":"review","dependsOn":["s3"],"expected":"ok","validation":"reviewPass"}]}
    """
    /// Appends one regression test to the fixture's test class (a test-file-only change).
    static let addTestEdit = "<<<<<<< SEARCH test_calc.py\n        self.assertEqual(mul(2, 3), 6)\n=======\n        self.assertEqual(mul(2, 3), 6)\n\n    def test_add_negative(self):\n        self.assertEqual(add(-1, -2), -3)\n>>>>>>> REPLACE\n"
    /// An edit that touches application code although only a test was approved.
    static let appCodeEdit = "<<<<<<< SEARCH calc.py\n    return a - b\n=======\n    return a + b\n>>>>>>> REPLACE\n"

    static func standard(userCoding: @escaping (Int) -> String = { _ in TaskFixtures.fixEdit }, testCoding: String = addTestEdit,
                         testPlanText: String = testPlan, reviewSuggestions: String? = nil) -> (AgentJob, Int) async -> ScriptedRunner.Answer {
        { job, index in
            let isTestTask = job.prompt.contains("Add one focused regression test") || job.prompt.contains("Scope approved by the user")
            switch job.type {
            case "PlannerAgent": return .text(isTestTask ? testPlanText : Scripts.planFiveSteps)
            case "AnalysisAgent": return .text(Scripts.analysis)
            case "CodingAgent": return .text(isTestTask ? testCoding : userCoding(index))
            case "ReviewAgent":
                if let s = reviewSuggestions, !isTestTask { return .text(s) }
                return .text(Scripts.reviewPass)
            case "OpportunityAssessor": return .text("{\"category\":\"maintenance\",\"affectedFiles\":[],\"designImpact\":false,\"risk\":\"low\",\"externalEffects\":[],\"requiredCapabilities\":[],\"confidence\":0.9,\"summary\":\"ok\"}")
            default: return .fail(.generic)
            }
        }
    }
}
