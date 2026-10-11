import Foundation

/// Who/what started a task (V0.5). Persisted on the task and shown in the HUD so a user task can always be told apart from
/// JARVIS' own initiative.
enum TaskOrigin: String, Codable, Sendable {
    case userTask
    case proactiveAutoAction        // policy-approved low-risk action (Low-Risk Autonomous mode)
    case approvedProposal           // the user approved a proposal

    var label: String {
        switch self { case .userTask: "USER TASK"; case .proactiveAutoAction: "JARVIS AUTO TASK"; case .approvedProposal: "APPROVED PROPOSAL" }
    }
    var isProactive: Bool { self != .userTask }
}

/// The scope a proactive task was approved for (or auto-authorised for). A user task has none: the user's own goal is the scope.
/// Enforced twice by the engine: the PLAN may not exceed it (step types, step count, deletes) and every EDIT must stay inside it
/// (paths, number of changed files). Approval grants scope; it never bypasses V0.4 safety.
struct TaskScope: Codable, Equatable, Sendable {
    var allowedStepTypes: Set<StepType>
    /// Workspace-relative files or directory prefixes that may be changed. Empty = no path restriction (still inside the workspace).
    var pathPrefixes: [String] = []
    /// Only test files may be changed (regression-test proposals).
    var testFilesOnly = false
    var maxChangedFiles = 2
    var maxSteps = 8
    var allowDelete = false

    static func isTestPath(_ path: String) -> Bool {
        let comps = path.split(separator: "/").map(String.init)
        if comps.dropLast().contains(where: { ["test", "tests", "spec", "specs", "__tests__", "unittests", "uitests"].contains($0.lowercased()) }) { return true }
        guard let base = comps.last else { return false }
        // tokenise the file stem (snake_case, dots, camelCase): "CalcTests.cs", "test_calc.py", "foo.test.js", "calc_test.go" are tests; "latest.py" is not
        var tokens: [String] = [], word = ""
        let chars = Array(base)
        for (i, ch) in chars.enumerated() {
            if ch.isLetter || ch.isNumber {
                if ch.isUppercase, i > 0, chars[i - 1].isLowercase, !word.isEmpty { tokens.append(word.lowercased()); word = "" }
                word.append(ch)
            } else if !word.isEmpty { tokens.append(word.lowercased()); word = "" }
        }
        if !word.isEmpty { tokens.append(word.lowercased()) }
        return tokens.contains { ["test", "tests", "spec", "specs"].contains($0) }
    }

    func allowsPath(_ path: String) -> Bool {
        if testFilesOnly && !Self.isTestPath(path) { return false }
        if pathPrefixes.isEmpty { return true }
        let p = path.lowercased()
        return pathPrefixes.contains { pre in
            let q = pre.lowercased()
            return p == q || p.hasPrefix(q.hasSuffix("/") ? q : q + "/")
        }
    }

    /// Human-readable reasons a plan exceeds the scope (empty = within scope).
    func planViolations(_ plan: TaskPlan) -> [String] {
        var out: [String] = []
        if plan.steps.count > maxSteps { out.append("the plan has \(plan.steps.count) steps; the approved scope allows \(maxSteps)") }
        for s in plan.steps {
            if !allowedStepTypes.contains(s.type) { out.append("step \(s.id) (\(s.type.rawValue)) is outside the approved scope") }
            if s.type == .delete && !allowDelete { out.append("step \(s.id) deletes files, which this approval does not cover") }
        }
        return out
    }

    /// Violations of changing `paths` (a single edit set).
    func editViolations(_ paths: [String], alreadyChanged: Int = 0) -> [String] {
        var out: [String] = []
        for p in paths where !allowsPath(p) { out.append("\(p) is outside the approved scope") }
        if alreadyChanged + paths.count > maxChangedFiles { out.append("changing \(alreadyChanged + paths.count) files exceeds the approved maximum of \(maxChangedFiles)") }
        return out
    }

    /// Prompt text so the planner stays inside the scope in the first place.
    var promptNotes: String {
        var s = "Scope approved by the user (do not exceed it): step types \(allowedStepTypes.map(\.rawValue).sorted().joined(separator: ", ")); at most \(maxSteps) steps; change at most \(maxChangedFiles) file(s)"
        if testFilesOnly { s += ", test files only (never application code)" }
        else if !pathPrefixes.isEmpty { s += ", only: \(pathPrefixes.joined(separator: ", "))" }
        return s + ". No deletions."
    }

    /// Canonical form used to bind an approval to exactly this scope.
    var canonical: String {
        "types=\(allowedStepTypes.map(\.rawValue).sorted().joined(separator: ","));paths=\(pathPrefixes.sorted().joined(separator: ","));testOnly=\(testFilesOnly);files=\(maxChangedFiles);steps=\(maxSteps);delete=\(allowDelete)"
    }
}
