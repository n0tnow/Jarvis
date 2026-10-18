import Foundation
import Testing
@testable import Jarvis

// V1.0 autonomous engineering pipeline — verification planning, the bounded repair loop, repeated-failure detection, write ownership, stale results, cancellation, partial work, hand-off, commit
// verification, checkpoint / resume and the grounded report. Pure logic over typed values.

private func a(_ objective: String = "Fix add() in calc.py", allowed: [String] = ["calc.py"], budget: EngineeringBudget = EngineeringBudget(), risk: RiskClass = .low) -> EngineeringAssignment {
    var x = EngineeringAssignment(objective: objective, project: "fixture")
    x.scope.allowed = allowed; x.budget = budget; x.risk = risk
    x.acceptance = [AcceptanceCriterion(id: "c1", text: "tests pass", check: .profile("unit")), AcceptanceCriterion(id: "c2", text: "no lingering a - b", check: .fileDoesNotContain(path: "calc.py", text: "a - b"))]
    return x
}

private func snap(_ files: [String: String], head: String? = "h1", branch: String? = "main") -> WorkspaceSnapshot {
    WorkspaceSnapshot(files: files.mapValues { FileFingerprint(hash: $0, size: $0.count, isBinary: false) }, git: GitFacts(head: head, branch: branch), capturedAt: Date(timeIntervalSince1970: 0))
}

private func verdict(_ status: WorkVerificationStatus, findings: [EngineeringFinding] = [], unmet: [String] = [], files: Int = 1) -> VerificationVerdict {
    VerificationVerdict(status: status, findings: findings, mismatches: [], unmetCriteria: unmet, missingStages: [], revision: "r", attribution: AttributionReport(changes: [], lostEdits: [], preexistingUntouched: []), diffStats: DiffStats(files: files, linesAdded: 3, linesRemoved: 1))
}

private let profiles = ProjectVerificationProfiles(staticCheck: "lint", unitTests: "unit", integrationTests: "integration", build: "build", securityGuards: "guards", unityCompile: "unity compile")

@Suite("V1.0 engineering · verification is proportional to the change")
struct VerificationPlannerTests {
    private func stages(_ p: VerificationPlan) -> Set<VerificationStage> { Set(p.requiredStages.map(\.stage)) }

    @Test("docs only: guards and a truth check, no build; source: build + unit tests; shared core adds integration tests")
    func proportional() {
        let docs = VerificationPlanner.plan(changedPaths: ["README.md", "docs/a.md"], profiles: profiles)
        #expect(stages(docs) == [.securityGuards] && !docs.stages.contains { $0.stage == .build })
        let src = VerificationPlanner.plan(changedPaths: ["Sources/A.swift"], profiles: profiles)
        #expect(stages(src) == [.build, .unitTests])
        let core = VerificationPlanner.plan(changedPaths: ["Sources/Core/A.swift"], profiles: profiles, sharedCorePatterns: ["Sources/Core/**"])
        #expect(stages(core) == [.build, .unitTests, .integrationTests])
        #expect(VerificationPlanner.plan(changedPaths: [], profiles: profiles).stages.isEmpty, "nothing changed: nothing to verify and nothing to claim")
    }

    @Test("build scripts, guards, dependency manifests and test changes widen verification and require elevated review")
    func widening() {
        for p in ["scripts/verify.sh", "scripts/guards_x.sh", "Package.swift"] {
            let plan = VerificationPlanner.plan(changedPaths: [p], profiles: profiles)
            #expect(plan.elevatedReview && stages(plan).isSuperset(of: [.build, .unitTests, .securityGuards]), Comment(rawValue: p))
        }
        let t = VerificationPlanner.plan(changedPaths: ["tests/test_a.py"], profiles: profiles)
        #expect(stages(t).contains(.unitTests))
    }

    @Test("Unity C# adds the future editor validation as a MANUAL requirement; UI work likewise; a missing profile is 'not available', never a pass")
    func manual() {
        let unity = VerificationPlanner.plan(changedPaths: ["Assets/Scripts/Player.cs"], profiles: profiles)
        #expect(unity.manualRequired.contains { $0.contains("Unity editor") })
        let ui = VerificationPlanner.plan(changedPaths: ["src/view.py"], profiles: profiles, domains: [.ui])
        #expect(ui.manualRequired.contains { $0.contains("real application") })
        let bare = VerificationPlanner.plan(changedPaths: ["src/a.py"], profiles: ProjectVerificationProfiles())
        #expect(bare.stages.allSatisfy { $0.status != .passed } && bare.requiredStages.isEmpty && bare.stages.contains { if case .notAvailable = $0.status { return true }; return false })
    }

