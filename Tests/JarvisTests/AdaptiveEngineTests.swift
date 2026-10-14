import Testing
import Foundation
@testable import Jarvis

private typealias F = RouteFixtures

// V0.14 — learned behaviour inside the real engine, bounded routing, and the controlled self-improvement path on a DISPOSABLE Git fixture.

@Suite("Adaptive · routing bias is bounded and only orders what is already eligible")
struct LearnedRoutingTests {
    private let securityPrompt = "Review this code for security problems in the login flow."

    @Test("two eligible premium engines are ordered by the learned nudge; with no nudge the default order stands")
    func ordering() {
        let base = ModelRouter.route(F.profile(securityPrompt), snapshot: F.snapshot())
        #expect(base.selected?.engine == .claudeCode)
        var s = F.snapshot(); s.learnedBias = ["codex": 0.2]
        #expect(ModelRouter.route(F.profile(securityPrompt), snapshot: s).selected?.engine == .codex)
        var neg = F.snapshot(); neg.learnedBias = ["claudeCode": -0.2]
        #expect(ModelRouter.route(F.profile(securityPrompt), snapshot: neg).selected?.engine == .codex)
        var huge = F.snapshot(); huge.learnedBias = ["codex": 50]
        #expect(huge.bias("codex") == RoutingAdjustment.limit, "a nudge can never exceed its bound")
    }

    @Test("a nudge cannot make an unavailable provider eligible, and an explicit provider choice is never overridden")
    func policyOutranks() {
        var s = F.snapshot(codex: .notInstalled); s.learnedBias = ["codex": 0.2]
        let d = ModelRouter.route(F.profile(securityPrompt), snapshot: s)
        #expect(d.selected?.engine == .claudeCode && d.rejected["codex"] != nil)
        var explicit = F.snapshot(.claudeCode); explicit.learnedBias = ["codex": 0.2]
        #expect(ModelRouter.route(F.profile(securityPrompt), snapshot: explicit).selected?.engine == .claudeCode)
        // privacy: a sensitive task never goes to free cloud, whatever the nudge says
        var sensitive = F.snapshot(); sensitive.learnedBias = ["opencode/alpha-free": 0.2]
        let p = TaskProfile(category: .coding, complexity: .moderate, privacy: .sensitive)
        let r = ModelRouter.route(p, snapshot: sensitive)
        #expect(r.selected?.engine != .openCode)
    }

    @Test("free models: the nudge reorders models that already passed price, privacy and benchmark gates; a failing benchmark is not rescued")
    func freeModels() {
        let models = [F.freeModel("alpha-free"), F.freeModel("beta-free")]
        let good = [BenchmarkGroup.general: F.summary(.general, passed: 3, total: 3), .coding: F.summary(.coding, passed: 4, total: 4), .testing: F.summary(.testing, passed: 3, total: 3), .research: F.summary(.research, passed: 3, total: 3)]
        var s = F.snapshot(models: models, benchmarks: ["opencode/alpha-free": good, "opencode/beta-free": good])
        let plain = ModelRouter.route(F.profile("Fix the null reference bug in PlayerController.cs"), snapshot: s)
        #expect(plain.selected?.model == "opencode/alpha-free")
        s.learnedBias = ["opencode/beta-free": 0.2]
        #expect(ModelRouter.route(F.profile("Fix the null reference bug in PlayerController.cs"), snapshot: s).selected?.model == "opencode/beta-free")
        // beta fails its benchmark: the nudge does not make it eligible
        let bad = [BenchmarkGroup.coding: F.summary(.coding, passed: 0, total: 4), .general: F.summary(.general, passed: 0, total: 3)]
        var t = F.snapshot(models: models, benchmarks: ["opencode/alpha-free": good, "opencode/beta-free": bad]); t.learnedBias = ["opencode/beta-free": 0.2]
        #expect(ModelRouter.route(F.profile("Fix the null reference bug in PlayerController.cs"), snapshot: t).selected?.model == "opencode/alpha-free")
    }
}

