import Testing
import Foundation
@testable import Jarvis

private typealias F = RouteFixtures

@Suite("Model router")
struct ModelRouterTests {
    private let codingPrompt = "Fix the null reference bug in PlayerController.cs and explain the compiler error."
    private let simplePrompt = "Summarize in one sentence: The cat sat on the mat and then slept."

    // MARK: Local eligibility

    @Test func aSimpleBoundedTaskRoutesToLocal() {
        let d = ModelRouter.route(F.profile(simplePrompt), snapshot: F.snapshot())
        #expect(d.selected == RoutingCandidate(engine: .local, model: nil))
        #expect(d.reasons["tier"] == "lightweight-local-first" && d.reasons["localEligible"] == "true")
        #expect(d.fallbacks.first?.engine == .openCode)                          // bounded fallback chain, free before premium
    }

    @Test func codingTestingAndRepositoryWorkNeverRouteLocal() {
        let prompts = [codingPrompt, "Write unit tests for the inventory class and run the tests", "Edit the file Inventory.swift and commit the change",
                       "Review this code for security problems", "Fix my Unity multiplayer system"]
        for prompt in prompts {
            for pref in [ProviderPreference.auto] {
                let d = ModelRouter.route(F.profile(prompt), snapshot: F.snapshot(pref))
                #expect(d.selected?.engine != .local, "\(prompt)")
                #expect(!d.fallbacks.contains { $0.engine == .local }, "\(prompt)")
                #expect(d.reasons["localModelIneligible"] == "true")
                #expect(d.rejected["local"]?.hasPrefix("policy:") == true)
            }
        }
    }

    @Test func explicitLocalIsRefusedForDevelopmentWorkWithoutFallback() {
        let d = ModelRouter.route(F.profile(codingPrompt), snapshot: F.snapshot(.local))
        guard case .refused(.localForbiddenForTask(let why)) = d.outcome else { Issue.record("expected refusal, got \(d.outcome)"); return }
        #expect(why.contains("requiresCoding") || why.contains { $0.hasPrefix("category:") })
        #expect(d.fallbacks.isEmpty && d.selected == nil)
        #expect(d.refusalMessage()?.contains("lightweight") == true)
    }

    @Test func explicitLocalWorksForLightweightTasksAndNeverFallsBackWhenDown() {
        #expect(ModelRouter.route(F.profile(simplePrompt), snapshot: F.snapshot(.local)).selected?.engine == .local)
        let down = ModelRouter.route(F.profile(simplePrompt), snapshot: F.snapshot(.local, local: .unavailable("runtime missing")))
        guard case .refused(.engineUnavailable(.local, _)) = down.outcome else { Issue.record("must refuse, got \(down.outcome)"); return }
    }

    @Test func localIsSkippedUnderMemoryPressureOrWhileAnotherLocalJobRuns() {
        var s = F.snapshot(); s.resources.memory = .warning
        var d = ModelRouter.route(F.profile(simplePrompt), snapshot: s)
        #expect(d.selected?.engine != .local && d.rejected["local"]?.hasPrefix("resource:memory") == true)
        s = F.snapshot(); s.resources.localJobsRunning = 1
        d = ModelRouter.route(F.profile(simplePrompt), snapshot: s)
        #expect(d.selected?.engine != .local && d.rejected["local"] == "resource:localJobBusy")
        s = F.snapshot(); s.resources.thermalSerious = true
        #expect(ModelRouter.route(F.profile(simplePrompt), snapshot: s).selected?.engine != .local)
    }

    // MARK: Development routing

    @Test func codingRoutesToAVerifiedBenchmarkedFreeModel() {
        let d = ModelRouter.route(F.profile(codingPrompt), snapshot: F.snapshot())
        #expect(d.selected == RoutingCandidate(engine: .openCode, model: "opencode/alpha-free"))
        #expect(d.reasons["freeVerified"] == "true" && d.reasons["providerReady"] == "true" && d.reasons["codingBenchmarkPassed"] == "true")
        #expect(d.reasons["benchmark.coding"] == "4/4" && d.reasons["tier"] == "development-free-first" && d.reasons["localModelIneligible"] == "true")
        #expect(d.fallbacks.map(\.engine) == [.claudeCode, .codex])
    }

    @Test func noSuitableFreeModelEscalatesToClaudeThenCodex() {
        var d = ModelRouter.route(F.profile(codingPrompt), snapshot: F.snapshot(models: []))
        #expect(d.selected?.engine == .claudeCode && d.fallbacks.map(\.engine) == [.codex])
        #expect(d.reasons["escalationReason"]?.hasPrefix("noFreeModel") == true)
        d = ModelRouter.route(F.profile(codingPrompt), snapshot: F.snapshot(claude: .authenticationRequired, models: []))
        #expect(d.selected?.engine == .codex && d.rejected["claudeCode"] == "unavailable:sign-in required")
        d = ModelRouter.route(F.profile(codingPrompt), snapshot: F.snapshot(openCode: .notInstalled, claude: .notInstalled, codex: .notInstalled))
        guard case .refused(.noCandidate) = d.outcome else { Issue.record("nothing ready must refuse, got \(d.outcome)"); return }
    }

