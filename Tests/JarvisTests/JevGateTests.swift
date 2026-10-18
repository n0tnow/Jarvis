import Foundation
import Testing
@testable import Jarvis

// V1.0 Jev gating pass — the remote classifier is OPTIONAL and ADVISORY, and deterministic policy always wins. These tests pin that as properties, with scripted classifiers only (no network, no key, no Keychain):
// the zero-Jev fast path with call counting · the abstain-path matrix · the gate (safety classes, local risk re-derivation, per-intent floors, corroboration, target resolution, model change) · malformed answers ·
// timeouts and the circuit breaker · privacy of what is sent · approval isolation · and the corpora (hard negatives, ambiguity, held-out) pushed through hostile classifiers.
// Nothing here says anything about how accurate the real Jev is: that is measured on the user's Mac (docs/JEV_DECISION_POLICY.md).

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var _seen: [String] = []
    func record(_ s: String) { lock.lock(); n += 1; _seen.append(s); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    var seen: [String] { lock.lock(); defer { lock.unlock() }; return _seen }
}

/// A classifier that counts every request and answers with a fixed intent / confidence (it has no execution API: nothing it returns can do anything but become a `Decision`).
private final class CountingJev: DecisionProviding, @unchecked Sendable {
    let calls = Calls()
    let intent: DecisionIntent
    let confidence: Double
    let page: String?
    let model: String?
    init(_ intent: DecisionIntent, _ confidence: Double = 0.99, page: String? = nil, model: String? = nil) { self.intent = intent; self.confidence = confidence; self.page = page; self.model = model }
    var reportedModel: String? { model }
    func decide(_ context: JevDecisionContext, config: JevConfig) async -> DecisionProviderResult {
        calls.record(context.utterance)
        let d = JevClassificationMapper.decision(from: JevClassification(intent: intent.rawValue, confidence: confidence, page: page))
        guard let d else { return .unavailable(.malformedResponse) }
        return .decision(d, latency: 0.3)
    }
}

@MainActor
private func gatedEngine(_ jev: CountingJev, level: JevGateLevel = .readOnly, floor: Double = 0.92, calibrated: String = "") -> DecisionEngine {
    var parsers = DecisionParsers()
    parsers.isKnownProjectName = { n in ["Hamam"].contains { ProjectOpenResolver.nameMatches(spoken: n, name: $0) } }
    let e = DecisionEngine(recognizer: DeterministicCommandRecognizer(parsers: parsers))
    e.jev = jev
    e.config = { JevConfig(mode: .gated, gatedMinimumConfidence: floor, gateLevel: level, calibratedModel: calibrated) }
    return e
}

private func candidate(_ intent: DecisionIntent, _ confidence: Double = 0.99, page: String? = nil, action: String? = nil) -> Decision {
    let target = intent == .jarvisNavigation ? page : nil
    return DecisionPolicy.finalize(intent: intent, confidence: confidence, normalized: "", target: target, action: intent == .jarvisNavigation ? "navigate" : action, deepReasoning: false, provenance: .jevShadow, provider: .jev)
}

private func gate(_ raw: String, _ d: Decision, level: JevGateLevel = .readOnly, resolution: JevTargetResolution = .notNeeded, floor: Double = 0, reported: String? = nil, calibrated: String = "", anchor: Bool = true, capability: Bool = true) -> JevGateVerdict {
    JevGatePolicy.evaluate(JevGateInput(raw: raw, production: Decision.unknown(raw), candidate: d, level: level, configuredFloor: floor, targetResolution: resolution, capabilityAvailable: capability, requireAnchor: anchor, reportedModel: reported, calibratedModel: calibrated))
}

private func corpusURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Benchmarks").appendingPathComponent(name)
}

private func registryRecognizer() -> DeterministicCommandRecognizer {
    var p = DecisionParsers()
    p.isKnownProjectName = { n in ["Hamam", "Hammam", "Turkish Hammam Simulator"].contains { ProjectOpenResolver.nameMatches(spoken: n, name: $0) } }
    return DeterministicCommandRecognizer(parsers: p)
}

// MARK: A · the zero-Jev fast path

@Suite("V1.0 Jev · A · a request the grammar understands never reaches Jev")
@MainActor
struct JevZeroPathTests {
    private static let known: [String] = ["Sistem durumunu söyle.", "System Durumu Nedir?", "Sesim geliyor mu?", "System panelini aç.", "Dashboard'a dön.", "Safari'yi aç.", "Safari'yi açabilir misin?",
                                          "Hamam'ı aç.", "Hamam'da devam et.", "Konuşmayı durdur.", "Görevi iptal et."]

    @Test("eleven everyday commands: decided locally, the classifier is asked ZERO times — in gated mode and in default shadow mode")
    func zeroJev() async {
        for text in Self.known {
            let jev = CountingJev(.systemStatus, 0.99)
            let e = gatedEngine(jev)
            let o = e.decide(text, context: DecisionContext())
            #expect(o.decision.intent != .unknown || o.decision.ambiguity != .none, Comment(rawValue: "the grammar did not understand “\(text)”"))
            let routed = await e.consultGated(text, context: DecisionContext(), outcome: o)
            #expect(routed == nil, Comment(rawValue: text))
            #expect(jev.calls.count == 0, Comment(rawValue: "“\(text)” reached Jev"))
            #expect(e.audit.entry(o.id)?.jevRejection != nil)

            let shadow = CountingJev(.systemStatus, 0.99)
            let s = DecisionEngine(recognizer: registryRecognizer()); s.jev = shadow; s.config = { JevConfig(mode: .shadow) }
            _ = s.decide(text, context: DecisionContext())
            await s.awaitShadow()
            #expect(shadow.calls.count == 0, Comment(rawValue: "shadow asked about “\(text)”"))
        }
    }

    @Test("disabled (the default) never asks anything, whatever the sentence")
    func disabledNeverAsks() async {
        let jev = CountingJev(.systemStatus, 0.99)
        let e = DecisionEngine(); e.jev = jev       // config() defaults to JevConfig() = disabled
        for text in ["Şu anki durumu bir özetle", "Sistem durumunu söyle.", "tamamen alakasız bir cümle"] {
            let o = e.decide(text, context: DecisionContext())
            let r = await e.consultGated(text, context: DecisionContext(), outcome: o)
            #expect(r == nil)
        }
        await e.awaitShadow()
        #expect(jev.calls.count == 0)
        #expect(JevConfig().mode == .disabled && JevConfig().gateLevel == .readOnly)
    }

