import Foundation

// MARK: - Kinds, risk, capabilities (V0.4 — DEC-033…)

/// What the user asked for. V0.4 executes USER-INITIATED goals only (proactive work is V0.5).
enum TaskKind: String, Codable, Sendable {
    /// Inspect/analyse/review the project and report. Never writes.
    case readOnlyAnalysis
    /// Change the project (bounded, validated, leased, audited).
    case development

    var label: String { self == .development ? "Development" : "Analysis" }
}

enum RiskClass: String, Codable, Sendable, Comparable {
    case low, medium, high, critical
    private var rank: Int { switch self { case .low: 0; case .medium: 1; case .high: 2; case .critical: 3 } }
    static func < (a: RiskClass, b: RiskClass) -> Bool { a.rank < b.rank }
}

/// Task-scoped permissions. Providers get NONE of these (they only produce text); they are what JARVIS' own typed tools
/// check before touching the project. `gitCommit`/`gitPush`/`purchase`/`useNetwork`/`useBrowser` can never be granted in V0.4.
enum TaskCapability: String, Codable, Sendable, CaseIterable {
    case readProject, writeProject, runBuild, runTests, useNetwork, useBrowser, destructiveFileOperation, gitCommit, gitPush, purchase
    // V0.6 Unity (DEC-048): typed editor operations. Granted per task kind; deletion stays approval-gated; package installation,
    // project upgrades, arbitrary C# and menu items are NOT capabilities at all.
    case inspectUnity, readUnityConsole, modifyUnityScene, saveUnityScene, createUnityPrefab, runUnityCompile, runUnityTests, controlUnityPlayMode, deleteUnityObject

    static let unityInspection: Set<TaskCapability> = [.inspectUnity, .readUnityConsole]
    static let unityDevelopment: Set<TaskCapability> = [.inspectUnity, .readUnityConsole, .modifyUnityScene, .saveUnityScene, .createUnityPrefab, .runUnityCompile, .runUnityTests, .controlUnityPlayMode]
}

struct CapabilitySet: Codable, Equatable, Sendable {
    var granted: Set<TaskCapability>

    static let readOnly = CapabilitySet(granted: [.readProject])
    static let development = CapabilitySet(granted: [.readProject, .writeProject, .runBuild, .runTests])
    /// Never grantable in V0.4 (documented in DEC-034): there is no code path that could honour them.
    static let neverGranted: Set<TaskCapability> = [.useNetwork, .useBrowser, .gitCommit, .gitPush, .purchase]

    init(granted: Set<TaskCapability>) { self.granted = granted.subtracting(Self.neverGranted) }
    func allows(_ c: TaskCapability) -> Bool { granted.contains(c) }
    func allows(all cs: Set<TaskCapability>) -> Bool { cs.isSubset(of: granted) }
    static func `for`(_ kind: TaskKind) -> CapabilitySet { kind == .development ? .development : .readOnly }
    /// A Unity project adds the typed Unity operations: inspection only for analysis tasks, bounded edit/compile/test/play for development.
    static func `for`(_ kind: TaskKind, unityProject: Bool) -> CapabilitySet {
        let base = Self.for(kind)
        guard unityProject else { return base }
        return CapabilitySet(granted: base.granted.union(kind == .development ? TaskCapability.unityDevelopment : TaskCapability.unityInspection))
    }
}

// MARK: - Task state machine

enum TaskState: String, Codable, Sendable, CaseIterable {
    case created, planning, ready, running, waitingForApproval, completed, failed, cancelled, interrupted

    var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
    /// Occupies the engine (a runner exists or should exist): everything except terminal, created and interrupted.
    var isActive: Bool { [.planning, .ready, .running, .waitingForApproval].contains(self) }
    /// The user can still stop it.
    var isStoppable: Bool { !isTerminal }

    var label: String {
        switch self {
        case .created: "CREATED"; case .planning: "PLANNING"; case .ready: "READY"; case .running: "RUNNING"
        case .waitingForApproval: "AWAITING APPROVAL"; case .completed: "COMPLETED"; case .failed: "FAILED"
        case .cancelled: "STOPPED"; case .interrupted: "INTERRUPTED"
        }
    }

