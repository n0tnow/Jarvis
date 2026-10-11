import Testing
import Foundation
@testable import Jarvis

private let askText = "Explain this Swift function: func f(_ xs: [Int]) -> Int { xs.reduce(0, +) }"

/// Everything an observer could read: conversation state, console, activity feed, SQLite, artifact files.
@MainActor
private func everythingObservable(_ h: IntelligenceHarness) -> String {
    h.hub.flushPersistNow()
    var text = h.conversation.messages.map(\.content).joined(separator: "\n")
    for run in h.hub.runs.keys { text += "\n" + h.hub.visibleText(run) + "\n" + (h.observatory.consoleEvents(run).map { $0.summary + ($0.detail ?? "") }.joined(separator: "\n")) }
    text += "\n" + h.store.activity.map(\.message).joined(separator: "\n")
    text += "\n" + h.databaseText() + "\n" + h.artifactFilesText()
    return text
}

@MainActor
@Suite("Live console", .serialized)
struct LiveConsoleTests {
    @Test func theSameExecutionFeedsTheAgentRuntimeAndTheConsoleWithoutASecondProcess() async throws {
        let h = IntelligenceHarness()
        h.installOpenCode(.text("OBSERVE_OPENCODE_OK")); h.passBenchmarks("opencode/alpha-free"); await h.refresh()
        await h.ask(askText)
        #expect(h.lastReply?.content == "OBSERVE_OPENCODE_OK")                                         // the agent runtime got the answer…
        let runID = try #require(h.runs().last?.id)
        #expect(h.hub.visibleText(runID).contains("OBSERVE_OPENCODE_OK"))                             // …and the console shows the SAME execution
        #expect(h.launches("opencode") == 1 && h.launches("claude") == 0)                               // exactly one provider process for both observers
        let kinds = h.hub.consoleSnapshot(runID).events.map(\.kind)
        #expect(kinds.first == .agentStarted && kinds.contains(.providerStarted) && kinds.contains(.providerOutput) && kinds.last == .completed)
        let ids = h.hub.consoleSnapshot(runID).events.map(\.id)
        #expect(ids == ids.sorted() && Set(ids).count == ids.count)                                    // ordering preserved, sequence unique
        let view = try #require(h.hub.run(runID))
        #expect(view.phase == .completed && view.engine == .openCode && view.model == "opencode/alpha-free" && view.finishedAt != nil)
        h.shutdown()
    }

    @Test func aTokenStreamIsAssembledIntoLinesWithALiveTail() {
        let hub = ExecutionHub(repository: nil, artifacts: nil)
        let v = AgentRunView(id: UUID(), label: "t", agentType: "A", engine: .claudeCode, model: nil, parent: nil, phase: .running, startedAt: Date(), activity: "x", owner: .agent)
        hub.begin(v)
        hub.appendOutput(v.id, "Hello wor"); hub.appendOutput(v.id, "ld\nsecond li"); hub.appendOutput(v.id, "ne\n\n\nthird")
        let s = hub.consoleSnapshot(v.id)
        #expect(s.events.filter { $0.kind == .providerOutput }.map(\.summary) == ["Hello world", "second line"] && s.tail == "third")
        hub.finish(v.id, phase: .completed)
        #expect(hub.consoleSnapshot(v.id).events.filter { $0.kind == .providerOutput }.map(\.summary).last == "third")       // the unfinished line is flushed at the end
    }

    @Test func memoryIsBoundedAndOldestEventsAreDroppedNotTheNewest() {
        let hub = ExecutionHub(repository: nil, artifacts: nil)
        hub.limits.maxEventsInMemory = 100; hub.limits.maxConsoleChars = 20_000
        let v = AgentRunView(id: UUID(), label: "t", agentType: "A", engine: .openCode, model: nil, parent: nil, phase: .running, startedAt: Date(), activity: "x", owner: .agent)
        hub.begin(v)
        for i in 0..<20_000 { hub.appendOutput(v.id, "line \(i) " + String(repeating: "x", count: 40) + "\n") }
        let stats = try! #require(hub.bufferStats(v.id))
        #expect(stats.events <= 100 && stats.chars <= 20_000 + 600 && stats.dropped > 19_000)
        #expect(hub.consoleSnapshot(v.id).events.last?.summary.hasPrefix("line 19999") == true)        // newest kept
        // The retained output log is capped too.
        hub.limits.maxOutputLog = 1000
        let w = AgentRunView(id: UUID(), label: "t", agentType: "A", engine: .openCode, model: nil, parent: nil, phase: .running, startedAt: Date(), activity: "x", owner: .agent)
        hub.begin(w); for _ in 0..<500 { hub.appendOutput(w.id, String(repeating: "y", count: 100) + "\n") }
        #expect(hub.visibleText(w.id).count < 80_000)
    }

