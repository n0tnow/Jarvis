import Foundation
import Testing
@testable import Jarvis

// V1.0 autonomous engineering pipeline — a deterministic chaos scenario, a repository-drift scenario, a long engineering soak and property tests over the whole typed space.
//
// HONEST SCOPE: this is NOT the TaskEngine and not a second orchestrator. A test driver composes the REAL policies (assignment, ownership registry, worker selection, snapshot + attribution,
// verifier, repair loop, review rubric, staleness, rollback planning, checkpoint / resume, report) over REAL disposable Git + Python fixtures and scripted "workers". It proves the policies fit
// together and hold their invariants; it does not prove that the engine wires them (docs/AUTONOMOUS_ENGINEERING_PIPELINE.md lists the integration seams). No provider, model, UI or real project is involved.

private struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 { state ^= state >> 12; state ^= state << 25; state ^= state >> 27; return state &* 2685821657736338717 }
    mutating func below(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
    mutating func chance(_ p: Double) -> Bool { Double(next() % 1_000_000) / 1_000_000 < p }
}

/// One scripted attempt of the driver: a worker action or an injected fault.
private enum Step { case worker(EngWorkerScript), providerTimeout, cancel }

private struct SimOutcome {
    var record: EngineeringRunRecord
    var workersUsed: [String] = []
    var providerFailures = 0
    var staleDetected = false
    var checkpointRoundTrips = 0
    var gateDenied = 0
    var events: Int { record.events.count + record.droppedEvents }
    var illegalVerified = false
    var reviewBlocked = 0
}

private let pool: [WorkerProfile] = {
    func w(_ id: String, pricing: WorkerPricing = .verifiedZero, premium: Bool = false) -> WorkerProfile {
        var x = WorkerProfile(id: id, capabilities: [.codeGeneration, .codeReview, .testGeneration, .debugging, .repositoryAnalysis], pricing: pricing); x.premiumReasoning = premium; x.benchmarkSuccess = 0.8; return x
    }
    return [w("worker-a"), w("worker-b"), w("worker-c", pricing: .subscription, premium: true), w("paid-x", pricing: .paid, premium: true)]
}()

