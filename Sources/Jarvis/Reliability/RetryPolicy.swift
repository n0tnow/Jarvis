import Foundation

// MARK: - Retry classification, deterministic backoff and a TASK-level retry budget (V1.0 background pass)
//
// The engine already bounds repair (1 per step), escalation (1) and capacity waits (40). What it lacks is ONE answer to "is this failure worth another try?" and a budget that spans the WHOLE task, so
// step A retrying five times, step B five times and step C five times cannot silently burn a night. Every retry is bounded, classified and observable (`RetryDecision` carries the class and the reason).
//   transient / network / timeout / rate limit → bounded exponential backoff (capped), counted against the step AND the task budget
//   deterministic validation failure           → one repair attempt at most (the engine's own), never a blind repeat
//   permission / approval / invalid input / permanent / security → NEVER retried: blocked or failed honestly
//   cancelled / interrupted                    → never retried automatically (resume is an explicit action)

enum RetryClass: String, Equatable, Sendable, CaseIterable {
    case transient, rateLimited, timeout, network, deterministicValidation, permission, approvalRequired, invalidInput, permanent, cancelled
    var isRetryableAutomatically: Bool { [.transient, .rateLimited, .timeout, .network].contains(self) }
}

enum RetryClassifier {
    static func classify(_ c: FailureCategory) -> RetryClass {
        switch c {
        case .providerUnavailable, .resourceUnavailable, .unityUnavailable, .downloadFailed: return .transient
        case .providerRateLimited: return .rateLimited
        case .unityTimeout, .computerTimeout: return .timeout
        case .networkUnavailable: return .network
        case .validationFailed, .buildFailed, .testFailed, .compileFailed, .toolFailed, .computerActionFailed, .providerFailed: return .deterministicValidation
        case .permissionRequired, .capabilityDenied, .blockedByNetworkPolicy: return .permission
        case .approvalDenied, .interactionRequired: return .approvalRequired
        case .malformedPlan, .ambiguousTarget, .noSources, .scopeExceeded: return .invalidInput
        case .workspaceViolation, .securityBlocked, .workspaceChanged, .unsafeEditorState, .acquisitionRefused: return .permanent
        case .cancelled, .interrupted: return .cancelled
        }
    }
}

struct RetryPolicy: Equatable, Sendable {
    var baseDelay: TimeInterval = 2
    var factor = 2.0
    var maxDelay: TimeInterval = 60
    /// Retries per STEP for the automatically retryable classes (transient, network, timeout); rate limits get fewer and a longer wait.
    var perStep = 3
    var perStepRateLimited = 2
    /// Retries per TASK across all steps.
    var perTask = 12
    /// ±fraction of the delay, derived from a seed so a test controls it exactly (0 = no jitter).
    var jitterFraction = 0.2
}

enum RetryDecision: Equatable, Sendable {
    case retry(after: TimeInterval, attempt: Int, cls: RetryClass)
    /// Not retried: the reason is machine-readable.
    case giveUp(RetryClass, GiveUpReason)
}

enum GiveUpReason: String, Equatable, Sendable {
    case notRetryable, stepBudgetExhausted, taskBudgetExhausted
    /// What the engine should do next: pause for the person, fail honestly, or hand to the repair path.
    var recommendation: String { self == .notRetryable ? "block-or-fail" : "checkpoint-and-pause" }
}

/// Mutable ledger of retries for ONE task. Value type; the engine owns one per task context.
struct RetryLedger: Equatable, Sendable {
    private(set) var perStep: [String: Int] = [:]
    private(set) var total = 0
    var policy = RetryPolicy()
    var seed: UInt64 = 0

    init(policy: RetryPolicy = RetryPolicy(), seed: UInt64 = 0) { self.policy = policy; self.seed = seed }

    /// Decides AND records. `stepKey` identifies the step; a seeded jitter keeps the schedule reproducible.
    mutating func decide(step stepKey: String, failure: FailureCategory) -> RetryDecision {
        let cls = RetryClassifier.classify(failure)
        guard cls.isRetryableAutomatically else { return .giveUp(cls, .notRetryable) }
        let used = perStep[stepKey, default: 0]
        let limit = cls == .rateLimited ? policy.perStepRateLimited : policy.perStep
        guard used < limit else { return .giveUp(cls, .stepBudgetExhausted) }
        guard total < policy.perTask else { return .giveUp(cls, .taskBudgetExhausted) }
        perStep[stepKey] = used + 1; total += 1
        var delay = min(policy.maxDelay, policy.baseDelay * pow(policy.factor, Double(used)) * (cls == .rateLimited ? 2 : 1))
        if policy.jitterFraction > 0 {
            var h = seed ^ 0x9E3779B97F4A7C15
            for b in stepKey.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
            h = (h ^ UInt64(used + 1)) &* 0x100000001b3
            let unit = Double(h % 10_000) / 10_000.0 * 2 - 1                    // −1 … 1, deterministic
            delay = min(policy.maxDelay, max(0, delay * (1 + unit * policy.jitterFraction)))
        }
        return .retry(after: delay, attempt: used + 1, cls: cls)
    }

    func used(_ stepKey: String) -> Int { perStep[stepKey, default: 0] }
    var remaining: Int { max(0, policy.perTask - total) }
}
