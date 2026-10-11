import Foundation

extension TaskEngine {
    // MARK: Terminal states

    func finalizeSuccess(_ ctx: TaskContext) async {
        refreshProgress(ctx)
        let report = makeReport(ctx, cleanup: nil, forState: .completed)
        guard transition(ctx, to: .completed, activity: "Completed") else { return }
        finish(ctx, report: report)
    }

    func finalizeFailure(_ ctx: TaskContext) async {
        if ctx.cancelRequested || Task.isCancelled { await finalizeCancelled(ctx); return }
        let (cat, why) = ctx.hardFailure ?? (.validationFailed, "The task failed.")
        let report = makeReport(ctx, cleanup: nil, forState: .failed, failure: (cat, why))
        guard transition(ctx, to: .failed, activity: "Failed — \(cat.label)", failure: (cat, why)) else { return }
        finish(ctx, report: report)
    }

    func finalizeCancelled(_ ctx: TaskContext) async {
        guard !ctx.record.state.isTerminal else { return }
        for s in ctx.steps where [.running, .verifying, .waitingForApproval, .ready].contains(s.state) { setStep(ctx, s.key, to: .cancelled) }
        let heldLeases = ctx.record.id
        let n = leases.leases(forTask: heldLeases).count
        let cleanup = "all task runs stopped; \(n) file lease\(n == 1 ? "" : "s") released"
        let report = makeReport(ctx, cleanup: cleanup, forState: .cancelled)
        guard transition(ctx, to: .cancelled, activity: "Stopped", failure: (.cancelled, "Stopped by the user")) else { return }
        finish(ctx, report: report, cleanup: cleanup)
    }

    private func finish(_ ctx: TaskContext, report: TaskReport, cleanup: String? = nil) {
        leases.release(taskID: ctx.record.id)
        var final = report
        final.state = ctx.record.state.rawValue
        // The persisted report (artifact) and a one-paragraph summary on the task row.
        if let artifacts, let data = try? JSONEncoder.pretty.encode(final) {
            _ = try? artifacts.store(Data(final.markdown().utf8), type: "task-report", folder: .reports, fileExtension: "md", taskID: ctx.record.id, meta: "sanitized markdown report")
            if let a = try? artifacts.store(data, type: "task-report-json", folder: .reports, fileExtension: "json", taskID: ctx.record.id, meta: "structured report") {
                mutate(ctx) { $0.reportArtifactID = a.id }
            }
        }
        mutate(ctx) { $0.summary = final.userSummary; $0.currentStepKey = nil }
        writeCheckpoint(ctx, reason: "final: \(ctx.record.state.rawValue)")
        publish(ctx)
        let v = views[ctx.record.id]
        contexts[ctx.record.id] = nil                                     // the durable record is the source of truth from here on
        trimViews()
        if let v { onFinished?(v) }
    }

    func makeReport(_ ctx: TaskContext, cleanup: String?, forState state: TaskState, failure: (FailureCategory, String)? = nil) -> TaskReport {
        var t = ctx.record
        t.state = state; t.finishedAt = Date()
        if let failure { t.failureCategory = failure.0; t.failureReason = failure.1 }
        let attempts = (try? repository?.attempts(taskID: t.id)) ?? []
        let approvals = (try? repository?.approvals(taskID: t.id)) ?? []
        return TaskReport.build(task: t, steps: ctx.steps, attempts: attempts, changes: ctx.changes, approvals: approvals, cleanup: cleanup)
    }

    /// The structured report of a task (after a restart it is rebuilt from the database).
    func report(for id: UUID) -> TaskReport? {
        guard let repository, let t = (try? repository.engineTask(id)) ?? nil else { return nil }
        let steps = (try? repository.steps(taskID: id)) ?? []
        return TaskReport.build(task: t, steps: steps, attempts: (try? repository.attempts(taskID: id)) ?? [], changes: (try? repository.taskFileChanges(taskID: id)) ?? [],
                                approvals: (try? repository.approvals(taskID: id)) ?? [])
    }

    // MARK: Checkpoints (recovery points at coherent boundaries)

    struct Checkpoint: Codable {
        struct Step: Codable { var key: String; var state: String; var attempts: Int; var evidence: String? }
        var taskID: UUID
        var reason: String
        var at: Date
        var state: String
        var planVersion: Int
        var steps: [Step]
        var changes: [TaskFileChange]
        var gitBaseline: GitBaseline?
        var leases: [String]
        var pendingApprovals: [UUID]
        var failure: String?
        var diff: String
    }

