import Testing
import Foundation
@testable import Jarvis

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func digest(_ title: String, _ state: TaskState, kind: String = "development", category: String? = nil, reason: String? = nil, origin: UUID? = nil, ago: TimeInterval = 3_600, passed: Int = 2, total: Int = 5) -> TaskDigest {
    TaskDigest(title: title, goal: title, kind: kind, state: state, failureCategory: category, failureReason: reason, updatedAt: t0.addingTimeInterval(-ago), originTaskID: origin, passed: passed, total: total)
}

private func inputs(tasks: [TaskDigest] = [], checkpoint: ContinuityCheckpoint? = nil, queue: [String] = [], memory: [MemoryDigest] = [], docs: ProjectDocsSummary? = nil, git: ContinuityGit = .none, unity: ContinuityUnity? = nil) -> ContinuityBuilder.Inputs {
    ContinuityBuilder.Inputs(key: "git:abc", name: "Hamam", root: "/tmp/hamam", docs: docs, tasks: tasks, checkpoint: checkpoint, queue: queue, git: git, unity: unity, memory: memory, now: t0)
}

private func checkpoint(head: String? = "aaa", dirty: [String] = [], hashes: [String: String] = [:], next: [String] = []) -> ContinuityCheckpoint {
    var c = ContinuityCheckpoint(projectKey: "git:abc", kind: "task", outcome: "SUCCESS", title: "Fix the pickup")
    c.gitHead = head; c.dirtyPaths = dirty; c.fileHashes = hashes; c.next = next; c.createdAt = t0.addingTimeInterval(-7_200)
    return c
}

private func snapshot(head: String? = "aaa", dirty: [String] = [], untracked: [String] = [], hashes: [String: String] = [:], isGit: Bool = true, fingerprint: String? = nil) -> ProjectSnapshot {
    ProjectSnapshot(root: "/tmp/hamam", git: isGit ? ContinuityGit(isRepository: true, branch: "main", head: head, subject: "s", dirtyPaths: dirty, untrackedPaths: untracked) : .none, fileHashes: hashes, treeFingerprint: fingerprint, unity: nil)
}

// MARK: - Recognising the phrases (typed and spoken alike)

@Suite("Continuity · intents")
struct ContinuityIntentTests {
    @Test("project status questions — Turkish and English — are recognised with the project name")
    func status() {
        #expect(ContinuityIntent.recognize("Hamam projesinde ne durumdayız?") == .status(project: "hamam", detailed: false))
        #expect(ContinuityIntent.recognize("Jarvis, hamam projesinde ne durumdayız") == .status(project: "hamam", detailed: false))
        #expect(ContinuityIntent.recognize("Where do we stand on this project?") == .status(project: nil, detailed: false))
        #expect(ContinuityIntent.recognize("Where do we stand?") == .status(project: nil, detailed: false))
        #expect(ContinuityIntent.recognize("Nerede kalmıştık?") == .status(project: nil, detailed: false))
        #expect(ContinuityIntent.recognize("Where did we leave off?") == .status(project: nil, detailed: false))
        #expect(ContinuityIntent.recognize("What's the status of the Hamam project?") == .status(project: "hamam", detailed: false))
        #expect(ContinuityIntent.recognize("Where are we on the game?") == .status(project: nil, detailed: false))
        #expect(ContinuityIntent.recognize("Detaylı proje durumunu ver") == .status(project: nil, detailed: true))
    }

    @Test("last report, last thing done and what is next")
    func others() {
        #expect(ContinuityIntent.recognize("Son raporu ver.") == .lastReport(project: nil, detailed: false))
        #expect(ContinuityIntent.recognize("Detaylı son rapor") == .lastReport(project: nil, detailed: true))
        #expect(ContinuityIntent.recognize("En son ne yaptık?") == .lastDone(project: nil))
        #expect(ContinuityIntent.recognize("What did we do last?") == .lastDone(project: nil))
        #expect(ContinuityIntent.recognize("Şu an sırada ne var?") == .next(project: nil))
        #expect(ContinuityIntent.recognize("What is next?") == .next(project: nil))
    }

