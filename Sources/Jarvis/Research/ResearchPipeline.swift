import Foundation
import CryptoKit

// MARK: - Seams

enum ModelPurpose: String, Sendable { case queryPlanning, extraction, styleAssessment }

struct ModelAnswer: Sendable { var text: String; var provider: String?; var model: String? }

/// One validated model call (the TaskEngine implements it with a routed, sanitized, audited agent run; tests pass a script; nil = no model).
typealias ModelCall = @Sendable (_ purpose: ModelPurpose, _ prompt: String, _ validate: @escaping @Sendable (String) -> Bool) async -> ModelAnswer?

protocol RenderedFetching: Sendable {
    /// `url` has ALREADY passed the URL gate; the renderer revalidates every navigation again.
    func render(_ url: URL) async -> Result<RenderedPageProvider.Page, ResearchFailure>
}

/// Persistence seam (SQLite in the app, nothing in unit tests). Implementations must be thread-safe and never throw into the pipeline.
protocol ResearchPersisting: Sendable {
    func saveSession(_ request: ResearchRequest, status: ResearchStatus, meter: BudgetMeter, note: String?)
    func saveQuery(_ q: QueryRecord)
    func saveSource(_ s: SourceRecord)
    func saveClaim(_ c: ClaimRecord)
    func saveCandidate(_ c: CandidateRecord)
    func saveReport(_ r: ResearchReport, markdown: String)
}

/// Bounded observability events (names, counts and sanitized URLs — never page bodies).
enum ResearchEvent: Sendable {
    case started(String), queryStarted(String, provider: String), searchResults(provider: String, count: Int), searchFailed(provider: String, reason: String)
    case sourceOpened(String), sourceRejected(String, reason: String), browserEscalation(String), claimVerified(String), priceVerified(String, PriceState), licenseVerified(String, LicenseState)
    case candidateAdded(String), candidateRejected(String, reason: String), modelCall(ModelPurpose, ok: Bool), stage(ResearchStatus, detail: String), reportCompleted(sources: Int, candidates: Int), injectionDetected(String, [String])

    var summary: String {
        switch self {
        case .started(let g): "Research started: \(g.prefix(80))"
        case .queryStarted(let q, let p): "Query via \(p): \(q.prefix(80))"
        case .searchResults(let p, let n): "\(n) result\(n == 1 ? "" : "s") from \(p)"
        case .searchFailed(let p, let r): "\(p) failed: \(r)"
        case .sourceOpened(let u): "Source opened: \(u.prefix(100))"
        case .sourceRejected(let u, let r): "Source rejected (\(r)): \(u.prefix(80))"
        case .browserEscalation(let u): "Rendering with the browser tier: \(u.prefix(80))"
        case .claimVerified(let c): "Claim verified: \(c.prefix(100))"
        case .priceVerified(let n, let s): "Price for \(n): \(s.rawValue)"
        case .licenseVerified(let n, let s): "Licence for \(n): \(s.rawValue)"
        case .candidateAdded(let n): "Candidate added: \(n)"
        case .candidateRejected(let n, let r): "Candidate rejected (\(r)): \(n)"
        case .modelCall(let p, let ok): "Model call \(p.rawValue): \(ok ? "accepted" : "rejected")"
        case .stage(let s, let d): "\(s.label): \(d)"
        case .reportCompleted(let s, let c): "Report ready (\(s) sources, \(c) candidates)"
        case .injectionDetected(let u, let l): "Page tried to instruct the assistant (\(l.joined(separator: ", "))); ignored: \(u.prefix(80))"
        }
    }
}

/// What the pipeline kept in memory about a page it read (bounded; never persisted).
struct ReadDocument: Sendable {
    var sourceID: UUID
    var url: URL
    var text: String
    var page: ExtractedPage
    var fetchedAt: Date
    var method: RetrievalMethod
    var json: JSONValue?
}

// MARK: - Pipeline

