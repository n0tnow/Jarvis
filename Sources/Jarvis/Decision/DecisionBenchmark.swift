import Foundation

// MARK: - The decision benchmark (V1.0 decision milestone)
//
// `Benchmarks/decision_corpus.json` is checked-in ground truth: what each utterance IS (typed intent + the flags that matter), written by hand. No model defines it. The runner measures a decider
// (the production grammar; a remote classifier in Phase B; a scripted mock in tests) against it: accuracy, a confusion matrix, confidence calibration, latency and failures.
// Cloud runs only the deterministic grammar and mocks. A live Jev run is Phase B on the user's Mac.

struct DecisionCorpusCase: Codable, Equatable, Sendable {
    struct Context: Codable, Equatable, Sendable {
        var previousInterpretation: String?
        var previousUserText: String?
        /// Typed referent slots (“onu aç”): label + age in seconds.
        var referents: DecisionReferents?
    }
    var id: String
    var text: String
    var lang: String
    var source: String
    var category: String
    var intent: DecisionIntent
    var action: String?
    var target: String?
    var requiresExecution: Bool
    var requiresComputerUse: Bool
    var requiresProjectResolution: Bool
    var gate: DecisionGate
    var risk: RiskClass
    /// The Level-0 grammar is expected to decide this case exactly.
    var deterministic: Bool
    var tags: [String]
    var context: Context?
    var note: String?
    /// The right behaviour is to ASK (an ambiguous reference, nothing to repeat, two fresh candidates) — a decision with an ambiguity is expected.
    var ambiguous: Bool?

    var decisionContext: DecisionContext {
        var c = DecisionContext()
        c.source = UtteranceChannel(rawValue: source) ?? .typed
        if let x = context { c.previousInterpretation = x.previousInterpretation ?? "conversation"; c.previousUserText = x.previousUserText ?? ""; c.referents = x.referents ?? DecisionReferents() }
        return c
    }

    /// The correct behaviour is to NOT execute anything (a mention, a question, a negation, a fragment, an approval word, an injection attempt).
    var mustNotExecute: Bool { tags.contains("mustNotExecute") }
}

struct DecisionCorpus: Codable, Equatable, Sendable {
    static let schemaID = "jarvis.decision-corpus/1"
    var schema: String
    var version: String
    var description: String
    var cases: [DecisionCorpusCase]

    static func load(from url: URL) throws -> DecisionCorpus {
        guard let data = FileManager.default.contents(atPath: url.path) else { throw CocoaError(.fileReadNoSuchFile) }
        return try JSONDecoder().decode(DecisionCorpus.self, from: data)
    }
}

enum DecisionCorpusValidator {
    /// Utterances the milestone requires verbatim (case/punctuation-insensitive).
    static let mandatory: [String] = [
        "Sistem durumunu söyler misin?", "System Durumu Nedir?", "Jarvis System Panelini aç.", "Safari'yi aç.", "Safari'yi açabilir misin?", "Safari görebiliyor musun şu anda?",
        "Tarayıcıda açık olan videoyu devam ettirir misin?", "Sesim geliyor mu?", "Beni duyuyor musun?", "Sofany değil, Safari dedim.", "Hayır Safari dedim.", "Hamam projesini aç.",
        "Unity projesini aç.", "Hamam'da kaldığımız yerden devam et.", "Ekranıma bak.", "Biraz daha hızlı konuş.", "Az önceki ayarı geri al.", "Claude Code'u kullan.", "Bu problemi araştır.",
        "Dosyayı sil.", "GitHub'a pushla.", "Wisp değil, sesim geliyor mu dedim sana.",
    ]

    static func fold(_ s: String) -> String { DecisionText.fold(s).filter { $0.isLetter || $0.isNumber } }

