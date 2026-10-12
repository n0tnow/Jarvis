import Foundation

/// Durable storage of research and acquisition (schema v7). Everything free-text is sanitized and bounded on the way in; URLs go through
/// `CanonicalURL.forStorage` (no credentials, no token-bearing query values); there is no column for a page body and no binary anywhere.
struct ResearchSessionRow: Equatable, Sendable, Identifiable {
    var id: UUID
    var goal: String
    var type: ResearchType
    var status: ResearchStatus
    var constraints: ResearchConstraints
    var freshness: Freshness
    var deep: Bool
    var note: String?
    var meter: BudgetMeter?
    var reportArtifactID: UUID?
    var markdownArtifactID: UUID?
    var createdAt: Date
    var updatedAt: Date
    var finishedAt: Date?
}

extension JarvisRepository {
    private static func js<T: Encodable>(_ v: T) -> String { (try? String(data: JSONEncoder().encode(v), encoding: .utf8)) ?? "null" }
    private static func unjs<T: Decodable>(_ s: String?, as: T.Type) -> T? { s.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
    private static func clean(_ s: String?, _ max: Int) -> String? { s.map { OutputSanitizer.sanitize(String($0.prefix(max))) } }
    private static func uid(_ s: String?) -> UUID? { s.flatMap(UUID.init(uuidString:)) }

    // MARK: Sessions

    func upsertResearchSession(_ r: ResearchRequest, status: ResearchStatus, meter: BudgetMeter, note: String?) throws {
        let now = Date()
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO research_sessions(id, goal, type, constraints, freshness, status, deep, project_facts, meter, note, created_at, updated_at, finished_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET status=excluded.status, meter=excluded.meter, note=COALESCE(excluded.note, research_sessions.note), updated_at=excluded.updated_at, finished_at=excluded.finished_at
                """, [.text(r.id.uuidString), .text(Self.clean(r.goal, 1500) ?? ""), .text(r.type.rawValue), .text(Self.js(r.constraints)), .text(r.freshness.rawValue), .text(status.rawValue), .bool(r.deep),
                      .opt(r.project.map { Self.js($0) }), .text(Self.js(meter)), .opt(Self.clean(note, 300)), .date(r.createdAt), .date(now), .opt(status.isTerminal ? now : nil)])
        }
    }

    func setResearchReport(_ id: UUID, json: UUID?, markdown: UUID?) throws {
        try database.write { ctx in
            try ctx.execute("UPDATE research_sessions SET report_artifact_id = ?, markdown_artifact_id = ?, updated_at = ? WHERE id = ?", [.opt(json?.uuidString), .opt(markdown?.uuidString), .date(Date()), .text(id.uuidString)])
        }
    }

    func researchSession(_ id: UUID) throws -> ResearchSessionRow? { try database.readOne("SELECT * FROM research_sessions WHERE id = ?", [.text(id.uuidString)]).flatMap(Self.sessionRow) }
    func researchSessions(limit: Int = 30) throws -> [ResearchSessionRow] { try database.read("SELECT * FROM research_sessions ORDER BY updated_at DESC LIMIT ?", [.int(Int64(limit))]).compactMap(Self.sessionRow) }

    private static func sessionRow(_ r: SQLRow) -> ResearchSessionRow? {
        guard let id = uid(r.string("id")), let goal = r.string("goal"), let type = r.string("type").flatMap(ResearchType.init(rawValue:)), let status = r.string("status").flatMap(ResearchStatus.init(rawValue:)),
              let created = r.date("created_at") else { return nil }
        return ResearchSessionRow(id: id, goal: goal, type: type, status: status, constraints: unjs(r.string("constraints"), as: ResearchConstraints.self) ?? ResearchConstraints(),
                                  freshness: r.string("freshness").flatMap(Freshness.init(rawValue:)) ?? .timeless, deep: r.bool("deep"), note: r.string("note"), meter: unjs(r.string("meter"), as: BudgetMeter.self),
                                  reportArtifactID: uid(r.string("report_artifact_id")), markdownArtifactID: uid(r.string("markdown_artifact_id")), createdAt: created, updatedAt: r.date("updated_at") ?? created, finishedAt: r.date("finished_at"))
    }

    /// Launch: a session that was still searching/reading is INTERRUPTED. Nothing is resumed by itself.
    @discardableResult
    func reconcileResearchAfterRestart(now: Date = Date()) throws -> [UUID] {
        let stale = try database.read("SELECT id FROM research_sessions WHERE status IN ('planning','searching','reading','verifying','comparing','reporting')").compactMap { Self.uid($0.string("id")) }
        for id in stale {
            try database.write { ctx in try ctx.execute("UPDATE research_sessions SET status='interrupted', updated_at=?, note='interrupted by an application restart' WHERE id=?", [.date(now), .text(id.uuidString)]) }
        }
        return stale
    }

    // MARK: Queries

    func insert(_ q: QueryRecord) throws {
        try database.write { ctx in
            try ctx.execute("INSERT OR REPLACE INTO research_queries(id, research_id, text, provider, result_count, failure, at) VALUES (?,?,?,?,?,?,?)",
                            [.text(q.id.uuidString), .text(q.researchID.uuidString), .text(Self.clean(q.text, 200) ?? ""), .text(q.provider), .int(Int64(q.resultCount)), .opt(Self.clean(q.failure, 300)), .date(q.at)])
        }
    }
    func researchQueries(_ id: UUID) throws -> [QueryRecord] {
        try database.read("SELECT * FROM research_queries WHERE research_id = ? ORDER BY at", [.text(id.uuidString)]).compactMap { r in
            guard let qid = Self.uid(r.string("id")), let text = r.string("text"), let provider = r.string("provider") else { return nil }
            var q = QueryRecord(researchID: id, text: text, provider: provider, resultCount: r.int("result_count") ?? 0); q.id = qid; q.at = r.date("at") ?? Date(); q.failure = r.string("failure"); return q
        }
    }

    // MARK: Sources

    func upsert(_ s: SourceRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT OR REPLACE INTO research_sources(id, research_id, url, final_url, domain, title, type, official, retrieved_at, published_at, author, content_hash, license, method, auth_required, dynamic, http_status, trust, excerpt, note, injection_flags)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(s.id.uuidString), .text(s.researchID.uuidString), .text(CanonicalURL.forStorage(s.url)), .opt(s.finalURL.map(CanonicalURL.forStorage)), .text(String(s.domain.prefix(120))), .opt(Self.clean(s.title, 200)),
                      .text(s.type.rawValue), .text(s.official.rawValue), .date(s.retrievedAt), .opt(s.publishedAt), .opt(Self.clean(s.author, 100)), .opt(s.contentHash), .opt(Self.clean(s.license, 140)), .text(s.method.rawValue),
                      .bool(s.authRequired), .bool(s.dynamic), .opt(s.httpStatus), .int(Int64(s.trust)), .opt(Self.clean(s.excerpt, 500)), .opt(Self.clean(s.note, 300)), .text(Self.js(s.injectionFlags))])
        }
    }
    func researchSources(_ id: UUID) throws -> [SourceRecord] {
        try database.read("SELECT * FROM research_sources WHERE research_id = ? ORDER BY trust DESC, retrieved_at", [.text(id.uuidString)]).compactMap { r in
            guard let sid = Self.uid(r.string("id")), let url = r.string("url"), let type = r.string("type").flatMap(SourceType.init(rawValue:)), let off = r.string("official").flatMap(OfficialStatus.init(rawValue:)),
                  let at = r.date("retrieved_at"), let method = r.string("method").flatMap(RetrievalMethod.init(rawValue:)) else { return nil }
            return SourceRecord(id: sid, researchID: id, url: url, finalURL: r.string("final_url"), domain: r.string("domain") ?? "", title: r.string("title") ?? "", type: type, official: off, retrievedAt: at, publishedAt: r.date("published_at"),
                                author: r.string("author"), contentHash: r.string("content_hash"), license: r.string("license"), method: method, authRequired: r.bool("auth_required"), dynamic: r.bool("dynamic"), httpStatus: r.int("http_status"),
                                trust: r.int("trust") ?? 0, excerpt: r.string("excerpt") ?? "", note: r.string("note"), injectionFlags: Self.unjs(r.string("injection_flags"), as: [String].self) ?? [])
        }
    }

    // MARK: Claims

    func insert(_ c: ClaimRecord) throws {
        var safe = c
        safe.statement = Self.clean(c.statement, 400) ?? ""; safe.subject = Self.clean(c.subject, 140) ?? ""; safe.note = Self.clean(c.note, 300)
        safe.evidence = c.evidence.map { EvidenceRef(sourceID: $0.sourceID, excerpt: Self.clean($0.excerpt, 240) ?? "", field: $0.field, retrievedAt: $0.retrievedAt) }
        try database.write { ctx in
            try ctx.execute("INSERT OR REPLACE INTO research_claims(id, research_id, subject, kind, statement, epistemic, status, freshness, evidence, note, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                            [.text(safe.id.uuidString), .text(safe.researchID.uuidString), .text(safe.subject), .text(safe.kind.rawValue), .text(safe.statement), .text(safe.epistemic.rawValue), .text(safe.status.rawValue),
                             .text(safe.freshness.rawValue), .text(Self.js(safe.evidence)), .opt(safe.note), .date(Date())])
        }
    }
    func researchClaims(_ id: UUID) throws -> [ClaimRecord] {
        try database.read("SELECT * FROM research_claims WHERE research_id = ? ORDER BY created_at", [.text(id.uuidString)]).compactMap { r in
            guard let cid = Self.uid(r.string("id")), let kind = r.string("kind").flatMap(ClaimKind.init(rawValue:)), let st = r.string("statement"), let ep = r.string("epistemic").flatMap(Epistemic.init(rawValue:)),
                  let status = r.string("status").flatMap(VerificationStatus.init(rawValue:)) else { return nil }
            var c = ClaimRecord(researchID: id, subject: r.string("subject") ?? "", kind: kind, statement: st, epistemic: ep, status: status, freshness: r.string("freshness").flatMap(Freshness.init(rawValue:)) ?? .timeless,
                                evidence: Self.unjs(r.string("evidence"), as: [EvidenceRef].self) ?? [], note: r.string("note"))
            c.id = cid; return c
        }
    }

    // MARK: Candidates

    func upsert(_ c: CandidateRecord) throws {
        var safe = c
        safe.name = Self.clean(c.name, 140) ?? ""; safe.url = CanonicalURL.forStorage(c.url); safe.summary = Self.clean(c.summary, 400); safe.downloadURL = c.downloadURL.map(CanonicalURL.forStorage)
        safe.previewURL = c.previewURL.map(CanonicalURL.forStorage)
        try database.write { ctx in
            try ctx.execute("INSERT OR REPLACE INTO research_candidates(id, research_id, name, url, rank, verdict, data, updated_at) VALUES (?,?,?,?,?,?,?,?)",
                            [.text(safe.id.uuidString), .text(safe.researchID.uuidString), .text(safe.name), .text(safe.url), .int(Int64(safe.rank)), .text(safe.verdict.rawValue), .text(Self.js(safe)), .date(Date())])
        }
    }
    func researchCandidates(_ id: UUID) throws -> [CandidateRecord] {
        try database.read("SELECT data FROM research_candidates WHERE research_id = ? ORDER BY CASE WHEN rank = 0 THEN 9999 ELSE rank END, updated_at", [.text(id.uuidString)]).compactMap { Self.unjs($0.string("data"), as: CandidateRecord.self) }
    }

    // MARK: Acquisitions

    func upsert(_ a: AcquisitionRecord) throws {
        var safe = a
        safe.failure = Self.clean(a.failure, 400); safe.sourceURL = CanonicalURL.forStorage(a.sourceURL); safe.downloadURL = a.downloadURL.map(CanonicalURL.forStorage); safe.name = Self.clean(a.name, 140) ?? ""
        safe.originalFilename = Self.clean(a.originalFilename, 120)
        try database.write { ctx in
            try ctx.execute("""
                INSERT OR REPLACE INTO acquisitions(id, research_id, candidate_id, task_id, state, class, name, source_url, sha256, size, trust, data, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(safe.id.uuidString), .opt(safe.researchID?.uuidString), .opt(safe.candidateID?.uuidString), .opt(safe.taskID?.uuidString), .text(safe.state.rawValue), .text(safe.acquisitionClass.rawValue), .text(safe.name),
                      .text(safe.sourceURL), .opt(safe.sha256), .opt(safe.size), .text(safe.trust.rawValue), .text(Self.js(safe)), .date(safe.createdAt), .date(safe.updatedAt)])
        }
    }
    func acquisition(_ id: UUID) throws -> AcquisitionRecord? { try database.readOne("SELECT data FROM acquisitions WHERE id = ?", [.text(id.uuidString)]).flatMap { Self.unjs($0.string("data"), as: AcquisitionRecord.self) } }
    func acquisitions(limit: Int = 50) throws -> [AcquisitionRecord] { try database.read("SELECT data FROM acquisitions ORDER BY updated_at DESC LIMIT ?", [.int(Int64(limit))]).compactMap { Self.unjs($0.string("data"), as: AcquisitionRecord.self) } }
    func acquisitions(researchID: UUID) throws -> [AcquisitionRecord] { try database.read("SELECT data FROM acquisitions WHERE research_id = ? ORDER BY updated_at DESC", [.text(researchID.uuidString)]).compactMap { Self.unjs($0.string("data"), as: AcquisitionRecord.self) } }
    func acquisitions(states: [AcquisitionState]) throws -> [AcquisitionRecord] {
        let marks = states.map { _ in "?" }.joined(separator: ",")
        return try database.read("SELECT data FROM acquisitions WHERE state IN (\(marks))", states.map { .text($0.rawValue) }).compactMap { Self.unjs($0.string("data"), as: AcquisitionRecord.self) }
    }
}