    @Test("“continue” is contextual project continuation — only as a whole request, never inside another sentence")
    func continuing() {
        func isContinue(_ s: String) -> Bool { if case .continueProject = ContinuityIntent.recognize(s) { return true }; return false }
        for s in ["Devam et.", "Tamam. Kaldığımız yerden devam et.", "Projeye devam et", "Sonraki işe geç", "Continue.", "Pick up where we left off", "Jarvis, continue the project", "ok continue"] {
            #expect(isContinue(s), Comment(rawValue: s))
        }
        #expect(ContinuityIntent.recognize("Hamam projesine devam et") == .continueProject(project: "hamam"))
        for s in ["I will continue later", "continue reading the file in the editor please and tell me what it does", "devam etmek istemiyorum", "Durum ne?", "What are you doing?", "Open the report", "Fix the pickup bug"] {
            #expect(ContinuityIntent.recognize(s) == nil, Comment(rawValue: s))
        }
    }

    @Test("the V0.12 task status questions are untouched: no project cue ⇒ no project intent")
    func taskStatusUntouched() {
        for s in ["Durum ne?", "Hangi agent çalışıyor?", "Testler geçti mi?", "What are you doing?", "status"] { #expect(ContinuityIntent.recognize(s) == nil, Comment(rawValue: s)) }
    }

    @Test("the user queues the accepted next step; questions about the next step do not")
    func queue() {
        #expect(ContinuityIntent.recognize("Next up is the pickup polish.") == .queueNext(project: nil, text: "the pickup polish"))
        #expect(ContinuityIntent.recognize("Sırada müşteri etkileşimleri var") == .queueNext(project: nil, text: "müşteri etkileşimleri"))
        #expect(ContinuityIntent.recognize("The next step is wiring the audio mixer") == .queueNext(project: nil, text: "wiring the audio mixer"))
        func isQueue(_ s: String) -> Bool { if case .queueNext = ContinuityIntent.recognize(s) { return true }; return false }
        #expect(!isQueue("Sırada ne var?") && !isQueue("What is next?"))
    }

    @Test("a pending choice is answered by an ordinal")
    func ordinals() {
        #expect(ContinuityIntent.ordinal("1") == 1 && ContinuityIntent.ordinal("ikincisi") == 2 && ContinuityIntent.ordinal("the third one") == 3 && ContinuityIntent.ordinal("ilki") == 1)
        #expect(ContinuityIntent.ordinal("fix the pickup") == nil)
    }
}

// MARK: - The derived view and what “continue” means

@Suite("Continuity · view and selection")
struct ContinuitySelectionTests {
    @Test("an interrupted task wins over everything else and is resumed (not duplicated) when nothing changed")
    func resume() {
        let t = digest("Fix the throw", .interrupted)
        let v = ContinuityBuilder.build(inputs(tasks: [t, digest("Old failure", .failed, category: "testFailed", reason: "tests failed")], checkpoint: checkpoint(next: ["Polish pickup"])))
        #expect(v.interrupted.map(\.id) == [t.id])
        #expect(ContinuationSelector.decide(v, drift: ReconciliationReport()) == .resumeInterrupted(t))
    }

    @Test("when the project changed under an interrupted task its old plan is not trusted: re-plan")
    func replan() {
        let t = digest("Fix the throw", .interrupted)
        let v = ContinuityBuilder.build(inputs(tasks: [t], checkpoint: checkpoint()))
        var drift = ReconciliationReport(); drift.changedPaths = ["Assets/Scripts/Throw.cs"]
        guard case .replanInterrupted(let got, let lines) = ContinuationSelector.decide(v, drift: drift) else { Issue.record("expected replan"); return }
        #expect(got.id == t.id && lines.contains { $0.contains("Throw.cs") })
    }

    @Test("an interrupted task that a later task already continues is not offered again")
    func noDuplicate() {
        let old = digest("Fix the throw", .interrupted)
        let newer = digest("Fix the throw", .running, origin: old.id)
        let v = ContinuityBuilder.build(inputs(tasks: [newer, old]))
        #expect(v.interrupted.isEmpty && ContinuationSelector.decide(v, drift: ReconciliationReport()) == .alreadyRunning(newer))
    }

