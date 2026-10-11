import Foundation

/// Write ownership of project files (single-machine, in-memory authority + persisted rows for crash recovery).
/// Before a step writes a file it must hold the lease; a second writer WAITS (or is rejected) — two agents never edit the same file
/// blindly. Reading needs no lease. Leases are released when the step ends (pass, fail, cancel) and reconciled as stale after a crash.
@MainActor
final class FileLeaseManager {
    struct Conflict: Equatable, Sendable { var path: String; var holder: FileLeaseRecord }

    private(set) var leases: [String: FileLeaseRecord] = [:]       // key = normalized path
    private let repository: JarvisRepository?
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Void, Never> }
    private var waiters: [Waiter] = []

    init(repository: JarvisRepository?) { self.repository = repository }

    /// macOS volumes are case-insensitive by default: "A.cs" and "a.cs" are the same file.
    static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }

    private func conflicts(_ a: String, _ b: String) -> Bool { a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") }

    func holder(of path: String) -> FileLeaseRecord? {
        let k = Self.key(path)
        return leases.first { conflicts($0.key, k) }?.value
    }

    var activeCount: Int { leases.count }
    func leases(forTask id: UUID) -> [FileLeaseRecord] { leases.values.filter { $0.taskID == id } }

    /// All-or-nothing, re-entrant for the same owner. Returns the first conflict otherwise.
    func acquire(paths: [String], taskID: UUID, stepID: UUID?, owner: String) -> Conflict? {
        let keyed = paths.map { ($0, Self.key($0)) }
        for (path, k) in keyed {
            if let h = leases.first(where: { conflicts($0.key, k) && $0.value.owner != owner })?.value { return Conflict(path: path, holder: h) }
        }
        for (path, k) in keyed where leases[k] == nil {
            let l = FileLeaseRecord(path: path, taskID: taskID, stepID: stepID, owner: owner)
            leases[k] = l
            try? repository?.insertLease(l)
        }
        return nil
    }

    /// Waits until the paths can be leased (event-driven: woken by `release`, never polled). Cancellation returns the last conflict.
    func acquireWaiting(paths: [String], taskID: UUID, stepID: UUID?, owner: String) async -> Conflict? {
        while true {
            guard let conflict = acquire(paths: paths, taskID: taskID, stepID: stepID, owner: owner) else { return nil }
            if Task.isCancelled { return conflict }
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    if Task.isCancelled { cont.resume() } else { waiters.append(Waiter(id: id, continuation: cont)) }
                }
            } onCancel: {
                Task { @MainActor in self.cancelWaiter(id) }
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).continuation.resume()
    }

    func release(owner: String) {
        let before = leases.count
        leases = leases.filter { $0.value.owner != owner }
        try? repository?.releaseLeases(owner: owner)
        if leases.count != before { wake() }
    }

    func release(taskID: UUID) {
        let before = leases.count
        leases = leases.filter { $0.value.taskID != taskID }
        try? repository?.releaseLeases(taskID: taskID)
        if leases.count != before { wake() }
    }

    private func wake() {
        let all = waiters; waiters = []
        for w in all { w.continuation.resume() }
    }

    /// Launch: every persisted active lease belongs to a dead process.
    @discardableResult
    func reconcileStale() -> Int { (try? repository?.markStaleLeases()) ?? 0 }
}
