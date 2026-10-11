import Testing
import Foundation
@testable import Jarvis

private func tempDB(_ tag: String = "db") throws -> (JarvisPaths, JarvisDatabase) {
    let paths = JarvisPaths.temporary(tag)
    try paths.ensureDirectories()
    return (paths, try JarvisDatabase(url: paths.database))
}

private func sampleRun(task: UUID? = nil, parent: UUID? = nil, engine: ProviderID = .openCode) -> AgentRunRecord {
    var r = AgentRunRecord(id: UUID(), taskID: task, parentAgentRunID: parent, agentType: "ResearchAgent", engine: engine,
                           model: "opencode/big-pickle", startedAt: Date())
    r.selectionReason = "{\"coding\":true}"
    return r
}

@Suite("SQLite persistence", .serialized)
struct PersistenceTests {
    @Test func firstRunCreatesDatabaseWithFullSchemaInWALMode() throws {
        let (paths, db) = try tempDB()
        #expect(FileManager.default.fileExists(atPath: paths.database.path))
        #expect(db.schemaVersion == Migration.latestVersion)
        let tables = try db.read("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0.string("name") }
        for t in ["projects", "tasks", "task_steps", "agent_runs", "model_registry", "model_benchmarks", "tool_executions",
                  "file_changes", "approvals", "proposals", "activity_events", "artifacts", "provider_health", "schema_migrations"] {
            #expect(tables.contains(t), "missing table \(t)")
        }
        let mode = try db.readOne("PRAGMA journal_mode")?.string("journal_mode")
        #expect(mode == "wal")
        let perms = try FileManager.default.attributesOfItem(atPath: paths.database.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func migrationsApplyIncrementallyAndKeepData() throws {
        let paths = JarvisPaths.temporary("mig"); try paths.ensureDirectories()
        let v1Only = [Migration.v1]
        let db1 = try JarvisDatabase(url: paths.database, migrations: v1Only)
        let repo1 = JarvisRepository(database: db1)
        _ = try repo1.insertProject(name: "keep me", rootPath: nil)
        db1.close()
        let v2 = Migration(version: 2, name: "test", statements: ["ALTER TABLE projects ADD COLUMN color TEXT"])
        let db2 = try JarvisDatabase(url: paths.database, migrations: v1Only + [v2])
        #expect(db2.schemaVersion == 2)
        let kept = try db2.readOne("SELECT name, color FROM projects")?.string("name")
        #expect(kept == "keep me")
        let hist = try db2.read("SELECT version FROM schema_migrations ORDER BY version").compactMap { $0.int("version") }
        #expect(hist == [1, 2])
        db2.close()
        // Reopening with the same list must not re-apply anything.
        let db3 = try JarvisDatabase(url: paths.database, migrations: v1Only + [v2])
        let rows3 = try db3.read("SELECT * FROM schema_migrations")
        #expect(db3.schemaVersion == 2 && rows3.count == 2)
    }

    @Test func aFailingMigrationRollsBackCompletely() throws {
        let paths = JarvisPaths.temporary("migfail"); try paths.ensureDirectories()
        let bad = Migration(version: 2, name: "bad", statements: ["CREATE TABLE half (x INTEGER)", "THIS IS NOT SQL"])
        let db = try JarvisDatabase(url: paths.database, migrations: [Migration.v1])
        db.close()
        #expect(throws: DatabaseError.self) { _ = try JarvisDatabase(url: paths.database, migrations: [Migration.v1, bad]) }
        let again = try JarvisDatabase(url: paths.database, migrations: [Migration.v1])
        #expect(again.schemaVersion == 1)
        let leftovers = try again.read("SELECT name FROM sqlite_master WHERE name = 'half'")
        #expect(leftovers.isEmpty)
    }

    @Test func aNewerDatabaseIsRefusedNotDowngraded() throws {
        let paths = JarvisPaths.temporary("newer"); try paths.ensureDirectories()
        let v2 = Migration(version: 2, name: "future", statements: ["CREATE TABLE future (x INTEGER)"])
        try JarvisDatabase(url: paths.database, migrations: [Migration.v1, v2]).close()
        do { _ = try JarvisDatabase(url: paths.database, migrations: [Migration.v1]); Issue.record("must refuse") }
        catch let e as DatabaseError { #expect(e == .newerSchema(found: 2, supported: 1)) }
    }

    @Test func recordsSurviveCloseAndReopen() throws {
        let (paths, db) = try tempDB("reopen")
        let repo = JarvisRepository(database: db)
        let taskID = try repo.insertTask(title: "Persist me", category: .coding)
        var run = sampleRun(task: taskID)
        run.status = .succeeded; run.finishedAt = Date(); run.filesChanged = ["Assets/NetworkPlayer.cs"]
        try repo.insert(run)
        var model = ModelRecord(id: "opencode/big-pickle", engine: .openCode, provider: "opencode", providerModelID: "big-pickle", displayName: "Big Pickle")
        model.pricingStatus = .verifiedZero; model.freeVerified = true; model.freeVerifiedAt = Date(); model.availability = .available
        model.capabilities.supportsCoding = true
        try repo.upsert(model)
        db.close()

        let reopened = JarvisRepository(database: try JarvisDatabase(url: paths.database))
        let backOpt = try reopened.agentRun(run.id)
        let back = try #require(backOpt)
        #expect(back.status == .succeeded && back.taskID == taskID && back.filesChanged == ["Assets/NetworkPlayer.cs"])
        #expect(back.selectionReason == "{\"coding\":true}")
        let mOpt = try reopened.model("opencode/big-pickle")
        let m = try #require(mOpt)
        #expect(m.freeVerified && m.pricingStatus == .verifiedZero && m.capabilities.supportsCoding && m.isFreePoolMember)
        let st = try reopened.taskStatus(taskID)
        #expect(st == "queued")
    }

    @Test func concurrentReadsDuringSerializedWritesAreConsistent() async throws {
        let (_, db) = try tempDB("conc")
        let repo = JarvisRepository(database: db)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<120 {
                group.addTask { try? repo.addActivity(kind: "info", message: "event \(i)") }
                group.addTask { _ = try? repo.recentActivity(limit: 5); _ = try? repo.count("activity_events") }
            }
        }
        let n = try repo.count("activity_events")
        #expect(n == 120)
    }

    @Test func aFailedWriteRollsBackTheWholeTransaction() throws {
        let (_, db) = try tempDB("tx")
        struct Boom: Error {}
        do {
            try db.write { ctx in
                try ctx.execute("INSERT INTO projects(id, name, created_at) VALUES ('p1','a',0)")
                throw Boom()
            }
        } catch {}
        let remaining = try db.read("SELECT * FROM projects")
        #expect(remaining.isEmpty)
        // Foreign keys are enforced: an agent run for a task that doesn't exist is rejected.
        let repo = JarvisRepository(database: db)
        #expect(throws: DatabaseError.self) { try repo.insert(sampleRun(task: UUID())) }
    }

    @Test func aCorruptDatabaseIsMovedAsideAndReplaced() throws {
        let paths = JarvisPaths.temporary("corrupt"); try paths.ensureDirectories()
        try Data("this is definitely not a sqlite database, just garbage bytes".utf8).write(to: paths.database)
        let db = try JarvisDatabase(url: paths.database)
        let aside = try #require(db.recoveredFromCorruptionAt)
        #expect(FileManager.default.fileExists(atPath: aside.path))                // evidence kept, never deleted
        #expect(db.schemaVersion == Migration.latestVersion)
        let repo = JarvisRepository(database: db)
        try repo.addActivity(kind: "info", message: "works again")
        let n = try repo.count("activity_events")
        #expect(n == 1)
    }

    @Test func artifactsLiveOnDiskAndSQLiteOnlyHoldsReferences() throws {
        let (paths, db) = try tempDB("art")
        let repo = JarvisRepository(database: db)
        let store = ArtifactStore(paths: paths, database: db)
        let runID = sampleRun(); try repo.insert(runID)
        let big = Data(repeating: 0x41, count: 1_500_000)
        let rec = try store.store(big, type: "provider-output", folder: .providerOutput, agentRunID: runID.id)
        #expect(rec.relativePath.hasPrefix("provider-output/") && !rec.relativePath.hasPrefix("/"))
        #expect(FileManager.default.fileExists(atPath: paths.artifacts.appendingPathComponent(rec.relativePath).path))
        #expect(store.verify(rec) && rec.size == big.count && rec.sha256.count == 64)
        let dbSize = try FileManager.default.attributesOfItem(atPath: paths.database.path)[.size] as? Int ?? 0
        #expect(dbSize < 300_000, "the 1.5 MB payload must not be stored in SQLite (db is \(dbSize) bytes)")
        let linked = try store.artifacts(agentRunID: runID.id).map(\.id)
        #expect(linked == [rec.id])
        // Tampering is detected.
        try Data("tampered".utf8).write(to: paths.artifacts.appendingPathComponent(rec.relativePath))
        #expect(!store.verify(rec))
    }

    @Test func theRuntimeDatabaseIsNeverInsideTheRepository() throws {
        let std = JarvisPaths.standard()
        #expect(std.database.path.contains("/Library/Application Support/"))
        // Walk up from this source file to the repository root and prove the standard location is outside it.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var repo: URL?
        while dir.path != "/" { if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { repo = dir; break }; dir.deleteLastPathComponent() }
        let root = try #require(repo)
        #expect(!JarvisPaths.isInside(std.database, directory: root))
        #expect(!JarvisPaths.isInside(std.artifacts, directory: root))
        #expect(JarvisPaths.isInside(std.database, directory: std.root))
    }

    @Test func fileChangesAnswerWhoChangedAFile() throws {
        let (_, db) = try tempDB("who")
        let repo = JarvisRepository(database: db)
        var run = sampleRun(); run.model = "opencode/ling-3.1-flash-free"; try repo.insert(run)
        try repo.insert(FileChangeRecord(agentRunID: run.id, path: "Assets/Scripts/NetworkPlayer.cs", changeType: "modified",
                                         gitHash: "abc123", verificationResult: "compiled"))
        let hits = try repo.fileChanges(path: "NetworkPlayer.cs")            // by file name
        #expect(hits.count == 1)
        let changerID = try #require(hits.first?.agentRunID)
        let changerOpt = try repo.agentRun(changerID)
        let changer = try #require(changerOpt)
        #expect(changer.model == "opencode/ling-3.1-flash-free" && hits.first?.verificationResult == "compiled")
    }

    @Test func parentChildRunsAndInterruptedRunsAreQueryable() throws {
        let (_, db) = try tempDB("tree")
        let repo = JarvisRepository(database: db)
        let parent = sampleRun(); try repo.insert(parent)
        var child = sampleRun(parent: parent.id); child.status = .running; try repo.insert(child)
        let kids = try repo.children(of: parent.id).map(\.id)
        let interrupted = try repo.interruptedRuns().map(\.id)
        #expect(kids == [child.id])
        #expect(interrupted.contains(child.id))
    }

    @Test func activityIsBoundedAndRedacted() throws {
        let (_, db) = try tempDB("act")
        let repo = JarvisRepository(database: db)
        try repo.addActivity(kind: "info", message: "token = sk-abcdefghijklmnopqrstuvwxyz0123456789")
        let recent = try repo.recentActivity(limit: 1)
        let msg = try #require(recent.first?.2)
        #expect(!msg.contains("sk-abcdefgh") && msg.contains(Redactor.mask))
    }
}

@Suite("Redaction")
struct RedactionTests {
    @Test func secretsAreMaskedAndPromptsAreHashedNotStored() {
        let samples = [
            "my key is sk-proj-ABCDEFGHIJKLMNOPQRSTUV12345",
            "Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456",
            "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
            "AKIAABCDEFGHIJKLMNOP",
            "password = hunter2hunter2",
            "api_key: \"abcd-efgh-ijkl\"",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
            "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSj\n-----END PRIVATE KEY-----",
        ]
        for s in samples {
            #expect(Redactor.containsSecret(s), "\(s.prefix(30))")
            let out = Redactor.redact(s)
            #expect(out.contains(Redactor.mask))
            for fragment in ["ABCDEFGHIJKLMNOPQRSTUV", "abcdefghijklmnopqrstuvwxyz123456", "hunter2", "abcd-efgh", "MIIEvQIBADANBg"] { #expect(!out.contains(fragment)) }
        }
        #expect(!Redactor.containsSecret("Explain how a neural network works."))
        #expect(Redactor.excerpt("hello   world\n again", max: 100) == "hello world again")
        #expect(Redactor.excerpt("secret stuff", allowExcerpt: false) == "")
        #expect(Redactor.excerpt(String(repeating: "word ", count: 100), max: 20).count <= 21)
        #expect(Redactor.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