    @Test("two interrupted tasks are not guessed between")
    func twoInterrupted() {
        let v = ContinuityBuilder.build(inputs(tasks: [digest("A task", .interrupted), digest("B task", .interrupted)]))
        guard case .needsChoice(let cs) = ContinuationSelector.decide(v, drift: ReconciliationReport()) else { Issue.record("expected a choice"); return }
        #expect(cs.count == 2)
    }

    @Test("a recent failed task is retried once with its evidence — never forever")
    func failedRetry() {
        let f = digest("Fix the throw", .failed, category: "testFailed", reason: "2 tests failed")
        let v = ContinuityBuilder.build(inputs(tasks: [f]))
        #expect(ContinuationSelector.decide(v, drift: ReconciliationReport()) == .retryFailed(f))
        let retry = digest("Fix the throw", .failed, category: "testFailed", reason: "still failing", origin: f.id)
        let v2 = ContinuityBuilder.build(inputs(tasks: [retry, f]))
        #expect(!v2.failed.contains { $0.id == f.id }, "already retried once")
        let goal = ContinuationGoal.build(.retryFailed(f), view: v, drift: ReconciliationReport())
        #expect(goal?.contains("2 tests failed") == true && goal?.contains("do not repeat the same approach") == true)
    }

    @Test("a retry that failed too is EXHAUSTED: the same recorded next step is not started a third time — JARVIS reports it and waits for direction")
    func exhausted() {
        let f = digest("Add a mul test", .failed, category: "providerFailed", reason: "the provider failed", ago: 600)
        var retry = digest("Add a mul test", .failed, category: "providerFailed", reason: "the provider failed again", origin: f.id, ago: 60)
        retry.isContinuation = true
        let v = ContinuityBuilder.build(inputs(tasks: [retry, f], docs: ProjectDocsSummary(next: ["Add a mul test"])))
        #expect(v.exhausted == ["Add a mul test"] && v.failed.isEmpty)
        #expect(v.candidates.isEmpty, "neither as a retry nor as the same recorded next step")
        guard case .nothingToContinue(let why) = ContinuationSelector.decide(v, drift: ReconciliationReport()) else { Issue.record("expected nothingToContinue"); return }
        #expect(why.contains("failed twice") && why.contains("without your direction"))
        // a different next step is still offered; a later success clears the exhaustion
        let other = ContinuityBuilder.build(inputs(tasks: [retry, f], docs: ProjectDocsSummary(next: ["Add a mul test", "Polish the README"])))
        #expect(other.candidates.map(\.title) == ["Polish the README"])
        let done = digest("Add a mul test", .completed, ago: 5)
        #expect(ContinuityBuilder.build(inputs(tasks: [done, retry, f])).exhausted.isEmpty)
        // the status says so, even though nothing is retriable
        let said = ContinuityStatus.lastDone(v, language: .en, now: t0)
        #expect(said.contains("failed") && said.contains("Add a mul test"))
    }

