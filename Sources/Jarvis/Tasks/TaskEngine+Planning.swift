import Foundation

/// Thread-safe holder the planner/agent validators write into (validators are `@Sendable` closures).
final class ValidationBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    private var notes: [String] = []
    func set(_ v: T?, notes n: [String] = []) { lock.lock(); value = v; notes = n; lock.unlock() }
    var result: T? { lock.lock(); defer { lock.unlock() }; return value }
    var detail: [String] { lock.lock(); defer { lock.unlock() }; return notes }
}

extension TaskEngine {
    // MARK: Job helpers

    /// Routing profile for a task prompt. Task prompts carry project material, so the local model can never take them (policy in code):
    /// development work, project code, coding/review requirements — exactly what `LocalModelPolicy` forbids.
    func jobProfile(_ ctx: TaskContext, _ type: StepType?, promptChars: Int) -> TaskProfile {
        var p = TaskClassifier.profile(for: ctx.record.goal)
        switch type {
        case .codeChange?, .delete?: p.category = .repositoryModification; p.requiresRepositoryModification = true
        case .review?: p.category = .review; p.requiresTechnicalReview = true
        default: p.category = .coding
        }
        p.requiresCoding = true
        p.containsProjectCode = true                      // free models must then be zero-retention (DEC-025)
        p.complexity = max(p.complexity, .moderate)
        p.privacy = ctx.record.privacy
        p.wantsStructuredOutput = type != .codeChange
        p.estimatedContextTokens = max(p.estimatedContextTokens, promptChars / 4)
        return p
    }

    /// Task-level escalation is legal only in Auto: the mode the user chose at submission (or, if none, the current setting) decides.
    func canEscalate(_ ctx: TaskContext) -> Bool { (ctx.record.preference == nil || ctx.record.preference == .auto) && agents.escalationAllowed }

    /// Runs one job. A capacity rejection WAITS (event-driven) for a slot instead of failing or spinning.
    func runJob(_ ctx: TaskContext, _ job: AgentJob) async -> AgentJobResult {
        var job = job
        job.preference = ctx.record.preference
        // V0.10: bounded Project Memory context for agents that work on the project (CURRENT TRUTH · MEMORY · UNCERTAINTY kept apart); the ids are audited per run.
        var used: (packet: ContextPacket, project: ProjectIdentity)?
        if let memory, Self.memoryAgents.contains(job.type) {
            used = await memory.contextFor(agentType: job.type, goal: ctx.record.goal + " " + job.title, workspaceRoot: ctx.record.kind.isWebTask ? nil : ctx.record.workspaceRoot, taskID: ctx.record.id)
            if let u = used {
                job.prompt = ProjectContextBuilder.render(u.packet) + "\n\n---\n\n" + job.prompt
                job.profile.estimatedContextTokens += u.packet.stats.approxTokens
                note("Context · \(u.packet.stats.selected) memor\(u.packet.stats.selected == 1 ? "y" : "ies") for \(job.type)", .info, taskID: ctx.record.id)
            }
        }
        // V0.12: a node can never call a provider more often than its role contract allows (repair and escalation included).
        if providerBudgetExhausted(ctx, job) { return .rejected(.noEligibleProvider("this node used its provider budget")) }
        let started = Date()
        let result = await runJobLoop(ctx, job)
        let runMS = Date().timeIntervalSince(started) * 1000
        recordRouting(ctx, job: job, result: result, runMS: runMS, queueMS: 0, memoryItems: used?.packet.stats.selected, memoryChars: used?.packet.stats.chars)
        if let u = used {
            let runID: UUID?
            switch result { case .completed(_, let id, _, _): runID = id; case .failed(let id, _, _, _): runID = id; case .cancelled(let id): runID = id; case .rejected: runID = nil }
            memory?.recordUse(packet: u.packet, project: u.project, agentType: job.type, taskID: ctx.record.id, runID: runID)
        }
        return result
    }

    static let memoryAgents: Set<String> = ["PlannerAgent", "AnalysisAgent", "CodingAgent", "ReviewAgent", "UnityAgent", "ResearchAgent"]

    private func runJobLoop(_ ctx: TaskContext, _ job: AgentJob) async -> AgentJobResult {
        var job = job
        while true {
            let r = await agents.run(job)
            guard case .rejected(let why) = r else { return r }
            switch why {
            case .tooManyBackgroundAgents, .tooManyFreeCloudAgents, .localInferenceBusy, .tooManyHeavyAgents, .tooManyChildren:
                ctx.capacityWaits += 1
                if ctx.capacityWaits > limits.maxCapacityWaits || Task.isCancelled || ctx.cancelRequested { return r }
                mutate(ctx) { $0.activity = "Waiting for a free agent slot" }
                await agents.waitForCapacityChange()
            default: return r
            }
        }
    }

