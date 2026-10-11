import Testing
import Foundation
@testable import Jarvis

// MARK: - Goal intake

@Suite("Goal intake: tasks vs conversation")
struct GoalIntakeTests {
    private func route(_ s: String) -> RouteDecision { IntelligenceRouter().route(s) }

    @Test func developmentRequestsBecomeDevelopmentTasks() {
        for text in ["Fix the multiplayer synchronization problem.", "Refactor the networking system and test it.", "Fix my Unity multiplayer system.",
                     "Implement the missing feature in the project", "multiplayer hatasını düzelt"] {
            guard case .workerRequired(let prompt, _) = route(text) else { Issue.record("not a worker request: \(text)"); continue }
            #expect(GoalIntake.development(for: prompt).kind == .development, "\(text)")
        }
    }

    @Test func deletionRequestsAreWorkNotConversation() {
        for text in ["Delete the whole old networking implementation.", "Delete the file old/legacy.py from the project", "Wipe the old multiplayer code"] {
            guard case .workerRequired(let prompt, _) = route(text) else { Issue.record("not routed as work: \(text)"); continue }
            #expect(GoalIntake.development(for: prompt).destructive)
        }
        if case .workerRequired = route("delete my email about the meeting") { Issue.record("an everyday request must stay conversation") }
    }

    @Test func destructiveWordsFlagTheGoalSoDeletionStepsMayBePlannedAndApproved() {
        #expect(GoalIntake.development(for: "Delete the whole old networking implementation.").destructive)
        #expect(GoalIntake.development(for: "Remove the legacy code from the project").destructive)
        #expect(!GoalIntake.development(for: "Fix the multiplayer synchronization problem.").destructive)
    }

    @Test func analysisRequestsAreReadOnlyTasks() {
        for text in ["Analyze the multiplayer issue.", "Investigate the networking bug", "Inspect the project for errors", "Diagnose the sync problem", "Review the codebase"] {
            #expect(GoalIntake.analysis(for: text)?.kind == .readOnlyAnalysis, "\(text)")
        }
    }

    @Test func conversationCommandsAndKnowledgeQuestionsAreNotTasks() {
        for text in ["How are you?", "Open Agents.", "Explain NetworkPlayer.", "What is a mutex?", "Write an email about the project", "Why does the multiplayer bug happen?",
                     "Tell me about the project history", "hello", "stop"] {
            #expect(GoalIntake.analysis(for: text) == nil, "\(text)")
            if case .workerRequired = route(text) { Issue.record("routed as work: \(text)") }
        }
    }

    @Test func aLongPromptIsNotATaskJustBecauseItIsLong() {
        let long = String(repeating: "This paragraph describes my afternoon walk in the park and a nice coffee. ", count: 60)
        #expect(GoalIntake.analysis(for: long) == nil)
        if case .workerRequired = route(long) { Issue.record("a long text must not become a task") }
    }
}

// MARK: - Conversation → tasks

@MainActor
private final class FakeSubmitter: TaskSubmitting {
    var hasProject = true
    var projectName: String? { hasProject ? "fixture" : nil }
    var result: TaskSubmission = .started(title: "Fix the multiplayer sync")
    private(set) var submitted: [(String, GoalIntake.Intent)] = []
    func submitTask(goal: String, intent: GoalIntake.Intent) async -> TaskSubmission {
        submitted.append((goal, intent))
        return hasProject ? result : .needsProject
    }
}

@Suite("Conversation hands tasks to the engine")
@MainActor
struct ConversationTaskRoutingTests {
    private func make() -> (ConversationService, ConversationStore, FakeSubmitter, FakeWindows) {
        let store = JarvisStore(), conv = ConversationStore(), windows = FakeWindows()
        DemoScenario.seed(store)
        let svc = ConversationService(store: store, conversation: conv, windows: windows)
        let sub = FakeSubmitter()
        svc.taskSubmitter = sub
        return (svc, conv, sub, windows)
    }

    @Test func aDevelopmentGoalCreatesATaskAndTheReplyConfirmsOnlyWhatHappened() async throws {
        let (svc, conv, sub, _) = make()
        svc.submit("Fix the multiplayer synchronization problem.")
        try await Task.sleep(for: .milliseconds(100))
        #expect(sub.submitted.count == 1 && sub.submitted[0].1.kind == .development)
        #expect(conv.last?.content.contains("created the task") == true && conv.last?.route == .worker)
    }

