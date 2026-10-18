import Foundation
@testable import Jarvis

// Test-only support for the autonomous engineering pipeline: a disposable Git + Python fixture repository (never the JARVIS repository, never a real project), a real process runner for
// the fixture's test command (so verification evidence is a REAL exit status), and a tiny "worker" description (edits JARVIS would apply, side effects it would not, the report text).

struct ProcessResult { var status: Int32; var output: String }

enum EngProcess {
    static func run(_ args: [String], in dir: URL, timeout: TimeInterval = 60) -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"; env["GIT_TERMINAL_PROMPT"] = "0"; env["GIT_OPTIONAL_LOCKS"] = "0"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return ProcessResult(status: 127, output: "\(error)") }
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        let reader = DispatchQueue(label: "eng.read")
        let group = DispatchGroup()
        group.enter()
        reader.async { data = pipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit(); group.wait()
        return ProcessResult(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

final class EngFixture {
    let root: URL

    init(files: [String: String], commit: Bool = true) {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("eng-fixture-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (p, t) in files { write(p, t) }
        _ = git(["init", "-q", "-b", "main"])
        if commit { commitAll("chore: initial fixture") }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult func git(_ args: [String]) -> ProcessResult {
        EngProcess.run(["git", "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false"] + args, in: root)
    }

    func commitAll(_ message: String) { _ = git(["add", "-A"]); _ = git(["commit", "-q", "-m", message]) }

    func write(_ path: String, _ text: String) {
        let url = root.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
    func remove(_ path: String) { try? FileManager.default.removeItem(at: root.appendingPathComponent(path)) }
    func read(_ path: String) -> String? { try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }

    func gitFacts() -> GitFacts {
        let status = git(["status", "--porcelain=v1", "--untracked-files=all"]).output
        let head = git(["rev-parse", "HEAD"])
        let branch = git(["rev-parse", "--abbrev-ref", "HEAD"])
        return GitStatusParser.parse(status, head: head.status == 0 ? head.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil, branch: branch.status == 0 ? branch.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
    }

    /// Snapshot + the text of every small text file (what `FileDelta`s are built from).
    func capture() -> (snapshot: WorkspaceSnapshot, contents: [String: String]) {
        let snap = WorkspaceSnapshotter.capture(root: root, git: gitFacts())
        var texts: [String: String] = [:]
        for (p, f) in snap.files where !f.isBinary && f.size < 200_000 { if let t = read(p) { texts[p] = t } }
        return (snap, texts)
    }

    func deltas(before: [String: String], after: [String: String]) -> [FileDelta] {
        Set(before.keys).union(after.keys).sorted().compactMap { p in
            before[p] == after[p] ? nil : FileDelta(path: p, before: before[p], after: after[p])
        }
    }

    /// The fixture's real test command → real evidence for the CURRENT revision.
    func runUnitTests(digest: String, profile: String = "python3 -m unittest") -> VerificationEvidence {
        let r = EngProcess.run(["python3", "-m", "unittest", "discover", "-s", "tests", "-t", ".", "-p", "test_*.py"], in: root)
        var counts: EvidenceTestCounts?
        if let m = r.output.range(of: #"Ran (\d+) test"#, options: .regularExpression) {
            let n = Int(r.output[m].filter(\.isNumber)) ?? 0
            let failed = r.output.range(of: #"failures=(\d+)"#, options: .regularExpression).flatMap { Int(r.output[$0].filter(\.isNumber)) } ?? 0
            let errors = r.output.range(of: #"errors=(\d+)"#, options: .regularExpression).flatMap { Int(r.output[$0].filter(\.isNumber)) } ?? 0
            counts = EvidenceTestCounts(passed: max(0, n - failed - errors), failed: failed + errors)
        }
        return VerificationEvidence(stage: .unitTests, profile: profile, exitStatus: r.status, snapshotDigest: digest, recordedAt: Date(timeIntervalSince1970: 1_800_000_000), excerpt: String(r.output.suffix(600)), counts: counts)
    }

    func runBuild(digest: String) -> VerificationEvidence {
        // "build" for a Python fixture = parse every module (a syntax error fails it; nothing is written into the tree)
        let r = EngProcess.run(["python3", "-c", "import ast, pathlib, sys\nbad = 0\nfor p in pathlib.Path('.').rglob('*.py'):\n    try: ast.parse(p.read_text())\n    except SyntaxError as e: print('syntax error', p, e); bad = 1\nsys.exit(bad)"], in: root)
        return VerificationEvidence(stage: .build, profile: "python3 syntax check", exitStatus: r.status, snapshotDigest: digest, recordedAt: Date(timeIntervalSince1970: 1_800_000_000), excerpt: String(r.output.suffix(400)), counts: nil)
    }
}

/// What a (fake) worker does. `edits` are applied by "JARVIS" (recorded as `AppliedEdit`s); `sideEffects` happen behind JARVIS' back (a worker with its own shell); `report` is its answer text.
struct EngWorkerScript {
    var label: String
    var edits: [String: String?] = [:]            // path → new content (nil = delete)
    var sideEffects: (EngFixture) -> Void = { _ in }
    var report: String
    var worker = "worker-a"
}

struct EngRun {
    var before: WorkspaceSnapshot
    var after: WorkspaceSnapshot
    var observed: ObservedState
    var claims: WorkerClaims?
    var parseIssue: WorkerReportIssue?
}

enum EngHarness {
    /// Apply a script to the fixture exactly as the pipeline would observe it: snapshot → edits (+ side effects) → snapshot → real build/test evidence → observed state.
    static func execute(_ f: EngFixture, script: EngWorkerScript, runBuildAndTests: Bool = true, extraEvidence: [VerificationEvidence] = []) -> EngRun {
        let (b, bc) = f.capture()
        var applied: [AppliedEdit] = []
        for (path, content) in script.edits.sorted(by: { $0.key < $1.key }) {
            if let c = content { f.write(path, c) } else { f.remove(path) }
        }
        script.sideEffects(f)
        let (a, ac) = f.capture()
        for (path, _) in script.edits.sorted(by: { $0.key < $1.key }) {
            applied.append(AppliedEdit(path: path, workerID: script.worker, stepKey: "s1", beforeHash: b.files[path]?.hash, afterHash: a.files[path]?.hash))
        }
        var evidence = extraEvidence
        if runBuildAndTests {
            evidence.append(f.runBuild(digest: a.digest))
            evidence.append(f.runUnitTests(digest: a.digest))
        }
        let observed = ObservedState(before: b, after: a, deltas: f.deltas(before: bc, after: ac), applied: applied, evidence: evidence, contents: ac, commit: nil)
        switch WorkerReportParser.parse(script.report) {
        case .success(let c): return EngRun(before: b, after: a, observed: observed, claims: c, parseIssue: nil)
        case .failure(let e): return EngRun(before: b, after: a, observed: observed, claims: nil, parseIssue: e)
        }
    }

    static func report(status: String = "done", changed: [String] = [], testsGreen: Bool? = true, extra: String = "") -> String {
        let files = changed.map { "\"\($0)\"" }.joined(separator: ",")
        let tests = testsGreen.map { ",\"tests\":{\"allGreen\":\($0)}" } ?? ""
        return "{\"status\":\"\(status)\",\"filesChanged\":[\(files)]\(tests)\(extra)}"
    }

    static let standardProfiles = ProjectVerificationProfiles(staticCheck: nil, unitTests: "python3 -m unittest", integrationTests: nil, build: "python3 syntax check", securityGuards: nil, unityCompile: nil)
}

extension EngHarness {
    /// The one place a test turns a run into a verdict, exactly as the pipeline would: plan from the OBSERVED change set, real evidence from the real run, claims only compared.
    static func verdict(_ run: EngRun, assignment: EngineeringAssignment, profiles: ProjectVerificationProfiles = standardProfiles, dependencyEvidence: [DependencyEvidence] = []) -> (verdict: VerificationVerdict, plan: VerificationPlan) {
        let plan = VerificationPlanner.plan(changedPaths: run.observed.changes.map(\.path), profiles: profiles, sharedCorePatterns: assignment.sharedCorePatterns, domains: assignment.domains)
        let v = EngineeringVerifier.verify(assignment: assignment, claims: run.claims, observed: run.observed, plan: plan, dependencyEvidence: dependencyEvidence, claimsIssue: run.parseIssue)
        return (v, plan)
    }
}

extension EngHarness {
    /// A verdict over a CUMULATIVE observation (task start → now): what several attempts together changed, not what the last one did.
    static func verdict(observed o: ObservedState, claims: WorkerClaims?, parseIssue: WorkerReportIssue?, assignment: EngineeringAssignment, profiles: ProjectVerificationProfiles = standardProfiles) -> (verdict: VerificationVerdict, plan: VerificationPlan) {
        let plan = VerificationPlanner.plan(changedPaths: o.changes.map(\.path), profiles: profiles, sharedCorePatterns: assignment.sharedCorePatterns, domains: assignment.domains)
        return (EngineeringVerifier.verify(assignment: assignment, claims: claims, observed: o, plan: plan, claimsIssue: parseIssue), plan)
    }
}
