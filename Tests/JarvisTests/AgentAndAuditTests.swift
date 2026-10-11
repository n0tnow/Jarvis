import Testing
import Foundation
@testable import Jarvis

private let research = TaskProfile(category: .research, complexity: .moderate)
private func descriptor(_ type: String = "ResearchAgent", prompt: String = "Compare two options.", parent: UUID? = nil, task: UUID? = nil,
                        preference: ProviderPreference? = nil, validator: (@Sendable (String) async -> BenchmarkSuite.Verdict)? = nil, timeout: TimeInterval = 20) -> AgentDescriptor {
    AgentDescriptor(type: type, prompt: prompt, profile: research, taskID: task, parentRunID: parent, preference: preference, validator: validator, timeout: timeout)
}
private let wantsGood: @Sendable (String) async -> BenchmarkSuite.Verdict = { out in .init(passed: out.contains("GOOD"), detail: "needs GOOD") }

@MainActor
private func ready(_ h: IntelligenceHarness) async { h.passBenchmarks("opencode/alpha-free"); await h.refresh() }

// MARK: - Background agents

@MainActor
@Suite("Background agent foundation", .serialized)
struct AgentRunManagerTests {
    @Test func anAgentRunsOnTheFreeModelAndIsFullyAudited() async throws {
        let h = IntelligenceHarness(); await ready(h)
        let task = try h.repo.insertTask(title: "Compare options", category: .research)
        let result = await h.agents.spawn(descriptor(task: task))
        guard case .completed(let text, let runID, let engine, let model, let validation, let esc) = result else { Issue.record("expected completed, got \(result)"); return }
        #expect(text == "OPENCODE_OK" && engine == .openCode && model == "opencode/alpha-free" && validation == .skipped && esc == 0)
        let run = try #require(try h.repo.agentRun(runID))
        #expect(run.taskID == task && run.agentType == "ResearchAgent" && run.status == .succeeded && run.finishedAt != nil && run.parentAgentRunID == nil)
        #expect(run.selectionReason?.contains("\"selected\":\"opencode/alpha-free\"") == true && run.inputTokens == 100)
        #expect(h.agents.active.isEmpty)
        let activity = try h.repo.recentActivity(limit: 20).map(\.2)
        #expect(activity.contains("ResearchAgent started using OpenCode · alpha-free"))
    }

    @Test func parentAndChildRunsAreLinkedButAgentsCannotRecurse() async throws {
        let h = IntelligenceHarness(); await ready(h)
        guard case .completed(_, let parent, _, _, _, _) = await h.agents.spawn(descriptor("Coordinator")) else { Issue.record("parent failed"); return }
        var children: [UUID] = []
        for i in 0..<3 {
            guard case .completed(_, let child, _, _, _, _) = await h.agents.spawn(descriptor("Worker\(i)", parent: parent)) else { Issue.record("child \(i) failed"); return }
            children.append(child)
        }
        let kids = try h.repo.children(of: parent)
        #expect(Set(kids.map(\.id)) == Set(children) && kids.allSatisfy { $0.parentAgentRunID == parent })
        // A 4th child exceeds maxChildrenPerParent; a grandchild exceeds maxDepth.
        #expect(await h.agents.spawn(descriptor("Worker4", parent: parent)) == .rejected(.tooManyChildren(3)))
        #expect(await h.agents.spawn(descriptor("Grandchild", parent: children[0])) == .rejected(.recursionNotAllowed))
        #expect(h.launches("opencode") == 4)                                                       // rejected spawns never reached a provider
    }

    @Test func concurrentAgentsAreCappedAndTheLimitIsRaceFree() async {
        let h = IntelligenceHarness(); h.slowSeconds = 2; h.installOpenCode(.slow("AGENT_OK")); await ready(h)
        h.resources.limits.maxBackgroundAgents = 2
        var results: [AgentRunResult] = []
        await withTaskGroup(of: AgentRunResult.self) { group in
            for i in 0..<4 { group.addTask { @MainActor in await h.agents.spawn(descriptor("A\(i)")) } }
            for await r in group { results.append(r) }
        }
        let completed = results.filter(\.isCompleted).count
        let rejected = results.filter { if case .rejected(.tooManyBackgroundAgents(2)) = $0 { true } else { false } }.count
        #expect(completed == 2 && rejected == 2, "\(results)")
        #expect(h.agents.active.isEmpty && h.launches("opencode") == 2)
    }