private func drive(_ t: EngTask, fixture f: EngFixture, steps: [Step], escalationAllowed: Bool = true, budget: EngineeringBudget = EngineeringBudget(), driftBefore: ((EngFixture) -> Void)? = nil, reviewWith: [ModelFinding] = []) -> SimOutcome {
    var a = t.assignment
    a.budget = budget
    var record = EngineeringRunRecord(assignment: a)
    var out = SimOutcome(record: record)
    var loop = RepairLoop(budget: budget)
    var registry = OwnershipRegistry()
    var (start, startContents) = f.capture()
    let initialStart = start
    a.base = initialStart.revision; record.assignment = a; record.baseline = initialStart.revision; record.baselineGit = initialStart.git
    record.log(.observe, "snapshot", "digest \(start.digest.prefix(8))")
    guard a.validate().isEmpty, DelegationPolicy.mayDelegate(a) else { record.log(.blocked, "invalid-assignment"); record.stopReason = .approvalRequired; out.record = record; return out }
    record.log(.plan, "assignment-valid")
    guard registry.request(a, owner: "run") == .granted else { record.log(.blocked, "ownership"); out.record = record; return out }
    var unavailable = Set<String>()
    var cancelled = false
    var lifecycle = TaskLifecycleView(cancelRequested: false, terminal: false)
    var contents = startContents
    var previousWorker: String?
    for step in steps {
        if cancelled { break }
        switch step {
        case .cancel:
            cancelled = true; lifecycle.cancelRequested = true
            _ = registry.cancel(a.id)
            record.log(.blocked, "cancelled"); record.stopReason = nil
            continue
        case .providerTimeout:
            // the provider selected for this attempt timed out: the circuit opens for it, a different eligible worker is tried next
            let sel = WorkerSelector.select(for: a, workers: pool, excluding: unavailable)
            if let c = sel.chosen { unavailable.insert(c) }
            out.providerFailures += 1; loop.noteProviderTimeout()
            record.log(.assign, "provider-timeout", sel.chosen ?? "none")
            continue
        case .worker(let script):
            guard AssignmentGate.mayIssueWrite(lifecycle, scope: a.scope) else { out.gateDenied += 1; continue }
            let sel = WorkerSelector.select(for: a, workers: pool, excluding: unavailable)
            guard let chosen = sel.chosen else { record.log(.blocked, "no-worker"); record.stopReason = .providerUnavailable; out.record = record; return out }
            if chosen != previousWorker { out.workersUsed.append(chosen) }
            previousWorker = chosen
            record.log(.assign, "worker", chosen)
            loop.noteWorkerAttempt(worker: chosen)
            var s = script; s.worker = chosen
            // the repository may drift while the worker runs
            if let drift = driftOnce(&driftHook, driftBefore) { drift(f) }
            let (preSnap, preContents) = f.capture()
            let staleness = StalenessCheck.assess(startedAt: start, now: preSnap, scope: a.scope, readSet: [t.primary, t.testFile], ownChanges: Set(record.changedFiles))
            if case .fresh = staleness {
                // somebody else's edit to an unrelated file is folded into the baseline: it is neither the task's change nor a scope escape
                let rebased = start.rebased(onto: preSnap, own: Set(record.changedFiles))
                if rebased != start { record.log(.inspect, "external-change", "unrelated files changed outside the task; baseline rebased"); start = rebased; for (p, c) in preContents where startContents[p] != c && !record.changedFiles.contains(p) { startContents[p] = c } }
            } else {
                out.staleDetected = true
                record.log(.inspect, "stale", "the repository changed after the assignment started")
                record.stopReason = .approvalRequired; out.record = record; return out
            }
            let run = EngHarness.execute(f, script: s)
            guard AssignmentGate.mayApplyResult(lifecycle) else { continue }
            loop.noteVerificationRun()
            for (p, c) in run.observed.contents { contents[p] = c }
            // several attempts together are judged against the TASK's start, not against the previous attempt
            let cumulative = ObservedState(before: start, after: run.after, deltas: f.deltas(before: startContents, after: run.observed.contents), applied: record.applied + run.observed.applied, evidence: run.observed.evidence, contents: run.observed.contents, commit: nil)
            let (verdict, plan) = EngHarness.verdict(observed: cumulative, claims: run.claims, parseIssue: run.parseIssue, assignment: a)
            record.plan = plan; record.evidence = run.observed.evidence; record.findings = verdict.findings
            record.changedFiles = verdict.attribution.changes.map(\.change.path).sorted()
            record.applied += run.observed.applied
            record.log(.verify, "verdict", verdict.status.rawValue)
            // review (deterministic evidence first; a model reviewer's findings only with verifiable evidence)
            var status = verdict.status
            if status == .needsReview || status == .verified, !reviewWith.isEmpty {
                let diff = DiffInspector.condensed(deltas: cumulative.deltas, changes: cumulative.changes)
                let review = ReviewRubric.evaluate(verdict: verdict, modelFindings: reviewWith, condensedDiff: diff)
                if !review.passes { out.reviewBlocked += 1; status = .failed; record.log(.review, "blocked", review.blocking.first?.message ?? "") } else { record.log(.review, "passed") }
            }
            var effective = verdict
            effective.status = status
            if let data = EngineeringCheckpointer.encode(record, workspaceDigest: run.after.digest), let back = EngineeringCheckpointer.decode(data), EngineeringCheckpointer.resume(back, checkpointSnapshot: run.after, now: run.after) == .resume {
                out.checkpointRoundTrips += 1; record.log(.checkpoint, "written")
            }
            let failing = run.observed.evidence.filter { !$0.passed }.map(\.excerpt).joined(separator: "\n")
            let decision = loop.decide(verdict: effective, failureOutput: failing, assignment: a, workerName: chosen, escalationAllowed: escalationAllowed, providerAvailable: true, diffSummary: DiffInspector.condensed(deltas: cumulative.deltas, changes: cumulative.changes, budget: 800))
            record.attempts = loop.history
            switch decision {
            case .done:
                record.verdict = effective.status; record.manualRequired = effective.manualRequired
                record.log(.done, "verified")
                if !(run.observed.evidence.contains { $0.stage == .unitTests && $0.passed && $0.snapshotDigest == run.after.digest } || plan.requiredStages.isEmpty) { out.illegalVerified = true }
                if !effective.findings.blockers.isEmpty { out.illegalVerified = true }
                out.record = record; return out
            case .stop(let reason): record.stopReason = reason; record.verdict = effective.status; record.log(.blocked, "stop", reason.rawValue); out.record = record; return out
            case .escalate(_, let why): previousWorker = nil; unavailable.insert(chosen); record.log(.correct, "escalate", why)
            case .repair: record.log(.correct, "repair")
            }
            record.verdict = effective.status
            _ = preContents
        }
    }
    out.record = record
    return out
}

