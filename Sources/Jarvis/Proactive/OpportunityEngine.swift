import Foundation
import Observation

struct AutonomySettings: Equatable, Sendable {
    var mode: AutonomyMode = .askBeforeActing          // conservative default (V0.5)
    var proactiveEnabled = true
    var showProposals = true
}

enum IngestResult: Equatable, Sendable {
    case ignored(String)
    case duplicate(UUID)             // same opportunity already known (open or in cooldown)
    case coalesced(UUID)             // merged into an existing open opportunity
    case recorded(UUID)
    case proposed(opportunity: UUID, proposal: UUID)
    case autoTask(opportunity: UUID, task: UUID)
    case queued(UUID)                // authorised, waiting for a free task slot
}

/// The decision layer above the V0.4 task engine (V0.5 — DEC-041…): observe (event-driven) → detect → deduplicate → assess → policy →
/// ignore / record / propose / auto-action. It NEVER edits project files and never executes anything itself: an automatic or approved
/// action becomes an ordinary V0.4 task (`TaskEngine.submit`) with a persisted origin, scope and depth.
@MainActor
@Observable
final class OpportunityEngine {
    let repository: JarvisRepository?
    let audit: AuditRecorder
    let tasks: TaskEngine
    @ObservationIgnored var settings: () -> AutonomySettings = { AutonomySettings() }
    var budget = AutonomyBudget()
    var denyCooldown: TimeInterval = 14 * 86400
    var dismissCooldown: TimeInterval = 3 * 86400
    var proposalLifetime: TimeInterval = 7 * 86400
    @ObservationIgnored var clock: () -> Date = { Date() }
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onEvent: ((String, ActivityKind) -> Void)?

    private(set) var pending: [ProposalRecord] = []
    private(set) var recorded: [OpportunityRecord] = []
    private(set) var revision = 0
    /// Why a provider was called for proactive reasoning (kept for the activity feed / usage report).
    private(set) var providerCalls: [String] = []
    @ObservationIgnored private var assessorCalls: [UUID: Int] = [:]
    @ObservationIgnored private var suggestions: [UUID: [(ReviewSuggestion, UUID?, UUID?)]] = [:]

    init(repository: JarvisRepository?, audit: AuditRecorder, tasks: TaskEngine) {
        self.repository = repository; self.audit = audit; self.tasks = tasks
    }

    // MARK: Observation entry points (event-driven; there is no timer and no polling in this file)

    /// A V0.4 task reached a terminal state: derive bounded, structured findings from what JARVIS recorded and ingest them.
    func taskFinished(_ view: TaskView) async {
        let t = view.task
        guard settings().proactiveEnabled, let repository else { suggestions[t.id] = nil; return }
        await handleScopeExceeded(t)
        await retryQueued()                                              // a task slot just freed up
        guard t.state == .completed || t.state == .failed else { return }
        let steps = (try? repository.steps(taskID: t.id)) ?? view.steps
        let changes = (try? repository.taskFileChanges(taskID: t.id)) ?? []
        let findings = FindingExtractor.findings(task: t, steps: steps, changes: changes, report: tasks.report(for: t.id), knownFiles: await knownFiles(t.workspaceRoot))
        for f in findings.prefix(3) { _ = await ingest(f) }              // bounded: at most 3 findings per finished task
        await flushSuggestions(for: t.id)                                // model suggestions come AFTER the deterministic facts (they coalesce into them, never the reverse)
    }

    /// Model-written review suggestions are CLAIMS. They are held until the task finishes (so the deterministic facts are ingested first)
    /// and then enter as findings with `reviewClaim` evidence only — a model-supplied file reference never makes evidence "strong".
    func reviewSuggestions(task: TaskRecord, stepID: UUID?, runID: UUID?, suggestions s: [ReviewSuggestion]) async {
        guard settings().proactiveEnabled, task.workspaceRoot != nil else { return }
        suggestions[task.id] = (suggestions[task.id] ?? []) + s.prefix(2).map { ($0, stepID, runID) }
    }

