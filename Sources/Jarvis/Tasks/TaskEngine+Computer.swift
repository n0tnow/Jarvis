import Foundation

// MARK: - V0.11 General Computer Use as an ordinary V0.4 task (DEC-127)
//
//   Conversation → Goal Intake → TaskEngine (this file) → approval policy → Context Builder → typed actions → observe → act → verify
//
// There is no second authority system: the same task states, the same approvals (HUD buttons only; a spoken "yes" never approves), the same cancellation, the same
// persistence and restart rules. A restart never resumes GUI automation by itself: the task is INTERRUPTED and an explicit Resume re-observes everything from scratch.

extension TaskEngine {
    // MARK: Submission

    /// `steps` come from `ComputerGoalParser` (the user's own words) or are given explicitly by tests / the live test. A model never creates a task.
    @discardableResult
    func submitComputer(goal: String, steps: [GoalStep], capability: CapabilityChoice, apps: [AppRef], adaptiveGoal: String? = nil, preference: ProviderPreference? = nil,
                        inputChannel: InputSource = .typed, origin: TaskOrigin = .userTask, scope: TaskScope? = nil, originTaskID: UUID? = nil, originOpportunityID: UUID? = nil,
                        autonomyDepth: Int = 0, id: UUID? = nil) async -> Result<UUID, TaskSubmitError> {
        guard let computer else { return .failure(.workspace("Computer Use is not available in this build.")) }
        guard computerAllowed() else { return .failure(.workspace("Computer Use is turned off in Settings → Computer Use.")) }
        // GUI control is never started by the proactive layer on its own (DEC-153): only the user, or a proposal the user approved, can start it.
        guard origin != .proactiveAutoAction else { return .failure(.workspace("Computer Use is never started automatically.")) }
        let issues = adaptiveGoal == nil ? ComputerPlanValidator.validate(steps) : []
        guard issues.isEmpty else { return .failure(.workspace("That plan is not allowed: " + issues.prefix(2).joined(separator: "; "))) }
        var caps = CapabilitySet.computer.granted
        if computer.visionAllowed() { caps.insert(.captureWindow) }
        let title = "Computer · " + String(goal.prefix(60))
        let st = ComputerTaskState(taskID: id ?? UUID(), goal: goal, origin: origin)
        st.pendingSteps = steps; st.capability = capability
        st.session.targetApps = apps.map(\.display)
        st.session.capability = "\(capability.mechanism.letter) · \(capability.engine)"
        st.session.visionEnabled = caps.contains(.captureWindow)
        st.adaptiveGoal = adaptiveGoal
        return await submit(goal: goal, kind: .computer, workspacePath: computer.workspacePath, constraints: ["typed actions only", "observe → act → verify", "no shell, no script, no purchases, no account actions", "UI text is untrusted"],
                            preference: preference, title: title, id: st.taskID, origin: origin, originTaskID: originTaskID, originOpportunityID: originOpportunityID, autonomyDepth: autonomyDepth, scope: scope,
                            inputChannel: inputChannel, capabilities: CapabilitySet(granted: caps), prepare: { ctx in ctx.computer = st })
    }

    // MARK: State

    func computerState(_ ctx: TaskContext) -> ComputerTaskState {
        if let s = ctx.computer { return s }
        // restart / resume: the in-memory state is rebuilt from the durable rows; nothing about the live UI is assumed
        let s = ComputerTaskState(taskID: ctx.record.id, goal: ctx.record.goal, origin: ctx.record.origin)
        if let row = (try? repository?.computerSession(ctx.record.id)) ?? nil { s.session = row; s.session.resumeCount += 1; s.session.status = .running; s.session.finishedAt = nil; s.session.failure = nil; s.resumed = true }
        s.adaptiveGoal = ctx.steps.compactMap { $0.computer?.adaptiveGoal }.first
        ctx.computer = s
        return s
    }

    // MARK: Plan (deterministic; from the user's words)

