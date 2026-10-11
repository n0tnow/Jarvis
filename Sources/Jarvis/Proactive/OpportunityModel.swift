import Foundation

// MARK: - Vocabulary (V0.5 — DEC-041…)

enum OpportunityOrigin: String, Codable, Sendable {
    case taskFinding, validationFinding, reviewFinding, testFinding, buildFinding, analysisFinding, userDeferredIdea, systemMaintenance
}

/// Descriptive only: a category NEVER grants authority (the policy engine does that).
enum OpportunityCategory: String, Codable, Sendable, CaseIterable {
    case bug, testCoverage, maintenance, refactor, performance, security, documentation, design, gameplay, asset, dependency, configuration

    var label: String {
        switch self {
        case .bug: "Bug"; case .testCoverage: "Test coverage"; case .maintenance: "Maintenance"; case .refactor: "Refactor"; case .performance: "Performance"
        case .security: "Security"; case .documentation: "Documentation"; case .design: "Design"; case .gameplay: "Gameplay"; case .asset: "Asset"
        case .dependency: "Dependency"; case .configuration: "Configuration"
        }
    }
    /// Product/design/content decisions belong to the user, whatever the confidence.
    var isProductDecision: Bool { [.design, .gameplay, .asset, .dependency].contains(self) }
}

enum ScopeRelation: String, Codable, Sendable { case direct, adjacent, unrelated }
enum ScopeSize: String, Codable, Sendable, Comparable {
    case small, medium, broad
    private var rank: Int { switch self { case .small: 0; case .medium: 1; case .broad: 2 } }
    static func < (a: ScopeSize, b: ScopeSize) -> Bool { a.rank < b.rank }
    /// ≤2 files small, ≤5 medium, more (or unknown-wide) broad.
    static func of(fileCount: Int) -> ScopeSize { fileCount <= 2 ? .small : fileCount <= 5 ? .medium : .broad }
}
enum Reversibility: String, Codable, Sendable { case reversible, partiallyReversible, irreversible }
enum Destructiveness: String, Codable, Sendable { case none, limited, significant }
enum DesignImpact: String, Codable, Sendable { case none, meaningful }
enum EvidenceStrength: Int, Codable, Sendable, Comparable {
    case none = 0, weak, medium, strong
    static func < (a: EvidenceStrength, b: EvidenceStrength) -> Bool { a.rawValue < b.rawValue }
}

/// Effects outside the project folder (or on someone else): never part of an automatic action in V0.5.
enum ExternalEffect: String, Codable, Sendable, CaseIterable {
    case purchase, paidProvider, credentialChange, accountChange, gitPush, deployment, production, networkMutation, upload, message, permissionChange
}

// MARK: - Evidence

/// A machine-checkable claim ("the issue is still present"), so a stale proposal can be detected before anything is executed.
enum EvidencePredicate: Codable, Equatable, Sendable {
    case fileContains(path: String, text: String)      // the issue exists while this text is present
    case fileLacks(path: String, text: String)         // the issue exists while this text is absent (e.g. no test for X yet)
    case fileExists(path: String)
    case fileMissing(path: String)
}

enum EvidenceKind: String, Codable, Sendable {
    case taskResult          // deterministic: recorded by JARVIS from a finished task (changed files, validation results)
    case validationOutput    // deterministic: build/test output captured by JARVIS
    case fileReference       // deterministic: a path that exists in the workspace
    case reviewClaim         // a model's review statement (a claim, not proof)
    case modelClaim          // a model's idea without anything checkable
}

struct EvidenceItem: Codable, Equatable, Sendable {
    var kind: EvidenceKind
    var summary: String                  // bounded + sanitized
    var reference: String?               // workspace-relative path, when there is one
    var predicate: EvidencePredicate?

    static let maxSummary = 280

    init(kind: EvidenceKind, summary: String, reference: String? = nil, predicate: EvidencePredicate? = nil) {
        self.kind = kind
        self.summary = OutputSanitizer.sanitize(String(summary.prefix(Self.maxSummary)))
        self.reference = reference.map { OutputSanitizer.sanitize(String($0.prefix(240))) }
        self.predicate = predicate
    }
    var isDeterministic: Bool { [.taskResult, .validationOutput, .fileReference].contains(kind) }
}

// MARK: - Proposed action (what a V0.4 task would do if approved)

struct ProposedAction: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case addRegressionTest, fixIssue, maintenance, refactor, other }
    var kind: Kind
    /// The goal handed to the V0.4 task (bounded, sanitized). The task still plans, validates and executes by itself.
    var goal: String
    var expectedFiles: [String]
    var scope: TaskScope
    var validationPlan: String
    var expectedBenefit: String
    var taskKind: TaskKind = .development
}

// MARK: - Assessment (structured fields; confidence is EVIDENCE, never authority)

struct OpportunityAssessment: Codable, Equatable, Sendable {
    var relevance: Double
    var confidence: Double
    var scopeSize: ScopeSize
    var affectedFileCount: Int
    var relation: ScopeRelation
    var risk: RiskClass
    var reversibility: Reversibility
    var destructiveness: Destructiveness
    var designImpact: DesignImpact
    var externalEffects: Set<ExternalEffect>
    var requiredCapabilities: Set<TaskCapability>
    var evidenceStrength: EvidenceStrength
    /// True when a model contributed to this assessment (it can only have made it MORE cautious).
    var modelAssisted = false
}

