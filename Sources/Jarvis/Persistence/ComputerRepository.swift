import Foundation

// MARK: - Computer sessions (V0.11, schema v9)
//
// Bounded, sanitized metadata about what Computer Use did. There is no column for an Accessibility tree, for pixels, for typed text or for clipboard
// contents: a typed text is recorded as its class and length only.

enum ComputerSessionStatus: String, Codable, Sendable {
    case running, waitingForApproval, completed, failed, cancelled, interrupted
    var isActive: Bool { self == .running || self == .waitingForApproval }
    var label: String { rawValue == "waitingForApproval" ? "AWAITING APPROVAL" : rawValue.uppercased() }
}

struct ComputerSessionRecord: Equatable, Sendable, Identifiable {
    var id: UUID                          // == the task id
    var taskID: UUID
    var goal: String
    var status: ComputerSessionStatus
    var targetApps: [String]
    var planSummary: String?
    var capability: String?
    var visionEnabled: Bool
    var startedAt: Date
    var finishedAt: Date?
    var failure: String?
    var resumeCount: Int
    var memoryIDs: [UUID]
    var origin: String?
}

struct ComputerActionRecord: Equatable, Sendable, Identifiable {
    var id: UUID
    var sessionID: UUID
    var seq: Int
    var at: Date
    var kind: String
    var mechanism: String
    var app: String?
    var window: String?
    var target: String?
    var risk: String
    var status: String
    var resolution: String?
    var verification: String?
    var detail: String?
    var approvalID: UUID?
    var textClass: String?
    var textLength: Int?
    var durationMS: Double?
    var attempts: Int
    var provider: String?
}

struct ComputerObservationRecord: Equatable, Sendable, Identifiable {
    var id: UUID
    var sessionID: UUID
    var at: Date
    var kind: String                      // "ax" | "screenshot"
    var app: String?
    var window: String?
    var nodes: Int?
    var windows: Int?
    var truncated: Bool
    var durationMS: Double?
    var width: Int?
    var height: Int?
    var fingerprint: String?
    var provider: String?
    var persisted: Bool                   // always false unless a developer explicitly asked (there is no such code path in V0.11)
}

