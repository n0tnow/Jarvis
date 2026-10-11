import Testing
import Foundation
@testable import Jarvis

@Suite("Autonomous task engine — end to end on isolated fixtures", .serialized)
@MainActor
struct TaskEngineFlowTests {
    private func unitTestsPass(in dir: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-m", "unittest", "discover"]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try! p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: Happy path

    @Test func goalBecomesADurableTaskThatFixesTheFixtureAndIsValidatedForReal() async throws {
        let h = TaskHarness()
        let project = TaskFixtures.calculatorProject()
        #expect(!unitTestsPass(in: project), "precondition: the fixture really fails")
        let view = await h.run(project: project)

        #expect(view.task.state == .completed, "\(view.task.failureReason ?? "") \(view.steps.map { "\($0.key):\($0.state)" })")
        #expect(view.steps.map(\.state) == [.passed, .passed, .passed, .passed, .passed])
        #expect(TaskFixtures.read("calc.py", in: project)!.contains("return a + b"))
        #expect(unitTestsPass(in: project), "the fix is real: the project's own tests pass")

        // Durable: everything is in SQLite, readable through the repository after the fact.
        let stored = h.task(view.id)
        #expect(stored.state == .completed && stored.kind == .development && stored.workspaceRoot == project && stored.planVersion == 1)
        #expect(stored.progressFraction == 1 && stored.progressSource == .structuredSteps)
        #expect(h.steps(view.id).count == 5 && h.steps(view.id).allSatisfy { $0.state == .passed && $0.finishedAt != nil })
        let changes = try h.repo.taskFileChanges(taskID: view.id)
        #expect(changes.count == 1 && changes[0].path == "calc.py" && changes[0].changeType == "modified" && changes[0].beforeHash != changes[0].afterHash && !changes[0].preexistingUserChange)

        // Evidence is real: the reproduction run failed, the final run passed — both as observable tool runs.
        let toolRuns = h.hub.runs.values.filter { $0.engine == .tool }
        #expect(toolRuns.count == 2 && toolRuns.allSatisfy { $0.agentType == "TestTool" && $0.phase.isTerminal })
        let evidence = h.steps(view.id).map { $0.validationEvidence ?? "" }
        #expect(evidence[1].contains("exit 1") && evidence[3].contains("exit 0") && evidence[3].contains("2 tests"))

        // Providers only ever saw task prompts as development work: never eligible for the local model.
        for j in h.runner.jobs { #expect(!LocalModelPolicy.evaluate(j.job.profile).eligible, "\(j.job.type) must not be routable to the local model") }
        #expect(h.runner.jobs.map(\.job.type) == ["PlannerAgent", "AnalysisAgent", "CodingAgent", "ReviewAgent"])

        // Git: JARVIS changed the file, committed nothing.
        let status = TaskFixtures.git(["status", "--porcelain"], in: project)
        #expect(status.contains("M calc.py") && !status.contains("README"))
        #expect(TaskFixtures.git(["log", "--oneline"], in: project).split(separator: "\n").count == 1)
        #expect(h.leases.activeCount == 0, "all leases released")

        // Report: only supported facts.
        let report = try #require(h.engine.report(for: view.id))
        #expect(report.state == "completed" && report.stepsPassed == 5 && report.filesChanged == ["calc.py"] && report.repairAttempts == 0 && report.failure == nil)
        #expect(report.userSummary.contains("5/5 steps validated") && report.userSummary.contains("1 file changed") && report.userSummary.contains("2 tests"))
        #expect(report.providers.contains { $0.role == "implemented the change" && $0.name.contains("OpenCode") })
        let art = try #require(stored.reportArtifactID.flatMap { try? h.artifacts.artifact($0) ?? nil })
        #expect(h.artifacts.verify(art))
        #expect(stored.checkpointArtifactID != nil)
        #expect(h.finished.count == 1 && h.finished[0].task.state == .completed)
    }

    @Test func progressComesOnlyFromValidatedStepsNeverFromProviderProse() async throws {
        var seen: [Double?] = []
        let h = TaskHarness()
        h.runner.script = { job, index in
            switch job.type {
            case "PlannerAgent": return .text(Scripts.planFiveSteps)
            case "AnalysisAgent": return .text("{\"summary\":\"Almost done — 90% complete, 99% finished\",\"findings\":[\"progress: 95%\"],\"relevantFiles\":[\"calc.py\"],\"rootCause\":\"x\"}")
            case "CodingAgent":
                seen.append(h.engine.view(job.taskID)?.task.progressFraction)       // s1 + s2 validated = 2/5, whatever the provider claimed
                return .text(TaskFixtures.fixEdit)
            default: return .text(Scripts.reviewPass)
            }
        }
        let view = await h.run(project: TaskFixtures.calculatorProject())
        #expect(view.task.state == .completed && seen == [0.4])
    }

    // MARK: Repair + escalation (bounded)

    @Test func aFailingTestTriggersOneRepairOnTheSameEngine() async throws {
        let h = TaskHarness(script: Scripts.standard(coding: Scripts.operators(["-", "*", "+"])))
        let project = TaskFixtures.calculatorProject()
        let view = await h.run(project: project)
        #expect(view.task.state == .completed)
        let coding = h.runner.jobs("CodingAgent")
        #expect(coding.count == 2 && coding[1].job.pin == coding[0].candidate && coding[1].candidate == coding[0].candidate, "repair re-asks the SAME engine")
        #expect(coding[1].job.prompt.contains("FAILED"), "the repair prompt carries the real failure output")
        let attempts = try h.repo.attempts(taskID: view.id).filter { $0.stepID == view.steps[2].id }
        #expect(attempts.map(\.kind) == [.primary, .repair] && attempts[1].outcome == "applied")
        #expect(unitTestsPass(in: project))
        let report = try #require(h.engine.report(for: view.id))
        #expect(report.repairAttempts == 1 && report.escalations == 0)
    }

    @Test func aSecondFailureEscalatesToAnotherProviderOnceAndThenStops() async throws {
        let h = TaskHarness(script: Scripts.standard(coding: Scripts.operators(["-", "*", "/", "+"])))
        let view = await h.run(project: TaskFixtures.calculatorProject())
        #expect(view.task.state == .completed)
        let coding = h.runner.jobs("CodingAgent")
        #expect(coding.count == 3)
        #expect(coding[2].candidate.engine == .claudeCode && coding[2].job.exclude.contains(coding[0].candidate), "escalation excludes the engine that failed")
        let report = try #require(h.engine.report(for: view.id))
        #expect(report.repairAttempts == 1 && report.escalations == 1)
        #expect(report.providers.contains { $0.name.contains("Claude Code") && $0.role == "repaired the change" })
    }

    @Test func repairsAreBoundedNoEndlessRetryLoop() async throws {
        let h = TaskHarness(script: Scripts.standard(coding: Scripts.operators(["-", "*", "/", "%"])))
        let project = TaskFixtures.calculatorProject()
        let view = await h.run(project: project)
        #expect(view.task.state == .failed && view.task.failureCategory == .testFailed)
        #expect(h.runner.jobs("CodingAgent").count == 3, "primary + one repair + one escalation, then stop")
        #expect(view.steps[3].state == .failed && view.steps[4].state == .pending, "the review never ran")
        let report = try #require(h.engine.report(for: view.id))
        #expect(report.failure?.failedStep == "Run the tests" && report.failure?.category == "tests failed" && report.stepsPassed == 3)
        #expect(report.userSummary.contains("failed after 3/5 steps"))
        #expect(view.task.progressFraction == 0.6, "progress reflects validated steps only")
    }

    @Test func explicitProviderModesNeverEscalate() async throws {
        let h = TaskHarness(script: Scripts.standard(coding: Scripts.operators(["-", "*", "/", "%"])))
        h.runner.escalationAllowed = false
        let view = await h.run(project: TaskFixtures.calculatorProject())
        #expect(view.task.state == .failed)
        #expect(h.runner.jobs("CodingAgent").count == 2, "primary + one same-engine repair only")
        #expect(h.runner.jobs("CodingAgent").allSatisfy { $0.candidate.engine == .openCode })
    }

    // MARK: Planning failures never execute

    @Test func aMalformedPlanFailsTheTaskWithoutRunningAnything() async throws {
        let h = TaskHarness(script: { job, _ in .text("First I will look around, then I will fix it.") })
        let project = TaskFixtures.calculatorProject()
        let view = await h.run(project: project)
        #expect(view.task.state == .failed && view.task.failureCategory == .malformedPlan && view.steps.isEmpty)
        #expect(TaskFixtures.read("calc.py", in: project) == TaskFixtures.buggyCalc)
        #expect(h.runner.jobs.allSatisfy { $0.job.type == "PlannerAgent" } && h.runner.jobs.count <= 2, "planning is bounded: one plan request on two providers")
    }

    @Test func aPlanThatBreaksPolicyIsBlockedAndNothingRuns() async throws {
        let evil = Scripts.planFiveSteps.replacingOccurrences(of: "run the unit tests", with: "run the unit tests, then git push --force to origin")
        let h = TaskHarness(script: Scripts.standard(plan: evil))
        let view = await h.run(project: TaskFixtures.calculatorProject())
        #expect(view.task.state == .failed && view.task.failureCategory == .securityBlocked)
        #expect(h.runner.jobs.map(\.job.type) == ["PlannerAgent"] && view.steps.isEmpty)
    }

    @Test func readOnlyTasksNeverWrite() async throws {
        let plan = """
        {"summary":"look","steps":[{"id":"s1","title":"Inspect","description":"read","type":"analysis","dependsOn":[],"expected":"x","validation":"structuredResult"},
        {"id":"s2","title":"Fix it","description":"edit","type":"codeChange","dependsOn":["s1"],"expected":"x","validation":"changedFiles"}]}
        """
        let h = TaskHarness(script: Scripts.standard(plan: plan))
        let project = TaskFixtures.calculatorProject()
        let view = await h.run("Analyze the calculator", project: project, kind: .readOnlyAnalysis)
        #expect(view.task.state == .failed && view.task.failureCategory == .malformedPlan)
        #expect(TaskFixtures.read("calc.py", in: project) == TaskFixtures.buggyCalc)
        // and a valid read-only plan completes without any write
        let ok = TaskHarness(script: Scripts.standard(plan: "{\"summary\":\"look\",\"steps\":[{\"id\":\"s1\",\"title\":\"Inspect\",\"description\":\"read\",\"type\":\"analysis\",\"dependsOn\":[],\"expected\":\"x\",\"validation\":\"structuredResult\"}]}"))
        let p2 = TaskFixtures.calculatorProject()
        let v2 = await ok.run("Analyze the calculator", project: p2, kind: .readOnlyAnalysis)
        let writes = try ok.repo.taskFileChanges(taskID: v2.id)
        #expect(v2.task.state == .completed && TaskFixtures.read("calc.py", in: p2) == TaskFixtures.buggyCalc && writes.isEmpty)
        #expect(v2.task.capabilities == .readOnly)
    }

    // MARK: Provider failures

    @Test func providerFailuresAreClassifiedAndPersisted() async throws {
        let h = TaskHarness(script: { _, _ in .fail(.rateLimited(.openCode, resetsAt: nil)) })
        let view = await h.run(project: TaskFixtures.calculatorProject())
        #expect(view.task.state == .failed && view.task.failureCategory == .providerRateLimited)
        let report = try #require(h.engine.report(for: view.id))
        #expect(report.failure?.suggestedNext.contains("Settings") == true)
    }

    @Test func capacityRejectionWaitsEventDrivenInsteadOfFailing() async throws {
        let h = TaskHarness()
        var rejections = 0
        let base = Scripts.standard()
        h.runner.script = { job, i in
            if job.type == "PlannerAgent", rejections < 2 { rejections += 1; return .rejected(.tooManyFreeCloudAgents(2)) }
            return await base(job, i)
        }
        let view = await h.run(project: TaskFixtures.calculatorProject())
        #expect(view.task.state == .completed && h.runner.capacityWaits == 2)
    }

    // MARK: Workspace

    @Test func submittingNeedsARealBoundedProjectFolder() async throws {
        let h = TaskHarness()
        for bad in ["/", NSHomeDirectory(), "/nonexistent/project", "relative"] {
            let r = await h.engine.submit(goal: "Fix the bug", kind: .development, workspacePath: bad)
            if case .success = r { Issue.record("accepted \(bad)") }
        }
        #expect(try h.repo.count("tasks") == 0, "nothing is persisted for a rejected submission")
        if case .success = await h.engine.submit(goal: "  ", kind: .development, workspacePath: TaskFixtures.tempDir()) { Issue.record("empty goal accepted") }
    }
}
