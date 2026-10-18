import Foundation
import Testing
@testable import Jarvis

// V1.0 autonomous engineering pipeline — worker selection by capability, cost policy, the REAL ModelRouter given an engineering assignment's profile (local chat model never codes; paid and
// unknown-price never automatic; an explicit choice never falls back), review independence and the review rubric. Worker ids are synthetic: nothing here depends on a brand name.

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func worker(_ id: String, caps: Set<WorkerCapability> = [.codeGeneration, .codeReview, .testGeneration, .debugging, .repositoryAnalysis], pricing: WorkerPricing = .verifiedZero, local: Bool = false, premium: Bool = false, ctx: Int = 64_000, bench: Double? = nil, mem: Int = 0, available: Bool = true) -> WorkerProfile {
    var w = WorkerProfile(id: id, capabilities: caps, pricing: pricing)
    w.isLocalConversationalModel = local; w.premiumReasoning = premium; w.contextTokens = ctx; w.benchmarkSuccess = bench; w.residentMemoryMB = mem; w.available = available
    return w
}

private func assignment(risk: RiskClass = .low, caps: Set<WorkerCapability> = [.codeGeneration], pref: String = "auto") -> EngineeringAssignment {
    var a = EngineeringAssignment(objective: "Fix add() in calc.py", project: "p")
    a.scope.allowed = ["calc.py"]; a.risk = risk; a.requiredCapabilities = caps; a.providerPreference = pref
    return a
}

@Suite("V1.0 engineering · capability-based worker selection")
struct WorkerSelectorTests {
    @Test("the local conversational model is never a coding, testing or review worker, whatever its capabilities claim")
    func localChat() {
        let local = worker("tiny", local: true), free = worker("alpha")
        for needs: Set<WorkerCapability> in [[.codeGeneration], [.testGeneration], [.codeReview], [.debugging], [.architecture]] {
            let s = WorkerSelector.select(needs: needs, complexity: .simple, workers: [worker("tiny", caps: Set(WorkerCapability.allCases), local: true), free])
            #expect(s.chosen != "tiny" && s.rejected["tiny"]?.contains("local conversational model") == true, Comment(rawValue: "\(needs)"))
        }
        let only = WorkerSelector.select(needs: [.codeGeneration], complexity: .simple, workers: [local])
        #expect(only.chosen == nil && only.reason == "no eligible worker")
        let explicit = WorkerSelector.select(needs: [.codeGeneration], complexity: .simple, workers: [worker("tiny", local: true), free], explicitChoice: "tiny")
        #expect(explicit.chosen == nil && explicit.reason.contains("no fallback"), "even an explicit choice cannot make the local chat model a coder")
    }

    @Test("cost policy: paid only when explicitly chosen; unknown price is never free; verified-free before subscription")
    func cost() {
        let paid = worker("paid1", pricing: .paid, premium: true), unknown = worker("mystery", pricing: .unknown), sub = worker("sub1", pricing: .subscription, premium: true), free = worker("free1")
        let s = WorkerSelector.select(needs: [.codeGeneration], complexity: .simple, workers: [paid, unknown, sub, free])
        #expect(s.chosen == "free1" && s.ranked == ["free1", "sub1"] && s.rejected["paid1"] != nil && s.rejected["mystery"] == "unknown price is never free")
        let onlyPaid = WorkerSelector.select(needs: [.codeGeneration], complexity: .simple, workers: [paid, unknown])
        #expect(onlyPaid.chosen == nil)
        let explicit = WorkerSelector.select(needs: [.codeGeneration], complexity: .simple, workers: [paid, free], explicitChoice: "paid1")
        #expect(explicit.chosen == "paid1" && explicit.ranked == ["paid1"], "an explicit, user-made choice may use a paid worker")
        let a = assignment(pref: "paid1")
        #expect(WorkerSelector.select(for: a, workers: [paid, free]).chosen == "paid1")
        #expect(WorkerSelector.select(for: assignment(), workers: [paid, free]).chosen == "free1")
    }

    @Test("an explicit choice never falls back: unavailable, unregistered, excluded or ineligible means NO worker, not another one")
    func explicit() {
        let a = worker("a1"), b = worker("b1", available: false)
        for (ws, pick) in [([a, b], "b1"), ([a], "ghost"), ([worker("a1"), worker("c1", caps: [.research])], "c1")] {
            let s = WorkerSelector.select(needs: [.codeGeneration], complexity: .simple, workers: ws, explicitChoice: pick)
            #expect(s.chosen == nil && s.ranked.isEmpty && s.reason.contains("no fallback"), Comment(rawValue: pick))
        }
        #expect(WorkerSelector.select(needs: [.codeGeneration], complexity: .simple, workers: [a], explicitChoice: "a1", excluding: ["a1"]).chosen == nil)
    }