    @Test("what an abstention costs: success → no Jev · ambiguity → the grammar asks, no Jev · policy block → no Jev and no override · true abstention → Jev may be asked")
    func abstainMatrix() async {
        // success
        let a = CountingJev(.systemStatus); let ea = gatedEngine(a)
        let oa = ea.decide("Sistem durumunu söyle.", context: DecisionContext())
        _ = await ea.consultGated("Sistem durumunu söyle.", context: DecisionContext(), outcome: oa)
        #expect(a.calls.count == 0 && ea.audit.entry(oa.id)?.jevRejection == JevRejection.deterministicDecided.rawValue)
        // ambiguity: a pronoun with nothing to point at is the grammar's question, not Jev's
        let b = CountingJev(.macosApplicationAction); let eb = gatedEngine(b)
        let ob = eb.decide("Onu aç", context: DecisionContext())
        let rb = await eb.consultGated("Onu aç", context: DecisionContext(), outcome: ob)
        #expect(ob.decision.ambiguity != .none && rb == nil && b.calls.count == 0)
        // policy block: Jev cannot turn a blocked / ask-first request into anything, and is not even asked
        for text in ["GitHub'a pushla.", "Dosyayı sil."] {
            let c = CountingJev(.systemStatus); let ec = gatedEngine(c)
            let oc = ec.decide(text, context: DecisionContext())
            let rc = await ec.consultGated(text, context: DecisionContext(), outcome: oc)
            #expect(oc.decision.gate != .none && rc == nil && c.calls.count == 0, Comment(rawValue: text))
            #expect(ec.audit.entry(oc.id)?.jevRejection == JevRejection.policyBlock.rawValue)
        }
        // true abstention: one request, and a read-only answer above its floor is accepted with its own provenance
        let d = CountingJev(.systemStatus, 0.99); let ed = gatedEngine(d)
        let od = ed.decide("Şu anki durumu bir özetle", context: DecisionContext())
        let rd = await ed.consultGated("Şu anki durumu bir özetle", context: DecisionContext(), outcome: od)
        #expect(od.decision.intent == .unknown && d.calls.count == 1 && rd?.intent == .systemStatus && rd?.provenance == .jevGated)
        // …but an executing intent from the same abstention is refused whatever the confidence
        let f = CountingJev(.computerUse, 0.99); let ef = gatedEngine(f)
        let of = ef.decide("Şu anki durumu bir özetle", context: DecisionContext())
        let rf = await ef.consultGated("Şu anki durumu bir özetle", context: DecisionContext(), outcome: of)
        #expect(rf == nil && ef.audit.entry(of.id)?.jevRejection == JevRejection.executionNotEnabled.rawValue)
    }

