import Foundation

// MARK: - Document parsers (pure; bounded; they PROPOSE candidates, they write nothing)

struct ParsedEntry: Equatable, Sendable {
    var id: String               // "DEC-094", "JARVIS-V09-3"
    var title: String
    var fields: [String: String] // Status / Decision / Why / Reason / Context / Consequences / Description / Evidence / Next
    var line: Int
}

enum MemoryDocParsers {
    /// `## DEC-094 — Title` blocks with `Label: text` lines. Field text may continue on following lines until the next label/heading.
    static func entries(in text: String, headingPrefix: String, level: Int) -> [ParsedEntry] {
        let marker = String(repeating: "#", count: level) + " "
        var out: [ParsedEntry] = []
        var cur: ParsedEntry?
        var lastField: String?
        for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            if line.hasPrefix(marker) {
                if let c = cur { out.append(c) }
                cur = nil; lastField = nil
                let head = String(line.dropFirst(marker.count))
                guard head.hasPrefix(headingPrefix) else { continue }
                let parts = head.components(separatedBy: " — ")
                let id = parts[0].trimmingCharacters(in: .whitespaces)
                cur = ParsedEntry(id: id, title: parts.dropFirst().joined(separator: " — ").trimmingCharacters(in: .whitespaces), fields: [:], line: n + 1)
                continue
            }
            if line.hasPrefix("#") { if let c = cur { out.append(c) }; cur = nil; lastField = nil; continue }
            guard cur != nil else { continue }
            if let colon = line.firstIndex(of: ":"), colon != line.startIndex, line.distance(from: line.startIndex, to: colon) <= 14, line[line.startIndex].isUppercase,
               !line.hasPrefix("http"), line[line.startIndex..<colon].allSatisfy({ $0.isLetter }) {
                let label = String(line[line.startIndex..<colon])
                cur!.fields[label] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                lastField = label
            } else if let f = lastField, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                cur!.fields[f] = ((cur!.fields[f] ?? "") + " " + line.trimmingCharacters(in: .whitespaces)).trimmingCharacters(in: .whitespaces)
            }
        }
        if let c = cur { out.append(c) }
        return out
    }

    static func decisions(_ text: String) -> [ParsedEntry] { entries(in: text, headingPrefix: "DEC-", level: 2) }
    static func issues(_ text: String) -> [ParsedEntry] { entries(in: text, headingPrefix: "JARVIS-", level: 3) }

    /// The bullets under `## Rules` of AGENTS.md: each rule is a standing instruction of the project owner.
    static func rules(_ text: String) -> [(title: String, body: String, line: Int)] {
        var out: [(String, String, Int)] = []
        var inRules = false
        for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            if line.hasPrefix("## ") { inRules = line.hasPrefix("## Rules"); continue }
            guard inRules, line.hasPrefix("- ") else { continue }
            let body = String(line.dropFirst(2))
            let title = body.components(separatedBy: CharacterSet(charactersIn: ".:;(")).first.map { MemoryText.clip($0, 60) } ?? "rule"
            out.append((title, body, n + 1))
        }
        return out
    }

    /// Dated development-log entries: the milestone episode (Goal) and the bullets under findings/problems headings.
    struct LogEntry: Equatable, Sendable { var heading: String; var goal: String; var findings: [String]; var results: String; var line: Int }
    static func devLog(_ text: String) -> [LogEntry] {
        var out: [LogEntry] = []
        var heading: String?, goal = "", results = "", findings: [String] = [], section = "", line = 0
        func flush() { if let h = heading { out.append(LogEntry(heading: h, goal: goal, findings: findings, results: results, line: line)) }; goal = ""; results = ""; findings = [] }
        for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let l = String(raw)
            if l.hasPrefix("## ") { flush(); heading = String(l.dropFirst(3)); line = n + 1; section = ""; continue }
            if l.hasPrefix("### ") { section = String(l.dropFirst(4)).lowercased(); continue }
            let t = l.trimmingCharacters(in: .whitespaces)
            guard heading != nil, !t.isEmpty else { continue }
            if section.hasPrefix("goal") { goal += (goal.isEmpty ? "" : " ") + t }
            else if section.hasPrefix("results") { results += (results.isEmpty ? "" : " ") + t }
            else if section.contains("finding") || section.hasPrefix("problems found") {
                if t.hasPrefix("* ") || t.hasPrefix("- ") { findings.append(String(t.dropFirst(2))) }
            }
        }
        flush()
        return out
    }
}

