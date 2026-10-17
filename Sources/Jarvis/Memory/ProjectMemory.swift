import Foundation
import Observation

/// Thread-safe mirror of the two preferences the off-main-actor memory services need.
final class MemorySwitches: @unchecked Sendable {
    private let lock = NSLock()
    private var e: Bool, s: Bool
    init(enabled: Bool, semantic: Bool) { e = enabled; s = semantic }
    var enabled: Bool { lock.withLock { e } }
    var semantic: Bool { lock.withLock { s } }
    func set(enabled: Bool, semantic: Bool) { lock.withLock { e = enabled; s = semantic } }
}

/// What the conversation layer asks of Project Memory (typed AND spoken text take this same path).
@MainActor
protocol MemoryConversing: AnyObject {
    /// `.none` when the sentence is not about memory, memory is off, or the question is only loosely about the project (it then goes to the normal conversation).
    func recognizes(_ text: String) -> MemoryCommand
    /// nil = "this is not mine" (a loosely phrased question memory is not confident about): the caller continues with the normal conversation.
    func reply(to command: MemoryCommand, language: ReplyLanguage) async -> String?
    /// A bounded memory packet for an ordinary conversational question, or nil when nothing in memory is relevant (or memory is off).
    func conversationContext(for prompt: String) async -> ConversationMemoryContext?
    func recordConversationUse(_ c: ConversationMemoryContext, runID: UUID?)
    /// True when the LAST command wrote a record into Project Memory (remember / correct). The conversation's storage ledger records what really happened, never what was intended.
    var lastCommandStored: Bool { get }
    var currentProjectName: String? { get }
}

struct ConversationMemoryContext: Sendable { var text: String; var packet: ContextPacket; var project: ProjectIdentity }

struct MemoryDiagnostics: Equatable, Sendable {
    var project: String
    var total: Int
    var byType: [MemoryType: Int]
    var byStatus: [MemoryStatus: Int]
    var indexed: Int
    var unindexed: Int
    var invalid: Int
    var indexState: String
    var embeddingModel: String
    var embeddingRevision: String
    var helperState: String
    var helperResidentMB: Int?
    var lastRebuild: Date?
    var lastIngest: String?
    var lastRetrievalMs: Double?
    var lastContext: String?
    var schemaVersion: Int
}

/// The composition of Project Memory for the app: one place that owns the service, index, retriever, context builder and ingestor, and the only place that knows
/// about preferences and the task engine. Everything it does is event-driven (a task finished, the user asked, a job is about to run) — it has no timers.
@MainActor
@Observable
final class ProjectMemory: MemoryConversing {
    let service: MemoryService
    let index: MemoryIndex
    let retriever: MemoryRetriever
    let builder: ProjectContextBuilder
    let ingestor: MemoryIngestor
    let resolver: ProjectIdentityResolver
    let truth: ProjectTruth
    let embedding: EmbeddingHostController?
    let repository: JarvisRepository
    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private let switches: MemorySwitches
    @ObservationIgnored var onActivity: ((String, ActivityKind) -> Void)?
    /// A small-model call for proposed lessons (injected by the app; nil in tests / when unavailable).
    @ObservationIgnored var modelCall: (@MainActor (TaskRecord, String) async -> (text: String, model: String)?)?

    private(set) var currentProject: ProjectIdentity?
    private(set) var lastCommandStored = false
    var currentProjectName: String? { currentProject?.name }
    private(set) var lastIngest: String?
    private(set) var lastRetrievalMs: Double?
    private(set) var lastContext: String?
    private(set) var revision = 0                     // bumped on every change: the screen refreshes on it (event-driven)
    private(set) var rebuilding = false
    @ObservationIgnored private var rebuildCancel = false

