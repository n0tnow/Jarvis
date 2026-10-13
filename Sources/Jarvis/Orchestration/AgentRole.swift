import Foundation

// MARK: - V0.12 Multi-agent orchestration — roles and contracts (DEC-157…)
//
// An AGENT is a ROLE; a MODEL is an execution engine. JARVIS (the TaskEngine + this layer) is the orchestrator: it owns the task, the plan, the authority, the
// capabilities, the memory, the validation, the retry/escalation budget and the report. A role is a bounded contract — which step types it may be given, which
// capabilities those need, which ones it can NEVER hold, how much context it gets, how often it may be retried. No role holds a universal tool, no role can
// create another role, and nothing a role writes (text, artifacts, handoffs) can widen anyone's authority.

enum AgentRole: String, Codable, Sendable, CaseIterable {
    case analysis, coding, research, unity, computer, qa, review

    var label: String {
        switch self {
        case .analysis: "Analysis"; case .coding: "Coding"; case .research: "Research"; case .unity: "Unity"
        case .computer: "Computer"; case .qa: "QA"; case .review: "Review"
        }
    }
    /// Observatory `agent_runs.agent_type` for model-backed work of this role (tool-backed steps keep their V0.4 names).
    var agentType: String {
        switch self {
        case .analysis: "AnalysisAgent"; case .coding: "CodingAgent"; case .research: "ResearchAgent"; case .unity: "UnityAgent"
        case .computer: "ComputerAgent"; case .qa: "QAAgent"; case .review: "ReviewAgent"
        }
    }
    /// Spoken/short status noun in Turkish and English ("the test agent", "test ajanı").
    func noun(_ l: ReplyLanguage) -> String {
        switch (self, l) {
        case (.analysis, .tr): "analiz ajanı"; case (.coding, .tr): "kod ajanı"; case (.research, .tr): "araştırma ajanı"; case (.unity, .tr): "Unity ajanı"
        case (.computer, .tr): "bilgisayar ajanı"; case (.qa, .tr): "test ajanı"; case (.review, .tr): "inceleme ajanı"
        case (.analysis, _): "analysis agent"; case (.coding, _): "coding agent"; case (.research, _): "research agent"; case (.unity, _): "Unity agent"
        case (.computer, _): "computer agent"; case (.qa, _): "QA agent"; case (.review, _): "review agent"
        }
    }
}

extension AgentRole {
    /// The role name for an Observatory run ("CodingAgent" → "Coding", "TestTool" → "QA"); other types (Planner, Benchmark…) keep their own name.
    static func displayName(forAgentType t: String) -> String {
        switch t {
        case "AnalysisAgent": "Analysis"; case "CodingAgent": "Coding"; case "ResearchAgent": "Research"; case "UnityAgent", "UnityTool": "Unity"
        case "ComputerAgent": "Computer"; case "ReviewAgent": "Review"; case "QAAgent", "TestTool", "BuildTool": "QA"; case "PlannerAgent": "Planner"
        default: t
        }
    }
}

/// How heavy running a node of this role is for the machine (drives the concurrency policy and the resource scheduler).
enum ResourceClass: String, Codable, Sendable {
    case modelLight      // a read-only model call (analysis, research synthesis): may overlap with another light node
    case modelHeavy      // a model call that edits (coding) or judges (review): runs alone
    case tool            // a deterministic local process (build, tests): runs alone (it reads what the writers produced)
    case editor          // the Unity editor (exclusive: one mutation lock)
    case gui             // the user's screen (exclusive: one target at a time)
    case delegated       // a child task (research): overlaps with read-only work only
}

/// Which retry/escalation budget a node of this role has. All bounded; nothing here is a loop.
struct RetryBudget: Equatable, Sendable {
    /// Re-asks on the SAME engine after a validation failure (engine-level format repair).
    var repairAttempts: Int
    /// Hand-overs to another engine (Auto only).
    var escalations: Int
    /// Hard cap on step attempts (primary + repair + escalation + recheck).
    var maxAttempts: Int
    /// Hard cap on provider invocations for ONE node over its whole life (each attempt may need one format re-ask).
    var maxProviderInvocations: Int
}

