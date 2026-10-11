import Testing
import Foundation
@testable import Jarvis

private func sourcesRoot() -> URL {
    // …/Tests/JarvisTests/TaskEngineExtraTests.swift → repository root
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

/// Code only: comment lines (which legitimately NAME forbidden things, e.g. "never runs git push") are not code.
private func codeOnly(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
}

private func allSwiftSources(under sub: String) -> [(path: String, text: String)] {
    let dir = sourcesRoot().appendingPathComponent(sub)
    var out: [(String, String)] = []
    for u in (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? [] where u.pathExtension == "swift" {
        out.append((u.path, codeOnly(FileManager.default.contents(atPath: u.path).map { String(decoding: $0, as: UTF8.self) } ?? "")))
    }
    return out
}

@Suite("Task engine: routing policy, observability and progress across states", .serialized)
@MainActor
struct TaskEngineExtraTests {
    // MARK: Routing policy holds for task prompts (real ModelRouter, real LocalModelPolicy)

    @Test func taskPromptsNeverRouteToTheLocalModelEvenWhenItIsTheOnlyReadyEngine() async throws {
        let h = TaskHarness()
        let project = TaskFixtures.calculatorProject()
        let id = await h.submit(project: project)
        await h.engine.waitUntilFinished(id)
        // The profiles the engine really produced for each job type, replayed through the REAL router:
        for j in h.runner.jobs {
            let onlyLocal = RouteFixtures.snapshot(.auto, local: .ready, openCode: .notInstalled, claude: .notInstalled, codex: .notInstalled, models: [])
            let d = ModelRouter.route(j.job.profile, snapshot: onlyLocal)
            #expect(d.selected == nil, "\(j.job.type): local must never be selected for task work")
            let explicitLocal = ModelRouter.route(j.job.profile, snapshot: RouteFixtures.snapshot(.local))
            #expect(explicitLocal.selected == nil, "\(j.job.type): explicit Local is refused for development work")
            let normal = ModelRouter.route(j.job.profile, snapshot: RouteFixtures.snapshot(.auto))
            #expect(normal.selected?.engine != .local && normal.selected?.engine != nil, "\(j.job.type): Auto picks free-cloud/subscription: \(normal.summary)")
            #expect(j.job.profile.containsProjectCode && j.job.profile.isDevelopment)
        }
        #expect(!h.runner.jobs.isEmpty)
    }

    @Test func taskPromptsWithProjectCodeNeedAZeroRetentionFreeModel() async throws {
        let h = TaskHarness()
        let id = await h.submit(project: TaskFixtures.calculatorProject())
        await h.engine.waitUntilFinished(id)
        let profile = try #require(h.runner.jobs("CodingAgent").first?.job.profile)
        let trains = RouteFixtures.freeModel("trainer", policy: .mayTrain)
        var snap = RouteFixtures.snapshot(.auto, models: [trains], benchmarks: ["opencode/trainer": [.coding: RouteFixtures.summary(.coding, passed: 4, total: 4)]])
        #expect(ModelRouter.route(profile, snapshot: snap).selected?.engine != .openCode, "a model that may train on prompts must not receive project code")
        snap.engines[.claudeCode] = EngineAvailability(.claudeCode, state: .notInstalled); snap.engines[.codex] = EngineAvailability(.codex, state: .notInstalled)
        #expect(ModelRouter.route(profile, snapshot: snap).selected == nil, "no silent fallback to anything else (and never a paid API: none exists)")
    }

    @Test func noEligibleProviderFailsTheTaskInsteadOfUsingAnotherOne() async throws {
        let h = TaskHarness(script: { _, _ in .text("{}") })
        h.runner.candidates = []                                         // nothing eligible
        let view = await h.run(project: TaskFixtures.calculatorProject())
        #expect(view.task.state == .failed && view.task.failureCategory == .providerUnavailable)
    }

    // MARK: Observability: everything shows up from real events

    @Test func theActivityFeedAndTimelineNarrateTheRealExecution() async throws {
        let h = TaskHarness(script: Scripts.standard(coding: Scripts.operators(["-", "*", "+"])))
        let view = await h.run(project: TaskFixtures.calculatorProject())
        #expect(view.task.state == .completed)
        let feed = try h.repo.recentActivity(limit: 200).map { $0.2 }
        for expected in ["Task created", "Plan created: 5 steps", "step 3/5 passed", "Repairing after a failed test", "completed"] {
            #expect(feed.contains { $0.localizedCaseInsensitiveContains(expected) }, "activity feed lacks “\(expected)”: \(feed.prefix(12))")
        }
        // each run has agent-started/tool/validation events in ITS console, and the run knows its provider/model and task
        let coding = try #require(h.hub.runs.values.first { $0.agentType == "CodingAgent" })
        #expect(coding.taskID == view.id && coding.model == "opencode/free-1" && coding.engine == .openCode)
        let toolRun = try #require(h.hub.runs.values.first { $0.engine == .tool })
        let kinds = h.hub.consoleSnapshot(toolRun.id).events.map(\.kind)
        #expect(kinds.contains(.agentStarted) && kinds.contains(.toolStarted) && kinds.contains(.toolFinished))
        let persisted = try h.repo.agentRuns(taskID: view.id)
        #expect(persisted.contains { $0.agentType == "CodingAgent" && $0.filesChanged == ["calc.py"] } && persisted.filter { $0.agentType == "CodingAgent" }.count == 2)
    }

    @Test func escalationIsVisibleOnTheRunsThatWereEscalatedFrom() async throws {
        let h = TaskHarness(script: Scripts.standard(coding: Scripts.operators(["-", "*", "/", "+"])))
        let view = await h.run(project: TaskFixtures.calculatorProject())
        #expect(view.task.state == .completed)
        h.hub.flushPersistNow()
        let codingRuns = try h.repo.agentRuns(taskID: view.id).filter { $0.agentType == "CodingAgent" }.sorted { $0.startedAt < $1.startedAt }
        #expect(codingRuns.map(\.engine) == [.openCode, .openCode, .claudeCode])
        let beforeEscalation = try h.repo.events(runID: codingRuns[1].id)
        #expect(beforeEscalation.contains { $0.kind == .escalation }, "the run that failed last records that it was escalated away from")
    }

    // MARK: Progress across states (never from provider text)

    @Test func progressIsExactlyValidatedStepsInEveryState() async throws {
        // waiting for approval: 1 of 2 validated
        let h = TaskHarness(script: Scripts.standard(plan: "{\"summary\":\"rm\",\"steps\":[{\"id\":\"s1\",\"title\":\"Inspect\",\"description\":\"read\",\"type\":\"analysis\",\"dependsOn\":[],\"expected\":\"x\",\"validation\":\"structuredResult\"},{\"id\":\"s2\",\"title\":\"Delete\",\"description\":\"rm\",\"type\":\"delete\",\"dependsOn\":[\"s1\"],\"expected\":\"x\",\"validation\":\"fileRemoved\",\"risk\":\"high\",\"targets\":[\"old/legacy.py\"]}]}"))
        let project = TaskFixtures.calculatorProject()
        TaskFixtures.write("old/legacy.py", "x\n", in: project)
        let id = await h.submit("Remove the legacy module", project: project, destructive: true)
        #expect(await h.waitUntil { !h.engine.pendingApprovals.isEmpty })
        #expect(h.task(id).progressFraction == 0.5 && h.task(id).progressSource == .structuredSteps)
        h.engine.cancel(id); await h.engine.waitUntilFinished(id)
        #expect(h.task(id).progressFraction == 0.5, "stopped after 1 of 2 validated steps")

        // interrupted at the review step: 4 of 5
        let h2 = TaskHarness()
        let base = Scripts.standard()
        h2.runner.script = { job, i in job.type == "ReviewAgent" ? .block : await base(job, i) }
        let id2 = await h2.submit(project: TaskFixtures.calculatorProject())
        #expect(await h2.waitUntil { h2.runner.jobs("ReviewAgent").count == 1 })
        #expect(h2.task(id2).progressFraction == 0.8)
        h2.engine.prepareForTermination(); await h2.engine.waitUntilIdle()
        #expect(h2.task(id2).progressFraction == 0.8 && h2.task(id2).state == .interrupted)

        // before a plan exists there is no percentage at all
        let h3 = TaskHarness()
        h3.runner.script = { _, _ in .block }
        let id3 = await h3.submit(project: TaskFixtures.calculatorProject())
        #expect(await h3.waitUntil { h3.runner.jobs("PlannerAgent").count == 1 })
        #expect(h3.task(id3).progressFraction == nil && h3.task(id3).progressSource == .unknown && h3.engine.view(id3)?.steps.isEmpty == true)
        h3.engine.cancel(id3); await h3.engine.waitUntilFinished(id3)

        // completed: 5 of 5
        let h4 = TaskHarness()
        let v4 = await h4.run(project: TaskFixtures.calculatorProject())
        #expect(h4.task(v4.id).progressFraction == 1)
    }

    @Test func aSkippedStepIsNotMeasurableWork() async throws {
        let plan = "{\"summary\":\"x\",\"steps\":[{\"id\":\"s1\",\"title\":\"Build\",\"description\":\"b\",\"type\":\"build\",\"dependsOn\":[],\"expected\":\"x\",\"validation\":\"buildPass\"},{\"id\":\"s2\",\"title\":\"Inspect\",\"description\":\"i\",\"type\":\"analysis\",\"dependsOn\":[\"s1\"],\"expected\":\"x\",\"validation\":\"structuredResult\"}]}"
        let h = TaskHarness(script: Scripts.standard(plan: plan))
        let view = await h.run(project: TaskFixtures.calculatorProject())      // the Python fixture has no build command
        #expect(view.task.state == .completed && view.steps.map(\.state) == [.skipped, .passed])
        #expect(view.task.progressFraction == 1, "1 of 1 measurable steps")
        #expect(h.engine.report(for: view.id)?.warnings.contains { $0.contains("Skipped") } == true)
    }



    @Test func anExplicitProviderChoiceAtSubmissionNeverEscalatesAndReachesEveryJob() async throws {
        let h = TaskHarness(script: Scripts.standard(coding: Scripts.operators(["-", "*", "/", "%"])))
        let project = TaskFixtures.calculatorProject()
        guard case .success(let id) = await h.engine.submit(goal: "Fix the failing calculation test", kind: .development, workspacePath: project, preference: .claudeCode) else { Issue.record("submit failed"); return }
        await h.engine.waitUntilFinished(id)
        #expect(h.task(id).state == .failed && h.task(id).preference == .claudeCode)
        #expect(h.runner.jobs.allSatisfy { $0.job.preference == .claudeCode }, "the chosen mode is passed to every routing decision")
        #expect(h.runner.jobs("CodingAgent").count == 2, "primary + one same-engine repair; an explicit choice never escalates")
    }

    // MARK: Scheduling

    @Test func dependenciesGateStartsAndOnlyReadOnlyAnalysisStepsRunSideBySide() async throws {
        let plan = """
        {"summary":"x","steps":[
         {"id":"s1","title":"Inspect A","description":"a","type":"analysis","dependsOn":[],"expected":"x","validation":"structuredResult"},
         {"id":"s2","title":"Inspect B","description":"b","type":"analysis","dependsOn":[],"expected":"x","validation":"structuredResult"},
         {"id":"s3","title":"Combine","description":"c","type":"analysis","dependsOn":["s1","s2"],"expected":"x","validation":"structuredResult"}]}
        """
        let h = TaskHarness()
        var concurrentlyStarted = 0, maxConcurrent = 0, running = 0
        h.runner.script = { job, _ in
            if job.type == "PlannerAgent" { return .text(plan) }
            running += 1; concurrentlyStarted += 1; maxConcurrent = max(maxConcurrent, running)
            // the first two analysis jobs wait for each other (proves they really overlap); the third must come after both
            let deadline = Date().addingTimeInterval(2)
            while concurrentlyStarted < 2 && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            try? await Task.sleep(for: .milliseconds(40))
            running -= 1
            return .text(Scripts.analysis)
        }
        let view = await h.run("Analyze the calculator", project: TaskFixtures.calculatorProject(), kind: .readOnlyAnalysis)
        #expect(view.task.state == .completed && maxConcurrent == 2, "s1 and s2 overlapped (max \(maxConcurrent))")
        let steps = h.steps(view.id)
        let s3 = try #require(steps.first { $0.key == "s3" })
        #expect(steps.filter { $0.key != "s3" }.allSatisfy { ($0.finishedAt ?? .distantFuture) <= (s3.startedAt ?? .distantPast) }, "s3 started only after BOTH dependencies passed")
    }

    @Test func writingAndTestingStepsNeverRunAlongsideOtherSteps() async throws {
        let plan = """
        {"summary":"x","steps":[
         {"id":"s1","title":"Inspect","description":"a","type":"analysis","dependsOn":[],"expected":"x","validation":"structuredResult"},
         {"id":"s2","title":"Fix","description":"b","type":"codeChange","dependsOn":[],"expected":"x","validation":"changedFiles"},
         {"id":"s3","title":"Run tests","description":"c","type":"test","dependsOn":[],"expected":"x","validation":"testEvidence"}]}
        """
        let h = TaskHarness()
        var overlap = false, running = 0
        let base = Scripts.standard(plan: plan)
        h.runner.script = { job, i in
            if job.type != "PlannerAgent" { running += 1; if running > 1 { overlap = true }; defer { running -= 1 }; try? await Task.sleep(for: .milliseconds(60)); return await base(job, i) }
            return await base(job, i)
        }
        let view = await h.run(project: TaskFixtures.calculatorProject())
        #expect(view.task.state == .completed && !overlap, "independent steps still ran one at a time when one of them writes/tests")
    }

    @Test func theEngineNeverPollsOrTicks() {
        for (path, text) in allSwiftSources(under: "Sources/Jarvis/Tasks") where !path.hasSuffix("TaskBridge.swift") {
            // The ONLY sleep is the one-shot deadline of a build/test command (CommandRunner's timeout watchdog), cancelled when the command ends.
            for bad in ["Task.sleep", "Timer.", "asyncAfter", "scheduledTimer"] where !(bad == "Task.sleep" && path.hasSuffix("CommandProfiles.swift")) {
                #expect(!text.contains(bad), "\(path) contains \(bad): scheduling must be event-driven")
            }
        }
    }

    // MARK: The engine has no unrestricted power (source-level proof next to verify.sh)

    @Test func theProductSourcesContainNoShellCredentialOrApiOperations() {
        let sources = allSwiftSources(under: "Sources")
        #expect(sources.count > 50)
        for (path, text) in sources {
            for bad in ["\"/bin/sh\"", "\"/bin/bash\"", "\"/bin/zsh\"", "credential.list", "credential.get", "integration.list", "api.openai.com", "api.anthropic.com"] {
                #expect(!text.contains(bad), "\(path) contains \(bad)")
            }
        }
        let tasks = allSwiftSources(under: "Sources/Jarvis/Tasks")
        #expect(tasks.count >= 12)
        for (path, text) in tasks where !path.hasSuffix("TaskPlan.swift") {
            for bad in ["Process()", "NSTask", "posix_spawn", "system(", "popen(", "\"sh\", \"-c\"", "git push", "reset --hard", "clean -fd"] {
                #expect(!text.contains(bad), "\(path) contains \(bad)")
            }
        }
        // the tool surface offers read / write-edit / delete / hash / list / search only
        let tools = tasks.first { $0.path.hasSuffix("ProjectTools.swift") }?.text ?? ""
        #expect(!tools.contains("func run") && !tools.contains("func exec") && !tools.contains("func shell"))
    }

    @Test func providerFlagsStillForbidProviderSideWrites() {
        let sources = allSwiftSources(under: "Sources")
        for (path, text) in sources where !path.hasSuffix("ProviderEnvironment.swift") {
            for bad in ["workspace-write", "danger-full-access", "bypassPermissions", "--dangerously", "--full-auto"] { #expect(!text.contains(bad), "\(path) contains \(bad)") }
        }
    }

    @Test func theUIDoesNotWriteTaskState() {
        for (path, text) in allSwiftSources(under: "Sources/Jarvis/UI") {
            #expect(!text.contains("app.repository") && !text.contains("repository?.update") && !text.contains(".setTaskStatus"), "\(path) touches storage")
            #expect(!text.contains("TaskStateMachine"), "\(path) must not drive state machines")
        }
    }
}
