import Foundation
import Accelerate

/// The semantic index: DERIVED state (DEC-116). It is rebuilt from canonical memory at any time; if it is missing, stale or corrupt, retrieval falls back to
/// structured + lexical search and says so. Vectors are only made from text that already passed the curator's secret gate (and is re-checked here).
final class MemoryIndex: @unchecked Sendable {
    enum State: Equatable, Sendable { case ok, degraded(String), unavailable(String), disabled }

    struct Health: Equatable, Sendable {
        var state: State
        var model: String
        var revision: String
        var dimension: Int
        var indexed: Int
        var unindexed: Int
        var invalid: Int
        var lastRebuild: Date?
    }

    struct SyncReport: Equatable, Sendable { var embedded = 0; var skippedSecret = 0; var failed = 0; var remaining = 0 }
    enum RebuildResult: Equatable, Sendable { case completed(count: Int), cancelled, failed(String) }

    let repository: JarvisRepository
    var embedder: (any TextEmbedder)?
    var isSemanticEnabled: @Sendable () -> Bool = { true }
    var onEvent: (@Sendable (String, String) -> Void)?
    static let batchSize = 16

    init(repository: JarvisRepository, embedder: (any TextEmbedder)?) { self.repository = repository; self.embedder = embedder }

    /// What gets embedded: the memory's own words, bounded. Never details/rationale text (kept small and cheap).
    static func embeddingText(_ m: MemoryItem) -> String {
        MemoryText.clip([m.subject, m.summary].filter { !$0.isEmpty }.joined(separator: ". "), 300)
    }
    static func textHash(_ s: String) -> String { String(Redactor.sha256(s).prefix(24)) }

    private func canEmbed() -> (any TextEmbedder)? {
        guard isSemanticEnabled(), let e = embedder, e.isAvailable else { return nil }
        return e
    }

    func health(projectKey: String) -> Health {
        let e = embedder
        let model = e?.modelID ?? EmbeddingModel.id, rev = e?.revision ?? EmbeddingModel.revision, dim = e?.dimension ?? EmbeddingModel.dimension
        let live = ((try? repository.memories(projectKey: projectKey, statuses: [.current, .stale, .disputed, .unverified])) ?? [])
        let rows: (valid: [EmbeddingRow], invalid: [UUID]) = (try? repository.embeddings(projectKey: projectKey, modelID: model, revision: rev, dim: dim)) ?? (valid: [], invalid: [])
        let hashes = (try? repository.embeddingTextHashes(projectKey: projectKey)) ?? [:]
        let current = live.filter { hashes[$0.id] == Self.textHash(Self.embeddingText($0)) }.count
        let state: State
        if !isSemanticEnabled() { state = .disabled }
        else if e == nil || e?.isAvailable == false { state = .unavailable("embedding helper not installed — run scripts/setup_memory_ai.sh") }
        else if !rows.invalid.isEmpty { state = .degraded("\(rows.invalid.count) vector(s) are invalid and are ignored until the index is repaired") }
        else { state = .ok }
        return Health(state: state, model: model, revision: rev, dimension: dim, indexed: rows.valid.count, unindexed: max(0, live.count - current), invalid: rows.invalid.count,
                      lastRebuild: (try? repository.memoryMeta("index.lastRebuild.\(projectKey)")).flatMap { $0 }.flatMap(Double.init).map { Date(timeIntervalSince1970: $0) })
    }

    // MARK: Maintenance (event-driven: called after ingestion / on user action, never by a timer)

