import Foundation

// MARK: - Local conversational model benchmark harness (V1.0 decision milestone)
//
// The conversational model (today: Qwen3.5-4B, MLX 4-bit) is a SEPARATE problem from command decisions and from voice reliability: a stronger model is never the fix for either. This harness is how the
// user's real Mac (MacBook Air M5, 16 GB) will compare the current model with a few stronger local candidates, on a fixed qualitative rubric and on measured performance.
// Cloud ships the harness only: nothing is downloaded, nothing is loaded, no performance number is invented. `DryRunModelRunner` exercises the whole path and marks every measurement NOT MEASURED.
// No candidate is chosen here and no production model is changed — Phase B selects candidates (availability, licence, MLX compatibility, size) and decides from measured results.

struct ModelCandidate: Codable, Equatable, Sendable {
    var id: String
    var displayName: String
    var license: String?
    var approximateSizeGB: Double?
    var quantization: String?
    var notes: String?
}

/// One deterministic check on a model's answer. Checks are string-level on purpose: the qualitative judgement ("is the Turkish natural?") stays a HUMAN review field in the report.
enum RubricCheck: Codable, Equatable, Sendable {
    case containsAny([String])
    case containsNone([String])
    case maxWords(Int)
    case language(String)                       // "tr" | "en": the answer is mostly in that language
    case asksClarification                      // ends in or contains a question that asks what was meant
    case doesNotClaimCapability([String])       // never says it did / can do these things (e.g. "açtım", "I opened")
    case mentionsFromContext([String])          // uses a fact that was in the supplied context (grounding)

    private enum CodingKeys: String, CodingKey { case kind, words, limit, lang }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "containsAny": self = .containsAny(try c.decode([String].self, forKey: .words))
        case "containsNone": self = .containsNone(try c.decode([String].self, forKey: .words))
        case "maxWords": self = .maxWords(try c.decode(Int.self, forKey: .limit))
        case "language": self = .language(try c.decode(String.self, forKey: .lang))
        case "asksClarification": self = .asksClarification
        case "doesNotClaimCapability": self = .doesNotClaimCapability(try c.decode([String].self, forKey: .words))
        case "mentionsFromContext": self = .mentionsFromContext(try c.decode([String].self, forKey: .words))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown rubric check")
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .containsAny(let w): try c.encode("containsAny", forKey: .kind); try c.encode(w, forKey: .words)
        case .containsNone(let w): try c.encode("containsNone", forKey: .kind); try c.encode(w, forKey: .words)
        case .maxWords(let n): try c.encode("maxWords", forKey: .kind); try c.encode(n, forKey: .limit)
        case .language(let l): try c.encode("language", forKey: .kind); try c.encode(l, forKey: .lang)
        case .asksClarification: try c.encode("asksClarification", forKey: .kind)
        case .doesNotClaimCapability(let w): try c.encode("doesNotClaimCapability", forKey: .kind); try c.encode(w, forKey: .words)
        case .mentionsFromContext(let w): try c.encode("mentionsFromContext", forKey: .kind); try c.encode(w, forKey: .words)
        }
    }

    func passes(_ answer: String) -> Bool {
        let f = DecisionText.fold(answer)
        func has(_ w: String) -> Bool { f.contains(DecisionText.fold(w)) }
        switch self {
        case .containsAny(let ws): return ws.contains(where: has)
        case .containsNone(let ws): return !ws.contains(where: has)
        case .maxWords(let n): return answer.split(whereSeparator: { $0.isWhitespace }).count <= n
        case .language(let l): return Self.languageShare(answer, l) >= 0.5
        case .asksClarification: return answer.contains("?") || has("hangisi") || has("ne demek") || has("which") || has("what do you mean") || has("could you clarify")
        case .doesNotClaimCapability(let ws): return !ws.contains(where: has)
        case .mentionsFromContext(let ws): return ws.contains(where: has)
        }
    }

    /// Crude, closed-vocabulary language share (Turkish vs English function words); enough to catch "answered in the wrong language", not a language identifier.
    static func languageShare(_ text: String, _ lang: String) -> Double {
        let tr: Set<String> = ["ve", "bir", "bu", "icin", "ne", "ama", "ben", "sen", "var", "yok", "mi", "mu", "evet", "hayir", "tamam", "ile", "de", "da", "gibi", "cok", "daha", "ise", "olarak", "biraz", "nasil", "neden", "sunu", "onu", "bunu", "sizin", "benim", "simdi", "lutfen", "yapabilirim", "edebilirim", "degil", "icin", "kadar", "olan"]
        let en: Set<String> = ["the", "and", "is", "are", "to", "of", "in", "that", "it", "for", "you", "with", "this", "can", "will", "not", "have", "your", "what", "but", "yes", "no", "please", "just", "i", "my", "be", "do"]
        let words = DecisionText.tokens(text)
        let t = words.filter { tr.contains($0) }.count, e = words.filter { en.contains($0) }.count
        guard t + e > 0 else { return 0.5 }
        return lang == "tr" ? Double(t) / Double(t + e) : Double(e) / Double(t + e)
    }
}