@MainActor
@Suite("Adaptive · learned requirements in the plan", .serialized)
struct LearnedPlanTests {
    @Test("a rule can only make a plan stricter: it adds a missing review / test and never removes anything")
    func applyOnlyAdds() {
        func plan(_ types: [StepType]) -> TaskPlan {
            TaskPlan(summary: "t", steps: types.enumerated().map { PlanStep(id: "s\($0.offset + 1)", title: $0.element.rawValue, description: "", type: $0.element, dependsOn: $0.offset == 0 ? [] : ["s\($0.offset)"], expected: "", validation: .default(for: $0.element), risk: .low) })
        }
        var p = plan([.analysis, .codeChange])
        var fx = RuleEffects(); fx.independentReviewRequired = true; fx.extraValidations = ["rerunTests"]
        let added = TaskEngine.applyLearnedRequirements(&p, effects: fx, hasTestCommand: true)
        #expect(added == ["a test run", "an independent review"] && p.steps.map(\.type) == [.analysis, .codeChange, .test, .review])
        #expect(p.steps[3].dependsOn == ["s3"] && p.steps[2].dependsOn == ["s2"])
        // nothing to add when the plan is already strict; the plan is never shortened
        var strict = plan([.analysis, .codeChange, .test, .review])
        #expect(TaskEngine.applyLearnedRequirements(&strict, effects: fx, hasTestCommand: true) == nil && strict.steps.count == 4)
        // no change in the plan ⇒ nothing to review
        var readOnly = plan([.analysis])
        #expect(TaskEngine.applyLearnedRequirements(&readOnly, effects: fx, hasTestCommand: true) == nil && readOnly.steps.count == 1)
        // no test command ⇒ no invented test step
        var noTests = plan([.analysis, .codeChange])
        var onlyTests = RuleEffects(); onlyTests.extraValidations = ["rerunTests"]
        #expect(TaskEngine.applyLearnedRequirements(&noTests, effects: onlyTests, hasTestCommand: false) == nil)
        // an empty effect set changes nothing
        var untouched = plan([.analysis, .codeChange])
        #expect(TaskEngine.applyLearnedRequirements(&untouched, effects: RuleEffects(), hasTestCommand: true) == nil && untouched.steps.count == 2)
    }

    private func rig() throws -> (TaskHarness, LearningService, SkillRegistry, [UUID]) {
        let h = TaskHarness(script: Scripts.standard())
        h.engine.orchestrationEnabled = true
        let decisions = AdaptiveDecisionService(repository: h.repo)
        let learning = LearningService(repository: h.repo, decisions: decisions)
        let skills = SkillRegistry(repository: h.repo)
        h.keepAlive += [decisions, learning, skills]
        return (h, learning, skills, [])
    }