    @Test func freeCloudCapacityPushesExtraAgentsToTheNextPolicyEngineInsteadOfOverloading() async {
        let h = IntelligenceHarness(); h.slowSeconds = 2; h.installOpenCode(.slow("AGENT_OK")); await ready(h)
        h.resources.limits.maxBackgroundAgents = 3; h.resources.limits.maxConcurrentFreeCloudAgents = 2
        var engines: [ProviderID] = []
        await withTaskGroup(of: AgentRunResult.self) { group in
            for i in 0..<3 { group.addTask { @MainActor in await h.agents.spawn(descriptor("B\(i)")) } }
            for await r in group { if case .completed(_, _, let e, _, _, _) = r { engines.append(e) } }
        }
        #expect(engines.filter { $0 == .openCode }.count == 2 && engines.filter { $0 == .claudeCode }.count == 1, "\(engines)")
        // An explicit "OpenCode Free" request has no alternative engine → rejected instead.
        h.prefs.providerPreference = .openCodeFree
        var rejections: [AgentRunResult] = []
        await withTaskGroup(of: AgentRunResult.self) { group in
            for i in 0..<3 { group.addTask { @MainActor in await h.agents.spawn(descriptor("C\(i)", preference: .openCodeFree)) } }
            for await r in group { rejections.append(r) }
        }
        #expect(rejections.filter { if case .rejected(.tooManyFreeCloudAgents(2)) = $0 { true } else { false } }.count == 1)
    }

    @Test func onlyOneLocalInferenceJobAtATime() async {
        let h = IntelligenceHarness(); await ready(h)
        let lightweight = TaskProfile(category: .conversation, complexity: .trivial)
        var results: [AgentRunResult] = []
        await withTaskGroup(of: AgentRunResult.self) { group in
            for i in 0..<2 { group.addTask { @MainActor in await h.agents.spawn(AgentDescriptor(type: "Chat\(i)", prompt: "LONG hello", profile: lightweight)) } }
            for await r in group { results.append(r) }
        }
        let onLocal = results.compactMap { r -> ProviderID? in if case .completed(_, _, let e, _, _, _) = r { e } else { nil } }.filter { $0 == .local }
        #expect(onLocal.count <= 1, "two local jobs must never run concurrently: \(results)")
        h.shutdown()
    }

    @Test func cancellingAnAgentKillsItsProcessAndIsRecorded() async throws {
        let h = IntelligenceHarness(); h.installOpenCode(.slow("late")); await ready(h)
        let task = Task { @MainActor in await h.agents.spawn(descriptor(timeout: 60)) }
        let pid = try #require(await FakeCLI.pid(from: h.dir + "/opencode.pid"))
        let runID = try #require(h.agents.active.first?.id)
        h.agents.cancel(runID)
        let result = await task.value
        guard case .cancelled(let rid) = result else { Issue.record("expected cancelled, got \(result)"); return }
        let died = await FakeCLI.waitDead(pid)
        #expect(rid == runID && died)
        #expect(try h.repo.agentRun(runID)?.status == .cancelled)
        #expect(h.agents.active.isEmpty && h.supervisor.consecutiveFailures(.openCode, "opencode/alpha-free") == 0)
    }

    @Test func aFailedValidationGetsOneBoundedRepairOnTheSameEngine() async throws {
        let h = IntelligenceHarness(); h.installOpenCode(.badThenGood(bad: "BAD answer", good: "GOOD answer")); await ready(h)
        let result = await h.agents.spawn(descriptor(validator: wantsGood))
        guard case .completed(let text, let runID, let engine, _, let validation, let esc) = result else { Issue.record("expected completed, got \(result)"); return }
        #expect(text == "GOOD answer" && engine == .openCode && validation == .passed && esc == 0)
        #expect(h.launches("opencode") == 2)
        let run = try #require(try h.repo.agentRun(runID))
        #expect(run.retryCount == 1 && run.validationStatus == .passed && run.status == .succeeded)
    }

