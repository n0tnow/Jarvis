import Foundation
import Testing
@testable import Jarvis

// V1.0 background-intelligence pass — persistence reliability for long tasks, against the REAL SQLite layer in an isolated temporary directory (never the user's database, never the JARVIS repository).
// What a restart leaves behind, what a torn checkpoint is worth, that history stays bounded, and that concurrent writers do not corrupt anything.

private func tempStore(_ tag: String) throws -> (JarvisPaths, JarvisDatabase, JarvisRepository) {
    let paths = JarvisPaths.temporary(tag)
    try paths.ensureDirectories()
    let db = try JarvisDatabase(url: paths.database)
    return (paths, db, JarvisRepository(database: db))
}

private func makeSteps(_ taskID: UUID, _ spec: [(String, StepType, TaskStepState, [String])]) -> [TaskStepRecord] {
    spec.enumerated().map { i, s in
        TaskStepRecord(id: UUID(), taskID: taskID, index: i, key: s.0, title: s.0, type: s.1, dependsOn: s.3, validation: .default(for: s.1), state: s.2, attempts: s.2 == .passed ? 1 : 0, optional: false)
    }
}

private final class FailureCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@Suite("V1.0 background · database reliability for long tasks", .serialized)
struct DatabaseReliabilityTests {
    @Test("a restart interrupts running work and nothing else: passed steps stay passed, approvals keep waiting, finished tasks stay finished; a second reconcile changes nothing")
    func restart() throws {
        let (paths, db, repo) = try tempStore("bgrel-restart"); defer { db.close(); try? FileManager.default.removeItem(at: paths.root) }
        var running = TaskRecord(id: UUID(), title: "night", goal: "Refactor", kind: .development); running.state = .running
        var waiting = TaskRecord(id: UUID(), title: "gate", goal: "Delete old assets", kind: .development); waiting.state = .waitingForApproval
        var done = TaskRecord(id: UUID(), title: "done", goal: "Docs", kind: .development); done.state = .completed
        var failed = TaskRecord(id: UUID(), title: "failed", goal: "Build", kind: .development); failed.state = .failed
        for t in [running, waiting, done, failed] { try repo.insert(t) }
        try repo.insertSteps(makeSteps(running.id, [("a", .analysis, .passed, []), ("b", .codeChange, .passed, ["a"]), ("c", .build, .running, ["b"]), ("d", .test, .verifying, ["c"]), ("e", .review, .pending, ["d"])]))
        try repo.insertSteps(makeSteps(waiting.id, [("x", .delete, .waitingForApproval, [])]))
        try repo.insertSteps(makeSteps(done.id, [("p", .analysis, .passed, [])]))

        let first = try repo.reconcileTasksAfterRestart()
        #expect(first.tasks == [running.id] && first.steps == 2, Comment(rawValue: "\(first)"))
        let sRunning = try repo.engineTask(running.id)?.state, sWaiting = try repo.engineTask(waiting.id)?.state
        let sDone = try repo.engineTask(done.id)?.state, sFailed = try repo.engineTask(failed.id)?.state
        #expect(sRunning == .interrupted && sWaiting == .waitingForApproval && sDone == .completed && sFailed == .failed)
        let steps = try repo.steps(taskID: running.id)
        #expect(steps.map { $0.state } == [.passed, .passed, .interrupted, .interrupted, .pending])
        let gateSteps = try repo.steps(taskID: waiting.id)
        #expect(gateSteps.first?.state == .waitingForApproval)

        // what a person is told in the morning comes from that persisted state
        let view = TaskStatusDeriver.derive(task: .interrupted, steps: steps)
        #expect(view.status == .paused && view.stepsPassed == 2 && view.stepsTotal == 5)

        let second = try repo.reconcileTasksAfterRestart()
        #expect(second.tasks.isEmpty && second.steps == 0, "reconciliation is idempotent")
        let after = try repo.steps(taskID: running.id)
        #expect(after.map { $0.state } == steps.map { $0.state })
    }

    @Test("a row that cannot be decoded is skipped without hiding the healthy ones (current behaviour, pinned; the silent skip is a known limitation)")
    func undecodableRow() throws {
        let (paths, db, repo) = try tempStore("bgrel-corrupt"); defer { db.close(); try? FileManager.default.removeItem(at: paths.root) }
        var good = TaskRecord(id: UUID(), title: "good", goal: "ok", kind: .development); good.state = .interrupted
        var bad = TaskRecord(id: UUID(), title: "bad", goal: "broken", kind: .development); bad.state = .interrupted
        try repo.insert(good); try repo.insert(bad)
        try db.write { ctx in try ctx.execute("UPDATE tasks SET status = 'not-a-real-state' WHERE id = ?", [.text(bad.id.uuidString)]) }
        let listed = try repo.engineTasks(limit: 50).map(\.id)
        #expect(listed == [good.id], "the healthy task is listed, the undecodable row is skipped")
        let badTask = try repo.engineTask(bad.id)
        #expect(badTask == nil)
        // the raw row is still there: nothing was deleted, so the data is recoverable by a person
        let raw = try db.read("SELECT id FROM tasks WHERE id = ?", [.text(bad.id.uuidString)])
        #expect(raw.count == 1)
    }

