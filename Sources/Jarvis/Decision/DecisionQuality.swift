import Foundation

// MARK: - A machine-readable routing confusion report and a SAFETY-first quality gate (V1.0 background pass)
//
// Coverage is not the goal: ABSTAINING is better than a WRONG EXECUTION. The report shows, per corpus, which labelled behaviours were confused with which (label = intent/action; "abstain" = the grammar left it to
// the router), grouped into the confusions that matter for JARVIS — conversation vs action, navigation vs research, application vs project, visibility vs running, project open vs continue, stop speech vs cancel task,
// provider capability vs provider selection — so the next grammar improvement is chosen by evidence, not by the last sentence someone tried. It stores corpus ids (ground truth is public in the repository), never
// utterance text from users. The gate fails on SAFETY first (an executing wrong answer, a must-not-execute case executed, a blocked/gated decision lost) and only then on coverage floors.

struct ConfusionCell: Codable, Equatable, Sendable {
    var expected: String
    var got: String
    var count: Int
    var ids: [String]
}

struct ConfusionGroup: Codable, Equatable, Sendable {
    var name: String
    var count: Int
    var ids: [String]
}

struct DecisionConfusionReport: Codable, Equatable, Sendable {
    var schema = "jarvis.decision-confusion/1"
    var corpus: String
    var total: Int
    var answered: Int
    var exact: Int
    var executingFalsePositives: [String]
    var mustNotExecuteTotal: Int
    var mustNotExecuteHeld: Int
    var cells: [ConfusionCell]
    var groups: [ConfusionGroup]
    var abstainedOnDeterministic: [String]

    static let groupDefinitions: [(name: String, pairs: Set<[String]>)] = [
        ("conversation vs action", [["conversation", "macos_application_action"], ["conversation", "jarvis_navigation"], ["conversation", "computer_use"], ["conversation", "project_task"], ["conversation", "settings_change"], ["conversation", "research"],
                                    ["macos_application_action", "conversation"], ["jarvis_navigation", "conversation"], ["computer_use", "conversation"], ["unknown", "macos_application_action"], ["unknown", "jarvis_navigation"], ["unknown", "computer_use"], ["unknown", "project_task"]]),
        ("navigation vs research", [["jarvis_navigation", "research"], ["research", "jarvis_navigation"]]),
        ("application vs project", [["macos_application_action", "project_open"], ["project_open", "macos_application_action"], ["macos_application_action", "project_task"], ["project_task", "macos_application_action"]]),
        ("visibility vs application-running", [["computer_use/visibility_query", "computer_use/running_query"], ["computer_use/running_query", "computer_use/visibility_query"], ["computer_use/visibility_query", "macos_application_action"], ["computer_use/running_query", "macos_application_action"]]),
        ("project-open vs project-continuation", [["project_open", "project_task"], ["project_task", "project_open"], ["project_query", "project_task"], ["project_task", "project_query"]]),
        ("stop-speech vs cancel-task", [["stop_speech", "cancel_task"], ["cancel_task", "stop_speech"]]),
        ("provider-capability vs provider-selection", [["provider_capability/query", "provider_capability/prefer_provider"], ["provider_capability/prefer_provider", "provider_capability/query"]]),
    ]

    private static func label(_ intent: DecisionIntent, _ action: String?) -> String { "\(intent.rawValue)/\(action ?? "-")" }

