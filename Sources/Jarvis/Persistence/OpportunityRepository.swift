import Foundation

/// Durable storage of opportunities and proposals (schema v4). Text is bounded and sanitized on the way in; there is no column
/// for model reasoning. `proposals` is the user-facing card; `opportunities` carries the finding, its assessment and policy decision.
extension JarvisRepository {
    private static func enc<T: Encodable>(_ v: T) -> String { (try? String(data: JSONEncoder().encode(v), encoding: .utf8)) ?? "null" }
    private static func dec<T: Decodable>(_ s: String?, as: T.Type) -> T? { s.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
    private static func id(_ s: String?) -> UUID? { s.flatMap(UUID.init(uuidString:)) }
    private static func safe(_ s: String?, _ max: Int) -> String? { s.map { OutputSanitizer.sanitize(String($0.prefix(max))) } }

    // MARK: Opportunities

    func insert(_ o: OpportunityRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO opportunities(id, project_root, origin, origin_task_id, origin_step_id, origin_run_id, title, summary, category, evidence, affected_scope,
                    assessment, risk, design_impact, reversibility, destructiveness, external_effects, required_capabilities, confidence, relation, evidence_strength,
                    policy_decision, policy_reasons, status, created_at, updated_at, expires_at, dedup_key, related_opportunity_id, occurrences, cooldown_until,
                    autonomy_depth, proposed_action, action_hash, task_id, source_event)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, Self.oppParams(o))
        }
    }

    func update(_ o: OpportunityRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                UPDATE opportunities SET project_root=?2, origin=?3, origin_task_id=?4, origin_step_id=?5, origin_run_id=?6, title=?7, summary=?8, category=?9, evidence=?10,
                    affected_scope=?11, assessment=?12, risk=?13, design_impact=?14, reversibility=?15, destructiveness=?16, external_effects=?17, required_capabilities=?18,
                    confidence=?19, relation=?20, evidence_strength=?21, policy_decision=?22, policy_reasons=?23, status=?24, created_at=?25, updated_at=?26, expires_at=?27,
                    dedup_key=?28, related_opportunity_id=?29, occurrences=?30, cooldown_until=?31, autonomy_depth=?32, proposed_action=?33, action_hash=?34, task_id=?35,
                    source_event=?36 WHERE id = ?1
                """, Self.oppParams(o))
        }
    }

    private static func oppParams(_ o: OpportunityRecord) -> [SQLValue] {
        let a = o.assessment
        return [.text(o.id.uuidString), .text(o.projectRoot), .text(o.origin.rawValue), .opt(o.originTaskID?.uuidString), .opt(o.originStepID?.uuidString), .opt(o.originRunID?.uuidString),
                .text(safe(o.title, 200) ?? ""), .opt(safe(o.summary, 800)), .text(o.category.rawValue), .text(enc(Array(o.evidence.prefix(12)))), .text(enc(o.affectedScope.prefix(20).map { $0 })),
                .opt(a.map { enc($0) }), .opt(a?.risk.rawValue), .opt(a?.designImpact.rawValue), .opt(a?.reversibility.rawValue), .opt(a?.destructiveness.rawValue),
                .opt(a.map { enc($0.externalEffects.map(\.rawValue).sorted()) }), .opt(a.map { enc($0.requiredCapabilities.map(\.rawValue).sorted()) }), .opt(a?.confidence),
                .opt(a?.relation.rawValue), .opt(a.map { String($0.evidenceStrength.rawValue) }), .opt(o.policyDecision?.rawValue), .text(enc(o.policyReasons.prefix(16).map { String($0.prefix(80)) })),
                .text(o.status.rawValue), .date(o.createdAt), .date(o.updatedAt), .opt(o.expiresAt), .text(o.dedupKey), .opt(o.relatedOpportunityID?.uuidString), .int(Int64(o.occurrences)),
                .opt(o.cooldownUntil), .int(Int64(o.autonomyDepth)), .opt(o.proposedAction.map { enc($0) }), .opt(o.actionHash), .opt(o.taskID?.uuidString), .opt(o.sourceEvent)]
    }

    private static func opp(_ r: SQLRow) -> OpportunityRecord? {
        guard let oid = id(r.string("id")), let root = r.string("project_root"), let origin = r.string("origin").flatMap(OpportunityOrigin.init(rawValue:)),
              let title = r.string("title"), let cat = r.string("category").flatMap(OpportunityCategory.init(rawValue:)),
              let status = r.string("status").flatMap(OpportunityStatus.init(rawValue:)), let created = r.date("created_at"), let key = r.string("dedup_key") else { return nil }
        var o = OpportunityRecord(id: oid, projectRoot: root, origin: origin, originTaskID: id(r.string("origin_task_id")), originStepID: id(r.string("origin_step_id")), originRunID: id(r.string("origin_run_id")),
                                  title: title, summary: r.string("summary") ?? "", category: cat, evidence: dec(r.string("evidence"), as: [EvidenceItem].self) ?? [],
                                  affectedScope: dec(r.string("affected_scope"), as: [String].self) ?? [], assessment: dec(r.string("assessment"), as: OpportunityAssessment.self),
                                  policyDecision: r.string("policy_decision").flatMap(PolicyDecision.init(rawValue:)), dedupKey: key)
        o.policyReasons = dec(r.string("policy_reasons"), as: [String].self) ?? []
        o.status = status; o.createdAt = created; o.updatedAt = r.date("updated_at") ?? created; o.expiresAt = r.date("expires_at")
        o.relatedOpportunityID = id(r.string("related_opportunity_id")); o.occurrences = r.int("occurrences") ?? 1; o.cooldownUntil = r.date("cooldown_until")
        o.autonomyDepth = r.int("autonomy_depth") ?? 0; o.proposedAction = dec(r.string("proposed_action"), as: ProposedAction.self); o.actionHash = r.string("action_hash")
        o.taskID = id(r.string("task_id")); o.sourceEvent = r.string("source_event")
        return o
    }

    func opportunity(_ oid: UUID) throws -> OpportunityRecord? {
        try database.readOne("SELECT * FROM opportunities WHERE id = ?", [.text(oid.uuidString)]).flatMap(Self.opp)
    }

    func opportunity(sourceEvent: String) throws -> OpportunityRecord? {
        try database.readOne("SELECT * FROM opportunities WHERE source_event = ?", [.text(sourceEvent)]).flatMap(Self.opp)
    }

    func opportunities(project: String? = nil, statuses: [OpportunityStatus]? = nil, limit: Int = 100) throws -> [OpportunityRecord] {
        var sql = "SELECT * FROM opportunities WHERE 1=1"; var p: [SQLValue] = []
        if let project { sql += " AND project_root = ?"; p.append(.text(project)) }
        if let statuses, !statuses.isEmpty { sql += " AND status IN (" + statuses.map { _ in "?" }.joined(separator: ",") + ")"; p += statuses.map { .text($0.rawValue) } }
        sql += " ORDER BY updated_at DESC LIMIT ?"; p.append(.int(Int64(limit)))
        return try database.read(sql, p).compactMap(Self.opp)
    }

    /// Candidates for deduplication: open ones, and closed ones whose cooldown has not elapsed.
    func dedupCandidates(project: String, now: Date = Date()) throws -> [OpportunityRecord] {
        try database.read("""
            SELECT * FROM opportunities WHERE project_root = ? AND (status IN ('detected','recorded','proposed','autoQueued','approved','needsReapproval','taskCreated')
                OR (cooldown_until IS NOT NULL AND cooldown_until > ?)) ORDER BY updated_at DESC LIMIT 300
            """, [.text(project), .date(now)]).compactMap(Self.opp)
    }

    /// Automatic actions already authorised for one originating task (the budget counter).
    func autoActionCount(originTaskID: UUID) throws -> Int {
        try database.readOne("SELECT count(*) AS n FROM opportunities WHERE origin_task_id = ? AND policy_decision = 'autoAction' AND status IN ('autoQueued','taskCreated')",
                             [.text(originTaskID.uuidString)])?.int("n") ?? 0
    }

    // MARK: Proposals

    func insert(_ p: ProposalRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO proposals(id, task_id, kind, title, body, status, created_at, decided_at, opportunity_id, project_root, reason, evidence, proposed_action, affected_scope,
                    risk, design_impact, reversibility, expected_benefit, validation_plan, action_hash, resulting_task_id, expires_at, critical)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, Self.propParams(p))
        }
    }

    func update(_ p: ProposalRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                UPDATE proposals SET task_id=?2, kind=?3, title=?4, body=?5, status=?6, created_at=?7, decided_at=?8, opportunity_id=?9, project_root=?10, reason=?11, evidence=?12,
                    proposed_action=?13, affected_scope=?14, risk=?15, design_impact=?16, reversibility=?17, expected_benefit=?18, validation_plan=?19, action_hash=?20,
                    resulting_task_id=?21, expires_at=?22, critical=?23 WHERE id = ?1
                """, Self.propParams(p))
        }
    }

    private static func propParams(_ p: ProposalRecord) -> [SQLValue] {
        [.text(p.id.uuidString), .null, .text(p.critical ? "critical-proposal" : "proposal"), .text(safe(p.title, 200) ?? ""), .opt(safe(p.summary, 800)), .text(p.status.rawValue), .date(p.createdAt), .opt(p.decidedAt),
         .text(p.opportunityID.uuidString), .text(p.projectRoot), .opt(safe(p.reason, 600)), .opt(safe(p.evidence, 1200)), .text(enc(p.proposedAction)), .text(enc(p.affectedScope.prefix(20).map { $0 })),
         .text(p.risk.rawValue), .text(p.designImpact.rawValue), .text(p.reversibility.rawValue), .opt(safe(p.expectedBenefit, 400)), .opt(safe(p.validationPlan, 400)), .text(p.actionHash),
         .opt(p.resultingTaskID?.uuidString), .opt(p.expiresAt), .int(p.critical ? 1 : 0)]
    }

    private static func prop(_ r: SQLRow) -> ProposalRecord? {
        guard let pid = id(r.string("id")), let oid = id(r.string("opportunity_id")), let root = r.string("project_root"), let action = dec(r.string("proposed_action"), as: ProposedAction.self),
              let status = r.string("status").flatMap(ProposalStatus.init(rawValue:)), let created = r.date("created_at"), let hash = r.string("action_hash") else { return nil }
        var p = ProposalRecord(id: pid, opportunityID: oid, projectRoot: root, title: r.string("title") ?? "", summary: r.string("body") ?? "", reason: r.string("reason") ?? "",
                               evidence: r.string("evidence") ?? "", proposedAction: action, affectedScope: dec(r.string("affected_scope"), as: [String].self) ?? [],
                               risk: r.string("risk").flatMap(RiskClass.init(rawValue:)) ?? .low, designImpact: r.string("design_impact").flatMap(DesignImpact.init(rawValue:)) ?? .none,
                               reversibility: r.string("reversibility").flatMap(Reversibility.init(rawValue:)) ?? .reversible, expectedBenefit: r.string("expected_benefit") ?? "",
                               validationPlan: r.string("validation_plan") ?? "", actionHash: hash, critical: r.bool("critical"))
        p.status = status; p.createdAt = created; p.decidedAt = r.date("decided_at"); p.resultingTaskID = id(r.string("resulting_task_id")); p.expiresAt = r.date("expires_at")
        return p
    }

    func proposal(_ pid: UUID) throws -> ProposalRecord? {
        try database.readOne("SELECT * FROM proposals WHERE id = ? AND opportunity_id IS NOT NULL", [.text(pid.uuidString)]).flatMap(Self.prop)
    }

    func proposal(forOpportunity oid: UUID) throws -> ProposalRecord? {
        try database.readOne("SELECT * FROM proposals WHERE opportunity_id = ? ORDER BY created_at DESC LIMIT 1", [.text(oid.uuidString)]).flatMap(Self.prop)
    }

    func proposals(forOpportunity oid: UUID) throws -> [ProposalRecord] {
        try database.read("SELECT * FROM proposals WHERE opportunity_id = ? ORDER BY created_at", [.text(oid.uuidString)]).compactMap(Self.prop)
    }

    func proposals(statuses: [ProposalStatus]? = nil, limit: Int = 100) throws -> [ProposalRecord] {
        var sql = "SELECT * FROM proposals WHERE opportunity_id IS NOT NULL"; var p: [SQLValue] = []
        if let statuses, !statuses.isEmpty { sql += " AND status IN (" + statuses.map { _ in "?" }.joined(separator: ",") + ")"; p += statuses.map { .text($0.rawValue) } }
        sql += " ORDER BY created_at DESC LIMIT ?"; p.append(.int(Int64(limit)))
        return try database.read(sql, p).compactMap(Self.prop)
    }

    /// Proposal approvals (kind "proposal"): at most one decision per proposal, bound to its action hash.
    func proposalApproval(_ pid: UUID) throws -> ApprovalRecord? {
        try database.readOne("SELECT * FROM approvals WHERE proposal_id = ? ORDER BY requested_at DESC LIMIT 1", [.text(pid.uuidString)]).flatMap { r in
            guard let aid = Self.id(r.string("id")), let tid = Self.id(r.string("task_id")), let st = r.string("status").flatMap(ApprovalState.init(rawValue:)), let at = r.date("requested_at") else { return nil }
            var a = ApprovalRecord(id: aid, taskID: tid, stepID: nil, action: r.string("action") ?? "", reason: r.string("reason") ?? "", risk: r.string("risk").flatMap(RiskClass.init(rawValue:)) ?? .low)
            a.state = st; a.requestedAt = at; a.decidedAt = r.date("decided_at"); a.decidedBy = r.string("decided_by"); a.kind = r.string("kind") ?? "proposal"
            a.proposalID = Self.id(r.string("proposal_id")); a.scopeHash = r.string("scope_hash")
            return a
        }
    }
}