    @Test("evidence counts only for the CURRENT revision: a green run from before the last edit leaves the stage open")
    func revisions() {
        var plan = VerificationPlanner.plan(changedPaths: ["src/a.py"], profiles: profiles)
        let old = VerificationEvidence(stage: .unitTests, profile: "unit", exitStatus: 0, snapshotDigest: "old", recordedAt: Date(), excerpt: "", counts: nil)
        plan.record(old, currentDigest: "new")
        #expect(plan.stageStatus(.unitTests) == .planned && !plan.allRequiredPassed)
        plan.record(VerificationEvidence(stage: .unitTests, profile: "unit", exitStatus: 0, snapshotDigest: "new", recordedAt: Date(), excerpt: "", counts: EvidenceTestCounts(passed: 3, failed: 0)), currentDigest: "new")
        plan.record(VerificationEvidence(stage: .build, profile: "build", exitStatus: 0, snapshotDigest: "new", recordedAt: Date(), excerpt: "", counts: nil), currentDigest: "new")
        #expect(plan.allRequiredPassed)
        plan.record(VerificationEvidence(stage: .unitTests, profile: "unit", exitStatus: 0, snapshotDigest: "new", recordedAt: Date(), excerpt: "", counts: EvidenceTestCounts(passed: 2, failed: 1)), currentDigest: "new")
        #expect(plan.stageStatus(.unitTests) == .failed, "an exit status of 0 with failing counts is not a pass")
    }
}

@Suite("V1.0 engineering · failure signatures")
struct FailureSignatureTests {
    @Test("the same failure has the same signature whatever the paths, line numbers, addresses and times")
    func semanticEquality() {
        let a = "/tmp/run-1/src/calc.py:12: error: cannot find 'foo' in scope at 2026-10-18T10:00:00Z (0x7ffe1234)"
        let b = "/mnt/other/src/calc.py:98: error: cannot find 'foo' in scope at 2026-10-19T23:59:59Z (0x1abc)"
        #expect(FailureNormalizer.signature(from: a) == FailureNormalizer.signature(from: b))
        let c = "AssertionError: 5 != 6\n  File \"/tmp/x/test_calc.py\", line 7"
        let d = "AssertionError: 7 != 8\n  File \"/home/u/test_calc.py\", line 99"
        #expect(FailureNormalizer.signature(from: c) == FailureNormalizer.signature(from: d))
        #expect(FailureNormalizer.signature(from: a) != FailureNormalizer.signature(from: c))
        #expect(FailureNormalizer.signature(from: "ModuleNotFoundError: No module named 'requests'").kind == .missingDependency)
        #expect(FailureNormalizer.signature(from: "error: cannot find 'x' in scope").kind == .compile && FailureNormalizer.signature(from: "FAIL: test_add (tests.test_calc.T)\nAssertionError: 1 != 2").kind == .test)
    }

    @Test("the log excerpt is bounded, centred on the first failure, secrets withheld, control characters removed")
    func excerpt() {
        let secret = "ghp_" + String(repeating: "a1B2", count: 6)
        var lines = (0..<400).map { "info line \($0)" }
        lines[200] = "error: something broke"; lines[202] = "token = \(secret)"; lines[203] = "bell\u{7} char"
        let e = RepairBrief.excerpt(of: lines.joined(separator: "\n"), limit: 1_000)
        #expect(e.contains("error: something broke") && !e.contains("info line 5\n") && !e.contains(secret) && !e.contains("\u{7}") && e.count <= 1_000)
    }
}

@Suite("V1.0 engineering · the repair loop is bounded")
struct RepairLoopTests {
    private func failing(_ code: FindingCode = .criterionUnmet, path: String = ".") -> VerificationVerdict { verdict(.failed, findings: [EngineeringFinding(code, .blocker, path: path, "fails", evidence: "x")], unmet: ["c1"]) }

