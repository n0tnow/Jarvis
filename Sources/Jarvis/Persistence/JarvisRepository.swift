import Foundation

/// Typed access to the operational database. All JSON columns are small lists/maps; big content goes to `ArtifactStore`.
final class JarvisRepository: @unchecked Sendable {
    let database: JarvisDatabase
    init(database: JarvisDatabase) { self.database = database }

    // MARK: JSON helpers

    private static func json<T: Encodable>(_ v: T) -> String {
        (try? String(data: JSONEncoder().encode(v), encoding: .utf8)) ?? "null"
    }
    private static func decode<T: Decodable>(_ s: String?, as: T.Type) -> T? {
        guard let s, let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
    private static func uuid(_ s: String?) -> UUID? { s.flatMap(UUID.init(uuidString:)) }

    // MARK: Model registry

    func upsert(_ m: ModelRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO model_registry(id, engine, provider, provider_model_id, display_name, availability, pricing_status,
                    input_price, output_price, free_verified, free_verified_at, free_verification_source, capabilities, data_policy,
                    context_limit, benchmark_status, last_health_check, last_successful_run, enabled, blocked_reason, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                    engine=excluded.engine, provider=excluded.provider, provider_model_id=excluded.provider_model_id,
                    display_name=excluded.display_name, availability=excluded.availability, pricing_status=excluded.pricing_status,
                    input_price=excluded.input_price, output_price=excluded.output_price, free_verified=excluded.free_verified,
                    free_verified_at=excluded.free_verified_at, free_verification_source=excluded.free_verification_source,
                    capabilities=excluded.capabilities, data_policy=excluded.data_policy, context_limit=excluded.context_limit,
                    benchmark_status=excluded.benchmark_status, last_health_check=excluded.last_health_check,
                    last_successful_run=excluded.last_successful_run, enabled=excluded.enabled,
                    blocked_reason=excluded.blocked_reason, updated_at=excluded.updated_at
                """, [.text(m.id), .text(m.engine.rawValue), .text(m.provider), .text(m.providerModelID), .text(m.displayName),
                      .text(m.availability.rawValue), .text(m.pricingStatus.rawValue), .opt(m.inputPrice), .opt(m.outputPrice),
                      .bool(m.freeVerified), .opt(m.freeVerifiedAt), .opt(m.freeVerificationSource),
                      .text(Self.json(m.capabilities)), .text(m.dataPolicy.rawValue), .opt(m.contextLimit),
                      .text(m.benchmarkStatus.rawValue), .opt(m.lastHealthCheck), .opt(m.lastSuccessfulRun),
                      .bool(m.enabled), .opt(m.blockedReason), .date(m.updatedAt)])
        }
    }

    func model(_ id: String) throws -> ModelRecord? {
        try database.readOne("SELECT * FROM model_registry WHERE id = ?", [.text(id)]).flatMap(Self.model)
    }

    func models(engine: ProviderID? = nil) throws -> [ModelRecord] {
        let rows = engine == nil ? try database.read("SELECT * FROM model_registry ORDER BY id")
                                 : try database.read("SELECT * FROM model_registry WHERE engine = ? ORDER BY id", [.text(engine!.rawValue)])
        return rows.compactMap(Self.model)
    }

    func setModelEnabled(_ id: String, _ enabled: Bool, reason: String? = nil) throws {
        try database.write { ctx in
            try ctx.execute("UPDATE model_registry SET enabled = ?, blocked_reason = ?, updated_at = ? WHERE id = ?",
                            [.bool(enabled), .opt(enabled ? nil : reason), .date(Date()), .text(id)])
        }
    }

    func setBenchmarkStatus(_ id: String, _ status: BenchmarkStatus) throws {
        try database.write { ctx in
            try ctx.execute("UPDATE model_registry SET benchmark_status = ?, updated_at = ? WHERE id = ?",
                            [.text(status.rawValue), .date(Date()), .text(id)])
        }
    }

    func markModelRun(_ id: String, success: Bool, at: Date = Date()) throws {
        try database.write { ctx in
            try ctx.execute(success ? "UPDATE model_registry SET last_health_check = ?, last_successful_run = ? WHERE id = ?"
                                    : "UPDATE model_registry SET last_health_check = ?, last_successful_run = last_successful_run WHERE id = ?",
                            success ? [.date(at), .date(at), .text(id)] : [.date(at), .text(id)])
        }
    }

    private static func model(_ r: SQLRow) -> ModelRecord? {
        guard let id = r.string("id"), let engine = r.string("engine").flatMap(ProviderID.init(rawValue:)),
              let provider = r.string("provider"), let pmid = r.string("provider_model_id"), let name = r.string("display_name") else { return nil }
        var m = ModelRecord(id: id, engine: engine, provider: provider, providerModelID: pmid, displayName: name)
        m.availability = r.string("availability").flatMap(ModelAvailability.init(rawValue:)) ?? .unknown
        m.pricingStatus = r.string("pricing_status").flatMap(PricingStatus.init(rawValue:)) ?? .unknown
        m.inputPrice = r.double("input_price"); m.outputPrice = r.double("output_price")
        m.freeVerified = r.bool("free_verified"); m.freeVerifiedAt = r.date("free_verified_at")
        m.freeVerificationSource = r.string("free_verification_source")
        m.capabilities = decode(r.string("capabilities"), as: ModelCapabilities.self) ?? ModelCapabilities()
        m.dataPolicy = r.string("data_policy").flatMap(DataPolicy.init(rawValue:)) ?? .unknown
        m.contextLimit = r.int("context_limit")
        m.benchmarkStatus = r.string("benchmark_status").flatMap(BenchmarkStatus.init(rawValue:)) ?? .none
        m.lastHealthCheck = r.date("last_health_check"); m.lastSuccessfulRun = r.date("last_successful_run")
        m.enabled = r.bool("enabled"); m.blockedReason = r.string("blocked_reason"); m.updatedAt = r.date("updated_at") ?? Date()
        return m
    }

    // MARK: Benchmarks

    func add(_ b: BenchmarkResultRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO model_benchmarks(model_id, suite, case_id, category, passed, validation, latency_ms, duration_ms,
                    retries, malformed, cancelled, ran_at, artifact_id) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(b.modelID), .text(b.suite), .text(b.caseID), .text(b.category.rawValue), .bool(b.passed), .opt(b.validation),
                      .opt(b.latencyMS), .opt(b.durationMS), .int(Int64(b.retries)), .bool(b.malformed), .bool(b.cancelled),
                      .date(b.ranAt), .opt(b.artifactID?.uuidString)])
        }
    }

    func benchmarks(modelID: String, group: BenchmarkGroup? = nil) throws -> [BenchmarkResultRecord] {
        var sql = "SELECT * FROM model_benchmarks WHERE model_id = ?"; var p: [SQLValue] = [.text(modelID)]
        if let group { sql += " AND category = ?"; p.append(.text(group.rawValue)) }
        return try database.read(sql + " ORDER BY ran_at, id", p).compactMap { r in
            guard let model = r.string("model_id"), let suite = r.string("suite"), let c = r.string("case_id"),
                  let cat = r.string("category").flatMap(BenchmarkGroup.init(rawValue:)) else { return nil }
            return BenchmarkResultRecord(modelID: model, suite: suite, caseID: c, category: cat, passed: r.bool("passed"),
                                         validation: r.string("validation"), latencyMS: r.double("latency_ms"),
                                         durationMS: r.double("duration_ms"), retries: r.int("retries") ?? 0,
                                         malformed: r.bool("malformed"), cancelled: r.bool("cancelled"),
                                         ranAt: r.date("ran_at") ?? Date(), artifactID: Self.uuid(r.string("artifact_id")))
        }
    }

    // MARK: Agent runs (audit trail)

    func insert(_ run: AgentRunRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO agent_runs(id, task_id, parent_agent_run_id, agent_type, engine, model, cost_class, selection_reason, privacy,
                    started_at, finished_at, status, tools_used, files_read, files_changed, validation_status, result_summary,
                    retry_count, escalated_from, escalated_to, error_category, prompt_hash, prompt_chars, input_tokens, output_tokens,
                    label, progress_source, steps_total, steps_done, progress_fraction, activity)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, Self.params(run))
        }
    }

    func update(_ run: AgentRunRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                UPDATE agent_runs SET task_id=?2, parent_agent_run_id=?3, agent_type=?4, engine=?5, model=?6, cost_class=?7,
                    selection_reason=?8, privacy=?9, started_at=?10, finished_at=?11, status=?12, tools_used=?13, files_read=?14,
                    files_changed=?15, validation_status=?16, result_summary=?17, retry_count=?18, escalated_from=?19,
                    escalated_to=?20, error_category=?21, prompt_hash=?22, prompt_chars=?23, input_tokens=?24, output_tokens=?25,
                    label=?26, progress_source=?27, steps_total=?28, steps_done=?29, progress_fraction=?30, activity=?31
                WHERE id = ?1
                """, Self.params(run))
        }
    }

