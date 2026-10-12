import Foundation

/// Canonical storage of project memory (V0.10, schema v8). The repository stores what the curator decided; it makes no decisions itself.
/// Text is sanitized by the curator before it gets here and bounded again here (defence in depth).
struct MemoryProjectRow: Equatable, Sendable {
    var key: String
    var name: String
    var rootPath: String?
    var aliases: [String]
    var identityKind: String
    var createdAt: Date
    var lastSeen: Date
}

struct EmbeddingRow: Sendable {
    var memoryID: UUID
    var modelID: String
    var revision: String
    var dim: Int
    var textHash: String
    var vector: [Float]
}

struct MemoryContextUse: Equatable, Sendable, Identifiable {
    var id = UUID()
    var runID: UUID?
    var taskID: UUID?
    var projectKey: String
    var agentType: String
    var memoryIDs: [UUID]
    var truthKeys: [String]
    var items: Int
    var chars: Int
    var createdAt = Date()
}

extension JarvisRepository {
    private static func js<T: Encodable>(_ v: T) -> String { (try? String(data: JSONEncoder().encode(v), encoding: .utf8)) ?? "null" }
    private static func unjs<T: Decodable>(_ s: String?, as: T.Type) -> T? { s.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
    private static func uid(_ s: String?) -> UUID? { s.flatMap(UUID.init(uuidString:)) }

    // MARK: Projects

    func upsertMemoryProject(_ p: MemoryProjectRow) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO memory_projects(key, name, root_path, aliases, identity_kind, created_at, last_seen) VALUES (?,?,?,?,?,?,?)
                ON CONFLICT(key) DO UPDATE SET name=excluded.name, root_path=excluded.root_path, aliases=excluded.aliases, last_seen=excluded.last_seen
                """, [.text(p.key), .text(String(p.name.prefix(120))), .opt(p.rootPath), .text(Self.js(p.aliases)), .text(p.identityKind), .date(p.createdAt), .date(p.lastSeen)])
        }
    }

    func memoryProject(_ key: String) throws -> MemoryProjectRow? {
        try database.readOne("SELECT * FROM memory_projects WHERE key = ?", [.text(key)]).flatMap(Self.projectRow)
    }
    func memoryProjects() throws -> [MemoryProjectRow] { try database.read("SELECT * FROM memory_projects ORDER BY last_seen DESC").compactMap(Self.projectRow) }
    func memoryProject(path: String) throws -> MemoryProjectRow? {
        try memoryProjects().first { $0.rootPath == path || $0.aliases.contains(path) }
    }
    private static func projectRow(_ r: SQLRow) -> MemoryProjectRow? {
        guard let key = r.string("key"), let name = r.string("name"), let kind = r.string("identity_kind"), let c = r.date("created_at") else { return nil }
        return MemoryProjectRow(key: key, name: name, rootPath: r.string("root_path"), aliases: unjs(r.string("aliases"), as: [String].self) ?? [], identityKind: kind, createdAt: c, lastSeen: r.date("last_seen") ?? c)
    }

    // MARK: Items

    func insertMemory(_ m: MemoryItem) throws {
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO memory_items(id, project_key, type, subject, key, value, summary, details, status, strength, importance, scope, area, tags, origin, created_at, updated_at, valid_from,
                    last_verified_at, expires_at, superseded_by, pinned, user_corrected, current_sensitive, language, extraction_version, canonical_hash, forgotten_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, Self.itemParams(m))
            try Self.writeSources(ctx, m)
            try Self.writeRelations(ctx, m)
        }
    }

    func updateMemory(_ m: MemoryItem) throws {
        try database.write { ctx in
            try ctx.execute("""
                UPDATE memory_items SET project_key=?2, type=?3, subject=?4, key=?5, value=?6, summary=?7, details=?8, status=?9, strength=?10, importance=?11, scope=?12, area=?13, tags=?14, origin=?15,
                    created_at=?16, updated_at=?17, valid_from=?18, last_verified_at=?19, expires_at=?20, superseded_by=?21, pinned=?22, user_corrected=?23, current_sensitive=?24, language=?25,
                    extraction_version=?26, canonical_hash=?27, forgotten_at=?28 WHERE id=?1
                """, Self.itemParams(m))
            try ctx.execute("DELETE FROM memory_sources WHERE memory_id = ?", [.text(m.id.uuidString)])
            try ctx.execute("DELETE FROM memory_relations WHERE memory_id = ?", [.text(m.id.uuidString)])
            try Self.writeSources(ctx, m)
            try Self.writeRelations(ctx, m)
        }
    }

    private static func itemParams(_ m: MemoryItem) -> [SQLValue] {
        [.text(m.id.uuidString), .text(m.projectKey), .text(m.type.rawValue), .text(String(m.subject.prefix(80))), .opt(m.key.map { String($0.prefix(160)) }), .opt(m.value.map { String($0.prefix(300)) }),
         .text(String(m.summary.prefix(MemoryConstants.maxSummary))), .opt(m.details.map { String($0.prefix(MemoryConstants.maxDetails)) }), .text(m.status.rawValue), .int(Int64(m.strength.rawValue)),
         .int(Int64(m.importance.rawValue)), .text(m.scope.rawValue), .opt(m.area), .text(js(m.tags)), .text(m.origin.rawValue), .date(m.createdAt), .date(m.updatedAt), .date(m.validFrom),
         .opt(m.lastVerifiedAt), .opt(m.expiresAt), .opt(m.supersededBy?.uuidString), .bool(m.pinned), .bool(m.userCorrected), .bool(m.currentSensitive), .text(m.language),
         .int(Int64(m.extractionVersion)), .text(m.canonicalHash), .opt(m.forgottenAt)]
    }

    private static func writeSources(_ ctx: JarvisDatabase.WriteContext, _ m: MemoryItem) throws {
        for s in m.sources.prefix(24) {
            try ctx.execute("INSERT OR IGNORE INTO memory_sources(memory_id, kind, ref, label, locator, observed_at) VALUES (?,?,?,?,?,?)",
                            [.text(m.id.uuidString), .text(s.kind.rawValue), .text(String(s.ref.prefix(300))), .text(String(s.label.prefix(200))), .opt(s.locator.map { String($0.prefix(200)) }), .date(s.observedAt)])
        }
    }
    private static func writeRelations(_ ctx: JarvisDatabase.WriteContext, _ m: MemoryItem) throws {
        for r in m.relations.prefix(24) {
            try ctx.execute("INSERT OR IGNORE INTO memory_relations(memory_id, predicate, target_kind, target) VALUES (?,?,?,?)",
                            [.text(m.id.uuidString), .text(r.predicate), .text(r.targetKind), .text(String(r.target.prefix(200)))])
        }
    }

    func memory(_ id: UUID) throws -> MemoryItem? {
        guard let row = try database.readOne("SELECT * FROM memory_items WHERE id = ?", [.text(id.uuidString)]), var m = Self.itemRow(row) else { return nil }
        try attach(&m)
        return m
    }

    /// Items of a project. `statuses` nil = every status. Sources and relations are attached (bounded by the page size).
    func memories(projectKey: String, statuses: [MemoryStatus]? = nil, types: [MemoryType]? = nil, limit: Int = 5_000) throws -> [MemoryItem] {
        var sql = "SELECT * FROM memory_items WHERE project_key = ?"
        var params: [SQLValue] = [.text(projectKey)]
        if let statuses { sql += " AND status IN (\(statuses.map { _ in "?" }.joined(separator: ",")))"; params += statuses.map { .text($0.rawValue) } }
        if let types { sql += " AND type IN (\(types.map { _ in "?" }.joined(separator: ",")))"; params += types.map { .text($0.rawValue) } }
        sql += " ORDER BY updated_at DESC LIMIT ?"; params.append(.int(Int64(limit)))
        var items = try database.read(sql, params).compactMap(Self.itemRow)
        try attachAll(&items)
        return items
    }

    func memories(projectKey: String, key: String) throws -> [MemoryItem] {
        var items = try database.read("SELECT * FROM memory_items WHERE project_key = ? AND key = ? AND status != 'forgotten'", [.text(projectKey), .text(key)]).compactMap(Self.itemRow)
        try attachAll(&items)
        return items
    }

    func memories(projectKey: String, canonicalHash: String) throws -> [MemoryItem] {
        var items = try database.read("SELECT * FROM memory_items WHERE project_key = ? AND canonical_hash = ?", [.text(projectKey), .text(canonicalHash)]).compactMap(Self.itemRow)
        try attachAll(&items)
        return items
    }

    func memoryCount(projectKey: String? = nil) throws -> Int {
        if let projectKey { return try database.readOne("SELECT count(*) AS n FROM memory_items WHERE project_key = ?", [.text(projectKey)])?.int("n") ?? 0 }
        return try count("memory_items")
    }

    func memoryCounts(projectKey: String) throws -> (byType: [MemoryType: Int], byStatus: [MemoryStatus: Int]) {
        var t: [MemoryType: Int] = [:], s: [MemoryStatus: Int] = [:]
        for r in try database.read("SELECT type, status, count(*) AS n FROM memory_items WHERE project_key = ? GROUP BY type, status", [.text(projectKey)]) {
            let n = r.int("n") ?? 0
            if let ty = r.string("type").flatMap(MemoryType.init(rawValue:)) { t[ty, default: 0] += n }
            if let st = r.string("status").flatMap(MemoryStatus.init(rawValue:)) { s[st, default: 0] += n }
        }
        return (t, s)
    }

    func memoriesReferencing(sourceKind: MemorySourceKind, ref: String, projectKey: String) throws -> [UUID] {
        try database.read("""
            SELECT i.id FROM memory_items i JOIN memory_sources s ON s.memory_id = i.id WHERE i.project_key = ? AND s.kind = ? AND s.ref = ?
            """, [.text(projectKey), .text(sourceKind.rawValue), .text(ref)]).compactMap { Self.uid($0.string("id")) }
    }

    private func attach(_ m: inout MemoryItem) throws {
        m.sources = try database.read("SELECT * FROM memory_sources WHERE memory_id = ? ORDER BY observed_at", [.text(m.id.uuidString)]).compactMap(Self.sourceRow)
        m.relations = try database.read("SELECT * FROM memory_relations WHERE memory_id = ?", [.text(m.id.uuidString)]).compactMap(Self.relationRow)
    }

    private func attachAll(_ items: inout [MemoryItem]) throws {
        guard !items.isEmpty else { return }
        var srcs: [String: [MemorySource]] = [:], rels: [String: [MemoryRelation]] = [:]
        let project = items[0].projectKey
        for r in try database.read("SELECT s.* FROM memory_sources s JOIN memory_items i ON i.id = s.memory_id WHERE i.project_key = ? ORDER BY s.observed_at", [.text(project)]) {
            if let id = r.string("memory_id"), let s = Self.sourceRow(r) { srcs[id, default: []].append(s) }
        }
        for r in try database.read("SELECT r.* FROM memory_relations r JOIN memory_items i ON i.id = r.memory_id WHERE i.project_key = ?", [.text(project)]) {
            if let id = r.string("memory_id"), let x = Self.relationRow(r) { rels[id, default: []].append(x) }
        }
        for i in items.indices { items[i].sources = srcs[items[i].id.uuidString] ?? []; items[i].relations = rels[items[i].id.uuidString] ?? [] }
    }

    private static func sourceRow(_ r: SQLRow) -> MemorySource? {
        guard let k = r.string("kind").flatMap(MemorySourceKind.init(rawValue:)), let ref = r.string("ref"), let label = r.string("label") else { return nil }
        return MemorySource(kind: k, ref: ref, label: label, locator: r.string("locator"), observedAt: r.date("observed_at") ?? Date())
    }
    private static func relationRow(_ r: SQLRow) -> MemoryRelation? {
        guard let p = r.string("predicate"), let k = r.string("target_kind"), let t = r.string("target") else { return nil }
        return MemoryRelation(predicate: p, targetKind: k, target: t)
    }

    private static func itemRow(_ r: SQLRow) -> MemoryItem? {
        guard let id = uid(r.string("id")), let pk = r.string("project_key"), let type = r.string("type").flatMap(MemoryType.init(rawValue:)), let subject = r.string("subject"), let summary = r.string("summary"),
              let status = r.string("status").flatMap(MemoryStatus.init(rawValue:)), let origin = r.string("origin").flatMap(MemoryOrigin.init(rawValue:)), let created = r.date("created_at") else { return nil }
        var m = MemoryItem(projectKey: pk, type: type, subject: subject, summary: summary, origin: origin)
        m.id = id; m.key = r.string("key"); m.value = r.string("value"); m.details = r.string("details"); m.status = status
        m.strength = MemoryStrength(rawValue: r.int("strength") ?? 2) ?? .supported
        m.importance = MemoryImportance(rawValue: r.int("importance") ?? 1) ?? .normal
        m.scope = r.string("scope").flatMap(MemoryScope.init(rawValue:)) ?? .project
        m.area = r.string("area"); m.tags = unjs(r.string("tags"), as: [String].self) ?? []
        m.createdAt = created; m.updatedAt = r.date("updated_at") ?? created; m.validFrom = r.date("valid_from") ?? created
        m.lastVerifiedAt = r.date("last_verified_at"); m.expiresAt = r.date("expires_at"); m.supersededBy = uid(r.string("superseded_by"))
        m.pinned = r.bool("pinned"); m.userCorrected = r.bool("user_corrected"); m.currentSensitive = r.bool("current_sensitive")
        m.language = r.string("language") ?? "en"; m.extractionVersion = r.int("extraction_version") ?? 1; m.canonicalHash = r.string("canonical_hash") ?? ""; m.forgottenAt = r.date("forgotten_at")
        return m
    }

    // MARK: Embeddings (derived index)

    static func encodeVector(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }
    static func decodeVector(_ d: Data, dim: Int) -> [Float]? {
        guard d.count == dim * MemoryLayout<Float>.size else { return nil }
        return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    func upsertEmbedding(_ e: EmbeddingRow) throws {
        let data = Self.encodeVector(e.vector)
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO memory_embeddings(memory_id, model_id, revision, dim, text_hash, vector, checksum, created_at) VALUES (?,?,?,?,?,?,?,?)
                ON CONFLICT(memory_id) DO UPDATE SET model_id=excluded.model_id, revision=excluded.revision, dim=excluded.dim, text_hash=excluded.text_hash, vector=excluded.vector, checksum=excluded.checksum, created_at=excluded.created_at
                """, [.text(e.memoryID.uuidString), .text(e.modelID), .text(e.revision), .int(Int64(e.dim)), .text(e.textHash), .blob(data), .text(Redactor.sha256(data)), .date(Date())])
        }
    }

    /// Atomic swap of a project's whole index: either every new vector is in place or the old index is untouched (cancelled / failed rebuilds never write).
    func replaceEmbeddings(projectKey: String, rows: [EmbeddingRow]) throws {
        try database.write { ctx in
            try ctx.execute("DELETE FROM memory_embeddings WHERE memory_id IN (SELECT id FROM memory_items WHERE project_key = ?)", [.text(projectKey)])
            for e in rows {
                let data = Self.encodeVector(e.vector)
                try ctx.execute("INSERT INTO memory_embeddings(memory_id, model_id, revision, dim, text_hash, vector, checksum, created_at) VALUES (?,?,?,?,?,?,?,?)",
                                [.text(e.memoryID.uuidString), .text(e.modelID), .text(e.revision), .int(Int64(e.dim)), .text(e.textHash), .blob(data), .text(Redactor.sha256(data)), .date(Date())])
            }
        }
    }

    func deleteEmbedding(_ id: UUID) throws { try database.write { ctx in try ctx.execute("DELETE FROM memory_embeddings WHERE memory_id = ?", [.text(id.uuidString)]) } }
    func clearEmbeddings(projectKey: String? = nil) throws {
        try database.write { ctx in
            if let projectKey { try ctx.execute("DELETE FROM memory_embeddings WHERE memory_id IN (SELECT id FROM memory_items WHERE project_key = ?)", [.text(projectKey)]) }
            else { try ctx.execute("DELETE FROM memory_embeddings") }
        }
    }

    /// Rows whose model/revision/dimension and checksum match; anything else is reported as `invalid` (never silently mixed into a search).
    func embeddings(projectKey: String, modelID: String, revision: String, dim: Int) throws -> (valid: [EmbeddingRow], invalid: [UUID]) {
        var valid: [EmbeddingRow] = [], invalid: [UUID] = []
        for r in try database.read("SELECT e.* FROM memory_embeddings e JOIN memory_items i ON i.id = e.memory_id WHERE i.project_key = ? AND i.status != 'forgotten'", [.text(projectKey)]) {
            guard let id = Self.uid(r.string("memory_id")) else { continue }
            guard r.string("model_id") == modelID, r.string("revision") == revision, r.int("dim") == dim, case .blob(let data) = r.value("vector"),
                  Redactor.sha256(data) == r.string("checksum"), let v = Self.decodeVector(data, dim: dim) else { invalid.append(id); continue }
            valid.append(EmbeddingRow(memoryID: id, modelID: modelID, revision: revision, dim: dim, textHash: r.string("text_hash") ?? "", vector: v))
        }
        return (valid, invalid)
    }

    func embeddingTextHashes(projectKey: String) throws -> [UUID: String] {
        var out: [UUID: String] = [:]
        for r in try database.read("SELECT e.memory_id, e.text_hash FROM memory_embeddings e JOIN memory_items i ON i.id = e.memory_id WHERE i.project_key = ?", [.text(projectKey)]) {
            if let id = Self.uid(r.string("memory_id")), let h = r.string("text_hash") { out[id] = h }
        }
        return out
    }
    func embeddingCount(projectKey: String? = nil) throws -> Int {
        if let projectKey { return try database.readOne("SELECT count(*) AS n FROM memory_embeddings e JOIN memory_items i ON i.id = e.memory_id WHERE i.project_key = ?", [.text(projectKey)])?.int("n") ?? 0 }
        return try count("memory_embeddings")
    }

    // MARK: Meta

    func memoryMeta(_ key: String) throws -> String? { try database.readOne("SELECT value FROM memory_meta WHERE key = ?", [.text(key)])?.string("value") }
    func setMemoryMeta(_ key: String, _ value: String) throws {
        try database.write { ctx in try ctx.execute("INSERT INTO memory_meta(key, value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)]) }
    }

    // MARK: Events (bounded)

    func insertMemoryEvent(_ e: MemoryEvent) throws {
        try database.write { ctx in
            try ctx.execute("INSERT INTO memory_events(at, project_key, kind, memory_id, detail) VALUES (?,?,?,?,?)",
                            [.date(e.at), .text(e.projectKey), .text(e.kind), .opt(e.memoryID?.uuidString), .text(OutputSanitizer.sanitize(String(e.detail.prefix(240))))])
            try ctx.execute("DELETE FROM memory_events WHERE id <= (SELECT max(id) FROM memory_events) - 3000", [])
        }
    }

    func memoryEvents(projectKey: String? = nil, limit: Int = 100) throws -> [MemoryEvent] {
        let rows = projectKey == nil ? try database.read("SELECT * FROM memory_events ORDER BY id DESC LIMIT ?", [.int(Int64(limit))])
                                     : try database.read("SELECT * FROM memory_events WHERE project_key = ? ORDER BY id DESC LIMIT ?", [.text(projectKey!), .int(Int64(limit))])
        return rows.compactMap { r in
            guard let pk = r.string("project_key"), let kind = r.string("kind") else { return nil }
            return MemoryEvent(id: Int64(r.int("id") ?? 0), at: r.date("at") ?? Date(), projectKey: pk, kind: kind, memoryID: Self.uid(r.string("memory_id")), detail: r.string("detail") ?? "")
        }
    }

    // MARK: Context uses (the audit answer to "why did the agent avoid that?")

    func insertMemoryContextUse(_ u: MemoryContextUse) throws {
        try database.write { ctx in
            try ctx.execute("INSERT INTO memory_context_uses(id, run_id, task_id, project_key, agent_type, memory_ids, truth_keys, items, chars, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
                            [.text(u.id.uuidString), .opt(u.runID?.uuidString), .opt(u.taskID?.uuidString), .text(u.projectKey), .text(u.agentType), .text(Self.js(u.memoryIDs.map(\.uuidString))),
                             .text(Self.js(u.truthKeys)), .int(Int64(u.items)), .int(Int64(u.chars)), .date(u.createdAt)])
        }
    }
    func memoryContextUses(taskID: UUID? = nil, runID: UUID? = nil, limit: Int = 50) throws -> [MemoryContextUse] {
        var sql = "SELECT * FROM memory_context_uses"
        var params: [SQLValue] = []
        if let taskID { sql += " WHERE task_id = ?"; params.append(.text(taskID.uuidString)) }
        else if let runID { sql += " WHERE run_id = ?"; params.append(.text(runID.uuidString)) }
        sql += " ORDER BY created_at DESC LIMIT ?"; params.append(.int(Int64(limit)))
        return try database.read(sql, params).compactMap { r in
            guard let id = Self.uid(r.string("id")), let pk = r.string("project_key"), let at = r.string("agent_type") else { return nil }
            let ids = (Self.unjs(r.string("memory_ids"), as: [String].self) ?? []).compactMap(UUID.init(uuidString:))
            return MemoryContextUse(id: id, runID: Self.uid(r.string("run_id")), taskID: Self.uid(r.string("task_id")), projectKey: pk, agentType: at, memoryIDs: ids,
                                    truthKeys: Self.unjs(r.string("truth_keys"), as: [String].self) ?? [], items: r.int("items") ?? 0, chars: r.int("chars") ?? 0, createdAt: r.date("created_at") ?? Date())
        }
    }
}