// MARK: - Bootstrap / ingestion

struct IngestReport: Equatable, Sendable {
    var created = 0, merged = 0, superseded = 0, disputed = 0, rejected = 0
    var byType: [MemoryType: Int] = [:]
    var sources: [String] = []
    var rejections: [String] = []
    var total: Int { created + merged + superseded + disputed + rejected }
    mutating func add(_ r: AdmitResult, type: MemoryType) {
        switch r {
        case .created: created += 1; byType[type, default: 0] += 1
        case .merged: merged += 1
        case .superseded: superseded += 1; byType[type, default: 0] += 1
        case .disputed: disputed += 1
        case .rejected(let why): rejected += 1; if rejections.count < 8 { rejections.append("\(why)") }
        }
    }
    mutating func add(_ other: IngestReport) {
        created += other.created; merged += other.merged; superseded += other.superseded; disputed += other.disputed; rejected += other.rejected
        for (k, v) in other.byType { byType[k, default: 0] += v }
        sources += other.sources; rejections = Array((rejections + other.rejections).prefix(8))
    }
}

/// Turns trustworthy sources into CANDIDATES and hands each to the curator. Deterministic extraction first; a model only ever proposes (`ModelMemoryExtractor`).
final class MemoryIngestor: @unchecked Sendable {
    let service: MemoryService
    var repository: JarvisRepository { service.repository }

    init(service: MemoryService) { self.service = service }

    private static let areas: [(String, [String])] = [
        ("camera", ["camera"]), ("voice", ["voice", "speech", "wake word", "microphone", "whisper", "tts", "barge-in"]), ("research", ["research", "web ", "webkit", "browser", "playwright", "search"]),
        ("hud", ["hud", "compact", "full hud", "window"]), ("unity", ["unity", "scene", "prefab", "editor bridge", "urp"]), ("assets", ["asset", "download", "quarantine", "licence", "license", "acquisition"]),
        ("security", ["security", "approval", "credential", "secret", "ssrf", "injection", "authority"]), ("models", ["model", "provider", "qwen", "opencode", "claude", "codex", "routing"]),
        ("persistence", ["sqlite", "schema", "migration", "persist"]), ("tasks", ["task engine", "task ", "plan", "lease", "workspace"]), ("memory", ["memory", "embedding", "retrieval"]),
    ]
    static func area(for text: String) -> String? {
        let f = text.lowercased()
        return areas.map { a in (a.0, a.1.filter { f.contains($0) }.count) }.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
    }

    private static func importance(for text: String) -> MemoryImportance {
        let f = text.lowercased()
        if f.contains("never") || f.contains("must not") || f.contains("no code path") || f.contains("cannot") || f.contains("credential") || f.contains("secret") { return .high }
        return .normal
    }

    // MARK: Repository documents