    private static func params(_ r: AgentRunRecord) -> [SQLValue] {
        [.text(r.id.uuidString), .opt(r.taskID?.uuidString), .opt(r.parentAgentRunID?.uuidString), .text(r.agentType),
         .text(r.engine.rawValue), .opt(r.model), .text(r.costClass.rawValue), .opt(r.selectionReason), .text(r.privacy.rawValue),
         .date(r.startedAt), .opt(r.finishedAt), .text(r.status.rawValue), .text(json(r.toolsUsed)), .text(json(r.filesRead)),
         .text(json(r.filesChanged)), .text(r.validationStatus.rawValue), .opt(r.resultSummary), .int(Int64(r.retryCount)),
         .opt(r.escalatedFrom), .opt(r.escalatedTo), .opt(r.errorCategory), .opt(r.promptHash), .opt(r.promptChars),
         .opt(r.inputTokens), .opt(r.outputTokens),
         .opt(r.label.map { OutputSanitizer.sanitize($0) }), .text(r.progressSource.rawValue), .opt(r.stepsTotal), .opt(r.stepsDone),
         .opt(r.progressFraction), .opt(r.activity.map { OutputSanitizer.sanitize($0) })]
    }

    func agentRun(_ id: UUID) throws -> AgentRunRecord? {
        try database.readOne("SELECT * FROM agent_runs WHERE id = ?", [.text(id.uuidString)]).flatMap(Self.run)
    }
    func agentRuns(taskID: UUID) throws -> [AgentRunRecord] {
        try database.read("SELECT * FROM agent_runs WHERE task_id = ? ORDER BY started_at", [.text(taskID.uuidString)]).compactMap(Self.run)
    }
    func children(of parent: UUID) throws -> [AgentRunRecord] {
        try database.read("SELECT * FROM agent_runs WHERE parent_agent_run_id = ? ORDER BY started_at", [.text(parent.uuidString)]).compactMap(Self.run)
    }
    func recentAgentRuns(limit: Int = 20) throws -> [AgentRunRecord] {
        try database.read("SELECT * FROM agent_runs ORDER BY started_at DESC LIMIT ?", [.int(Int64(limit))]).compactMap(Self.run)
    }
    /// Runs left `running`/`queued` by a previous process (crash / force quit): V0.4 will resume or fail them explicitly.
    func interruptedRuns() throws -> [AgentRunRecord] {
        try database.read("SELECT * FROM agent_runs WHERE status IN ('running','queued') ORDER BY started_at").compactMap(Self.run)
    }

