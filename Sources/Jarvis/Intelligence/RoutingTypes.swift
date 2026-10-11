import Foundation

// MARK: - Benchmark summaries (derived ONLY from recorded results)

struct BenchmarkSummary: Equatable, Sendable {
    var group: BenchmarkGroup
    var total: Int
    var passed: Int
    var malformed: Int
    var medianLatencyMS: Double?
    var lastRanAt: Date?

    var passRate: Double { total == 0 ? 0 : Double(passed) / Double(total) }
    /// Honest display: "4/5", never an invented quality percentage.
    var label: String { "\(passed)/\(total)" }

    /// Summarises the NEWEST result per case of `suite` (older runs of the same case don't count twice).
    static func summarize(_ results: [BenchmarkResultRecord], group: BenchmarkGroup, suite: String) -> BenchmarkSummary? {
        var newest: [String: BenchmarkResultRecord] = [:]
        for r in results where r.category == group && r.suite == suite && !r.cancelled {
            if let old = newest[r.caseID], old.ranAt >= r.ranAt { continue }
            newest[r.caseID] = r
        }
        guard !newest.isEmpty else { return nil }
        let rs = Array(newest.values)
        let latencies = rs.compactMap(\.latencyMS).sorted()
        return BenchmarkSummary(group: group, total: rs.count, passed: rs.filter(\.passed).count, malformed: rs.filter(\.malformed).count,
                                medianLatencyMS: latencies.isEmpty ? nil : latencies[latencies.count / 2],
                                lastRanAt: rs.map(\.ranAt).max())
    }
}

struct BenchmarkPolicy: Equatable, Sendable {
    /// A model must have been benchmarked on ALL cases of the group in the current suite…
    var requiredCases: [BenchmarkGroup: Int] = [.general: 3, .research: 3, .coding: 4, .testing: 3]
    /// …and passed at least this fraction. (Coding/testing are stricter: a miss there costs real work.)
    var minPassRate: [BenchmarkGroup: Double] = [.general: 0.66, .research: 0.66, .coding: 0.75, .testing: 0.66]
    var maxAge: TimeInterval = 14 * 24 * 3600

    func isEligible(_ s: BenchmarkSummary?, group: BenchmarkGroup, now: Date) -> Bool {
        guard let s, s.total >= (requiredCases[group] ?? 3), s.malformed == 0 || Double(s.malformed) / Double(s.total) <= 0.25,
              s.passRate >= (minPassRate[group] ?? 0.75) else { return false }
        if let at = s.lastRanAt, now.timeIntervalSince(at) > maxAge { return false }
        return true
    }
}

// MARK: - Cooldown / backoff (deterministic, testable)

struct CooldownPolicy: Equatable, Sendable {
    var baseSeconds: TimeInterval = 60
    var maxSeconds: TimeInterval = 30 * 60
    /// Failures in a row before cooldown starts (1 = immediately).
    var threshold = 2

    /// Cooldown after `consecutiveFailures`: 0 below the threshold, then base·2^(n−threshold) capped.
    func duration(forConsecutiveFailures n: Int) -> TimeInterval {
        guard n >= threshold else { return 0 }
        return min(maxSeconds, baseSeconds * pow(2, Double(n - threshold)))
    }
}

// MARK: - Resources

enum MemoryPressureLevel: String, Sendable { case normal, warning, critical }

struct ResourcePressure: Equatable, Sendable {
    var memory: MemoryPressureLevel = .normal
    var thermalSerious = false
    var lowPowerMode = false
    var localJobsRunning = 0
    var heavyAgentsRunning = 0
    var backgroundAgentsRunning = 0

    /// Obviously bad moments to start local inference: system under memory pressure / throttling.
    var localInferenceAdvisable: Bool { memory == .normal && !thermalSerious }
}

// MARK: - Settings + availability snapshot

struct RoutingSettings: Equatable, Sendable {
    var allowLocal = true
    var allowFreeCloud = true
    /// Tasks containing project code may only go to free-cloud models documented as zero-retention.
    var projectCodeNeedsZeroRetention = true
    var allowSensitiveOnFreeCloud = false
    /// Auto mode requires a benchmark pass before a free model serves a task automatically.
    var requireBenchmarkForAuto = true
    var benchmark = BenchmarkPolicy()
}

