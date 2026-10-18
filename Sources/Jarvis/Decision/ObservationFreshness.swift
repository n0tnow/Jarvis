import Foundation

// MARK: - One freshness policy for every "right now" claim (V1.0 reliability pass)
//
// A statement about the PRESENT — "Safari is on screen", "the task is running", "the microphone is on" — is only as good as the observation behind it. Each kind of observation has ONE time-to-live,
// here, instead of a number scattered at every call site. An observation older than its TTL may still be mentioned as history ("my last observation, 40 s ago, showed …"), never as present fact.
// Pure: no clock of its own, nothing is probed.

enum ObservationKind: String, CaseIterable, Sendable {
    /// What a Computer Use observation saw on screen.
    case screenVisibility
    /// A single application's window in that observation.
    case appVisibility
    /// The application / process list (cheap to re-read: the answer re-reads it, so a short TTL).
    case processRunning
    /// The registry / Git / Unity facts about a project.
    case projectState
    /// The task engine's state for a task (live in memory).
    case taskState
    case voicePipeline
    case providerReadiness
    case permission
}

enum FreshnessVerdict: Equatable, Sendable {
    case fresh(ageSeconds: Int)
    case stale(ageSeconds: Int)
    case never
    var mayClaimAsPresent: Bool { if case .fresh = self { return true }; return false }
}

struct ObservationFreshnessPolicy: Equatable, Sendable {
    var ttl: [ObservationKind: TimeInterval] = [
        .screenVisibility: 20, .appVisibility: 20, .processRunning: 5, .projectState: 60, .taskState: 5, .voicePipeline: 10, .providerReadiness: 120, .permission: 30,
    ]

    static let standard = ObservationFreshnessPolicy()

    func ttl(for kind: ObservationKind) -> TimeInterval { ttl[kind] ?? 0 }

    func verdict(_ kind: ObservationKind, observedAt: Date?, now: Date) -> FreshnessVerdict {
        guard let observedAt else { return .never }
        let age = max(0, now.timeIntervalSince(observedAt))
        return age <= ttl(for: kind) ? .fresh(ageSeconds: Int(age)) : .stale(ageSeconds: Int(age))
    }

    func isFresh(_ kind: ObservationKind, ageSeconds: TimeInterval) -> Bool { ageSeconds >= 0 && ageSeconds <= ttl(for: kind) }
}
