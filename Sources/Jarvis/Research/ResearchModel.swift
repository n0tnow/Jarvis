import Foundation

// MARK: - Authority levels (V0.9 — DEC-088)

/// The five authority levels the brief keeps apart. A research task has the first one only; every higher level needs its own typed tool,
/// its own task capability and — from `accountAction` on — an explicit user decision that V0.9 does not even implement as an automatic path.
enum AuthorityLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case research            // search, fetch public pages, read metadata/licences, compare, recommend
    case acquisition         // download a public artifact into the quarantine
    case projectImport       // copy a quarantined, inspected artifact into a project (a normal V0.4 task, approval-gated)
    case accountAction       // sign in, accept terms, "add to my assets", OAuth — never automatic, not implemented
    case commercial          // purchase, subscription, paid trial, paid API — never automatic, not implemented

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    static func < (a: AuthorityLevel, b: AuthorityLevel) -> Bool { a.rank < b.rank }

    /// What the product DOES in V0.9: the two highest levels have no code path at all.
    var isImplemented: Bool { self <= .projectImport }
}

enum Tri: String, Codable, Sendable { case yes, no, unknown }

// MARK: - Request

enum ResearchType: String, Codable, Sendable, CaseIterable {
    case documentation       // "find the official documentation for X"
    case troubleshooting     // "research this error"
    case comparison          // "compare these libraries"
    case library             // "find an open-source package for X"
    case community           // "find people who had this problem"
    case currentInfo         // "what is current about Y"
    case assetDiscovery      // "find a free animation / prop / sound for X"
    case general

    var label: String {
        switch self {
        case .documentation: "Documentation"; case .troubleshooting: "Troubleshooting"; case .comparison: "Comparison"; case .library: "Library search"
        case .community: "Community experience"; case .currentInfo: "Current information"; case .assetDiscovery: "Asset discovery"; case .general: "General research"
        }
    }
}

enum Freshness: String, Codable, Sendable {
    case timeless, recent, current

    /// How old a retrieved fact may be before it must be re-verified (price/availability are always `current`).
    var maxAge: TimeInterval { switch self { case .timeless: .infinity; case .recent: 30 * 86_400; case .current: 24 * 3_600 } }
}

enum AssetKind: String, Codable, Sendable, CaseIterable {
    case animation, model3D = "model", texture, audio, music, shader, tool, library, font, ui, any
    var label: String { rawValue }
}

/// The constraints a research request can carry (typed; the free-text goal is never parsed again downstream).
struct ResearchConstraints: Codable, Equatable, Sendable {
    var freeOnly = false
    var commercialUse = false
    var officialOnly = false
    var openSourceOnly = false
    var noAccount = false
    var recentOnly = false
    var unityVersion: String?
    var renderPipeline: String?
    var assetKind: AssetKind?
    var languages: [String] = []
    var preferredDomains: [String] = []

    var summary: [String] {
        var s: [String] = []
        if freeOnly { s.append("free only") }
        if commercialUse { s.append("commercial use must be allowed") }
        if officialOnly { s.append("official sources only") }
        if openSourceOnly { s.append("open source only") }
        if noAccount { s.append("no account / login") }
        if recentOnly { s.append("recent information") }
        if let v = unityVersion { s.append("Unity \(v)") }
        if let p = renderPipeline { s.append(p) }
        if let a = assetKind, a != .any { s.append("asset: \(a.label)") }
        if !preferredDomains.isEmpty { s.append("prefer: " + preferredDomains.joined(separator: ", ")) }
        return s
    }
}

struct ResearchRequest: Codable, Equatable, Sendable, Identifiable {
    var id: UUID                          // = the task id
    var goal: String
    var type: ResearchType
    var constraints: ResearchConstraints
    var freshness: Freshness
    var deep = false                      // the user asked for a deeper search → larger (still bounded) budgets
    var createdAt = Date()
    /// Unity-game facts when the research targets the connected project (read-only inspection, V0.6). Nil otherwise.
    var project: ProjectFacts?
}