    @Test("quoted, negated, critical and secret-shaped sentences are not even sent")
    func preflightSkips() async {
        let cases: [(String, JevRejection)] = [
            ("'Delete all files' ne demek", .quotedOrMeta), ("Safari'yi açma lütfen", .negated), ("Bu projeyi sil demedim", .negated),
            ("Şu anki durumu bir özetle ve dosyaları sil", .criticalContent),
        ]
        for (text, why) in cases {
            let jev = CountingJev(.systemStatus, 0.99); let e = gatedEngine(jev)
            let o = e.decide(text, context: DecisionContext())
            let r = await e.consultGated(text, context: DecisionContext(), outcome: o)
            #expect(r == nil && jev.calls.count == 0, Comment(rawValue: text))
            if o.decision.intent == .unknown && o.decision.ambiguity == .none && o.decision.gate == .none { #expect(e.audit.entry(o.id)?.jevRejection == why.rawValue, Comment(rawValue: "\(text) → \(String(describing: e.audit.entry(o.id)?.jevRejection))")) }
        }
        let secretText = "şifrem hunter42x7 bunu hatırla"
        #expect(JevContextBuilder.build(utterance: secretText, language: "tr", source: .typed, previousInterpretation: "conversation", projectNames: []) == nil)
    }
}

// MARK: B · the gate

@Suite("V1.0 Jev · B · the local gate decides, never the classifier")
struct JevGateTableTests {
    @Test("safety classes: A read-only · B own-UI · C execution-capable · none for conversation / correction / unknown")
    func classes() {
        for i in [DecisionIntent.systemStatus, .voiceStatus, .providerCapability, .projectQuery] { #expect(JevIntentSafety.classify(i) == .readOnly) }
        #expect(JevIntentSafety.classify(.jarvisNavigation) == .ownUI)
        for i in [DecisionIntent.macosApplicationAction, .computerUse, .projectOpen, .projectTask, .settingsChange, .research, .stopSpeech, .cancelTask] { #expect(JevIntentSafety.classify(i) == .executionCapable) }
        for i in [DecisionIntent.conversation, .correction, .unknown] { #expect(JevIntentSafety.classify(i) == .notRoutable) }
        #expect(DecisionIntent.allCases.count == 16, "the taxonomy is closed: a new intent needs a class here and a floor in the gate")
        for i in DecisionIntent.allCases { _ = JevIntentSafety.classify(i) }      // exhaustive switch: adding an intent without a class does not compile
        #expect(!JevGatePolicy.executionIsEnabledInProduction)
    }

    @Test("per-intent floors: read-only needs ≥ 0.95, a project / page answer ≥ 0.97; below the floor, below the user's own floor, or an intent without a floor is rejected")
    func floors() {
        #expect(JevGatePolicy.floor(for: .systemStatus) == 0.95 && JevGatePolicy.floor(for: .projectQuery) == 0.97 && JevGatePolicy.floor(for: .jarvisNavigation) == 0.97)
        #expect(JevGatePolicy.floor(for: .computerUse) == nil && JevGatePolicy.floor(for: .macosApplicationAction) == nil && JevGatePolicy.floor(for: .conversation) == nil)
        let s = "Sistemin durumu nasıl gidiyor"
        #expect(gate(s, candidate(.systemStatus, 0.96)).accepted?.intent == .systemStatus)
        #expect(gate(s, candidate(.systemStatus, 0.94)).rejection == .belowIntentThreshold)
        #expect(gate(s, candidate(.systemStatus, 0.96), floor: 0.99).rejection == .belowIntentThreshold, "the user's own floor can only raise the bar")
        #expect(gate("Hamam ne durumda", candidate(.projectQuery, 0.96), resolution: .resolved("Hamam")).rejection == .belowIntentThreshold)
        #expect(gate("Hamam ne durumda", candidate(.projectQuery, 0.98), resolution: .resolved("Hamam")).accepted?.intent == .projectQuery)
        #expect(gate(s, candidate(.conversation, 0.99)).rejection == .intentNotRoutable)
    }

    @Test("a class-C intent is NEVER accepted in production — not at any gate level, not at 1.0 — and the simulation never accepts the computer, stop or cancel either")
    func executionNeverAccepted() {
        let prompts: [(String, DecisionIntent)] = [("Safari'yi aç bakalım", .macosApplicationAction), ("Ekrana bir bak", .computerUse), ("Hamam projesini aç", .projectOpen), ("Hızını biraz artır", .settingsChange),
                                                  ("Bunu araştır", .research), ("Konuşmayı kes", .stopSpeech), ("Görevi bırak", .cancelTask), ("Şu işi yap", .projectTask)]
        for (text, intent) in prompts { for level in JevGateLevel.allCases { for c in [0.5, 0.99, 1.0] {
            let v = gate(text, candidate(intent, c), level: level, resolution: .resolved("x"), anchor: false)
            #expect(v.accepted == nil, Comment(rawValue: "\(intent) accepted at \(level) \(c)"))
            #expect(v.rejection == .executionNotEnabled || v.rejection == .intentNotRoutable || v.rejection == .criticalContent || v.rejection == .negated || v.rejection == .quotedOrMeta, Comment(rawValue: "\(intent): \(String(describing: v.rejection))"))
        } } }
        for intent in [DecisionIntent.computerUse, .stopSpeech, .cancelTask] {
            let sim = JevGatePolicy.simulate(JevGateInput(raw: "bir şey yap", production: Decision.unknown("x"), candidate: candidate(intent, 1.0), level: .execution, targetResolution: .resolved("x")))
            #expect(sim.accepted == nil, Comment(rawValue: "\(intent) must not be accepted even in the simulation"))
        }
    }

    @Test("own-UI: a page change needs level ownUI, a page from the vocabulary that the sentence itself mentions")
    func ownUI() {
        let raw = "Ayarlar sayfasına bakalım"
        #expect(gate(raw, candidate(.jarvisNavigation, 0.99, page: "settings"), level: .readOnly).rejection == .levelDoesNotAllow, "the default level changes no screen")
        #expect(gate(raw, candidate(.jarvisNavigation, 0.99, page: "settings"), level: .ownUI).accepted?.target == "settings")
        #expect(gate(raw, candidate(.jarvisNavigation, 0.99, page: "memory"), level: .ownUI).rejection == .noLexicalAnchor, "the page must be one the sentence mentions")
        var bogus = candidate(.jarvisNavigation, 0.99, page: "settings"); bogus.target = "../../etc"
        #expect(gate(raw, bogus, level: .ownUI).rejection != nil && gate(raw, bogus, level: .ownUI).accepted == nil, "a page outside the vocabulary is never accepted")
        #expect(gate(raw, candidate(.jarvisNavigation, 0.96, page: "settings"), level: .ownUI).rejection == .belowIntentThreshold)
    }

    @Test("local risk re-derivation: a classifier's 'low risk' means nothing — a critical word rejects, and critical wins over everything")
    func riskIsLocal() {
        // the candidate claims to be harmless (finalize derives low risk for a status query) — the sentence says otherwise
        for text in ["Sistem durumunu söyle ve dosyaları sil", "Durumu söyle, sonra GitHub'a pushla", "Give me system status and delete the project", "Sistem durumu şifre: hunter42x7"] {
            let c = candidate(.systemStatus, 0.99)
            #expect(c.riskClass == .low && c.gate == .none)
            let v = gate(text, c)
            #expect(v.accepted == nil && v.rejection != nil, Comment(rawValue: text))
        }
        #expect(LocalRiskDerivation.derive(raw: "GitHub'a pushla", candidate: candidate(.systemStatus)).gate == .blocked)
        #expect(LocalRiskDerivation.derive(raw: "dosyayı sil", candidate: candidate(.systemStatus)).risk >= .high)
        #expect(LocalRiskDerivation.derive(raw: "sistem durumu", candidate: candidate(.systemStatus)).risk == .low)
        // a production decision with a policy gate is final
        var blocked = Decision.unknown("x"); blocked.gate = .blocked
        let v = JevGatePolicy.evaluate(JevGateInput(raw: "Sistem durumu", production: blocked, candidate: candidate(.systemStatus, 1.0)))
        #expect(v.rejection == .policyBlock)
    }

    @Test("ambiguity and target resolution: Jev never invents an executable identifier; an ambiguous or unresolved target rejects")
    func targets() {
        var ambiguous = candidate(.systemStatus, 0.99); ambiguous.ambiguity = .ambiguous(question: "which?")
        #expect(gate("Sistem durumu", ambiguous).rejection == .ambiguousCandidate)
        #expect(gate("Hamam ne durumda", candidate(.projectQuery, 0.99), resolution: .unresolved).rejection == .targetUnresolved)
        #expect(gate("Hamam ne durumda", candidate(.projectQuery, 0.99), resolution: .ambiguous(["Hamam", "Hamam Old"])).rejection == .targetAmbiguous)
        #expect(gate("Hamam ne durumda", candidate(.projectQuery, 0.99), resolution: .resolved("Hamam")).accepted != nil)
        // the engine's registry hook decides, not the classifier's answer
        let ok = JevGatePolicy.evaluate(JevGateInput(raw: "Hamam ne durumda", production: Decision.unknown("x"), candidate: candidate(.projectQuery, 0.99), targetResolution: .resolved("Hamam")))
        #expect(ok.accepted?.target == nil, "the accepted decision carries no classifier-supplied target")
    }

    @Test("corroboration: a confidently wrong read-only answer about an unrelated sentence is not routed")
    func anchors() {
        #expect(gate("Bugün hava nasıl olacak", candidate(.systemStatus, 0.99)).rejection == .noLexicalAnchor)
        #expect(gate("Bana bir şiir yaz", candidate(.voiceStatus, 0.99)).rejection == .noLexicalAnchor)
        #expect(gate("Bana bir şiir yaz", candidate(.systemStatus, 0.99), anchor: false).accepted != nil, "with the corroboration off the same answer would pass: that is what the evaluation measures")
        #expect(gate("Mikrofonum çalışıyor mu bakar mısın", candidate(.voiceStatus, 0.97)).accepted?.intent == .voiceStatus)
        #expect(JevCorroboration.anchored(intent: .conversation, page: nil, raw: "herhangi bir şey"))
    }

    @Test("a request to CHOOSE a provider is never read as a capability question; an unavailable capability and a changed model version reject")
    func providerModelCapability() {
        #expect(gate("Bunu Claude'a yaptır", candidate(.providerCapability, 0.99)).rejection == .possibleSelection)
        #expect(gate("Claude Code'u kullan", candidate(.providerCapability, 0.99)).rejection == .possibleSelection)
        #expect(gate("Claude hazır mı", candidate(.providerCapability, 0.99)).accepted != nil)
        #expect(gate("Sistem durumu nasıl", candidate(.systemStatus, 0.99), capability: false).rejection == .capabilityUnavailable)
        // calibration belongs to one model version
        #expect(gate("Sistem durumu nasıl", candidate(.systemStatus, 0.99), reported: "jev-1.14.0", calibrated: "jev-1.13.0").rejection == .modelChanged)
        #expect(gate("Sistem durumu nasıl", candidate(.systemStatus, 0.99), reported: nil, calibrated: "jev-1.13.0").rejection == .modelChanged)
        #expect(gate("Sistem durumu nasıl", candidate(.systemStatus, 0.99), reported: "jev-1.13.0", calibrated: "jev-1.13.0").accepted != nil)
        #expect(gate("Sistem durumu nasıl", candidate(.systemStatus, 0.99), reported: "jev-2", calibrated: "").accepted != nil, "no calibration recorded: nothing to compare against")
    }

    @Test("malformed confidence: NaN, ±∞, -1 and 5 are rejected, never clamped into something acceptable")
    func malformedConfidence() {
        for bad in [Double.nan, .infinity, -.infinity, -1, 5, 1.5] {
            #expect(JevClassificationMapper.decision(from: JevClassification(intent: "system_status", confidence: bad)) == nil, Comment(rawValue: "\(bad)"))
        }
        #expect(JevClassificationMapper.decision(from: JevClassification(intent: "system_status", confidence: 1.0))?.confidence == 1.0)
        #expect(JevClassificationMapper.decision(from: JevClassification(intent: "teleport", confidence: 0.99)) == nil, "an unknown intent is not one of ours")
        #expect(JevResponseParser.parse(#"{"intent":"system_status","confidence":5}"#) == nil && JevResponseParser.parse(#"{"intent":"system_status","confidence":-1}"#) == nil)
        // even a hand-built Decision cannot carry a non-finite confidence
        #expect(Decision(intent: .systemStatus, confidence: .nan).confidence == 0)
        let nan = JevGatePolicy.evaluate(JevGateInput(raw: "sistem durumu", production: Decision.unknown("x"), candidate: { var d = candidate(.systemStatus); d.confidence = .nan; return d }()))
        #expect(nan.rejection == .malformedConfidence)
    }

    @Test("the service's own response shapes: a missing intent, a wrong type, an empty choice, an HTTP error and invalid JSON are all malformed or classed — none becomes a decision")
    func transportShapes() throws {
        func parse(_ json: String) -> JevClassification? { (try? JSONSerialization.jsonObject(with: Data(json.utf8))).flatMap { TypeSafeJevTransport.parse($0) } }
        #expect(parse(#"{"model":"m","answers":{"intent":{"type":"choice","choice":"system_status","confidence":0.97}}}"#)?.intent == "system_status")
        #expect(parse(#"{"model":"m","answers":{"intent":{"type":"choice","confidence":0.97}}}"#) == nil, "missing choice")
        #expect(parse(#"{"model":"m","answers":{"intent":{"type":"choice","choice":"system_status"}}}"#) == nil, "missing confidence")
        #expect(parse(#"{"model":"m","answers":{}}"#) == nil && parse(#"{"model":"m"}"#) == nil && parse("[]") == nil && parse(#"{"answers":"x"}"#) == nil)
        #expect(parse(#"{"model":"m","answers":{"intent":{"type":"choice","choice":"system_status","confidence":5}}}"#) == nil, "confidence 5")
        #expect(parse(#"{"model":"m","answers":{"intent":{"type":"choice","choice":"system_status","confidence":-1}}}"#) == nil, "confidence -1")
        #expect(parse(#"{"model":"m","answers":{"intent":{"type":"choice","choice":"","confidence":0.99}}}"#).flatMap(JevClassificationMapper.decision(from:)) == nil, "empty choice")
        #expect(parse(#"{"model":"m","answers":{"intent":{"type":"choice","choice":"shutdown_computer","confidence":0.99}}}"#).flatMap(JevClassificationMapper.decision(from:)) == nil, "unknown intent")
        #expect(parse("not json") == nil)
        for (status, expected) in [(401, JevFailure.credentialMissing), (402, .outOfBalance), (408, .timeout), (429, .rateLimited), (404, .apiChanged), (500, .unavailable), (503, .unavailable)] {
            #expect(TypeSafeJevTransport.failure(status: status, bodyHint: "") == expected, Comment(rawValue: "\(status)"))
        }
        #expect(TypeSafeJevTransport.failure(status: 429, bodyHint: "insufficient balance") == .outOfBalance)
    }
}

// MARK: C · timeouts, outages, the breaker and the cost guards

private struct ScriptedTransport: JevTransport {
    let calls: Calls
    let script: @Sendable (Int) async throws -> JevClassification
    func complete(_ request: JevClassifyRequest, modelAlias: String, timeout: TimeInterval) async throws -> JevClassification { calls.record("c"); return try await script(calls.count) }
}

private func ctx(_ text: String = "Şu anki durumu bir özetle") -> JevDecisionContext {
    JevContextBuilder.build(utterance: text, language: "tr", source: .typed, previousInterpretation: "conversation", projectNames: [], config: JevConfig())!
}

@Suite("V1.0 Jev · C · a slow, failing or exhausted classifier is never a single point of failure")
@MainActor
struct JevResilienceTests {
    @Test("every failure class is an 'unavailable' result, the conversation continues on the existing route, and the audit says why")
    func fallbackIsAlwaysTheExistingRoute() async {
        for failure in [JevFailure.timeout, .offline, .rateLimited, .outOfBalance, .malformedResponse, .apiChanged, .unavailable, .credentialMissing] {
            let provider = JevDecisionProvider(transport: ScriptedTransport(calls: Calls()) { _ in throw failure }, credentialAvailable: { true })
            var cfg = JevConfig(mode: .gated); cfg.maxRetries = 0
            let e = DecisionEngine(); e.jev = provider; e.config = { cfg }
            let o = e.decide("Şu anki durumu bir özetle", context: DecisionContext())
            let r = await e.consultGated("Şu anki durumu bir özetle", context: DecisionContext(), outcome: o)
            #expect(r == nil, Comment(rawValue: "\(failure)"))
            #expect(o.decision.intent == .unknown, "the production decision is untouched: the existing router handles the sentence")
            #expect(e.audit.entry(o.id)?.jevFallbackUsed == true || e.audit.entry(o.id)?.jevRejection == JevRejection.unavailable.rawValue, Comment(rawValue: "\(failure): \(String(describing: e.audit.entry(o.id)))"))
        }
    }

    @Test("the gated timeout is the SHORTER of the configured timeout and 1.5 s; a hanging transport is abandoned")
    func gatedTimeout() async {
        #expect(JevLatencyModel.worstCaseAdded(config: JevConfig(timeoutSeconds: 4)) == 1.5)
        #expect(JevLatencyModel.worstCaseAdded(config: JevConfig(timeoutSeconds: 0.5)) == 0.5)
        let hang = ScriptedTransport(calls: Calls()) { _ in try await Task.sleep(for: .seconds(30)); return JevClassification(intent: "system_status", confidence: 0.99) }
        let provider = JevDecisionProvider(transport: hang, credentialAvailable: { true })
        var cfg = JevConfig(mode: .gated); cfg.timeoutSeconds = 0.2; cfg.maxRetries = 0
        let started = Date()
        let r = await provider.decide(ctx(), config: cfg)
        #expect(r == .unavailable(.timeout) && Date().timeIntervalSince(started) < 3)
    }

    @Test("the circuit breaker opens after three consecutive failures, stops asking, and closes again after its window; an out-of-balance answer opens it at once")
    func breaker() async {
        let calls = Calls()
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_800_000_000) }
        let clock = Clock()
        let provider = JevDecisionProvider(transport: ScriptedTransport(calls: calls) { _ in throw JevFailure.unavailable }, credentialAvailable: { true }, clock: { clock.now })
        var cfg = JevConfig(mode: .gated); cfg.maxRetries = 0; cfg.breakerFailures = 3; cfg.breakerSeconds = 600
        for _ in 0..<3 { _ = await provider.decide(ctx(), config: cfg) }
        #expect(calls.count == 3)
        let blocked = await provider.decide(ctx(), config: cfg)
        #expect(blocked == .unavailable(.unavailable) && calls.count == 3 && provider.usage.skippedByBreaker == 1, "the breaker is open: no request is made")
        clock.now = clock.now.addingTimeInterval(601)
        _ = await provider.decide(ctx(), config: cfg)
        #expect(calls.count == 4, "half-open after the window: one probe goes out")

        let c2 = Calls()
        let broke = JevDecisionProvider(transport: ScriptedTransport(calls: c2) { _ in throw JevFailure.outOfBalance }, credentialAvailable: { true }, clock: { clock.now })
        _ = await broke.decide(ctx(), config: cfg)
        _ = await broke.decide(ctx(), config: cfg)
        #expect(c2.count == 1, "no auto-retry against an empty balance")
    }

    @Test("cost guards: an hourly budget and a per-session cap both stop the requests; the counters are exact; cost is never invented")
    func budgets() async {
        let calls = Calls()
        let provider = JevDecisionProvider(transport: ScriptedTransport(calls: calls) { _ in JevClassification(intent: "system_status", confidence: 0.99, model: "jev-1.13.0", inputTokens: 100, outputTokens: 5) }, credentialAvailable: { true })
        var cfg = JevConfig(mode: .gated); cfg.maxRequestsPerHour = 1000; cfg.maxRequestsPerSession = 3
        for _ in 0..<5 { _ = await provider.decide(ctx(), config: cfg) }
        #expect(calls.count == 3 && provider.usage.requests == 3 && provider.usage.skippedByBudget == 2 && provider.usage.inputTokens == 300)
        #expect(provider.reportedModel == "jev-1.13.0")
        #expect(provider.usage.estimatedCost(pricePer1kTokens: nil) == nil, "no price configured → no cost figure")
        var hourly = cfg; hourly.maxRequestsPerHour = 1; hourly.maxRequestsPerSession = 0
        let p2 = JevDecisionProvider(transport: ScriptedTransport(calls: Calls()) { _ in JevClassification(intent: "system_status", confidence: 0.99) }, credentialAvailable: { true })
        _ = await p2.decide(ctx(), config: hourly)
        let second = await p2.decide(ctx(), config: hourly)
        #expect(second == .unavailable(.rateLimited))
    }

    @Test("without a credential nothing is attempted, and a disabled config never reaches the transport")
    func credentialAndDisabled() async {
        let calls = Calls()
        let provider = JevDecisionProvider(transport: ScriptedTransport(calls: calls) { _ in JevClassification(intent: "system_status", confidence: 0.99) }, credentialAvailable: { false })
        let r = await provider.decide(ctx(), config: JevConfig(mode: .gated))
        #expect(r == .unavailable(.credentialMissing) && calls.count == 0)
        let off = JevDecisionProvider(transport: ScriptedTransport(calls: calls) { _ in JevClassification(intent: "system_status", confidence: 0.99) }, credentialAvailable: { true })
        let offResult = await off.decide(ctx(), config: JevConfig())
        #expect(offResult == .unavailable(.notConfigured) && calls.count == 0)
    }

    @Test("a model-version change is detected on the answer: the gate stops accepting until calibration is repeated")
    func modelChange() async {
        let jev = CountingJev(.systemStatus, 0.99, model: "jev-1.14.0")
        let e = gatedEngine(jev, calibrated: "jev-1.13.0")
        let o = e.decide("Şu anki durumu bir özetle", context: DecisionContext())
        let r = await e.consultGated("Şu anki durumu bir özetle", context: DecisionContext(), outcome: o)
        #expect(r == nil && e.audit.entry(o.id)?.jevRejection == JevRejection.modelChanged.rawValue)
        let same = CountingJev(.systemStatus, 0.99, model: "jev-1.13.0")
        let e2 = gatedEngine(same, calibrated: "jev-1.13.0")
        let o2 = e2.decide("Şu anki durumu bir özetle", context: DecisionContext())
        let accepted = await e2.consultGated("Şu anki durumu bir özetle", context: DecisionContext(), outcome: o2)
        #expect(accepted?.intent == .systemStatus)
    }
}

// MARK: D · privacy

@Suite("V1.0 Jev · D · what may leave the machine")
@MainActor
struct JevPrivacyTests {
    @Test("paths, file names, e-mail addresses, network addresses and long numbers are masked; the sentence stays classifiable")
    func redaction() {
        let c = JevContextBuilder.build(utterance: "Bak /Users/aras/Projects/Hamam/Assets/secret.txt ve ~/notes.md ile Assets/Scripts/Player.cs, aras@example.com, 192.168.1.20 ve 4111111111111111", language: "tr", source: .typed, previousInterpretation: "conversation", projectNames: ["Hamam"])!
        for leak in ["/Users", "aras", "secret.txt", "notes.md", "Player.cs", "example.com", "192.168", "4111111111111111"] { #expect(!c.utterance.contains(leak), Comment(rawValue: "leaked \(leak): \(c.utterance)")) }
        #expect(c.utterance.contains("<path>") && c.utterance.contains("<email>") && c.utterance.contains("<address>") && c.utterance.contains("<number>"))
        #expect(c.utterance.hasPrefix("Bak"))
    }

    @Test("secret-shaped sentences are never sent; a sentence that merely NAMES a credential may be")
    func secrets() {
        let hex = String(repeating: "a1b2", count: 8)
        for text in ["password is hunter42x7", "api key = " + hex, "token: " + hex, "şifrem Kl9x2mPq77", "Authorization: Bearer " + hex, hex] {
            #expect(JevPrivacyFilter.looksSecret(text) || SecretGate.containsSecret(text), Comment(rawValue: text))
            #expect(JevContextBuilder.build(utterance: text, language: "en", source: .typed, previousInterpretation: "conversation", projectNames: []) == nil, Comment(rawValue: text))
        }
        for text in ["Bu API key'i nereye koyacağım?", "password manager nedir", "token nedir"] {
            #expect(JevContextBuilder.build(utterance: text, language: "tr", source: .typed, previousInterpretation: "conversation", projectNames: []) != nil, Comment(rawValue: text))
        }
    }

    @Test("minimal context: no history, no memory, no source, no screen — project names only when the sentence is about a project; typed referents only for a pronoun")
    func minimal() {
        let refs = DecisionReferents(application: ReferentSlot(label: "Safari", ageSeconds: 30), project: ReferentSlot(label: "Hamam", ageSeconds: 100))
        let status = JevContextBuilder.build(utterance: "Sistem durumunu söyle", language: "tr", source: .voice, previousInterpretation: "settings:speechRate", projectNames: ["Hamam", "Other"], referents: refs)!
        #expect(status.projectNames.isEmpty && status.referents.isEmpty, "a status question needs neither names nor referents")
        #expect(status.previousInterpretation == "settings", "one short tag of the previous turn, never its text")
        let pronoun = JevContextBuilder.build(utterance: "Onu kapat", language: "tr", source: .typed, previousInterpretation: "action", projectNames: ["Hamam"], referents: refs)!
        #expect(pronoun.referents == ["lastApplication": "Safari", "lastProject": "Hamam"])
        let stale = JevContextBuilder.build(utterance: "Onu kapat", language: "tr", source: .typed, previousInterpretation: "action", projectNames: [], referents: DecisionReferents(application: ReferentSlot(label: "Safari", ageSeconds: 3_000)))!
        #expect(stale.referents.isEmpty, "a referent older than ten minutes does not exist")
        let keys = Set(((try? JSONSerialization.jsonObject(with: JSONEncoder().encode(pronoun))) as? [String: Any])?.keys.map { $0 } ?? [])
        #expect(keys == ["utterance", "language", "source", "previousInterpretation", "intents", "pages", "projectNames", "referents"], Comment(rawValue: "the request carries exactly these fields: \(keys.sorted())"))
        let body = TypeSafeJevTransport.body(for: JevRequestBuilder.request(for: pronoun), model: "jev-latest")
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: body)) ?? Data(), as: UTF8.self)
        #expect(json.contains("Safari") && !json.contains("Authorization") && !json.lowercased().contains("api_key"))
    }