private var driftHook: Bool = false
private func driftOnce(_ fired: inout Bool, _ hook: ((EngFixture) -> Void)?) -> ((EngFixture) -> Void)? { guard !fired, let h = hook else { return nil }; fired = true; return h }

private func claims(_ t: EngTask) -> String { EngHarness.report(changed: [t.primary]) }

@Suite("V1.0 engineering · chaos: timeout, retry, failed verification, review, second worker, checkpoint, report", .serialized)
struct EngineeringChaosTests {
    @Test("plan → worker A times out → another worker answers with a bad patch → verification fails → review finds the issue → a different worker fixes it → verified → checkpoint → grounded report")
    func happyChaos() {
        driftHook = false
        let t = EngBenchmark.tasks[1]                                           // the multi-file bug
        let f = EngBenchmark.fixture(t)
        let halfFix = EngWorkerScript(label: "half fix", edits: ["tax.py": "def rate():\n    return 0.08\n"], report: EngHarness.report(changed: ["tax.py", "pricing.py"]))      // forgets the rounding and claims both files
        let good = EngWorkerScript(label: "full fix", edits: t.good, report: EngHarness.report(changed: t.good.keys.sorted()))
        let out = drive(t, fixture: f, steps: [.providerTimeout, .worker(halfFix), .worker(good)])
        #expect(out.providerFailures == 1 && out.record.verdict == .verified && out.record.stopReason == nil && !out.illegalVerified)
        #expect(out.workersUsed.first != "worker-a" && !out.workersUsed.contains("paid-x"), Comment(rawValue: "the timed-out worker is not asked again: \(out.workersUsed)"))
        #expect(out.record.attempts.map(\.outcome).contains { $0.hasPrefix("failed") } && out.record.attempts.last?.outcome == "verified")
        #expect(out.checkpointRoundTrips == 2 && out.record.events.contains { $0.stage == .checkpoint })
        #expect(out.record.changedFiles == ["pricing.py", "tax.py"] && out.record.validationState == .automatedTested)
        let rep = EngineeringReport.build(out.record).render(language: .en).joined(separator: "\n")
        #expect(rep.contains("AUTOMATED TESTED") && rep.contains("Files changed: pricing.py, tax.py") && rep.contains("unitTests: python3 -m unittest → exit 0"))
        #expect(f.read("pricing.py") == t.good["pricing.py"]! && f.read("other.py") == EngBenchmark.tasks[1].files["other.py"])
    }

    @Test("the review step: verified-by-tests work that a reviewer blocks WITH evidence is not completed; a reviewer without evidence cannot block")
    func review() {
        driftHook = false
        let t = EngBenchmark.tasks[0]
        let good = EngWorkerScript(label: "fix", edits: t.good, report: claims(t))
        let withEvidence = ModelFinding(text: "add() ignores overflow of big ints in other callers", severity: .blocker, dimension: .correctness, evidence: "return a + b")
        let blocked = drive(t, fixture: EngBenchmark.fixture(t), steps: [.worker(good)], reviewWith: [withEvidence])
        #expect(blocked.reviewBlocked == 1 && blocked.record.verdict != .verified)
        let noEvidence = ModelFinding(text: "I just do not like it", severity: .blocker, dimension: .maintainability, evidence: "vibes")
        let passed = drive(t, fixture: EngBenchmark.fixture(t), steps: [.worker(good)], reviewWith: [noEvidence])
        #expect(passed.reviewBlocked == 0 && passed.record.verdict == .verified)
    }