    /// Ingests the held suggestions of a finished task (bounded: 2).
    func flushSuggestions(for taskID: UUID) async {
        let held = suggestions.removeValue(forKey: taskID) ?? []
        guard !held.isEmpty, let task = (try? repository?.engineTask(taskID)) ?? nil, let root = task.workspaceRoot else { return }
        for (s, stepID, runID) in held.prefix(2) {
            let f = RawFinding(origin: .reviewFinding, title: s.title, summary: s.summary, category: s.category,
                               evidence: [EvidenceItem(kind: .reviewClaim, summary: s.summary.isEmpty ? s.title : s.summary, reference: s.files.first)],
                               affectedPaths: s.files, originTaskID: task.id, originStepID: stepID, originRunID: runID, projectRoot: root,
                               claimedDesignImpact: s.designImpact, needsModelAssessment: s.category == nil,
                               eventKey: "review:\(task.id.uuidString):\(OpportunityNormalizer.dedupKey(project: root, category: s.category ?? .maintenance, scope: s.files, title: s.title))")
            _ = await ingest(f)
        }
    }

    // MARK: Ingest

    @discardableResult
    func ingest(_ f: RawFinding) async -> IngestResult {
        let s = settings()
        guard s.proactiveEnabled else { return .ignored("proactive reasoning is off") }
        guard let repository else { return .ignored("no database") }
        let now = clock()
        let root = f.projectRoot
        let title = OutputSanitizer.sanitize(String(f.title.prefix(200)))
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return .ignored("empty finding") }

        // Idempotent delivery: the same event never creates a second opportunity.
        if let key = f.eventKey, let existing = (try? repository.opportunity(sourceEvent: key)) ?? nil { return .duplicate(existing.id) }

        var category = OpportunityAssessor.inferCategory(f)
        let candidates = (try? repository.dedupCandidates(project: root, now: now)) ?? []

        // Deduplicate against open opportunities and against closed ones still in cooldown.
        if let dup = candidates.first(where: { OpportunityNormalizer.isDuplicate(project: root, category: category, scope: f.affectedPaths, title: title, of: $0) }) {
            let inCooldown = dup.status.isClosedByUser || dup.status == .obsolete || dup.status == .expired
            if !inCooldown || !materiallyDifferent(f.evidence, from: dup.evidence) {
                var d = dup
                d.occurrences += 1; d.updatedAt = now
                d.evidence = mergedEvidence(d.evidence, f.evidence)
                try? repository.update(d)
                note("Opportunity deduplicated: \(d.title)", .info, d)
                refresh()
                return .duplicate(d.id)
            }
        }
        // The same ask in different words as something the user already denied/dismissed (cooldown): suppressed, not re-proposed.
        if let closed = candidates.first(where: { OpportunityNormalizer.shouldSuppress(project: root, category: category, scope: f.affectedPaths, whileCoolingDown: $0) }), !materiallyDifferent(f.evidence, from: closed.evidence) {
            var d = closed
            d.occurrences += 1; d.updatedAt = now; d.evidence = mergedEvidence(d.evidence, f.evidence)
            try? repository.update(d)
            note("Opportunity suppressed (you already declined a similar one): \(f.title)", .info, d)
            refresh()
            return .duplicate(d.id)
        }
        // Coalesce related findings (same kind, same primary file) into ONE open opportunity / proposal.
        if let into = candidates.first(where: { OpportunityNormalizer.shouldCoalesce(project: root, category: category, scope: f.affectedPaths, into: $0, originTaskID: f.originTaskID) }) {
            var d = into
            d.occurrences += 1; d.updatedAt = now
            d.evidence = mergedEvidence(d.evidence, f.evidence)
            try? repository.update(d)
            note("Opportunity coalesced into: \(d.title)", .info, d)
            refresh()
            return .coalesced(d.id)
        }

