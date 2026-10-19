import Foundation
import Testing
@testable import Jarvis

// V1.0 background-intelligence pass — the reliability policies around the TaskEngine, tested against the REAL task model (state machine, step / approval records, failure categories, idempotency).
// Pure logic with injected time: no engine, no provider, no database, no timer, no microphone, no GUI. (Persistence and the overnight simulation have their own files.)

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func step(_ key: String, _ type: StepType = .analysis, deps: [String] = [], state: TaskStepState = .pending, attempts: Int = 0, optional: Bool = false, index: Int = 0, title: String? = nil) -> TaskStepRecord {
    TaskStepRecord(id: UUID(), taskID: UUID(), index: index, key: key, title: title ?? key, type: type, dependsOn: deps, validation: .default(for: type), state: state, attempts: attempts, optional: optional)
}

// MARK: Task state machine audit

@Suite("V1.0 background · task state machine audit")
struct TaskTransitionAuditTests {
    @Test("every transition on the forbidden list is rejected by the real state machine")
    func forbidden() {
        for (a, b) in ForbiddenTransitions.task { #expect(!TaskStateMachine.canMove(a, to: b), Comment(rawValue: "\(a) → \(b)")) }
        for (a, b) in ForbiddenTransitions.step { #expect(!TaskStateMachine.canMove(a, to: b), Comment(rawValue: "step \(a) → \(b)")) }
    }

    @Test("terminal states are sinks; interrupted is the only way back and it is explicit; nothing completes without running; approval never skips to running without a decision path")
    func structure() {
        for s in TaskState.allCases where s.isTerminal { #expect(s.allowedNext.isEmpty, Comment(rawValue: s.rawValue)) }
        for s in TaskStepState.allCases where s.isTerminal { #expect(s.allowedNext.isEmpty, Comment(rawValue: s.rawValue)) }
        // completed is reachable only from running
        #expect(TaskState.allCases.filter { $0.allowedNext.contains(.completed) } == [.running])
        // an interrupted task can resume but can never jump to completed or waitingForApproval
        #expect(!TaskState.interrupted.allowedNext.contains(.completed) && !TaskState.interrupted.allowedNext.contains(.waitingForApproval))
        // every non-terminal state can reach a terminal state (no state is a trap)
        for s in TaskState.allCases where !s.isTerminal {
            var seen: Set<TaskState> = [s], frontier = [s], reaches = false
            while let n = frontier.popLast() { for x in n.allowedNext { if x.isTerminal { reaches = true }; if seen.insert(x).inserted { frontier.append(x) } } }
            #expect(reaches, Comment(rawValue: "\(s) cannot terminate"))
        }
        // every state is reachable from created
        var reach: Set<TaskState> = [.created], fr: [TaskState] = [.created]
        while let n = fr.popLast() { for x in n.allowedNext where reach.insert(x).inserted { fr.append(x) } }
        #expect(reach == Set(TaskState.allCases))
    }

    @Test("the vocabulary of a long task (queued, retrying, waiting for a dependency, paused, blocked …) is DERIVED from existing states, not added")
    func derived() {
        func status(_ t: TaskState, _ s: [TaskStepRecord]) -> DerivedTaskStatus { TaskStatusDeriver.derive(task: t, steps: s).status }
        #expect(status(.created, []) == .queued && status(.planning, []) == .planning && status(.ready, [step("a")]) == .ready)
        #expect(status(.running, [step("a", state: .running, attempts: 1)]) == .running)
        #expect(status(.running, [step("a", state: .running, attempts: 3)]) == .retrying)
        #expect(status(.running, [step("a", .test, state: .verifying)]) == .verifying)
        #expect(status(.running, [step("a", .delete, state: .waitingForApproval)]) == .waitingForApproval)
        #expect(status(.waitingForApproval, [step("a", .delete, state: .waitingForApproval)]) == .waitingForApproval)
        #expect(status(.interrupted, [step("a", state: .interrupted)]) == .paused)
        #expect(status(.running, [step("a", .build, state: .failed), step("b", .test, deps: ["a"])]) == .blocked)
        // nothing in flight, something pending whose dependency is not satisfied and did not fail → waiting for a dependency
        let waiting = TaskStatusDeriver.derive(task: .running, steps: [step("a", deps: ["x"], state: .pending), step("x", deps: ["a"], state: .pending)])
        #expect(waiting.status == .waitingForDependency && waiting.blockedBy.contains("x"))
        #expect(status(.completed, [step("a", state: .passed)]) == .completed && status(.failed, []) == .failed && status(.cancelled, []) == .cancelled)
        #expect(DerivedTaskStatus.paused.needsPerson && DerivedTaskStatus.blocked.needsPerson && !DerivedTaskStatus.running.needsPerson)
        let v = TaskStatusDeriver.derive(task: .running, steps: [step("a", state: .passed), step("b", state: .running), step("c", state: .skipped)])
        #expect(v.stepsPassed == 1 && v.stepsMeasurable == 2 && v.stepsTotal == 3 && v.currentStepKey == "b")
    }
}

// MARK: Dependencies

@Suite("V1.0 background · dependencies: a failed step never lets its dependents run")
struct StepReadinessTests {
    @Test("build failed → deploy never becomes ready; download failed → import never becomes ready; an optional failure does not block")
    func failureBlocksDependents() {
        let steps = [step("build", .build, state: .failed, index: 0), step("test", .test, deps: ["build"], index: 1), step("deploy", .analysis, deps: ["test"], index: 2)]
        #expect(StepReadiness.ready(steps).isEmpty)
        #expect(StepReadiness.blockedByFailure(steps) == ["test", "deploy"])
        let dl = [step("download", .acquire, state: .failed), step("import", .importAsset, deps: ["download"])]
        #expect(StepReadiness.ready(dl).isEmpty && StepReadiness.blockedByFailure(dl) == ["import"])
        let optional = [step("polish", .analysis, state: .failed, optional: true), step("next", .analysis, deps: ["polish"])]
        #expect(StepReadiness.ready(optional).map(\.key) == ["next"])
    }

    @Test("independent work continues while one branch waits for an approval or has stopped; dependents of that branch do not")
    func independentWork() {
        let steps = [step("del", .delete, state: .waitingForApproval, index: 0), step("after", .analysis, deps: ["del"], index: 1), step("other", .analysis, index: 2), step("other2", .test, deps: ["other"], index: 3)]
        #expect(StepReadiness.independentWhileBlocked(steps).map(\.key) == ["other"])
        let interrupted = [step("a", .codeChange, state: .interrupted), step("b", .analysis, deps: ["a"]), step("c", .analysis)]
        #expect(StepReadiness.independentWhileBlocked(interrupted).map(\.key) == ["c"])
        #expect(StepReadiness.ready([step("a", state: .passed), step("b", deps: ["a"])]).map(\.key) == ["b"])
    }
}

// MARK: Retry

@Suite("V1.0 background · retries are classified, bounded and budgeted per task")
struct RetryPolicyTests {
    @Test("every failure category has a class; permanent, permission, approval, invalid-input and cancel are never retried")
    func classes() {
        for c in [FailureCategory.workspaceViolation, .securityBlocked, .workspaceChanged, .unsafeEditorState, .acquisitionRefused] { #expect(RetryClassifier.classify(c) == .permanent, Comment(rawValue: c.rawValue)) }
        for c in [FailureCategory.permissionRequired, .capabilityDenied, .blockedByNetworkPolicy] { #expect(RetryClassifier.classify(c) == .permission) }
        for c in [FailureCategory.approvalDenied, .interactionRequired] { #expect(RetryClassifier.classify(c) == .approvalRequired) }
        for c in [FailureCategory.malformedPlan, .ambiguousTarget, .noSources, .scopeExceeded] { #expect(RetryClassifier.classify(c) == .invalidInput) }
        #expect(RetryClassifier.classify(.cancelled) == .cancelled && RetryClassifier.classify(.interrupted) == .cancelled)
        #expect(RetryClassifier.classify(.providerRateLimited) == .rateLimited && RetryClassifier.classify(.networkUnavailable) == .network && RetryClassifier.classify(.computerTimeout) == .timeout)
        #expect(RetryClassifier.classify(.buildFailed) == .deterministicValidation && RetryClassifier.classify(.providerUnavailable) == .transient)
        var ledger = RetryLedger(policy: RetryPolicy(jitterFraction: 0))
        for c in [FailureCategory.workspaceViolation, .permissionRequired, .approvalDenied, .malformedPlan, .cancelled, .buildFailed, .testFailed, .validationFailed] {
            if case .giveUp(_, .notRetryable) = ledger.decide(step: "s", failure: c) {} else { Issue.record("must not be retried automatically: \(c)") }
        }
        #expect(ledger.total == 0, "a refusal consumes no budget")
    }

    @Test("transient failures back off exponentially up to the step limit, then give up with a reason; the task budget caps all steps together")
    func budgets() {
        var ledger = RetryLedger(policy: RetryPolicy(baseDelay: 2, factor: 2, maxDelay: 60, perStep: 3, perStepRateLimited: 2, perTask: 5, jitterFraction: 0))
        var delays: [TimeInterval] = []
        for _ in 0..<3 { if case .retry(let after, _, .transient) = ledger.decide(step: "a", failure: .providerUnavailable) { delays.append(after) } }
        #expect(delays == [2, 4, 8])
        if case .giveUp(.transient, .stepBudgetExhausted) = ledger.decide(step: "a", failure: .providerUnavailable) {} else { Issue.record("the step budget must end the retries") }
        // other steps may still retry until the TASK budget is spent: 3 used, 2 left
        for _ in 0..<2 { if case .retry = ledger.decide(step: "b", failure: .networkUnavailable) {} else { Issue.record("task budget not yet spent") } }
        if case .giveUp(_, .taskBudgetExhausted) = ledger.decide(step: "c", failure: .providerUnavailable) {} else { Issue.record("the task budget must end retries across steps") }
        #expect(ledger.total == 5 && ledger.remaining == 0 && GiveUpReason.taskBudgetExhausted.recommendation == "checkpoint-and-pause")
        // rate limits get fewer, longer waits
        var rl = RetryLedger(policy: RetryPolicy(jitterFraction: 0))
        if case .retry(let after, _, .rateLimited) = rl.decide(step: "r", failure: .providerRateLimited) { #expect(after == 4) } else { Issue.record("rate limit retry expected") }
        _ = rl.decide(step: "r", failure: .providerRateLimited)
        if case .giveUp(_, .stepBudgetExhausted) = rl.decide(step: "r", failure: .providerRateLimited) {} else { Issue.record("rate-limit retries are fewer") }
    }

    @Test("jitter is deterministic for a seed, bounded, and never makes a delay negative or above the cap")
    func jitter() {
        var a = RetryLedger(policy: RetryPolicy(jitterFraction: 0.2), seed: 7), b = RetryLedger(policy: RetryPolicy(jitterFraction: 0.2), seed: 7), c = RetryLedger(policy: RetryPolicy(jitterFraction: 0.2), seed: 8)
        func delay(_ l: inout RetryLedger) -> TimeInterval { if case .retry(let d, _, _) = l.decide(step: "x", failure: .providerUnavailable) { return d }; return -1 }
        let da = delay(&a), db = delay(&b), dc = delay(&c)
        #expect(da == db && da >= 1.6 && da <= 2.4 && dc >= 1.6 && dc <= 2.4)
    }

    @Test("no infinite retry loop: whatever the failure sequence, the ledger gives up within perTask decisions")
    func finite() {
        var ledger = RetryLedger(policy: RetryPolicy(perStep: 100, perTask: 12, jitterFraction: 0))
        var retries = 0
        for i in 0..<10_000 { if case .retry = ledger.decide(step: "s\(i % 50)", failure: .providerUnavailable) { retries += 1 } }
        #expect(retries == 12)
    }
}

// MARK: Task budgets

@Suite("V1.0 background · task budgets stop a runaway loop, not honest work")
struct TaskBudgetTests {
    @Test("each dimension exhausts independently, warns once at 80 %, and the verdict names the dimension")
    func dimensions() {
        var b = TaskBudgetLedger(budget: TaskBudget(wallClock: 100, modelRequests: 10, providerRetries: 5, toolFailures: 4, consecutiveVerificationFailures: 3))
        #expect(b.check() == .ok)
        for _ in 0..<8 { b.noteModelRequest() }
        if case .warn(.modelRequests, _, _) = b.check() {} else { Issue.record("expected a warning at 80 %") }
        #expect(b.check() == .ok, "a warning is reported once")
        for _ in 0..<2 { b.noteModelRequest() }
        if case .exhausted(.modelRequests, 10, 10) = b.check() {} else { Issue.record("expected exhaustion") }
        var w = TaskBudgetLedger(budget: TaskBudget(wallClock: 100)); w.addActive(101)
        #expect(w.check().isExhausted)
    }

    @Test("consecutive verification failures reset on a pass; the generous defaults let a long task finish")
    func verification() {
        var b = TaskBudgetLedger(budget: TaskBudget(consecutiveVerificationFailures: 3))
        b.noteVerification(passed: false); b.noteVerification(passed: false)
        b.noteVerification(passed: true)
        b.noteVerification(passed: false); b.noteVerification(passed: false)
        #expect(!b.check().isExhausted)
        b.noteVerification(passed: false)
        if case .exhausted(.consecutiveVerificationFailures, _, _) = b.check() {} else { Issue.record("three in a row must exhaust") }
        let d = TaskBudget()
        #expect(d.wallClock >= 8 * 3600 && d.modelRequests >= 200 && d.consecutiveVerificationFailures >= 3, "not so small that an honest night of work is stopped")
    }
}

// MARK: Replay and verification

@Suite("V1.0 background · replaying after a crash, and verification that is not a verdict")
struct StepReplayTests {
    @Test("side-effect classes: reads repeat, edits inspect first, deletes / imports / gates are never replayed on their own authority")
    func classes() {
        for t in [StepType.analysis, .review, .build, .test, .unityInspect, .researchSearch, .experiment] { #expect(StepSideEffects.classify(t) == .readOnly) }
        for t in [StepType.codeChange, .unityEdit, .acquire] { #expect(StepSideEffects.classify(t) == .idempotentWrite) }
        for t in [StepType.computerAct, .importAsset, .delegateComputer] { #expect(StepSideEffects.classify(t) == .nonIdempotentWrite) }
        for t in [StepType.delete, .approvalGate] { #expect(StepSideEffects.classify(t) == .critical) }
        // the engine's own idempotency table agrees with the classes (retryable ⇔ read-only, manual ⇒ non-idempotent or critical)
        for t in StepType.allCases where t.idempotency == .manual { #expect(StepSideEffects.classify(t) != .readOnly) }
    }

    @Test("a crash during read / test / build replays; a crash during a write inspects first; a delete is never replayed without a fresh approval")
    func replay() {
        for crash in CrashPoint.allCases { #expect(StepReplayPolicy.decide(.test, crash: crash, evidence: ReplayEvidence()) == .replay) }
        #expect(StepReplayPolicy.decide(.codeChange, crash: .duringWrite, evidence: ReplayEvidence(effectObserved: true)) == .skipAlreadyDone)
        #expect(StepReplayPolicy.decide(.codeChange, crash: .duringWrite, evidence: ReplayEvidence(worldUnchanged: true)) == .replay)
        #expect(StepReplayPolicy.decide(.codeChange, crash: .afterEffectBeforeRecord, evidence: ReplayEvidence()) == .revalidateThenReplay)
        #expect(StepReplayPolicy.decide(.codeChange, crash: .duringWrite, evidence: ReplayEvidence(diverged: true)) != .replay)
        if case .neverReplay = StepReplayPolicy.decide(.delete, crash: .duringWrite, evidence: ReplayEvidence()) {} else { Issue.record("a delete must not be replayed") }
        #expect(StepReplayPolicy.decide(.delete, crash: .duringWrite, evidence: ReplayEvidence(effectObserved: true)) == .skipAlreadyDone)
        #expect(StepReplayPolicy.decide(.delete, crash: .beforeStart, evidence: ReplayEvidence(freshApproval: true)) == .replay)
        if case .neverReplay = StepReplayPolicy.decide(.importAsset, crash: .duringWrite, evidence: ReplayEvidence()) {} else { Issue.record("an import must not be replayed") }
        if case .askUser = StepReplayPolicy.decide(.importAsset, crash: .duringWrite, evidence: ReplayEvidence(diverged: true)) {} else { Issue.record("diverged state asks the person") }
    }

    @Test("an inconclusive verification never repeats a non-idempotent action; reads may be re-checked once")
    func inconclusive() {
        // the form was submitted; the check timed out
        for t in [StepType.computerAct, .importAsset, .delegateComputer, .delete] {
            #expect(VerificationPolicy.afterAction(t, verification: .inconclusive, alreadyRepeated: false) == .recordUnverifiedDoNotRepeat, Comment(rawValue: t.rawValue))
        }
        #expect(VerificationPolicy.afterAction(.test, verification: .inconclusive, alreadyRepeated: false) == .reverifyOrRepeatOnce)
        #expect(VerificationPolicy.afterAction(.test, verification: .inconclusive, alreadyRepeated: true) == .failHonestly)
        #expect(VerificationPolicy.afterAction(.codeChange, verification: .inconclusive, alreadyRepeated: false) == .reverifyOrRepeatOnce)
        #expect(VerificationPolicy.afterAction(.codeChange, verification: .inconclusive, alreadyRepeated: true) == .recordUnverifiedDoNotRepeat)
        for t in StepType.allCases {
            #expect(VerificationPolicy.afterAction(t, verification: .verifiedSuccess, alreadyRepeated: false) == .accept)
            #expect(VerificationPolicy.afterAction(t, verification: .verifiedFailure, alreadyRepeated: false) == .failHonestly)
        }
    }
}

// MARK: Approvals

@Suite("V1.0 background · an approval belongs to one action and expires")
struct ApprovalBindingTests {
    private let task = UUID()
    private func binding(_ target: String = "Assets/a.png", params: String = "", risk: RiskClass = .high, op: String = "delete") -> ApprovalBinding {
        ApprovalBinding(taskID: task, stepKey: "s3", operation: op, target: target, parameters: params, risk: risk)
    }

    @Test("the same action matches while fresh; any material change breaks the binding")
    func binding_() {
        let granted = binding()
        #expect(ApprovalReuse.evaluate(granted: granted, approvedAt: t0, requested: binding(), now: t0.addingTimeInterval(600)) == .matches)
        #expect(ApprovalReuse.evaluate(granted: granted, approvedAt: t0, requested: binding("Assets/b.png"), now: t0.addingTimeInterval(60)) == .differentAction)
        #expect(ApprovalReuse.evaluate(granted: granted, approvedAt: t0, requested: binding(params: "recursive"), now: t0.addingTimeInterval(60)) == .differentAction)
        #expect(ApprovalReuse.evaluate(granted: granted, approvedAt: t0, requested: binding(op: "overwrite"), now: t0.addingTimeInterval(60)) == .differentAction)
        #expect(ApprovalReuse.evaluate(granted: binding(risk: .medium), approvedAt: t0, requested: binding(risk: .high), now: t0.addingTimeInterval(60)) == .differentRisk)
        var other = binding(); other.taskID = UUID()
        #expect(ApprovalReuse.evaluate(granted: granted, approvedAt: t0, requested: other, now: t0.addingTimeInterval(60)) == .differentAction)
        // length-prefixed: shifting a character between fields cannot collide
        #expect(binding("ab", params: "c").digest != binding("a", params: "bc").digest)
    }

    @Test("freshness by risk: low/medium 12 h, high 2 h, critical never; a future or missing decision time is not an approval")
    func expiry() {
        #expect(ApprovalFreshness.mayReuse(approvedAt: t0, risk: .medium, now: t0.addingTimeInterval(11 * 3600)))
        #expect(!ApprovalFreshness.mayReuse(approvedAt: t0, risk: .medium, now: t0.addingTimeInterval(13 * 3600)))
        #expect(ApprovalFreshness.mayReuse(approvedAt: t0, risk: .high, now: t0.addingTimeInterval(3600)))
        #expect(!ApprovalFreshness.mayReuse(approvedAt: t0, risk: .high, now: t0.addingTimeInterval(3 * 3600)))
        #expect(!ApprovalFreshness.mayReuse(approvedAt: t0, risk: .critical, now: t0.addingTimeInterval(1)))
        #expect(!ApprovalFreshness.mayReuse(approvedAt: nil, risk: .low, now: t0) && !ApprovalFreshness.mayReuse(approvedAt: t0.addingTimeInterval(100), risk: .low, now: t0))
        #expect(ApprovalReuse.evaluate(granted: binding(), approvedAt: t0, requested: binding(), now: t0.addingTimeInterval(5 * 3600)) == .stale)
    }

    @Test("a persisted approval record is reused only when approved, fresh for its risk and the action text is identical (the engine's restart path)")
    func record() {
        var rec = ApprovalRecord(id: UUID(), taskID: task, stepID: UUID(), action: "delete Assets/a.png", reason: "r", risk: .high)
        #expect(!ApprovalFreshness.mayReuse(rec, forAction: "delete Assets/a.png", now: t0), "pending is not approved")
        rec.state = .approved; rec.decidedAt = t0
        #expect(ApprovalFreshness.mayReuse(rec, forAction: "delete Assets/a.png", now: t0.addingTimeInterval(1800)))
        #expect(!ApprovalFreshness.mayReuse(rec, forAction: "delete Assets/b.png", now: t0.addingTimeInterval(1800)))
        #expect(!ApprovalFreshness.mayReuse(rec, forAction: "delete Assets/a.png", now: t0.addingTimeInterval(4 * 3600)))
        rec.state = .denied
        #expect(!ApprovalFreshness.mayReuse(rec, forAction: "delete Assets/a.png", now: t0.addingTimeInterval(60)))
    }
}

// MARK: Drift and Git

@Suite("V1.0 background · project binding, drift and Git safety")
struct ProjectDriftTests {
    private let head = GitSnapshot(isRepository: true, branch: "main", head: "aaa", detachedHead: false, dirtyPaths: ["user.txt"], untrackedPaths: [], conflictInProgress: false)

    @Test("a task keeps ITS project: the focused project is ignored")
    func binding() {
        #expect(TaskProjectBinding.workspace(recorded: "/work/A", focused: "/work/B") == "/work/A")
        #expect(TaskProjectBinding.workspace(recorded: nil, focused: "/work/B") == nil, "an unbound task is never silently bound to whatever is focused")
    }

    @Test("file changed / removed / appeared, HEAD moved, branch changed, dirty tree, conflict, detached HEAD, moved folder are all detected")
    func detect() {
        let rec = ProjectFingerprint(rootExists: true, git: head, fileHashes: ["a.swift": "h1", "b.swift": "h2", "c.swift": nil])
        #expect(ProjectDrift.assess(recorded: rec, current: rec).isEmpty)
        var cur = rec
        cur.fileHashes = ["a.swift": "CHANGED", "b.swift": nil, "c.swift": "new"]
        let issues = ProjectDrift.assess(recorded: rec, current: cur)
        #expect(issues.contains(.fileChanged("a.swift")) && issues.contains(.fileRemoved("b.swift")) && issues.contains(.fileAppeared("c.swift")))
        #expect(ProjectDrift.action(for: issues) == .revalidateThenContinue)
        var g = head; g.head = "bbb"
        #expect(ProjectDrift.assess(recorded: rec, current: ProjectFingerprint(rootExists: true, git: g, fileHashes: rec.fileHashes)).contains(.headMoved(from: "aaa", to: "bbb")))
        g = head; g.branch = "feature"
        #expect(ProjectDrift.action(for: ProjectDrift.assess(recorded: rec, current: ProjectFingerprint(rootExists: true, git: g, fileHashes: rec.fileHashes))) == .blockAndReport)
        g = head; g.conflictInProgress = true
        #expect(ProjectDrift.assess(recorded: rec, current: ProjectFingerprint(rootExists: true, git: g, fileHashes: rec.fileHashes)).contains(.conflictInProgress))
        g = head; g.detachedHead = true; g.branch = nil
        #expect(ProjectDrift.assess(recorded: rec, current: ProjectFingerprint(rootExists: true, git: g, fileHashes: rec.fileHashes)).contains(.detachedHead))
        g = head; g.dirtyPaths = ["user.txt", "new-dirty.txt"]; g.untrackedPaths = ["scratch.txt"]
        let dirty = ProjectDrift.assess(recorded: rec, current: ProjectFingerprint(rootExists: true, git: g, fileHashes: rec.fileHashes))
        #expect(dirty.contains(.newDirtyPaths(["new-dirty.txt"])) && dirty.contains(.newUntracked(["scratch.txt"])))
        #expect(ProjectDrift.assess(recorded: rec, current: ProjectFingerprint(rootExists: false, git: nil, fileHashes: [:])) == [.rootMissing])
        #expect(ProjectDrift.action(for: [.rootMissing]) == .blockAndReport && ProjectDrift.action(for: [.newUntracked(["x"])]) == .continueNormally)
        // files the TASK itself touched are not drift
        var mine = head; mine.dirtyPaths = ["user.txt", "task-file.txt"]
        #expect(ProjectDrift.assess(recorded: rec, current: ProjectFingerprint(rootExists: true, git: mine, fileHashes: rec.fileHashes), touchedByTask: ["task-file.txt"]).isEmpty)
    }

    @Test("writes are refused over a user's changes, over a file that changed under the task, and while the repository is in conflict or on another branch — and JARVIS never reacts by resetting or discarding")
    func writes() {
        #expect(ProjectDrift.mayWrite(path: "a.swift", drift: [], userDirty: []))
        #expect(!ProjectDrift.mayWrite(path: "user.txt", drift: [], userDirty: ["user.txt"]))
        #expect(!ProjectDrift.mayWrite(path: "a.swift", drift: [.fileChanged("a.swift")], userDirty: []))
        #expect(ProjectDrift.mayWrite(path: "b.swift", drift: [.fileChanged("a.swift")], userDirty: []))
        #expect(!ProjectDrift.mayWrite(path: "a.swift", drift: [.conflictInProgress], userDirty: []))
        #expect(!ProjectDrift.mayWrite(path: "a.swift", drift: [.branchChanged(from: "main", to: "x")], userDirty: []))
        #expect(ProjectDrift.forbiddenReactions == Set(ProjectDrift.ForbiddenReaction.allCases) && ProjectDrift.forbiddenReactions.count == 7)
    }
}

// MARK: Event log and notifications

@Suite("V1.0 background · the task event log is bounded, de-duplicated and secret-free")
struct TaskEventLogTests {
    @Test("17 identical failures become ONE entry with a count, the first detail and the first/last time; important events are never merged")
    func dedupe() {
        var log = TaskEventLog(capacity: 50)
        for i in 0..<17 { log.record(.failure, step: "s1", code: "provider-timeout", detail: "attempt \(i)", at: t0.addingTimeInterval(Double(i) * 60)) }
        #expect(log.entries.count == 1 && log.entries[0].count == 17 && log.entries[0].detail == "attempt 0" && log.entries[0].last == t0.addingTimeInterval(16 * 60) && log.entries[0].first == t0)
        for _ in 0..<3 { log.record(.approvalRequested, step: "s2", code: "delete", at: t0) }
        #expect(log.entries.filter { $0.kind == .approvalRequested }.count == 3, "approvals are never merged")
        #expect(log.summaryLines(language: .en).first?.contains("×17") == true && log.count(of: .failure) == 17)
        // a different step or code is a different failure
        log.record(.failure, step: "s2", code: "provider-timeout", at: t0); log.record(.failure, step: "s1", code: "build-failed", at: t0)
        #expect(log.entries.filter { $0.kind == .failure }.count == 3)
    }

    @Test("the log never exceeds its capacity; aggregatable entries go first; dropped counts are kept; important events survive")
    func bounded() {
        var log = TaskEventLog(capacity: 20)
        log.record(.taskStarted, code: "start", at: t0)
        for i in 0..<500 { log.record(.stepCompleted, step: "s\(i)", code: "done", at: t0.addingTimeInterval(Double(i))) }
        log.record(.blocked, code: "needs-approval", at: t0)
        #expect(log.entries.count <= 20 && log.dropped > 400)
        #expect(log.entries.contains { $0.kind == .taskStarted } && log.entries.contains { $0.kind == .blocked })
        var all = TaskEventLog(capacity: 10)
        for i in 0..<100 { all.record(.approvalRequested, step: "s\(i)", code: "x", at: t0) }
        #expect(all.entries.count <= 10 && all.dropped >= 90, "even an all-important log is bounded")
    }

    @Test("detail is clipped, stripped of control characters and replaced when it looks like a secret; there is no field for hidden reasoning")
    func redaction() {
        var log = TaskEventLog()
        log.record(.failure, code: "x", detail: String(repeating: "a", count: 900) + "\u{7}", at: t0)
        #expect(log.entries[0].detail.count == TaskEventLog.maxDetail && !log.entries[0].detail.contains("\u{7}"))
        log.record(.failure, code: "y", detail: "key sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAA leaked", at: t0)
        #expect(log.entries[1].detail == "<redacted>")
        let names = Mirror(reflecting: log.entries[0]).children.compactMap(\.label)
        #expect(!names.contains { $0.lowercased().contains("reason") || $0.lowercased().contains("thought") }, "no reasoning field exists: \(names)")
    }

    @Test("notifications: completed, blocked, approval (critical louder), terminal failure — never retries or progress; flapping is rate-limited")
    func notifications() {
        var p = NotificationPolicy()
        #expect(p.evaluate(.retryScheduled, at: t0) == .silent && p.evaluate(.stepCompleted, at: t0) == .silent && p.evaluate(.providerFallback, at: t0) == .silent && p.evaluate(.checkpointWritten, at: t0) == .silent)
        #expect(p.evaluate(.taskCompleted, at: t0) == .notify("completed") && p.evaluate(.taskFailed, at: t0) == .notify("failed"))
        #expect(p.evaluate(.approvalRequested, critical: true, at: t0) == .notify("critical-approval"))
        #expect(p.evaluate(.blocked, at: t0) == .notify("blocked"))
        #expect(p.evaluate(.blocked, at: t0.addingTimeInterval(60)) == .silent, "a flapping block does not spam")
        #expect(p.evaluate(.blocked, at: t0.addingTimeInterval(16 * 60)) == .notify("blocked"))
        #expect(p.evaluate(.approvalRequested, critical: true, at: t0.addingTimeInterval(61)) == .notify("critical-approval"), "a critical approval always gets through")
    }
}

// MARK: Usage

@Suite("V1.0 background · usage accounting is honest")
struct UsageLedgerTests {
    @Test("missing token counts stay missing, money is never invented, totals are lower bounds, and the ledger is bounded")
    func usage() {
        var l = UsageLedger(capacity: 10)
        let task = UUID()
        l.record(UsageRecord(taskID: task, provider: "opencode", model: "m", inputTokens: 100, outputTokens: 50, latency: 1.0, failed: false, isRetry: false, at: t0))
        l.record(UsageRecord(taskID: task, provider: "opencode", model: "m", inputTokens: nil, outputTokens: nil, latency: 3.0, failed: true, isRetry: true, at: t0))
        let t = l.byProvider["opencode"]!
        #expect(t.requests == 2 && t.failures == 1 && t.retries == 1 && t.inputTokens == 100 && t.outputTokens == 50 && t.runsWithoutTokens == 1 && t.meanLatency == 2.0)
        #expect(t.estimatedCost(pricePer1kTokens: nil) == nil && t.estimatedCost(pricePer1kTokens: 0.01) == 0.0015)
        #expect(l.byTask[task]?.requests == 2)
        for _ in 0..<100 { l.record(UsageRecord(taskID: nil, provider: "local", model: nil, inputTokens: 1, outputTokens: 1, latency: nil, failed: false, isRetry: false, at: t0)) }
        #expect(l.recent.count == 10 && l.byProvider["local"]?.requests == 100 && l.byProvider["local"]?.meanLatency == nil)
        l.forget(task: task)
        #expect(l.byTask[task] == nil)
    }
}

// MARK: Context

@Suite("V1.0 background · context is minimised without losing what keeps the task safe")
struct ContextSelectorTests {
    private func item(_ k: ContextKind, _ text: String, _ w: Double = 0) -> ContextItem { ContextItem(kind: k, text: text, weight: w) }

    @Test("invariants are always included verbatim, however tight the budget; the rest is ranked and capped")
    func invariants() {
        let base: [ContextItem] = [item(.objective, "Fix the shader bug in project Hamam"), item(.projectIdentity, "project=Hamam path=/p/Hamam"), item(.pendingApproval, "approval pending: delete Assets/old.png"),
                                   item(.failedVerification, "test run failed: 3 failures"), item(.prohibition, "user said: do not touch Scenes/Main.unity"), item(.constraint, "no network")]
        let pad = String(repeating: "x", count: 100)
        let turnItems: [ContextItem] = (0..<30).map { (n: Int) -> ContextItem in item(.recentTurn, "turn \(n) " + pad, Double(n)) }
        let memories: [ContextItem] = (0..<20).map { (n: Int) -> ContextItem in item(.memorySnippet, "memory \(n)", Double(n)) }
        let old: [ContextItem] = (0..<50).map { (n: Int) -> ContextItem in item(.history, "old \(n) " + pad, Double(n)) }
        var items = base
        items.append(contentsOf: turnItems); items.append(contentsOf: memories); items.append(contentsOf: old)
        let s = ContextSelector.select(items, budget: 900)
        #expect(s.invariants.count == 6)
        let text = ContextSelector.render(s)
        for must in ["delete Assets/old.png", "do not touch Scenes/Main.unity", "3 failures", "project=Hamam", "Fix the shader bug", "no network"] { #expect(text.contains(must), Comment(rawValue: must)) }
        #expect(s.included.filter { $0.kind == .recentTurn }.count <= ContextSelector.maxRecentTurns && s.included.filter { $0.kind == .memorySnippet }.count <= ContextSelector.maxMemorySnippets, "per-kind caps")
        #expect(s.usedCharacters <= 900 || s.overBudget, Comment(rawValue: "used \(s.usedCharacters) of 900"))
        #expect(s.compactionLine?.hasPrefix("[omitted:") == true && s.droppedCounts[.history, default: 0] > 0, Comment(rawValue: "compaction \(s.compactionLine ?? "nil") dropped \(s.droppedCounts)"))
        // newest turns win
        let turns = s.included.filter { $0.kind == .recentTurn }.map(\.weight)
        #expect(turns == turns.sorted(by: >))
    }

    @Test("when the invariants alone exceed the budget they are kept anyway and the selection says so")
    func overBudget() {
        let s = ContextSelector.select([item(.objective, String(repeating: "o", count: 500)), item(.prohibition, String(repeating: "p", count: 500)), item(.recentTurn, "hello")], budget: 100)
        #expect(s.overBudget && s.invariants.count == 2 && s.included.isEmpty)
    }

    @Test("the latest tool result outranks conversation; a huge tool result is clipped; compaction is counts, not prose")
    func ranking() {
        let s = ContextSelector.select([item(.toolResult, String(repeating: "t", count: 9_000), 1), item(.recentTurn, "hi", 5), item(.history, "old", 1)], budget: 2_300)
        #expect(s.included.first?.kind == .toolResult && (s.included.first?.text.count ?? 0) <= ContextSelector.maxToolResultCharacters + 1)
        let c = ContextSelector.select((0..<20).map { item(.history, "line \($0)", Double($0)) }, budget: 60)
        #expect(c.compactionLine?.contains("history") == true && !(c.compactionLine ?? "").contains("line"))
    }
}

// MARK: Workers, resources, processes

@Suite("V1.0 background · worker admission for a 16 GB machine")
struct WorkerAdmissionTests {
    @Test("synthetic machine states: idle, local model loaded, Unity active, browser active, Computer Use active, a coding worker running")
    func states() {
        func admit(_ w: WorkerKind, _ running: [WorkerKind], pressure: MemoryPressureLevel = .normal, power: PowerContext = PowerContext(), explicit: Bool = false, required: Bool = false) -> Admission {
            WorkerAdmission.admit(w, running: running, pressure: pressure, power: power, explicitlyRequested: explicit, required: required)
        }
        #expect(admit(.codingAgent, []).allowed && admit(.localModelSmall, []).allowed && admit(.analysisAgent, [.localModelSmall]).allowed)
        // one heavy coding agent, three agents, one local model
        #expect(!admit(.codingAgent, [.codingAgent]).allowed)
        #expect(!admit(.analysisAgent, [.codingAgent, .analysisAgent, .freeCloudAgent]).allowed)
        #expect(!admit(.localModelSmall, [.localModelLarge]).allowed && !admit(.localModelLarge, [.localModelSmall]).allowed)
        // the combination the brief names: coding agent + large local model + Unity + Computer Use
        #expect(!admit(.localModelLarge, [.codingAgent, .unityEditor, .computerUse]).allowed, "a 9B-class model next to Unity and an agent does not fit the budget")
        #expect(admit(.localModelSmall, [.codingAgent, .unityEditor, .computerUse]).allowed)
        // memory pressure stops optional heavy work but never the task's own required worker
        #expect(!admit(.localModelLarge, [], pressure: .warning).allowed)
        #expect(admit(.codingAgent, [], pressure: .warning, required: true).allowed)
        // Computer Use capture is tiny: allowed next to Unity
        #expect(admit(.computerUse, [.unityEditor, .codingAgent]).allowed)
    }

    @Test("benchmarks never start on their own; optional heavy work waits on low battery / low-power / thermal pressure; required work does not")
    func power() {
        func admit(_ w: WorkerKind, power: PowerContext, explicit: Bool = false, required: Bool = false) -> Admission { WorkerAdmission.admit(w, running: [], power: power, explicitlyRequested: explicit, required: required) }
        #expect(!admit(.benchmark, power: PowerContext()).allowed, "no benchmark without an explicit request")
        #expect(admit(.benchmark, power: PowerContext(), explicit: true).allowed)
        for p in [PowerContext(lowPowerMode: true), PowerContext(thermalSerious: true), PowerContext(onBattery: true, batteryFraction: 0.1)] {
            #expect(!admit(.benchmark, power: p, explicit: true).allowed && !admit(.localModelLarge, power: p).allowed)
            #expect(admit(.codingAgent, power: p, required: true).allowed && admit(.analysisAgent, power: p).allowed, "the task's own work is never blocked by power state")
        }
        #expect(admit(.localModelLarge, power: PowerContext(onBattery: true, batteryFraction: nil)).allowed, "an unknown battery level never blocks")
        #expect(WorkerAdmission.parallelNodes(pressure: ResourcePressure(), power: PowerContext(), calmLimit: 2) == 2)
        #expect(WorkerAdmission.parallelNodes(pressure: ResourcePressure(), power: PowerContext(thermalSerious: true), calmLimit: 2) == 1)
        #expect(WorkerAdmission.parallelNodes(pressure: ResourcePressure(memory: .warning), power: PowerContext(), calmLimit: 2) == 1)
    }

    @Test("task cleanup terminates only processes started FOR that task; shared and user-owned processes are never touched; orphans are found")
    func processes() {
        let a = UUID(), b = UUID()
        let own = TrackedProcess(pid: 10, ownership: .startedForTask, taskID: a), other = TrackedProcess(pid: 11, ownership: .startedForTask, taskID: b)
        let shared = TrackedProcess(pid: 12, ownership: .startedByJarvisShared, taskID: nil), external = TrackedProcess(pid: 13, ownership: .externalUserOwned, taskID: nil)
        #expect(ProcessHygiene.shouldTerminate(own, whenTaskEnds: a) && !ProcessHygiene.shouldTerminate(other, whenTaskEnds: a))
        #expect(!ProcessHygiene.shouldTerminate(shared, whenTaskEnds: a) && !ProcessHygiene.shouldTerminate(external, whenTaskEnds: a))
        #expect(ProcessHygiene.orphans([own, other, shared, external], liveTasks: [b]).map(\.pid) == [10])
    }
}

// MARK: Digest and the morning brief

@Suite("V1.0 background · the report and the morning questions come from structured state")
struct TaskDigestTests {
    private func digest() -> NightTaskDigest {
        var task = TaskRecord(id: UUID(), title: "t", goal: "Fix the shader bug and update the menu scene", kind: .development)
        task.state = .running
        let s1 = step("s1", .analysis, state: .passed, index: 0, title: "Analyse shader"), s2 = step("s2", .codeChange, state: .passed, index: 1, title: "Patch shader"),
            s3 = step("s3", .delete, state: .waitingForApproval, index: 2, title: "Remove old texture"), s4 = step("s4", .test, deps: ["s2"], state: .failed, index: 3, title: "Run tests")
        var s4f = s4; s4f.failureReason = "3 tests failed"; s4f.failureCategory = .testFailed
        var s2e = s2; s2e.validationEvidence = "1 file changed, hash recorded"
        let approval = ApprovalRecord(id: UUID(), taskID: task.id, stepID: s3.id, action: "delete Assets/old.png", reason: "r", risk: .high)
        let attempts = [StepAttemptRecord(stepID: s2.id, taskID: task.id, number: 1, kind: .primary, engine: .openCode, model: "m", outcome: "failed:providerFailed"), StepAttemptRecord(stepID: s2.id, taskID: task.id, number: 2, kind: .escalation, engine: .claudeCode, model: nil, outcome: "passed")]
        let change = TaskFileChange(path: "Assets/shader.shader", changeType: "modified", beforeHash: "a", afterHash: "b", stepKey: "s2", preexistingUserChange: false)
        var log = TaskEventLog()
        for _ in 0..<5 { log.record(.failure, step: "s4", code: "tests-failed", at: t0) }
        return NightTaskDigest.build(task: task, steps: [s1, s2e, s3, s4f], attempts: attempts, approvals: [approval], changes: [change], events: log, language: .en)
    }

    @Test("the report lists what was completed, changed, failed, waiting and remaining, the providers used and the retries — and nothing else")
    func report() {
        let d = digest()
        let text = d.report(language: .en).joined(separator: "\n")
        #expect(text.contains("Fix the shader bug") && text.contains("Analyse shader; Patch shader") && text.contains("Assets/shader.shader") && text.contains("Run tests — 3 tests failed"))
        #expect(text.contains("delete Assets/old.png") && text.contains("claudeCode") == false || text.contains("Providers:"))
        #expect(text.contains("verified 2/4") && text.contains("Same event ×5"))
        #expect(d.providersUsed.values.reduce(0, +) == 2 && d.fallbacks == 1)
        let tr = d.report(language: .tr).joined(separator: "\n")
        #expect(tr.contains("Hedef:") && tr.contains("Onayınızı bekleyen"))
    }

    @Test("the five morning questions are recognised (Turkish and English) and answered from the digest; answering starts nothing")
    func morning() {
        #expect(MorningBrief.recognize("Gece ne yaptın?") == .whatDidYouDo && MorningBrief.recognize("Nerede kaldın?") == .whereDidYouStop && MorningBrief.recognize("Ne başarısız oldu?") == .whatFailed)
        #expect(MorningBrief.recognize("Benden ne bekliyorsun?") == .whatDoYouNeedFromMe && MorningBrief.recognize("Devam edebilir misin?") == .canYouContinue)
        #expect(MorningBrief.recognize("What did you do?") == .whatDidYouDo && MorningBrief.recognize("what failed") == .whatFailed && MorningBrief.recognize("can you continue") == .canYouContinue)
        #expect(MorningBrief.recognize("Bana bir fıkra anlat") == nil && MorningBrief.recognize("Safari'yi aç") == nil)
        let d = digest()
        #expect(MorningBrief.answer(.whatFailed, digests: [d], language: .tr).contains("Run tests"))
        #expect(MorningBrief.answer(.whatDoYouNeedFromMe, digests: [d], language: .en).contains("Approval: delete Assets/old.png (high)"))
        #expect(MorningBrief.answer(.whereDidYouStop, digests: [d], language: .en).contains("Step "))
        #expect(MorningBrief.answer(.canYouContinue, digests: [d], language: .en).lowercased().contains("approval") || MorningBrief.answer(.canYouContinue, digests: [d], language: .en).contains("Not"))
        #expect(MorningBrief.answer(.whatDidYouDo, digests: [], language: .en) == "There is no task on record.")
        var paused = d; paused.derived = DerivedTaskView(status: .paused, stepsTotal: 4, stepsPassed: 2, stepsMeasurable: 4, currentStepKey: nil, blockedBy: [], reason: nil)
        #expect(MorningBrief.answer(.canYouContinue, digests: [paused], language: .en).contains("re-check") && MorningBrief.answer(.whatDoYouNeedFromMe, digests: [paused], language: .tr).contains("devam et"))
        var done = d; done.derived = DerivedTaskView(status: .completed, stepsTotal: 4, stepsPassed: 4, stepsMeasurable: 4, currentStepKey: nil, blockedBy: [], reason: nil)
        #expect(MorningBrief.answer(.canYouContinue, digests: [done], language: .en).contains("complete"))
    }

    @Test("an empty digest answers honestly: nothing failed, nothing waits")
    func quiet() {
        var task = TaskRecord(id: UUID(), title: "t", goal: "g", kind: .readOnlyAnalysis); task.state = .completed
        let d = NightTaskDigest.build(task: task, steps: [step("a", state: .passed)])
        #expect(MorningBrief.answer(.whatFailed, digests: [d], language: .en).contains("Nothing failed") && MorningBrief.answer(.whatDoYouNeedFromMe, digests: [d], language: .en).contains("Nothing is waiting"))
    }
}