/// Facts about the target project that compatibility is judged against — only what the deterministic V0.6 descriptor knows.
struct ProjectFacts: Codable, Equatable, Sendable {
    var name: String
    var unityVersion: String?
    var renderPipeline: String?           // "URP" | "HDRP" | "Built-in" | nil when unknown
    var hasTestFramework = false
}

// MARK: - Budgets (no unbounded browsing, ever)

struct ResearchBudget: Codable, Equatable, Sendable {
    var maxQueries = 6
    var resultsPerQuery = 8
    var maxSources = 12                   // pages fetched and read
    var maxPageBytes = 1_500_000
    var maxTotalBytes = 14_000_000
    var maxRendered = 4                   // browser (rendered-page) navigations
    var maxCandidates = 8
    var maxSeconds: TimeInterval = 300
    var maxProviderCalls = 3              // model calls for extraction/assessment (the plan itself is deterministic)
    var maxRetries = 1
    var perHostMinInterval: TimeInterval = 1.0
    var maxConcurrentFetches = 3

    static let standard = ResearchBudget()
    /// "Research this more deeply": roughly 2.5× — still a fixed ceiling.
    static let deep: ResearchBudget = {
        var b = ResearchBudget()
        b.maxQueries = 12; b.maxSources = 28; b.maxCandidates = 14; b.maxSeconds = 600; b.maxProviderCalls = 5; b.maxTotalBytes = 30_000_000; b.maxRendered = 8
        return b
    }()
    static func `for`(_ r: ResearchRequest) -> ResearchBudget { r.deep ? .deep : .standard }
}

/// Consumption counters checked before every costly action. `exhausted` names the first limit that was hit.
struct BudgetMeter: Codable, Equatable, Sendable {
    var queries = 0, sources = 0, rendered = 0, providerCalls = 0, bytes = 0, retries = 0
    var started = Date()

    func exhausted(_ b: ResearchBudget, now: Date = Date()) -> String? {
        if now.timeIntervalSince(started) > b.maxSeconds { return "time (\(Int(b.maxSeconds)) s)" }
        if queries >= b.maxQueries { return "queries (\(b.maxQueries))" }
        if bytes >= b.maxTotalBytes { return "downloaded bytes" }
        return nil
    }
    func canRead(_ b: ResearchBudget) -> Bool { sources < b.maxSources && bytes < b.maxTotalBytes }
    func canRender(_ b: ResearchBudget) -> Bool { rendered < b.maxRendered }
    func canCallProvider(_ b: ResearchBudget) -> Bool { providerCalls < b.maxProviderCalls }
}

// MARK: - State machines

enum ResearchStatus: String, Codable, Sendable {
    case planning, searching, reading, verifying, comparing, reporting, completed, failed, cancelled, interrupted

    var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
    var label: String {
        switch self {
        case .planning: "Planning"; case .searching: "Searching"; case .reading: "Reading"; case .verifying: "Verifying"; case .comparing: "Comparing"
        case .reporting: "Reporting"; case .completed: "Report ready"; case .failed: "Failed"; case .cancelled: "Stopped"; case .interrupted: "Interrupted"
        }
    }
    var allowedNext: Set<ResearchStatus> {
        switch self {
        case .planning: [.searching, .reading, .failed, .cancelled, .interrupted]
        case .searching: [.reading, .verifying, .reporting, .failed, .cancelled, .interrupted]
        case .reading: [.reading, .verifying, .comparing, .reporting, .searching, .failed, .cancelled, .interrupted]
        case .verifying: [.comparing, .reporting, .reading, .failed, .cancelled, .interrupted]
        case .comparing: [.reporting, .verifying, .failed, .cancelled, .interrupted]
        case .reporting: [.completed, .failed, .cancelled, .interrupted]
        case .interrupted: [.planning, .searching, .reading, .failed, .cancelled]
        case .completed, .failed, .cancelled: []
        }
    }
}

// MARK: - Sources

