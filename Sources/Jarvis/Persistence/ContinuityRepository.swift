import Foundation

/// Storage of what project continuity cannot derive (schema v11): the checkpoints a finished task or continuation session left behind, and when the last session ran.
/// Free text is sanitized and bounded on the way in; the payload is the checkpoint's own JSON.
struct ContinuityState: Equatable, Sendable {
    var projectKey: String
    var lastContinuationAt: Date?
    var lastTaskID: UUID?
    var sessions: Int
    /// Steps the user queued as accepted next work (bounded).
    var queue: [String] = []
}

extension JarvisRepository {
    private static func cjs<T: Encodable>(_ v: T) -> String { (try? String(data: JSONEncoder().encode(v), encoding: .utf8)) ?? "{}" }

    private static func clean(_ c: ContinuityCheckpoint) -> ContinuityCheckpoint {
        func s(_ x: String, _ n: Int) -> String { OutputSanitizer.sanitize(String(x.prefix(n))) }
        var c = c
        c.title = s(c.title, 160); c.summary = s(c.summary, 600)
        c.changed = c.changed.prefix(60).map { s($0, 200) }
        c.validated = c.validated.prefix(20).map { s($0, 200) }
        c.remaining = c.remaining.prefix(12).map { s($0, 200) }
        c.next = c.next.prefix(8).map { s($0, 200) }
        c.inconclusive = c.inconclusive.prefix(8).map { s($0, 200) }
        c.unity = c.unity.prefix(12).map { s($0, 200) }
        c.dirtyPaths = Array(c.dirtyPaths.prefix(ContinuityLimits.maxFileHashes))
        if c.fileHashes.count > ContinuityLimits.maxFileHashes { c.fileHashes = Dictionary(uniqueKeysWithValues: c.fileHashes.sorted { $0.key < $1.key }.prefix(ContinuityLimits.maxFileHashes).map { ($0.key, $0.value) }) }
        return c
    }

    func insert(_ checkpoint: ContinuityCheckpoint) throws {
        let c = Self.clean(checkpoint)
        try database.write { ctx in
            try ctx.execute("""
                INSERT OR REPLACE INTO project_checkpoints(id, project_key, task_id, created_at, kind, outcome, title, git_head, git_branch, payload) VALUES (?,?,?,?,?,?,?,?,?,?)
                """, [.text(c.id.uuidString), .text(c.projectKey), .opt(c.taskID?.uuidString), .date(c.createdAt), .text(c.kind), .text(c.outcome), .text(c.title), .opt(c.gitHead), .opt(c.gitBranch), .text(Self.cjs(c))])
        }
    }

    private static func checkpoint(_ r: SQLRow) -> ContinuityCheckpoint? {
        r.string("payload").flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(ContinuityCheckpoint.self, from: $0) }
    }

    func latestCheckpoint(projectKey: String) throws -> ContinuityCheckpoint? {
        try database.readOne("SELECT payload FROM project_checkpoints WHERE project_key = ? ORDER BY created_at DESC LIMIT 1", [.text(projectKey)]).flatMap(Self.checkpoint)
    }

    func checkpoints(projectKey: String, limit: Int = 10) throws -> [ContinuityCheckpoint] {
        try database.read("SELECT payload FROM project_checkpoints WHERE project_key = ? ORDER BY created_at DESC LIMIT ?", [.text(projectKey), .int(Int64(limit))]).compactMap(Self.checkpoint)
    }

    func checkpoint(forTask id: UUID) throws -> ContinuityCheckpoint? {
        try database.readOne("SELECT payload FROM project_checkpoints WHERE task_id = ? ORDER BY created_at DESC LIMIT 1", [.text(id.uuidString)]).flatMap(Self.checkpoint)
    }

    /// Old checkpoints fall away (the newest `keep` per project stay); tasks, reports and memory are untouched.
    @discardableResult
    func pruneCheckpoints(keep: Int = 30) throws -> Int {
        try database.write { ctx in
            try ctx.execute("""
                DELETE FROM project_checkpoints WHERE id IN (
                    SELECT id FROM (SELECT id, ROW_NUMBER() OVER (PARTITION BY project_key ORDER BY created_at DESC) AS n FROM project_checkpoints) WHERE n > ?)
                """, [.int(Int64(keep))])
            return 0
        }
    }

    func continuityState(_ key: String) throws -> ContinuityState? {
        try database.readOne("SELECT * FROM project_continuity WHERE project_key = ?", [.text(key)]).map {
            ContinuityState(projectKey: key, lastContinuationAt: $0.date("last_continuation_at"), lastTaskID: $0.string("last_task_id").flatMap(UUID.init(uuidString:)), sessions: $0.int("sessions") ?? 0,
                            queue: $0.string("queue").flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
        }
    }

    func recordContinuationSession(projectKey: String, taskID: UUID?, at: Date = Date()) throws {
        let old = try continuityState(projectKey)
        try saveContinuity(ContinuityState(projectKey: projectKey, lastContinuationAt: at, lastTaskID: taskID, sessions: (old?.sessions ?? 0) + 1, queue: old?.queue ?? []))
    }

    func saveContinuity(_ s: ContinuityState) throws {
        let queue = s.queue.prefix(12).map { OutputSanitizer.sanitize(String($0.prefix(200))) }
        try database.write { ctx in
            try ctx.execute("INSERT OR REPLACE INTO project_continuity(project_key, last_continuation_at, last_task_id, sessions, queue, updated_at) VALUES (?,?,?,?,?,?)",
                            [.text(s.projectKey), .opt(s.lastContinuationAt), .opt(s.lastTaskID?.uuidString), .int(Int64(s.sessions)), .text(Self.cjs(Array(queue))), .date(Date())])
        }
    }

    /// Root engine tasks of a project (by every path it has been known under), newest first. Child tasks of a graph are excluded.
    func continuityTasks(roots: [String], limit: Int = 60) throws -> [TaskRecord] {
        guard !roots.isEmpty else { return [] }
        let marks = roots.map { _ in "?" }.joined(separator: ",")
        return try database.read("SELECT * FROM tasks WHERE kind IS NOT NULL AND parent_task_id IS NULL AND workspace_root IN (\(marks)) ORDER BY created_at DESC LIMIT ?",
                                 roots.map { .text($0) } + [.int(Int64(limit))]).compactMap(Self.taskRow)
    }

    /// Paths (with the after-hash) that JARVIS tasks of these roots changed after `date` — what is NOT outside interference when the project is reconciled.
    func jarvisFileChanges(roots: [String], after date: Date) throws -> [String: String] {
        guard !roots.isEmpty else { return [:] }
        let marks = roots.map { _ in "?" }.joined(separator: ",")
        let rows = try database.read("""
            SELECT f.path AS path, f.after_hash AS after_hash, f.change_type AS change_type FROM file_changes f JOIN tasks t ON t.id = f.task_id
            WHERE t.workspace_root IN (\(marks)) AND f.changed_at > ? AND f.step_key IS NOT NULL ORDER BY f.changed_at
            """, roots.map { .text($0) } + [.date(date)])
        var out: [String: String] = [:]
        for r in rows { if let p = r.string("path") { out[p] = r.string("change_type") == "deleted" ? "deleted" : (r.string("after_hash") ?? "") } }
        return out
    }
}