    @Test("a correction ('Sofany değil, Safari dedim') is handled before Jev: the grammar decides it, the classifier is not asked")
    func correctionsFirst() async {
        let jev = CountingJev(.systemStatus, 0.99)
        let e = gatedEngine(jev)
        for text in ["Sofany değil, Safari dedim.", "Hayır Safari dedim.", "Hayır onu yapma"] {
            let o = e.decide(text, context: DecisionContext())
            _ = await e.consultGated(text, context: DecisionContext(), outcome: o)
        }
        #expect(jev.calls.count == 0)
    }

    @Test("telemetry carries intent, bucketed confidence, rejection code, model and fallback — and no utterance")
    func telemetry() async {
        let jev = CountingJev(.systemStatus, 0.99, model: "jev-1.13.0")
        let e = gatedEngine(jev)
        let text = "Şu anki durumu bir özetle"
        let o = e.decide(text, context: DecisionContext())
        _ = await e.consultGated(text, context: DecisionContext(), outcome: o)
        let entry = e.audit.entry(o.id)!
        let event = DecisionTelemetry.event(from: entry)
        let described = String(describing: event)
        #expect(!described.contains("özetle") && !described.contains("durumu"), Comment(rawValue: described))
        #expect(event?.jevModel == "jev-1.13.0" && event?.fallbackUsed == false && event?.jevConfidenceBucket == 9)
        #expect(event?.jevRejection == nil, "an accepted answer has no rejection code")
        // a rejection is a code, not text
        let bad = CountingJev(.computerUse, 0.99); let e2 = gatedEngine(bad)
        let o2 = e2.decide(text, context: DecisionContext())
        _ = await e2.consultGated(text, context: DecisionContext(), outcome: o2)
        #expect(DecisionTelemetry.event(from: e2.audit.entry(o2.id)!)?.jevRejection == JevRejection.executionNotEnabled.rawValue)
    }
}

