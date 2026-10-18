import Foundation

// MARK: - Concurrent workers: write ownership, stale results, cancellation, partial work, handoff (V1.0 autonomous engineering pipeline)
//
// Parallel workers are only worth it when their tasks are independent. This is the lightweight, local, bounded counterpart of the engine's `FileLeaseManager` at the ASSIGNMENT level:
// an assignment that WRITES reserves its allowed paths; a second writer on an overlapping path must wait, be merged into the same task, or be coordinated explicitly — never silently
// overlap. Read-only assignments never conflict. A result is only trusted if the repository did not change underneath it (`StalenessCheck`); after a cancel no new write assignment may start
// (`AssignmentGate`) and a late result is discarded; partial work is classified, never called complete; a worker taking over receives facts (objective, actual state, failures), never reasoning.

enum OwnershipDecision: Equatable, Sendable {
    case granted
    /// Wait for these assignments to release (event-driven by the caller; the registry never polls).
    case wait(for: [UUID])
    /// Same owner and objective group: fold into the running assignment instead of racing it.
    case mergeInto(UUID)
    /// Waiting would deadlock or the overlap is partial: a person (or the planner) must coordinate.
    case needsCoordination([String])
    case denied(String)
}

struct Reservation: Codable, Equatable, Sendable {
    var assignment: UUID
    var owner: String
    var group: String
    var patterns: [String]
    var domains: Set<EngineeringDomain>
    var base: RevisionStamp?
    var waitsFor: Set<UUID> = []
}

struct OwnershipRegistry: Codable, Equatable, Sendable {
    private(set) var reservations: [UUID: Reservation] = [:]
    private(set) var cancelled: Set<UUID> = []
    static let maxReservations = 64

    mutating func request(_ a: EngineeringAssignment, owner: String, group: String = "") -> OwnershipDecision {
        if cancelled.contains(a.id) { return .denied("the assignment was cancelled") }
        guard !a.scope.isReadOnly else { return .granted }
        guard reservations.count < Self.maxReservations else { return .denied("too many concurrent write assignments") }
        let mine = a.scope.allowed
        let conflicting = reservations.values.filter { r in r.assignment != a.id && r.patterns.contains { p in mine.contains { PathGlob.mayOverlap(p, $0) } } }
        if conflicting.isEmpty {
            reservations[a.id] = Reservation(assignment: a.id, owner: owner, group: group, patterns: mine, domains: a.domains, base: a.base)
            return .granted
        }
        if let same = conflicting.first(where: { $0.owner == owner && !group.isEmpty && $0.group == group }) { return .mergeInto(same.assignment) }
        let blockers = Set(conflicting.map(\.assignment))
        // deadlock: a blocker (transitively) waits for me
        if blockers.contains(where: { waits($0, for: a.id) }) { return .needsCoordination(conflicting.flatMap(\.patterns).filter { p in mine.contains { PathGlob.mayOverlap(p, $0) } }.sorted()) }
        reservations[a.id] = Reservation(assignment: a.id, owner: owner, group: group, patterns: mine, domains: a.domains, base: a.base, waitsFor: blockers)
        return .wait(for: blockers.sorted { $0.uuidString < $1.uuidString })
    }

    private func waits(_ x: UUID, for target: UUID, depth: Int = 0) -> Bool {
        guard depth < 16, let r = reservations[x] else { return false }
        return r.waitsFor.contains(target) || r.waitsFor.contains { waits($0, for: target, depth: depth + 1) }
    }

    /// Releasing an assignment unblocks the writers that waited for it; returns the ones that may now proceed.
    mutating func release(_ id: UUID) -> [UUID] {
        reservations[id] = nil
        var ready: [UUID] = []
        for (k, var r) in reservations where r.waitsFor.contains(id) {
            r.waitsFor.remove(id); reservations[k] = r
            if r.waitsFor.isEmpty { ready.append(k) }
        }
        return ready.sorted { $0.uuidString < $1.uuidString }
    }

    mutating func cancel(_ id: UUID) -> [UUID] { cancelled.insert(id); return release(id) }

    /// Active holders (not waiting) of a path.
    func holder(of path: String) -> Reservation? { reservations.values.first { $0.waitsFor.isEmpty && $0.patterns.contains { PathGlob.matches($0, path) } } }
    var activeCount: Int { reservations.values.filter { $0.waitsFor.isEmpty }.count }
}

/// Domains that are usually independent and can safely run side by side when their path scopes do not overlap.
enum SafeParallelism {
    static func mayRunTogether(_ a: EngineeringAssignment, _ b: EngineeringAssignment) -> Bool {
        if a.scope.isReadOnly || b.scope.isReadOnly { return true }
        if a.dependsOn.contains(b.id) || b.dependsOn.contains(a.id) { return false }
        return !a.scope.allowed.contains { p in b.scope.allowed.contains { PathGlob.mayOverlap(p, $0) } }
    }
}