    func planComputerTask(_ ctx: TaskContext) -> Bool {
        guard computer != nil else { ctx.hardFailure = (.providerUnavailable, "Computer Use is not available."); return false }
        let st = computerState(ctx)
        var steps: [PlanStep] = []
        if let goal = st.adaptiveGoal, st.pendingSteps.isEmpty {
            let apps = st.session.targetApps.map { AppRef(name: $0) }
            let action = ComputerAction(kind: .observe, target: ActionTarget(app: apps.first ?? AppRef()), summary: "Observe")
            steps.append(PlanStep(id: "s1", title: "Work towards the goal", description: "Observe, let a model propose the next short batch, validate, act, verify (bounded rounds).", type: .computerAct, dependsOn: [],
                                  expected: "the goal's postcondition is observed", validation: .computerVerified, risk: .medium, computer: ComputerStepParams(actions: [action], adaptiveGoal: goal, maxRounds: ComputerLimits.maxRounds)))
        } else {
            for (i, g) in st.pendingSteps.enumerated() {
                let risk = g.actions.map { ComputerPolicy.assess($0, in: ActionPolicyContext(bundleID: $0.target.app.bundleID, windowTitle: $0.target.windowTitle)).risk }.max() ?? .low
                steps.append(PlanStep(id: "s\(i + 1)", title: g.title, description: g.actions.map(\.summary).joined(separator: " → "), type: .computerAct, dependsOn: i == 0 ? [] : ["s\(i)"],
                                      expected: Set(g.actions.flatMap(\.checks).map(\.summary)).sorted().joined(separator: "; "), validation: .computerVerified, risk: risk, computer: ComputerStepParams(actions: g.actions)))
            }
        }
        guard !steps.isEmpty else { ctx.hardFailure = (.malformedPlan, "There is nothing to do."); return false }
        installPlan(ctx, TaskPlan(summary: st.capability.map { "\($0.mechanism.label): \(ctx.record.title)" } ?? ctx.record.title, steps: steps))
        return true
    }

    // MARK: Session bookkeeping

    private func startComputerSession(_ ctx: TaskContext) async -> ComputerTaskState? {
        guard let computer else { return nil }
        let st = computerState(ctx)
        if st.executor == nil { st.executor = computer.makeExecutor(token: st.token, taskID: ctx.record.id) }
        let ex = st.executor!
        ex.observed = { [weak self, weak st] s in
            guard let self, let st else { return }
            try? self.repository?.insert(ComputerObservationRecord(id: UUID(), sessionID: st.taskID, at: Date(), kind: "ax", app: s.app.name, window: s.window?.title, nodes: s.nodeCount, windows: s.windows.count,
                                                                    truncated: s.truncated, durationMS: s.durationMS, width: nil, height: nil, fingerprint: nil, provider: nil, persisted: false))
        }
        ex.screenObserved = { [weak self, weak st] o in
            guard let self, let st else { return }
            try? self.repository?.insert(ComputerObservationRecord(id: UUID(), sessionID: st.taskID, at: o.capturedAt, kind: "screenshot", app: o.bundleID, window: o.windowTitle, nodes: nil, windows: nil, truncated: false,
                                                                    durationMS: nil, width: Int(o.pixelSize.width), height: Int(o.pixelSize.height), fingerprint: String(o.fingerprint, radix: 16), provider: computer.vision.name, persisted: false))
        }
        if st.started { return st }
        st.started = true
        st.session.status = .running
        st.session.planSummary = ctx.record.summary
        st.session.visionEnabled = ctx.record.capabilities.allows(.captureWindow)
        try? repository?.upsert(st.session)
        computer.sessionStarted(taskID: ctx.record.id, goal: ctx.record.goal, token: st.token)
        if st.resumed { computer.record(.sessionStarted(goal: "resumed — observing everything from scratch"), taskID: ctx.record.id) }
        computer.refreshPermissions()
        // V0.10: the bounded, relevant project context (constraints/decisions); audited by task. UI observations never become memory.
        if let memory, !st.memoryRecorded {
            st.memoryRecorded = true
            if let u = await memory.contextFor(agentType: "ComputerAgent", goal: ctx.record.goal, workspaceRoot: nil, taskID: ctx.record.id) {
                st.memoryPacket = ProjectContextBuilder.render(u.packet); st.memoryIDs = u.packet.usedIDs
                st.session.memoryIDs = u.packet.usedIDs
                memory.recordUse(packet: u.packet, project: u.project, agentType: "ComputerAgent", taskID: ctx.record.id, runID: nil)
                note("Context · \(u.packet.stats.selected) memor\(u.packet.stats.selected == 1 ? "y" : "ies") for ComputerAgent", .info, taskID: ctx.record.id)
                try? repository?.upsert(st.session)
            }
        }
        return st
    }