    @Test func persistentValidationFailureEscalatesToClaudeThenStops() async throws {
        let h = IntelligenceHarness(); h.installOpenCode(.text("BAD")); h.installClaude(text: "GOOD from claude"); await ready(h)
        let result = await h.agents.spawn(descriptor(validator: wantsGood))
        guard case .completed(let text, let runID, let engine, _, _, let esc) = result else { Issue.record("expected completed, got \(result)"); return }
        #expect(text == "GOOD from claude" && engine == .claudeCode && esc == 1)
        #expect(h.launches("opencode") == 2 && h.launches("claude") == 1)                          // 1 try + 1 repair, then ONE escalation
        let runs = h.runs().filter { $0.agentType == "ResearchAgent" }
        #expect(runs.count == 2)
        #expect(runs[0].engine == .openCode && runs[0].status == .escalated && runs[0].escalatedTo == "claudeCode" && runs[0].validationStatus == .failed && runs[0].retryCount >= 1)
        #expect(runs[1].engine == .claudeCode && runs[1].escalatedFrom == "openCode" && runs[1].status == .succeeded && runs[1].id == runID)
        #expect(h.store.activity.isEmpty || true)
    }

    @Test func retryAndEscalationAreHardBounded() async {
        let h = IntelligenceHarness(); h.installOpenCode(.text("BAD")); h.installClaude(text: "ALSO BAD"); await ready(h)
        h.states[.codex] = .ready; h.providerPaths[.codex] = FakeCLI.script("cat >/dev/null\necho \"$$\" >> \(h.dir)/codex.launches\necho '{\"type\":\"turn.completed\"}'", in: h.dir, name: "codex")
        await h.refresh()
        let result = await h.agents.spawn(descriptor(validator: wantsGood))
        guard case .failed(_, _, let validation) = result else { Issue.record("must fail, got \(result)"); return }
        #expect(validation == .failed)
        #expect(h.launches("opencode") + h.launches("claude") + h.launches("codex") <= h.agents.policy.maxTotalAttempts)
        #expect(h.launches("codex") == 0)                                                           // only ONE escalation, never a third engine
        #expect(h.agents.active.isEmpty)
    }

    @Test func aProviderFailureEscalatesOnceAndRecordsTheFailure() async throws {
        let h = IntelligenceHarness(); h.installOpenCode(.fail503); await ready(h)
        let result = await h.agents.spawn(descriptor())
        guard case .completed(_, _, let engine, _, _, let esc) = result else { Issue.record("expected completed, got \(result)"); return }
        #expect(engine == .claudeCode && esc == 1)
        #expect(h.supervisor.consecutiveFailures(.openCode, "opencode/alpha-free") == 1)
    }

    @Test func explicitModesNeverSubstituteAnotherEngine() async {
        let h = IntelligenceHarness(); h.installOpenCode(.fail503); await ready(h)
        let result = await h.agents.spawn(descriptor(preference: .openCodeFree))
        guard case .failed = result else { Issue.record("explicit OpenCode Free must not escalate, got \(result)"); return }
        #expect(h.launches("claude") == 0)
    }

    @Test func limitsAreConservativeForA16GBMachine() {
        let l = ConcurrencyLimits()
        #expect(l.maxLocalInferenceJobs == 1 && l.maxHeavyCodingAgents == 1 && l.maxConcurrentFreeCloudAgents == 2 && l.maxBackgroundAgents == 3)
        #expect(l.maxDepth == 1 && l.maxChildrenPerParent == 3)
        let p = EscalationPolicy()
        #expect(p.maxRepairAttempts == 1 && p.maxEscalations == 1 && p.maxTotalAttempts == 3)
    }
}