    private func step(_ loop: inout RepairLoop, _ v: VerificationVerdict, out: String = "AssertionError: 5 != 6", escalate: Bool = true, provider: Bool = true, assignment: EngineeringAssignment = a()) -> RepairDecision {
        loop.noteWorkerAttempt(worker: "w1"); loop.noteVerificationRun()
        return loop.decide(verdict: v, failureOutput: out, assignment: assignment, workerName: "w1", escalationAllowed: escalate, providerAvailable: provider)
    }

    @Test("verified work ends the loop")
    func verified() {
        var loop = RepairLoop(budget: EngineeringBudget())
        #expect(step(&loop, verdict(.verified)) == .done)
        var l2 = RepairLoop(budget: EngineeringBudget())
        #expect(step(&l2, verdict(.verifiedAutomated)) == .done)
    }

    @Test("a first failure gets a precise repair brief — objective, observed diff, the failing check, logs, constraints, attempt number — never a bare 'fix it'")
    func brief() {
        var loop = RepairLoop(budget: EngineeringBudget())
        guard case .repair(let b) = step(&loop, failing(), out: "FAIL: test_add\nAssertionError: 5 != 6\n") else { Issue.record("expected a repair"); return }
        let text = b.render()
        #expect(text.contains("REPAIR ATTEMPT 2 OF 3") && text.contains("OBJECTIVE: Fix add() in calc.py") && text.contains("WHAT CHANGED SO FAR (observed, not reported)") && text.contains("AssertionError") && text.contains("do not delete, skip or weaken any test"))
        #expect(!text.lowercased().contains("chain of thought") && text.count <= RepairBrief.maxCharacters)
    }

    @Test("the worker-attempt budget stops the loop; so do verification runs, provider requests and wall clock")
    func budgets() {
        var tight = EngineeringBudget(); tight.workerAttempts = 2
        var loop = RepairLoop(budget: tight)
        _ = step(&loop, failing(), out: "error one")
        #expect(step(&loop, failing(), out: "error two different") == .stop(.workerAttemptsExhausted))
        var vb = EngineeringBudget(); vb.verificationRuns = 1
        var l2 = RepairLoop(budget: vb)
        #expect(step(&l2, failing()) == .stop(.verificationRunsExhausted))
        var pb = EngineeringBudget(); pb.providerRequests = 1
        var l3 = RepairLoop(budget: pb)
        #expect(step(&l3, failing()) == .stop(.providerRequestsExhausted))
        var wb = EngineeringBudget(); wb.wallClock = 60
        var l4 = RepairLoop(budget: wb); l4.addActive(61)
        #expect(step(&l4, failing()) == .stop(.wallClockExhausted))
    }

    @Test("the SAME failure repeating escalates once (Auto only), then stops: no 20 model calls to reproduce one error")
    func repeated() {
        var big = EngineeringBudget(); big.workerAttempts = 10; big.verificationRuns = 10; big.providerRequests = 20
        var loop = RepairLoop(budget: big)
        let out1 = "/tmp/a/calc.py:3: error: cannot find 'foo' in scope"
        guard case .repair = step(&loop, failing(), out: out1) else { Issue.record("first: repair"); return }
        guard case .escalate(_, let why) = step(&loop, failing(), out: out1.replacingOccurrences(of: ":3:", with: ":9:")) else { Issue.record("second: escalate"); return }
        #expect(why.contains("same failure"))
        #expect(step(&loop, failing(), out: out1) == .stop(.sameFailureRepeated))
        // an explicit provider choice never escalates: it stops at the second repeat
        var l2 = RepairLoop(budget: big)
        _ = step(&l2, failing(), out: out1, escalate: false)
        #expect(step(&l2, failing(), out: out1, escalate: false) == .stop(.sameFailureRepeated))
        // different failures keep repairing until a budget
        var l3 = RepairLoop(budget: big)
        for i in 0..<5 { if case .stop = step(&l3, failing(), out: "error: distinct failure number \(i) word\(i)zzz") { Issue.record("distinct failures must not stop early") ; break } }
    }