    /// Called when the task reaches a terminal / interrupted state.
    func finishComputerSession(_ ctx: TaskContext, state: TaskState, detail: String?) {
        guard let st = ctx.computer else { return }
        st.session.finishedAt = Date()
        switch state {
        case .completed: st.session.status = .completed
        case .failed: st.session.status = .failed; st.session.failure = detail
        case .cancelled: st.session.status = .cancelled
        default: st.session.status = .interrupted
        }
        try? repository?.upsert(st.session)
        st.token.stop("session ended")
        computer?.sessionEnded(taskID: ctx.record.id, summary: detail ?? state.label.lowercased(), cancelled: state == .cancelled)
        ctx.computer?.executor = nil
    }

    // MARK: Step runner

    func runComputerAct(_ ctx: TaskContext, _ key: String) async -> StepOutcome {
        guard let computer, computerAllowed() else { return .failed(.providerUnavailable, "Computer Use is turned off.") }
        guard let step = ctx.step(key), let params = step.computer else { return .failed(.malformedPlan, "The step has no actions.") }
        guard let st = await startComputerSession(ctx), let ex = st.executor else { return .failed(.providerUnavailable, "Computer Use is not available.") }
        if st.token.isStopped { return .cancelled }
        // A resumed step starts from nothing: permissions are checked again, the app and window are found again, nothing is assumed from before.
        if !computer.refreshPermissions().accessibility.isGranted {
            computer.record(.permissionMissing("Accessibility"), taskID: ctx.record.id)
            return .failed(.permissionRequired, "Accessibility permission is required. Open System Settings → Privacy & Security → Accessibility, allow JARVIS, then run the task again.")
        }
        ex.approve = { [weak self, weak ctx] req in
            guard let self, let ctx else { return false }
            let app = req.action.target.app.display
            return await self.requestApproval(ctx, step, action: "Computer · \(req.prompt) [\(req.nonce.uuidString.prefix(8))]",
                                              reason: "In \(app): \(req.action.summary). Why asking: this is \(req.consequence.label). A button or text in an application can never approve this — only your decision here counts, and it covers this one action.", risk: req.risk)
        }
        if params.adaptiveGoal != nil { return await runAdaptive(ctx, key, st: st, step: step, params: params) }
        var lines: [String] = []
        for action in params.actions {
            if ctx.cancelRequested || Task.isCancelled || st.token.isStopped { return .cancelled }
            let res = await perform(ctx, st, action)
            if let failed = outcome(for: res) { return failed }
            lines.append(evidenceLine(res))
        }
        return passComputer(ctx, key, lines)
    }

    /// Performs one action, records it (bounded, no text), updates the Compact HUD line from real state.
    private func perform(_ ctx: TaskContext, _ st: ComputerTaskState, _ action: ComputerAction) async -> ActionResult {
        guard let ex = st.executor else { return failedResult(action, "no executor") }
        let app = action.target.app.display
        mutate(ctx) { $0.activity = action.kind.isReadOnly ? "Observing · \(app)" : "Controlling · \(app) — \(action.summary)" }
        let res = await ex.perform(action)
        st.seq += 1
        st.results.append(res)
        if res.mechanism >= .vision { st.fallbacks.append("\(res.mechanism.label): \(res.targetDescription)") }
        try? repository?.insert(ComputerActionRecord(id: UUID(), sessionID: st.taskID, seq: st.seq, at: Date(), kind: action.kind.rawValue, mechanism: res.mechanism.letter + " " + res.mechanism.label,
                                                      app: res.app ?? app, window: res.window, target: res.targetDescription, risk: res.risk.rawValue, status: res.status.rawValue, resolution: res.resolution?.rawValue,
                                                      verification: res.verification.map { ($0.passed ? "PASS: " : "FAIL: ") + $0.checks.joined(separator: "; ") }, detail: res.detail, approvalID: res.approvalID,
                                                      textClass: res.textClass?.rawValue, textLength: res.textLength, durationMS: res.durationMS, attempts: res.attempts,
                                                      provider: res.mechanism == .vision || res.mechanism == .rawCoordinates ? computer?.vision.name : nil))
        return res
    }

