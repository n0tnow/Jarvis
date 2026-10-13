import Foundation

// MARK: - The task graph (V0.12, DEC-158…)
//
// The graph is NOT a second plan format: it is the persisted V0.4 plan (`task_steps` + `dependsOn`) seen through the orchestrator's eyes — a bounded DAG whose nodes
// carry a role, an optional flag and (for delegates / gates) typed parameters. This file is pure: derive the graph, validate it, ask which nodes may start, derive
// the task outcome. Execution stays in the TaskEngine.

struct GraphNode: Equatable, Sendable, Identifiable {
    var key: String
    var title: String
    var type: StepType
    var dependsOn: [String]
    var optional: Bool
    var revision: Int
    var delegate: DelegateParams?
    var id: String { key }
    var role: AgentRole? { type.role }
    var mutates: Bool { type == .codeChange || type == .delete || type == .unityEdit || type == .computerAct || type == .delegateComputer || type == .importAsset }
}

struct TaskGraph: Equatable, Sendable {
    var nodes: [GraphNode]

    init(nodes: [GraphNode]) { self.nodes = nodes }
    init(plan: TaskPlan, revision: Int = 0) {
        nodes = plan.steps.map { GraphNode(key: $0.id, title: $0.title, type: $0.type, dependsOn: $0.dependsOn, optional: $0.optional, revision: revision, delegate: $0.delegate) }
    }
    init(steps: [TaskStepRecord]) {
        nodes = steps.map { GraphNode(key: $0.key, title: $0.title, type: $0.type, dependsOn: $0.dependsOn, optional: $0.optional, revision: $0.revision, delegate: $0.delegate) }
    }

    func node(_ key: String) -> GraphNode? { nodes.first { $0.key == key } }
    var roles: [AgentRole] { var seen = Set<AgentRole>(); return nodes.compactMap { $0.role }.filter { seen.insert($0).inserted } }

    /// All transitive dependencies of `key` (not including itself).
    func ancestors(of key: String) -> Set<String> {
        var seen = Set<String>(), stack = node(key)?.dependsOn ?? []
        while let k = stack.popLast() { guard seen.insert(k).inserted, let n = node(k) else { continue }; stack += n.dependsOn }
        return seen
    }
    func isOrdered(_ a: String, _ b: String) -> Bool { ancestors(of: a).contains(b) || ancestors(of: b).contains(a) }

    /// Topological levels: level 0 has no dependencies; nodes of the same level are the ONLY candidates for running side by side.
    func levels() -> [[String]] {
        var depth: [String: Int] = [:]
        func d(_ k: String, _ guardCount: Int = 0) -> Int {
            if let v = depth[k] { return v }
            guard guardCount < 64, let n = node(k) else { return 0 }
            let v = (n.dependsOn.map { d($0, guardCount + 1) + 1 }.max() ?? 0)
            depth[k] = v; return v
        }
        for n in nodes { _ = d(n.key) }
        let maxLevel = depth.values.max() ?? 0
        return (0...maxLevel).map { l in nodes.filter { depth[$0.key] == l }.map(\.key) }.filter { !$0.isEmpty }
    }

    /// The nodes that could start now given which nodes are finished (a failed OPTIONAL dependency counts as finished: its branch simply has no result).
    func frontier(done: Set<String>, started: Set<String>) -> [GraphNode] {
        nodes.filter { !done.contains($0.key) && !started.contains($0.key) && $0.dependsOn.allSatisfy(done.contains) }
    }
}

// MARK: - Validation

enum GraphIssue: Equatable, Sendable, CustomStringConvertible {
    case tooManyNodes(Int)
    case roleViolation(node: String, why: String)
    case tooManyDelegates(Int)
    case delegateWithoutGoal(node: String)
    case delegateGoalRefused(node: String, why: String)
    case gateWithoutAction(node: String)
    case gateGuardsNothing(node: String)
    case optionalNotAllowed(node: String, type: StepType)
    case unorderedWriters(a: String, b: String)
    case testBeforeChange(node: String, change: String)
    case reviewWithoutChange(node: String)
    case reviewBeforeValidation(node: String)
    case revisionLimit(Int)
    case duplicateRole(node: String)

