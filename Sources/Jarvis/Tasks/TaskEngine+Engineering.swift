import Foundation

// MARK: - The engineering seam in the ONE TaskEngine (V1.0 final integration)
//
// Six narrow call sites connect the pure engineering policies to the existing engine; nothing here schedules, routes, approves or stores anything of its own:
//
//   plan accepted ─ engineeringBegin ───────────────── assignment + snapshot of the workspace BEFORE any write (or the revalidated restore after a restart)
//   edits parsed ── engineeringStaleness / Gate ────── a result that raced with someone else's change is stale; a prospective edit set is judged BEFORE it is written
//   edits applied ─ engineeringAfterApply ───────────── the applied edits (attribution), the worker's claims (kept apart), the new observed revision
//   command run ─── engineeringDigest / RecordEvidence the revision a build / test ran against, and its result as VerificationEvidence (never for a cancelled run)
//   repair ──────── engineeringRepairGate ───────────── the bounded, semantic repair policy decides whether the engine's own (single) repair loop may go on
//   all steps passed engineeringCompletionGate ──────── the verdict from the REAL diff and the REAL evidence at the final revision: verified / not verified / refused
//
// Applies only to development tasks with a code-change step (`EngineeringSeam.applies`); conversation, status, navigation, launches, media and research never enter it.

extension TaskEngine {
    /// Hashing a workspace is file I/O: it runs off the main actor so a large project never freezes the app while a snapshot is taken.
    func engineeringCapture(root: String, git: GitFacts, withContents: Bool) async -> (snapshot: WorkspaceSnapshot, contents: [String: String]) {
        await Task.detached(priority: .utility) { EngineeringSeam.capture(root: root, git: git, withContents: withContents) }.value
    }
}

extension TaskEngine {
    // MARK: Begin

    /// Once per task, after the Git baseline and before the first write. After a restart the stored run is revalidated (project, branch, HEAD, workspace digest) and an engineering task that cannot
    /// prove its stored state does NOT write: it fails safe with a recoverable explanation.
    func engineeringBegin(_ ctx: TaskContext) async {
        guard ctx.engineering == nil, EngineeringSeam.applies(kind: ctx.record.kind, steps: ctx.steps) else { return }
        let git = await GitTool.facts(workspace: ctx.workspace) ?? GitFacts(isRepository: false)
        let (now, texts) = (await engineeringCapture(root: ctx.workspace.root, git: git, withContents: true))
        let labels = EngineeringSeam.profileLabels(ctx.profiles)
        if let restored = ctx.engineeringRestored {
            ctx.engineeringRestored = nil
            // The stored snapshot is taken AFTER every one of this task's own writes, so any difference from it is somebody else's change — even in a file the task also edited.
            var stored = restored.record; stored.changedFiles = []
            switch EngineeringCheckpointer.resume(stored, checkpointSnapshot: restored.observed, now: now) {
            case .resume:
                let before = restored.before ?? now
                var beforeTexts: [String: String] = [:]
                if let head = before.git.head {
                    for c in SnapshotDiff.between(before, now) where c.kind != .created && !before.git.dirty.contains(c.path) && !before.git.untracked.contains(c.path) {
                        if let t = await GitTool.contents(of: c.path, at: head, workspace: ctx.workspace) { beforeTexts[c.path] = t }
                    }
                }
                let s = EngineeringRunState(record: restored.record, before: before, beforeContents: beforeTexts, profiles: labels)
                s.observed = now
                s.record.log(.observe, "resumed", "the stored run matched the workspace")
                ctx.engineering = s
            case .replan(let changed):
                ctx.hardFailure = (.workspaceChanged, "The project changed since the last checkpoint (\(changed.prefix(5).joined(separator: ", "))\(changed.count > 5 ? ", …" : "")). Nothing was written; start the task again so it is planned against the current files.")
            case .askUser(let why):
                ctx.hardFailure = (.workspaceChanged, "The stored engineering state cannot be trusted: \(why). Nothing was written; start the task again.")
            case .corrupt:
                ctx.hardFailure = (.workspaceChanged, "The stored engineering state does not match its checkpoint digest (a torn or altered checkpoint). Nothing was written; start the task again.")
            }
            return
        }
        // A task that already changed files but has no readable engineering state (a checkpoint that is missing, torn or from before this feature) cannot prove its baseline.
        if !ctx.changes.isEmpty {
            ctx.hardFailure = (.workspaceChanged, "This task already changed files, but its engineering checkpoint is missing or unreadable, so the starting point cannot be proven. Nothing was written; start the task again.")
            return
        }
        let assignment = EngineeringSeam.assignment(record: ctx.record, steps: ctx.steps, profiles: ctx.profiles, base: now.revision)
        var record = EngineeringRunRecord(assignment: assignment)
        record.baseline = now.revision; record.baselineGit = git
        record.log(.observe, "baseline", "\(now.files.count) file(s) fingerprinted, \(git.dirty.count) modified and \(git.untracked.count) untracked by the user, \(git.staged.count) staged")
        let issues = assignment.validate()
        if !issues.isEmpty { record.log(.plan, "assignment-notes", issues.map(\.description).joined(separator: "; ")) }
        record.log(.assign, "assigned", "scope \(assignment.scope.allowed.joined(separator: ", ")); profiles \(assignment.verificationProfiles.isEmpty ? "none" : assignment.verificationProfiles.joined(separator: ", "))")
        ctx.engineering = EngineeringRunState(record: record, before: now, beforeContents: texts, profiles: labels)
    }