enum SourceType: String, Codable, Sendable, CaseIterable {
    case officialDocs = "OFFICIAL_DOCS", officialProduct = "OFFICIAL_PRODUCT", officialRepository = "OFFICIAL_REPOSITORY"
    case officialLicense = "OFFICIAL_LICENSE", officialPricing = "OFFICIAL_PRICING", packageRegistry = "PACKAGE_REGISTRY"
    case assetStore = "ASSET_STORE", marketplace = "MARKETPLACE", github = "GITHUB", forum = "FORUM", community = "COMMUNITY"
    case blog = "BLOG", article = "ARTICLE", searchResult = "SEARCH_RESULT", unknown = "UNKNOWN"

    var isOfficial: Bool { [.officialDocs, .officialProduct, .officialRepository, .officialLicense, .officialPricing].contains(self) }
    var label: String { rawValue.replacingOccurrences(of: "_", with: " ").lowercased() }
}

enum OfficialStatus: String, Codable, Sendable { case official, community, unknown }

enum RetrievalMethod: String, Codable, Sendable { case http, api, renderedBrowser, searchSnippet, fixture }

/// A page/API response JARVIS actually looked at (or, for `searchSnippet`, only saw listed). Nothing here is invented: unknown stays nil.
struct SourceRecord: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var researchID: UUID
    var url: String                       // canonical (tracking removed, fragment dropped)
    var finalURL: String?                 // after redirects (sanitized)
    var domain: String
    var title: String
    var type: SourceType
    var official: OfficialStatus
    var retrievedAt: Date
    var publishedAt: Date?
    var author: String?
    var contentHash: String?
    var license: String?
    var method: RetrievalMethod
    var authRequired: Bool
    var dynamic: Bool
    var httpStatus: Int?
    var trust: Int                        // 0 (unknown) … 5 (maintainer/official primary)
    var excerpt: String                   // bounded, sanitized, paraphrase-free first lines — NOT the page
    var note: String?                     // e.g. "login wall", "contains instructions aimed at AI — ignored"
    var injectionFlags: [String] = []
}

struct QueryRecord: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var researchID: UUID
    var text: String
    var provider: String
    var resultCount: Int
    var at = Date()
    var failure: String?
}

// MARK: - Claims and evidence

/// FACT = something a source states or a structured field says; ASSESSMENT = JARVIS' (or a model's) judgement; RECOMMENDATION = what to do.
enum Epistemic: String, Codable, Sendable { case fact, assessment, recommendation }

enum ClaimKind: String, Codable, Sendable {
    case price, license, compatibility, availability, accountRequirement, downloadMethod, apiBehavior, deprecation, workaround, maintenance, style, other
}

enum VerificationStatus: String, Codable, Sendable { case verified, unverified, contradicted, stale }

struct EvidenceRef: Codable, Equatable, Sendable {
    var sourceID: UUID
    var excerpt: String                   // ≤ 240 chars, must be a (normalised) substring of what the source said
    var field: String?                    // "jsonld.offers.price", "github.license.spdx_id", "text"
    var retrievedAt: Date
}

struct ClaimRecord: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var researchID: UUID
    var subject: String                   // candidate name or topic
    var kind: ClaimKind
    var statement: String
    var epistemic: Epistemic
    var status: VerificationStatus
    var freshness: Freshness
    var evidence: [EvidenceRef]
    var note: String?                     // e.g. the contradiction
}

// MARK: - Price / licence / compatibility states (never collapse UNKNOWN into good news)

enum PriceState: String, Codable, Sendable {
    case freeVerified = "FREE_VERIFIED", paidVerified = "PAID_VERIFIED", unknown = "UNKNOWN", requiresLoginToVerify = "REQUIRES_LOGIN_TO_VERIFY"
    case unavailable = "UNAVAILABLE", regionDependent = "REGION_DEPENDENT", subscriptionIncluded = "SUBSCRIPTION_INCLUDED", promotion = "PROMOTION", other = "OTHER"

    /// Only a verified zero price may ever be called free. Everything else — including a promotion — is NOT.
    var isFree: Bool { self == .freeVerified }
}

