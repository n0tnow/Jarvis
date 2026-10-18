import Foundation

// MARK: - The bounded repair loop (V1.0 autonomous engineering pipeline)
//
//   IMPLEMENT → VERIFY → FAILURE → DIAGNOSE → CORRECT → VERIFY
//
// Every pass through the loop is counted against the assignment's budget (worker attempts, verification runs, provider requests — mapped onto the EXISTING `TaskBudgetLedger`, no second budget
// system). The loop stops when the work is verified, a budget is exhausted, the SAME failure repeats (a semantic signature: the same compiler error, test assertion or missing dependency, ignoring
// paths, line numbers, addresses and timestamps), an approval is required, architecture is uncertain, or no provider is available. Asking a worker to "fix it" without context is not an option:
// `RepairBrief` carries the objective, the actual diff summary, the failing check, bounded logs, the constraints and the attempt number — never hidden reasoning.

enum FailureKind: String, Codable, Sendable { case compile, test, missingDependency, scope, tampering, review, runtime, other }

struct FailureSignature: Hashable, Codable, Sendable {
    var kind: FailureKind
    var key: String
}

enum FailureNormalizer {
    private static let kinds: [(FailureKind, String)] = [
        (.missingDependency, #"(?:no such module|module not found|cannot find module|could not resolve package|modulenotfounderror|no module named|package .* not found|unresolved dependency|cannot find package)"#),
        (.test, #"(?:assertionerror|xctassert|\bfailed\b.*\btest|test(?:s)? failed|\bFAIL\b|expectation failed|expected .* but got|\bfailures?=[1-9])"#),
        (.compile, #"(?:\berror:|compilation failed|syntaxerror|cannot find '|expected [\w'\"`]+ (?:in|after)|use of unresolved identifier|undefined symbol|type .* has no member|build failed)"#),
    ]

    /// A semantic signature: same failure ⇒ same signature, whatever the paths, line numbers, hex addresses, durations or timestamps are.
    static func signature(from output: String, fallback: FailureKind = .other) -> FailureSignature {
        let lines = output.split(separator: "\n").map(String.init)
        let lower = output.lowercased()
        var kind = fallback
        for (k, p) in kinds where lower.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil { kind = k; break }
        let focus = lines.first { l in let x = l.lowercased(); return x.contains("error") || x.contains("fail") || x.contains("assert") || x.contains("no module") || x.contains("not found") } ?? lines.first ?? ""
        return FailureSignature(kind: kind, key: normalize(focus))
    }

    static func normalize(_ line: String) -> String {
        var s = line.lowercased()
        let rules: [(String, String)] = [
            (#"(?:/[\w.\-@+]+)+"#, "<path>"), (#"\b0x[0-9a-f]+\b"#, "<hex>"), (#"\b[0-9a-f]{7,40}\b"#, "<hash>"),
            (#"\b\d{4}-\d{2}-\d{2}[t ]\d{2}:\d{2}:\d{2}[\w.:+-]*"#, "<time>"), (#"\b\d+(?:\.\d+)?\s?(?:ms|s|sec|seconds)\b"#, "<dur>"),
            (#":\d+(?::\d+)?\b"#, ":<n>"), (#"\bline \d+\b"#, "line <n>"), (#"\b\d+\b"#, "<n>"), (#"\s+"#, " "),
        ]
        for (p, r) in rules { s = s.replacingOccurrences(of: p, with: r, options: .regularExpression) }
        return String(s.trimmingCharacters(in: .whitespaces).prefix(160))
    }
}

struct AttemptSummary: Codable, Equatable, Sendable {
    var number: Int
    var worker: String
    var outcome: String                   // machine-readable: "verified", "failed:compile", "scope", …
    var signature: FailureSignature?
    var filesChanged: Int
    var note: String                      // bounded, hygiene-checked, never reasoning
}

enum StopReason: String, Codable, Equatable, Sendable {
    case verified
    case workerAttemptsExhausted, verificationRunsExhausted, providerRequestsExhausted, wallClockExhausted
    case sameFailureRepeated
    case approvalRequired, architectureUncertain, providerUnavailable
    case securityFinding
    case regression
}

enum RepairDecision: Equatable, Sendable {
    /// Ask the same worker once more with a precise brief.
    case repair(RepairBrief)
    /// Hand over to another eligible worker (Auto only): the same failure repeated once.
    case escalate(RepairBrief, reason: String)
    case stop(StopReason)
    case done
}

struct RepairBrief: Equatable, Sendable {
    var objective: String
    var attempt: Int
    var maxAttempts: Int
    var diffSummary: String
    var failure: String
    var logs: String
    var constraints: [String]
    var protectedCriteria: [String]
    var previousAttempts: [String]

    static let maxCharacters = 5_000

    /// The text a worker receives for a correction: original objective, the ACTUAL diff, the failing check, bounded logs, constraints and the attempt number.
    func render() -> String {
        var lines = ["REPAIR ATTEMPT \(attempt) OF \(maxAttempts)", "OBJECTIVE: \(objective)"]
        lines.append("WHAT CHANGED SO FAR (observed, not reported):\n\(diffSummary)")
        lines.append("WHAT FAILED:\n\(failure)")
        if !logs.isEmpty { lines.append("RELEVANT LOG (bounded):\n\(logs)") }
        if !previousAttempts.isEmpty { lines.append("EARLIER ATTEMPTS:\n" + previousAttempts.suffix(4).map { "- \($0)" }.joined(separator: "\n")) }
        lines.append("STILL REQUIRED (do not regress):\n" + (protectedCriteria.isEmpty ? "- the original objective" : protectedCriteria.map { "- \($0)" }.joined(separator: "\n")))
        lines.append("CONSTRAINTS:\n" + (constraints + ["do not delete, skip or weaken any test to make it pass", "stay inside the allowed files"]).map { "- \($0)" }.joined(separator: "\n"))
        let text = lines.joined(separator: "\n\n")
        return text.count <= Self.maxCharacters ? text : String(text.prefix(Self.maxCharacters - 1)) + "…"
    }

    /// Bounded, sanitised log excerpt: the lines around the first failure marker, secrets and control characters removed.
    static func excerpt(of output: String, limit: Int = 1_800) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let marker = lines.firstIndex { let l = $0.lowercased(); return l.contains("error") || l.contains("fail") || l.contains("assert") } ?? 0
        let slice = lines[max(0, marker - 3)..<min(lines.count, marker + 25)].map { SecretGate.containsSecret($0) ? "[line withheld: credential-shaped]" : $0 }
        let cleaned = String(String.UnicodeScalarView(slice.joined(separator: "\n").unicodeScalars.map { $0 == "\n" || !CharacterSet.controlCharacters.contains($0) ? $0 : Unicode.Scalar(32) }))
        return String(cleaned.prefix(limit))
    }
}

/// Tracks which acceptance criteria held at the last verification, so a fix for one cannot silently break another.
struct AcceptanceTracker: Codable, Equatable, Sendable {
    private(set) var passing: Set<String> = []
    private(set) var everPassed: Set<String> = []

    /// Returns the criteria that PASSED before and fail now (regressions).
    mutating func update(failing: Set<String>, all: [String]) -> [String] {
        let nowPassing = Set(all).subtracting(failing)
        let regressed = passing.subtracting(nowPassing).sorted()
        passing = nowPassing; everPassed.formUnion(nowPassing)
        return regressed
    }
}

struct RepairLoop: Codable, Equatable, Sendable {
    var budget: EngineeringBudget
    private(set) var workerAttempts = 0
    private(set) var verificationRuns = 0
    private(set) var providerRequests = 0
    private(set) var activeSeconds: TimeInterval = 0
    private(set) var signatures: [FailureSignature: Int] = [:]
    private(set) var history: [AttemptSummary] = []
    private(set) var escalated = false
    private(set) var tracker = AcceptanceTracker()

    init(budget: EngineeringBudget) { self.budget = budget }

    mutating func noteWorkerAttempt(worker: String, providerRequests used: Int = 1) { workerAttempts += 1; providerRequests += used }
    /// A provider request that produced no worker result (a timeout): it costs request budget, not a worker attempt.
    mutating func noteProviderTimeout() { providerRequests += 1 }
    mutating func noteVerificationRun() { verificationRuns += 1 }
    mutating func addActive(_ s: TimeInterval) { activeSeconds += max(0, s) }

    /// The decision after a verification. `failureOutput` is the observed log of the failing check (empty when only findings failed).
    mutating func decide(verdict: VerificationVerdict, failureOutput: String, assignment: EngineeringAssignment, workerName: String, escalationAllowed: Bool, providerAvailable: Bool,
                         failing: Set<String> = [], diffSummary: String = "", now: Date? = nil) -> RepairDecision {
        let regressions = tracker.update(failing: failing.union(Set(verdict.unmetCriteria)), all: assignment.acceptance.map(\.id))
        if verdict.status == .verified || verdict.status == .verifiedAutomated {
            history.append(AttemptSummary(number: workerAttempts, worker: workerName, outcome: "verified", signature: nil, filesChanged: verdict.diffStats.files, note: ""))
            return .done
        }
        // stop conditions that no repair fixes
        if verdict.findings.contains(where: { [.secretIntroduced, .unsafeCommand, .guardWeakened].contains($0.code) && $0.severity == .blocker }) { return record(.stop(.securityFinding), verdict, workerName, nil) }
        if verdict.findings.contains(.architectureDrift) { return record(.stop(.architectureUncertain), verdict, workerName, nil) }
        if verdict.findings.contains(where: { $0.code == .userDirtyFileTouched || $0.code == .dependencyAdded && $0.severity == .blocker }) { return record(.stop(.approvalRequired), verdict, workerName, nil) }
        // budgets
        if workerAttempts >= budget.workerAttempts { return record(.stop(.workerAttemptsExhausted), verdict, workerName, nil) }
        if verificationRuns >= budget.verificationRuns { return record(.stop(.verificationRunsExhausted), verdict, workerName, nil) }
        if providerRequests >= budget.providerRequests { return record(.stop(.providerRequestsExhausted), verdict, workerName, nil) }
        if activeSeconds >= budget.wallClock { return record(.stop(.wallClockExhausted), verdict, workerName, nil) }
        // semantic repetition
        let sig = verdict.findings.first(where: { $0.severity == .blocker && $0.code != .criterionUnmet }).map { FailureSignature(kind: kindOf($0.code), key: FailureNormalizer.normalize("\($0.code.rawValue) \($0.path ?? "")")) }
            ?? FailureNormalizer.signature(from: failureOutput, fallback: .test)
        signatures[sig, default: 0] += 1
        let repeats = signatures[sig] ?? 0
        guard providerAvailable else { return record(.stop(.providerUnavailable), verdict, workerName, sig) }
        let brief = RepairBrief(objective: assignment.objective, attempt: workerAttempts + 1, maxAttempts: budget.workerAttempts, diffSummary: diffSummary.isEmpty ? "\(verdict.diffStats.files) file(s), +\(verdict.diffStats.linesAdded) −\(verdict.diffStats.linesRemoved)" : diffSummary,
                                failure: failureText(verdict, sig) + (regressions.isEmpty ? "" : "\nREGRESSION — these criteria passed before and fail now: " + regressions.joined(separator: ", ")), logs: RepairBrief.excerpt(of: failureOutput), constraints: assignment.constraints,
                                protectedCriteria: assignment.acceptance.filter { tracker.everPassed.contains($0.id) }.map { "[\($0.id)] \($0.text)" },
                                previousAttempts: history.map { "attempt \($0.number) (\($0.worker)): \($0.outcome)" })
        if repeats >= 3 { return record(.stop(.sameFailureRepeated), verdict, workerName, sig) }
        if repeats == 2 {
            if escalationAllowed, !escalated { escalated = true; return record(.escalate(brief, reason: "the same failure repeated: a different worker may see it differently"), verdict, workerName, sig) }
            return record(.stop(.sameFailureRepeated), verdict, workerName, sig)
        }
        return record(.repair(brief), verdict, workerName, sig)
    }

    private func kindOf(_ c: FindingCode) -> FailureKind {
        switch c {
        case .scopeEscape, .forbiddenPath, .protectedPath, .unexplainedChange: .scope
        case .testDeleted, .testSkipped, .assertionWeakened, .buildFailureSuppressed, .guardWeakened: .tampering
        case .unverifiedDependency, .dependencyAdded: .missingDependency
        default: .other
        }
    }

    private func failureText(_ v: VerificationVerdict, _ sig: FailureSignature) -> String {
        let blockers = v.findings.filter { $0.severity >= .major }.prefix(4).map { "\($0.severity.label) \($0.code.rawValue): \($0.message)" }
        var lines = ["failure class: \(sig.kind.rawValue)"]
        lines += blockers
        if !v.unmetCriteria.isEmpty { lines.append("unmet criteria: " + v.unmetCriteria.joined(separator: ", ")) }
        if !v.missingStages.isEmpty { lines.append("stages without a passing run: " + v.missingStages.map(\.rawValue).joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    @discardableResult
    private mutating func record(_ d: RepairDecision, _ v: VerificationVerdict, _ worker: String, _ sig: FailureSignature?) -> RepairDecision {
        var outcome = "failed"
        switch d { case .stop(let r): outcome = "stop:\(r.rawValue)"; case .repair: outcome = "failed:repair"; case .escalate: outcome = "failed:escalate"; case .done: outcome = "verified" }
        history.append(AttemptSummary(number: max(workerAttempts, 1), worker: worker, outcome: outcome, signature: sig, filesChanged: v.diffStats.files, note: ""))
        return d
    }
}