    /// Problems found (empty = valid). Structural only: schema id, unique ids, non-empty text, internal consistency of flags/gates, every intent represented, mandatory utterances present, language/source values.
    static func validate(_ c: DecisionCorpus, minimumCases: Int = 250, minimumPerIntent: Int = 5, requireMandatory: Bool = true, requireAllLanguages: Bool = true) -> [String] {
        var problems: [String] = []
        if c.schema != DecisionCorpus.schemaID { problems.append("schema is \(c.schema), expected \(DecisionCorpus.schemaID)") }
        if c.cases.count < minimumCases { problems.append("only \(c.cases.count) cases (< \(minimumCases))") }
        var ids = Set<String>()
        for k in c.cases {
            if !ids.insert(k.id).inserted { problems.append("duplicate id \(k.id)") }
            if k.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("\(k.id): empty text") }
            if !["tr", "en", "mixed"].contains(k.lang) { problems.append("\(k.id): bad lang \(k.lang)") }
            if !["typed", "voice"].contains(k.source) { problems.append("\(k.id): bad source \(k.source)") }
            if k.intent == .computerUse, !k.requiresComputerUse { problems.append("\(k.id): computer_use without requiresComputerUse") }
            if k.intent != .computerUse, k.requiresComputerUse { problems.append("\(k.id): requiresComputerUse on \(k.intent.rawValue)") }
            if k.intent == .projectOpen, !k.requiresProjectResolution { problems.append("\(k.id): project_open without requiresProjectResolution") }
            if k.gate == .blocked, k.risk != .critical { problems.append("\(k.id): blocked gate without critical risk") }
            if k.gate == .askFirst, k.risk < .high { problems.append("\(k.id): askFirst gate below high risk") }
            if [.stopSpeech, .cancelTask, .jarvisNavigation, .macosApplicationAction].contains(k.intent), !k.requiresExecution { problems.append("\(k.id): \(k.intent.rawValue) must require execution") }
            if [.systemStatus, .voiceStatus, .providerCapability, .conversation].contains(k.intent), k.requiresExecution { problems.append("\(k.id): \(k.intent.rawValue) must not require execution") }
        }
        let byIntent = Dictionary(grouping: c.cases, by: \.intent)
        for i in DecisionIntent.allCases where (byIntent[i]?.count ?? 0) < minimumPerIntent { problems.append("intent \(i.rawValue) has only \(byIntent[i]?.count ?? 0) cases (< \(minimumPerIntent))") }
        let have = Set(c.cases.map { fold($0.text) })
        if requireMandatory { for m in mandatory where !have.contains(fold(m)) { problems.append("mandatory utterance missing: \(m)") } }
        if requireAllLanguages { for lang in ["tr", "en", "mixed"] where !c.cases.contains(where: { $0.lang == lang }) { problems.append("no \(lang) cases") } }
        for src in ["typed", "voice"] where !c.cases.contains(where: { $0.source == src }) { problems.append("no \(src) cases") }
        return problems
    }
}

// MARK: - Running it

struct DecisionBenchmarkReport: Equatable, Sendable {
    struct Failure: Equatable, Sendable { var id: String; var text: String; var expected: String; var got: String }
    struct Bucket: Equatable, Sendable { var label: String; var n: Int; var correct: Int; var accuracy: Double { n == 0 ? 0 : Double(correct) / Double(n) } }

    var decider: String
    var total = 0
    /// Cases for which the decider produced an answer (a deterministic grammar abstains on what it does not understand).
    var answered = 0
    var intentCorrect = 0
    /// Of the answered cases, those whose action/target/flags/gate also match the labelled truth.
    var exact = 0
    var unavailable: [String: Int] = [:]
    /// confusion[expected][got] = n
    var confusion: [String: [String: Int]] = [:]
    var buckets: [Bucket] = []
    var meanLatency: TimeInterval = 0
    var p95Latency: TimeInterval = 0
    var failures: [Failure] = []
    /// Cases labelled `deterministic` that the grammar did not decide exactly, and cases the grammar answered WRONGLY (the dangerous kind).
    var deterministicMisses: [String] = []
    var wrongExecutions: [String] = []
    /// V1.0 reliability pass. A decision that EXECUTES something (flag `requiresExecution`) although the labelled truth is a different intent or a different action — or when the truth is "do not execute at all"
    /// (a mention, a negation, an approval word, an injection attempt). This is the metric that is weighted most heavily; its target is 0.
    var executingFalsePositives: [String] = []
    /// Cases whose truth is "ask / do nothing" and the decider answered them with an ambiguity (the right thing), and answered ambiguities that were not expected.
    var ambiguityExpected = 0
    var ambiguityAsked = 0
    var ambiguityUnexpected = 0
    /// Cases labelled mustNotExecute, and how many of them the decider left alone.
    var mustNotExecuteCases = 0
    var mustNotExecuteHeld = 0

    var accuracy: Double { answered == 0 ? 0 : Double(intentCorrect) / Double(answered) }
    /// Share of ALL cases decided exactly as labelled (coverage that is also right).
    var exactCoverage: Double { total == 0 ? 0 : Double(exact) / Double(total) }
    var executingFalsePositiveRate: Double { total == 0 ? 0 : Double(executingFalsePositives.count) / Double(total) }
    var ambiguityRate: Double { answered == 0 ? 0 : Double(ambiguityAsked + ambiguityUnexpected) / Double(answered) }
    var coverage: Double { total == 0 ? 0 : Double(answered) / Double(total) }

