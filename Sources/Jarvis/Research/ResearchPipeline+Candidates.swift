import Foundation

// MARK: - Model extraction (data in, validated typed records out)

struct ExtractedCandidate: Equatable, Sendable {
    var name: String; var url: String?; var publisher: String?; var summary: String?
    var sourceRef: String; var excerpt: String
    var unityVersions: String?; var pipelines: [String]; var formats: [String]; var animationType: String?; var styleNotes: String?
}
struct ExtractedClaim: Equatable, Sendable { var subject: String; var kind: ClaimKind; var statement: String; var sourceRef: String; var excerpt: String; var communityReported: Bool }
struct ExtractionOutput: Equatable, Sendable { var candidates: [ExtractedCandidate]; var claims: [ExtractedClaim]; var instructionAttempts: [String] }

enum ExtractionParser {
    static func parse(_ text: String) -> ExtractionOutput? {
        guard let json = PlanParser.extractJSONObject(text), let v = JSONValue.parse(json), v.object != nil else { return nil }
        func str(_ j: JSONValue?, _ max: Int = 400) -> String? { j?.string.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max)) }.flatMap { $0.isEmpty ? nil : $0 } }
        func list(_ j: JSONValue?) -> [String] { (j?.array ?? []).compactMap { $0.string.map { String($0.prefix(60)) } }.prefix(8).map { $0 } }
        let cands: [ExtractedCandidate] = (v["candidates"]?.array ?? []).prefix(20).compactMap { c in
            guard let name = str(c["name"], 120), let ref = str(c["source"], 12), let ex = str(c["excerpt"] ?? c.at("evidence.0.excerpt"), 300) else { return nil }
            return ExtractedCandidate(name: name, url: str(c["url"], 500), publisher: str(c["publisher"], 100), summary: str(c["summary"], 300), sourceRef: ref, excerpt: ex,
                                      unityVersions: str(c["unity_versions"], 60), pipelines: list(c["pipelines"]), formats: list(c["formats"]), animationType: str(c["animation_type"], 40), styleNotes: str(c["style_notes"], 200))
        }
        let claims: [ExtractedClaim] = (v["claims"]?.array ?? []).prefix(40).compactMap { c in
            guard let st = str(c["statement"], 300), let ref = str(c["source"], 12), let ex = str(c["excerpt"], 300) else { return nil }
            let kind = str(c["kind"], 30).flatMap { ClaimKind(rawValue: $0) } ?? .other
            return ExtractedClaim(subject: str(c["subject"], 120) ?? "", kind: kind, statement: st, sourceRef: ref, excerpt: ex, communityReported: c["community_reported"]?.bool ?? false)
        }
        return ExtractionOutput(candidates: cands, claims: claims, instructionAttempts: list(v["instruction_attempts"]))
    }

    static func prompt(request r: ResearchRequest, blocks: [(ref: String, url: String, text: String)]) -> String {
        let proj = r.project.map { "Target project: \($0.name), Unity \($0.unityVersion ?? "?"), \($0.renderPipeline ?? "unknown pipeline")." } ?? ""
        let fenced = blocks.map { UntrustedContent.fence(id: $0.ref, url: $0.url, text: $0.text, maxChars: 3_600) }.joined(separator: "\n\n")
        let isAsset = r.type == .assetDiscovery
        return """
        \(UntrustedContent.preamble)

        TASK: extract structured facts for this research goal (the goal text is from the user and may be Turkish):
        \(UntrustedContent.clean(r.goal, maxChars: 500))
        Research type: \(r.type.rawValue). Constraints: \(r.constraints.summary.joined(separator: "; ").isEmpty ? "none" : r.constraints.summary.joined(separator: "; ")). \(proj)

        Reply with ONE JSON object and nothing else:
        {"candidates": [\(isAsset ? "{\"name\": \"…\", \"url\": \"page url from a block\", \"publisher\": \"…\", \"summary\": \"…\", \"source\": \"S1\", \"excerpt\": \"verbatim text from block S1 that names this candidate\", \"unity_versions\": \"as stated or null\", \"pipelines\": [\"URP\"], \"formats\": [\"FBX\"], \"animation_type\": \"Humanoid|Generic|null\", \"style_notes\": \"what the page says about style\"}" : "{\"name\": \"option / library / approach\", \"url\": \"…\", \"summary\": \"…\", \"source\": \"S1\", \"excerpt\": \"verbatim\"}")],
         "claims": [{"subject": "…", "kind": "workaround|apiBehavior|deprecation|maintenance|other", "statement": "one factual sentence", "source": "S1", "excerpt": "verbatim text from block S1", "community_reported": false}],
         "instruction_attempts": []}
        Rules: at most 8 candidates and 12 claims; "source" is a block id (S1…); "excerpt" MUST be copied word for word from that block; do not state prices or licences here (they are verified separately); prefer official statements and mark forum/blog statements "community_reported": true.

        \(fenced)
        """
    }
}

