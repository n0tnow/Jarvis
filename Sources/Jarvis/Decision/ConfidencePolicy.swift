import Foundation

// MARK: - Confidence policy, remote-classifier routing, retry and pattern cache (V1.0 reliability pass)
//
// ONE place that says what a confidence number is worth, per kind of decision — and, as important, what it is NOT worth:
//   · confidence is evidence about CLASSIFICATION. It never overrides risk, the approval policy, a permission or the requirement to verify an outcome: `accepts` also requires no gate and no ambiguity,
//     and an executing / computer / project-writing / settings decision is never accepted from a REMOTE classifier at any confidence;
//   · read-only answers (status, capability questions) may be accepted at a lower confidence than anything that changes JARVIS' own screen, because a wrong read-only answer costs one sentence;
//   · the thresholds are RULES with a stated rationale, not numbers fitted to a benchmark. The Phase B measurements (monotonic calibration, ≥ 0.97 → 100 %, held-out ≥ 0.97 → 97.8 %) are the reason the
//     remote floors sit where they do; they were not tuned until a benchmark liked them, and the benchmark is re-measured, never edited.

enum DecisionCategory: String, CaseIterable, Sendable {
    /// Answers from JARVIS' own state: status, voice, capability, project queries, conversation.
    case readOnly
    /// Changes only JARVIS' own screen (pages, HUD).
    case ownUI
    /// Operates an application, starts a project action, changes a setting, researches, stops something.
    case executing
    /// Computer Use (observe, media, UI actions).
    case computer
    /// Policy-gated or blocked (delete, push, purchase, credentials).
    case policyGated
}

enum ConfidenceSource: String, Sendable { case deterministic, remote }

struct ConfidencePolicy: Equatable, Sendable {
    /// Minimum confidence per category for a decision from the closed deterministic grammar. These are authoring-time constants (an exact closed form is ≥ 0.9, a tolerant form 0.6–0.88), not probabilities:
    /// the floor only keeps a FUTURE low-confidence deterministic path from executing.
    var local: [DecisionCategory: Double] = [.readOnly: 0.5, .ownUI: 0.6, .executing: 0.6, .computer: 0.6, .policyGated: 0.6]
    /// Minimum confidence for a REMOTE classifier's answer. A category absent here is NEVER accepted remotely.
    var remote: [DecisionCategory: Double] = [.readOnly: 0.88, .ownUI: 0.92]

    static let standard = ConfidencePolicy()

    static func category(of d: Decision) -> DecisionCategory {
        if d.gate != .none || d.riskClass >= .high { return .policyGated }
        if d.requiresComputerUse || d.intent == .computerUse { return .computer }
        switch d.intent {
        case .conversation, .voiceStatus, .systemStatus, .projectQuery, .providerCapability, .correction, .unknown: return .readOnly
        case .jarvisNavigation: return .ownUI
        default: return .executing
        }
    }

    /// nil = never accepted from this source.
    func threshold(for d: Decision, source: ConfidenceSource) -> Double? {
        let c = Self.category(of: d)
        return source == .remote ? remote[c] : local[c]
    }

    /// Accepted for ROUTING (not for execution: execution is decided by the policy gate and the verified receipt, never by this). `configuredFloor` is the user's own minimum (it can only raise the bar).
    func accepts(_ d: Decision, source: ConfidenceSource, configuredFloor: Double = 0) -> Bool {
        guard let floor = threshold(for: d, source: source), d.ambiguity == .none || d.action == "ask_referent" else { return false }
        if source == .remote, d.gate != .none || d.riskClass != .low { return false }
        return d.confidence >= max(floor, configuredFloor)
    }
}

// MARK: - When the remote classifier is worth asking

/// The grammar owns every request it understands; an abstention is the only moment a remote opinion can help, and only for a SHORT, command-shaped sentence. A long paragraph is conversation (the router's
/// job), code is never sent, and a secret-shaped sentence is refused by the context builder. Pure.
enum JevRoutingPolicy {
    static let maxTokens = 10
    static let maxCharacters = 100

    static func shouldConsult(_ raw: String, production: Decision) -> Bool {
        guard production.intent == .unknown, production.gate == .none, production.ambiguity == .none else { return false }
        return isCommandShaped(raw)
    }