    func failure(from r: AgentJobResult) -> (FailureCategory, String) {
        switch r {
        case .completed: return (.validationFailed, "validation failed")
        case .cancelled: return (.cancelled, "cancelled")
        case .rejected(let why):
            switch why {
            case .noEligibleProvider(let m): return (.providerUnavailable, "No eligible provider: \(m)")
            case .recursionNotAllowed, .tooManyChildren: return (.securityBlocked, "agents may not create agents")
            default: return (.resourceUnavailable, "all agent slots are in use")
            }
        case .failed(_, let error, let validationFailed, _):
            if validationFailed { return (.validationFailed, "the provider's answer did not pass validation") }
            switch error {
            case .rateLimited?: return (.providerRateLimited, "the provider's usage limit was reached")
            case .notInstalled?, .authenticationRequired?, .unavailable?, .networkUnavailable?, .noProviderReady?, .refused?, .busy?: return (.providerUnavailable, "the provider is not available")
            case .timedOut?: return (.providerFailed, "the provider timed out")
            default: return (.providerFailed, "the provider failed")
            }
        }
    }

    @discardableResult
    func beginAttempt(_ ctx: TaskContext, _ step: TaskStepRecord, _ kind: AttemptKind) -> StepAttemptRecord {
        let number = (ctx.step(step.key)?.attempts ?? 0) + 1
        let a = StepAttemptRecord(stepID: step.id, taskID: ctx.record.id, number: number, kind: kind, engine: nil, model: nil, agentRunID: nil, outcome: "running")
        try? repository?.insert(a)
        updateStep(ctx, step.key) { $0.attempts = number }
        return a
    }

    func endAttempt(_ a: StepAttemptRecord, outcome: String, evidence: String?, runID: UUID? = nil, candidate: RoutingCandidate? = nil) {
        var done = a
        done.outcome = outcome; done.evidence = evidence; done.finishedAt = Date(); done.agentRunID = runID
        done.engine = candidate?.engine; done.model = candidate?.model
        try? repository?.update(done)
    }

    // MARK: Planning