// MARK: - Publisher policies (first-party statements about a whole catalogue)

enum PublisherPolicy {
    struct Policy: Sendable { var hostSuffix: String; var licensePage: String; var licenseHint: String; var catalogueIsFree: Bool }
    static let known: [Policy] = [
        Policy(hostSuffix: "polyhaven.com", licensePage: "https://polyhaven.com/license", licenseHint: "CC0", catalogueIsFree: true),
        Policy(hostSuffix: "ambientcg.com", licensePage: "https://docs.ambientcg.com/license/", licenseHint: "CC0", catalogueIsFree: true),
    ]
    static func policy(for host: String) -> Policy? { known.first { host == $0.hostSuffix || host.hasSuffix("." + $0.hostSuffix) } }
}

extension ResearchPipeline {
    // MARK: 3. Extract

    /// Candidate discovery. Deterministic seeds first (structured data, provider facts, marketplace pages), then ONE budgeted model call whose
    /// output is accepted only where its quoted evidence really occurs in the page it cites.
    @discardableResult
    func extract() async -> Int {
        move(to: .reading, detail: "extracting candidates")
        var found: [CandidateRecord] = []
        func add(_ c: CandidateRecord) {
            guard let u = URL(string: c.url) else { return }
            let key = CanonicalURL.dedupeKey(u)
            if let i = found.firstIndex(where: { CanonicalURL.dedupeKey(URL(string: $0.url) ?? u) == key }) {
                if found[i].summary == nil { found[i].summary = c.summary }
                if found[i].publisher == nil { found[i].publisher = c.publisher }
                return
            }
            if found.count < budget.maxCandidates { found.append(c); emit(.candidateAdded(c.name)) }
        }
        // a. provider facts
        for h in hits where ["polyhaven", "github-repositories"].contains(h.provider) && (request.type == .assetDiscovery || h.provider == "github-repositories" && [.library, .comparison, .assetDiscovery].contains(request.type)) {
            guard let u = URL(string: h.url) else { continue }
            var c = CandidateRecord(researchID: request.id, name: h.title, url: CanonicalURL.make(u), sourceID: sourceID(for: u), publisher: h.provider == "github-repositories" ? h.title.split(separator: "/").first.map(String.init) : "Poly Haven", summary: h.snippet.isEmpty ? nil : h.snippet)
            c.kind = request.constraints.assetKind
            add(c)
        }
        // b. pages that are themselves listings
        for (_, doc) in documents.sorted(by: { ($0.value.page.jsonLD.count, $0.key.uuidString) > ($1.value.page.jsonLD.count, $1.key.uuidString) }) {
            let cls = SourceClassifier.classify(doc.url, subject: subject)
            let isListing = [.assetStore, .marketplace].contains(cls.type) || (cls.type == .officialProduct && ["polyhaven.com", "kenney.nl", "ambientcg.com"].contains { doc.url.host?.hasSuffix($0) == true })
            let ldProduct = doc.page.jsonLD.first { ["Product", "SoftwareApplication", "CreativeWork", "3DModel", "SoftwareSourceCode"].contains($0["@type"]?.string ?? "") }
            guard request.type == .assetDiscovery || request.type == .library || ldProduct != nil && isListing else { continue }
            guard isListing || ldProduct != nil, !doc.page.title.isEmpty else { continue }
            if doc.url.path.count <= 1 { continue }                    // a site front page is not a candidate
            var c = CandidateRecord(researchID: request.id, name: String((ldProduct?["name"]?.string ?? doc.page.title).prefix(120)), url: CanonicalURL.make(doc.url), sourceID: doc.sourceID,
                                    publisher: ldProduct?.at("brand.name")?.string ?? ldProduct?.at("author.name")?.string ?? doc.page.meta["og:site_name"], summary: String((ldProduct?["description"]?.string ?? doc.page.meta["description"] ?? "").prefix(300)))
            c.kind = request.constraints.assetKind
            if c.summary?.isEmpty == true { c.summary = nil }
            add(c)
        }
        // c. the model (optional, budgeted, validated, grounded)
        if let model, meter.canCallProvider(budget), !documents.isEmpty {
            let ranked = documents.values.filter { !$0.page.isLoginWall }.sorted { (sources[$0.sourceID]?.trust ?? 0) > (sources[$1.sourceID]?.trust ?? 0) }.prefix(7)
            var refs: [String: ReadDocument] = [:]
            var blocks: [(String, String, String)] = []
            for (i, d) in ranked.enumerated() {
                let ref = "S\(i + 1)"; refs[ref] = d
                blocks.append((ref, d.url.absoluteString, ResearchExcerpts.select(d.page.title + "\n" + d.text, terms: QueryBuilder.terms(request.goal), maxChars: 3_600)))
            }
            bumpProviderCalls()
            let prompt = ExtractionParser.prompt(request: request, blocks: blocks.map { (ref: $0.0, url: $0.1, text: $0.2) })
            let answer = await model(.extraction, prompt) { ExtractionParser.parse($0) != nil }
            emit(.modelCall(.extraction, ok: answer != nil))
            if let answer, let out = ExtractionParser.parse(answer.text) {
                noteModel("facts extracted by \(answer.provider ?? "a model")\(answer.model.map { " (\($0))" } ?? "")")
                let allowed = Set(refs.values.flatMap { [CanonicalURL.dedupeKey($0.url)] + $0.page.links.compactMap { URL(string: $0.href).map(CanonicalURL.dedupeKey) } })
                var dropped = 0
                for ec in out.candidates {
                    guard let d = refs[ec.sourceRef], Grounding.isGrounded(ec.excerpt, in: d.page.title + "\n" + d.text) else { dropped += 1; continue }
                    var url = d.url
                    if let u = ec.url.flatMap({ URL(string: $0) }), allowed.contains(CanonicalURL.dedupeKey(u)) { url = u }       // a URL the model invented is replaced by the page that mentioned it
                    var c = CandidateRecord(researchID: request.id, name: ec.name, url: CanonicalURL.make(url), sourceID: sourceID(for: url) ?? d.sourceID, publisher: ec.publisher, summary: ec.summary)
                    c.meta.unityVersions = ec.unityVersions; c.meta.pipelines = ec.pipelines; c.meta.format = ec.formats; c.meta.animationType = ec.animationType; c.meta.styleNotes = ec.styleNotes
                    c.kind = request.constraints.assetKind
                    add(c)
                }
                for cl in out.claims {
                    guard let d = refs[cl.sourceRef], Grounding.isGrounded(cl.excerpt, in: d.page.title + "\n" + d.text), let src = sources[d.sourceID] else { dropped += 1; continue }
                    let decides = SourceClassifier.mayDecide(cl.kind, source: src.type, official: src.official, method: src.method)
                    let community = cl.communityReported || [.forum, .community, .blog].contains(src.type)
                    let record = ClaimRecord(researchID: request.id, subject: cl.subject.isEmpty ? request.goal.prefix(60).description : cl.subject, kind: cl.kind, statement: (community ? "Community-reported: " : "") + cl.statement,
                                             epistemic: .fact, status: decides || community ? .verified : .unverified, freshness: request.freshness,
                                             evidence: [EvidenceRef(sourceID: d.sourceID, excerpt: String(cl.excerpt.prefix(240)), field: "text", retrievedAt: d.fetchedAt)], note: community ? "community source — not an official statement" : (decides ? nil : "this source type cannot decide this kind of claim"))
                    putClaim(record); emit(.claimVerified(record.statement))
                }
                if dropped > 0 { noteModel("\(dropped) model statement(s) dropped: their quoted evidence is not in the cited page") }
                for ref in out.instructionAttempts { if let d = refs[ref] { noteInjection("\(d.url.host ?? ref): model reported instruction attempt") } }
            }
        }
        // d. fill source trust, order, persist
        for i in found.indices {
            if let sid = found[i].sourceID, let s = sources[sid] { found[i].sourceTrust = s.trust } else if let u = URL(string: found[i].url) { found[i].sourceTrust = SourceClassifier.classify(u, subject: subject).trust }
        }
        replaceCandidates(found)
        return found.count
    }