struct PriceAssessment: Codable, Equatable, Sendable {
    var state: PriceState
    var amount: Double?
    var currency: String?
    var evidence: [EvidenceRef]
    var verifiedAt: Date?
    var note: String?

    static let unknown = PriceAssessment(state: .unknown, amount: nil, currency: nil, evidence: [], verifiedAt: nil, note: "no current price evidence")
    var label: String {
        switch state {
        case .freeVerified: return "FREE_VERIFIED"
        case .paidVerified: return "PAID_VERIFIED" + (amount.map { String(format: " (%.2f %@)", $0, currency ?? "") } ?? "")
        default: return state.rawValue
        }
    }
}

enum LicenseState: String, Codable, Sendable {
    case permissive = "PERMISSIVE", attributionRequired = "ATTRIBUTION_REQUIRED", copyleft = "COPYLEFT", nonCommercial = "NON_COMMERCIAL"
    case noDerivatives = "NO_DERIVATIVES", customRestricted = "CUSTOM_RESTRICTED", marketplaceEULA = "MARKETPLACE_EULA", unknown = "UNKNOWN", contradictory = "CONTRADICTORY"
}

struct LicenseAssessment: Codable, Equatable, Sendable {
    var state: LicenseState
    var identifier: String?               // SPDX id or the licence's own name
    var commercialUse: Tri
    var modification: Tri
    var redistribution: Tri
    var attribution: Tri
    var evidence: [EvidenceRef]
    var needsReview: Bool                 // ambiguous or restrictive → the user must read it before acquisition/import
    var note: String?

    static let unknown = LicenseAssessment(state: .unknown, identifier: nil, commercialUse: .unknown, modification: .unknown, redistribution: .unknown, attribution: .unknown,
                                           evidence: [], needsReview: true, note: "no licence evidence — unknown is NOT safe")
    /// Safe enough to acquire without a human reading it first: a recognised licence that allows commercial use and modification.
    var allowsAutomaticAcquisition: Bool {
        !needsReview && commercialUse == .yes && modification != .no && [.permissive, .attributionRequired].contains(state)
    }
}

enum CompatibilityState: String, Codable, Sendable { case compatible = "COMPATIBLE", likely = "LIKELY_COMPATIBLE", incompatible = "INCOMPATIBLE", unknown = "UNKNOWN" }

struct CompatibilityAssessment: Codable, Equatable, Sendable {
    var overall: CompatibilityState
    var unityVersion: CompatibilityState
    var renderPipeline: CompatibilityState
    var reasons: [String]
    static let unknown = CompatibilityAssessment(overall: .unknown, unityVersion: .unknown, renderPipeline: .unknown, reasons: ["no project facts or no candidate metadata"])
}

// MARK: - Candidates

enum AcquisitionClass: String, Codable, Sendable {
    case publicDirectDownload = "PUBLIC_DIRECT_DOWNLOAD", accountRequiredFree = "ACCOUNT_REQUIRED_FREE", marketplaceClaim = "MARKETPLACE_CLAIM"
    case paidPurchase = "PAID_PURCHASE", unknown = "UNKNOWN"

    /// Which authority a download in this class would need. Account/commercial classes are reported, never executed by V0.9.
    var requiredAuthority: AuthorityLevel {
        switch self {
        case .publicDirectDownload: .acquisition
        case .accountRequiredFree, .marketplaceClaim: .accountAction
        case .paidPurchase: .commercial
        case .unknown: .accountAction
        }
    }
}

struct AssetMetadata: Codable, Equatable, Sendable {
    var publisher: String?
    var version: String?
    var format: [String] = []             // FBX, glTF, Blend, unitypackage, UPM, wav…
    var unityVersions: String?            // as stated by the source ("2021.3+", "Unity 6")
    var pipelines: [String] = []          // "URP", "HDRP", "Built-in" as stated
    var animationType: String?            // Humanoid / Generic / Legacy
    var rigRequirement: String?
    var dependencies: [String] = []
    var polycount: String?
    var textureResolution: String?
    var lastUpdate: String?
    var styleNotes: String?
    var platformRestrictions: String?
}

