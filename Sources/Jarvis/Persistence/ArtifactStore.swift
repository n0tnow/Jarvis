import Foundation

struct ArtifactRecord: Equatable, Sendable {
    var id: UUID
    var type: String
    var relativePath: String              // relative to JarvisPaths.artifacts — never absolute, never inside the repo
    var size: Int
    var sha256: String
    var createdAt: Date
    var taskID: UUID?
    var agentRunID: UUID?
    var meta: String?
}

/// Hybrid storage: large content (reports, provider output, screenshots, benchmark artifacts, checkpoints, logs) is
/// written to files under Application Support; SQLite stores only the reference (path, type, size, hash, relations).
final class ArtifactStore: @unchecked Sendable {
    private let paths: JarvisPaths
    private let db: JarvisDatabase

    init(paths: JarvisPaths, database: JarvisDatabase) {
        self.paths = paths
        self.db = database
        try? paths.ensureDirectories()
    }

    @discardableResult
    func store(_ data: Data, type: String, folder: JarvisPaths.Folder, fileExtension: String = "txt",
               taskID: UUID? = nil, agentRunID: UUID? = nil, meta: String? = nil) throws -> ArtifactRecord {
        let id = UUID()
        let day = Self.dayFormatter.string(from: Date())
        let rel = "\(folder.rawValue)/\(day)/\(id.uuidString.lowercased()).\(fileExtension)"
        let url = paths.artifacts.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let record = ArtifactRecord(id: id, type: type, relativePath: rel, size: data.count, sha256: Redactor.sha256(data),
                                    createdAt: Date(), taskID: taskID, agentRunID: agentRunID, meta: meta)
        try db.write { ctx in
            try ctx.execute("""
                INSERT INTO artifacts(id, type, path, size, sha256, created_at, task_id, agent_run_id, meta) VALUES (?,?,?,?,?,?,?,?,?)
                """, [.text(id.uuidString), .text(type), .text(rel), .int(Int64(record.size)), .text(record.sha256),
                      .date(record.createdAt), .opt(taskID?.uuidString), .opt(agentRunID?.uuidString), .opt(meta)])
        }
        return record
    }

    func artifact(_ id: UUID) throws -> ArtifactRecord? {
        try db.readOne("SELECT * FROM artifacts WHERE id = ?", [.text(id.uuidString)]).flatMap(Self.record)
    }

    func artifacts(taskID: UUID? = nil, agentRunID: UUID? = nil) throws -> [ArtifactRecord] {
        var sql = "SELECT * FROM artifacts WHERE 1=1"; var params: [SQLValue] = []
        if let taskID { sql += " AND task_id = ?"; params.append(.text(taskID.uuidString)) }
        if let agentRunID { sql += " AND agent_run_id = ?"; params.append(.text(agentRunID.uuidString)) }
        return try db.read(sql + " ORDER BY created_at", params).compactMap(Self.record)
    }

    func read(_ record: ArtifactRecord) throws -> Data {
        guard let data = FileManager.default.contents(atPath: paths.artifacts.appendingPathComponent(record.relativePath).path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return data
    }

    /// True if the file still exists and matches its recorded hash.
    func verify(_ record: ArtifactRecord) -> Bool {
        guard let data = try? read(record) else { return false }
        return data.count == record.size && Redactor.sha256(data) == record.sha256
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    static func record(_ r: SQLRow) -> ArtifactRecord? {
        guard let id = r.string("id").flatMap(UUID.init(uuidString:)), let type = r.string("type"), let path = r.string("path"),
              let size = r.int("size"), let sha = r.string("sha256"), let created = r.date("created_at") else { return nil }
        return ArtifactRecord(id: id, type: type, relativePath: path, size: size, sha256: sha, createdAt: created,
                              taskID: r.string("task_id").flatMap(UUID.init(uuidString:)),
                              agentRunID: r.string("agent_run_id").flatMap(UUID.init(uuidString:)), meta: r.string("meta"))
    }
}