    @Test("a matching Skill chooses the template; an active rule adds the independent review; both run through the normal engine and are credited when the task finishes")
    func skillAndRuleThroughTheEngine() async throws {
        let (h, learning, skills, _) = try rig()
        let wf = WorkflowTemplate(nodes: [WorkflowNode(key: "w1", title: "Inspect", type: .analysis, dependsOn: [], optional: false), WorkflowNode(key: "w2", title: "Change", type: .codeChange, dependsOn: ["w1"], optional: false),
                                          WorkflowNode(key: "w3", title: "Test", type: .test, dependsOn: ["w2"], optional: false)])
        #expect(SkillValidator.validate(wf).isEmpty)
        let skill = Skill(name: "Calculator fix", description: "learned", scope: .global, version: 1, status: .active, triggerPatterns: ["calculation", "failing"], requiredCapabilities: SkillValidator.capabilities(of: wf).map(\.rawValue).sorted(),
                          requiredMCPs: [], graph: wf, approvalGates: [], validationGates: [], maxNodes: 3, origin: "learned from 3 successful run(s)", evidence: [], successCount: 3)
        try h.repo.save(skill)
        let rule = LearnedRule(scope: .global, version: 1, status: .active, definition: RuleDefinition(when: [RuleCondition(fact: .taskKind, comparison: .equals, value: "development")], then: [RuleAction(kind: .requireIndependentReview, argument: nil)]), title: "Review code changes", origin: "test")
        try h.repo.save(rule)
        h.engine.skillMatcher = { goal, kind, caps in skills.match(goal: goal, kind: kind, available: caps).map { (skills.orchestratedPlan(for: $0, goal: goal), $0.skill.id) } }
        h.engine.learnedEffects = { learning.effects(for: $0) }
        h.engine.onLearnedApplied = { learning.noteApplied(task: $0, rules: $1, skill: $2) }
        learning.skillOutcome = { skills.recordOutcome($0, success: $1) }
        h.engine.onFinished = { v in h.finished.append(v); Task { @MainActor in await learning.taskFinished(v) } }
        let project = TaskFixtures.calculatorProject()
        let v = await h.run("Fix the failing calculation test", project: project)
        #expect(v.task.state == .completed, "\(v.task.failureReason ?? "") \(v.steps.map { "\($0.key):\($0.state)" })")
        #expect(v.steps.map(\.type) == [.analysis, .codeChange, .test, .review], "the Skill's three steps plus the review the rule asked for")
        #expect(h.runner.jobs("ReviewAgent").count == 1 && h.runner.jobs("PlannerAgent").isEmpty, "no planner model: the Skill's template was validated like any plan")
        #expect(TaskFixtures.read("calc.py", in: project)?.contains("return a + b") == true)
        let graph = try #require(try h.repo.taskGraph(v.id))
        #expect(graph.template == "skill:\(skill.id.uuidString)" && graph.rationale?.contains("learned rule adds") == true)
        _ = await h.waitUntil { (try? h.repo.skill(skill.id))?.successCount == 4 }
        #expect(try h.repo.skill(skill.id)?.successCount == 4 && h.repo.learnedRule(rule.id)?.successCount == 1, "the outcome is credited to what was applied")
        #expect(try h.repo.learnedRule(rule.id)?.lastUsedAt != nil)
    }

    @Test("an invalid Skill plan is refused by the same validators and the planner model takes over; learning never bypasses them")
    func invalidSkillPlan() async throws {
        let (h, _, _, _) = try rig()
        let bad = TaskPlan(summary: "bad", steps: [PlanStep(id: "s1", title: "Delete", description: "", type: .delete, dependsOn: [], expected: "", validation: .default(for: .delete), risk: .high, targets: ["calc.py"])])
        h.engine.skillMatcher = { _, _, _ in (OrchestratedPlan(plan: bad, template: "skill:bad", rationale: "x", addsResearch: false, addsComputer: false), UUID()) }
        let project = TaskFixtures.calculatorProject()
        let v = await h.run("Fix the failing calculation test", project: project)
        #expect(v.steps.count == 5 && h.runner.jobs("PlannerAgent").count == 1, "the planner model produced the plan after the Skill plan failed validation")
        #expect(!v.steps.contains { $0.type == .delete })
    }

    @Test("a learned warning reaches the task's activity feed; nothing else changes")
    func warnings() async throws {
        let (h, learning, _, _) = try rig()
        let rule = LearnedRule(scope: .global, version: 1, status: .active, definition: RuleDefinition(when: [RuleCondition(fact: .taskKind, comparison: .equals, value: "development")], then: [RuleAction(kind: .addWarning, argument: "Check the camera rig first")]), title: "Warn", origin: "test")
        try h.repo.save(rule)
        h.engine.learnedEffects = { learning.effects(for: $0) }
        let project = TaskFixtures.calculatorProject()
        let v = await h.run("Find the bug, fix it, run the tests and review the change.", project: project)
        #expect(v.task.state == .completed && v.steps.count == 5)
        let log = ((try? h.repo.recentActivity(limit: 200)) ?? []).map { "\($0.1) \($0.2)" }
        #expect(log.contains { $0.contains("Learned rule") && $0.contains("Check the camera rig first") })
    }
}

