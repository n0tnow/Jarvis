import Foundation

/// Durable storage of the autonomous task engine (schema v3). Every free-text field is passed through the redactor/sanitizer on
/// the way in and bounded; large content (reports, checkpoints, diffs) lives in artifacts and is only referenced here.
extension JarvisRepository {
    private static func js<T: Encodable>(_ v: T) -> String { (try? String(data: JSONEncoder().encode(v), encoding: .utf8)) ?? "null" }
    private static func unjs<T: Decodable>(_ s: String?, as: T.Type) -> T? { s.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
    private static func uid(_ s: String?) -> UUID? { s.flatMap(UUID.init(uuidString:)) }
    private static func clean(_ s: String?, _ max: Int) -> String? { s.map { OutputSanitizer.sanitize(String($0.prefix(max))) } }

    // MARK: Tasks

    func insert(_ t: TaskRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO tasks(id, project_id, title, category, status, privacy, created_at, updated_at, finished_at, summary,
                    goal, kind, risk, workspace_root, started_at, current_step, activity, progress_fraction, progress_source, constraints,
                    failure_category, failure_reason, cancel_requested, recovery, plan_version, capabilities, git_baseline,
                    report_artifact_id, checkpoint_artifact_id, accumulated_seconds, preference, destructive_requested,
                    origin, origin_task_id, origin_opportunity_id, autonomy_depth, scope)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, Self.taskParams(t))
        }
    }

    func update(_ t: TaskRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                UPDATE tasks SET project_id=?2, title=?3, category=?4, status=?5, privacy=?6, created_at=?7, updated_at=?8, finished_at=?9,
                    summary=?10, goal=?11, kind=?12, risk=?13, workspace_root=?14, started_at=?15, current_step=?16, activity=?17,
                    progress_fraction=?18, progress_source=?19, constraints=?20, failure_category=?21, failure_reason=?22, cancel_requested=?23,
                    recovery=?24, plan_version=?25, capabilities=?26, git_baseline=?27, report_artifact_id=?28, checkpoint_artifact_id=?29,
                    accumulated_seconds=?30, preference=?31, destructive_requested=?32,
                    origin=?33, origin_task_id=?34, origin_opportunity_id=?35, autonomy_depth=?36, scope=?37
                WHERE id = ?1
                """, Self.taskParams(t))
        }
    }

    private static func taskParams(_ t: TaskRecord) -> [SQLValue] {
        [.text(t.id.uuidString), .opt(t.projectID?.uuidString), .text(Redactor.redact(String(t.title.prefix(160)))), .text(t.category.rawValue), .text(t.state.rawValue),
         .text(t.privacy.rawValue), .date(t.createdAt), .date(t.updatedAt), .opt(t.finishedAt), .opt(Self.clean(t.summary, 2000)),
         .opt(Self.clean(t.goal, 2000)), .text(t.kind.rawValue), .text(t.risk.rawValue), .opt(t.workspaceRoot), .opt(t.startedAt), .opt(t.currentStepKey),
         .opt(Self.clean(t.activity, 200)), .opt(t.progressFraction), .text(t.progressSource.rawValue), .text(Self.js(t.constraints.map { OutputSanitizer.sanitize(String($0.prefix(300))) })),
         .opt(t.failureCategory?.rawValue), .opt(Self.clean(t.failureReason, 1000)), .int(t.cancelRequested ? 1 : 0), .opt(Self.clean(t.recovery, 400)),
         .int(Int64(t.planVersion)), .text(Self.js(t.capabilities)), .opt(t.gitBaseline.map { Self.js($0) }), .opt(t.reportArtifactID?.uuidString),
         .opt(t.checkpointArtifactID?.uuidString), .double(t.accumulatedSeconds), .opt(t.preference?.rawValue), .int(t.destructiveRequested ? 1 : 0),
         .text(t.origin.rawValue), .opt(t.originTaskID?.uuidString), .opt(t.originOpportunityID?.uuidString), .int(Int64(t.autonomyDepth)), .opt(t.scope.map { js($0) })]
    }

    private static func task(_ r: SQLRow) -> TaskRecord? {
        guard let id = Self.uid(r.string("id")), let title = r.string("title"), let kind = r.string("kind").flatMap(TaskKind.init(rawValue:)),
              let state = r.string("status").flatMap(TaskState.init(rawValue:)), let created = r.date("created_at") else { return nil }
        var t = TaskRecord(id: id, title: title, goal: r.string("goal") ?? title, kind: kind)
        t.category = r.string("category").flatMap(TaskCategory.init(rawValue:)) ?? .coding
        t.state = state
        t.risk = r.string("risk").flatMap(RiskClass.init(rawValue:)) ?? .low
        t.privacy = r.string("privacy").flatMap(PrivacyLevel.init(rawValue:)) ?? .normal
        t.workspaceRoot = r.string("workspace_root")
        t.projectID = Self.uid(r.string("project_id"))
        t.createdAt = created; t.startedAt = r.date("started_at"); t.updatedAt = r.date("updated_at") ?? created; t.finishedAt = r.date("finished_at")
        t.currentStepKey = r.string("current_step"); t.activity = r.string("activity") ?? ""
        t.progressFraction = r.double("progress_fraction")
        t.progressSource = r.string("progress_source").flatMap(ProgressSource.init(rawValue:)) ?? .unknown
        t.constraints = Self.unjs(r.string("constraints"), as: [String].self) ?? []
        t.failureCategory = r.string("failure_category").flatMap(FailureCategory.init(rawValue:))
        t.failureReason = r.string("failure_reason")
        t.cancelRequested = r.bool("cancel_requested")
        t.recovery = r.string("recovery")
        t.planVersion = r.int("plan_version") ?? 0
        t.capabilities = Self.unjs(r.string("capabilities"), as: CapabilitySet.self) ?? .readOnly
        t.gitBaseline = Self.unjs(r.string("git_baseline"), as: GitBaseline.self)
        t.reportArtifactID = Self.uid(r.string("report_artifact_id")); t.checkpointArtifactID = Self.uid(r.string("checkpoint_artifact_id"))
        t.summary = r.string("summary")
        t.accumulatedSeconds = r.double("accumulated_seconds") ?? 0
        t.preference = r.string("preference").flatMap(ProviderPreference.init(rawValue:))
        t.destructiveRequested = r.bool("destructive_requested")
        t.origin = r.string("origin").flatMap(TaskOrigin.init(rawValue:)) ?? .userTask
        t.originTaskID = uid(r.string("origin_task_id")); t.originOpportunityID = uid(r.string("origin_opportunity_id"))
        t.autonomyDepth = r.int("autonomy_depth") ?? 0
        t.scope = unjs(r.string("scope"), as: TaskScope.self)
        return t
    }

    func engineTask(_ id: UUID) throws -> TaskRecord? {
        try database.readOne("SELECT * FROM tasks WHERE id = ? AND kind IS NOT NULL", [.text(id.uuidString)]).flatMap(Self.task)
    }

    /// Engine tasks (those created by the V0.4 engine), newest first.
    func engineTasks(states: [TaskState]? = nil, limit: Int = 50, offset: Int = 0) throws -> [TaskRecord] {
        var sql = "SELECT * FROM tasks WHERE kind IS NOT NULL"; var p: [SQLValue] = []
        if let states, !states.isEmpty { sql += " AND status IN (" + states.map { _ in "?" }.joined(separator: ",") + ")"; p += states.map { .text($0.rawValue) } }
        sql += " ORDER BY created_at DESC LIMIT ? OFFSET ?"; p += [.int(Int64(limit)), .int(Int64(offset))]
        return try database.read(sql, p).compactMap(Self.task)
    }

    // MARK: Steps

    func insertSteps(_ steps: [TaskStepRecord]) throws {
        try database.write { ctx in
            for s in steps {
                try ctx.execute("""
                    INSERT INTO task_steps(id, task_id, idx, title, status, started_at, finished_at, step_key, type, description, depends_on, expected,
                        validation, risk, weight, attempts, agent_run_id, result_summary, failure_category, failure_reason, validation_evidence, unity_params)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, Self.stepParams(s))
            }
        }
    }

    func update(_ s: TaskStepRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                UPDATE task_steps SET task_id=?2, idx=?3, title=?4, status=?5, started_at=?6, finished_at=?7, step_key=?8, type=?9, description=?10,
                    depends_on=?11, expected=?12, validation=?13, risk=?14, weight=?15, attempts=?16, agent_run_id=?17, result_summary=?18,
                    failure_category=?19, failure_reason=?20, validation_evidence=?21, unity_params=?22 WHERE id = ?1
                """, Self.stepParams(s))
        }
    }

    func deleteSteps(taskID: UUID) throws {
        try database.write { ctx in try ctx.execute("DELETE FROM task_steps WHERE task_id = ?", [.text(taskID.uuidString)]) }
    }

    private static func stepParams(_ s: TaskStepRecord) -> [SQLValue] {
        [.text(s.id.uuidString), .text(s.taskID.uuidString), .int(Int64(s.index)), .text(Self.clean(s.title, 160) ?? ""), .text(s.state.rawValue), .opt(s.startedAt), .opt(s.finishedAt),
         .text(s.key), .text(s.type.rawValue), .opt(Self.clean(s.details, 700)), .text(Self.js(s.dependsOn)), .opt(Self.clean(s.expected, 400)), .text(s.validation.rawValue),
         .text(s.risk.rawValue), .double(s.weight), .int(Int64(s.attempts)), .opt(s.agentRunID?.uuidString), .opt(Self.clean(s.resultSummary, 1500)),
         .opt(s.failureCategory?.rawValue), .opt(Self.clean(s.failureReason, 1000)), .opt(Self.clean(s.validationEvidence, 4000)),
         .opt(s.unity.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) })]
    }

    private static func step(_ r: SQLRow) -> TaskStepRecord? {
        guard let id = Self.uid(r.string("id")), let tid = Self.uid(r.string("task_id")), let idx = r.int("idx"), let key = r.string("step_key"),
              let type = r.string("type").flatMap(StepType.init(rawValue:)), let state = r.string("status").flatMap(TaskStepState.init(rawValue:)),
              let validation = r.string("validation").flatMap(ValidationKind.init(rawValue:)) else { return nil }
        var s = TaskStepRecord(id: id, taskID: tid, index: idx, key: key, title: r.string("title") ?? key, type: type, validation: validation)
        s.details = r.string("description") ?? ""; s.dependsOn = Self.unjs(r.string("depends_on"), as: [String].self) ?? []
        s.expected = r.string("expected") ?? ""; s.risk = r.string("risk").flatMap(RiskClass.init(rawValue:)) ?? .low
        s.weight = r.double("weight") ?? 1; s.state = state; s.attempts = r.int("attempts") ?? 0
        s.agentRunID = Self.uid(r.string("agent_run_id")); s.resultSummary = r.string("result_summary")
        s.failureCategory = r.string("failure_category").flatMap(FailureCategory.init(rawValue:)); s.failureReason = r.string("failure_reason")
        s.startedAt = r.date("started_at"); s.finishedAt = r.date("finished_at"); s.validationEvidence = r.string("validation_evidence")
        s.unity = r.string("unity_params").flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(UnityStepParams.self, from: $0) }
        return s
    }

    func steps(taskID: UUID) throws -> [TaskStepRecord] {
        try database.read("SELECT * FROM task_steps WHERE task_id = ? ORDER BY idx", [.text(taskID.uuidString)]).compactMap(Self.step)
    }

    // MARK: Attempts (primary / repair / escalation)

    func insert(_ a: StepAttemptRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO step_attempts(id, step_id, task_id, number, kind, engine, model, agent_run_id, outcome, evidence, started_at, finished_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                """, Self.attemptParams(a))
        }
    }

    func update(_ a: StepAttemptRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                UPDATE step_attempts SET step_id=?2, task_id=?3, number=?4, kind=?5, engine=?6, model=?7, agent_run_id=?8, outcome=?9, evidence=?10,
                    started_at=?11, finished_at=?12 WHERE id = ?1
                """, Self.attemptParams(a))
        }
    }

    private static func attemptParams(_ a: StepAttemptRecord) -> [SQLValue] {
        [.text(a.id.uuidString), .text(a.stepID.uuidString), .text(a.taskID.uuidString), .int(Int64(a.number)), .text(a.kind.rawValue), .opt(a.engine?.rawValue),
         .opt(a.model), .opt(a.agentRunID?.uuidString), .text(OutputSanitizer.sanitize(String(a.outcome.prefix(120)))), .opt(Self.clean(a.evidence, 4000)),
         .date(a.startedAt), .opt(a.finishedAt)]
    }

    func attempts(taskID: UUID) throws -> [StepAttemptRecord] {
        try database.read("SELECT * FROM step_attempts WHERE task_id = ? ORDER BY started_at, number", [.text(taskID.uuidString)]).compactMap { r in
            guard let id = Self.uid(r.string("id")), let sid = Self.uid(r.string("step_id")), let tid = Self.uid(r.string("task_id")), let n = r.int("number"),
                  let kind = r.string("kind").flatMap(AttemptKind.init(rawValue:)), let outcome = r.string("outcome"), let started = r.date("started_at") else { return nil }
            var a = StepAttemptRecord(id: id, stepID: sid, taskID: tid, number: n, kind: kind, engine: r.string("engine").flatMap(ProviderID.init(rawValue:)),
                                      model: r.string("model"), agentRunID: Self.uid(r.string("agent_run_id")), outcome: outcome, evidence: r.string("evidence"), startedAt: started)
            a.finishedAt = r.date("finished_at")
            return a
        }
    }

    // MARK: Approvals

    func insert(_ a: ApprovalRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO approvals(id, task_id, agent_run_id, kind, summary, status, requested_at, decided_at, decided_by, step_id, action, reason, risk, proposal_id, scope_hash)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, Self.approvalParams(a))
        }
    }

    func update(_ a: ApprovalRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                UPDATE approvals SET task_id=?2, agent_run_id=?3, kind=?4, summary=?5, status=?6, requested_at=?7, decided_at=?8, decided_by=?9,
                    step_id=?10, action=?11, reason=?12, risk=?13, proposal_id=?14, scope_hash=?15 WHERE id = ?1
                """, Self.approvalParams(a))
        }
    }

    private static func approvalParams(_ a: ApprovalRecord) -> [SQLValue] {
        [.text(a.id.uuidString), .text(a.taskID.uuidString), .null, .text(a.kind), .opt(Self.clean(a.action, 300)), .text(a.state.rawValue), .date(a.requestedAt), .opt(a.decidedAt),
         .opt(a.decidedBy), .opt(a.stepID?.uuidString), .opt(Self.clean(a.action, 300)), .opt(Self.clean(a.reason, 500)), .text(a.risk.rawValue),
         .opt(a.proposalID?.uuidString), .opt(a.scopeHash)]
    }

    private static func approval(_ r: SQLRow) -> ApprovalRecord? {
        guard let id = Self.uid(r.string("id")), let tid = Self.uid(r.string("task_id")), let st = r.string("status").flatMap(ApprovalState.init(rawValue:)),
              let at = r.date("requested_at") else { return nil }
        var a = ApprovalRecord(id: id, taskID: tid, stepID: Self.uid(r.string("step_id")), action: r.string("action") ?? r.string("summary") ?? "", reason: r.string("reason") ?? "",
                               risk: r.string("risk").flatMap(RiskClass.init(rawValue:)) ?? .high)
        a.state = st; a.requestedAt = at; a.decidedAt = r.date("decided_at"); a.decidedBy = r.string("decided_by"); a.kind = r.string("kind") ?? "task-action"
        a.proposalID = uid(r.string("proposal_id")); a.scopeHash = r.string("scope_hash")
        return a
    }

    func approvals(taskID: UUID) throws -> [ApprovalRecord] {
        try database.read("SELECT * FROM approvals WHERE task_id = ? ORDER BY requested_at", [.text(taskID.uuidString)]).compactMap(Self.approval)
    }

    func pendingApprovals() throws -> [ApprovalRecord] {
        try database.read("SELECT * FROM approvals WHERE status = 'pending' AND step_id IS NOT NULL ORDER BY requested_at").compactMap(Self.approval)
    }

    // MARK: File leases

    func insertLease(_ l: FileLeaseRecord) throws {
        try database.write { ctx in
            try ctx.execute("INSERT INTO file_leases(path, task_id, step_id, owner, acquired_at, state) VALUES (?,?,?,?,?,?)",
                            [.text(l.path), .text(l.taskID.uuidString), .opt(l.stepID?.uuidString), .text(l.owner), .date(l.acquiredAt), .text(l.state.rawValue)])
        }
    }

    func releaseLeases(owner: String, to state: LeaseState = .released) throws {
        try database.write { ctx in
            try ctx.execute("UPDATE file_leases SET state = ?, released_at = ? WHERE owner = ? AND state = 'active'", [.text(state.rawValue), .date(Date()), .text(owner)])
        }
    }

    func releaseLeases(taskID: UUID, to state: LeaseState = .released) throws {
        try database.write { ctx in
            try ctx.execute("UPDATE file_leases SET state = ?, released_at = ? WHERE task_id = ? AND state = 'active'", [.text(state.rawValue), .date(Date()), .text(taskID.uuidString)])
        }
    }

    func activeLeases() throws -> [FileLeaseRecord] {
        try database.read("SELECT * FROM file_leases WHERE state = 'active' ORDER BY acquired_at").compactMap { r in
            guard let path = r.string("path"), let tid = Self.uid(r.string("task_id")), let owner = r.string("owner"), let at = r.date("acquired_at") else { return nil }
            return FileLeaseRecord(path: path, taskID: tid, stepID: Self.uid(r.string("step_id")), owner: owner, acquiredAt: at, state: .active)
        }
    }

    /// Restart reconciliation: every lease still `active` belonged to a process that no longer exists.
    @discardableResult
    func markStaleLeases(now: Date = Date()) throws -> Int {
        let n = try activeLeases().count
        guard n > 0 else { return 0 }
        try database.write { ctx in try ctx.execute("UPDATE file_leases SET state = 'stale', released_at = ? WHERE state = 'active'", [.date(now)]) }
        return n
    }

    // MARK: File changes made by a task step

    func insertTaskFileChange(_ c: TaskFileChange, taskID: UUID, agentRunID: UUID?) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO file_changes(id, task_id, agent_run_id, path, change_type, changed_at, step_key, before_hash, after_hash, preexisting)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                """, [.text(UUID().uuidString), .text(taskID.uuidString), .opt(agentRunID?.uuidString), .text(c.path), .text(c.changeType), .date(Date()),
                      .text(c.stepKey), .opt(c.beforeHash), .opt(c.afterHash), .int(c.preexistingUserChange ? 1 : 0)])
        }
    }

    func taskFileChanges(taskID: UUID) throws -> [TaskFileChange] {
        try database.read("SELECT * FROM file_changes WHERE task_id = ? AND step_key IS NOT NULL ORDER BY changed_at", [.text(taskID.uuidString)]).compactMap { r in
            guard let path = r.string("path"), let type = r.string("change_type") else { return nil }
            return TaskFileChange(path: path, changeType: type, beforeHash: r.string("before_hash"), afterHash: r.string("after_hash"),
                                  stepKey: r.string("step_key") ?? "", preexistingUserChange: r.bool("preexisting"))
        }
    }

    // MARK: Restart reconciliation

    struct TaskReconciliation: Equatable, Sendable { var tasks: [UUID]; var steps: Int; var leases: Int }

    /// Tasks left `planning/ready/running` by a process that no longer exists become INTERRUPTED (never "running forever"); their
    /// in-flight steps likewise. `waitingForApproval` tasks keep waiting (they hold no process). Leases of the dead process are stale.
    func reconcileTasksAfterRestart(now: Date = Date()) throws -> TaskReconciliation {
        let stale = try engineTasks(states: [.planning, .ready, .running], limit: 500)
        var stepCount = 0
        for t in stale {
            stepCount += try steps(taskID: t.id).filter { $0.state == .running || $0.state == .verifying }.count
            try database.write { ctx in
                try ctx.execute("""
                    UPDATE tasks SET status = 'interrupted', updated_at = ?, activity = 'Interrupted — JARVIS stopped while this task was running',
                        recovery = 'interrupted by an application restart; resume to continue from the persisted state' WHERE id = ?
                    """, [.date(now), .text(t.id.uuidString)])
                try ctx.execute("UPDATE task_steps SET status = 'interrupted', finished_at = ? WHERE task_id = ? AND status IN ('running','verifying')",
                                [.date(now), .text(t.id.uuidString)])
            }
        }
        let leases = try markStaleLeases(now: now)
        return TaskReconciliation(tasks: stale.map(\.id), steps: stepCount, leases: leases)
    }
}
