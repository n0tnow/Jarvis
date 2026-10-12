import Foundation

// MARK: - Provider abstraction

struct WebSearchHit: Equatable, Sendable {
    var title: String
    var url: String
    var snippet: String
    var provider: String
    var rank: Int
    /// Structured facts the provider itself returned (stars, licence id, price…) — still just hints until a source page confirms them.
    var facts: [String: String] = [:]
}

struct ProviderCapabilities: Equatable, Sendable {
    var search = true
    var fetch = true
    var javaScriptRequired = false
    var browserRequired = false
    var authenticationRequired = false
    var downloadCapable = false
    var structuredMetadata = false
    var requiresKey = false
    var rateLimitNote: String?
}

protocol SearchProvider: Sendable {
    var id: String { get }
    var title: String { get }
    var capabilities: ProviderCapabilities { get }
    /// Minimum seconds between two requests to this provider's host.
    var hostInterval: TimeInterval { get }
    func search(_ query: String, limit: Int, client: WebClient) async -> Result<[WebSearchHit], ResearchFailure>
}

extension SearchProvider { var hostInterval: TimeInterval { 1.0 } }

/// Search engines that AND every word (GitHub, Stack Exchange) return nothing for a sentence: keep the few words that carry the subject.
enum SearchTerms {
    /// Words that describe the REQUEST, not the subject — they are never evidence that a candidate is on topic.
    static let generic: Set<String> = ["free", "unity", "model", "models", "asset", "assets", "cc0", "stylized", "stylised", "game", "games", "low", "poly", "lowpoly", "3d", "prop", "props", "kit", "pack", "packs",
                                       "commercial", "use", "usage", "licence", "license", "licensed", "suitable", "find", "search", "research", "official", "documentation", "docs", "tell", "about", "what", "for", "the", "and", "with",
                                       "open", "source", "opensource", "permissive", "library", "libraries", "package", "packages", "best", "lightweight", "github", "community", "discussion", "people", "problem", "issue", "mit", "like", "some", "any", "turkish", "oyunum", "that"]

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !$0.isEmpty }
    }
    /// Crude plural/gerund folding so "buckets" meets "bucket" and "pooling" meets "pool".
    static func stem(_ w: String) -> String {
        var t = w
        for suf in ["ing", "es", "s"] where t.hasSuffix(suf) && t.count - suf.count >= 3 { t = String(t.dropLast(suf.count)); break }
        return t
    }
    /// Stemmed subject words of a text (generic request words removed).
    static func subject(_ text: String) -> [String] {
        var out: [String] = []
        for w in words(text) where !generic.contains(w) && w.count > 1 { let st = stem(w); if !out.contains(st) { out.append(st) } }
        return out
    }
    /// A short query for AND-matching engines: always keeps "unity" when the user asked about Unity, then at most `max` subject words.
    static func core(_ query: String, keepUnity: Bool = true, max: Int = 4) -> String {
        let all = words(query)
        var terms: [String] = keepUnity && all.contains("unity") ? ["unity"] : []
        for w in all where !generic.contains(w) && w.count > 1 && !terms.contains(w) { terms.append(w) }
        return terms.prefix(max).joined(separator: " ")
    }
    /// Does `text` mention the (stemmed) term as a word or inside a longer word of the same stem?
    static func mentions(_ text: String, term: String) -> Bool {
        words(text).contains { stem($0) == term || ($0.count > 4 && term.count > 3 && $0.hasPrefix(term)) }
    }
}

enum SearchURL {
    static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#?/:"))) ?? s }
}

private func fetchJSON(_ url: String, client: WebClient, headers: [String: String] = [:]) async -> Result<JSONValue, ResearchFailure> {
    var cfg = FetchConfig(); cfg.maxBytes = 3_000_000; cfg.accept = "application/json"; cfg.extraHeaders = headers
    switch await client.fetch(url, config: cfg) {
    case .failure(let f): return .failure(f)
    case .success(let doc): return JSONValue.parse(doc.body).map { .success($0) } ?? .failure(.providerFailed("the response was not JSON"))
    }
}

