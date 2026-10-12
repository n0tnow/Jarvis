import Testing
import Foundation
@testable import Jarvis

/// Deterministic stand-in for the neural embedder: hashed word + character-trigram buckets (no model, no helper). Good enough to test PLUMBING; real quality is measured
/// with the real model in `--memory-live-test` and `scripts/memory-ai/bench`.
final class HashingEmbedder: TextEmbedder, @unchecked Sendable {
    var modelID = "fake-hash"; var revision = "1"; var dimension = 512
    var isAvailable = true
    var calls = 0
    var failing = false
    /// FNV-1a: stable across processes (Swift's hashValue is randomised per run, which would make the tests flaky).
    static func bucket(_ s: String, _ n: Int) -> Int { var h: UInt64 = 0xcbf29ce484222325; for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }; return Int(h % UInt64(n)) }
    func embed(_ texts: [String]) async throws -> [[Float]] {
        calls += 1
        if failing { throw EmbeddingError.timedOut }
        return texts.map { t in
            var v = [Float](repeating: 0, count: dimension)
            for w in MemoryText.words(t) {
                let s = MemoryText.stem(w)
                v[Self.bucket(s, dimension)] += 1
                let chars = Array(s)
                if chars.count >= 3 { for i in 0...(chars.count - 3) { v[Self.bucket(String(chars[i..<(i + 3)]), dimension)] += 0.3 } }
            }
            let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
            return n > 0 ? v.map { $0 / n } : v
        }
    }
}

struct BenchCorpus: Decodable {
    struct M: Decodable { let id: String; let type: String; let lang: String; let text: String }
    struct Q: Decodable { let id: String; let kind: String; let text: String; let relevant: [String] }
    let memories: [M]; let queries: [Q]
    static func load() throws -> BenchCorpus {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/memory-ai/bench/corpus.json")
        return try JSONDecoder().decode(BenchCorpus.self, from: Data(contentsOf: url))
    }
}

struct RetrievalRig {
    let rig: MemRig
    let embedder = HashingEmbedder()
    let index: MemoryIndex
    let retriever: MemoryRetriever
    var ids: [String: UUID] = [:]
    var project: String { rig.project }
    var vectors: Int { (try? rig.repo.embeddingCount(projectKey: rig.project)) ?? -1 }

    init(loadCorpus: Bool = true) async throws {
        rig = try MemRig()
        index = MemoryIndex(repository: rig.repo, embedder: embedder)
        retriever = MemoryRetriever(repository: rig.repo, index: index, service: rig.service)
        if loadCorpus {
            let c = try BenchCorpus.load()
            var map: [String: UUID] = [:]
            for m in c.memories {
                let cand = MemoryCandidate(type: MemoryType(rawValue: m.type == "PROJECT_FACT" ? "projectFact" : m.type == "RESEARCH_FINDING" ? "researchFinding" : m.type == "ASSET_DECISION" ? "assetDecision" : m.type.lowercased()) ?? .other,
                                           subject: String(m.text.prefix(24)), summary: m.text, strength: .strong, origin: .document, sources: [MemorySource(kind: .document, ref: m.id, label: m.id)])
                if case .created(let id) = rig.service.admit(cand, projectKey: rig.project) { map[m.id] = id }
            }
            ids = map
        }
    }
    func rank(_ q: String, mode: RetrievalMode = .current, semantic: Bool = true, filters: MemoryFilters = MemoryFilters(), intent: MemoryQuestion.Kind? = nil) async -> RetrievalResult {
        await retriever.search(RetrievalRequest(query: q, projectKey: project, mode: mode, filters: filters, limit: 8, useSemantic: semantic, intent: intent))
    }
}

@Suite("Memory · retrieval")
struct MemoryRetrievalTests {
    @Test func benchmarkCorpusIsAdmittedAndSearchableWithoutEmbeddings() async throws {
        let r = try await RetrievalRig()
        #expect(r.ids.count >= 60)
        let c = try BenchCorpus.load()
        var hit3 = 0, n = 0
        for q in c.queries where q.kind == "en-en" || q.kind == "tr-tr" {
            let res = await r.rank(q.text, semantic: false)
            let top = res.ranked.prefix(3).compactMap { rm in r.ids.first { $0.value == rm.item.id }?.key }
            n += 1; if q.relevant.contains(where: { top.contains($0) }) { hit3 += 1 }
        }
        #expect(Double(hit3) / Double(n) >= 0.8, "lexical Recall@3 \(hit3)/\(n)")
    }

