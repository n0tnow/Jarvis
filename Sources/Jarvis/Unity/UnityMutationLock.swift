import Foundation

/// One mutating Unity operation sequence per project at a time (DEC-053). Script edits, scene edits, compilation, tests and Play Mode
/// transitions all interact with the same editor state and domain reloads, so they take turns; correctness over parallelism.
/// Waiters are woken by `release` (event-driven) and give up on cancellation.
@MainActor
final class UnityMutationLock {
    struct Holder: Equatable, Sendable { var owner: String; var taskID: UUID; var since: Date }

    private var holders: [String: Holder] = [:]
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Void, Never> }
    private var waiters: [Waiter] = []

    static func key(_ root: String) -> String { UnityProcessScanner.canonical(root) }

    func holder(of root: String) -> Holder? { holders[Self.key(root)] }
    var heldCount: Int { holders.count }

    /// Re-entrant for the same owner. Returns false when the wait was cancelled (the lock is then NOT held).
    func acquire(root: String, taskID: UUID, owner: String) async -> Bool {
        let k = Self.key(root)
        while true {
            if let h = holders[k], h.owner != owner {
                if Task.isCancelled { return false }
                let id = UUID()
                await withTaskCancellationHandler {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        if Task.isCancelled { cont.resume() } else { waiters.append(Waiter(id: id, continuation: cont)) }
                    }
                } onCancel: {
                    Task { @MainActor in self.cancelWaiter(id) }
                }
                continue
            }
            holders[k] = Holder(owner: owner, taskID: taskID, since: Date())
            return true
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).continuation.resume()
    }

    func release(owner: String) {
        let before = holders.count
        holders = holders.filter { $0.value.owner != owner }
        if holders.count != before { wake() }
    }

    func release(taskID: UUID) {
        let before = holders.count
        holders = holders.filter { $0.value.taskID != taskID }
        if holders.count != before { wake() }
    }

    private func wake() {
        let all = waiters; waiters = []
        for w in all { w.continuation.resume() }
    }
}
