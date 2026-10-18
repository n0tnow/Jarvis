import Foundation

// MARK: - Measuring the gate (V1.0 Jev gating pass)
//
// The gate (`JevGatePolicy`) is judged by what it ACCEPTS, never by what the classifier says. This file runs a corpus through the same order the engine uses —
//   grammar (zero Jev) → ambiguity / policy handling → preflight → classifier answer → local gate —
// and counts: how many requests never needed Jev, how many calls each routing strategy makes, which answers the gate accepted, which of those were right, and above all how many EXECUTING decisions a
// wrong or hostile answer could have produced (the most important number; its target is 0 and it is a property of the gate, not of the classifier).
//
// Cloud has no Jev. The answers here come from three honest sources, always labelled:
//   · SIMULATED classifiers (an oracle, a classifier that is wrong on purpose, one that is always maximally confident about an executing intent) — they test the GATE, they say nothing about Jev;
//   · RECORDED rows from a real shadow run on the user's Mac (`Jarvis --decision-benchmark --jev --rows F`), evaluated offline by `Jarvis --jev-gate-evaluate` — the only source of real accuracy numbers;
//   · nothing else. A number that was not measured is not printed.
// Pure: no network, no clock, no file, no state.

/// One classifier answer for one case (recorded or simulated). `classification == nil` = no answer (`failure` says why).
struct JevAnswer: Sendable, Equatable {
    var classification: JevClassification?
    var failure: String?
    var latency: TimeInterval?
}

struct JevAnswerSource: Sendable {
    var name: String
    /// true = produced by code in this repository, not by the remote model. Every report says so.
    var simulated: Bool
    var answer: @Sendable (DecisionCorpusCase) -> JevAnswer

    // MARK: simulated classifiers (they exercise the gate)

    private static func classification(_ intent: DecisionIntent, _ confidence: Double, page: String? = nil) -> JevClassification { JevClassification(intent: intent.rawValue, confidence: confidence, page: page) }

    /// Knows the labelled truth and says it with high confidence — the upper bound of what the gate could ever accept.
    static let oracle = JevAnswerSource(name: "simulated oracle (labelled truth, confidence 0.99)", simulated: true) { k in
        JevAnswer(classification: classification(k.intent, 0.99, page: k.intent == .jarvisNavigation ? k.target : nil), failure: nil, latency: nil)
    }
    /// Says the same intent about EVERYTHING with maximal confidence — what a compromised or confused classifier would look like.
    static func alwaysSays(_ intent: DecisionIntent, page: String? = nil) -> JevAnswerSource {
        JevAnswerSource(name: "simulated adversary: always \(intent.rawValue) @0.99", simulated: true) { _ in JevAnswer(classification: classification(intent, 0.99, page: page), failure: nil, latency: nil) }
    }
    /// Is wrong on EVERY case (rotating through the intents that are not the truth) and maximally confident about it.
    static let alwaysWrong = JevAnswerSource(name: "simulated adversary: wrong on every case @0.99", simulated: true) { k in
        let order: [DecisionIntent] = [.macosApplicationAction, .computerUse, .projectTask, .settingsChange, .research, .projectOpen, .cancelTask, .stopSpeech, .systemStatus, .voiceStatus, .jarvisNavigation, .providerCapability, .projectQuery]
        let n = abs(k.id.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) })
        var wrong = order[n % order.count]
        if wrong == k.intent { wrong = order[(n + 1) % order.count] }
        return JevAnswer(classification: classification(wrong, 0.99, page: wrong == .jarvisNavigation ? "settings" : nil), failure: nil, latency: nil)
    }
    /// The truth except every `n`-th case, which gets a confidently wrong intent.
    static func noisy(everyNth n: Int) -> JevAnswerSource {
        JevAnswerSource(name: "simulated noisy classifier (every \(n)th answer wrong @0.99)", simulated: true) { k in
            let idx = abs(k.id.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) })
            if idx % n == 0 { return alwaysWrong.answer(k) }
            return oracle.answer(k)
        }
    }
    /// The service did not answer (timeout, HTTP error, …).
    static func failing(_ why: String) -> JevAnswerSource { JevAnswerSource(name: "simulated outage (\(why))", simulated: true) { _ in JevAnswer(classification: nil, failure: why, latency: nil) } }

    // MARK: recorded rows (real)

    /// A row of `Jarvis --decision-benchmark --jev --rows F`. Extra keys are ignored.
    struct RecordedRow: Codable, Sendable, Equatable {
        var id: String
        var jev: String?
        var jevConfidence: Double?
        var jevPage: String?
        var jevFailure: String?
        var jevLatency: Double?
    }
    /// Cases without a row get "no answer" (the run did not ask — e.g. a secret-shaped sentence was never sent).
    static func recorded(_ rows: [RecordedRow], name: String) -> JevAnswerSource {
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return JevAnswerSource(name: name, simulated: false) { k in
            guard let r = byID[k.id] else { return JevAnswer(classification: nil, failure: "noRecordedRow", latency: nil) }
            if let intent = r.jev, let c = r.jevConfidence { return JevAnswer(classification: JevClassification(intent: intent, confidence: c, page: r.jevPage), failure: nil, latency: r.jevLatency) }
            return JevAnswer(classification: nil, failure: r.jevFailure ?? "noAnswer", latency: r.jevLatency)
        }
    }
}