extension JarvisRepository {
    private static func cl(_ s: String?, _ max: Int) -> String? { s.map { OutputSanitizer.sanitize(String($0.prefix(max))) } }
    private static func js<T: Encodable>(_ v: T) -> String { (try? String(data: JSONEncoder().encode(v), encoding: .utf8)) ?? "[]" }
    private static func unjs<T: Decodable>(_ s: String?, as: T.Type) -> T? { s.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
    private static func uid(_ s: String?) -> UUID? { s.flatMap(UUID.init(uuidString:)) }

    // MARK: Sessions

    func upsert(_ s: ComputerSessionRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO computer_sessions(id, task_id, goal, status, target_apps, plan_summary, capability, vision_enabled, started_at, finished_at, failure, resume_count, memory_ids, origin)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET status=excluded.status, target_apps=excluded.target_apps, plan_summary=excluded.plan_summary, capability=excluded.capability,
                    vision_enabled=excluded.vision_enabled, finished_at=excluded.finished_at, failure=excluded.failure, resume_count=excluded.resume_count, memory_ids=excluded.memory_ids
                """, [.text(s.id.uuidString), .text(s.taskID.uuidString), .text(Self.cl(s.goal, 600) ?? ""), .text(s.status.rawValue), .text(Self.js(s.targetApps)), .opt(Self.cl(s.planSummary, 400)),
                      .opt(Self.cl(s.capability, 200)), .bool(s.visionEnabled), .date(s.startedAt), .opt(s.finishedAt), .opt(Self.cl(s.failure, 500)), .int(Int64(s.resumeCount)),
                      .text(Self.js(s.memoryIDs.map(\.uuidString))), .opt(s.origin)])
        }
    }

    private static func session(_ r: SQLRow) -> ComputerSessionRecord? {
        guard let id = uid(r.string("id")), let tid = uid(r.string("task_id")), let st = r.string("status").flatMap(ComputerSessionStatus.init(rawValue:)), let start = r.date("started_at") else { return nil }
        return ComputerSessionRecord(id: id, taskID: tid, goal: r.string("goal") ?? "", status: st, targetApps: unjs(r.string("target_apps"), as: [String].self) ?? [], planSummary: r.string("plan_summary"),
                                     capability: r.string("capability"), visionEnabled: (r.int("vision_enabled") ?? 0) != 0, startedAt: start, finishedAt: r.date("finished_at"), failure: r.string("failure"),
                                     resumeCount: r.int("resume_count") ?? 0, memoryIDs: (unjs(r.string("memory_ids"), as: [String].self) ?? []).compactMap(UUID.init(uuidString:)), origin: r.string("origin"))
    }

    func computerSession(_ id: UUID) throws -> ComputerSessionRecord? {
        try database.readOne("SELECT * FROM computer_sessions WHERE id = ?", [.text(id.uuidString)]).flatMap(Self.session)
    }
    func computerSessions(limit: Int = 30) throws -> [ComputerSessionRecord] {
        try database.read("SELECT * FROM computer_sessions ORDER BY started_at DESC LIMIT ?", [.int(Int64(limit))]).compactMap(Self.session)
    }

    // MARK: Actions

    func insert(_ a: ComputerActionRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO computer_actions(id, session_id, seq, at, kind, mechanism, app, window, target, risk, status, resolution, verification, detail, approval_id, text_class, text_length, duration_ms, attempts, provider)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(a.id.uuidString), .text(a.sessionID.uuidString), .int(Int64(a.seq)), .date(a.at), .text(a.kind), .text(a.mechanism), .opt(Self.cl(a.app, 80)), .opt(Self.cl(a.window, 100)),
                      .opt(Self.cl(a.target, 140)), .text(a.risk), .text(a.status), .opt(a.resolution), .opt(Self.cl(a.verification, 400)), .opt(Self.cl(a.detail, 500)),
                      .opt(a.approvalID?.uuidString), .opt(a.textClass), .opt(a.textLength), .opt(a.durationMS), .int(Int64(a.attempts)), .opt(Self.cl(a.provider, 80))])
            // bounded: the most recent 400 actions of a session
            try ctx.execute("DELETE FROM computer_actions WHERE session_id = ?1 AND seq <= (SELECT MAX(seq) - 400 FROM computer_actions WHERE session_id = ?1)", [.text(a.sessionID.uuidString)])
        }
    }

    func computerActions(sessionID: UUID, limit: Int = 200) throws -> [ComputerActionRecord] {
        try database.read("SELECT * FROM computer_actions WHERE session_id = ? ORDER BY seq LIMIT ?", [.text(sessionID.uuidString), .int(Int64(limit))]).compactMap { r in
            guard let id = Self.uid(r.string("id")), let sid = Self.uid(r.string("session_id")), let at = r.date("at") else { return nil }
            return ComputerActionRecord(id: id, sessionID: sid, seq: r.int("seq") ?? 0, at: at, kind: r.string("kind") ?? "", mechanism: r.string("mechanism") ?? "", app: r.string("app"), window: r.string("window"),
                                        target: r.string("target"), risk: r.string("risk") ?? "low", status: r.string("status") ?? "", resolution: r.string("resolution"), verification: r.string("verification"),
                                        detail: r.string("detail"), approvalID: Self.uid(r.string("approval_id")), textClass: r.string("text_class"), textLength: r.int("text_length"),
                                        durationMS: r.double("duration_ms"), attempts: r.int("attempts") ?? 1, provider: r.string("provider"))
        }
    }

    // MARK: Observations (metadata only)

    func insert(_ o: ComputerObservationRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO computer_observations(id, session_id, at, kind, app, window, nodes, windows, truncated, duration_ms, width, height, fingerprint, provider, persisted)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,0)
                """, [.text(o.id.uuidString), .text(o.sessionID.uuidString), .date(o.at), .text(o.kind), .opt(Self.cl(o.app, 80)), .opt(Self.cl(o.window, 100)), .opt(o.nodes), .opt(o.windows),
                      .bool(o.truncated), .opt(o.durationMS), .opt(o.width), .opt(o.height), .opt(o.fingerprint), .opt(Self.cl(o.provider, 80))])
            try ctx.execute("DELETE FROM computer_observations WHERE session_id = ?1 AND at < (SELECT MIN(at) FROM (SELECT at FROM computer_observations WHERE session_id = ?1 ORDER BY at DESC LIMIT 200))", [.text(o.sessionID.uuidString)])
        }
    }

    func computerObservations(sessionID: UUID, limit: Int = 100) throws -> [ComputerObservationRecord] {
        try database.read("SELECT * FROM computer_observations WHERE session_id = ? ORDER BY at LIMIT ?", [.text(sessionID.uuidString), .int(Int64(limit))]).compactMap { r in
            guard let id = Self.uid(r.string("id")), let sid = Self.uid(r.string("session_id")), let at = r.date("at") else { return nil }
            return ComputerObservationRecord(id: id, sessionID: sid, at: at, kind: r.string("kind") ?? "ax", app: r.string("app"), window: r.string("window"), nodes: r.int("nodes"), windows: r.int("windows"),
                                             truncated: (r.int("truncated") ?? 0) != 0, durationMS: r.double("duration_ms"), width: r.int("width"), height: r.int("height"), fingerprint: r.string("fingerprint"),
                                             provider: r.string("provider"), persisted: (r.int("persisted") ?? 0) != 0)
        }
    }

    // MARK: Restart

    /// A session that was running when JARVIS stopped is INTERRUPTED — never resumed silently. Resuming is an explicit user action that re-observes from scratch.
    @discardableResult
    func reconcileComputerAfterRestart(now: Date = Date()) throws -> Int {
        let active = try database.read("SELECT id FROM computer_sessions WHERE status IN ('running','waitingForApproval')")
        try database.write { ctx in
            try ctx.execute("UPDATE computer_sessions SET status = 'interrupted', finished_at = ?, failure = 'interrupted by an application restart; resume re-observes from scratch' WHERE status IN ('running','waitingForApproval')", [.date(now)])
        }
        return active.count
    }

    /// Old sessions fall away (bounded history); their actions and observations go with them.
    func pruneComputerSessions(keep: Int = 100) throws {
        try database.write { ctx in
            try ctx.execute("DELETE FROM computer_sessions WHERE id NOT IN (SELECT id FROM computer_sessions ORDER BY started_at DESC LIMIT ?)", [.int(Int64(keep))])
        }
    }
}
