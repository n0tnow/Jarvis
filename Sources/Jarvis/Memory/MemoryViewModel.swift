import Foundation
import Observation

/// Read model + user actions of the Project Memory screen. The screen never touches the database: every list and every change goes through here (and through the
/// curator in `MemoryService`), so a correction can never be an invisible edit.
@MainActor
@Observable
final class MemoryViewModel {
    struct Row: Identifiable, Equatable {
        var item: MemoryItem
        var score: Double?
        var reasons: [String]
        var caveat: String?
        var id: UUID { item.id }
    }

    enum StatusFilter: String, CaseIterable { case live = "Live", history = "History", forgotten = "Forgotten", all = "All" }

    private(set) var rows: [Row] = []
    private(set) var project: ProjectIdentity?
    private(set) var diagnostics: MemoryDiagnostics?
    private(set) var detail: MemoryItem?
    private(set) var related: [MemoryItem] = []
    private(set) var contextUses: [MemoryContextUse] = []
    private(set) var semanticNote: String?
    private(set) var searching = false
    private(set) var bootstrapSummary: String?
    var query = ""
    var typeFilter: MemoryType?
    var statusFilter: StatusFilter = .live
    var importanceFilter: MemoryImportance?
    var selectedID: UUID? { didSet { if selectedID != oldValue { loadDetail() } } }
    var message: String?
    var showDiagnostics = false

    @ObservationIgnored private let memory: ProjectMemory
    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var lastRevision = -1

    init(memory: ProjectMemory, preferences: Preferences) { self.memory = memory; prefs = preferences }

    var isEnabled: Bool { prefs.projectMemoryEnabled }
    var service: MemoryService { memory.service }

    // MARK: Loading

    func refresh() {
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            guard let self else { return }
            self.project = await self.memory.refreshCurrentProject()
            await self.reload()
        }
    }

    func reload() async {
        guard let project else { rows = []; diagnostics = nil; return }
        searching = true; defer { searching = false }
        let statuses: Set<MemoryStatus>
        switch statusFilter { case .live: statuses = [.current, .stale, .disputed, .unverified]; case .history: statuses = [.superseded, .archived]; case .forgotten: statuses = [.forgotten]; case .all: statuses = Set(MemoryStatus.allCases) }
        var filters = MemoryFilters(types: typeFilter.map { [$0] }, statuses: statuses, minImportance: importanceFilter)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || statusFilter == .forgotten {
            let all = (try? memory.repository.memories(projectKey: project.key, statuses: Array(statuses), types: typeFilter.map { [$0] })) ?? []
            var items = all.filter { i in importanceFilter.map { i.importance >= $0 } ?? true }
            items.sort { ($0.pinned ? 1 : 0, $0.importance.rawValue, $0.updatedAt) > ($1.pinned ? 1 : 0, $1.importance.rawValue, $1.updatedAt) }
            rows = items.prefix(400).map { Row(item: $0, score: nil, reasons: [], caveat: MemoryRetriever.caveat($0, now: Date())) }
            semanticNote = nil
        } else {
            filters.statuses = statuses
            let res = await memory.retriever.search(RetrievalRequest(query: trimmed, projectKey: project.key, mode: statusFilter == .history ? .historical : .current, filters: filters, limit: 60, useSemantic: true, intent: nil))
            rows = res.ranked.map { Row(item: $0.item, score: $0.score, reasons: $0.reasons, caveat: $0.caveat) }
            semanticNote = res.semanticNote
        }
        diagnostics = await memory.diagnostics()
        contextUses = (try? memory.repository.memoryContextUses(limit: 8)) ?? []
        lastRevision = memory.revision
        loadDetail()
    }

    /// The screen calls this when `memory.revision` changed (event-driven refresh, coalesced).
    func revisionChanged() {
        guard memory.revision != lastRevision else { return }
        guard pending == nil || pending?.isCancelled == true else { return }
        refresh()
    }

    private func loadDetail() {
        guard let id = selectedID, let m = (try? memory.repository.memory(id)) ?? nil else { detail = nil; related = []; return }
        detail = m
        var rel: [MemoryItem] = []
        for r in m.relations where r.targetKind == "memory" { if let uuid = UUID(uuidString: r.target), let x = (try? memory.repository.memory(uuid)) ?? nil { rel.append(x) } }
        if let by = m.supersededBy, let x = (try? memory.repository.memory(by)) ?? nil, !rel.contains(where: { $0.id == x.id }) { rel.append(x) }
        related = rel
    }

    // MARK: Actions

    func pin(_ id: UUID, _ on: Bool) { do { try service.setPinned(id, on); message = on ? "Pinned. It still obeys current project truth." : "Unpinned." } catch { message = "\(error)" }; refresh() }
    func forget(_ id: UUID) {
        do { try service.forget(id); message = "Forgotten. JARVIS will no longer use it as context. Git, task history and the audit trail are unchanged." } catch { message = "\(error)" }
        selectedID = nil; refresh()
    }
    func restore(_ id: UUID) { do { try service.restore(id); message = "Restored." } catch { message = "\(error)" }; refresh() }
    func correct(_ id: UUID, with text: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let new = try self.service.correct(id, with: text, projectRoot: self.project?.rootPath)
                if let p = self.project { _ = await self.memory.index.sync(projectKey: p.key) }
                self.message = "Corrected. The old record stays in History as superseded."
                self.selectedID = new
            } catch { self.message = "\(error)" }
            self.refresh()
        }
    }
    func remember(_ text: String) {
        Task { @MainActor [weak self] in
            guard let self, let p = self.project else { return }
            switch self.service.remember(text, projectKey: p.key, projectRoot: p.rootPath) {
            case .created(let id), .merged(let id), .superseded(let id, _), .disputed(let id, _): self.message = "Remembered for \(p.name)."; _ = await self.memory.index.sync(projectKey: p.key); self.selectedID = id
            case .rejected(let why): self.message = "Not stored: \(why)."
            }
            self.refresh()
        }
    }
    func setImportance(_ id: UUID, _ i: MemoryImportance) { try? service.setImportance(id, i); refresh() }

    func bootstrap() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.message = "Reading the project's decisions, issues and rules…"
            if let rep = await self.memory.bootstrap() { self.bootstrapSummary = "Added \(rep.created), already known \(rep.merged), updated \(rep.superseded), skipped \(rep.rejected) — from \(rep.sources.joined(separator: ", "))."; self.message = self.bootstrapSummary }
            else { self.message = "Choose a project folder first (Tasks → Choose folder…)." }
            self.refresh()
        }
    }
    func rebuildIndex() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.message = "Rebuilding the semantic index…"
            switch await self.memory.rebuildIndex() {
            case .completed(let n): self.message = "Semantic index rebuilt: \(n) vectors."
            case .cancelled: self.message = "Rebuild cancelled — the previous index is untouched."
            case .failed(let why): self.message = "Rebuild failed: \(why). The previous index is untouched."
            }
            self.refresh()
        }
    }
    func cancelRebuild() { memory.cancelRebuild() }
    var rebuilding: Bool { memory.rebuilding }
}
