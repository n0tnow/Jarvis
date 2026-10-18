import Foundation

// MARK: - The vocabulary of a long-running task, derived from the states the engine already has (V1.0 background pass)
//
// The TaskEngine state machine has nine task states and ten step states. The concepts a person asks about after hours away — queued, waiting, waiting for a dependency, retrying, paused, blocked — are
// NOT extra states: they are derivable from what is already persisted (task state, step states, attempt counts, the pending approval, the failure category). Adding states would add transitions that
// must be proven; deriving them adds none. `TaskStatusDeriver` is that derivation, pure and tested, so "Nerede kaldın?" has one typed answer.
//   queued                → created / ready, nothing started
//   planning / ready / running / verifying / completed / failed / cancelled   → the engine's own
//   waitingForApproval    → the engine's own (task or step)
//   waitingForDependency  → running, nothing in flight, work remains whose dependencies are not yet satisfied (and nothing failed)
//   retrying              → a step is running with more than one attempt recorded
//   paused                → interrupted (JARVIS stopped; resume is an explicit user action) — there is no silent pause
//   blocked               → a REQUIRED step failed, or an approval was denied, and everything left depends on it

enum DerivedTaskStatus: String, Equatable, Sendable, CaseIterable {
    case queued, planning, ready, running, verifying, retrying, waitingForApproval, waitingForDependency, paused, blocked, completed, failed, cancelled
    var isFinal: Bool { self == .completed || self == .failed || self == .cancelled }
    var needsPerson: Bool { self == .waitingForApproval || self == .paused || self == .blocked }
}

struct DerivedTaskView: Equatable, Sendable {
    var status: DerivedTaskStatus
    var stepsTotal: Int
    var stepsPassed: Int
    var stepsMeasurable: Int
    var currentStepKey: String?
    var blockedBy: [String]
    /// Machine-readable reason for blocked / paused / waiting (never prose from a model).
    var reason: String?
}

enum TaskStatusDeriver {
    static func derive(task: TaskState, steps: [TaskStepRecord], failure: FailureCategory? = nil) -> DerivedTaskView {
        let measurable = steps.filter { $0.state != .skipped }
        let passed = steps.filter { $0.state == .passed }.count
        let current = steps.first { $0.state.isActive || $0.state == .waitingForApproval }?.key ?? steps.first { $0.state == .ready }?.key
        func view(_ s: DerivedTaskStatus, blockedBy: [String] = [], reason: String? = nil) -> DerivedTaskView {
            DerivedTaskView(status: s, stepsTotal: steps.count, stepsPassed: passed, stepsMeasurable: measurable.count, currentStepKey: current, blockedBy: blockedBy, reason: reason)
        }
        switch task {
        case .created: return view(.queued)
        case .planning: return view(.planning)
        case .ready: return view(.ready)
        case .completed: return view(.completed)
        case .cancelled: return view(.cancelled)
        case .failed: return view(.failed, reason: failure?.rawValue)
        case .interrupted: return view(.paused, reason: "interrupted: resume is an explicit action")
        case .waitingForApproval: return view(.waitingForApproval, blockedBy: steps.filter { $0.state == .waitingForApproval }.map(\.key))
        case .running:
            if steps.contains(where: { $0.state == .waitingForApproval }) { return view(.waitingForApproval, blockedBy: steps.filter { $0.state == .waitingForApproval }.map(\.key)) }
            let failedRequired = steps.filter { $0.state == .failed && !$0.optional }.map(\.key)
            if !failedRequired.isEmpty, !steps.contains(where: { $0.state.isActive }) { return view(.blocked, blockedBy: failedRequired, reason: "a required step failed") }
            if let s = steps.first(where: { $0.state == .running }), s.attempts > 1 { return view(.retrying, reason: "attempt \(s.attempts)") }
            if steps.contains(where: { $0.state == .verifying }) { return view(.verifying) }
            if steps.contains(where: { $0.state == .running }) { return view(.running) }
            let done = Set(steps.filter { $0.state == .passed || $0.state == .skipped || ($0.optional && $0.state == .failed) }.map(\.key))
            let waiting = steps.filter { ($0.state == .pending || $0.state == .ready) && !$0.dependsOn.allSatisfy(done.contains) }
            let startable = steps.contains { ($0.state == .pending || $0.state == .ready) && $0.dependsOn.allSatisfy(done.contains) }
            if !startable, !waiting.isEmpty { return view(.waitingForDependency, blockedBy: waiting.flatMap { $0.dependsOn.filter { !done.contains($0) } }.uniqued(), reason: "dependencies not satisfied") }
            return view(.running)
        }
    }
}

/// The transitions the engine must NEVER allow (a regression list kept as data; the test asserts every pair is rejected by `TaskStateMachine`).
enum ForbiddenTransitions {
    static let task: [(TaskState, TaskState)] = [
        (.completed, .running), (.completed, .planning), (.completed, .failed), (.completed, .cancelled), (.completed, .interrupted),
        (.failed, .running), (.failed, .completed), (.failed, .ready), (.failed, .planning),
        (.cancelled, .running), (.cancelled, .completed), (.cancelled, .planning), (.cancelled, .ready),
        (.waitingForApproval, .completed), (.waitingForApproval, .planning), (.waitingForApproval, .ready),
        (.created, .running), (.created, .completed), (.created, .waitingForApproval),
        (.ready, .completed), (.ready, .waitingForApproval), (.planning, .running), (.planning, .completed), (.planning, .waitingForApproval),
        (.running, .ready), (.running, .planning), (.running, .created),
    ]
    static let step: [(TaskStepState, TaskStepState)] = [
        (.passed, .running), (.passed, .failed), (.passed, .pending), (.failed, .passed), (.failed, .running), (.failed, .pending), (.cancelled, .running), (.cancelled, .passed),
        (.skipped, .running), (.skipped, .passed), (.pending, .running), (.pending, .passed), (.pending, .verifying), (.ready, .passed), (.ready, .verifying), (.pending, .waitingForApproval),
        (.waitingForApproval, .passed), (.waitingForApproval, .verifying), (.interrupted, .running), (.interrupted, .passed), (.interrupted, .verifying),
    ]
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}