    func checkpoint(_ ctx: TaskContext, reason: String) async { writeCheckpoint(ctx, reason: reason) }

    /// Not a mere "status write": plan version, step states + evidence, changed files (hashes), git baseline, leases, approvals and the
    /// cumulative diff — enough to understand and safely continue the task after a restart. Stored as an artifact; the DB keeps the reference.
    func writeCheckpoint(_ ctx: TaskContext, reason: String) {
        guard let artifacts else { return }
        let pending = ((try? repository?.approvals(taskID: ctx.record.id)) ?? []).filter { $0.state == .pending }.map(\.id)
        let cp = Checkpoint(taskID: ctx.record.id, reason: reason, at: Date(), state: ctx.record.state.rawValue, planVersion: ctx.record.planVersion,
                            steps: ctx.steps.map { .init(key: $0.key, state: $0.state.rawValue, attempts: $0.attempts, evidence: $0.validationEvidence.map { OutputSanitizer.sanitize(String($0.prefix(400))) }) },
                            changes: ctx.changes, gitBaseline: ctx.record.gitBaseline, leases: leases.leases(forTask: ctx.record.id).map(\.path), pendingApprovals: pending,
                            failure: ctx.record.failureReason.map { OutputSanitizer.sanitize($0) }, diff: diffText(ctx, limit: 20_000))
        guard let data = try? JSONEncoder.pretty.encode(cp),
              let a = try? artifacts.store(data, type: "task-checkpoint", folder: .checkpoints, fileExtension: "json", taskID: ctx.record.id, meta: reason) else { return }
        ctx.record.checkpointArtifactID = a.id
        persist(ctx)
    }

    // MARK: Restart recovery

    /// Launch: stale RUNNING tasks become INTERRUPTED (never "running forever"), their leases are released as stale, waiting tasks keep
    /// waiting. Nothing is resumed automatically: a restart never silently repeats work or spends quota.
    @discardableResult
    func reconcileOnLaunch() -> JarvisRepository.TaskReconciliation {
        guard let repository, let r = try? repository.reconcileTasksAfterRestart() else { return .init(tasks: [], steps: 0, leases: 0) }
        if !r.tasks.isEmpty { note("\(r.tasks.count) task(s) were interrupted by a restart — resume them from the Tasks screen", .warning, taskID: nil) }
        refreshHistory()
        return r
    }

    /// Re-creates the waiting state of tasks that were awaiting an approval when JARVIS quit (their approval stays pending).
    func restoreWaitingTasks() {
        guard let repository, let waiting = try? repository.engineTasks(states: [.waitingForApproval], limit: 20) else { return }
        for t in waiting where contexts[t.id] == nil {
            guard let ctx = loadContext(t) else { continue }
            for s in ctx.steps where s.state == .waitingForApproval {
                if s.type != .delete {                                              // the edits it was about are gone: supersede and re-run the step
                    for var a in ((try? repository.approvals(taskID: t.id)) ?? []) where a.stepID == s.id && a.state == .pending {
                        a.state = .cancelled; a.decidedAt = Date(); a.decidedBy = "restart"; try? repository.update(a)
                    }
                }
                setStep(ctx, s.key, to: .ready)
            }
            contexts[t.id] = ctx
            publish(ctx)
            startRunner(ctx)
        }
    }

    /// Rebuilds the in-memory context of a persisted task.
    func loadContext(_ t: TaskRecord) -> TaskContext? {
        guard let root = t.workspaceRoot, let ws = try? WorkspaceGuard(rootPath: root), let repository else {
            var failed = t; failed.state = .failed; failed.failureCategory = .workspaceViolation; failed.failureReason = "The project folder is no longer available."
            failed.finishedAt = Date(); try? self.repository?.update(failed)
            return nil
        }
        let steps = (try? repository.steps(taskID: t.id)) ?? []
        let ctx = TaskContext(record: t, steps: steps, workspace: ws, tools: ProjectTools(workspace: ws, capabilities: t.capabilities), profiles: ProfileDiscovery.discover(ws))
        for s in steps where s.state == .passed && s.type == .analysis { if let r = s.resultSummary { ctx.results[s.key] = r } }
        ctx.changes = (try? repository.taskFileChanges(taskID: t.id)) ?? []
        if let id = t.checkpointArtifactID, let art = try? artifacts?.artifact(id), let data = try? artifacts?.read(art), let cp = try? JSONDecoder.iso.decode(Checkpoint.self, from: data) {
            ctx.restoredDiff = cp.diff
        }
        ctx.evidence = steps.filter { $0.state == .passed }.compactMap { $0.validationEvidence }
        return ctx
    }

