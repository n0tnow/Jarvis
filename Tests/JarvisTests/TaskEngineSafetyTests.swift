import Testing
import Foundation
@testable import Jarvis

private func pgrepCount(_ pattern: String) -> Int {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-f", pattern]
    let pipe = Pipe(); p.standardOutput = pipe
    try! p.run(); p.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").count
}

private enum DeletePlan {
    static let json = """
    {"summary":"Remove the legacy module","steps":[
     {"id":"s1","title":"Inspect","description":"read the project","type":"analysis","dependsOn":[],"expected":"understanding","validation":"structuredResult"},
     {"id":"s2","title":"Delete legacy module","description":"the user asked to remove old/legacy.py","type":"delete","dependsOn":["s1"],"expected":"file removed","validation":"fileRemoved","risk":"high","targets":["old/legacy.py"]}]}
    """
    static func project() -> String {
        let dir = TaskFixtures.calculatorProject()
        TaskFixtures.write("old/legacy.py", "print('legacy')\n", in: dir)
        TaskFixtures.git(["add", "-A"], in: dir); TaskFixtures.git(["commit", "-q", "-m", "legacy"], in: dir)
        return dir
    }
}

@Suite("Task engine safety: approvals, user changes, cancellation, recovery", .serialized)
@MainActor
struct TaskEngineSafetyTests {
    // MARK: Approvals (destructive actions wait)

    @Test func aDestructiveStepWaitsForApprovalAndDoesNotExecute() async throws {
        let h = TaskHarness(script: Scripts.standard(plan: DeletePlan.json))
        let project = DeletePlan.project()
        let id = await h.submit("Remove the legacy module", project: project, destructive: true)
        #expect(await h.waitUntil { !h.engine.pendingApprovals.isEmpty })
        #expect(h.engine.view(id)?.task.state == .waitingForApproval && h.steps(id)[1].state == .waitingForApproval)
        #expect(FileManager.default.fileExists(atPath: project + "/old/legacy.py"), "nothing was deleted while waiting")
        let a = try #require(h.engine.pendingApprovals.first)
        #expect(a.action.contains("old/legacy.py") && a.risk == .high && a.state == .pending && h.engine.view(id)?.pendingApproval?.id == a.id)
        #expect(h.engine.decide(a.id, approved: true))
        #expect(!h.engine.decide(a.id, approved: false), "a decided approval cannot be changed")
        await h.engine.waitUntilFinished(id)
        #expect(h.task(id).state == .completed && !FileManager.default.fileExists(atPath: project + "/old/legacy.py"))
        #expect(try h.repo.approvals(taskID: id).map(\.state) == [.approved])
        #expect(try h.repo.taskFileChanges(taskID: id).first?.changeType == "deleted")
    }

    @Test func aDeniedApprovalResolvesSafely() async throws {
        let h = TaskHarness(script: Scripts.standard(plan: DeletePlan.json))
        let project = DeletePlan.project()
        let id = await h.submit("Remove the legacy module", project: project, destructive: true)
        #expect(await h.waitUntil { !h.engine.pendingApprovals.isEmpty })
        h.engine.decide(h.engine.pendingApprovals[0].id, approved: false)
        await h.engine.waitUntilFinished(id)
        let t = h.task(id)
        #expect(t.state == .failed && t.failureCategory == .approvalDenied && h.steps(id)[1].state == .failed)
        #expect(FileManager.default.fileExists(atPath: project + "/old/legacy.py"))
        #expect(try h.repo.approvals(taskID: id).map(\.state) == [.denied])
    }

    @Test func aWaitingApprovalSurvivesARestart() async throws {
        let h = TaskHarness(script: Scripts.standard(plan: DeletePlan.json))
        let project = DeletePlan.project()
        let id = await h.submit("Remove the legacy module", project: project, destructive: true)
        #expect(await h.waitUntil { !h.engine.pendingApprovals.isEmpty })
        h.engine.prepareForTermination()
        await h.engine.waitUntilIdle()
        #expect(h.task(id).state == .waitingForApproval && h.persistedPendingApprovals == 1, "quitting is not a denial")
        h.restart()
        #expect(h.engine.view(id)?.task.state == .waitingForApproval)
        #expect(await h.waitUntil { h.engine.isRunnerActive(id) && h.engine.view(id)?.task.state == .waitingForApproval && !h.engine.pendingApprovals.isEmpty })
        #expect(FileManager.default.fileExists(atPath: project + "/old/legacy.py"))
        h.engine.decide(h.engine.pendingApprovals[0].id, approved: true)
        await h.engine.waitUntilFinished(id)
        #expect(h.task(id).state == .completed && !FileManager.default.fileExists(atPath: project + "/old/legacy.py"))
        #expect(try h.repo.approvals(taskID: id).count == 1, "the persisted approval was reused, not asked twice")
    }