// MARK: Calibration

struct JevCalibrationBin: Equatable, Sendable {
    var label: String
    var lower: Double
    var upper: Double
    var count = 0
    var correct = 0
    /// Answers whose candidate decision would EXECUTE something, and how many of those were right / wrong.
    var executingCount = 0
    var executingCorrect = 0
    var falseExecutions: Int { executingCount - executingCorrect }
    var accuracy: Double? { count == 0 ? nil : Double(correct) / Double(count) }
    var executingAccuracy: Double? { executingCount == 0 ? nil : Double(executingCorrect) / Double(executingCount) }
}

enum JevCalibration {
    /// The bins the milestone asks for (0.50–0.69, 0.70–0.79, 0.80–0.89, 0.90–0.94, 0.95–0.96, 0.97–1.00) plus everything below 0.50.
    static let edges: [Double] = [0, 0.5, 0.7, 0.8, 0.9, 0.95, 0.97, 1.0001]
    static let labels = ["<0.50", "0.50–0.69", "0.70–0.79", "0.80–0.89", "0.90–0.94", "0.95–0.96", "0.97–1.00"]

    struct Record: Sendable, Equatable {
        var confidence: Double
        var correct: Bool
        var executing: Bool
    }

    static func bins(_ records: [Record]) -> [JevCalibrationBin] {
        var out = (0..<(edges.count - 1)).map { JevCalibrationBin(label: labels[$0], lower: edges[$0], upper: edges[$0 + 1]) }
        for r in records where r.confidence.isFinite {
            guard let i = (0..<out.count).first(where: { r.confidence >= out[$0].lower && r.confidence < out[$0].upper }) else { continue }
            out[i].count += 1
            if r.correct { out[i].correct += 1 }
            if r.executing { out[i].executingCount += 1; if r.correct { out[i].executingCorrect += 1 } }
        }
        return out
    }
}

// MARK: Evaluation

/// What the deterministic side did with a case, before Jev could be asked.
enum JevGrammarOutcome: String, Sendable, Codable {
    case decided, ambiguity, policyBlock, abstained
}

