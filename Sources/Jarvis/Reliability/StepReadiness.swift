import Foundation

// MARK: - Which steps may start (pure; the engine's `readySteps` delegates here)
//
// A step starts only when EVERY dependency has finished well: passed, skipped, or an OPTIONAL step that failed. A dependency that failed, was cancelled or was interrupted blocks all of its dependents —
// "build failed → deploy runs anyway" and "download failed → import claims success" cannot happen, because the dependent is never ready. Pure, so the rule can be proven without an engine.

enum StepReadiness {
    static func satisfied(_ steps: [TaskStepRecord]) -> Set<String> {
        Set(steps.filter { $0.state == .passed || $0.state == .skipped || ($0.optional && $0.state == .failed) }.map(\.key))
    }

    static func ready(_ steps: [TaskStepRecord]) -> [TaskStepRecord] {
        let done = satisfied(steps)
        return steps.filter { ($0.state == .pending || $0.state == .ready) && $0.dependsOn.allSatisfy(done.contains) }
    }

    /// Steps that can never run because a dependency (transitively) failed required, was cancelled or interrupted.
    static func blockedByFailure(_ steps: [TaskStepRecord]) -> Set<String> {
        var dead = Set(steps.filter { ($0.state == .failed && !$0.optional) || $0.state == .cancelled || $0.state == .interrupted }.map(\.key))
        var changed = true
        while changed {
            changed = false
            for s in steps where !dead.contains(s.key) && !s.state.isTerminal && s.dependsOn.contains(where: dead.contains) { dead.insert(s.key); changed = true }
        }
        return dead.subtracting(steps.filter { $0.state == .failed || $0.state == .cancelled || $0.state == .interrupted }.map(\.key))
    }

    /// Steps that can run NOW although another branch waits for an approval or has stopped: ready, and independent of every unfinished-or-failed step that is blocked.
    static func independentWhileBlocked(_ steps: [TaskStepRecord]) -> [TaskStepRecord] {
        let stuck = Set(steps.filter { $0.state == .waitingForApproval || $0.state == .interrupted || ($0.state == .failed && !$0.optional) }.map(\.key))
        guard !stuck.isEmpty else { return ready(steps) }
        var tainted = stuck
        var changed = true
        while changed { changed = false; for s in steps where !tainted.contains(s.key) && s.dependsOn.contains(where: tainted.contains) { tainted.insert(s.key); changed = true } }
        return ready(steps).filter { !tainted.contains($0.key) }
    }
}
