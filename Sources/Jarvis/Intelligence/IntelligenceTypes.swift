import Foundation

// MARK: - Task description (input to routing)

enum PrivacyLevel: String, Codable, Sendable, Comparable {
    case publicData, normal, sensitive
    private var rank: Int { switch self { case .publicData: 0; case .normal: 1; case .sensitive: 2 } }
    static func < (a: PrivacyLevel, b: PrivacyLevel) -> Bool { a.rank < b.rank }
}

enum Complexity: Int, Codable, Sendable, Comparable {
    case trivial = 0, simple, moderate, complex, critical
    static func < (a: Complexity, b: Complexity) -> Bool { a.rawValue < b.rawValue }
}

enum TaskCategory: String, CaseIterable, Codable, Sendable {
    // lightweight
    case conversation, classification, extraction, summarization, formatting, stateRendering
    // general / research
    case explanation, research
    // development
    case coding, testing, review, debugging, repositoryModification
    // heavy
    case architecture, security
}

/// Everything the router may base a decision on. Built by `TaskClassifier` (conversation) or by the caller (agents,
/// benchmarks). The `requires…` flags are what `LocalModelPolicy` forbids on the local model.
struct TaskProfile: Equatable, Codable, Sendable {
    var category: TaskCategory = .conversation
    var complexity: Complexity = .simple
    var privacy: PrivacyLevel = .normal
    var requiresCoding = false
    var requiresTesting = false
    var requiresRepositoryModification = false
    var requiresTechnicalReview = false
    var requiresComplexReasoning = false
    var requiresTools = false
    var containsProjectCode = false
    var wantsStructuredOutput = false
    var estimatedContextTokens = 0
    /// e.g. "unity", "multiplayer", "swift", "security"
    var domainTags: Set<String> = []

    /// Benchmark group a model must have passed to serve this profile automatically.
    var benchmarkGroup: BenchmarkGroup {
        if requiresTesting || category == .testing { return .testing }
        if requiresCoding || requiresRepositoryModification || [.coding, .debugging, .review].contains(category) { return .coding }
        if category == .research { return .research }
        return .general
    }

    /// Needs the engine to be strong at technical work (development tasks).
    var isDevelopment: Bool {
        requiresCoding || requiresTesting || requiresRepositoryModification || requiresTechnicalReview
            || [.coding, .testing, .review, .debugging, .repositoryModification, .architecture, .security].contains(category)
    }
}

enum BenchmarkGroup: String, CaseIterable, Codable, Sendable { case general, research, coding, testing }

// MARK: - Model registry

/// What is KNOWN about a model's price. Only `.verifiedZero` can ever become FREE; `.unknown` is never routed
/// automatically and `.paid` is blocked (DEC-022).
enum PricingStatus: String, Codable, Sendable { case verifiedZero, paid, unknown }

enum ModelAvailability: String, Codable, Sendable { case available, unavailable, unknown }

/// Documented data handling of a hosted free model (OpenCode Zen docs). Anything not documented is `.unknown`.
enum DataPolicy: String, Codable, Sendable {
    case zeroRetention        // documented: zero retention, no training
    case mayTrain             // documented: prompts may be used to improve the model
    case trialLogged          // documented: trial, usage logged, no confidential data
    case unknown
}

enum BenchmarkStatus: String, Codable, Sendable { case none, partial, passed, failed }

struct ModelCapabilities: Codable, Equatable, Sendable {
    var supportsCoding = false
    var supportsReasoning = false
    var supportsTools = false
    var supportsStreaming = false
    var supportsStructuredOutput = false
}

struct ModelRecord: Equatable, Sendable {
    var id: String                       // "opencode/big-pickle"
    var engine: ProviderID
    var provider: String                 // "opencode"
    var providerModelID: String          // "big-pickle"
    var displayName: String
    var availability: ModelAvailability = .unknown
    var pricingStatus: PricingStatus = .unknown
    var inputPrice: Double?              // USD / 1M tokens, from provider metadata
    var outputPrice: Double?
    var freeVerified = false
    var freeVerifiedAt: Date?
    var freeVerificationSource: String?
    var capabilities = ModelCapabilities()
    var dataPolicy: DataPolicy = .unknown
    var contextLimit: Int?
    var benchmarkStatus: BenchmarkStatus = .none
    var lastHealthCheck: Date?
    var lastSuccessfulRun: Date?
    var enabled = true
    var blockedReason: String?
    var updatedAt = Date()

    /// The ONLY gate for "may JARVIS use this as a free cloud model": verified zero price + available + enabled.
    var isFreePoolMember: Bool {
        freeVerified && pricingStatus == .verifiedZero && availability == .available && enabled && blockedReason == nil
    }
}

// MARK: - Agent runs / audit

enum AgentRunStatus: String, Codable, Sendable { case queued, running, succeeded, failed, cancelled, escalated }
enum ValidationStatus: String, Codable, Sendable { case notRun, passed, failed, skipped }

struct AgentRunRecord: Equatable, Sendable {
    var id: UUID
    var taskID: UUID?
    var parentAgentRunID: UUID?
    var agentType: String
    var engine: ProviderID
    var model: String?
    var selectionReason: String?          // JSON (RoutingDecision.reasonJSON)
    var privacy: PrivacyLevel = .normal
    var startedAt: Date
    var finishedAt: Date?
    var status: AgentRunStatus = .queued
    var toolsUsed: [String] = []
    var filesRead: [String] = []
    var filesChanged: [String] = []
    var validationStatus: ValidationStatus = .notRun
    var resultSummary: String?
    var retryCount = 0
    var escalatedFrom: String?
    var escalatedTo: String?
    var errorCategory: String?
    var promptHash: String?
    var promptChars: Int?
    var inputTokens: Int?
    var outputTokens: Int?
    var costClass: CostClass { engine.costClass }
}

struct ToolExecutionRecord: Equatable, Sendable {
    var id = UUID()
    var agentRunID: UUID
    var tool: String
    var summary: String?
    var status: String
    var startedAt = Date()
    var finishedAt: Date?
    var exitCode: Int?
}

struct FileChangeRecord: Equatable, Sendable {
    var id = UUID()
    var taskID: UUID?
    var agentRunID: UUID?
    var path: String
    var changeType: String               // created | modified | deleted | renamed
    var gitHash: String?
    var gitCommit: String?
    var diffArtifactID: UUID?
    var verificationResult: String?
    var changedAt = Date()
}

struct BenchmarkResultRecord: Equatable, Sendable {
    var modelID: String
    var suite: String
    var caseID: String
    var category: BenchmarkGroup
    var passed: Bool
    var validation: String?
    var latencyMS: Double?               // time to first output
    var durationMS: Double?
    var retries = 0
    var malformed = false
    var cancelled = false
    var ranAt = Date()
    var artifactID: UUID?
}

struct ProviderHealthRecord: Equatable, Sendable {
    var engine: ProviderID
    var subject: String                  // model id, or "" for the engine itself
    var consecutiveFailures = 0
    var totalFailures = 0
    var lastFailureAt: Date?
    var lastErrorCategory: String?
    var cooldownUntil: Date?
    var lastSuccessAt: Date?
}