    // MARK: User changes are protected

    @Test func preExistingUncommittedChangesAreNeverOverwrittenSilently() async throws {
        // Denied: the user's file stays exactly as the user left it.
        let h = TaskHarness()
        let project = TaskFixtures.calculatorProject()
        let mine = "# my local tweak — not committed\n" + TaskFixtures.buggyCalc
        TaskFixtures.write("calc.py", mine, in: project)
        TaskFixtures.write("README.md", "# Calculator fixture\nuser notes\n", in: project)
        let id = await h.submit(project: project)
        #expect(await h.waitUntil { !h.engine.pendingApprovals.isEmpty })
        let a = h.engine.pendingApprovals[0]
        #expect(a.action.contains("calc.py") && !a.action.contains("README.md"), "only the file the task wants to change needs approval")
        let baseline = try #require(h.task(id).gitBaseline)
        #expect(baseline.isRepository && Set(baseline.dirtyPaths) == ["calc.py", "README.md"] && baseline.head != nil && baseline.branch == "main")
        h.engine.decide(a.id, approved: false)
        await h.engine.waitUntilFinished(id)
        #expect(h.task(id).failureCategory == .approvalDenied)
        #expect(TaskFixtures.read("calc.py", in: project) == mine && TaskFixtures.read("README.md", in: project)!.contains("user notes"))
        #expect(TaskFixtures.git(["log", "--oneline"], in: project).split(separator: "\n").count == 1, "no reset, no clean, no commit")

        // Approved: the fix is applied AROUND the user's change, which survives; the change is flagged as touching user work.
        let h2 = TaskHarness()
        let p2 = TaskFixtures.calculatorProject()
        TaskFixtures.write("calc.py", mine, in: p2)
        let id2 = await h2.submit(project: p2)
        #expect(await h2.waitUntil { !h2.engine.pendingApprovals.isEmpty })
        h2.engine.decide(h2.engine.pendingApprovals[0].id, approved: true)
        await h2.engine.waitUntilFinished(id2)
        #expect(h2.task(id2).state == .completed)
        let result = TaskFixtures.read("calc.py", in: p2)!
        #expect(result.hasPrefix("# my local tweak") && result.contains("return a + b"))
        #expect(try h2.repo.taskFileChanges(taskID: id2).first?.preexistingUserChange == true)
        #expect(h2.engine.report(for: id2)?.warnings.contains { $0.contains("uncommitted") } == true)
    }

    @Test func unrelatedUserChangesNeedNoApprovalAndSurvive() async throws {
        let h = TaskHarness()
        let project = TaskFixtures.calculatorProject()
        TaskFixtures.write("README.md", "# Calculator fixture\nmy notes\n", in: project)
        TaskFixtures.write("scratch.txt", "untracked user file\n", in: project)
        let view = await h.run(project: project)
        #expect(view.task.state == .completed && h.engine.pendingApprovals.isEmpty)
        #expect(TaskFixtures.read("README.md", in: project)!.contains("my notes") && TaskFixtures.read("scratch.txt", in: project) == "untracked user file\n")
        let status = TaskFixtures.git(["status", "--porcelain"], in: project)
        #expect(status.contains("M calc.py") && status.contains("M README.md") && status.contains("?? scratch.txt"))
    }

    // MARK: Workspace + capability enforcement inside the engine

