import Foundation

/// DEVELOPER / CAPTURE ONLY (Services/Demo): synthetic research rows so the Research screen can be inspected without the network. Every title says DEMO.
/// Production code never references this file.
enum ResearchDemo {
    @discardableResult
    static func seed(_ repo: JarvisRepository, artifacts: ArtifactStore?) -> UUID {
        let id = UUID()
        var req = ResearchRequest(id: id, goal: "DEMO · find a free stylized throwing animation for the Turkish bath game", type: .assetDiscovery, constraints: ResearchConstraints(), freshness: .current)
        req.constraints.freeOnly = true; req.constraints.commercialUse = true; req.constraints.assetKind = .animation; req.constraints.unityVersion = "6000.0"; req.constraints.renderPipeline = "URP"
        var meter = BudgetMeter(); meter.queries = 5; meter.sources = 7
        try? repo.upsertResearchSession(req, status: .completed, meter: meter, note: "demo data")
        func src(_ title: String, _ domain: String, _ type: SourceType, _ off: OfficialStatus, _ trust: Int, _ method: RetrievalMethod = .http, note: String? = nil, flags: [String] = []) -> SourceRecord {
            SourceRecord(id: UUID(), researchID: id, url: "https://\(domain)/demo", finalURL: nil, domain: domain, title: title, type: type, official: off, retrievedAt: Date().addingTimeInterval(-90), publishedAt: nil, author: nil,
                         contentHash: String(repeating: "ab", count: 32), license: nil, method: method, authRequired: false, dynamic: false, httpStatus: 200, trust: trust, excerpt: "demo excerpt", note: note, injectionFlags: flags)
        }
        let s1 = src("Free Throw Pack — publisher page (demo)", "demo-publisher.example", .officialProduct, .official, 5)
        let s2 = src("Demo Store listing — Paid Throw Pack", "demo-store.example", .assetStore, .official, 4)
        let s3 = src("Forum thread about throwing animations (demo)", "demo-forum.example", .forum, .community, 2)
        let s4 = src("Totally normal page (demo)", "demo-blog.example", .blog, .unknown, 1, note: "contains instructions aimed at an AI assistant — ignored", flags: ["ignore-previous-instructions", "shell-command"])
        let s5 = src("Search result only (demo)", "demo-seo.example", .searchResult, .unknown, 1, .searchSnippet, note: "search result — discovery only, not evidence")
        for s in [s1, s2, s3, s4, s5] { try? repo.upsert(s) }
        try? repo.insert(QueryRecord(researchID: id, text: "slipper throwing animation free cc0 unity", provider: "duckduckgo-html", resultCount: 8))
        try? repo.insert(QueryRecord(researchID: id, text: "slipper throwing animation", provider: "polyhaven", resultCount: 0, failure: "no results"))
        func ev(_ s: SourceRecord, _ text: String, _ field: String) -> EvidenceRef { EvidenceRef(sourceID: s.id, excerpt: text, field: field, retrievedAt: s.retrievedAt) }
        var a = CandidateRecord(researchID: id, name: "Free Throw Pack (demo)", url: s1.url); a.sourceID = s1.id; a.publisher = "Demo Publisher"; a.kind = .animation; a.sourceTrust = 5
        a.price = PriceAssessment(state: .freeVerified, amount: 0, currency: "USD", evidence: [ev(s1, "price 0 USD", "jsonld.offers.price")], verifiedAt: Date().addingTimeInterval(-90), note: nil)
        a.license = LicenseAssessment(state: .permissive, identifier: "CC0-1.0", commercialUse: .yes, modification: .yes, redistribution: .yes, attribution: .no, evidence: [ev(s1, "Creative Commons Zero", "text")], needsReview: false, note: nil)
        a.meta.unityVersions = "2021.3 or newer"; a.meta.pipelines = ["URP", "Built-in"]; a.meta.format = ["FBX"]; a.meta.animationType = "Humanoid"
        a.compatibility = CompatibilityAssessment(overall: .compatible, unityVersion: .compatible, renderPipeline: .compatible, reasons: ["listing states Unity 2021.3 or newer; project uses 6000.0", "listing states URP support"])
        a.acquisition = .publicDirectDownload; a.accountRequired = .no; a.downloadURL = "https://demo-publisher.example/files/throw.zip"; a.styleFit = "high — neutral humanoid motion"; a.styleModel = "demo"
        var b = CandidateRecord(researchID: id, name: "Paid Throw Pack (demo)", url: s2.url); b.sourceID = s2.id; b.sourceTrust = 4; b.kind = .animation
        b.price = PriceAssessment(state: .paidVerified, amount: 14.99, currency: "USD", evidence: [ev(s2, "$14.99", "jsonld.offers.price")], verifiedAt: Date(), note: nil)
        b.license = LicenseAssessment(state: .marketplaceEULA, identifier: "UNITY-ASSET-STORE-EULA", commercialUse: .yes, modification: .yes, redistribution: .no, attribution: .no, evidence: [], needsReview: true, note: nil)
        b.compatibility = .unknown; b.acquisition = .paidPurchase; b.accountRequired = .yes; b.unknowns = ["Unity/pipeline compatibility could not be determined from the sources"]
        var c = CandidateRecord(researchID: id, name: "Mystery Pack (demo)", url: s3.url); c.sourceID = s3.id; c.sourceTrust = 2; c.kind = .animation
        c.price = .unknown; c.license = .unknown; c.compatibility = .unknown; c.unknowns = ["current price not verified", "licence not found"]
        for x in CandidateRanker.rank([a, b, c], request: req) { try? repo.upsert(x) }
        try? repo.insert(ClaimRecord(researchID: id, subject: a.name, kind: .price, statement: "Price: FREE_VERIFIED", epistemic: .fact, status: .verified, freshness: .current, evidence: a.price.evidence, note: nil))
        try? repo.insert(ClaimRecord(researchID: id, subject: a.name, kind: .license, statement: "Licence: CC0-1.0", epistemic: .fact, status: .verified, freshness: .recent, evidence: a.license.evidence, note: nil))
        try? repo.insert(ClaimRecord(researchID: id, subject: b.name, kind: .price, statement: "Price: PAID_VERIFIED (14.99 USD)", epistemic: .fact, status: .verified, freshness: .current, evidence: b.price.evidence, note: nil))
        try? repo.insert(ClaimRecord(researchID: id, subject: "throwing", kind: .workaround, statement: "Community-reported: retarget the clip to the Humanoid avatar first.", epistemic: .fact, status: .verified, freshness: .recent, evidence: [ev(s3, "retarget the clip to the Humanoid avatar", "text")], note: "community source — not an official statement"))
        try? repo.insert(ClaimRecord(researchID: id, subject: a.name, kind: .compatibility, statement: "Compatibility: COMPATIBLE — listing states URP support", epistemic: .assessment, status: .verified, freshness: .recent, evidence: [], note: "JARVIS assessment against the project facts"))
        var rec = AcquisitionRecord(id: UUID(), researchID: id, candidateID: a.id, taskID: nil, state: .readyForImport, acquisitionClass: .publicDirectDownload, name: a.name, sourceURL: s1.url, downloadURL: a.downloadURL, finalHost: "demo-publisher.example",
                                    originalFilename: "throw.zip", publisher: "Demo Publisher", assetVersion: nil, licenseID: "CC0-1.0", licenseSourceURL: s1.url, priceState: .freeVerified, priceVerifiedAt: Date(), sha256: String(repeating: "9f", count: 32),
                                    hashMatchesPublished: .unknown, size: 4_812_345, detectedType: "zip", declaredMIME: "application/zip", quarantinePath: nil, trust: .validatedForImport, inspection: ArtifactInspection(kind: "zip", entryCount: 12, uncompressedBytes: 9_100_000, maxCompressionRatio: 4, hasScripts: false, hasEditorScripts: false, hasNativeLibraries: false, hasExecutables: false, findings: [], rejectedReason: nil, sampleEntries: ["Throw/throw_a.fbx"], codeBearing: .none))
        rec.downloadedAt = Date()
        try? repo.upsert(rec)
        let report = ResearchReport(researchID: id, goal: req.goal, type: .assetDiscovery, constraints: req.constraints.summary, generatedAt: Date(), durationSeconds: 94, status: .completed, queries: [], sourceCount: 4, facts: [], assessments: [], candidates: [], contradictions: ["Paid Throw Pack (demo): a search snippet said “free”, the current official page says PAID_VERIFIED — the current page wins"],
                                     uncertainties: [], injectionNotes: ["demo-blog.example: ignore-previous-instructions, shell-command"], recommendation: "Preferred: Free Throw Pack (demo) — highest score among candidates that meet every constraint. Price FREE_VERIFIED, licence CC0-1.0, compatibility COMPATIBLE. Alternatives: none.",
                                     acquisitionNote: "Public direct download without an account.", nextSafeAction: "Download “Free Throw Pack (demo)” into the quarantine and inspect it (you decide), then — only if you ask — import it into a disposable project first.")
        let md = ResearchReportBuilder.markdown(report, sources: [s1, s2, s3, s4, s5])
        if let artifacts, let m = try? artifacts.store(Data(md.utf8), type: "research-report", folder: .reports, fileExtension: "md", taskID: nil, meta: "demo report") { try? repo.setResearchReport(id, json: nil, markdown: m.id) }
        return id
    }
}
