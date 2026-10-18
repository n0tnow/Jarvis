import Foundation

// MARK: - Content-free decision telemetry (V1.0 reliability pass)
//
// What is worth keeping about how the decision layer behaved is never what the person said: it is WHICH intent was chosen, how confident, by whom, how fast, and what happened. `DecisionTelemetry` folds
// audit entries into counters and small histograms — no utterance, no target name, no path — held in memory only with a hard bound (a ring of the most recent `capacity` events, expired after `retention`).
// There is no persistence in this type: a restart forgets it, and `clear()` forgets it sooner.

struct DecisionTelemetryEvent: Equatable, Sendable {
    var at: Date
    var intent: DecisionIntent
    var provider: DecisionProviderID
    var provenance: DecisionProvenance
    var confidenceBucket: Int          // 0…10 (tenths)
    var gate: DecisionGate
    var latencyBucketMs: Int?          // 0, 50, 100, 250, 500, 1000, 2500, 5000+
    var route: String?                 // “action”, “answer”, “system status” … (a fixed set written by the conversation layer)
    var outcome: String?               // “answered”, “verified”, “failed” … (bounded vocabulary)
    var jevAgreement: String?
    var reason: String?                // a CODE: “gated-accepted”, “routing-skip”, “cache-hit”, “guard-rejected” …
    /// V1.0 Jev gating pass: why a remote answer was rejected (a `JevRejection` code), the model that answered (a version id, never text) and whether the existing path handled the sentence.
    var jevRejection: String?
    var jevModel: String?
    var fallbackUsed: Bool = false
    var jevConfidenceBucket: Int?
}

struct DecisionTelemetry: Equatable, Sendable {
    private(set) var events: [DecisionTelemetryEvent] = []
    let capacity: Int
    let retention: TimeInterval

    init(capacity: Int = 500, retention: TimeInterval = 7 * 86_400) { self.capacity = max(1, capacity); self.retention = retention }

    static func latencyBucket(_ seconds: TimeInterval) -> Int {
        let ms = seconds * 1000
        for edge in [0, 50, 100, 250, 500, 1000, 2500, 5000] where ms < Double(edge) + (edge == 0 ? 50 : 0) { return edge }
        return 5000
    }

    mutating func ingest(_ e: DecisionTelemetryEvent, now: Date = Date()) {
        events.append(e)
        prune(now: now)
    }

    /// Builds an event from an audit entry WITHOUT copying any text.
    static func event(from e: DecisionAuditEntry, reason: String? = nil) -> DecisionTelemetryEvent? {
        guard let d = e.production else { return nil }
        return DecisionTelemetryEvent(at: e.at, intent: d.intent, provider: d.provider, provenance: d.provenance, confidenceBucket: Int((d.confidence * 10).rounded(.down)), gate: d.gate,
                                      latencyBucketMs: e.jevLatency.map { latencyBucket($0) }, route: e.route, outcome: e.outcome.map { String($0.prefix(24)) }, jevAgreement: e.agreement == .notConsulted ? nil : e.agreement.rawValue,
                                      reason: reason ?? (e.jevCacheHit ? "cache-hit" : e.jevSkippedByRouting ? "routing-skip" : e.jevAccepted ? "gated-accepted" : nil),
                                      jevRejection: e.jevRejection, jevModel: e.jevModel.map { String($0.prefix(40)) }, fallbackUsed: e.jevFallbackUsed, jevConfidenceBucket: e.jev.map { Int(($0.confidence * 10).rounded(.down)) })
    }

    mutating func prune(now: Date = Date()) {
        events.removeAll { now.timeIntervalSince($0.at) > retention }
        if events.count > capacity { events.removeFirst(events.count - capacity) }
    }

    mutating func clear() { events.removeAll() }

    // MARK: Summaries (counts only)

    func countByIntent() -> [String: Int] { Dictionary(events.map { ($0.intent.rawValue, 1) }, uniquingKeysWith: +) }
    func countByProvider() -> [String: Int] { Dictionary(events.map { ($0.provider.rawValue, 1) }, uniquingKeysWith: +) }
    var deterministicShare: Double { events.isEmpty ? 0 : Double(events.filter { $0.provider == .deterministic }.count) / Double(events.count) }
    var gatedOrBlocked: Int { events.filter { $0.gate != .none }.count }
    var remoteAccepted: Int { events.filter { $0.provenance == .jevGated }.count }

    func summary() -> String {
        let byIntent = countByIntent().sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return "events \(events.count) · deterministic \(Int(deterministicShare * 100))% · gated/blocked \(gatedOrBlocked) · remote accepted \(remoteAccepted) · \(byIntent)"
    }
}