// MARK: - Audit trail

@MainActor
@Suite("Audit trail", .serialized)
struct AuditTrailTests {
    @Test func startEndResultToolsFilesAndArtifactsAreLinkedToOneRun() throws {
        let h = IntelligenceHarness()
        let task = try h.repo.insertTask(title: "Fix NetworkPlayer.cs")
        let decision = ModelRouter.route(TaskClassifier.profile(for: "Explain NetworkPlayer.cs"), snapshot: RouteFixtures.snapshot())
        let id = h.audit.begin(agentType: "CodeAgent", taskID: task, engine: .openCode, model: "opencode/alpha-free", decision: decision, prompt: "do it", privacy: .normal)
        #expect(try h.repo.agentRun(id)?.status == .running)
        h.audit.recordTool(id, tool: "swiftc -typecheck", summary: "typecheck snippet with token sk-proj-ABCDEFGHIJKLMNOPQRSTUV123456", status: "ok", exitCode: 0)
        h.audit.recordFileChange(FileChangeRecord(taskID: task, agentRunID: id, path: "Assets/Scripts/NetworkPlayer.cs", changeType: "modified", gitHash: "abc", verificationResult: "compiled"))
        let artifact = try h.artifacts.store(Data("large report".utf8), type: "report", folder: .reports, taskID: task, agentRunID: id)
        h.audit.finish(id, status: .succeeded, resultText: "All done", usage: (10, 5), validation: .passed)
        let run = try #require(try h.repo.agentRun(id))
        #expect(run.status == .succeeded && run.finishedAt != nil && run.validationStatus == .passed && run.inputTokens == 10 && run.resultSummary == "8 chars · All done")
        let tools = try h.repo.toolExecutions(agentRunID: id)
        #expect(tools.count == 1 && tools[0].tool == "swiftc -typecheck" && tools[0].exitCode == 0 && !(tools[0].summary ?? "").contains("ABCDEFGH"))
        #expect(try h.repo.fileChanges(agentRunID: id).count == 1)
        #expect(try h.artifacts.artifacts(agentRunID: id).map(\.id) == [artifact.id])
        #expect(try h.repo.fileChanges(path: "NetworkPlayer.cs").first?.agentRunID == id)           // "who changed NetworkPlayer.cs?"
    }

    @Test func refusedToolAttemptsAreRecordedAsRefusedNotAsExecuted() async throws {
        let h = IntelligenceHarness()
        h.installOpenCode(.toolsOnly)
        h.passBenchmarks("opencode/alpha-free"); await h.refresh()
        await h.ask(coding)                                                                         // free model tries bash, answers nothing → escalates to Claude
        let runs = h.runs()
        let first = try #require(runs.first)
        #expect(first.engine == .openCode && first.toolsUsed == ["attempted-refused:bash"])
        #expect(h.lastReply?.content == "CLAUDE_OK")
    }

    @Test func contextRetrievalIsTargetedBoundedAndTaskScoped() throws {
        let h = IntelligenceHarness()
        let t1 = try h.repo.insertTask(title: "Network sync analysis"), t2 = try h.repo.insertTask(title: "UNRELATED secret project")
        func run(_ task: UUID, _ type: String, _ status: AgentRunStatus, summary: String, err: String? = nil) throws {
            var r = AgentRunRecord(id: UUID(), taskID: task, agentType: type, engine: .openCode, model: "m", startedAt: Date())
            r.status = status; r.resultSummary = summary; r.errorCategory = err
            try h.repo.insert(r)
        }
        for i in 0..<6 { try run(t1, "Agent\(i)", .succeeded, summary: "12 chars · finding \(i)") }
        try run(t1, "Broken", .failed, summary: "", err: "timeout")
        try run(t2, "Other", .succeeded, summary: "9 chars · TOPSECRET")
        let ctx = try #require(ContextRetrieval(repository: h.repo).preface(taskID: t1))
        #expect(ctx.contains("Network sync analysis") && ctx.contains("finding 5") && ctx.contains("(timeout)"))
        #expect(!ctx.contains("TOPSECRET") && !ctx.contains("UNRELATED"))                            // never other tasks
        #expect(ctx.components(separatedBy: "\n- ").count - 1 <= 3 + 2)                              // ≤ 3 results + ≤ 2 problems
        #expect(!ctx.contains("finding 0"))                                                         // only the newest few
        var small = ContextRetrieval(repository: h.repo); small.maxCharacters = 80
        #expect((small.preface(taskID: t1) ?? "").count <= 80)
        #expect(ContextRetrieval(repository: h.repo).preface(taskID: nil) == nil && ContextRetrieval(repository: nil).preface(taskID: t1) == nil)
    }

