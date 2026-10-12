import Foundation

/// V0.6 — who may fail a task (DEC-050). Deterministic facts (compile, tests, expected editor state, scope, destructive-action gates)
/// outrank a model's opinion in BOTH directions: a failing hard validator is never rescued by an optimistic review, and a validated
/// result is never turned into FAILED by a reviewer that merely dislikes it. A reviewer can still fail a task with a CONCRETE,
/// VERIFIABLE defect (it names evidence that really appears in the diff / validation record) or when the user asked for a review gate.
enum IssueSeverity: String, Codable, Sendable { case blocking, advice }

struct ReviewIssue: Equatable, Sendable {
    var text: String
    var severity: IssueSeverity
    /// What the reviewer points at: a quote from the diff, a changed path, or a validation line. Verified by JARVIS, not trusted.
    var evidence: String
}

enum ReviewAuthority {
    static let advisoryPrefix = "Review advice (not blocking):"

    /// Validations that are facts about the project, produced by JARVIS' own tools (never by a model).
    static let hardKinds: Set<ValidationKind> = [.buildPass, .testPass, .unityCompiled, .unityTestsPass, .unityState, .unityPlayObserved]

    enum Decision: Equatable {
        case pass
        case advisory(String)          // the step passes; the advice is kept in the report
        case fail(String)
    }

    /// Words in a task constraint that mean "the review must pass" (an explicit review gate).
    static func isGate(constraints: [String]) -> Bool {
        constraints.contains { c in
            let l = c.lowercased()
            return l.contains("review gate") || l.contains("review must pass") || l.contains("require review") || l.contains("reviewgate")
        }
    }

    static func hardValidationPassed(steps: [TaskStepRecord]) -> Bool {
        steps.contains { $0.state == .passed && hardKinds.contains($0.validation) }
    }

    /// A blocking issue only counts when its evidence is something JARVIS can find in what it actually recorded.
    static func isVerifiable(_ issue: ReviewIssue, diff: String, evidence: [String], changedPaths: [String]) -> Bool {
        guard issue.severity == .blocking else { return false }
        let e = issue.evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard e.count >= 6 else { return false }
        if diff.contains(e) { return true }
        if changedPaths.contains(where: { e.contains($0) || $0.contains(e) }) { return true }
        return evidence.contains { $0.contains(e) }
    }

    static func decide(review: ReviewResult, hardPassed: Bool, gate: Bool, diff: String, evidence: [String], changedPaths: [String]) -> Decision {
        if review.passed { return .pass }
        let verified = review.detailed.filter { isVerifiable($0, diff: diff, evidence: evidence, changedPaths: changedPaths) }
        if !verified.isEmpty || gate || !hardPassed {
            let why = (verified.isEmpty ? review.issues : verified.map(\.text)).prefix(3).joined(separator: "; ")
            return .fail("The review found problems: " + (why.isEmpty ? (review.summary.isEmpty ? "unspecified" : review.summary) : why))
        }
        let advice = (review.issues.isEmpty ? [review.summary] : review.issues).filter { !$0.isEmpty }.prefix(3).joined(separator: "; ")
        return .advisory(advisoryPrefix + " " + (advice.isEmpty ? "the reviewer disliked the change but named no verifiable defect" : advice))
    }
}