    init(repository: JarvisRepository, preferences: Preferences, embedding: EmbeddingHostController?, truth: ProjectTruth = ProjectTruth(), embedder: (any TextEmbedder)? = nil) {
        self.repository = repository; self.prefs = preferences; self.embedding = embedding; self.truth = truth
        service = MemoryService(repository: repository, truth: truth)
        let emb: (any TextEmbedder)? = embedder ?? embedding.map { LocalEmbedder(controller: $0) }
        index = MemoryIndex(repository: repository, embedder: emb)
        retriever = MemoryRetriever(repository: repository, index: index, service: service)
        builder = ProjectContextBuilder(service: service, retriever: retriever)
        ingestor = MemoryIngestor(service: service)
        resolver = ProjectIdentityResolver(repository: repository)
        // The services run off the main actor; preferences live on it. A lock-protected mirror (refreshed event-driven whenever a preference changes) bridges the two.
        let switches = MemorySwitches(enabled: preferences.projectMemoryEnabled, semantic: preferences.memorySemanticEnabled)
        self.switches = switches
        service.isEnabled = { switches.enabled }
        index.isSemanticEnabled = { switches.semantic }
        let p = preferences
        observeContinuously(track: { _ = p.projectMemoryEnabled; _ = p.memorySemanticEnabled }, onChange: { switches.set(enabled: p.projectMemoryEnabled, semantic: p.memorySemanticEnabled) })
        service.onEvent = { [weak self] e in Task { @MainActor in self?.changed(e) } }
        truth.register(key: "jarvis.compactHUD.size", label: "Compact HUD size") { "\(Int(CompactHUDLayout.size.width))x\(Int(CompactHUDLayout.size.height))" }
    }

    var isEnabled: Bool { prefs.projectMemoryEnabled }

    /// Called once by the app: learns which project is current now and whenever the chosen folder changes (event-driven; nothing runs while idle).
    func start() {
        let p = prefs
        Task { await refreshCurrentProject() }
        observeContinuously(track: { _ = p.projectRoot }, onChange: { [weak self] in Task { @MainActor in await self?.refreshCurrentProject() } })
    }
    /// Test hook / immediate refresh after a programmatic preference change.
    func syncSwitches() { switches.set(enabled: prefs.projectMemoryEnabled, semantic: prefs.memorySemanticEnabled) }
    private func changed(_ e: MemoryEvent) {
        revision &+= 1
        if ["accepted", "superseded", "disputed", "corrected", "forgotten", "bootstrap"].contains(e.kind) { onActivity?("Project memory · \(e.kind)", .info) }
    }

    // MARK: Project

    func identity(forRoot root: String?) async -> ProjectIdentity? {
        guard let root, !root.isEmpty, FileManager.default.fileExists(atPath: root) else { return nil }
        let id = await resolver.resolve(root: root)
        await truth.refreshGit(root: root)
        return id
    }
    @discardableResult
    func refreshCurrentProject() async -> ProjectIdentity? {
        let id = await identity(forRoot: prefs.projectRoot)
        if id != currentProject { currentProject = id; revision &+= 1 }
        return id
    }

    // MARK: Conversation (typed or spoken)

    nonisolated static func isCommand(_ c: MemoryCommand) -> Bool { c != .none }

    func recognizes(_ text: String) -> MemoryCommand {
        guard isEnabled else { return .none }
        // Only questions that explicitly ask about THIS project's history / state ("what did we decide…") are answered from records. A loosely phrased question
        // ("Can spoken approval authorize a critical action?") goes to the normal conversation WITH the relevant memory in its context — no guessing which one it is.
        let c = MemoryIntentParser.parse(text)
        if case .question(let q) = c, !q.strongFrame { return .none }
        return c
    }

    func conversationContext(for prompt: String) async -> ConversationMemoryContext? {
        guard isEnabled, prompt.count < 4_000, let p = currentProject else { return nil }
        let packet = await builder.build(ContextRequest(goal: prompt, agent: .conversation, projectKey: p.key, projectRoot: p.rootPath))
        guard !packet.isEmpty, packet.usedIDs.count > 0 else { return nil }
        lastContext = "conversation: \(packet.stats.selected) memories · \(packet.stats.chars) chars"
        return ConversationMemoryContext(text: ProjectContextBuilder.render(packet), packet: packet, project: p)
    }

    func recordConversationUse(_ c: ConversationMemoryContext, runID: UUID?) {
        try? repository.insertMemoryContextUse(MemoryContextUse(runID: runID, taskID: nil, projectKey: c.project.key, agentType: "Conversation", memoryIDs: c.packet.usedIDs, truthKeys: c.packet.truth.map(\.key), items: c.packet.stats.selected, chars: c.packet.stats.chars))
        revision &+= 1
    }

    private func tr(_ l: ReplyLanguage, _ en: String, _ trk: String) -> String { l == .tr ? trk : en }