    @discardableResult
    func ingestDocuments(root: String, projectKey: String) -> IngestReport {
        var report = IngestReport()
        func read(_ rel: String) -> String? { FileManager.default.contents(atPath: root + "/" + rel).flatMap { String(data: $0.prefix(2_000_000), encoding: .utf8) } }

        if let t = read("docs/DECISIONS.md") {
            report.sources.append("docs/DECISIONS.md")
            for e in MemoryDocParsers.decisions(t) {
                guard let decision = e.fields["Decision"] ?? e.fields["Context"] else { continue }
                let status = (e.fields["Status"] ?? "")
                let superseded = status.lowercased().hasPrefix("superseded")
                var summary = "\(e.id) — \(e.title): \(decision)"
                summary = MemoryText.clip(summary, 300)
                var why = ["Decision: " + decision, e.fields["Why"].map { "Why: " + $0 }, e.fields["Reason"].map { "Reason: " + $0 }, e.fields["Consequences"].map { "Consequences: " + $0 }].compactMap { $0 }.joined(separator: " ")
                if !status.isEmpty { why = "Status: \(status). " + why }
                var c = MemoryCandidate(type: .decision, subject: MemoryText.clip(e.title, 60), key: "decision:\(e.id)", value: MemoryText.fold(decision),
                                        summary: summary, details: MemoryText.clip(why, MemoryConstants.maxDetails), strength: .strong, importance: Self.importance(for: decision + " " + e.title), area: Self.area(for: e.title + " " + decision),
                                        tags: [e.id.lowercased()], origin: .bootstrap, sources: [MemorySource(kind: .decisionDoc, ref: e.id, label: e.id, locator: "docs/DECISIONS.md:\(e.line)")])
                c.statusHint = superseded ? .superseded : nil
                report.add(service.admit(c, projectKey: projectKey, projectRoot: root), type: .decision)
            }
        }
        if let t = read("docs/KNOWN_ISSUES.md") {
            report.sources.append("docs/KNOWN_ISSUES.md")
            for e in MemoryDocParsers.issues(t) {
                let body = e.fields["Description"] ?? e.fields["Evidence"] ?? e.title
                let status = e.fields["Status"] ?? ""
                let resolved = status.lowercased().hasPrefix("resolved") || status.lowercased().hasPrefix("fixed")
                var c = MemoryCandidate(type: .knownIssue, subject: MemoryText.clip(e.title, 60), key: "issue:\(e.id)", value: MemoryText.fold(body + status),
                                        summary: MemoryText.clip("\(e.id) — \(e.title): \(body)", MemoryConstants.maxSummary), details: MemoryText.clip("Status: \(status). " + (e.fields["Next"] ?? e.fields["Evidence"] ?? ""), MemoryConstants.maxDetails),
                                        strength: .strong, importance: status.contains("BLOCKING") && !status.contains("NON-BLOCKING") ? .high : .normal, area: Self.area(for: e.title + " " + body), tags: [e.id.lowercased()],
                                        origin: .bootstrap, sources: [MemorySource(kind: .document, ref: e.id, label: e.id, locator: "docs/KNOWN_ISSUES.md:\(e.line)")])
                c.statusHint = resolved ? .archived : nil
                report.add(service.admit(c, projectKey: projectKey, projectRoot: root), type: .knownIssue)
            }
        }
        if let t = read("AGENTS.md") {
            report.sources.append("AGENTS.md")
            for r in MemoryDocParsers.rules(t) {
                let body = MemoryText.clip(r.body, 1_800)
                let first = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? body
                let summary = MemoryText.clip(body.count <= MemoryConstants.maxSummary ? body : first + ".", MemoryConstants.maxSummary)
                let c = MemoryCandidate(type: .constraint, subject: r.title, key: "rule:" + MemoryText.canonicalHash(type: .constraint, summary: r.title, key: nil, value: nil).prefix(10), value: MemoryText.fold(body).prefix(300).description,
                                        summary: summary, details: body.count > summary.count ? body : nil, strength: .authoritative, importance: .high, area: Self.area(for: body), tags: ["agents-rule"],
                                        origin: .bootstrap, sources: [MemorySource(kind: .document, ref: "AGENTS.md#rule-\(r.line)", label: "AGENTS.md", locator: "AGENTS.md:\(r.line)")])
                report.add(service.admit(c, projectKey: projectKey, projectRoot: root), type: .constraint)
            }
        }
        if let t = read("docs/DEVELOPMENT_LOG.md") {
            report.sources.append("docs/DEVELOPMENT_LOG.md")
            for e in MemoryDocParsers.devLog(t) {
                let name = e.heading.components(separatedBy: " — ").dropFirst().joined(separator: " — ")
                let label = name.isEmpty ? e.heading : name
                if e.goal.count > 30 {
                    let c = MemoryCandidate(type: .episode, subject: MemoryText.clip(label, 60), key: "episode:" + MemoryText.canonicalHash(type: .episode, summary: e.heading, key: nil, value: nil).prefix(10), value: MemoryText.fold(e.goal + e.results).prefix(300).description,
                                            summary: MemoryText.clip("\(label): \(e.goal)", MemoryConstants.maxSummary), details: e.results.isEmpty ? nil : MemoryText.clip("Result: \(e.results)", MemoryConstants.maxDetails), strength: .strong,
                                            area: Self.area(for: label + " " + e.goal), origin: .bootstrap, sources: [MemorySource(kind: .document, ref: "DEVELOPMENT_LOG#\(e.line)", label: "DEVELOPMENT_LOG: \(MemoryText.clip(label, 40))", locator: "docs/DEVELOPMENT_LOG.md:\(e.line)")])
                    report.add(service.admit(c, projectKey: projectKey, projectRoot: root), type: .episode)
                }
                for f in e.findings.prefix(12) where f.count >= 40 {
                    let c = MemoryCandidate(type: .failure, subject: MemoryText.clip(f, 40), summary: MemoryText.clip(f, MemoryConstants.maxSummary), strength: .strong, area: Self.area(for: f), tags: ["finding"],
                                            origin: .bootstrap, sources: [MemorySource(kind: .document, ref: "DEVELOPMENT_LOG#\(e.line)", label: "DEVELOPMENT_LOG: \(MemoryText.clip(label, 40))", locator: "docs/DEVELOPMENT_LOG.md:\(e.line)")])
                    report.add(service.admit(c, projectKey: projectKey, projectRoot: root), type: .failure)
                }
            }
        }
        return report
    }