enum Staleness: Equatable, Sendable {
    case fresh
    /// Something in the worker's scope or read set changed after the assignment started: do not apply or declare it verified without re-inspection.
    case stale(changed: [String], overlapsScope: Bool)
    case headMoved(from: String?, to: String?)
}

enum StalenessCheck {
    /// `at` = the snapshot when the assignment started; `now` = the repository now; `readSet` = files the worker inspected (its claim — used only to WIDEN suspicion, never to narrow it).
    static func assess(startedAt: WorkspaceSnapshot, now: WorkspaceSnapshot, scope: WriteScope, readSet: [String] = [], ownChanges: Set<String> = []) -> Staleness {
        if let a = startedAt.git.head, let b = now.git.head, a != b { return .headMoved(from: a, to: b) }
        let changes = SnapshotDiff.between(startedAt, now).map(\.path).filter { !ownChanges.map(PathGlob.normalize).contains(PathGlob.normalize($0)) }
        let relevant = changes.filter { p in scope.allows(p) || readSet.contains { PathGlob.normalize($0) == PathGlob.normalize(p) } || scope.allowed.contains { PathGlob.mayOverlap($0, p) } }
        guard !relevant.isEmpty else { return .fresh }
        return .stale(changed: relevant.sorted(), overlapsScope: relevant.contains { scope.allows($0) })
    }
}

struct TaskLifecycleView: Equatable, Sendable {
    var cancelRequested: Bool
    var terminal: Bool
    var interrupted: Bool = false
}

enum AssignmentGate {
    /// No new write assignment after a cancel, a terminal state or an interruption; read-only work may still finish.
    static func mayIssueWrite(_ t: TaskLifecycleView, scope: WriteScope) -> Bool { scope.isReadOnly || !(t.cancelRequested || t.terminal || t.interrupted) }
    /// A worker result that arrives after a cancel is never applied.
    static func mayApplyResult(_ t: TaskLifecycleView) -> Bool { !(t.cancelRequested || t.terminal) }
}

/// A critical operation is not delegated to a worker at all unless its gate was released by a HUD decision.
enum DelegationPolicy {
    static func mayDelegate(_ a: EngineeringAssignment) -> Bool { a.risk < .critical || a.gateApproved }
}

enum PartialWork: String, Codable, Equatable, Sendable {
    /// Inside scope, no blocker, compiles at the current revision — but not complete.
    case usable
    /// A blocker, a scope escape, a failing build, or unexplained changes: not safe to keep applied.
    case unsafe
    /// No evidence either way.
    case unknown
}

enum PartialWorkClassifier {
    static func classify(verdict: VerificationVerdict, evidence: [VerificationEvidence], timedOut: Bool) -> PartialWork {
        if !verdict.findings.blockers.isEmpty || !verdict.attribution.unexplained.isEmpty { return .unsafe }
        let current = evidence.filter { $0.snapshotDigest == verdict.revision }
        if current.contains(where: { !$0.passed }) { return .unsafe }
        if verdict.diffStats.files == 0 { return .unknown }
        if current.contains(where: { $0.stage == .build && $0.passed }) { return .usable }
        _ = timedOut
        return .unknown
    }
}

enum WorkerHandoff {
    /// What a second worker receives: the objective, the ACTUAL current state, the failures and a short attempt history. No transcript, no reasoning.
    static func build(assignment: EngineeringAssignment, diffSummary: String, verdict: VerificationVerdict?, attempts: [AttemptSummary], maxCharacters: Int = 4_500) -> String {
        var lines = [assignment.promptBlock(maxCharacters: 1_800), "CURRENT STATE (observed): \(diffSummary)"]
        if let v = verdict {
            let top = v.findings.filter { $0.severity >= .major }.prefix(5).map { "- \($0.severity.label) \($0.code.rawValue)\($0.path.map { " (\($0))" } ?? ""): \($0.message)" }
            if !top.isEmpty { lines.append("OPEN FINDINGS:\n" + top.joined(separator: "\n")) }
            if !v.unmetCriteria.isEmpty { lines.append("UNMET CRITERIA: " + v.unmetCriteria.joined(separator: ", ")) }
        }
        if !attempts.isEmpty { lines.append("ATTEMPTS SO FAR:\n" + attempts.suffix(5).map { "- #\($0.number) \($0.worker): \($0.outcome)" }.joined(separator: "\n")) }
        let text = lines.joined(separator: "\n\n")
        return text.count <= maxCharacters ? text : String(text.prefix(maxCharacters - 1)) + "…"
    }
}