    @Test func persistedEventsAreCappedPerRunAndReloadLazily() throws {
        let h = IntelligenceHarness()
        let id = h.audit.begin(agentType: "A", engine: .openCode, model: nil, decision: nil, prompt: "p", privacy: .normal)
        for i in 0..<(JarvisRepository.maxEventsPerRun + 500) { h.hub.appendOutput(id, "persisted line \(i)\n"); if i % 400 == 0 { h.hub.flushPersistNow() } }
        h.hub.flushPersistNow()
        let count = try h.repo.eventCount(runID: id)
        #expect(count <= JarvisRepository.maxEventsPerRun + 1)
        let page = try h.repo.events(runID: id, afterSeq: 0, limit: 50)
        #expect(page.count == 50 && page.map(\.id) == page.map(\.id).sorted())
        let next = try h.repo.events(runID: id, afterSeq: page.last!.id, limit: 50)
        #expect(next.first!.id > page.last!.id)                                                      // pagination, not "load everything"
    }

    @Test func cancellationLeavesATerminalConsoleEventInMemoryAndInSQLite() async throws {
        let h = IntelligenceHarness()
        h.slowSeconds = 30; h.installOpenCode(.slow("late")); h.passBenchmarks("opencode/alpha-free"); await h.refresh()
        h.service.submit(askText)
        let pid = try #require(await FakeCLI.pid(from: h.dir + "/opencode.pid"))
        let runID = try #require(h.service.respondingRunID)
        #expect(h.hub.run(runID)?.phase.isActive == true)                                              // RUNNING (or STARTING) while the process lives
        #expect(h.hub.requestStop(runID))                                                              // the same action the Stop button calls
        await h.service.waitUntilIdle()
        #expect(await FakeCLI.waitDead(pid))                                                           // existing cancellation killed the process tree
        #expect(h.hub.run(runID)?.phase == .cancelled)
        h.hub.flushPersistNow()
        let stored = try h.repo.events(runID: runID)
        #expect(stored.contains { $0.kind == .cancelled } && stored.contains { $0.summary == "Stop requested" })
        #expect(try h.repo.agentRun(runID)?.status == .cancelled)
        #expect(h.hub.activeRuns.isEmpty && !h.service.isResponding && h.supervisor.consecutiveFailures(.openCode, "opencode/alpha-free") == 0)
    }

    @Test func stopRoutesToAgentCancellationToo() async throws {
        let h = IntelligenceHarness()
        h.slowSeconds = 30; h.installOpenCode(.slow("late")); h.passBenchmarks("opencode/alpha-free"); await h.refresh()
        let profile = TaskProfile(category: .research, complexity: .moderate)
        let task = Task { @MainActor in await h.agents.spawn(AgentDescriptor(type: "ResearchAgent", prompt: "x", profile: profile, timeout: 60, title: "Compare options")) }
        let pid = try #require(await FakeCLI.pid(from: h.dir + "/opencode.pid"))
        let runID = try #require(h.hub.activeRuns.first { $0.owner == .agent }?.id)
        #expect(h.hub.run(runID)?.label == "Compare options")
        #expect(h.hub.requestStop(runID))
        guard case .cancelled = await task.value else { Issue.record("must be cancelled"); return }
        #expect(await FakeCLI.waitDead(pid) && h.hub.run(runID)?.phase == .cancelled)
    }

    @Test func malformedProviderOutputNeverBreaksTheConsole() async throws {
        let h = IntelligenceHarness()
        let path = FakeCLI.script("cat >/dev/null\nprintf '%s\\n' 'not json at all' '{broken' '\\x01\\x02 binary-ish' '{\"type\":\"text\",\"sessionID\":\"s\",\"part\":{\"text\":\"fine\"}}'", in: h.dir, name: "opencode")
        h.openCode.testExecutablePath = path
        h.passBenchmarks("opencode/alpha-free"); await h.refresh()
        await h.ask(askText)
        let runID = try #require(h.runs().last?.id)
        #expect(h.hub.visibleText(runID).contains("fine") && h.hub.run(runID)?.phase.isTerminal == true)
    }
}

