import Foundation

/// Where a decision came from. Only a REAL user action path may pass one of these; no model/provider output is ever parsed into a
/// decision (there is no API that accepts text), so "Approved." in a provider answer cannot change anything.
enum DecisionSource: String, Sendable { case hud, test }

enum ApprovalOutcome: Equatable, Sendable {
    case notPending
    case tampered                       // the stored action no longer matches what was approved (hash mismatch)
    case started(taskID: UUID)
    case queued                         // approved; the task will be created when a task slot is free
    case obsolete(String)               // the issue no longer exists: nothing was modified
    case unsupported([String])          // approval never creates a capability or an external effect V0.4 does not have
    case denied
    case dismissed
}

/// The ONLY owner of proposal decisions (approve / deny / dismiss). Approval is specific: it binds to one proposal, its action, its
/// scope, its workspace and its risk (`action_hash`), and it only authorises creating a normal V0.4 task — it never executes anything
/// itself and never bypasses planning, plan validation, capabilities, leases, validation or repair limits.
@MainActor
final class ProposalService {
    private let repository: JarvisRepository?
    private unowned let engine: OpportunityEngine
    @ObservationIgnored var clock: () -> Date = { Date() }

    init(repository: JarvisRepository?, engine: OpportunityEngine) {
        self.repository = repository; self.engine = engine
        engine.proposalApprovedNeedsTask = { [weak self] p in _ = await self?.executeApproved(p.id) }
    }

    // MARK: Decisions (called from the HUD buttons only)

    @discardableResult
    func approve(_ proposalID: UUID, source: DecisionSource) async -> ApprovalOutcome {
        guard let repository, var p = (try? repository.proposal(proposalID)) ?? nil, p.status == .pending,
              var o = (try? repository.opportunity(p.opportunityID)) ?? nil else { return .notPending }
        // Scope binding: what is approved must be exactly what was shown.
        let expected = OpportunityAssessor.actionHash(opportunityID: o.id, projectRoot: o.projectRoot, action: p.proposedAction, risk: p.risk, category: o.category)
        guard expected == p.actionHash, p.actionHash == o.actionHash else { engine.note("Approval refused: the proposal changed after it was shown (\(p.title))", .error, o); return .tampered }
        let now = clock()
        var a = ApprovalRecord(id: UUID(), taskID: o.originTaskID ?? o.id, stepID: nil, action: "Approve proposal: \(p.title)", reason: p.reason, risk: p.risk)
        a.kind = "proposal"; a.proposalID = p.id; a.scopeHash = p.actionHash; a.state = .approved; a.decidedAt = now; a.decidedBy = source.rawValue
        try? repository.insert(a)
        p.status = .approved; p.decidedAt = now; try? repository.update(p)
        o.status = .approved; o.updatedAt = now; try? repository.update(o)
        engine.note("Proposal approved: \(p.title)", .success, o)
        engine.refresh()
        return await executeApproved(p.id)
    }

    @discardableResult
    func deny(_ proposalID: UUID, source: DecisionSource) -> ApprovalOutcome { close(proposalID, status: .denied, cooldown: engine.denyCooldown, source: source) }

    @discardableResult
    func dismiss(_ proposalID: UUID, source: DecisionSource) -> ApprovalOutcome { close(proposalID, status: .dismissed, cooldown: engine.dismissCooldown, source: source) }

    private func close(_ proposalID: UUID, status: ProposalStatus, cooldown: TimeInterval, source: DecisionSource) -> ApprovalOutcome {
        guard let repository, var p = (try? repository.proposal(proposalID)) ?? nil, p.status == .pending, var o = (try? repository.opportunity(p.opportunityID)) ?? nil else { return .notPending }
        let now = clock()
        var a = ApprovalRecord(id: UUID(), taskID: o.originTaskID ?? o.id, stepID: nil, action: "\(status == .denied ? "Deny" : "Dismiss") proposal: \(p.title)", reason: p.reason, risk: p.risk)
        a.kind = "proposal"; a.proposalID = p.id; a.scopeHash = p.actionHash; a.state = .denied; a.decidedAt = now; a.decidedBy = source.rawValue
        try? repository.insert(a)
        p.status = status; p.decidedAt = now; try? repository.update(p)
        o.status = status == .denied ? .denied : .dismissed; o.cooldownUntil = now.addingTimeInterval(cooldown); o.updatedAt = now; try? repository.update(o)
        engine.note("Proposal \(status == .denied ? "denied" : "dismissed"): \(p.title) (will not be proposed again for \(Int(cooldown / 86400)) day(s) unless the evidence materially changes)", .warning, o)
        engine.refresh()
        return status == .denied ? .denied : .dismissed
    }

    // MARK: Execution of an approved proposal (idempotent)