/// Fire-and-forget adapter used by the pipeline and the acquisition service (a missing or failing database never stops research).
final class SQLiteResearchPersistence: ResearchPersisting, AcquisitionPersisting, @unchecked Sendable {
    let repository: JarvisRepository
    let artifacts: ArtifactStore?
    init(repository: JarvisRepository, artifacts: ArtifactStore?) { self.repository = repository; self.artifacts = artifacts }

    func saveSession(_ request: ResearchRequest, status: ResearchStatus, meter: BudgetMeter, note: String?) { try? repository.upsertResearchSession(request, status: status, meter: meter, note: note) }
    func saveQuery(_ q: QueryRecord) { try? repository.insert(q) }
    func saveSource(_ s: SourceRecord) { try? repository.upsert(s) }
    func saveClaim(_ c: ClaimRecord) { try? repository.insert(c) }
    func saveCandidate(_ c: CandidateRecord) { try? repository.upsert(c) }
    func save(_ record: AcquisitionRecord) { try? repository.upsert(record) }
    func saveReport(_ r: ResearchReport, markdown: String) {
        guard let artifacts else { return }
        let json = try? artifacts.store(JSONEncoder.pretty.encode(r), type: "research-report-json", folder: .reports, fileExtension: "json", taskID: r.researchID, meta: "structured research report")
        let md = try? artifacts.store(Data(markdown.utf8), type: "research-report", folder: .reports, fileExtension: "md", taskID: r.researchID, meta: "sanitized research report")
        try? repository.setResearchReport(r.researchID, json: json?.id, markdown: md?.id)
    }
}