    /// Embeds live items that have no valid, current vector. Bounded per call (`limit`); forgotten/superseded items never get one.
    @discardableResult
    func sync(projectKey: String, limit: Int = 200) async -> SyncReport {
        guard let e = canEmbed() else { return SyncReport() }
        var report = SyncReport()
        let live = ((try? repository.memories(projectKey: projectKey, statuses: [.current, .stale, .disputed, .unverified])) ?? [])
        let valid: (valid: [EmbeddingRow], invalid: [UUID]) = (try? repository.embeddings(projectKey: projectKey, modelID: e.modelID, revision: e.revision, dim: e.dimension)) ?? (valid: [], invalid: [])
        for bad in valid.invalid { try? repository.deleteEmbedding(bad) }
        let have = Dictionary(uniqueKeysWithValues: valid.valid.map { ($0.memoryID, $0.textHash) })
        var todo: [(MemoryItem, String, String)] = []
        for m in live {
            let text = Self.embeddingText(m)
            if MemoryGate.containsSecret(text) { report.skippedSecret += 1; continue }
            let h = Self.textHash(text)
            if have[m.id] != h { todo.append((m, text, h)) }
        }
        report.remaining = max(0, todo.count - limit)
        for chunk in stride(from: 0, to: min(todo.count, limit), by: Self.batchSize).map({ Array(todo[$0..<min($0 + Self.batchSize, min(todo.count, limit))]) }) {
            do {
                let vecs = try await e.embed(chunk.map(\.1))
                guard vecs.count == chunk.count else { report.failed += chunk.count; continue }
                for (i, item) in chunk.enumerated() {
                    // a forgotten item must not get a vector after the fact
                    guard let fresh = (try? repository.memory(item.0.id)) ?? nil, fresh.status.isLive else { continue }
                    try? repository.upsertEmbedding(EmbeddingRow(memoryID: item.0.id, modelID: e.modelID, revision: e.revision, dim: e.dimension, textHash: item.2, vector: vecs[i]))
                    report.embedded += 1
                }
            } catch { report.failed += chunk.count; onEvent?("embed-failed", "\(error)"); break }
        }
        if report.embedded > 0 { onEvent?("embedded", "\(report.embedded) vector(s)") }
        return report
    }

    /// Recomputes EVERY vector, then swaps the project's index in one transaction. Cancelling or failing leaves the previous index exactly as it was.
    func rebuild(projectKey: String, isCancelled: @Sendable () -> Bool = { false }, progress: @Sendable (Int, Int) -> Void = { _, _ in }) async -> RebuildResult {
        guard let e = canEmbed() else { return .failed("semantic search is not available") }
        let live = ((try? repository.memories(projectKey: projectKey, statuses: [.current, .stale, .disputed, .unverified])) ?? [])
        let texts = live.map { ($0, Self.embeddingText($0)) }.filter { !MemoryGate.containsSecret($0.1) }
        var rows: [EmbeddingRow] = []
        for start in stride(from: 0, to: texts.count, by: Self.batchSize) {
            if isCancelled() { return .cancelled }
            let chunk = Array(texts[start..<min(start + Self.batchSize, texts.count)])
            do {
                let vecs = try await e.embed(chunk.map(\.1))
                guard vecs.count == chunk.count else { return .failed("the helper returned a wrong number of vectors") }
                for (i, c) in chunk.enumerated() { rows.append(EmbeddingRow(memoryID: c.0.id, modelID: e.modelID, revision: e.revision, dim: e.dimension, textHash: Self.textHash(c.1), vector: vecs[i])) }
                progress(rows.count, texts.count)
            } catch { return .failed("\(error)") }
        }
        if isCancelled() { return .cancelled }
        do { try repository.replaceEmbeddings(projectKey: projectKey, rows: rows) } catch { return .failed("could not write the index") }
        try? repository.setMemoryMeta("index.lastRebuild.\(projectKey)", String(Date().timeIntervalSince1970))
        try? repository.setMemoryMeta("index.model", "\(e.modelID)@\(e.revision)#\(e.dimension)")
        onEvent?("rebuilt", "\(rows.count) vector(s)")
        return .completed(count: rows.count)
    }

    // MARK: Search

    func embedQuery(_ text: String) async -> [Float]? {
        guard let e = canEmbed() else { return nil }
        return try? await e.embed([MemoryText.clip(text, 300)]).first
    }

    /// Cosine similarity (vectors are L2-normalised) of the query against every valid vector of the project.
    func similarities(to query: [Float], projectKey: String) -> [UUID: Float] {
        guard let e = embedder else { return [:] }
        guard query.count == e.dimension, let rows = try? repository.embeddings(projectKey: projectKey, modelID: e.modelID, revision: e.revision, dim: e.dimension) else { return [:] }
        var out: [UUID: Float] = [:]
        out.reserveCapacity(rows.valid.count)
        for r in rows.valid { out[r.memoryID] = vDSP.dot(query, r.vector) }
        return out
    }
}