    /// Explicit resume of an INTERRUPTED task. Steps are reconciled by idempotency: read-only/build/test steps simply run again, a code
    /// step first inspects what is on disk (edits verified → kept; untouched → redone; diverged → the task fails explicitly), a delete is
    /// never replayed without a fresh approval.
    @discardableResult
    func resume(_ taskID: UUID) -> Bool {
        guard contexts[taskID] == nil, let t = (try? repository?.engineTask(taskID)) ?? nil, t.state == .interrupted else { return false }
        guard activeCount < limits.maxActiveTasks else { return false }
        guard let ctx = loadContext(t) else { refreshHistory(); return false }
        if let why = recoverSteps(ctx) {
            contexts[taskID] = ctx
            ctx.hardFailure = (.workspaceChanged, why)
            _ = transition(ctx, to: .running, activity: "Resuming")           // interrupted → running → failed (explicit, recorded)
            runners[taskID] = Task { @MainActor [weak self] in
                await self?.finalizeFailure(ctx)
                self?.runners[taskID] = nil
            }
            return true
        }
        contexts[taskID] = ctx
        ctx.runningSince = nil
        let target: TaskState = t.planVersion == 0 ? .planning : .running
        guard transition(ctx, to: target, activity: "Resumed after interruption") else { contexts[taskID] = nil; return false }
        mutate(ctx) { $0.recovery = "resumed by the user after a restart"; $0.cancelRequested = false }
        startRunner(ctx)
        return true
    }

    /// Returns a reason when the workspace diverged in a way that makes continuing unsafe.
    private func recoverSteps(_ ctx: TaskContext) -> String? {
        for s in ctx.steps where s.state == .interrupted {
            switch s.type.idempotency {
            case .retryable, .manual: setStep(ctx, s.key, to: .pending)
            case .inspectFirst:
                let mine = ctx.changes.filter { $0.stepKey == s.key }
                if mine.isEmpty { setStep(ctx, s.key, to: .pending); continue }
                var applied = 0, reverted = 0
                for c in mine {
                    let now = (try? ctx.tools.fileHash(c.path)) ?? nil
                    if now == c.afterHash { applied += 1 } else if now == c.beforeHash { reverted += 1 }
                }
                if applied == mine.count { ctx.recoveredApplied.insert(s.key); setStep(ctx, s.key, to: .pending) }
                else if reverted == mine.count { setStep(ctx, s.key, to: .pending) }
                else { return "Files changed by step “\(s.title)” no longer match what JARVIS wrote or the original content: " + mine.map(\.path).joined(separator: ", ") }
            }
        }
        return nil
    }

    // MARK: Application lifecycle

    /// Normal termination: stop scheduling, persist the interrupted state and a checkpoint, release leases. The processes themselves are
    /// killed by the existing `ProcessRegistry.killAll()` path (no second kill mechanism).
    func prepareForTermination() {
        for (id, ctx) in contexts where ctx.record.state.isActive || ctx.record.state == .waitingForApproval {
            let waiting = ctx.record.state == .waitingForApproval
            ctx.terminating = true
            runners[id]?.cancel()
            writeCheckpoint(ctx, reason: "application is quitting")
            if !waiting {
                for s in ctx.steps where s.state.isActive { setStep(ctx, s.key, to: .interrupted) }
                _ = transition(ctx, to: .interrupted, activity: "Interrupted — JARVIS quit while this task was running")
            }
            leases.release(taskID: id)
        }
        for (_, cont) in decisions { cont.resume(returning: false) }
        decisions.removeAll()
    }

    /// macOS sleep/wake: processes made no progress while asleep, so the clock is paused; on wake the state is re-evaluated, never assumed.
    func willSleep() {
        for ctx in contexts.values {
            if let since = ctx.runningSince { ctx.record.accumulatedSeconds += max(0, Date().timeIntervalSince(since)); ctx.runningSince = nil; persist(ctx) }
        }
    }

    func didWake() {
        for ctx in contexts.values where ctx.record.state == .running || ctx.record.state == .planning {
            ctx.runningSince = Date()
            note("Resumed after sleep: \(ctx.record.title)", .info, taskID: ctx.record.id)
        }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }
}
extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
