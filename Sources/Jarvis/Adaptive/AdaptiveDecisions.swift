import Foundation
import CryptoKit

// MARK: - The adaptive approval boundary (V0.14, DEC-219)
//
// Promotion of a learned rule / skill, registration / update / removal of a capability and a self-improvement are ALL decided here, and only from HUD buttons
// (`AdaptiveDecisionSource.hud`). There is no API that accepts text as a decision: typed or spoken "yes" cannot satisfy it (ApprovalGuard + this boundary). A decision
// binds to the exact subject that was shown (`scopeHash`): if the subject changed afterwards the approval is refused.

enum AdaptiveOutcome: Equatable, Sendable {
    case notPending
    case tampered
    case denied
    case executed(String)
    case failed(String)
    case refused(String)
}

@MainActor @Observable
final class AdaptiveDecisionService {
    struct Domain {
        /// The CURRENT fingerprint of the subject (nil = it no longer exists). Compared with the request's `scopeHash`.
        var fingerprint: (String) -> String?
        /// Runs the approved request. Returns the result text, or a failure/refusal.
        var execute: (AdaptiveRequest) async -> Result<String, AdaptiveExecutionError>
    }
    struct AdaptiveExecutionError: Error, Equatable { var message: String; var refused = false }

    private let repository: JarvisRepository?
    private var domains: [AdaptiveRequestKind: Domain] = [:]
    @ObservationIgnored var onEvent: ((String, ActivityKind) -> Void)?
    @ObservationIgnored var clock: () -> Date = { Date() }
    /// Bumped on every change so views refresh (event-driven; no polling).
    private(set) var revision = 0

    init(repository: JarvisRepository?) { self.repository = repository }

    func register(_ kind: AdaptiveRequestKind, _ domain: Domain) { domains[kind] = domain }

    static func scopeHash(kind: AdaptiveRequestKind, subjectID: String, material: String) -> String {
        SHA256.hash(data: Data("\(kind.rawValue)|\(subjectID)|\(material)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Creating a request (any caller — a request is only a QUESTION; nothing executes)

    @discardableResult
    func request(kind: AdaptiveRequestKind, subjectID: String, material: String, summary: String, detail: String, risk: RiskClass) -> AdaptiveRequest? {
        guard let repository else { return nil }
        // One open request per subject: asking twice does not stack questions.
        if let open = ((try? repository.adaptiveRequests(statuses: [.pending])) ?? []).first(where: { $0.kind == kind && $0.subjectID == subjectID }) { return open }
        let q = AdaptiveRequest(kind: kind, subjectID: subjectID, scopeHash: Self.scopeHash(kind: kind, subjectID: subjectID, material: material), summary: summary, detail: detail, risk: risk, requestedAt: clock())
        try? repository.save(q)
        try? repository.addLearningAudit(LearningAuditEntry(kind: "request", subjectID: q.id.uuidString, detail: "\(kind.label): \(summary)", by: "system"))
        onEvent?("Waiting for your decision: \(summary)", .info)
        revision += 1
        return q
    }

    func pending() -> [AdaptiveRequest] { ((try? repository?.adaptiveRequests(statuses: [.pending])) ?? []) ?? [] }
    func recent(limit: Int = 30) -> [AdaptiveRequest] { ((try? repository?.adaptiveRequests(limit: limit)) ?? []) ?? [] }
    func request(_ id: UUID) -> AdaptiveRequest? { ((try? repository?.adaptiveRequest(id)) ?? nil) }

    // MARK: Deciding (HUD buttons only)

    @discardableResult
    func approve(_ id: UUID, source: AdaptiveDecisionSource) async -> AdaptiveOutcome {
        guard let repository, var q = (try? repository.adaptiveRequest(id)) ?? nil, q.status == .pending else { return .notPending }
        guard let domain = domains[q.kind] else { return .refused("nothing can execute “\(q.kind.label)” in this build") }
        guard let current = domain.fingerprint(q.subjectID), current == q.scopeHash else {
            q.status = .cancelled; q.decidedAt = clock(); q.decidedBy = source.rawValue; q.result = "the subject changed after it was shown"
            try? repository.save(q); revision += 1
            onEvent?("Approval refused: “\(q.summary)” changed after it was shown", .error)
            return .tampered
        }
        q.status = .approved; q.decidedAt = clock(); q.decidedBy = source.rawValue
        try? repository.save(q)
        try? repository.addLearningAudit(LearningAuditEntry(kind: "approved", subjectID: q.id.uuidString, detail: q.summary, by: source.rawValue))
        return await run(q, domain: domain)
    }

    @discardableResult
    func deny(_ id: UUID, source: AdaptiveDecisionSource) -> AdaptiveOutcome {
        guard let repository, var q = (try? repository.adaptiveRequest(id)) ?? nil, q.status == .pending else { return .notPending }
        q.status = .denied; q.decidedAt = clock(); q.decidedBy = source.rawValue
        try? repository.save(q)
        try? repository.addLearningAudit(LearningAuditEntry(kind: "denied", subjectID: q.id.uuidString, detail: q.summary, by: source.rawValue))
        onDenied?(q)
        revision += 1
        onEvent?("Declined: \(q.summary)", .warning)
        return .denied
    }
    @ObservationIgnored var onDenied: ((AdaptiveRequest) -> Void)?

    /// A POLICY decision the user pre-authorised in Settings (auto-promotion of low-risk workflow rules). Recorded as such — never as a HUD click.
    @discardableResult
    func approveByStandingPolicy(_ id: UUID, policy: String) async -> AdaptiveOutcome {
        guard let repository, var q = (try? repository.adaptiveRequest(id)) ?? nil, q.status == .pending, q.kind == .promoteCandidate || q.kind == .activateSkill, q.risk == .low,
              let domain = domains[q.kind], let current = domain.fingerprint(q.subjectID), current == q.scopeHash else { return .refused("standing policy does not apply") }
        q.status = .approved; q.decidedAt = clock(); q.decidedBy = "policy:\(policy)"
        try? repository.save(q)
        try? repository.addLearningAudit(LearningAuditEntry(kind: "approved-by-policy", subjectID: q.id.uuidString, detail: "\(q.summary) — \(policy)", by: "policy"))
        return await run(q, domain: domain)
    }

    private func run(_ request: AdaptiveRequest, domain: Domain) async -> AdaptiveOutcome {
        var q = request
        let result = await domain.execute(q)
        q.executedAt = clock()
        defer { revision += 1 }
        switch result {
        case .success(let text):
            q.status = .executed; q.result = text; try? repository?.save(q)
            try? repository?.addLearningAudit(LearningAuditEntry(kind: "executed", subjectID: q.id.uuidString, detail: text, by: q.decidedBy ?? "?"))
            onEvent?(text, .success)
            return .executed(text)
        case .failure(let e):
            q.status = .failed; q.result = e.message; try? repository?.save(q)
            onEvent?("Not done: \(e.message)", .warning)
            return e.refused ? .refused(e.message) : .failed(e.message)
        }
    }
}