/// The strict contract of a role. `allowedCapabilities` is the UNION of what its step types need; `forbiddenCapabilities` can never be present in a node of this
/// role whatever the plan says. The orchestrator checks this at plan time AND again right before a node starts (a handoff is data, never a grant).
struct AgentContract: Equatable, Sendable {
    var role: AgentRole
    var stepTypes: Set<StepType>
    var allowedCapabilities: Set<TaskCapability>
    var forbiddenCapabilities: Set<TaskCapability>
    var outputSchema: String
    var validations: Set<ValidationKind>
    var resource: ResourceClass
    /// May this role change anything on disk / in an editor / on the screen?
    var mutates: Bool
    var retry: RetryBudget
    /// Bounded context profile (characters of upstream material, memory items, artifacts, files). Measured per node.
    var context: ContextBudget
    /// Plain-language statement of the authority scope (shown in diagnostics and the docs).
    var authority: String
    /// Only an Auto-routed model may be chosen freely; roles that must not be served by the local model say so (LocalModelPolicy still decides in code).
    var modelBacked: Bool
}

struct ContextBudget: Equatable, Sendable {
    var maxChars: Int
    var maxMemoryItems: Int
    var maxArtifacts: Int
    var maxFiles: Int
}

enum AgentContracts {
    /// Capabilities NO role may ever hold (no code path honours them): kept in one place so a guard can assert it.
    static let neverGranted: Set<TaskCapability> = CapabilitySet.neverGranted
    private static let projectWrite: Set<TaskCapability> = [.writeProject, .destructiveFileOperation, .importIntoProject]
    private static let unityMutation: Set<TaskCapability> = [.modifyUnityScene, .saveUnityScene, .createUnityPrefab, .controlUnityPlayMode, .deleteUnityObject, .editUnityAssets, .runExperiment]