    @Test("memory alone never starts work: a known issue that exists only as a memory item is PROPOSED (needsChoice), while a recorded next step in the project's own docs starts")
    func memoryOnlyNeverStarts() {
        let m = [MemoryDigest(type: .knownIssue, subject: "pickup", summary: "Pickup jitters on slopes")]
        let only = ContinuityBuilder.build(inputs(memory: m))
        guard case .needsChoice(let cs) = ContinuationSelector.decide(only, drift: ReconciliationReport()) else { Issue.record("memory-only work must be proposed, not started"); return }
        #expect(cs.count == 1 && cs[0].source == .knownIssue)
        let withDocs = ContinuityBuilder.build(inputs(memory: m, docs: ProjectDocsSummary(next: ["Polish the bucket pickup"])))
        if case .startNext(let c) = ContinuationSelector.decide(withDocs, drift: ReconciliationReport()) { #expect(c.source == .checkpoint) } else { Issue.record("a documented next step is current truth and starts") }
    }

    @Test("old failures and failures that need a decision are not retried; they are blockers")
    func notRetriable() {
        let old = digest("Ancient", .failed, category: "testFailed", reason: "x", ago: 9 * 86_400)
        let policy = digest("Delete assets", .failed, category: "approvalDenied", reason: "you declined")
        let v = ContinuityBuilder.build(inputs(tasks: [old, policy]))
        #expect(v.failed.isEmpty && v.blockers.contains { $0.contains("Delete assets") })
        guard case .nothingToContinue(let why) = ContinuationSelector.decide(v, drift: ReconciliationReport()) else { Issue.record("expected nothing to continue"); return }
        #expect(why.contains("needs your decision"))
    }

    @Test("an accepted next step is started; several equally open ones are asked, not invented")
    func nextSteps() {
        let one = ContinuityBuilder.build(inputs(queue: ["Customer interactions"]))
        guard case .startNext(let c) = ContinuationSelector.decide(one, drift: ReconciliationReport()) else { Issue.record("expected startNext"); return }
        #expect(c.title == "Customer interactions" && c.source == .checkpoint)
        let two = ContinuityBuilder.build(inputs(queue: ["Customer interactions", "Scene lighting"]))
        guard case .needsChoice(let cs) = ContinuationSelector.decide(two, drift: ReconciliationReport()) else { Issue.record("expected a choice"); return }
        #expect(cs.map(\.title) == ["Customer interactions", "Scene lighting"])
    }

    @Test("queue, checkpoint and docs are merged without duplicates; the project's own docs count as recorded work")
    func recorded() {
        let docs = ProjectDocsSummary(milestone: "Alpha", goal: "Hamam cleaning game", next: ["Scene lighting", "customer interactions"])
        let v = ContinuityBuilder.build(inputs(checkpoint: checkpoint(next: ["Customer interactions"]), queue: ["Pickup polish"], docs: docs))
        #expect(v.recordedNext.map(\.text) == ["Pickup polish", "Customer interactions", "Scene lighting"])
        #expect(v.recordedNext.map(\.origin) == ["queued by you", "recorded at the last checkpoint", "listed in the project docs"])
        #expect(v.primaryGoal == "Hamam cleaning game" && v.milestone == "Alpha")
    }

    @Test("a major design change is only ever PROPOSED: never started under a plain “continue”")
    func designSensitive() {
        #expect(MajorDesign.isMajor("Replace the main character with a new model"))
        #expect(MajorDesign.isMajor("Migrate to a different render pipeline"))
        #expect(MajorDesign.isMajor("Switch to a new networking architecture"))
        #expect(!MajorDesign.isMajor("Polish the pickup animation") && !MajorDesign.isMajor("Fix the camera jitter"))
        let v = ContinuityBuilder.build(inputs(queue: ["Replace the main character with a new model"]))
        guard case .needsChoice(let cs) = ContinuationSelector.decide(v, drift: ReconciliationReport()) else { Issue.record("expected a proposal"); return }
        #expect(cs.first?.designSensitive == true)
        #expect(ContinuityStatus.choice(cs, view: v, language: .en).contains("won't decide that"))
    }

    @Test("nothing to continue says so and asks what to do")
    func nothing() {
        let v = ContinuityBuilder.build(inputs())
        #expect(ContinuationSelector.decide(v, drift: ReconciliationReport()) == .nothingToContinue("There is no unfinished work, failed task or recorded next step for this project."))
    }

    @Test("project memory feeds issues, constraints and decisions — as context, bounded")
    func memory() {
        let m = [MemoryDigest(type: .knownIssue, subject: "pickup", summary: "Pickup jitters on slopes"), MemoryDigest(type: .constraint, subject: "camera", summary: "Never change the working camera rig"),
                 MemoryDigest(type: .decision, subject: "net", summary: "Netcode stays on NGO")]
        let v = ContinuityBuilder.build(inputs(memory: m))
        #expect(v.openIssues == ["Pickup jitters on slopes"] && v.constraints == ["Never change the working camera rig"] && v.decisions == ["Netcode stays on NGO"])
        #expect(ContinuationGoal.build(.startNext(NextCandidate(id: "x", source: .checkpoint, title: "Polish pickup", detail: "d")), view: v, drift: ReconciliationReport())?.contains("Never change the working camera rig") == true)
    }
}

// MARK: - Reconciliation: current truth wins

@Suite("Continuity · reconciliation")
struct ContinuityReconcileTests {
    @Test("nothing changed ⇒ no drift")
    func calm() {
        let e = ExpectedState(checkpoint: checkpoint(hashes: ["a.cs": "h1"]))
        let r = ContinuityReconciler.reconcile(expected: e, current: snapshot(hashes: ["a.cs": "h1"]))
        #expect(!r.hasDrift && r.changedPaths.isEmpty && !r.firstSession)
    }