    var description: String {
        switch self {
        case .tooManyNodes(let n): "the graph has \(n) nodes (maximum \(OrchestrationLimits.maxNodes))"
        case .roleViolation(let n, let why): "node \(n): \(why)"
        case .tooManyDelegates(let n): "the graph delegates \(n) child tasks (maximum \(OrchestrationLimits.maxDelegates))"
        case .delegateWithoutGoal(let n): "node \(n): a delegated node needs a goal"
        case .delegateGoalRefused(let n, let why): "node \(n): the delegated goal is refused (\(why))"
        case .gateWithoutAction(let n): "node \(n): an approval gate names the action it guards"
        case .gateGuardsNothing(let n): "node \(n): an approval gate must guard at least one later node"
        case .optionalNotAllowed(let n, let t): "node \(n): \(t.rawValue) nodes cannot be optional"
        case .unorderedWriters(let a, let b): "nodes \(a) and \(b) both change things but are not ordered by a dependency"
        case .testBeforeChange(let n, let c): "node \(n) validates a change but does not depend on \(c)"
        case .reviewWithoutChange(let n): "node \(n): a review needs the change it reviews as a dependency"
        case .reviewBeforeValidation(let n): "node \(n): a review must come after the build/test validation of the change"
        case .revisionLimit(let n): "graph revision \(n) exceeds the limit of \(OrchestrationLimits.maxRevisions)"
        case .duplicateRole(let n): "node \(n): duplicate"
        }
    }
    /// A policy block (no re-wording fixes it) as opposed to a structural flaw the planner can repair.
    var isPolicyBlock: Bool {
        switch self {
        case .roleViolation, .delegateGoalRefused, .tooManyDelegates, .optionalNotAllowed: true
        default: false
        }
    }
}

enum GraphValidator {
    /// Node types that may be optional (their failure ends the task PARTIAL): knowledge-gathering branches only. Anything that changes, validates or judges the result is required.
    static let optionalAllowed: Set<StepType> = [.delegateResearch, .analysis, .delegateComputer]

    /// Structural + authority validation of an ORCHESTRATED plan. `PlanValidator` (cycles, ids, prohibited operations, destructive rules, Unity ordering, recursion
    /// keys, paid providers, local model) has already run on the same plan; this adds what only a multi-agent graph can get wrong.
    static func validate(_ plan: TaskPlan, capabilities: CapabilitySet, delegateCheck: (@Sendable (PlanStep) -> String?)? = nil) -> [GraphIssue] {
        var out: [GraphIssue] = []
        if plan.steps.count > OrchestrationLimits.maxNodes { out.append(.tooManyNodes(plan.steps.count)) }
        let graph = TaskGraph(plan: plan)
        var delegates = 0
        for s in plan.steps {
            for why in AgentContracts.violations(of: s.type, granted: capabilities) { out.append(.roleViolation(node: s.id, why: why)) }
            if s.type.isDelegate {
                delegates += 1
                let goal = s.delegate?.goal.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if goal.isEmpty { out.append(.delegateWithoutGoal(node: s.id)) }
                else if let why = delegateCheck?(s) { out.append(.delegateGoalRefused(node: s.id, why: why)) }
            }
            if s.type == .approvalGate {
                if (s.delegate?.gateAction ?? "").trimmingCharacters(in: .whitespaces).isEmpty { out.append(.gateWithoutAction(node: s.id)) }
                if !plan.steps.contains(where: { $0.dependsOn.contains(s.id) }) { out.append(.gateGuardsNothing(node: s.id)) }
                if s.optional { out.append(.optionalNotAllowed(node: s.id, type: s.type)) }
            }
            if s.optional, !optionalAllowed.contains(s.type) { out.append(.optionalNotAllowed(node: s.id, type: s.type)) }
        }
        if delegates > OrchestrationLimits.maxDelegates { out.append(.tooManyDelegates(delegates)) }

        // Two nodes that change things must be ordered (determinism; the scheduler also serialises them and leases are the last defence).
        let writers = graph.nodes.filter(\.mutates)
        for (i, a) in writers.enumerated() { for b in writers.dropFirst(i + 1) where !graph.isOrdered(a.key, b.key) { out.append(.unorderedWriters(a: a.key, b: b.key)) } }

        // Validation gates: whatever proves or judges a change comes AFTER the change; a review comes after the QA of it.
        let changes = graph.nodes.filter { $0.type == .codeChange || $0.type == .unityEdit }
        if !changes.isEmpty {
            for n in graph.nodes {
                let proves = (n.type == .build) || (n.type == .test && plan.steps.first { $0.id == n.key }?.validation == .testPass) || n.type == .unityCompile || n.type == .unityTest
                if proves, let missed = changes.first(where: { !graph.ancestors(of: n.key).contains($0.key) && $0.key != n.key }) { out.append(.testBeforeChange(node: n.key, change: missed.key)) }
                if n.type == .review {
                    if let missed = changes.first(where: { !graph.ancestors(of: n.key).contains($0.key) }) { out.append(.reviewWithoutChange(node: n.key)) ; _ = missed }
                    let anc = graph.ancestors(of: n.key)
                    let validators = graph.nodes.filter { ($0.type == .build || $0.type == .test || $0.type == .unityCompile || $0.type == .unityTest) && anc.contains($0.key) }
                    let validatorsExist = graph.nodes.contains { $0.type == .build || $0.type == .test || $0.type == .unityCompile || $0.type == .unityTest }
                    if validatorsExist, validators.isEmpty { out.append(.reviewBeforeValidation(node: n.key)) }
                }
            }
        }
        return out
    }

