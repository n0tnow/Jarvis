import Foundation

// MARK: - Capability-based worker selection and review independence (V1.0 autonomous engineering pipeline)
//
// The `ModelRouter` (V0.3.1) remains the ROUTING authority: it decides which engines are eligible (cost, privacy, `LocalModelPolicy`, health, benchmarks, explicit user choice). This layer adds
// what an engineering assignment knows that the router does not — the CAPABILITIES it needs — and ranks workers by capability metadata instead of brand names. It can only NARROW:
//   · the lightweight local conversational model is never a production coding / testing / review worker;
//   · a PAID worker is never chosen unless the user explicitly chose it; UNKNOWN price is never free (only a verified-zero price makes a cloud worker free);
//   · an explicit choice never falls back to anything else;
//   · heavy work (complex / critical / architecture / security) needs a worker that declares premium reasoning;
//   · the reviewer of a non-trivial change is a different worker than the implementer when risk or breadth warrants it and a zero-extra-cost alternative exists.

enum WorkerPricing: String, Codable, Sendable { case verifiedZero, subscription, paid, unknown }

struct WorkerProfile: Codable, Equatable, Sendable {
    var id: String
    var capabilities: Set<WorkerCapability>
    var pricing: WorkerPricing
    var isLocalConversationalModel = false
    var available = true
    var contextTokens = 32_000
    /// Declares strong reasoning for complex / critical / architectural work.
    var premiumReasoning = false
    /// Recent benchmark pass rate for coding tasks (0…1), nil = never benchmarked.
    var benchmarkSuccess: Double?
    var residentMemoryMB = 0
}

struct WorkerSelection: Equatable, Sendable {
    var chosen: String?
    var ranked: [String]
    var rejected: [String: String]
    var reason: String
}

enum WorkerSelector {
    private static let developmentNeeds: Set<WorkerCapability> = [.codeGeneration, .testGeneration, .codeReview, .debugging, .architecture, .repositoryAnalysis]

    static func eligibility(_ w: WorkerProfile, needs: Set<WorkerCapability>, complexity: Complexity, explicitChoice: String?, estimatedContextTokens: Int, memoryPressure: Bool) -> String? {
        if !w.available { return "unavailable" }
        if w.isLocalConversationalModel, !needs.isDisjoint(with: developmentNeeds) { return "the local conversational model is not a coding / testing / review worker" }
        if !needs.isSubset(of: w.capabilities) { return "lacks \(needs.subtracting(w.capabilities).map(\.rawValue).sorted().joined(separator: ", "))" }
        if w.pricing == .paid, explicitChoice != w.id { return "paid workers are used only when explicitly chosen" }
        if w.pricing == .unknown { return "unknown price is never free" }
        if complexity >= .complex, !w.premiumReasoning { return "complex work needs a premium-reasoning worker" }
        if estimatedContextTokens > w.contextTokens { return "context too small (\(w.contextTokens) < \(estimatedContextTokens))" }
        if memoryPressure, w.residentMemoryMB >= 4_000 { return "memory pressure: a large resident worker does not start now" }
        return nil
    }

    static func select(needs: Set<WorkerCapability>, complexity: Complexity, workers: [WorkerProfile], explicitChoice: String? = nil, estimatedContextTokens: Int = 0, memoryPressure: Bool = false, excluding: Set<String> = []) -> WorkerSelection {
        var rejected: [String: String] = [:]
        if let e = explicitChoice {
            // an explicit choice never falls back: it is served by exactly that worker or by nobody
            guard let w = workers.first(where: { $0.id == e }) else { return WorkerSelection(chosen: nil, ranked: [], rejected: [e: "not registered"], reason: "the explicitly chosen worker does not exist; no fallback") }
            if excluding.contains(e) { return WorkerSelection(chosen: nil, ranked: [], rejected: [e: "excluded"], reason: "the explicitly chosen worker is excluded; no fallback") }
            if let why = eligibility(w, needs: needs, complexity: complexity, explicitChoice: e, estimatedContextTokens: estimatedContextTokens, memoryPressure: memoryPressure) { return WorkerSelection(chosen: nil, ranked: [], rejected: [e: why], reason: "the explicitly chosen worker cannot serve this assignment; no fallback") }
            return WorkerSelection(chosen: e, ranked: [e], rejected: [:], reason: "explicit choice")
        }
        var ok: [WorkerProfile] = []
        for w in workers {
            if excluding.contains(w.id) { rejected[w.id] = "excluded"; continue }
            if let why = eligibility(w, needs: needs, complexity: complexity, explicitChoice: nil, estimatedContextTokens: estimatedContextTokens, memoryPressure: memoryPressure) { rejected[w.id] = why } else { ok.append(w) }
        }
        // cheaper first (verified free, then subscription), then benchmark evidence, then the tighter context fit, then a stable id order
        func tier(_ w: WorkerProfile) -> Int { switch w.pricing { case .verifiedZero: 0; case .subscription: 1; default: 2 } }
        // heavy work prefers the premium-reasoning worker even over a free one
        let heavy = complexity >= .complex
        let ranked = ok.sorted { a, b in
            if heavy, a.premiumReasoning != b.premiumReasoning { return a.premiumReasoning }
            if tier(a) != tier(b) { return tier(a) < tier(b) }
            let (sa, sb) = (a.benchmarkSuccess ?? -1, b.benchmarkSuccess ?? -1)
            if sa != sb { return sa > sb }
            if a.contextTokens != b.contextTokens { return a.contextTokens < b.contextTokens }
            return a.id < b.id
        }
        guard let first = ranked.first else { return WorkerSelection(chosen: nil, ranked: [], rejected: rejected, reason: "no eligible worker") }
        return WorkerSelection(chosen: first.id, ranked: ranked.map(\.id), rejected: rejected, reason: "capability match, cost tier \(tier(first)), benchmark \(first.benchmarkSuccess.map { String(format: "%.2f", $0) } ?? "none")")
    }