    @Test("no checkpoint ⇒ first session, no invented drift")
    func first() {
        let r = ContinuityReconciler.reconcile(expected: ExpectedState(checkpoint: nil), current: snapshot())
        #expect(r.firstSession && !r.hasDrift)
    }

    @Test("a moved HEAD and an edited file are external changes")
    func external() {
        let e = ExpectedState(checkpoint: checkpoint(hashes: ["a.cs": "h1"]))
        let r = ContinuityReconciler.reconcile(expected: e, current: snapshot(head: "bbb", hashes: ["a.cs": "h2"]))
        #expect(r.headMoved && r.changedPaths == ["a.cs"] && r.hasDrift)
        #expect(r.lines.contains { $0.contains("HEAD moved") } && r.lines.contains { $0.contains("a.cs") })
    }

    @Test("a file JARVIS wrote itself after the checkpoint is not interference — until someone edits it again")
    func jarvisOwn() {
        let e = ExpectedState(checkpoint: checkpoint(hashes: ["a.cs": "h1"]), laterChanges: ["a.cs": "h2", "b.cs": "h9"])
        #expect(!ContinuityReconciler.reconcile(expected: e, current: snapshot(untracked: ["b.cs"], hashes: ["a.cs": "h2", "b.cs": "h9"])).hasDrift)
        #expect(ContinuityReconciler.reconcile(expected: e, current: snapshot(untracked: ["b.cs"], hashes: ["a.cs": "h3", "b.cs": "h9"])).changedPaths == ["a.cs"])
    }

    @Test("a new uncommitted file nobody at JARVIS wrote is the user's change; a file JARVIS wrote and that vanished is too")
    func newAndGone() {
        let e = ExpectedState(checkpoint: checkpoint(hashes: ["a.cs": "h1"]))
        let r = ContinuityReconciler.reconcile(expected: e, current: snapshot(dirty: ["notes.md"], hashes: [:]))
        #expect(Set(r.changedPaths) == ["notes.md", "a.cs"])
        let del = ExpectedState(checkpoint: checkpoint(hashes: ["gone.cs": "deleted"]))
        #expect(!ContinuityReconciler.reconcile(expected: del, current: snapshot(hashes: [:])).hasDrift, "JARVIS deleted it itself")
    }

    @Test("a dirty file that was already dirty at the checkpoint is not new")
    func alreadyDirty() {
        let e = ExpectedState(checkpoint: checkpoint(dirty: ["wip.cs"]))
        #expect(!ContinuityReconciler.reconcile(expected: e, current: snapshot(dirty: ["wip.cs"])).hasDrift)
    }

    @Test("without Git the tree fingerprint decides")
    func fingerprint() {
        var cp = checkpoint(); cp.treeFingerprint = "f1"
        #expect(ContinuityReconciler.reconcile(expected: ExpectedState(checkpoint: cp), current: snapshot(isGit: false, fingerprint: "f1")).hasDrift == false)
        #expect(ContinuityReconciler.reconcile(expected: ExpectedState(checkpoint: cp), current: snapshot(isGit: false, fingerprint: "f2")).hasDrift)
    }

    @Test("memory corrections are carried through and shown")
    func corrections() {
        let r = ContinuityReconciler.reconcile(expected: ExpectedState(checkpoint: checkpoint()), current: snapshot(), memoryCorrections: ["unity.version: memory said “6000.0”, the project says “6000.5”"])
        #expect(r.lines == ["unity.version: memory said “6000.0”, the project says “6000.5”"] && !r.hasDrift)
    }
}

// MARK: - What the user hears

@Suite("Continuity · answers")
struct ContinuityAnswerTests {
    private func view() -> ProjectContinuityView {
        var cp = checkpoint(next: ["Customer interactions"]); cp.validated = ["Tests: 31 passed"]
        return ContinuityBuilder.build(inputs(tasks: [digest("Fix the pickup", .completed, passed: 5, total: 5), digest("Network throw", .interrupted)], checkpoint: cp,
                                              git: ContinuityGit(isRepository: true, branch: "main", head: "abcdef1234", subject: "x", dirtyPaths: [], untrackedPaths: []),
                                              unity: ContinuityUnity(version: "6000.5.1f1", renderPipeline: "Universal (URP)", packageCount: 20, sceneCount: 3, bridgeInstalled: true, hasTests: true, editor: nil)))
    }

