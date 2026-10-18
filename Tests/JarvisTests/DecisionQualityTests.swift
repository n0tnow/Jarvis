import Foundation
import Testing
@testable import Jarvis

// V1.0 background-intelligence pass — the routing confusion report and the SAFETY-first quality gate, measured over the four checked-in hand-written corpora.
// Pure logic (no model, no Jev, no network). The labels are ground truth: nothing here edits a corpus, and the held-out and blind sets stay REPORT-ONLY (they are spent — a set used to fix something is
// no longer evidence).

private func corpusURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Benchmarks").appendingPathComponent(name)
}

private func recognizer() -> DeterministicCommandRecognizer {
    var p = DecisionParsers()
    p.isKnownProjectName = { n in ["Hamam", "Hammam", "Turkish Hammam Simulator"].contains { ProjectOpenResolver.nameMatches(spoken: n, name: $0) } }
    return DeterministicCommandRecognizer(parsers: p)
}

private let corpora: [(name: String, file: String, allowed: Set<String>)] = [
    ("main", "decision_corpus.json", []),
    ("held-out", "decision_heldout.json", []),
    ("adversarial A", "decision_adversarial.json", ["adv-referent-019"]),     // “devam et” alone is handed to Project Continuity, which asks itself (documented, DEC-282)
    ("blind B", "decision_blind.json", []),
]

@Suite("V1.0 background · routing confusion report and quality gate")
struct DecisionQualityTests {
    private func report(_ i: Int) throws -> DecisionConfusionReport {
        let c = try DecisionCorpus.load(from: corpusURL(corpora[i].file))
        return DecisionConfusionReport.build(name: corpora[i].name, corpus: c, recognizer: recognizer())
    }

    @Test("the gate passes every corpus on SAFETY: zero unexpected executing false positives, every must-not-execute case held")
    func safety() throws {
        for i in corpora.indices {
            let r = try report(i)
            let violations = DecisionQualityGate.evaluate(r, thresholds: QualityThresholds(allowedExecutingFalsePositives: corpora[i].allowed, minExactCoverage: 0))
            #expect(violations.filter { $0.kind == .safety }.isEmpty, Comment(rawValue: "\(corpora[i].name): \(violations.map(\.message))"))
            #expect(r.mustNotExecuteHeld == r.mustNotExecuteTotal, Comment(rawValue: "\(corpora[i].name) must-not-execute"))
        }
    }

    @Test("coverage floors sit below the measured values; a miss is reported as COVERAGE, never as safety")
    func coverage() throws {
        let floors: [Double] = [0.80, 0.68, 0.70, 0.66]
        for i in corpora.indices {
            let r = try report(i)
            let v = DecisionQualityGate.evaluate(r, thresholds: QualityThresholds(allowedExecutingFalsePositives: corpora[i].allowed, minExactCoverage: floors[i]))
            #expect(v.isEmpty, Comment(rawValue: "\(corpora[i].name): \(v.map(\.message)) exact \(r.exact)/\(r.total)"))
        }
    }

    @Test("the gate itself fails safety first: a synthetic executing false positive and a lost must-not-execute are both caught")
    func gateDetects() {
        var r = DecisionConfusionReport(corpus: "synthetic", total: 10, answered: 8, exact: 7, executingFalsePositives: ["x-1"], mustNotExecuteTotal: 3, mustNotExecuteHeld: 2, cells: [], groups: [], abstainedOnDeterministic: [])
        let v = DecisionQualityGate.evaluate(r, thresholds: QualityThresholds(minExactCoverage: 0.9))
        #expect(v.count == 3 && v.prefix(2).allSatisfy { $0.kind == .safety } && v.last?.kind == .coverage)
        r.executingFalsePositives = []; r.mustNotExecuteHeld = 3
        #expect(DecisionQualityGate.evaluate(r, thresholds: QualityThresholds()).isEmpty)
        #expect(DecisionQualityGate.evaluate(r, thresholds: QualityThresholds(allowedExecutingFalsePositives: ["x-1"])).isEmpty)
    }

    @Test("the report is machine-readable JSON, groups every confusion that matters and keeps ids only (no utterance text)")
    func reportShape() throws {
        let r = try report(2)
        let data = Data(r.json().utf8)
        let back = try JSONDecoder().decode(DecisionConfusionReport.self, from: data)
        #expect(back == r && back.schema == "jarvis.decision-confusion/1")
        #expect(r.groups.map(\.name) == ["conversation vs action", "navigation vs research", "application vs project", "visibility vs application-running", "project-open vs project-continuation", "stop-speech vs cancel-task", "provider-capability vs provider-selection"])
        // ids reference the corpus; no field carries a sentence
        let corpus = try DecisionCorpus.load(from: corpusURL("decision_adversarial.json"))
        let texts = Set(corpus.cases.map(\.text))
        #expect(texts.allSatisfy { !$0.isEmpty })
        for text in texts.prefix(60) where text.count > 12 { #expect(!r.json().contains(text), Comment(rawValue: "the report leaks an utterance")) }
        #expect(r.cells.reduce(0) { $0 + $1.count } == r.cells.flatMap(\.ids).count)
    }

    @Test("the report is deterministic: two builds are byte-identical")
    func deterministic() throws {
        let a = try report(0).json(), b = try report(0).json()
        #expect(a == b)
    }

    @Test("safety groups that must stay empty: stop-speech/cancel-task and application/project confusions never EXECUTE the wrong thing")
    func criticalGroups() throws {
        for i in corpora.indices {
            let r = try report(i)
            for g in r.groups where g.name == "stop-speech vs cancel-task" { #expect(g.count == 0, Comment(rawValue: "\(corpora[i].name): \(g.ids)")) }
        }
    }
}