    @Test func anEditThatEscapesTheWorkspaceIsRejectedAndNothingIsWritten() async throws {
        let escape = "<<<<<<< CREATE ../escaped.py\nprint('x')\n>>>>>>> END\n"
        let h = TaskHarness(script: Scripts.standard(coding: { _ in escape }))
        let project = TaskFixtures.calculatorProject()
        let view = await h.run(project: project)
        #expect(view.task.state == .failed && view.task.failureCategory == .workspaceViolation)
        #expect(!FileManager.default.fileExists(atPath: (project as NSString).deletingLastPathComponent + "/escaped.py"))
        #expect(TaskFixtures.read("calc.py", in: project) == TaskFixtures.buggyCalc)
    }

    // MARK: Cancellation

    @Test func cancellingATaskStopsEverythingAndLeavesNothingBehind() async throws {
        let h = TaskHarness()
        let base = Scripts.standard()
        h.runner.script = { job, i in job.type == "AnalysisAgent" ? .block : await base(job, i) }
        let project = TaskFixtures.calculatorProject()
        let id = await h.submit(project: project)
        #expect(await h.waitUntil { h.runner.jobs("AnalysisAgent").count == 1 && h.engine.view(id)?.task.state == .running })
        h.engine.cancel(id)
        await h.engine.waitUntilFinished(id)
        let t = h.task(id)
        #expect(t.state == .cancelled && t.cancelRequested)
        let steps = h.steps(id)
        #expect(steps[0].state == .cancelled && steps.dropFirst().allSatisfy { $0.state == .pending }, "no new step started")
        #expect(h.runner.jobs("CodingAgent").isEmpty && h.runner.jobs("ReviewAgent").isEmpty)
        #expect(h.hub.activeRuns.isEmpty && h.leases.activeCount == 0 && h.persistedActiveLeases == 0)
        #expect(TaskFixtures.read("calc.py", in: project) == TaskFixtures.buggyCalc)
        let report = try #require(h.engine.report(for: id))
        #expect(report.state == "cancelled" && report.stoppedAt == "Inspect the calculator" && report.filesChanged.isEmpty && report.userSummary.contains("no files were changed"))
        #expect(h.finished.last?.task.state == .cancelled)
        // persisted terminal state survives a restart and is never resumable
        h.restart()
        #expect(h.task(id).state == .cancelled && !h.engine.resume(id))
    }

    @Test func cancellingKillsARunningBuildOrTestProcess() async throws {
        let h = TaskHarness()
        let marker = "slow_" + UUID().uuidString.prefix(8).lowercased()
        let project = TaskFixtures.tempDir()
        TaskFixtures.write("\(marker).py", "import time\nprint('started')\ntime.sleep(60)\n", in: project)
        TaskFixtures.write(".jarvis/project.json", "{\"test\":{\"executable\":\"python3\",\"arguments\":[\"\(marker).py\"],\"timeoutSeconds\":120}}", in: project)
        let plan = "{\"summary\":\"run\",\"steps\":[{\"id\":\"s1\",\"title\":\"Run tests\",\"description\":\"run\",\"type\":\"test\",\"dependsOn\":[],\"expected\":\"x\",\"validation\":\"testEvidence\"}]}"
        h.runner.script = Scripts.standard(plan: plan)
        let id = await h.submit("Run the tests", project: project, kind: .development)
        #expect(await h.waitUntil { pgrepCount(marker) >= 1 })
        let started = Date()
        h.engine.cancel(id)
        await h.engine.waitUntilFinished(id)
        #expect(h.task(id).state == .cancelled && Date().timeIntervalSince(started) < 8)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(pgrepCount(marker) == 0, "the process tree is really gone")
        #expect(h.hub.activeRuns.isEmpty)
    }

    @Test func stoppingATaskAgentFromTheObservatoryStopsTheTask() async throws {
        let h = TaskHarness()
        let base = Scripts.standard()
        h.runner.script = { job, i in job.type == "AnalysisAgent" ? .block : await base(job, i) }
        h.hub.stopHandler = { [weak h] run in h?.engine.cancelTask(owningRun: run) ?? false }
        let id = await h.submit(project: TaskFixtures.calculatorProject())
        #expect(await h.waitUntil { h.runner.jobs("AnalysisAgent").count == 1 })
        let run = try #require(h.hub.activeRuns.first { $0.agentType == "AnalysisAgent" })
        #expect(run.owner == .task && run.taskID == id)
        #expect(h.hub.requestStop(run.id))
        await h.engine.waitUntilFinished(id)
        #expect(h.task(id).state == .cancelled)
    }

