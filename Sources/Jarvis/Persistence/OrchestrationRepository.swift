import Foundation

// MARK: - Orchestration records (V0.12, schema v10)
//
// What survives a restart: the graph header, structural revisions, typed artifacts (sanitized and bounded on the way in) and one routing decision per node execution.
// There is no column for a provider conversation, for hidden reasoning, for a page body or for a secret. Everything free-text is sanitized and truncated before it is bound.

struct TaskGraphRecord: Equatable, Sendable {
    var taskID: UUID
    var template: String               // "fix-flow", "investigation", "asset-suitability", "run-tests", "model-planned", "single-…"
    var planner: String                // "deterministic" | "model"
    var rationale: String?
    var nodeCount: Int
    var revisions: Int
    var plannerChars: Int?
    var plannerMS: Double?
    var createdAt = Date()
}

struct GraphRevisionRecord: Equatable, Sendable, Identifiable {
    var id = UUID()
    var taskID: UUID
    var n: Int
    var reason: String
    var added: [String]
    var at = Date()
}

struct RoutingDecisionRecord: Equatable, Sendable, Identifiable {
    var id = UUID()
    var taskID: UUID
    var nodeKey: String?
    var role: AgentRole?                // nil = the orchestrator's own planner call
    var agentRunID: UUID?
    var engine: String?
    var model: String?
    var mode: String?
    var reasonText: String
    var reasonJSON: String?
    var independence: String?
    var escalationReason: String?
    var failureClass: String?
    var outcome: String?
    var contextChars: Int?
    var memoryItems: Int?
    var artifactCount: Int?
    var fileCount: Int?
    var handoffChars: Int?
    var queueMS: Double?
    var runMS: Double?
    var inputTokens: Int?
    var outputTokens: Int?
    var costClass: String?
    var createdAt = Date()
}

/// Aggregates for "which model succeeds most for coding / how often does free escalate / which role uses the most context" (no hidden reasoning, only recorded facts).
struct RoutingTelemetry: Equatable, Sendable {
    struct Row: Equatable, Sendable { var role: String; var engine: String; var model: String?; var runs: Int; var successes: Int; var avgRunMS: Double?; var avgContextChars: Double? }
    var rows: [Row]
    var escalations: Int
    var totalRuns: Int
}