@MainActor
@Suite("Observatory security boundary (synthetic secrets only)", .serialized)
struct ObservatorySecurityTests {
    private func assertNoLeak(_ h: IntelligenceHarness, _ context: String) {
        let blob = everythingObservable(h)
        #expect(FakeSecrets.leaks(blob).isEmpty, "\(context): leaked \(FakeSecrets.leaks(blob))")
        for secret in FakeSecrets.all where secret.count >= 14 { #expect(!blob.contains(String(secret.prefix(12))) || secret == FakeSecrets.pem, "\(context): fragment of \(secret.prefix(6))…") }
    }

    @Test func aSecretInProviderOutputNeverReachesObservableStateTheDatabaseOrArtifacts() async throws {
        let h = IntelligenceHarness()
        h.installClaude(text: "The key is \(FakeSecrets.skKey) and the header Authorization: Bearer \(FakeSecrets.bearer) end.")
        await h.refresh()
        h.prefs.providerPreference = .claudeCode
        await h.ask(askText)
        #expect(h.lastReply?.content.contains(OutputSanitizer.mask) == true)                           // the user sees the redaction…
        assertNoLeak(h, "plain output")                                                                // …and the secret exists nowhere
        let runID = try #require(h.runs().last?.id)
        #expect(try h.artifacts.artifacts(agentRunID: runID).contains { $0.type == "console-output" })   // output WAS archived — sanitized
    }

    @Test func aSecretSplitAcrossProviderDeltasIsStillRedacted() async throws {
        let h = IntelligenceHarness()
        let s = FakeSecrets.skKey
        let mid = s.index(s.startIndex, offsetBy: 17)
        h.installClaude(chunks: ["Here: ", String(s[..<mid]), String(s[mid...]), " thanks."])
        await h.refresh(); h.prefs.providerPreference = .claudeCode
        await h.ask(askText)
        assertNoLeak(h, "split secret")
        #expect(h.lastReply?.content.contains("thanks.") == true)
    }

    @Test func environmentLikeAndStructuredCredentialOutputIsMasked() async throws {
        let h = IntelligenceHarness()
        h.installClaude(chunks: ["AWS_SECRET_ACCESS_KEY=\(FakeSecrets.password)\\n", "{\\\"password\\\": \\\"\(FakeSecrets.password)\\\", \\\"note\\\": \\\"ok\\\"}\\n", "export OPENCODE_API_KEY=\(FakeSecrets.skKey)\\n"])
        await h.refresh(); h.prefs.providerPreference = .claudeCode
        await h.ask(askText)
        assertNoLeak(h, "env/structured")
        #expect(everythingObservable(h).contains("ok"))                                               // harmless fields survive
    }

    @Test func aMalformedOpenCodeEventWithASecretIsNeitherShownNorStored() async throws {
        let h = IntelligenceHarness()
        let path = FakeCLI.script("cat >/dev/null\nprintf '%s\\n' '{\"type\":\"text\" broken token=\(FakeSecrets.skKey)' '{\"type\":\"error\",\"error\":{\"message\":\"failed with \(FakeSecrets.bearer)\",\"status\":503}}'", in: h.dir, name: "opencode")
        h.openCode.testExecutablePath = path
        h.passBenchmarks("opencode/alpha-free"); await h.refresh()
        await h.ask(askText)                                                                          // fails → escalates to Claude (fake)
        assertNoLeak(h, "malformed/error events")
    }

    @Test func aProviderErrorMessageContainingASecretIsNotPersisted() async throws {
        let h = IntelligenceHarness()
        h.installClaude(text: "x", fail: true)                                                         // result: "boom"
        let path = FakeCLI.script("cat >/dev/null\necho 'ERR token \(FakeSecrets.ghToken)' >&2\necho '{\"type\":\"result\",\"is_error\":true,\"result\":\"auth failed for \(FakeSecrets.ghToken)\"}'\nexit 1", in: h.dir, name: "claude")
        h.providerPaths[.claudeCode] = path
        await h.refresh(); h.prefs.providerPreference = .claudeCode
        await h.ask(askText)
        assertNoLeak(h, "provider error text")
    }

    private struct BrokenEngine: SanitizerEngine {
        func redact(_ text: String) throws -> String { throw SanitizerFailure() }
        func detectsSecret(_ text: String) throws -> Bool { throw SanitizerFailure() }
    }

    @Test func ifSanitizationFailsNothingUnsafeIsDisplayedOrPersisted() async throws {
        let h = IntelligenceHarness()
        h.installClaude(text: "payload \(FakeSecrets.skKey) here")
        await h.refresh(); h.prefs.providerPreference = .claudeCode
        let saved = OutputSanitizer.holder.get()
        OutputSanitizer.holder.set(BrokenEngine())
        defer { OutputSanitizer.holder.set(saved) }
        await h.ask(askText)                                                                          // must not crash
        assertNoLeak(h, "sanitizer failure")
        #expect(everythingObservable(h).contains(OutputSanitizer.withheld))                           // fail closed: a placeholder, never the raw text
    }

    @Test func consoleEventsCannotBeConstructedFromRawText() {
        let e = AgentConsoleEvent(id: 1, runID: UUID(), kind: .providerOutput, source: "src Bearer \(FakeSecrets.bearer)", summary: "x \(FakeSecrets.skKey)", detail: "d password=\(FakeSecrets.password)")
        #expect(FakeSecrets.leaks(e.summary + e.source + (e.detail ?? "")).isEmpty)
        let hub = ExecutionHub(repository: nil, artifacts: nil)
        let v = AgentRunView(id: UUID(), label: "t \(FakeSecrets.skKey)", agentType: "A", engine: .codex, model: nil, parent: nil, phase: .running, startedAt: Date(), activity: "act \(FakeSecrets.skKey)", owner: .agent)
        hub.begin(v); hub.setActivity(v.id, "now \(FakeSecrets.ghToken)"); hub.setSteps(v.id, [("do \(FakeSecrets.awsKey)", 1)])
        #expect(FakeSecrets.leaks(hub.run(v.id)!.activity + hub.run(v.id)!.steps[0].title).isEmpty)
    }

    @Test func theAuditLabelAndResultExcerptAreRedactedAndSensitiveTasksStayPrivate() throws {
        let h = IntelligenceHarness()
        let id = h.audit.begin(agentType: "A", engine: .claudeCode, model: nil, decision: nil, prompt: "my password is \(FakeSecrets.password)", privacy: .sensitive)
        h.audit.finish(id, status: .succeeded, resultText: "secret \(FakeSecrets.skKey)")
        let rec = try #require(try h.repo.agentRun(id))
        #expect(rec.label == "Private request" && FakeSecrets.leaks((rec.resultSummary ?? "") + (rec.label ?? "")).isEmpty)
        #expect(FakeSecrets.leaks(h.databaseText()).isEmpty)
    }
}

@MainActor
@Suite("History, restart and reconciliation", .serialized)
struct HistoryAndRecoveryTests {
    @Test func runsCreatedByTheRealServicesSurviveReopeningTheDatabase() async throws {
        let h = IntelligenceHarness()
        h.installOpenCode(.text("PERSISTED_ANSWER")); h.passBenchmarks("opencode/alpha-free"); await h.refresh()
        await h.ask(askText)
        let runID = try #require(h.runs().last?.id)
        let original = try #require(try h.repo.agentRun(runID))
        h.hub.flushPersistNow()

        // "Restart": a brand-new database connection, repository, hub and observatory over the same files.
        let db2 = try JarvisDatabase(url: h.paths.database)
        let repo2 = JarvisRepository(database: db2)
        let art2 = ArtifactStore(paths: h.paths, database: db2)
        let hub2 = ExecutionHub(repository: repo2, artifacts: art2)
        let obs2 = AgentObservatory(hub: hub2, supervisor: h.supervisor, openCode: h.openCode, local: h.runtime, repository: repo2, artifacts: art2)

        let page = obs2.history(filter: .init())
        let v = try #require(page.first { $0.id == runID })
        #expect(v.engine == .openCode && v.model == "opencode/alpha-free" && v.phase == .completed && v.label.contains("Explain this Swift function"))
        #expect(abs(v.startedAt.timeIntervalSince(original.startedAt)) < 0.01 && v.finishedAt != nil)
        let d = try #require(obs2.detail(runID))
        #expect(d.resultSummary?.contains("PERSISTED_ANSWER") == true && d.selectionSummary?.contains("development-free-first") == true && d.validation == .notRun)
        #expect(d.view.progress == .unknown)                                                          // progress source preserved: unknown stays unknown
        #expect(d.artifacts.contains { $0.type == "console-output" } && d.artifacts.allSatisfy { art2.verify($0) })
        let events = obs2.consoleEvents(runID)
        #expect(events.contains { $0.kind == .providerOutput && $0.summary == "PERSISTED_ANSWER" } && events.last?.kind == .completed)
        let text = try #require(d.artifacts.first { $0.type == "console-output" }.flatMap { obs2.artifactText($0) })
        #expect(text.contains("PERSISTED_ANSWER"))
        h.shutdown()
    }