    @Test("the status is short, factual and contains the sources it used — Turkish and English")
    func shortFacts() {
        let en = ContinuityStatus.summary(view(), drift: nil, language: .en, now: t0)
        #expect(en.contains("Fix the pickup") && en.contains("Git is clean (main@abcdef1)") && en.contains("Unity 6000.5.1f1") && en.contains("Network throw") && en.contains("Customer interactions") && en.contains("tests: 31 passed"))
        #expect(en.count <= ContinuityLimits.maxReplyChars)
        let tr = ContinuityStatus.summary(view(), drift: nil, language: .tr, now: t0)
        #expect(tr.contains("son doğrulanan iş") && tr.contains("Git temiz") && tr.contains("Yarım kalan") && tr.contains("Sırada"))
    }

    @Test("drift is part of the answer, and nothing is claimed that is not in the records")
    func driftSentence() {
        var r = ReconciliationReport(); r.changedPaths = ["a.cs", "b.cs"]; r.headMoved = true
        let s = ContinuityStatus.summary(view(), drift: r, language: .en, now: t0)
        #expect(s.contains("changed outside JARVIS") && s.contains("2 files") && s.contains("HEAD moved"))
        let empty = ContinuityStatus.summary(ContinuityBuilder.build(inputs()), drift: nil, language: .en, now: t0)
        #expect(empty.contains("no finished work recorded"))
    }

    @Test("a detailed answer adds goal, decisions, constraints and open issues; the short one does not")
    func detailed() {
        var v = view(); v.primaryGoal = "Hamam cleaning game"; v.decisions = ["Netcode stays on NGO"]; v.constraints = ["Keep the camera"]
        let short = ContinuityStatus.summary(v, drift: nil, language: .en, now: t0), long = ContinuityStatus.summary(v, drift: nil, language: .en, detailed: true, now: t0)
        #expect(!short.contains("Netcode") && long.contains("Netcode stays on NGO") && long.contains("Keep the camera") && long.contains("Hamam cleaning game"))
    }

    @Test("the answer is sanitized: a secret that reached a title never reaches the user")
    func sanitized() {
        let key = "sk-" + String(repeating: "a", count: 30)
        let v = ContinuityBuilder.build(inputs(tasks: [digest("Fix login with key \(key)", .completed)]))
        #expect(!ContinuityStatus.summary(v, drift: nil, language: .en, now: t0).contains(key))
    }

    @Test("a derived goal grants nothing: bounded, no authority words, session bounds stated")
    func goalGrantsNothing() {
        let v = ContinuityBuilder.build(inputs(queue: ["Polish the pickup animation"]))
        let c = NextCandidate(id: "n", source: .checkpoint, title: "Polish the pickup animation", detail: "queued by you")
        let g = ContinuationGoal.build(.startNext(c), view: v, drift: ReconciliationReport())!
        #expect(g.contains("Session bounds:") && g.contains("30 min") && g.contains("propose it instead"))
        #expect(!MemoryGate.grantsAuthority(g))
        #expect(ContinuationBounds.standard.maxNodes <= OrchestrationLimits.maxNodes && ContinuationBounds.standard.maxCorrectionRounds == 2)
    }

