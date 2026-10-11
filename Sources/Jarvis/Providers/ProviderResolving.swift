import Foundation

struct ResolvedProvider: Sendable {
    let provider: any IntelligenceProvider
    let id: ProviderID?
    /// V0.3.1: which model (OpenCode), why (routing decision) and the audit row of this run.
    var model: String? = nil
    var runID: UUID? = nil
    var decision: RoutingDecision? = nil
    var profile: TaskProfile? = nil
    var escalationDepth = 0

    var name: String {
        let base = id?.displayName ?? provider.displayName
        guard let model else { return base }
        return "\(base) · \(model.split(separator: "/").last.map(String.init) ?? model)"
    }
}

/// What a finished run reports back for auditing / health (never raw prompts; text is only counted and excerpted).
struct RunReport: Sendable {
    var resultText = ""
    var inputTokens: Int?
    var outputTokens: Int?
    var toolAttempts: [String] = []
}

enum ProviderResolution {
    case ready(ResolvedProvider)
    case unavailable(ProviderError)
}

enum ProviderOutcome: Equatable, Sendable {
    case completed, cancelled
    case failed(ProviderError)
}

/// What `ConversationService` needs from "the provider layer". `ProviderManager` is the real implementation;
/// `StaticProviderResolver` serves tests/fakes. The service never knows about CLIs, paths or processes.
@MainActor
protocol IntelligenceProviderResolving: AnyObject {
    var hasProviders: Bool { get }
    func resolve(_ kind: IntelligenceRequestKind) async -> ProviderResolution
    /// V0.3.1: routing needs the text (task classification). Default ignores it (V0.3 resolvers).
    func resolve(_ kind: IntelligenceRequestKind, prompt: String) async -> ProviderResolution
    /// Auto mode only: after a provider failure with no output, the next eligible provider (bounded by the coordinator).
    func escalate(from failed: ResolvedProvider, error: ProviderError, prompt: String) async -> ResolvedProvider?
    /// Audit + health bookkeeping for a finished run.
    func runFinished(_ resolved: ResolvedProvider, outcome: ProviderOutcome, report: RunReport)
    func sessionID(for id: ProviderID?) -> String?
    func recordSession(_ session: String, for id: ProviderID?)
    func providerStarted(_ id: ProviderID?)
    func providerFinished(_ id: ProviderID?, outcome: ProviderOutcome)
    func resetSessions()
}

extension IntelligenceProviderResolving {
    func resolve(_ kind: IntelligenceRequestKind, prompt: String) async -> ProviderResolution { await resolve(kind) }
    func escalate(from failed: ResolvedProvider, error: ProviderError, prompt: String) async -> ResolvedProvider? { nil }
    func runFinished(_ resolved: ResolvedProvider, outcome: ProviderOutcome, report: RunReport) {}
}

/// Fixed set of providers (tests, or "no provider" = the V0.2 behaviour).
@MainActor
final class StaticProviderResolver: IntelligenceProviderResolving {
    private let registry: IntelligenceProviderRegistry
    private var sessions: [String: String] = [:]
    init(registry: IntelligenceProviderRegistry = IntelligenceProviderRegistry()) { self.registry = registry }

    var hasProviders: Bool { !registry.providers.isEmpty }
    func resolve(_ kind: IntelligenceRequestKind) async -> ProviderResolution {
        if let p = registry.provider(for: kind) { return .ready(ResolvedProvider(provider: p, id: p.providerID)) }
        return .unavailable(.noProviderReady(summary: ""))
    }
    func sessionID(for id: ProviderID?) -> String? { sessions[id?.rawValue ?? "static"] }
    func recordSession(_ session: String, for id: ProviderID?) { sessions[id?.rawValue ?? "static"] = session }
    func providerStarted(_ id: ProviderID?) {}
    func providerFinished(_ id: ProviderID?, outcome: ProviderOutcome) {}
    func resetSessions() { sessions.removeAll() }
}
