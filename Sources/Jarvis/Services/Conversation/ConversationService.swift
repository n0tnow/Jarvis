import Foundation
import Observation

enum InputOrigin: Sendable { case fullHUD, compactHUD, other }

/// Coalesces streamed text into ~25 store updates per second so a fast token stream doesn't re-render the HUD per token.
/// Text is appended in order, never dropped or duplicated; whole `String`s only, so Unicode is never split.
@MainActor
final class StreamCoalescer {
    static let interval: Duration = .milliseconds(40)
    private let conversation: ConversationStore
    private let id: UUID
    private var buffer = ""
    private var flushTask: Task<Void, Never>?
    private(set) var flushCount = 0

    init(conversation: ConversationStore, id: UUID) { self.conversation = conversation; self.id = id }

    func append(_ text: String) {
        buffer += text
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.interval)
            self?.flushNow()
        }
    }

    func flushNow() {
        flushTask?.cancel(); flushTask = nil
        guard !buffer.isEmpty else { return }
        conversation.appendDelta(id, buffer)
        flushCount += 1
        buffer = ""
    }
}

/// Orchestrates one user submission: store the message → route → execute/answer → store the reply.
/// Provider-backed answers stream into the store; deterministic commands NEVER touch a provider.
/// Text input is not privileged: voice/LLM-tool callers use `submit` (or the router/executor) the same way.
@MainActor
@Observable
final class ConversationService {
    @ObservationIgnored private let store: JarvisStore
    @ObservationIgnored let conversation: ConversationStore
    @ObservationIgnored private let windows: any JarvisWindowControlling
    @ObservationIgnored private let router: IntelligenceRouter
    @ObservationIgnored private let resolver: any IntelligenceProviderResolving
    @ObservationIgnored private var executor: CommandExecutor!

    /// The in-flight provider response (cancel = STOP GENERATION / barge-in foundation).
    @ObservationIgnored private var responseTask: Task<Void, Never>?
    @ObservationIgnored private var responseMessageID: UUID?
    /// True only if THIS service moved JARVIS into Thinking (so it never clobbers a state someone else set).
    @ObservationIgnored private var ownsThinking = false
    private(set) var isResponding = false
    private(set) var respondingProvider: ProviderID?
    private(set) var respondingProviderName: String?
    var hasProviders: Bool { resolver.hasProviders }

