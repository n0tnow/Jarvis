import Foundation

// MARK: - MCP discovery (V0.14, DEC-224): research, not installation
//
// Uses the V0.9 web client (URL policy, per-hop checks, polite rate limits — no key, no paid API). Sources, best first:
//   1. the official MCP registry (registry.modelcontextprotocol.io) — a lead with publisher-declared metadata;
//   2. repository facts from the public GitHub API (licence, activity, archived, stars) for every lead that names a repository;
//   3. the repository's own README for credential / network / risk statements (text is DATA; instruction-shaped text is flagged, never followed).
// Popularity is a lead, never trust. Anything not found stays UNKNOWN. Discovery stores records as DISCOVERED — it never installs, downloads executables or registers.

enum MCPDomain: String, CaseIterable, Sendable {
    case design, image, audio, speech, threeD = "3d", blender, unity, animation, texture, assets, web, docs, coding, testing, git, files
    var label: String {
        switch self {
        case .design: "UI / product design"; case .image: "image generation / editing"; case .audio: "audio and sound effects"; case .speech: "speech / TTS"; case .threeD: "3D modelling"
        case .blender: "Blender"; case .unity: "Unity"; case .animation: "animation / rigging"; case .texture: "texture / material generation"; case .assets: "asset management"
        case .web: "web research"; case .docs: "documentation"; case .coding: "coding"; case .testing: "testing"; case .git: "Git / GitHub"; case .files: "file / document workflows"
        }
    }
    /// Short search phrases (kept few: the GitHub API ANDs every word).
    var terms: [String] {
        switch self {
        case .design: ["figma", "design"]; case .image: ["image generation"]; case .audio: ["audio", "sound effects"]; case .speech: ["text to speech"]
        case .threeD: ["3d modeling"]; case .blender: ["blender"]; case .unity: ["unity"]; case .animation: ["animation", "rigging"]; case .texture: ["texture"]
        case .assets: ["asset"]; case .web: ["web search"]; case .docs: ["documentation"]; case .coding: ["code"]; case .testing: ["testing"]; case .git: ["github"]; case .files: ["filesystem"]
        }
    }
    static func parse(_ text: String) -> MCPDomain? {
        let t = MemoryText.fold(text)
        let table: [(MCPDomain, [String])] = [(.blender, ["blender"]), (.unity, ["unity"]), (.animation, ["animasyon", "animation", "rig", "mixamo"]), (.audio, ["ses ", "audio", "sound", "muzik", "music", "sfx"]),
                                               (.speech, ["konusma", "speech", "tts", "text to speech", "seslendirme"]), (.design, ["tasarim", "design", "figma", "arayuz", "ui "]), (.image, ["gorsel", "image", "resim", "picture"]),
                                               (.threeD, ["3d", "3 boyut", "modelleme", "modeling", "modelling"]), (.texture, ["texture", "doku", "materyal", "material"]), (.assets, ["asset", "varlik"]),
                                               (.git, ["github", "git "]), (.docs, ["dokuman", "documentation", "docs"]), (.testing, ["test"]), (.web, ["web ", "internet"]), (.files, ["dosya", "file"]), (.coding, ["kod", "code", "coding"])]
        let padded = t + " "
        return table.first { $0.1.contains { padded.contains($0) } }?.0
    }
}

struct MCPDiscoveryReport: Equatable, Sendable {
    var domain: String
    var records: [MCPDiscoveryRecord]
    var sourcesQueried: [String]
    var failures: [String]
    var at: Date
    /// Candidates that clear the bar: licence known, not archived, pushed within 12 months, a repository to inspect.
    var credible: [MCPDiscoveryRecord] { records.filter { MCPDiscovery.assess($0).clears } }
}

final class MCPDiscovery: @unchecked Sendable {
    let client: WebClient
    init(client: WebClient) { self.client = client }
    static let registryHost = "https://registry.modelcontextprotocol.io"

    private func json(_ url: String, headers: [String: String] = [:]) async -> (JSONValue?, String?) {
        var cfg = FetchConfig(); cfg.maxBytes = 3_000_000; cfg.accept = "application/json"; cfg.extraHeaders = headers
        switch await client.fetch(url, config: cfg) {
        case .failure(let f): return (nil, "\(url.prefix(70)) — \(f)")
        case .success(let doc): return (JSONValue.parse(doc.body), JSONValue.parse(doc.body) == nil ? "\(url.prefix(70)) — not JSON" : nil)
        }
    }

    // MARK: Search