    @discardableResult
    func executeApproved(_ proposalID: UUID) async -> ApprovalOutcome {
        guard let repository, var p = (try? repository.proposal(proposalID)) ?? nil, p.status == .approved, var o = (try? repository.opportunity(p.opportunityID)) ?? nil else { return .notPending }
        let now = clock()
        // Approval does not create capabilities: V0.4 can only run what a development task is granted, never an external effect,
        // and never a deletion that the approved scope (allowDelete = false) could not cover.
        let missing = Self.unsupportedReasons(o, action: p.proposedAction)
        if !missing.isEmpty {
            p.status = .unsupported; p.decidedAt = now; try? repository.update(p)
            o.status = .unsupported; o.updatedAt = now; try? repository.update(o)
            engine.note("Approved, but JARVIS cannot do this: it needs \(missing.joined(separator: ", ")), which V0.4/V0.5 do not provide. Nothing was done: \(p.title)", .warning, o)
            engine.refresh()
            return .unsupported(missing)
        }
        // Stale evidence: the user may have fixed it already.
        if case .resolved(let why) = EvidenceRevalidator.check(o.evidence, projectRoot: o.projectRoot) {
            p.status = .obsolete; try? repository.update(p)
            o.status = .obsolete; o.cooldownUntil = now.addingTimeInterval(engine.dismissCooldown); o.updatedAt = now; try? repository.update(o)
            engine.note("Proposal is obsolete (\(why)) — nothing was modified: \(p.title)", .info, o)
            engine.refresh()
            return .obsolete(why)
        }
        guard let tid = await engine.startTask(for: o, origin: .approvedProposal, proposalID: p.id) else {
            engine.note("Approved proposal waits for a free task slot: \(p.title)", .info, o)
            return .queued
        }
        p.status = .executed; p.resultingTaskID = tid; try? repository.update(p)
        engine.refresh()
        return .started(taskID: tid)
    }

    /// What an approval could NOT make possible: capabilities V0.4 never grants, external effects, destructive actions.
    static func unsupportedReasons(_ o: OpportunityRecord, action: ProposedAction) -> [String] {
        var missing: [String] = (o.assessment?.requiredCapabilities ?? []).subtracting(CapabilitySet.for(action.taskKind).granted).map(\.rawValue)
        missing += (o.assessment?.externalEffects ?? []).map { "externalEffect:\($0.rawValue)" }
        if (o.assessment?.destructiveness ?? .none) != .none { missing.append("destructiveAction") }
        return Array(Set(missing)).sorted()
    }

    // MARK: User-initiated promotion / re-proposal

    /// A recorded finding becomes a pending proposal ONLY because the user asked for it (e.g. from the findings list).
    @discardableResult
    func promote(_ opportunityID: UUID, source: DecisionSource) -> UUID? {
        guard let repository, var o = (try? repository.opportunity(opportunityID)) ?? nil, o.status == .recorded, let action = o.proposedAction, let a = o.assessment else { return nil }
        let critical = a.risk == .critical || !a.externalEffects.isEmpty || a.destructiveness != .none
        let pid = OpportunityEngine.derivedID("proposal:\(o.id.uuidString):\(((try? repository.proposals(forOpportunity: o.id))?.count ?? 0) + 1)")
        let p = ProposalRecord(id: pid, opportunityID: o.id, projectRoot: o.projectRoot, title: o.title, summary: o.summary, reason: "You asked JARVIS to turn this recorded finding into a proposal.",
                               evidence: OpportunityEngine.evidenceText(o.evidence), proposedAction: action, affectedScope: o.affectedScope, risk: a.risk, designImpact: a.designImpact,
                               reversibility: a.reversibility, expectedBenefit: action.expectedBenefit, validationPlan: action.validationPlan, actionHash: o.actionHash ?? "", critical: critical,
                               expiresAt: clock().addingTimeInterval(engine.proposalLifetime))
        try? repository.insert(p)
        o.status = .proposed; o.updatedAt = clock(); try? repository.update(o)
        engine.note("Proposal created from a recorded finding: \(o.title)", .info, o)
        engine.refresh()
        return pid
    }

    /// After a scope-exceeded stop: a NEW pending proposal for the same opportunity (the user decides again; nothing runs meanwhile).
    @discardableResult
    func repropose(_ opportunityID: UUID, source: DecisionSource) -> UUID? {
        guard let repository, var o = (try? repository.opportunity(opportunityID)) ?? nil, o.status == .needsReapproval, let action = o.proposedAction, let a = o.assessment else { return nil }
        let n = ((try? repository.proposals(forOpportunity: o.id))?.count ?? 0) + 1
        let p = ProposalRecord(id: OpportunityEngine.derivedID("proposal:\(o.id.uuidString):\(n)"), opportunityID: o.id, projectRoot: o.projectRoot, title: o.title + " (new decision)", summary: o.summary,
                               reason: "A previous attempt needed more than the scope you approved, so nothing beyond it was done. Approve again only if this scope is still what you want.",
                               evidence: OpportunityEngine.evidenceText(o.evidence), proposedAction: action, affectedScope: o.affectedScope, risk: a.risk, designImpact: a.designImpact,
                               reversibility: a.reversibility, expectedBenefit: action.expectedBenefit, validationPlan: action.validationPlan, actionHash: o.actionHash ?? "", critical: false,
                               expiresAt: clock().addingTimeInterval(engine.proposalLifetime))
        try? repository.insert(p)
        o.status = .proposed; o.updatedAt = clock(); try? repository.update(o)
        engine.refresh()
        return p.id
    }
}