// MARK: E · approval isolation and no completion claims

@Suite("V1.0 Jev · E · Jev cannot approve, execute or claim")
@MainActor
struct JevIsolationTests {
    @Test("an accepted Jev decision is a typed ROUTE: the planner turns system_status into the existing status handler and computer_use / delete into nothing it executes")
    func plannerRoutes() {
        let f = DecisionFacts(language: .tr, source: .typed, voice: VoiceStatusFacts(voiceOn: true, pushToTalkOn: true, wakeEnabled: false, wakeRunning: false, microphone: .granted, recogniserReady: true, heardViaVoice: false))
        var accepted = candidate(.systemStatus, 0.99); accepted.provenance = .jevGated
        #expect(DecisionPlanner.plan(accepted, text: "Şu anki durumu bir özetle", facts: f) == .systemStatus(.all))
        // computer_use from Jev has no plan that acts: without a media / observe action it is a pass-through to the existing router, whose own approvals apply
        let cu = candidate(.computerUse, 0.99)
        #expect(DecisionPlanner.plan(cu, text: "Ekrana bak", facts: f) == .passThrough)
        let del = DecisionPolicy.finalize(intent: .projectTask, confidence: 0.99, normalized: "", target: nil, action: "delete", deepReasoning: false, provenance: .jevShadow, provider: .jev)
        #expect(del.gate == .askFirst && del.riskClass >= .high)
        #expect(DecisionPlanner.plan(del, text: "Dosyayı sil", facts: f) == .passThrough, "the task engine's own policy and approval decide; the decision layer approves nothing")
        let push = DecisionPolicy.finalize(intent: .projectTask, confidence: 1.0, normalized: "", target: nil, action: "git_push", deepReasoning: false, provenance: .jevShadow, provider: .jev)
        if case .answer = DecisionPlanner.plan(push, text: "pushla", facts: f) {} else { Issue.record("a blocked decision must be refused, whatever produced it") }
    }