extension JarvisRepository {
    private static func uid(_ s: String?) -> UUID? { s.flatMap(UUID.init(uuidString:)) }
    private static func clean(_ s: String?, _ max: Int) -> String? { s.map { OutputSanitizer.sanitize(String($0.prefix(max))) } }
    private static func js<T: Encodable>(_ v: T) -> String { (try? String(data: JSONEncoder().encode(v), encoding: .utf8)) ?? "[]" }
    private static func unjs<T: Decodable>(_ s: String?, as: T.Type) -> T? { s.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(T.self, from: $0) } }

    // MARK: Graph header + revisions

    func save(_ g: TaskGraphRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO task_graphs(task_id, template, planner, rationale, node_count, revisions, planner_chars, planner_ms, created_at) VALUES (?,?,?,?,?,?,?,?,?)
                ON CONFLICT(task_id) DO UPDATE SET template=excluded.template, planner=excluded.planner, rationale=excluded.rationale, node_count=excluded.node_count,
                    revisions=excluded.revisions, planner_chars=excluded.planner_chars, planner_ms=excluded.planner_ms
                """, [.text(g.taskID.uuidString), .text(Self.clean(g.template, 60) ?? ""), .text(g.planner), .opt(Self.clean(g.rationale, 400)), .int(Int64(g.nodeCount)),
                      .int(Int64(g.revisions)), .opt(g.plannerChars), .opt(g.plannerMS), .date(g.createdAt)])
        }
    }

    func taskGraph(_ taskID: UUID) throws -> TaskGraphRecord? {
        try database.readOne("SELECT * FROM task_graphs WHERE task_id = ?", [.text(taskID.uuidString)]).flatMap { r in
            guard let t = r.string("template"), let p = r.string("planner") else { return nil }
            return TaskGraphRecord(taskID: taskID, template: t, planner: p, rationale: r.string("rationale"), nodeCount: r.int("node_count") ?? 0, revisions: r.int("revisions") ?? 0,
                                   plannerChars: r.int("planner_chars"), plannerMS: r.double("planner_ms"), createdAt: r.date("created_at") ?? Date())
        }
    }

    func insert(_ r: GraphRevisionRecord) throws {
        try database.write { ctx in
            try ctx.execute("INSERT INTO graph_revisions(id, task_id, n, reason, added, at) VALUES (?,?,?,?,?,?)",
                            [.text(r.id.uuidString), .text(r.taskID.uuidString), .int(Int64(r.n)), .text(Self.clean(r.reason, 300) ?? ""), .text(Self.js(r.added)), .date(r.at)])
        }
    }

    func graphRevisions(taskID: UUID) throws -> [GraphRevisionRecord] {
        try database.read("SELECT * FROM graph_revisions WHERE task_id = ? ORDER BY n", [.text(taskID.uuidString)]).compactMap { r in
            guard let id = Self.uid(r.string("id")), let n = r.int("n"), let reason = r.string("reason") else { return nil }
            return GraphRevisionRecord(id: id, taskID: taskID, n: n, reason: reason, added: Self.unjs(r.string("added"), as: [String].self) ?? [], at: r.date("at") ?? Date())
        }
    }

    // MARK: Artifacts

    func insert(_ a: AgentArtifact) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO agent_artifacts(id, task_id, node_key, role, kind, trust, provider, model, agent_run_id, attempt, created_at, inputs, status, validation, content, content_hash, chars, injection_flags)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(a.id.uuidString), .text(a.taskID.uuidString), .text(a.nodeKey), .opt(a.role?.rawValue), .text(a.kind.rawValue), .text(a.trust.rawValue), .opt(a.provider), .opt(a.model),
                      .opt(a.agentRunID?.uuidString), .int(Int64(a.attempt)), .date(a.createdAt), .text(Self.js(a.inputs)), .text(a.status.rawValue), .opt(Self.clean(a.validation, 300)),
                      .text(OutputSanitizer.sanitize(String(a.content.prefix(OrchestrationLimits.maxArtifactChars)))), .text(a.contentHash), .int(Int64(a.chars)), .text(Self.js(a.injectionFlags))])
        }
    }

    func artifacts(taskID: UUID) throws -> [AgentArtifact] {
        try database.read("SELECT * FROM agent_artifacts WHERE task_id = ? ORDER BY created_at", [.text(taskID.uuidString)]).compactMap { r in
            guard let id = Self.uid(r.string("id")), let node = r.string("node_key"), let kind = r.string("kind").flatMap(ArtifactKind.init(rawValue:)),
                  let trust = r.string("trust").flatMap(AgentTrust.init(rawValue:)), let content = r.string("content") else { return nil }
            return AgentArtifact(id: id, taskID: taskID, nodeKey: node, role: r.string("role").flatMap(AgentRole.init(rawValue:)), kind: kind, trust: trust, provider: r.string("provider"), model: r.string("model"),
                                 agentRunID: Self.uid(r.string("agent_run_id")), attempt: r.int("attempt") ?? 1, createdAt: r.date("created_at") ?? Date(), inputs: Self.unjs(r.string("inputs"), as: [String].self) ?? [],
                                 status: r.string("status").flatMap(ArtifactStatus.init(rawValue:)) ?? .valid, validation: r.string("validation") ?? "", content: content,
                                 contentHash: r.string("content_hash") ?? "", injectionFlags: Self.unjs(r.string("injection_flags"), as: [String].self) ?? [])
        }
    }

    /// Marks the artifacts of the given nodes stale (their inputs changed, e.g. a code step was redone): a stale artifact never travels in a handoff.
    func markArtifactsStale(taskID: UUID, nodeKeys: [String]) throws {
        guard !nodeKeys.isEmpty else { return }
        try database.write { ctx in
            for k in nodeKeys {
                try ctx.execute("UPDATE agent_artifacts SET status = 'stale' WHERE task_id = ? AND node_key = ? AND status = 'valid'", [.text(taskID.uuidString), .text(k)])
            }
        }
    }

    // MARK: Routing decisions

    func insert(_ d: RoutingDecisionRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO routing_decisions(id, task_id, node_key, role, agent_run_id, engine, model, mode, reason_text, reason_json, independence, escalation_reason, failure_class, outcome,
                    context_chars, memory_items, artifact_count, file_count, handoff_chars, queue_ms, run_ms, input_tokens, output_tokens, cost_class, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(d.id.uuidString), .text(d.taskID.uuidString), .opt(d.nodeKey), .opt(d.role?.rawValue), .opt(d.agentRunID?.uuidString), .opt(d.engine), .opt(d.model), .opt(d.mode),
                      .text(Self.clean(d.reasonText, 600) ?? ""), .opt(Self.clean(d.reasonJSON, 1500)), .opt(d.independence), .opt(d.escalationReason), .opt(d.failureClass), .opt(d.outcome),
                      .opt(d.contextChars), .opt(d.memoryItems), .opt(d.artifactCount), .opt(d.fileCount), .opt(d.handoffChars), .opt(d.queueMS), .opt(d.runMS), .opt(d.inputTokens), .opt(d.outputTokens),
                      .opt(d.costClass), .date(d.createdAt)])
        }
    }

    func routingDecisions(taskID: UUID) throws -> [RoutingDecisionRecord] {
        try database.read("SELECT * FROM routing_decisions WHERE task_id = ? ORDER BY created_at", [.text(taskID.uuidString)]).compactMap { r in
            guard let id = Self.uid(r.string("id")), let text = r.string("reason_text") else { return nil }
            let role = r.string("role").flatMap(AgentRole.init(rawValue:))
            var d = RoutingDecisionRecord(id: id, taskID: taskID, nodeKey: r.string("node_key"), role: role, agentRunID: Self.uid(r.string("agent_run_id")), engine: r.string("engine"), model: r.string("model"),
                                          mode: r.string("mode"), reasonText: text, reasonJSON: r.string("reason_json"), independence: r.string("independence"), escalationReason: r.string("escalation_reason"),
                                          failureClass: r.string("failure_class"), outcome: r.string("outcome"), contextChars: r.int("context_chars"), memoryItems: r.int("memory_items"),
                                          artifactCount: r.int("artifact_count"), fileCount: r.int("file_count"), handoffChars: r.int("handoff_chars"), queueMS: r.double("queue_ms"), runMS: r.double("run_ms"),
                                          inputTokens: r.int("input_tokens"), outputTokens: r.int("output_tokens"), costClass: r.string("cost_class"))
            d.createdAt = r.date("created_at") ?? Date()
            return d
        }
    }

    /// Which model succeeds most for each role, how long it takes, how big its context is, how often a run was an escalation. Recorded facts only.
    func routingTelemetry(role: AgentRole? = nil) throws -> RoutingTelemetry {
        var sql = """
            SELECT role, engine, model, COUNT(*) AS runs, SUM(CASE WHEN outcome = 'passed' THEN 1 ELSE 0 END) AS ok, AVG(run_ms) AS avg_ms, AVG(context_chars) AS avg_ctx
            FROM routing_decisions WHERE engine IS NOT NULL
            """
        var p: [SQLValue] = []
        if let role { sql += " AND role = ?"; p.append(.text(role.rawValue)) }
        sql += " GROUP BY role, engine, model ORDER BY role, ok DESC, runs DESC"
        let rows = try database.read(sql, p).compactMap { r -> RoutingTelemetry.Row? in
            guard let e = r.string("engine") else { return nil }
            let ro = r.string("role") ?? "planner"
            return .init(role: ro, engine: e, model: r.string("model"), runs: r.int("runs") ?? 0, successes: r.int("ok") ?? 0, avgRunMS: r.double("avg_ms"), avgContextChars: r.double("avg_ctx"))
        }
        let esc = try database.readOne("SELECT COUNT(*) AS n FROM routing_decisions WHERE escalation_reason IS NOT NULL", [])?.int("n") ?? 0
        let total = try database.readOne("SELECT COUNT(*) AS n FROM routing_decisions", [])?.int("n") ?? 0
        return RoutingTelemetry(rows: rows, escalations: esc, totalRuns: total)
    }

    // MARK: Children + cleanup

    func childTasks(of parent: UUID) throws -> [TaskRecord] {
        try database.read("SELECT id FROM tasks WHERE parent_task_id = ? ORDER BY created_at", [.text(parent.uuidString)]).compactMap { Self.uid($0.string("id")) }.compactMap { try engineTask($0) }
    }

    /// Cleanup policy (DEC-176): artifacts, routing rows and graph rows of tasks older than the newest `keepTasks` finished tasks fall away; the tasks, steps, attempts, approvals,
    /// reports and agent runs themselves are history and stay. Unfinished tasks are never touched.
    @discardableResult
    func pruneOrchestration(keepTasks: Int = 150) throws -> Int {
        let old = try database.read("""
            SELECT id FROM tasks WHERE kind IS NOT NULL AND status IN ('completed','failed','cancelled') ORDER BY created_at DESC LIMIT -1 OFFSET ?
            """, [.int(Int64(keepTasks))]).compactMap { $0.string("id") }
        guard !old.isEmpty else { return 0 }
        try database.write { ctx in
            for id in old {
                for table in ["agent_artifacts", "routing_decisions", "graph_revisions"] { try ctx.execute("DELETE FROM \(table) WHERE task_id = ?", [.text(id)]) }
                try ctx.execute("DELETE FROM task_graphs WHERE task_id = ?", [.text(id)])
            }
        }
        return old.count
    }
}

extension JarvisRepository {
    /// Models that have any recorded benchmark result (for the developer role table).
    func benchmarkedModelIDs() throws -> [String] {
        try database.read("SELECT DISTINCT model_id FROM model_benchmarks WHERE suite = ? ORDER BY model_id", [.text(RoleScoreboard.suiteID)]).compactMap { $0.string("model_id") }
    }
}