    @Test("the project's own docs name the milestone, the goal and what is next — read as data")
    func docs() throws {
        let dir = NSTemporaryDirectory() + "docs-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/docs", withIntermediateDirectories: true)
        try "# Current Task\n\nVersion:\nAlpha 0.3 — pickup\n\nTask:\nFinish the pickup and throw\n\nNext Step:\nCustomer interactions\n- Scene lighting pass\n\nBlocked By:\nNothing.\n".write(toFile: dir + "/docs/CURRENT_TASK.md", atomically: true, encoding: .utf8)
        try "- [ ] Audio mixer\n- [x] Done thing\n".write(toFile: dir + "/TODO.md", atomically: true, encoding: .utf8)
        let d = ProjectDocsSummary.read(root: dir)
        #expect(d.milestone == "Alpha 0.3 — pickup" && d.goal == "Finish the pickup and throw")
        #expect(d.next == ["Customer interactions", "Scene lighting pass", "Audio mixer"])
    }
}

// MARK: - Persistence (schema v11)

@Suite("Continuity · persistence")
struct ContinuityPersistenceTests {
    @Test("a fresh database and an upgrade from V0.12's schema v10 both reach v11 with the continuity tables")
    func migration() throws {
        #expect(Migration.latestVersion >= 11)
        let p = JarvisPaths.temporary("cont-mig"); try p.ensureDirectories()
        let db = try JarvisDatabase(url: p.database)
        #expect(db.schemaVersion == Migration.latestVersion)
        let tables = try db.read("SELECT name FROM sqlite_master WHERE name IN ('project_checkpoints','project_continuity')")
        #expect(tables.count == 2)

        // Upgrade: build a v10 database, keep a row, open it with the current build.
        let up = JarvisPaths.temporary("cont-up"); try up.ensureDirectories()
        let v10 = try JarvisDatabase(url: up.database, migrations: Migration.all.filter { $0.version <= 10 })
        let hadTable = try v10.read("SELECT name FROM sqlite_master WHERE name = 'project_checkpoints'")
        #expect(v10.schemaVersion == 10 && hadTable.isEmpty)
        let upgraded = try JarvisDatabase(url: up.database)
        #expect(upgraded.schemaVersion == Migration.latestVersion)
        let after = try upgraded.read("SELECT name FROM sqlite_master WHERE name = 'project_checkpoints'")
        #expect(after.count == 1)
    }

    @Test("checkpoints round-trip, stay bounded and sanitized, and prune to the newest")
    func checkpoints() throws {
        let p = JarvisPaths.temporary("cont-cp"); try p.ensureDirectories()
        let repo = JarvisRepository(database: try JarvisDatabase(url: p.database))
        let key = "sk-" + String(repeating: "b", count: 30)
        var c = ContinuityCheckpoint(projectKey: "git:abc", kind: "continuation", outcome: "SUCCESS", title: "Fix \(key)")
        c.changed = (0..<200).map { "f\($0).cs" }; c.fileHashes = Dictionary(uniqueKeysWithValues: (0..<500).map { ("f\($0).cs", "h\($0)") }); c.next = ["Customer interactions"]
        try repo.insert(c)
        let back = try #require(try repo.latestCheckpoint(projectKey: "git:abc"))
        #expect(!back.title.contains(key) && back.changed.count == 60 && back.fileHashes.count == ContinuityLimits.maxFileHashes && back.next == ["Customer interactions"])
        for i in 0..<40 { var x = ContinuityCheckpoint(projectKey: "git:abc", outcome: "SUCCESS", title: "t\(i)"); x.createdAt = Date().addingTimeInterval(Double(i)); try repo.insert(x) }
        _ = try repo.pruneCheckpoints(keep: 30)
        #expect(try repo.checkpoints(projectKey: "git:abc", limit: 100).count == 30)
        #expect(try repo.latestCheckpoint(projectKey: "git:abc")?.title == "t39")
    }

    @Test("the queue and the session counter persist; children of a graph never count as the project's tasks")
    func stateAndTasks() throws {
        let p = JarvisPaths.temporary("cont-st"); try p.ensureDirectories()
        let repo = JarvisRepository(database: try JarvisDatabase(url: p.database))
        try repo.saveContinuity(ContinuityState(projectKey: "k", lastContinuationAt: nil, lastTaskID: nil, sessions: 0, queue: ["A item", "B item"]))
        try repo.recordContinuationSession(projectKey: "k", taskID: UUID())
        let st = try #require(try repo.continuityState("k"))
        #expect(st.sessions == 1 && st.queue == ["A item", "B item"] && st.lastContinuationAt != nil)

        var root = TaskRecord(id: UUID(), title: "Root", goal: "g", kind: .development); root.workspaceRoot = "/tmp/proj"
        var child = TaskRecord(id: UUID(), title: "Child", goal: "g", kind: .research); child.workspaceRoot = "/tmp/proj"; child.parentTaskID = root.id
        var other = TaskRecord(id: UUID(), title: "Other", goal: "g", kind: .development); other.workspaceRoot = "/tmp/else"
        for t in [root, child, other] { try repo.insert(t) }
        #expect(try repo.continuityTasks(roots: ["/tmp/proj"]).map(\.title) == ["Root"])
        #expect(try repo.continuityTasks(roots: ["/tmp/proj", "/tmp/else"]).count == 2, "known aliases of one project are all searched")
    }
}

// MARK: - V0.13.1 — the Project card's scene facts: live, or history labelled as such

@Suite("Continuity · scene facts (Project card)")
struct UnitySceneFactsTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func facts(live: Bool, age: TimeInterval = 0, dirty: Bool = false, broken: Int = 0, cameras: Int = 1, lights: Int = 2) -> UnitySceneFacts {
        UnitySceneFacts(scene: "Assets/Scenes/Bathhouse.unity", objectCount: 18, cameras: cameras, lights: lights, missingScripts: broken, missingReferences: 0, isPlaying: false, hasUnsavedChanges: dirty, capturedAt: t0.addingTimeInterval(-age), live: live)
    }

