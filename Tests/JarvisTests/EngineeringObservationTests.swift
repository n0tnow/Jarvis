import Foundation
import Testing
@testable import Jarvis

// V1.0 autonomous engineering pipeline — observed repository state: snapshots, the real change set, a pre-existing dirty tree, attribution, rollback planning and temporary-artifact hygiene.
// Every test builds a DISPOSABLE Git repository (never the JARVIS repository, never a real project) and runs real `git`.

private let base: [String: String] = [
    "calc.py": "def add(a, b):\n    return a - b\n",
    "util.py": "def helper():\n    return 1\n",
    "notes.txt": "original notes\n",
    "tests/test_calc.py": "import unittest\nfrom calc import add\n\nclass T(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(add(2, 3), 5)\n",
]

@Suite("V1.0 engineering · snapshots and the real change set", .serialized)
struct EngineeringSnapshotTests {
    @Test("a snapshot fingerprints files, ignores VCS internals, and its digest follows the content")
    func snapshot() {
        let f = EngFixture(files: base)
        let s1 = WorkspaceSnapshotter.capture(root: f.root, git: f.gitFacts())
        #expect(s1.files.keys.sorted() == ["calc.py", "notes.txt", "tests/test_calc.py", "util.py"], "no .git content")
        #expect(s1.files["calc.py"]?.hash.count == 64 && s1.files["calc.py"]?.isBinary == false)
        let again = WorkspaceSnapshotter.capture(root: f.root, git: f.gitFacts())
        #expect(again.digest == s1.digest)
        f.write("calc.py", "def add(a, b):\n    return a + b\n")
        let s2 = WorkspaceSnapshotter.capture(root: f.root, git: f.gitFacts())
        #expect(s2.digest != s1.digest)
        let changes = SnapshotDiff.between(s1, s2)
        #expect(changes.map(\.path) == ["calc.py"] && changes[0].kind == .modified && changes[0].beforeHash != changes[0].afterHash)
        f.write("new.py", "x = 1\n"); f.remove("util.py")
        let kinds = Dictionary(uniqueKeysWithValues: SnapshotDiff.between(s1, WorkspaceSnapshotter.capture(root: f.root, git: f.gitFacts())).map { ($0.path, $0.kind) })
        #expect(kinds["new.py"] == .created && kinds["util.py"] == .deleted && kinds["calc.py"] == .modified)
    }

    @Test("somebody else's change seen before the next attempt is folded into the baseline (not the task's, not a scope escape); the task's own earlier changes are not")
    func rebase() {
        let f = EngFixture(files: base)
        let (start, _) = f.capture()
        f.write("notes.txt", "edited by the user meanwhile\n"); f.write("calc.py", "def add(a, b):\n    return a + b\n")
        let (now, _) = f.capture()
        let rebased = start.rebased(onto: now, own: ["calc.py"])
        #expect(rebased.files["notes.txt"] == now.files["notes.txt"] && rebased.files["calc.py"] == start.files["calc.py"])
        #expect(SnapshotDiff.between(rebased, now).map(\.path) == ["calc.py"], "only the task's own change remains in the diff")
        f.remove("util.py")
        let (gone, _) = f.capture()
        #expect(start.rebased(onto: gone).files["util.py"] == nil)
    }

    @Test("binary and oversized files are fingerprinted without being read as text")
    func binary() {
        let f = EngFixture(files: base)
        try? Data([0, 1, 2, 0, 255, 0]).write(to: f.root.appendingPathComponent("art.png"))
        let s = WorkspaceSnapshotter.capture(root: f.root, git: GitFacts())
        #expect(s.files["art.png"]?.isBinary == true)
        let (_, texts) = f.capture()
        #expect(texts["art.png"] == nil && texts["calc.py"] != nil)
    }

    @Test("real git status feeds the facts: staged, modified and untracked are told apart and HEAD / branch are read")
    func gitFacts() {
        let f = EngFixture(files: base)
        f.write("notes.txt", "user edited\n")
        f.write("util.py", "def helper():\n    return 2\n"); _ = f.git(["add", "util.py"])
        f.write("scratch.txt", "untracked\n")
        let g = f.gitFacts()
        #expect(g.dirty == ["notes.txt", "util.py"] && g.staged == ["util.py"] && g.untracked == ["scratch.txt"] && g.branch == "main" && (g.head?.count ?? 0) == 40 && !g.detached)
    }
}

@Suite("V1.0 engineering · a dirty tree is the USER's work", .serialized)
struct EngineeringDirtyTreeTests {
    /// A user with uncommitted work: a modified tracked file, a staged change and an untracked file.
    private func dirtyFixture() -> EngFixture {
        let f = EngFixture(files: base)
        f.write("notes.txt", "my unsaved thoughts\n")
        f.write("util.py", "def helper():\n    return 42  # mine\n"); _ = f.git(["add", "util.py"])
        f.write("scratch.txt", "untracked scratch\n")
        return f
    }

