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
    /// Natural requests that change a typed setting (speech speed, address, answer length, wake word …): applied, read back, then reported. Never a model call.
    @ObservationIgnored weak var settingsHandler: (any SettingsConversing)?
    /// What really went where (setting / Project Memory / task record / nowhere) — answers “nereye kaydettin?” and “will you remember that?”.
    @ObservationIgnored var storageLedger: StorageLedger?
    /// Typed actions (open an application, a folder, a JARVIS page): executed deterministically, verified, and reported from an `ActionReceipt` (V1.0 fix 4). Never a model call.
    @ObservationIgnored weak var actionService: ActionService?
    /// V1.0 decision milestone: the typed Decision layer (deterministic grammar first, optional remote classifier in shadow/gated mode). ADVISORY: it picks which existing handler takes an utterance and
    /// records why; it cannot execute, approve or claim anything. nil (tests that predate it) = the pipeline below runs exactly as before.
    @ObservationIgnored var decisionEngine: DecisionEngine?
    /// Facts the decision planner reads (voice pipeline state, fresh Computer Use observations, the application list, the project registry). All read-only; nothing is probed by asking.
    @ObservationIgnored var voiceFacts: ((_ heardViaVoice: Bool) -> VoiceStatusFacts)?
    @ObservationIgnored var observedApps: (() -> [ObservedApp])?
    @ObservationIgnored var isAppRunning: ((String) -> Bool?)?
    @ObservationIgnored var knownProjects: (() async -> [KnownProject])?
    @ObservationIgnored var currentProjectRoot: (() -> String?)?
    /// Opens a resolved project: makes it the conversation's project and reveals its folder, as a verified receipt (never a guess, never a write).
    @ObservationIgnored var openProject: ((KnownProject) async -> ActionReceipt)?
    /// Current truth about a project folder / its engine kind (files on disk). Injected so a test can use a fixture registry without real folders.
    @ObservationIgnored var projectPathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    @ObservationIgnored var projectIsKind: (String, String) -> Bool = { ProjectOpenResolver.markerExists(root: $0, kind: $1) }
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
        let shown = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shown.isEmpty else { return nil }
        // A voice transcript gets the closed repair table for JARVIS' own vocabulary (“weak word” → “wake word”); what the user sees stays what was heard.
        let text0 = source == .voice ? SpeechTranscriptRepair.repair(shown) : shown

        onSubmit?(source)
        let previousTurn = capturePreviousTurn()                   // read BEFORE this message joins the transcript
        let interpretedBefore = currentInterpretation
        currentInterpretationBeforeTurn = interpretedBefore
        currentInterpretation = "conversation"
        conversation.appendUser(shown, source: source)
        let initialDepth = presenter.beginTurn(text0)
        workingContext.beginTurn()
        storageLedger?.beginTurn()
        let inputLanguage = InputNormalizer.normalize(shown).language
        defer { announceLatestReply() }
        // "yes" / "approve" never approves anything — typed or spoken. Approvals are HUD buttons only (V0.7, DEC-066). V0.15: that holds for EVERY kind of pending decision.
        if (store.pendingApproval != nil || hasPendingDecision()), ApprovalGuard.isApprovalUtterance(text0) {
            let lang = inputLanguage
            conversation.appendJarvis(ApprovalGuard.notice(lang), tone: .notice, route: .local)
            return .localResponse(.approvalNeedsHUD, lang)
        }
        // A correction (“Hayır, demek istediğim …”, “No, I meant …”): the corrected sentence is routed again from scratch, with the previous turn kept in the bounded working context. A bare
        // “yanlış anladın” asks what was meant. It carries no authority and passes every check the corrected request would have passed on its own.
        var text: String
        switch resolveCorrection(text0, previous: previousTurn, interpretedBefore: interpretedBefore, language: inputLanguage) {
        case .none: text = text0
        case .ask(let question):
            conversation.appendJarvis(question, tone: .notice, route: .local)
            return .localResponse(.contextual, inputLanguage)
        case .reroute(let corrected): text = corrected; currentInterpretation = "correction"
        }
        let depth = text == text0 ? initialDepth : ResponseDepthDetector.detect(text)
        // V1.0 decision milestone: a typed Decision first. Known, unambiguous commands (system / voice status, JARVIS pages, stop speech, cancel task, project open / continue, media, “look at my screen”, visibility
        // questions, settings, spoken restatements, blocked requests) are routed here WITHOUT a language model; everything else returns nil and the pipeline below runs unchanged.
        var decisionOutcome: DecisionEngine.Outcome?
        if let engine = decisionEngine {
            var rewrites = 0
            while true {
                let outcome = engine.decide(text, context: DecisionContext(source: source == .voice ? .voice : .typed, previousInterpretation: interpretedBefore, previousUserText: previousTurn?.user ?? "", hasPendingDecision: store.pendingApproval != nil || hasPendingDecision()), language: inputLanguage)
                decisionOutcome = outcome
                switch routeByDecision(outcome, text: text, language: inputLanguage, source: source, origin: origin) {
                case .handled(let r): return r
                case .rewrite(let corrected) where rewrites < 1:
                    // “Sofany değil, Safari dedim.”: the previous sentence with the word corrected (or the restated sentence) takes the normal route, once. The transcript keeps what was really said.
                    rewrites += 1
                    conversation.appendJarvis(inputLanguage == .tr ? "Anladım — “\(corrected)” olarak okudum." : "Understood — I read that as “\(corrected)”.", tone: .notice, route: .local)
                    text = corrected; currentInterpretation = "correction"
                    continue
                default: break
                }
                break
            }
        }
        // An action request — “Safari'yi aç”, “Safari'yi açabilir misin?”, “System panelini aç”, “Dashboard'a dön”: executed, verified, and answered from the RECEIPT. A polite question about doing
        // something JARVIS can do is a request, not a conversation; the language model is never involved and never gets to say it was done.
        if let actions = actionService, let intent = actions.recognizes(text) {
            currentInterpretation = "action"
            handleAction(intent, with: actions, language: inputLanguage)
            return .localResponse(.contextual, inputLanguage)
        }
        // Settings requests (“Konuşma hızını biraz arttır”, “Bana efendim diye hitap et”, “Wake word'ü kapat”): typed, validated, read back, then reported (V1.0 fix 2). Strict grammar, so a real
        // request keeps its route; the language model is never asked and Project Memory is never used for a preference.
        if let settings = settingsHandler, let intent = settings.recognizes(text) {
            currentInterpretation = "settings: \(intent)"
            conversation.appendJarvis(presenter.present(full: settings.perform(intent, language: inputLanguage), language: inputLanguage, evidence: true), route: .local)
            return .localResponse(.contextual, inputLanguage)
        }
        // “Bunu nereye kaydettin?” / “Kalıcı mı?” / “Will you remember that?”: answered from what was REALLY written, never from habit.
        if let ledger = storageLedger, let q = StorageQuestionParser.recognize(text) {
            currentInterpretation = "storage"
            conversation.appendJarvis(presenter.present(full: ledger.reply(to: q, language: inputLanguage), language: inputLanguage, evidence: true), route: .local)
            return .localResponse(.contextual, inputLanguage)
        }
        // “Detaylı anlat.” / “Kısa söyle.” on its own: the answer IMMEDIATELY BEFORE this request again, at that depth (no model). The target is read from the conversation itself — the last
        // JARVIS message of the previous turn — so it can never be an older answer.
        if let d = depth, d.bare, !d.weak {          // “Explain it again” / “Neden?” are questions for the model, not a depth change
            currentInterpretation = "depth"
            let again = presenter.rerender(previous: previousAnswerForDepthRequest(), depth: d.depth, language: inputLanguage)
            conversation.appendJarvis(again, route: .local)
            return .localResponse(.contextual, inputLanguage)
        }
        // “Hamam’a dön”: the conversation's project changes (and what belonged to the old one is dropped). Nothing is selected for writing.
        if let request = ProjectSwitchParser.parse(text), let focus = focusProject, !isNavigationCommand(text) {
            currentInterpretation = "project"
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
            currentInterpretation = "follow-up"
            workingContext.select(id)
            conversation.appendJarvis(chosen, route: .local)
            return dispatch(goal, origin: origin, source: source)
        }
        // Project continuity: project status questions and “continue” are resolved against CURRENT project truth (no model, no invention); “continue” becomes an ordinary bounded task.
        if let continuity = continuityHandler, let intent = continuity.recognizes(text) {
            currentInterpretation = "continuity"
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
            currentInterpretation = "readiness: \(intent)"
            let lang = inputLanguage
            let forms = readiness.replyForms(to: intent, language: lang)
            conversation.appendJarvis(presenter.present(full: forms.full, short: forms.short, language: lang, evidence: forms.short == nil), route: .local)
            return .localResponse(.contextual, lang)
        }
        // Project Memory: explicit remember / correct / forget and direct questions about the project's history are answered from RECORDS (no model, no invention).
        if let memory = memoryHandler {
            let command = memory.recognizes(text)
            if command != .none {
                currentInterpretation = "memory"
                let lang = InputNormalizer.normalize(text).language
                handleMemoryCommand(command, text: text, language: lang, memory: memory, origin: origin, source: source)
                return .localResponse(.memory, lang)
            }
        }
        // GATED remote classification (off unless the user turned it on): only for what the grammar did not understand, and only the closed read-only set in `GatedPolicy` can be accepted.
        if let engine = decisionEngine, engine.config().mode == .gated, let outcome = decisionOutcome, outcome.decision.intent == .unknown {
            handleGated(outcome, text: text, language: inputLanguage, source: source, origin: origin)
            return .localResponse(.contextual, inputLanguage)
        }
        return dispatch(text, origin: origin, source: source)
    }

    // MARK: Decision routing (V1.0 decision milestone)

    private func decisionFacts(language: ReplyLanguage, source: InputSource, previous: (user: String, answer: String)?, interpretedBefore: String, projects: [KnownProject]) -> DecisionFacts {
        let voice = voiceFacts?(source == .voice) ?? VoiceStatusFacts(voiceOn: source == .voice, pushToTalkOn: false, wakeEnabled: false, wakeRunning: false, microphone: .unknown, recogniserReady: nil, heardViaVoice: source == .voice)
        var f = DecisionFacts(language: language, source: source == .voice ? .voice : .typed, voice: voice)
        f.observations = observedApps?() ?? []
        f.isAppRunning = { [weak self] name in self?.isAppRunning?(name) }
        f.projects = projects
        f.currentProjectRoot = currentProjectRoot?()
        f.previousUserText = previous?.user ?? ""
        f.previousInterpretation = interpretedBefore
        f.computerAvailable = computerSubmitter != nil
        f.actionLookup = { [weak self] text in self?.actionService?.recognizes(text) }
        f.pathExists = projectPathExists
        f.isKind = projectIsKind
        return f
    }

    private enum DecisionRouting { case handled(RouteDecision), rewrite(String), next }

    /// `.next` = the existing pipeline continues. `.handled` = the Decision layer routed the utterance to an existing capability. `.rewrite` = a spoken correction produced a sentence to route again.
    private func routeByDecision(_ outcome: DecisionEngine.Outcome, text: String, language: ReplyLanguage, source: InputSource, origin: InputOrigin) -> DecisionRouting {
        let d = outcome.decision
        guard d.isDeterministic || (d.provider == .deterministic && d.gate == .blocked) else { return .next }          // a blocked request is refused even when it has no other intent
        let previous = capturePreviousTurnForDecision()
        if d.intent == .projectOpen, knownProjects != nil {
            currentInterpretation = "project"
            pendingTaskAcks += 1
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.pendingTaskAcks -= 1 }
                let projects = await self.knownProjects?() ?? []
                let facts = self.decisionFacts(language: language, source: source, previous: previous, interpretedBefore: self.currentInterpretationBeforeTurn, projects: projects)
                _ = self.execute(DecisionPlanner.plan(d, text: text, facts: facts), outcome: outcome, text: text, language: language, source: source)
                self.announceLatestReply()
            }
            return .handled(.localResponse(.contextual, language))
        }
        let facts = decisionFacts(language: language, source: source, previous: previous, interpretedBefore: currentInterpretationBeforeTurn, projects: [])
        return execute(DecisionPlanner.plan(d, text: text, facts: facts), outcome: outcome, text: text, language: language, source: source)
    }

    /// The interpretation of the PREVIOUS turn as seen when this one started (the field is reset to "conversation" at the top of `submit`).
    @ObservationIgnored private var currentInterpretationBeforeTurn = "conversation"

    private func capturePreviousTurnForDecision() -> (user: String, answer: String)? {
        let msgs = conversation.messages
        // the current user message was just appended: the previous turn is the user message before it
        guard let last = msgs.lastIndex(where: { $0.role == .user }), let uIdx = msgs[..<last].lastIndex(where: { $0.role == .user }) else { return nil }
        let answer = msgs[(uIdx + 1)..<last].last(where: { $0.role == .jarvis })?.content ?? ""
        return (msgs[uIdx].content, answer)
    }

    private func execute(_ plan: DecisionPlan, outcome: DecisionEngine.Outcome, text: String, language: ReplyLanguage, source: InputSource) -> DecisionRouting {
        let engine = decisionEngine
        switch plan {
        case .passThrough:
            return .next
        case .answer(let reply, let tone):
            currentInterpretation = "decision: \(outcome.decision.intent.rawValue)"
            engine?.record(outcome.id, route: "answer", executor: "grounded facts", outcome: tone == .normal ? "answered" : "answered (nothing claimed beyond the evidence)")
            conversation.appendJarvis(presenter.present(full: reply, language: language, evidence: true), tone: tone == .normal ? .normal : .notice, route: .local)
            return .handled(.localResponse(.contextual, language))
        case .systemStatus(let scope):
            guard let readiness = readinessHandler else { return .next }
            currentInterpretation = "readiness: system status"
            engine?.record(outcome.id, route: "system status", executor: "SystemStatusSnapshot", outcome: "answered from the structured state")
            let forms = readiness.replyForms(to: .systemStatus(scope), language: language)
            conversation.appendJarvis(presenter.present(full: forms.full, short: forms.short, language: language, evidence: forms.short == nil), route: .local)
            return .handled(.localResponse(.contextual, language))
        case .action(let typed):
            guard let actions = actionService, let intent = typed ?? actions.recognizes(text) else { return .next }
            currentInterpretation = "action"
            engine?.record(outcome.id, route: "action", executor: "ActionService", outcome: "executing; the reply comes from the verified receipt")
            handleAction(intent, with: actions, language: language, decisionID: outcome.id)
            return .handled(.localResponse(.contextual, language))
        case .settings:
            guard let settings = settingsHandler, let intent = settings.recognizes(text) else { return .next }
            currentInterpretation = "settings: \(intent)"
            engine?.record(outcome.id, route: "settings", executor: "SettingsAssistant", outcome: "applied and read back")
            conversation.appendJarvis(presenter.present(full: settings.perform(intent, language: language), language: language, evidence: true), route: .local)
            return .handled(.localResponse(.contextual, language))
        case .stopSpeech:
            currentInterpretation = "command"
            engine?.record(outcome.id, route: "stop speech", executor: "CommandExecutor", outcome: "speech and generation stopped")
            let result = executor.execute(.cancelGeneration, language: language)
            conversation.appendJarvis(result.message, tone: result.tone, route: .command)
            return .handled(.command(.cancelGeneration, language))
        case .cancelTask:
            currentInterpretation = "command"
            engine?.record(outcome.id, route: "cancel task", executor: "CommandExecutor", outcome: "the task engine's stop")
            let result = executor.execute(.stopTask, language: language)
            conversation.appendJarvis(result.message, tone: result.tone, route: .command)
            return .handled(.command(.stopTask, language))
        case .openProject(let project):
            guard let open = openProject else { return .next }
            currentInterpretation = "project"
            engine?.record(outcome.id, route: "project open", executor: "project registry + NSWorkspace", outcome: "opening \(project.name)")
            pendingTaskAcks += 1
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.pendingTaskAcks -= 1 }
                let receipt = await open(project)
                self.decisionEngine?.record(outcome.id, route: "project open", executor: receipt.executor, verification: receipt.verification.map { "\($0.method): \($0.detail)" }, outcome: receipt.successIsClaimable ? "verified" : receipt.status.rawValue)
                var line = ActionPhrasebook.render(receipt, language: language)
                if receipt.successIsClaimable {
                    self.workingContext.projectChanged(to: project.key)
                    self.workingContext.note(kind: .project, refID: project.key, label: project.name, source: .userStated, evidence: "user-request")
                    line += language == .tr ? " Unity Editor'ünü açmadım; Unity işleri gerektiğinde ayrı ve izinli çalışır." : " I did not launch the Unity Editor; Unity work runs separately when a task needs it."
                }
                self.conversation.appendJarvis(self.presenter.present(full: line, language: language, evidence: true), tone: receipt.successIsClaimable ? .normal : .notice, route: .command)
                self.announceLatestReply()
            }
            return .handled(.localResponse(.contextual, language))
        case .continueProject(let sentence):
            guard let continuity = continuityHandler, let intent = continuity.recognizes(sentence) else { return .next }
            currentInterpretation = "continuity"
            engine?.record(outcome.id, route: "continue project", executor: "ProjectContinuity → TaskEngine", outcome: "one bounded task, or a question")
            handleContinuity(intent, language: language, source: source)
            return .handled(.localResponse(.continuity, language))
        case .computer(let prompt):
            guard computerSubmitter != nil else { return .next }
            currentInterpretation = "computer"
            engine?.record(outcome.id, route: "computer use", executor: "Computer Use", outcome: "handed to the computer classifier (observe → act → verify)")
            return handleComputerIfAny(prompt, language: language, channel: source) ? .handled(.workerRequired(prompt: prompt, language)) : .next
        case .reroute(let sentence):
            engine?.record(outcome.id, route: "correction", executor: nil, outcome: "the corrected sentence is routed again")
            return .rewrite(sentence)
        }
    }

    private func handleGated(_ outcome: DecisionEngine.Outcome, text: String, language: ReplyLanguage, source: InputSource, origin: InputOrigin) {
        pendingTaskAcks += 1
        Task { @MainActor [weak self] in
            guard let self, let engine = self.decisionEngine else { return }
            defer { self.pendingTaskAcks -= 1 }
            let context = DecisionContext(source: source == .voice ? .voice : .typed, previousInterpretation: self.currentInterpretationBeforeTurn, previousUserText: "", hasPendingDecision: self.store.pendingApproval != nil || self.hasPendingDecision())
            if let accepted = await engine.consultGated(text, context: context, outcome: outcome, language: language) {
                let facts = self.decisionFacts(language: language, source: source, previous: nil, interpretedBefore: self.currentInterpretationBeforeTurn, projects: [])
                let plan = DecisionPlanner.plan(accepted, text: text, facts: facts)
                if plan != .passThrough, case .handled = self.execute(plan, outcome: outcome, text: text, language: language, source: source) { self.announceLatestReply(); return }
            }
            _ = self.dispatch(text, origin: origin, source: source)
            self.announceLatestReply()
        }
    }

    private func handleAction(_ intent: ActionIntent, with actions: ActionService, language: ReplyLanguage, decisionID: UUID? = nil) {
        pendingTaskAcks += 1
        Task { @MainActor [weak self, weak actions] in
            guard let self, let actions else { return }
            defer { self.pendingTaskAcks -= 1 }
            let receipt = await actions.perform(intent)
            if let decisionID { self.decisionEngine?.record(decisionID, route: "action", executor: receipt.executor, verification: receipt.verification.map { "\($0.method): \($0.detail)" }, outcome: receipt.successIsClaimable ? "verified success" : "\(receipt.status.rawValue)\(receipt.error.map { ": " + $0 } ?? "")") }
            var text = ActionPhrasebook.render(receipt, language: language)
            let ok = receipt.successIsClaimable
            // A sound-shape match is a guess: say what was understood (only when it worked; a wrong guess is then visible and one sentence from being corrected).
            if ok, case .launchApp(let app) = intent, let heard = app.heardAs, ComputerText.fold(heard) != ComputerText.fold(app.display) {
                let prefix = language == .tr ? "“\(heard)” için \(app.display) uygulamasını anladım. " : "I took “\(heard)” to mean \(app.display). "
                text = prefix + text
            }
            self.conversation.appendJarvis(self.presenter.present(full: text, language: language, evidence: true), tone: ok ? .normal : .notice, route: .command)
            self.announceLatestReply()
        }
    }

    // MARK: Corrections (V1.0 fix 2)

    /// The interpretation JARVIS gave the PREVIOUS turn (“readiness”, “settings”, “memory”, “conversation”…): part of the bounded working context, never an authority.
    @ObservationIgnored private var currentInterpretation = "conversation"

    private func capturePreviousTurn() -> (user: String, answer: String)? {
        let msgs = conversation.messages
        guard let uIdx = msgs.lastIndex(where: { $0.role == .user }) else { return nil }
        let answer = msgs[(uIdx + 1)...].last(where: { $0.role == .jarvis })?.content ?? ""
        return (msgs[uIdx].content, answer)
    }

    private enum CorrectionResolution { case none, ask(String), reroute(String) }

    private func resolveCorrection(_ text: String, previous: (user: String, answer: String)?, interpretedBefore: String, language l: ReplyLanguage) -> CorrectionResolution {
        guard let c = CorrectionParser.parse(text), let prev = previous else { return .none }
        let pendingDecision = store.pendingApproval != nil || hasPendingDecision()
        // A bare “hayır” answers a question that is waiting (a decision, a clarification) or corrects a Project Memory record: neither is a conversational correction.
        if c.strength == .weak, interpretedBefore.hasPrefix("memory") { return .none }
        if c.remainder.isEmpty, c.strength == .weak, pendingDecision || workingContext.clarification != nil { return .none }
        let turn = TurnMemory(userText: prev.user, interpretation: interpretedBefore, answer: prev.answer)
        workingContext.recordTurn(turn)
        workingContext.markCorrection(of: turn)
        if c.remainder.isEmpty {
            let what = TurnMemory.clip(prev.user)
            return .ask(l == .tr ? "Yanlış anladıysam özür dilerim. “\(what)” demiştiniz; ben bunu “\(Self.describe(interpretedBefore, l))” diye okudum. Asıl neyi kastettiniz?"
                                 : "Sorry if I misunderstood. You said “\(what)”, and I read it as “\(Self.describe(interpretedBefore, l))”. What did you mean?")
        }
        // A short fragment (“yavaşlat”) after a SETTINGS change takes that setting as its subject; after anything else it is just the corrected request.
        let isFragment = c.remainder.split(whereSeparator: { $0.isWhitespace }).count <= 3
        let completed = (interpretedBefore.hasPrefix("settings") && isFragment) ? settingsHandler?.completeFragment(c.remainder) : nil
        return .reroute(completed ?? c.remainder)
    }

    private static func describe(_ interpretation: String, _ l: ReplyLanguage) -> String {
        let base = interpretation.split(separator: ":").first.map(String.init) ?? interpretation
        switch (base, l) {
        case ("readiness", .tr): return "bir durum/yetenek sorusu"; case ("readiness", .en): return "a question about my status or abilities"
        case ("settings", .tr): return "bir ayar isteği"; case ("settings", .en): return "a settings request"
        case ("storage", .tr): return "nereye kaydedildiği sorusu"; case ("storage", .en): return "a question about where something was saved"
        case ("memory", .tr): return "bir proje hafızası komutu"; case ("memory", .en): return "a Project Memory command"
        case ("depth", .tr): return "daha kısa/uzun anlatma isteği"; case ("depth", .en): return "a request for a shorter or longer answer"
        case ("project", .tr): return "bir proje değişikliği"; case ("project", .en): return "a project switch"
        case ("continuity", .tr): return "bir proje durumu isteği"; case ("continuity", .en): return "a project status request"
        case ("follow-up", .tr): return "bir devam isteği"; case ("follow-up", .en): return "a follow-up"
        default: return l == .tr ? "genel bir soru/istek" : "a general question or request"
        }
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
        // typed actions / task acknowledgements land after their read-back; idle means those replies are in the conversation too (bounded)
        let deadline = Date().addingTimeInterval(10)
        while pendingTaskAcks > 0, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
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
                self.storageLedger?.record(.taskRecord, title)
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
                switch command {
                case .remember(let what), .correct(let what):
                    if memory.lastCommandStored { self.storageLedger?.record(.projectMemory, (language == .tr ? "“\(MemoryText.clip(what, 60))” — \(memory.currentProjectName ?? "proje")" : "“\(MemoryText.clip(what, 60))” — \(memory.currentProjectName ?? "project")")) }
                    else { self.storageLedger?.record(.notStored, language == .tr ? "Proje Hafızası'na kaydedilmedi; \(MemoryText.clip(what, 60)) hiçbir yerde saklanmıyor." : "It was not saved to Project Memory; “\(MemoryText.clip(what, 60))” is stored nowhere.") }
                default: break
                }
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
                    self.storageLedger?.record(.taskRecord, title)
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
                self.storageLedger?.record(.taskRecord, title)
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
            applyCapabilityFirewall(to: messageID, language: language)
            applyAddressCadence(to: messageID, language: language)
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

    /// Provider identity firewall: an engine's claim about what JARVIS can or cannot do (screen, files, memory, computer) is replaced by JARVIS' own statement from its readiness state.
    private func applyCapabilityFirewall(to messageID: UUID, language: ReplyLanguage) {
        guard let text = conversation.messages.last(where: { $0.id == messageID })?.content else { return }
        // (1) An engine reply that claims it DID something has no receipt behind it: the engine cannot execute anything.
        let actionClaims = ActionClaimGuard.claims(in: text)
        if !actionClaims.isEmpty {
            conversation.replaceContent(messageID, with: ActionClaimGuard.replacement(for: text, claims: actionClaims, language: language))
            store.log("Engine reply claimed an action that no receipt backs — replaced by a true notice", kind: .warning)
            return
        }
        // (2) Claims about what JARVIS can or cannot do.
        let found = CapabilityClaimGuard.findings(in: text)
        guard !found.isEmpty else { return }
        let grounded = readinessHandler?.reply(to: .capabilities, language: language) ?? ""
        conversation.replaceContent(messageID, with: CapabilityClaimGuard.replacement(for: found, grounded: grounded, language: language))
        store.log("Engine reply contained a claim about JARVIS' abilities — replaced by JARVIS' own state", kind: .warning)
    }

    /// The “efendim” cadence holds for a model's answer as much as for JARVIS' own sentences (typed and spoken replies are the same text).
    private func applyAddressCadence(to messageID: UUID, language: ReplyLanguage) {
        guard let text = conversation.messages.last(where: { $0.id == messageID })?.content else { return }
        let constrained = presenter.constrainModelOutput(text, language: language)
        if constrained != text { conversation.rewriteContent(messageID, with: constrained) }
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