    private static func run(_ r: SQLRow) -> AgentRunRecord? {
        guard let id = uuid(r.string("id")), let engine = r.string("engine").flatMap(ProviderID.init(rawValue:)),
              let type = r.string("agent_type"), let started = r.date("started_at"),
              let status = r.string("status").flatMap(AgentRunStatus.init(rawValue:)) else { return nil }
        var run = AgentRunRecord(id: id, taskID: uuid(r.string("task_id")), parentAgentRunID: uuid(r.string("parent_agent_run_id")),
                                 agentType: type, engine: engine, model: r.string("model"), startedAt: started)
        run.selectionReason = r.string("selection_reason")
        run.privacy = r.string("privacy").flatMap(PrivacyLevel.init(rawValue:)) ?? .normal
        run.finishedAt = r.date("finished_at"); run.status = status
        run.toolsUsed = decode(r.string("tools_used"), as: [String].self) ?? []
        run.filesRead = decode(r.string("files_read"), as: [String].self) ?? []
        run.filesChanged = decode(r.string("files_changed"), as: [String].self) ?? []
        run.validationStatus = r.string("validation_status").flatMap(ValidationStatus.init(rawValue:)) ?? .notRun
        run.resultSummary = r.string("result_summary"); run.retryCount = r.int("retry_count") ?? 0
        run.escalatedFrom = r.string("escalated_from"); run.escalatedTo = r.string("escalated_to")
        run.errorCategory = r.string("error_category"); run.promptHash = r.string("prompt_hash"); run.promptChars = r.int("prompt_chars")
        run.inputTokens = r.int("input_tokens"); run.outputTokens = r.int("output_tokens")
        run.label = r.string("label"); run.progressSource = r.string("progress_source").flatMap(ProgressSource.init(rawValue:)) ?? .unknown
        run.stepsTotal = r.int("steps_total"); run.stepsDone = r.int("steps_done"); run.progressFraction = r.double("progress_fraction")
        run.activity = r.string("activity")
        return run
    }