    static func select(for a: EngineeringAssignment, workers: [WorkerProfile], memoryPressure: Bool = false, estimatedContextTokens: Int = 0, excluding: Set<String> = []) -> WorkerSelection {
        let explicit = a.providerPreference == "auto" ? nil : a.providerPreference
        return select(needs: a.requiredCapabilities, complexity: a.routingProfile().complexity, workers: workers, explicitChoice: explicit, estimatedContextTokens: estimatedContextTokens, memoryPressure: memoryPressure, excluding: excluding)
    }
}

// MARK: Review policy

enum ReviewMode: String, Codable, Equatable, Sendable {
    /// Deterministic evidence is enough: no model review.
    case deterministicOnly
    case modelReview
    /// A model review by a worker that is NOT the implementer.
    case independentModelReview
}

enum ReviewPolicy {
    /// Trivial, clean, verified changes get no model reviewer (no spending on what a diff check already settled); risk, breadth, sensitive paths or major findings escalate.
    static func mode(assignment a: EngineeringAssignment, verdict v: VerificationVerdict, plan: VerificationPlan?) -> ReviewMode {
        let sensitive = v.findings.contains { [.guardChanged, .guardWeakened, .buildScriptChanged, .dependencyAdded, .architectureDrift, .testModifiedWithoutAuthority, .assertionChanged].contains($0.code) } || (plan?.elevatedReview ?? false)
        let broad = v.diffStats.files >= 3 || v.diffStats.linesAdded + v.diffStats.linesRemoved >= 80
        if sensitive || a.risk >= .high || !v.findings.majors.isEmpty { return .independentModelReview }
        if broad || a.risk == .medium { return .modelReview }
        return .deterministicOnly
    }

    /// The reviewer: not the implementer when an independent mode is required and a zero-extra-cost alternative exists; `sameWorker` states honestly when it had to be the same.
    static func reviewer(implementer: String, mode: ReviewMode, workers: [WorkerProfile], needs: Set<WorkerCapability> = [.codeReview], explicitChoice: String? = nil) -> (id: String?, independent: Bool) {
        guard mode != .deterministicOnly else { return (nil, false) }
        let all = WorkerSelector.select(needs: needs, complexity: .moderate, workers: workers, explicitChoice: explicitChoice)
        if mode == .independentModelReview {
            let other = WorkerSelector.select(needs: needs, complexity: .moderate, workers: workers, explicitChoice: explicitChoice, excluding: [implementer])
            if let c = other.chosen { return (c, true) }
        }
        return (all.chosen, all.chosen != nil && all.chosen != implementer)
    }
}

enum ReviewDimension: String, Codable, CaseIterable, Sendable {
    case correctness, scopeAdherence, errorHandling, tests, security, performance, maintainability, architectureFit, backwardsCompatibility
}

enum DimensionStatus: String, Codable, Equatable, Sendable { case pass, concern, fail, notAssessed }

struct ModelFinding: Codable, Equatable, Sendable {
    var text: String
    var severity: FindingSeverity
    var dimension: ReviewDimension
    /// A quote from the diff, a changed path, or a recorded evidence line — verified by JARVIS, not trusted.
    var evidence: String
}

struct EngineeringReviewResult: Equatable, Sendable {
    var dimensions: [ReviewDimension: DimensionStatus]
    /// Findings that may block: deterministic BLOCKERs and model findings whose evidence JARVIS could find.
    var blocking: [EngineeringFinding]
    var advisory: [EngineeringFinding]
    var rejectedModelFindings: [String]
    var passes: Bool { blocking.isEmpty }
}