@MainActor
@Suite("Self-improvement · levels, checkpoint, approval and an ordinary V0.12 task on a disposable fixture", .serialized)
struct SelfImprovementTests {
    struct Rig {
        let h: TaskHarness
        let learning: LearningService
        let decisions: AdaptiveDecisionService
        let si: SelfImprovementService
        let project: String
        var level: Box<SelfImprovementLevel>
    }
    func rig(level: SelfImprovementLevel, script: ((AgentJob, Int) async -> ScriptedRunner.Answer)? = nil) throws -> Rig {
        let h = TaskHarness(script: script ?? Scripts.standard())
        h.engine.orchestrationEnabled = true
        let decisions = AdaptiveDecisionService(repository: h.repo)
        let learning = LearningService(repository: h.repo, decisions: decisions)
        let lvl = Box(level)
        learning.settings = { var s = LearningSettings(); s.level = lvl.value; return s }
        let si = SelfImprovementService(repository: h.repo, learning: learning, decisions: decisions)
        si.engine = h.engine; si.level = { lvl.value }
        let project = TaskFixtures.calculatorProject()
        si.selfRepositoryPath = { project }
        h.engine.onFinished = { v in h.finished.append(v); si.taskFinished(v, report: nil) }
        h.keepAlive += [decisions, learning, si]
        return Rig(h: h, learning: learning, decisions: decisions, si: si, project: project, level: lvl)
    }
    func candidate(_ r: Rig) throws -> UUID {
        let ids = try (0..<3).map { i -> LearningEvidenceRef in
            var t = TaskRecord(id: UUID(), title: "slow \(i)", goal: "g", kind: .development); t.state = .completed; t.accumulatedSeconds = 900; t.finishedAt = Date().addingTimeInterval(-Double(i + 1) * 3600)
            try r.h.repo.insert(t)
            return LearningEvidenceRef(kind: .task, sourceID: t.id.uuidString, at: t.finishedAt!, note: "took 900 s")
        }
        let d = ImprovementDraft(problem: "add() in the calculator subtracts", evidenceSummary: "3 separate tasks", proposedChange: "fix add() so it returns the sum", expectedBenefit: "correct results", risk: "Low: one line", validationPlan: "run the unit tests", rollback: "git revert", affectedArea: "calc.py")
        let draft = CandidateDraft(kind: .sourceCodeImprovement, scope: .global, projectKey: nil, situation: "slow development", title: "Fix the calculator add() function", summary: d.problem, evidence: ids, counterEvidence: 0, risk: .medium, proposedEffect: "A written proposal.",
                                   validationRequirement: "tests", promotionRequirement: "approval", payload: LearningPayload(improvement: d))
        guard case .admitted(let id, _) = r.learning.admit(draft, by: "test") else { throw TestFailure("admit") }
        return id
    }
    struct TestFailure: Error { let m: String; init(_ m: String) { self.m = m } }