// MARK: - DuckDuckGo (HTML endpoint, no key)

/// General web discovery without an API key. Chosen after checking: `html.duckduckgo.com/robots.txt` allows crawling (`Allow: /`), the terms
/// do not forbid it, Brave's API needs a key (and its free tier is gone/contested), SearXNG public instances are unreliable. It is
/// a discovery aid with polite pacing; if the service answers with a challenge JARVIS stops (no evasion) and uses the structured providers.
struct DuckDuckGoHTMLProvider: SearchProvider {
    let id = "duckduckgo-html"
    let title = "DuckDuckGo (HTML, no key)"
    var capabilities: ProviderCapabilities { ProviderCapabilities(rateLimitNote: "≥ 2 s between requests; a challenge page stops the provider") }
    var hostInterval: TimeInterval { 2.0 }

    func search(_ query: String, limit: Int, client: WebClient) async -> Result<[WebSearchHit], ResearchFailure> {
        var cfg = FetchConfig(); cfg.maxBytes = 900_000
        switch await client.fetch("https://html.duckduckgo.com/html/?q=\(SearchURL.encode(query))", config: cfg) {
        case .failure(let f):
            if case .httpStatus(202) = f { return .failure(.captcha) }
            return .failure(f)
        case .success(let doc):
            if doc.status == 202 { return .failure(.captcha) }
            let hits = Self.parse(doc.text, limit: limit)
            if hits.isEmpty {
                let probe = HTMLExtractor.extract(doc.body, maxChars: 2_000)
                if probe.isCaptchaChallenge || doc.text.lowercased().contains("anomaly") { return .failure(.captcha) }
                return .failure(.noResults)
            }
            return .success(hits)
        }
    }

