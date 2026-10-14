import Foundation

// MARK: - Adaptive learning (V0.14, DEC-215…)
//
// LEARNING != AUTHORITY. Everything in this file is DATA: a candidate says "repeated evidence suggests this change"; it never approves, grants a capability,
// weakens a policy or runs anything. Memory (V0.10) answers "what do we know?"; learning answers "what does repeated evidence suggest we should change?".

enum LearningKind: String, Codable, Sendable, CaseIterable {
    case lesson, rule, preference, workflow, routingAdjustment, capabilityGap, mcpRecommendation, skillRecommendation, sourceCodeImprovement, knownLimitation

    var label: String {
        switch self {
        case .lesson: "Lesson"; case .rule: "Rule"; case .preference: "Preference"; case .workflow: "Workflow"; case .routingAdjustment: "Routing"
        case .capabilityGap: "Capability gap"; case .mcpRecommendation: "MCP recommendation"; case .skillRecommendation: "Skill recommendation"
        case .sourceCodeImprovement: "JARVIS improvement"; case .knownLimitation: "Known limitation"
        }
    }
    /// Kinds that change nothing when active: they are shown, never applied.
    var isInformational: Bool { self == .lesson || self == .knownLimitation || self == .capabilityGap }
}

/// Explicit states. A candidate never moves silently from CANDIDATE to ACTIVE: behaviour-changing kinds pass VALIDATED → PROPOSED → APPROVED first.
enum LearningStatus: String, Codable, Sendable, CaseIterable {
    case observed, candidate, testing, validated, proposed, approved, active, rejected, superseded, disabled, retired

    var label: String { rawValue.uppercased() }
    var isTerminal: Bool { self == .rejected || self == .superseded || self == .retired }
    var allowedNext: Set<LearningStatus> {
        switch self {
        case .observed: [.candidate, .rejected, .retired]
        case .candidate: [.testing, .validated, .proposed, .rejected, .superseded, .retired]
        case .testing: [.validated, .candidate, .rejected]
        case .validated: [.proposed, .rejected, .superseded, .retired]
        case .proposed: [.approved, .rejected, .superseded]
        case .approved: [.active, .rejected]
        case .active: [.disabled, .retired, .superseded]
        case .disabled: [.active, .retired]
        case .rejected, .superseded, .retired: []
        }
    }
    func canMove(to next: LearningStatus) -> Bool { allowedNext.contains(next) }
}

struct LearningScope: Codable, Equatable, Hashable, Sendable {
    enum Level: String, Codable, Sendable, CaseIterable { case project, capability, workflow, global
        /// Narrower scopes outrank wider ones for the same project (current truth and security policy outrank every scope).
        var specificity: Int { switch self { case .project: 3; case .capability: 2; case .workflow: 1; case .global: 0 } }
    }
    var level: Level
    var key: String?
    static let global = LearningScope(level: .global, key: nil)
    static func project(_ key: String) -> LearningScope { LearningScope(level: .project, key: key) }
    static func capability(_ key: String) -> LearningScope { LearningScope(level: .capability, key: key) }
    static func workflow(_ key: String) -> LearningScope { LearningScope(level: .workflow, key: key) }
    var label: String { level == .global ? "everywhere" : "\(level.rawValue): \(key ?? "?")" }
    /// Does a rule of this scope apply to the given situation?
    func applies(project: String?, capability: String?, workflow: String?) -> Bool {
        switch level {
        case .global: true
        case .project: key != nil && key == project
        case .capability: key != nil && key == capability
        case .workflow: key != nil && key == workflow
        }
    }
}

enum LearningEvidenceKind: String, Codable, Sendable, CaseIterable {
    case task, run, step, experiment, research, correction, benchmark, git, unityReadback, computerResult, memory, mcpActivity, proposal, assetEvaluation, signal, request
}

/// A link to something that EXISTS. An unresolvable link is refused at admission ("no unsupported ‘I learned that…’ records").
struct LearningEvidenceRef: Codable, Equatable, Hashable, Sendable {
    var kind: LearningEvidenceKind
    var sourceID: String
    var at: Date
    var note: String
}