    // MARK: Restart + interruption

    @Test func aTaskInterruptedAfterPersistedStepsResumesWithoutStartingFromZero() async throws {
        let h = TaskHarness()
        let base = Scripts.standard()
        h.runner.script = { job, i in job.type == "ReviewAgent" ? .block : await base(job, i) }
        let project = TaskFixtures.calculatorProject()
        let id = await h.submit(project: project)
        #expect(await h.waitUntil { h.runner.jobs("ReviewAgent").count == 1 && h.engine.view(id)?.steps[4].state == .running })
        let before = h.steps(id)
        #expect(before[0...3].allSatisfy { $0.state == .passed })

        // Quit: the interrupted state and a checkpoint are persisted; leases released; nothing marked failed or denied.
        h.engine.prepareForTermination()
        await h.engine.waitUntilIdle()
        var t = h.task(id)
        #expect(t.state == .interrupted && h.steps(id)[4].state == .interrupted && h.steps(id)[0...3].allSatisfy { $0.state == .passed })
        #expect(t.checkpointArtifactID != nil && h.persistedActiveLeases == 0)

        // Relaunch.
        h.restart(script: Scripts.standard())
        #expect(h.engine.view(id)?.task.state == .interrupted, "nothing resumes automatically")
        #expect(h.engine.resume(id))
        await h.engine.waitUntilFinished(id)
        t = h.task(id)
        #expect(t.state == .completed && t.progressFraction == 1)
        #expect(h.runner.jobs.map(\.job.type) == ["ReviewAgent"], "planner, analysis and coding were NOT repeated")
        let after = h.steps(id)
        #expect(zip(before[0...3], after[0...3]).allSatisfy { $0.finishedAt == $1.finishedAt && $0.attempts == $1.attempts }, "completed steps are untouched")
        #expect(TaskFixtures.read("calc.py", in: project)!.contains("return a + b"))
    }

    @Test func aCrashLeavesNoRunningTaskBehind() async throws {
        let h = TaskHarness()
        let base = Scripts.standard()
        h.runner.script = { job, i in job.type == "CodingAgent" ? .block : await base(job, i) }
        let id = await h.submit(project: TaskFixtures.calculatorProject())
        #expect(await h.waitUntil { h.runner.jobs("CodingAgent").count == 1 })
        #expect(h.task(id).state == .running && h.steps(id)[2].state == .running)
        // "kill -9": the old process writes nothing more
        h.engine.contexts[id]?.terminating = true
        h.engine.cancelAllRunnersForTests()
        await h.engine.waitUntilIdle()
        #expect(h.task(id).state == .running, "the database still says running — only a restart can know better")
        h.restart()
        let t = h.task(id)
        #expect(t.state == .interrupted && t.recovery?.contains("restart") == true)
        #expect(h.steps(id)[2].state == .interrupted && h.steps(id)[0].state == .passed)
        #expect(h.hub.activeRuns.isEmpty && h.persistedActiveLeases == 0)
        // The stale agent run of the dead process is INTERRUPTED too (V0.3.2 reconciliation).
        #expect(try h.repo.agentRuns(taskID: id).allSatisfy { $0.status != .running })
    }

    @Test func aCodeStepWhoseEditsAreVerifiedOnDiskIsNotAskedAgain() async throws {
        let h = TaskHarness()
        let project = TaskFixtures.calculatorProject()
        let first = await h.run(project: project)
        #expect(first.task.state == .completed)
        // Simulate "interrupted right after the edit was applied": code step interrupted, later steps not yet run.
        var t = h.task(first.id); t.state = .interrupted; t.finishedAt = nil; try h.repo.update(t)
        var steps = h.steps(first.id)
        for i in [2, 3, 4] { steps[i].state = i == 2 ? .interrupted : .pending; steps[i].finishedAt = nil; try h.repo.update(steps[i]) }
        h.restart(script: Scripts.standard())
        #expect(h.engine.resume(first.id))
        await h.engine.waitUntilFinished(first.id)
        #expect(h.task(first.id).state == .completed)
        #expect(h.runner.jobs("CodingAgent").isEmpty, "the verified write is never replayed")
        #expect(h.steps(first.id)[2].validationEvidence?.contains("Recovered after restart") == true)
    }