    @Test("security findings, architecture uncertainty, approval needs and an unavailable provider stop the loop instead of asking for another try")
    func stops() {
        var l1 = RepairLoop(budget: EngineeringBudget())
        #expect(step(&l1, verdict(.failed, findings: [EngineeringFinding(.secretIntroduced, .blocker, path: "a.py", "s", evidence: "line 1")])) == .stop(.securityFinding))
        var l2 = RepairLoop(budget: EngineeringBudget())
        #expect(step(&l2, verdict(.needsReview, findings: [EngineeringFinding(.architectureDrift, .major, path: "a.swift", "d", evidence: "type X")])) == .stop(.architectureUncertain))
        var l3 = RepairLoop(budget: EngineeringBudget())
        #expect(step(&l3, verdict(.needsReview, findings: [EngineeringFinding(.userDirtyFileTouched, .major, path: "n.txt", "d", evidence: "x")])) == .stop(.approvalRequired))
        var l4 = RepairLoop(budget: EngineeringBudget())
        #expect(step(&l4, failing(), provider: false) == .stop(.providerUnavailable))
        var l5 = RepairLoop(budget: EngineeringBudget())
        #expect(step(&l5, verdict(.failed, findings: [EngineeringFinding(.guardWeakened, .blocker, path: "g.sh", "w", evidence: "x")])) == .stop(.securityFinding))
    }

    @Test("a fix that breaks a criterion that passed before is called out as a regression in the next brief")
    func regression() {
        var loop = RepairLoop(budget: EngineeringBudget())
        loop.noteWorkerAttempt(worker: "w"); loop.noteVerificationRun()
        _ = loop.decide(verdict: verdict(.failed, findings: [EngineeringFinding(.criterionUnmet, .blocker, path: ".", "x", evidence: "c1")], unmet: ["c1"]), failureOutput: "boom one", assignment: a(), workerName: "w", escalationAllowed: true, providerAvailable: true)
        loop.noteWorkerAttempt(worker: "w"); loop.noteVerificationRun()
        let d = loop.decide(verdict: verdict(.failed, findings: [EngineeringFinding(.criterionUnmet, .blocker, path: ".", "x", evidence: "c2")], unmet: ["c2"]), failureOutput: "boom two", assignment: a(), workerName: "w", escalationAllowed: true, providerAvailable: true)
        guard case .repair(let b) = d else { Issue.record("expected repair"); return }
        #expect(b.failure.contains("REGRESSION") && b.failure.contains("c2") && b.protectedCriteria.contains { $0.contains("[c1]") })
        var t = AcceptanceTracker()
        let r1 = t.update(failing: ["c1"], all: ["c1", "c2"]), r2 = t.update(failing: ["c2"], all: ["c1", "c2"])
        #expect(r1.isEmpty && r2 == ["c2"])
    }

    @Test("a loop is a value: it survives a JSON round trip mid-run (checkpoint / resume)")
    func codable() throws {
        var loop = RepairLoop(budget: EngineeringBudget())
        _ = step(&loop, failing(), out: "error: x")
        let data = try JSONEncoder().encode(loop)
        let back = try JSONDecoder().decode(RepairLoop.self, from: data)
        #expect(back == loop && back.workerAttempts == 1)
    }
}

@Suite("V1.0 engineering · write ownership, parallelism, staleness, cancellation")
struct OwnershipTests {
    private func w(_ paths: [String], id: UUID = UUID(), deps: [UUID] = []) -> EngineeringAssignment { var x = a(allowed: paths); x.id = id; x.dependsOn = deps; return x }

    @Test("a second writer on the same file waits; a writer on another module does not; read-only work never conflicts")
    func conflicts() {
        var reg = OwnershipRegistry()
        let first = w(["Sources/Player/PlayerController.cs"]), second = w(["Sources/Player/PlayerController.cs"]), other = w(["Sources/Net/**"])
        #expect(reg.request(first, owner: "A") == .granted)
        #expect(reg.request(second, owner: "B") == .wait(for: [first.id]))
        #expect(reg.request(other, owner: "C") == .granted)
        var ro = a(allowed: []); ro.id = UUID()
        #expect(reg.request(ro, owner: "D") == .granted)
        #expect(reg.holder(of: "Sources/Player/PlayerController.cs")?.owner == "A")
        #expect(reg.release(first.id) == [second.id])
        #expect(reg.holder(of: "Sources/Player/PlayerController.cs")?.owner == "B")
    }

    @Test("the same owner and objective group is merged into the running assignment instead of racing it")
    func merge() {
        var reg = OwnershipRegistry()
        let one = w(["src/**"]), two = w(["src/a.py"])
        #expect(reg.request(one, owner: "A", group: "refactor") == .granted)
        #expect(reg.request(two, owner: "A", group: "refactor") == .mergeInto(one.id))
        #expect(reg.request(w(["src/a.py"]), owner: "B", group: "refactor") != .granted)
    }