    @Test("complex / critical work needs a premium-reasoning worker and prefers it even over a free one; context and memory pressure are respected")
    func complexity() {
        let free = worker("free1"), premium = worker("prem1", pricing: .subscription, premium: true)
        #expect(WorkerSelector.select(needs: [.codeGeneration], complexity: .simple, workers: [free, premium]).chosen == "free1")
        let hard = WorkerSelector.select(needs: [.codeGeneration], complexity: .complex, workers: [free, premium])
        #expect(hard.chosen == "prem1" && hard.rejected["free1"]?.contains("premium") == true)
        #expect(WorkerSelector.select(needs: [.codeGeneration], complexity: .critical, workers: [free]).chosen == nil)
        #expect(WorkerSelector.select(needs: [.codeGeneration], complexity: .simple, workers: [worker("small", ctx: 8_000), worker("big", ctx: 128_000)], estimatedContextTokens: 20_000).chosen == "big")
        #expect(WorkerSelector.select(needs: [.codeGeneration], complexity: .simple, workers: [worker("heavy", mem: 6_500), worker("light", mem: 300)], memoryPressure: true).chosen == "light")
        #expect(WorkerSelector.select(needs: [.unity, .codeGeneration], complexity: .simple, workers: [worker("generic"), worker("unity1", caps: [.codeGeneration, .unity])]).chosen == "unity1")
    }

    @Test("ranking uses benchmark evidence, then the tighter context fit, then a stable id order — deterministic")
    func ranking() {
        let ws = [worker("zeta", bench: 0.9), worker("alpha", bench: 0.9), worker("mid", bench: 0.95), worker("never")]
        let s = WorkerSelector.select(needs: [.codeGeneration], complexity: .simple, workers: ws)
        #expect(s.ranked == ["mid", "alpha", "zeta", "never"])
        #expect(WorkerSelector.select(needs: [.codeGeneration], complexity: .simple, workers: ws.reversed()).ranked == s.ranked)
        #expect(WorkerSelector.select(needs: [.codeGeneration], complexity: .simple, workers: ws, excluding: ["mid"]).chosen == "alpha")
    }
}

@Suite("V1.0 engineering · the REAL router given an engineering profile")
struct EngineeringRoutingTests {
    private func model(_ id: String, pricing: PricingStatus = .verifiedZero) -> ModelRecord {
        var m = ModelRecord(id: "opencode/\(id)", engine: .openCode, provider: "opencode", providerModelID: id, displayName: id)
        m.availability = .available; m.pricingStatus = pricing
        if pricing == .verifiedZero { m.inputPrice = 0; m.outputPrice = 0; m.freeVerified = true; m.freeVerifiedAt = now.addingTimeInterval(-60); m.freeVerificationSource = "test" }
        m.dataPolicy = .zeroRetention; m.contextLimit = 200_000
        return m
    }
    private func benchmarks(_ id: String) -> [String: [BenchmarkGroup: BenchmarkSummary]] {
        func s(_ g: BenchmarkGroup) -> BenchmarkSummary { BenchmarkSummary(group: g, total: 4, passed: 4, malformed: 0, medianLatencyMS: 1000, lastRanAt: now.addingTimeInterval(-3600)) }
        return ["opencode/\(id)": [.general: s(.general), .coding: s(.coding), .testing: s(.testing), .research: s(.research)]]
    }
    private func snapshot(pref: ProviderPreference = .auto, local: ProviderState = .ready, openCode: ProviderState = .ready, claude: ProviderState = .ready, codex: ProviderState = .ready, models: [ModelRecord]? = nil) -> RouterSnapshot {
        var s = RouterSnapshot()
        s.now = now; s.preference = pref
        s.engines = [.local: EngineAvailability(.local, state: local), .openCode: EngineAvailability(.openCode, state: openCode), .claudeCode: EngineAvailability(.claudeCode, state: claude), .codex: EngineAvailability(.codex, state: codex)]
        s.models = models ?? [model("alpha-free")]
        s.benchmarks = benchmarks("alpha-free")
        return s
    }

