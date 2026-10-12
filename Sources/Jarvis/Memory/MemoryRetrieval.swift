import Foundation

struct MemoryFilters: Equatable, Sendable {
    var types: Set<MemoryType>? = nil
    var statuses: Set<MemoryStatus>? = nil
    var minImportance: MemoryImportance? = nil
    var since: Date? = nil
    var area: String? = nil
    var tag: String? = nil
    var sourceKind: MemorySourceKind? = nil
}

enum RetrievalMode: Sendable { case current, historical, all }

struct RetrievalRequest: Sendable {
    var query: String
    var projectKey: String
    var mode: RetrievalMode = .current
    var filters = MemoryFilters()
    var limit = 8
    var useSemantic = true
    var intent: MemoryQuestion.Kind? = nil
    /// Cosine floor for an item with NO keyword anchor to count as related (browsing 0.30; agent context is stricter).
    var minSemantic: Float = MemoryRetriever.minSemantic
}

struct RankedMemory: Identifiable, Sendable {
    var item: MemoryItem
    var score: Double
    var lexical: Double
    var semantic: Float?
    var reasons: [String]
    var caveat: String?
    var id: UUID { item.id }
}

struct RetrievalResult: Sendable {
    var ranked: [RankedMemory]
    var candidates: Int
    var semanticUsed: Bool
    var semanticNote: String?
    var milliseconds: Double
    /// Nothing in the project's memory is convincingly about this query (no lexical anchor and no strong semantic match).
    var lowConfidence: Bool
}

/// Hybrid retrieval (DEC-117): structured filters → BM25 lexical (Turkish/English folded, prefix-stemmed, with a small TR↔EN project vocabulary) → semantic cosine from the
/// derived index → explainable fusion (weights chosen on the benchmark: 0.8 semantic / 0.2 lexical) → status / strength / importance / pin / intent boosts.
/// A stale or superseded item can never outrank a current authoritative one only because it is semantically closer.
final class MemoryRetriever: @unchecked Sendable {
    let repository: JarvisRepository
    let index: MemoryIndex
    weak var service: MemoryService?
    static let semanticWeight = 0.8
    static let minSemantic: Float = 0.30

    init(repository: JarvisRepository, index: MemoryIndex, service: MemoryService? = nil) { self.repository = repository; self.index = index; self.service = service }

    /// Project vocabulary that bridges the two languages for the lexical signal (semantic search covers the rest).
    static let bridge: [String: [String]] = [
        "karar": ["decision", "decided"], "decision": ["karar"], "kisit": ["constraint"], "kisitlama": ["constraint"], "constraint": ["kisit", "kisitlama"], "neden": ["why", "reason"], "why": ["neden"],
        "onay": ["approval", "approve"], "onayla": ["approve", "approval"], "approval": ["onay"], "sesli": ["voice", "spoken"], "ses": ["voice", "audio"], "voice": ["sesli", "ses"],
        "indirilen": ["download", "downloaded"], "indirme": ["download"], "download": ["indirilen", "indirme"], "karantina": ["quarantine"], "quarantine": ["karantina"],
        "tarayici": ["browser"], "browser": ["tarayici"], "lisans": ["license", "licence"], "license": ["lisans"], "licence": ["lisans"], "fiyat": ["price"], "price": ["fiyat"],
        "varlik": ["asset"], "asset": ["varlik"], "gorev": ["task"], "task": ["gorev"], "hata": ["error", "failure", "bug"], "error": ["hata"], "kamera": ["camera"], "camera": ["kamera"],
        "guvenilmez": ["untrusted"], "untrusted": ["guvenilmez"], "arastirma": ["research"], "research": ["arastirma"], "denedik": ["tried"], "tried": ["denedik", "denemis"], "reddedildi": ["rejected"],
        "rejected": ["reddedildi", "reddettik"], "kullanma": ["use"], "secmistik": ["chose", "selected"], "yerine": ["instead"], "instead": ["yerine"], "model": ["model"], "unity": ["unity"],
        "pencere": ["window"], "boyut": ["size"], "size": ["boyut"], "saklamak": ["store"], "saklıyor": ["store"], "saklamiyor": ["store"], "anahtar": ["key"], "key": ["anahtar"],
    ]

    static func queryTokens(_ q: String) -> [String] {
        var out: [String] = []
        for w in MemoryText.words(q) {
            out.append(MemoryText.stem(w))
            for b in bridge[w] ?? [] { out.append(MemoryText.stem(b)) }
        }
        return Array(NSOrderedSet(array: out)) as? [String] ?? out
    }

