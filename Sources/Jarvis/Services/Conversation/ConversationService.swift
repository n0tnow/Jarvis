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
    /// V0.11: operate native macOS applications (typed and spoken requests alike). nil = such requests stay ordinary conversation.
    @ObservationIgnored weak var computerSubmitter: (any ComputerSubmitting)?
    /// V0.12: status questions ("Durum ne?", "which agent is running?", "did the tests pass?") are answered from the orchestrated task's real graph, not by a model.
    @ObservationIgnored var graphStatus: ((StatusFocus, ReplyLanguage) -> String?)? { didSet { executor.graphStatus = graphStatus } }
    /// V0.10: Project Memory (remember / correct / forget / "what did we decide…"). Typed and spoken text take this same path; nil = memory is not wired (stubbed runs).
    @ObservationIgnored weak var memoryHandler: (any MemoryConversing)?
    /// V0.13: project continuity (“where are we on the Hamam project?”, “continue”). Typed and spoken text take this same path; nil = not wired (stubbed runs).
    @ObservationIgnored weak var continuityHandler: (any ContinuityConversing)?
    /// V0.14: learning and capabilities (“what did you learn?”, “show the MCPs”, “turn Blender MCP off”, “delete Blender MCP”). Typed and spoken text take this same path; a destructive request only
    /// CREATES a request that a HUD button decides — a spoken “yes” never does (ApprovalGuard above). nil = not wired.
    @ObservationIgnored weak var adaptiveHandler: (any AdaptiveConversing)?
    /// V0.15: how an answer is shown (depth, shortening that never hides a failure, the form of address) and the bounded follow-up context. Presentation and references only: neither can approve,
    /// grant or decide anything, and a resolved follow-up is rewritten into an explicit sentence that takes the normal route below.
    @ObservationIgnored let presenter = ResponsePresenter()
    @ObservationIgnored let workingContext = ConversationWorkingContext()
    /// V0.15: “Is Claude ready?”, “Ses sistemi hazır mı?” — answered from the readiness picture. nil = not wired.
    @ObservationIgnored weak var readinessHandler: (any ReadinessConversing)?
    /// V0.15: true while any decision (approval, adaptive request, proposal) waits for a HUD button — a bare “yes” is then caught by `ApprovalGuard`, whatever kind of decision it is.
    @ObservationIgnored var hasPendingDecision: () -> Bool = { false }
    /// Settings → Speak task acknowledgements. Off: the acknowledgement is still shown, just not spoken.
    @ObservationIgnored var speakTaskAcknowledgements: () -> Bool = { true }
    /// V0.15: “Hamam’a dön” — makes a known project the conversation’s project (no permission change).
    @ObservationIgnored var focusProject: ((String) async -> ProjectContinuity.FocusResult)?
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
        let depth = presenter.beginTurn(text)
        workingContext.beginTurn()
        let inputLanguage = InputNormalizer.normalize(text).language
        defer { announceLatestReply() }
        // "yes" / "approve" never approves anything — typed or spoken. Approvals are HUD buttons only (V0.7, DEC-066). V0.15: that holds for EVERY kind of pending decision.
        if (store.pendingApproval != nil || hasPendingDecision()), ApprovalGuard.isApprovalUtterance(text) {
            let lang = inputLanguage
            conversation.appendJarvis(ApprovalGuard.notice(lang), tone: .notice, route: .local)
            return .localResponse(.approvalNeedsHUD, lang)
        }
        // “Detaylı anlat.” / “Kısa söyle.” on its own: the answer IMMEDIATELY BEFORE this request again, at that depth (no model). The target is read from the conversation itself — the last
        // JARVIS message of the previous turn — so it can never be an older answer.
        if let d = depth, d.bare, !d.weak {          // “Explain it again” / “Neden?” are questions for the model, not a depth change
            let again = presenter.rerender(previous: previousAnswerForDepthRequest(), depth: d.depth, language: inputLanguage)
            conversation.appendJarvis(again, route: .local)
            return .localResponse(.contextual, inputLanguage)
        }
        // “Hamam’a dön”: the conversation's project changes (and what belonged to the old one is dropped). Nothing is selected for writing.
        if let request = ProjectSwitchParser.parse(text), let focus = focusProject, !isNavigationCommand(text) {
            handleProjectFocus(request, original: text, origin: origin, source: source, focus: focus, language: inputLanguage)
            return .localResponse(.contextual, inputLanguage)
        }
        // Follow-ups (“ikincisini dene”, “onu kullan”, “biraz sola al”): resolved against the bounded working context, or asked about. Never from recency for anything destructive.
        switch ReferenceResolver.resolve(text, context: workingContext, language: inputLanguage) {
        case .notFollowUp: break
        case .ask(let question), .nothing(let question):
            conversation.appendJarvis(question, tone: .notice, route: .local)
            return .localResponse(.contextual, inputLanguage)
        case .resolved(let goal, let chosen, let id):
            workingContext.select(id)
            conversation.appendJarvis(chosen, route: .local)
            return dispatch(goal, origin: origin, source: source)
        }
        // Project continuity: project status questions and “continue” are resolved against CURRENT project truth (no model, no invention); “continue” becomes an ordinary bounded task.
        if let continuity = continuityHandler, let intent = continuity.recognizes(text) {
            let lang = InputNormalizer.normalize(text).language
            handleContinuity(intent, language: lang, source: source)
            return .localResponse(.continuity, lang)
        }
        // Adaptive learning and the capability registry: answered from persisted records; management acts only inside its authority (never an approval).
        if let adaptive = adaptiveHandler {
            adaptive.observe(text)                                                   // a correction becomes an OBSERVATION for learning; it never changes a rule by itself
            if let intent = adaptive.recognizes(text) {
                let lang = InputNormalizer.normalize(text).language
                handleAdaptive(intent, language: lang, source: source)
                return .localResponse(.adaptive, lang)
            }
        }
        // Readiness questions (“Claude hazır mı?”, “is the voice system ready?”): answered from the readiness picture; nothing is started or installed.
        if let readiness = readinessHandler, let intent = readiness.recognizes(text) {
            let lang = inputLanguage
            let full = readiness.reply(to: intent, language: lang)
            conversation.appendJarvis(presenter.present(full: full, language: lang, evidence: true), route: .local)
            return .localResponse(.contextual, lang)
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
            case .greeting: conversation.appendJarvis(presenter.addressed(Phrasebook.greeting(lang), moment: .greeting, language: lang), route: .local)
            case .thanks: conversation.appendJarvis(Phrasebook.thanks(lang), route: .local)
            case .approvalNeedsHUD: conversation.appendJarvis(ApprovalGuard.notice(lang), tone: .notice, route: .local)
            case .memory, .continuity, .adaptive, .contextual: break           // answered by handleMemoryCommand / handleContinuity / handleAdaptive
            }

        case .reasoningRequired(let prompt, let lang):
            if computerSubmitter != nil, handleComputerIfAny(prompt, language: lang, channel: source) { return decision }
            // V0.12: a COMPOUND goal about the project ("find the problems, research current docs if needed, fix it, run the tests") is one orchestrated task, even when it mentions research.
            if let submitter = taskSubmitter, submitter.hasProject, GoalCues.isCompound(prompt) {
                handleTaskRequest(prompt, intent: GoalCues.fix(prompt) ? GoalIntake.development(for: prompt) : GoalIntake.Intent(kind: .readOnlyAnalysis, destructive: false), language: lang, channel: source, compound: true)
                return decision
            }
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
            if computerSubmitter != nil, handleComputerIfAny(prompt, language: lang, channel: source) { return decision }
            if taskSubmitter != nil { handleTaskRequest(prompt, intent: GoalIntake.development(for: prompt), language: lang, channel: source, compound: GoalCues.isCompound(prompt)) }
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
    private func handleTaskRequest(_ prompt: String, intent: GoalIntake.Intent, language: ReplyLanguage, channel: InputSource, compound: Bool = false) {
        guard let submitter = taskSubmitter else { return }
        pendingTaskAcks += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingTaskAcks -= 1 }
            switch await submitter.submitTask(goal: prompt, intent: intent, channel: channel) {
            case .started(let title):
                let readOnly = intent.kind == .readOnlyAnalysis
                let full = compound ? Phrasebook.orchestratedStarted(title, language) : Phrasebook.taskStarted(title, readOnly: readOnly, language)
                let brief = compound ? DailyPhrasebook.orchestratedAccepted(language) : DailyPhrasebook.taskAccepted(readOnly: readOnly, language)
                self.conversation.appendJarvis(self.acknowledgement(full: full, brief: brief, language: language), route: .worker, silent: !self.speakTaskAcknowledgements())
                self.workingContext.note(kind: .completedAction, refID: "last-request", label: title, source: .userStated, evidence: "task-request", payload: prompt)
            case .needsProject: self.conversation.appendJarvis(Phrasebook.needsProject(language), tone: .notice, route: .worker)
            case .rejected(let why): self.conversation.appendJarvis(why, tone: .notice, route: .worker)
            }
            self.announceLatestReply()
        }
    }

    private func handleContinuity(_ intent: ContinuityIntent, language: ReplyLanguage, source: InputSource) {
        guard let continuity = continuityHandler else { return }
        pendingTaskAcks += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingTaskAcks -= 1 }
            let reply = await continuity.reply(to: intent, language: language, channel: source)
            self.conversation.appendJarvis(reply, route: .local)
            self.announceLatestReply()
        }
    }

    private func handleAdaptive(_ intent: AdaptiveIntent, language: ReplyLanguage, source: InputSource) {
        guard let adaptive = adaptiveHandler else { return }
        pendingTaskAcks += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingTaskAcks -= 1 }
            let reply = await adaptive.reply(to: intent, language: language, channel: source)
            self.conversation.appendJarvis(self.presenter.present(full: reply, language: language), route: .local)
            self.announceLatestReply()
        }
    }

    private func handleMemoryCommand(_ command: MemoryCommand, text original: String, language: ReplyLanguage, memory: any MemoryConversing, origin: InputOrigin, source: InputSource) {
        pendingTaskAcks += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingTaskAcks -= 1 }
            if let reply = await memory.reply(to: command, language: language) {
                self.conversation.appendJarvis(self.presenter.present(full: reply, language: language, evidence: true), route: .local)
                self.announceLatestReply()
            } else {
                _ = self.dispatch(original, origin: origin, source: source)           // memory was not confident: the question goes the normal way
                self.announceLatestReply()
            }
        }
    }

    /// The capability ladder decides: a goal a stronger mechanism owns (project tools, Unity bridge, research, Git) continues down the normal path; only what is left is Computer Use.
    private func handleComputerIfAny(_ prompt: String, language: ReplyLanguage, channel: InputSource) -> Bool {
        guard let submitter = computerSubmitter else { return false }
        switch submitter.classifyComputer(prompt) {
        case .notComputer, .delegate: return false
        case .refused(let why):
            conversation.appendJarvis(why, tone: .notice, route: .local)
            return true
        case .computer:
            pendingTaskAcks += 1
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.pendingTaskAcks -= 1 }
                switch await submitter.submitComputer(goal: prompt, channel: channel) {
                case .started(let title):
                    self.conversation.appendJarvis(self.acknowledgement(full: Phrasebook.computerStarted(title, language), brief: DailyPhrasebook.computerAccepted(language), language: language), route: .worker, silent: !self.speakTaskAcknowledgements())
                    self.workingContext.note(kind: .completedAction, refID: "last-request", label: title, source: .userStated, evidence: "task-request", payload: prompt)
                case .needsProject: self.conversation.appendJarvis(Phrasebook.needsProject(language), tone: .notice, route: .worker)
                case .rejected(let why): self.conversation.appendJarvis(why, tone: .notice, route: .worker)
                }
                self.announceLatestReply()
            }
            return true
        }
    }

    private func handleResearchRequest(_ prompt: String, language: ReplyLanguage, channel: InputSource) {
        guard let submitter = researchSubmitter else { return }
        pendingTaskAcks += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingTaskAcks -= 1 }
            switch await submitter.submitResearch(goal: prompt, channel: channel) {
            case .started(let title):
                self.conversation.appendJarvis(self.acknowledgement(full: Phrasebook.researchStarted(title, language), brief: DailyPhrasebook.researchAccepted(language), language: language), route: .worker, silent: !self.speakTaskAcknowledgements())
                self.workingContext.note(kind: .completedAction, refID: "last-request", label: title, source: .userStated, evidence: "task-request", payload: prompt)
            case .needsProject: self.conversation.appendJarvis(Phrasebook.needsProject(language), tone: .notice, route: .worker)
            case .rejected(let why): self.conversation.appendJarvis(why, tone: .notice, route: .worker)
            }
            self.announceLatestReply()
        }
    }

    /// The words for “a task was created”: short by default, the original explanation when the user asked for detail or chose the Detailed style. Says only that the task exists.
    private func acknowledgement(full: String, brief: String, language: ReplyLanguage) -> String {
        let expanded = presenter.lastDepth.expands || presenter.style() == .detailed
        return presenter.addressed(expanded ? full : brief, moment: .taskAccepted, language: language)
    }

    /// The text of the JARVIS answer that came immediately before the current user message — nil when the previous turn was not answered (still streaming, failed to answer, cleared) or there is none.
    private func previousAnswerForDepthRequest() -> String? {
        let m = conversation.messages
        guard m.count >= 2, m[m.count - 1].role == .user else { return nil }
        let prior = m[m.count - 2]
        return prior.role == .jarvis && prior.status == .complete && !prior.content.isEmpty ? prior.content : nil
    }

    /// “go to system”, “switch to compact”, “open the report”: deterministic commands win over a project switch.
    private func isNavigationCommand(_ text: String) -> Bool { if case .command = router.route(text) { return true }; return false }

    private func handleProjectFocus(_ request: ProjectSwitchParser.Request, original: String, origin: InputOrigin, source: InputSource, focus: @escaping (String) async -> ProjectContinuity.FocusResult, language: ReplyLanguage) {
        pendingTaskAcks += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingTaskAcks -= 1 }
            switch await focus(request.name) {
            case .found(let projectName, let key):
                self.workingContext.projectChanged(to: key)
                self.workingContext.note(kind: .project, refID: key, label: projectName, source: .userStated, evidence: "user-request")
                self.conversation.appendJarvis(language == .tr ? "Konuşma “\(projectName)” projesine döndü. İzinler değişmedi." : "Back on “\(projectName)”. Permissions are unchanged.", route: .local)
            case .unknown(let n, let known):
                guard request.explicit else { _ = self.dispatch(original, origin: origin, source: source); self.announceLatestReply(); return }          // “back to work” is just a sentence
                let list = known.isEmpty ? "" : (language == .tr ? " Bildiğim projeler: \(known.joined(separator: ", "))." : " Known projects: \(known.joined(separator: ", ")).")
                self.conversation.appendJarvis(language == .tr ? "“\(n)” adında bir proje tanımıyorum.\(list)" : "I do not know a project called “\(n)”.\(list)", tone: .notice, route: .local)
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
