import Foundation

/// What the policy knows besides the assessment (all from JARVIS' own durable records — never from a model).
struct PolicyContext: Sendable {
    var mode: AutonomyMode
    var proactiveEnabled = true
    /// The task the finding came from: only a USER task may authorise an automatic child (depth 0).
    var originAutonomyDepth = 0
    var originIsUserTask = true
    var hasOriginTask = true
    var autoTasksForOrigin = 0
    var hasProposedAction = true
    var budget = AutonomyBudget()
}

/// Deterministic policy: the ONLY place that turns an assessment into an authority level. Pure and exhaustively unit-tested.
///
/// Precedence (higher overrides lower, whatever the confidence):
///   1 CRITICAL  → requireApproval   (external effects, destructive/irreversible, critical risk, capabilities V0.4 can never grant)
///   2 DESIGN    → propose           (product/design/content/dependency decisions, security, refactors beyond the goal)
///   3 SCOPE     → propose           (non-small, adjacent/unrelated work)
///   4 LOW-RISK LOCAL MAINTENANCE → autoAction (only in Low-Risk Autonomous mode, only within budget) else propose
/// then the mode caps the result (Observe Only records, Ask Before Acting never auto-acts).
enum OpportunityPolicy {
    static let autoCategories: Set<OpportunityCategory> = [.testCoverage, .maintenance, .bug]
    static let autoCapabilities: Set<TaskCapability> = [.readProject, .writeProject, .runBuild, .runTests]

    static func decide(_ a: OpportunityAssessment, category: OpportunityCategory, context c: PolicyContext) -> PolicyOutcome {
        guard c.proactiveEnabled else { return PolicyOutcome(decision: .ignore, reasons: ["proactiveReasoningDisabled"]) }
        if a.relevance < 0.2 { return PolicyOutcome(decision: .ignore, reasons: ["lowRelevance"]) }

        var reasons: [String] = []
        var decision: PolicyDecision

        // 1. CRITICAL — never automatic, whatever the confidence.
        var critical: [String] = []
        for e in a.externalEffects.sorted(by: { $0.rawValue < $1.rawValue }) { critical.append("externalEffect:\(e.rawValue)") }
        if a.risk == .critical { critical.append("riskCritical") }
        if a.destructiveness != .none { critical.append("destructive:\(a.destructiveness.rawValue)") }
        if a.reversibility == .irreversible { critical.append("irreversible") }
        for cap in a.requiredCapabilities.intersection(CapabilitySet.neverGranted).sorted(by: { $0.rawValue < $1.rawValue }) { critical.append("capability:\(cap.rawValue)") }
        if a.requiredCapabilities.contains(.destructiveFileOperation) && !critical.contains(where: { $0.hasPrefix("destructive") }) { critical.append("capability:destructiveFileOperation") }
        if !critical.isEmpty {
            reasons = critical + ["criticalApprovalRequired"]
            decision = .requireApproval
        }
        // 1b. WEB AUTHORITY (V0.9, DEC-088): an acquisition or an import is its own decision — always the user's; web research may only ever be PROPOSED (never automatic).
        else if !a.requiredCapabilities.isDisjoint(with: [.downloadToQuarantine, .importIntoProject]) {
            reasons = ["webAcquisitionOrImport", "separateDecisionRequired"]
            decision = .requireApproval
        }
        else if a.requiredCapabilities.contains(.researchWeb) {
            reasons = ["webResearch", "proposedNeverAutomatic"]
            decision = .propose
        }
        // 2. DESIGN / PRODUCT / SECURITY
        else if a.designImpact == .meaningful || category.isProductDecision || category == .security || (category == .refactor && a.relation != .direct) {
            if a.designImpact == .meaningful { reasons.append("designImpact") }
            if category.isProductDecision { reasons.append("productDecision:\(category.rawValue)") }
            if category == .security { reasons.append("securitySensitive") }
            if category == .refactor && a.relation != .direct { reasons.append("refactorBeyondGoal") }
            reasons.append("userIntentRequired")
            decision = .propose
        }
        // 3. SCOPE
        else if a.scopeSize != .small || a.relation != .direct {
            if a.scopeSize != .small { reasons.append("scope:\(a.scopeSize.rawValue)") }
            if a.relation != .direct { reasons.append("\(a.relation.rawValue)Scope") }
            decision = a.relation == .unrelated && a.evidenceStrength < .medium ? .record : .propose
            if decision == .record { reasons.append("weakUnrelated") }
        }
        // 4. low-risk local maintenance candidate
        else {
            let eligibility = autoEligibility(a, category: category, context: c)
            if eligibility.blockers.isEmpty {
                reasons = ["directScope", "reversible", "localOnly", "nonDestructive", "noDesignImpact", "strongEvidence", "smallScope", "withinBudget"]
                decision = .autoAction
            } else {
                reasons = eligibility.blockers
                decision = (a.evidenceStrength >= .weak || a.confidence >= 0.4) ? .propose : .record
            }
        }

        // Confidence/evidence may only make the result QUIETER (propose → record). They never create authority.
        if decision == .propose, a.evidenceStrength == .none, a.confidence < 0.5 { decision = .record; reasons.append("noEvidenceLowConfidence") }

        // Mode caps the result.
        switch c.mode {
        case .observeOnly:
            if decision != .ignore && decision != .record { reasons.append("mode:observeOnly"); reasons.append("wouldBe:\(decision.rawValue)"); decision = .record }
        case .askBeforeActing:
            if decision == .autoAction { reasons.append("mode:askBeforeActing"); decision = .propose }
        case .lowRiskAutonomous: break
        }
        return PolicyOutcome(decision: decision, reasons: reasons)
    }

    /// Everything that must hold for AUTO_ACTION; `blockers` is empty only when ALL conditions hold.
    static func autoEligibility(_ a: OpportunityAssessment, category: OpportunityCategory, context c: PolicyContext) -> (blockers: [String], ok: Bool) {
        var b: [String] = []
        if c.mode != .lowRiskAutonomous { b.append("mode:\(c.mode.rawValue)") }
        if !c.hasProposedAction { b.append("noConcreteAction") }
        if !c.hasOriginTask { b.append("noOriginTask") }
        if !c.originIsUserTask || c.originAutonomyDepth >= c.budget.maxChainDepth { b.append("autonomyChainDepth") }
        if c.autoTasksForOrigin >= c.budget.maxAutoTasksPerOriginTask { b.append("autonomyBudgetExhausted") }
        if !autoCategories.contains(category) { b.append("categoryNotAutomatic:\(category.rawValue)") }
        if a.relation != .direct { b.append("notDirect") }
        if a.risk != .low { b.append("risk:\(a.risk.rawValue)") }
        if a.reversibility != .reversible { b.append("notReversible") }
        if a.destructiveness != .none { b.append("destructive") }
        if a.designImpact != .none { b.append("designImpact") }
        if !a.externalEffects.isEmpty { b.append("externalEffect") }
        if a.scopeSize != .small { b.append("scopeNotSmall") }
        if !a.requiredCapabilities.isSubset(of: autoCapabilities) { b.append("capabilityNotPermitted") }
        if a.evidenceStrength < .strong { b.append("evidenceNotStrong") }
        if a.confidence < 0.6 { b.append("lowConfidence") }
        return (b, b.isEmpty)
    }
}