struct CandidateRecord: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var researchID: UUID
    var name: String
    var url: String
    var sourceID: UUID?
    var publisher: String?
    var summary: String?
    var price: PriceAssessment = .unknown
    var license: LicenseAssessment = .unknown
    var compatibility: CompatibilityAssessment = .unknown
    var meta = AssetMetadata()
    var accountRequired: Tri = .unknown
    var acquisition: AcquisitionClass = .unknown
    var downloadURL: String?
    var styleFit: String?                 // MODEL ASSESSMENT — labelled as such in every surface
    var styleModel: String?
    var unknowns: [String] = []
    var rank = 0
    var score: Double = 0
    var factors: [RankFactor] = []
    var verdict: CandidateVerdict = .undecided
    var verdictReasons: [String] = []
    var codeBearing: CodeBearing = .unknown
    /// Trust (0…5) of the listing this candidate came from; previewURL = the page's own preview image (a link only — never downloaded or stored).
    var sourceTrust = 0
    var previewURL: String?
    var kind: AssetKind?
    /// Checksums the PUBLISHER states for the download (GitHub's asset digest, Poly Haven's md5): compared after download, never invented.
    var expectedSHA256: String?
    var expectedMD5: String?
}

struct RankFactor: Codable, Equatable, Sendable {
    var name: String
    var weight: Double
    var value: Double                     // 0…1
    var reason: String
}

enum CandidateVerdict: String, Codable, Sendable { case preferred, alternative, notRecommended, undecided }

enum CodeBearing: String, Codable, Sendable { case none, scripts, editorScripts, nativeLibraries, unknown }

// MARK: - Acquisition

enum AcquisitionState: String, Codable, Sendable {
    case discovered, verifying, eligible, approvalRequired, approved, downloading, downloaded, inspecting, readyForImport, rejected, failed, cancelled, interrupted

    var label: String { rawValue.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).uppercased() }
    var isTerminal: Bool { [.readyForImport, .rejected, .failed, .cancelled].contains(self) }
    var allowedNext: Set<AcquisitionState> {
        switch self {
        case .discovered: [.verifying, .rejected, .cancelled]
        case .verifying: [.eligible, .approvalRequired, .rejected, .failed, .cancelled, .interrupted]
        case .eligible: [.approved, .downloading, .approvalRequired, .rejected, .cancelled]
        case .approvalRequired: [.approved, .rejected, .cancelled, .interrupted]
        case .approved: [.downloading, .cancelled, .interrupted]
        case .downloading: [.downloaded, .failed, .cancelled, .interrupted]
        case .downloaded: [.inspecting, .failed, .cancelled, .interrupted]
        case .inspecting: [.readyForImport, .rejected, .failed, .cancelled, .interrupted]
        case .interrupted: [.verifying, .downloading, .failed, .cancelled]    // explicit user resume only
        case .readyForImport, .rejected, .failed, .cancelled: []
        }
    }
    static func canMove(_ a: AcquisitionState, to b: AcquisitionState) -> Bool { a == b || a.allowedNext.contains(b) }
}

/// What the quarantine knows about one downloaded artifact. Trust is never implied: DOWNLOADED ≠ INSPECTED ≠ VALIDATED_FOR_IMPORT.
enum ArtifactTrust: String, Codable, Sendable { case downloaded = "DOWNLOADED", inspected = "INSPECTED", validatedForImport = "VALIDATED_FOR_IMPORT", rejected = "REJECTED" }