    @Test func unbenchmarkedOrFailingModelsAreNotAutoEligible() {
        let none = F.snapshot(benchmarks: [:])
        #expect(ModelRouter.route(F.profile(codingPrompt), snapshot: none).selected?.engine == .claudeCode)
        let weak = F.snapshot(benchmarks: ["opencode/alpha-free": [.coding: F.summary(.coding, passed: 1, total: 4), .general: F.summary(.general, passed: 3, total: 3)]])
        let d = ModelRouter.route(F.profile(codingPrompt), snapshot: weak)
        #expect(d.selected?.engine == .claudeCode && d.rejected["opencode/alpha-free"]?.hasPrefix("benchmark:coding") == true)
        let tooFew = F.snapshot(benchmarks: ["opencode/alpha-free": [.coding: F.summary(.coding, passed: 2, total: 2)]])
        #expect(ModelRouter.route(F.profile(codingPrompt), snapshot: tooFew).selected?.engine == .claudeCode)       // 2 cases < required 4
        var old = F.snapshot(); old.now = F.now.addingTimeInterval(30 * 24 * 3600)
        old.models = [F.freeModel("alpha-free", verifiedAgo: 60)]
        #expect(ModelRouter.route(F.profile(codingPrompt), snapshot: old).selected?.engine != .openCode)             // stale benchmark + stale free verification
    }