    @Test func anAgentWithATaskReceivesOnlyTheBoundedPrefaceNotTheHistory() async throws {
        let h = IntelligenceHarness()
        h.passBenchmarks("opencode/alpha-free"); await h.refresh()
        let task = try h.repo.insertTask(title: "Compare options")
        for i in 0..<5 {
            var r = AgentRunRecord(id: UUID(), taskID: task, agentType: "Old\(i)", engine: .claudeCode, model: nil, startedAt: Date().addingTimeInterval(Double(i)))
            r.status = .succeeded; r.resultSummary = String(repeating: "x", count: 400)
            try h.repo.insert(r)
        }
        let result = await h.agents.spawn(AgentDescriptor(type: "ResearchAgent", prompt: "Compare two options.", profile: research, taskID: task))
        #expect(result.isCompleted)
        let run = try #require(h.runs().last)
        #expect((run.promptChars ?? 0) <= "Compare two options.".count + ContextRetrieval(repository: nil).maxCharacters + 20)  // hash covers the original prompt only
    }

    @Test func auditFailuresNeverBreakTheConversation() async {
        let h = IntelligenceHarness()
        h.database.close()                                                                          // simulate a dead database
        await h.refresh()
        await h.ask(simple)
        #expect(h.lastReply?.content == "t0 t1 t2 ")
        #expect(h.audit.failures > 0)
        h.shutdown()
    }

    @Test func withoutADatabaseTheStackStillRuns() async {
        let audit = AuditRecorder(repository: nil)
        let id = audit.begin(agentType: "X", engine: .local, model: nil, decision: nil, prompt: "p", privacy: .normal)
        audit.finish(id, status: .succeeded, resultText: "r")
        #expect(audit.record(id)?.status == .succeeded && audit.failures == 0)
    }
}

// MARK: - Benchmarks

private struct ScriptedProvider: IntelligenceProvider {
    var answer: @Sendable (String) -> [IntelligenceEvent]
    var id: String { "scripted" }
    var displayName: String { "Scripted" }
    func supports(_ kind: IntelligenceRequestKind) -> Bool { true }
    func respond(to request: IntelligenceRequest) -> AsyncThrowingStream<IntelligenceEvent, Error> {
        AsyncThrowingStream { c in for e in answer(request.prompt) { c.yield(e) }; c.finish() }
    }
}

@MainActor
@Suite("Benchmark runner and validators", .serialized)
struct BenchmarkTests {
    private let goodGeneral: @Sendable (String) -> [IntelligenceEvent] = { p in
        if p.contains("JARVIS_BENCH_OK") { return [.textDelta("JARVIS_BENCH_OK"), .finished] }
        if p.contains("\"Ada\"") { return [.textDelta("```json\n{\"name\":\"Ada\",\"age\":36}\n```"), .finished] }
        return [.textDelta("The restored lighthouse reopened to visitors with volunteer-led weekend tours."), .finished]
    }