    // MARK: Filtered history (paginated — never "load everything")

    struct RunFilter: Equatable, Sendable {
        var engine: ProviderID?
        var statuses: [AgentRunStatus] = []
        var text: String?                 // matches label, agent type or model (case-insensitive substring)
        var since: Date?
        var until: Date?
    }

    func agentRuns(filter: RunFilter, limit: Int = 25, offset: Int = 0) throws -> [AgentRunRecord] {
        var sql = "SELECT * FROM agent_runs WHERE 1=1"; var p: [SQLValue] = []
        if let e = filter.engine { sql += " AND engine = ?"; p.append(.text(e.rawValue)) }
        if !filter.statuses.isEmpty { sql += " AND status IN (" + filter.statuses.map { _ in "?" }.joined(separator: ",") + ")"; p += filter.statuses.map { .text($0.rawValue) } }
        if let t = filter.text?.trimmingCharacters(in: .whitespaces), !t.isEmpty {
            sql += " AND (label LIKE ? ESCAPE '\\' OR agent_type LIKE ? ESCAPE '\\' OR model LIKE ? ESCAPE '\\')"
            let like = "%" + t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            p += [.text(like), .text(like), .text(like)]
        }
        if let s = filter.since { sql += " AND started_at >= ?"; p.append(.date(s)) }
        if let u = filter.until { sql += " AND started_at < ?"; p.append(.date(u)) }
        sql += " ORDER BY started_at DESC LIMIT ? OFFSET ?"; p += [.int(Int64(max(1, min(limit, 200)))), .int(Int64(max(0, offset)))]
        return try database.read(sql, p).compactMap(Self.run)
    }

    /// The most recent run of each engine (provider cards: "last result").
    func lastRunPerEngine() throws -> [ProviderID: AgentRunRecord] {
        var out: [ProviderID: AgentRunRecord] = [:]
        for e in ProviderID.allCases {
            if let r = try database.readOne("SELECT * FROM agent_runs WHERE engine = ? ORDER BY started_at DESC LIMIT 1", [.text(e.rawValue)]).flatMap(Self.run) { out[e] = r }
        }
        return out
    }