    func search(domain: MCPDomain, extraTerms: [String] = [], limit: Int = 6, enrichLeads: Bool = true) async -> MCPDiscoveryReport {
        var records: [MCPDiscoveryRecord] = [], queried: [String] = [], failures: [String] = []
        var seenRepos = Set<String>()
        let terms = Array((domain.terms + extraTerms).prefix(2))

        // 1. official registry
        for term in terms {
            queried.append("official MCP registry · “\(term)”")
            let (j, err) = await json("\(Self.registryHost)/v0/servers?search=\(SearchURL.encode(term))&limit=20")
            if let err { failures.append(err); continue }
            for e in (j?["servers"]?.array ?? []).prefix(20) {
                let s = e["server"] ?? e
                guard let name = s["name"]?.string, Self.relevant(name + " " + (s["description"]?.string ?? ""), to: terms) else { continue }
                let repoURL = s.at("repository.url")?.string ?? s["repository"]?.string
                let key = (repoURL ?? name).lowercased()
                guard seenRepos.insert(key).inserted else { continue }
                let pkgs = s["packages"]?.array ?? []
                let first = pkgs.first
                let registryName = first?["registry_name"]?.string ?? first?["registryType"]?.string ?? first?["registry_type"]?.string
                let remotes = s["remotes"]?.array ?? []
                var r = MCPDiscoveryRecord(name: name, domain: domain.label, sourceURL: "\(Self.registryHost)/v0/servers?search=\(SearchURL.encode(term))", repository: repoURL, publisher: name.split(separator: "/").first.map(String.init),
                                           license: nil, version: s["version"]?.string ?? s.at("version_detail.version")?.string, lastRelease: Self.date(s.at("version_detail.release_date")?.string ?? s.at("_meta.io.modelcontextprotocol.registry/official.publishedAt")?.string),
                                           installMethod: registryName ?? (remotes.isEmpty ? nil : "remote service"), runtime: first?["runtime_hint"]?.string ?? first?["runtimeHint"]?.string ?? registryName.map(Self.runtime(for:)),
                                           networkRequirement: remotes.isEmpty ? "unknown" : "required (remote service)", credentialRequirement: "unknown", filesystemRequirement: "unknown", processRequirement: "unknown",
                                           declaredTools: [], declaredResources: [], declaredPrompts: [], knownRisks: [], price: "unknown", apiRequirements: "unknown", macOS: "unknown", appleSilicon: "unknown", overlap: [],
                                           expectedBenefit: OutputSanitizer.sanitize(String((s["description"]?.string ?? "").prefix(240))), evidenceFetchedAt: Date(), sourceKind: "official registry (publisher-declared)")
                if !remotes.isEmpty { r.knownRisks.append("hosted service: your data would leave this Mac") }
                records.append(r)
            }
        }
        // 2. GitHub search (community leads)
        for term in terms {
            queried.append("GitHub repositories · “\(term) mcp”")
            let q = "\(term) mcp in:name,description,topics"
            let (j, err) = await json("https://api.github.com/search/repositories?q=\(SearchURL.encode(q))&sort=stars&order=desc&per_page=8", headers: GitHubSearchProvider.headers)
            if let err { failures.append(err); continue }
            for item in (j?["items"]?.array ?? []).prefix(8) {
                guard let url = item["html_url"]?.string, seenRepos.insert(url.lowercased()).inserted, let full = item["full_name"]?.string else { continue }
                let topics = (item["topics"]?.array ?? []).compactMap(\.string)
                let blob = full + " " + (item["description"]?.string ?? "") + " " + topics.joined(separator: " ")
                guard Self.relevant(blob, to: ["mcp", "model context protocol"]), Self.relevant(blob, to: terms) else { continue }          // “mcp” as a WORD (a substring also matched “mcprep”)
                records.append(MCPDiscoveryRecord(name: full, domain: domain.label, sourceURL: url, repository: url, publisher: item.at("owner.login")?.string, license: item.at("license.spdx_id")?.string,
                                                  version: nil, lastRelease: nil, lastPush: Self.date(item["pushed_at"]?.string), stars: Int(item["stargazers_count"]?.double ?? 0), installMethod: nil, runtime: item["language"]?.string.map { $0.lowercased() },
                                                  networkRequirement: "unknown", credentialRequirement: "unknown", filesystemRequirement: "unknown", processRequirement: "unknown", declaredTools: [], declaredResources: [], declaredPrompts: [],
                                                  knownRisks: item["archived"]?.bool == true ? ["the repository is archived"] : [], price: "unknown", apiRequirements: "unknown", macOS: "unknown", appleSilicon: "unknown", overlap: [],
                                                  expectedBenefit: OutputSanitizer.sanitize(String((item["description"]?.string ?? "").prefix(240))), evidenceFetchedAt: Date(), sourceKind: "repository search (community lead)"))
            }
        }
        // 3. enrich the best leads with repository facts and the README
        var out = records
        if enrichLeads {
            let ranked = records.sorted { Self.leadScore($0) > Self.leadScore($1) }.prefix(limit)
            var enriched: [MCPDiscoveryRecord] = []
            for r in ranked { enriched.append(await enrich(r, failures: &failures)) }
            out = enriched + records.filter { r in !ranked.contains { $0.repository == r.repository && $0.name == r.name } }.prefix(max(0, limit))
        }
        return MCPDiscoveryReport(domain: domain.label, records: out, sourcesQueried: queried, failures: failures, at: Date())
    }

