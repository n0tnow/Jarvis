import Foundation

// MARK: - An approval belongs to ONE action, for a LIMITED time (V1.0 background pass)
//
// The engine persists approvals and, after a restart, reuses an already-approved decision "for this exact action" so the person is not asked twice. Reuse needs two more guards for a task that runs for
// hours: the approval must still be about the SAME operation (target, parameters, risk, task) and it must not be STALE. Binding is a stable hash of those fields; freshness is a time-to-live by risk:
// an approval is never reused for critical risk (a critical action asks again every time), high risk for two hours, everything else for twelve. A material change (another target, another parameter, a
// higher risk) produces another binding, so the old approval simply no longer matches. Pure.

struct ApprovalBinding: Equatable, Sendable {
    var taskID: UUID
    var stepKey: String
    var operation: String
    var target: String
    var parameters: String
    var risk: RiskClass

    /// FNV-1a over a canonical, length-prefixed encoding (so "ab"+"c" never collides with "a"+"bc"). A binding identity, not a security primitive: approvals are local rows.
    var digest: String {
        var h: UInt64 = 0xcbf29ce484222325
        func mix(_ s: String) { for b in "\(s.utf8.count):\(s)".utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 } }
        for part in [taskID.uuidString, stepKey, operation, target, parameters, risk.rawValue] { mix(part) }
        return String(format: "%016llx", h)
    }
}

enum ApprovalFreshness {
    /// Seconds an APPROVED decision may be reused; 0 = never (ask again).
    static func timeToLive(_ risk: RiskClass) -> TimeInterval {
        switch risk { case .low, .medium: 12 * 3600; case .high: 2 * 3600; case .critical: 0 }
    }

    static func mayReuse(approvedAt: Date?, risk: RiskClass, now: Date) -> Bool {
        guard let approvedAt, now >= approvedAt else { return false }
        let ttl = timeToLive(risk)
        return ttl > 0 && now.timeIntervalSince(approvedAt) <= ttl
    }

    /// An already-persisted approval record may be reused for a new request only if it is approved, fresh for its risk AND the action text is identical.
    static func mayReuse(_ existing: ApprovalRecord, forAction action: String, now: Date) -> Bool {
        existing.state == .approved && existing.action == action && mayReuse(approvedAt: existing.decidedAt, risk: existing.risk, now: now)
    }
}

enum ApprovalMatch: Equatable, Sendable {
    case matches
    case stale
    case differentAction
    case differentRisk
}

enum ApprovalReuse {
    /// `granted` was approved for `binding` at `approvedAt`; may it authorise `requested` now?
    static func evaluate(granted: ApprovalBinding, approvedAt: Date?, requested: ApprovalBinding, now: Date) -> ApprovalMatch {
        if requested.risk > granted.risk { return .differentRisk }
        guard granted.digest == requested.digest else { return .differentAction }
        return ApprovalFreshness.mayReuse(approvedAt: approvedAt, risk: requested.risk, now: now) ? .matches : .stale
    }
}