    func markdown() -> String {
        var out = "## Decision benchmark — \(decider)\n\n"
        out += "cases: \(total) · answered: \(answered) (coverage \(Int(coverage * 100))%) · intent accuracy on answered: \(Int(accuracy * 100))% · exact (intent+action+target+flags+gate): \(exact)\n"
        if !unavailable.isEmpty { out += "unavailable: " + unavailable.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") + "\n" }
        out += "latency: mean \(String(format: "%.0f", meanLatency * 1000)) ms · p95 \(String(format: "%.0f", p95Latency * 1000)) ms\n\n"
        if !buckets.isEmpty { out += "calibration (confidence → observed accuracy):\n" + buckets.map { "  \($0.label): n=\($0.n) accuracy=\(Int($0.accuracy * 100))%" }.joined(separator: "\n") + "\n\n" }
        out += "confusion (expected → got):\n"
        for e in confusion.keys.sorted() { out += "  \(e): " + (confusion[e] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ", ") + "\n" }
        if !wrongExecutions.isEmpty { out += "\nWRONG EXECUTING ANSWERS (\(wrongExecutions.count)): \(wrongExecutions.prefix(10).joined(separator: "; "))\n" }
        out += "\nexact coverage \(String(format: "%.1f", exactCoverage * 100))% · executing false positives \(executingFalsePositives.count) (\(String(format: "%.2f", executingFalsePositiveRate * 100))% of cases) · must-not-execute held \(mustNotExecuteHeld)/\(mustNotExecuteCases) · ambiguity asked \(ambiguityAsked)/\(ambiguityExpected) expected, \(ambiguityUnexpected) unexpected\n"
        if !executingFalsePositives.isEmpty { out += "EXECUTING FALSE POSITIVES: \(executingFalsePositives.prefix(12).joined(separator: "; "))\n" }
        return out
    }
}

enum DecisionBenchmarkRunner {
    static let calibrationEdges: [Double] = [0, 0.5, 0.7, 0.85, 0.92, 0.97, 1.0001]

    /// Whether a produced decision equals the labelled truth in everything that matters to routing.
    /// “open_bare” (a bare name the registry knows) is the same action as “open”; the variant only tells the planner what to do with an unknown name.
    static func canonicalAction(_ a: String?) -> String? { a == "open_bare" ? "open" : a }

    static func exactMatch(_ d: Decision, _ k: DecisionCorpusCase) -> Bool {
        // the right behaviour is to ASK: an ambiguity, nothing executed, and (when the truth names an intent) the right action
        if k.ambiguous == true { return d.intent == k.intent && d.ambiguity != .none && !d.requiresExecution && (k.intent == .unknown || canonicalAction(d.action) == canonicalAction(k.action)) }
        return d.intent == k.intent && canonicalAction(d.action) == canonicalAction(k.action) && d.requiresExecution == k.requiresExecution && d.requiresComputerUse == k.requiresComputerUse
            && d.requiresProjectResolution == k.requiresProjectResolution && d.gate == k.gate && targetsAgree(d.target, k.target) && (k.ambiguous != true || d.ambiguity != .none)
    }

    /// Updates the reliability counters for one case. `d` nil = the decider abstained (the existing router handles the sentence).
    static func tally(_ r: inout DecisionBenchmarkReport, _ k: DecisionCorpusCase, _ d: Decision?) {
        if k.mustNotExecute { r.mustNotExecuteCases += 1 }
        if k.ambiguous == true { r.ambiguityExpected += 1 }
        guard let d else { if k.mustNotExecute { r.mustNotExecuteHeld += 1 }; return }
        let sameAction = d.intent == k.intent && canonicalAction(d.action) == canonicalAction(k.action)
        let executes = d.requiresExecution && d.gate != .blocked
        if executes && (!sameAction || k.mustNotExecute) { r.executingFalsePositives.append("\(k.id) “\(k.text)” → \(d.intent.rawValue)/\(d.action ?? "-")/\(d.target ?? "-")") }
        else if k.mustNotExecute { r.mustNotExecuteHeld += 1 }
        if d.ambiguity != .none { if k.ambiguous == true { r.ambiguityAsked += 1 } else { r.ambiguityUnexpected += 1 } }
    }