    @Test func turkishQueriesFindTheTurkishAndEnglishMemoriesThroughTheBridgeVocabulary() async throws {
        let r = try await RetrievalRig()
        let res = await r.rank("Playwright hakkında ne karar vermiştik?", semantic: false, intent: .decision)
        let top = res.ranked.prefix(3).compactMap { rm in r.ids.first { $0.value == rm.item.id }?.key }
        #expect(top.contains("m01") || top.contains("m02") || top.contains("m04"), "\(top)")
        let q2 = await r.rank("Sesli onay kritik işlemi onaylayabilir mi?", semantic: false)
        let top2 = q2.ranked.prefix(3).compactMap { rm in r.ids.first { $0.value == rm.item.id }?.key }
        #expect(top2.contains("m11") || top2.contains("m12"), "\(top2)")
    }

    @Test func hybridUsesTheSemanticIndexAndReportsIt() async throws {
        let r = try await RetrievalRig()
        let rep = await r.index.sync(projectKey: r.project)
        #expect(rep.embedded >= 60)
        let res = await r.rank("What did we decide about Playwright?", intent: .decision)
        #expect(res.semanticUsed && res.ranked.first?.semantic != nil)
        let top = res.ranked.prefix(3).compactMap { rm in r.ids.first { $0.value == rm.item.id }?.key }
        #expect(top.contains { ["m01", "m02", "m04"].contains($0) })
    }

    @Test func supersededMemoryIsHiddenFromCurrentQuestionsButFoundHistorically() async throws {
        let r = try await RetrievalRig(loadCorpus: false)
        func c(_ s: String, ref: String) -> MemoryCandidate { MemoryCandidate(type: .projectFact, subject: "pickup speed", summary: s, strength: .strong, origin: .document, sources: [MemorySource(kind: .document, ref: ref, label: ref)]) }
        _ = r.rig.service.admit(c("Pickup animation speed is 1.2 for the throwable system.", ref: "a"), projectKey: r.project)
        _ = r.rig.service.admit(c("Pickup animation speed is 1.5 for the throwable system.", ref: "b"), projectKey: r.project)
        let now = await r.rank("pickup animation speed", semantic: false)
        #expect(now.ranked.count == 1 && now.ranked[0].item.summary.contains("1.5"))
        let hist = await r.rank("what was the pickup animation speed before", mode: .historical, semantic: false)
        #expect(hist.ranked.count == 2 && hist.ranked[0].item.summary.contains("1.2") == false || hist.ranked.contains { $0.item.status == .superseded })
        #expect(hist.ranked.contains { $0.item.summary.contains("1.2") && $0.caveat?.contains("superseded") == true })
    }

    @Test func forgottenMemoryNeverSurfacesLexicallyOrSemantically() async throws {
        let r = try await RetrievalRig()
        _ = await r.index.sync(projectKey: r.project)
        let id = try #require(r.ids["m35"])
        try r.rig.service.forget(id)
        for sem in [false, true] {
            let res = await r.rank("camera micro-stutter architecture", semantic: sem)
            #expect(!res.ranked.contains { $0.item.id == id }, "semantic=\(sem)")
        }
        let vectors = r.vectors
        _ = await r.index.sync(projectKey: r.project)
        #expect(r.vectors == vectors)          // nothing re-embeds the forgotten item
        let all = try r.rig.repo.embeddings(projectKey: r.project, modelID: "fake-hash", revision: "1", dim: 512)
        #expect(!all.valid.contains { $0.memoryID == id })
    }