    // MARK: Current project inspection (deterministic facts, authoritative while true)

    @discardableResult
    func ingestInspection(root: String, projectKey: String) -> IngestReport {
        var report = IngestReport()
        guard let d = UnityProjectDetector.describe(root: root) else { return report }
        let src = MemorySource(kind: .unityInspection, ref: "ProjectSettings/ProjectVersion.txt", label: "Unity project inspection")
        func fact(_ subject: String, _ key: String, _ value: String, _ text: String) {
            let c = MemoryCandidate(type: .projectFact, subject: subject, key: key, value: value, summary: text, strength: .authoritative, area: "unity", origin: .inspection, sources: [src], lastVerifiedAt: Date())
            report.add(service.admit(c, projectKey: projectKey, projectRoot: root), type: .projectFact)
        }
        if let v = d.declaredVersionRaw { fact("unity version", "unity.version", v, "The Unity project uses editor version \(v).") }
        fact("render pipeline", "unity.pipeline", d.renderPipeline, "The Unity project's render pipeline is \(d.renderPipeline).")
        fact("test framework", "unity.tests", d.hasTestFramework ? "true" : "false", d.hasTestFramework ? "The Unity project has the Test Framework package." : "The Unity project has no Test Framework package.")
        report.sources.append("Unity project files")
        return report
    }

    // MARK: Finished tasks (meaningful lifecycle trigger; trivial and infrastructure outcomes write nothing)

    static let infrastructureFailures: Set<FailureCategory> = [.providerUnavailable, .providerRateLimited, .providerFailed, .resourceUnavailable, .cancelled, .interrupted, .networkUnavailable,
                                                               .approvalDenied, .capabilityDenied, .unityUnavailable, .unsafeEditorState, .unityTimeout, .interactionRequired]