    @Test("pre-existing modified, staged and untracked files are never attributed to the task; the worker's own edit is")
    func attribution() {
        let f = dirtyFixture()
        var a = EngineeringAssignment(objective: "Fix add() in calc.py to return the sum", project: "fixture")
        a.scope.allowed = ["calc.py"]
        let script = EngWorkerScript(label: "good", edits: ["calc.py": "def add(a, b):\n    return a + b\n"], report: EngHarness.report(changed: ["calc.py"]))
        let run = EngHarness.execute(f, script: script)
        let r = ChangeAttribution.attribute(changes: run.observed.changes, applied: run.observed.applied, baseline: run.before.git)
        #expect(r.changes.map(\.change.path) == ["calc.py"] && r.taskProduced.count == 1 && r.unexplained.isEmpty && r.touchedUserDirty.isEmpty)
        #expect(Set(r.preexistingUntouched) == ["notes.txt", "util.py", "scratch.txt"], "the user's three files are left exactly as they were")
        #expect(r.files(ofWorker: "worker-a") == ["calc.py"])
        // the user's bytes are untouched
        #expect(f.read("notes.txt") == "my unsaved thoughts\n" && f.read("scratch.txt") == "untracked scratch\n" && f.read("util.py")?.contains("# mine") == true)
        let findings = ScopeEnforcer.check(changes: run.observed.changes, scope: a.scope, attribution: r, userDirtyBefore: run.before.git.dirty.union(run.before.git.untracked))
        #expect(findings.isEmpty, Comment(rawValue: "\(findings)"))
    }

    @Test("a worker edit to a file the user had changed is flagged as touching the user's work; an unexplained change is never silently the task's")
    func userDirtyAndUnexplained() {
        let f = dirtyFixture()
        var a = EngineeringAssignment(objective: "Edit notes.txt and util.py as asked", project: "fixture")
        a.scope.allowed = ["notes.txt", "util.py"]
        let script = EngWorkerScript(label: "touches user work", edits: ["notes.txt": "worker overwrote the notes\n"], sideEffects: { $0.write("util.py", "def helper():\n    return 3\n") }, report: EngHarness.report(changed: ["notes.txt"]))
        let run = EngHarness.execute(f, script: script, runBuildAndTests: false)
        let r = ChangeAttribution.attribute(changes: run.observed.changes, applied: run.observed.applied, baseline: run.before.git)
        #expect(r.touchedUserDirty.map(\.change.path) == ["notes.txt"] && r.unexplained.map(\.change.path) == ["util.py"])
        let findings = ScopeEnforcer.check(changes: run.observed.changes, scope: a.scope, attribution: r, userDirtyBefore: run.before.git.dirty.union(run.before.git.untracked))
        #expect(findings.filter { $0.code == .userDirtyFileTouched }.count == 2 && findings.contains(.unexplainedChange))
    }

    @Test("an applied edit whose effect is not visible in the repository is a lost edit, not a success")
    func lostEdit() {
        let f = EngFixture(files: base)
        let (b, _) = f.capture()
        let edit = AppliedEdit(path: "calc.py", workerID: "w", stepKey: "s1", beforeHash: b.files["calc.py"]?.hash, afterHash: "deadbeef")
        let r = ChangeAttribution.attribute(changes: [], applied: [edit], baseline: b.git)
        #expect(r.lostEdits == [edit] && r.changes.isEmpty)
    }
}

/// Test-only executor: applies a `RollbackPlan` to a fixture. The PRODUCT has no executor in this layer — applying a plan is the engine's guarded file tools' job; this proves the plan is sound.
private func apply(_ plan: RollbackPlan, to f: EngFixture, backups: [String: String]) {
    for a in plan.revert {
        switch a {
        case .restore(let path, _): if let t = backups[path] { f.write(path, t) }
        case .removeCreated(let path): f.remove(path)
        }
    }
}