    static func parse(_ html: String, limit: Int) -> [WebSearchHit] {
        guard let anchor = try? NSRegularExpression(pattern: "<a[^>]*class=\"[^\"]*result__a[^\"]*\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>", options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let snippet = try? NSRegularExpression(pattern: "<a[^>]*class=\"[^\"]*result__snippet[^\"]*\"[^>]*>(.*?)</a>", options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        let anchors = anchor.matches(in: html, range: full)
        let snippets = snippet.matches(in: html, range: full)
        var hits: [WebSearchHit] = []
        for (i, m) in anchors.enumerated() {
            guard hits.count < limit else { break }
            let href = HTMLExtractor.decodeEntities(ns.substring(with: m.range(at: 1)))
            let title = stripTags(ns.substring(with: m.range(at: 2)))
            guard let real = resolve(href), !title.isEmpty else { continue }
            // an advert redirect ("y.js") is not an organic result
            if real.contains("duckduckgo.com/y.js") { continue }
            let snip: String = {
                // the snippet that follows this anchor and precedes the next one
                let end = i + 1 < anchors.count ? anchors[i + 1].range.location : ns.length
                guard let s = snippets.first(where: { $0.range.location > m.range.location && $0.range.location < end }) else { return "" }
                return stripTags(ns.substring(with: s.range(at: 1)))
            }()
            hits.append(WebSearchHit(title: title, url: real, snippet: snip, provider: "duckduckgo-html", rank: hits.count + 1))
        }
        return hits
    }

    private static func stripTags(_ s: String) -> String {
        let noTags = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return HTMLExtractor.decodeEntities(noTags).collapsedWhitespace
    }

    /// DuckDuckGo wraps results as `//duckduckgo.com/l/?uddg=<percent-encoded target>&rut=…`.
    private static func resolve(_ href: String) -> String? {
        var h = href
        if h.hasPrefix("//") { h = "https:" + h }
        guard let comps = URLComponents(string: h) else { return nil }
        if comps.host?.hasSuffix("duckduckgo.com") == true, comps.path.hasPrefix("/l/") {
            return comps.queryItems?.first(where: { $0.name == "uddg" })?.value
        }
        return h.hasPrefix("http") ? h : nil
    }
}

// MARK: - GitHub (public REST API, no key)

struct GitHubSearchProvider: SearchProvider {
    let id = "github-repositories"
    let title = "GitHub repositories (public API)"
    var capabilities: ProviderCapabilities { ProviderCapabilities(downloadCapable: true, structuredMetadata: true, rateLimitNote: "unauthenticated search is limited to 10 requests per minute") }
    var hostInterval: TimeInterval { 1.5 }
    static let headers = ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]

    func search(_ query: String, limit: Int, client: WebClient) async -> Result<[WebSearchHit], ResearchFailure> {
        // GitHub ANDs every word: a sentence finds nothing. Try the short subject query, then an even shorter one.
        let core = SearchTerms.core(query, max: 4)
        var attempts = [core.isEmpty ? query : core]
        let shorter = core.split(separator: " ").prefix(2).joined(separator: " ")
        if shorter != core, !shorter.isEmpty { attempts.append(shorter) }
        var lastFailure: ResearchFailure = .noResults
        for q in attempts {
            switch await searchOnce(q, limit: limit, client: client) {
            case .success(let hits): return .success(hits)
            case .failure(let f): lastFailure = f; if f != .noResults { return .failure(f) }
            }
        }
        return .failure(lastFailure)
    }

    private func searchOnce(_ query: String, limit: Int, client: WebClient) async -> Result<[WebSearchHit], ResearchFailure> {
        switch await fetchJSON("https://api.github.com/search/repositories?q=\(SearchURL.encode(query))&per_page=\(min(limit, 20))", client: client, headers: Self.headers) {
        case .failure(let f): return .failure(f)
        case .success(let json):
            let items = json["items"]?.array ?? []
            guard !items.isEmpty else { return .failure(.noResults) }
            return .success(items.prefix(limit).enumerated().compactMap { i, repo in
                guard let url = repo["html_url"]?.string, let name = repo["full_name"]?.string else { return nil }
                var facts: [String: String] = [:]
                if let l = repo.at("license.spdx_id")?.string { facts["license"] = l }
                if let s = repo["stargazers_count"]?.string { facts["stars"] = s }
                if let p = repo["pushed_at"]?.string { facts["pushed_at"] = p }
                if repo["archived"]?.bool == true { facts["archived"] = "true" }
                return WebSearchHit(title: name, url: url, snippet: repo["description"]?.string ?? "", provider: id, rank: i + 1, facts: facts)
            })
        }
    }
}

/// Repository facts from the public API: licence, activity, archived flag and the newest release's downloadable assets.
struct GitHubRepoFacts: Equatable, Sendable {
    var fullName: String
    var htmlURL: String
    var description: String?
    var licenseSPDX: String?
    var licenseName: String?
    var archived: Bool
    var pushedAt: String?
    var latestRelease: String?
    var assets: [Asset]
    struct Asset: Equatable, Sendable { var name: String; var url: String; var size: Int; var contentType: String?; var sha256: String? }
}

enum GitHubInspector {
    static func parseRepoURL(_ url: String) -> (owner: String, repo: String)? {
        guard let u = URL(string: url), let host = u.host?.lowercased(), host == "github.com" || host == "www.github.com" else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, !["topics", "search", "orgs", "marketplace", "sponsors", "settings"].contains(parts[0]) else { return nil }
        return (parts[0], parts[1].replacingOccurrences(of: ".git", with: ""))
    }