    func taskCandidates(task: TaskRecord, report: TaskReport?) -> [MemoryCandidate] {
        guard !task.kind.isWebTask else { return [] }                  // research/acquisition are remembered from their own validated records
        let taskSource = MemorySource(kind: .task, ref: task.id.uuidString, label: "Task: " + MemoryText.clip(task.title, 50))
        var out: [MemoryCandidate] = []
        let area = Self.area(for: task.title + " " + task.goal)
        switch task.state {
        case .completed:
            guard let r = report, !r.filesChanged.isEmpty else { return [] }          // nothing changed → nothing worth remembering
            let files = r.filesChanged.prefix(4).joined(separator: ", ")
            var text = "Completed “\(MemoryText.clip(task.title, 70))”: changed \(r.filesChanged.count) file\(r.filesChanged.count == 1 ? "" : "s") (\(files)\(r.filesChanged.count > 4 ? ", …" : ""))."
            if let v = r.validations.first { text += " Validation: \(MemoryText.clip(v, 90))." }
            if r.repairAttempts > 0 { text += " Needed \(r.repairAttempts) repair attempt\(r.repairAttempts == 1 ? "" : "s")." }
            var c = MemoryCandidate(type: .episode, subject: MemoryText.clip(task.title, 60), summary: MemoryText.clip(text, MemoryConstants.maxSummary), strength: .strong, area: area, tags: ["task"], origin: .task,
                                    sources: [taskSource] + r.filesChanged.prefix(6).map { MemorySource(kind: .fileChange, ref: $0, label: $0) },
                                    relations: r.filesChanged.prefix(6).map { MemoryRelation(predicate: "modifies", targetKind: "entity", target: "file:\($0)") })
            c.validFrom = task.finishedAt ?? Date()
            out.append(c)
            if let u = r.unity?.first(where: { $0.lowercased().contains("test") }) {
                var v = MemoryCandidate(type: .validationResult, subject: "Unity tests", summary: MemoryText.clip("After “\(MemoryText.clip(task.title, 50))”: \(u)", MemoryConstants.maxSummary), strength: .strong, area: "unity", origin: .task, sources: [taskSource], currentSensitive: true)
                v.validFrom = task.finishedAt ?? Date()
                out.append(v)
            }
        case .failed:
            guard let cat = task.failureCategory, !Self.infrastructureFailures.contains(cat), let why = report?.failure?.reason ?? task.failureReason, why.count > 15 else { return [] }
            var c = MemoryCandidate(type: .failure, subject: MemoryText.clip(task.title, 60), summary: MemoryText.clip("Task “\(MemoryText.clip(task.title, 60))” failed (\(cat.label)): \(why)", MemoryConstants.maxSummary),
                                    details: report?.failure.map { MemoryText.clip("Failed step: \($0.failedStep ?? "n/a"). Suggested next: \($0.suggestedNext)", 400) }, strength: .strong, area: area, tags: ["task", "failure"], origin: .task, sources: [taskSource])
            c.validFrom = task.finishedAt ?? Date()
            out.append(c)
        default: break
        }
        return out
    }

    @discardableResult
    func ingestTask(task: TaskRecord, report: TaskReport?, projectKey: String, projectRoot: String?) -> IngestReport {
        var rep = IngestReport()
        for c in taskCandidates(task: task, report: report) { rep.add(service.admit(c, projectKey: projectKey, projectRoot: projectRoot), type: c.type) }
        return rep
    }

    // MARK: Research (only what the V0.9 pipeline VERIFIED)

