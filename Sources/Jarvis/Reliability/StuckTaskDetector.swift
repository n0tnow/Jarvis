import Foundation

// MARK: - Deterministic stuck-task detection (V1.0 reliability pass)
//
// "Is this task stuck?" is answered from MEASURABLE state only — never by asking a language model and never by guessing:
//   · how long since the step last CHANGED STATE, since the provider last PRODUCED OUTPUT, since the project folder or a managed process last CHANGED;
//   · the same failure signature repeating;
//   · a provider that is unavailable (cooling down / circuit open).
// A task waiting for a person (an approval) is NOT stuck: waiting is a legitimate state with its own report. The detector returns one verdict and, when stuck, ONE recommended outcome, chosen by a fixed
// order: retry once → fall back to another provider (only when the user's routing mode allows it, never to a paid one) → pause → ask the user → fail honestly. Every outcome is bounded: a task is never
// retried forever, and "fail honestly" always ends with a reason a person can read. Pure: no clock of its own, no timers, nothing runs while idle (the engine evaluates it at events and when a
// supervised step times out).

struct TaskLiveness: Equatable, Sendable {
    enum Phase: String, Sendable { case planning, runningProvider, runningTool, verifying, waitingForApproval, waitingForCapacity, other }
    var phase: Phase
    var now: Date
    var lastTransitionAt: Date
    /// When a provider last streamed output for the current step (nil = none yet).
    var lastOutputAt: Date?
    /// The latest modification seen in the project folder / a managed process's activity (nil = none observed).
    var lastObservedChangeAt: Date?
    /// How many times the SAME failure signature repeated for this step.
    var identicalFailures = 0
    /// Retries already spent on this step.
    var retriesUsed = 0
    var providerAvailable = true
    /// Another provider may be tried (the user's routing mode is Auto and a non-paid candidate remains).
    var fallbackAvailable = false
    var userPresent = true
}

struct StuckPolicy: Equatable, Sendable {
    /// A provider step with no state change at all for this long is suspect (the provider timeout is 600 s, so this is a bit longer than one full timeout).
    var noTransition: TimeInterval = 15 * 60
    /// A running provider that has produced no output for this long (streams normally emit within seconds).
    var noOutput: TimeInterval = 4 * 60
    /// A tool / build with neither a state change nor an observed change for this long.
    var noToolActivity: TimeInterval = 10 * 60
    var maxRetries = 1
    var identicalFailureLimit = 2
}

enum StuckAction: String, Equatable, Sendable {
    case retry, fallbackProvider, pause, askUser, failHonestly
}

enum StuckReason: String, Equatable, Sendable {
    case noStateChange, noProviderOutput, noToolActivity, repeatedIdenticalFailure, providerUnavailable
}

enum StuckVerdict: Equatable, Sendable {
    case healthy
    /// Waiting for a person or for capacity: legitimate, reported as such, never "stuck".
    case waiting
    case suspect([StuckReason])
    case stuck([StuckReason], StuckAction)

    var isStuck: Bool { if case .stuck = self { return true }; return false }
}

enum StuckTaskDetector {
    static func evaluate(_ l: TaskLiveness, policy p: StuckPolicy = StuckPolicy()) -> StuckVerdict {
        if l.phase == .waitingForApproval || l.phase == .waitingForCapacity { return .waiting }
        var reasons: [StuckReason] = []
        let sinceTransition = l.now.timeIntervalSince(l.lastTransitionAt)
        if l.identicalFailures >= p.identicalFailureLimit { reasons.append(.repeatedIdenticalFailure) }
        if !l.providerAvailable, l.phase == .runningProvider || l.phase == .planning { reasons.append(.providerUnavailable) }
        switch l.phase {
        case .runningProvider:
            let quietSince = l.lastOutputAt ?? l.lastTransitionAt
            if l.now.timeIntervalSince(quietSince) >= p.noOutput { reasons.append(.noProviderOutput) }
            if sinceTransition >= p.noTransition { reasons.append(.noStateChange) }
        case .runningTool, .verifying:
            let active = [l.lastTransitionAt, l.lastObservedChangeAt].compactMap { $0 }.max() ?? l.lastTransitionAt
            if l.now.timeIntervalSince(active) >= p.noToolActivity { reasons.append(.noToolActivity) }
        case .planning, .other:
            if sinceTransition >= p.noTransition { reasons.append(.noStateChange) }
        case .waitingForApproval, .waitingForCapacity: break
        }
        guard !reasons.isEmpty else { return .healthy }
        // a lone "no output yet" within the first moments of a long job is only a suspicion
        let hard = reasons.contains(.repeatedIdenticalFailure) || reasons.contains(.providerUnavailable) || reasons.contains(.noStateChange) || reasons.contains(.noToolActivity) || reasons.contains(.noProviderOutput)
        guard hard else { return .suspect(reasons) }
        return .stuck(reasons, action(for: reasons, l, p))
    }

    /// The fixed order of outcomes. Bounded: a retry budget, a fallback that must exist, then pause / ask / fail.
    static func action(for reasons: [StuckReason], _ l: TaskLiveness, _ p: StuckPolicy) -> StuckAction {
        if reasons.contains(.providerUnavailable) {
            if l.fallbackAvailable { return .fallbackProvider }
            return l.userPresent ? .askUser : .pause                       // nothing else can serve it: pause (unattended) or tell the person
        }
        if reasons.contains(.repeatedIdenticalFailure) {
            // the same thing failed the same way: another try of the same thing is pointless
            if l.fallbackAvailable { return .fallbackProvider }
            return l.userPresent ? .askUser : .failHonestly
        }
        if l.retriesUsed < p.maxRetries { return .retry }
        if l.fallbackAvailable { return .fallbackProvider }
        return l.userPresent ? .askUser : .failHonestly
    }
}