    @Test func historyIsPaginatedAndFilterable() async throws {
        let h = IntelligenceHarness()
        for i in 0..<30 {
            let engine: ProviderID = i % 3 == 0 ? .codex : (i % 3 == 1 ? .openCode : .local)
            let id = h.audit.begin(agentType: "Agent\(i)", engine: engine, model: engine == .openCode ? "opencode/alpha-free" : nil, decision: nil, prompt: "p", privacy: .normal,
                                   label: "Task number \(i)", now: Date().addingTimeInterval(Double(i)))
            h.audit.finish(id, status: i % 5 == 0 ? .failed : .succeeded, resultText: "r", error: i % 5 == 0 ? .timedOut(engine) : nil)
        }
        let all = h.observatory.history(filter: .init(), limit: 25, offset: 0)
        #expect(all.count == 25 && all.first?.label == "Task number 29")                               // newest first, bounded page
        #expect(h.observatory.history(filter: .init(), limit: 25, offset: 25).count == 5)
        #expect(h.observatory.history(filter: .init(engine: .codex), limit: 100).allSatisfy { $0.engine == .codex } && h.observatory.history(filter: .init(engine: .codex), limit: 100).count == 10)
        #expect(h.observatory.history(filter: .init(statuses: [.failed]), limit: 100).count == 6)
        #expect(h.observatory.history(filter: .init(text: "number 2"), limit: 100).count == 11)       // 2, 20…29
        #expect(h.observatory.history(filter: .init(text: "alpha-free"), limit: 100).count == 10)       // model search
        #expect(h.observatory.history(filter: .init(text: "100%_"), limit: 100).isEmpty)                // LIKE wildcards are escaped
    }