    static func isCommandShaped(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxCharacters else { return false }
        guard (1...maxTokens).contains(DecisionText.tokens(text).count) else { return false }
        if text.contains("```") || text.contains("{") || text.contains("};") || text.contains("func ") || text.contains("import ") { return false }
        return true
    }
}

/// Bounded retry for a transient transport failure: one more attempt after a short backoff, only for failures that can clear by themselves in a moment. Never for a timeout (the speech latency budget is spent),
/// a rate limit, an exhausted balance, a changed API, a missing credential or a malformed answer — those open the breaker or are the end of the request.
enum JevRetryPolicy {
    static let transient: Set<JevFailure> = [.offline, .unavailable]
    static func shouldRetry(_ failure: JevFailure, attempt: Int, maxRetries: Int) -> Bool { attempt < maxRetries && transient.contains(failure) }
    static func backoff(attempt: Int, base: TimeInterval) -> TimeInterval { min(2.0, base * pow(2, Double(attempt))) }
}

// MARK: - A tiny, privacy-safe pattern cache for remote answers

/// Remembers WHICH typed decision the classifier gave for a NORMALIZED PATTERN, so the same short command is not paid for twice. Strictly bounded and deliberately dumb:
///   · the key is a salted hash of the folded, digit-masked tokens — no utterance text is kept, nothing is persisted, the salt dies with the process;
///   · only a decision the gated policy would accept anyway, at very high confidence, and only for sentences of at most 8 tokens, is stored; never anything executing, never a secret-shaped sentence;
///   · capacity 64 (oldest evicted), entries expire (default 6 h), and `clear()` forgets everything;
///   · a hit is re-checked by the policy before it is used, so lowering the user's threshold takes effect at once.
final class DecisionPatternCache: @unchecked Sendable {
    struct Entry: Sendable { var decision: Decision; var storedAt: Date }
    static let minimumConfidenceToStore = 0.97
    static let maxTokens = 8

    private let capacity: Int
    private let ttl: TimeInterval
    private let clock: @Sendable () -> Date
    private let salt: UInt64
    private let lock = NSLock()
    private var entries: [UInt64: Entry] = [:]
    private var order: [UInt64] = []
    private(set) var hits = 0
    private(set) var misses = 0

    init(capacity: Int = 64, ttl: TimeInterval = 6 * 3600, salt: UInt64 = UInt64.random(in: 1...UInt64.max), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.capacity = max(1, capacity); self.ttl = ttl; self.salt = salt; self.clock = clock
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    /// nil = this sentence is not cacheable (too long, contains a path / long number, or is secret-shaped).
    func key(for utterance: String) -> UInt64? {
        guard !SecretGate.containsSecret(utterance) else { return nil }
        let tokens = DecisionText.tokens(utterance)
        guard (1...Self.maxTokens).contains(tokens.count), utterance.count <= 80, !utterance.contains("/"), !utterance.contains("://") else { return nil }
        let masked = tokens.map { t in t.contains(where: \.isNumber) ? "#" : t }
        var h: UInt64 = 0xcbf29ce484222325 ^ salt
        for byte in masked.joined(separator: " ").utf8 { h ^= UInt64(byte); h = h &* 0x100000001b3 }
        return h
    }

    func lookup(_ utterance: String) -> Decision? {
        guard let k = key(for: utterance) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[k], clock().timeIntervalSince(e.storedAt) <= ttl else { misses += 1; if entries[k] != nil { entries[k] = nil; order.removeAll { $0 == k } }; return nil }
        hits += 1
        return e.decision
    }

    func store(_ utterance: String, _ d: Decision) {
        guard let k = key(for: utterance), d.confidence >= Self.minimumConfidenceToStore, d.gate == .none, d.riskClass == .low, !d.requiresExecution, !d.requiresComputerUse, d.ambiguity == .none,
              GatedPolicy.acceptableIntents.contains(d.intent) else { return }
        lock.lock(); defer { lock.unlock() }
        if entries[k] == nil { order.append(k) }
        entries[k] = Entry(decision: d, storedAt: clock())
        while order.count > capacity { let old = order.removeFirst(); entries[old] = nil }
    }

    func clear() { lock.lock(); entries.removeAll(); order.removeAll(); hits = 0; misses = 0; lock.unlock() }
}
