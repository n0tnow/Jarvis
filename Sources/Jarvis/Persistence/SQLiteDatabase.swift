import Foundation
import SQLite3

/// A value bound to / read from a SQLite statement.
enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    static func opt(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
    static func opt(_ i: Int?) -> SQLValue { i.map { .int(Int64($0)) } ?? .null }
    static func opt(_ d: Double?) -> SQLValue { d.map { .double($0) } ?? .null }
    static func opt(_ d: Date?) -> SQLValue { d.map { .double($0.timeIntervalSince1970) } ?? .null }
    static func date(_ d: Date) -> SQLValue { .double(d.timeIntervalSince1970) }
    static func bool(_ b: Bool) -> SQLValue { .int(b ? 1 : 0) }
}

struct SQLRow: Sendable {
    fileprivate var columns: [String: SQLValue]
    func value(_ name: String) -> SQLValue { columns[name] ?? .null }
    func string(_ n: String) -> String? { if case .text(let s) = value(n) { return s }; return nil }
    func int(_ n: String) -> Int? {
        switch value(n) { case .int(let i): return Int(i); case .double(let d): return Int(d); default: return nil }
    }
    func double(_ n: String) -> Double? {
        switch value(n) { case .double(let d): return d; case .int(let i): return Double(i); default: return nil }
    }
    func bool(_ n: String) -> Bool { (int(n) ?? 0) != 0 }
    func date(_ n: String) -> Date? { double(n).map { Date(timeIntervalSince1970: $0) } }
}

enum DatabaseError: Error, Equatable, CustomStringConvertible {
    case open(code: Int32, message: String)
    case sql(code: Int32, message: String)
    case newerSchema(found: Int, supported: Int)
    case closed

    var description: String {
        switch self {
        case .open(let c, let m): "database open failed (\(c)): \(m)"
        case .sql(let c, let m): "sql error (\(c)): \(m)"
        case .newerSchema(let f, let s): "database schema v\(f) is newer than this build supports (v\(s))"
        case .closed: "database is closed"
        }
    }
}

/// One SQLite connection guarded by its own serial queue. Raw access is confined to this file.
final class SQLiteConnection: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let queue: DispatchQueue
    let readOnly: Bool

    init(path: String, readOnly: Bool, label: String) throws {
        self.readOnly = readOnly
        queue = DispatchQueue(label: "jarvis.sqlite.\(label)")
        var db: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)) | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db { sqlite3_close(db) }
            throw DatabaseError.open(code: rc, message: msg)
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
        // Validate that the file really is a database (opening a garbage file succeeds lazily).
        do {
            _ = try run("SELECT count(*) FROM sqlite_master", [])
            if !readOnly {
                _ = try run("PRAGMA journal_mode = WAL", [])
                _ = try run("PRAGMA synchronous = NORMAL", [])
            }
            _ = try run("PRAGMA foreign_keys = ON", [])
        } catch { sqlite3_close(db); handle = nil; throw error }
    }

    deinit { if let handle { sqlite3_close(handle) } }

    func close() { queue.sync { if let h = handle { sqlite3_close(h); handle = nil } } }

    /// Runs `body` on this connection's queue (serialises all use of the handle, incl. transactions).
    func sync<T>(_ body: () throws -> T) rethrows -> T { try queue.sync(execute: body) }

    // MARK: Statement execution (must run on `queue`; public wrappers below)

    @discardableResult
    func run(_ sql: String, _ params: [SQLValue]) throws -> [SQLRow] {
        guard let db = handle else { throw DatabaseError.closed }
        var stmt: OpaquePointer?
        var rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw DatabaseError.sql(code: rc, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)     // SQLITE_TRANSIENT
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .null: rc = sqlite3_bind_null(stmt, idx)
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, transient)
            case .blob(let v): rc = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), transient) }
            }
            if rc != SQLITE_OK { throw DatabaseError.sql(code: rc, message: String(cString: sqlite3_errmsg(db))) }
        }
        var rows: [SQLRow] = []
        let cols = sqlite3_column_count(stmt)
        while true {
            rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                var dict: [String: SQLValue] = [:]
                for c in 0..<cols {
                    let name = String(cString: sqlite3_column_name(stmt, c))
                    switch sqlite3_column_type(stmt, c) {
                    case SQLITE_INTEGER: dict[name] = .int(sqlite3_column_int64(stmt, c))
                    case SQLITE_FLOAT: dict[name] = .double(sqlite3_column_double(stmt, c))
                    case SQLITE_TEXT: dict[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                    case SQLITE_BLOB:
                        let n = Int(sqlite3_column_bytes(stmt, c))
                        dict[name] = .blob(n > 0 ? Data(bytes: sqlite3_column_blob(stmt, c), count: n) : Data())
                    default: dict[name] = .null
                    }
                }
                rows.append(SQLRow(columns: dict))
            } else if rc == SQLITE_DONE { break }
            else { throw DatabaseError.sql(code: rc, message: String(cString: sqlite3_errmsg(db))) }
        }
        return rows
    }

    var lastInsertRowID: Int64 { handle.map { sqlite3_last_insert_rowid($0) } ?? 0 }
}

