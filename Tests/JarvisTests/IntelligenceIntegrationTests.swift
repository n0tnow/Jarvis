import Testing
import Foundation
@testable import Jarvis

let simple = "Summarize in one sentence: The cat sat on the mat and then slept."
/// A coding QUESTION (reasoning). Coding WORK ("write/fix/refactor …") is workerRequired in V0.3 and never reaches a provider.
let coding = "Explain this Swift function: func f(_ xs: [Int]) -> Int { xs.reduce(0, +) }"

// MARK: - OpenCode service

@MainActor
@Suite("OpenCode service (fake catalog + fake CLI)", .serialized)
struct OpenCodeServiceTests {
    @Test func refreshBuildsAndPersistsTheVerifiedFreeRegistry() async throws {
        let h = IntelligenceHarness()
        h.setCatalog([("alpha-free", 0, 0), ("beta-free", 0, 0)])
        var events: [String] = []
        h.openCode.onEvent = { events.append($0) }
        await h.openCode.refresh(remote: false)
        #expect(h.openCode.state == .ready && h.openCode.version == "1.18.34")
        #expect(h.openCode.freePool.map(\.id) == ["opencode/alpha-free", "opencode/beta-free"])
        #expect(events == ["Free model registry refreshed (2 verified free)"])
        // The registry survives a restart (new service object, same database).
        let again = OpenCodeService(repository: h.repo, preferences: nil, providerWorkspace: h.dir)
        #expect(again.models.map(\.id) == ["opencode/alpha-free", "opencode/beta-free"] && again.models.allSatisfy { $0.freeVerified && $0.freeVerificationSource != nil })
    }

    @Test func pricesAreReReadSoAChargingModelLosesFreeStatusAndAMissingOneBecomesUnavailable() async {
        let h = IntelligenceHarness()
        h.setCatalog([("alpha-free", 0, 0), ("beta-free", 0, 0)])
        await h.openCode.refresh(remote: false)
        #expect(h.openCode.freePool.count == 2)
        h.setCatalog([("alpha-free", 0, 0.5)])                                   // alpha now charges, beta vanished
        await h.openCode.refresh(remote: false)
        #expect(h.openCode.freePool.isEmpty)
        #expect(h.openCode.model("opencode/alpha-free")?.pricingStatus == .paid)
        #expect(h.openCode.model("opencode/beta-free")?.availability == .unavailable)
    }

    @Test func userDisabledModelsAndBenchmarkStatusSurviveRefresh() async throws {
        let h = IntelligenceHarness()
        await h.openCode.refresh(remote: false)
        h.openCode.setEnabled("opencode/alpha-free", false)
        try h.repo.setBenchmarkStatus("opencode/alpha-free", .passed)
        await h.openCode.refresh(remote: false)
        let m = try #require(h.openCode.model("opencode/alpha-free"))
        #expect(!m.enabled && !m.isFreePoolMember && m.benchmarkStatus == .passed)
        h.openCode.setEnabled("opencode/alpha-free", true)
        #expect(h.openCode.freePool.map(\.id) == ["opencode/alpha-free"])
    }

    @Test func aBrokenOrEmptyCatalogLeavesPreviousDataAndReportsUnavailable() async {
        let h = IntelligenceHarness()
        await h.openCode.refresh(remote: false)
        h.openCode.catalogOverride = { _ in nil }
        await h.openCode.refresh(remote: false)
        if case .unavailable = h.openCode.state {} else { Issue.record("must be unavailable") }
        #expect(h.openCode.models.count == 1)                                      // old registry kept, but state is not ready → router won't use it
        h.openCode.catalogOverride = { _ in ("opencode 1.18.34", "garbage output") }
        await h.openCode.refresh(remote: false)
        if case .unavailable = h.openCode.state {} else { Issue.record("empty catalog must be unavailable") }
    }

    @Test func notInstalledIsReportedWhenNoExecutableExists() async {
        let locator = ExecutableLocator(home: "/nonexistent", path: "", isExecutableFile: { _ in false }, directoryContents: { _ in [] }, resolveSymlinks: { $0 })
        let svc = OpenCodeService(repository: nil, preferences: nil, locator: locator, providerWorkspace: NSTemporaryDirectory())
        await svc.refresh(remote: false)
        #expect(svc.state == .notInstalled && svc.models.isEmpty)
    }

