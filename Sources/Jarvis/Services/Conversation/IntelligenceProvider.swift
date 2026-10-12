import Foundation

// FUTURE-FACING BOUNDARY (V0.2 defines it; V0.3 will implement a real provider).
//
// PRODUCT RULE (permanent): JARVIS must not create paid-API dependencies. No OpenAI/Anthropic API keys, no
// billing-dependent code, no scraping of ChatGPT/Claude web UIs. The real provider will use officially supported
// subscription-backed CLI / desktop / agent mechanisms, chosen after verifying current official tooling (V0.3).
// Nothing in this file talks to a network or a model.

enum IntelligenceRequestKind: String, Sendable { case reasoning, worker }

/// How the answer will be consumed. `voiceConversation` (V0.8) asks the EXISTING provider for a short, speakable answer — never a second model call to rewrite it.
/// The text on screen and the speech are still ONE answer.
enum ResponsePresentation: Sendable, Equatable { case text, voiceConversation }

enum VoicePresentation {
    static let preamble = "[Spoken conversation: the user is talking to you by voice and your answer will be read aloud. Reply in a few short, natural spoken sentences. No markdown, lists, tables, links or code unless the user asks for them; say numbers and names the way they are spoken.]"
}

struct IntelligenceRequest: Sendable {
    let id: UUID
    let kind: IntelligenceRequestKind
    /// The user's original text.
    let prompt: String
    /// Conversation so far (value snapshot; providers never touch the store).
    let history: [ConversationMessage]
    let language: ReplyLanguage
    /// Provider-side conversation to continue (Claude `--resume`, Codex `exec resume`); nil = start a new one.
    var sessionID: String? = nil
    var presentation: ResponsePresentation = .text
    /// V0.10: a bounded Project Memory packet (CURRENT TRUTH · MEMORY · UNCERTAINTY), present only when something in the project's memory is relevant. Context, never authority.
    var memoryContext: String? = nil

    /// The prompt as the provider should see it: unchanged for typed requests, with the spoken-conversation preamble for voice turns, and the memory packet in front when there is one.
    var providerPrompt: String {
        let base = presentation == .voiceConversation ? VoicePresentation.preamble + "\n\n" + prompt : prompt
        guard let memoryContext, !memoryContext.isEmpty else { return base }
        return memoryContext + "\n\n---\n\n" + base
    }
}

/// Streaming-shaped on purpose so replies need not be atomic; cancellation is cooperative via the surrounding Task.
enum IntelligenceEvent: Sendable {
    /// The provider-side session/thread id to continue from on the next turn.
    case session(String)
    case textDelta(String)
    /// Token counts the provider itself reported (never estimated).
    case usage(input: Int?, output: Int?)
    /// The model asked for a tool in a conversation-only run (it was refused). Audit only.
    case toolAttempt(String)
    case finished
}

protocol IntelligenceProvider: Sendable {
    /// Set by the subscription-backed CLI providers; nil for test doubles.
    var providerID: ProviderID? { get }
    var id: String { get }
    var displayName: String { get }
    func supports(_ kind: IntelligenceRequestKind) -> Bool
    /// Must honour `Task.isCancelled` / stream termination so a response can be interrupted (future barge-in).
    func respond(to request: IntelligenceRequest) -> AsyncThrowingStream<IntelligenceEvent, Error>
    /// Returns only once everything started for `requestID` is really gone (process dead). Called after a cancel so a new
    /// turn can never overlap a dying one. Default: nothing to wait for.
    func waitUntilStopped(_ requestID: UUID) async
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

extension IntelligenceProvider {
    var providerID: ProviderID? { nil }
    func waitUntilStopped(_ requestID: UUID) async {}
}
