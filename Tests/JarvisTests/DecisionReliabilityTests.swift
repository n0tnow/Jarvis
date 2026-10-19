import Foundation
import Testing
@testable import Jarvis

// V1.0 reliability pass — confidence policy, remote-classifier routing / retry / cache, the presentation contract and claim firewall, language consistency and the freshness policy. Pure logic: runs anywhere
// Swift runs. No model, no network, no microphone; the remote classifier is a scripted transport.

private func jev(_ intent: DecisionIntent, _ confidence: Double, page: String? = nil) -> Decision {
    DecisionPolicy.finalize(intent: intent, confidence: confidence, normalized: "", target: page, action: page == nil ? nil : "navigate", deepReasoning: false, provenance: .jevShadow, provider: .jev)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// A scripted transport: each call asks `script(callNumber)` to answer or throw.
private struct ScriptedTransport: JevTransport {
    let counter: Counter
    let script: @Sendable (Int) throws -> JevClassification
    func complete(_ request: JevClassifyRequest, modelAlias: String, timeout: TimeInterval) async throws -> JevClassification { try script(counter.next()) }
}

private final class FixedProvider: DecisionProviding, @unchecked Sendable {
    let counter = Counter()
    let answer: Decision
    init(_ d: Decision) { answer = d }
    func decide(_ context: JevDecisionContext, config: JevConfig) async -> DecisionProviderResult { _ = counter.next(); return .decision(answer, latency: 0.1) }
}

private func context(_ text: String) -> JevDecisionContext {
    JevContextBuilder.build(utterance: text, language: "tr", source: .typed, previousInterpretation: "conversation", projectNames: ["Hamam"], config: JevConfig())!
}

// MARK: Confidence policy

@Suite("V1.0 reliability · confidence policy")
struct ConfidencePolicyTests {
    @Test("categories follow risk and effect, not the intent name alone")
    func categories() {
        #expect(ConfidencePolicy.category(of: jev(.systemStatus, 1)) == .readOnly)
        #expect(ConfidencePolicy.category(of: jev(.jarvisNavigation, 1, page: "system")) == .ownUI)
        #expect(ConfidencePolicy.category(of: jev(.macosApplicationAction, 1)) == .executing)
        #expect(ConfidencePolicy.category(of: jev(.computerUse, 1)) == .computer)
        #expect(ConfidencePolicy.category(of: DecisionPolicy.finalize(intent: .projectTask, confidence: 1, normalized: "", target: nil, action: "delete", deepReasoning: false, provenance: .jevShadow, provider: .jev)) == .policyGated)
    }

    @Test("a read-only answer may be accepted at a lower confidence than an own-UI change; nothing else is ever accepted from a remote classifier")
    func remote() {
        let p = ConfidencePolicy.standard
        #expect(p.accepts(jev(.systemStatus, 0.90), source: .remote))
        #expect(!p.accepts(jev(.systemStatus, 0.80), source: .remote))
        #expect(!p.accepts(jev(.jarvisNavigation, 0.90, page: "system"), source: .remote))
        #expect(p.accepts(jev(.jarvisNavigation, 0.95, page: "system"), source: .remote))
        for intent in [DecisionIntent.macosApplicationAction, .computerUse, .projectOpen, .projectTask, .settingsChange, .stopSpeech, .cancelTask, .research] {
            #expect(!p.accepts(jev(intent, 1.0), source: .remote), Comment(rawValue: intent.rawValue))           // confidence 1.0 still buys nothing
        }
    }

    @Test("confidence never overrides a gate, a risk class or an ambiguity; the user's own floor can only raise the bar")
    func neverOverrides() {
        var blocked = jev(.systemStatus, 1.0); blocked.gate = .blocked
        var risky = jev(.systemStatus, 1.0); risky.riskClass = .high
        var ambiguous = jev(.systemStatus, 1.0); ambiguous.ambiguity = .ambiguous(question: "which?")
        for d in [blocked, risky, ambiguous] { #expect(!ConfidencePolicy.standard.accepts(d, source: .remote)) }
        #expect(!ConfidencePolicy.standard.accepts(jev(.systemStatus, 0.95), source: .remote, configuredFloor: 0.99))
        #expect(ConfidencePolicy.standard.accepts(jev(.systemStatus, 0.95), source: .remote, configuredFloor: 0.5))
    }

    @Test("deterministic floors exist per category and are lower than the remote ones for read-only answers")
    func local() {
        let p = ConfidencePolicy.standard
        #expect(p.threshold(for: jev(.systemStatus, 1), source: .deterministic) == 0.5)
        #expect(p.threshold(for: jev(.macosApplicationAction, 1), source: .deterministic) == 0.6)
        #expect(p.threshold(for: jev(.macosApplicationAction, 1), source: .remote) == nil)
        #expect((p.threshold(for: jev(.systemStatus, 1), source: .deterministic) ?? 1) < (p.threshold(for: jev(.systemStatus, 1), source: .remote) ?? 0))
    }

    @Test("GatedPolicy delegates to the policy and keeps its closed intent set")
    func gated() {
        #expect(GatedPolicy.accepts(jev(.systemStatus, 0.95), minimumConfidence: 0.92))
        #expect(!GatedPolicy.accepts(jev(.systemStatus, 0.95), minimumConfidence: 0.99))
        #expect(!GatedPolicy.accepts(jev(.systemStatus, 0.80), minimumConfidence: 0.5))
        #expect(!GatedPolicy.accepts(jev(.jarvisNavigation, 1.0, page: "nonsense"), minimumConfidence: 0.5))
    }
}

// MARK: Routing, retry, cache

@Suite("V1.0 reliability · when the remote classifier is asked, retried and remembered")
struct JevRoutingTests {
    @Test("only a short, command-shaped abstention of the grammar is worth a remote opinion")
    func routing() {
        let unknown = Decision.unknown("x")
        #expect(JevRoutingPolicy.shouldConsult("Şu anki durumu bir özetle", production: unknown))
        #expect(!JevRoutingPolicy.shouldConsult("Sistem durumunu söyle", production: Decision(intent: .systemStatus)))              // the grammar owns it
        #expect(!JevRoutingPolicy.shouldConsult(String(repeating: "kelime ", count: 40), production: unknown))                       // a paragraph is conversation
        #expect(!JevRoutingPolicy.shouldConsult("func a() { return 1 }", production: unknown))                                       // code is never sent
        #expect(!JevRoutingPolicy.shouldConsult("", production: unknown))
        var blocked = Decision.unknown("x"); blocked.gate = .blocked
        #expect(!JevRoutingPolicy.shouldConsult("Bunu yap", production: blocked))
    }

    @Test("retry: one more attempt for a transient failure only, bounded, with a backoff that grows and is capped")
    func retryPolicy() {
        #expect(JevRetryPolicy.shouldRetry(.offline, attempt: 0, maxRetries: 1))
        #expect(!JevRetryPolicy.shouldRetry(.offline, attempt: 1, maxRetries: 1))
        for f in [JevFailure.timeout, .rateLimited, .outOfBalance, .apiChanged, .credentialMissing, .malformedResponse] { #expect(!JevRetryPolicy.shouldRetry(f, attempt: 0, maxRetries: 3), Comment(rawValue: f.rawValue)) }
        #expect(JevRetryPolicy.backoff(attempt: 0, base: 0.25) == 0.25 && JevRetryPolicy.backoff(attempt: 2, base: 0.25) == 1.0 && JevRetryPolicy.backoff(attempt: 10, base: 0.25) == 2.0)
    }

    @Test("provider: a transient failure is retried once and counted; a timeout is not retried; the number of attempts is bounded")
    func providerRetry() async {
        var cfg = JevConfig(mode: .shadow); cfg.retryBackoffSeconds = 0.01; cfg.maxRetries = 1
        let ok = JevClassification(intent: "system_status", confidence: 0.99)
        let counter = Counter()
        let flaky = JevDecisionProvider(transport: ScriptedTransport(counter: counter) { n in if n == 1 { throw JevFailure.offline }; return ok }, credentialAvailable: { true })
        let r = await flaky.decide(context("Şu anki durumu özetle"), config: cfg)
        guard case .decision(let d, _) = r else { Issue.record("expected a decision after one retry"); return }
        #expect(d.intent == .systemStatus && flaky.usage.retries == 1 && flaky.usage.requests == 2 && counter.value == 2)

        let c2 = Counter()
        let slow = JevDecisionProvider(transport: ScriptedTransport(counter: c2) { _ in throw JevFailure.timeout }, credentialAvailable: { true })
        let r2 = await slow.decide(context("Durumu özetle"), config: cfg)
        #expect(r2 == .unavailable(.timeout) && c2.value == 1 && slow.usage.retries == 0)

        let c3 = Counter()
        var many = cfg; many.maxRetries = 5; many.breakerFailures = 99
        let down = JevDecisionProvider(transport: ScriptedTransport(counter: c3) { _ in throw JevFailure.offline }, credentialAvailable: { true })
        _ = await down.decide(context("Durumu özetle"), config: { var c = many; c.maxRetries = 1; return c }())
        #expect(c3.value == 2, "1 attempt + 1 retry, never more")
    }

    @Test("request minimisation: project names are sent only when the sentence is about a project")
    func minimisation() {
        let about = JevContextBuilder.build(utterance: "Hamam projesine devam et", language: "tr", source: .typed, previousInterpretation: "conversation", projectNames: ["Hamam", "Arena"], config: JevConfig())!
        let other = JevContextBuilder.build(utterance: "Şu anki durumu özetle", language: "tr", source: .typed, previousInterpretation: "conversation", projectNames: ["Hamam", "Arena"], config: JevConfig())!
        #expect(about.projectNames == ["Hamam", "Arena"] && other.projectNames.isEmpty)
        #expect(JevContextBuilder.build(utterance: "my password is /Users/x/secret", language: "en", source: .typed, previousInterpretation: "conversation", projectNames: [], config: JevConfig())?.utterance.contains("/Users") != true)
    }

    @Test("pattern cache: bounded, expiring, salted, digit-masked; stores only high-confidence read-only answers; keeps no text")
    func cache() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = Box(now)
        let cache = DecisionPatternCache(capacity: 3, ttl: 100, salt: 7, clock: { clock.value })
        let d = jev(.systemStatus, 0.99)
        cache.store("Şu anki durumu özetle", d)
        #expect(cache.lookup("şu anki durumu özetle")?.intent == .systemStatus)                    // normalised pattern, not exact text
        #expect(cache.lookup("başka bir cümle") == nil)
        cache.store("sayfa 3 durumu", d)
        #expect(cache.lookup("Sayfa 9 durumu")?.intent == .systemStatus)                             // digits are masked
        clock.value = now.addingTimeInterval(101)
        #expect(cache.lookup("Şu anki durumu özetle") == nil, "expired")
        clock.value = now
        for i in 0..<5 { cache.store("kelime\(i) bir iki", d) }
        #expect(cache.count <= 3, "capacity bound")
        // never executing, never low confidence, never long, never a path
        cache.clear()
        cache.store("Safari'yi aç", jev(.macosApplicationAction, 1.0)); cache.store("durumu özetle", jev(.systemStatus, 0.9)); cache.store(String(repeating: "kelime ", count: 20), d); cache.store("/Users/x/a durumu", d)
        #expect(cache.count == 0)
        // different salts → different keys (nothing is derivable across runs)
        #expect(DecisionPatternCache(salt: 1).key(for: "durumu özetle") != DecisionPatternCache(salt: 2).key(for: "durumu özetle"))
    }

    final class Box: @unchecked Sendable { var value: Date; init(_ v: Date) { value = v } }
}

@MainActor
@Suite("V1.0 reliability · the engine asks the remote classifier only where it can matter")
struct JevEngineTests {
    private func engine(_ mode: JevMode, _ provider: FixedProvider, scope: JevShadowScope = .abstentionsOnly) -> DecisionEngine {
        let e = DecisionEngine()
        e.jev = provider
        e.config = { JevConfig(mode: mode, shadowScope: scope, gatedMinimumConfidence: 0.92) }
        return e
    }

    @Test("shadow, default scope: a sentence the grammar understands is never sent; an abstention is")
    func shadowScope() async {
        let p = FixedProvider(jev(.systemStatus, 0.98))
        let e = engine(.shadow, p)
        _ = e.decide("Sistem durumunu söyle", context: DecisionContext())
        _ = e.decide("Safari'yi aç", context: DecisionContext())
        await e.awaitShadow()
        #expect(p.counter.value == 0, "grammar-owned requests are never sent")
        _ = e.decide("Şu anki durumu bir özetle", context: DecisionContext())
        await e.awaitShadow()
        #expect(p.counter.value == 1)
        let all = FixedProvider(jev(.systemStatus, 0.98))
        let e2 = engine(.shadow, all, scope: .everything)
        _ = e2.decide("Sistem durumunu söyle", context: DecisionContext())
        await e2.awaitShadow()
        #expect(all.counter.value == 1, "an explicit agreement measurement can ask about everything")
    }

    @Test("gated: a long sentence is not sent; an accepted answer is cached, and the same pattern is not paid for twice")
    func gatedRoutingAndCache() async {
        let p = FixedProvider(jev(.systemStatus, 0.99))
        let e = engine(.gated, p)
        let long = String(repeating: "kelime ", count: 30)
        let o1 = e.decide(long, context: DecisionContext())
        let skipped = await e.consultGated(long, context: DecisionContext(), outcome: o1)
        #expect(skipped == nil && p.counter.value == 0 && e.audit.entry(o1.id)?.jevSkippedByRouting == true)

        let ask = "Şu anki durumu bir özetle"
        let o2 = e.decide(ask, context: DecisionContext())
        let first = await e.consultGated(ask, context: DecisionContext(), outcome: o2)
        #expect(first?.intent == .systemStatus && p.counter.value == 1)
        let o3 = e.decide("şu anki durumu bir özetle", context: DecisionContext())
        let second = await e.consultGated("şu anki durumu bir özetle", context: DecisionContext(), outcome: o3)
        #expect(second?.intent == .systemStatus && p.counter.value == 1 && e.audit.entry(o3.id)?.jevCacheHit == true, "served from the pattern cache, no second request")
        // a stricter user threshold applies to a cached answer at once
        let strict = DecisionEngine(); strict.jev = p; strict.config = { JevConfig(mode: .gated, gatedMinimumConfidence: 0.999) }
        strict.patternCache.store(ask, jev(.systemStatus, 0.99))
        let o4 = strict.decide(ask, context: DecisionContext())
        let refused = await strict.consultGated(ask, context: DecisionContext(), outcome: o4)
        #expect(refused == nil)
    }

    @Test("the shadow report exposes calibration buckets and an agreement rate")
    func calibration() async {
        let p = FixedProvider(jev(.systemStatus, 0.98))
        let e = engine(.shadow, p)
        for s in ["Şu anki durumu bir özetle", "Neler oluyor şimdi"] { _ = e.decide(s, context: DecisionContext()) }
        await e.awaitShadow()
        let r = e.audit.shadowReport
        #expect(r.consulted == 2 && r.productionUnknown == 2)
        #expect(r.calibrationBuckets().reduce(0) { $0 + $1.n } == 0, "unknown production decisions carry no agreement to calibrate against")
    }
}

// MARK: Presentation contract and claim firewall

@Suite("V1.0 reliability · presentation contract and claim firewall")
struct ResponseContractTests {
    @Test("the fact block lists verified and unverified results, is bounded and carries the rules")
    func block() {
        let facts: [StructuredFact] = [.actionResult(kind: "launch", target: "Safari", verified: true, detail: "application list"), .visibility(target: "Safari", seen: nil, ageSeconds: nil), .unknown(about: "task 7")]
        let b = PresentationContract.block(facts: facts, language: .tr)!
        #expect(b.contains("VERIFIED") && b.contains("unknown (no fresh observation)") && b.contains("Turkish") && b.count <= PresentationContract.maxCharacters)
        #expect(PresentationContract.block(facts: [], language: .en) == nil)
        let many = PresentationContract.block(facts: (0..<40).map { .systemState(key: "k\($0)", value: String(repeating: "v", count: 300)) }, language: .en)!
        #expect(many.count <= PresentationContract.maxCharacters)
    }

    @Test("structural claim patterns, Turkish and English: actions, perception, state, task results")
    func patterns() {
        let claims: [(String, ResponseClaimKind)] = [("Safari'yi açıyorum.", .action), ("Projeyi açtım.", .action), ("Dosyayı sildim.", .action), ("I opened Safari for you.", .action), ("I've deleted the file.", .action),
                                             ("Ekranı görüyorum.", .visibility), ("Safari ekranda görünüyor.", .visibility), ("I can see your screen.", .visibility), ("Your screen shows a video.", .visibility),
                                             ("Safari şu an açık.", .state), ("The microphone is active.", .state), ("Görev tamamlandı.", .task), ("The task is complete.", .task)]
        for (text, kind) in claims {
            let found = ResponseClaimFirewall.findings(in: text)
            #expect(found.contains { $0.kind == kind }, "\(text) → \(found.map(\.kind))")
        }
        for harmless in ["Python'da liste nasıl sıralanır?", "Safari macOS'in varsayılan tarayıcısıdır.", "Claude hazır olduğunda haber veririm.", "Swift'te actor, durumu koruyan bir türdür.", "Safari'yi açabilir misin?", "I cannot see your screen."] {
            #expect(ResponseClaimFirewall.findings(in: harmless).isEmpty, Comment(rawValue: harmless))
        }
    }

    @Test("a model's claim survives only when a VERIFIED fact of the same kind names the same thing; JARVIS' own text is never second-guessed")
    func review() {
        let reply = "Safari'yi açtım."
        if case .replace(let f, let text) = ResponseClaimFirewall.review(reply: reply, provenance: .modelGenerated, facts: [], language: .tr) { #expect(!f.isEmpty && !text.contains("açtım")) } else { Issue.record("an unbacked claim must be replaced") }
        #expect(ResponseClaimFirewall.review(reply: reply, provenance: .modelGenerated, facts: [.actionResult(kind: "launch", target: "Safari", verified: true, detail: "")], language: .tr) == .allow)
        if case .allow = ResponseClaimFirewall.review(reply: reply, provenance: .modelGenerated, facts: [.actionResult(kind: "launch", target: "Safari", verified: false, detail: "not read back")], language: .tr) { Issue.record("an unverified result backs nothing") }
        if case .allow = ResponseClaimFirewall.review(reply: reply, provenance: .modelGenerated, facts: [.actionResult(kind: "launch", target: "Finder", verified: true, detail: "")], language: .tr) { Issue.record("a verified result about something else backs nothing") }
        #expect(ResponseClaimFirewall.review(reply: reply, provenance: .groundedFacts, facts: [], language: .tr) == .allow)
        #expect(ResponseClaimFirewall.review(reply: reply, provenance: .template, facts: [], language: .tr) == .allow)
        // visibility needs a fresh SEEN observation of that very thing
        let seeing = "Safari ekranda görünüyor."
        if case .allow = ResponseClaimFirewall.review(reply: seeing, provenance: .modelGenerated, facts: [.visibility(target: "Safari", seen: nil, ageSeconds: nil)], language: .tr) { Issue.record("an unknown observation backs nothing") }
        #expect(ResponseClaimFirewall.review(reply: seeing, provenance: .modelGenerated, facts: [.visibility(target: "Safari", seen: true, ageSeconds: 4)], language: .tr) == .allow)
    }

    @Test("what is left of a partly-claiming reply is kept, and the notice is true and says nothing was done")
    func replacement() {
        let text = ResponseClaimFirewall.replacement(for: "Python'da liste şöyle sıralanır. Dosyayı sildim.", findings: [ClaimFinding(kind: .action, sentence: "Dosyayı sildim")], language: .tr)
        #expect(text.contains("Python'da liste") && !text.contains("sildim") && text.contains("hiçbir eylem gerçekleştirilmedi"))
        let en = ResponseClaimFirewall.replacement(for: "I can see your screen.", findings: [ClaimFinding(kind: .visibility, sentence: "I can see your screen")], language: .en)
        #expect(en.contains("fresh observation"))
    }
}

// MARK: Language consistency

@Suite("V1.0 reliability · Turkish language consistency")
struct LanguageConsistencyTests {
    @Test("the directive exists for Turkish only, names the things that must not be translated, and needs no model call")
    func directive() {
        let tr = LanguageDirective.preamble(for: .tr)!
        #expect(tr.contains("Turkish") && tr.contains("do not translate") && tr.contains("code"))
        #expect(LanguageDirective.preamble(for: .en) == nil)
    }

    @Test("the probe sees through product names, acronyms, identifiers, code and paths")
    func probe() {
        #expect(LanguageProbe.detect("Tamam, Claude Code hazır; dosyayı Swift ile yazabilirim ve projeyi açabilirim.") == .turkish)
        #expect(LanguageProbe.detect("Sure, I opened it and everything is fine, you can continue with the task.") == .english)
        #expect(LanguageProbe.detect("Projeyi açtım: `let isReady = true` ve /Users/x/Hamam/Assets içinde MyScript.swift var.") != .english)
        #expect(LanguageProbe.detect("OK GPU API MLX") == .unknown)
        #expect(LanguageProbe.detect("```swift\nlet a = 1\n```") == .unknown)
    }

    @Test("a Turkish request answered in English is a mismatch; names alone never are")
    func verdicts() {
        #expect(ResponseLanguageCheck.verdict(reply: "Sure, I opened it and everything is fine, you can continue with the task.", expected: .tr) == .mismatch(.english))
        #expect(ResponseLanguageCheck.verdict(reply: "Anladım, projeyi açmadan önce yedek almanızı öneririm, bunu sizin için yapamam.", expected: .tr) == .consistent)
        #expect(ResponseLanguageCheck.verdict(reply: "Safari Chrome Unity", expected: .tr) == .insufficient)
        #expect(ResponseLanguageCheck.verdict(reply: "Anladım, projeyi açmadan önce yedek almanızı öneririm, bunu sizin için yapamam.", expected: .en) == .mismatch(.turkish))
    }
}

// MARK: Freshness

@Suite("V1.0 reliability · one observation freshness policy")
struct FreshnessPolicyTests {
    @Test("every kind has one TTL; fresh / stale / never is decided from the age alone")
    func ttl() {
        let p = ObservationFreshnessPolicy.standard
        for k in ObservationKind.allCases { #expect(p.ttl(for: k) > 0, Comment(rawValue: k.rawValue)) }
        let t0 = Date(timeIntervalSince1970: 5_000)
        #expect(p.verdict(.screenVisibility, observedAt: t0, now: t0.addingTimeInterval(10)) == .fresh(ageSeconds: 10))
        #expect(p.verdict(.screenVisibility, observedAt: t0, now: t0.addingTimeInterval(45)) == .stale(ageSeconds: 45))
        #expect(p.verdict(.processRunning, observedAt: nil, now: t0) == .never)
        #expect(!p.verdict(.screenVisibility, observedAt: t0, now: t0.addingTimeInterval(45)).mayClaimAsPresent)
        #expect(p.ttl(for: .processRunning) < p.ttl(for: .projectState) && p.ttl(for: .projectState) < p.ttl(for: .providerReadiness))
    }

    @Test("the visibility grounding uses the same number instead of its own")
    func shared() {
        #expect(ObservationGrounding.freshSeconds == ObservationFreshnessPolicy.standard.ttl(for: .appVisibility))
        let now = Date(timeIntervalSince1970: 9_000)
        #expect(ObservationGrounding.evaluate(target: "Safari", observations: [ObservedApp(name: "Safari", at: now.addingTimeInterval(-5))], now: now).mayClaimVisible)
        #expect(!ObservationGrounding.evaluate(target: "Safari", observations: [ObservedApp(name: "Safari", at: now.addingTimeInterval(-25))], now: now).mayClaimVisible)
    }
}