struct ConversationalProbe: Codable, Equatable, Sendable {
    struct Turn: Codable, Equatable, Sendable { var role: String; var text: String }
    var id: String
    /// turkish_conversation · mixed_language · stt_recovery · correction · referent · followup · capability_hallucination · grounded_response
    var category: String
    var history: [Turn]
    var prompt: String
    /// Facts JARVIS would supply from its own state (for grounded probes); the model must use them, not invent.
    var groundingContext: String?
    var checks: [RubricCheck]
}

struct ConversationalProbeSet: Codable, Equatable, Sendable {
    static let schemaID = "jarvis.local-model-probes/1"
    var schema: String
    var version: String
    var description: String
    var probes: [ConversationalProbe]
    static func load(from url: URL) throws -> ConversationalProbeSet {
        guard let data = FileManager.default.contents(atPath: url.path) else { throw CocoaError(.fileReadNoSuchFile) }
        return try JSONDecoder().decode(ConversationalProbeSet.self, from: data)
    }

    static let categories = ["turkish_conversation", "mixed_language", "stt_recovery", "correction", "referent", "followup", "capability_hallucination", "grounded_response"]

    func validate() -> [String] {
        var problems: [String] = []
        if schema != Self.schemaID { problems.append("schema is \(schema)") }
        var ids = Set<String>()
        for p in probes {
            if !ids.insert(p.id).inserted { problems.append("duplicate id \(p.id)") }
            if p.prompt.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("\(p.id): empty prompt") }
            if p.checks.isEmpty { problems.append("\(p.id): no checks") }
            if !Self.categories.contains(p.category) { problems.append("\(p.id): unknown category \(p.category)") }
        }
        for c in Self.categories where !probes.contains(where: { $0.category == c }) { problems.append("no probes in category \(c)") }
        return problems
    }
}

// MARK: Running

/// What one generation produced. Every performance field is optional: a runner reports what it measured, and the report says "not measured" for the rest.
struct ModelRun: Equatable, Sendable {
    var text: String
    var timeToFirstToken: TimeInterval?
    var totalSeconds: TimeInterval?
    var outputTokens: Int?
    var contextTokens: Int?
    var failed: Bool = false
}

protocol ConversationalModelRunning: Sendable {
    var candidate: ModelCandidate { get }
    /// Seconds to load the model for this run (nil = not measured / not applicable).
    func load() async throws -> TimeInterval?
    func generate(_ probe: ConversationalProbe) async -> ModelRun
    /// Resident memory in MB right now (nil = not measured). Sampled by the harness after load and after the last probe.
    func residentMemoryMB() -> Double?
    func unload() async
}

/// Exercises the whole harness without any model: canned answers, nothing measured. Used by the tests and by a Phase B dry run before the real runner is wired.
struct DryRunModelRunner: ConversationalModelRunning {
    var candidate = ModelCandidate(id: "dry-run", displayName: "Dry run (no model)", license: nil, approximateSizeGB: nil, quantization: nil, notes: "nothing is loaded or measured")
    var answer: @Sendable (ConversationalProbe) -> String = { _ in "" }
    func load() async throws -> TimeInterval? { nil }
    func generate(_ probe: ConversationalProbe) async -> ModelRun { ModelRun(text: answer(probe)) }
    func residentMemoryMB() -> Double? { nil }
    func unload() async {}
}

struct LocalModelReport: Equatable, Sendable {
    struct CategoryResult: Equatable, Sendable { var category: String; var probes: Int; var passed: Int; var rate: Double { probes == 0 ? 0 : Double(passed) / Double(probes) } }
    var candidate: ModelCandidate
    var dryRun: Bool
    var probes = 0
    var failedGenerations = 0
    var checksPassedProbes = 0
    var categories: [CategoryResult] = []
    var loadSeconds: TimeInterval?
    var medianTimeToFirstToken: TimeInterval?
    var meanTokensPerSecond: Double?
    var memoryAfterLoadMB: Double?
    var memoryAfterRunMB: Double?
    var meanResponseWords = 0.0
    var maxContextTokens: Int?
    /// Probe ids that failed a check, with the failed check — for the human reviewer.
    var failures: [String] = []
    /// Everything this harness cannot judge itself. A human fills these in.
    var manualReview: [String: String?] = ["turkish_naturalness": nil, "mixed_language_quality": nil, "tone": nil]
    var notMeasured: [String] = []