    static func facts(owner: String, repo: String, client: WebClient) async -> Result<GitHubRepoFacts, ResearchFailure> {
        switch await fetchJSON("https://api.github.com/repos/\(owner)/\(repo)", client: client, headers: GitHubSearchProvider.headers) {
        case .failure(let f): return .failure(f)
        case .success(let r):
            var facts = GitHubRepoFacts(fullName: r["full_name"]?.string ?? "\(owner)/\(repo)", htmlURL: r["html_url"]?.string ?? "https://github.com/\(owner)/\(repo)", description: r["description"]?.string,
                                        licenseSPDX: r.at("license.spdx_id")?.string, licenseName: r.at("license.name")?.string, archived: r["archived"]?.bool ?? false, pushedAt: r["pushed_at"]?.string,
                                        latestRelease: nil, assets: [])
            if case .success(let rel) = await fetchJSON("https://api.github.com/repos/\(owner)/\(repo)/releases/latest", client: client, headers: GitHubSearchProvider.headers) {
                facts.latestRelease = rel["tag_name"]?.string
                facts.assets = (rel["assets"]?.array ?? []).compactMap { a in
                    guard let name = a["name"]?.string, let url = a["browser_download_url"]?.string else { return nil }
                    let digest = a["digest"]?.string.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil }
                    return GitHubRepoFacts.Asset(name: name, url: url, size: Int(a["size"]?.double ?? 0), contentType: a["content_type"]?.string, sha256: digest)
                }
            }
            return .success(facts)
        }
    }

    /// The repository's own LICENSE text (raw), when the API can provide it.
    static func licenseText(owner: String, repo: String, client: WebClient) async -> String? {
        guard case .success(let j) = await fetchJSON("https://api.github.com/repos/\(owner)/\(repo)/license", client: client, headers: GitHubSearchProvider.headers),
              let content = j["content"]?.string, let data = Data(base64Encoded: content.replacingOccurrences(of: "\n", with: "")) else { return nil }
        return String(data: data.prefix(60_000), encoding: .utf8)
    }
}

// MARK: - Community sources (public APIs, no key)

struct HackerNewsProvider: SearchProvider {
    let id = "hacker-news"
    let title = "Hacker News (Algolia, public)"
    var capabilities: ProviderCapabilities { ProviderCapabilities(structuredMetadata: true) }
    func search(_ query: String, limit: Int, client: WebClient) async -> Result<[WebSearchHit], ResearchFailure> {
        let q = SearchTerms.core(query, max: 6)
        switch await fetchJSON("https://hn.algolia.com/api/v1/search?query=\(SearchURL.encode(q.isEmpty ? query : q))&tags=story&hitsPerPage=\(min(limit, 15))", client: client) {
        case .failure(let f): return .failure(f)
        case .success(let j):
            let hits = (j["hits"]?.array ?? []).prefix(limit).enumerated().compactMap { i, h -> WebSearchHit? in
                guard let title = h["title"]?.string, let oid = h["objectID"]?.string else { return nil }
                return WebSearchHit(title: title, url: "https://news.ycombinator.com/item?id=\(oid)", snippet: "\(h["points"]?.string ?? "0") points · \(h["num_comments"]?.string ?? "0") comments", provider: id, rank: i + 1,
                                 facts: h["url"]?.string.map { ["external_url": $0] } ?? [:])
            }
            return hits.isEmpty ? .failure(.noResults) : .success(Array(hits))
        }
    }
}

struct StackExchangeProvider: SearchProvider {
    let id = "stack-exchange"
    let title = "Stack Exchange (public API)"
    var site = "stackoverflow"
    var capabilities: ProviderCapabilities { ProviderCapabilities(structuredMetadata: true, rateLimitNote: "300 requests per day without a key") }
    var hostInterval: TimeInterval { 1.2 }
    func search(_ query: String, limit: Int, client: WebClient) async -> Result<[WebSearchHit], ResearchFailure> {
        let q = SearchTerms.core(query, max: 6)
        switch await fetchJSON("https://api.stackexchange.com/2.3/search/advanced?order=desc&sort=relevance&q=\(SearchURL.encode(q.isEmpty ? query : q))&site=\(site)&pagesize=\(min(limit, 15))", client: client) {
        case .failure(let f): return .failure(f)
        case .success(let j):
            let hits = (j["items"]?.array ?? []).prefix(limit).enumerated().compactMap { i, q -> WebSearchHit? in
                guard let link = q["link"]?.string, let title = q["title"]?.string else { return nil }
                var facts: [String: String] = [:]
                if q["is_answered"]?.bool == true { facts["answered"] = "true" }
                if let a = q["accepted_answer_id"]?.string { facts["accepted_answer"] = a }
                return WebSearchHit(title: HTMLExtractor.decodeEntities(title), url: link, snippet: "score \(q["score"]?.string ?? "0") · \(q["answer_count"]?.string ?? "0") answers", provider: id, rank: i + 1, facts: facts)
            }
            return hits.isEmpty ? .failure(.noResults) : .success(Array(hits))
        }
    }
}