struct JevGateTally: Equatable, Sendable {
    var accepted = 0
    var acceptedCorrect = 0
    /// Accepted although the labelled intent differs.
    var acceptedWrong = 0
    /// Accepted although the user's labelled truth is an ACTION (or "do nothing"): a read-only answer swallowed an actionable sentence.
    var acceptedButTruthWasAction = 0
    /// Accepted decisions of the execution-capable class (an application, a project, a setting, research, stop / cancel, the computer) although the truth is a different intent / action, or the truth is "do not
    /// execute at all". THE metric; production target 0 — and structurally 0, because the gate refuses the whole class.
    var executingFalseAccepts = 0
    var executingAccepts = 0
    /// Page changes (JARVIS' own screen: visible, reversible, no side effect) accepted at level `ownUI`, and how many were the wrong page / not wanted. Counted apart from the executing class on purpose.
    var ownUIAccepts = 0
    var ownUIFalseAccepts = 0
    var acceptedExamples: [String] = []
    var falseExecutionExamples: [String] = []
}

struct JevGateEvaluation: Sendable {
    var corpus: String
    var source: String
    var simulated: Bool
    var level: JevGateLevel
    var total = 0
    var grammar: [JevGrammarOutcome: Int] = [:]
    /// Grammar answered exactly as labelled / answered with a different intent (the grammar's own quality, for comparison).
    var grammarExact = 0
    var grammarWrongIntent = 0
    var grammarExecutingFalsePositives = 0
    /// Routing strategies: how many classifier calls each would make (A every request · B grammar abstains or asks · C after the full preflight).
    var callsA = 0
    var callsB = 0
    var callsC = 0
    var preflight: [JevRejection: Int] = [:]
    var noAnswer: [String: Int] = [:]
    var answers = 0
    var answerCorrect = 0
    var rejections: [JevRejection: Int] = [:]
    var production = JevGateTally()
    var simulation = JevGateTally()
    var calibration: [JevCalibrationBin] = []
    var latencies: [TimeInterval] = []
    /// Combined routing (grammar else gated Jev): decided at all / decided correctly, versus the grammar alone.
    var routedByGrammar = 0
    var routedByJev = 0
    var routedByJevCorrect = 0
    /// Cases where the grammar abstained and Jev's accepted answer was right: the only calls that bought anything.
    var usefulJevRoutes: Int { routedByJevCorrect }

    var jevShare: Double { total == 0 ? 0 : Double(callsC) / Double(total) }

    func markdown() -> String {
        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "n/a" : String(format: "%.1f%%", Double(a) / Double(b) * 100) }
        var s = "### \(corpus) — \(source)\(simulated ? "  [SIMULATED classifier: this exercises the GATE, it says nothing about Jev]" : "  [RECORDED from a real run]")\n\n"
        s += "cases \(total) · gate level \(level.rawValue)\n"
        s += "grammar: decided \(grammar[.decided] ?? 0) · ambiguity \(grammar[.ambiguity] ?? 0) · policy block \(grammar[.policyBlock] ?? 0) · abstained \(grammar[.abstained] ?? 0) (exact \(grammarExact), wrong intent \(grammarWrongIntent), executing false positives \(grammarExecutingFalsePositives))\n"
        s += "calls — A every request: \(callsA) · B grammar abstains or asks: \(callsB) · C after preflight: \(callsC)  (C is \(pct(callsC, callsA)) of A)\n"
        if !preflight.isEmpty { s += "preflight skipped: " + preflight.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)×\($0.value)" }.joined(separator: ", ") + "\n" }
        s += "classifier answers \(answers) (correct intent \(answerCorrect) = \(pct(answerCorrect, answers)))"
        if !noAnswer.isEmpty { s += " · no answer: " + noAnswer.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ", ") }
        s += "\n"
        s += "PRODUCTION gate (\(level.rawValue)): accepted \(production.accepted) · correct \(production.acceptedCorrect) · wrong \(production.acceptedWrong) · swallowed an action \(production.acceptedButTruthWasAction) · own-UI page changes \(production.ownUIAccepts) (wrong \(production.ownUIFalseAccepts)) · EXECUTING accepts \(production.executingAccepts) · EXECUTING FALSE ACCEPTS \(production.executingFalseAccepts)\n"
        s += "SIMULATED execution level: accepted \(simulation.accepted) · correct \(simulation.acceptedCorrect) · wrong \(simulation.acceptedWrong) · executing accepts \(simulation.executingAccepts), false \(simulation.executingFalseAccepts) (never active in production)\n"
        s += "routing: grammar \(routedByGrammar) · gated Jev \(routedByJev) (right \(routedByJevCorrect))\n"
        if !rejections.isEmpty { s += "rejections: " + rejections.sorted { $0.value > $1.value }.map { "\($0.key.rawValue)×\($0.value)" }.joined(separator: ", ") + "\n" }
        if !latencies.isEmpty { let sorted = latencies.sorted(); s += String(format: "latency (recorded): mean %.0f ms · p95 %.0f ms (n=%d)\n", sorted.reduce(0, +) / Double(sorted.count) * 1000, sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] * 1000, sorted.count) }
        if answers > 0 {
            s += "calibration (candidate confidence → accuracy; executing = the candidate would execute):\n"
            for b in calibration { s += "  \(b.label): n=\(b.count) accuracy=\(b.accuracy.map { String(format: "%.0f%%", $0 * 100) } ?? "—") · executing n=\(b.executingCount) accuracy=\(b.executingAccuracy.map { String(format: "%.0f%%", $0 * 100) } ?? "—") false executions=\(b.falseExecutions)\n" }
        }
        if !production.falseExecutionExamples.isEmpty { s += "FALSE EXECUTIONS: \(production.falseExecutionExamples.prefix(8).joined(separator: "; "))\n" }
        return s
    }
}