    var passRate: Double { probes == 0 ? 0 : Double(checksPassedProbes) / Double(probes) }
    var failureRate: Double { probes == 0 ? 0 : Double(failedGenerations) / Double(probes) }

    func markdown() -> String {
        var s = "## Local model — \(candidate.displayName)\(dryRun ? "  (DRY RUN — nothing was loaded or measured)" : "")\n\n"
        s += "probes: \(probes) · rubric pass: \(Int(passRate * 100))% · generation failures: \(Int(failureRate * 100))% · mean response: \(Int(meanResponseWords)) words\n"
        for c in categories { s += "  \(c.category): \(c.passed)/\(c.probes)\n" }
        func f(_ v: Double?, _ unit: String, _ scale: Double = 1) -> String { v.map { String(format: "%.2f", $0 * scale) + unit } ?? "NOT MEASURED" }
        s += "load: \(f(loadSeconds, " s")) · TTFT median: \(f(medianTimeToFirstToken, " ms", 1000)) · tokens/s: \(f(meanTokensPerSecond, ""))\n"
        s += "memory after load: \(f(memoryAfterLoadMB, " MB")) · after run: \(f(memoryAfterRunMB, " MB")) · max context: \(maxContextTokens.map(String.init) ?? "NOT MEASURED")\n"
        if !failures.isEmpty { s += "failed checks: \(failures.prefix(12).joined(separator: "; "))\n" }
        s += "manual review needed: \(manualReview.keys.sorted().joined(separator: ", "))\n"
        return s
    }
}

enum LocalModelBenchmark {
    static func run(runner: any ConversationalModelRunning, probes: ConversationalProbeSet, dryRun: Bool) async -> LocalModelReport {
        var report = LocalModelReport(candidate: runner.candidate, dryRun: dryRun)
        report.loadSeconds = try? await runner.load()
        report.memoryAfterLoadMB = runner.residentMemoryMB()
        var ttfts: [TimeInterval] = [], rates: [Double] = [], words: [Int] = []
        var byCategory: [String: (n: Int, ok: Int)] = [:]
        for p in probes.probes {
            let run = await runner.generate(p)
            report.probes += 1
            if run.failed { report.failedGenerations += 1 }
            let failed = p.checks.filter { !$0.passes(run.text) }
            let ok = !run.failed && failed.isEmpty
            if ok { report.checksPassedProbes += 1 } else { report.failures.append("\(p.id)") }
            byCategory[p.category, default: (0, 0)].n += 1
            if ok { byCategory[p.category, default: (0, 0)].ok += 1 }
            words.append(run.text.split(whereSeparator: { $0.isWhitespace }).count)
            if let t = run.timeToFirstToken { ttfts.append(t) }
            if let n = run.outputTokens, let total = run.totalSeconds, total > 0, n > 0 { rates.append(Double(n) / total) }
            if let c = run.contextTokens { report.maxContextTokens = max(report.maxContextTokens ?? 0, c) }
        }
        report.memoryAfterRunMB = runner.residentMemoryMB()
        await runner.unload()
        report.categories = ConversationalProbeSet.categories.compactMap { c in byCategory[c].map { .init(category: c, probes: $0.n, passed: $0.ok) } }
        report.meanResponseWords = words.isEmpty ? 0 : Double(words.reduce(0, +)) / Double(words.count)
        if !ttfts.isEmpty { report.medianTimeToFirstToken = ttfts.sorted()[ttfts.count / 2] }
        if !rates.isEmpty { report.meanTokensPerSecond = rates.reduce(0, +) / Double(rates.count) }
        if report.loadSeconds == nil { report.notMeasured.append("load time") }
        if report.medianTimeToFirstToken == nil { report.notMeasured.append("time to first token") }
        if report.meanTokensPerSecond == nil { report.notMeasured.append("tokens per second") }
        if report.memoryAfterLoadMB == nil || report.memoryAfterRunMB == nil { report.notMeasured.append("memory") }
        if report.maxContextTokens == nil { report.notMeasured.append("context size used") }
        return report
    }
}