    @Test("a coding assignment is NEVER routed to the local model — not in Auto, not when it is the only engine ready, not when the user picked it")
    func localNeverCodes() {
        let p = assignment().routingProfile()
        #expect(p.isDevelopment && !LocalModelPolicy.evaluate(p).eligible)
        let auto = ModelRouter.route(p, snapshot: snapshot(openCode: .notInstalled, claude: .notInstalled, codex: .notInstalled))
        #expect(auto.selected?.engine != .local, Comment(rawValue: "\(auto.outcome)"))
        let explicit = ModelRouter.route(p, snapshot: snapshot(pref: .local))
        #expect(explicit.selected == nil, "an explicit local choice for development work is refused, not rerouted")
        for caps: Set<WorkerCapability> in [[.testGeneration], [.codeReview], [.debugging]] {
            let q = assignment(caps: caps).routingProfile()
            #expect(ModelRouter.route(q, snapshot: snapshot(openCode: .notInstalled, claude: .notInstalled, codex: .notInstalled)).selected?.engine != .local)
        }
    }

    @Test("routine assignments take the verified-free OpenCode model; unknown price is never routed automatically; heavy / critical work goes to the premium subscription tools")
    func tiers() {
        let routine = ModelRouter.route(assignment().routingProfile(), snapshot: snapshot())
        #expect(routine.selected?.engine == .openCode && routine.selected?.model == "opencode/alpha-free")
        let unknown = ModelRouter.route(assignment().routingProfile(), snapshot: snapshot(openCode: .ready, claude: .notInstalled, codex: .notInstalled, models: [model("mystery", pricing: .unknown)]))
        #expect(unknown.selected == nil || unknown.selected?.engine != .openCode, "an unknown price is not free")
        let hard = ModelRouter.route(assignment(risk: .critical).routingProfile(), snapshot: snapshot())
        #expect(hard.selected?.engine == .claudeCode || hard.selected?.engine == .codex, Comment(rawValue: "\(hard.outcome)"))
        let arch = ModelRouter.route(assignment(caps: [.architecture]).routingProfile(), snapshot: snapshot())
        #expect(arch.selected?.engine != .openCode && arch.selected?.engine != .local)
    }

    @Test("an explicit provider choice never falls back, and when no verified-free worker exists the router does not silently use a paid API")
    func noFallbackNoPaid() {
        let p = assignment().routingProfile()
        let claudeDown = ModelRouter.route(p, snapshot: snapshot(pref: .claudeCode, claude: .notInstalled))
        #expect(claudeDown.selected == nil, "explicit Claude Code unavailable: refused, not rerouted to Codex or OpenCode")
        let freeOnlyMissing = ModelRouter.route(p, snapshot: snapshot(openCode: .notInstalled, claude: .notInstalled, codex: .notInstalled, models: []))
        #expect(freeOnlyMissing.selected == nil, "nothing eligible: the router refuses; there is no paid API fallback in the candidate set")
        for d in [ModelRouter.route(p, snapshot: snapshot()), claudeDown, freeOnlyMissing] { #expect(d.selected.map { [.local, .openCode, .claudeCode, .codex].contains($0.engine) } ?? true) }
    }
}

@Suite("V1.0 engineering · review independence and the review rubric")
struct ReviewPolicyTests {
    private func v(_ status: WorkVerificationStatus = .verified, findings: [EngineeringFinding] = [], files: Int = 1, lines: Int = 4) -> VerificationVerdict {
        VerificationVerdict(status: status, findings: findings, mismatches: [], unmetCriteria: [], missingStages: [], revision: "r", attribution: AttributionReport(changes: [AttributedChange(change: FileChange(path: "calc.py", kind: .modified, beforeHash: "a", afterHash: "b", isBinary: false), attribution: .taskProduced, workerID: "w", stepKey: "s")], lostEdits: [], preexistingUntouched: []), diffStats: DiffStats(files: files, linesAdded: lines, linesRemoved: 0))
    }

    @Test("a trivial clean change gets no model reviewer; risk, breadth, sensitive files and major findings escalate; elevated plans require an independent review")
    func mode() {
        #expect(ReviewPolicy.mode(assignment: assignment(), verdict: v(), plan: nil) == .deterministicOnly)
        #expect(ReviewPolicy.mode(assignment: assignment(risk: .medium), verdict: v(), plan: nil) == .modelReview)
        #expect(ReviewPolicy.mode(assignment: assignment(), verdict: v(files: 5, lines: 200), plan: nil) == .modelReview)
        #expect(ReviewPolicy.mode(assignment: assignment(risk: .high), verdict: v(), plan: nil) == .independentModelReview)
        #expect(ReviewPolicy.mode(assignment: assignment(), verdict: v(.needsReview, findings: [EngineeringFinding(.guardChanged, .major, path: "g.sh", "x", evidence: "e")]), plan: nil) == .independentModelReview)
        let elevated = VerificationPlanner.plan(changedPaths: ["scripts/verify.sh"], profiles: ProjectVerificationProfiles(unitTests: "u", build: "b"))
        #expect(ReviewPolicy.mode(assignment: assignment(), verdict: v(), plan: elevated) == .independentModelReview)
    }