    @Test func aStaleSemanticallyCloseItemDoesNotOutrankACurrentAuthoritativeOne() async throws {
        let r = try await RetrievalRig(loadCorpus: false)
        var old = MemoryCandidate(type: .constraint, subject: "camera", summary: "Camera architecture changes require a design review before editing.", strength: .weak, origin: .document, sources: [MemorySource(kind: .document, ref: "o", label: "o")])
        old.validFrom = Date(timeIntervalSinceNow: -400 * 86_400)
        guard case .created(let oid) = r.rig.service.admit(old, projectKey: r.project) else { return }
        var m = try #require(try r.rig.repo.memory(oid)); m.status = .stale; try r.rig.repo.updateMemory(m)
        let cur = MemoryCandidate(type: .constraint, subject: "camera", summary: "Camera architecture must not change without new evidence.", strength: .authoritative, importance: .high, area: "camera", origin: .document, sources: [MemorySource(kind: .document, ref: "n", label: "n")])
        guard case .created(let nid) = r.rig.service.admit(cur, projectKey: r.project) else { return }
        _ = await r.index.sync(projectKey: r.project)
        let res = await r.rank("camera architecture change", intent: .constraints)
        #expect(res.ranked.first?.item.id == nid && res.ranked.contains { $0.item.id == oid })
    }

    @Test func pinnedAndCriticalMemoryGetPriorityWhenRelevant() async throws {
        let r = try await RetrievalRig(loadCorpus: false)
        for (i, text) in ["Texture import settings use compression for the bath scene", "Texture atlas packing is disabled for the bath scene props", "Texture streaming is enabled for the bath scene"].enumerated() {
            _ = r.rig.service.admit(MemoryCandidate(type: .projectFact, subject: "texture \(i)", summary: text, strength: .strong, origin: .document, sources: [MemorySource(kind: .document, ref: "t\(i)", label: "t\(i)")]), projectKey: r.project)
        }
        let last = try #require(try r.rig.repo.memories(projectKey: r.project).first { $0.summary.contains("streaming") })
        try r.rig.service.setPinned(last.id, true)
        let res = await r.rank("texture bath scene", semantic: false)
        #expect(res.ranked.first?.item.id == last.id && res.ranked.first?.reasons.contains("pinned") == true)
    }

    @Test func projectsAreIsolatedInRetrieval() async throws {
        let r = try await RetrievalRig(loadCorpus: false)
        _ = r.rig.service.admit(MemoryCandidate(type: .decision, subject: "camera", summary: "Camera architecture must not change without new evidence.", strength: .strong, origin: .document, sources: [MemorySource(kind: .document, ref: "x", label: "x")]), projectKey: "git:other")
        let res = await r.rank("camera architecture")
        #expect(res.ranked.isEmpty && res.lowConfidence)
    }

    @Test func irrelevantQuestionsAreLowConfidence() async throws {
        let r = try await RetrievalRig()
        let res = await r.rank("What is the weather forecast for tomorrow in Istanbul?", semantic: false)
        #expect(res.lowConfidence || res.ranked.isEmpty)
    }

    @Test func semanticOffOrUnavailableFallsBackToKeywordsAndSaysSo() async throws {
        let r = try await RetrievalRig()
        r.index.isSemanticEnabled = { false }
        let off = await r.rank("Compact HUD size")
        #expect(!off.semanticUsed && off.semanticNote?.contains("off") == true && !off.ranked.isEmpty)
        r.index.isSemanticEnabled = { true }
        r.embedder.isAvailable = false
        let gone = await r.rank("Compact HUD size")
        #expect(!gone.semanticUsed && gone.semanticNote?.contains("not installed") == true && !gone.ranked.isEmpty)
    }

    @Test func filtersNarrowByTypeStatusImportanceAndArea() async throws {
        let r = try await RetrievalRig()
        let onlyFailures = await r.rank("voice", semantic: false, filters: MemoryFilters(types: [.failure]))
        #expect(!onlyFailures.ranked.isEmpty && onlyFailures.ranked.allSatisfy { $0.item.type == .failure })
        let none = await r.rank("voice", semantic: false, filters: MemoryFilters(minImportance: .critical))
        #expect(none.ranked.isEmpty)
    }
}

@Suite("Memory · semantic index lifecycle")
struct MemoryIndexTests {
    @Test func syncEmbedsOnlyWhatNeedsIt() async throws {
        let r = try await RetrievalRig()
        let first = await r.index.sync(projectKey: r.project)
        let calls = r.embedder.calls
        let second = await r.index.sync(projectKey: r.project)
        #expect(first.embedded >= 60 && second.embedded == 0 && r.embedder.calls == calls)
    }