/// The JARVIS operational database: ONE serialised writer connection + two reader connections (WAL allows reads while
/// a write is in progress). Large content is never stored here — see `ArtifactStore`.
final class JarvisDatabase: @unchecked Sendable {
    let url: URL
    private let writer: SQLiteConnection
    private let readers: [SQLiteConnection]
    private let readerLock = NSLock()
    private var nextReader = 0
    /// Set when an unreadable database file was moved aside and a fresh one was created.
    private(set) var recoveredFromCorruptionAt: URL?

    /// Opens (creating + migrating) the database at `url`. A corrupt/unreadable file is MOVED ASIDE (never deleted)
    /// and replaced by a new database, so JARVIS keeps starting.
    init(url: URL, migrations: [Migration] = Migration.all) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var aside: URL?
        var conn: SQLiteConnection
        do { conn = try SQLiteConnection(path: url.path, readOnly: false, label: "writer") }
        catch let e as DatabaseError {
            guard case .sql = e, FileManager.default.fileExists(atPath: url.path) else { throw e }
            aside = url.deletingLastPathComponent().appendingPathComponent("jarvis.sqlite.corrupt-\(Int(Date().timeIntervalSince1970))")
            try FileManager.default.moveItem(at: url, to: aside!)
            for ext in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + ext) }
            conn = try SQLiteConnection(path: url.path, readOnly: false, label: "writer")
        }
        writer = conn
        recoveredFromCorruptionAt = aside
        try Migration.migrate(connection: writer, migrations: migrations)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        readers = [try SQLiteConnection(path: url.path, readOnly: true, label: "reader0"),
                   try SQLiteConnection(path: url.path, readOnly: true, label: "reader1")]
    }

    func close() { writer.close(); readers.forEach { $0.close() } }

    // MARK: API

    /// Serialised write. `body` may run several statements; they are wrapped in ONE transaction (all-or-nothing).
    @discardableResult
    func write<T>(_ body: (WriteContext) throws -> T) throws -> T {
        try writer.sync {
            try writer.run("BEGIN IMMEDIATE", [])
            do {
                let result = try body(WriteContext(connection: writer))
                try writer.run("COMMIT", [])
                return result
            } catch {
                _ = try? writer.run("ROLLBACK", [])
                throw error
            }
        }
    }

    func read(_ sql: String, _ params: [SQLValue] = []) throws -> [SQLRow] {
        readerLock.lock(); let r = readers[nextReader % readers.count]; nextReader += 1; readerLock.unlock()
        return try r.sync { try r.run(sql, params) }
    }

    func readOne(_ sql: String, _ params: [SQLValue] = []) throws -> SQLRow? { try read(sql, params).first }

    var schemaVersion: Int { (try? readOne("PRAGMA user_version"))?.int("user_version") ?? 0 }

    struct WriteContext {
        fileprivate let connection: SQLiteConnection
        @discardableResult
        func execute(_ sql: String, _ params: [SQLValue] = []) throws -> [SQLRow] { try connection.run(sql, params) }
        var lastInsertRowID: Int64 { connection.lastInsertRowID }
    }
}