    /// Restart reconciliation: a run still recorded as running/queued can only belong to a previous JARVIS process that is gone.
    @discardableResult
    func markInterrupted(at now: Date = Date()) throws -> [UUID] {
        let stale = try interruptedRuns()
        guard !stale.isEmpty else { return [] }
        try database.write { ctx in
            try ctx.execute("""
                UPDATE agent_runs SET status = 'interrupted', finished_at = ?, error_category = COALESCE(error_category, 'interrupted'),
                    activity = 'Interrupted — JARVIS stopped before this run finished' WHERE status IN ('running','queued')
                """, [.date(now)])
        }
        return stale.map(\.id)
    }

    // MARK: Console events (sanitized text only)

    static let maxEventsPerRun = 5000

    func appendEvents(_ events: [AgentConsoleEvent]) throws {
        guard !events.isEmpty else { return }
        try database.write { ctx in
            for e in events {
                try ctx.execute("""
                    INSERT OR IGNORE INTO agent_events(run_id, seq, ts, kind, source, severity, summary, detail, artifact_id) VALUES (?,?,?,?,?,?,?,?,?)
                    """, [.text(e.runID.uuidString), .int(Int64(e.id)), .date(e.timestamp), .text(e.kind.rawValue), .text(e.source), .text(e.severity.rawValue),
                          .text(e.summary), .opt(e.detail), .opt(e.artifactID?.uuidString)])
            }
            if let run = events.first?.runID {
                try ctx.execute("DELETE FROM agent_events WHERE run_id = ? AND seq <= (SELECT max(seq) FROM agent_events WHERE run_id = ?) - ?",
                                [.text(run.uuidString), .text(run.uuidString), .int(Int64(Self.maxEventsPerRun))])
            }
        }
    }

    func events(runID: UUID, afterSeq: Int = 0, limit: Int = 500) throws -> [AgentConsoleEvent] {
        try database.read("SELECT * FROM agent_events WHERE run_id = ? AND seq > ? ORDER BY seq LIMIT ?",
                          [.text(runID.uuidString), .int(Int64(afterSeq)), .int(Int64(max(1, min(limit, 2000))))]).compactMap { r in
            guard let seq = r.int("seq"), let kind = r.string("kind").flatMap(ConsoleEventKind.init(rawValue:)), let src = r.string("source"), let sum = r.string("summary") else { return nil }
            return AgentConsoleEvent(id: seq, runID: runID, timestamp: r.date("ts") ?? Date(), kind: kind, source: src, summary: sum, detail: r.string("detail"),
                                     severity: r.string("severity").flatMap(EventSeverity.init(rawValue:)) ?? .info, artifactID: Self.uuid(r.string("artifact_id")))
        }
    }

    func eventCount(runID: UUID) throws -> Int {
        try database.readOne("SELECT count(*) AS n FROM agent_events WHERE run_id = ?", [.text(runID.uuidString)])?.int("n") ?? 0
    }

    /// Timeline across runs: key events only (no provider output lines), newest first.
    struct TimelineRow: Equatable, Sendable {
        var event: AgentConsoleEvent
        var agentType: String
        var engine: ProviderID
        var model: String?
        var label: String?
    }

    func recentTimeline(limit: Int = 60, excludingRuns: Set<UUID> = []) throws -> [TimelineRow] {
        try database.read("""
            SELECT e.*, r.agent_type AS a_type, r.engine AS a_engine, r.model AS a_model, r.label AS a_label
            FROM agent_events e JOIN agent_runs r ON r.id = e.run_id
            WHERE e.kind != 'providerOutput' ORDER BY e.ts DESC, e.seq DESC LIMIT ?
            """, [.int(Int64(max(1, min(limit * 2, 400))))]).compactMap { r -> TimelineRow? in
            guard let run = Self.uuid(r.string("run_id")), !excludingRuns.contains(run), let seq = r.int("seq"),
                  let kind = r.string("kind").flatMap(ConsoleEventKind.init(rawValue:)), let src = r.string("source"), let sum = r.string("summary"),
                  let engine = r.string("a_engine").flatMap(ProviderID.init(rawValue:)) else { return nil }
            let e = AgentConsoleEvent(id: seq, runID: run, timestamp: r.date("ts") ?? Date(), kind: kind, source: src, summary: sum, detail: r.string("detail"),
                                      severity: r.string("severity").flatMap(EventSeverity.init(rawValue:)) ?? .info)
            return TimelineRow(event: e, agentType: r.string("a_type") ?? "Agent", engine: engine, model: r.string("a_model"), label: r.string("a_label"))
        }.prefix(limit).map { $0 }
    }