    /// A lead is relevant when a search term appears as a whole word (so “blender” does not match “Toll Blenders”).
    static func relevant(_ text: String, to terms: [String]) -> Bool {
        let t = " " + MemoryText.fold(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ") + " "
        return terms.contains { term in
            let words = MemoryText.fold(term).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            return words.allSatisfy { t.contains(" \($0) ") }
        }
    }

    /// A lead the USER named (an address of a repository): the same evidence as a searched lead, labelled as such.
    func record(forRepository url: String, domain: String) async -> MCPDiscoveryRecord? {
        guard let (owner, name) = GitHubInspector.parseRepoURL(url) else { return nil }
        let base = MCPDiscoveryRecord(name: "\(owner)/\(name)", domain: domain, sourceURL: url, repository: url, publisher: owner, license: nil, version: nil, lastRelease: nil, lastPush: nil, stars: nil, installMethod: nil, runtime: nil,
                                      networkRequirement: "unknown", credentialRequirement: "unknown", filesystemRequirement: "unknown", processRequirement: "unknown", declaredTools: [], declaredResources: [], declaredPrompts: [], knownRisks: [],
                                      price: "unknown", apiRequirements: "unknown", macOS: "unknown", appleSilicon: "unknown", overlap: [], expectedBenefit: "", evidenceFetchedAt: Date(), sourceKind: "named repository (requested)")
        var failures: [String] = []
        return await enrich(base, failures: &failures)
    }

    static func leadScore(_ r: MCPDiscoveryRecord) -> Double {
        var s = 0.0
        if r.sourceKind.hasPrefix("official") { s += 3 }
        if r.repository != nil { s += 1 }
        s += min(2, log10(Double(max(1, r.stars ?? 1))) / 2)
        if let p = r.lastPush ?? r.lastRelease, Date().timeIntervalSince(p) < 180 * 86_400 { s += 1 }
        return s
    }

    // MARK: Enrichment

    func enrich(_ base: MCPDiscoveryRecord, failures: inout [String]) async -> MCPDiscoveryRecord {
        var r = base
        guard let repo = r.repository, let (owner, name) = GitHubInspector.parseRepoURL(repo) else { return r }
        if case .success(let f) = await GitHubInspector.facts(owner: owner, repo: name, client: client) {
            r.license = f.licenseSPDX ?? r.license
            r.lastPush = Self.date(f.pushedAt) ?? r.lastPush
            if f.archived { r.knownRisks.append("the repository is archived") }
            if let rel = f.latestRelease { r.version = r.version ?? rel }
        } else { failures.append("repository facts for \(owner)/\(name) could not be read") }
        let (readme, _) = await json("https://api.github.com/repos/\(owner)/\(name)/readme", headers: GitHubSearchProvider.headers)
        if let content = readme?["content"]?.string, let data = Data(base64Encoded: content.replacingOccurrences(of: "\n", with: "")), let text = String(data: data.prefix(80_000), encoding: .utf8) {
            MCPReadme.apply(readme: text, to: &r)
        }
        // price: an open-source licence says the CODE is free; what its backing API costs stays unknown unless the README says it needs a key
        let open = Set(["MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC", "MPL-2.0", "GPL-3.0", "GPL-2.0", "LGPL-3.0", "AGPL-3.0", "Unlicense", "0BSD"])
        if let l = r.license, open.contains(l) { r.price = r.credentialRequirement.contains("api key") || r.credentialRequirement.contains("account") ? "free code; a service behind it may be paid (unknown)" : "free (open-source licence)" }
        r.evidenceFetchedAt = Date()
        return r
    }

    // MARK: The bar

    struct Assessment: Equatable { var clears: Bool; var score: Double; var reasons: [String] }
    static func assess(_ r: MCPDiscoveryRecord, now: Date = Date()) -> Assessment {
        var why: [String] = [], score = 0.0
        if r.repository == nil { why.append("no repository to inspect") } else { score += 1 }
        if !r.licenseKnown { why.append("licence unknown (an unknown licence is never safe)") } else { score += 1 }
        if let p = r.lastPush ?? r.lastRelease { if now.timeIntervalSince(p) > 365 * 86_400 { why.append("no activity for over a year") } else { score += 1 } } else { why.append("activity unknown") }
        if r.knownRisks.contains(where: { $0.contains("archived") }) { why.append("archived") }
        if r.knownRisks.contains(where: { $0.contains("arbitrary code") }) { why.append("exposes arbitrary code execution") }
        if r.macOS.hasPrefix("no") { why.append("not for macOS") }
        if r.sourceKind.hasPrefix("official") { score += 1 }
        return Assessment(clears: why.isEmpty, score: score, reasons: why)
    }

    static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime]; return f.date(from: iso)
    }
    static func runtime(for registry: String) -> String { ["npm": "node", "pypi": "python", "oci": "docker", "docker": "docker", "nuget": ".NET"][registry.lowercased()] ?? registry }

    /// The snapshot address of a repository (kept here with the other research addresses).
    static func sourceSnapshotURL(of r: MCPDiscoveryRecord) -> (url: String, name: String)? {
        guard let repo = r.repository, let (owner, name) = GitHubInspector.parseRepoURL(repo) else { return nil }
        return ("https://api.github.com/repos/\(owner)/\(name)/zipball", name)
    }
}
