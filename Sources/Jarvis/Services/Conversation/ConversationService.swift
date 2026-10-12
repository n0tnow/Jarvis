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
    /// Task submissions whose acknowledgement has not been appended yet (the answer to a task request arrives after the task is persisted).
    private(set) var pendingTaskAcks = 0
    /// True while the answer to the latest submission is still being produced (provider streaming or a task being created).
    var isAnswering: Bool { isResponding || pendingTaskAcks > 0 }
    private(set) var respondingProvider: ProviderID?
    private(set) var respondingProviderName: String?
    /// Audit/observatory id of the run currently being answered (so Stop can be addressed by run id).
    private(set) var respondingRunID: UUID?
    var hasProviders: Bool { resolver.hasProviders }
    /// V0.4: the autonomous task layer. nil (tests, stubbed runs) keeps the V0.3 behaviour: worker requests start nothing.
    @ObservationIgnored weak var taskSubmitter: (any TaskSubmitting)?
    /// V0.9: web research tasks (same entry point for typed and spoken requests). nil = research requests stay ordinary conversation.
    @ObservationIgnored weak var researchSubmitter: (any ResearchSubmitting)?
    /// V0.10: Project Memory (remember / correct / forget / "what did we decide…"). Typed and spoken text take this same path; nil = memory is not wired (stubbed runs).
    @ObservationIgnored weak var memoryHandler: (any MemoryConversing)?
    /// Called at the start of every accepted submission (V0.7: a typed message silences speech that is still playing).
    @ObservationIgnored var onSubmit: ((InputSource) -> Void)?
    /// "stop talking" also silences speech that is playing (V0.7): returns true when something was being spoken.
    @ObservationIgnored var stopSpeech: (() -> Bool)?

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
            cancelGeneration: { [weak self] in
                let stoppedGeneration = self?.cancelCurrentResponse() ?? false
                let stoppedSpeech = self?.stopSpeech?() ?? false
                return stoppedGeneration || stoppedSpeech
            })
    }

    /// Returns the routing decision taken (nil for blank input, which does nothing).
    @discardableResult
    func submit(_ raw: String, origin: InputOrigin = .fullHUD, source: InputSource = .typed) -> RouteDecision? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        onSubmit?(source)
        conversation.appendUser(text, source: source)
        defer { announceLatestReply() }
        // "yes" / "approve" never approves anything — typed or spoken. Approvals are HUD buttons only (V0.7, DEC-066).
        if store.pendingApproval != nil, ApprovalGuard.isApprovalUtterance(text) {
            let lang = InputNormalizer.normalize(text).language
            conversation.appendJarvis(ApprovalGuard.notice(lang), tone: .notice, route: .local)
            return .localResponse(.approvalNeedsHUD, lang)
        }
        // Project Memory: explicit remember / correct / forget and direct questions about the project's history are answered from RECORDS (no model, no invention).
        if let memory = memoryHandler {
            let command = memory.recognizes(text)
            if command != .none {
                let lang = InputNormalizer.normalize(text).language
                handleMemoryCommand(command, text: text, language: lang, memory: memory, origin: origin, source: source)
                return .localResponse(.memory, lang)
            }
        }
        return dispatch(text, origin: origin, source: source)
    }

    /// The normal routing of one user message (commands, local replies, tasks, research, provider). Split out so a loosely phrased memory question that memory is NOT
    /// confident about can continue here after the memory check.
    @discardableResult
    private func dispatch(_ text: String, origin: InputOrigin, source: InputSource) -> RouteDecision {
        let decision = router.route(text)

        switch decision {
        case .command(let intent, let lang):
            let result = executor.execute(intent, language: lang)
            conversation.appendJarvis(result.message, tone: result.tone, route: .command)

        case .localResponse(let reply, let lang):
            switch reply {
            case .greeting: conversation.appendJarvis(Phrasebook.greeting(lang), route: .local)
            case .thanks: conversation.appendJarvis(Phrasebook.thanks(lang), route: .local)
            case .approvalNeedsHUD: conversation.appendJarvis(ApprovalGuard.notice(lang), tone: .notice, route: .local)
            case .memory: break                                   // answered by handleMemoryCommand
            }

        case .reasoningRequired(let prompt, let lang):
            // "Research this error / find a free animation / compare these libraries" is a web RESEARCH task (read-only, bounded, cited).
            if researchSubmitter != nil, ResearchIntake.isResearchRequest(prompt) {
                handleResearchRequest(prompt, language: lang, channel: source)
            // "Analyze the multiplayer issue" with a project chosen is a bounded read-only TASK; without a project it stays a conversation.
            } else if let intent = GoalIntake.analysis(for: prompt), let submitter = taskSubmitter, submitter.hasProject {
                handleTaskRequest(prompt, intent: intent, language: lang, channel: source)
            } else {
                handleProviderRequest(.reasoning, prompt: prompt, language: lang, origin: origin, presentation: source == .voice ? .voiceConversation : .text)
            }

        case .workerRequired(let prompt, let lang):
            if taskSubmitter != nil { handleTaskRequest(prompt, intent: GoalIntake.development(for: prompt), language: lang, channel: source) }
            else { handleProviderRequest(.worker, prompt: prompt, language: lang, origin: origin, presentation: source == .voice ? .voiceConversation : .text) }

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

    // MARK: Task path (V0.4)

    /// A durable task is created BEFORE any work starts; the reply only confirms what really happened.
    private func handleTaskRequest(_ prompt: String, intent: GoalIntake.Intent, language: ReplyLanguage, channel: InputSource) {
        guard let submitter = taskSubmitter else { return }
        pendingTaskAcks += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingTaskAcks -= 1 }
            switch await submitter.submitTask(goal: prompt, intent: intent, channel: channel) {
            case .started(let title): self.conversation.appendJarvis(Phrasebook.taskStarted(title, readOnly: intent.kind == .readOnlyAnalysis, language), route: .worker)
            case .needsProject: self.conversation.appendJarvis(Phrasebook.needsProject(language), tone: .notice, route: .worker)
            case .rejected(let why): self.conversation.appendJarvis(why, tone: .notice, route: .worker)
            }
            self.announceLatestReply()
        }
    }

    private func handleMemoryCommand(_ command: MemoryCommand, text original: String, language: ReplyLanguage, memory: any MemoryConversing, origin: InputOrigin, source: InputSource) {
        pendingTaskAcks += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingTaskAcks -= 1 }
            if let reply = await memory.reply(to: command, language: language) {
                self.conversation.appendJarvis(reply, route: .local)
                self.announceLatestReply()
            } else {
                _ = self.dispatch(original, origin: origin, source: source)           // memory was not confident: the question goes the normal way
                self.announceLatestReply()
            }
        }
    }

    private func handleResearchRequest(_ prompt: String, language: ReplyLanguage, channel: InputSource) {
        guard let submitter = researchSubmitter else { return }
        pendingTaskAcks += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingTaskAcks -= 1 }
            switch await submitter.submitResearch(goal: prompt, channel: channel) {
            case .started(let title): self.conversation.appendJarvis(Phrasebook.researchStarted(title, language), route: .worker)
            case .needsProject: self.conversation.appendJarvis(Phrasebook.needsProject(language), tone: .notice, route: .worker)
            case .rejected(let why): self.conversation.appendJarvis(why, tone: .notice, route: .worker)
            }
            self.announceLatestReply()
        }
    }

    // MARK: Provider path

    private func handleProviderRequest(_ kind: IntelligenceRequestKind, prompt: String, language: ReplyLanguage, origin: InputOrigin, presentation: ResponsePresentation = .text) {
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

        responseTask = Task { [weak self] in await self?.runProviderRequest(kind, prompt: prompt, language: language, messageID: messageID, presentation: presentation) }
    }

    private struct Attempt {
        var outcome: ProviderOutcome
        var report: RunReport
        var hasContent: Bool
    }

    private func runProviderRequest(_ kind: IntelligenceRequestKind, prompt: String, language: ReplyLanguage, messageID: UUID, presentation: ResponsePresentation = .text) async {
        let memoryContext = await memoryHandler?.conversationContext(for: prompt)
        let resolution = await resolver.resolve(kind, prompt: prompt)
        if Task.isCancelled {                                   // STOP pressed while the provider was still being resolved
            conversation.markCancelled(messageID)
            endResponse(messageID); announceLatestReply()
            return
        }
        guard case .ready(var resolved) = resolution else {
            if case .unavailable(let error) = resolution { conversation.setNotice(messageID, Self.message(for: error, language)) }
            endResponse(messageID)
            announceLatestReply()
            return
        }

        if let memoryContext { memoryHandler?.recordConversationUse(memoryContext, runID: resolved.runID) }

        // Attempt loop. Bounded: the resolver allows at most `maxEscalations` hand-offs, and only in Auto, only after a
        // provider FAILURE that produced no output (never after a user cancel, never once text has streamed).
        var attempt: Attempt
        while true {
            attempt = await runAttempt(resolved, kind: kind, prompt: prompt, language: language, messageID: messageID, presentation: presentation, memoryContext: memoryContext?.text)
            resolver.runFinished(resolved, outcome: attempt.outcome, report: attempt.report)
            if case .failed(let error) = attempt.outcome, !attempt.hasContent, !Task.isCancelled,
               let next = await resolver.escalate(from: resolved, error: error, prompt: prompt) {
                store.log("\(resolved.name) failed — escalating to \(next.name)", kind: .warning)
                resolved = next
                continue
            }
            break
        }

        let outcome = attempt.outcome
        switch outcome {
        case .completed:
            conversation.finish(messageID)
            store.log("\(resolved.name) response completed", kind: .success)
        case .cancelled:
            conversation.markCancelled(messageID)
            store.log("\(resolved.name) response cancelled", kind: .warning)
        case .failed(let error):
            let text = Self.message(for: error, language)
            if attempt.hasContent {
                conversation.finish(messageID)                                  // keep what streamed
                conversation.appendJarvis(text, tone: .notice, route: .reasoning)
            } else {
                conversation.fail(messageID, reason: text)
            }
            store.log("\(resolved.name) failed: \(Self.activityReason(error))", kind: .error)
        }
        endResponse(messageID)
        announceLatestReply()
    }

    /// One provider attempt: start → stream (coalesced) → wait until the provider is really gone → report.
    private func runAttempt(_ resolved: ResolvedProvider, kind: IntelligenceRequestKind, prompt: String, language: ReplyLanguage, messageID: UUID, presentation: ResponsePresentation, memoryContext: String? = nil) async -> Attempt {
        respondingProvider = resolved.id
        respondingProviderName = resolved.name
        respondingRunID = resolved.runID
        conversation.setProvider(messageID, resolved.name)
        resolver.providerStarted(resolved.id)
        store.log("\(resolved.name) response started", kind: .info)

        let request = IntelligenceRequest(id: UUID(), kind: kind, prompt: prompt, history: conversation.messages, language: language,
                                          sessionID: resolver.sessionID(for: resolved.id), presentation: presentation, memoryContext: memoryContext)
        let coalescer = StreamCoalescer(conversation: conversation, id: messageID)
        var outcome = ProviderOutcome.completed
        var sawFinished = false
        var report = RunReport()

        do {
            for try await event in resolved.provider.respond(to: request) {
                try Task.checkCancellation()
                switch event {
                case .session(let s): resolver.recordSession(s, for: resolved.id)
                case .textDelta(let d): coalescer.append(d); report.resultText += d
                case .usage(let i, let o): report.inputTokens = i; report.outputTokens = o
                case .toolAttempt(let t): report.toolAttempts.append(t)
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
        if outcome == .completed && !hasContent {
            let who = resolved.id ?? .claudeCode
            outcome = .failed(.malformedOutput(who))
            store.log("\(resolved.name) returned no answer", kind: .warning)
        }
        resolver.providerFinished(resolved.id, outcome: outcome)
        return Attempt(outcome: outcome, report: report, hasContent: hasContent)
    }

    private func endResponse(_ id: UUID) {
        guard responseMessageID == id else { return }
        isResponding = false
        responseTask = nil
        responseMessageID = nil
        respondingProvider = nil
        respondingProviderName = nil
        respondingRunID = nil
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