    @Test func unknownPaidDisabledStaleAndCooldownModelsAreNeverAutoSelected() {
        var unknown = F.freeModel("u-free"); unknown.pricingStatus = .unknown; unknown.freeVerified = false; unknown.blockedReason = "provider data: price unknown"
        var paid = F.freeModel("p-free"); paid.pricingStatus = .paid; paid.freeVerified = false; paid.blockedReason = "provider data: price > 0"
        var disabled = F.freeModel("d-free"); disabled.enabled = false; disabled.blockedReason = "disabled by user"
        var unavailable = F.freeModel("x-free"); unavailable.availability = .unavailable
        let stale = F.freeModel("s-free", verifiedAgo: 2 * 24 * 3600)
        let cool = F.freeModel("c-free")
        let all = [unknown, paid, disabled, unavailable, stale, cool]
        var bench: [String: [BenchmarkGroup: BenchmarkSummary]] = [:]
        for m in all { bench[m.id] = [.coding: F.summary(.coding, passed: 4, total: 4)] }
        var s = F.snapshot(models: all, benchmarks: bench)
        s.modelCooldowns[cool.id] = F.now.addingTimeInterval(600)
        let d = ModelRouter.route(F.profile(codingPrompt), snapshot: s)
        #expect(d.selected?.engine == .claudeCode)
        for m in all { #expect(d.rejected[m.id] != nil, "\(m.id) must be rejected") }
        #expect(d.rejected[unknown.id] == "provider data: price unknown" && d.rejected[stale.id] == "freeVerification:stale" && d.rejected[cool.id] == "cooldown")
        // …and explicit OpenCode Free refuses too (no fallback to premium).
        s.preference = .openCodeFree
        let e = ModelRouter.route(F.profile(codingPrompt), snapshot: s)
        guard case .refused(.noEligibleFreeModel) = e.outcome else { Issue.record("expected refusal, got \(e.outcome)"); return }
        #expect(e.fallbacks.isEmpty)
    }

    @Test func theBestBenchmarkedFreeModelWinsAndTiesAreDeterministic() {
        let a = F.freeModel("a-free"), b = F.freeModel("b-free"), c = F.freeModel("c-free")
        let bench: [String: [BenchmarkGroup: BenchmarkSummary]] = [
            a.id: [.coding: F.summary(.coding, passed: 3, total: 4, latency: 500)],
            b.id: [.coding: F.summary(.coding, passed: 4, total: 4, latency: 900)],
            c.id: [.coding: F.summary(.coding, passed: 4, total: 4, latency: 400)]]
        let d = ModelRouter.route(F.profile(codingPrompt), snapshot: F.snapshot(models: [a, b, c], benchmarks: bench))
        #expect(d.selected?.model == "opencode/c-free")                           // 4/4 and fastest
        #expect(d.fallbacks.prefix(2).compactMap(\.model) == ["opencode/b-free", "opencode/a-free"])
        let d2 = ModelRouter.route(F.profile(codingPrompt), snapshot: F.snapshot(models: [c, a, b], benchmarks: bench))
        #expect(d2 == d)                                                          // input order does not matter
    }

    // MARK: Heavy work, privacy

    @Test func architectureSecurityAndComplexWorkGoStraightToPremium() {
        for prompt in ["Design the architecture for a scalable multiplayer backend and explain the trade-offs",
                       "Is my OAuth login flow secure? Analyse the vulnerabilities."] {
            let d = ModelRouter.route(F.profile(prompt), snapshot: F.snapshot())
            #expect(d.selected?.engine == .claudeCode, "\(prompt)")
            #expect(d.reasons["tier"] == "heavy-premium-only" && d.rejected["openCode"] == "tier:heavy" && !d.fallbacks.contains { $0.engine == .openCode })
        }
    }

    @Test func sensitiveTasksNeverReachFreeCloud() {
        let prompt = "My password is hunter2 and my api key is sk-proj-ABCDEFGHIJKLMNOPQRSTUV123456. Explain how to rotate them."
        let p = F.profile(prompt)
        #expect(p.privacy == .sensitive)
        for pref in [ProviderPreference.auto, .openCodeFree] {
            let d = ModelRouter.route(p, snapshot: F.snapshot(pref))
            #expect(d.selected?.engine != .openCode && !d.fallbacks.contains { $0.engine == .openCode })
            if pref == .openCodeFree { guard case .refused(.sensitiveBlockedFromFreeCloud) = d.outcome else { Issue.record("must refuse"); return } }
            else { #expect(d.rejected["openCode"] == "privacy:sensitive") }
        }
        var s = F.snapshot(); s.settings.allowSensitiveOnFreeCloud = true           // explicit policy permission
        #expect(ModelRouter.route(F.profile("Explain how neural networks work. My password is hunter2"), snapshot: s).selected?.engine == .openCode)
    }

    @Test func projectCodeOnlyGoesToZeroRetentionFreeModels() {
        let mayTrain = F.freeModel("train-free", policy: .mayTrain), zero = F.freeModel("zero-free", policy: .zeroRetention)
        let bench: [String: [BenchmarkGroup: BenchmarkSummary]] = [mayTrain.id: [.coding: F.summary(.coding, passed: 4, total: 4, latency: 100)],
                                                                   zero.id: [.coding: F.summary(.coding, passed: 4, total: 4, latency: 900)]]
        let prompt = "Why does this crash?\n```csharp\nvar x = player.GetComponent<Rigidbody>();\nx.AddForce(Vector3.up);\n```"
        let d = ModelRouter.route(F.profile(prompt), snapshot: F.snapshot(models: [mayTrain, zero], benchmarks: bench))
        #expect(d.selected?.model == "opencode/zero-free" && d.rejected[mayTrain.id] == "dataPolicy:mayTrain")
        let onlyTrain = ModelRouter.route(F.profile(prompt), snapshot: F.snapshot(models: [mayTrain], benchmarks: bench))
        #expect(onlyTrain.selected?.engine == .claudeCode)
        // A non-code question may use a "may train" model (public knowledge).
        let general = F.snapshot(models: [mayTrain], benchmarks: [mayTrain.id: [.general: F.summary(.general, passed: 3, total: 3)]])
        #expect(ModelRouter.route(F.profile("Explain how neural networks work."), snapshot: general).selected?.model == "opencode/train-free")
    }

    // MARK: Explicit preferences never fall back silently

    @Test func explicitProviderChoicesNeverFallBack() {
        let down = F.snapshot(.claudeCode, claude: .authenticationRequired)
        let d = ModelRouter.route(F.profile(codingPrompt), snapshot: down)
        guard case .refused(.engineUnavailable(.claudeCode, _)) = d.outcome else { Issue.record("must refuse, got \(d.outcome)"); return }
        #expect(d.fallbacks.isEmpty)
        #expect(ModelRouter.route(F.profile(codingPrompt), snapshot: F.snapshot(.codex)).selected?.engine == .codex)
        #expect(ModelRouter.route(F.profile(codingPrompt), snapshot: F.snapshot(.claudeCode, codex: .ready)).selected?.engine == .claudeCode)
        let busy = ModelRouter.route(F.profile(codingPrompt), snapshot: F.snapshot(.codex, codex: .running))
        guard case .refused = busy.outcome else { Issue.record("a running provider is not selectable"); return }
    }

    @Test func explicitOpenCodeFreeUsesVerifiedModelsEvenWithoutABenchmark() {
        let d = ModelRouter.route(F.profile(codingPrompt), snapshot: F.snapshot(.openCodeFree, benchmarks: [:]))
        #expect(d.selected?.model == "opencode/alpha-free" && d.fallbacks.isEmpty && d.reasons["tier"] == "explicit")
        #expect(d.reasons["benchmark.coding"] == "none" && d.reasons["codingBenchmarkPassed"] == "false")
    }

    @Test func cooldownRemovesAnEngineFromSelection() {
        var s = F.snapshot()
        s.engines[.openCode]?.cooldownUntil = F.now.addingTimeInterval(120)
        #expect(ModelRouter.route(F.profile(codingPrompt), snapshot: s).selected?.engine == .claudeCode)
        s.engines[.openCode]?.cooldownUntil = F.now.addingTimeInterval(-1)              // expired
        #expect(ModelRouter.route(F.profile(codingPrompt), snapshot: s).selected?.engine == .openCode)
    }

    @Test func noPaidAPIEngineExistsAnywhereInTheRoutingSpace() {
        for e in ProviderID.allCases { #expect(e.costClass != .paidAPI) }
        #expect(Set(ProviderPreference.allCases.compactMap(\.providerID)) == Set(ProviderID.allCases))
    }

    // MARK: Reasons

    @Test func everyDecisionCarriesAStableMachineReadableReason() throws {
        let d = ModelRouter.route(F.profile(codingPrompt), snapshot: F.snapshot())
        let json = try #require(try JSONSerialization.jsonObject(with: Data(d.reasonJSON.utf8)) as? [String: String])
        for key in ["mode", "outcome", "selected", "tier", "coding", "freeVerified", "freeVerifiedAt", "providerReady", "localModelIneligible", "privacy", "dataPolicy", "benchmark.coding"] {
            #expect(json[key] != nil, "missing \(key): \(d.reasonJSON)")
        }
        #expect(json["outcome"] == "selected" && json["selected"] == "opencode/alpha-free")
        #expect(ModelRouter.route(F.profile(codingPrompt), snapshot: F.snapshot()).reasonJSON == d.reasonJSON)      // deterministic
        let refused = ModelRouter.route(F.profile(codingPrompt), snapshot: F.snapshot(.local))
        #expect(refused.reasonJSON.contains("\"outcome\":\"refused\""))
    }
}

@Suite("Benchmark summaries and cooldown policy")
struct BenchmarkAndCooldownTests {
    private func r(_ id: String, group: BenchmarkGroup = .coding, passed: Bool, ago: TimeInterval = 100, latency: Double = 1000, suite: String = "v1") -> BenchmarkResultRecord {
        BenchmarkResultRecord(modelID: "m", suite: suite, caseID: id, category: group, passed: passed, validation: nil, latencyMS: latency, durationMS: latency,
                              ranAt: F.now.addingTimeInterval(-ago))
    }

    @Test func onlyTheNewestResultPerCaseCountsAndOtherSuitesAreIgnored() throws {
        let s = try #require(BenchmarkSummary.summarize([r("a", passed: false, ago: 500), r("a", passed: true, ago: 100), r("b", passed: true), r("c", passed: false),
                                                         r("zz", passed: true, suite: "old")], group: .coding, suite: "v1"))
        #expect(s.total == 3 && s.passed == 2 && s.label == "2/3")
        #expect(BenchmarkSummary.summarize([], group: .coding, suite: "v1") == nil)
    }