struct LearningCandidate: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var fingerprint: String
    var kind: LearningKind
    var status: LearningStatus
    var title: String
    var summary: String
    var scope: LearningScope
    var projectKey: String?
    var confidence: Double
    var risk: RiskClass
    var occurrenceCount: Int
    var evidence: [LearningEvidenceRef]
    var proposedEffect: String
    var validationRequirement: String
    var promotionRequirement: String
    var payload: LearningPayload
    var rejectionReason: String?
    var supersededBy: UUID?
    var createdAt = Date()
    var lastSeenAt = Date()
    var updatedAt = Date()
    var decidedBy: String?
    var decidedAt: Date?
    /// A rejected candidate is not proposed again before this moment unless the evidence at least doubles.
    var cooldownUntil: Date?
    /// The evidence count that was current when it was rejected (the “materially changed” comparison).
    var evidenceAtRejection: Int?

    var sourceTaskIDs: [UUID] { evidence.filter { $0.kind == .task }.compactMap { UUID(uuidString: $0.sourceID) } }
    var sourceRunIDs: [UUID] { evidence.filter { $0.kind == .run }.compactMap { UUID(uuidString: $0.sourceID) } }
    var sourceExperimentIDs: [UUID] { evidence.filter { $0.kind == .experiment }.compactMap { UUID(uuidString: $0.sourceID) } }
    var sourceMemoryIDs: [String] { evidence.filter { $0.kind == .memory }.map(\.sourceID) }
}

/// The typed content of a candidate. Rules are STRUCTURED DATA from a closed vocabulary; nothing here is executable.
struct LearningPayload: Codable, Equatable, Sendable {
    var lesson: String?
    var rule: RuleDefinition?
    var workflow: WorkflowTemplate?
    var routing: RoutingAdjustment?
    var gap: CapabilityGapDetail?
    var improvement: ImprovementDraft?
    var recommendation: CapabilityRecommendation?

    static func lesson(_ s: String) -> LearningPayload { LearningPayload(lesson: s) }
    static func rule(_ r: RuleDefinition) -> LearningPayload { LearningPayload(rule: r) }
}

// MARK: Signals (persisted, derived from existing records — idempotent)

enum SignalKind: String, Codable, Sendable, CaseIterable {
    case taskFailed, taskCancelled, taskRepaired, taskEscalated, stepFailed, reviewFinding
    case unityCorrection, assetIncompatible, assetCompatible, researchSourceFailed, researchSourceOK
    case computerVisionFallback, computerAccessibilitySuccess, computerAccessibilityInsufficient, computerAppDiscovery
    case userCorrection, proposalApproved, proposalRejected, workflowSucceeded
    case providerFailed, providerSucceeded, slowPath, manualIntervention, unsupportedOperation
    case experimentRefuted, experimentConfirmed, resourcePressure
    case mcpFailed, mcpSucceeded, capabilityUnavailable
}

struct LearningSignal: Codable, Equatable, Sendable, Identifiable {
    enum Outcome: String, Codable, Sendable { case failure, success, event }
    var id = UUID()
    var kind: SignalKind
    /// The normalised situation (e.g. "toolFailed|development", "app=com.blender|vision"). Two signals with the same key describe the same thing.
    var key: String
    var projectKey: String?
    var sourceKind: LearningEvidenceKind
    var sourceID: String
    /// The unit of independence: everything that happened inside one task / session / experiment is ONE episode (a retry loop is one event, not five).
    var episode: String
    var at: Date
    var outcome: Outcome
    var detail: String
}

// MARK: Rules — a CLOSED vocabulary

/// Facts a rule may look at. Every value is a short token from the situation, never free text.
enum RuleFactKey: String, Codable, Sendable, CaseIterable {
    case projectKind, taskKind, stepType, agentRole, capability, assetFormat, assetSource, assetCompatibility, renderPipeline, application, failureCategory, goalIntent
}
enum RuleComparison: String, Codable, Sendable, CaseIterable { case equals, notEquals, isUnknown }