    static func contract(_ role: AgentRole) -> AgentContract {
        switch role {
        case .analysis:
            return AgentContract(role: role, stepTypes: [.analysis], allowedCapabilities: [.readProject], forbiddenCapabilities: neverGranted.union(projectWrite).union(unityMutation).union([.researchWeb, .controlComputer, .runBuild, .runTests]),
                                 outputSchema: "AnalysisResult {summary, findings[], relevantFiles[], rootCause}", validations: [.structuredResult], resource: .modelLight, mutates: false,
                                 retry: RetryBudget(repairAttempts: 1, escalations: 1, maxAttempts: 3, maxProviderInvocations: 4),
                                 context: ContextBudget(maxChars: 36_000, maxMemoryItems: 5, maxArtifacts: 3, maxFiles: 6),
                                 authority: "Reads project files that JARVIS selects for it. Cannot write, run commands, browse or operate the Mac.", modelBacked: true)
        case .coding:
            return AgentContract(role: role, stepTypes: [.codeChange, .delete], allowedCapabilities: [.readProject, .writeProject, .destructiveFileOperation], forbiddenCapabilities: neverGranted.union([.researchWeb, .downloadToQuarantine, .importIntoProject, .controlComputer, .captureWindow]).union(unityMutation),
                                 outputSchema: "SEARCH/REPLACE edit blocks (JARVIS validates and applies them)", validations: [.changedFiles, .fileRemoved], resource: .modelHeavy, mutates: true,
                                 retry: RetryBudget(repairAttempts: 1, escalations: 1, maxAttempts: 3, maxProviderInvocations: 4),
                                 context: ContextBudget(maxChars: 50_000, maxMemoryItems: 6, maxArtifacts: 4, maxFiles: 7),
                                 authority: "Proposes edits to files inside the task workspace. JARVIS applies them (capability, workspace guard, dirty-file approval, write lease, hash check). Deleting needs a per-action approval.", modelBacked: true)
        case .research:
            return AgentContract(role: role, stepTypes: [.delegateResearch, .researchSearch, .researchRead, .researchExtract, .researchVerify, .researchReport], allowedCapabilities: [.researchWeb], forbiddenCapabilities: neverGranted.union(projectWrite).union(unityMutation).union([.downloadToQuarantine, .controlComputer, .runBuild, .runTests]),
                                 outputSchema: "ResearchResult {claims[] with sources + verbatim evidence, uncertainties[], candidates[]}", validations: [.researchDelegated, .researchSearched, .researchRead, .researchExtracted, .researchVerified, .researchReported], resource: .delegated, mutates: false,
                                 retry: RetryBudget(repairAttempts: 1, escalations: 0, maxAttempts: 2, maxProviderInvocations: 3),
                                 context: ContextBudget(maxChars: 6_000, maxMemoryItems: 4, maxArtifacts: 2, maxFiles: 0),
                                 authority: "Reads the public web through the V0.9 URL-gated client in its own empty workspace. No project access, no downloads, no accounts, no purchases.", modelBacked: true)
        case .unity:
            return AgentContract(role: role, stepTypes: [.unityInspect, .unityEdit, .unityCompile, .unityTest, .unityPlayMode, .unityValidate, .experiment], allowedCapabilities: TaskCapability.unityDevelopment.union([.deleteUnityObject]), forbiddenCapabilities: neverGranted.union([.researchWeb, .controlComputer, .importIntoProject]),
                                 outputSchema: "UnityResult {operations[], editor state facts, compile/test/console evidence}", validations: [.unityInspected, .unityState, .unityCompiled, .unityTestsPass, .unityPlayObserved, .experimentConcluded], resource: .editor, mutates: true,
                                 retry: RetryBudget(repairAttempts: 1, escalations: 1, maxAttempts: 3, maxProviderInvocations: 4),
                                 context: ContextBudget(maxChars: 14_000, maxMemoryItems: 5, maxArtifacts: 3, maxFiles: 3),
                                 authority: "Typed V0.6 editor operations only (closed enum). No C#, menu item, package, shell or GUI automation.", modelBacked: false)
        case .computer:
            return AgentContract(role: role, stepTypes: [.delegateComputer, .computerAct], allowedCapabilities: [.controlComputer, .captureWindow], forbiddenCapabilities: neverGranted.union(projectWrite).union(unityMutation).union([.researchWeb, .runBuild, .runTests]),
                                 outputSchema: "ComputerResult {typed actions with observed postconditions}", validations: [.computerDelegated, .computerVerified], resource: .gui, mutates: true,
                                 retry: RetryBudget(repairAttempts: 0, escalations: 0, maxAttempts: 1, maxProviderInvocations: 0),
                                 context: ContextBudget(maxChars: 1_800, maxMemoryItems: 5, maxArtifacts: 1, maxFiles: 0),
                                 authority: "Typed V0.11 actions that JARVIS' policy allows, observed → acted → verified. No shell, script, password, purchase or account action.", modelBacked: false)
        case .qa:
            return AgentContract(role: role, stepTypes: [.build, .test], allowedCapabilities: [.runBuild, .runTests], forbiddenCapabilities: neverGranted.union(projectWrite).union(unityMutation).union([.researchWeb, .controlComputer]),
                                 outputSchema: "ValidationResult {command, exit code, test counts, duration}", validations: [.buildPass, .testPass, .testEvidence], resource: .tool, mutates: false,
                                 retry: RetryBudget(repairAttempts: 0, escalations: 0, maxAttempts: 1, maxProviderInvocations: 0),
                                 context: ContextBudget(maxChars: 3_000, maxMemoryItems: 0, maxArtifacts: 0, maxFiles: 0),
                                 authority: "Runs the project's approved build/test profile (no shell) and reports the real exit status. Cannot edit sources.", modelBacked: false)
        case .review:
            return AgentContract(role: role, stepTypes: [.review], allowedCapabilities: [.readProject], forbiddenCapabilities: neverGranted.union(projectWrite).union(unityMutation).union([.researchWeb, .controlComputer, .runBuild, .runTests]),
                                 outputSchema: "ReviewResult {verdict, issues[] with file/hunk/test/decision evidence}", validations: [.reviewPass], resource: .modelHeavy, mutates: false,
                                 retry: RetryBudget(repairAttempts: 1, escalations: 1, maxAttempts: 2, maxProviderInvocations: 4),
                                 context: ContextBudget(maxChars: 18_000, maxMemoryItems: 5, maxArtifacts: 4, maxFiles: 0),
                                 authority: "Reads the final diff and the recorded evidence. Cannot write. A blocking finding must cite evidence; deterministic build/test facts outrank its opinion.", modelBacked: true)
        }
    }