    init(store: JarvisStore, conversation: ConversationStore, windows: any JarvisWindowControlling,
         router: IntelligenceRouter = IntelligenceRouter(), resolver: (any IntelligenceProviderResolving)? = nil) {
        self.store = store
        self.conversation = conversation
        self.windows = windows
        self.router = router
        self.resolver = resolver ?? StaticProviderResolver()
        self.executor = CommandExecutor(
            store: store, windows: windows,
            clearConversation: { [weak self] in
                self?.cancelCurrentResponse()
                self?.conversation.clear()
                self?.resolver.resetSessions()
            },
            cancelGeneration: { [weak self] in self?.cancelCurrentResponse() ?? false })
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

    /// STOP GENERATION: cancels the in-flight provider request; the provider layer kills the real process.
    /// Returns true if something was being generated.
    @discardableResult
    func cancelCurrentResponse() -> Bool {
        guard isResponding else { return false }
        responseTask?.cancel()
        return true
    }

    /// Waits until no provider response is in flight (tests, smoke, shutdown).
    func waitUntilIdle() async {
        while let task = responseTask { await task.value; if responseTask == nil { break } }
    }

    // MARK: Provider path

    private func handleProviderRequest(_ kind: IntelligenceRequestKind, prompt: String, language: ReplyLanguage, origin: InputOrigin) {
        // Anything needing more room than the Compact HUD continues in the Full HUD (WindowManager keeps Compact XOR Full).
        if origin == .compactHUD { windows.showFullHUD(section: .dashboard) }

        // V0.3 is conversational: autonomous/worker requests are NEVER sent to a provider (task engine = V0.4).
        guard kind == .reasoning else {
            conversation.appendJarvis(Phrasebook.workerUnavailable(language), tone: .notice, route: .worker)
            return
        }
        guard !isResponding else {
            conversation.appendJarvis(ProviderError.busy.userMessage(language), tone: .notice, route: .reasoning)
            return
        }

        let messageID = conversation.beginJarvisResponse(route: .reasoning)
        responseMessageID = messageID
        isResponding = true
        if store.state == .idle || store.state == .completed { store.setState(.thinking); ownsThinking = true }

        responseTask = Task { [weak self] in await self?.runProviderRequest(kind, prompt: prompt, language: language, messageID: messageID) }
    }

    private func runProviderRequest(_ kind: IntelligenceRequestKind, prompt: String, language: ReplyLanguage, messageID: UUID) async {
        let resolution = await resolver.resolve(kind)
        if Task.isCancelled {                                   // STOP pressed while the provider was still being resolved
            conversation.markCancelled(messageID)
            endResponse(messageID); announceLatestReply()
            return
        }
        guard case .ready(let resolved) = resolution else {
            if case .unavailable(let error) = resolution { conversation.setNotice(messageID, Self.message(for: error, language)) }
            endResponse(messageID)
            announceLatestReply()
            return
        }

        respondingProvider = resolved.id
        respondingProviderName = resolved.name
        conversation.setProvider(messageID, resolved.name)
        resolver.providerStarted(resolved.id)
        store.log("\(resolved.name) response started", kind: .info)

        let request = IntelligenceRequest(id: UUID(), kind: kind, prompt: prompt, history: conversation.messages, language: language,
                                          sessionID: resolver.sessionID(for: resolved.id))
        let coalescer = StreamCoalescer(conversation: conversation, id: messageID)
        var outcome = ProviderOutcome.completed
        var sawFinished = false

        do {
            for try await event in resolved.provider.respond(to: request) {
                try Task.checkCancellation()
                switch event {
                case .session(let s): resolver.recordSession(s, for: resolved.id)
                case .textDelta(let d): coalescer.append(d)
                case .usage, .toolAttempt: break          // audit-only (handled by the coordinator in the next step)
                case .finished: sawFinished = true
                }
            }
            if !sawFinished { try Task.checkCancellation() }    // a cancelled stream may end silently; a COMPLETE answer stays complete
        } catch is CancellationError {
            outcome = .cancelled
        } catch let error as ProviderError {
            outcome = error == .cancelled ? .cancelled : .failed(error)
        } catch {
            outcome = .failed(.generic)
        }
        coalescer.flushNow()
        // A cancelled consumer stops iterating at once; wait until the provider has really killed and reaped its process,
        // so the next turn can never overlap (or `--resume` the same session as) a dying one.
        await resolved.provider.waitUntilStopped(request.id)

        let hasContent = !(conversation.messages.last(where: { $0.id == messageID })?.content.isEmpty ?? true)
        switch outcome {
        case .completed where hasContent:
            conversation.finish(messageID)
            store.log("\(resolved.name) response completed", kind: .success)
        case .completed:
            outcome = .failed(.malformedOutput(resolved.id ?? .claudeCode))
            conversation.setNotice(messageID, Self.message(for: .malformedOutput(resolved.id ?? .claudeCode), language))
            store.log("\(resolved.name) returned no answer", kind: .warning)
        case .cancelled:
            conversation.markCancelled(messageID)
            store.log("\(resolved.name) response cancelled", kind: .warning)
        case .failed(let error):
            let text = Self.message(for: error, language)
            if hasContent {
                conversation.finish(messageID)                                  // keep what streamed
                conversation.appendJarvis(text, tone: .notice, route: .reasoning)
            } else {
                conversation.fail(messageID, reason: text)
            }
            store.log("\(resolved.name) failed: \(Self.activityReason(error))", kind: .error)
        }

        resolver.providerFinished(resolved.id, outcome: outcome)
        endResponse(messageID)
        announceLatestReply()
    }

    private func endResponse(_ id: UUID) {
        guard responseMessageID == id else { return }
        isResponding = false
        responseTask = nil
        responseMessageID = nil
        respondingProvider = nil
        respondingProviderName = nil
        if ownsThinking, store.state == .thinking { store.setState(.idle) }   // back to calm; provider errors never leave JARVIS stuck
        ownsThinking = false
    }

    static func message(for error: ProviderError, _ language: ReplyLanguage) -> String {
        if case .noProviderReady(let summary) = error, summary.isEmpty { return Phrasebook.reasoningUnavailable(language) }
        return error.userMessage(language)
    }

    private static func activityReason(_ e: ProviderError) -> String {
        switch e {
        case .authenticationRequired: "authentication required"
        case .rateLimited: "usage limit reached"
        case .networkUnavailable: "network unavailable"
        case .timedOut: "timed out"
        case .notInstalled: "not installed"
        default: "provider error"
        }
    }

    /// VoiceOver users otherwise hear nothing when a reply lands in a text field / panel.
    private func announceLatestReply() {
        guard let last = conversation.last, last.role == .jarvis, last.status == .complete || last.status == .failed else { return }
        Announcer.announce(last.content, high: last.tone == .notice)
    }
}
