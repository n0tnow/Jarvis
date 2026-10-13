import Foundation

/// Concise structured report of a finished task. Built ONLY from persisted records (steps, attempts, file changes, approvals),
/// so every statement is supported by what actually happened — and it can be rebuilt after a restart.
struct TaskReport: Codable, Equatable, Sendable {
    struct Step: Codable, Equatable, Sendable { var key: String; var title: String; var type: String; var state: String; var attempts: Int; var validation: String; var evidence: String? }
    struct Provider: Codable, Equatable, Sendable { var name: String; var role: String; var runs: Int }
    struct Failure: Codable, Equatable, Sendable { var category: String; var reason: String; var failedStep: String?; var suggestedNext: String }

    var taskID: UUID
    var title: String
    var goal: String
    var kind: String
    var state: String
    var startedAt: Date?
    var finishedAt: Date?
    var durationSeconds: Double
    var stepsPassed: Int
    var stepsTotal: Int
    var steps: [Step]
    var providers: [Provider]
    var filesChanged: [String]
    var userChangesPreserved: [String]
    var validations: [String]
    var repairAttempts: Int
    var escalations: Int
    var approvals: [String]
    var warnings: [String]
    var failure: Failure?
    var stoppedAt: String?
    var cleanup: String?
    /// V0.6: facts from the Unity steps (deterministic evidence only) and non-blocking reviewer advice. Optional so older reports still decode.
    var unity: [String]?
    var advisories: [String]?

    // MARK: Build

    static func build(task: TaskRecord, steps: [TaskStepRecord], attempts: [StepAttemptRecord], changes: [TaskFileChange], approvals: [ApprovalRecord],
                      cleanup: String? = nil) -> TaskReport {
        let measurable = steps.filter { $0.state != .skipped }
        let passed = measurable.filter { $0.state == .passed }
        var providers: [Provider] = []
        for s in steps {
            let ok = attempts.filter { $0.stepID == s.id && ($0.outcome == "passed" || $0.outcome == "applied") && $0.engine != nil }
            for a in ok {
                let name = (a.engine?.displayName ?? "") + (a.model.map { " · " + ($0.split(separator: "/").last.map(String.init) ?? $0) } ?? "")
                let role: String
                switch s.type { case .analysis: role = "analysed"; case .codeChange: role = a.kind == .primary ? "implemented the change" : "repaired the change"; case .review: role = "reviewed the result"
                case .unityEdit: role = "proposed the Unity edit"
                default: role = s.type.rawValue }
                if let i = providers.firstIndex(where: { $0.name == name && $0.role == role }) { providers[i].runs += 1 } else { providers.append(Provider(name: name, role: role, runs: 1)) }
            }
        }
        let failedStep = steps.first { $0.state == .failed }
        var failure: Failure?
        if task.state == .failed {
            let cat = task.failureCategory ?? failedStep?.failureCategory ?? .validationFailed
            failure = Failure(category: cat.label, reason: task.failureReason ?? failedStep?.failureReason ?? "unknown", failedStep: failedStep?.title, suggestedNext: suggestion(cat))
        }
        var warnings: [String] = []
        if steps.contains(where: { $0.state == .skipped }) { warnings.append("Skipped (nothing to do): " + steps.filter { $0.state == .skipped }.map(\.title).joined(separator: ", ")) }
        if changes.contains(where: \.preexistingUserChange) { warnings.append("JARVIS modified files that already had your uncommitted changes (after your approval).") }
        if task.kind == .development, !steps.contains(where: { $0.type == .test && $0.state == .passed && $0.validation == .testPass }) {
            warnings.append("No test run was validated as passing for this task.")
        }
        // V0.6: Unity facts come from the steps' own deterministic evidence; visual validation is never claimed (nothing captures or inspects an image).
        let unitySteps = steps.filter { $0.type.isUnity && ($0.state == .passed || $0.state == .failed) }
        var unity = unitySteps.compactMap { st -> String? in
            guard let e = st.validationEvidence, !e.isEmpty else { return nil }
            return "\(st.type.label): \(st.state == .passed ? "PASS" : "FAIL") — " + String(e.replacingOccurrences(of: "\n", with: " ").prefix(260))
        }
        if !unitySteps.isEmpty { unity.append("Visual validation: NOT PERFORMED (no Game/Scene View image was captured or inspected).") }
        let advisories = steps.filter { $0.type == .review && $0.state == .passed && ($0.validationEvidence ?? "").hasPrefix(ReviewAuthority.advisoryPrefix) }
            .compactMap { $0.validationEvidence.map { String($0.prefix(400)) } }
        let end = task.finishedAt ?? Date()
        let duration = task.accumulatedSeconds > 0 ? task.accumulatedSeconds : max(0, end.timeIntervalSince(task.startedAt ?? task.createdAt))
        return TaskReport(
            taskID: task.id, title: task.title, goal: task.goal, kind: task.kind.label, state: task.state.rawValue, startedAt: task.startedAt, finishedAt: task.finishedAt,
            durationSeconds: duration, stepsPassed: passed.count, stepsTotal: measurable.count,
            steps: steps.map { Step(key: $0.key, title: $0.title, type: $0.type.rawValue, state: $0.state.rawValue, attempts: $0.attempts, validation: $0.validation.rawValue, evidence: $0.validationEvidence) },
            providers: providers, filesChanged: Array(Set(changes.map(\.path))).sorted(),
            userChangesPreserved: (task.gitBaseline?.dirtyPaths ?? []) + (task.gitBaseline?.untrackedPaths ?? []),
            validations: steps.filter { $0.state == .passed && [.buildPass, .testPass, .reviewPass, .fileRemoved, .unityCompiled, .unityTestsPass, .unityState, .unityPlayObserved, .unityInspected].contains($0.validation) }.compactMap { $0.validationEvidence }.filter { !$0.isEmpty },
            repairAttempts: attempts.filter { $0.kind == .repair }.count, escalations: attempts.filter { $0.kind == .escalation }.count,
            approvals: approvals.map { "\($0.action) — \($0.state.rawValue)" }, warnings: warnings, failure: failure,
            stoppedAt: task.state == .cancelled ? (steps.first { $0.state == .cancelled }?.title ?? steps.first { $0.state == .pending }?.title ?? "before the first step") : nil,
            cleanup: cleanup, unity: unity.isEmpty ? nil : unity, advisories: advisories.isEmpty ? nil : advisories)
    }