enum JevGateEvaluator {
    /// Resolves a candidate's target from the UTTERANCE with JARVIS' own resolvers — Jev never supplies an executable identifier. The default resolves nothing, which is also what the engine does until a registry is wired.
    typealias TargetResolver = @Sendable (DecisionIntent, String) -> JevTargetResolution

    static let resolveNothing: TargetResolver = { _, _ in .unresolved }

    /// One pass over a corpus. `recognizer` is the production grammar (with whatever project registry the caller supplies).
    static func evaluate(corpus: DecisionCorpus, corpusName: String, source: JevAnswerSource, level: JevGateLevel = .readOnly, recognizer: DeterministicCommandRecognizer = DeterministicCommandRecognizer(),
                         targetResolver: TargetResolver = JevGateEvaluator.resolveNothing, configuredFloor: Double = 0, capabilityAvailable: Bool = true, requireAnchor: Bool = true) -> JevGateEvaluation {
        var e = JevGateEvaluation(corpus: corpusName, source: source.name, simulated: source.simulated, level: level)
        e.total = corpus.cases.count
        e.callsA = e.total
        var records: [JevCalibration.Record] = []
        for k in corpus.cases {
            // 1 · the grammar
            let det = recognizer.recognize(k.text, context: k.decisionContext)
            let production = det ?? Decision(intent: .unknown, confidence: 0, normalized: "")
            let outcome: JevGrammarOutcome
            if det == nil { outcome = .abstained }
            else if production.gate != .none { outcome = .policyBlock }
            else if production.ambiguity != .none { outcome = .ambiguity }
            else if production.intent == .unknown { outcome = .abstained }
            else { outcome = .decided }
            e.grammar[outcome, default: 0] += 1
            if let d = det {
                let sameAction = d.intent == k.intent && DecisionBenchmarkRunner.canonicalAction(d.action) == DecisionBenchmarkRunner.canonicalAction(k.action)
                if DecisionBenchmarkRunner.exactMatch(d, k) { e.grammarExact += 1 }
                if d.intent != k.intent && d.intent != .unknown { e.grammarWrongIntent += 1 }
                if d.requiresExecution, d.gate != .blocked, !sameAction || k.mustNotExecute { e.grammarExecutingFalsePositives += 1 }
            }
            if outcome == .decided { e.routedByGrammar += 1 }
            // 2 · call accounting
            if outcome == .abstained || outcome == .ambiguity { e.callsB += 1 }
            if let skip = JevPreflight.skipReason(raw: k.text, production: production, gated: true) {
                e.preflight[skip, default: 0] += 1
                continue
            }
            e.callsC += 1
            // 3 · the classifier's answer
            let ans = source.answer(k)
            if let l = ans.latency { e.latencies.append(l) }
            guard let c = ans.classification else { e.noAnswer[ans.failure ?? "noAnswer", default: 0] += 1; e.rejections[.unavailable, default: 0] += 1; continue }
            guard let candidate = JevClassificationMapper.decision(from: c) else { e.noAnswer["unknownIntentOrNonFinite", default: 0] += 1; e.rejections[c.confidence.isFinite ? .intentNotRoutable : .malformedConfidence, default: 0] += 1; continue }
            e.answers += 1
            let correct = candidate.intent == k.intent
            if correct { e.answerCorrect += 1 }
            records.append(.init(confidence: candidate.confidence, correct: correct, executing: candidate.requiresExecution))
            // 4 · the gate (production level, then the simulation of the execution level)
            let input = JevGateInput(raw: k.text, production: production, candidate: candidate, level: level, configuredFloor: configuredFloor, targetResolution: targetResolver(candidate.intent, k.text),
                                     capabilityAvailable: capabilityAvailable, requireAnchor: requireAnchor, reportedModel: c.model, calibratedModel: "")
            func tally(_ t: inout JevGateTally, _ d: Decision) {
                t.accepted += 1
                let sameAction = d.intent == k.intent && (d.action == nil || k.action == nil || DecisionBenchmarkRunner.canonicalAction(d.action) == DecisionBenchmarkRunner.canonicalAction(k.action))
                if d.intent == k.intent { t.acceptedCorrect += 1 } else { t.acceptedWrong += 1 }
                if (k.requiresExecution || k.mustNotExecute) && d.intent != k.intent { t.acceptedButTruthWasAction += 1 }
                let wrongOrUnwanted = !sameAction || k.mustNotExecute
                switch JevIntentSafety.classify(d.intent) {
                case .executionCapable, .critical:
                    t.executingAccepts += 1
                    if wrongOrUnwanted { t.executingFalseAccepts += 1; t.falseExecutionExamples.append("\(k.id) → \(d.intent.rawValue)") }
                case .ownUI:
                    t.ownUIAccepts += 1
                    if wrongOrUnwanted { t.ownUIFalseAccepts += 1 }
                case .readOnly, .notRoutable: break
                }
                if t.acceptedExamples.count < 6 { t.acceptedExamples.append("\(k.id) → \(d.intent.rawValue)") }
            }
            switch JevGatePolicy.evaluate(input) {
            case .accept(let d):
                tally(&e.production, d)
                e.routedByJev += 1; if d.intent == k.intent { e.routedByJevCorrect += 1 }
            case .reject(let r): e.rejections[r, default: 0] += 1
            }
            if case .accept(let d) = JevGatePolicy.simulate(input) { tally(&e.simulation, d) }
        }
        e.calibration = JevCalibration.bins(records)
        return e
    }
}

// MARK: Latency (from measured data only)

enum JevLatencyModel {
    /// Expected EXTRA latency per request under a routing strategy, given a MEASURED per-call latency. nil input → nil output: nothing is invented.
    /// Strategy A pays it on every request, C only on the share that reaches Jev; a timeout is paid in full (the call is abandoned and the existing route runs).
    static func expectedAddedLatency(callShare: Double, measuredCallLatency: TimeInterval?) -> TimeInterval? {
        guard let m = measuredCallLatency, m >= 0, callShare >= 0, callShare <= 1 else { return nil }
        return callShare * m
    }
    /// The longest a single request can be delayed by the classifier: the configured timeout (gated requests use the shorter gated timeout).
    static func worstCaseAdded(config: JevConfig) -> TimeInterval { min(config.timeoutSeconds, config.gatedTimeoutSeconds) }
}