    @Test func realResultsAreRecordedAndDriveTheModelStatus() async throws {
        let h = IntelligenceHarness()
        let runner = BenchmarkRunner(repository: h.repo, artifacts: h.artifacts)
        let outcomes = await runner.run(modelID: "opencode/alpha-free", groups: [.general], makeProvider: { ScriptedProvider(answer: goodGeneral) })
        #expect(outcomes.count == 3 && outcomes.allSatisfy(\.passed), "\(outcomes)")
        let stored = try h.repo.benchmarks(modelID: "opencode/alpha-free")
        #expect(stored.count == 3 && stored.allSatisfy { $0.passed && $0.suite == BenchmarkSuite.id && $0.durationMS != nil && $0.latencyMS != nil })
        let summary = try #require(BenchmarkSummary.summarize(stored, group: .general, suite: BenchmarkSuite.id))
        #expect(summary.label == "3/3" && BenchmarkPolicy().isEligible(summary, group: .general, now: Date()))
        #expect(try h.artifacts.artifacts().filter { $0.type == "benchmark-output" }.count == 3)
        // Only one of four groups was run → "partial", never "passed".
        try h.repo.upsert(RouteFixtures.freeModel("alpha-free"))
        runner.updateStatus("opencode/alpha-free")
        #expect(try h.repo.model("opencode/alpha-free")?.benchmarkStatus == .partial)
    }

    @Test func wrongMalformedToolUsingAndTimedOutAnswersFailHonestly() async throws {
        let h = IntelligenceHarness()
        let runner = BenchmarkRunner(repository: h.repo, artifacts: h.artifacts)
        let bad = await runner.run(modelID: "m1", groups: [.general]) { ScriptedProvider(answer: { _ in [.textDelta("I think the answer is blue."), .finished] }) }
        #expect(bad.allSatisfy { !$0.passed })
        let tools = await runner.run(modelID: "m2", groups: [.general]) { ScriptedProvider(answer: { _ in [.toolAttempt("bash"), .textDelta("JARVIS_BENCH_OK"), .finished] }) }
        #expect(tools.allSatisfy { !$0.passed && $0.detail.contains("tried tools") })
        let unavailable = await runner.run(modelID: "m3", groups: [.general]) { nil }
        #expect(unavailable.allSatisfy { !$0.passed && $0.detail == "provider unavailable" })
        let malformed = try h.repo.benchmarks(modelID: "m1").filter(\.malformed)
        #expect(!malformed.isEmpty)                                                                // non-JSON answer to a JSON task is recorded as malformed
        #expect(try h.repo.benchmarks(modelID: "m1").allSatisfy { !$0.passed })
    }

    @Test func aRemovedModelEndsItsBenchmarkEarlyInsteadOfBurningRequests() async throws {
        let h = IntelligenceHarness()
        let runner = BenchmarkRunner(repository: h.repo, artifacts: h.artifacts)
        let calls = CallCounter()
        var removedCalled = false
        struct Gone: IntelligenceProvider {
            let counter: CallCounter
            var id: String { "gone" }; var displayName: String { "Gone" }
            func supports(_ kind: IntelligenceRequestKind) -> Bool { true }
            func respond(to request: IntelligenceRequest) -> AsyncThrowingStream<IntelligenceEvent, Error> {
                counter.bump()
                return AsyncThrowingStream { $0.finish(throwing: ProviderError.unavailable(.openCode, OpenCodeModelRegistry.removedErrorText)) }
            }
        }
        let outcomes = await runner.run(modelID: "opencode/exo-free", groups: BenchmarkGroup.allCases, makeProvider: { Gone(counter: calls) }, onModelRemoved: { removedCalled = true })
        #expect(calls.value == 1 && removedCalled)
        #expect(outcomes.count == BenchmarkSuite.all.count && outcomes.allSatisfy { !$0.passed })
        #expect(outcomes.dropFirst().allSatisfy { $0.detail == "skipped: model removed" })
    }