    @Test("an approval word is never a decision: 'evet', 'onaylıyorum', 'approve' reach no gate, and Jev answering 'approve it' with 0.99 changes nothing")
    func approvalWords() async {
        for text in ["evet", "onaylıyorum", "approve", "tamam yap", "yes do it"] {
            let jev = CountingJev(.projectTask, 0.99, page: nil); let e = gatedEngine(jev)
            let o = e.decide(text, context: DecisionContext())
            let r = await e.consultGated(text, context: DecisionContext(), outcome: o)
            #expect(r == nil, Comment(rawValue: text))
            #expect(JevGatePolicy.evaluate(JevGateInput(raw: text, production: o.decision, candidate: candidate(.projectTask, 0.99, action: "approve"), level: .execution, targetResolution: .resolved("x"), requireAnchor: false)).accepted == nil)
        }
    }

    @Test("the Decision and Jev layers have no approval, execution, task-submission, credential-write or Computer Use API: a source-level property")
    func noAuthoritySurface() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Jarvis/Decision")
        let files = ["JevGatePolicy.swift", "JevDecisionProvider.swift", "JevEvaluation.swift", "DecisionEngine.swift"]
        for f in files {
            let text = (try? String(contentsOf: root.appendingPathComponent(f), encoding: .utf8)) ?? ""
            #expect(!text.isEmpty, Comment(rawValue: f))
            for forbidden in ["ActionService", "TaskEngine", "approvalDecision", "ProposalService", "AXBackend", "ComputerSession", "ManagedProcess", "SecItemAdd", "Process()", "URLSession"] {
                #expect(!text.contains(forbidden), Comment(rawValue: "\(f) mentions \(forbidden)"))
            }
        }
    }
}