    /// Explicit, testable transitions. UI code never mutates task state directly — only the engine, through `TaskStateMachine`.
    var allowedNext: Set<TaskState> {
        switch self {
        case .created: [.planning, .cancelled, .failed]
        case .planning: [.ready, .failed, .cancelled, .interrupted]
        case .ready: [.running, .failed, .cancelled, .interrupted]
        case .running: [.waitingForApproval, .completed, .failed, .cancelled, .interrupted]
        case .waitingForApproval: [.running, .failed, .cancelled, .interrupted]
        case .interrupted: [.planning, .ready, .running, .failed, .cancelled]    // an explicit resume; never automatic
        case .completed, .failed, .cancelled: []
        }
    }
}

enum TaskStepState: String, Codable, Sendable, CaseIterable {
    case pending, ready, running, verifying, passed, failed, waitingForApproval, cancelled, interrupted, skipped

    var isTerminal: Bool { [.passed, .failed, .cancelled, .skipped].contains(self) }
    var isActive: Bool { self == .running || self == .verifying }
    var label: String {
        switch self {
        case .pending: "PENDING"; case .ready: "READY"; case .running: "RUNNING"; case .verifying: "VERIFYING"; case .passed: "PASSED"
        case .failed: "FAILED"; case .waitingForApproval: "APPROVAL"; case .cancelled: "STOPPED"; case .interrupted: "INTERRUPTED"; case .skipped: "SKIPPED"
        }
    }

    var allowedNext: Set<TaskStepState> {
        switch self {
        case .pending: [.ready, .skipped, .cancelled]
        case .ready: [.running, .waitingForApproval, .skipped, .cancelled, .failed]
        case .running: [.verifying, .passed, .failed, .waitingForApproval, .cancelled, .interrupted, .skipped]    // skipped: nothing to do (no such command)
        case .verifying: [.passed, .failed, .running, .cancelled, .interrupted]
        case .waitingForApproval: [.running, .ready, .failed, .cancelled, .skipped, .interrupted]
        case .interrupted: [.ready, .pending, .waitingForApproval, .failed, .cancelled, .skipped]
        case .passed, .failed, .cancelled, .skipped: []
        }
    }
}

enum ApprovalState: String, Codable, Sendable {
    case pending, approved, denied, cancelled
    var isTerminal: Bool { self != .pending }
    var allowedNext: Set<ApprovalState> { self == .pending ? [.approved, .denied, .cancelled] : [] }
}

enum LeaseState: String, Codable, Sendable {
    case active, released, stale
    var allowedNext: Set<LeaseState> { self == .active ? [.released, .stale] : [] }
}

/// The only way task/step/approval/lease state changes. Illegal transitions are rejected (never silently applied).
enum TaskStateMachine {
    static func canMove(_ from: TaskState, to: TaskState) -> Bool { from.allowedNext.contains(to) }
    static func canMove(_ from: TaskStepState, to: TaskStepState) -> Bool { from.allowedNext.contains(to) }
    static func canMove(_ from: ApprovalState, to: ApprovalState) -> Bool { from.allowedNext.contains(to) }
    static func canMove(_ from: LeaseState, to: LeaseState) -> Bool { from.allowedNext.contains(to) }
}

// MARK: - Failure categories (few, useful)

enum FailureCategory: String, Codable, Sendable {
    case providerUnavailable, providerRateLimited, providerFailed
    case toolFailed, buildFailed, testFailed, validationFailed
    case workspaceViolation, capabilityDenied, approvalDenied, resourceUnavailable
    case cancelled, interrupted, malformedPlan, securityBlocked, workspaceChanged, scopeExceeded
    // V0.6
    case unityUnavailable, ambiguousTarget, unsafeEditorState, compileFailed, unityTimeout