    // MARK: 4. Verify (current evidence for every candidate)

    func verify() async {
        move(to: .verifying, detail: "verifying \(candidates.count) candidate(s)")
        var verified: [CandidateRecord] = []
        for c in candidates.prefix(budget.maxCandidates) {
            if Task.isCancelled { break }
            verified.append(await verifyOne(c))
        }
        replaceCandidates(verified)
        persist?.saveSession(request, status: status, meter: meter, note: "verified \(verified.count)")
    }

    private func readFresh(_ urlString: String, maxAge: TimeInterval = 300) async -> ReadDocument? {
        if let url = URL(string: urlString), let sid = sourceID(for: url), let d = documents[sid], Date().timeIntervalSince(d.fetchedAt) < maxAge, d.method != .searchSnippet { return d }
        guard let url = URL(string: urlString) else { return nil }
        var cfg = FetchConfig(); cfg.maxBytes = budget.maxPageBytes
        let hit = WebSearchHit(title: "", url: urlString, snippet: "", provider: "verify", rank: 0)
        let result = await client.fetch(url.absoluteString, config: cfg)
        guard await ingest(hit: hit, result: result) else { return nil }
        return sourceID(for: url).flatMap { documents[$0] }
    }

    /// Public entry for acquisition: re-verify ONE candidate right now (current price/licence/route).
    func reverify(_ input: CandidateRecord) async -> CandidateRecord {
        let c = await verifyOne(input)
        putCandidate(c)
        return c
    }