    /// A finished research session → ONE finding that points at the session, plus asset decisions for its recommended / rejected candidates. Nothing is copied from a page.
    @discardableResult
    func ingestResearch(sessionID: UUID, projectKey: String) -> IngestReport {
        var rep = IngestReport()
        guard let s = (try? repository.researchSession(sessionID)) ?? nil, s.status == .completed else { return rep }
        let candidates = (try? repository.researchCandidates(sessionID)) ?? []
        let preferred = candidates.first { $0.verdict == .preferred }
        let sessionSource = MemorySource(kind: .researchSession, ref: sessionID.uuidString, label: "Research: " + MemoryText.clip(s.goal, 50))
        var text = "Researched “\(MemoryText.clip(s.goal, 90))” (\(s.type.label.lowercased()))."
        if let p = preferred { text += " Recommended: \(p.name) (\(p.price.state.rawValue), \(p.license.identifier ?? p.license.state.rawValue))." } else if candidates.isEmpty { text += " No candidate was found." }
        let finding = MemoryCandidate(type: .researchFinding, subject: MemoryText.clip(s.goal, 60), summary: MemoryText.clip(text, MemoryConstants.maxSummary), strength: .strong, area: Self.area(for: s.goal) ?? "research",
                                      tags: ["research"], origin: .research, sources: [sessionSource], currentSensitive: s.type == .assetDiscovery, validFrom: s.finishedAt ?? s.updatedAt)
        rep.add(service.admit(finding, projectKey: projectKey), type: .researchFinding)
        for c in candidates.prefix(8) where c.verdict == .preferred || c.verdict == .alternative || c.verdict == .notRecommended {
            let accepted = c.verdict != .notRecommended
            var t = accepted ? "\(c.name) was \(c.verdict == .preferred ? "recommended" : "an alternative") for “\(MemoryText.clip(s.goal, 50))”" : "\(c.name) was not recommended for “\(MemoryText.clip(s.goal, 50))”"
            t += ": price \(c.price.state.rawValue), licence \(c.license.identifier ?? c.license.state.rawValue)"
            if !accepted, let why = c.verdictReasons.first { t += "; reason: \(why)" }
            let d = MemoryCandidate(type: .assetDecision, subject: MemoryText.clip(c.name, 50), key: "asset:" + MemoryText.fold(c.name) + ":" + sessionID.uuidString.prefix(8), value: c.verdict.rawValue,
                                    summary: MemoryText.clip(t + ".", MemoryConstants.maxSummary), strength: .strong, area: "assets", tags: ["asset", accepted ? "candidate" : "rejected"], origin: .research,
                                    sources: [MemorySource(kind: .researchCandidate, ref: c.id.uuidString, label: "Candidate: " + MemoryText.clip(c.name, 40)), sessionSource],
                                    relations: [MemoryRelation(predicate: "about", targetKind: "entity", target: "asset:\(c.name)")], currentSensitive: true, validFrom: s.finishedAt ?? s.updatedAt)
            rep.add(service.admit(d, projectKey: projectKey), type: .assetDecision)
        }
        return rep
    }

    /// Acquired / imported artifacts → what happened to the asset (provenance links to the V0.9 records).
    @discardableResult
    func ingestAcquisitions(projectKey: String) -> IngestReport {
        var rep = IngestReport()
        for a in ((try? repository.acquisitions(limit: 50)) ?? []) where a.state == .readyForImport || a.importedTo != nil {
            var t = "\(a.name) was acquired into the quarantine (licence \(a.licenseID ?? "unknown"), \(a.size.map { "\($0 / 1024) KB" } ?? "size unknown"))"
            if let dest = a.importedTo { t += " and imported to \(dest)" }
            var rels = [MemoryRelation(predicate: "about", targetKind: "entity", target: "asset:\(a.name)")]
            if let dest = a.importedTo { rels.append(MemoryRelation(predicate: "modifies", targetKind: "entity", target: "file:\(dest)")) }
            var srcs = [MemorySource(kind: .acquisition, ref: a.id.uuidString, label: "Acquisition: " + MemoryText.clip(a.name, 40))]
            if let tid = a.importTaskID { srcs.append(MemorySource(kind: .importTask, ref: tid.uuidString, label: "Import task")) }
            let c = MemoryCandidate(type: .assetDecision, subject: MemoryText.clip(a.name, 50), key: "acquisition:\(a.id.uuidString.prefix(8))", value: a.importedTo != nil ? "imported" : "quarantined", summary: MemoryText.clip(t + ".", MemoryConstants.maxSummary),
                                    strength: .strong, area: "assets", tags: ["asset", "acquisition"], origin: .research, sources: srcs, relations: rels, currentSensitive: false, validFrom: a.updatedAt)
            rep.add(service.admit(c, projectKey: projectKey), type: .assetDecision)
        }
        return rep
    }