    func pruneEvents(olderThan: Date) throws {
        try database.write { ctx in try ctx.execute("DELETE FROM agent_events WHERE ts < ?", [.date(olderThan)]) }
    }

    // MARK: Structured steps

    func saveSteps(runID: UUID, _ steps: [AgentStep]) throws {
        try database.write { ctx in
            for s in steps {
                try ctx.execute("""
                    INSERT INTO agent_run_steps(run_id, idx, title, weight, state) VALUES (?,?,?,?,?)
                    ON CONFLICT(run_id, idx) DO UPDATE SET title=excluded.title, weight=excluded.weight, state=excluded.state
                    """, [.text(runID.uuidString), .int(Int64(s.index)), .text(OutputSanitizer.sanitize(s.title)), .double(s.weight), .text(s.state.rawValue)])
            }
        }
    }

    func steps(runID: UUID) throws -> [AgentStep] {
        try database.read("SELECT * FROM agent_run_steps WHERE run_id = ? ORDER BY idx", [.text(runID.uuidString)]).compactMap { r in
            guard let i = r.int("idx"), let t = r.string("title"), let st = r.string("state").flatMap(StepState.init(rawValue:)) else { return nil }
            return AgentStep(index: i, title: t, weight: r.double("weight") ?? 1, state: st)
        }
    }

    // MARK: Report-ready queries ("what ran today? which models? what failed? how long?")

    struct RunStats: Equatable, Sendable {
        var total = 0
        var byEngine: [String: Int] = [:]
        var byModel: [String: Int] = [:]
        var byStatus: [String: Int] = [:]
        var escalated = 0
        var totalSeconds: Double = 0
    }

    func runStats(since: Date, until: Date? = nil) throws -> RunStats {
        var stats = RunStats()
        let rows = try database.read("""
            SELECT engine, model, status, escalated_to, (COALESCE(finished_at, started_at) - started_at) AS secs FROM agent_runs
            WHERE started_at >= ? AND started_at < ?
            """, [.date(since), .date(until ?? Date.distantFuture)])
        for r in rows {
            stats.total += 1
            stats.byEngine[r.string("engine") ?? "?", default: 0] += 1
            if let m = r.string("model") { stats.byModel[m, default: 0] += 1 }
            stats.byStatus[r.string("status") ?? "?", default: 0] += 1
            if r.string("escalated_to") != nil { stats.escalated += 1 }
            stats.totalSeconds += r.double("secs") ?? 0
        }
        return stats
    }

    // MARK: Tool executions + file changes