    /// Wrapper used by the engine: V0.4's rules first, then the graph rules. `plan` is non-nil only when there are NO issues.
    static func check(_ text: String, kind: TaskKind, capabilities: CapabilitySet, allowDestructive: Bool, delegateCheck: (@Sendable (PlanStep) -> String?)? = nil) -> (plan: TaskPlan?, issues: [String], policy: Bool) {
        let parsed = PlanParser.parse(text)
        guard let plan = parsed.plan else { return (nil, parsed.issues.map(\.description), false) }
        let base = PlanValidator.validate(plan, kind: kind, capabilities: capabilities, allowDestructive: allowDestructive, rawKeys: parsed.rawKeys)
        let graph = validate(plan, capabilities: capabilities, delegateCheck: delegateCheck)
        let all = base.map(\.description) + graph.map(\.description)
        return (all.isEmpty ? plan : nil, all, base.contains { $0.isPolicyBlock } || graph.contains { $0.isPolicyBlock })
    }
}

// MARK: - Concurrency policy (what may run side by side)

enum ConcurrencyPolicy {
    /// How many nodes may run at once: two on a calm machine, ONE under any memory pressure / thermal throttling / low-power mode (a MacBook Air with 16 GB also runs Unity,
    /// a browser and the voice stack). Interactive conversation is always foreground and never waits for these slots.
    static func parallelLimit(_ p: ResourcePressure) -> Int {
        (p.memory != .normal || p.thermalSerious || p.lowPowerMode) ? 1 : OrchestrationLimits.maxParallel
    }

    /// Read-only knowledge nodes that never touch what another node reads or writes.
    static func isReadOnly(_ t: StepType) -> Bool { t == .analysis || t == .delegateResearch }

    /// May `type` start while `inflight` is running? Only two read-only nodes ever overlap (at most one web delegate); every node that writes, builds, tests, reviews,
    /// drives the editor or the screen runs ALONE.
    static func canStart(_ type: StepType, alongside inflight: [StepType], pressure: ResourcePressure = ResourcePressure()) -> Bool {
        if inflight.isEmpty { return true }
        guard inflight.count < parallelLimit(pressure) else { return false }
        guard isReadOnly(type), inflight.allSatisfy(isReadOnly) else { return false }
        if type == .delegateResearch, inflight.contains(.delegateResearch) { return false }
        return true
    }

    /// A graph is deadlocked when work remains, nothing runs, and nothing can start although no failure explains it (dependencies that can never be satisfied).
    static func isDeadlocked(pending: [GraphNode], done: Set<String>, failedRequired: Bool, inflight: Int) -> Bool {
        guard inflight == 0, !failedRequired, !pending.isEmpty else { return false }
        return !pending.contains { $0.dependsOn.allSatisfy(done.contains) }
    }
}

// MARK: - Task outcome (the honest vocabulary the user sees)

enum TaskOutcome: String, Codable, Sendable {
    case notStarted, running, approvalRequired, success, partial, failed, cancelled, interrupted, blocked

    var label: String {
        switch self {
        case .notStarted: "NOT STARTED"; case .running: "RUNNING"; case .approvalRequired: "APPROVAL REQUIRED"; case .success: "SUCCESS"; case .partial: "PARTIAL"
        case .failed: "FAILED"; case .cancelled: "CANCELLED"; case .interrupted: "INTERRUPTED"; case .blocked: "BLOCKED"
        }
    }

    /// Categories that mean "JARVIS refused or could not be allowed to continue" rather than "the work failed its validation".
    private static let blockedCategories: Set<FailureCategory> = [.securityBlocked, .capabilityDenied, .approvalDenied, .permissionRequired, .providerUnavailable, .blockedByNetworkPolicy, .scopeExceeded, .resourceUnavailable, .unityUnavailable]

    /// SUCCESS = completed with every REQUIRED node validated and no optional node failed; PARTIAL = completed, but an optional node failed or was skipped for lack of its input
    /// (never shown as complete); FAILED = a required node failed validation; BLOCKED = policy/approval/availability stopped it; the rest mirror the task state.
    static func derive(state: TaskState, failure: FailureCategory?, steps: [TaskStepRecord]) -> TaskOutcome {
        switch state {
        case .created, .planning, .ready: return .notStarted
        case .running: return .running
        case .waitingForApproval: return .approvalRequired
        case .cancelled: return .cancelled
        case .interrupted: return .interrupted
        case .failed: return failure.map { blockedCategories.contains($0) } == true ? .blocked : .failed
        case .completed:
            let optionalGaps = steps.contains { $0.optional && ($0.state == .failed || $0.state == .cancelled || ($0.state == .skipped && !$0.title.isEmpty && $0.failureCategory != nil)) }
            return optionalGaps ? .partial : .success
        }
    }
}

/// Progress = validated REQUIRED nodes / required nodes. Optional nodes never distort it: a passed optional node is not counted, a failed one does not lower it.
enum GraphProgress {
    static func required(_ steps: [TaskStepRecord]) -> [TaskStepRecord] { steps.filter { !$0.optional && $0.state != .skipped } }
    static func validated(_ steps: [TaskStepRecord]) -> (done: Int, total: Int) {
        let req = required(steps)
        return (req.filter { $0.state == .passed }.count, req.count)
    }
}