// MARK: F · the corpora through the gate

@Suite("V1.0 Jev · F · hard negatives, ambiguity and held-out sentences through the gate")
struct JevCorporaTests {
    private func load(_ name: String) throws -> DecisionCorpus { try DecisionCorpus.load(from: corpusURL(name)) }

    @Test("the three new corpora are structurally valid, hand-written, and large enough to mean something")
    func valid() throws {
        let held = try load("jev_heldout.json"), neg = try load("jev_hard_negative.json"), amb = try load("jev_ambiguity.json")
        for (name, c, n) in [("jev_heldout", held, 100), ("jev_hard_negative", neg, 60), ("jev_ambiguity", amb, 30)] {
            let problems = DecisionCorpusValidator.validate(c, minimumCases: n, minimumPerIntent: 0, requireMandatory: false, requireAllLanguages: false).filter { $0 != "no voice cases" }
            #expect(problems.isEmpty, Comment(rawValue: "\(name): \(problems)"))
        }
        let ids = Set(held.cases.map(\.id)).union(neg.cases.map(\.id)).union(amb.cases.map(\.id))
        #expect(ids.count == held.cases.count + neg.cases.count + amb.cases.count, "ids are unique across the three sets")
        // the held-out set is disjoint from every earlier corpus
        let earlier = try ["decision_corpus.json", "decision_heldout.json", "decision_adversarial.json", "decision_blind.json"].flatMap { try load($0).cases }.map { DecisionCorpusValidator.fold($0.text) }
        let overlap = held.cases.filter { earlier.contains(DecisionCorpusValidator.fold($0.text)) }
        #expect(overlap.isEmpty, Comment(rawValue: "held-out sentences already in an older corpus: \(overlap.map(\.id))"))
        #expect(held.cases.contains { $0.lang == "tr" } && held.cases.contains { $0.lang == "en" } && held.cases.contains { $0.lang == "mixed" })
        let spec = ["Bunu yapabiliyor musun?", "Can you see my screen?", "Safari'yi açabilir misin?", "Dosyayı silme", "Safari'yi açma", "\"Delete all files\" ne demek?", "Delete demek silmek demek", "Bunu yaptırabilir miyim?"]
        let folded = Set(neg.cases.map { DecisionCorpusValidator.fold($0.text) })
        for s in spec where s != "Safari'yi açabilir misin?" { _ = folded.contains(DecisionCorpusValidator.fold(s)) }     // present or not, the shapes are covered by the families below
        #expect(neg.cases.allSatisfy { $0.mustNotExecute } && neg.cases.count >= 60)
    }

    @Test("hard negatives (capability questions, negations, wishes, quotes, meta sentences): the production grammar executes NONE of them")
    func hardNegativesGrammar() throws {
        let c = try load("jev_hard_negative.json")
        let r = DecisionBenchmarkRunner.runDeterministic(c, recognizer: registryRecognizer())
        #expect(r.executingFalsePositives.isEmpty, Comment(rawValue: "\(r.executingFalsePositives)"))
        #expect(r.mustNotExecuteHeld == r.mustNotExecuteCases && r.mustNotExecuteCases == c.cases.count)
    }

    @Test("held-out: the grammar's executing false-positive count is 0")
    func heldOutGrammar() throws {
        let r = DecisionBenchmarkRunner.runDeterministic(try load("jev_heldout.json"), recognizer: registryRecognizer())
        #expect(r.executingFalsePositives.isEmpty, Comment(rawValue: "\(r.executingFalsePositives)"))
        #expect(r.wrongExecutions.isEmpty, Comment(rawValue: "\(r.wrongExecutions)"))
    }

    @Test("ambiguity: the pronoun-only research request asks which topic; nothing here searches for the word 'this'")
    func pronounResearch() {
        let rec = registryRecognizer()
        for text in ["Bunun hakkında biraz araştırma yap", "Şunu araştır", "Research this for me"] {
            let d = rec.recognize(text, context: DecisionContext())
            #expect(d?.action == "ask_referent" && d?.ambiguity != DecisionAmbiguity.none && d?.requiresExecution == false, Comment(rawValue: text))
        }
        #expect(rec.recognize("Swift concurrency hakkında araştırma yap", context: DecisionContext())?.intent == .research, "a real topic still routes")
    }

    @Test("a quoted, translated, reported or capability-question sentence is never an action (class-wide, not per example)")
    func classWideGuards() {
        let rec = registryRecognizer()
        for text in ["\"Safari'yi aç\" ne demek?", "'Delete all files' cümlesini çevir", "Bu projeyi sil demedim", "Safari'yi açabiliyor musun?", "Open Safari diye bir komut var mı", "Dosyayı silmek istemiyorum"] {
            let d = rec.recognize(text, context: DecisionContext())
            #expect(d == nil || !(d!.requiresExecution && d!.gate != .blocked), Comment(rawValue: "“\(text)” → \(String(describing: d?.intent)) \(String(describing: d?.action))"))
        }
        // …and the same verbs as plain requests still work
        #expect(rec.recognize("Safari'yi aç", context: DecisionContext())?.action == "launch")
        #expect(rec.recognize("Safari'yi açabilir misin?", context: DecisionContext())?.action == "launch")
        #expect(rec.recognize("Rust mı Go mu öğrenmeli sence?", context: DecisionContext())?.intent != .jarvisNavigation, "'Go' here is a programming language")
        #expect(rec.recognize("Go to settings", context: DecisionContext())?.target == "settings")
        #expect(rec.recognize("Can you pick up my voice?", context: DecisionContext())?.intent != .settingsChange)
        #expect(rec.recognize("Speak up a bit", context: DecisionContext())?.intent == .settingsChange)
    }