    @Test func eligibilityNeedsEnoughCasesPassRateAndFreshness() {
        let pol = BenchmarkPolicy()
        #expect(pol.isEligible(F.summary(.coding, passed: 4, total: 4), group: .coding, now: F.now))
        #expect(pol.isEligible(F.summary(.coding, passed: 3, total: 4), group: .coding, now: F.now))
        #expect(!pol.isEligible(F.summary(.coding, passed: 2, total: 4), group: .coding, now: F.now))
        #expect(!pol.isEligible(F.summary(.coding, passed: 3, total: 3), group: .coding, now: F.now))               // only 3 of the 4 required cases
        #expect(!pol.isEligible(nil, group: .general, now: F.now))
        #expect(!pol.isEligible(F.summary(.general, passed: 3, total: 3), group: .general, now: F.now.addingTimeInterval(20 * 24 * 3600)))
    }

    @Test func cooldownGrowsExponentiallyAndIsCapped() {
        let c = CooldownPolicy(baseSeconds: 60, maxSeconds: 1800, threshold: 2)
        #expect(c.duration(forConsecutiveFailures: 0) == 0 && c.duration(forConsecutiveFailures: 1) == 0)
        #expect(c.duration(forConsecutiveFailures: 2) == 60 && c.duration(forConsecutiveFailures: 3) == 120 && c.duration(forConsecutiveFailures: 4) == 240)
        #expect(c.duration(forConsecutiveFailures: 20) == 1800)
    }
}
