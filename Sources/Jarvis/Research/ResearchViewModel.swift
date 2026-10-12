import Foundation
import AppKit
import Observation

/// Read model + user actions of the Research screen. Reads the durable research tables (never the UI → repository directly), coalesces refreshes, and
/// turns clicks into ordinary V0.4 tasks — it never downloads, imports or opens anything on its own.
@MainActor
@Observable
final class ResearchViewModel {
    struct Detail: Equatable {
        var row: ResearchSessionRow
        var sources: [SourceRecord]
        var queries: [QueryRecord]
        var claims: [ClaimRecord]
        var candidates: [CandidateRecord]
        var acquisitions: [AcquisitionRecord]
        var markdown: String?
    }

    private(set) var sessions: [ResearchSessionRow] = []
    private(set) var acquisitions: [AcquisitionRecord] = []
    private(set) var detail: Detail?
    var selectedID: UUID? { didSet { if selectedID != oldValue { loadDetail() } } }
    var message: String?
    var expandedSources = false
    var highlightedSource: UUID?

    @ObservationIgnored private let repository: JarvisRepository?
    @ObservationIgnored private let artifacts: ArtifactStore?
    @ObservationIgnored private unowned let engine: TaskEngine
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var pending: Task<Void, Never>?

    init(repository: JarvisRepository?, artifacts: ArtifactStore?, engine: TaskEngine, preferences: Preferences) {
        self.repository = repository; self.artifacts = artifacts; self.engine = engine; self.preferences = preferences
    }

    /// Coalesced: the engine publishes after every mutation; the screen refreshes at most every 0.4 s and only while it asks to.
    func refreshSoon() {
        guard pending == nil else { return }
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.pending = nil
            self?.refresh()
        }
    }

    func refresh() {
        guard let repository else { return }
        sessions = (try? repository.researchSessions(limit: 25)) ?? []
        acquisitions = (try? repository.acquisitions(limit: 25)) ?? []
        if selectedID == nil { selectedID = sessions.first?.id } else { loadDetail() }
    }

    private func loadDetail() {
        guard let id = selectedID, let repository, let row = (try? repository.researchSession(id)) ?? nil else { detail = nil; return }
        var md: String?
        if let aid = row.markdownArtifactID, let art = (try? artifacts?.artifact(aid)) ?? nil, let data = try? artifacts?.read(art) { md = String(decoding: data, as: UTF8.self) }
        let next = Detail(row: row, sources: (try? repository.researchSources(id)) ?? [], queries: (try? repository.researchQueries(id)) ?? [], claims: (try? repository.researchClaims(id)) ?? [],
                          candidates: (try? repository.researchCandidates(id)) ?? [], acquisitions: (try? repository.acquisitions(researchID: id)) ?? [], markdown: md)
        if next != detail { detail = next }
    }

    // MARK: Actions

    /// Opens a source in the user's normal browser through the system (no script is injected anywhere); only public http(s) links.
    func open(_ urlString: String) {
        guard case .success(let v) = URLPolicy.production.validate(urlString) else { message = "That link is not a public web address, so JARVIS will not open it."; return }
        NSWorkspace.shared.open(v.url)
    }

    func reveal(_ record: AcquisitionRecord, in paths: JarvisPaths) {
        guard let rel = record.quarantinePath else { return }
        let url = paths.acquisitions.appendingPathComponent(rel)
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func requestDownload(_ c: CandidateRecord) {
        guard let d = detail else { return }
        let request = ResearchRequest(id: d.row.id, goal: d.row.goal, type: d.row.type, constraints: d.row.constraints, freshness: d.row.freshness, deep: d.row.deep, createdAt: d.row.createdAt)
        Task { @MainActor in
            switch await engine.submitAcquisition(candidate: c, request: request) {
            case .success: message = "Download task started for “\(c.name)”. It re-verifies price and licence first and may ask you; nothing is imported."
            case .failure(let e): message = e.description
            }
            refresh()
        }
    }

    func requestImport(_ r: AcquisitionRecord) {
        let root = preferences.projectRoot
        guard !root.isEmpty else { message = "Choose a project folder in Tasks first — preferably a disposable COPY of the game."; return }
        Task { @MainActor in
            switch await engine.submitImport(r, projectRoot: root) {
            case .success: message = "Import task started. It asks for your approval before copying anything into the project."
            case .failure(let e): message = e.description
            }
            refresh()
        }
    }

    /// "Delete downloaded files" in Settings: the quarantine only (imported copies in projects are never touched).
    func purgeQuarantine(_ web: ResearchServices) {
        guard let repository, let all = try? repository.acquisitions(limit: 500) else { return }
        web.acquisition.purgeQuarantine(all); refresh()
    }

    func stop(_ id: UUID) { engine.cancel(id) }
    func resume(_ id: UUID) { _ = engine.resume(id) }

}