    @Test("a torn checkpoint is not truth: truncation is detected by the recorded hash and a half-written JSON never decodes")
    func tornCheckpoint() throws {
        let (paths, db, _) = try tempStore("bgrel-ckpt"); defer { db.close(); try? FileManager.default.removeItem(at: paths.root) }
        let store = ArtifactStore(paths: paths, database: db)
        let payload = #"{"task":"night","passed":["a","b"],"next":"c","fingerprint":"abc123"}"#
        let rec = try store.store(Data(payload.utf8), type: "checkpoint", folder: .checkpoints, fileExtension: "json")
        #expect(store.verify(rec))
        // simulate power loss in the middle of an in-place write
        let url = paths.artifacts.appendingPathComponent(rec.relativePath)
        try Data(payload.prefix(31).utf8).write(to: url)
        #expect(!store.verify(rec), "the hash no longer matches")
        let torn = try Data(contentsOf: url)
        #expect((try? JSONSerialization.jsonObject(with: torn)) == nil, "the partial content is not valid JSON")
        // a missing file is also "not verified"
        try FileManager.default.removeItem(at: url)
        #expect(!store.verify(rec))
        // the replacement is written atomically: no temporary sibling is left behind
        let again = try store.store(Data(payload.utf8), type: "checkpoint", folder: .checkpoints, fileExtension: "json")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: paths.artifacts.appendingPathComponent(again.relativePath).deletingLastPathComponent().path)
        #expect(siblings.allSatisfy { $0.hasSuffix(".json") }, Comment(rawValue: "\(siblings)"))
    }

    @Test("checkpoint hygiene refuses reasoning, secrets and raw-audio references before anything is written")
    func hygiene() {
        let secret = "api_key=" + String(repeating: "Ab3", count: 12)
        #expect(CheckpointHygiene.safeEvidence("Build passed, 3 files changed") != nil)
        #expect(CheckpointHygiene.safeEvidence("<thinking>maybe the shader</thinking> done") == nil)
        #expect(CheckpointHygiene.safeEvidence("see capture" + ".wav") == nil)
        #expect(CheckpointHygiene.violations(in: secret).contains("secret-shaped text"))
        #expect((CheckpointHygiene.safeEvidence(String(repeating: "x", count: 5_000)) ?? "").count == 400)
    }

    @Test("the activity history is bounded however long the night, and a restart reopens the same data")
    func bounded() throws {
        let (paths, db, repo) = try tempStore("bgrel-bound"); defer { try? FileManager.default.removeItem(at: paths.root) }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<(JarvisRepository.activityRetention + 300) { try repo.addActivity(kind: "step", message: "step \(i) finished", at: t0.addingTimeInterval(Double(i))) }
        let n = try db.readOne("SELECT count(*) AS n FROM activity_events")?.int("n") ?? -1
        #expect(n <= JarvisRepository.activityRetention + 1, Comment(rawValue: "kept \(n)"))
        let newest = try repo.recentActivity(limit: 1).first?.2
        #expect(newest == "step \(JarvisRepository.activityRetention + 299) finished", "the newest event survives")
        db.close()
        let reopened = try JarvisDatabase(url: paths.database)
        defer { reopened.close() }
        #expect(reopened.schemaVersion == Migration.latestVersion)
        let reopenedCount = try reopened.readOne("SELECT count(*) AS n FROM activity_events")?.int("n")
        let mode = try reopened.readOne("PRAGMA journal_mode")?.string("journal_mode")
        #expect(reopenedCount == n && mode == "wal")
    }

    @Test("concurrent writers (8 threads × 100 events) neither lose nor corrupt rows")
    func concurrent() throws {
        let (paths, db, repo) = try tempStore("bgrel-conc"); defer { db.close(); try? FileManager.default.removeItem(at: paths.root) }
        let counter = FailureCounter()
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for i in 0..<100 {
                do { try repo.addActivity(kind: "w\(worker)", message: "event \(i)") } catch { counter.bump() }
            }
        }
        #expect(counter.value == 0)
        let total = try db.readOne("SELECT count(*) AS n FROM activity_events")?.int("n")
        let integrity = try db.readOne("PRAGMA integrity_check")?.string("integrity_check")
        #expect(total == 800 && integrity == "ok")
    }

    @Test("growth: 40 tasks × 120 steps stays small and reads stay fast; the database never holds a payload")
    func growth() throws {
        let (paths, db, repo) = try tempStore("bgrel-growth"); defer { db.close(); try? FileManager.default.removeItem(at: paths.root) }
        for n in 0..<40 {
            var t = TaskRecord(id: UUID(), title: "task \(n)", goal: "long running work \(n)", kind: .development); t.state = .completed
            try repo.insert(t)
            let spec: [(String, StepType, TaskStepState, [String])] = (0..<120).map { i in ("s\(i)", .analysis, .passed, i == 0 ? [] : ["s\(i - 1)"]) }
            try repo.insertSteps(makeSteps(t.id, spec))
        }
        let size = try FileManager.default.attributesOfItem(atPath: paths.database.path)[.size] as? Int ?? 0
        #expect(size < 12_000_000, Comment(rawValue: "db is \(size) bytes"))
        let started = Date()
        let tasks = try repo.engineTasks(limit: 50)
        let steps = try tasks.map { try repo.steps(taskID: $0.id).count }.reduce(0, +)
        #expect(tasks.count == 40 && steps == 4_800)
        #expect(Date().timeIntervalSince(started) < 5, "reads stay fast")
    }
}