struct EngineAvailability: Equatable, Sendable {
    var engine: ProviderID
    var state: ProviderState
    var cooldownUntil: Date?
    var detail: String?

    init(_ engine: ProviderID, state: ProviderState, cooldownUntil: Date? = nil, detail: String? = nil) {
        self.engine = engine; self.state = state; self.cooldownUntil = cooldownUntil; self.detail = detail
    }

    func isUsable(at now: Date) -> Bool {
        if let c = cooldownUntil, c > now { return false }
        return state == .ready
    }
}

struct RouterSnapshot: Sendable {
    var now = Date()
    var preference: ProviderPreference = .auto
    var engines: [ProviderID: EngineAvailability] = [:]
    var models: [ModelRecord] = []
    var benchmarks: [String: [BenchmarkGroup: BenchmarkSummary]] = [:]
    var modelCooldowns: [String: Date] = [:]
    var resources = ResourcePressure()
    var settings = RoutingSettings()
}

// MARK: - Decision

struct RoutingCandidate: Equatable, Hashable, Sendable, Codable {
    var engine: ProviderID
    var model: String?
    var label: String { model.map { "\(engine.displayName) · \($0)" } ?? engine.displayName }
}

enum RoutingRefusal: Equatable, Sendable {
    case localForbiddenForTask([String])
    case engineUnavailable(ProviderID, String)
    case noEligibleFreeModel(String)
    case sensitiveBlockedFromFreeCloud
    case noCandidate(String)
}

struct RoutingDecision: Equatable, Sendable {
    enum Outcome: Equatable, Sendable { case selected(RoutingCandidate), refused(RoutingRefusal) }

    var outcome: Outcome
    var profile: TaskProfile
    var mode: ProviderPreference
    /// Ordered remaining eligible candidates — the bounded escalation chain (never re-evaluated mid-run).
    var fallbacks: [RoutingCandidate] = []
    /// Machine-readable reason (flat, string-valued, stable keys). Persisted in `agent_runs.selection_reason`.
    var reasons: [String: String] = [:]
    var rejected: [String: String] = [:]

    var selected: RoutingCandidate? { if case .selected(let c) = outcome { return c }; return nil }

    var reasonJSON: String {
        var all = reasons
        all["mode"] = mode.rawValue
        all["outcome"] = selected == nil ? "refused" : "selected"
        for (k, v) in rejected.sorted(by: { $0.key < $1.key }) { all["rejected.\(k)"] = v }
        if let data = try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]) { return String(decoding: data, as: UTF8.self) }
        return "{}"
    }

    /// Short, user-facing explanation of a refusal.
    func refusalMessage(_ l: ReplyLanguage = .en) -> String? {
        guard case .refused(let r) = outcome else { return nil }
        func p(_ en: String, _ tr: String) -> String { l == .tr ? tr : en }
        switch r {
        case .localForbiddenForTask:
            return p("The local model is limited to lightweight tasks and can't do this one. Pick Auto, OpenCode Free, Claude Code or Codex in Settings.",
                     "Yerel model yalnızca hafif işler içindir; bunu yapamaz. Ayarlar'dan Auto, OpenCode Free, Claude Code veya Codex seçin.")
        case .engineUnavailable(let e, _):
            return p("\(e.displayName) isn't available right now. (You chose it explicitly, so JARVIS won't switch to another provider.)",
                     "\(e.displayName) şu an kullanılamıyor. (Bunu açıkça seçtiğiniz için JARVIS başka bir sağlayıcıya geçmez.)")
        case .noEligibleFreeModel:
            return p("No verified-free OpenCode model is available for this request. Nothing was sent.",
                     "Bu istek için doğrulanmış ücretsiz bir OpenCode modeli yok. Hiçbir şey gönderilmedi.")
        case .sensitiveBlockedFromFreeCloud:
            return p("This looks sensitive, so it won't be sent to a free cloud model. Choose Local, Claude Code or Codex.",
                     "Bu içerik hassas görünüyor; ücretsiz bulut modeline gönderilmeyecek. Yerel, Claude Code veya Codex seçin.")
        case .noCandidate:
            return p("No provider is ready for this request.", "Bu istek için hazır bir sağlayıcı yok.")
        }
    }
}
