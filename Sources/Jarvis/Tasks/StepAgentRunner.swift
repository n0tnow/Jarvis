import Foundation

/// One provider-executed unit of work for a task step. The engine owns planning/repair/escalation; the runner only executes a job
/// through the existing routing + supervisor + resource + audit + sanitization stack (`AgentRunManager.spawn`).
struct AgentJob: Sendable {
    var type: String                       // "PlannerAgent", "AnalysisAgent", "CodingAgent", "ReviewAgent"
    var title: String                      // what the Observatory shows
    var prompt: String
    var profile: TaskProfile
    var taskID: UUID
    var validator: (@Sendable (String) async -> BenchmarkSuite.Verdict)?
    var timeout: TimeInterval = 600
    var exclude: Set<RoutingCandidate> = []
    var pin: RoutingCandidate?
    /// Format-repair budget of THIS job only (the engine counts repair/escalation attempts of the STEP).
    var policy = EscalationPolicy(maxRepairAttempts: 1, maxEscalations: 0, maxTotalAttempts: 2)
}

enum AgentJobResult: Equatable, Sendable {
    case completed(text: String, runID: UUID, candidate: RoutingCandidate, validated: Bool)
    case failed(runID: UUID?, error: ProviderError?, validationFailed: Bool, candidate: RoutingCandidate?)
    case cancelled(runID: UUID?)
    case rejected(AgentRejection)
}

@MainActor
protocol StepAgentRunner: AnyObject {
    /// Task-level escalation is only legal when the user's routing mode is Auto (explicit modes never fall back).
    var escalationAllowed: Bool { get }
    func run(_ job: AgentJob) async -> AgentJobResult
    /// Resolves when capacity may have freed up (event-driven; never a timer).
    func waitForCapacityChange() async
    func cancel(runID: UUID)
}

/// Production runner: delegates to `AgentRunManager` (routing, capacity limits, supervision, audit, hub, sanitization).
@MainActor
final class ManagerAgentRunner: StepAgentRunner {
    private let manager: AgentRunManager
    init(manager: AgentRunManager) { self.manager = manager }

    var escalationAllowed: Bool { manager.coordinator.preference == .auto }

    func run(_ job: AgentJob) async -> AgentJobResult {
        var d = AgentDescriptor(type: job.type, prompt: job.prompt, profile: job.profile, taskID: job.taskID, parentRunID: nil, preference: nil,
                                validator: job.validator, timeout: job.timeout, includeTaskContext: false, title: job.title)
        d.owner = .task; d.exclude = job.exclude; d.pin = job.pin; d.policy = job.policy
        switch await manager.spawn(d) {
        case .completed(let text, let runID, let engine, let model, let validation, _):
            return .completed(text: text, runID: runID, candidate: RoutingCandidate(engine: engine, model: model), validated: validation == .passed)
        case .failed(let runID, let error, let validation):
            let c = runID.flatMap { manager.audit.record($0) }.map { RoutingCandidate(engine: $0.engine, model: $0.model) }
            return .failed(runID: runID, error: error, validationFailed: validation == .failed, candidate: c)
        case .cancelled(let runID): return .cancelled(runID: runID)
        case .rejected(let r): return .rejected(r)
        }
    }

    func waitForCapacityChange() async { await manager.waitForCapacityChange() }
    func cancel(runID: UUID) { manager.cancel(runID) }
}