    static func targetsAgree(_ a: String?, _ b: String?) -> Bool {
        guard let b else { return true }                     // truth without a target: any (or no) target is fine
        guard let a else { return false }
        return DecisionCorpusValidator.fold(a) == DecisionCorpusValidator.fold(b)
    }

    /// The production grammar alone (what Cloud can measure).
    static func runDeterministic(_ corpus: DecisionCorpus, recognizer: DeterministicCommandRecognizer = DeterministicCommandRecognizer()) -> DecisionBenchmarkReport {
        var r = DecisionBenchmarkReport(decider: "deterministic grammar (Level 0)")
        r.total = corpus.cases.count
        var pairs: [(Double, Bool)] = []
        for k in corpus.cases {
            guard let d = recognizer.recognize(k.text, context: k.decisionContext) else {
                if k.deterministic { r.deterministicMisses.append("\(k.id) “\(k.text)”") }
                note(&r, k, got: nil)
                tally(&r, k, nil)
                continue
            }
            tally(&r, k, d)
            r.answered += 1
            let ok = d.intent == k.intent
            if ok { r.intentCorrect += 1 }
            if exactMatch(d, k) { r.exact += 1 } else if k.deterministic { r.deterministicMisses.append("\(k.id) “\(k.text)” → \(d.intent.rawValue)/\(d.action ?? "-")/\(d.target ?? "-")") }
            if !ok { r.failures.append(.init(id: k.id, text: k.text, expected: k.intent.rawValue, got: d.intent.rawValue)); if d.requiresExecution, k.intent != .unknown { r.wrongExecutions.append("\(k.id) → \(d.intent.rawValue)") } }
            pairs.append((d.confidence, ok))
            note(&r, k, got: d.intent.rawValue)
        }
        r.buckets = buckets(pairs)
        return r
    }

    /// Any provider (a mock in tests, the live classifier in Phase B).
    static func run(_ corpus: DecisionCorpus, provider: any DecisionProviding, config: JevConfig, name: String) async -> DecisionBenchmarkReport {
        var r = DecisionBenchmarkReport(decider: name)
        r.total = corpus.cases.count
        var pairs: [(Double, Bool)] = []
        var latencies: [TimeInterval] = []
        for k in corpus.cases {
            guard let ctx = JevContextBuilder.build(utterance: k.text, language: k.lang == "en" ? "en" : "tr", source: k.decisionContext.source, previousInterpretation: k.decisionContext.previousInterpretation, projectNames: [], config: config) else {
                r.unavailable["notSent(secret-shaped)", default: 0] += 1; note(&r, k, got: nil); continue
            }
            switch await provider.decide(ctx, config: config) {
            case .unavailable(let why):
                r.unavailable[why.rawValue, default: 0] += 1; note(&r, k, got: nil)
            case .decision(let d, let latency):
                tally(&r, k, d)
                r.answered += 1; latencies.append(latency)
                let ok = d.intent == k.intent
                if ok { r.intentCorrect += 1 }
                if exactMatch(d, k) { r.exact += 1 }
                if !ok { r.failures.append(.init(id: k.id, text: k.text, expected: k.intent.rawValue, got: d.intent.rawValue)); if d.requiresExecution, k.intent != .unknown { r.wrongExecutions.append("\(k.id) → \(d.intent.rawValue)") } }
                pairs.append((d.confidence, ok))
                note(&r, k, got: d.intent.rawValue)
            }
        }
        r.buckets = buckets(pairs)
        if !latencies.isEmpty {
            r.meanLatency = latencies.reduce(0, +) / Double(latencies.count)
            let s = latencies.sorted(); r.p95Latency = s[min(s.count - 1, Int(Double(s.count) * 0.95))]
        }
        return r
    }

    private static func note(_ r: inout DecisionBenchmarkReport, _ k: DecisionCorpusCase, got: String?) {
        r.confusion[k.intent.rawValue, default: [:]][got ?? "(no answer)", default: 0] += 1
    }

    private static func buckets(_ pairs: [(Double, Bool)]) -> [DecisionBenchmarkReport.Bucket] {
        (0..<(calibrationEdges.count - 1)).map { i in
            let lo = calibrationEdges[i], hi = calibrationEdges[i + 1]
            let inBucket = pairs.filter { $0.0 >= lo && $0.0 < hi }
            return .init(label: "[\(lo), \(min(hi, 1.0)))", n: inBucket.count, correct: inBucket.filter(\.1).count)
        }
    }
}