// MARK: - Poly Haven (public API; every asset is CC0 per the site)

struct PolyHavenProvider: SearchProvider {
    let id = "polyhaven"
    let title = "Poly Haven (public API, CC0)"
    var capabilities: ProviderCapabilities { ProviderCapabilities(downloadCapable: true, structuredMetadata: true, rateLimitNote: "send a descriptive User-Agent; the catalogue is cached per run") }
    var kind = "models"        // models | textures | hdris

    func search(_ query: String, limit: Int, client: WebClient) async -> Result<[WebSearchHit], ResearchFailure> {
        switch await fetchJSON("https://api.polyhaven.com/assets?t=\(kind)", client: client) {
        case .failure(let f): return .failure(f)
        case .success(let j):
            guard let all = j.object else { return .failure(.noResults) }
            let terms = SearchTerms.subject(query)
            var scored: [(Double, String, JSONValue)] = []
            var byTerm: [String: [(Double, String, JSONValue)]] = [:]
            for (slug, a) in all {
                let hay = ([a["name"]?.string ?? "", slug.replacingOccurrences(of: "_", with: " ")] + (a["categories"]?.array ?? []).compactMap(\.string) + (a["tags"]?.array ?? []).compactMap(\.string)).joined(separator: " ")
                let hitTerms = terms.filter { SearchTerms.mentions(hay, term: $0) }
                let popularity = (a["download_count"]?.double ?? 0) / 1_000_000
                if !hitTerms.isEmpty { scored.append((Double(hitTerms.count) + popularity, slug, a)) }
                for t in hitTerms { byTerm[t, default: []].append((popularity, slug, a)) }
            }
            // Breadth first: a popular asset for ONE word must not crowd out the only asset for another ("bucket" vs "bath"). Multi-word matches lead, then one best per word in turn.
            var picked: [(Double, String, JSONValue)] = []
            var seen = Set<String>()
            for item in scored.filter({ $0.0 >= 2 }).sorted(by: { $0.0 > $1.0 }) where seen.insert(item.1).inserted { picked.append(item) }
            let lists = terms.compactMap { byTerm[$0]?.sorted { $0.0 > $1.0 } }
            var depth = 0
            while picked.count < limit, lists.contains(where: { depth < $0.count }) {
                for l in lists where depth < l.count && picked.count < limit { if seen.insert(l[depth].1).inserted { picked.append(l[depth]) } }
                depth += 1
            }
            let top = picked.prefix(limit)
            guard !top.isEmpty else { return .failure(.noResults) }
            return .success(top.enumerated().map { i, t in
                WebSearchHit(title: t.2["name"]?.string ?? t.1, url: "https://polyhaven.com/a/\(t.1)", snippet: (t.2["categories"]?.array ?? []).compactMap(\.string).joined(separator: ", "), provider: id, rank: i + 1,
                          facts: ["slug": t.1, "kind": kind, "license": "CC0-1.0", "price": "0"])
            })
        }
    }

    /// Download options for one asset: format → resolution → (url, size, md5).
    struct File: Equatable, Sendable { var format: String; var resolution: String; var url: String; var size: Int; var md5: String?; var includes: Int }
    static func files(slug: String, client: WebClient) async -> [File] {
        guard case .success(let j) = await fetchJSON("https://api.polyhaven.com/files/\(slug)", client: client), let root = j.object else { return [] }
        var out: [File] = []
        for (format, byRes) in root where ["fbx", "gltf", "blend", "usd", "obj"].contains(format) {
            for (res, byKind) in byRes.object ?? [:] {
                guard let file = byKind[format] ?? byKind.object?.values.first(where: { $0["url"] != nil }), let url = file["url"]?.string else { continue }
                out.append(File(format: format, resolution: res, url: url, size: Int(file["size"]?.double ?? 0), md5: file["md5"]?.string, includes: file["include"]?.object?.count ?? 0))
            }
        }
        return out.sorted { ($0.size, $0.format) < ($1.size, $1.format) }
    }
}


