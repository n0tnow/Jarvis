import Foundation

// MARK: - Per-task budgets (V1.0 background pass)
//
// A long task needs limits that stop a RUNAWAY loop without being small enough to stop honest work. The existing engine bounds wall clock (graph timeout) and per-step repair; this adds the dimensions that
// were missing: model requests, provider retries, tool failures and CONSECUTIVE verification failures. The defaults are deliberately generous (a night of work fits); hitting one is not a failure of the
// task — it is a CHECKPOINT and a block, with the dimension named, so a person decides whether to raise it. Pure value logic; the engine feeds the counters.

enum BudgetDimension: String, Equatable, Sendable, CaseIterable {
    case wallClock, modelRequests, providerRetries, toolFailures, consecutiveVerificationFailures
}

struct TaskBudget: Equatable, Sendable {
    var wallClock: TimeInterval = 10 * 3600
    var modelRequests = 400
    var providerRetries = 40
    var toolFailures = 60
    var consecutiveVerificationFailures = 6
    /// Warn when a counter reaches this share of its limit (the activity feed says so once; nothing stops yet).
    var warnAt = 0.8

    func limit(_ d: BudgetDimension) -> Double {
        switch d {
        case .wallClock: wallClock; case .modelRequests: Double(modelRequests); case .providerRetries: Double(providerRetries)
        case .toolFailures: Double(toolFailures); case .consecutiveVerificationFailures: Double(consecutiveVerificationFailures)
        }
    }
}

enum TaskBudgetVerdict: Equatable, Sendable {
    case ok
    case warn(BudgetDimension, used: Double, limit: Double)
    /// Stop starting new work: checkpoint, block, report which dimension ran out.
    case exhausted(BudgetDimension, used: Double, limit: Double)
    var isExhausted: Bool { if case .exhausted = self { return true }; return false }
}

struct TaskBudgetLedger: Equatable, Sendable {
    var budget = TaskBudget()
    private(set) var activeSeconds: TimeInterval = 0
    private(set) var modelRequests = 0
    private(set) var providerRetries = 0
    private(set) var toolFailures = 0
    private(set) var consecutiveVerificationFailures = 0
    private var warned: Set<BudgetDimension> = []

    init(budget: TaskBudget = TaskBudget()) { self.budget = budget }

    mutating func addActive(_ seconds: TimeInterval) { activeSeconds += max(0, seconds) }
    mutating func noteModelRequest() { modelRequests += 1 }
    mutating func noteProviderRetry() { providerRetries += 1 }
    mutating func noteToolFailure() { toolFailures += 1 }
    /// A verification that PASSED resets the streak; a failure extends it.
    mutating func noteVerification(passed: Bool) { consecutiveVerificationFailures = passed ? 0 : consecutiveVerificationFailures + 1 }

    func used(_ d: BudgetDimension) -> Double {
        switch d {
        case .wallClock: activeSeconds; case .modelRequests: Double(modelRequests); case .providerRetries: Double(providerRetries)
        case .toolFailures: Double(toolFailures); case .consecutiveVerificationFailures: Double(consecutiveVerificationFailures)
        }
    }

    /// The first exhausted dimension (in a fixed order), else the first new warning, else ok. A warning is reported ONCE per dimension.
    mutating func check() -> TaskBudgetVerdict {
        for d in BudgetDimension.allCases where used(d) >= budget.limit(d) { return .exhausted(d, used: used(d), limit: budget.limit(d)) }
        for d in BudgetDimension.allCases where used(d) >= budget.limit(d) * budget.warnAt && !warned.contains(d) { warned.insert(d); return .warn(d, used: used(d), limit: budget.limit(d)) }
        return .ok
    }
}