    func reply(to command: MemoryCommand, language l: ReplyLanguage) async -> String? {
        lastCommandStored = false
        guard let project = await refreshCurrentProject() else {
            return tr(l, "Project memory is per project and no project folder is chosen, so NOTHING was saved. Open Tasks and choose one (Choose folder…), then say it again. If this is a personal preference rather than project knowledge, I can save it as a setting instead — for example “call me efendim”, “answer shorter”.", "Proje hafızası projeye özgüdür ve şu an seçili bir proje klasörü yok; bu yüzden HİÇBİR ŞEY kaydedilmedi. Tasks ekranından bir klasör seçip tekrar söyleyin. Bu proje bilgisi değil kişisel bir tercihse, onu ayar olarak kaydedebilirim — örneğin “bana efendim diye hitap et”, “daha kısa cevap ver”.")
        }
        switch command {
        case .none: return ""
        case .remember(let text):
            switch service.remember(text, projectKey: project.key, projectRoot: project.rootPath) {
            case .created(let id), .merged(let id), .superseded(let id, _), .disputed(let id, _):
                lastCommandStored = true
                _ = await index.sync(projectKey: project.key)
                let m = (try? repository.memory(id)) ?? nil
                return tr(l, "Remembered for project \(project.name): “\(MemoryText.clip(m?.summary ?? text, 160))”. You can review, pin or correct it on the Project Memory screen.", "\(project.name) projesi için hatırlayacağım: “\(MemoryText.clip(m?.summary ?? text, 160))”. Project Memory ekranında inceleyebilir, sabitleyebilir veya düzeltebilirsiniz.")
            case .rejected(let why):
                if why == .taskLocal { return tr(l, "That sounds specific to a single task, so I did not make it project memory. Say “remember that …” without “for this task” if it should apply to the whole project.", "Bu tek bir göreve özgü görünüyor, bu yüzden proje hafızasına yazmadım. Tüm proje için geçerliyse “bu görev için” demeden “hatırla” deyin.") }
                if why == .authorityGrant { return tr(l, "I did not store that: memory can never grant approvals or weaken security. Approvals stay HUD buttons.", "Bunu saklamadım: hafıza onay veremez ve güvenliği gevşetemez. Onaylar HUD düğmeleriyle kalır.") }
                return tr(l, "I did not store that: \(why).", "Bunu saklamadım: \(why).")
            }
        case .correct(let text):
            let hits = service.forgetCandidates(matching: text, projectKey: project.key)
            if let best = hits.first, best.score >= 0.5, hits.count == 1 || best.score - (hits.dropFirst().first?.score ?? 0) >= 0.2 {
                do {
                    let id = try service.correct(best.item.id, with: text, projectRoot: project.rootPath)
                    lastCommandStored = true
                    _ = await index.sync(projectKey: project.key)
                    return tr(l, "Corrected. The new record replaces “\(MemoryText.clip(best.item.summary, 110))”; the old one stays in history, marked as superseded.", "Düzelttim. Yeni kayıt “\(MemoryText.clip(best.item.summary, 110))” kaydının yerini aldı; eski kayıt geçmişte “değiştirildi” olarak duruyor.") + (id == best.item.id ? "" : "")
                } catch let e as MemoryUserError { return e.description }
                catch { return tr(l, "I could not apply that correction.", "Bu düzeltmeyi uygulayamadım.") }
            }
            if hits.isEmpty {
                if case .rejected(let why) = service.remember(text, projectKey: project.key, projectRoot: project.rootPath) { return tr(l, "I found no earlier record to replace and I did not store that: \(why).", "Değiştirilecek bir kayıt bulamadım ve bunu saklamadım: \(why).") }
                lastCommandStored = true
                _ = await index.sync(projectKey: project.key)
                return tr(l, "I found no earlier record to replace, so I stored your statement as a new note for \(project.name).", "Değiştirilecek bir kayıt bulamadım; ifadenizi \(project.name) için yeni bir not olarak kaydettim.")
            }
            return tr(l, "Several records could be meant. Open Project Memory and use Correct on the right one:\n", "Birden fazla kayıt kastedilmiş olabilir. Project Memory ekranında doğru olanı seçip Düzelt'i kullanın:\n") + hits.prefix(3).map { "• " + MemoryText.clip($0.item.summary, 120) }.joined(separator: "\n")
        case .forget(let phrase):
            let hits = service.forgetCandidates(matching: phrase, projectKey: project.key)
            guard let best = hits.first, best.score >= 0.5 else {
                return hits.isEmpty ? tr(l, "I found no memory matching “\(MemoryText.clip(phrase, 60))”.", "“\(MemoryText.clip(phrase, 60))” ile eşleşen bir kayıt bulamadım.")
                                    : tr(l, "I am not sure which record you mean. Open Project Memory to forget the right one:\n", "Hangi kaydı kastettiğinizden emin değilim. Doğrusunu Project Memory ekranında unutun:\n") + hits.prefix(3).map { "• " + MemoryText.clip($0.item.summary, 120) }.joined(separator: "\n")
            }
            if hits.count > 1, best.score - hits[1].score < 0.2 {
                return tr(l, "Two records match equally well. Open Project Memory to forget the right one:\n", "İki kayıt eşit derecede eşleşiyor. Doğrusunu Project Memory ekranında unutun:\n") + hits.prefix(3).map { "• " + MemoryText.clip($0.item.summary, 120) }.joined(separator: "\n")
            }
            if best.item.pinned { return tr(l, "That memory is pinned. Unpin it on the Project Memory screen first, then forget it.", "Bu kayıt sabitlenmiş. Önce Project Memory ekranında sabitlemeyi kaldırın, sonra unutun.") }
            do {
                try service.forget(best.item.id)
                return tr(l, "Forgotten: “\(MemoryText.clip(best.item.summary, 120))”. JARVIS will no longer use it as context. This does not rewrite Git, task history or the audit trail; you can restore it on the Project Memory screen.", "Unutuldu: “\(MemoryText.clip(best.item.summary, 120))”. JARVIS artık bunu bağlam olarak kullanmayacak. Git, görev geçmişi ve denetim kaydı değişmez; Project Memory ekranından geri getirebilirsiniz.")
            } catch { return tr(l, "I could not forget that.", "Bunu unutamadım.") }
        case .question(let q):
            let res = await retriever.search(RetrievalRequest(query: q.topic.isEmpty ? q.raw : q.raw, projectKey: project.key, mode: q.historical ? .historical : .current, limit: 8, useSemantic: true, intent: q.kind))
            lastRetrievalMs = res.milliseconds
            let truthLines: [TruthLine] = q.kind == .current ? truth.knownKeys(projectRoot: project.rootPath).compactMap { k in truth.truth(for: k, projectRoot: project.rootPath).map { TruthLine(key: k, label: truth.label(k), value: $0.value, source: $0.source.label) } } : []
            let a = MemoryAnswerer.compose(question: q, result: res, language: l, projectName: project.name, truth: truthLines)
            lastContext = "answer: \(a.usedIDs.count) record(s) · \(Int(a.milliseconds)) ms"
            return a.text
        }
    }