    @Test("below ‘Propose’ nothing can be proposed; below the highest level nothing can be applied; there is no level above it")
    func levels() throws {
        #expect(SelfImprovementLevel.allCases.count == 5 && SelfImprovementLevel.allCases.max() == .approvedSelfImprovement)
        #expect(SelfImprovementLevel.experiment.rawValue == 2, "the default level")
        let r = try rig(level: .experiment)
        let c = try candidate(r)
        if case .failure(let e) = r.si.propose(from: c) { #expect(e == .levelTooLow(.experiment) && e.description.contains("Propose")) } else { Issue.record("level 2 must not propose") }
        r.level.value = .propose
        guard case .success(let p) = r.si.propose(from: c) else { Issue.record("level 3 proposes"); return }
        #expect(p.status == .proposed && r.si.explanation(p).contains("Rollback:") && r.si.explanation(p).contains("Validation plan:"))
        #expect(r.learning.candidate(c)?.status == .proposed)
        if case .success = r.si.propose(from: c) {} else { Issue.record("proposing twice returns the open proposal") }
        #expect(r.si.proposals().count == 1)
    }

    @Test("proposing never touches the repository, and applying below the highest level is refused")
    func proposalChangesNothing() async throws {
        let r = try rig(level: .propose)
        let c = try candidate(r)
        let before = TaskFixtures.read("calc.py", in: r.project)
        guard case .success(let p) = r.si.propose(from: c) else { Issue.record("propose"); return }
        if case .failure(let e) = await r.si.requestApplication(p.id) { #expect(e == .levelTooLow(.propose)) } else { Issue.record("must refuse below level 4") }
        #expect(r.decisions.pending().isEmpty && TaskFixtures.read("calc.py", in: r.project) == before && r.h.engine.orderedViews.isEmpty, "no task, no request, no change")
    }

    @Test("approved at level 4 on a clean checkpoint: the change is an ORDINARY development task (analysis, coding, tests, independent review) and is applied only after the whole graph passed")
    func approvedSelfChange() async throws {
        let r = try rig(level: .approvedSelfImprovement)
        let c = try candidate(r)
        guard case .success(let p) = r.si.propose(from: c), case .success(let q) = await r.si.requestApplication(p.id) else { Issue.record("propose + request"); return }
        #expect(q.risk == .high && q.kind == .selfImprovement && q.detail.contains("Rollback:"))
        let head = await GitTool.continuity(at: r.project).head
        guard case .executed(let text) = await r.decisions.approve(q.id, source: .hud) else { Issue.record("approval must start the task"); return }
        #expect(text.contains("clean checkpoint") && text.contains("independent review"))
        let started = try #require(r.si.proposal(p.id))
        let taskID = try #require(started.taskID)
        #expect(started.checkpoint?.gitHead == head && started.checkpoint?.isClean == true && started.status == .running)
        await r.h.engine.waitUntilFinished(taskID)
        _ = await r.h.waitUntil { r.si.proposal(p.id)?.status == .applied }
        let done = try #require(r.si.proposal(p.id))
        #expect(done.status == .applied && done.result?.contains("scripts/verify.sh") == true && done.result?.contains("git revert") == true)
        let v = try #require(r.h.engine.view(taskID))
        #expect(v.task.state == .completed && v.steps.map(\.role) == [.analysis, .qa, .coding, .qa, .review], "the normal Analysis · QA · Coding · QA · Review graph")
        #expect(v.task.constraints.contains(SelfImprovementMarker.constraint) && v.task.origin == .userTask, "an ordinary user-approved task — nothing special because JARVIS proposed it")
        #expect(TaskFixtures.read("calc.py", in: r.project)?.contains("return a + b") == true)
        #expect(r.learning.candidate(c)?.status == .active)
        let g = await GitTool.continuity(at: r.project)
        #expect(g.head == head && !g.isClean, "JARVIS never commits: the change is a working-tree change the user can review or revert")
    }

    @Test("a dirty or unexplained working tree refuses the change; a lowered level refuses it at execution")
    func guards() async throws {
        let r = try rig(level: .approvedSelfImprovement)
        let c = try candidate(r)
        guard case .success(let p) = r.si.propose(from: c), case .success(let q) = await r.si.requestApplication(p.id) else { Issue.record("propose + request"); return }
        TaskFixtures.write("stray.txt", "somebody's unsaved work", in: r.project)
        guard case .refused(let why) = await r.decisions.approve(q.id, source: .hud) else { Issue.record("a dirty tree must refuse"); return }
        #expect(why.contains("not explained") && why.contains("stray.txt") && r.h.engine.orderedViews.isEmpty)
        #expect(r.si.proposal(p.id)?.status == .proposed)
        try FileManager.default.removeItem(atPath: r.project + "/stray.txt")
        guard case .success(let q2) = await r.si.requestApplication(p.id) else { Issue.record("ask again"); return }
        r.level.value = .propose
        guard case .refused(let why2) = await r.decisions.approve(q2.id, source: .hud) else { Issue.record("a lowered level must refuse"); return }
        #expect(why2.contains("level was lowered") && r.h.engine.orderedViews.isEmpty)
    }

    @Test("a failed self-change is NOT promoted and keeps its checkpoint for rollback")
    func failedChangeNotPromoted() async throws {
        let r = try rig(level: .approvedSelfImprovement, script: Scripts.standard(coding: { _ in "<<<<<<< SEARCH calc.py\nthis text is not in the file\n=======\nx\n>>>>>>> REPLACE\n" }))
        let c = try candidate(r)
        guard case .success(let p) = r.si.propose(from: c), case .success(let q) = await r.si.requestApplication(p.id), case .executed = await r.decisions.approve(q.id, source: .hud) else { Issue.record("start"); return }
        let taskID = try #require(r.si.proposal(p.id)?.taskID)
        await r.h.engine.waitUntilFinished(taskID)
        _ = await r.h.waitUntil { r.si.proposal(p.id)?.status == .failed }
        let done = try #require(r.si.proposal(p.id))
        #expect(done.status == .failed && done.result?.contains("NOT promoted") == true && done.checkpoint?.gitHead.isEmpty == false)
        #expect(r.learning.candidate(c)?.status != .active)
        #expect(TaskFixtures.read("calc.py", in: r.project)?.contains("return a - b") == true, "the file was not changed")
    }

    @Test("the approval is bound to the proposal that was shown")
    func scopeBound() async throws {
        let r = try rig(level: .approvedSelfImprovement)
        let c = try candidate(r)
        guard case .success(var p) = r.si.propose(from: c), case .success(let q) = await r.si.requestApplication(p.id) else { Issue.record("request"); return }
        p.draft.proposedChange = "delete everything and push"
        try r.h.repo.save(p)                                                       // the stored text is not what was shown
        _ = p.draft.proposedChange
        var stored = try #require(r.si.proposal(p.id)); stored.draft.proposedChange = "something else entirely"; try r.h.repo.save(stored)
        // `save` only updates status / checkpoint / result, so tamper through SQL as a second writer would
        try r.h.database.write { ctx in try ctx.execute("UPDATE improvement_proposals SET draft = ? WHERE id = ?", [.text((try? String(data: JSONEncoder().encode(stored.draft), encoding: .utf8)) ?? "{}"), .text(p.id.uuidString)]) }
        #expect(await r.decisions.approve(q.id, source: .hud) == .tampered && r.h.engine.orderedViews.isEmpty)
    }

    @Test("a self-improvement task that was running when JARVIS stopped is never promoted")
    func interrupted() async throws {
        let r = try rig(level: .approvedSelfImprovement)
        let c = try candidate(r)
        guard case .success(var p) = r.si.propose(from: c) else { Issue.record("propose"); return }
        p.status = .running; p.checkpoint = SelfChangeCheckpoint(gitHead: "abcdef1234", dirtyFiles: [], testsState: "x", version: "0.14", activeRuleIDs: [], activeMCPs: [], activeSkills: [], providerState: "x", at: Date())
        try r.h.repo.save(p)
        r.si.reconcileAfterLaunch()
        #expect(r.si.proposal(p.id)?.status == .failed && r.si.proposal(p.id)?.result?.contains("abcdef1") == true)
    }

    @Test("a source-code improvement is derived only from repeated slow tasks of one kind, and it is a PROPOSAL, never a change")
    func slowPathDetection() async throws {
        let r = try rig(level: .propose)
        for i in 0..<9 { var t = TaskRecord(id: UUID(), title: "t\(i)", goal: "g", kind: .development); t.state = .completed; t.accumulatedSeconds = i < 6 ? 30 : 900; t.finishedAt = Date().addingTimeInterval(-Double(i + 1) * 7200); t.workspaceRoot = "/tmp/p"; try r.h.repo.insert(t) }
        _ = await r.learning.extract(reason: "test")
        let imp = r.learning.candidates(kinds: [.sourceCodeImprovement])
        #expect(imp.count == 1, "\(r.learning.history().map(\.detail)) signals \(r.learning.signalCount)")
        #expect(imp.first?.payload.improvement?.rollback.contains("git revert") == true && imp.first?.risk == .medium)
        #expect(r.h.engine.orderedViews.isEmpty && r.decisions.pending().isEmpty, "nothing was started or asked")
    }
}