// MARK: - Unity documentation (a deterministic resolver, not a search engine)

/// "Open the official Unity documentation for BoxCollider" does not need a search engine: the ScriptReference URL is predictable. The pipeline still READS the page
/// (so a wrong guess is a failed source, never a fabricated one) and classifies docs.unity3d.com as official for a Unity question.
struct UnityDocsProvider: SearchProvider {
    let id = "unity-docs-direct"
    let title = "Unity documentation (direct)"
    var capabilities: ProviderCapabilities { ProviderCapabilities(structuredMetadata: false, rateLimitNote: "one request per identifier; docs.unity3d.com only") }
    var version = "6000.0"

    static let ignored: Set<String> = ["Unity", "Find", "Documentation", "Official", "Research", "The", "Compare", "Search", "Open", "Show", "Docs", "API", "Manual", "Script", "Reference", "What", "How", "Please", "Jarvis", "Turkish", "English", "Mixamo", "GitHub", "Asset", "Store", "URP", "HDRP"]

    /// CamelCase identifiers in the text ("BoxCollider", "Rigidbody2D", "NavMeshAgent"); a single capitalised word counts only when it is a long, non-common word.
    static func identifiers(in text: String) -> [String] {
        var out: [String] = []
        for raw in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let w = String(raw)
            guard w.count >= 5, w.first?.isUppercase == true, !ignored.contains(w) else { continue }
            let humps = w.dropFirst().filter { $0.isUppercase }.count
            if humps >= 1 || w.contains(where: { $0.isNumber }), !out.contains(w) { out.append(w) }
        }
        return out
    }

    func search(_ query: String, limit: Int, client: WebClient) async -> Result<[WebSearchHit], ResearchFailure> {
        let ids = Self.identifiers(in: query).prefix(max(1, min(limit, 3)))
        guard !ids.isEmpty else { return .failure(.noResults) }
        return .success(ids.enumerated().map { i, name in
            WebSearchHit(title: "\(name) — Unity Scripting API", url: "https://docs.unity3d.com/\(version)/Documentation/ScriptReference/\(name).html", snippet: "Official Unity ScriptReference page for \(name).", provider: id, rank: i + 1)
        })
    }
}

// MARK: - Kenney (CC0 game-asset library; public pages, direct download links, no account)

struct KenneyProvider: SearchProvider {
    let id = "kenney"
    let title = "Kenney (public CC0 asset library)"
    var capabilities: ProviderCapabilities { ProviderCapabilities(downloadCapable: true, structuredMetadata: false, rateLimitNote: "a handful of category pages per query") }
    var hostInterval: TimeInterval { 1.0 }

    static func category(for terms: Set<String>) -> String {
        if !terms.isDisjoint(with: ["texture", "textures", "material", "tiles"]) { return "Textures" }
        if !terms.isDisjoint(with: ["2d", "sprite", "sprites", "ui", "icons", "pixel"]) { return "2D" }
        if !terms.isDisjoint(with: ["sound", "audio", "sfx", "music"]) { return "Audio" }
        return "3D"
    }

    static func parse(_ html: String) -> [(slug: String, title: String)] {
        guard let re = try? NSRegularExpression(pattern: "<h2><a href='https://kenney\\.nl/assets/([a-z0-9-]+)'>([^<]+)</a></h2>") else { return [] }
        let ns = html as NSString
        return re.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { (ns.substring(with: $0.range(at: 1)), HTMLExtractor.decodeEntities(ns.substring(with: $0.range(at: 2)))) }
    }