    static func build(name: String, corpus: DecisionCorpus, recognizer: DeterministicCommandRecognizer) -> DecisionConfusionReport {
        var cells: [String: ConfusionCell] = [:]
        var fp: [String] = [], abstainedDet: [String] = []
        var answered = 0, exact = 0, mne = 0, mneHeld = 0
        var report = DecisionBenchmarkReport(decider: name)
        for k in corpus.cases {
            let d = recognizer.recognize(k.text, context: k.decisionContext)
            let truthLabel = label(k.intent, k.action), gotLabel = d.map { label($0.intent, $0.action) } ?? "abstain"
            DecisionBenchmarkRunner.tally(&report, k, d)
            if k.mustNotExecute { mne += 1 }
            guard let d else { if k.deterministic { abstainedDet.append(k.id) }; if k.mustNotExecute { mneHeld += 1 }; if k.intent != .unknown && k.intent != .conversation { record(&cells, truthLabel, "abstain", k.id) }; continue }
            answered += 1
            if DecisionBenchmarkRunner.exactMatch(d, k) { exact += 1 } else { record(&cells, truthLabel, gotLabel, k.id) }
            if k.mustNotExecute, !(d.requiresExecution && d.gate != .blocked) { mneHeld += 1 }
        }
        fp = report.executingFalsePositives.map { String($0.split(separator: " ").first ?? "") }
        // a total order (count, then expected, then got): a dictionary's iteration order must never reach the report
        let sortedCells = cells.values.sorted { a, b in a.count != b.count ? a.count > b.count : (a.expected != b.expected ? a.expected < b.expected : a.got < b.got) }
        var groups: [ConfusionGroup] = []
        for g in groupDefinitions {
            var ids: [String] = []
            for c in sortedCells where g.pairs.contains([c.expected, c.got]) || g.pairs.contains([String(c.expected.split(separator: "/").first ?? ""), String(c.got.split(separator: "/").first ?? "")]) { ids += c.ids }
            groups.append(ConfusionGroup(name: g.name, count: ids.count, ids: ids.sorted()))
        }
        return DecisionConfusionReport(corpus: name, total: corpus.cases.count, answered: answered, exact: exact, executingFalsePositives: fp, mustNotExecuteTotal: mne, mustNotExecuteHeld: mneHeld, cells: sortedCells, groups: groups, abstainedOnDeterministic: abstainedDet)
    }

    private static func record(_ cells: inout [String: ConfusionCell], _ e: String, _ g: String, _ id: String) {
        let key = "\(e)→\(g)"
        var c = cells[key] ?? ConfusionCell(expected: e, got: g, count: 0, ids: [])
        c.count += 1; c.ids.append(id); cells[key] = c
    }

    func json() -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: enc.encode(self), encoding: .utf8)) ?? "{}"
    }
}

enum QualityViolationKind: String, Codable, Equatable, Sendable { case safety, coverage }

struct QualityViolation: Equatable, Sendable {
    var kind: QualityViolationKind
    var corpus: String
    var message: String
}

struct QualityThresholds: Equatable, Sendable {
    /// Executing decisions that are wrong, allowed by id (documented exceptions). Everything else must be zero.
    var allowedExecutingFalsePositives: Set<String> = []
    /// Informational floor on exact coverage; a coverage miss is reported, but a SAFETY violation is always reported first.
    var minExactCoverage = 0.0
}

enum DecisionQualityGate {
    static func evaluate(_ r: DecisionConfusionReport, thresholds t: QualityThresholds) -> [QualityViolation] {
        var v: [QualityViolation] = []
        let unexpected = r.executingFalsePositives.filter { !t.allowedExecutingFalsePositives.contains($0) }
        if !unexpected.isEmpty { v.append(QualityViolation(kind: .safety, corpus: r.corpus, message: "executing false positives: \(unexpected.prefix(5).joined(separator: ", "))")) }
        if r.mustNotExecuteHeld < r.mustNotExecuteTotal { v.append(QualityViolation(kind: .safety, corpus: r.corpus, message: "a must-not-execute case was executed (\(r.mustNotExecuteTotal - r.mustNotExecuteHeld))")) }
        if r.total > 0, Double(r.exact) / Double(r.total) < t.minExactCoverage { v.append(QualityViolation(kind: .coverage, corpus: r.corpus, message: "exact coverage \(Int(Double(r.exact) / Double(r.total) * 100))% below \(Int(t.minExactCoverage * 100))%")) }
        return v
    }
}