    var label: String {
        switch self {
        case .providerUnavailable: "provider unavailable"; case .providerRateLimited: "provider rate-limited"; case .providerFailed: "provider failed"
        case .toolFailed: "tool failed"; case .buildFailed: "build failed"; case .testFailed: "tests failed"; case .validationFailed: "validation failed"
        case .workspaceViolation: "workspace violation"; case .capabilityDenied: "capability denied"; case .approvalDenied: "approval denied"
        case .resourceUnavailable: "resources unavailable"; case .cancelled: "cancelled"; case .interrupted: "interrupted"
        case .malformedPlan: "malformed plan"; case .securityBlocked: "blocked by security policy"; case .workspaceChanged: "workspace changed unexpectedly"; case .scopeExceeded: "outside the approved scope"
        case .unityUnavailable: "Unity unavailable"; case .ambiguousTarget: "ambiguous target"; case .unsafeEditorState: "unsafe editor state"
        case .compileFailed: "Unity compilation failed"; case .unityTimeout: "Unity timed out"
        }
    }
}

// MARK: - Steps

/// What a step does. Each type has ONE executor, a required capability set and a deterministic default validation.
enum StepType: String, Codable, Sendable, CaseIterable {
    case analysis, codeChange, build, test, review, delete
    // V0.6 Unity steps (DEC-048): typed, deterministic, executed by JARVIS' Unity tool layer (the provider only proposes edit actions).
    case unityInspect, unityEdit, unityCompile, unityTest, unityPlayMode, unityValidate

    /// Short phrase for the Compact HUD while a Unity step is the current one.
    var unityActivity: String? {
        switch self {
        case .unityInspect, .unityValidate: "Unity · Inspecting"; case .unityEdit: "Unity · Editing"; case .unityCompile: "Unity · Compiling"
        case .unityTest: "Unity · Testing"; case .unityPlayMode: "Unity · Play Mode"; default: nil
        }
    }

    var isUnity: Bool { switch self { case .unityInspect, .unityEdit, .unityCompile, .unityTest, .unityPlayMode, .unityValidate: true; default: false } }

    var requiredCapabilities: Set<TaskCapability> {
        switch self {
        case .analysis, .review: [.readProject]
        case .codeChange: [.readProject, .writeProject]
        case .build: [.runBuild]
        case .test: [.runTests]
        case .delete: [.readProject, .writeProject, .destructiveFileOperation]
        case .unityInspect: [.inspectUnity]
        case .unityEdit: [.inspectUnity, .modifyUnityScene, .saveUnityScene]
        case .unityCompile: [.runUnityCompile, .readUnityConsole]
        case .unityTest: [.runUnityTests]
        case .unityPlayMode: [.controlUnityPlayMode, .inspectUnity, .readUnityConsole]
        case .unityValidate: [.inspectUnity, .readUnityConsole]
        }
    }
    /// Provider-executed (an agent run with a model) vs. deterministic JARVIS tool.
    var usesProvider: Bool { self == .analysis || self == .codeChange || self == .review }
    var agentType: String {
        switch self {
        case .analysis: "AnalysisAgent"; case .codeChange: "CodingAgent"; case .review: "ReviewAgent"
        case .build: "BuildTool"; case .test: "TestTool"; case .delete: "FileTool"
        case .unityInspect, .unityEdit, .unityCompile, .unityTest, .unityPlayMode, .unityValidate: "UnityTool"
        }
    }
    var defaultRisk: RiskClass { self == .delete ? .high : (self == .codeChange || self == .unityEdit) ? .medium : .low }
    /// Safe to repeat after an interruption without inspecting the world first.
    var idempotency: Idempotency {
        switch self {
        case .analysis, .review, .build, .test: .retryable
        case .codeChange, .unityEdit: .inspectFirst
        case .delete: .manual
        case .unityInspect, .unityCompile, .unityTest, .unityPlayMode, .unityValidate: .retryable
        }
    }
    var label: String {
        switch self {
        case .analysis: "Analysis"; case .codeChange: "Code change"; case .build: "Build"; case .test: "Test"; case .review: "Review"; case .delete: "Delete"
        case .unityInspect: "Unity inspect"; case .unityEdit: "Unity edit"; case .unityCompile: "Unity compile"; case .unityTest: "Unity tests"
        case .unityPlayMode: "Unity Play Mode"; case .unityValidate: "Unity validation"
        }
    }
}