    @Test func withoutAProjectNothingStartsAndTheUserIsToldWhy() async throws {
        let (svc, conv, sub, _) = make()
        sub.hasProject = false
        svc.submit("Fix the multiplayer synchronization problem.")
        try await Task.sleep(for: .milliseconds(100))
        #expect(conv.last?.content.contains("project folder") == true && conv.last?.tone == .notice)
    }

    @Test func analysisBecomesAReadOnlyTaskOnlyWhenAProjectExists() async throws {
        let (svc, conv, sub, _) = make()
        svc.submit("Analyze the multiplayer issue.")
        try await Task.sleep(for: .milliseconds(100))
        #expect(sub.submitted.count == 1 && sub.submitted[0].1.kind == .readOnlyAnalysis)
        #expect(conv.last?.content.contains("inspect the project") == true)
        // no project: stays a normal reasoning request (no provider here → the usual "not connected" notice), never a task
        let (svc2, _, sub2, _) = make()
        sub2.hasProject = false
        svc2.submit("Analyze the multiplayer issue.")
        try await Task.sleep(for: .milliseconds(100))
        #expect(sub2.submitted.isEmpty)
    }

    @Test func commandsKnowledgeQuestionsAndConversationNeverReachTheEngine() async throws {
        let (svc, _, sub, windows) = make()
        for text in ["open tasks", "what are you doing?", "Explain NetworkPlayer.", "How are you?", "hello", "stop"] { svc.submit(text) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(sub.submitted.isEmpty)
        #expect(windows.calls.contains(.showFull(.tasks)))
    }

    @Test func withoutTheEngineWorkerRequestsKeepTheV03Behaviour() async throws {
        let store = JarvisStore(), conv = ConversationStore()
        DemoScenario.seed(store)
        let svc = ConversationService(store: store, conversation: conv, windows: FakeWindows())
        svc.submit("Fix my Unity multiplayer system.")
        #expect(conv.last?.content.contains("isn't enabled yet") == true)
    }
}

// MARK: - Engine ⇄ HUD (store projection, controls)

@Suite("Engine tasks drive the existing HUD surfaces", .serialized)
@MainActor
struct TaskBridgeTests {
    private func make(script: (@MainActor (AgentJob, Int) async -> ScriptedRunner.Answer)? = nil) -> (TaskHarness, JarvisStore, TaskBridge) {
        let h = TaskHarness()
        if let script { h.runner.script = script }
        let store = JarvisStore()
        DemoScenario.seed(store)                                    // the demo task exists too: the real task must win
        let bridge = TaskBridge(engine: h.engine, store: store, hub: h.hub)
        h.engine.onFinished = { [weak h, weak bridge] v in h?.finished.append(v); bridge?.finished(v) }
        h.keepAlive.append(bridge)
        return (h, store, bridge)
    }

    @Test func aRunningTaskIsProjectedWithRealProgressAndBeatsTheDemoTask() async throws {
        let base = Scripts.standard()
        let (h, store, bridge) = make(script: { job, i in job.type == "CodingAgent" ? .block : await base(job, i) })
        let id = await h.submit(project: TaskFixtures.calculatorProject())
        #expect(await h.waitUntil { h.runner.jobs("CodingAgent").count == 1 })
        bridge.sync()
        let t = try #require(store.activeTask)
        #expect(t.id == id && t.engine != nil && t.status == .running && t.steps.count == 5)
        #expect(t.completedStepCount == 2 && t.progress == 0.4 && t.engine?.progressFraction == 0.4 && t.currentStepNumber == 3)
        #expect(t.engine?.activeAgents == 1 && store.state == .working)
        #expect(store.allTasks.count == store.tasks.count + 1)
        h.engine.cancel(id); await h.engine.waitUntilFinished(id)
        #expect(store.activeTask?.engine == nil, "back to the demo task once the real one is over")
    }

    @Test func pauseIsRefusedStopCancelsThroughTheEngine() async throws {
        let base = Scripts.standard()
        let (h, store, _) = make(script: { job, i in job.type == "AnalysisAgent" ? .block : await base(job, i) })
        let id = await h.submit(project: TaskFixtures.calculatorProject())
        #expect(await h.waitUntil { h.runner.jobs("AnalysisAgent").count == 1 })
        store.pauseActiveTask()
        #expect(store.activeTask?.status == .running && store.activity.last?.message.contains("can't be paused") == true)
        let cmd = CommandExecutor(store: store, windows: FakeWindows(), clearConversation: {}, cancelGeneration: { false })
        #expect(cmd.execute(.pauseTask, language: .en).message.contains("can't be paused"))
        store.stopActiveTask()
        await h.engine.waitUntilFinished(id)
        #expect(h.task(id).state == .cancelled && store.activeTask?.engine == nil)
        #expect(store.state == .idle)
    }

