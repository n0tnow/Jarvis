import Foundation

/// Lifecycle of a task. `waiting` means "blocked on a human approval".
enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case queued, running, paused, waiting, completed, failed, cancelled
    /// V0.4: an autonomous task whose process died (restart/crash); the user decides to resume or stop it.
    case interrupted

    var label: String {
        switch self {
        case .queued: "QUEUED"
        case .running: "RUNNING"
        case .paused: "PAUSED"
        case .waiting: "AWAITING APPROVAL"
        case .completed: "COMPLETED"
        case .failed: "FAILED"
        case .cancelled: "STOPPED"
        case .interrupted: "INTERRUPTED"
        }
    }

    /// Compact label for dense rows.
    var shortLabel: String { self == .waiting ? "APPROVAL" : label }

    var symbolName: String {
        switch self {
        case .queued: "clock"
        case .running: "play.fill"
        case .paused: "pause.fill"
        case .waiting: "hand.raised.fill"
        case .completed: "checkmark"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "stop.fill"
        case .interrupted: "bolt.slash.fill"
        }
    }

    /// An "active" task is one the user can still pause/resume/stop.
    var isActive: Bool { self == .running || self == .paused || self == .waiting || self == .interrupted }
}

enum StepStatus: String, Codable, CaseIterable, Sendable {
    case pending, active, completed, failed

    var label: String {
        switch self {
        case .pending: "Pending"
        case .active: "In progress"
        case .completed: "Done"
        case .failed: "Failed"
        }
    }

    var symbolName: String {
        switch self {
        case .pending: "circle"
        case .active: "circle.dotted.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }
}

struct TaskStep: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var status: StepStatus
}

/// V0.4: facts only the autonomous engine knows. Present ⇒ the task is engine-owned (state changes only through `TaskEngine`).
struct EngineTaskInfo: Codable, Hashable, Sendable {
    /// Real progress (validated steps / steps) — nil while there is no plan yet. Never provider text.
    var progressFraction: Double?
    var activity: String
    var activeAgents: Int
    var failureReason: String?
    var summary: String?
    var stepCount: Int
}

/// UI-facing task representation. Plain Codable value type so a SQLite (or any)
/// persistence layer can be added later without touching views.
struct JarvisTask: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var title: String
    /// The brief's "description" (named `details` to avoid colliding with `CustomStringConvertible`).
    var details: String
    var status: TaskStatus
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var steps: [TaskStep]

    /// Active run time is accumulated so pausing actually stops the clock.
    var accumulatedRunTime: TimeInterval = 0
    var runningSince: Date?
    /// V0.4 autonomous task information (nil for the V0.1 demo task).
    var engine: EngineTaskInfo?

    // MARK: Derived from steps — never invented

    var currentStep: TaskStep? {
        steps.first { $0.status == .active } ?? steps.first { $0.status == .pending }
    }

    /// 1-based position of `currentStep`, if any.
    var currentStepNumber: Int? {
        guard let current = currentStep, let idx = steps.firstIndex(where: { $0.id == current.id }) else { return nil }
        return idx + 1
    }

    var completedStepCount: Int { steps.filter { $0.status == .completed }.count }

    /// Fraction of steps completed (0...1). Derived purely from step statuses.
    var progress: Double {
        steps.isEmpty ? 0 : Double(completedStepCount) / Double(steps.count)
    }

    func elapsed(at now: Date) -> TimeInterval {
        accumulatedRunTime + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    // MARK: Transitions

    mutating func pause(at now: Date = .now) {
        guard status == .running else { return }
        settleClock(at: now)
        status = .paused
    }

    mutating func resume(at now: Date = .now) {
        guard status == .paused || status == .waiting || status == .queued else { return }
        if startedAt == nil { startedAt = now }
        runningSince = now
        status = .running
    }

    mutating func awaitApproval(at now: Date = .now) {
        guard status == .running else { return }
        settleClock(at: now)
        status = .waiting
    }

    mutating func cancel(at now: Date = .now) {
        guard status.isActive else { return }
        settleClock(at: now)
        status = .cancelled
        completedAt = now
    }

    /// Marks every step done and the task completed.
    mutating func complete(at now: Date = .now) {
        guard status.isActive else { return }
        settleClock(at: now)
        for i in steps.indices { steps[i].status = .completed }
        status = .completed
        completedAt = now
    }

    /// Fails the task; the step that was in progress (or the next pending one) is marked failed.
    mutating func fail(at now: Date = .now) {
        guard status.isActive else { return }
        settleClock(at: now)
        if let idx = steps.firstIndex(where: { $0.status == .active }) ?? steps.firstIndex(where: { $0.status == .pending }) {
            steps[idx].status = .failed
        }
        status = .failed
        completedAt = now
    }

    private mutating func settleClock(at now: Date) {
        if let since = runningSince { accumulatedRunTime += max(0, now.timeIntervalSince(since)) }
        runningSince = nil
    }
}