enum Idempotency: String, Codable, Sendable {
    case retryable      // read/search/build/test
    case inspectFirst   // writes: look at the current state before repeating
    case manual         // delete / external: never replayed automatically
}

/// How a step's result is checked. Deterministic wherever possible; an LLM verdict only for `reviewPass` and the schema of agent output.
enum ValidationKind: String, Codable, Sendable, CaseIterable {
    case structuredResult      // the agent's answer parsed against its schema
    case changedFiles          // ≥1 edit applied inside the workspace, hashes recorded
    case buildPass             // real build exit status
    case testPass              // real test exit status == 0
    case testEvidence          // a test run happened and its outcome was recorded (reproduction); pass or fail
    case reviewPass            // the review verdict is pass
    case fileRemoved           // the file no longer exists inside the workspace
    // V0.6: deterministic Unity facts (the editor's own state, never a model's opinion).
    case unityInspected        // the requested objects/state were read from the editor
    case unityState            // the required object/component/property state holds in the editor
    case unityCompiled         // Unity's compiler state is clean (and no new compiler errors)
    case unityTestsPass        // the requested Unity tests ran and all passed
    case unityPlayObserved     // Play Mode was really entered, observed and left, with no new errors

    static func allowed(for type: StepType) -> Set<ValidationKind> {
        switch type {
        case .analysis: [.structuredResult]
        case .codeChange: [.changedFiles]
        case .build: [.buildPass]
        case .test: [.testPass, .testEvidence]
        case .review: [.reviewPass]
        case .delete: [.fileRemoved]
        case .unityInspect: [.unityInspected]
        case .unityEdit, .unityValidate: [.unityState]
        case .unityCompile: [.unityCompiled]
        case .unityTest: [.unityTestsPass]
        case .unityPlayMode: [.unityPlayObserved]
        }
    }
    static func `default`(for type: StepType) -> ValidationKind {
        switch type {
        case .analysis: .structuredResult; case .codeChange: .changedFiles; case .build: .buildPass
        case .test: .testPass; case .review: .reviewPass; case .delete: .fileRemoved
        case .unityInspect: .unityInspected; case .unityEdit, .unityValidate: .unityState; case .unityCompile: .unityCompiled
        case .unityTest: .unityTestsPass; case .unityPlayMode: .unityPlayObserved
        }
    }
    /// Plain-language aliases an LLM planner may use (the examples in the product spec) → the real validation.
    static func parse(_ raw: String?, for type: StepType) -> ValidationKind? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return .default(for: type) }
        if let k = ValidationKind(rawValue: raw) ?? ValidationKind.allCases.first(where: { $0.rawValue.lowercased() == raw }) { return k }
        switch raw {
        case "inspectioncomplete", "rootcauseevidence", "analysiscomplete", "inspected", "structured": return .structuredResult
        case "reproductionevidence", "reproduced", "testrun": return .testEvidence
        case "buildpassed", "compiles", "build": return .buildPass
        case "testspass", "testspassed", "tests": return .testPass
        case "reviewpassed", "review": return .reviewPass
        case "changedfile", "filechanged", "diff": return .changedFiles
        default: return nil
        }
    }
}

// MARK: - Records

struct GitBaseline: Codable, Equatable, Sendable {
    var isRepository: Bool
    var branch: String?
    var head: String?
    /// Paths with uncommitted changes BEFORE JARVIS touched anything (the user's own work).
    var dirtyPaths: [String]
    var untrackedPaths: [String]
    var capturedAt: Date
}