    private func failedResult(_ a: ComputerAction, _ why: String) -> ActionResult {
        ActionResult(action: a, status: .failed, mechanism: .accessibility, risk: .low, resolution: nil, verification: nil, detail: why, attempts: 0, durationMS: 0, approvalID: nil, app: nil, window: nil,
                     targetDescription: a.target.description, textClass: nil, textLength: nil)
    }

    /// nil = the action succeeded and was verified; otherwise the step outcome that ends the step.
    private func outcome(for r: ActionResult) -> StepOutcome? {
        switch r.status {
        case .verified: return nil
        case .cancelled: return .cancelled
        default: return .failed(r.category ?? r.status.failureCategory, "\(r.action.summary): \(r.detail)")
        }
    }

    private func evidenceLine(_ r: ActionResult) -> String {
        "\(r.action.summary) → \(r.status == .verified ? "verified" : r.status.rawValue) (\(r.mechanism.letter) \(r.mechanism.label)\(r.resolution.map { ", \($0.label)" } ?? ""))" + (r.verification.map { " · " + $0.checks.joined(separator: "; ") } ?? "")
    }

    private func passComputer(_ ctx: TaskContext, _ key: String, _ lines: [String]) -> StepOutcome {
        verifying(ctx, key)
        let evidence = lines.joined(separator: "\n")
        setStep(ctx, key, to: .passed, evidence: evidence, result: lines.last ?? "done")
        return .passed
    }

    // MARK: Adaptive rounds (a model proposes; JARVIS validates, acts and verifies)

    private func runAdaptive(_ ctx: TaskContext, _ key: String, st: ComputerTaskState, step: TaskStepRecord, params: ComputerStepParams) async -> StepOutcome {
        guard let ex = st.executor else { return .failed(.providerUnavailable, "Computer Use is not available.") }
        let goal = params.adaptiveGoal ?? ctx.record.goal
        // names → bundle identifiers (running applications first, then the catalog): the planner and the checks work on identities, not on guessed names
        let running = await ex.backend.runningApplications()
        let apps: [AppRef] = st.session.targetApps.map { name in
            if let r = running.first(where: { ComputerText.fold($0.name) == ComputerText.fold(name) }) { return AppRef(bundleID: r.bundleID, name: r.name) }
            return AppCatalog.match(tokens: ComputerText.tokens(name)).map { AppRef(bundleID: $0.app.bundleID, name: $0.app.display) } ?? AppRef(name: name)
        }
        var lines: [String] = []
        var lastFailure: String?
        let rounds = min(params.maxRounds, ComputerLimits.maxRounds)
        for round in 1...rounds {
            if ctx.cancelRequested || Task.isCancelled || st.token.isStopped { return .cancelled }
            st.rounds = round
            mutate(ctx) { $0.activity = "Planning · round \(round)/\(rounds)" }
            let obs = await perform(ctx, st, ComputerAction(kind: .observe, target: ActionTarget(app: apps.first ?? AppRef()), summary: "Observe"))
            if let failed = outcome(for: obs) { return failed }
            let observation = ex.lastSnapshot.map { ex.planningObservation($0) } ?? obs.detail
            let prompt = ComputerModelPlanner.prompt(goal: goal, apps: apps, observation: observation, memory: st.memoryPacket, round: round, maxRounds: rounds, lastFailure: lastFailure)
            var profile = TaskClassifier.profile(for: goal)
            profile.category = .classification; profile.requiresCoding = false; profile.containsProjectCode = false; profile.requiresRepositoryModification = false
            profile.wantsStructuredOutput = true; profile.complexity = .moderate
            profile.privacy = .sensitive                                  // window titles and labels can be private: never the free cloud pool
            profile.estimatedContextTokens = max(profile.estimatedContextTokens, prompt.count / 4)
            let allowed = apps
            let job = AgentJob(type: "ComputerPlanner", title: "Computer · plan round \(round)", prompt: prompt, profile: profile, taskID: ctx.record.id,
                               validator: { text in
                                   let p = ComputerModelPlanner.parse(text, allowedApps: allowed)
                                   return (p.actions.isEmpty && p.done == nil) ? BenchmarkSuite.Verdict(passed: false, detail: p.issues.joined(separator: "; ")) : BenchmarkSuite.Verdict(passed: true, detail: "")
                               }, timeout: 180)
            let result = await runJob(ctx, job)
            guard case .completed(let text, _, _, _) = result else {
                if case .cancelled = result { return .cancelled }
                let (cat, why) = failure(from: result)
                return .failed(cat, "No usable plan for the next step: \(why)")
            }
            let proposal = ComputerModelPlanner.parse(text, allowedApps: apps)
            if let claims = proposal.done {
                let v = await ex.verify(claims, app: ex.lastSnapshot?.app, before: nil)
                if v.passed { lines.append("Goal reached — observed: " + v.checks.joined(separator: "; ")); return passComputer(ctx, key, lines) }
                lastFailure = "the claim “done” was not observed (\(v.detail))"
                lines.append("Round \(round): done was claimed but not observed")
                continue
            }
            if proposal.actions.isEmpty { lastFailure = proposal.issues.first ?? "no action proposed"; continue }
            lastFailure = nil
            for a in proposal.actions {
                if ctx.cancelRequested || Task.isCancelled || st.token.isStopped { return .cancelled }
                let res = await perform(ctx, st, a)
                lines.append(evidenceLine(res))
                switch res.status {
                case .verified: continue
                case .cancelled: return .cancelled
                case .notFound, .ambiguous, .stale, .notVerified, .failed, .modalPresent:
                    lastFailure = "\(a.summary): \(res.detail)"                        // re-plan from a fresh observation
                default: return .failed(res.category ?? res.status.failureCategory, "\(a.summary): \(res.detail)")
                }
                if lastFailure != nil { break }
            }
        }
        return .failed(.computerActionFailed, "The goal was not reached within \(rounds) planning rounds. \(lastFailure ?? "")")
    }

