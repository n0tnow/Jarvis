import Foundation

// MARK: - The decision engine and its audit trail (V1.0 decision milestone)
//
//   utterance → deterministic grammar (Level 0) → [optional remote classifier: shadow | gated] → a typed Decision → the EXISTING orchestration (action service, readiness answers, Computer Use,
//   continuity, task engine, router, conversation) → execute → verify → ActionReceipt → grounded reply.
// This class produces and records decisions. It cannot execute, approve, grant or verify anything; it has no reference to the task engine, the action service or an approval.

/// Why a decision came out the way it did, for the audit and for Phase B's agreement report. Memory only, bounded; the utterance is kept clipped and in memory — never persisted, never sent anywhere.
struct DecisionAuditEntry: Identifiable, Equatable, Sendable {
    enum Agreement: String, Sendable, Equatable { case agree, disagree, productionUnknown, jevUnavailable, notConsulted }
    let id: UUID
    let at: Date
    let source: UtteranceChannel
    /// Clipped (≤ 160) copy of what the user said, in memory only.
    var utterance: String
    var utteranceLength: Int
    /// A reason code when the VOICE guard rejected the transcript before any decision (then there is no decision at all).
    var voiceGuard: String?
    var production: Decision?
    var jev: Decision?
    var jevLatency: TimeInterval?
    var jevFailure: JevFailure?
    var agreement: Agreement = .notConsulted
    /// What the existing pipeline finally did with it (filled in by the conversation layer): the route, who executed, what was verified, why success or failure was reported.
    var route: String?
    var executor: String?
    var verification: String?
    var outcome: String?
    /// True when a gated remote decision was accepted for routing.
    var jevAccepted = false
    /// The answer came from the in-memory pattern cache (no request was made) / the routing policy declined to ask.
    var jevCacheHit = false
    var jevSkippedByRouting = false
}

@MainActor
final class DecisionAuditLog {
    static let capacity = 200
    private(set) var entries: [DecisionAuditEntry] = []

    @discardableResult
    func begin(source: UtteranceChannel, utterance: String, at: Date = Date()) -> UUID {
        let e = DecisionAuditEntry(id: UUID(), at: at, source: source, utterance: String(utterance.prefix(160)), utteranceLength: utterance.count)
        entries.append(e)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        return e.id
    }
    func update(_ id: UUID, _ change: (inout DecisionAuditEntry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[i])
    }
    func entry(_ id: UUID) -> DecisionAuditEntry? { entries.first { $0.id == id } }
    var last: DecisionAuditEntry? { entries.last }
    func clear() { entries.removeAll() }

    /// The shadow comparison summary Phase B reads (and the benchmark prints).
    var shadowReport: ShadowReport { ShadowReport(entries: entries) }
}

struct ShadowReport: Equatable, Sendable {
    var consulted = 0
    var agree = 0
    var disagree = 0
    var productionUnknown = 0
    var unavailable: [String: Int] = [:]
    var meanLatency: TimeInterval = 0
    var p95Latency: TimeInterval = 0
    /// (confidence, agreed) pairs for calibration.
    var calibration: [(confidence: Double, agreed: Bool)] = []

    init(entries: [DecisionAuditEntry]) {
        var latencies: [TimeInterval] = []
        for e in entries {
            switch e.agreement {
            case .notConsulted: continue
            case .agree: agree += 1
            case .disagree: disagree += 1
            case .productionUnknown: productionUnknown += 1
            case .jevUnavailable: unavailable[e.jevFailure?.rawValue ?? "unavailable", default: 0] += 1
            }
            consulted += 1
            if let l = e.jevLatency { latencies.append(l) }
            if let j = e.jev, e.agreement == .agree || e.agreement == .disagree { calibration.append((j.confidence, e.agreement == .agree)) }
        }
        if !latencies.isEmpty {
            meanLatency = latencies.reduce(0, +) / Double(latencies.count)
            let sorted = latencies.sorted()
            p95Latency = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        }
    }
    /// Observed agreement per confidence bucket (the same edges the benchmark uses): the calibration curve Phase B reads before deciding anything about gated mode.
    func calibrationBuckets(edges: [Double] = DecisionBenchmarkRunner.calibrationEdges) -> [(label: String, n: Int, agreed: Int)] {
        (0..<(edges.count - 1)).map { i in
            let inBucket = calibration.filter { $0.confidence >= edges[i] && $0.confidence < edges[i + 1] }
            return ("[\(edges[i]), \(min(edges[i + 1], 1.0)))", inBucket.count, inBucket.filter(\.agreed).count)
        }
    }
    var agreementRate: Double { (agree + disagree) == 0 ? 0 : Double(agree) / Double(agree + disagree) }

    static func == (a: ShadowReport, b: ShadowReport) -> Bool {
        a.consulted == b.consulted && a.agree == b.agree && a.disagree == b.disagree && a.productionUnknown == b.productionUnknown && a.unavailable == b.unavailable
            && a.meanLatency == b.meanLatency && a.p95Latency == b.p95Latency && a.calibration.count == b.calibration.count
    }
}