    static func suggestion(_ c: FailureCategory) -> String {
        switch c {
        case .buildFailed, .testFailed: "Open the failing run in Agents → Console, fix the cause (or adjust the goal) and run the task again."
        case .providerUnavailable, .providerRateLimited: "Check the provider's sign-in/usage limit in Settings, then run the task again."
        case .providerFailed: "Run the task again; if it repeats, pick another provider in Settings."
        case .approvalDenied: "Run the task again and approve the action if you want it done."
        case .workspaceChanged: "Review the files that changed unexpectedly, then run the task again."
        case .malformedPlan, .validationFailed: "Rephrase the goal more specifically or choose a stronger provider in Settings."
        case .securityBlocked, .capabilityDenied, .workspaceViolation: "This request is outside what V0.4 may do (see docs/AUTONOMOUS_TASK_ENGINE.md)."
        case .resourceUnavailable: "Wait for other agents to finish and run the task again."
        case .toolFailed: "Check the project's build/test configuration (.jarvis/project.json) and run the task again."
        case .scopeExceeded: "The work needed more than you approved. Review the proposal and approve a larger scope if you want it."
        case .cancelled, .interrupted: "Resume or run the task again."
        case .unityUnavailable: "Open the project in a Unity editor that has the JARVIS bridge (see docs/UNITY_PROJECT_AGENT.md), then run the task again."
        case .ambiguousTarget: "Name the exact object (its hierarchy path or Global ID) and run the task again."
        case .unsafeEditorState: "Leave Play Mode and save or discard your unsaved Unity changes, then run the task again."
        case .compileFailed: "Open the Unity Console, fix the compiler errors (or adjust the goal) and run the task again."
        case .unityTimeout: "Check that the Unity Editor is responsive (it may be importing or showing a dialog), then run the task again."
        case .networkUnavailable: "Check the internet connection, then run the research again."
        case .blockedByNetworkPolicy: "JARVIS only reads the public internet (no localhost, private networks or non-web links). Use a public https source."
        case .permissionRequired: "Allow JARVIS in System Settings → Privacy & Security (Accessibility, and Screen Recording only for the vision fallback), then run the task again."
        case .computerActionFailed: "Open the Computer screen to see which step could not be verified, adjust the goal or bring the application to the state described, then run the task again."
        case .computerTimeout: "Check that the application is responsive (not busy or showing a dialog), then run the task again. JARVIS never force-quits an application."
        case .noSources: "Nothing readable was found. Rephrase the question, ask for a deeper search, or open sources yourself."
        case .acquisitionRefused: "JARVIS did not download this: open the listing yourself if you want it (account actions and purchases are never automatic)."
        case .downloadFailed: "The download did not complete or failed verification; nothing partial was kept. Try again later."
        case .interactionRequired: "The site asks for a login or a human check (CAPTCHA). JARVIS does not bypass that — open the page yourself."
        }
    }