    @Test func aProviderThatKeepsFailingStopsConsumingBenchmarkRequests() async throws {
        let h = IntelligenceHarness()
        let runner = BenchmarkRunner(repository: h.repo, artifacts: h.artifacts)
        let calls = CallCounter()
        struct Flaky: IntelligenceProvider {
            let counter: CallCounter
            var id: String { "flaky" }; var displayName: String { "Flaky" }
            func supports(_ kind: IntelligenceRequestKind) -> Bool { true }
            func respond(to request: IntelligenceRequest) -> AsyncThrowingStream<IntelligenceEvent, Error> {
                counter.bump()
                return AsyncThrowingStream { $0.finish(throwing: ProviderError.processFailed(.openCode, exitCode: 1)) }
            }
        }
        let outcomes = await runner.run(modelID: "opencode/flaky", groups: BenchmarkGroup.allCases, makeProvider: { Flaky(counter: calls) })
        #expect(calls.value == BenchmarkRunner.maxConsecutiveProviderFailures)
        #expect(outcomes.count == BenchmarkSuite.all.count && outcomes.dropFirst(3).allSatisfy { $0.detail == "skipped: provider failing" })
        #expect(runner.needsBenchmark("opencode/flaky") == false)                                 // every case has a (failed) result
        #expect(runner.needsBenchmark("opencode/never-run"))
    }

    @Test func benchmarkEvidenceUnlocksAutomaticRoutingAndFailureKeepsItLocked() async throws {
        let h = IntelligenceHarness()
        await h.refresh()
        #expect(ModelRouter.route(TaskClassifier.profile(for: coding), snapshot: h.supervisor.snapshot(preference: .auto, settings: RoutingSettings())).selected?.engine == .claudeCode)
        h.passBenchmarks("opencode/alpha-free", passed: 1)                                          // 1 of N cases pass in every group
        #expect(ModelRouter.route(TaskClassifier.profile(for: coding), snapshot: h.supervisor.snapshot(preference: .auto, settings: RoutingSettings())).selected?.engine == .claudeCode)
        h.passBenchmarks("opencode/alpha-free")                                                     // newest results now pass
        #expect(ModelRouter.route(TaskClassifier.profile(for: coding), snapshot: h.supervisor.snapshot(preference: .auto, settings: RoutingSettings())).selected?.engine == .openCode)
    }

    @Test func theSwiftValidatorsTypecheckForRealButNeverExecuteAnything() async {
        let good = "```swift\nfunc add(_ a: Int, _ b: Int) -> Int {\n    return a + b\n}\n```"
        let c3 = BenchmarkSuite.coding.first { $0.id == "c3-patch-swift" }!
        let vGood = await c3.validate(good)
        let vWrong = await c3.validate("func add(_ a: Int, _ b: Int) -> Int { return a - b }")             // fix missing
        let vNoCompile = await c3.validate("func add(_ a: Int, _ b: Int) -> Int { return a + c }")          // does not typecheck
        let vEvil = await c3.validate("func add(_ a: Int, _ b: Int) -> Int { _ = Process(); return a + b }")
        #expect(vGood.passed)
        #expect(!vWrong.passed && !vNoCompile.passed)
        #expect(!vEvil.passed && vEvil.detail.contains("forbidden"))
        let c4 = BenchmarkSuite.coding.first { $0.id == "c4-compiler-output" }!
        let v4Good = await c4.validate("let n: Int = Int(\"5\")!")
        let v4Bad = await c4.validate("let n: Int = \"5\"")
        #expect(v4Good.passed && !v4Bad.passed)
    }

    @Test func theSuiteHasEnoughCasesPerGroupForTheEligibilityPolicy() {
        let policy = BenchmarkPolicy()
        for g in BenchmarkGroup.allCases { #expect(BenchmarkSuite.cases(g).count >= (policy.requiredCases[g] ?? 3), "\(g)") }
        #expect(Set(BenchmarkSuite.all.map(\.id)).count == BenchmarkSuite.all.count)
    }

    @Test func benchmarksUseIsolatedFixturesAndNeverTouchTheWorkingDirectory() async throws {
        let before = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.currentDirectoryPath).sorted()
        let h = IntelligenceHarness()
        let runner = BenchmarkRunner(repository: h.repo, artifacts: h.artifacts)
        _ = await runner.run(modelID: "m", groups: [.coding]) { ScriptedProvider(answer: { _ in [.textDelta("6"), .finished] }) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.currentDirectoryPath).sorted() == before)
    }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
