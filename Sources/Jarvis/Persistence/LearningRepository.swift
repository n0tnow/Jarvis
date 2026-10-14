import Foundation

// MARK: - Adaptive learning persistence (V0.14). Structured rows only: no secret, no screenshot, no raw transcript, no reasoning text.

extension JarvisRepository {
    private static func ljs<T: Encodable>(_ v: T) -> String { (try? String(data: JSONEncoder().encode(v), encoding: .utf8)) ?? "{}" }
    private static func unljs<T: Decodable>(_ s: String?, as: T.Type) -> T? { s.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
    private static func lclean(_ s: String?, _ n: Int) -> String? { s.map { OutputSanitizer.sanitize(String($0.prefix(n))) } }
    private static func luid(_ s: String?) -> UUID? { s.flatMap(UUID.init(uuidString:)) }

    // MARK: Signals (idempotent: the same source can only produce the same signal once)

    @discardableResult
    func insertSignal(_ s: LearningSignal) throws -> Bool {
        try database.write { ctx in
            let before = try ctx.execute("SELECT COUNT(*) AS n FROM learning_signals").first?.int("n") ?? 0
            try ctx.execute("""
                INSERT OR IGNORE INTO learning_signals(id, kind, key, project_key, source_kind, source_id, episode, at, outcome, detail) VALUES (?,?,?,?,?,?,?,?,?,?)
                """, [.text(s.id.uuidString), .text(s.kind.rawValue), .text(String(s.key.prefix(160))), .opt(s.projectKey), .text(s.sourceKind.rawValue), .text(String(s.sourceID.prefix(120))),
                      .text(String(s.episode.prefix(120))), .date(s.at), .text(s.outcome.rawValue), .opt(Self.lclean(s.detail, 400))])
            let after = try ctx.execute("SELECT COUNT(*) AS n FROM learning_signals").first?.int("n") ?? 0
            return after > before
        }
    }

    private static func signal(_ r: SQLRow) -> LearningSignal? {
        guard let id = luid(r.string("id")), let kind = r.string("kind").flatMap(SignalKind.init(rawValue:)), let sk = r.string("source_kind").flatMap(LearningEvidenceKind.init(rawValue:)),
              let at = r.date("at"), let outcome = r.string("outcome").flatMap(LearningSignal.Outcome.init(rawValue:)) else { return nil }
        return LearningSignal(id: id, kind: kind, key: r.string("key") ?? "", projectKey: r.string("project_key"), sourceKind: sk, sourceID: r.string("source_id") ?? "", episode: r.string("episode") ?? "", at: at, outcome: outcome, detail: r.string("detail") ?? "")
    }
    func signals(since: Date, limit: Int = 2_000) throws -> [LearningSignal] {
        try database.read("SELECT * FROM learning_signals WHERE at >= ? ORDER BY at DESC LIMIT ?", [.date(since), .int(Int64(limit))]).compactMap(Self.signal)
    }
    func signals(kind: SignalKind, key: String) throws -> [LearningSignal] {
        try database.read("SELECT * FROM learning_signals WHERE kind = ? AND key = ? ORDER BY at", [.text(kind.rawValue), .text(key)]).compactMap(Self.signal)
    }
    func signalExists(sourceKind: String, sourceID: String) throws -> Bool {
        (try database.readOne("SELECT 1 AS x FROM learning_signals WHERE source_kind = ? AND source_id = ? LIMIT 1", [.text(sourceKind), .text(sourceID)])) != nil
    }
    func signalCount() throws -> Int { try database.readOne("SELECT COUNT(*) AS n FROM learning_signals")?.int("n") ?? 0 }
    @discardableResult
    func pruneSignals(keep: Int = 5_000) throws -> Int {
        try database.write { ctx in try ctx.execute("DELETE FROM learning_signals WHERE id IN (SELECT id FROM learning_signals ORDER BY at DESC LIMIT -1 OFFSET ?)", [.int(Int64(keep))]); return 0 }
    }

    // MARK: Candidates

    func save(_ c: LearningCandidate) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO learning_candidates(id, fingerprint, kind, status, scope_level, scope_key, project_key, title, summary, confidence, risk, occurrence_count, proposed_effect, validation_requirement,
                    promotion_requirement, payload, rejection_reason, superseded_by, created_at, last_seen_at, updated_at, decided_by, decided_at, cooldown_until, evidence_at_rejection)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET status = excluded.status, title = excluded.title, summary = excluded.summary, confidence = excluded.confidence, risk = excluded.risk,
                    occurrence_count = excluded.occurrence_count, proposed_effect = excluded.proposed_effect, validation_requirement = excluded.validation_requirement,
                    promotion_requirement = excluded.promotion_requirement, payload = excluded.payload, rejection_reason = excluded.rejection_reason, superseded_by = excluded.superseded_by,
                    last_seen_at = excluded.last_seen_at, updated_at = excluded.updated_at, decided_by = excluded.decided_by, decided_at = excluded.decided_at,
                    cooldown_until = excluded.cooldown_until, evidence_at_rejection = excluded.evidence_at_rejection
                """, [.text(c.id.uuidString), .text(c.fingerprint), .text(c.kind.rawValue), .text(c.status.rawValue), .text(c.scope.level.rawValue), .opt(c.scope.key), .opt(c.projectKey),
                      .text(Self.lclean(c.title, 160) ?? ""), .text(Self.lclean(c.summary, 600) ?? ""), .double(c.confidence), .text(c.risk.rawValue), .int(Int64(c.occurrenceCount)),
                      .opt(Self.lclean(c.proposedEffect, 400)), .opt(Self.lclean(c.validationRequirement, 300)), .opt(Self.lclean(c.promotionRequirement, 300)), .text(Self.ljs(c.payload)),
                      .opt(Self.lclean(c.rejectionReason, 300)), .opt(c.supersededBy?.uuidString), .date(c.createdAt), .date(c.lastSeenAt), .date(c.updatedAt), .opt(c.decidedBy), .opt(c.decidedAt),
                      .opt(c.cooldownUntil), .opt(c.evidenceAtRejection)])
            for e in c.evidence {
                try ctx.execute("INSERT OR IGNORE INTO learning_evidence(id, candidate_id, kind, source_id, at, note) VALUES (?,?,?,?,?,?)",
                                [.text(UUID().uuidString), .text(c.id.uuidString), .text(e.kind.rawValue), .text(String(e.sourceID.prefix(120))), .date(e.at), .opt(Self.lclean(e.note, 200))])
            }
        }
    }

    private func candidate(_ r: SQLRow) -> LearningCandidate? {
        guard let id = Self.luid(r.string("id")), let kind = r.string("kind").flatMap(LearningKind.init(rawValue:)), let status = r.string("status").flatMap(LearningStatus.init(rawValue:)),
              let level = r.string("scope_level").flatMap(LearningScope.Level.init(rawValue:)), let payload = Self.unljs(r.string("payload"), as: LearningPayload.self),
              let created = r.date("created_at") else { return nil }
        let ev = ((try? database.read("SELECT * FROM learning_evidence WHERE candidate_id = ? ORDER BY at", [.text(id.uuidString)])) ?? []).compactMap { e -> LearningEvidenceRef? in
            guard let k = e.string("kind").flatMap(LearningEvidenceKind.init(rawValue:)), let at = e.date("at") else { return nil }
            return LearningEvidenceRef(kind: k, sourceID: e.string("source_id") ?? "", at: at, note: e.string("note") ?? "")
        }
        return LearningCandidate(id: id, fingerprint: r.string("fingerprint") ?? "", kind: kind, status: status, title: r.string("title") ?? "", summary: r.string("summary") ?? "",
                                 scope: LearningScope(level: level, key: r.string("scope_key")), projectKey: r.string("project_key"), confidence: r.double("confidence") ?? 0,
                                 risk: r.string("risk").flatMap(RiskClass.init(rawValue:)) ?? .low, occurrenceCount: r.int("occurrence_count") ?? 0, evidence: ev,
                                 proposedEffect: r.string("proposed_effect") ?? "", validationRequirement: r.string("validation_requirement") ?? "", promotionRequirement: r.string("promotion_requirement") ?? "",
                                 payload: payload, rejectionReason: r.string("rejection_reason"), supersededBy: Self.luid(r.string("superseded_by")), createdAt: created,
                                 lastSeenAt: r.date("last_seen_at") ?? created, updatedAt: r.date("updated_at") ?? created, decidedBy: r.string("decided_by"), decidedAt: r.date("decided_at"),
                                 cooldownUntil: r.date("cooldown_until"), evidenceAtRejection: r.int("evidence_at_rejection"))
    }
    func learningCandidate(_ id: UUID) throws -> LearningCandidate? { try database.readOne("SELECT * FROM learning_candidates WHERE id = ?", [.text(id.uuidString)]).flatMap(candidate) }
    func learningCandidate(fingerprint: String) throws -> LearningCandidate? { try database.readOne("SELECT * FROM learning_candidates WHERE fingerprint = ?", [.text(fingerprint)]).flatMap(candidate) }
    func learningCandidates(statuses: [LearningStatus]? = nil, kinds: [LearningKind]? = nil, limit: Int = 200) throws -> [LearningCandidate] {
        var sql = "SELECT * FROM learning_candidates WHERE 1=1"; var p: [SQLValue] = []
        if let statuses, !statuses.isEmpty { sql += " AND status IN (\(statuses.map { _ in "?" }.joined(separator: ",")))"; p += statuses.map { .text($0.rawValue) } }
        if let kinds, !kinds.isEmpty { sql += " AND kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))"; p += kinds.map { .text($0.rawValue) } }
        sql += " ORDER BY updated_at DESC LIMIT ?"; p.append(.int(Int64(limit)))
        return try database.read(sql, p).compactMap(candidate)
    }
    func learningCandidateCount() throws -> Int { try database.readOne("SELECT COUNT(*) AS n FROM learning_candidates")?.int("n") ?? 0 }

    // MARK: Rules

    func save(_ r: LearnedRule, reason: String? = nil, by: String? = nil) throws {
        try database.write { ctx in
            let existing = try ctx.execute("SELECT version FROM learned_rules WHERE id = ?", [.text(r.id.uuidString)]).first?.int("version")
            try ctx.execute("""
                INSERT INTO learned_rules(id, candidate_id, scope_level, scope_key, project_key, version, status, definition, title, origin, activated_at, last_used_at, success_count, failure_count, previous_version, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET version = excluded.version, status = excluded.status, definition = excluded.definition, title = excluded.title, activated_at = excluded.activated_at,
                    last_used_at = excluded.last_used_at, success_count = excluded.success_count, failure_count = excluded.failure_count, previous_version = excluded.previous_version
                """, [.text(r.id.uuidString), .opt(r.candidateID?.uuidString), .text(r.scope.level.rawValue), .opt(r.scope.key), .opt(r.projectKey), .int(Int64(r.version)), .text(r.status.rawValue),
                      .text(Self.ljs(r.definition)), .text(Self.lclean(r.title, 160) ?? ""), .text(Self.lclean(r.origin, 200) ?? ""), .opt(r.activatedAt), .opt(r.lastUsedAt), .int(Int64(r.successCount)),
                      .int(Int64(r.failureCount)), .opt(r.previousVersion), .date(r.createdAt)])
            if existing != r.version {
                try ctx.execute("INSERT INTO rule_versions(id, rule_id, version, definition, at, reason, changed_by) VALUES (?,?,?,?,?,?,?)",
                                [.text(UUID().uuidString), .text(r.id.uuidString), .int(Int64(r.version)), .text(Self.ljs(r.definition)), .date(Date()), .opt(Self.lclean(reason, 200)), .opt(by)])
            }
        }
    }
    private static func rule(_ r: SQLRow) -> LearnedRule? {
        guard let id = luid(r.string("id")), let level = r.string("scope_level").flatMap(LearningScope.Level.init(rawValue:)), let status = r.string("status").flatMap(LearningStatus.init(rawValue:)),
              let def = unljs(r.string("definition"), as: RuleDefinition.self), let created = r.date("created_at") else { return nil }
        return LearnedRule(id: id, candidateID: luid(r.string("candidate_id")), scope: LearningScope(level: level, key: r.string("scope_key")), projectKey: r.string("project_key"),
                           version: r.int("version") ?? 1, status: status, definition: def, title: r.string("title") ?? "", origin: r.string("origin") ?? "", activatedAt: r.date("activated_at"),
                           lastUsedAt: r.date("last_used_at"), successCount: r.int("success_count") ?? 0, failureCount: r.int("failure_count") ?? 0, previousVersion: r.int("previous_version"), createdAt: created)
    }
    func learnedRule(_ id: UUID) throws -> LearnedRule? { try database.readOne("SELECT * FROM learned_rules WHERE id = ?", [.text(id.uuidString)]).flatMap(Self.rule) }
    func learnedRules(statuses: [LearningStatus]? = nil) throws -> [LearnedRule] {
        var sql = "SELECT * FROM learned_rules"; var p: [SQLValue] = []
        if let statuses, !statuses.isEmpty { sql += " WHERE status IN (\(statuses.map { _ in "?" }.joined(separator: ",")))"; p = statuses.map { .text($0.rawValue) } }
        return try database.read(sql + " ORDER BY created_at DESC", p).compactMap(Self.rule)
    }
    func ruleVersions(_ id: UUID) throws -> [(version: Int, definition: RuleDefinition, at: Date, reason: String?)] {
        try database.read("SELECT * FROM rule_versions WHERE rule_id = ? ORDER BY version", [.text(id.uuidString)]).compactMap { r in
            guard let d = Self.unljs(r.string("definition"), as: RuleDefinition.self), let at = r.date("at") else { return nil }
            return (r.int("version") ?? 0, d, at, r.string("reason"))
        }
    }

    // MARK: Skills

    func save(_ s: Skill, reason: String? = nil) throws {
        try database.write { ctx in
            let existing = try ctx.execute("SELECT version FROM skills WHERE id = ?", [.text(s.id.uuidString)]).first?.int("version")
            let def = Self.ljs(s)
            try ctx.execute("""
                INSERT INTO skills(id, name, description, scope_level, scope_key, version, status, definition, origin, success_count, failure_count, last_used_at, created_at, built_in) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, description = excluded.description, version = excluded.version, status = excluded.status, definition = excluded.definition,
                    success_count = excluded.success_count, failure_count = excluded.failure_count, last_used_at = excluded.last_used_at
                """, [.text(s.id.uuidString), .text(Self.lclean(s.name, 80) ?? ""), .text(Self.lclean(s.description, 300) ?? ""), .text(s.scope.level.rawValue), .opt(s.scope.key), .int(Int64(s.version)),
                      .text(s.status.rawValue), .text(def), .text(Self.lclean(s.origin, 200) ?? ""), .int(Int64(s.successCount)), .int(Int64(s.failureCount)), .opt(s.lastUsedAt), .date(s.createdAt), .bool(s.builtIn)])
            if existing != s.version {
                try ctx.execute("INSERT INTO skill_versions(id, skill_id, version, definition, at, reason) VALUES (?,?,?,?,?,?)",
                                [.text(UUID().uuidString), .text(s.id.uuidString), .int(Int64(s.version)), .text(def), .date(Date()), .opt(Self.lclean(reason, 200))])
            }
        }
    }
    func skill(_ id: UUID) throws -> Skill? { try database.readOne("SELECT definition FROM skills WHERE id = ?", [.text(id.uuidString)]).flatMap { Self.unljs($0.string("definition"), as: Skill.self) } }
    func skills(statuses: [SkillStatus]? = nil) throws -> [Skill] {
        var sql = "SELECT definition FROM skills"; var p: [SQLValue] = []
        if let statuses, !statuses.isEmpty { sql += " WHERE status IN (\(statuses.map { _ in "?" }.joined(separator: ",")))"; p = statuses.map { .text($0.rawValue) } }
        return try database.read(sql + " ORDER BY created_at DESC", p).compactMap { Self.unljs($0.string("definition"), as: Skill.self) }
    }
    func skillVersions(_ id: UUID) throws -> Int { try database.readOne("SELECT COUNT(*) AS n FROM skill_versions WHERE skill_id = ?", [.text(id.uuidString)])?.int("n") ?? 0 }

    // MARK: Improvement proposals

    func save(_ p: ImprovementProposal) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO improvement_proposals(id, candidate_id, title, draft, status, checkpoint, task_id, result, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET status = excluded.status, checkpoint = excluded.checkpoint, task_id = excluded.task_id, result = excluded.result, updated_at = excluded.updated_at
                """, [.text(p.id.uuidString), .opt(p.candidateID?.uuidString), .text(Self.lclean(p.title, 160) ?? ""), .text(Self.ljs(p.draft)), .text(p.status.rawValue), .opt(p.checkpoint.map { Self.ljs($0) }),
                      .opt(p.taskID?.uuidString), .opt(Self.lclean(p.result, 600)), .date(p.createdAt), .date(p.updatedAt)])
        }
    }
    private static func proposal(_ r: SQLRow) -> ImprovementProposal? {
        guard let id = luid(r.string("id")), let draft = unljs(r.string("draft"), as: ImprovementDraft.self), let status = r.string("status").flatMap(ImprovementStatus.init(rawValue:)),
              let created = r.date("created_at") else { return nil }
        return ImprovementProposal(id: id, candidateID: luid(r.string("candidate_id")), title: r.string("title") ?? "", draft: draft, status: status, checkpoint: unljs(r.string("checkpoint"), as: SelfChangeCheckpoint.self),
                                   taskID: luid(r.string("task_id")), result: r.string("result"), createdAt: created, updatedAt: r.date("updated_at") ?? created)
    }
    func improvementProposal(_ id: UUID) throws -> ImprovementProposal? { try database.readOne("SELECT * FROM improvement_proposals WHERE id = ?", [.text(id.uuidString)]).flatMap(Self.proposal) }
    func improvementProposals(limit: Int = 50) throws -> [ImprovementProposal] { try database.read("SELECT * FROM improvement_proposals ORDER BY updated_at DESC LIMIT ?", [.int(Int64(limit))]).compactMap(Self.proposal) }

    // MARK: Requests (the approval boundary)

    func save(_ q: AdaptiveRequest) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO adaptive_requests(id, kind, subject_id, scope_hash, summary, detail, risk, status, requested_at, decided_at, decided_by, executed_at, result) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET status = excluded.status, decided_at = excluded.decided_at, decided_by = excluded.decided_by, executed_at = excluded.executed_at, result = excluded.result
                """, [.text(q.id.uuidString), .text(q.kind.rawValue), .text(String(q.subjectID.prefix(120))), .text(q.scopeHash), .text(Self.lclean(q.summary, 240) ?? ""), .opt(Self.lclean(q.detail, 800)),
                      .text(q.risk.rawValue), .text(q.status.rawValue), .date(q.requestedAt), .opt(q.decidedAt), .opt(q.decidedBy), .opt(q.executedAt), .opt(Self.lclean(q.result, 400))])
        }
    }
    private static func request(_ r: SQLRow) -> AdaptiveRequest? {
        guard let id = luid(r.string("id")), let kind = r.string("kind").flatMap(AdaptiveRequestKind.init(rawValue:)), let status = r.string("status").flatMap(AdaptiveRequestStatus.init(rawValue:)),
              let at = r.date("requested_at") else { return nil }
        return AdaptiveRequest(id: id, kind: kind, subjectID: r.string("subject_id") ?? "", scopeHash: r.string("scope_hash") ?? "", summary: r.string("summary") ?? "", detail: r.string("detail") ?? "",
                               risk: r.string("risk").flatMap(RiskClass.init(rawValue:)) ?? .medium, status: status, requestedAt: at, decidedAt: r.date("decided_at"), decidedBy: r.string("decided_by"),
                               executedAt: r.date("executed_at"), result: r.string("result"))
    }
    func adaptiveRequest(_ id: UUID) throws -> AdaptiveRequest? { try database.readOne("SELECT * FROM adaptive_requests WHERE id = ?", [.text(id.uuidString)]).flatMap(Self.request) }
    func adaptiveRequests(statuses: [AdaptiveRequestStatus]? = nil, limit: Int = 100) throws -> [AdaptiveRequest] {
        var sql = "SELECT * FROM adaptive_requests"; var p: [SQLValue] = []
        if let statuses, !statuses.isEmpty { sql += " WHERE status IN (\(statuses.map { _ in "?" }.joined(separator: ",")))"; p = statuses.map { .text($0.rawValue) } }
        sql += " ORDER BY requested_at DESC LIMIT ?"; p.append(.int(Int64(limit)))
        return try database.read(sql, p).compactMap(Self.request)
    }

    // MARK: Audit

    func addLearningAudit(_ a: LearningAuditEntry) throws {
        try database.write { ctx in
            try ctx.execute("INSERT INTO learning_audit(id, at, kind, subject_id, detail, by) VALUES (?,?,?,?,?,?)",
                            [.text(a.id.uuidString), .date(a.at), .text(String(a.kind.prefix(60))), .opt(a.subjectID), .opt(Self.lclean(a.detail, 500)), .text(String(a.by.prefix(60)))])
        }
    }
    func learningAudit(subjectID: String? = nil, limit: Int = 100) throws -> [LearningAuditEntry] {
        let rows = subjectID.map { try? database.read("SELECT * FROM learning_audit WHERE subject_id = ? ORDER BY at DESC LIMIT ?", [.text($0), .int(Int64(limit))]) } ?? (try? database.read("SELECT * FROM learning_audit ORDER BY at DESC LIMIT ?", [.int(Int64(limit))]))
        return (rows ?? []).compactMap { r in
            guard let id = Self.luid(r.string("id")), let at = r.date("at") else { return nil }
            return LearningAuditEntry(id: id, at: at, kind: r.string("kind") ?? "", subjectID: r.string("subject_id"), detail: r.string("detail") ?? "", by: r.string("by") ?? "")
        }
    }
}