    func search(_ query: String, limit: Int, client: WebClient) async -> Result<[WebSearchHit], ResearchFailure> {
        let terms = SearchTerms.subject(query)
        let cat = Self.category(for: SourceClassifier.subjectTerms(query))
        var all: [(slug: String, title: String)] = []
        for page in 1...4 {
            let url = page == 1 ? "https://kenney.nl/assets/category:\(cat)" : "https://kenney.nl/assets/category:\(cat)/page:\(page)"
            var cfg = FetchConfig(); cfg.maxBytes = 600_000
            switch await client.fetch(url, config: cfg) {
            case .failure(let f): if page == 1 { return .failure(f) }
            case .success(let doc): let items = Self.parse(doc.text); if items.isEmpty { break }; all += items
            }
        }
        // slug/title words vs. the question's words (the page's own tags are not on the index; a listing that merely mentions "kit" is not a match)
        let scored = all.map { item -> (Double, (slug: String, title: String)) in
            let hay = item.slug.replacingOccurrences(of: "-", with: " ") + " " + item.title
            return (terms.reduce(0.0) { $0 + (SearchTerms.mentions(hay, term: $1) ? 1 : 0) }, item)
        }.filter { $0.0 > 0 }.sorted { $0.0 > $1.0 }
        guard !scored.isEmpty else { return .failure(.noResults) }
        return .success(scored.prefix(limit).enumerated().map { i, s in
            WebSearchHit(title: s.1.title, url: "https://kenney.nl/assets/\(s.1.slug)", snippet: "Kenney \(cat) asset pack", provider: id, rank: i + 1, facts: ["category": cat])
        })
    }
}


// MARK: - Stack Exchange question as a document (via the public API, never by scraping the HTML page)

extension StackExchangeProvider {
    /// stackoverflow.com answers automated page requests with 403. The documented public API returns the same question and answers, so that is the route (no evasion, no headers faked).
    static func apiDocument(for link: String, client: WebClient) async -> Result<FetchedDocument, ResearchFailure> {
        guard let u = URL(string: link), let host = u.host?.lowercased(), host == "stackoverflow.com" || host.hasSuffix(".stackexchange.com") || host == "superuser.com" || host == "serverfault.com" || host == "askubuntu.com",
              let idString = u.path.split(separator: "/").drop(while: { $0 != "questions" }).dropFirst().first, let qid = Int(idString) else { return .failure(.providerFailed("not a Stack Exchange question link")) }
        let site = host == "stackoverflow.com" ? "stackoverflow" : (host.hasSuffix(".stackexchange.com") ? String(host.dropLast(".stackexchange.com".count)) : String(host.split(separator: ".").first ?? ""))
        guard case .success(let q) = await fetchJSON("https://api.stackexchange.com/2.3/questions/\(qid)?site=\(site)&filter=withbody", client: client), let item = q["items"]?.array?.first else { return .failure(.noResults) }
        var answers: [JSONValue] = []
        if case .success(let a) = await fetchJSON("https://api.stackexchange.com/2.3/questions/\(qid)/answers?order=desc&sort=votes&site=\(site)&filter=withbody&pagesize=3", client: client) { answers = a["items"]?.array ?? [] }
        let title = HTMLExtractor.decodeEntities(item["title"]?.string ?? "Question \(qid)")
        var html = "<html><head><title>\(title)</title></head><body><h1>\(title)</h1><div>\(item["body"]?.string ?? "")</div>"
        html += "<p>Score \(item["score"]?.string ?? "0"), \(item["answer_count"]?.string ?? "0") answers.</p>"
        for (i, a) in answers.enumerated() { html += "<h2>Answer \(i + 1)\(a["is_accepted"]?.bool == true ? " (accepted)" : "") — score \(a["score"]?.string ?? "0")</h2><div>\(a["body"]?.string ?? "")</div>" }
        html += "</body></html>"
        let body = Data(html.utf8)
        return .success(FetchedDocument(requestedURL: u, finalURL: u, hops: [], status: 200, headers: ["content-type": "text/html; charset=utf-8"], contentType: "text/html", body: body, truncated: false, retrievedAt: Date(), remoteAddress: nil, method: .api))
    }
}