    // MARK: Before a worker result is applied

    /// A result that arrives after the repository changed in the assignment's scope (by someone else) is STALE: it is not applied, it is never "verified", the task says why.
    func engineeringStaleness(_ ctx: TaskContext) async -> (FailureCategory, String)? {
        guard let s = ctx.engineering else { return nil }
        if let why = s.resumeBlock { return (.workspaceChanged, why) }
        let git = await GitTool.facts(workspace: ctx.workspace) ?? s.observed.git
        let (now, _) = (await engineeringCapture(root: ctx.workspace.root, git: git, withContents: false))
        switch StalenessCheck.assess(startedAt: s.observed, now: now, scope: s.record.assignment.scope, readSet: [], ownChanges: []) {
        case .fresh: return nil
        case .stale(let changed, _):
            s.record.log(.inspect, "stale", changed.prefix(6).joined(separator: ", "))
            return (.workspaceChanged, "The project changed while the worker was running (\(changed.prefix(4).joined(separator: ", "))). The result was not applied and nothing is claimed; run the task again so it starts from the current files.")
        case .headMoved(let a, let b):
            s.record.log(.inspect, "head-moved", "\(a?.prefix(8) ?? "-") → \(b?.prefix(8) ?? "-")")
            return (.workspaceChanged, "The Git HEAD moved while the worker was running. The result was not applied; run the task again.")
        }
    }

    /// The deterministic review of a PROSPECTIVE edit set (prepared before/after texts), before anything is written. A blocker refuses the whole set.
    func engineeringGate(_ ctx: TaskContext, prepared: [ProjectTools.PreparedFile]) -> (FailureCategory, String)? {
        guard let s = ctx.engineering else { return nil }
        if let why = s.resumeBlock { return (.workspaceChanged, why) }
        let edits = prepared.map { EngineeringSeam.ProspectiveEdit(path: $0.path, before: $0.before, after: $0.after) }
        let findings = EngineeringSeam.review(edits, assignment: s.record.assignment, alreadyChanged: Set(ctx.changes.map(\.path)))
        let blockers = findings.blockers
        if !blockers.isEmpty {
            s.record.log(.inspect, "refused", EngineeringSeam.summary(blockers, limit: 2))
            s.record.findings = Array((s.record.findings + blockers).suffix(40))
            return (EngineeringSeam.category(for: blockers), "Not applied (nothing was written): " + EngineeringSeam.summary(blockers))
        }
        let majors = findings.majors
        if !majors.isEmpty { s.record.findings = Array((s.record.findings + majors).suffix(40)); s.record.log(.inspect, "advisory", EngineeringSeam.summary(majors, limit: 2)) }
        return nil
    }

    // MARK: After a worker result was applied

    func engineeringAfterApply(_ ctx: TaskContext, step: TaskStepRecord, changes: [TaskFileChange], providerText: String, candidate: RoutingCandidate) async {
        guard let s = ctx.engineering else { return }
        let worker = candidate.label
        let parsed = EngineeringSeam.claims(from: providerText)
        s.claims = parsed.claims; s.claimsIssue = parsed.issue
        for c in changes {
            s.record.applied.append(AppliedEdit(path: c.path, workerID: worker, stepKey: step.key, beforeHash: c.beforeHash, afterHash: c.afterHash))
            if !s.record.changedFiles.contains(c.path) { s.record.changedFiles.append(c.path) }
        }
        if !s.record.workers.contains(worker) { s.record.workers.append(worker) }
        s.loop.noteWorkerAttempt(worker: worker)
        s.record.attempts.append(AttemptSummary(number: s.loop.workerAttempts, worker: worker, outcome: "applied", signature: nil, filesChanged: changes.count, note: ""))
        s.record.log(.implement, "applied", "\(changes.count) file(s) by \(worker)")
        let git = await GitTool.facts(workspace: ctx.workspace) ?? s.observed.git
        s.observed = (await engineeringCapture(root: ctx.workspace.root, git: git, withContents: false)).snapshot
    }

    /// A provider call that produced nothing usable costs request budget, not a worker attempt.
    func engineeringNoteProviderFailure(_ ctx: TaskContext) { ctx.engineering?.loop.noteProviderTimeout() }

    // MARK: Verification evidence