@Suite("V1.0 engineering · rollback never destroys unknown work", .serialized)
struct EngineeringRollbackTests {
    @Test("only task-produced changes with a stored pre-task copy are reverted; the user's dirty files, unexplained changes and files that changed again are left for a decision")
    func rollback() {
        let f = EngFixture(files: base)
        f.write("notes.txt", "user work in progress\n")                       // user's dirty file
        let (b, bc) = f.capture()
        let script = EngWorkerScript(label: "w", edits: ["calc.py": "def add(a, b):\n    return a + b\n", "created.py": "x = 1\n"], sideEffects: { $0.write("util.py", "def helper():\n    return 99\n") }, report: EngHarness.report(changed: ["calc.py", "created.py"]))
        let run = EngHarness.execute(f, script: script, runBuildAndTests: false)
        let attribution = ChangeAttribution.attribute(changes: run.observed.changes, applied: run.observed.applied, baseline: b.git)
        let backups = [PreTaskBackup(path: "calc.py", hash: b.files["calc.py"]!.hash, hasContent: true)]
        let plan = RollbackPlanner.plan(attribution: attribution, current: run.after, baseline: b.git, backups: backups)
        #expect(Set(plan.revert) == [.restore(path: "calc.py", toHash: b.files["calc.py"]!.hash), .removeCreated(path: "created.py")])
        #expect(plan.needsDecision.keys.contains("util.py") && !plan.isSafeToApplyAutomatically)
        #expect(plan.untouchable == ["notes.txt"])
        apply(plan, to: f, backups: bc)
        #expect(f.read("calc.py") == base["calc.py"] && f.read("created.py") == nil)
        #expect(f.read("util.py")?.contains("99") == true, "an unexplained change is never reverted automatically")
        #expect(f.read("notes.txt") == "user work in progress\n", "the user's work is untouched")
    }

    @Test("without a stored pre-task copy, or after another change, nothing is restored: the plan asks")
    func refuses() {
        let f = EngFixture(files: base)
        let (b, _) = f.capture()
        let run = EngHarness.execute(f, script: EngWorkerScript(label: "w", edits: ["calc.py": "def add(a, b):\n    return a + b\n"], report: EngHarness.report(changed: ["calc.py"])), runBuildAndTests: false)
        let attribution = ChangeAttribution.attribute(changes: run.observed.changes, applied: run.observed.applied, baseline: b.git)
        let noBackup = RollbackPlanner.plan(attribution: attribution, current: run.after, baseline: b.git, backups: [])
        #expect(noBackup.revert.isEmpty && noBackup.needsDecision["calc.py"] != nil)
        // somebody edits the file after the worker
        f.write("calc.py", "def add(a, b):\n    return a + b + 0  # later\n")
        let (nowSnap, _) = f.capture()
        let later = RollbackPlanner.plan(attribution: attribution, current: nowSnap, baseline: b.git, backups: [PreTaskBackup(path: "calc.py", hash: b.files["calc.py"]!.hash, hasContent: true)])
        #expect(later.revert.isEmpty && later.needsDecision["calc.py"]?.contains("changed again") == true)
    }

    @Test("a user-dirty file the task modified is only restored from a stored copy that includes the user's work; otherwise a person decides")
    func userDirtyRollback() {
        let f = EngFixture(files: base)
        f.write("notes.txt", "user wip\n")
        let (b, bc) = f.capture()
        let run = EngHarness.execute(f, script: EngWorkerScript(label: "w", edits: ["notes.txt": "worker text\n"], report: EngHarness.report(changed: ["notes.txt"])), runBuildAndTests: false)
        let attribution = ChangeAttribution.attribute(changes: run.observed.changes, applied: run.observed.applied, baseline: b.git)
        let withoutCopy = RollbackPlanner.plan(attribution: attribution, current: run.after, baseline: b.git, backups: [])
        #expect(withoutCopy.revert.isEmpty && withoutCopy.needsDecision["notes.txt"] != nil)
        let withCopy = RollbackPlanner.plan(attribution: attribution, current: run.after, baseline: b.git, backups: [PreTaskBackup(path: "notes.txt", hash: b.files["notes.txt"]!.hash, hasContent: true)])
        #expect(withCopy.revert == [.restore(path: "notes.txt", toHash: b.files["notes.txt"]!.hash)])
        apply(withCopy, to: f, backups: bc)
        #expect(f.read("notes.txt") == "user wip\n", "restored to what the USER had, not to the committed version")
    }
}

@Suite("V1.0 engineering · temporary artifacts")
struct EngineeringTempArtifactTests {
    @Test("only files JARVIS registered for THIS task and that still hold what JARVIS wrote are removable; everything else is kept")
    func cleanup() {
        let t1 = UUID(), t2 = UUID()
        var reg = TempArtifactRegistry()
        reg.register(path: "tmp/scratch.patch", hash: "h1", taskID: t1)
        reg.register(path: "tmp/bench.log", hash: "h2", taskID: t1)
        reg.register(path: "tmp/other.log", hash: "h3", taskID: t2)
        let plan = reg.cleanup(taskID: t1, present: ["tmp/scratch.patch": "h1", "tmp/bench.log": "CHANGED", "tmp/other.log": "h3", "notes/user.txt": "x"])
        #expect(plan.remove == ["tmp/scratch.patch"])
        #expect(plan.keep["tmp/bench.log"] == "changed since JARVIS wrote it" && plan.keep["tmp/other.log"] == "belongs to another task" && plan.keep["notes/user.txt"] == "not created by JARVIS")
    }
}