struct TaskRecord: Equatable, Sendable, Identifiable {
    var id: UUID
    var title: String
    var goal: String                         // bounded, redacted
    var kind: TaskKind
    var category: TaskCategory = .coding
    var state: TaskState = .created
    var risk: RiskClass = .low
    var privacy: PrivacyLevel = .normal
    var workspaceRoot: String?
    var projectID: UUID?
    var createdAt = Date()
    var startedAt: Date?
    var updatedAt = Date()
    var finishedAt: Date?
    var currentStepKey: String?
    var activity: String = ""
    var progressFraction: Double?
    var progressSource: ProgressSource = .unknown
    var constraints: [String] = []
    var failureCategory: FailureCategory?
    var failureReason: String?
    var cancelRequested = false
    var recovery: String?
    var planVersion = 0
    var capabilities: CapabilitySet = .readOnly
    var gitBaseline: GitBaseline?
    var reportArtifactID: UUID?
    var checkpointArtifactID: UUID?
    var summary: String?
    /// Accumulated active run time (survives restarts; `runningSince` is memory only).
    var accumulatedSeconds: TimeInterval = 0
    var preference: ProviderPreference?
    /// The USER's goal explicitly asks to remove things: only then may a plan contain `delete` steps (each still needs its own approval).
    var destructiveRequested = false
    /// V0.5: who started this task and under which scope (nil scope = a user task: the user's goal is the scope).
    var origin: TaskOrigin = .userTask
    var originTaskID: UUID?
    var originOpportunityID: UUID?
    var autonomyDepth = 0
    var scope: TaskScope?

    var isTerminal: Bool { state.isTerminal }
}

struct TaskStepRecord: Equatable, Sendable, Identifiable {
    var id: UUID
    var taskID: UUID
    var index: Int
    var key: String                          // planner id: "s1"
    var title: String
    var details: String = ""
    var type: StepType
    var dependsOn: [String] = []
    var expected: String = ""
    var validation: ValidationKind
    var risk: RiskClass = .low
    var weight: Double = 1
    var state: TaskStepState = .pending
    var attempts = 0
    var agentRunID: UUID?
    var resultSummary: String?
    var failureCategory: FailureCategory?
    var failureReason: String?
    var startedAt: Date?
    var finishedAt: Date?
    var validationEvidence: String?
    /// V0.6: typed parameters of a Unity step (nil for every other step type).
    var unity: UnityStepParams?
    var idempotency: Idempotency { type.idempotency }
}

/// `recheck` = the same build/test command run again after a repair (the repair itself is the `repair`/`escalation` attempt of the code step).
enum AttemptKind: String, Codable, Sendable { case primary, repair, escalation, recheck }

struct StepAttemptRecord: Equatable, Sendable, Identifiable {
    var id = UUID()
    var stepID: UUID
    var taskID: UUID
    var number: Int
    var kind: AttemptKind
    var engine: ProviderID?
    var model: String?
    var agentRunID: UUID?
    var outcome: String                      // "passed" | "failed:<category>" | "cancelled" | "interrupted"
    var evidence: String?                    // bounded, sanitized
    var startedAt = Date()
    var finishedAt: Date?
}

struct ApprovalRecord: Equatable, Sendable, Identifiable {
    var id: UUID
    var taskID: UUID
    var stepID: UUID?
    var action: String                       // "delete path/to/file", "modify file with uncommitted changes: x"
    var reason: String
    var risk: RiskClass
    var state: ApprovalState = .pending
    var requestedAt = Date()
    var decidedAt: Date?
    var decidedBy: String?
    var kind: String = "task-action"
    /// V0.5: a proposal approval (kind "proposal") is bound to exactly one proposal and the hash of its action+scope.
    var proposalID: UUID?
    var scopeHash: String?
}

struct FileLeaseRecord: Equatable, Sendable {
    var path: String                         // workspace-relative
    var taskID: UUID
    var stepID: UUID?
    var owner: String                        // agent run id or "step:<id>" — who may write
    var acquiredAt = Date()
    var state: LeaseState = .active
}

/// What changed on disk because of a task step (also mirrored into `file_changes` for the audit trail).
struct TaskFileChange: Codable, Equatable, Sendable {
    var path: String
    var changeType: String                   // created | modified | deleted
    var beforeHash: String?
    var afterHash: String?
    var stepKey: String
    var preexistingUserChange: Bool
}