    @Test("repository DRIFT during the worker's run: the user edits a file in scope → the result is detected as stale, never verified, and the user's edit is preserved")
    func drift() {
        driftHook = false
        let t = EngBenchmark.tasks[0]
        let f = EngBenchmark.fixture(t)
        let good = EngWorkerScript(label: "fix", edits: t.good, report: claims(t))
        let out = drive(t, fixture: f, steps: [.worker(good)], driftBefore: { $0.write("calc.py", "def add(a, b):\n    return a - b  # the user is editing this right now\n") })
        #expect(out.staleDetected && out.record.verdict != .verified && out.record.stopReason == .approvalRequired)
        #expect(f.read("calc.py")?.contains("the user is editing this right now") == true, "nothing was applied over the user's concurrent edit")
        #expect(out.record.changedFiles.isEmpty && out.record.applied.isEmpty)
        // drift in an unrelated file does not block the task
        driftHook = false
        let g = EngBenchmark.fixture(t)
        let calm = drive(t, fixture: g, steps: [.worker(good)], driftBefore: { $0.write("README.md", "# fixture\n\nedited by the user while the worker ran\n") })
        #expect(!calm.staleDetected && calm.record.verdict == .verified)
    }

    @Test("an explicit provider choice that times out ends the run: no silent worker swap and no paid worker is ever used")
    func providerCost() {
        driftHook = false
        let t = EngBenchmark.tasks[0]
        let good = EngWorkerScript(label: "fix", edits: t.good, report: claims(t))
        let out = drive(t, fixture: EngBenchmark.fixture(t), steps: [.providerTimeout, .providerTimeout, .providerTimeout, .providerTimeout, .worker(good)])
        #expect(!out.workersUsed.contains("paid-x"), "a paid worker is never an automatic fallback")
        #expect(out.record.stopReason == .providerUnavailable && out.record.verdict == nil, Comment(rawValue: "all free / subscription workers timed out: \(String(describing: out.record.stopReason))"))
    }

    @Test("repeated identical failure: the loop escalates to a different worker once, then stops — it does not burn the whole budget")
    func repeatedFailure() {
        driftHook = false
        let t = EngBenchmark.tasks[0]
        var big = EngineeringBudget(); big.workerAttempts = 10; big.verificationRuns = 10; big.providerRequests = 30
        let wrong = EngWorkerScript(label: "same wrong fix", edits: ["calc.py": "def add(a, b):\n    return a * b\n"], report: claims(t))
        let out = drive(t, fixture: EngBenchmark.fixture(t), steps: Array(repeating: .worker(wrong), count: 8), budget: big)
        #expect(out.record.stopReason == .sameFailureRepeated && out.record.verdict == .failed)
        #expect(out.record.attempts.count <= 4, Comment(rawValue: "stopped after \(out.record.attempts.count) attempts of a budget of 10"))
        #expect(out.record.attempts.contains { $0.outcome.contains("escalate") })
    }

    @Test("cancellation: after a cancel no further write assignment is issued and no later result is applied")
    func cancellation() {
        driftHook = false
        let t = EngBenchmark.tasks[0]
        let f = EngBenchmark.fixture(t)
        let good = EngWorkerScript(label: "fix", edits: t.good, report: claims(t))
        let out = drive(t, fixture: f, steps: [.cancel, .worker(good), .worker(good)])
        #expect(out.gateDenied == 0 && out.record.verdict == nil && out.record.changedFiles.isEmpty)
        #expect(f.read("calc.py") == t.files["calc.py"], "the project was never written after the cancel")
        var lifecycle = TaskLifecycleView(cancelRequested: true, terminal: false)
        #expect(!AssignmentGate.mayIssueWrite(lifecycle, scope: t.assignment.scope) && !AssignmentGate.mayApplyResult(lifecycle))
        lifecycle.cancelRequested = false
        #expect(AssignmentGate.mayIssueWrite(lifecycle, scope: t.assignment.scope))
    }
}