    @Test func aCodeStepWhoseFilesDivergedFailsExplicitlyInsteadOfReplaying() async throws {
        let h = TaskHarness()
        let project = TaskFixtures.calculatorProject()
        let first = await h.run(project: project)
        var t = h.task(first.id); t.state = .interrupted; t.finishedAt = nil; try h.repo.update(t)
        var steps = h.steps(first.id)
        for i in [2, 3, 4] { steps[i].state = i == 2 ? .interrupted : .pending; steps[i].finishedAt = nil; try h.repo.update(steps[i]) }
        TaskFixtures.write("calc.py", "def add(a, b):\n    return 42  # someone else edited this\n", in: project)
        h.restart(script: Scripts.standard())
        #expect(h.engine.resume(first.id))
        await h.engine.waitUntilFinished(first.id)
        #expect(h.task(first.id).state == .failed && h.task(first.id).failureCategory == .workspaceChanged)
        #expect(h.runner.jobs.isEmpty && TaskFixtures.read("calc.py", in: project)!.contains("someone else"))
    }

    @Test func aRevertedCodeStepIsRedoneAndADeleteIsNeverReplayedWithoutApproval() async throws {
        let h = TaskHarness()
        let project = TaskFixtures.calculatorProject()
        let first = await h.run(project: project)
        var t = h.task(first.id); t.state = .interrupted; t.finishedAt = nil; try h.repo.update(t)
        var steps = h.steps(first.id)
        for i in [2, 3, 4] { steps[i].state = i == 2 ? .interrupted : .pending; steps[i].finishedAt = nil; try h.repo.update(steps[i]) }
        TaskFixtures.write("calc.py", TaskFixtures.buggyCalc, in: project)               // the edit was lost before it hit the disk
        h.restart(script: Scripts.standard())
        #expect(h.engine.resume(first.id))
        await h.engine.waitUntilFinished(first.id)
        #expect(h.task(first.id).state == .completed && h.runner.jobs("CodingAgent").count == 1, "an untouched file means the step runs again")

        // delete: interrupted → asks for approval again, deletes nothing by itself
        let h2 = TaskHarness(script: Scripts.standard(plan: DeletePlan.json))
        let p2 = DeletePlan.project()
        let id2 = await h2.submit("Remove the legacy module", project: p2, destructive: true)
        #expect(await h2.waitUntil { !h2.engine.pendingApprovals.isEmpty })
        h2.engine.prepareForTermination(); await h2.engine.waitUntilIdle()
        var t2 = h2.task(id2); t2.state = .interrupted; try h2.repo.update(t2)       // as if it had been running, not waiting
        var s2 = h2.steps(id2)[1]; s2.state = .interrupted; try h2.repo.update(s2)
        for var a in try h2.repo.pendingApprovals() { a.state = .cancelled; try h2.repo.update(a) }
        h2.restart(script: Scripts.standard(plan: DeletePlan.json))
        #expect(h2.engine.resume(id2))
        #expect(await h2.waitUntil { !h2.engine.pendingApprovals.isEmpty })
        #expect(FileManager.default.fileExists(atPath: p2 + "/old/legacy.py"), "not replayed blindly")
        h2.engine.cancel(id2); await h2.engine.waitUntilFinished(id2)
    }

    @Test func conflictingWritersWaitForTheLease() async throws {
        let h = TaskHarness()
        let project = TaskFixtures.calculatorProject()
        let tid = try h.repo.insertTask(title: "other agent's task")
        #expect(h.leases.acquire(paths: ["calc.py"], taskID: tid, stepID: nil, owner: "agent-other") == nil)
        let id = await h.submit(project: project)
        #expect(await h.waitUntil { h.runner.jobs("CodingAgent").count == 1 })
        try? await Task.sleep(for: .milliseconds(250))
        #expect(TaskFixtures.read("calc.py", in: project) == TaskFixtures.buggyCalc, "no simultaneous write while another agent owns the file")
        #expect(h.engine.view(id)?.task.state == .running)
        h.leases.release(owner: "agent-other")
        await h.engine.waitUntilFinished(id)
        #expect(h.task(id).state == .completed && TaskFixtures.read("calc.py", in: project)!.contains("return a + b"))
        #expect(h.leases.activeCount == 0, "released after the step")
    }

