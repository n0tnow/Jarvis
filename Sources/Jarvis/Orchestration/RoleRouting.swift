import Foundation

// MARK: - Role-aware routing support (V0.12, DEC-164…)
//
// The pure `ModelRouter` (V0.3.1) still decides WHICH engines are eligible (cost, privacy, local-model policy, health, benchmarks, explicit user choice). This layer adds what
// the orchestrator knows that the router does not: the ROLE of the node, review independence, a per-node invocation budget, and a human-readable, persisted reason.
// Provider HEALTH (cooldowns) and model QUALITY (role benchmarks) stay separate inputs.

/// Per-node accounting. Every attempt and every provider invocation of ONE node is counted; the caps come from the role's contract and cannot be exceeded by repair or escalation.
struct NodeLedger: Equatable, Sendable {
    var attempts = 0
    var providerRuns = 0
    var repairs = 0
    var escalations = 0
    var engines: [String] = []

    mutating func record(engine: String?, repair: Bool = false, escalation: Bool = false) {
        providerRuns += 1; attempts += 1
        if repair { repairs += 1 }
        if escalation { escalations += 1 }
        if let engine, engines.last != engine { engines.append(engine) }
    }

    func mayRetry(role: AgentRole) -> Bool {
        let b = AgentContracts.contract(role).retry
        return attempts < b.maxAttempts && providerRuns < b.maxProviderInvocations
    }
    func mayEscalate(role: AgentRole) -> Bool {
        let b = AgentContracts.contract(role).retry
        return escalations < b.escalations && providerRuns < b.maxProviderInvocations
    }
}

/// Review independence is risk-based, never mandatory for trivial work (DEC-169).
enum ReviewIndependence {
    struct Facts: Equatable, Sendable {
        var changedFiles: Int
        var changedLines: Int
        var taskRisk: RiskClass
        var securityRelevant: Bool
        var escalated: Bool
    }

    /// A nontrivial change gets a reviewer that is NOT the writer when another eligible, zero-extra-cost engine exists.
    static func isRequired(_ f: Facts) -> Bool {
        f.securityRelevant || f.escalated || f.taskRisk >= .high || f.changedFiles >= 2 || f.changedLines >= 30
    }

    enum Outcome: String, Equatable, Sendable { case differentProvider, differentModel, sameProvider, notRequired }

    static func outcome(required: Bool, writers: [RoutingCandidate], reviewer: RoutingCandidate?) -> Outcome {
        guard required else { return .notRequired }
        guard let reviewer, !writers.isEmpty else { return .sameProvider }
        if !writers.contains(where: { $0.engine == reviewer.engine }) { return .differentProvider }
        if !writers.contains(reviewer) { return .differentModel }
        return .sameProvider
    }

    static let securityWords = ["auth", "password", "token", "secret", "crypto", "permission", "security", "sql", "inject", "sanitiz", "credential", "session", "login", "oturum", "guvenlik", "sifre"]
    static func looksSecurityRelevant(goal: String, paths: [String]) -> Bool {
        let t = (ResearchText.fold(goal) + " " + paths.map { ResearchText.fold($0) }.joined(separator: " "))
        return securityWords.contains { t.contains($0) }
    }
}

/// Turns the router's machine-readable reason (`agent_runs.selection_reason`) into the sentence the user and the diagnostics show.
enum RoutingExplainer {
    static func parse(_ json: String?) -> [String: String] {
        guard let json, let d = json.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [:] }
        return o.compactMapValues { $0 as? String }
    }

    /// "Selected space-bunny-free for Coding because it passed the coding benchmark, is currently verified $0 (zero retention), and the task is moderate."
    static func sentence(role: AgentRole, candidate: RoutingCandidate?, reasons: [String: String], independence: ReviewIndependence.Outcome = .notRequired, escalatedFrom: String? = nil, roleScore: String? = nil) -> String {
        guard let candidate else { return "No provider was selected for \(role.label)\(reasons["outcome"] == "refused" ? " (refused by policy)" : "")." }
        let name = candidate.model ?? candidate.engine.displayName
        var because: [String] = []
        switch reasons["tier"] {
        case "explicit": because.append("you chose \(candidate.engine.displayName) explicitly")
        case "lightweight-local-first": because.append("the task is lightweight and the local model is allowed to do it")
        case "development-free-first": because.append("development work goes to a verified-free OpenCode model first")
        case "heavy-premium-only"?: because.append("the task is complex or sensitive, so it goes to a premium subscription engine")
        default: break
        }
        if reasons["freeVerified"] == "true" { because.append("it is currently verified $0\(reasons["dataPolicy"] == "zeroRetention" ? " with zero data retention" : "")") }
        if reasons["codingBenchmarkPassed"] == "true" { because.append("it passed the coding benchmark") }
        else if reasons["testingBenchmarkPassed"] == "true" { because.append("it passed the testing benchmark") }
        if let roleScore { because.append(roleScore) }
        if candidate.engine == .claudeCode || candidate.engine == .codex { because.append("it is a subscription-backed engine (no metered API)") }
        if reasons["providerReady"] == "true", because.isEmpty { because.append("it is ready") }
        if reasons["complexity"] != nil, let c = reasons["complexity"] { because.append("the task is \(c)") }
        if let from = escalatedFrom { because.append("escalated from \(from)") }
        switch independence {
        case .differentProvider: because.append("the reviewer is a different provider than the writer")
        case .differentModel: because.append("the reviewer is a different model than the writer")
        case .sameProvider: because.append("no other eligible provider exists, so the writer also reviews")
        case .notRequired: break
        }
        return "Selected \(name) for \(role.label)" + (because.isEmpty ? "." : " because " + because.joined(separator: ", ") + ".")
    }
}