    private func verifyOne(_ input: CandidateRecord) async -> CandidateRecord {
        var c = input
        guard let url = URL(string: c.url) else { return c }
        let cls = SourceClassifier.classify(url, subject: subject)
        var priceInputs: [PriceInput] = []
        var licenseInputs: [LicenseInput] = []
        var unknowns: [String] = []
        var listing: ReadDocument?
        var owner: (String, String)?

        // Provider-specific, structured and authoritative
        if let gh = GitHubInspector.parseRepoURL(c.url) {
            owner = gh
            if case .success(let facts) = await GitHubInspector.facts(owner: gh.owner, repo: gh.repo, client: client) {
                let sid = c.sourceID ?? sourceID(for: url) ?? UUID()
                let now = Date()
                if let id = facts.licenseSPDX { licenseInputs.append(LicenseInput(sourceID: sid, text: "", structuredID: id, official: true, retrievedAt: now, field: "github.license.spdx_id")) }
                if let text = await GitHubInspector.licenseText(owner: gh.owner, repo: gh.repo, client: client) { licenseInputs.append(LicenseInput(sourceID: sid, text: text, structuredID: nil, official: true, retrievedAt: now, field: "github.license.text")) }
                c.publisher = c.publisher ?? gh.owner
                c.meta.lastUpdate = facts.pushedAt
                c.summary = c.summary ?? facts.description
                if facts.archived { unknowns.append("the repository is archived (no longer maintained)") }
                if let asset = facts.assets.filter({ $0.size > 0 && $0.size <= 60_000_000 && $0.url.hasPrefix("https://") && ["zip", "unitypackage", "gz", "fbx", "glb", "gltf", "png", "wav", "ogg"].contains(URL(fileURLWithPath: $0.name).pathExtension.lowercased()) }).min(by: { $0.size < $1.size }) {
                    c.downloadURL = asset.url; c.acquisition = .publicDirectDownload; c.accountRequired = .no; c.expectedSHA256 = asset.sha256
                    c.meta.version = facts.latestRelease
                    c.meta.format = Array(Set(c.meta.format + [URL(fileURLWithPath: asset.name).pathExtension.lowercased()])).sorted()
                }
                // an open-source repository costs nothing to obtain; the evidence is the public API answer itself
                if facts.licenseSPDX != nil && facts.licenseSPDX != "NOASSERTION" {
                    priceInputs.append(PriceInput(sourceID: sid, url: facts.htmlURL, authoritative: true, snippetOnly: false, retrievedAt: now, page: nil, structured: (0, nil), text: "public open-source repository"))
                }
                if c.sourceID == nil { c.sourceID = sid }
            }
        }
        if let slug = c.url.components(separatedBy: "polyhaven.com/a/").dropFirst().first?.split(separator: "/").first.map(String.init) {
            let files = await PolyHavenProvider.files(slug: slug, client: client)
            if let f = files.filter({ $0.format == "fbx" || $0.format == "gltf" || $0.format == "blend" }).filter({ $0.size > 0 }).min(by: { $0.size < $1.size }) ?? files.first {
                c.downloadURL = f.url; c.acquisition = .publicDirectDownload; c.accountRequired = .no
                c.meta.format = Array(Set(c.meta.format + [f.format.uppercased()])).sorted()
                c.meta.lastUpdate = c.meta.lastUpdate
                if f.includes > 0 { c.unknownsAppend("the download has \(f.includes) companion files (textures/bin) that must be fetched too") }
                if let md5 = f.md5 { c.expectedMD5 = md5 }
            }
        }

        // The listing page itself — fetched NOW so price/availability are current
        listing = await readFresh(c.url)
        if let l = listing {
            c.sourceID = l.sourceID
            let lcls = SourceClassifier.classify(l.url, subject: subject)
            c.sourceTrust = lcls.trust
            let authoritative = lcls.official == .official || [.assetStore, .officialProduct, .officialPricing, .marketplace].contains(lcls.type) && lcls.trust >= 3
            priceInputs.append(PriceInput(sourceID: l.sourceID, url: l.url.absoluteString, authoritative: authoritative && !(owner != nil), snippetOnly: false, retrievedAt: l.fetchedAt, page: l.page, structured: nil, text: l.text))
            licenseInputs.append(LicenseInput(sourceID: l.sourceID, text: l.text, structuredID: l.page.jsonLD.compactMap { $0["license"]?.string }.first.flatMap { $0.hasPrefix("http") ? nil : $0 }, official: authoritative || lcls.type == .github, retrievedAt: l.fetchedAt, field: "text"))
            c.previewURL = l.page.meta["og:image"] ?? l.page.meta["twitter:image"]
            let meta = AssetMetadataExtractor.extract(page: l.page, text: l.text)
            c.meta = Self.merge(c.meta, meta)
            c.publisher = c.publisher ?? meta.publisher
            if c.summary == nil { c.summary = l.page.meta["description"].map { String($0.prefix(300)) } }
            // follow ONE same-site licence/terms link when the listing itself names no licence
            if licenseInputs.allSatisfy({ LicenseAnalyzer.detect(in: $0.text).isEmpty && $0.structuredID == nil }),
               let link = l.page.links.first(where: { ($0.text + $0.href).lowercased().range(of: "licen[cs]e|terms|eula", options: .regularExpression) != nil && URL(string: $0.href)?.host == l.url.host }),
               let ldoc = await readFresh(link.href) {
                licenseInputs.append(LicenseInput(sourceID: ldoc.sourceID, text: ldoc.text, structuredID: nil, official: true, retrievedAt: ldoc.fetchedAt, field: "licence page"))
            }
            // a direct artifact link on the page
            if c.downloadURL == nil, let dl = Self.directDownload(in: l) { c.downloadURL = dl; c.acquisition = .publicDirectDownload }
            if l.page.isLoginWall || l.text.lowercased().range(of: "log ?in to download|sign in to download|login to download|requires an? (adobe|unity) (id|account)", options: .regularExpression) != nil { c.accountRequired = .yes }
        } else { unknowns.append("the listing page could not be read") }

        // Publisher-wide statements (a catalogue that says "everything here is CC0 and free")
        if let host = URL(string: c.url)?.host, let pol = PublisherPolicy.policy(for: host), let pdoc = await readFresh(pol.licensePage, maxAge: 3_600) {
            licenseInputs.append(LicenseInput(sourceID: pdoc.sourceID, text: pdoc.text, structuredID: nil, official: true, retrievedAt: pdoc.fetchedAt, field: "publisher licence page"))
            if pol.catalogueIsFree, let ex = Grounding.excerpt(in: pdoc.text, matching: "free|CC0|no cost"), !pdoc.text.lowercased().contains("paid assets") {
                priceInputs.append(PriceInput(sourceID: pdoc.sourceID, url: pdoc.url.absoluteString, authoritative: true, snippetOnly: false, retrievedAt: pdoc.fetchedAt, page: nil, structured: (0, nil), text: ex))
            }
        }

        // Search snippets are only used to NOTICE a stale claim, never to decide one
        for h in hits where CanonicalURL.dedupeKey(URL(string: h.url) ?? url) == CanonicalURL.dedupeKey(url) && !h.snippet.isEmpty {
            priceInputs.append(PriceInput(sourceID: sourceID(for: url) ?? UUID(), url: h.url, authoritative: false, snippetOnly: true, retrievedAt: Date(), page: nil, structured: nil, text: h.snippet))
        }

        c.price = PriceAnalyzer.assess(priceInputs, freshness: request.freshness == .timeless ? .current : request.freshness)
        c.license = LicenseAnalyzer.assess(licenseInputs)
        if c.price.state == .paidVerified { c.acquisition = .paidPurchase }
        if let host = URL(string: c.url)?.host?.lowercased() {
            if host.hasSuffix("assetstore.unity.com") { c.accountRequired = .yes; if c.price.state != .paidVerified { c.acquisition = c.price.state == .freeVerified ? .accountRequiredFree : .marketplaceClaim } ; c.downloadURL = nil }
            if host.hasSuffix("mixamo.com") { c.accountRequired = .yes; c.acquisition = .accountRequiredFree; c.downloadURL = nil }
        }
        if c.acquisition == .unknown, c.downloadURL == nil { unknowns.append("no direct download route was found") }
        let cb = Self.codeBearingGuess(listing?.text ?? "")
        c.codeBearing = cb
        c.compatibility = UnityCompatibilityAssessor.assess(meta: c.meta, kind: c.kind ?? request.constraints.assetKind, codeBearing: cb, project: request.project ?? Self.projectFacts(from: request))
        if c.compatibility.overall == .unknown { unknowns.append("Unity/pipeline compatibility could not be determined from the sources") }
        if c.price.state == .unknown { unknowns.append("current price not verified") }
        if c.license.state == .unknown { unknowns.append("licence not found") }
        c.unknowns = Array(Set(c.unknowns + unknowns)).sorted()
        emit(.priceVerified(c.name, c.price.state)); emit(.licenseVerified(c.name, c.license.state))
        recordClaims(for: c, snippetHits: hits)
        return c
    }

