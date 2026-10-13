import Foundation

// MARK: - V0.12 JARVIS as orchestrator (DEC-157…)
//
//   goal ─► OrchestrationPlanner (deterministic template │ planner MODEL, validated like a template) ─► role graph (the V0.4 plan: nodes + dependsOn)
//        ─► scheduler (ConcurrencyPolicy: read-only pairs only, writers alone, resources) ─► node ─► role contract re-checked ─► specialist ─► typed artifact (sanitized, bounded, trust-labelled)
//        ─► HandoffBuilder (data, never instruction) ─► next node ─► deterministic validation outranks every claim ─► report from graph state
//
// The orchestrator is this code, not a model. Models and tools are workers. Nothing in an artifact, a handoff, a research page or a screen label can grant a capability,
// an approval or a policy change: authority is re-derived from the task's capabilities and the role contract before EVERY node starts.

enum OrchestrationPolicy {
    /// Words that can never be the goal of a delegated node (purchases, credentials, installs, shells): the node is refused at plan time AND at start time.
    private static let forbidden = ["purchase", "buy ", "checkout", "subscribe", "password", "credential", "api key", "api_key", "token", "keychain", "sudo", "curl ", "wget ", "rm -rf", "install ", "terminal", "applescript", "osascript",
                                    "satın al", "satin al", "şifre", "sifre", "yükle", "yukle", "kur "]
    static func forbiddenIntent(in text: String) -> String? {
        let t = text.lowercased()
        return forbidden.first { t.contains($0) }.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

extension TaskEngine {
    // MARK: Planning

    func planningContext(_ ctx: TaskContext) async -> PlanningContext {
        var c = PlanningContext()
        c.hasBuildCommand = ctx.profiles.build != nil
        c.hasTestCommand = ctx.profiles.test != nil
        c.isUnityProject = ctx.unityProject
        c.webAllowed = web != nil && webAllowed()
        c.computerAllowed = computer != nil && computerAllowed()
        c.writable = ctx.record.kind == .development
        if c.webAllowed, GoalCues.needsResearch(ctx.record.goal), !GoalCues.demandsCurrency(ctx.record.goal), let memory,
           let u = await memory.contextFor(agentType: "ResearchAgent", goal: ctx.record.goal, workspaceRoot: ctx.record.workspaceRoot, taskID: nil) {
            c.researchCoveredByMemory = u.packet.sections.contains { $0.title.hasPrefix("earlier research") && !$0.items.isEmpty }
        }
        return c
    }

    /// Deterministic orchestration: returns true when a graph was installed, nil when the goal has no template (the planner model proposes one, validated the same way).
    func planOrchestrated(_ ctx: TaskContext) async -> Bool? {
        guard orchestrationEnabled, ctx.record.kind == .development || ctx.record.kind == .readOnlyAnalysis, ctx.record.scope == nil, ctx.research?.importSource == nil else { return nil }
        let started = Date()
        let c = await planningContext(ctx)
        let route = OrchestrationPlanner.route(goal: ctx.record.goal, kind: ctx.record.kind, context: c)
        let plan: TaskPlan, template: String, rationale: String
        switch route {
        case .needsModelPlanning(let why): note("Orchestrator · no template (\(why)) — the planner model proposes a graph", .info, taskID: ctx.record.id); return nil
        case .single(let role, let tpl):
            plan = TaskPlan(summary: "Single \(role.label) node", steps: [PlanStep(id: "s1", title: "Run the project's tests", description: "Run the project's test command and report the real result.", type: .test, dependsOn: [],
                                                                                  expected: "the tests pass", validation: .testPass, risk: .low)])
            template = tpl; rationale = "a single \(role.label) job — no other agent is needed"
        case .graph(let op): plan = op.plan; template = op.template; rationale = op.rationale
        }
        guard let capset = capabilitiesForGraph(ctx, plan: plan) else { return nil }
        let base = PlanValidator.validate(plan, kind: ctx.record.kind, capabilities: capset, allowDestructive: ctx.record.destructiveRequested)
        let graph = GraphValidator.validate(plan, capabilities: capset, delegateCheck: delegateCheck(ctx))
        guard base.isEmpty, graph.isEmpty else {
            note("Orchestrator · the \(template) template does not fit this project (" + (base.map(\.description) + graph.map(\.description)).prefix(2).joined(separator: "; ") + ") — the planner model proposes a graph", .warning, taskID: ctx.record.id)
            return nil
        }
        mutate(ctx) { $0.capabilities = capset }
        installPlan(ctx, plan)
        ctx.orchestrated = true; ctx.graphTemplate = template
        saveGraph(ctx, template: template, planner: "deterministic", rationale: rationale, plannerChars: 0, plannerMS: Date().timeIntervalSince(started) * 1000)
        note("Orchestrator · \(plan.steps.count == 1 ? "1 node" : "\(plan.steps.count)-node graph") (\(template)): \(rationale)", .info, taskID: ctx.record.id)
        return true
    }

    /// Delegated nodes need the capability of the CHILD kind on the parent; nothing else is added. nil when a needed capability is not allowed by the user's settings.
    func capabilitiesForGraph(_ ctx: TaskContext, plan: TaskPlan) -> CapabilitySet? {
        var caps = ctx.record.capabilities.granted
        if plan.steps.contains(where: { $0.type == .delegateResearch }) { guard web != nil, webAllowed() else { return nil }; caps.insert(.researchWeb) }
        if plan.steps.contains(where: { $0.type == .delegateComputer }) { guard computer != nil, computerAllowed() else { return nil }; caps.insert(.controlComputer) }
        return CapabilitySet(granted: caps)
    }

    /// Plan-time check of a delegated node's goal: forbidden intent is refused; a computer goal must classify as Computer Use under the V0.11 ladder.
    func delegateCheck(_ ctx: TaskContext) -> @Sendable (PlanStep) -> String? {
        let unity = ctx.unityProject, root = ctx.record.workspaceRoot
        let vision = computer?.visionAllowed() ?? false
        return { step in
            let goal = step.delegate?.goal ?? ""
            if let bad = OrchestrationPolicy.forbiddenIntent(in: goal) { return "“\(bad)” can never be delegated" }
            if step.type == .delegateComputer {
                guard case .computer = ComputerGoalParser.classify(goal, context: GoalContext(projectRoot: root, unityProjectOpen: unity, visionEnabled: vision)) else { return "that is not a job for Computer Use under the capability ladder" }
            }
            return nil
        }
    }

    func saveGraph(_ ctx: TaskContext, template: String, planner: String, rationale: String?, plannerChars: Int?, plannerMS: Double?) {
        try? repository?.save(TaskGraphRecord(taskID: ctx.record.id, template: template, planner: planner, rationale: rationale, nodeCount: ctx.steps.count, revisions: ctx.revisionCount, plannerChars: plannerChars, plannerMS: plannerMS))
    }

    // MARK: Authority at node start (a handoff is data: the orchestrator re-derives authority every time)

    func orchestrationRefusal(_ ctx: TaskContext, _ step: TaskStepRecord) -> (FailureCategory, String)? {
        guard ctx.orchestrated else { return nil }
        let why = AgentContracts.violations(of: step.type, granted: ctx.record.capabilities)
        if !why.isEmpty { return (.capabilityDenied, "The \(step.role?.label ?? "node") role contract does not allow this: " + why.joined(separator: "; ")) }
        if step.type.isDelegate, let bad = OrchestrationPolicy.forbiddenIntent(in: step.delegate?.goal ?? "") { return (.securityBlocked, "“\(bad)” can never be delegated.") }
        return nil
    }

    // MARK: Artifacts + handoff

    func handoffFor(_ ctx: TaskContext, _ step: TaskStepRecord) -> HandoffPacket {
        guard ctx.orchestrated else { return .empty }
        let graph = TaskGraph(steps: ctx.steps)
        return HandoffBuilder.build(for: step, artifacts: ctx.artifacts, ancestors: graph.ancestors(of: step.key))
    }

    @discardableResult
    func store(_ ctx: TaskContext, _ artifact: AgentArtifact) -> AgentArtifact {
        ctx.artifacts.append(artifact)
        try? repository?.insert(artifact)
        if !artifact.injectionFlags.isEmpty { note("Artifact · \(artifact.kind.label) from \(artifact.role?.label ?? "JARVIS") contains instruction-shaped text (\(artifact.injectionFlags.joined(separator: ", "))) — kept as untrusted data", .warning, taskID: ctx.record.id) }
        return artifact
    }

    /// A finished (or failed) deterministic/model node leaves one typed artifact. Delegated nodes and gates build theirs themselves.
    func recordArtifact(_ ctx: TaskContext, key: String) {
        guard ctx.orchestrated, let step = ctx.step(key), !step.type.isDelegate, step.type != .approvalGate else { return }
        let inputs = TaskGraph(steps: ctx.steps).node(key)?.dependsOn ?? []
        let cand = ctx.candidates[key]?.last
        let provider = cand?.engine.displayName, model = cand?.model.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
        let attempt = step.attempts
        let evidence = step.validationEvidence ?? step.resultSummary ?? ""
        let passed = step.state == .passed
        let art: AgentArtifact?
        switch step.type {
        case .analysis:
            guard passed, let rendered = ctx.results[key] else { return }
            art = ArtifactFactory.analysis(taskID: ctx.record.id, node: key, rendered: rendered, provider: provider, model: model, runID: step.agentRunID, attempt: attempt, inputs: inputs, validation: evidence.isEmpty ? "structured result accepted" : evidence)
        case .codeChange:
            guard passed else { return }
            art = ArtifactFactory.codeChange(taskID: ctx.record.id, node: key, changes: ctx.changes.filter { $0.stepKey == key }, summary: step.resultSummary ?? "changed", provider: provider, model: model, runID: step.agentRunID, attempt: attempt, inputs: inputs)
        case .build, .test:
            guard step.state == .passed || step.state == .failed else { return }
            art = ArtifactFactory.validation(taskID: ctx.record.id, node: key, evidence: evidence, tail: ctx.lastFailureTail[key], passed: passed, attempt: attempt, inputs: inputs)
        case .review:
            guard step.state == .passed || step.state == .failed else { return }
            art = ArtifactFactory.review(taskID: ctx.record.id, node: key, verdict: passed ? "pass" : "fail", summary: step.resultSummary ?? "", issues: evidence.split(separator: "\n").map(String.init), provider: provider, model: model, runID: step.agentRunID, attempt: attempt, inputs: inputs, validation: passed ? "weighed against the recorded build/test facts" : "blocking finding with verifiable evidence")
        case .unityInspect, .unityEdit, .unityCompile, .unityTest, .unityPlayMode, .unityValidate:
            guard step.state == .passed || step.state == .failed else { return }
            art = ArtifactFactory.unity(taskID: ctx.record.id, node: key, evidence: evidence, inputs: inputs)
        case .computerAct:
            guard passed else { return }
            art = ArtifactFactory.computer(taskID: ctx.record.id, node: key, summary: evidence.isEmpty ? (step.resultSummary ?? "done") : evidence, inputs: inputs)
        default: art = nil
        }
        if let art { store(ctx, art) }
    }

    // MARK: Routing decisions + per-node ledgers

    static func role(forJobType t: String) -> AgentRole? {
        switch t { case "AnalysisAgent": .analysis; case "CodingAgent": .coding; case "ReviewAgent": .review; case "ResearchAgent": .research; case "UnityAgent": .unity; default: nil }
    }

    /// May this node still call a provider? (the per-node invocation cap from its role contract — repair and escalation cannot exceed it)
    func providerBudgetExhausted(_ ctx: TaskContext, _ job: AgentJob) -> Bool {
        guard ctx.orchestrated, let key = job.nodeKey, let role = Self.role(forJobType: job.type) else { return false }
        let cap = AgentContracts.contract(role).retry.maxProviderInvocations
        return cap > 0 && (ctx.ledgers[key]?.providerRuns ?? 0) >= cap
    }

    func recordRouting(_ ctx: TaskContext, job: AgentJob, result: AgentJobResult, runMS: Double, queueMS: Double, memoryItems: Int?, memoryChars: Int?) {
        let role = Self.role(forJobType: job.type)
        var runID: UUID?, cand: RoutingCandidate?, outcome = "rejected", failure: NodeFailureClass = .notApplicable
        switch result {
        case .completed(_, let id, let c, _): runID = id; cand = c; outcome = "passed"
        case .failed(let id, _, let vf, let c):
            runID = id; cand = c; outcome = "failed"
            failure = vf ? .invalidSchema : NodeFailureClass.classify(self.failure(from: result).0, validationFailed: vf)
        case .cancelled(let id): runID = id; outcome = "cancelled"; failure = .cancelled
        case .rejected: failure = NodeFailureClass.classify(self.failure(from: result).0)
        }
        let rec = runID.flatMap { audit.record($0) }
        let reasons = RoutingExplainer.parse(rec?.selectionReason)
        let key = job.nodeKey
        var independence: ReviewIndependence.Outcome?
        if let key, role == .review, cand != nil, let writers = ctx.reviewWriters[key] {
            independence = ReviewIndependence.outcome(required: true, writers: writers, reviewer: cand ?? rec.map { RoutingCandidate(engine: $0.engine, model: $0.model) })
            ctx.independence[key] = independence
        }
        let escalation = key.flatMap { ctx.escalationReasons[$0] }
        let text: String
        if let role { text = RoutingExplainer.sentence(role: role, candidate: cand ?? rec.map { RoutingCandidate(engine: $0.engine, model: $0.model) }, reasons: reasons, independence: independence ?? .notRequired, escalatedFrom: rec?.escalatedFrom, roleScore: nil) }
        else { text = RoutingExplainer.sentence(role: .analysis, candidate: cand, reasons: reasons).replacingOccurrences(of: "for Analysis", with: "for planning") }
        if let key, role != nil {
            var l = ctx.ledgers[key] ?? NodeLedger()
            l.record(engine: cand?.engine.rawValue, repair: false, escalation: escalation != nil && rec?.escalatedFrom != nil)
            ctx.ledgers[key] = l
        }
        try? repository?.insert(RoutingDecisionRecord(taskID: ctx.record.id, nodeKey: key, role: role, agentRunID: runID, engine: (cand?.engine ?? rec?.engine)?.rawValue, model: cand?.model ?? rec?.model, mode: reasons["mode"],
                                                      reasonText: text, reasonJSON: rec?.selectionReason, independence: independence?.rawValue, escalationReason: escalation?.rawValue,
                                                      failureClass: failure == .notApplicable ? nil : failure.rawValue, outcome: outcome, contextChars: job.prompt.count, memoryItems: memoryItems,
                                                      artifactCount: job.artifactCount, fileCount: job.fileCount, handoffChars: job.handoffChars, queueMS: queueMS, runMS: runMS,
                                                      inputTokens: rec?.inputTokens, outputTokens: rec?.outputTokens, costClass: (cand?.engine ?? rec?.engine)?.costClass.rawValue))
    }

    /// Why a node escalated, stated explicitly (never "it failed").
    func inferEscalationReason(_ ctx: TaskContext, _ step: TaskStepRecord, why: String) -> EscalationReason {
        let l = why.lowercased()
        if ReviewIndependence.looksSecurityRelevant(goal: ctx.record.goal, paths: ctx.changes.map(\.path)) { return .securityRelevant }
        if l.contains("unavailable") || l.contains("not installed") || l.contains("no eligible") || l.contains("rate") { return .freeModelUnavailable }
        if l.contains("context") || l.contains("too large") { return .contextTooLarge }
        if l.contains("review") { return .reviewFoundDefect }
        if (ctx.step(step.key)?.attempts ?? 0) >= 2 { return .validationFailedTwice }
        return ctx.record.category == .architecture ? .complexArchitecture : .validationFailedTwice
    }

    // MARK: Delegated nodes (research / computer) — each runs as an ordinary child task started by the orchestrator

    private func childRecord(_ id: UUID) -> TaskRecord? { (try? repository?.engineTask(id)) ?? nil }

    private func waitForChild(_ ctx: TaskContext, _ childID: UUID, activity: String) async -> TaskRecord? {
        mutate(ctx) { $0.activity = activity }
        await waitUntilFinished(childID)
        return childRecord(childID)
    }

    func runDelegateResearch(_ ctx: TaskContext, _ key: String) async -> StepOutcome {
        guard let step = ctx.step(key), let params = step.delegate else { return .failed(.malformedPlan, "The research node has no goal.") }
        guard let web, webAllowed() else { return .failed(.providerUnavailable, "Web research is turned off or not available.") }
        // Reuse: a child that already FINISHED (before a restart) is reused when its evidence is still fresh; an interrupted one is resumed explicitly by this resume.
        if let existing = step.delegatedTaskID, let child = childRecord(existing) {
            if child.state == .completed, Date().timeIntervalSince(child.finishedAt ?? .distantPast) < Self.researchFreshness { return finishResearchNode(ctx, step, child: child, reused: true) }
            if child.state == .interrupted, contexts[existing] == nil, resume(existing) {
                guard let done = await waitForChild(ctx, existing, activity: "Waiting for the research task (resumed)") else { return .failed(.toolFailed, "The research task disappeared.") }
                if ctx.cancelRequested || Task.isCancelled { return .cancelled }
                return finishResearchNode(ctx, step, child: done, reused: false)
            }
        }
        let facts = (ctx.record.kind == .development || ctx.record.kind == .readOnlyAnalysis) ? TaskIntake.projectFacts(root: ctx.record.workspaceRoot ?? "") : nil
        let request = ResearchIntake.parse(goal: params.goal, project: facts)
        switch await submitResearch(request, preference: ctx.record.preference, inputChannel: ctx.record.inputChannel, parentTaskID: ctx.record.id) {
        case .failure(let e): return .failed(.providerUnavailable, e.description)
        case .success(let childID):
            updateStep(ctx, key) { $0.delegatedTaskID = childID }
            note("Orchestrator · started the research task for “\(step.title)”", .info, taskID: ctx.record.id)
            guard let child = await waitForChild(ctx, childID, activity: "Waiting for the research task") else { return .failed(.toolFailed, "The research task disappeared.") }
            if ctx.cancelRequested || Task.isCancelled { return .cancelled }
            _ = web
            return finishResearchNode(ctx, step, child: child, reused: false)
        }
    }
    static let researchFreshness: TimeInterval = 24 * 3600

    private func finishResearchNode(_ ctx: TaskContext, _ step: TaskStepRecord, child: TaskRecord, reused: Bool) -> StepOutcome {
        guard child.state == .completed else {
            let cat = child.failureCategory ?? .noSources
            return .failed(cat, "The research task " + (child.state == .cancelled ? "was stopped" : "did not finish") + ": " + (child.failureReason ?? cat.label))
        }
        let claims = ((try? repository?.researchClaims(child.id)) ?? []) ?? []
        let sources = ((try? repository?.researchSources(child.id)) ?? []) ?? []
        let verified = claims.filter { $0.status == .verified }
        let domains = Dictionary(sources.map { ($0.id, $0.domain) }, uniquingKeysWith: { a, _ in a })
        var lines: [String] = []
        if let s = researchSummaries[child.id] ?? child.summary, !s.isEmpty { lines.append(String(s.prefix(900))) }
        lines.append("Verified findings (\(verified.count)):")
        for c in verified.prefix(8) { lines.append("- [\(c.kind.rawValue)] \(String(c.statement.prefix(220))) — \(c.evidence.first.flatMap { domains[$0.sourceID] } ?? "source")") }
        let open = claims.filter { $0.status != .verified }
        if !open.isEmpty { lines.append("Not verified (\(open.count)): " + open.prefix(3).map { "\($0.status.rawValue): \(String($0.statement.prefix(100)))" }.joined(separator: "; ")) }
        if verified.isEmpty { lines.append("Nothing could be verified from the sources — treat the topic as unresearched.") }
        let art = ArtifactFactory.research(taskID: ctx.record.id, node: step.key, summary: lines.joined(separator: "\n"), validation: "V0.9: \(verified.count) claim(s) verified against verbatim evidence from \(sources.count) source(s)\(reused ? " (reused after restart)" : "")",
                                           inputs: TaskGraph(steps: ctx.steps).node(step.key)?.dependsOn ?? [])
        store(ctx, art)
        verifying(ctx, step.key)
        setStep(ctx, step.key, to: .passed, evidence: art.validation, result: "\(verified.count) verified finding(s)")
        return .passed
    }

    func runDelegateComputer(_ ctx: TaskContext, _ key: String) async -> StepOutcome {
        guard let step = ctx.step(key), let params = step.delegate else { return .failed(.malformedPlan, "The computer node has no goal.") }
        guard let computer, computerAllowed() else { return .failed(.providerUnavailable, "Computer Use is turned off or not available.") }
        // GUI work is never replayed from an old session: a restart means a NEW child that observes everything from scratch.
        guard case .computer(let parsed) = ComputerGoalParser.classify(params.goal, context: GoalContext(projectRoot: ctx.record.workspaceRoot, unityProjectOpen: ctx.unityProject, visionEnabled: computer.visionAllowed())) else {
            return .failed(.securityBlocked, "That is not a job for Computer Use under the capability ladder.")
        }
        switch await submitComputer(goal: params.goal, steps: parsed.steps, capability: parsed.capability, apps: parsed.apps, preference: ctx.record.preference, inputChannel: ctx.record.inputChannel, parentTaskID: ctx.record.id) {
        case .failure(let e): return .failed(.providerUnavailable, e.description)
        case .success(let childID):
            updateStep(ctx, key) { $0.delegatedTaskID = childID }
            note("Orchestrator · started a Computer Use task for “\(step.title)”", .info, taskID: ctx.record.id)
            guard let child = await waitForChild(ctx, childID, activity: "Waiting for the Computer Use task") else { return .failed(.toolFailed, "The computer task disappeared.") }
            if ctx.cancelRequested || Task.isCancelled { return .cancelled }
            guard child.state == .completed else { return .failed(child.failureCategory ?? .computerActionFailed, "The computer task did not finish: " + (child.failureReason ?? "unknown")) }
            let lines = computerReportLines(taskID: childID) ?? []
            let art = ArtifactFactory.computer(taskID: ctx.record.id, node: key, summary: (child.summary ?? "done") + "\n" + lines.prefix(12).joined(separator: "\n"), inputs: TaskGraph(steps: ctx.steps).node(key)?.dependsOn ?? [])
            store(ctx, art)
            verifying(ctx, key)
            setStep(ctx, key, to: .passed, evidence: "Computer Use task completed; every action's postcondition was observed", result: child.summary)
            return .passed
        }
    }

    // MARK: Approval gate (a graph node only a HUD decision can release)

    func runApprovalGate(_ ctx: TaskContext, _ key: String) async -> StepOutcome {
        guard let step = ctx.step(key), let action = step.delegate?.gateAction, !action.isEmpty else { return .failed(.malformedPlan, "The approval gate names no action.") }
        let ok = await requestApproval(ctx, step, action: "Continue with: \(action)", reason: step.delegate?.reason.isEmpty == false ? step.delegate!.reason : "Later steps of this task depend on your decision. JARVIS (and no agent) can approve this for you.", risk: step.risk)
        if ctx.cancelRequested || Task.isCancelled { return .cancelled }
        let rec = (try? repository?.approvals(taskID: ctx.record.id))?.last { $0.stepID == step.id }
        store(ctx, ArtifactFactory.gate(taskID: ctx.record.id, node: key, action: action, approved: ok, decidedBy: rec?.decidedBy ?? "user"))
        guard ok else { return .failed(.approvalDenied, "“\(action)” was not approved.") }
        verifying(ctx, key)
        setStep(ctx, key, to: .passed, evidence: "Released by a HUD approval (\(rec?.decidedBy ?? "user")) — \(action)")
        return .passed
    }

    // MARK: Bounded graph revision (the ORCHESTRATOR decides; a specialist may only ask)

    /// A specialist reported that knowledge is missing. Insert a research node after it — once per need, at most `maxRevisions` times per task, only when research is allowed.
    @discardableResult
    func considerResearchRevision(_ ctx: TaskContext, after key: String, wants: [String]) -> Bool {
        guard ctx.orchestrated, !wants.isEmpty, web != nil, webAllowed(), ctx.revisionCount < OrchestrationLimits.maxRevisions,
              !ctx.steps.contains(where: { $0.type == .delegateResearch && $0.state != .failed }) || ctx.revisionCount == 0 && !ctx.steps.contains(where: { $0.type == .delegateResearch }),
              ctx.steps.count < OrchestrationLimits.maxNodes, ctx.step(key) != nil else { return false }
        let question = String(wants.joined(separator: "; ").prefix(400))
        guard OrchestrationPolicy.forbiddenIntent(in: question) == nil else { return false }
        var plan = planFromSteps(ctx)
        guard let result = GraphRevision.insertResearch(into: plan, after: key, goal: ctx.record.goal + " — " + question, reason: "a specialist reported missing knowledge: " + question, revision: ctx.revisionCount + 1) else { return false }
        plan = result.plan
        guard let caps = capabilitiesForGraph(ctx, plan: plan),
              PlanValidator.validate(plan, kind: ctx.record.kind, capabilities: caps, allowDestructive: ctx.record.destructiveRequested).isEmpty,
              GraphValidator.validate(plan, capabilities: caps, delegateCheck: delegateCheck(ctx)).isEmpty else {
            note("Orchestrator · the proposed graph revision was rejected by validation", .warning, taskID: ctx.record.id); return false
        }
        applyRevision(ctx, plan: plan, caps: caps, added: result.addedKeys, reason: result.summary)
        return true
    }

    func planFromSteps(_ ctx: TaskContext) -> TaskPlan {
        TaskPlan(summary: ctx.record.summary ?? ctx.record.title, steps: ctx.steps.map {
            PlanStep(id: $0.key, title: $0.title, description: $0.details, type: $0.type, dependsOn: $0.dependsOn, expected: $0.expected, validation: $0.validation, risk: $0.risk, unity: $0.unity, computer: $0.computer, optional: $0.optional, delegate: $0.delegate)
        }, version: ctx.record.planVersion)
    }

    private func applyRevision(_ ctx: TaskContext, plan: TaskPlan, caps: CapabilitySet, added: [String], reason: String) {
        ctx.revisionCount += 1
        let existing = Dictionary(ctx.steps.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var steps: [TaskStepRecord] = []
        for (i, p) in plan.steps.enumerated() {
            if var old = existing[p.id] { old.index = i; old.dependsOn = p.dependsOn; steps.append(old); continue }
            var rec = TaskStepRecord(id: UUID(), taskID: ctx.record.id, index: i, key: p.id, title: p.title, details: p.description, type: p.type, dependsOn: p.dependsOn, expected: p.expected, validation: p.validation, risk: max(p.risk, p.type.defaultRisk), weight: 1)
            rec.optional = p.optional; rec.delegate = p.delegate; rec.revision = ctx.revisionCount
            steps.append(rec)
        }
        ctx.steps = steps
        for s in steps { if existing[s.key] == nil { try? repository?.insertSteps([s]) } else { try? repository?.update(s) } }
        mutate(ctx) { $0.capabilities = caps; $0.planVersion += 1 }
        try? repository?.insert(GraphRevisionRecord(taskID: ctx.record.id, n: ctx.revisionCount, reason: reason, added: added))
        saveGraph(ctx, template: ctx.graphTemplate, planner: "deterministic", rationale: nil, plannerChars: nil, plannerMS: nil)
        refreshProgress(ctx)
        note("Orchestrator · graph revision \(ctx.revisionCount)/\(OrchestrationLimits.maxRevisions): \(reason)", .info, taskID: ctx.record.id)
    }

    // MARK: Staleness (restart / changed truth)

    /// A node's result can no longer be relied on: it and everything that was built on it run again, and their artifacts stop travelling.
    func invalidate(_ ctx: TaskContext, from key: String, why: String) {
        let graph = TaskGraph(steps: ctx.steps)
        var affected: Set<String> = [key]
        var changed = true
        while changed { changed = false; for n in graph.nodes where !affected.contains(n.key) && n.dependsOn.contains(where: affected.contains) { affected.insert(n.key); changed = true } }
        for k in affected { if let s = ctx.step(k), [.passed, .failed, .skipped, .interrupted].contains(s.state) { resetStep(ctx, k) } }
        try? repository?.markArtifactsStale(taskID: ctx.record.id, nodeKeys: Array(affected))
        for i in ctx.artifacts.indices where affected.contains(ctx.artifacts[i].nodeKey) { ctx.artifacts[i].status = .stale }
        note("Orchestrator · \(affected.count) node(s) will run again: \(why)", .warning, taskID: ctx.record.id)
    }

    private func resetStep(_ ctx: TaskContext, _ key: String) {
        guard let i = ctx.index(key) else { return }
        ctx.steps[i].state = .pending; ctx.steps[i].finishedAt = nil; ctx.steps[i].failureCategory = nil; ctx.steps[i].failureReason = nil
        try? repository?.update(ctx.steps[i])
        ctx.results[key] = nil
    }

    /// On an explicit resume: completed work is reused only while the truth it rested on still holds (files unchanged on disk; research still fresh).
    func revalidateCompleted(_ ctx: TaskContext) {
        guard ctx.orchestrated else { return }
        for s in ctx.steps where s.state == .passed {
            switch s.type {
            case .codeChange:
                let mine = ctx.changes.filter { $0.stepKey == s.key }
                let drift = mine.contains { c in ((try? ctx.tools.fileHash(c.path)) ?? nil) != c.afterHash }
                if drift { invalidate(ctx, from: s.key, why: "files written by “\(s.title)” no longer match what JARVIS wrote") }
            case .delegateResearch:
                if let id = s.delegatedTaskID, let child = childRecord(id), Date().timeIntervalSince(child.finishedAt ?? .distantPast) >= Self.researchFreshness { invalidate(ctx, from: s.key, why: "the research behind “\(s.title)” is older than 24 h") }
            default: break
            }
        }
    }
}

extension GoalCues {
    /// The user asks for CURRENT information: memory of earlier research can never answer that on its own (V0.10: research memory is "revalidate before use").
    static func demandsCurrency(_ raw: String) -> Bool {
        let f = ResearchText.fold(raw)
        return ["guncel", "up to date", "up-to-date", "latest", "current", "newest", "yeni surum", "son surum", "bugun", "today"].contains { f.contains($0) }
    }
}

extension TaskEngine {
    /// The capabilities a validated graph needs on top of the task's own (the child kinds of its delegated nodes), limited by the user's settings.
    nonisolated static func graphCapabilities(_ base: CapabilitySet, plan: TaskPlan, web: Bool, computer: Bool) -> CapabilitySet {
        var caps = base.granted
        if web, plan.steps.contains(where: { $0.type == .delegateResearch }) { caps.insert(.researchWeb) }
        if computer, plan.steps.contains(where: { $0.type == .delegateComputer }) { caps.insert(.controlComputer) }
        return CapabilitySet(granted: caps)
    }
}

// MARK: - Final synthesis (from graph state and validated artifacts — never from provider memory)

extension TaskEngine {
    func orchestrationReportLines(_ taskID: UUID, task: TaskRecord, steps: [TaskStepRecord]) -> [String] {
        var out: [String] = []
        let g = (try? repository?.taskGraph(taskID)) ?? nil
        if let g { out.append("Graph: \(g.nodeCount) node(s), \(g.template), planned by \(g.planner == "model" ? "the planner model (validated by JARVIS)" : "JARVIS (deterministic)")\(g.revisions > 0 ? ", \(g.revisions) revision(s)" : "")") }
        let (done, total) = GraphProgress.validated(steps)
        out.append("Required nodes validated: \(done)/\(total)")
        for s in steps {
            let role = s.role?.label ?? "Approval"
            out.append("\(role) · \(s.title): \(s.state.label.lowercased())\(s.optional ? " (optional)" : "")" + (s.attempts > 1 ? ", \(s.attempts) attempts" : ""))
        }
        let decisions = ((try? repository?.routingDecisions(taskID: taskID)) ?? []) ?? []
        for d in decisions where d.role != nil { out.append("Routing · " + d.reasonText) }
        let arts = ((try? repository?.artifacts(taskID: taskID)) ?? []) ?? []
        if !arts.isEmpty { out.append("Artifacts: " + Dictionary(grouping: arts, by: { $0.kind.label }).map { "\($0.key) ×\($0.value.count)" }.sorted().joined(separator: ", ") + " (trust: " + Set(arts.map { $0.trust.label }).sorted().joined(separator: ", ") + ")") }
        if let revs = try? repository?.graphRevisions(taskID: taskID) { for r in revs { out.append("Graph revision \(r.n): \(r.reason)") } }
        let skipped = arts.contains { !$0.injectionFlags.isEmpty }
        if skipped { out.append("Some upstream text contained instruction-shaped phrases; it was kept as untrusted data and changed nothing.") }
        return out
    }
}

// MARK: - Status adapter

extension TaskEngine {
    /// The orchestrated task a status question is about: the newest ACTIVE root task, else the newest orchestrated one that finished.
    func statusSnapshot() -> StatusSnapshot? {
        let candidates = orderedViews.filter { $0.task.parentTaskID == nil && (contexts[$0.id]?.orchestrated ?? (((try? repository?.taskGraph($0.id)) ?? nil) != nil)) }
        guard let v = candidates.first(where: { $0.task.state.isActive || $0.task.state == .waitingForApproval }) ?? candidates.first else { return nil }
        let children = contexts.values.filter { $0.record.parentTaskID == v.id && $0.record.state.isActive }.map(\.record)
        var providers: [String: String] = [:]
        for s in v.steps where s.state.isActive {
            if let rid = s.agentRunID ?? hub?.activeRuns.first(where: { $0.taskID == v.id && $0.label == s.title })?.id, let rec = audit.record(rid) {
                providers[s.key] = rec.engine.displayName + (rec.model.map { " · " + ($0.split(separator: "/").last.map(String.init) ?? $0) } ?? "")
            }
        }
        return StatusSnapshot(title: v.task.title, state: v.task.state, steps: v.steps, pendingApprovalAction: v.pendingApproval?.action, activeChildren: children, providers: providers)
    }

    func graphStatusText(_ focus: StatusFocus, _ language: ReplyLanguage) -> String? {
        statusSnapshot().map { OrchestrationStatus.describe($0, focus: focus, language: language) }
    }
}

// MARK: - Review → repair (one bounded cycle)

extension TaskEngine {
    /// The reviewer found a defect it could back with evidence (`ReviewAuthority` already decided that it fails the task). The change is repaired ONCE with those findings, every
    /// build/test that depends on the change is run again for real, and only if they all pass does the review run once more. Returns true when a re-review should happen.
    func reviewRepairCycle(_ ctx: TaskContext, review step: TaskStepRecord, result: ReviewResult) async -> Bool {
        guard let code = nearestCodeStep(ctx, before: step), (ctx.step(code.key)?.attempts ?? 0) < Self.maxStepAttempts, !ctx.cancelRequested, !Task.isCancelled else { return false }
        ctx.reviewCycles += 1
        ctx.escalationReasons[code.key] = .reviewFoundDefect
        mutate(ctx) { $0.activity = "Repairing after the review" }
        note("Orchestrator · the review found a defect — one repair cycle: \(code.title)", .warning, taskID: ctx.record.id)
        let findings = (result.detailed.filter { $0.severity == .blocking }.map { "- \($0.text) (evidence: \($0.evidence))" } + result.issues.map { "- \($0)" }).prefix(6).joined(separator: "\n")
        let used = ctx.candidates[code.key] ?? []
        let attempt = beginAttempt(ctx, code, .repair)
        let r = await codeAttempt(ctx, code, kind: .repair, failure: "The reviewer found these defects in your change:\n" + findings, pin: used.last, exclude: [])
        if r.cancelled || r.failure != nil {
            endAttempt(attempt, outcome: r.cancelled ? "cancelled" : "failed:\(r.failure?.0.rawValue ?? "toolFailed")", evidence: r.failure?.1, runID: r.runID, candidate: r.candidate)
            return false
        }
        endAttempt(attempt, outcome: "applied", evidence: r.evidence, runID: r.runID, candidate: r.candidate)
        updateStep(ctx, code.key) { $0.agentRunID = r.runID; $0.resultSummary = "Changed: " + ctx.finals.keys.sorted().joined(separator: ", ") }
        try? repository?.markArtifactsStale(taskID: ctx.record.id, nodeKeys: [code.key])
        recordArtifact(ctx, key: code.key)
        // Everything that proves the change runs again, in plan order — a repair that breaks the build or the tests never reaches the second review.
        let graph = TaskGraph(steps: ctx.steps)
        let anc = graph.ancestors(of: step.key)
        for v in ctx.steps where anc.contains(v.key) && (v.type == .build || (v.type == .test && v.validation == .testPass)) {
            guard let profile = v.type == .build ? ctx.profiles.build : ctx.profiles.test else { continue }
            let res = await runCommand(ctx, v, profile, label: "\(v.title) · after the review repair", attemptKind: .recheck)
            if ctx.cancelRequested || Task.isCancelled || res.cancelled { return false }
            let line = evidenceLine(v, profile, res)
            ctx.evidence.append(line)
            updateStep(ctx, v.key) { $0.validationEvidence = line }
            if !res.succeeded { ctx.lastFailureTail[v.key] = res.tail; return false }
            try? repository?.markArtifactsStale(taskID: ctx.record.id, nodeKeys: [v.key])
            recordArtifact(ctx, key: v.key)
        }
        try? repository?.markArtifactsStale(taskID: ctx.record.id, nodeKeys: [step.key])
        return true
    }
}

// MARK: - Compact HUD line

extension TaskEngine {
    /// "Coding · space-bunny-free" for the node that is running now, and the role that waits next ("QA waiting"). nil for tasks that are not orchestrated.
    func compactAgentLine(_ v: TaskView) -> (active: String, waiting: String?)? {
        guard contexts[v.id]?.orchestrated == true, v.task.state.isActive else { return nil }
        guard let cur = v.steps.first(where: { $0.state.isActive || $0.state == .waitingForApproval }) else { return nil }
        let role = cur.role?.label ?? "Approval"
        var s = role
        if let rid = cur.agentRunID ?? hub?.activeRuns.first(where: { $0.taskID == v.id && $0.label == cur.title })?.id, let rec = audit.record(rid) {
            s += " · " + (rec.model.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? rec.engine.displayName)
        }
        let done = Set(v.steps.filter { $0.state == .passed || $0.state == .skipped }.map(\.key))
        let next = v.steps.first { $0.state == .pending && $0.dependsOn.contains(cur.key) } ?? v.steps.first { $0.state == .pending && !$0.dependsOn.allSatisfy(done.contains) }
        return (s, next.map { "\($0.role?.label ?? "Approval") waiting" })
    }
}