    @Test func theStopCommandStopsTheRealTask() async throws {
        let base = Scripts.standard()
        let (h, store, _) = make(script: { job, i in job.type == "AnalysisAgent" ? .block : await base(job, i) })
        let id = await h.submit(project: TaskFixtures.calculatorProject())
        #expect(await h.waitUntil { h.runner.jobs("AnalysisAgent").count == 1 })
        let cmd = CommandExecutor(store: store, windows: FakeWindows(), clearConversation: {}, cancelGeneration: { false })
        let r = cmd.execute(.stopTask, language: .en)
        #expect(r.message.lowercased().contains("stopped"))
        await h.engine.waitUntilFinished(id)
        #expect(h.task(id).state == .cancelled)
    }

    @Test func approvalsReachTheHUDAndTheButtonsDecideThroughTheEngine() async throws {
        let (h, store, _) = make()
        h.runner.script = Scripts.standard(plan: "{\"summary\":\"rm\",\"steps\":[{\"id\":\"s1\",\"title\":\"Delete legacy\",\"description\":\"remove\",\"type\":\"delete\",\"dependsOn\":[],\"expected\":\"gone\",\"validation\":\"fileRemoved\",\"risk\":\"high\",\"targets\":[\"old/legacy.py\"]}]}")
        let project = TaskFixtures.calculatorProject()
        TaskFixtures.write("old/legacy.py", "x\n", in: project)
        let id = await h.submit("Remove the legacy module", project: project, destructive: true)
        #expect(await h.waitUntil { store.state == .waitingForApproval && store.pendingApproval != nil })
        #expect(store.pendingApproval?.title.contains("old/legacy.py") == true && store.activeTask?.status == .waiting)
        #expect(FileManager.default.fileExists(atPath: project + "/old/legacy.py"))
        store.clearPendingApproval()                                  // developer tools must not drop a real approval
        #expect(store.pendingApproval != nil)
        store.resolveApproval(approved: false)                        // the HUD button
        await h.engine.waitUntilFinished(id)
        #expect(h.task(id).failureCategory == .approvalDenied && FileManager.default.fileExists(atPath: project + "/old/legacy.py"))
        #expect(store.pendingApproval == nil)
    }

    @Test func aFinishedTaskShowsCompletedThenSettles() async throws {
        let (h, store, _) = make()
        _ = await h.run(project: TaskFixtures.calculatorProject())
        #expect(store.state == .completed && store.activeTask?.engine == nil)
    }

    @Test func anInterruptedTaskIsResumableFromTheHUDStore() async throws {
        let base = Scripts.standard()
        let (h, store, _) = make(script: { job, i in job.type == "ReviewAgent" ? .block : await base(job, i) })
        let id = await h.submit(project: TaskFixtures.calculatorProject())
        #expect(await h.waitUntil { h.runner.jobs("ReviewAgent").count == 1 })
        h.engine.prepareForTermination(); await h.engine.waitUntilIdle()
        h.restart(script: Scripts.standard())
        let bridge2 = TaskBridge(engine: h.engine, store: store, hub: h.hub)
        h.keepAlive.append(bridge2)
        bridge2.sync()
        let t = try #require(store.activeTask)
        #expect(t.status == .interrupted && t.engine != nil)
        store.resumeActiveTask()
        await h.engine.waitUntilFinished(id)
        #expect(h.task(id).state == .completed)
    }
}

// MARK: - Intake wiring

@Suite("TaskIntake uses the user's project folder")
@MainActor
struct TaskIntakeTests {
    @Test func needsAProjectAndNeverGuesses() async throws {
        let h = TaskHarness()
        let prefs = Preferences(defaults: UserDefaults(suiteName: "jarvis-intake-\(UUID().uuidString)")!)
        let intake = TaskIntake(engine: h.engine, preferences: prefs)
        #expect(!intake.hasProject)
        #expect(await intake.submitTask(goal: "Fix the bug", intent: .init(kind: .development, destructive: false)) == .needsProject)
        prefs.projectRoot = "/"
        #expect(!intake.hasProject, "a too-broad folder is not a project")
        prefs.projectRoot = TaskFixtures.calculatorProject()
        #expect(intake.hasProject)
        if case .started = await intake.submitTask(goal: "Fix the failing calculation test", intent: .init(kind: .development, destructive: false)) {} else { Issue.record("not started") }
        await h.engine.waitUntilIdle()
        #expect(try h.repo.count("tasks") == 1)
    }
}