    @Test("a live reading says so; a remembered one is NEVER live and always says how old it is and that the editor is not connected")
    func freshness() {
        #expect(facts(live: true).freshness(now: t0).hasPrefix("live"))
        let old = facts(live: true, age: 7_200).remembered
        #expect(!old.live && old.freshness(now: t0).contains("2 h ago") && old.freshness(now: t0).contains("not connected") && old.freshness(now: t0).contains("out of date"))
        #expect(facts(live: false, age: 20).freshness(now: t0).contains("a moment ago"))
        #expect(facts(live: false, age: 3 * 86_400).freshness(now: t0).contains("3 days ago"))
        #expect(!facts(live: true).remembered.live, "remembering never makes a reading live again")
    }

    @Test("the headline is compact numbers only; warnings are concise and only when there is something to warn about")
    func lineAndWarnings() {
        #expect(facts(live: true).line == "Bathhouse · 18 objects · 1 camera · 2 lights · Edit Mode · saved")
        #expect(facts(live: true).warnings.isEmpty)
        let bad = facts(live: true, dirty: true, broken: 3, cameras: 0, lights: 0)
        #expect(bad.warnings.count == 4 && bad.warnings[0].contains("3 broken references") && bad.warnings.contains("no camera in the scene") && bad.warnings.contains("unsaved changes"))
        #expect(!facts(live: true).line.contains("/") && facts(live: true).line.count < 90, "no hierarchy, no paths")
    }

    @Test("built from the editor's own profile answer")
    func fromProfile() {
        let f = UnitySceneFacts(profile: ["scene": "Assets/Scenes/A.unity", "objectCount": 7, "cameras": 1, "lights": 1, "missingScripts": 2, "missingReferences": 1, "dirty": true], isPlaying: true, now: t0)
        #expect(f.live && f.brokenReferences == 3 && f.hasUnsavedChanges && f.isPlaying && f.line.contains("Play Mode") && f.line.contains("unsaved"))
    }
}

@MainActor
@Suite("Continuity · scene facts from the Unity service", .serialized)
struct UnitySceneServiceTests {
    @Test("a connected editor gives LIVE facts; once it is gone the same numbers come back as history (never live); a project never read gives nothing; nothing is started or polled")
    func liveThenHistory() async throws {
        let h = UnityHarness(script: UnityScripts.standard(plan: UnityScripts.addCollider), editorAlive: true)
        let service = h.service
        #expect(await service.sceneFacts(for: h.project) == nil, "no connection yet: nothing to read, and the card must not start an editor")
        #expect(h.launcher.launched.isEmpty)
        #expect(await service.prepare(root: h.project, approvedInstall: true, approvedUpgrade: false) == .ready)
        let live = try #require(await service.sceneFacts(for: h.project))
        #expect(live.live && live.objectCount > 0, "\(live)")
        let before = h.editor.received.count
        h.editor.alive = false
        service.existingConnection(for: h.project)?.apply(status: nil)
        let history = try #require(await service.sceneFacts(for: h.project))
        #expect(!history.live && history.objectCount == live.objectCount && history.freshness().contains("not connected"))
        #expect(h.editor.received.count == before, "with the editor gone nothing was sent")
        #expect(h.launcher.launched.isEmpty, "reading scene facts never launches an editor")
    }
}