    @Test("circular waiting is detected and handed to coordination instead of deadlocking")
    func deadlock() {
        var reg = OwnershipRegistry()
        let x = w(["a/**", "b/**"]), y = w(["b/**", "c/**"])
        #expect(reg.request(x, owner: "A") == .granted)
        #expect(reg.request(y, owner: "B") == .wait(for: [x.id]))
        // x now wants something y holds (c/**): x already holds a reservation, a fresh request of the same id sees y waiting for x
        var xAgain = w(["c/**"]); xAgain.id = x.id
        if case .needsCoordination(let overlaps) = reg.request(xAgain, owner: "A") { #expect(!overlaps.isEmpty) } else { Issue.record("expected coordination") }
    }

    @Test("a cancelled assignment is denied afterwards and releases its waiters; the registry is bounded")
    func cancel() {
        var reg = OwnershipRegistry()
        let x = w(["a.py"]), y = w(["a.py"])
        _ = reg.request(x, owner: "A"); _ = reg.request(y, owner: "B")
        #expect(reg.cancel(x.id) == [y.id])
        #expect(reg.request(x, owner: "A") == .denied("the assignment was cancelled"))
        var full = OwnershipRegistry()
        for i in 0..<OwnershipRegistry.maxReservations { _ = full.request(w(["dir\(i)/**"]), owner: "o\(i)") }
        #expect(full.request(w(["extra/**"]), owner: "z") == .denied("too many concurrent write assignments"))
    }

    @Test("parallelism only for independent, non-overlapping or read-only assignments")
    func parallel() {
        let x = w(["Sources/A/**"]), y = w(["Sources/B/**"]), z = w(["Sources/A/x.swift"])
        #expect(SafeParallelism.mayRunTogether(x, y) && !SafeParallelism.mayRunTogether(x, z))
        var ro = a(allowed: []); ro.id = UUID()
        #expect(SafeParallelism.mayRunTogether(x, ro))
        let dep = w(["Sources/C/**"], deps: [x.id])
        #expect(!SafeParallelism.mayRunTogether(x, dep))
    }

    @Test("a result built on an outdated repository is stale: scope or read-set changes, a moved HEAD; the worker's own changes do not count")
    func staleness() {
        var s = WriteScope(); s.allowed = ["Sources/A/**"]
        let start = snap(["Sources/A/a.swift": "1", "Sources/Shared/s.swift": "1", "docs/x.md": "1"])
        #expect(StalenessCheck.assess(startedAt: start, now: start, scope: s) == .fresh)
        let shared = snap(["Sources/A/a.swift": "1", "Sources/Shared/s.swift": "2", "docs/x.md": "1"])
        #expect(StalenessCheck.assess(startedAt: start, now: shared, scope: s) == .fresh, "an unrelated file changed")
        #expect(StalenessCheck.assess(startedAt: start, now: shared, scope: s, readSet: ["Sources/Shared/s.swift"]) == .stale(changed: ["Sources/Shared/s.swift"], overlapsScope: false), "the worker READ the file another agent changed")
        let inScope = snap(["Sources/A/a.swift": "2", "Sources/Shared/s.swift": "1", "docs/x.md": "1"])
        #expect(StalenessCheck.assess(startedAt: start, now: inScope, scope: s) == .stale(changed: ["Sources/A/a.swift"], overlapsScope: true))
        #expect(StalenessCheck.assess(startedAt: start, now: inScope, scope: s, ownChanges: ["Sources/A/a.swift"]) == .fresh)
        #expect(StalenessCheck.assess(startedAt: start, now: snap(start.files.mapValues(\.hash), head: "h2"), scope: s) == .headMoved(from: "h1", to: "h2"))
    }

    @Test("no write assignment starts after a cancel, a terminal state or an interruption; a late result is never applied; critical work is not delegated without its gate")
    func gate() {
        var rw = WriteScope(); rw.allowed = ["a.py"]
        #expect(AssignmentGate.mayIssueWrite(TaskLifecycleView(cancelRequested: false, terminal: false), scope: rw))
        for t in [TaskLifecycleView(cancelRequested: true, terminal: false), TaskLifecycleView(cancelRequested: false, terminal: true), TaskLifecycleView(cancelRequested: false, terminal: false, interrupted: true)] {
            #expect(!AssignmentGate.mayIssueWrite(t, scope: rw))
            #expect(AssignmentGate.mayIssueWrite(t, scope: WriteScope()), "read-only work may still finish")
        }
        #expect(!AssignmentGate.mayApplyResult(TaskLifecycleView(cancelRequested: true, terminal: false)) && AssignmentGate.mayApplyResult(TaskLifecycleView(cancelRequested: false, terminal: false)))
        var crit = a(risk: .critical)
        #expect(!DelegationPolicy.mayDelegate(crit)); crit.gateApproved = true
        #expect(DelegationPolicy.mayDelegate(crit) && DelegationPolicy.mayDelegate(a()))
    }
}

@Suite("V1.0 engineering · partial work, hand-off, commits and external actions")
struct LifecycleTests {
    @Test("partial work is classified, never called complete: usable only when it is in scope and builds at the current revision")
    func partial() {
        let clean = verdict(.partial)
        let build = VerificationEvidence(stage: .build, profile: "build", exitStatus: 0, snapshotDigest: "r", recordedAt: Date(), excerpt: "", counts: nil)
        #expect(PartialWorkClassifier.classify(verdict: clean, evidence: [build], timedOut: true) == .usable)
        #expect(PartialWorkClassifier.classify(verdict: clean, evidence: [], timedOut: true) == .unknown)
        var failedBuild = build; failedBuild.exitStatus = 1
        #expect(PartialWorkClassifier.classify(verdict: clean, evidence: [failedBuild], timedOut: true) == .unsafe)
        #expect(PartialWorkClassifier.classify(verdict: verdict(.failed, findings: [EngineeringFinding(.scopeEscape, .blocker, path: "x", "s", evidence: "x")]), evidence: [build], timedOut: false) == .unsafe)
        #expect(PartialWorkClassifier.classify(verdict: verdict(.partial, files: 0), evidence: [build], timedOut: true) == .unknown)
        #expect(PartialWorkClassifier.classify(verdict: clean, evidence: [VerificationEvidence(stage: .build, profile: "build", exitStatus: 0, snapshotDigest: "OLD", recordedAt: Date(), excerpt: "", counts: nil)], timedOut: true) == .unknown, "a build of an older revision proves nothing")
    }