@MainActor
final class DecisionEngine {
    var recognizer: DeterministicCommandRecognizer
    /// nil = no remote classifier exists (the default). Even when one is set, `config().mode == .disabled` means it is never asked.
    var jev: (any DecisionProviding)?
    var config: () -> JevConfig = { JevConfig() }
    /// Names of known projects for the minimised context (names only, bounded). Injected; never paths.
    var projectNames: () -> [String] = { [] }
    let audit = DecisionAuditLog()
    /// In-memory, bounded, salted-hash pattern cache of remote answers (see `DecisionPatternCache`). Never persisted, forgets on `clear()`.
    let patternCache = DecisionPatternCache()
    /// Forwarded as a content-free one-liner to the activity feed.
    var onActivity: ((String) -> Void)?
    private var pendingShadow: [Task<Void, Never>] = []

    init(recognizer: DeterministicCommandRecognizer = DeterministicCommandRecognizer(), jev: (any DecisionProviding)? = nil) {
        self.recognizer = recognizer; self.jev = jev
    }

    struct Outcome: Sendable {
        var id: UUID
        var decision: Decision
    }

    /// The production decision (deterministic grammar, else `.unknown` = the existing router). Synchronous and independent of any remote service. In shadow mode a background comparison is started;
    /// it can change nothing about what happens next.
    func decide(_ raw: String, context: DecisionContext, language: ReplyLanguage = .en) -> Outcome {
        let id = audit.begin(source: context.source, utterance: raw)
        let production = recognizer.recognize(raw, context: context) ?? Decision.unknown(String(raw.prefix(120)))
        audit.update(id) { $0.production = production }
        onActivity?("Decision: \(production.intent.rawValue)\(production.action.map { "/" + $0 } ?? "") via \(production.provider.rawValue)")
        let cfg = config()
        // Shadow mode measures the classifier where it could matter — on an ABSTENTION of the grammar. A request the grammar owns is never sent (cost, privacy, latency); the offline benchmark covers those.
        if cfg.mode == .shadow, let jev, cfg.shadowScope == .everything || JevRoutingPolicy.shouldConsult(raw, production: production), let jevContext = makeContext(raw, context: context, language: language, config: cfg) {
            let task = Task { @MainActor [weak self] in
                let result = await jev.decide(jevContext, config: cfg)
                self?.recordShadow(id, production: production, result: result)
            }
            pendingShadow.append(task)
            pendingShadow.removeAll { $0.isCancelled }
        }
        return Outcome(id: id, decision: production)
    }

    /// GATED mode, only when the production grammar found nothing: ask the remote classifier and accept its answer ONLY if `GatedPolicy` allows it. Returns the accepted decision, or nil
    /// (the existing router then handles the utterance exactly as it would without Jev). A deterministic decision is never replaced.
    func consultGated(_ raw: String, context: DecisionContext, outcome: Outcome, language: ReplyLanguage = .en) async -> Decision? {
        let cfg = config()
        guard cfg.mode == .gated, outcome.decision.intent == .unknown, outcome.decision.gate == .none, let jev else { return nil }
        // the routing policy: only a short, command-shaped abstention is worth a (possibly paid) remote opinion
        guard JevRoutingPolicy.shouldConsult(raw, production: outcome.decision) else { audit.update(outcome.id) { $0.jevSkippedByRouting = true }; return nil }
        // a pattern this classifier already answered with very high confidence (re-checked against the CURRENT threshold)
        if var cached = patternCache.lookup(raw), GatedPolicy.accepts(cached, minimumConfidence: cfg.gatedMinimumConfidence) {
            cached.provenance = .jevGated
            audit.update(outcome.id) { $0.jevAccepted = true; $0.jevCacheHit = true; $0.jev = cached; $0.agreement = .productionUnknown }
            return cached
        }
        guard let jevContext = makeContext(raw, context: context, language: language, config: cfg) else { return nil }
        let result = await jev.decide(jevContext, config: cfg)
        recordShadow(outcome.id, production: outcome.decision, result: result)
        guard case .decision(var d, _) = result, GatedPolicy.accepts(d, minimumConfidence: cfg.gatedMinimumConfidence) else { return nil }
        d.provenance = .jevGated
        patternCache.store(raw, d)
        audit.update(outcome.id) { $0.jevAccepted = true }
        return d
    }

    /// Lets tests (and shutdown) wait for background shadow comparisons.
    func awaitShadow() async { for t in pendingShadow { await t.value }; pendingShadow.removeAll() }

    private func makeContext(_ raw: String, context: DecisionContext, language: ReplyLanguage, config: JevConfig) -> JevDecisionContext? {
        JevContextBuilder.build(utterance: raw, language: language.rawValue, source: context.source, previousInterpretation: context.previousInterpretation, projectNames: projectNames(), config: config)
    }

    private func recordShadow(_ id: UUID, production: Decision, result: DecisionProviderResult) {
        audit.update(id) { e in
            switch result {
            case .unavailable(let why):
                e.agreement = .jevUnavailable; e.jevFailure = why
            case .decision(var d, let latency):
                d.provenance = .jevShadow
                e.jev = d; e.jevLatency = latency
                e.agreement = production.intent == .unknown ? .productionUnknown : (production.intent == d.intent ? .agree : .disagree)
            }
        }
        if let e = audit.entry(id) { onActivity?("Decision shadow: \(e.agreement.rawValue)") }
    }

    /// Called by the conversation layer once the existing pipeline has acted on a decision.
    func record(_ id: UUID, route: String, executor: String? = nil, verification: String? = nil, outcome: String? = nil) {
        audit.update(id) { $0.route = route; $0.executor = executor ?? $0.executor; $0.verification = verification ?? $0.verification; $0.outcome = outcome ?? $0.outcome }
    }
}
