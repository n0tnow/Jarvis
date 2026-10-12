import Testing
import Foundation
@testable import Jarvis

@Suite("Review authority: hard validators outrank a model's opinion (both directions)")
@MainActor
struct ReviewAuthorityTests {
    func passes(_ r: ReviewResult, hard: Bool, gate: Bool = false, diff: String = "+    return a + b", paths: [String] = ["calc.py"]) -> ReviewAuthority.Decision {
        ReviewAuthority.decide(review: r, hardPassed: hard, gate: gate, diff: diff, evidence: ["Tests: python3 -m unittest discover → exit 0"], changedPaths: paths)
    }
    func review(_ json: String) -> ReviewResult { ReviewResult.parse(json)! }

    @Test func plainStringIssuesAreAdviceAndCannotFailAValidatedTask() {
        let r = review(#"{"verdict":"fail","summary":"naming","issues":["rename the helper","use a loop"]}"#)
        if case .advisory(let a) = passes(r, hard: true) { #expect(a.hasPrefix(ReviewAuthority.advisoryPrefix) && a.contains("rename the helper")) } else { Issue.record("should be advisory") }
        if case .fail = passes(r, hard: false) {} else { Issue.record("without any hard validator the reviewer's verdict still counts") }
        #expect(passes(review(#"{"verdict":"pass","summary":"ok","issues":[]}"#), hard: true) == .pass)
    }

    @Test func aConcreteVerifiableDefectCanStillFailATask() {
        let blocking = review(#"{"verdict":"fail","summary":"x","issues":[{"text":"deletes the user's data file","severity":"blocking","evidence":"+    return a + b"}]}"#)
        if case .fail(let why) = passes(blocking, hard: true) { #expect(why.contains("deletes the user's data file")) } else { Issue.record("a verifiable blocking issue must fail") }
        let invented = review(#"{"verdict":"fail","summary":"x","issues":[{"text":"SQL injection","severity":"blocking","evidence":"db.execute(user_input)"}]}"#)
        if case .advisory = passes(invented, hard: true) {} else { Issue.record("evidence that is not in the diff proves nothing") }
        let byPath = review(#"{"verdict":"fail","summary":"x","issues":[{"text":"touches secrets","severity":"blocking","evidence":"calc.py"}]}"#)
        if case .fail = passes(byPath, hard: true) {} else { Issue.record("a changed path is verifiable evidence") }
        let tooShort = review(#"{"verdict":"fail","summary":"x","issues":[{"text":"bad","severity":"blocking","evidence":"a"}]}"#)
        if case .advisory = passes(tooShort, hard: true) {} else { Issue.record("empty evidence is not evidence") }
    }

    @Test func anExplicitReviewGateRestoresTheReviewersVeto() {
        let r = review(#"{"verdict":"fail","summary":"I do not like it","issues":["style"]}"#)
        if case .fail = passes(r, hard: true, gate: true) {} else { Issue.record("gate") }
        #expect(ReviewAuthority.isGate(constraints: ["Review gate: the review must pass"]) && ReviewAuthority.isGate(constraints: ["please require review"]))
        #expect(!ReviewAuthority.isGate(constraints: ["keep it small"]))
    }

    @Test func onlyJarvisOwnFactsCountAsHardValidation() {
        func step(_ type: StepType, _ v: ValidationKind, _ state: TaskStepState) -> TaskStepRecord { var s = TaskStepRecord(id: UUID(), taskID: UUID(), index: 0, key: "k", title: "t", type: type, validation: v); s.state = state; return s }
        #expect(ReviewAuthority.hardValidationPassed(steps: [step(.test, .testPass, .passed)]))
        #expect(ReviewAuthority.hardValidationPassed(steps: [step(.unityCompile, .unityCompiled, .passed)]))
        #expect(!ReviewAuthority.hardValidationPassed(steps: [step(.test, .testPass, .failed)]))
        #expect(!ReviewAuthority.hardValidationPassed(steps: [step(.test, .testEvidence, .passed), step(.codeChange, .changedFiles, .passed), step(.analysis, .structuredResult, .passed)]))
    }

    // End to end on the V0.4 engine (no Unity involved): the same rule applies everywhere.

    @Test func passingTestsPlusADislikingReviewerStayCompleted() async {
        let dislike = #"{"verdict":"fail","summary":"I dislike this","issues":["Tests are noisy","Consider another structure"]}"#
        let h = TaskHarness(script: Scripts.withReview(Scripts.standard(plan: Scripts.planFiveSteps, coding: { _ in TaskFixtures.fixEdit }), dislike))
        let v = await h.run(project: TaskFixtures.calculatorProject())
        #expect(v.task.state == .completed, "\(v.task.failureReason ?? "")")
        let r = h.engine.report(for: v.id)
        #expect(r?.advisories?.count == 1 && r?.markdown().contains("Reviewer advice") == true)
    }

    @Test func aFailingTestIsNotRescuedByAHappyReviewer() async {
        let h = TaskHarness(script: Scripts.standard(plan: Scripts.planFiveSteps, coding: { _ in Scripts.addEdit(from: "-", to: "*") }))
        let v = await h.run(project: TaskFixtures.calculatorProject())
        #expect(v.task.state == .failed && v.task.failureCategory == .testFailed)
    }

    @Test func aReviewWithoutAnyHardValidatorStillCanFailTheTask() async {
        let plan = """
        {"summary":"s","steps":[{"id":"s1","title":"Fix","description":"d","type":"codeChange","dependsOn":[],"expected":"e","validation":"changedFiles","risk":"medium"},
        {"id":"s2","title":"Review","description":"d","type":"review","dependsOn":["s1"],"expected":"e","validation":"reviewPass","risk":"low"}]}
        """
        let h = TaskHarness(script: Scripts.withReview(Scripts.standard(plan: plan, coding: { _ in TaskFixtures.fixEdit }), #"{"verdict":"fail","summary":"wrong","issues":["it is wrong"]}"#))
        let v = await h.run(project: TaskFixtures.calculatorProject())
        #expect(v.task.state == .failed && v.task.failureCategory == .validationFailed)
    }

    @Test func aReviewGateInTheTaskConstraintsMakesTheReviewerBinding() async {
        let dislike = #"{"verdict":"fail","summary":"no","issues":["style"]}"#
        let h = TaskHarness(script: Scripts.withReview(Scripts.standard(plan: Scripts.planFiveSteps, coding: { _ in TaskFixtures.fixEdit }), dislike))
        let project = TaskFixtures.calculatorProject()
        guard case .success(let id) = await h.engine.submit(goal: "Fix the failing calculation test", kind: .development, workspacePath: project, constraints: ["review gate: the review must pass"]) else { Issue.record(); return }
        await h.engine.waitUntilFinished(id)
        #expect(h.engine.view(id)?.task.state == .failed)
    }

    @Test func aVerifiableBlockingIssueFailsEvenWhenTestsPass() async {
        let blocking = #"{"verdict":"fail","summary":"x","issues":[{"text":"returns the wrong thing","severity":"blocking","evidence":"return a + b"}]}"#
        let h = TaskHarness(script: Scripts.withReview(Scripts.standard(plan: Scripts.planFiveSteps, coding: { _ in TaskFixtures.fixEdit }), blocking))
        let v = await h.run(project: TaskFixtures.calculatorProject())
        #expect(v.task.state == .failed && v.task.failureReason?.contains("returns the wrong thing") == true)
    }
}

extension Scripts {
    /// The standard script with a different ReviewAgent answer.
    static func withReview(_ base: @escaping (AgentJob, Int) async -> ScriptedRunner.Answer, _ review: String) -> (AgentJob, Int) async -> ScriptedRunner.Answer {
        { job, i in job.type == "ReviewAgent" ? .text(review) : await base(job, i) }
    }
}