        // Assess (deterministic) — and, only when the finding lacks structure and the budget allows, add model caution.
        let originTask = f.originTaskID.flatMap { (try? repository.engineTask($0)) ?? nil }
        let known = await knownFiles(root)
        let changed = ((f.originTaskID.flatMap { try? repository.taskFileChanges(taskID: $0) }) ?? []).map(\.path)
        var assessment = OpportunityAssessor.assess(f, category: category, context: AssessmentContext(taskChangedPaths: changed, knownFiles: known, originAutonomyDepth: originTask?.autonomyDepth ?? 0))
        var affected = f.affectedPaths
        if f.needsModelAssessment, let origin = f.originTaskID, (assessorCalls[origin] ?? 0) < budget.assessorCallsPerOriginTask {
            if let merged = await modelAssess(f, task: originTask, known: known, assessment: assessment, category: category) {
                assessment = merged.0; category = merged.1; affected = Array(Set(affected + merged.2))
                assessorCalls[origin, default: 0] += 1
            }
        }
        var raw = f; raw.affectedPaths = affected
        let concrete = f.proposedAction != nil || [.testCoverage, .bug, .maintenance, .documentation].contains(category) && f.origin != .validationFinding && f.origin != .testFinding && f.origin != .buildFinding
        let action = OpportunityAssessor.proposedAction(for: raw, category: category, assessment: assessment, knownFiles: known)

        let autoCount = f.originTaskID.flatMap { try? repository.autoActionCount(originTaskID: $0) } ?? 0
        let ctx = PolicyContext(mode: s.mode, proactiveEnabled: s.proactiveEnabled, originAutonomyDepth: originTask?.autonomyDepth ?? 0,
                                originIsUserTask: (originTask?.origin ?? .userTask) == .userTask, hasOriginTask: originTask != nil, autoTasksForOrigin: autoCount,
                                hasProposedAction: concrete, budget: budget)
        var outcome = OpportunityPolicy.decide(assessment, category: category, context: ctx)
        if outcome.reasons.contains("autonomyBudgetExhausted") { note("Autonomy budget exhausted for this task — the finding is recorded/proposed instead", .warning, nil) }
        if outcome.decision == .ignore {
            note("Opportunity ignored: \(title) (\(outcome.reasons.joined(separator: ", ")))", .info, nil)
            return .ignored(outcome.reasons.joined(separator: ", "))
        }

        // Persist FIRST (status detected) so a crash between steps can be reconciled idempotently.
        let oid = f.eventKey.map { Self.derivedID("opp:" + $0) } ?? UUID()
        var o = OpportunityRecord(id: oid, projectRoot: root, origin: f.origin, originTaskID: f.originTaskID, originStepID: f.originStepID, originRunID: f.originRunID, title: title,
                                  summary: OutputSanitizer.sanitize(String(f.summary.prefix(800))), category: category, evidence: Array(f.evidence.prefix(12)),
                                  affectedScope: OpportunityNormalizer.normalizedScope(affected), assessment: assessment, policyDecision: outcome.decision,
                                  dedupKey: OpportunityNormalizer.dedupKey(project: root, category: category, scope: affected, title: title))
        o.policyReasons = outcome.reasons
        o.autonomyDepth = originTask?.autonomyDepth ?? 0
        o.proposedAction = action
        o.actionHash = OpportunityAssessor.actionHash(opportunityID: oid, projectRoot: root, action: action, risk: assessment.risk, category: category)
        o.sourceEvent = f.eventKey
        o.expiresAt = now.addingTimeInterval(proposalLifetime)
        let closedBefore = (try? repository.opportunities(project: root, statuses: [.denied, .dismissed], limit: 100)) ?? []
        if let dup = closedBefore.first(where: { OpportunityNormalizer.isDuplicate(project: root, category: category, scope: f.affectedPaths, title: title, of: $0) }) { o.relatedOpportunityID = dup.id }
        do { try repository.insert(o) } catch { return .ignored("could not persist") }
        note("Opportunity detected: \(o.title) [\(category.rawValue)]", .info, o)
        refresh()