// MARK: - Role scoreboard (quality per ROLE, from recorded benchmark results only)

struct RoleScore: Equatable, Sendable {
    var role: String
    var total: Int
    var passed: Int
    var malformed: Int
    var medianLatencyMS: Double?
    var contextChars: Int?
    var ranAt: Date?
    var passRate: Double { total == 0 ? 0 : Double(passed) / Double(total) }
    var label: String { "\(passed)/\(total)" }
}

enum RoleScoreboard {
    static let suiteID = "roles-v1"

    /// Newest result per case, grouped by role (the role is the second component of the case id: `role.<role>.<n>`).
    static func scores(_ results: [BenchmarkResultRecord]) -> [String: RoleScore] {
        var newest: [String: BenchmarkResultRecord] = [:]
        for r in results where r.suite == suiteID && !r.cancelled { if let o = newest[r.caseID], o.ranAt >= r.ranAt { continue }; newest[r.caseID] = r }
        var byRole: [String: [BenchmarkResultRecord]] = [:]
        for r in newest.values { byRole[roleOf(r.caseID), default: []].append(r) }
        return byRole.mapValues { rs in
            let lat = rs.compactMap(\.latencyMS).sorted()
            return RoleScore(role: roleOf(rs[0].caseID), total: rs.count, passed: rs.filter(\.passed).count, malformed: rs.filter(\.malformed).count, medianLatencyMS: lat.isEmpty ? nil : lat[lat.count / 2],
                             contextChars: rs.compactMap(\.contextChars).max(), ranAt: rs.map(\.ranAt).max())
        }
    }
    static func roleOf(_ caseID: String) -> String { let p = caseID.split(separator: ".").map(String.init); return p.count >= 3 ? p[1] : "general" }

    /// A model has "role evidence" only when every case of the role ran and enough passed; absence of evidence is NOT failure (nothing here blocks the V0.3.1 gates).
    static func isQualified(_ s: RoleScore?, needed: Int, minRate: Double = 0.66) -> Bool {
        guard let s, s.total >= needed, s.malformed == 0 || Double(s.malformed) / Double(s.total) <= 0.25 else { return false }
        return s.passRate >= minRate
    }
}

// MARK: - Failure vocabulary (never "AI failed")

enum NodeFailureClass: String, Codable, Sendable {
    case providerUnavailable, timeout, invalidSchema, contextOverflow, toolRefusal, poorValidation, securityRefusal, rateLimit, modelError, cancelled, notApplicable

    var label: String {
        switch self {
        case .providerUnavailable: "provider unavailable"; case .timeout: "timeout"; case .invalidSchema: "invalid output schema"; case .contextOverflow: "context too large"
        case .toolRefusal: "tool refusal"; case .poorValidation: "failed deterministic validation"; case .securityRefusal: "blocked by security policy"; case .rateLimit: "rate limit"
        case .modelError: "model error"; case .cancelled: "cancelled"; case .notApplicable: "—"
        }
    }

    static func classify(_ category: FailureCategory?, validationFailed: Bool = false) -> NodeFailureClass {
        switch category {
        case .providerUnavailable?, .unityUnavailable?, .networkUnavailable?: return .providerUnavailable
        case .providerRateLimited?: return .rateLimit
        case .providerFailed?: return validationFailed ? .invalidSchema : .modelError
        case .malformedPlan?: return .invalidSchema
        case .securityBlocked?, .capabilityDenied?, .blockedByNetworkPolicy?, .scopeExceeded?, .workspaceViolation?: return .securityRefusal
        case .buildFailed?, .testFailed?, .validationFailed?, .compileFailed?, .workspaceChanged?: return .poorValidation
        case .computerTimeout?, .unityTimeout?: return .timeout
        case .cancelled?, .interrupted?: return .cancelled
        case .approvalDenied?: return .toolRefusal
        case nil: return .notApplicable
        default: return .modelError
        }
    }
}

// MARK: - Escalation reasons (explicit)

enum EscalationReason: String, Codable, Sendable {
    case validationFailedTwice, complexArchitecture, securitySensitive, securityRelevant, freeModelUnavailable, contextTooLarge, reviewFoundDefect

    var label: String {
        switch self {
        case .validationFailedTwice: "the same validation failed twice"; case .complexArchitecture: "architecture complexity is high"; case .securitySensitive, .securityRelevant: "the work is security-sensitive"
        case .freeModelUnavailable: "the free model was unavailable"; case .contextTooLarge: "the context is too large for the first choice"; case .reviewFoundDefect: "the review found a substantive defect"
        }
    }
}
