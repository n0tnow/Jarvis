import Foundation

enum InputOrigin: Sendable { case fullHUD, compactHUD, other }

/// Orchestrates one user submission: store the message → route → execute/answer → store the reply.
/// Text input is not privileged: future voice/LLM-tool callers use `submit` (or the router/executor) the same way.
@MainActor
final class ConversationService {
    private let store: JarvisStore
    let conversation: ConversationStore
    private let windows: any JarvisWindowControlling
    private let router: IntelligenceRouter
    private var providers: IntelligenceProviderRegistry
    private let executor: CommandExecutor

    /// The in-flight provider response, if any (future: reasoning/worker). Cancel = barge-in foundation.
    private var responseTask: Task<Void, Never>?
    private var responseMessageID: UUID?
    private(set) var isResponding = false
    /// True once a provider is registered (never in V0.2).
    var hasProviders: Bool { !providers.providers.isEmpty }

    init(store: JarvisStore, conversation: ConversationStore, windows: any JarvisWindowControlling,
         router: IntelligenceRouter = IntelligenceRouter(), providers: IntelligenceProviderRegistry = IntelligenceProviderRegistry()) {
        self.store = store
        self.conversation = conversation
        self.windows = windows
        self.router = router
        self.providers = providers
        self.executor = CommandExecutor(store: store, windows: windows, clearConversation: { [weak conversation] in conversation?.clear() })
    }

    /// Returns the routing decision taken (nil for blank input, which does nothing).
    @discardableResult
    func submit(_ raw: String, origin: InputOrigin = .fullHUD) -> RouteDecision? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        conversation.appendUser(text)
        let decision = router.route(text)
        defer { announceLatestReply() }

        switch decision {
        case .command(let intent, let lang):
            let result = executor.execute(intent, language: lang)
            conversation.appendJarvis(result.message, tone: result.tone, route: .command)

        case .localResponse(let reply, let lang):
            conversation.appendJarvis(reply == .greeting ? Phrasebook.greeting(lang) : Phrasebook.thanks(lang), route: .local)

        case .reasoningRequired(let prompt, let lang):
            handleProviderRequest(.reasoning, prompt: prompt, language: lang, origin: origin)

        case .workerRequired(let prompt, let lang):
            handleProviderRequest(.worker, prompt: prompt, language: lang, origin: origin)

        case .unsupported(_, let lang):
            conversation.appendJarvis(Phrasebook.unsupported(lang), tone: .notice, route: .unsupported)
        }
        return decision
    }

    /// VoiceOver users otherwise hear nothing when a reply lands in a text field / panel.
    private func announceLatestReply() {
        guard let last = conversation.last, last.role == .jarvis, last.status == .complete else { return }
        Announcer.announce(last.content, high: last.tone == .notice)
    }

    /// Interrupts an in-flight provider response (what a future barge-in will call). No-op when idle.
    func cancelCurrentResponse() {
        responseTask?.cancel()
    }

    /// Wiring point for V0.3. V0.2 never registers one.
    func register(_ provider: any IntelligenceProvider) { providers.register(provider) }

    // MARK: Provider path (dormant in V0.2: the registry is empty)

    private func handleProviderRequest(_ kind: IntelligenceRequestKind, prompt: String, language: ReplyLanguage, origin: InputOrigin) {
        let route: RouteKind = kind == .reasoning ? .reasoning : .worker
        guard let provider = providers.provider(for: kind) else {
            // Truthful: no fake intelligence. From the Compact HUD the full message needs room → continue in Full HUD.
            let text = kind == .reasoning ? Phrasebook.reasoningUnavailable(language) : Phrasebook.workerUnavailable(language)
            conversation.appendJarvis(text, tone: .notice, route: route)
            if origin == .compactHUD { windows.showFullHUD(section: .dashboard) }
            return
        }

        if origin == .compactHUD { windows.showFullHUD(section: .dashboard) }
        responseTask?.cancel()
        let history = conversation.messages
        let request = IntelligenceRequest(id: UUID(), kind: kind, prompt: prompt, history: history, language: language)
        let messageID = conversation.beginJarvisResponse(route: route)
        responseMessageID = messageID
        isResponding = true
        if store.state == .idle || store.state == .completed { store.setState(.thinking) }

        responseTask = Task { [weak self] in
            do {
                for try await event in provider.respond(to: request) {
                    guard let self else { return }
                    try Task.checkCancellation()
                    if case .textDelta(let delta) = event { self.conversation.appendDelta(messageID, delta) }
                }
                try Task.checkCancellation()   // a cancelled stream may end the loop silently instead of throwing
                self?.finishResponse(messageID, outcome: .finished)
            } catch is CancellationError {
                self?.finishResponse(messageID, outcome: .cancelled)
            } catch {
                self?.finishResponse(messageID, outcome: .failed)
            }
        }
    }

    private enum Outcome { case finished, cancelled, failed }

    private func finishResponse(_ id: UUID, outcome: Outcome) {
        guard responseMessageID == id else { return }
        switch outcome {
        case .finished: conversation.finish(id)
        case .cancelled: conversation.markCancelled(id)
        case .failed: conversation.fail(id, reason: "The intelligence provider failed.")
        }
        isResponding = false
        responseTask = nil
        responseMessageID = nil
        if store.state == .thinking { store.setState(.idle) }
    }
}