    @Test func rebuildSwapsAtomicallyAndCancellationKeepsTheOldIndex() async throws {
        let r = try await RetrievalRig()
        _ = await r.index.sync(projectKey: r.project)
        let before = r.vectors
        let cancelled = await r.index.rebuild(projectKey: r.project, isCancelled: { true })
        #expect(cancelled == .cancelled && r.vectors == before)
        r.embedder.failing = true
        if case .failed = await r.index.rebuild(projectKey: r.project) {} else { Issue.record("expected failure") }
        #expect(r.vectors == before)             // a failing rebuild never leaves a half index
        r.embedder.failing = false
        let ok = await r.index.rebuild(projectKey: r.project)
        guard case .completed(let n) = ok else { Issue.record("\(ok)"); return }
        #expect(n == before)
        let h = r.index.health(projectKey: r.project)
        #expect(h.state == .ok && h.lastRebuild != nil && h.indexed == n && h.unindexed == 0)
    }

    @Test func aCorruptVectorIsIgnoredReportedAndRepaired() async throws {
        let r = try await RetrievalRig()
        _ = await r.index.sync(projectKey: r.project)
        let victim = try #require(r.ids["m17"])
        try r.rig.repo.database.write { ctx in try ctx.execute("UPDATE memory_embeddings SET vector = ? WHERE memory_id = ?", [.blob(Data([1, 2, 3, 4])), .text(victim.uuidString)]) }
        let h = r.index.health(projectKey: r.project)
        if case .degraded = h.state { #expect(h.invalid == 1) } else { Issue.record("expected degraded, got \(h.state)") }
        let res = await r.rank("Compact HUD size 392 448")
        #expect(res.ranked.contains { $0.item.id == victim } && res.ranked.first { $0.item.id == victim }?.semantic == nil)          // still found: lexically
        _ = await r.index.sync(projectKey: r.project)
        #expect(r.index.health(projectKey: r.project).state == .ok)
    }

    @Test func aChangedEmbeddingModelNeverMixesWithTheOldVectors() async throws {
        let r = try await RetrievalRig()
        _ = await r.index.sync(projectKey: r.project)
        r.embedder.revision = "2"
        let h = r.index.health(projectKey: r.project)
        #expect(h.indexed == 0 && h.invalid > 0)
        let res = await r.rank("Compact HUD size")
        #expect(!res.semanticUsed)
        _ = await r.index.sync(projectKey: r.project)
        #expect(r.index.health(projectKey: r.project).state == .ok && r.index.health(projectKey: r.project).indexed >= 60)
    }

    @Test func secretShapedTextIsNeverEmbedded() async throws {
        let r = try await RetrievalRig(loadCorpus: false)
        // simulate a legacy row that predates the gate: it must still not be embedded
        var m = MemoryItem(projectKey: r.project, type: .projectFact, subject: "legacy", summary: "token ghp_abcdefghijklmnopqrstuvwxyz0123456789 in the old notes", origin: .document)
        m.sources = [MemorySource(kind: .document, ref: "l", label: "l")]; m.canonicalHash = "legacy"
        try r.rig.repo.insertMemory(m)
        let rep = await r.index.sync(projectKey: r.project)
        #expect(rep.skippedSecret == 1 && rep.embedded == 0 && r.vectors == 0)
    }
}

@Suite("Memory · vocabulary tables")
struct MemoryVocabularyTests {
    @Test func theBridgeAndFrameTablesBuildAndMapBothWays() {
        #expect(MemoryRetriever.bridge["karar"]?.contains("decision") == true && MemoryRetriever.bridge["decision"]?.contains("karar") == true)
        #expect(MemoryRetriever.bridge["indirilen"]?.contains("download") == true && MemoryRetriever.bridge["karantina"]?.contains("quarantine") == true)
        #expect(MemoryIntentParser.frameWords.contains("decide") && !MemoryIntentParser.frameWords.contains("playwright"))
        #expect(MemoryRetriever.queryTokens("İndirilen dosyaları").contains(MemoryText.stem("download")))
    }
}