    @Test("a worker taking over receives the objective, the ACTUAL state, the open findings and the attempt history — no transcript")
    func handoff() {
        let v = verdict(.failed, findings: [EngineeringFinding(.testDeleted, .blocker, path: "tests/t.py", "a test case was removed", evidence: "def test_x")], unmet: ["c1"])
        let text = WorkerHandoff.build(assignment: a(), diffSummary: "2 file(s), +10 −3", verdict: v, attempts: [AttemptSummary(number: 1, worker: "w1", outcome: "failed:compile", signature: nil, filesChanged: 2, note: "")])
        #expect(text.contains("OBJECTIVE") && text.contains("CURRENT STATE (observed): 2 file(s)") && text.contains("BLOCKER testDeleted") && text.contains("UNMET CRITERIA: c1") && text.contains("#1 w1: failed:compile"))
        #expect(!text.lowercased().contains("reasoning") && !text.lowercased().contains("transcript") && text.count <= 4_500)
    }

    @Test("a claimed commit is checked against the repository: HEAD must have moved, include only in-scope files, avoid AI trailers and follow the project's style")
    func commits() {
        let policy = CommitPolicy(allowLocalCommit: true)
        var s = WriteScope(); s.allowed = ["src/**"]
        let good = CommitObservation(headBefore: "aaa111", headAfter: "bbb222cc", commitExists: true, files: ["src/a.py"], message: "fix(calc): add returns the sum")
        #expect(CommitVerifier.verify(claimedHash: "bbb222", observed: good, scope: s, policy: policy).isEmpty)
        #expect(CommitVerifier.verify(claimedHash: "ccc333", observed: good, scope: s, policy: policy).contains(.commitClaimContradicted))
        let none = CommitObservation(headBefore: "aaa111", headAfter: "aaa111", commitExists: true, files: [], message: "")
        #expect(CommitVerifier.verify(claimedHash: "aaa111", observed: none, scope: s, policy: policy).contains { $0.severity == .blocker })
        var extra = good; extra.files = ["src/a.py", "README.md"]
        #expect(CommitVerifier.verify(claimedHash: nil, observed: extra, scope: s, policy: policy).contains { $0.code == .scopeEscape && $0.path == "README.md" })
        var attributed = good; attributed.message = "fix(calc): sum\n\nCo-Authored-By: Claude <noreply@anthropic.com>"
        #expect(CommitVerifier.verify(claimedHash: nil, observed: attributed, scope: s, policy: policy).contains { $0.severity == .major })
        var sloppy = good; sloppy.message = "update"
        #expect(CommitVerifier.verify(claimedHash: nil, observed: sloppy, scope: s, policy: policy).first?.severity == .minor)
        #expect(CommitVerifier.verify(claimedHash: nil, observed: good, scope: s, policy: CommitPolicy(allowLocalCommit: false)).contains { $0.severity == .blocker }, "a commit nobody allowed")
    }