    private static func docTokens(_ m: MemoryItem) -> [String] {
        var s = m.subject + " " + m.summary + " " + (m.details ?? "") + " " + (m.area ?? "") + " " + m.tags.joined(separator: " ")
        s += " " + m.sources.map(\.label).joined(separator: " ")
        return MemoryText.tokens(s)
    }

    private static func intentTypes(_ k: MemoryQuestion.Kind?) -> Set<MemoryType> {
        switch k {
        case .decision: [.decision, .architecture]
        case .why: [.decision, .failure, .lesson, .architecture]
        case .tried: [.failure, .episode, .lesson]
        case .failure: [.failure, .lesson, .knownIssue]
        case .constraints: [.constraint, .decision]
        case .assets: [.assetDecision, .researchFinding]
        case .issues: [.knownIssue, .failure]
        case .changed: [.episode, .decision, .projectFact]
        case .current: [.projectFact, .constraint, .decision]
        default: []
        }
    }

    func search(_ req: RetrievalRequest) async -> RetrievalResult {
        let t0 = Date()
        service?.applyStaleness(projectKey: req.projectKey)
        var statuses: Set<MemoryStatus> = [.current, .stale, .disputed, .unverified]
        if req.mode != .current { statuses.formUnion([.superseded, .archived]) }
        if let f = req.filters.statuses { statuses = f.subtracting([.forgotten]) }
        var pool = ((try? repository.memories(projectKey: req.projectKey, statuses: Array(statuses), types: req.filters.types.map(Array.init))) ?? []).filter { $0.scope == .project }
        if let m = req.filters.minImportance { pool = pool.filter { $0.importance >= m } }
        if let d = req.filters.since { pool = pool.filter { $0.updatedAt >= d || $0.validFrom >= d } }
        if let a = req.filters.area { pool = pool.filter { MemoryText.fold($0.area ?? "") == MemoryText.fold(a) } }
        if let t = req.filters.tag { pool = pool.filter { $0.tags.contains(MemoryText.fold(t)) } }
        if let k = req.filters.sourceKind { pool = pool.filter { $0.sources.contains { $0.kind == k } } }
        guard !pool.isEmpty else { return RetrievalResult(ranked: [], candidates: 0, semanticUsed: false, semanticNote: nil, milliseconds: ms(t0), lowConfidence: true) }

        // lexical (BM25)
        let q = Self.queryTokens(req.query)
        let docs = pool.map(Self.docTokens)
        let n = Double(docs.count)
        let totalLen = docs.reduce(0) { $0 + $1.count }
        let avg = max(1.0, Double(totalLen) / n)
        var df: [String: Int] = [:]
        for d in docs { for t in Set(d) { df[t, default: 0] += 1 } }
        var lex = [Double](repeating: 0, count: pool.count)
        var anchored = [Bool](repeating: false, count: pool.count)
        for (i, d) in docs.enumerated() {
            for t in Set(q) where df[t] != nil {
                let f = Double(d.filter { $0 == t }.count)
                guard f > 0 else { continue }
                let idf = log(1 + (n - Double(df[t]!) + 0.5) / (Double(df[t]!) + 0.5))
                lex[i] += idf * f * 2.4 / (f + 1.4 * (0.25 + 0.75 * Double(d.count) / avg))
                anchored[i] = true
            }
        }
        // explicit ids in the query ("DEC-094") are exact anchors
        let ids = (req.query.range(of: "DEC-\\d+", options: [.regularExpression, .caseInsensitive]).map { String(req.query[$0]).uppercased() })
        if let ids { for (i, m) in pool.enumerated() where m.sources.contains(where: { $0.label.uppercased().contains(ids) || ($0.locator ?? "").uppercased().contains(ids) }) || (m.key ?? "").uppercased().contains(ids) { lex[i] += 12; anchored[i] = true } }

        // semantic
        var sims: [UUID: Float] = [:]
        var semNote: String?
        var semanticUsed = false
        if req.useSemantic {
            let h = index.health(projectKey: req.projectKey)
            switch h.state {
            case .disabled: semNote = "semantic search is turned off"
            case .unavailable(let why): semNote = why
            default:
                if let qv = await index.embedQuery(req.query) { sims = index.similarities(to: qv, projectKey: req.projectKey); semanticUsed = !sims.isEmpty
                    if case .degraded(let w) = h.state { semNote = w }
                    if sims.isEmpty { semNote = "no vectors yet — run Rebuild index" }
                } else { semNote = "the embedding helper is not responding; using keyword search" }
            }
        } else { semNote = "semantic search skipped" }

        func norm(_ v: [Double]) -> [Double] { let lo = v.min() ?? 0, hi = v.max() ?? 0; return hi > lo ? v.map { ($0 - lo) / (hi - lo) } : v.map { _ in 0 } }
        let lexN = norm(lex)
        let semRaw: [Float?] = pool.map { sims[$0.id] }
        let semVals = semRaw.compactMap { $0 }
        let semLo = semVals.min() ?? 0, semHi = semVals.max() ?? 0
        let wanted = Self.intentTypes(req.intent)
        let now = Date()
        var ranked: [RankedMemory] = []
        for (i, m) in pool.enumerated() {
            var reasons: [String] = []
            var base: Double
            if let s = semRaw[i] {
                let sN = semHi > semLo ? Double(s - semLo) / Double(semHi - semLo) : 0
                base = Self.semanticWeight * sN + (1 - Self.semanticWeight) * lexN[i]
                reasons.append(String(format: "semantic %.2f", s)); if lex[i] > 0 { reasons.append("keyword match") }
            } else { base = lexN[i] * (semanticUsed ? 0.85 : 1); if lex[i] > 0 { reasons.append("keyword match") } }
            // an item is only a candidate if something REAL connects it to the query: a keyword anchor, a convincing semantic match, or a pin (min-max scores alone prove nothing)
            if !anchored[i] && (semRaw[i] ?? 0) < req.minSemantic && !m.pinned { continue }
            var boost = 0.0
            if m.pinned { boost += 0.15; reasons.append("pinned") }
            switch m.importance { case .critical: boost += 0.10; reasons.append("critical"); case .high: boost += 0.05; default: break }
            switch m.strength { case .authoritative: boost += 0.06; case .strong: boost += 0.03; default: break }
            if wanted.contains(m.type) { boost += 0.08; reasons.append("fits the question (\(m.type.label.lowercased()))") }
            if let a = m.area, MemoryText.fold(req.query).contains(MemoryText.fold(a)) { boost += 0.06; reasons.append("area: \(a)") }
            if req.intent == .current, m.type == .projectFact || m.type == .constraint { boost += max(0, 0.02 * (1 - min(1, now.timeIntervalSince(m.updatedAt) / (365 * 86_400)))) }
            var mult: Double
            switch m.status { case .current: mult = 1; case .stale: mult = 0.85; case .disputed: mult = 0.85; case .unverified: mult = 0.7; case .superseded: mult = req.mode == .historical ? 0.9 : 0.5; case .archived: mult = 0.6; case .forgotten: continue }
            if m.status != .current { reasons.append(m.status.label.lowercased()) }
            if req.mode == .historical, m.status == .superseded { boost += 0.04 }
            ranked.append(RankedMemory(item: m, score: (base + boost) * mult, lexical: lex[i], semantic: semRaw[i], reasons: reasons, caveat: Self.caveat(m, now: now)))
        }
        ranked.sort { ($0.score, $0.item.updatedAt) > ($1.score, $1.item.updatedAt) }
        let top = Array(ranked.prefix(max(1, req.limit)))
        let confident = top.first.map { ($0.semantic ?? 0) >= req.minSemantic || anchoredRaw($0.lexical) } ?? false
        let result = RetrievalResult(ranked: top, candidates: pool.count, semanticUsed: semanticUsed, semanticNote: semNote, milliseconds: ms(t0), lowConfidence: !confident)
        service?.note(req.projectKey, "retrieved", nil, "\(top.count)/\(pool.count) · \(semanticUsed ? "hybrid" : "keyword") · \(Int(result.milliseconds)) ms")
        return result
    }

    private func anchoredRaw(_ lexical: Double) -> Bool { lexical > 0 }
    private func ms(_ t0: Date) -> Double { Date().timeIntervalSince(t0) * 1000 }

    static func caveat(_ m: MemoryItem, now: Date) -> String? {
        switch m.status {
        case .stale:
            let days = Int(now.timeIntervalSince(m.lastVerifiedAt ?? m.createdAt) / 86_400)
            return "last verified \(days) day\(days == 1 ? "" : "s") ago — may be out of date"
        case .disputed: return "conflicts with another record"
        case .unverified: return "unverified — a guess or an unconfirmed note"
        case .superseded: return "superseded by newer information"
        case .archived: return "archived"
        default: return m.currentSensitive ? "price/licence style information — re-verify before acting" : nil
        }
    }
}