    @Test func aProviderIsOnlyBuiltForCurrentVerifiedFreeModels() async throws {
        let h = IntelligenceHarness()
        h.setCatalog([("alpha-free", 0, 0), ("pricey", 2, 6)])
        await h.openCode.refresh(remote: false)
        let free = try #require(h.openCode.model("opencode/alpha-free")), paid = try #require(h.openCode.model("opencode/pricey"))
        #expect(h.openCode.provider(for: free) != nil)
        #expect(h.openCode.provider(for: paid) == nil)
        var stale = free; stale.freeVerifiedAt = Date().addingTimeInterval(-3 * 24 * 3600)
        #expect(h.openCode.provider(for: stale) == nil)
        let ws = h.dir + "/work/opencode"
        #expect(try String(contentsOfFile: ws + "/opencode.json", encoding: .utf8) == OpenCodeWorkspace.configJSON)
    }

    @Test func theLaunchedCommandIsPinnedAndEnvironmentIsScrubbed() async throws {
        let h = IntelligenceHarness()
        await h.openCode.refresh(remote: false)
        let model = try #require(h.openCode.model("opencode/alpha-free"))
        let provider = try #require(h.openCode.provider(for: model))
        let r = await OneShotRunner.run(provider: provider, prompt: "hello")
        #expect(r.succeeded && r.text == "OPENCODE_OK" && r.inputTokens == 100 && r.outputTokens == 20)
        let args = h.args("opencode")
        #expect(args.contains("run --pure --format json -m opencode/alpha-free"))
        for bad in ["--auto", "--attach", "serve", "--password", "--share"] { #expect(!args.contains(bad)) }
        let env = OpenCodeWorkspace.environment
        #expect(env["OPENCODE_DISABLE_AUTOUPDATE"] == "1")
        let scrubbed = h.openCode.environment()
        for name in ProviderEnvironment.forbidden { #expect(scrubbed[name] == nil) }
    }
}

// MARK: - Provider supervisor

@MainActor
@Suite("Provider supervisor: health, cooldown, restart, pressure", .serialized)
struct ProviderSupervisorTests {
    @Test func failuresBackOffExponentiallyAndSuccessResets() {
        let h = IntelligenceHarness()
        let s = h.supervisor
        #expect(s.recordFailure(.openCode, subject: "opencode/x", error: .processFailed(.openCode, exitCode: 1)) == nil)       // 1st: tolerated
        let t1 = s.recordFailure(.openCode, subject: "opencode/x", error: .malformedOutput(.openCode))                          // 2nd: 60 s
        #expect(t1 != nil && abs(t1!.timeIntervalSinceNow - 60) < 2)
        let t2 = s.recordFailure(.openCode, subject: "opencode/x", error: .timedOut(.openCode))                                 // 3rd: 120 s
        #expect(abs(t2!.timeIntervalSinceNow - 120) < 2)
        #expect(s.cooldownUntil(.openCode, "opencode/x") != nil && s.cooldownUntil(.openCode, "opencode/other") == nil)       // per model
        s.recordSuccess(.openCode, subject: "opencode/x")
        #expect(s.cooldownUntil(.openCode, "opencode/x") == nil && s.consecutiveFailures(.openCode, "opencode/x") == 0)
    }

    @Test func cancelsBusyRefusalsAndLostSessionsAreNotProviderFailures() {
        let s = IntelligenceHarness().supervisor
        for e in [ProviderError.cancelled, .busy, .refused("x"), .sessionLost(.claudeCode)] { _ = s.recordFailure(.claudeCode, error: e) }
        #expect(s.consecutiveFailures(.claudeCode) == 0)
    }

    @Test func rateLimitsAndAuthFailuresCooldownImmediately() {
        let s = IntelligenceHarness().supervisor
        let reset = Date().addingTimeInterval(1800)
        let u = s.recordFailure(.codex, error: .rateLimited(.codex, resetsAt: reset))
        #expect(u != nil && abs(u!.timeIntervalSince(reset)) < 2)
        let d = s.recordFailure(.claudeCode, error: .rateLimited(.claudeCode, resetsAt: nil))
        #expect(abs(d!.timeIntervalSinceNow - 900) < 2)                                           // default 15 min
        #expect(s.recordFailure(.openCode, subject: "m", error: .authenticationRequired(.openCode)) != nil)
    }

    @Test func cooldownStateSurvivesARestart() {
        let h = IntelligenceHarness()
        _ = h.supervisor.recordFailure(.openCode, subject: "opencode/x", error: .processFailed(.openCode, exitCode: 1))
        _ = h.supervisor.recordFailure(.openCode, subject: "opencode/x", error: .processFailed(.openCode, exitCode: 1))
        let reborn = ProviderSupervisor(providers: h.providers, openCode: h.openCode, local: nil, resources: h.resources, repository: h.repo)
        #expect(reborn.cooldownUntil(.openCode, "opencode/x") != nil)
        #expect(reborn.consecutiveFailures(.openCode, "opencode/x") == 2)
    }

    @Test func availabilityAndTheRouterSnapshotReflectRealStates() async {
        let h = IntelligenceHarness()
        h.states = [.claudeCode: .authenticationRequired, .codex: .ready]
        h.providerPaths[.codex] = "/x"
        await h.refresh()
        let a = h.supervisor.availability()
        #expect(a[.claudeCode]?.state == .authenticationRequired && a[.codex]?.state == .ready)
        #expect(a[.openCode]?.state == .ready && a[.local]?.state == .ready)                      // idle local = usable (starts on demand)
        _ = h.supervisor.recordFailure(.openCode, subject: "opencode/alpha-free", error: .processFailed(.openCode, exitCode: 1))
        _ = h.supervisor.recordFailure(.openCode, subject: "opencode/alpha-free", error: .processFailed(.openCode, exitCode: 1))
        let snap = h.supervisor.snapshot(preference: .auto, settings: RoutingSettings())
        #expect(snap.modelCooldowns["opencode/alpha-free"] != nil && snap.models.count == 1)
    }

    @Test func aLocalCrashIsRecoveredOnceThenNeverRestartedInALoop() async throws {
        let h = IntelligenceHarness()
        var events: [String] = []
        h.supervisor.onEvent = { events.append($0) }
        // 1st crash → ONE bounded restart + health check.
        let r1 = await FakeWorker.drain(h.runtime, "CRASH please")
        #expect(r1.error != nil)
        let deadline = Date().addingTimeInterval(10)
        while h.runtime.state != .ready && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(h.runtime.state == .ready && events.contains("Local Qwen restarted"))
        #expect(h.supervisor.restartTimes.count == 1)
        // 2nd crash inside the window → NO automatic restart.
        let r2 = await FakeWorker.drain(h.runtime, "CRASH again")
        #expect(r2.error != nil)
        try await Task.sleep(nanoseconds: 800_000_000)
        if case .failed = h.runtime.state {} else { Issue.record("must stay failed (no restart loop), got \(h.runtime.state)") }
        #expect(events.contains("Local Qwen unavailable (restart limit reached)") && h.supervisor.restartTimes.count == 1)
        // Repeated failures put the engine into cooldown, so the router stops choosing it.
        let r3 = await FakeWorker.drain(h.runtime, "CRASH third")
        #expect(r3.error != nil)
        #expect(h.supervisor.cooldownUntil(.local, nil) != nil)
        #expect(ModelRouter.route(TaskClassifier.profile(for: simple), snapshot: h.supervisor.snapshot(preference: .auto, settings: RoutingSettings())).selected?.engine != .local)
        h.shutdown()
    }

    @Test func memoryPressureUnloadsAnIdleLocalModelAndShutdownKillsTheWorker() async throws {
        let h = IntelligenceHarness()
        _ = await FakeWorker.drain(h.runtime, "hello")
        #expect(h.runtime.state == .ready)
        let pid = try #require(await FakeCLI.pid(from: h.runtimePidfile))
        h.resources.setMemory(.warning)
        let deadline = Date().addingTimeInterval(5)
        while h.runtime.state != .idle && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        let died = await FakeCLI.waitDead(pid)
        #expect(h.runtime.state == .idle && died)
        // Under pressure the router also refuses to START local inference.
        let snap = h.supervisor.snapshot(preference: .auto, settings: RoutingSettings())
        #expect(snap.resources.memory == .warning && !snap.resources.localInferenceAdvisable)
        h.resources.setMemory(.normal)
        _ = await FakeWorker.drain(h.runtime, "again")
        let pid2 = try #require(await FakeCLI.pid(from: h.runtimePidfile))
        h.supervisor.shutdown()
        #expect(await FakeCLI.waitDead(pid2))
    }

    @Test func providersAreNotKeptAliveBetweenRequests() async throws {
        let h = IntelligenceHarness()
        await h.refresh()
        h.passBenchmarks("opencode/alpha-free"); await h.refresh()
        await h.ask(coding)
        #expect(h.launches("opencode") == 1)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(ProcessRegistry.shared.count == 0 || h.runtime.state == .idle)                    // no CLI process lingers (the local worker is only present if loaded)
        h.shutdown()
    }
}

// MARK: - Coordinator + conversation, end to end

@MainActor
@Suite("Automatic routing through the real conversation stack", .serialized)
struct CoordinatorIntegrationTests {
    @Test func aLightweightTaskRunsOnTheLocalModelAndTheDecisionIsPersisted() async throws {
        let h = IntelligenceHarness()
        await h.refresh()
        await h.ask(simple)
        #expect(h.lastReply?.content == "t0 t1 t2 " && h.launches("opencode") == 0 && h.launches("claude") == 0)
        let run = try #require(h.runs().last)
        #expect(run.engine == .local && run.status == .succeeded && run.agentType == "Conversation" && run.finishedAt != nil)
        #expect(run.costClass == .local && run.inputTokens == 7 && run.outputTokens == 3)
        let reason = try #require(try JSONSerialization.jsonObject(with: Data((run.selectionReason ?? "").utf8)) as? [String: String])
        #expect(reason["selected"] == "local" && reason["tier"] == "lightweight-local-first" && reason["localEligible"] == "true" && reason["mode"] == "auto")
        #expect(run.promptHash?.count == 64 && (run.promptChars ?? 0) > 20 && run.resultSummary?.contains("chars") == true)
        h.shutdown()
    }

    @Test func codingRoutesToTheVerifiedBenchmarkedFreeModel() async throws {
        let h = IntelligenceHarness()
        h.passBenchmarks("opencode/alpha-free")
        await h.refresh()
        await h.ask(coding)
        #expect(h.lastReply?.content == "OPENCODE_OK" && h.lastReply?.provider == "OpenCode · alpha-free")
        #expect(h.launches("opencode") == 1 && h.launches("claude") == 0 && h.runtimePidFileAbsent)
        let run = try #require(h.runs().last)
        #expect(run.engine == .openCode && run.model == "opencode/alpha-free" && run.status == .succeeded && run.costClass == .freeCloud)
        #expect(run.inputTokens == 100 && run.outputTokens == 20)
        let reason = try #require(try JSONSerialization.jsonObject(with: Data((run.selectionReason ?? "").utf8)) as? [String: String])
        for (k, v) in ["selected": "opencode/alpha-free", "freeVerified": "true", "codingBenchmarkPassed": "true", "providerReady": "true",
                       "localModelIneligible": "true", "tier": "development-free-first"] { #expect(reason[k] == v, "\(k)") }
        #expect(h.args("opencode").contains("-m opencode/alpha-free"))
    }

    @Test func withoutBenchmarkEvidenceDevelopmentEscalatesToClaudeAndSaysWhy() async throws {
        let h = IntelligenceHarness()
        await h.refresh()
        await h.ask(coding)
        #expect(h.lastReply?.content == "CLAUDE_OK" && h.launches("opencode") == 0)
        let run = try #require(h.runs().last)
        #expect(run.engine == .claudeCode && run.costClass == .subscription)
        #expect(run.selectionReason?.contains("\"escalationReason\":\"noFreeModel") == true && run.selectionReason?.contains("benchmark:") == true)
    }

    @Test func pricedOrUnknownPriceModelsAreNeverLaunchedNoMatterWhat() async {
        let h = IntelligenceHarness()
        h.setCatalog([("pricey", 2, 6)])
        h.passBenchmarks("opencode/pricey")
        await h.refresh()
        await h.ask(coding)
        #expect(h.launches("opencode") == 0 && h.lastReply?.content == "CLAUDE_OK")
        h.catalog = #"opencode/mystery"# + "\n" + #"{"id":"mystery","providerID":"opencode","name":"mystery","status":"active","api":{"url":"https://opencode.ai/zen/v1"}}"#
        h.passBenchmarks("opencode/mystery")
        await h.refresh()
        await h.ask(coding)
        #expect(h.launches("opencode") == 0)
        // Explicit "OpenCode Free" with nothing verified: refused, nothing sent, no fallback to Claude.
        h.prefs.providerPreference = .openCodeFree
        let before = h.launches("claude")
        await h.ask(coding)
        #expect(h.launches("opencode") == 0 && h.launches("claude") == before && h.lastReply?.content.contains("No verified-free OpenCode model") == true)
    }

    @Test func aFailingFreeModelEscalatesOnceInTheSameTurnThenEntersCooldown() async throws {
        let h = IntelligenceHarness()
        h.installOpenCode(.fail503)
        h.passBenchmarks("opencode/alpha-free")
        await h.refresh()
        await h.ask(coding)
        #expect(h.lastReply?.content == "CLAUDE_OK")                                                // user got an answer
        #expect(h.launches("opencode") == 1 && h.launches("claude") == 1)
        var runs = h.runs()
        #expect(runs.count == 2)
        #expect(runs[0].engine == .openCode && runs[0].status == .escalated && runs[0].escalatedTo == "claudeCode" && runs[0].errorCategory == "unavailable")
        #expect(runs[1].engine == .claudeCode && runs[1].status == .succeeded && runs[1].escalatedFrom == "openCode")
        #expect(h.store.activity.contains { $0.message.contains("escalating to Claude Code") })
        await h.ask(coding)                                                                         // 2nd failure → cooldown starts
        #expect(h.launches("opencode") == 2)
        #expect(h.supervisor.cooldownUntil(.openCode, "opencode/alpha-free") != nil)
        await h.ask(coding)                                                                         // cooled-down model is skipped
        #expect(h.launches("opencode") == 2 && h.launches("claude") == 3)
        runs = h.runs()
        #expect(runs.last?.selectionReason?.contains("\"rejected.opencode/alpha-free\":\"cooldown\"") == true)
        let health = try #require(try h.repo.health(.openCode, subject: "opencode/alpha-free"))
        #expect(health.consecutiveFailures == 2 && health.cooldownUntil != nil && health.lastErrorCategory == "unavailable")
    }

    @Test func escalationIsBoundedToOneHandOver() async {
        let h = IntelligenceHarness()
        h.installOpenCode(.fail503)
        h.installClaude(text: "x", fail: true)
        h.states[.codex] = .ready; h.providerPaths[.codex] = FakeCLI.script("cat >/dev/null\necho \"$$\" >> \(h.dir)/codex.launches\nexit 1", in: h.dir, name: "codex")
        h.passBenchmarks("opencode/alpha-free")
        await h.refresh()
        await h.ask(coding)
        #expect(h.launches("opencode") == 1 && h.launches("claude") == 1 && h.launches("codex") == 0)      // free → Claude, and STOP there
        #expect(h.conversation.messages.last?.status == .failed || h.lastReply?.tone == .notice)
        #expect(h.runs().count == 2)
    }

    @Test func explicitLocalIsRefusedForCodingWithoutStartingAnything() async throws {
        let h = IntelligenceHarness()
        h.prefs.providerPreference = .local
        await h.refresh()
        await h.ask(coding)
        #expect(h.lastReply?.content.contains("lightweight") == true)
        #expect(h.launches("opencode") == 0 && h.launches("claude") == 0 && h.runtimePidFileAbsent)
        let run = try #require(h.runs().last)
        #expect(run.status == .failed && run.errorCategory == "refused" && run.selectionReason?.contains("\"outcome\":\"refused\"") == true)
        #expect(run.selectionReason?.contains("localViolations") == true)
    }

    @Test func explicitProvidersNeverFallBackSilently() async {
        let h = IntelligenceHarness()
        h.states[.claudeCode] = .authenticationRequired
        h.prefs.providerPreference = .claudeCode
        h.passBenchmarks("opencode/alpha-free")
        await h.refresh()
        await h.ask(coding)
        #expect(h.launches("claude") == 0 && h.launches("opencode") == 0 && h.runtimePidFileAbsent)
        #expect(h.lastReply?.content.contains("Claude Code isn't available") == true || h.lastReply?.content.contains("authentication") == true)
    }

    @Test func deterministicCommandsAndWorkerRequestsNeverReachAnyEngineOrTheAuditTrail() async {
        let h = IntelligenceHarness()
        h.passBenchmarks("opencode/alpha-free")
        await h.refresh()
        await h.ask("show tasks")
        await h.ask("raporu aç")
        await h.ask("pause the current task")
        await h.ask("Fix my Unity multiplayer system. Run it and keep working until it passes.")
        #expect(h.launches("opencode") == 0 && h.launches("claude") == 0 && h.runtimePidFileAbsent)
        #expect(h.runs().isEmpty)
        #expect(h.store.state != .thinking)
    }

    @Test func stopGenerationKillsTheFreeModelProcessAndRecordsACancel() async throws {
        let h = IntelligenceHarness()
        h.installOpenCode(.slow("late"))
        h.passBenchmarks("opencode/alpha-free")
        await h.refresh()
        h.service.submit(coding)
        let pid = try #require(await FakeCLI.pid(from: h.dir + "/opencode.pid"))
        #expect(FakeCLI.alive(pid) && h.service.isResponding)
        #expect(h.service.cancelCurrentResponse())
        await h.service.waitUntilIdle()
        #expect(await FakeCLI.waitDead(pid))
        let run = try #require(h.runs().last)
        #expect(run.status == .cancelled && run.finishedAt != nil)
        #expect(h.supervisor.consecutiveFailures(.openCode, "opencode/alpha-free") == 0)           // a user cancel is not a provider failure
        #expect(!h.service.isResponding && h.store.state == .idle)
    }

    @Test func secretsInPromptsOrAnswersNeverReachTheDatabaseAndSensitiveTasksStayOffFreeCloud() async throws {
        let h = IntelligenceHarness()
        h.passBenchmarks("opencode/alpha-free")
        await h.refresh()
        let prompt = "Explain how hash maps work. My password is hunter2hunter2 and my key is sk-proj-ABCDEFGHIJKLMNOPQRSTUV123456."
        await h.ask(prompt)
        #expect(h.launches("opencode") == 0)                                                       // sensitive ⇒ never free cloud
        let run = try #require(h.runs().last)
        #expect(run.privacy == .sensitive && run.engine != .openCode)
        #expect(run.resultSummary == "\(h.lastReply?.content.count ?? -1) chars")                  // no excerpt at all for sensitive tasks
        let dump = h.databaseText()
        for secret in ["hunter2hunter2", "ABCDEFGHIJKLMNOPQRSTUV", "Explain how hash maps"] { #expect(!dump.contains(secret), "\(secret) leaked into SQLite") }
    }

    @Test func nonSensitiveResultsStoreOnlyARedactedExcerpt() async throws {
        let h = IntelligenceHarness()
        h.installOpenCode(.text("Token is sk-proj-ABCDEFGHIJKLMNOPQRSTUV123456 ok"))
        h.passBenchmarks("opencode/alpha-free")
        await h.refresh()
        await h.ask(coding)
        let run = try #require(h.runs().last)
        #expect(run.resultSummary?.contains(Redactor.mask) == true && run.resultSummary?.contains("ABCDEFGH") == false)
    }

    @Test func noCredentialsOrApiKeysAreEverPassedToAnyChild() async throws {
        let h = IntelligenceHarness()
        h.passBenchmarks("opencode/alpha-free")
        await h.refresh()
        await h.ask(coding)
        let envFile = h.dir + "/opencode.args"
        #expect(FileManager.default.fileExists(atPath: envFile))
        let env = h.openCode.environment()
        for name in ProviderEnvironment.forbidden { #expect(env[name] == nil) }
        #expect(!env.keys.contains { $0.contains("KEY") || $0.contains("TOKEN") || $0.contains("SECRET") })
    }
}

extension IntelligenceHarness {
    var runtimePidFileAbsent: Bool { !FileManager.default.fileExists(atPath: runtimePidfile) }
}