    @Test("nothing outward-facing is automatic: a passing test never authorises a push, a pull request, a tag or a merge")
    func external() {
        for act in ExternalAction.allCases where act != .localCommit { #expect(!ExternalActionPolicy.mayRunAutomatically(act, policy: CommitPolicy(allowLocalCommit: true)) && ExternalActionPolicy.isCritical(act), Comment(rawValue: act.rawValue)) }
        #expect(ExternalActionPolicy.mayRunAutomatically(.localCommit, policy: CommitPolicy(allowLocalCommit: true)) && !ExternalActionPolicy.mayRunAutomatically(.localCommit, policy: CommitPolicy()))
    }

    @Test("project conventions are discovered from the project's own files; JARVIS's AGENTS.md is first when present")
    func conventions() {
        let found = ProjectConventionDiscovery.candidates(in: ["README.md", "src/a.py", "CONTRIBUTING.md", "AGENTS.md", ".editorconfig", "deep/dir/AGENTS.md", "CLAUDE.md"])
        #expect(found == ["AGENTS.md", "CLAUDE.md", "CONTRIBUTING.md", ".editorconfig", "README.md"])
        #expect(ProjectConventionDiscovery.candidates(in: ["src/a.py"]).isEmpty)
    }
}

@Suite("V1.0 engineering · checkpoint, resume and the grounded report")
struct ReportAndCheckpointTests {
    private func record() -> EngineeringRunRecord {
        var r = EngineeringRunRecord(assignment: a())
        r.changedFiles = ["calc.py"]; r.verdict = .verifiedAutomated; r.manualRequired = ["Unity editor validation on a real editor"]
        r.evidence = [VerificationEvidence(stage: .unitTests, profile: "unit", exitStatus: 0, snapshotDigest: "d", recordedAt: Date(), excerpt: "", counts: EvidenceTestCounts(passed: 3, failed: 0))]
        r.attempts = [AttemptSummary(number: 1, worker: "w1", outcome: "failed:test", signature: nil, filesChanged: 1, note: ""), AttemptSummary(number: 2, worker: "w2", outcome: "verified", signature: nil, filesChanged: 1, note: "")]
        r.commit = "abcdef1234567890"
        return r
    }

    @Test("AUTOMATED TESTED and MANUAL TEST REQUIRED are first-class; nothing becomes MANUALLY VERIFIED without a person's record")
    func states() {
        var r = record()
        #expect(r.validationState == .manualTestRequired)
        r.verdict = .verified; r.manualRequired = []
        #expect(r.validationState == .automatedTested)
        r.verdict = .failed
        #expect(r.validationState == .notVerified)
        var m = EngineeringRunRecord(assignment: { var x = a(); x.acceptance.append(AcceptanceCriterion(id: "m1", text: "looks right in the editor", check: .manual("editor"))); return x }())
        m.verdict = .verifiedAutomated; m.manualRequired = ["looks right in the editor"]
        #expect(m.validationState == .manualTestRequired)
        m.manualRecorded = ["m1"]; m.manualRequired = []
        #expect(m.validationState == .manuallyVerified)
    }