    // MARK: Rendering

    /// One short paragraph for the conversation / announcement. Only facts present in the records.
    var userSummary: String {
        switch state {
        case TaskState.completed.rawValue:
            var s = "\(title) — completed. \(stepsPassed)/\(stepsTotal) steps validated."
            if !filesChanged.isEmpty { s += " \(filesChanged.count) file\(filesChanged.count == 1 ? "" : "s") changed." }
            for v in validations where v.hasPrefix("Build:") || v.hasPrefix("Tests:") { s += " " + v.replacingOccurrences(of: #"\s*\([\d.]+ s\)"#, with: "", options: .regularExpression) + "." }
            if !providers.isEmpty { s += " " + providers.map { "\($0.name) \($0.role)" }.joined(separator: "; ") + "." }
            if repairAttempts > 0 { s += " \(repairAttempts) repair attempt\(repairAttempts == 1 ? "" : "s")" + (escalations > 0 ? ", \(escalations) escalation." : ".") }
            return s
        case TaskState.failed.rawValue:
            let f = failure
            return "\(title) — failed after \(stepsPassed)/\(stepsTotal) steps. \(f?.category.capitalized ?? "Failure")\(f?.failedStep.map { " at “\($0)”" } ?? ""): \(f?.reason ?? "unknown"). \(f?.suggestedNext ?? "")"
        case TaskState.cancelled.rawValue:
            return "\(title) — stopped after \(stepsPassed)/\(stepsTotal) steps validated\(filesChanged.isEmpty ? "; no files were changed" : "; changed before stopping: " + filesChanged.joined(separator: ", "))."
        default:
            return "\(title) — \(state)."
        }
    }

    func markdown() -> String {
        var l = ["# Task report — \(title)", "", "- State: **\(state)** · Kind: \(kind) · Duration: \(Int(durationSeconds)) s", "- Goal: \(goal)", "- Steps validated: \(stepsPassed)/\(stepsTotal)", ""]
        l.append("## Steps")
        for s in steps { l.append("- [\(s.state)] \(s.title) (\(s.type), validation \(s.validation), attempts \(s.attempts))" + (s.evidence.map { "\n  - \($0.replacingOccurrences(of: "\n", with: " ").prefix(240))" } ?? "")) }
        if !providers.isEmpty { l += ["", "## Providers"] + providers.map { "- \($0.name): \($0.role) (\($0.runs))" } }
        if !filesChanged.isEmpty { l += ["", "## Files changed"] + filesChanged.map { "- \($0)" } }
        if !userChangesPreserved.isEmpty { l += ["", "## Your uncommitted changes at the start (left intact)"] + userChangesPreserved.map { "- \($0)" } }
        if !approvals.isEmpty { l += ["", "## Approvals"] + approvals.map { "- \($0)" } }
        if repairAttempts + escalations > 0 { l += ["", "Repairs: \(repairAttempts) · Escalations: \(escalations)"] }
        if let u = unity, !u.isEmpty { l += ["", "## Unity"] + u.map { "- \($0)" } }
        if let a = advisories, !a.isEmpty { l += ["", "## Reviewer advice (did not change the validated result)"] + a.map { "- \($0)" } }
        if !warnings.isEmpty { l += ["", "## Warnings"] + warnings.map { "- \($0)" } }
        if let f = failure { l += ["", "## Failure", "- \(f.category): \(f.reason)", f.failedStep.map { "- Failed step: \($0)" } ?? "", "- Next: \(f.suggestedNext)"] }
        if let s = stoppedAt { l += ["", "## Stopped", "- Stopped at: \(s)", "- Cleanup: \(cleanup ?? "—")"] }
        return l.joined(separator: "\n")
    }
}
