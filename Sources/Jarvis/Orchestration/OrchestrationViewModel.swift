import Foundation
import Observation

/// Everything the Tasks / Agents screens show about an orchestrated task, read from the durable records (never from a provider). The UI never writes any of it.
struct OrchestrationDetail: Equatable {
    var graph: TaskGraphRecord?
    var revisions: [GraphRevisionRecord]
    var artifacts: [AgentArtifact]
    var decisions: [RoutingDecisionRecord]
    var children: [TaskRecord]

    /// "Coding · OpenCode Free · space-bunny-free" for a node (the newest model run that served it); nil for tool/gate nodes.
    func providerLabel(node key: String) -> String? {
        guard let d = decisions.last(where: { $0.nodeKey == key && $0.engine != nil }), let e = d.engine.flatMap(ProviderID.init(rawValue:)) else { return nil }
        let model = d.model.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
        return e.displayName + (model.map { " · " + $0 } ?? "")
    }
    func decisions(node key: String) -> [RoutingDecisionRecord] { decisions.filter { $0.nodeKey == key } }
    func artifacts(node key: String) -> [AgentArtifact] { artifacts.filter { $0.nodeKey == key } }
}

@MainActor
@Observable
final class OrchestrationViewModel {
    private let repository: JarvisRepository?
    private(set) var revision = 0
    init(repository: JarvisRepository?) { self.repository = repository }

    func detail(_ taskID: UUID) -> OrchestrationDetail? {
        guard let repository, let graph = (try? repository.taskGraph(taskID)) ?? nil else { return nil }
        return OrchestrationDetail(graph: graph, revisions: (try? repository.graphRevisions(taskID: taskID)) ?? [], artifacts: (try? repository.artifacts(taskID: taskID)) ?? [],
                                   decisions: (try? repository.routingDecisions(taskID: taskID)) ?? [], children: (try? repository.childTasks(of: taskID)) ?? [])
    }

    func telemetry() -> RoutingTelemetry? { try? repository?.routingTelemetry() }

    /// Per model: the role scores recorded by the role benchmark (diagnostics only).
    func roleScores() -> [(model: String, scores: [String: RoleScore])] {
        guard let repository, let models = try? repository.benchmarkedModelIDs() else { return [] }
        return models.map { m in (m, RoleScoreboard.scores((try? repository.benchmarks(modelID: m)) ?? [])) }.filter { !$0.scores.isEmpty }
    }
}