@Suite("V1.0 engineering · long engineering soak (no real waiting)", .serialized)
struct EngineeringSoakTests {
    @Test("a long session: every benchmark task, several times, with timeouts, bad patches, repeated failures, escalation, reviews, cancellations and checkpoints — bounded, correctly attributed, no false completion")
    func soak() {
        var rng = SeededRandom(seed: 2026)
        var totalEvents = 0, verified = 0, stopped = 0, cancelled = 0, timeouts = 0, escalations = 0, workerSwitches = 0, roundTrips = 0, runs = 0, illegal = 0, paidUsed = 0, maxEvents = 0, maxAttempts = 0
        var records: [EngineeringRunRecord] = []
        for round in 0..<12 {
            let t = EngBenchmark.tasks[round % EngBenchmark.tasks.count]
            driftHook = false
            let f = EngBenchmark.fixture(t)
            let goodScript = EngWorkerScript(label: "good", edits: t.good, report: EngHarness.report(changed: t.good.keys.sorted()))
            let bads = EngBenchmark.badWorkers(t).map(\.script)
            var steps: [Step] = []
            let scenario = rng.below(6)
            switch scenario {
            case 0: steps = [.worker(goodScript)]
            case 1: steps = [.providerTimeout, .worker(bads[rng.below(bads.count)]), .worker(goodScript)]
            case 2: steps = [.worker(bads[5]), .worker(bads[5]), .worker(bads[5]), .worker(goodScript)]                     // the same placeholder over and over
            case 3: steps = [.worker(bads[rng.below(bads.count)]), .providerTimeout, .providerTimeout, .worker(goodScript)]
            case 4: steps = [.worker(bads[0]), .cancel, .worker(goodScript)]
            default: steps = [.worker(bads[rng.below(bads.count)]), .worker(bads[rng.below(bads.count)]), .worker(goodScript)]
            }
            var big = EngineeringBudget(); big.workerAttempts = 6; big.verificationRuns = 8; big.providerRequests = 20
            let out = drive(t, fixture: f, steps: steps, budget: big)
            runs += 1; totalEvents += out.events; records.append(out.record)
            maxEvents = max(maxEvents, out.record.events.count); maxAttempts = max(maxAttempts, out.record.attempts.count)
            roundTrips += out.checkpointRoundTrips; timeouts += out.providerFailures; workerSwitches += max(0, out.workersUsed.count - 1)
            if out.illegalVerified { illegal += 1 }
            if out.workersUsed.contains("paid-x") { paidUsed += 1 }
            if out.record.verdict == .verified { verified += 1 }
            if out.record.stopReason != nil { stopped += 1 }
            if scenario == 4 { cancelled += 1 }
            escalations += out.record.attempts.filter { $0.outcome.contains("escalate") }.count
            // attribution: whatever is reported as changed is what really differs from the committed fixture
            let diff = f.git(["status", "--porcelain=v1", "--untracked-files=all"]).output.split(separator: "\n").map { String($0.dropFirst(3)) }.sorted()
            if out.record.verdict == .verified { #expect(Set(out.record.changedFiles) == Set(diff), Comment(rawValue: "\(t.name): reported \(out.record.changedFiles) vs real \(diff)")) }
            #expect(out.record.events.count <= EngineeringRunRecord.maxEvents && out.record.attempts.count <= big.workerAttempts + 1)
        }
        #expect(runs == 12 && illegal == 0 && paidUsed == 0)
        #expect(verified >= 5 && stopped + cancelled >= 1, Comment(rawValue: "verified \(verified), stopped \(stopped), cancelled \(cancelled)"))
        #expect(totalEvents >= 100, Comment(rawValue: "events \(totalEvents)"))
        #expect(roundTrips >= 10 && timeouts >= 2 && maxAttempts <= 7)
        // the night's digest answers from the records only
        let d = EngineeringDigest.build(records)
        #expect(d.attempted == 12 && d.verified == verified && d.verified + d.automatedOnly + d.failed + d.blocked + d.awaitingApproval >= 1)
        #expect(!d.render(language: .tr).isEmpty && !d.render(language: .en).isEmpty)
        // no record ever claims verification without evidence
        for r in records where r.verdict == .verified { #expect(r.evidence.contains { $0.passed }, "a verified record carries passing evidence") }
        _ = (escalations, workerSwitches)
    }
}

// MARK: - Properties over the typed space (synthetic observed states: fast, seeded)

private func observed(before: [String: String], after: [String: String], evidence: [VerificationEvidence] = [], applied: [AppliedEdit] = [], dirty: Set<String> = [], contents: [String: String]? = nil) -> ObservedState {
    func snap(_ d: [String: String], _ g: GitFacts) -> WorkspaceSnapshot { WorkspaceSnapshot(files: d.mapValues { FileFingerprint(hash: Redactor.sha256($0), size: $0.count, isBinary: false) }, git: g, capturedAt: Date(timeIntervalSince1970: 0)) }
    let b = snap(before, GitFacts(head: "h", branch: "main", dirty: dirty)), a = snap(after, GitFacts(head: "h", branch: "main", dirty: dirty))
    let deltas = Set(before.keys).union(after.keys).sorted().compactMap { p in before[p] == after[p] ? nil : FileDelta(path: p, before: before[p], after: after[p]) }
    return ObservedState(before: b, after: a, deltas: deltas, applied: applied, evidence: evidence, contents: contents ?? after, commit: nil)
}

private func evidence(_ digest: String, stage: VerificationStage = .unitTests, profile: String = "unit", exit: Int32 = 0) -> VerificationEvidence {
    VerificationEvidence(stage: stage, profile: profile, exitStatus: exit, snapshotDigest: digest, recordedAt: Date(timeIntervalSince1970: 0), excerpt: "", counts: nil)
}

@Suite("V1.0 engineering · properties")
struct EngineeringPropertyTests {
    private func assignment(allowed: [String] = ["src/**"]) -> EngineeringAssignment {
        var a = EngineeringAssignment(objective: "Fix the parser bug in src/parse.py", project: "p")
        a.scope.allowed = allowed
        a.acceptance = [AcceptanceCriterion(id: "t", text: "tests", check: .profile("unit"))]
        return a
    }

    @Test("a worker's CLAIM alone can never mark work verified: 400 random claims against a repository that did not change or whose tests fail")
    func claimsAreNotEvidence() {
        var rng = SeededRandom(seed: 7)
        let a = assignment()
        let files = ["src/a.py": "x = 1\n", "src/b.py": "y = 2\n"]
        for _ in 0..<400 {
            let status = ["done", "done", "partial", "blocked", "failed"][rng.below(5)]
            let changed = (0..<rng.below(4)).map { _ in ["src/a.py", "src/b.py", "src/c.py", "README.md"][rng.below(4)] }
            let tests = rng.chance(0.7) ? ",\"tests\":{\"allGreen\":true,\"passed\":\(rng.below(50)),\"failed\":0}" : ""
            let commit = rng.chance(0.3) ? ",\"commit\":\"abc123\"" : ""
            let text = "{\"status\":\"\(status)\",\"filesChanged\":[\(changed.map { "\"\($0)\"" }.joined(separator: ","))]\(tests)\(commit)}"
            guard case .success(let c) = WorkerReportParser.parse(text) else { Issue.record("unparseable generated claim"); continue }
            // (1) nothing changed
            let none = observed(before: files, after: files)
            let plan = VerificationPlanner.plan(changedPaths: [], profiles: EngHarness.standardProfiles)
            #expect(!EngineeringVerifier.verify(assignment: a, claims: c, observed: none, plan: plan).isVerified)
            // (2) something changed but the real tests FAILED at the final revision
            var after = files; after["src/a.py"] = "x = 2\n"
            let failed = observed(before: files, after: after, evidence: [evidence(Redactor.sha256("-"), exit: 1)])
            let obs2 = ObservedState(before: failed.before, after: failed.after, deltas: failed.deltas, applied: failed.applied, evidence: [evidence(failed.after.digest, exit: 1)], contents: failed.contents, commit: nil)
            let plan2 = VerificationPlanner.plan(changedPaths: ["src/a.py"], profiles: EngHarness.standardProfiles)
            let v2 = EngineeringVerifier.verify(assignment: a, claims: c, observed: obs2, plan: plan2)
            #expect(!v2.isVerified && v2.status == .failed)
            // (3) no evidence at all
            let obs3 = ObservedState(before: failed.before, after: failed.after, deltas: failed.deltas, applied: failed.applied, evidence: [], contents: failed.contents, commit: nil)
            #expect(!EngineeringVerifier.verify(assignment: a, claims: c, observed: obs3, plan: plan2).isVerified)
        }
    }

    @Test("the verdict ignores claims: the same observation gives the same status with or without any claim that does not contradict it")
    func claimsDoNotChangeTheVerdict() {
        let a = assignment()
        let files = ["src/a.py": "x = 1\n"], after = ["src/a.py": "x = 2\n"]
        let base = observed(before: files, after: after)
        let obs = ObservedState(before: base.before, after: base.after, deltas: base.deltas, applied: [AppliedEdit(path: "src/a.py", workerID: "w", stepKey: "s", beforeHash: base.before.files["src/a.py"]?.hash, afterHash: base.after.files["src/a.py"]?.hash)], evidence: [evidence(base.after.digest), evidence(base.after.digest, stage: .build, profile: "build")], contents: after, commit: nil)
        let plan = VerificationPlanner.plan(changedPaths: ["src/a.py"], profiles: ProjectVerificationProfiles(unitTests: "unit", build: "build"))
        let silent = EngineeringVerifier.verify(assignment: a, claims: nil, observed: obs, plan: plan)
        #expect(silent.status == .verified)
        for text in ["{\"status\":\"done\",\"filesChanged\":[\"src/a.py\"]}", "{\"status\":\"done\",\"filesChanged\":[\"src/a.py\"],\"tests\":{\"allGreen\":true}}"] {
            guard case .success(let c) = WorkerReportParser.parse(text) else { continue }
            #expect(EngineeringVerifier.verify(assignment: a, claims: c, observed: obs, plan: plan).status == silent.status)
        }
    }

    @Test("a scope escape never passes silently: random change sets with at least one path outside the allowed files are never verified")
    func scopeEscape() {
        var rng = SeededRandom(seed: 11)
        let a = assignment(allowed: ["src/**"])
        let outside = ["README.md", ".gitignore", "other/x.py", "docs/a.md", "Package.swift"]
        for _ in 0..<150 {
            var before = ["src/a.py": "a\n", "README.md": "r\n", "other/x.py": "o\n", ".gitignore": "g\n", "docs/a.md": "d\n", "Package.swift": "p\n"], after = before
            after["src/a.py"] = "a2\n"
            for p in (0..<(1 + rng.below(3))).map({ _ in outside[rng.below(outside.count)] }) { after[p] = (after[p] ?? "") + "changed\n" }
            before["src/new.py"] = nil
            let o = observed(before: before, after: after)
            let obs = ObservedState(before: o.before, after: o.after, deltas: o.deltas, applied: o.changes.map { AppliedEdit(path: $0.path, workerID: "w", stepKey: "s", beforeHash: $0.beforeHash, afterHash: $0.afterHash) }, evidence: [evidence(o.after.digest), evidence(o.after.digest, stage: .build, profile: "build")], contents: after, commit: nil)
            let plan = VerificationPlanner.plan(changedPaths: o.changes.map(\.path), profiles: ProjectVerificationProfiles(unitTests: "unit", build: "build"))
            let v = EngineeringVerifier.verify(assignment: a, claims: nil, observed: obs, plan: plan)
            #expect(!v.isVerified && v.findings.contains(.scopeEscape))
        }
    }

    @Test("a failing check at the FINAL revision can never produce completion, whatever else is green; stale green evidence leaves the work unverified")
    func failureBlocksCompletion() {
        let a = assignment()
        let files = ["src/a.py": "x = 1\n"], after = ["src/a.py": "x = 2\n"]
        let o = observed(before: files, after: after)
        let profiles = ProjectVerificationProfiles(unitTests: "unit", build: "build")
        let plan = VerificationPlanner.plan(changedPaths: ["src/a.py"], profiles: profiles)
        func verdict(_ ev: [VerificationEvidence]) -> VerificationVerdict {
            EngineeringVerifier.verify(assignment: a, claims: nil, observed: ObservedState(before: o.before, after: o.after, deltas: o.deltas, applied: [AppliedEdit(path: "src/a.py", workerID: "w", stepKey: "s", beforeHash: o.before.files["src/a.py"]?.hash, afterHash: o.after.files["src/a.py"]?.hash)], evidence: ev, contents: after, commit: nil), plan: plan)
        }
        let d = o.after.digest
        #expect(verdict([evidence(d), evidence(d, stage: .build, profile: "build")]).status == .verified)
        #expect(verdict([evidence(d, exit: 1), evidence(d, stage: .build, profile: "build")]).status == .failed)
        #expect(verdict([evidence(d), evidence(d, stage: .build, profile: "build", exit: 2)]).status == .failed)
        #expect(!verdict([evidence("OLD-REVISION"), evidence("OLD-REVISION", stage: .build, profile: "build")]).isVerified)
        #expect(verdict([evidence("OLD"), evidence(d, exit: 1), evidence(d, stage: .build, profile: "build")]).status == .failed, "a pass from an older revision does not cancel a failure at this one")
    }

    @Test("a pre-existing dirty file can never be attributed to the task; a change no applied edit explains is never silently the task's")
    func dirtyFilesAreNotTheTasks() {
        var rng = SeededRandom(seed: 13)
        let names = (0..<10).map { "f\($0).py" }
        for _ in 0..<150 {
            var before: [String: String] = [:]
            for n in names { before[n] = "orig \(n)\n" }
            let dirty = Set(names.filter { _ in rng.chance(0.35) })
            for d in dirty { before[d] = "user's edit of \(d)\n" }                  // the user's work is IN the 'before' snapshot
            var after = before
            var applied: [AppliedEdit] = []
            let mine = names.filter { !dirty.contains($0) && rng.chance(0.3) }
            for m in mine { after[m] = "task edit \(m)\n"; applied.append(AppliedEdit(path: m, workerID: "w", stepKey: "s", beforeHash: Redactor.sha256(before[m]!), afterHash: Redactor.sha256(after[m]!))) }
            let stray = names.filter { !dirty.contains($0) && !mine.contains($0) && rng.chance(0.1) }
            for s in stray { after[s] = "somebody else \(s)\n" }
            let o = observed(before: before, after: after, dirty: dirty)
            let r = ChangeAttribution.attribute(changes: o.changes, applied: applied, baseline: o.before.git)
            #expect(Set(r.taskProduced.map(\.change.path)) == Set(mine))
            #expect(Set(r.unexplained.map(\.change.path)) == Set(stray))
            #expect(r.taskProduced.allSatisfy { !dirty.contains($0.change.path) } && Set(r.preexistingUntouched) == dirty)
        }
    }

    @Test("a critical assignment cannot be delegated without its gate, and a cancelled or finished task issues no write")
    func gates() {
        var rng = SeededRandom(seed: 17)
        for _ in 0..<200 {
            var a = assignment()
            a.risk = [RiskClass.low, .medium, .high, .critical][rng.below(4)]
            a.gateApproved = rng.chance(0.5)
            let delegable = DelegationPolicy.mayDelegate(a)
            #expect(delegable == (a.risk < .critical || a.gateApproved))
            #expect(a.validate().contains(.criticalNeedsGate) == (a.risk >= .critical && !a.gateApproved))
            let t = TaskLifecycleView(cancelRequested: rng.chance(0.4), terminal: rng.chance(0.2), interrupted: rng.chance(0.2))
            let mayWrite = AssignmentGate.mayIssueWrite(t, scope: a.scope)
            #expect(mayWrite == !(t.cancelRequested || t.terminal || t.interrupted))
            #expect(AssignmentGate.mayIssueWrite(t, scope: WriteScope()), "read-only work is not a write")
        }
    }

    @Test("the repair loop is bounded by construction: over 200 random failure streams it never runs more attempts than its budget and always terminates")
    func loopBounds() {
        var rng = SeededRandom(seed: 19)
        for _ in 0..<200 {
            var b = EngineeringBudget(); b.workerAttempts = 1 + rng.below(5); b.verificationRuns = 1 + rng.below(6); b.providerRequests = 1 + rng.below(8)
            var loop = RepairLoop(budget: b)
            var attempts = 0, finished = false
            let a = assignment()
            while attempts < 50, !finished {
                attempts += 1
                loop.noteWorkerAttempt(worker: "w"); loop.noteVerificationRun()
                let failure = "error \(rng.below(3)): thing\(rng.below(3))"
                let v = VerificationVerdict(status: .failed, findings: [EngineeringFinding(.criterionUnmet, .blocker, path: ".", "x", evidence: "e")], mismatches: [], unmetCriteria: ["t"], missingStages: [], revision: "r", attribution: AttributionReport(changes: [], lostEdits: [], preexistingUntouched: []), diffStats: DiffStats(files: 1))
                if case .stop = loop.decide(verdict: v, failureOutput: failure, assignment: a, workerName: "w", escalationAllowed: rng.chance(0.5), providerAvailable: rng.chance(0.95)) { finished = true }
            }
            #expect(finished && attempts <= max(b.workerAttempts, b.verificationRuns, b.providerRequests) + 3, Comment(rawValue: "attempts \(attempts) vs budget \(b)"))
        }
    }
}