    @Test func staleRunningRecordsAreReconciledAsInterruptedNotRunningForever() throws {
        let h = IntelligenceHarness()
        // A previous JARVIS process started two runs and died: both stay recorded as running/queued.
        let a = h.audit.begin(agentType: "CodingAgent", engine: .openCode, model: "opencode/x", decision: nil, prompt: "p", privacy: .normal, label: "Fix tests")
        let finished = h.audit.begin(agentType: "Done", engine: .codex, model: nil, decision: nil, prompt: "p", privacy: .normal)
        h.audit.finish(finished, status: .succeeded, resultText: "ok")
        #expect(try h.repo.agentRun(a)?.status == .running)

        let db2 = try JarvisDatabase(url: h.paths.database)                                           // the next launch
        let repo2 = JarvisRepository(database: db2)
        let audit2 = AuditRecorder(repository: repo2)
        #expect(audit2.reconcileStaleRuns() == 1)
        let rec = try #require(try repo2.agentRun(a))
        #expect(rec.status == .interrupted && rec.finishedAt != nil && rec.errorCategory == "interrupted" && rec.activity?.contains("Interrupted") == true)
        let events = try repo2.events(runID: a)
        #expect(events.contains { $0.kind == .interrupted && $0.summary.contains("JARVIS stopped") })   // the reason is persisted
        #expect(try repo2.agentRun(finished)?.status == .succeeded)                                    // finished runs untouched
        #expect(audit2.reconcileStaleRuns() == 0)                                                      // idempotent
        let hub2 = ExecutionHub(repository: repo2, artifacts: nil)
        let obs2 = AgentObservatory(hub: hub2, supervisor: h.supervisor, openCode: h.openCode, local: h.runtime, repository: repo2, artifacts: nil)
        let v = try #require(obs2.history(filter: .init()).first { $0.id == a })
        #expect(v.phase == .interrupted && !v.phase.isActive && hub2.activeRuns.isEmpty)
        #expect(obs2.providerCards().first { $0.id == .openCode }?.activeRuns.isEmpty == true)
    }