    // MARK: Stop

    /// The emergency stop and the HUD's Stop both end here: every in-flight executor is stopped first, then the tasks are cancelled through the ordinary path.
    func cancelComputerTasks(reason: String) {
        for (id, ctx) in contexts where ctx.record.kind == .computer && ctx.record.state.isStoppable {
            ctx.computer?.token.stop(reason)
            cancel(id)
        }
    }

    /// The one-paragraph message for a finished computer task.
    func computerSummary(for v: TaskView) -> String? {
        guard v.task.kind == .computer else { return nil }
        let actions = (try? repository?.computerActions(sessionID: v.id)) ?? []
        switch v.task.state {
        case .completed:
            let verified = actions.filter { $0.status == ActionStatus.verified.rawValue && $0.kind != ComputerActionKind.observe.rawValue }.count
            let apps = Set(actions.compactMap(\.app)).sorted().joined(separator: ", ")
            return "Done — \(verified) action\(verified == 1 ? "" : "s") performed and verified" + (apps.isEmpty ? "." : " in \(apps).")
        default: return nil
        }
    }

    /// Lines for the task report: capabilities, actions with verification, approvals, fallbacks, failures — never typed text.
    func computerReportLines(taskID: UUID) -> [String]? {
        guard let repository, let session = (try? repository.computerSession(taskID)) ?? nil else { return nil }
        let actions = (try? repository.computerActions(sessionID: taskID)) ?? []
        var out: [String] = []
        out.append("Applications: " + (session.targetApps.isEmpty ? "—" : session.targetApps.joined(separator: ", ")))
        out.append("Capability: " + (session.capability ?? "—") + (session.visionEnabled ? " · window-scoped vision fallback enabled" : ""))
        for a in actions where a.kind != ComputerActionKind.observe.rawValue || a.status != ActionStatus.verified.rawValue {
            out.append("\(a.kind) \(a.target ?? "") · \(a.mechanism) · risk \(a.risk) · \(a.status)" + (a.verification.map { " · \($0)" } ?? "") + (a.textClass.map { " · text \($0) (\(a.textLength ?? 0) chars)" } ?? "") + (a.approvalID != nil ? " · approved by you" : ""))
        }
        let fallbacks = actions.filter { $0.mechanism.hasPrefix("F") || $0.mechanism.hasPrefix("G") }
        if !fallbacks.isEmpty { out.append("Fallbacks: \(fallbacks.count) action(s) used the window-scoped vision fallback / a validated window-relative point (no screenshot was stored)") }
        out.append("Final state: \(session.status.rawValue)" + (session.failure.map { " — \($0)" } ?? "") + (session.resumeCount > 0 ? " · resumed \(session.resumeCount)×" : ""))
        return out
    }
}

extension PermissionState { var isGranted: Bool { self == .granted } }
