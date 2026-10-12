import Foundation

// MARK: - Types

/// What a memory is about. Deliberately small (DEC-104): relationships are a separate table, not a type.
enum MemoryType: String, Codable, CaseIterable, Sendable {
    case projectFact, decision, constraint, preference, episode, failure, lesson, researchFinding, assetDecision, architecture, workflow, knownIssue, validationResult, other

    var label: String {
        switch self {
        case .projectFact: "Project fact"; case .decision: "Decision"; case .constraint: "Constraint"; case .preference: "Preference"; case .episode: "Episode"
        case .failure: "Failure"; case .lesson: "Lesson"; case .researchFinding: "Research finding"; case .assetDecision: "Asset decision"; case .architecture: "Architecture"
        case .workflow: "Workflow"; case .knownIssue: "Known issue"; case .validationResult: "Validation result"; case .other: "Other"
        }
    }

    /// Types that describe HOW the project must be treated: they are surfaced before background material.
    var isNormative: Bool { self == .constraint || self == .decision || self == .architecture || self == .preference }

    /// Per-type staleness (DEC-111). nil = a historical fact that does not age (a past failure stays a past failure). A fact with a `key` that a probe can check is
    /// re-checked against current truth instead of aged.
    var defaultStaleAfter: TimeInterval? {
        switch self {
        case .projectFact: 14 * 86_400
        case .researchFinding: 86_400            // price / availability style claims
        case .knownIssue: 30 * 86_400
        case .validationResult: 7 * 86_400
        default: nil
        }
    }
}

enum MemoryStatus: String, Codable, CaseIterable, Sendable {
    case current, stale, superseded, disputed, unverified, archived, forgotten

    var label: String { rawValue.uppercased() }
    /// Usable in normal (current-state) retrieval — possibly with a visible caveat.
    var isLive: Bool { self == .current || self == .stale || self == .disputed || self == .unverified }
    /// Only reachable when the question is historical.
    var isHistorical: Bool { self == .superseded || self == .archived }
}

/// Interpretable evidence strength (never a fake percentage). Ordered weakest → strongest.
enum MemoryStrength: Int, Codable, CaseIterable, Comparable, Sendable {
    case inferred = 0, weak, supported, strong, authoritative
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    var label: String { ["INFERRED", "WEAK", "SUPPORTED", "STRONG", "AUTHORITATIVE"][rawValue] }
}

enum MemoryImportance: Int, Codable, CaseIterable, Comparable, Sendable {
    case low = 0, normal, high, critical
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    var label: String { ["LOW", "NORMAL", "HIGH", "CRITICAL"][rawValue] }
}

/// task-local statements ("use this model for this task") are never durable project memory.
enum MemoryScope: String, Codable, Sendable { case project, taskLocal }

/// Where a memory item came from, as a CLASS of origin (the exact evidence is in `MemorySource`).
enum MemoryOrigin: String, Codable, Sendable {
    case inspection      // deterministic read of current project state (files, Git, Unity descriptor)
    case document        // a repository document (DECISIONS.md, KNOWN_ISSUES.md, AGENTS.md …)
    case task            // a finished V0.4 task (report, failure, file changes)
    case research        // validated V0.9 claims / candidates / decisions
    case user            // explicit user statement (remember / correct)
    case model           // proposed by a model: never authoritative on its own
    case bootstrap       // the bounded import of existing project history
    case consolidation   // derived from several other memories

    var isModel: Bool { self == .model }
}

// MARK: - Sources (provenance)

enum MemorySourceKind: String, Codable, Sendable {
    case task, taskStep, agentRun, fileChange, gitCommit, decisionDoc, document, researchSession, researchClaim, researchCandidate, acquisition, importTask
    case unityInspection, projectInspection, testResult, conversationTurn, userStatement, correction, memory
}

struct MemorySource: Codable, Equatable, Hashable, Sendable {
    var kind: MemorySourceKind
    var ref: String                  // id / path / hash — what a person can look up
    var label: String                // human text ("DEC-094", "Task: Fix calculator", "docs/WEB_RESEARCH.md")
    var locator: String? = nil       // anchor inside the source (line, heading)
    var observedAt = Date()
    /// Does this source EXIST in a system that was independently verified (task/DB/doc/inspection) as opposed to being text a model or a web page produced?
    var isVerifiable: Bool { ![.conversationTurn].contains(kind) }
}

// MARK: - Item