    /// A loosely phrased question is answered from memory only when the top record is a convincing match: close in meaning (≥ 0.50) or sharing most of the question's words.
    // MARK: Agents

    /// The bounded memory packet for an agent job about to run, or nil (memory off, no project, nothing relevant). Everything it contains was reconciled with the
    /// project's CURRENT state first.
    func contextFor(agentType: String, goal: String, workspaceRoot: String?, taskID: UUID?) async -> (packet: ContextPacket, project: ProjectIdentity)? {
        guard isEnabled else { return nil }
        guard let project = await identity(forRoot: workspaceRoot ?? prefs.projectRoot) else { return nil }
        let packet = await builder.build(ContextRequest(goal: goal, agent: ContextAgentKind.from(agentType: agentType), projectKey: project.key, projectRoot: project.rootPath, taskID: taskID))
        guard !packet.isEmpty else { return nil }
        lastContext = "\(packet.agent.rawValue): \(packet.stats.selected) memories · \(packet.stats.chars) chars"
        return (packet, project)
    }

    func recordUse(packet: ContextPacket, project: ProjectIdentity, agentType: String, taskID: UUID, runID: UUID?) {
        try? repository.insertMemoryContextUse(MemoryContextUse(runID: runID, taskID: taskID, projectKey: project.key, agentType: agentType, memoryIDs: packet.usedIDs, truthKeys: packet.truth.map(\.key), items: packet.stats.selected, chars: packet.stats.chars))
        revision &+= 1
    }