    @Test func reportQueriesAnswerWhatRanToday() async throws {
        let h = IntelligenceHarness()
        let ok = h.audit.begin(agentType: "A", engine: .openCode, model: "opencode/alpha-free", decision: nil, prompt: "p", privacy: .normal)
        h.audit.finish(ok, status: .succeeded, resultText: "r")
        let bad = h.audit.begin(agentType: "B", engine: .claudeCode, model: nil, decision: nil, prompt: "p", privacy: .normal)
        h.audit.update(bad) { $0.escalatedTo = "codex" }
        h.audit.finish(bad, status: .failed, error: .timedOut(.claudeCode))
        let stats = try #require(h.observatory.todayStats())
        #expect(stats.total == 2 && stats.byEngine["openCode"] == 1 && stats.byEngine["claudeCode"] == 1 && stats.byModel["opencode/alpha-free"] == 1)
        #expect(stats.byStatus["succeeded"] == 1 && stats.byStatus["failed"] == 1 && stats.escalated == 1 && stats.totalSeconds >= 0)
    }

    @Test func theTimelineMergesLiveAndPersistedEventsWithoutProviderChatter() async throws {
        let h = IntelligenceHarness()
        h.installOpenCode(.text("TIMELINE_OK")); h.passBenchmarks("opencode/alpha-free"); await h.refresh()
        await h.ask(askText)
        h.hub.flushPersistNow()
        let live = h.observatory.timeline()
        #expect(live.contains { $0.kind == .agentStarted } && live.contains { $0.kind == .completed } && !live.contains { $0.kind == .providerOutput })
        // A fresh hub (restart) still shows it, from SQLite.
        let hub2 = ExecutionHub(repository: h.repo, artifacts: nil)
        let obs2 = AgentObservatory(hub: hub2, supervisor: h.supervisor, openCode: h.openCode, local: h.runtime, repository: h.repo, artifacts: nil)
        let old = obs2.timeline()
        #expect(old.contains { $0.kind == .agentStarted && $0.provider == "OpenCode · alpha-free" } && old.first!.time >= old.last!.time)
        h.shutdown()
    }
}

@MainActor
@Suite("Developer simulation is isolated", .serialized)
struct SimulationIsolationTests {
    @Test func simulatedRunsAreFlaggedNeverPersistedAndUseStructuredStepsOnly() async throws {
        let h = IntelligenceHarness()
        let before = (try h.repo.count("agent_runs"), try h.repo.count("agent_events"), try h.repo.count("artifacts"), try h.repo.count("activity_events"))
        h.observatory.demo!.startShowcase()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let sim = h.hub.runs.values.filter(\.isSimulated)
        #expect(sim.count == 3 && sim.allSatisfy { $0.owner == .simulated })
        let planner = try #require(sim.first { $0.agentType == "PlannerAgent" }), coder = try #require(sim.first { $0.agentType == "CodingAgent" })
        #expect(planner.progress.source == .structuredSteps && planner.progress.total == 5)             // fake progress derives from fake STRUCTURED steps…
        #expect(coder.progress == .unknown && coder.progress.fraction == nil)                           // …and unstructured runs stay indeterminate
        h.hub.flushPersistNow()
        let after = (try h.repo.count("agent_runs"), try h.repo.count("agent_events"), try h.repo.count("artifacts"), try h.repo.count("activity_events"))
        #expect(before == after)                                                                       // production history is untouched
        // The synthetic secret fixture is redacted like any other output.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        #expect(!h.hub.visibleText(planner.id).contains("FAKE-DEMO-TOKEN"))
        #expect(h.hub.requestStop(coder.id) && h.hub.run(coder.id)?.phase == .cancelled)
        h.observatory.demo!.stopAll()
        #expect(h.hub.activeRuns.isEmpty)
    }
}