struct MemoryItem: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var projectKey: String
    var type: MemoryType
    var subject: String                       // the topic in 1–4 words ("camera", "web research browser")
    var key: String? = nil                    // structured key for facts a probe can check or that conflict by value ("unity.version", "decision:DEC-094")
    var value: String? = nil                  // the value under `key`
    var summary: String                       // ≤ 400 chars, sanitized
    var details: String? = nil                // ≤ 1,500 chars: rationale, alternatives, consequences
    var status: MemoryStatus = .current
    var strength: MemoryStrength = .supported
    var importance: MemoryImportance = .normal
    var scope: MemoryScope = .project
    var area: String? = nil                   // subsystem ("camera", "voice", "research", "hud")
    var tags: [String] = []
    var origin: MemoryOrigin
    var createdAt = Date()
    var updatedAt = Date()
    var validFrom = Date()
    var lastVerifiedAt: Date? = nil
    var expiresAt: Date? = nil
    var supersededBy: UUID? = nil
    var pinned = false
    var userCorrected = false
    /// Price / licence / availability style content: must be re-verified before it is used for an action.
    var currentSensitive = false
    var language = "en"
    var extractionVersion = MemoryConstants.extractionVersion
    var canonicalHash: String = ""
    var forgottenAt: Date? = nil
    var sources: [MemorySource] = []
    var relations: [MemoryRelation] = []

    var isLive: Bool { status.isLive }
}

struct MemoryRelation: Codable, Equatable, Hashable, Sendable {
    /// supersedes · contradicts · corrects · affects · caused_by · rejected_because · uses · modifies · derived_from · about
    var predicate: String
    var targetKind: String                    // "memory" | "entity"
    var target: String                        // memory id, or "area:camera", "file:Assets/…", "task:<id>"
}

enum MemoryConstants {
    static let schemaVersion = 1
    static let extractionVersion = 1
    static let maxSummary = 400
    static let maxDetails = 1_500
    static let maxTags = 8
}

// MARK: - Candidates (what ingestion proposes; nothing is persisted without passing the curator)

struct MemoryCandidate: Sendable {
    var type: MemoryType
    var subject: String
    var key: String? = nil
    var value: String? = nil
    var summary: String
    var details: String? = nil
    var strength: MemoryStrength = .supported
    var importance: MemoryImportance = .normal
    var scope: MemoryScope = .project
    var area: String? = nil
    var tags: [String] = []
    var origin: MemoryOrigin
    var sources: [MemorySource] = []
    var relations: [MemoryRelation] = []
    var currentSensitive = false
    var validFrom = Date()
    var lastVerifiedAt: Date? = nil
    var pinned = false
    var userCorrected = false
    /// For a model-proposed candidate: the model that proposed it (recorded in the source list as a non-verifiable source).
    var proposedBy: String? = nil
}

enum MemoryRejection: Equatable, Sendable, CustomStringConvertible {
    case empty, trivial, secret, webInjection, authorityGrant, taskLocal, noProvenance, modelOnly, tooLong, disabled, forgotten, unverifiedResearch, conflictsCurrent(String)

    var description: String {
        switch self {
        case .empty: "nothing worth remembering"
        case .trivial: "too trivial to remember"
        case .secret: "contains something that looks like a credential"
        case .webInjection: "text from the web that tries to instruct the assistant"
        case .authorityGrant: "memory cannot grant approvals or weaken security"
        case .taskLocal: "only relevant to a single task, not durable project memory"
        case .noProvenance: "no verifiable source"
        case .modelOnly: "a model's guess without supporting evidence"
        case .tooLong: "too long"
        case .disabled: "Project Memory is turned off"
        case .forgotten: "the user forgot a memory with the same content"
        case .unverifiedResearch: "research that was not verified by the research pipeline"
        case .conflictsCurrent(let key): "it contradicts the project's current state (\(key)); current project files win over memory"
        }
    }
}

enum AdmitResult: Equatable, Sendable {
    case created(UUID)
    case merged(UUID)                         // duplicate: sources/verification folded into the existing item
    case superseded(new: UUID, old: [UUID])   // newer or stronger information replaced older current memory
    case disputed(new: UUID, with: [UUID])    // unresolved conflict: both stay visible, flagged
    case rejected(MemoryRejection)

    var itemID: UUID? {
        switch self {
        case .created(let id), .merged(let id): id
        case .superseded(let id, _), .disputed(let id, _): id
        case .rejected: nil
        }
    }
    var isRejected: Bool { if case .rejected = self { true } else { false } }
}

// MARK: - Events (bounded diagnostics / observability)

struct MemoryEvent: Equatable, Sendable, Identifiable {
    var id: Int64 = 0
    var at = Date()
    var projectKey: String
    var kind: String                          // proposed · accepted · merged · superseded · disputed · rejected · corrected · forgotten · pinned · stale · retrieved · context · revalidated · embedded · bootstrap
    var memoryID: UUID?
    var detail: String
}