    /// The revision a command is about to run against (digest of the workspace right now).
    func engineeringDigest(_ ctx: TaskContext) async -> String? {
        guard let s = ctx.engineering else { return nil }
        let git = await GitTool.facts(workspace: ctx.workspace) ?? s.observed.git
        return (await engineeringCapture(root: ctx.workspace.root, git: git, withContents: false)).snapshot.digest
    }

    /// An approved profile's real result becomes evidence for the revision it ran against — and only for that one.
    func engineeringRecordEvidence(_ ctx: TaskContext, step: TaskStepRecord, profile: CommandProfile, result: CommandResult, digest: String?) {
        guard let s = ctx.engineering, let digest else { return }
        s.loop.noteVerificationRun()
        guard let e = EngineeringSeam.evidence(step: step.type, profile: profile, result: result, digest: digest) else { s.record.log(.verify, "cancelled", profile.label); return }
        s.record.evidence.append(e)
        if s.record.evidence.count > 24 { s.record.evidence.removeFirst(s.record.evidence.count - 24) }
        s.record.log(.verify, e.passed ? "passed" : "failed", "\(profile.label) → exit \(e.exitStatus)")
    }

    // MARK: Repair

    /// Consulted by the engine's single repair loop before each repair / escalation: the semantic policy stops what the engine's own counters would not (the same failure repeating, exhausted
    /// worker / verification / request budgets, a security finding). It never ADDS attempts: the engine's bounds (one repair, one escalation, three attempts per step) still apply.
    func engineeringRepairGate(_ ctx: TaskContext, failure: String) async -> Bool {
        guard let s = ctx.engineering else { return true }
        let git = await GitTool.facts(workspace: ctx.workspace) ?? s.observed.git
        let (snap, texts) = (await engineeringCapture(root: ctx.workspace.root, git: git, withContents: true))
        let (verdict, _) = EngineeringSeam.verify(s, after: snap, afterContents: texts)
        let name = s.record.workers.last ?? "worker"
        let decision = s.loop.decide(verdict: verdict, failureOutput: failure, assignment: s.record.assignment, workerName: name, escalationAllowed: canEscalate(ctx), providerAvailable: true,
                                     failing: Set(verdict.unmetCriteria), diffSummary: "\(verdict.diffStats.files) file(s) changed")
        s.record.attempts = s.loop.history
        switch decision {
        case .repair, .escalate: s.record.log(.correct, "repair", "attempt \(s.loop.workerAttempts + 1)"); return true
        case .stop(let reason):
            s.record.stopReason = reason
            s.record.log(.blocked, "repair-stopped", reason.rawValue)
            note("Repair stopped by the engineering policy: \(reason.rawValue)", .warning, taskID: ctx.record.id)
            return false
        case .done: return true
        }
    }

    // MARK: Completion

    /// Runs when every counted step passed, before the engine reports success. The verdict is computed from the REAL repository and the REAL evidence at the final revision.
    /// nil = the task may be reported (verified or honestly "not verified"); a value = the completion is refused and the task fails with that reason.
    func engineeringCompletionGate(_ ctx: TaskContext) async -> (FailureCategory, String)? {
        guard let s = ctx.engineering else { return nil }
        let git = await GitTool.facts(workspace: ctx.workspace) ?? s.observed.git
        let (snap, texts) = (await engineeringCapture(root: ctx.workspace.root, git: git, withContents: true))
        let (verdict, plan) = EngineeringSeam.verify(s, after: snap, afterContents: texts)
        s.observed = snap
        s.record.plan = plan
        s.record.verdict = verdict.status
        s.record.findings = Array(verdict.findings.suffix(40))
        s.record.manualRequired = verdict.manualRequired
        s.record.changedFiles = verdict.diffStats.files == 0 ? [] : Array(Set(SnapshotDiff.between(s.before, snap).map(\.path))).sorted()
        let completion = EngineeringSeam.completion(verdict: verdict, plan: plan, profilesAvailable: !s.record.assignment.verificationProfiles.isEmpty)
        s.completion = completion
        s.record.log(.report, "verdict", verdict.status.rawValue)
        switch completion {
        case .verified: s.record.stopReason = .verified; s.record.stage = .done; return nil
        case .unverified(let why): s.record.log(.report, "not-verified", why); return nil
        case .failed(let cat, let why): s.record.stage = .blocked; return (cat, why)
        }
    }

    /// Report lines for the task report (observable facts only; no reasoning, no worker prose).
    func engineeringReportLines(_ ctx: TaskContext) -> [String]? {
        guard let s = ctx.engineering else { return nil }
        return EngineeringSeam.reportLines(s.record, completion: s.completion)
    }

    func engineeringVerificationState(_ ctx: TaskContext) -> (state: String, note: String?)? {
        guard let s = ctx.engineering, let c = s.completion else { return nil }
        switch c {
        case .verified(let manual): return ("verified", manual.isEmpty ? nil : "manual check still required: " + manual.joined(separator: "; "))
        case .unverified(let why): return ("unverified", why)
        case .failed(_, let why): return ("refused", why)
        }
    }
}