    func planPhase(_ ctx: TaskContext) async -> Bool {
        // V0.9: web tasks have a deterministic plan (research type → fixed bounded steps); no model is asked to plan, nothing can be "browsed until satisfied".
        if ctx.record.kind.isWebTask || ctx.research?.importSource != nil { return planWebTask(ctx) }
        // V0.11: computer tasks have a deterministic plan from the user's own words (a model may only propose the NEXT short batch, inside a step).
        if ctx.record.kind == .computer { return planComputerTask(ctx) }
        // V0.12: the orchestrator plans deterministic shapes itself (no model call); only an open-ended compound goal reaches the planner model below.
        if let installed = await planOrchestrated(ctx) { return installed }
        let orchestrating = orchestrationEnabled && (ctx.record.kind == .development || ctx.record.kind == .readOnlyAnalysis) && ctx.record.scope == nil && ctx.research?.importSource == nil
        let planningStarted = Date()
        let pc = orchestrating ? await planningContext(ctx) : nil
        let tree = (try? ctx.tools.projectTree(maxEntries: 160)) ?? ""
        let prompt = PlannerPrompt.build(goal: ctx.record.goal, kind: ctx.record.kind, projectTree: tree, buildCommand: ctx.profiles.build?.display,
                                         testCommand: ctx.profiles.test?.display, constraints: ctx.record.constraints, allowDelete: ctx.record.destructiveRequested, scopeNotes: ctx.record.scope?.promptNotes,
                                         unity: unityPlanContext(ctx), orchestration: pc)
        var excluded: Set<RoutingCandidate> = []
        let dcheck = delegateCheck(ctx)
        let kind = ctx.record.kind, caps = ctx.record.capabilities, allowDestructive = ctx.record.destructiveRequested, scope = ctx.record.scope
        for attempt in 0..<2 {
            if ctx.cancelRequested || Task.isCancelled { return false }
            let box = ValidationBox<TaskPlan>()
            let job = AgentJob(type: "PlannerAgent", title: "Plan · \(ctx.record.title)", prompt: prompt, profile: jobProfile(ctx, nil, promptChars: prompt.count),
                               taskID: ctx.record.id,
                               validator: { text in
                                   // V0.12: a delegated node's capability exists on the task only if the user's settings allow it AND the validated plan contains such a node.
                                   let planCaps = pc.map { CapabilitySet(granted: caps.granted.union($0.webAllowed ? [.researchWeb] : []).union($0.computerAllowed ? [.controlComputer] : [])) } ?? caps
                                   var r = PlanValidator.check(text, kind: kind, capabilities: planCaps, allowDestructive: allowDestructive)
                                   var graphPolicy = false
                                   if orchestrating, r.plan != nil {                       // the graph rules (roles, optional nodes, ordering, validation gates) on top of V0.4's
                                       let g = GraphValidator.check(text, kind: kind, capabilities: planCaps, allowDestructive: allowDestructive, delegateCheck: dcheck)
                                       graphPolicy = g.policy
                                       if g.plan == nil { r = (nil, g.issues.map { graphPolicy ? PlanIssue.prohibitedOperation(step: "graph", phrase: $0) : PlanIssue.missingField(step: "graph", field: $0) }) }
                                   }
                                   if let plan = r.plan, let scope {                      // V0.5: a proactive task's plan may not exceed what was approved
                                       let over = scope.planViolations(plan)
                                       if !over.isEmpty { box.set(nil, notes: over + ["scope"]); return BenchmarkSuite.Verdict(passed: false, detail: over.joined(separator: "; ")) }
                                   }
                                   box.set(r.plan, notes: r.issues.map(\.description) + (r.issues.contains { $0.isPolicyBlock } ? ["policy"] : []))
                                   return BenchmarkSuite.Verdict(passed: r.plan != nil, detail: r.issues.map(\.description).joined(separator: "; "))
                               }, timeout: limits.providerTimeout, exclude: excluded)
            mutate(ctx) { $0.activity = attempt == 0 ? "Planning" : "Planning (different provider)" }
            let result = await runJob(ctx, job)
            switch result {
            case .completed(_, _, _, _):
                if let plan = box.result {
                    if orchestrating, let pc {
                        mutate(ctx) { $0.capabilities = Self.graphCapabilities($0.capabilities, plan: plan, web: pc.webAllowed, computer: pc.computerAllowed) }
                        ctx.orchestrated = true; ctx.graphTemplate = "model-planned"
                    }
                    installPlan(ctx, plan)
                    if ctx.orchestrated { saveGraph(ctx, template: "model-planned", planner: "model", rationale: "open-ended compound goal planned by the model, validated by JARVIS", plannerChars: prompt.count, plannerMS: Date().timeIntervalSince(planningStarted) * 1000) }
                    return true
                }
                ctx.hardFailure = (.malformedPlan, "The planner returned no usable plan.")
                return false
            case .cancelled:
                return false
            case .failed(_, _, let validationFailed, let cand):
                if let c = cand { excluded.insert(c) }
                if validationFailed, box.detail.contains("scope") {
                    ctx.hardFailure = (.scopeExceeded, "The plan exceeded the approved scope: " + box.detail.filter { $0 != "scope" }.prefix(3).joined(separator: "; "))
                    return false
                }
                if validationFailed, box.detail.contains("policy") {
                    ctx.hardFailure = (.securityBlocked, "The plan was rejected by the security policy: " + box.detail.filter { $0 != "policy" }.joined(separator: "; "))
                    return false
                }
                if attempt == 0, canEscalate(ctx), cand != nil { continue }                     // one more, different provider
                let (cat, why) = failure(from: result)
                ctx.hardFailure = (validationFailed ? .malformedPlan : cat, validationFailed ? "The planner's answers were not valid plans: " + box.detail.prefix(3).joined(separator: "; ") : why)
                return false
            case .rejected:
                let (cat, why) = failure(from: result)
                ctx.hardFailure = (cat, why)
                return false
            }
        }
        return false
    }

    func installPlan(_ ctx: TaskContext, _ plan: TaskPlan) {
        var steps: [TaskStepRecord] = []
        for (i, s) in plan.steps.enumerated() {
            var rec = TaskStepRecord(id: UUID(), taskID: ctx.record.id, index: i, key: s.id, title: s.title, details: s.description, type: s.type,
                                     dependsOn: s.dependsOn, expected: s.expected, validation: s.validation, risk: max(s.risk, s.type.defaultRisk), weight: 1)
            rec.unity = s.unity
            rec.computer = s.computer
            rec.optional = s.optional
            rec.delegate = s.delegate
            rec.revision = ctx.revisionCount
            steps.append(rec)
        }
        try? repository?.insertSteps(steps)
        ctx.steps = steps
        // A delete step carries its explicit targets (needed again after a restart): stored in the step details.
        for s in plan.steps where s.type == .delete && !s.targets.isEmpty {
            updateStep(ctx, s.id) { $0.details = ($0.details.isEmpty ? "" : $0.details + "\n") + "targets: " + s.targets.joined(separator: ", ") }
        }
        mutate(ctx) {
            $0.planVersion = plan.version; $0.summary = plan.summary
            $0.risk = max($0.risk, steps.map(\.risk).max() ?? .low)
            $0.activity = "Plan accepted (\(steps.count) steps)"
        }
        refreshProgress(ctx)
        note("Plan created: \(steps.count) steps", .info, taskID: ctx.record.id)
    }
}