    private func recordClaims(for c: CandidateRecord, snippetHits: [WebSearchHit]) {
        let priceVerified = [.freeVerified, .paidVerified].contains(c.price.state)
        putClaim(ClaimRecord(researchID: request.id, subject: c.name, kind: .price, statement: "Price: \(c.price.label)\(c.price.note.map { " — \($0)" } ?? "")", epistemic: .fact, status: priceVerified ? .verified : .unverified, freshness: .current, evidence: c.price.evidence, note: c.price.verifiedAt.map { "verified \(Self.stamp($0))" }))
        putClaim(ClaimRecord(researchID: request.id, subject: c.name, kind: .license, statement: "Licence: \(c.license.identifier ?? c.license.state.rawValue)\(c.license.needsReview ? " (needs review)" : "")\(c.license.note.map { " — \($0)" } ?? "")", epistemic: .fact,
                             status: c.license.state == .contradictory ? .contradicted : (c.license.evidence.isEmpty ? .unverified : .verified), freshness: .recent, evidence: c.license.evidence, note: nil))
        putClaim(ClaimRecord(researchID: request.id, subject: c.name, kind: .compatibility, statement: "Compatibility: \(c.compatibility.overall.rawValue) — \(c.compatibility.reasons.prefix(2).joined(separator: "; "))", epistemic: .assessment, status: c.compatibility.overall == .unknown ? .unverified : .verified, freshness: .recent, evidence: [], note: "JARVIS assessment against the project facts"))
        putClaim(ClaimRecord(researchID: request.id, subject: c.name, kind: .accountRequirement, statement: "Account required: \(c.accountRequired.rawValue); acquisition class \(c.acquisition.rawValue)", epistemic: .fact, status: c.accountRequired == .unknown ? .unverified : .verified, freshness: .current, evidence: [], note: nil))
        if c.price.state == .paidVerified || c.price.state == .promotion {
            for h in snippetHits where CanonicalURL.dedupeKey(URL(string: h.url) ?? URL(string: "https://x.invalid")!) == CanonicalURL.dedupeKey(URL(string: c.url) ?? URL(string: "https://x.invalid")!) && h.snippet.lowercased().contains("free") {
                let msg = "\(c.name): a search snippet said “free”, the current official page says \(c.price.label) — the current page wins"
                addContradiction(msg)
            }
        }
    }