/// The research engine behind the V0.4 research steps. It plans nothing about authority (the task engine and policy do): it searches, reads,
/// extracts, verifies, compares and reports — inside a fixed budget, treating everything fetched as untrusted data.
actor ResearchPipeline {
    let request: ResearchRequest
    let budget: ResearchBudget
    let client: WebClient
    let providers: [any SearchProvider]
    let rendered: (any RenderedFetching)?
    let persist: (any ResearchPersisting)?
    let model: ModelCall?
    var events: (@Sendable (ResearchEvent) -> Void)?

    private(set) var status: ResearchStatus = .planning
    private(set) var meter = BudgetMeter()
    private(set) var queries: [QueryRecord] = []
    private(set) var sources: [UUID: SourceRecord] = [:]
    private(set) var documents: [UUID: ReadDocument] = [:]
    private(set) var claims: [ClaimRecord] = []
    private(set) var candidates: [CandidateRecord] = []
    private(set) var warnings: [String] = []
    private(set) var contradictions: [String] = []
    private(set) var injectionNotes: [String] = []
    private(set) var hits: [WebSearchHit] = []
    private(set) var plannedQueries: [QueryBuilder.Planned] = []
    private(set) var modelNotes: [String] = []
    private var deadProviders: Set<String> = []
    private var urlToSource: [String: UUID] = [:]            // dedupe key → source id
    private var readOrder: [WebSearchHit] = []
    var subject: Set<String> { SourceClassifier.subjectTerms(request.goal + " " + (request.project?.name ?? "")) }

    init(request: ResearchRequest, budget: ResearchBudget? = nil, client: WebClient, providers: [any SearchProvider], rendered: (any RenderedFetching)? = nil,
         persist: (any ResearchPersisting)? = nil, model: ModelCall? = nil, events: (@Sendable (ResearchEvent) -> Void)? = nil) {
        self.request = request; self.budget = budget ?? .for(request); self.client = client; self.providers = providers
        self.rendered = rendered; self.persist = persist; self.model = model; self.events = events
    }

    func setEvents(_ e: (@Sendable (ResearchEvent) -> Void)?) { events = e }
    func emit(_ e: ResearchEvent) { events?(e) }

    func move(to s: ResearchStatus, detail: String = "") {
        guard status == s || status.allowedNext.contains(s) else { return }
        status = s
        persist?.saveSession(request, status: s, meter: meter, note: detail.isEmpty ? nil : detail)
        emit(.stage(s, detail: detail))
    }

    // MARK: 1. Plan + search

    /// Deterministic queries, optionally refined by ONE budgeted model call (validated; a bad answer changes nothing).
    func planQueries() async -> [QueryBuilder.Planned] {
        var plan = QueryBuilder.plan(for: request, maxQueries: budget.maxQueries)
        if let model, meter.canCallProvider(budget), request.type != .documentation || plan.count < 2 {
            meter.providerCalls += 1
            let prompt = """
            You help a research assistant search the public web. Rewrite this goal as up to \(min(5, budget.maxQueries)) short ENGLISH web search queries (3–9 words each) that would find the best primary sources.
            Goal (may be Turkish): \(UntrustedContent.clean(request.goal, maxChars: 600))
            Research type: \(request.type.rawValue). Constraints: \(request.constraints.summary.joined(separator: "; ")).
            Reply with ONE JSON object only: {"queries": ["…", "…"]}
            """
            let max = budget.maxQueries
            let answer = await model(.queryPlanning, prompt) { QueryBuilder.validateModelQueries($0, max: max) != nil }
            emit(.modelCall(.queryPlanning, ok: answer != nil))
            if let answer, let qs = QueryBuilder.validateModelQueries(answer.text, max: max) {
                modelNotes.append("queries refined by \(answer.provider ?? "a model")")
                let main = plan.first.map(\.providers) ?? ["duckduckgo-html"]
                let refined = qs.map { QueryBuilder.Planned(text: $0, providers: main) }
                // keep the structured-provider queries (asset catalogues, GitHub…), replace the web-search ones
                plan = Array((plan.filter { !$0.providers.contains("duckduckgo-html") } + refined).prefix(budget.maxQueries))
            }
        }
        plannedQueries = plan
        return plan
    }

    @discardableResult
    func search() async -> Result<Int, ResearchFailure> {
        move(to: .searching, detail: "planning queries")
        if plannedQueries.isEmpty { _ = await planQueries() }
        guard !plannedQueries.isEmpty else { return .failure(.noResults) }
        emit(.started(request.goal))
        var all: [WebSearchHit] = []
        var anySuccess = false
        for planned in plannedQueries {
            for pid in planned.providers {
                if Task.isCancelled { return .failure(.cancelled) }
                guard let provider = providers.first(where: { $0.id == pid }), !deadProviders.contains(pid) else { continue }
                if let why = meter.exhausted(budget) { warnings.append("search stopped: \(why)"); break }
                meter.queries += 1
                await client.limiter.setInterval(provider.hostInterval, for: hostOf(provider))
                emit(.queryStarted(planned.text, provider: provider.id))
                let result = await provider.search(planned.text, limit: budget.resultsPerQuery, client: client)
                var rec = QueryRecord(researchID: request.id, text: planned.text, provider: provider.id, resultCount: 0)
                switch result {
                case .success(let found):
                    rec.resultCount = found.count; anySuccess = true; all += found
                    emit(.searchResults(provider: provider.id, count: found.count))
                case .failure(let f):
                    rec.failure = f.description
                    emit(.searchFailed(provider: provider.id, reason: f.description))
                    switch f {
                    case .captcha: deadProviders.insert(pid); warnings.append("\(provider.title) asked for a CAPTCHA — USER INTERACTION REQUIRED; JARVIS does not bypass it and used other sources")
                    case .rateLimited: deadProviders.insert(pid); warnings.append("\(provider.title) rate-limited the search")
                    case .offline: return .failure(.offline)
                    case .cancelled: return .failure(.cancelled)
                    default: break
                    }
                }
                queries.append(rec); persist?.saveQuery(rec)
            }
        }
        hits = dedupe(all)
        for h in hits { registerHit(h) }
        guard anySuccess, !hits.isEmpty else { return .failure(warnings.isEmpty ? .noResults : .providerFailed(warnings.joined(separator: "; "))) }
        readOrder = prioritise(hits)
        return .success(hits.count)
    }

    private func hostOf(_ p: any SearchProvider) -> String {
        switch p.id {
        case "duckduckgo-html": "html.duckduckgo.com"; case "github-repositories": "api.github.com"; case "hacker-news": "hn.algolia.com"
        case "stack-exchange": "api.stackexchange.com"; case "polyhaven": "api.polyhaven.com"; default: p.id
        }
    }

    private func dedupe(_ found: [WebSearchHit]) -> [WebSearchHit] {
        var seen = Set<String>(); var out: [WebSearchHit] = []
        for h in found {
            guard let u = URL(string: h.url) else { continue }
            if case .failure = URLPolicy.production.validate(url: u) { continue }           // never even list a URL the policy would refuse
            if seen.insert(CanonicalURL.dedupeKey(u)).inserted { out.append(h) }
        }
        return out
    }

    /// A search hit becomes a SOURCE record of method `searchSnippet` — visible in the UI, never evidence for price/licence/compatibility.
    private func registerHit(_ h: WebSearchHit) {
        guard let url = URL(string: h.url) else { return }
        let key = CanonicalURL.dedupeKey(url)
        guard urlToSource[key] == nil else { return }
        let cls = SourceClassifier.classify(url, subject: subject, ownerOrRepoMatchesSubject: ownerMatches(url))
        let s = SourceRecord(id: UUID(), researchID: request.id, url: CanonicalURL.forStorage(CanonicalURL.make(url)), finalURL: nil, domain: (url.host ?? "").lowercased(), title: String(h.title.prefix(160)),
                             type: cls.type == .unknown ? .searchResult : cls.type, official: cls.official, retrievedAt: Date(), publishedAt: nil, author: nil, contentHash: nil, license: nil, method: .searchSnippet,
                             authRequired: false, dynamic: false, httpStatus: nil, trust: cls.trust, excerpt: OutputSanitizer.sanitize(String(h.snippet.prefix(300))), note: cls.suspicious ? cls.reason : "search result — discovery only, not evidence")
        sources[s.id] = s; urlToSource[key] = s.id
        persist?.saveSource(s)
    }

    private func ownerMatches(_ url: URL) -> Bool {
        guard let gh = GitHubInspector.parseRepoURL(url.absoluteString) else { return false }
        return subject.contains(gh.owner.lowercased()) || subject.contains(gh.repo.lowercased())
    }

    /// Reading order: official and structured sources first, diverse domains, no suspicious mirrors unless nothing else exists.
    private func prioritise(_ list: [WebSearchHit]) -> [WebSearchHit] {
        struct Scored { var hit: WebSearchHit; var score: Double }
        var scored: [Scored] = []
        for h in list {
            guard let url = URL(string: h.url) else { continue }
            let cls = SourceClassifier.classify(url, subject: subject, ownerOrRepoMatchesSubject: ownerMatches(url))
            if request.constraints.officialOnly, cls.official != .official, cls.trust < 4 { continue }
            var score = Double(cls.trust) * 10 + (cls.official == .official ? 20 : 0) - Double(h.rank) * 1.5
            if ["polyhaven", "github-repositories", "stack-exchange"].contains(h.provider) { score += 6 }
            if request.constraints.preferredDomains.contains(where: { (url.host ?? "").hasSuffix($0) }) { score += 15 }
            if cls.suspicious { score -= 100 }
            scored.append(Scored(hit: h, score: score))
        }
        var perDomain: [String: Int] = [:]; var out: [WebSearchHit] = []
        for s in scored.sorted(by: { $0.score > $1.score }) {
            let d = (URL(string: s.hit.url)?.host ?? "")
            if s.score < -50 { continue }
            if perDomain[d, default: 0] >= (request.constraints.officialOnly ? 4 : 2) { continue }
            perDomain[d, default: 0] += 1; out.append(s.hit)
        }
        return out
    }

    // MARK: 2. Read

    @discardableResult
    func read(maxPages: Int? = nil) async -> Result<Int, ResearchFailure> {
        move(to: .reading, detail: "reading sources")
        let limit = min(maxPages ?? budget.maxSources, budget.maxSources)
        let targets = Array(readOrder.prefix(limit))
        guard !targets.isEmpty else { return .failure(.noResults) }
        var opened = 0
        var index = 0
        await withTaskGroup(of: (WebSearchHit, Result<FetchedDocument, ResearchFailure>).self) { group in
            var inflight = 0
            func launch(_ hit: WebSearchHit) {
                inflight += 1
                var cfg = FetchConfig(); cfg.maxBytes = self.budget.maxPageBytes
                if hit.provider == "github-repositories" || hit.provider == "stack-exchange" || hit.provider == "polyhaven" { cfg.accept = "text/html,application/xhtml+xml" }
                let client = self.client
                if hit.provider == "stack-exchange" { group.addTask { (hit, await StackExchangeProvider.apiDocument(for: hit.url, client: client)) } }
                else { group.addTask { (hit, await client.fetch(hit.url, config: cfg)) } }
            }
            while index < targets.count || inflight > 0 {
                while index < targets.count, inflight < budget.maxConcurrentFetches, meter.canRead(budget), !Task.isCancelled {
                    launch(targets[index]); index += 1; meter.sources += 1
                }
                guard let (hit, result) = await group.next() else { break }
                inflight -= 1
                if await ingest(hit: hit, result: result) { opened += 1 }
                if Task.isCancelled { group.cancelAll() }
            }
        }
        if Task.isCancelled { return .failure(.cancelled) }
        persist?.saveSession(request, status: status, meter: meter, note: "read \(opened)")
        return opened > 0 ? .success(opened) : .failure(warnings.isEmpty ? .noResults : .providerFailed(warnings.suffix(2).joined(separator: "; ")))
    }

    /// Turns one fetch result into a SourceRecord (+ an in-memory document when readable). Returns true when a page was read.
    func ingest(hit: WebSearchHit, result: Result<FetchedDocument, ResearchFailure>) async -> Bool {
        guard let url = URL(string: hit.url) else { return false }
        let key = CanonicalURL.dedupeKey(url)
        var rec = sources[urlToSource[key] ?? UUID()] ?? SourceRecord(id: UUID(), researchID: request.id, url: CanonicalURL.forStorage(url), finalURL: nil, domain: (url.host ?? "").lowercased(), title: hit.title, type: .unknown,
                                                                      official: .unknown, retrievedAt: Date(), publishedAt: nil, author: nil, contentHash: nil, license: nil, method: .http, authRequired: false, dynamic: false, httpStatus: nil, trust: 1, excerpt: "", note: nil)
        urlToSource[key] = rec.id
        switch result {
        case .failure(let f):
            rec.note = f.description; rec.retrievedAt = Date()
            if f == .loginWall { rec.authRequired = true }
            emit(.sourceRejected(hit.url, reason: f.description))
            sources[rec.id] = rec; persist?.saveSource(rec)
            if case .offline = f { warnings.append("offline") }
            return false
        case .success(let doc):
            meter.bytes += doc.body.count
            var page = HTMLExtractor.extract(doc.body, baseURL: doc.finalURL)
            var method: RetrievalMethod = doc.method == .api || (doc.contentType ?? "").contains("json") ? .api : .http
            var json: JSONValue?
            if method == .api, (doc.contentType ?? "").contains("json") { json = JSONValue.parse(doc.body); page.text = String(doc.text.prefix(80_000)) }
            if method == .http, page.looksJavaScriptRendered, let rendered, meter.canRender(budget), !Task.isCancelled {
                let attempt = await rendered.render(doc.finalURL)
                if case .success(let rp) = attempt {
                    meter.rendered += 1
                    emit(.browserEscalation(hit.url))
                    var p = HTMLExtractor.extract(Data(rp.html.utf8), baseURL: rp.finalURL)
                    if p.text.count < rp.text.count { p.text = String(rp.text.prefix(80_000)) }
                    if p.title.isEmpty { p.title = rp.title }
                    page = p; method = .renderedBrowser
                }
            }
            if page.isLoginWall { rec.authRequired = true; rec.note = "a login is required to see the content" }
            if page.isCaptchaChallenge { rec.note = "the page is a bot-check challenge — USER INTERACTION REQUIRED"; emit(.sourceRejected(hit.url, reason: "captcha challenge")); sources[rec.id] = rec; persist?.saveSource(rec); return false }
            let cls = SourceClassifier.classify(doc.finalURL, subject: subject, ownerOrRepoMatchesSubject: ownerMatches(doc.finalURL))
            rec.type = cls.type == .unknown && rec.type != .searchResult ? rec.type : cls.type
            rec.official = cls.official; rec.trust = cls.trust
            rec.finalURL = CanonicalURL.forStorage(doc.finalURL)
            rec.url = CanonicalURL.forStorage(CanonicalURL.make(URL(string: page.canonical ?? "") ?? doc.finalURL))
            rec.domain = (doc.finalURL.host ?? rec.domain).lowercased()
            rec.title = String((page.title.isEmpty ? hit.title : page.title).prefix(160))
            rec.retrievedAt = doc.retrievedAt; rec.httpStatus = doc.status; rec.method = method
            rec.contentHash = SHA256.hash(data: doc.body).map { String(format: "%02x", $0) }.joined()
            rec.dynamic = method == .renderedBrowser
            rec.publishedAt = Self.date(page.meta["article:published_time"] ?? page.meta["og:published_time"] ?? page.meta["date"] ?? page.jsonLD.compactMap { $0["datePublished"]?.string }.first)
            rec.author = (page.meta["author"] ?? page.jsonLD.compactMap { $0.at("author.name")?.string ?? $0["author"]?.string }.first).map { String($0.prefix(80)) }
            rec.license = page.jsonLD.compactMap { $0["license"]?.string }.first.map { String($0.prefix(120)) }
            rec.excerpt = Redactor.excerpt(page.text, max: 400)
            let flags = UntrustedContent.scan(page.text + "\n" + page.title)
            rec.injectionFlags = flags
            if !flags.isEmpty {
                rec.note = "contains instructions aimed at an AI assistant — ignored (\(flags.joined(separator: ", ")))"
                injectionNotes.append("\(rec.domain): \(flags.joined(separator: ", "))")
                emit(.injectionDetected(hit.url, flags))
            }
            sources[rec.id] = rec; persist?.saveSource(rec)
            urlToSource[CanonicalURL.dedupeKey(doc.finalURL)] = rec.id
            documents[rec.id] = ReadDocument(sourceID: rec.id, url: doc.finalURL, text: String(page.text.prefix(60_000)), page: page, fetchedAt: doc.retrievedAt, method: method, json: json)
            emit(.sourceOpened(CanonicalURL.forStorage(doc.finalURL)))
            return true
        }
    }

    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]; if let d = f.date(from: s) { return d }
        f.formatOptions = [.withFullDate]; return f.date(from: String(s.prefix(10)))
    }

    // MARK: Restore (explicit resume of an interrupted research task)

    /// Reloads what earlier steps persisted so a resumed task continues from its first unpassed step. Page texts are NOT stored: later steps re-fetch what they need.
    func restore(queries q: [QueryRecord], sources s: [SourceRecord], claims c: [ClaimRecord], candidates cand: [CandidateRecord]) {
        queries = q; claims = c; candidates = cand
        for src in s {
            sources[src.id] = src
            if let u = URL(string: src.url) { urlToSource[CanonicalURL.dedupeKey(u)] = src.id }
        }
        meter.queries = q.count; meter.sources = s.filter { $0.method != .searchSnippet }.count
        let snippets = s.filter { $0.method == .searchSnippet }.sorted { ($0.trust, $1.domain) > ($1.trust, $0.domain) }
        hits = snippets.enumerated().map { WebSearchHit(title: $1.title, url: $1.url, snippet: $1.excerpt, provider: "restored", rank: $0 + 1) }
        readOrder = hits
    }

    /// Re-fetches the best already-known sources so extraction can run again after a restart (bounded by the normal read budget).
    func rehydrateDocuments() async {
        guard documents.isEmpty else { return }
        readOrder = readOrder.isEmpty ? sources.values.filter { $0.method != .searchSnippet }.sorted { $0.trust > $1.trust }.map { WebSearchHit(title: $0.title, url: $0.url, snippet: "", provider: "restored", rank: 0) } : readOrder
        _ = await read(maxPages: min(budget.maxSources, 8))
    }

    // MARK: Access for later stages / the UI

    func source(_ id: UUID) -> SourceRecord? { sources[id] }
    func allSources() -> [SourceRecord] { sources.values.sorted { ($0.method == .searchSnippet ? 1 : 0, -$0.trust, $0.domain) < ($1.method == .searchSnippet ? 1 : 0, -$1.trust, $1.domain) } }
    func setStatusForRecovery(_ s: ResearchStatus) { status = s }

    /// A step failed or was cancelled: the durable session row must say so (it would otherwise stay on "searching"/"reading" forever).
    func markEnded(_ f: ResearchFailure) {
        guard !status.isTerminal else { return }
        status = f == .cancelled ? .cancelled : .failed
        persist?.saveSession(request, status: status, meter: meter, note: f == .cancelled ? "stopped" : String(f.description.prefix(200)))
        emit(.stage(status, detail: f.description))
    }

    /// Words that name what the user is looking for: the goal's own terms plus the English terms of the planned structured queries (a Turkish goal is glossed or model-translated there).
    func relevanceTerms() -> [String] {
        var out: [String] = []
        let structured = plannedQueries.filter({ !$0.text.contains("site:") }).map(\.text)
        for text in [request.goal] + structured {
            for t in SearchTerms.subject(QueryBuilder.terms(text).joined(separator: " ")) where !out.contains(t) { out.append(t) }
        }
        return out
    }
    func addWarning(_ w: String) { if !warnings.contains(w) { warnings.append(w) } }
    func addContradiction(_ c: String) { if !contradictions.contains(c) { contradictions.append(c) } }
    func putCandidate(_ c: CandidateRecord) { if let i = candidates.firstIndex(where: { $0.id == c.id }) { candidates[i] = c } else { candidates.append(c) }; persist?.saveCandidate(c) }
    func replaceCandidates(_ list: [CandidateRecord]) { candidates = list; for c in list { persist?.saveCandidate(c) } }
    func putClaim(_ c: ClaimRecord) { claims.append(c); persist?.saveClaim(c) }
    func putSource(_ s: SourceRecord) { sources[s.id] = s; persist?.saveSource(s) }
    func putDocument(_ d: ReadDocument) { documents[d.sourceID] = d }
    func noteModel(_ n: String) { modelNotes.append(n) }
    func noteInjection(_ n: String) { injectionNotes.append(n) }
    func bumpProviderCalls() { meter.providerCalls += 1 }
    func addBytes(_ n: Int) { meter.bytes += n }
    func registerSourceKey(_ url: URL, _ id: UUID) { urlToSource[CanonicalURL.dedupeKey(url)] = id }
    func sourceID(for url: URL) -> UUID? { urlToSource[CanonicalURL.dedupeKey(url)] }
}