    // MARK: Learning (meaningful lifecycle triggers only)

    func taskFinished(_ v: TaskView, report: TaskReport?) async {
        guard isEnabled, prefs.memoryAutoLearnEnabled else { return }
        let t = v.task
        let root: String? = t.kind.usesEmptyWorkspace ? prefs.projectRoot : (t.workspaceRoot ?? prefs.projectRoot)
        guard let project = await identity(forRoot: root) else { return }
        var rep = IngestReport()
        switch t.kind {
        case .research: if t.state == .completed { rep = ingestor.ingestResearch(sessionID: t.id, projectKey: project.key) }
        case .acquisition: rep = ingestor.ingestAcquisitions(projectKey: project.key)
        case .computer: break                                   // V0.11: what an app looked like at a moment is a session observation, never project memory
        default:
            rep = ingestor.ingestTask(task: t, report: report, projectKey: project.key, projectRoot: project.rootPath)
            if t.kind == .development, t.state == .completed, prefs.memoryModelLearningEnabled, let r = report, r.filesChanged.count >= 2, let call = modelCall {
                let text = r.markdown()
                if let answer = await call(t, ModelMemoryExtractor.prompt(taskTitle: t.title, report: text)) {
                    for c in ModelMemoryExtractor.parse(answer.text, report: text, task: t, modelName: answer.model) { rep.add(service.admit(c, projectKey: project.key, projectRoot: project.rootPath), type: c.type) }
                }
            }
        }
        if rep.created + rep.superseded + rep.disputed > 0 {
            lastIngest = "\(t.kind.rawValue): +\(rep.created) new, \(rep.superseded) updated"
            _ = await index.sync(projectKey: project.key)
        }
    }

    // MARK: User actions (Memory screen)

    @discardableResult
    func bootstrap() async -> IngestReport? {
        guard isEnabled, let project = await refreshCurrentProject() else { return nil }
        let rep = ingestor.bootstrap(root: project.rootPath, projectKey: project.key)
        lastIngest = "bootstrap: +\(rep.created) new, \(rep.merged) already known, \(rep.superseded) updated, \(rep.rejected) skipped"
        _ = await index.sync(projectKey: project.key, limit: 2_000)
        revision &+= 1
        return rep
    }

    func rebuildIndex() async -> MemoryIndex.RebuildResult {
        guard let project = await refreshCurrentProject() else { return .failed("no project") }
        rebuilding = true; rebuildCancel = false
        defer { rebuilding = false; revision &+= 1 }
        return await index.rebuild(projectKey: project.key, isCancelled: { [weak self] in MainActor.assumeIsolated { self?.rebuildCancel ?? true } })
    }
    func cancelRebuild() { rebuildCancel = true }

    func diagnostics() async -> MemoryDiagnostics? {
        guard let project = await refreshCurrentProject() else { return nil }
        let counts: (byType: [MemoryType: Int], byStatus: [MemoryStatus: Int]) = (try? repository.memoryCounts(projectKey: project.key)) ?? (byType: [:], byStatus: [:])
        let h = index.health(projectKey: project.key)
        let stateText: String
        switch h.state { case .ok: stateText = "OK"; case .degraded(let w): stateText = "DEGRADED — \(w)"; case .unavailable(let w): stateText = "UNAVAILABLE — \(w)"; case .disabled: stateText = "OFF" }
        return MemoryDiagnostics(project: project.name, total: counts.byStatus.values.reduce(0, +), byType: counts.byType, byStatus: counts.byStatus, indexed: h.indexed, unindexed: h.unindexed, invalid: h.invalid, indexState: stateText,
                                 embeddingModel: h.model, embeddingRevision: String(h.revision.prefix(10)), helperState: embedding?.state.label ?? "NOT CONFIGURED", helperResidentMB: embedding?.host.residentBytes.map { Int($0 / 1_048_576) },
                                 lastRebuild: h.lastRebuild, lastIngest: lastIngest, lastRetrievalMs: lastRetrievalMs, lastContext: lastContext, schemaVersion: repository.database.schemaVersion)
    }

    func onMemoryPressure() { Task { await embedding?.unloadNow() } }
    func shutdown() { embedding?.shutdownNow() }
}