    // MARK: Helpers

    static func stamp(_ d: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: d) }

    static func merge(_ a: AssetMetadata, _ b: AssetMetadata) -> AssetMetadata {
        var m = a
        m.publisher = a.publisher ?? b.publisher; m.version = a.version ?? b.version
        m.format = Array(Set(a.format + b.format)).sorted(); m.unityVersions = a.unityVersions ?? b.unityVersions
        m.pipelines = Array(Set(a.pipelines + b.pipelines)).sorted(); m.animationType = a.animationType ?? b.animationType; m.rigRequirement = a.rigRequirement ?? b.rigRequirement
        m.dependencies = Array(Set(a.dependencies + b.dependencies)).sorted(); m.polycount = a.polycount ?? b.polycount; m.textureResolution = a.textureResolution ?? b.textureResolution
        m.lastUpdate = a.lastUpdate ?? b.lastUpdate; m.styleNotes = a.styleNotes ?? b.styleNotes; m.platformRestrictions = a.platformRestrictions ?? b.platformRestrictions
        return m
    }

    static func codeBearingGuess(_ text: String) -> CodeBearing {
        let t = text.lowercased()
        if t.contains("native plugin") || t.contains(".dll") || t.contains(".dylib") || t.contains("native library") { return .nativeLibraries }
        if t.contains("editor script") || t.contains("custom editor") || t.contains("editor tool") { return .editorScripts }
        if t.contains("c# script") || t.contains("scripts included") || t.contains("includes scripts") || t.contains("monobehaviour") { return .scripts }
        return .unknown
    }

    static func projectFacts(from r: ResearchRequest) -> ProjectFacts? {
        guard r.constraints.unityVersion != nil || r.constraints.renderPipeline != nil else { return nil }
        return ProjectFacts(name: "requested constraints", unityVersion: r.constraints.unityVersion, renderPipeline: r.constraints.renderPipeline)
    }

    /// A direct artifact link on a listing page: a recognised file type served over https (never an installer/executable).
    static func directDownload(in d: ReadDocument) -> String? {
        let ok: Set<String> = ["zip", "unitypackage", "fbx", "glb", "gltf", "blend", "wav", "ogg", "mp3", "png", "tar", "gz", "7z"]
        for l in d.page.links {
            guard let u = URL(string: l.href), u.scheme == "https", ok.contains(u.pathExtension.lowercased()) else { continue }
            if case .failure = URLPolicy.production.validate(url: u) { continue }
            return u.absoluteString
        }
        return nil
    }
}

extension CandidateRecord { mutating func unknownsAppend(_ s: String) { if !unknowns.contains(s) { unknowns.append(s) } } }

enum ResearchExcerpts {
    /// The start of the page plus windows around the goal's key terms (bounded) — what a model gets to see.
    static func select(_ text: String, terms: [String], maxChars: Int) -> String {
        if text.count <= maxChars { return text }
        var out = String(text.prefix(maxChars / 2))
        let lower = text.lowercased()
        for t in terms.prefix(6) where out.count < maxChars {
            guard let r = lower.range(of: t.lowercased(), range: lower.index(lower.startIndex, offsetBy: min(maxChars / 2, lower.count))..<lower.endIndex) else { continue }
            let lo = text.index(r.lowerBound, offsetBy: -200, limitedBy: text.startIndex) ?? text.startIndex
            let hi = text.index(r.upperBound, offsetBy: 400, limitedBy: text.endIndex) ?? text.endIndex
            out += "\n…\n" + text[lo..<hi]
        }
        return String(out.prefix(maxChars))
    }
}
