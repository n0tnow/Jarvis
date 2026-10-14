import Foundation

// MARK: - MCP registry persistence (V0.14). Bounded, sanitised; no raw tool output, no secret, no screenshot.

extension JarvisRepository {
    private static func mjs<T: Encodable>(_ v: T) -> String { (try? String(data: JSONEncoder().encode(v), encoding: .utf8)) ?? "{}" }
    private static func unmjs<T: Decodable>(_ s: String?, as: T.Type) -> T? { s.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(T.self, from: $0) } }

    func save(_ s: MCPServerRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO mcp_registry(id, name, status, health, version, executable_hash, definition, install_directory, registered_at, status_changed_at, last_used_at, revalidation_required, is_fixture)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, status = excluded.status, health = excluded.health, version = excluded.version, executable_hash = excluded.executable_hash,
                    definition = excluded.definition, install_directory = excluded.install_directory, status_changed_at = excluded.status_changed_at, last_used_at = excluded.last_used_at,
                    revalidation_required = excluded.revalidation_required
                """, [.text(s.id), .text(String(s.name.prefix(80))), .text(s.status.rawValue), .text(s.health.rawValue), .text(String(s.version.prefix(40))), .opt(s.executableHash), .text(Self.mjs(s)),
                      .opt(s.installDirectory), .date(s.registeredAt), .date(s.statusChangedAt), .opt(s.lastUsedAt), .bool(s.revalidationRequired), .bool(s.isFixture)])
        }
    }
    func mcpServer(_ id: String) throws -> MCPServerRecord? { try database.readOne("SELECT definition FROM mcp_registry WHERE id = ?", [.text(id)]).flatMap { Self.unmjs($0.string("definition"), as: MCPServerRecord.self) } }
    func mcpServers(statuses: [MCPStatus]? = nil) throws -> [MCPServerRecord] {
        var sql = "SELECT definition FROM mcp_registry"; var p: [SQLValue] = []
        if let statuses, !statuses.isEmpty { sql += " WHERE status IN (\(statuses.map { _ in "?" }.joined(separator: ",")))"; p = statuses.map { .text($0.rawValue) } }
        return try database.read(sql + " ORDER BY status_changed_at DESC", p).compactMap { Self.unmjs($0.string("definition"), as: MCPServerRecord.self) }
    }
    func deleteMCPServer(_ id: String) throws { try database.write { ctx in try ctx.execute("DELETE FROM mcp_registry WHERE id = ?", [.text(id)]) } }

    func save(benchmark b: MCPBenchmarkResult, serverID: String) throws {
        try database.write { ctx in
            try ctx.execute("INSERT INTO mcp_benchmarks(id, server_id, at, result) VALUES (?,?,?,?)", [.text(UUID().uuidString), .text(serverID), .date(b.at), .text(Self.mjs(b))])
            try ctx.execute("DELETE FROM mcp_benchmarks WHERE server_id = ? AND id NOT IN (SELECT id FROM mcp_benchmarks WHERE server_id = ? ORDER BY at DESC LIMIT 10)", [.text(serverID), .text(serverID)])
        }
    }
    func mcpBenchmarks(serverID: String) throws -> [MCPBenchmarkResult] {
        try database.read("SELECT result FROM mcp_benchmarks WHERE server_id = ? ORDER BY at DESC", [.text(serverID)]).compactMap { Self.unmjs($0.string("result"), as: MCPBenchmarkResult.self) }
    }

    func insert(_ a: MCPActivityRecord) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT OR REPLACE INTO mcp_activity(id, server_id, capability, task_id, role, project_key, started_at, ended_at, status, latency_ms, envelope, error, validated) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(a.id.uuidString), .text(a.serverID), .text(String(a.capability.prefix(80))), .opt(a.taskID?.uuidString), .opt(a.role), .opt(a.projectKey), .date(a.startedAt), .opt(a.endedAt), .text(a.status),
                      .opt(a.latencyMS), .opt(a.envelope), .opt(a.error.map { OutputSanitizer.sanitize(String($0.prefix(240))) }), .bool(a.validated)])
            try ctx.execute("DELETE FROM mcp_activity WHERE id IN (SELECT id FROM mcp_activity ORDER BY started_at DESC LIMIT -1 OFFSET 2000)")
        }
    }
    func mcpActivity(serverID: String? = nil, limit: Int = 100) throws -> [MCPActivityRecord] {
        let rows = serverID.map { try? database.read("SELECT * FROM mcp_activity WHERE server_id = ? ORDER BY started_at DESC LIMIT ?", [.text($0), .int(Int64(limit))]) } ?? (try? database.read("SELECT * FROM mcp_activity ORDER BY started_at DESC LIMIT ?", [.int(Int64(limit))]))
        return (rows ?? []).compactMap { r in
            guard let id = r.string("id").flatMap(UUID.init(uuidString:)), let at = r.date("started_at") else { return nil }
            return MCPActivityRecord(id: id, serverID: r.string("server_id") ?? "", capability: r.string("capability") ?? "", taskID: r.string("task_id").flatMap(UUID.init(uuidString:)), role: r.string("role"), projectKey: r.string("project_key"),
                                     startedAt: at, endedAt: r.date("ended_at"), status: r.string("status") ?? "", latencyMS: r.double("latency_ms"), envelope: r.string("envelope"), error: r.string("error"), validated: r.bool("validated"))
        }
    }
}