        return await act(on: o, outcome: outcome)
    }

    // MARK: Acting on a decision (idempotent; also used by launch reconciliation)

    func act(on opp: OpportunityRecord, outcome: PolicyOutcome) async -> IngestResult {
        guard let repository else { return .ignored("no database") }
        var o = opp
        switch outcome.decision {
        case .ignore: return .ignored("ignored")
        case .record:
            o.status = .recorded; o.updatedAt = clock(); try? repository.update(o)
            note("Opportunity recorded: \(o.title)", .info, o)
            refresh()
            return .recorded(o.id)
        case .propose, .requireApproval:
            guard let action = o.proposedAction, let a = o.assessment else { return .ignored("no action") }
            let pid = Self.derivedID("proposal:\(o.id.uuidString):1")
            if (try? repository.proposal(pid)) == nil {
                let p = ProposalRecord(id: pid, opportunityID: o.id, projectRoot: o.projectRoot, title: o.title, summary: o.summary, reason: Self.reasonText(o, outcome), evidence: Self.evidenceText(o.evidence),
                                       proposedAction: action, affectedScope: o.affectedScope, risk: a.risk, designImpact: a.designImpact, reversibility: a.reversibility,
                                       expectedBenefit: action.expectedBenefit, validationPlan: action.validationPlan, actionHash: o.actionHash ?? "", critical: outcome.decision == .requireApproval, expiresAt: o.expiresAt)
                try? repository.insert(p)
                note(outcome.decision == .requireApproval ? "Approval required: \(o.title)" : "Proposal created: \(o.title)", .warning, o)
            }
            o.status = .proposed; o.updatedAt = clock(); try? repository.update(o)
            refresh()
            return .proposed(opportunity: o.id, proposal: pid)
        case .autoAction:
            o.status = .autoQueued; o.updatedAt = clock(); try? repository.update(o)
            if let tid = await startTask(for: o, origin: .proactiveAutoAction, proposalID: nil) {
                refresh()
                return .autoTask(opportunity: o.id, task: tid)
            }
            refresh()
            return .queued(o.id)
        }
    }

    // MARK: Task creation (the ONLY execution path: a normal V0.4 task; idempotent)

    /// Creates the V0.4 task for an auto-authorised or approved opportunity. Same input ⇒ same task id ⇒ never two tasks.
    func startTask(for opp: OpportunityRecord, origin: TaskOrigin, proposalID: UUID?) async -> UUID? {
        guard let repository, let action = opp.proposedAction else { return nil }
        let seed = proposalID.map { "task:proposal:\($0.uuidString)" } ?? "task:auto:\(opp.id.uuidString)"
        let tid = Self.derivedID(seed)
        let originDepth = (opp.originTaskID.flatMap { (try? repository.engineTask($0)) ?? nil })?.autonomyDepth ?? 0
        let result = await tasks.submit(goal: action.goal, kind: action.taskKind, workspacePath: opp.projectRoot, title: opp.title, id: tid, origin: origin,
                                        originTaskID: opp.originTaskID, originOpportunityID: opp.id, autonomyDepth: originDepth + 1, scope: action.scope)
        guard case .success(let id) = result else { return nil }
        var o = opp; o.status = .taskCreated; o.taskID = id; o.updatedAt = clock()
        try? repository.update(o)
        note(origin == .proactiveAutoAction ? "Auto task created: \(o.title)" : "Task created from approved proposal: \(o.title)", .success, o)
        return id
    }

    /// Launch + task-finished: finish what a crash or a full task queue left half-done (each step is idempotent).
    func retryQueued() async {
        guard let repository else { return }
        let open = (try? repository.opportunities(statuses: [.detected, .autoQueued, .approved], limit: 50)) ?? []
        for o in open {
            switch o.status {
            case .detected:
                if let d = o.policyDecision, d != .ignore { _ = await act(on: o, outcome: PolicyOutcome(decision: d, reasons: o.policyReasons)) }
            case .autoQueued:
                if (try? repository.engineTask(Self.derivedID("task:auto:\(o.id.uuidString)"))) != nil { var d = o; d.status = .taskCreated; d.taskID = Self.derivedID("task:auto:\(o.id.uuidString)"); try? repository.update(d) }
                else if o.autonomyDepth < budget.maxChainDepth, settings().mode == .lowRiskAutonomous { _ = await startTask(for: o, origin: .proactiveAutoAction, proposalID: nil) }
            case .approved:
                if let p = (try? repository.proposals(forOpportunity: o.id))?.last(where: { $0.status == .approved }) { await proposalApprovedNeedsTask?(p) }
            default: break
            }
        }
        refresh()
    }
    /// Set by `ProposalService`: executes an approved proposal whose task has not been created yet.
    @ObservationIgnored var proposalApprovedNeedsTask: ((ProposalRecord) async -> Void)?

    /// Launch reconciliation: pending proposals stay pending, expired ones expire, half-done decisions finish exactly once.
    func reconcileOnLaunch() async {
        guard let repository else { return }
        let now = clock()
        for var p in (try? repository.proposals(statuses: [.pending])) ?? [] where (p.expiresAt ?? .distantFuture) < now {
            p.status = .expired; p.decidedAt = now; try? repository.update(p)
            if var o = (try? repository.opportunity(p.opportunityID)) ?? nil { o.status = .expired; o.cooldownUntil = now.addingTimeInterval(dismissCooldown); try? repository.update(o) }
            note("Proposal expired: \(p.title)", .info, nil)
        }
        await retryQueued()
        refresh()
    }

    // MARK: Scope expansion (an approved/auto task needed more than it was allowed)

    private func handleScopeExceeded(_ t: TaskRecord) async {
        guard let repository, t.state == .failed, t.failureCategory == .scopeExceeded, let oid = t.originOpportunityID, var o = (try? repository.opportunity(oid)) ?? nil else { return }
        o.status = .needsReapproval; o.updatedAt = clock(); try? repository.update(o)
        for var p in (try? repository.proposals(forOpportunity: oid)) ?? [] where p.status == .executed || p.status == .approved {
            p.status = .expired; p.decidedAt = clock(); try? repository.update(p)
        }
        note("The work needed more than the approved scope — nothing beyond it was executed; a new decision is required: \(o.title)", .warning, o)
        refresh()
    }

    // MARK: Model assistance (budgeted; may only add caution)

    private func modelAssess(_ f: RawFinding, task: TaskRecord?, known: [String], assessment: OpportunityAssessment, category: OpportunityCategory) async -> (OpportunityAssessment, OpportunityCategory, [String])? {
        guard let task, let origin = f.originTaskID else { return nil }
        var profile = TaskProfile(category: .coding, complexity: .moderate, privacy: task.privacy)     // project reasoning: never the local model (policy in code)
        profile.requiresCoding = true; profile.containsProjectCode = true; profile.wantsStructuredOutput = true
        let prompt = OpportunityAssessor.modelAssessmentPrompt(f, knownFiles: known)
        profile.estimatedContextTokens = prompt.count / 4
        let job = AgentJob(type: "OpportunityAssessor", title: "Assess · \(OutputSanitizer.sanitize(String(f.title.prefix(60))))", prompt: prompt, profile: profile, taskID: origin,
                           validator: { OpportunityAssessor.parseModelAssessment($0) != nil ? BenchmarkSuite.Verdict(passed: true, detail: "") : BenchmarkSuite.Verdict(passed: false, detail: "reply with the JSON object") },
                           timeout: 240, policy: EscalationPolicy(maxRepairAttempts: 1, maxEscalations: 0, maxTotalAttempts: 2), preference: task.preference)
        let result = await tasks.agents.run(job)
        guard case .completed(let text, _, let cand, _) = result, let m = OpportunityAssessor.parseModelAssessment(text) else { return nil }
        let reason = "the finding \"\(OutputSanitizer.sanitize(String(f.title.prefix(60))))\" had no structured assessment (category unknown) — one budgeted call"
        providerCalls.append("\(cand.label): \(reason)")
        note("Proactive assessment used \(cand.label) because \(reason)", .info, nil)
        return OpportunityAssessor.mergeModelAssessment(assessment, category: category, model: m, knownFiles: known)
    }

    // MARK: Helpers

    private func materiallyDifferent(_ new: [EvidenceItem], from old: [EvidenceItem]) -> Bool {
        let oldFP = Set(old.filter(\.isDeterministic).map(Self.fingerprint))
        return new.filter(\.isDeterministic).contains { !oldFP.contains(Self.fingerprint($0)) }
    }
    private static func fingerprint(_ e: EvidenceItem) -> String { "\(e.kind.rawValue)|\(e.reference ?? "")|\(e.predicate.map { "\($0)" } ?? "")" }

    private func mergedEvidence(_ a: [EvidenceItem], _ b: [EvidenceItem]) -> [EvidenceItem] {
        var out = a; var seen = Set(a.map(Self.fingerprint))
        for e in b where seen.insert(Self.fingerprint(e)).inserted { out.append(e) }
        return Array(out.prefix(12))
    }

    func knownFiles(_ root: String?) async -> [String] {
        guard let root, let ws = try? WorkspaceGuard(rootPath: root) else { return [] }
        let tools = ProjectTools(workspace: ws, capabilities: .readOnly)
        return (try? await Task.detached { try tools.listFiles(maxFiles: 400) }.value) ?? []
    }

    /// Plain-language rendering of the machine-readable decision factors (the factors themselves stay in the database).
    static func humanReason(_ code: String) -> String? {
        if code.hasPrefix("externalEffect:") { return "it would have an effect outside the project (\(code.dropFirst(15)))" }
        if code.hasPrefix("capability:") { return "it needs a permission JARVIS never grants (\(code.dropFirst(11)))" }
        if code.hasPrefix("destructive:") { return "it would delete or replace things" }
        if code.hasPrefix("productDecision:") { return "it is a product/design decision" }
        if code.hasPrefix("scope:") { return "its scope is larger than a small, local change" }
        switch code {
        case "riskCritical": return "its risk is critical"
        case "irreversible": return "it cannot be undone"
        case "designImpact": return "it would change how the project looks or behaves"
        case "securitySensitive": return "it is security-sensitive"
        case "refactorBeyondGoal": return "it is a refactor beyond what you asked for"
        case "userIntentRequired": return "only you can decide it"
        case "adjacentScope": return "it is next to, not part of, the work you asked for"
        case "unrelatedScope": return "it is unrelated to the work you asked for"
        case "autonomyBudgetExhausted": return "JARVIS already started one automatic task for this work"
        case "autonomyChainDepth": return "automatic work never starts more automatic work"
        case "mode:askBeforeActing": return "your autonomy mode is Ask Before Acting"
        case "evidenceNotStrong": return "the evidence is not strong enough to act without asking"
        case "noConcreteAction": return "there is no concrete, bounded action yet"
        case "weakUnrelated": return "it is weakly evidenced and unrelated"
        default: return nil
        }
    }

    static func reasonText(_ o: OpportunityRecord, _ out: PolicyOutcome) -> String {
        let human = out.reasons.compactMap(humanReason)
        let list = human.isEmpty ? "" : " " + (out.decision == .requireApproval ? "It needs your explicit approval because " : "You are asked because ") + human.joined(separator: "; ") + "."
        return "JARVIS noticed this while \(o.originTaskID == nil ? "observing the project" : "working on a task")." + list
    }
    static func evidenceText(_ e: [EvidenceItem]) -> String { e.prefix(5).map { "• \($0.summary)" }.joined(separator: "\n") }

    /// Deterministic UUID from a seed (stable across restarts): the same opportunity/proposal always maps to the same task.
    static func derivedID(_ seed: String) -> UUID {
        let hex = Redactor.sha256(Data(seed.utf8))
        var bytes = [UInt8](); var i = hex.startIndex
        while bytes.count < 16, i < hex.endIndex { let j = hex.index(i, offsetBy: 2); bytes.append(UInt8(hex[i..<j], radix: 16) ?? 0); i = j }
        bytes[6] = (bytes[6] & 0x0F) | 0x50; bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    func note(_ message: String, _ kind: ActivityKind, _ o: OpportunityRecord?) {
        audit.activity(kind.rawValue, message, taskID: o?.originTaskID)
        onEvent?(message, kind)
    }

    func opportunity(_ id: UUID) -> OpportunityRecord? { (try? repository?.opportunity(id)) ?? nil }
    func proposals(for opportunityID: UUID) -> [ProposalRecord] { (try? repository?.proposals(forOpportunity: opportunityID)) ?? [] }
    /// Open items for the Dashboard summary.
    var summary: (proposals: Int, findings: Int) { (pending.count, recorded.count) }

    func refresh() {
        guard let repository else { return }
        pending = (try? repository.proposals(statuses: [.pending], limit: 50)) ?? []
        recorded = (try? repository.opportunities(statuses: [.recorded], limit: 40)) ?? []
        revision += 1
        onChange?()
    }
}