    @Test func staleLeasesOfADeadProcessAreReconciledOnLaunch() async throws {
        let h = TaskHarness()
        let tid = try h.repo.insertTask(title: "x")
        _ = h.leases.acquire(paths: ["a.cs", "b.cs"], taskID: tid, stepID: nil, owner: "step:dead")
        #expect(try h.repo.activeLeases().count == 2)
        h.restart()
        #expect(h.persistedActiveLeases == 0 && h.leases.activeCount == 0)
    }

    // MARK: Security: sanitization + persistence

    @Test func secretsPrintedByProjectToolsNeverReachConsolePersistenceOrArtifacts() async throws {
        let h = TaskHarness()
        let project = TaskFixtures.tempDir()
        TaskFixtures.write("leaky_test.py", "print('api_key=\(FakeSecrets.skKey)')\nprint('Authorization: Bearer \(FakeSecrets.bearer)')\nprint('ok')\n", in: project)
        TaskFixtures.write(".jarvis/project.json", "{\"test\":{\"executable\":\"python3\",\"arguments\":[\"leaky_test.py\"]}}", in: project)
        let plan = "{\"summary\":\"run\",\"steps\":[{\"id\":\"s1\",\"title\":\"Run tests\",\"description\":\"run\",\"type\":\"test\",\"dependsOn\":[],\"expected\":\"x\",\"validation\":\"testPass\"}]}"
        h.runner.script = Scripts.standard(plan: plan)
        let view = await h.run("Run the tests", project: project, kind: .development)
        #expect(view.task.state == .completed)
        h.hub.flushPersistNow()
        var everything = ""
        for run in h.hub.runs.keys { everything += h.hub.visibleText(run) }
        for table in ["agent_runs", "agent_events", "activity_events", "artifacts", "tasks", "task_steps", "step_attempts", "tool_executions"] {
            for row in try h.database.read("SELECT * FROM \(table)") { everything += "\(row)" }
        }
        for u in (FileManager.default.enumerator(at: h.paths.artifacts, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? [] {
            everything += FileManager.default.contents(atPath: u.path).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        #expect(FakeSecrets.leaks(everything).isEmpty, "leaked: \(FakeSecrets.leaks(everything))")
        #expect(everything.contains("ok"), "the harmless output is still visible")
    }

    @Test func taskTextIsRedactedBeforeItIsStored() async throws {
        let h = TaskHarness()
        let id = await h.submit("Fix the build, my key is \(FakeSecrets.skKey)", project: TaskFixtures.calculatorProject())
        await h.engine.waitUntilFinished(id)
        let stored = h.task(id)
        #expect(!stored.title.contains(FakeSecrets.skKey) && !stored.goal.contains(FakeSecrets.skKey) && stored.privacy == .sensitive)
    }

    // MARK: Observatory integration (V0.3.2 data model carries V0.4 tasks)

    @Test func taskRunsAppearInTheObservatoryGroupedByTask() async throws {
        let h = TaskHarness()
        let view = await h.run(project: TaskFixtures.calculatorProject())
        let runs = h.hub.runs.values.filter { $0.taskID == view.id }
        #expect(Set(runs.map(\.agentType)) == ["PlannerAgent", "AnalysisAgent", "CodingAgent", "ReviewAgent", "TestTool"])
        #expect(runs.allSatisfy { $0.owner == .task && $0.phase == .completed || $0.phase == .failed })
        #expect(runs.filter { $0.engine == .tool }.count == 2 && runs.filter { $0.engine == .openCode }.count == 4)
        // persisted run rows are linked to the task and rebuilt into views after a restart
        let rows = try h.repo.agentRuns(taskID: view.id)
        #expect(rows.count == 6 && rows.allSatisfy { AgentObservatory.view(from: $0).taskID == view.id })
        #expect(rows.first { $0.agentType == "CodingAgent" }?.filesChanged == ["calc.py"])
        // the tool run's console shows the real command output (sanitized)
        let testRun = try #require(runs.first { $0.engine == .tool })
        #expect(h.hub.visibleText(testRun.id).contains("Ran 2 tests") || h.hub.visibleText(testRun.id).contains("Ran"))
    }
}