    static let all: [AgentContract] = AgentRole.allCases.map(contract)

    /// The role that executes a step type; the approval gate belongs to JARVIS itself, not to any role.
    static func role(for type: StepType) -> AgentRole? {
        switch type {
        case .analysis: .analysis
        case .codeChange, .delete, .importAsset: .coding
        case .build, .test: .qa
        case .review: .review
        case .unityInspect, .unityEdit, .unityCompile, .unityTest, .unityPlayMode, .unityValidate, .experiment: .unity
        case .researchSearch, .researchRead, .researchExtract, .researchVerify, .researchReport, .acquire, .delegateResearch: .research
        case .computerAct, .delegateComputer: .computer
        case .approvalGate: nil
        }
    }

    /// Plan-time AND start-time check: the node's step type belongs to its role, its needed capabilities are inside the role's allowance, none is forbidden,
    /// and the task actually granted them. Returns the reasons (empty = allowed).
    static func violations(of type: StepType, granted: CapabilitySet) -> [String] {
        guard let role = role(for: type) else { return [] }                                  // gates need nothing
        let c = contract(role)
        // Import and acquisition belong to the V0.9 import/acquisition TASKS (their own approval path); inside a multi-agent graph they have no role contract.
        if type == .importAsset || type == .acquire { return ["\(type.rawValue) steps are separate, approval-gated tasks and are never part of an orchestrated graph"] }
        var out: [String] = []
        if !c.stepTypes.contains(type) { out.append("\(role.label) does not run \(type.rawValue) steps") }
        let needed = type.requiredCapabilities.subtracting([.destructiveFileOperation])
        if !needed.isSubset(of: c.allowedCapabilities) { out.append("\(type.rawValue) needs \(needed.subtracting(c.allowedCapabilities).map(\.rawValue).sorted().joined(separator: ", ")) outside the \(role.label) contract") }
        if !needed.isDisjoint(with: c.forbiddenCapabilities) { out.append("\(role.label) may never hold \(needed.intersection(c.forbiddenCapabilities).map(\.rawValue).sorted().joined(separator: ", "))") }
        if !granted.allows(all: needed) { out.append("the task does not grant \(needed.subtracting(granted.granted).map(\.rawValue).sorted().joined(separator: ", "))") }
        return out
    }
}

extension TaskStepRecord {
    /// The specialist role that executes this node (nil for an approval gate: approving is never an agent's job).
    var role: AgentRole? { AgentContracts.role(for: type) }
}
extension StepType {
    var role: AgentRole? { AgentContracts.role(for: self) }
}

// MARK: - Orchestration limits (one place; every one of them is a bound, none a default that can grow)

enum OrchestrationLimits {
    /// Maximum nodes in a graph (V0.4's plan limit, kept: the brief asks for 12).
    static let maxNodes = 12
    /// Structural graph revisions per task (e.g. "insert a research node"): after that JARVIS reports the uncertainty.
    static let maxRevisions = 2
    /// Delegated child tasks (research / computer) one graph may start.
    static let maxDelegates = 3
    /// Agents running at once on this machine (a MacBook Air with 16 GB): two read-only nodes at most, ONE under any pressure.
    static let maxParallel = 2
    /// Delegation depth: orchestrator → specialist. A specialist never creates nodes or agents.
    static let maxDepth = 1
    /// Review → repair cycles after the first review (writer → critic loops are not endless).
    static let maxReviewCycles = 1
    /// Characters of a model's text kept in an artifact / handoff (sanitized first).
    static let maxArtifactChars = 6_000
    static let maxHandoffChars = 9_000
    /// Wall-clock bounds.
    static let planningTimeout: TimeInterval = 600
    static let nodeTimeout: TimeInterval = 900
    static let graphTimeout: TimeInterval = 4 * 3600
}