enum ReviewRubric {
    private static let map: [FindingCode: ReviewDimension] = [
        .scopeEscape: .scopeAdherence, .forbiddenPath: .scopeAdherence, .protectedPath: .scopeAdherence, .unexplainedChange: .scopeAdherence, .userDirtyFileTouched: .scopeAdherence, .largeDiff: .scopeAdherence, .readOnlyAssignmentChanged: .scopeAdherence,
        .testDeleted: .tests, .testSkipped: .tests, .assertionWeakened: .tests, .assertionChanged: .tests, .testModifiedWithoutAuthority: .tests,
        .guardWeakened: .security, .guardChanged: .security, .secretIntroduced: .security, .unsafeCommand: .security, .shellInjectionRisk: .security, .buildFailureSuppressed: .tests, .buildScriptChanged: .tests,
        .silentErrorSuppression: .errorHandling, .placeholderCode: .correctness, .placeholderComment: .maintainability, .noChange: .correctness, .criterionUnmet: .correctness, .regression: .correctness,
        .architectureDrift: .architectureFit, .duplicateAbstraction: .architectureFit, .dependencyAdded: .maintainability, .unverifiedDependency: .correctness, .unvalidatedAPI: .correctness,
        .binaryFileChanged: .maintainability, .generatedFileChanged: .maintainability, .documentationOverclaim: .correctness, .commitClaimContradicted: .correctness, .testClaimContradicted: .correctness,
    ]

    static func dimension(of code: FindingCode) -> ReviewDimension { map[code] ?? .correctness }

    /// Deterministic evidence first; a model reviewer's findings count only with verifiable evidence (a quote in the diff, a changed path, a recorded line) — and only a BLOCKER blocks.
    static func evaluate(verdict v: VerificationVerdict, modelFindings: [ModelFinding] = [], condensedDiff: String = "", evidenceLines: [String] = []) -> EngineeringReviewResult {
        var dims: [ReviewDimension: DimensionStatus] = [:]
        for d in ReviewDimension.allCases { dims[d] = .notAssessed }
        for d in [ReviewDimension.correctness, .scopeAdherence, .tests, .security] { dims[d] = .pass }
        for f in v.findings {
            let d = dimension(of: f.code)
            let s: DimensionStatus = f.severity == .blocker ? .fail : (f.severity >= .minor ? .concern : dims[d] ?? .pass)
            if rank(s) > rank(dims[d] ?? .notAssessed) || dims[d] == .notAssessed { dims[d] = s }
        }
        var blocking = v.findings.filter { $0.severity == .blocker }
        var advisory = v.findings.filter { $0.severity < .blocker }
        var rejected: [String] = []
        let changedPaths = Set(v.attribution.changes.map(\.change.path))
        for m in modelFindings {
            let e = m.evidence.trimmingCharacters(in: .whitespacesAndNewlines)
            let verifiable = e.count >= 6 && (condensedDiff.contains(e) || changedPaths.contains { e.contains($0) || $0.contains(e) } || evidenceLines.contains { $0.contains(e) })
            guard verifiable else { rejected.append(String(m.text.prefix(120))); continue }
            let f = EngineeringFinding(.criterionUnmet, m.severity, path: changedPaths.first { e.contains($0) }, m.text, evidence: e)
            if m.severity == .blocker { blocking.append(f) } else { advisory.append(f) }
            let s: DimensionStatus = m.severity == .blocker ? .fail : (m.severity >= .minor ? .concern : .pass)
            if rank(s) > rank(dims[m.dimension] ?? .notAssessed) || dims[m.dimension] == .notAssessed { dims[m.dimension] = s }
        }
        return EngineeringReviewResult(dimensions: dims, blocking: blocking, advisory: advisory, rejectedModelFindings: rejected)
    }

    private static func rank(_ s: DimensionStatus) -> Int { switch s { case .notAssessed: 0; case .pass: 1; case .concern: 2; case .fail: 3 } }

    /// What a reviewer receives: the objective, the criteria, the deterministic findings and the CONDENSED ACTUAL DIFF — never the implementer's own prose summary.
    static func packet(assignment a: EngineeringAssignment, verdict v: VerificationVerdict, condensedDiff: String, maxCharacters: Int = 9_000) -> String {
        var lines = ["REVIEW OBJECTIVE: \(a.objective)", "ACCEPTANCE:\n" + a.acceptance.map { "- [\($0.id)] \($0.text)" }.joined(separator: "\n")]
        let facts = v.findings.filter { $0.severity >= .minor }.prefix(12).map { "- \($0.severity.label) \($0.code.rawValue)\($0.path.map { " (\($0))" } ?? ""): \($0.message)" }
        if !facts.isEmpty { lines.append("DETERMINISTIC FINDINGS:\n" + facts.joined(separator: "\n")) }
        lines.append("ACTUAL DIFF:\n" + condensedDiff)
        lines.append("Report findings as BLOCKER / MAJOR / MINOR / NOTE, each citing a quote from the diff or a changed path. Style preferences are not findings.")
        let text = lines.joined(separator: "\n\n")
        return text.count <= maxCharacters ? text : String(text.prefix(maxCharacters - 1)) + "…"
    }
}