    func insert(_ t: ToolExecutionRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO tool_executions(id, agent_run_id, tool, summary, status, started_at, finished_at, exit_code) VALUES (?,?,?,?,?,?,?,?)
                """, [.text(t.id.uuidString), .text(t.agentRunID.uuidString), .text(t.tool), .opt(t.summary), .text(t.status),
                      .date(t.startedAt), .opt(t.finishedAt), .opt(t.exitCode)])
        }
    }
    func toolExecutions(agentRunID: UUID) throws -> [ToolExecutionRecord] {
        try database.read("SELECT * FROM tool_executions WHERE agent_run_id = ? ORDER BY started_at", [.text(agentRunID.uuidString)]).compactMap { r in
            guard let id = Self.uuid(r.string("id")), let run = Self.uuid(r.string("agent_run_id")), let tool = r.string("tool"),
                  let status = r.string("status") else { return nil }
            return ToolExecutionRecord(id: id, agentRunID: run, tool: tool, summary: r.string("summary"), status: status,
                                       startedAt: r.date("started_at") ?? Date(), finishedAt: r.date("finished_at"), exitCode: r.int("exit_code"))
        }
    }

    func insert(_ c: FileChangeRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO file_changes(id, task_id, agent_run_id, path, change_type, git_hash, git_commit, diff_artifact_id,
                    verification_result, changed_at) VALUES (?,?,?,?,?,?,?,?,?,?)
                """, [.text(c.id.uuidString), .opt(c.taskID?.uuidString), .opt(c.agentRunID?.uuidString), .text(c.path),
                      .text(c.changeType), .opt(c.gitHash), .opt(c.gitCommit), .opt(c.diffArtifactID?.uuidString),
                      .opt(c.verificationResult), .date(c.changedAt)])
        }
    }
    /// "Who changed NetworkPlayer.cs?" — every recorded change to a path, newest first.
    func fileChanges(path: String) throws -> [FileChangeRecord] {
        try database.read("SELECT * FROM file_changes WHERE path = ? OR path LIKE ? ORDER BY changed_at DESC",
                          [.text(path), .text("%/" + path)]).compactMap(Self.change)
    }
    func fileChanges(agentRunID: UUID) throws -> [FileChangeRecord] {
        try database.read("SELECT * FROM file_changes WHERE agent_run_id = ? ORDER BY changed_at", [.text(agentRunID.uuidString)]).compactMap(Self.change)
    }
    private static func change(_ r: SQLRow) -> FileChangeRecord? {
        guard let id = uuid(r.string("id")), let path = r.string("path"), let type = r.string("change_type") else { return nil }
        return FileChangeRecord(id: id, taskID: uuid(r.string("task_id")), agentRunID: uuid(r.string("agent_run_id")), path: path,
                                changeType: type, gitHash: r.string("git_hash"), gitCommit: r.string("git_commit"),
                                diffArtifactID: uuid(r.string("diff_artifact_id")), verificationResult: r.string("verification_result"),
                                changedAt: r.date("changed_at") ?? Date())
    }

    // MARK: Provider health (cooldown state survives restarts)

    func health(_ engine: ProviderID, subject: String = "") throws -> ProviderHealthRecord? {
        try database.readOne("SELECT * FROM provider_health WHERE engine = ? AND subject = ?", [.text(engine.rawValue), .text(subject)]).map { r in
            ProviderHealthRecord(engine: engine, subject: subject, consecutiveFailures: r.int("consecutive_failures") ?? 0,
                                 totalFailures: r.int("total_failures") ?? 0, lastFailureAt: r.date("last_failure_at"),
                                 lastErrorCategory: r.string("last_error_category"), cooldownUntil: r.date("cooldown_until"),
                                 lastSuccessAt: r.date("last_success_at"))
        }
    }
    func allHealth() throws -> [ProviderHealthRecord] {
        try database.read("SELECT * FROM provider_health").compactMap { r in
            guard let e = r.string("engine").flatMap(ProviderID.init(rawValue:)) else { return nil }
            return ProviderHealthRecord(engine: e, subject: r.string("subject") ?? "", consecutiveFailures: r.int("consecutive_failures") ?? 0,
                                        totalFailures: r.int("total_failures") ?? 0, lastFailureAt: r.date("last_failure_at"),
                                        lastErrorCategory: r.string("last_error_category"), cooldownUntil: r.date("cooldown_until"),
                                        lastSuccessAt: r.date("last_success_at"))
        }
    }
    func save(_ h: ProviderHealthRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO provider_health(engine, subject, consecutive_failures, total_failures, last_failure_at, last_error_category,
                    cooldown_until, last_success_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?)
                ON CONFLICT(engine, subject) DO UPDATE SET consecutive_failures=excluded.consecutive_failures,
                    total_failures=excluded.total_failures, last_failure_at=excluded.last_failure_at,
                    last_error_category=excluded.last_error_category, cooldown_until=excluded.cooldown_until,
                    last_success_at=excluded.last_success_at, updated_at=excluded.updated_at
                """, [.text(h.engine.rawValue), .text(h.subject), .int(Int64(h.consecutiveFailures)), .int(Int64(h.totalFailures)),
                      .opt(h.lastFailureAt), .opt(h.lastErrorCategory), .opt(h.cooldownUntil), .opt(h.lastSuccessAt), .date(Date())])
        }
    }

    // MARK: Activity (meaningful events only; bounded)

    static let activityRetention = 2000

    func addActivity(kind: String, message: String, taskID: UUID? = nil, agentRunID: UUID? = nil, at: Date = Date()) throws {
        try database.write { ctx in
            try ctx.execute("INSERT INTO activity_events(ts, kind, message, task_id, agent_run_id) VALUES (?,?,?,?,?)",
                            [.date(at), .text(kind), .text(Redactor.redact(message)), .opt(taskID?.uuidString), .opt(agentRunID?.uuidString)])
            try ctx.execute("DELETE FROM activity_events WHERE id <= (SELECT max(id) FROM activity_events) - ?", [.int(Int64(Self.activityRetention))])
        }
    }
    func recentActivity(limit: Int = 50) throws -> [(Date, String, String)] {
        try database.read("SELECT ts, kind, message FROM activity_events ORDER BY id DESC LIMIT ?", [.int(Int64(limit))]).compactMap { r in
            guard let d = r.date("ts"), let k = r.string("kind"), let m = r.string("message") else { return nil }
            return (d, k, m)
        }
    }

    // MARK: Projects / tasks (storage only — the task engine is V0.4)

    func insertProject(id: UUID = UUID(), name: String, rootPath: String?) throws -> UUID {
        try database.write { ctx in
            try ctx.execute("INSERT INTO projects(id, name, root_path, created_at) VALUES (?,?,?,?)",
                            [.text(id.uuidString), .text(name), .opt(rootPath), .date(Date())])
        }
        return id
    }

    func insertTask(id: UUID = UUID(), projectID: UUID? = nil, parent: UUID? = nil, title: String, category: TaskCategory? = nil,
                    status: String = "queued", privacy: PrivacyLevel = .normal) throws -> UUID {
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO tasks(id, project_id, parent_task_id, title, category, status, privacy, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?)
                """, [.text(id.uuidString), .opt(projectID?.uuidString), .opt(parent?.uuidString), .text(Redactor.redact(title)),
                      .opt(category?.rawValue), .text(status), .text(privacy.rawValue), .date(Date()), .date(Date())])
        }
        return id
    }

    func setTaskStatus(_ id: UUID, _ status: String, summary: String? = nil, finished: Bool = false) throws {
        try database.write { ctx in
            try ctx.execute("UPDATE tasks SET status = ?, summary = COALESCE(?, summary), updated_at = ?, finished_at = ? WHERE id = ?",
                            [.text(status), .opt(summary.map { Redactor.redact($0) }), .date(Date()), .opt(finished ? Date() : nil), .text(id.uuidString)])
        }
    }

    struct TaskInfo: Equatable, Sendable { var title: String; var status: String; var summary: String? }
    func taskInfo(_ id: UUID) throws -> TaskInfo? {
        try database.readOne("SELECT title, status, summary FROM tasks WHERE id = ?", [.text(id.uuidString)]).flatMap { r in
            r.string("title").map { TaskInfo(title: $0, status: r.string("status") ?? "", summary: r.string("summary")) }
        }
    }

    func taskStatus(_ id: UUID) throws -> String? { try database.readOne("SELECT status FROM tasks WHERE id = ?", [.text(id.uuidString)])?.string("status") }

    func count(_ table: String) throws -> Int {
        precondition(table.allSatisfy { $0.isLetter || $0 == "_" })
        return try database.readOne("SELECT count(*) AS n FROM \(table)")?.int("n") ?? 0
    }
}