    @Test("the reviewer is NOT the implementer when independence is required and a zero-extra-cost alternative exists; the result says honestly when it could not be")
    func reviewer() {
        let ws = [worker("impl"), worker("other"), worker("paidx", pricing: .paid, premium: true)]
        let r = ReviewPolicy.reviewer(implementer: "impl", mode: .independentModelReview, workers: ws)
        #expect(r.id == "other" && r.independent)
        let solo = ReviewPolicy.reviewer(implementer: "impl", mode: .independentModelReview, workers: [worker("impl"), worker("paidx", pricing: .paid)])
        #expect(solo.id == "impl" && !solo.independent, "no free alternative: the same worker reviews and the report says it was not independent")
        #expect(ReviewPolicy.reviewer(implementer: "impl", mode: .deterministicOnly, workers: ws).id == nil)
        #expect(ReviewPolicy.reviewer(implementer: "impl", mode: .modelReview, workers: ws).id != nil)
    }

    @Test("only BLOCKER findings block; model findings count only with verifiable evidence; style preferences never block")
    func rubric() {
        let withFindings = v(.needsReview, findings: [EngineeringFinding(.placeholderComment, .minor, path: "calc.py", "a TODO", evidence: "# TODO"), EngineeringFinding(.assertionChanged, .major, path: "tests/t.py", "changed", evidence: "assertEqual")])
        let diff = "--- calc.py\n+ return a + b\n+ x = compute_total(items)"
        let model: [ModelFinding] = [
            ModelFinding(text: "off-by-one in the loop", severity: .blocker, dimension: .correctness, evidence: "x = compute_total(items)"),
            ModelFinding(text: "I would name this differently", severity: .blocker, dimension: .maintainability, evidence: "naming"),
            ModelFinding(text: "invented problem", severity: .blocker, dimension: .security, evidence: "this text is nowhere in the diff"),
            ModelFinding(text: "style nit", severity: .minor, dimension: .maintainability, evidence: "x = compute_total(items)"),
        ]
        let r = ReviewRubric.evaluate(verdict: v(.needsReview), modelFindings: model, condensedDiff: diff)
        #expect(r.blocking.map(\.message) == ["off-by-one in the loop"] && r.rejectedModelFindings.count == 2 && r.advisory.contains { $0.message == "style nit" } && !r.passes)
        let none = ReviewRubric.evaluate(verdict: withFindings, modelFindings: [], condensedDiff: diff)
        #expect(none.passes && none.blocking.isEmpty && none.advisory.count == 2, "minor and major findings are advice here (a major asks for a decision elsewhere), never a blocker")
        #expect(none.dimensions[.performance] == .notAssessed && none.dimensions[.correctness] != .notAssessed && none.dimensions[.tests] == .concern)
        let blocker = ReviewRubric.evaluate(verdict: v(.failed, findings: [EngineeringFinding(.secretIntroduced, .blocker, path: "c.py", "s", evidence: "line 1")]), modelFindings: [], condensedDiff: "")
        #expect(blocker.dimensions[.security] == .fail && !blocker.passes)
    }

    @Test("the reviewer's packet carries the objective, the criteria, deterministic findings and the ACTUAL condensed diff — never the implementer's own prose")
    func packet() {
        var a = assignment(); a.acceptance = [AcceptanceCriterion(id: "c1", text: "tests pass", check: .profile("unit"))]
        let claim = "I carefully verified everything works perfectly and all edge cases are handled"
        let p = ReviewRubric.packet(assignment: a, verdict: v(.needsReview, findings: [EngineeringFinding(.assertionChanged, .major, path: "t.py", "an expectation changed", evidence: "assertEqual")]), condensedDiff: "--- calc.py\n+ return a + b")
        #expect(p.contains("REVIEW OBJECTIVE") && p.contains("[c1]") && p.contains("MAJOR assertionChanged") && p.contains("ACTUAL DIFF") && p.contains("+ return a + b") && p.contains("Style preferences are not findings"))
        #expect(!p.contains(claim) && p.count <= 9_000)
        _ = claim
    }
}