    @Test("the report is rendered from records only, in both languages: objective, files, real evidence, findings, risks, manual checks, local commit")
    func report() {
        let rep = EngineeringReport.build(record())
        let en = rep.render(language: .en).joined(separator: "\n"), tr = rep.render(language: .tr).joined(separator: "\n")
        #expect(en.contains("AUTOMATED TESTED · MANUAL TEST REQUIRED") && en.contains("Files changed: calc.py") && en.contains("unitTests: unit → exit 0 (3 passed, 0 failed)") && en.contains("For you to check: Unity editor") && en.contains("Local commit: abcdef123456"))
        #expect(tr.contains("OTOMATİK TEST EDİLDİ · MANUEL TEST GEREKLİ") && tr.contains("Değişen dosyalar: calc.py") && tr.contains("Sizin kontrol etmeniz gereken"))
        var failed = record(); failed.verdict = .failed; failed.stopReason = .sameFailureRepeated
        let risk = EngineeringReport.build(failed).render(language: .en).joined(separator: "\n")
        #expect(risk.contains("NOT VERIFIED") && risk.contains("the work is NOT verified") && risk.contains("stopped: sameFailureRepeated"))
        #expect(!en.lowercased().contains("chain of thought"))
    }

    @Test("the morning digest counts what happened from the run records: verified, automated-only, blocked, failed, waiting, files, tests, failed attempts, manual checks")
    func digest() {
        var blocked = EngineeringRunRecord(assignment: a("Refactor menu", allowed: ["menu/**"])); blocked.stopReason = .sameFailureRepeated; blocked.verdict = .failed
        var waiting = EngineeringRunRecord(assignment: a("Remove old assets", allowed: ["assets/**"])); waiting.stopReason = .approvalRequired
        var ok = record(); ok.verdict = .verified; ok.manualRequired = []
        let d = EngineeringDigest.build([record(), blocked, waiting, ok])
        #expect(d.attempted == 4 && d.verified == 1 && d.automatedOnly == 1 && d.failed == 1 && d.awaitingApproval == 1 && d.blocked == 1 && d.filesChanged == ["calc.py"] && d.testsRun == 2 && d.failuresAndFixes == 2 && d.manualChecks.count == 1)
        #expect(d.render(language: .en).contains("4 task(s) attempted") && d.render(language: .tr).contains("4 görev denendi"))
        #expect(EngineeringDigest.build([]).render(language: .en).contains("No engineering task"))
    }

    @Test("the run record is bounded, hygiene-checked (no reasoning, no secrets), and a checkpoint resumes only after revalidation")
    func checkpoint() throws {
        var r = EngineeringRunRecord(assignment: a())
        let secret = "ghp_" + String(repeating: "a1B2", count: 6)
        for i in 0..<(EngineeringRunRecord.maxEvents + 30) { r.log(.verify, "step", "event \(i)") }
        r.log(.implement, "note", "<thinking>maybe the shader</thinking>"); r.log(.implement, "note", "token \(secret)")
        #expect(r.events.count == EngineeringRunRecord.maxEvents && r.droppedEvents > 0 && r.events.suffix(2).allSatisfy { $0.detail == "[withheld]" })
        let before = snap(["calc.py": "1", "util.py": "1"])
        guard let data = EngineeringCheckpointer.encode(r, workspaceDigest: before.digest), let back = EngineeringCheckpointer.decode(data) else { Issue.record("round trip"); return }
        #expect(back.checkpointDigest == before.digest && !String(decoding: data, as: UTF8.self).contains(secret))
        #expect(EngineeringCheckpointer.resume(back, checkpointSnapshot: before, now: before) == .resume)
        let own = snap(["calc.py": "2", "util.py": "1"])
        var withOwn = back; withOwn.changedFiles = ["calc.py"]
        #expect(EngineeringCheckpointer.resume(withOwn, checkpointSnapshot: before, now: own) == .resume, "the task's own change is not drift")
        #expect(EngineeringCheckpointer.resume(back, checkpointSnapshot: before, now: snap(["calc.py": "1", "util.py": "9"])) == .replan(changed: ["util.py"]))
        #expect({ if case .askUser = EngineeringCheckpointer.resume(back, checkpointSnapshot: before, now: snap(["calc.py": "1", "util.py": "1"], head: "h2")) { return true }; return false }())
        #expect({ if case .askUser = EngineeringCheckpointer.resume(back, checkpointSnapshot: before, now: snap(["calc.py": "1", "util.py": "1"], branch: "feature")) { return true }; return false }())
        #expect(EngineeringCheckpointer.resume(back, checkpointSnapshot: snap(["calc.py": "x"]), now: before) == .corrupt, "a record that does not match its snapshot digest is not truth")
        #expect(EngineeringCheckpointer.decode(Data(data.prefix(40))) == nil, "a torn write never decodes")
    }
}
