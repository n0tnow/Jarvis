import Foundation

// MARK: - May this worker start? Memory, power and concurrency in ONE pure answer (V1.0 background pass)
//
// Composes what already exists — `ResourceBudget` (declared resident memory), `ConcurrencyPolicy` (parallel nodes under pressure) and the engine's `ConcurrencyLimits` (3 agents, 1 heavy coding agent, 1 local job) —
// with power state, for the 16 GB target. More agents is not better: the policy refuses the combinations that end in an out-of-memory event (a heavy coding agent + a large local model + Unity + Computer Use),
// declines OPTIONAL heavy work (a benchmark, a model pre-load) on low battery, low-power mode, thermal pressure or memory pressure, and never admits a BENCHMARK that nobody asked for.
// Battery LEVEL is not available to JARVIS without IOKit (not used); `PowerContext.batteryFraction` is optional and nil means "unknown" — unknown never blocks required work. Pure; no sensor is read here.

struct PowerContext: Equatable, Sendable {
    var onBattery = false
    /// 0…1 when known, nil when unknown.
    var batteryFraction: Double?
    var thermalSerious = false
    var lowPowerMode = false

    var constrained: Bool { lowPowerMode || thermalSerious || (onBattery && (batteryFraction ?? 1) < 0.2) }
}

enum WorkerKind: String, Equatable, Sendable, CaseIterable {
    case codingAgent, analysisAgent, freeCloudAgent, localModelSmall, localModelLarge, benchmark, mcpServer, computerUse, unityEditor

    var isHeavy: Bool { self == .codingAgent || self == .localModelLarge || self == .benchmark }
    /// Required for the task's correctness vs. nice-to-have.
    var isOptionalByDefault: Bool { self == .benchmark || self == .localModelLarge }
    var resident: ResidentComponent? {
        switch self {
        case .localModelSmall: .localModelSmall; case .localModelLarge: .localModelLarge; case .unityEditor: .unityEditor
        case .computerUse: .computerUseCapture; case .codingAgent, .analysisAgent, .freeCloudAgent, .mcpServer: .cliProvider; case .benchmark: nil
        }
    }
}

struct Admission: Equatable, Sendable {
    var allowed: Bool
    var reason: String
}

struct WorkerLimits: Equatable, Sendable {
    var maxAgents = 3
    var maxHeavyCoding = 1
    var maxLocalModels = 1
    var maxFreeCloud = 2
}

enum WorkerAdmission {
    static func admit(_ w: WorkerKind, running: [WorkerKind], pressure: MemoryPressureLevel = .normal, power: PowerContext = PowerContext(), explicitlyRequested: Bool = false,
                      required: Bool = false, limits: WorkerLimits = WorkerLimits(), budget: ResourceBudget = ResourceBudget()) -> Admission {
        // a benchmark / stress test is a developer operation: never started by the system on its own
        if w == .benchmark, !explicitlyRequested { return Admission(allowed: false, reason: "benchmarks start only when explicitly requested") }
        // optional heavy work gives way to power and thermal state; REQUIRED work is never blocked by them
        if w.isOptionalByDefault, !required {
            if power.constrained { return Admission(allowed: false, reason: "power or thermal state is constrained: optional heavy work waits") }
            if pressure != .normal { return Admission(allowed: false, reason: "memory pressure is \(pressure.rawValue): optional heavy work waits") }
            // the same rule as `ResourceBudget.preferredLocalModel`: the large local model is not started next to Unity
            if w == .localModelLarge, running.contains(.unityEditor) { return Admission(allowed: false, reason: "the large local model is not started next to the Unity editor") }
        }
        let agents: Set<WorkerKind> = [.codingAgent, .analysisAgent, .freeCloudAgent]
        if agents.contains(w), running.filter({ agents.contains($0) }).count >= limits.maxAgents { return Admission(allowed: false, reason: "at most \(limits.maxAgents) agents run at once") }
        if w == .codingAgent, running.filter({ $0 == .codingAgent }).count >= limits.maxHeavyCoding { return Admission(allowed: false, reason: "one heavy coding agent at a time") }
        if w == .freeCloudAgent, running.filter({ $0 == .freeCloudAgent }).count >= limits.maxFreeCloud { return Admission(allowed: false, reason: "two free-cloud agents at most") }
        if w == .localModelSmall || w == .localModelLarge, running.filter({ $0 == .localModelSmall || $0 == .localModelLarge }).count >= limits.maxLocalModels { return Admission(allowed: false, reason: "one local model at a time") }
        if let c = w.resident {
            let verdict = budget.mayStart(c, running: running.compactMap(\.resident), pressure: pressure)
            if !verdict.allowed { return Admission(allowed: false, reason: verdict.reason) }
        }
        return Admission(allowed: true, reason: "within limits")
    }

    /// How many graph nodes may run side by side: the existing pressure rule, further reduced by power state. Never below 1.
    static func parallelNodes(pressure: ResourcePressure, power: PowerContext, calmLimit: Int) -> Int {
        let base = (pressure.memory != .normal || pressure.thermalSerious || pressure.lowPowerMode) ? 1 : calmLimit
        return power.constrained ? 1 : max(1, base)
    }
}

// MARK: - Child-process ownership: kill what JARVIS started, never what it only borrowed

enum ProcessOwnership: String, Equatable, Sendable { case startedForTask, startedByJarvisShared, externalUserOwned }

struct TrackedProcess: Equatable, Sendable {
    var pid: Int32
    var ownership: ProcessOwnership
    var taskID: UUID?
}

enum ProcessHygiene {
    /// After a task ends: the processes JARVIS started FOR that task must be gone; shared or user-owned ones are never to be terminated by task cleanup.
    static func shouldTerminate(_ p: TrackedProcess, whenTaskEnds taskID: UUID) -> Bool { p.ownership == .startedForTask && p.taskID == taskID }

    /// Orphans: processes started for a task that no longer exists / is terminal.
    static func orphans(_ procs: [TrackedProcess], liveTasks: Set<UUID>) -> [TrackedProcess] {
        procs.filter { $0.ownership == .startedForTask && !($0.taskID.map(liveTasks.contains) ?? false) }
    }
}