struct AcquisitionRecord: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var researchID: UUID?
    var candidateID: UUID?
    var taskID: UUID?
    var state: AcquisitionState
    var acquisitionClass: AcquisitionClass
    var name: String
    var sourceURL: String                 // the canonical page the user can open
    var downloadURL: String?              // sanitized (no tokens)
    var finalHost: String?
    var originalFilename: String?
    var publisher: String?
    var assetVersion: String?
    var licenseID: String?
    var licenseSourceURL: String?
    var priceState: PriceState?
    var priceVerifiedAt: Date?
    var sha256: String?
    var expectedSHA256: String?
    var hashMatchesPublished: Tri = .unknown
    var size: Int?
    var detectedType: String?
    var declaredMIME: String?
    var quarantinePath: String?           // relative to the acquisitions folder
    var trust: ArtifactTrust = .downloaded
    var inspection: ArtifactInspection?
    var failure: String?
    var bytesDownloaded: Int?
    var bytesExpected: Int?
    var createdAt = Date()
    var updatedAt = Date()
    var downloadedAt: Date?
    /// Set once a V0.4 import task copied the artifact into a project (the destination folder, project-relative) — and which task did it.
    var importedTo: String?
    var importTaskID: UUID?
}

struct ArtifactInspection: Codable, Equatable, Sendable {
    var kind: String                      // zip, tar.gz, unitypackage, png, fbx, wav, executable, …
    var entryCount: Int
    var uncompressedBytes: Int
    var maxCompressionRatio: Double
    var hasScripts: Bool
    var hasEditorScripts: Bool
    var hasNativeLibraries: Bool
    var hasExecutables: Bool
    var findings: [String]                // human-readable warnings
    var rejectedReason: String?
    var sampleEntries: [String]           // first N paths (bounded)
    var codeBearing: CodeBearing
}

// MARK: - Report

struct ReportFact: Codable, Equatable, Sendable { var text: String; var epistemic: Epistemic; var status: VerificationStatus; var sourceIDs: [UUID] }

struct ResearchReport: Codable, Equatable, Sendable {
    var researchID: UUID
    var goal: String
    var type: ResearchType
    var constraints: [String]
    var generatedAt: Date
    var durationSeconds: Double
    var status: ResearchStatus
    var queries: [String]
    var sourceCount: Int
    var facts: [ReportFact]
    var assessments: [ReportFact]
    var candidates: [CandidateRecord]
    var contradictions: [String]
    var uncertainties: [String]
    var injectionNotes: [String]
    var recommendation: String
    var acquisitionNote: String
    var nextSafeAction: String
    var budgetNote: String?
}

// MARK: - Errors / outcomes

enum ResearchFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case blockedByURLPolicy(String)
    case offline
    case timeout
    case tlsFailure
    case httpStatus(Int)
    case rateLimited(retryAfter: TimeInterval?)
    case loginWall
    case captcha
    case tooLarge
    case unsupportedContent(String)
    case budgetExhausted(String)
    case cancelled
    case noResults
    case providerFailed(String)
    case ssrfPostCheck(String)

    var description: String {
        switch self {
        case .blockedByURLPolicy(let w): "blocked by the URL policy: \(w)"
        case .offline: "no network connection"
        case .timeout: "the request timed out"
        case .tlsFailure: "the secure connection failed"
        case .httpStatus(let s): "HTTP \(s)"
        case .rateLimited: "rate limited by the site"
        case .loginWall: "a login is required to see this page"
        case .captcha: "the site asks for a CAPTCHA — user interaction required (JARVIS does not bypass it)"
        case .tooLarge: "the response is larger than the limit"
        case .unsupportedContent(let t): "unsupported content type \(t)"
        case .budgetExhausted(let w): "research budget used up (\(w))"
        case .cancelled: "cancelled"
        case .noResults: "no results"
        case .providerFailed(let w): "the search provider failed: \(w)"
        case .ssrfPostCheck(let w): "the connection went to a non-public address (\(w))"
        }
    }

    /// "Could not verify" is NOT "does not exist": these outcomes leave a fact UNKNOWN rather than false.
    var leavesFactUnknown: Bool {
        switch self {
        case .offline, .timeout, .tlsFailure, .rateLimited, .loginWall, .captcha, .tooLarge, .budgetExhausted, .providerFailed, .httpStatus(500...599), .httpStatus(403), .httpStatus(429): true
        default: false
        }
    }
}
