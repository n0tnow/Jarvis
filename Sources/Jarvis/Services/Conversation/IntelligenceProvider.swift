import Foundation

// FUTURE-FACING BOUNDARY (V0.2 defines it; V0.3 will implement a real provider).
//
// PRODUCT RULE (permanent): JARVIS must not create paid-API dependencies. No OpenAI/Anthropic API keys, no
// billing-dependent code, no scraping of ChatGPT/Claude web UIs. The real provider will use officially supported
// subscription-backed CLI / desktop / agent mechanisms, chosen after verifying current official tooling (V0.3).
// Nothing in this file talks to a network or a model.

enum IntelligenceRequestKind: String, Sendable { case reasoning, worker }

struct IntelligenceRequest: Sendable {
    let id: UUID
    let kind: IntelligenceRequestKind
    /// The user's original text.
    let prompt: String
    /// Conversation so far (value snapshot; providers never touch the store).
    let history: [ConversationMessage]
    let language: ReplyLanguage
}

/// Streaming-shaped on purpose so replies need not be atomic; cancellation is cooperative via the surrounding Task.
enum IntelligenceEvent: Sendable {
    case textDelta(String)
    case finished
}

protocol IntelligenceProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func supports(_ kind: IntelligenceRequestKind) -> Bool
    /// Must honour `Task.isCancelled` / stream termination so a response can be interrupted (future barge-in).
    func respond(to request: IntelligenceRequest) -> AsyncThrowingStream<IntelligenceEvent, Error>
}

/// Holds connected providers. In V0.2 it is intentionally EMPTY, so every reasoning/worker request gets the
/// truthful "not connected" reply instead of a fake answer.
struct IntelligenceProviderRegistry: Sendable {
    private(set) var providers: [any IntelligenceProvider] = []

    init(providers: [any IntelligenceProvider] = []) { self.providers = providers }

    mutating func register(_ provider: any IntelligenceProvider) { providers.append(provider) }

    func provider(for kind: IntelligenceRequestKind) -> (any IntelligenceProvider)? {
        providers.first { $0.supports(kind) }
    }
}