struct RuleCondition: Codable, Equatable, Hashable, Sendable {
    var fact: RuleFactKey
    var comparison: RuleComparison
    var value: String?
}

/// What a rule may DO. There is deliberately no action that approves, grants, installs, deletes, sends, buys, runs a command, removes an approval or weakens a
/// sandbox — the set below is exhaustive and `RuleActionKind.allCases` is pinned by a unit test and a `verify.sh` guard.
enum RuleActionKind: String, Codable, Sendable, CaseIterable {
    case requireExperiment, requireExtraValidation, requireIndependentReview, preferWorkflow, avoidSource, addWarning, preferCapability
}

struct RuleAction: Codable, Equatable, Hashable, Sendable {
    var kind: RuleActionKind
    var argument: String?
}

struct RuleDefinition: Codable, Equatable, Hashable, Sendable {
    var when: [RuleCondition]
    var then: [RuleAction]
    var version = 1
}

/// What the rules said about one situation. Effects only ADD requirements: they can never remove an approval, a check or a restriction.
struct RuleEffects: Equatable, Sendable {
    var requiredExperiments: [String] = []
    var extraValidations: [String] = []
    var independentReviewRequired = false
    var preferredWorkflows: [String] = []
    var avoidedSources: [String] = []
    var warnings: [String] = []
    var preferredCapabilities: [String] = []
    var firedRuleIDs: [UUID] = []
    var isEmpty: Bool { firedRuleIDs.isEmpty }
}

struct LearnedRule: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var candidateID: UUID?
    var scope: LearningScope
    var projectKey: String?
    var version: Int
    var status: LearningStatus                 // active · disabled · retired
    var definition: RuleDefinition
    var title: String
    var origin: String
    var activatedAt: Date?
    var lastUsedAt: Date?
    var successCount = 0
    var failureCount = 0
    var previousVersion: Int?
    var createdAt = Date()
    /// success / (success + failure) once there is any outcome; nil before.
    var effectiveness: Double? { let n = successCount + failureCount; return n == 0 ? nil : Double(successCount) / Double(n) }
}

// MARK: Routing, gaps, improvements, recommendations

/// A bounded nudge to a role/provider preference score. It cannot override an explicit user choice, price, privacy, local-only or security restrictions.
struct RoutingAdjustment: Codable, Equatable, Sendable {
    var role: String
    var provider: String
    /// −RoutingAdjustment.limit … +limit
    var delta: Double
    static let limit = 0.2
    var clamped: Double { min(Self.limit, max(-Self.limit, delta)) }
}

struct CapabilityGapDetail: Codable, Equatable, Sendable {
    var domain: String
    var observation: String
    var currentMechanism: String
    var occurrences: Int
    /// Which architecture compares best: native extension · MCP · CLI · browser integration · learned Skill · source improvement (never “install this”).
    var options: [GapOption]
}
struct GapOption: Codable, Equatable, Sendable {
    var architecture: String
    var rationale: String
    var rank: Int
}

struct CapabilityRecommendation: Codable, Equatable, Sendable {
    var serverID: String?
    var name: String
    var reason: String
}

struct ImprovementDraft: Codable, Equatable, Sendable {
    var problem: String
    var evidenceSummary: String
    var proposedChange: String
    var expectedBenefit: String
    var risk: String
    var validationPlan: String
    var rollback: String
    var affectedArea: String
}

// MARK: Workflows

struct WorkflowNode: Codable, Equatable, Hashable, Sendable {
    var key: String
    var title: String
    var type: StepType
    var dependsOn: [String]
    var optional: Bool
}

struct WorkflowTemplate: Codable, Equatable, Hashable, Sendable {
    var nodes: [WorkflowNode]
    /// Step types in order — the signature a repeated pattern is matched on.
    var signature: String { nodes.map { $0.type.rawValue }.joined(separator: ">") }
}

// MARK: Adaptive requests (approval boundary — decided from HUD buttons only)