// MARK: - Policy

enum PolicyDecision: String, Codable, Sendable {
    case ignore, record, autoAction, propose, requireApproval
    var label: String {
        switch self { case .ignore: "IGNORE"; case .record: "RECORD"; case .autoAction: "AUTO ACTION"; case .propose: "PROPOSE"; case .requireApproval: "REQUIRES APPROVAL" }
    }
}

enum AutonomyMode: String, Codable, Sendable, CaseIterable {
    case observeOnly, askBeforeActing, lowRiskAutonomous

    var label: String {
        switch self { case .observeOnly: "Observe Only"; case .askBeforeActing: "Ask Before Acting"; case .lowRiskAutonomous: "Low-Risk Autonomous" }
    }
    var explanation: String {
        switch self {
        case .observeOnly: "JARVIS records what it notices. It does not interrupt you with proposals and never starts anything by itself."
        case .askBeforeActing: "JARVIS records findings and shows proposals. Nothing happens until you approve it. (Default)"
        case .lowRiskAutonomous: "JARVIS may run small, reversible, local maintenance tasks when policy allows (one per task of yours). Design changes and critical actions still need your approval."
        }
    }
}

struct PolicyOutcome: Equatable, Sendable {
    var decision: PolicyDecision
    /// Concise machine-readable decision factors (never model reasoning).
    var reasons: [String]
}

struct AutonomyBudget: Equatable, Sendable {
    var maxAutoTasksPerOriginTask = 1
    var maxChainDepth = 1
    var maxAutoChangedFiles = 2
    var maxAutoSteps = 8
    var assessorCallsPerOriginTask = 1
}

// MARK: - Statuses

enum OpportunityStatus: String, Codable, Sendable {
    case detected          // persisted, not yet decided (crash window)
    case recorded          // kept as a finding (no proposal)
    case proposed          // a pending proposal exists
    case autoQueued        // policy authorised an automatic task; not created yet (capacity/crash window)
    case approved          // the user approved; task not created yet (capacity/crash window)
    case taskCreated       // exactly one V0.4 task exists for it
    case denied, dismissed, obsolete, expired
    case unsupported       // approved, but V0.4 has no capability for it (approval never creates a capability)
    case needsReapproval   // the generated work exceeded the approved scope

    var isOpen: Bool { [.detected, .recorded, .proposed, .autoQueued, .approved, .needsReapproval].contains(self) }
    var isClosedByUser: Bool { self == .denied || self == .dismissed }
}

enum ProposalStatus: String, Codable, Sendable {
    case pending, approved, denied, dismissed, expired, obsolete, executed, unsupported
    var isTerminal: Bool { self != .pending && self != .approved }
}

// MARK: - Records

struct OpportunityRecord: Equatable, Sendable, Identifiable {
    var id: UUID
    var projectRoot: String
    var origin: OpportunityOrigin
    var originTaskID: UUID?
    var originStepID: UUID?
    var originRunID: UUID?
    var title: String
    var summary: String
    var category: OpportunityCategory
    var evidence: [EvidenceItem]
    var affectedScope: [String]
    var assessment: OpportunityAssessment?
    var policyDecision: PolicyDecision?
    var policyReasons: [String] = []
    var status: OpportunityStatus = .detected
    var createdAt = Date()
    var updatedAt = Date()
    var expiresAt: Date?
    var dedupKey: String
    var relatedOpportunityID: UUID?
    var occurrences = 1
    var cooldownUntil: Date?
    var autonomyDepth = 0
    var proposedAction: ProposedAction?
    var actionHash: String?
    var taskID: UUID?
    var sourceEvent: String?

    var risk: RiskClass { assessment?.risk ?? .low }
}

struct ProposalRecord: Equatable, Sendable, Identifiable {
    var id: UUID
    var opportunityID: UUID
    var projectRoot: String
    var title: String
    var summary: String
    var reason: String
    var evidence: String
    var proposedAction: ProposedAction
    var affectedScope: [String]
    var risk: RiskClass
    var designImpact: DesignImpact
    var reversibility: Reversibility
    var expectedBenefit: String
    var validationPlan: String
    var actionHash: String
    var critical: Bool
    var status: ProposalStatus = .pending
    var createdAt = Date()
    var decidedAt: Date?
    var resultingTaskID: UUID?
    var expiresAt: Date?
}

/// What a finding looks like when it enters the engine (structured; produced by JARVIS code from task results, or parsed from a
/// model's JSON with unknown/authority-bearing fields ignored). A finding can ASK for capabilities; it cannot grant any.
struct RawFinding: Sendable {
    var origin: OpportunityOrigin
    var title: String
    var summary: String
    var category: OpportunityCategory?
    var evidence: [EvidenceItem]
    var affectedPaths: [String]
    var originTaskID: UUID?
    var originStepID: UUID?
    var originRunID: UUID?
    var projectRoot: String
    var claimedDesignImpact: Bool = false
    var claimedConfidence: Double?
    var requestedCapabilities: Set<TaskCapability> = []
    var claimedExternalEffects: Set<ExternalEffect> = []
    var proposedAction: ProposedAction?
    /// Free text from a model/user without enough structure for deterministic assessment → the (budgeted) assessor may add caution.
    var needsModelAssessment = false
    /// Stable id of the delivering event, so re-delivery of the same event never creates a second opportunity.
    var eventKey: String?
}