    // MARK: Bootstrap (explicit, bounded, idempotent)

    @discardableResult
    func bootstrap(root: String, projectKey: String) -> IngestReport {
        var rep = ingestDocuments(root: root, projectKey: projectKey)
        rep.add(ingestInspection(root: root, projectKey: projectKey))
        for s in ((try? repository.researchSessions(limit: 30)) ?? []) where s.status == .completed { rep.add(ingestResearch(sessionID: s.id, projectKey: projectKey)) }
        rep.add(ingestAcquisitions(projectKey: projectKey))
        service.consolidateLessons(projectKey: projectKey)
        service.note(projectKey, "bootstrap", nil, "\(rep.created) new · \(rep.merged) already known · \(rep.superseded) updated · \(rep.rejected) skipped")
        return rep
    }
}

// MARK: - Model-proposed memory (validated, grounded, never authoritative)

/// A model may PROPOSE lessons/decision rationale from a finished task report. Output must be one JSON object of at most 3 memories; each must quote an `evidence` excerpt that
/// appears VERBATIM in the report (`Grounding`); otherwise it is kept only as an UNVERIFIED inference. The proposal then goes through the same curator as everything else.
enum ModelMemoryExtractor {
    static func prompt(taskTitle: String, report: String) -> String {
        """
        \(UntrustedContent.preamble)
        You help maintain a project's memory. From the finished-task report below, propose at most 3 durable project memories: a decision WITH its reason, a failed approach, or a lesson. Skip anything trivial.
        Each memory needs: "type" (decision|failure|lesson|constraint), "subject" (1–4 words), "summary" (one sentence, ≤ 280 chars), "evidence" (an exact quote of 8–25 words copied from the report).
        Reply with ONE JSON object only: {"memories":[{"type":"…","subject":"…","summary":"…","evidence":"…"}]}  (an empty list is fine).
        Task: \(UntrustedContent.clean(taskTitle, maxChars: 120))
        \(UntrustedContent.fence(id: "R", url: "task-report", text: report, maxChars: 3_500))
        """
    }

    static func parse(_ answer: String, report: String, task: TaskRecord, modelName: String) -> [MemoryCandidate] {
        guard let json = PlanParser.extractJSONObject(answer), let v = JSONValue.parse(json), let arr = v["memories"]?.array else { return [] }
        var out: [MemoryCandidate] = []
        for m in arr.prefix(3) {
            guard let t = m["type"]?.string.flatMap({ MemoryType(rawValue: $0 == "constraint" ? "constraint" : $0) }), [.decision, .failure, .lesson, .constraint].contains(t),
                  let summary = m["summary"]?.string, summary.count >= 20, summary.count <= 400, let subject = m["subject"]?.string, !subject.isEmpty else { continue }
            let evidence = m["evidence"]?.string ?? ""
            let grounded = evidence.count >= 20 && Grounding.isGrounded(evidence, in: report)
            var c = MemoryCandidate(type: t, subject: MemoryText.clip(subject, 50), summary: summary, strength: grounded ? .supported : .inferred, area: MemoryIngestor.area(for: summary), tags: ["task", "model-proposed"], origin: .model,
                                    sources: [MemorySource(kind: .task, ref: task.id.uuidString, label: "Task: " + MemoryText.clip(task.title, 50)), MemorySource(kind: .agentRun, ref: modelName, label: "proposed by \(modelName)")])
            c.proposedBy = modelName; c.grounded = grounded
            out.append(c)
        }
        return out
    }
}