enum AdaptiveRequestKind: String, Codable, Sendable, CaseIterable {
    case promoteCandidate, activateRule, activateSkill, installCapability, updateCapability, removeCapability, enableCapability, selfImprovement
    var label: String {
        switch self {
        case .promoteCandidate: "Promote a learning candidate"; case .activateRule: "Activate a rule"; case .activateSkill: "Activate a skill"
        case .installCapability: "Register a capability"; case .updateCapability: "Update a capability"; case .removeCapability: "Remove a capability"
        case .enableCapability: "Enable a capability"; case .selfImprovement: "Apply an improvement to JARVIS"
        }
    }
    /// Destructive requests can never be satisfied by anything but the HUD button, and they re-check ownership and activity at execution.
    var isDestructive: Bool { self == .removeCapability }
}

enum AdaptiveRequestStatus: String, Codable, Sendable { case pending, approved, denied, cancelled, executed, failed
    var isTerminal: Bool { self != .pending && self != .approved }
}

struct AdaptiveRequest: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var kind: AdaptiveRequestKind
    var subjectID: String
    /// Binds the decision to exactly what was shown: if the subject changed afterwards the hash no longer matches and the approval is refused.
    var scopeHash: String
    var summary: String
    var detail: String
    var risk: RiskClass
    var status: AdaptiveRequestStatus = .pending
    var requestedAt = Date()
    var decidedAt: Date?
    var decidedBy: String?
    var executedAt: Date?
    var result: String?
}

/// Only a real user action path may pass one of these (HUD buttons). There is no API that accepts text as a decision.
enum AdaptiveDecisionSource: String, Sendable { case hud, test }

// MARK: Skills

enum SkillStatus: String, Codable, Sendable, CaseIterable { case candidate, validated, active, disabled, retired
    var label: String { rawValue.uppercased() }
}

struct Skill: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var description: String
    var scope: LearningScope
    var version: Int
    var status: SkillStatus
    var triggerPatterns: [String]
    var requiredCapabilities: [String]
    var requiredMCPs: [String]
    var graph: WorkflowTemplate
    var approvalGates: [String]
    var validationGates: [String]
    var maxNodes: Int
    var origin: String
    var evidence: [LearningEvidenceRef]
    var successCount = 0
    var failureCount = 0
    var lastUsedAt: Date?
    var createdAt = Date()
    var builtIn = false
}

// MARK: Self-improvement

enum SelfImprovementLevel: Int, Codable, Sendable, CaseIterable, Comparable {
    case observe = 0, learn = 1, experiment = 2, propose = 3, approvedSelfImprovement = 4
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    var label: String {
        switch self {
        case .observe: "Observe"; case .learn: "Learn"; case .experiment: "Experiment"; case .propose: "Propose"; case .approvedSelfImprovement: "Approved self-improvement"
        }
    }
    var explanation: String {
        switch self {
        case .observe: "JARVIS only notices opportunities."
        case .learn: "JARVIS may create lessons, rule and workflow candidates."
        case .experiment: "JARVIS may also test low-risk candidates in disposable environments. It cannot change its own source. (default)"
        case .propose: "JARVIS may also propose changes to its own workflow, configuration and routing."
        case .approvedSelfImprovement: "After your explicit approval JARVIS may open an ordinary development task on its own source code. There is no higher level."
        }
    }
}

enum ImprovementStatus: String, Codable, Sendable { case proposed, approved, running, applied, failed, rejected, rolledBack }

struct SelfChangeCheckpoint: Codable, Equatable, Sendable {
    var gitHead: String
    var dirtyFiles: [String]
    var testsState: String
    var version: String
    var activeRuleIDs: [String]
    var activeMCPs: [String]
    var activeSkills: [String]
    var providerState: String
    var at: Date
    var isClean: Bool { dirtyFiles.isEmpty }
}

struct ImprovementProposal: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var candidateID: UUID?
    var title: String
    var draft: ImprovementDraft
    var status: ImprovementStatus = .proposed
    var checkpoint: SelfChangeCheckpoint?
    var taskID: UUID?
    var result: String?
    var createdAt = Date()
    var updatedAt = Date()
}

struct LearningAuditEntry: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var at = Date()
    var kind: String
    var subjectID: String?
    var detail: String
    var by: String
}