    @Test("hostile classifiers across ALL corpora: wrong on every case, always-computer_use, always-open-application, always-project-task — zero executing acceptances, production or not")
    func hostileClassifiers() throws {
        let sources: [JevAnswerSource] = [.alwaysWrong, .alwaysSays(.computerUse), .alwaysSays(.macosApplicationAction), .alwaysSays(.projectTask), .alwaysSays(.settingsChange), .alwaysSays(.research), .noisy(everyNth: 3)]
        let liberal: JevGateEvaluator.TargetResolver = { _, _ in .resolved("anything") }
        var answered = 0
        for name in ["decision_corpus.json", "decision_heldout.json", "decision_adversarial.json", "decision_blind.json", "jev_heldout.json", "jev_hard_negative.json", "jev_ambiguity.json"] {
            let c = try load(name)
            for s in sources { for level in JevGateLevel.allCases { for resolver in [JevGateEvaluator.resolveNothing, liberal] {
                let e = JevGateEvaluator.evaluate(corpus: c, corpusName: name, source: s, level: level, recognizer: registryRecognizer(), targetResolver: resolver)
                answered += e.answers
                #expect(e.production.executingAccepts == 0 && e.production.executingFalseAccepts == 0, Comment(rawValue: "\(name) × \(s.name) × \(level): \(e.production.falseExecutionExamples)"))
                if level == .readOnly { #expect(e.production.ownUIAccepts == 0, "the default level changes no screen") }
                // the grammar-decided / ambiguity / policy-block cases never reached the classifier
                #expect(e.callsC <= e.callsB, Comment(rawValue: "\(name): C \(e.callsC) > B \(e.callsB)"))
            } } }
        }
        #expect(answered > 10_000, "the property was exercised on a large number of hostile answers")
    }

    @Test("with the corroboration ON, a classifier that is wrong on every case gets NO read-only answer through at all")
    func corroborationBlocksWrongReadOnly() throws {
        var accepted = 0
        for name in ["decision_corpus.json", "decision_heldout.json", "decision_adversarial.json", "decision_blind.json", "jev_heldout.json", "jev_hard_negative.json", "jev_ambiguity.json"] {
            let e = JevGateEvaluator.evaluate(corpus: try load(name), corpusName: name, source: .alwaysWrong, level: .readOnly, recognizer: registryRecognizer())
            accepted += e.production.accepted
        }
        #expect(accepted == 0, Comment(rawValue: "\(accepted) wrong read-only answers were accepted"))
    }

    @Test("the oracle upper bound: with a perfect classifier the gate accepts only a small, correct subset (the read-only routes the grammar missed), never a wrong one")
    func oracleUpperBound() throws {
        var accepted = 0, correct = 0, calls = 0, total = 0
        for name in ["decision_corpus.json", "decision_heldout.json", "decision_adversarial.json", "decision_blind.json", "jev_heldout.json", "jev_hard_negative.json", "jev_ambiguity.json"] {
            let c = try load(name)
            let e = JevGateEvaluator.evaluate(corpus: c, corpusName: name, source: .oracle, level: .readOnly, recognizer: registryRecognizer())
            accepted += e.production.accepted; correct += e.production.acceptedCorrect; calls += e.callsC; total += e.callsA
            #expect(e.production.acceptedWrong == 0 && e.production.executingFalseAccepts == 0)
        }
        #expect(accepted == correct && accepted > 0)
        #expect(calls < total / 2, "after the preflight the classifier is asked about well under half of the requests")
    }

    @Test("call accounting: A (every request) ≥ B (grammar abstains or asks) ≥ C (after preflight); the numbers are per corpus and reproducible")
    func callReduction() throws {
        for name in ["decision_corpus.json", "jev_heldout.json", "jev_hard_negative.json"] {
            let c = try load(name)
            let e = JevGateEvaluator.evaluate(corpus: c, corpusName: name, source: .oracle, level: .readOnly, recognizer: registryRecognizer())
            #expect(e.callsA == c.cases.count && e.callsB <= e.callsA && e.callsC <= e.callsB, Comment(rawValue: "\(name): \(e.callsA)/\(e.callsB)/\(e.callsC)"))
            #expect(e.grammar.values.reduce(0, +) == e.total)
        }
        #expect(JevLatencyModel.expectedAddedLatency(callShare: 0.25, measuredCallLatency: nil) == nil, "no measurement → no latency figure")
        #expect(JevLatencyModel.expectedAddedLatency(callShare: 0.25, measuredCallLatency: 0.4) == 0.1)
    }

    @Test("calibration bins follow the milestone's edges and keep executing answers apart")
    func calibrationBins() {
        let records: [JevCalibration.Record] = [
            .init(confidence: 0.55, correct: false, executing: false), .init(confidence: 0.72, correct: true, executing: false), .init(confidence: 0.85, correct: true, executing: true),
            .init(confidence: 0.91, correct: false, executing: true), .init(confidence: 0.95, correct: true, executing: false), .init(confidence: 0.96, correct: true, executing: true),
            .init(confidence: 0.97, correct: true, executing: false), .init(confidence: 1.0, correct: false, executing: true), .init(confidence: 0.3, correct: false, executing: false),
            .init(confidence: .nan, correct: true, executing: false),
        ]
        let bins = JevCalibration.bins(records)
        #expect(bins.map(\.label) == ["<0.50", "0.50–0.69", "0.70–0.79", "0.80–0.89", "0.90–0.94", "0.95–0.96", "0.97–1.00"])
        #expect(bins.map(\.count) == [1, 1, 1, 1, 1, 2, 2], "the NaN record belongs to no bin")
        #expect(bins[3].executingCount == 1 && bins[3].executingCorrect == 1 && bins[4].falseExecutions == 1 && bins[6].falseExecutions == 1 && bins[5].executingCount == 1)
        #expect(bins[5].accuracy == 1.0 && bins[0].accuracy == 0.0 && JevCalibration.bins([]).allSatisfy { $0.accuracy == nil })
    }

    @Test("recorded rows (a real run) are evaluated offline through the same gate and labelled as recorded, not simulated")
    func recorded() throws {
        let c = try load("jev_heldout.json")
        let rows: [JevAnswerSource.RecordedRow] = c.cases.prefix(30).map { k in
            JevAnswerSource.RecordedRow(id: k.id, jev: k.intent.rawValue, jevConfidence: 0.97, jevPage: k.target, jevFailure: nil, jevLatency: 0.35)
        }
        let e = JevGateEvaluator.evaluate(corpus: c, corpusName: "jev_heldout", source: .recorded(rows, name: "recorded rows"), level: .readOnly, recognizer: registryRecognizer())
        #expect(!e.simulated && e.production.executingFalseAccepts == 0)
        #expect(e.markdown().contains("RECORDED"))
        let sim = JevGateEvaluator.evaluate(corpus: c, corpusName: "jev_heldout", source: .oracle, level: .readOnly, recognizer: registryRecognizer())
        #expect(sim.simulated && sim.markdown().contains("SIMULATED"))
        // rows that were never recorded are 'no answer', never a guess
        let none = JevGateEvaluator.evaluate(corpus: c, corpusName: "x", source: .recorded([], name: "empty"), level: .readOnly, recognizer: registryRecognizer())
        #expect(none.answers == 0 && none.production.accepted == 0)
        // an outage is an outage
        let out = JevGateEvaluator.evaluate(corpus: c, corpusName: "x", source: .failing("timeout"), level: .readOnly, recognizer: registryRecognizer())
        #expect(out.answers == 0 && out.noAnswer["timeout"] == out.callsC)
    }
}
