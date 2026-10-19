import Foundation

// MARK: - The engineering seam (V1.0 final integration)
//
// The autonomous-engineering policy layer (`Sources/Jarvis/Engineering/`, pure) is connected to the ONE existing TaskEngine here and in `TaskEngine+Engineering.swift`. This file holds the typed,
// process-free glue: when the pipeline applies, how an assignment is derived from the task the engine already has, how a `CommandResult` of an approved profile becomes `VerificationEvidence`
// bound to a workspace revision, how a prospective edit set is judged BEFORE it is written, and what the final verdict means for the task. It starts no process, writes no file, creates no
// orchestrator, router or store: the engine keeps its scheduler, leases, approvals and persistence; this only decides what the OBSERVED repository state allows the engine to claim.
//
//   a worker's text      → a CLAIM (`WorkerClaims`, compared with reality, never evidence)
//   a CommandResult      → EVIDENCE for the revision it ran against (and for no other)
//   the repository       → FACT (snapshot of the files, Git facts, the diff JARVIS actually applied)
//   NO VERIFIED ACTION → NO COMPLETION CLAIM

/// In-memory engineering state of ONE task. The durable form is `EngineeringRunRecord`, written into the existing task checkpoint (no second store).
final class EngineeringRunState {
    var record: EngineeringRunRecord
    /// The workspace at the start of the task (fingerprints; contents only for small text files, bounded) — what the diff is computed against.
    var before: WorkspaceSnapshot
    var beforeContents: [String: String]
    /// The workspace at the last observation (after the last applied edit set): a change that is not ours since then makes a worker result STALE.
    var observed: WorkspaceSnapshot
    var loop: RepairLoop
    var claims: WorkerClaims?
    var claimsIssue: WorkerReportIssue?
    var profiles: ProjectVerificationProfiles
    /// Set when a resume could not prove the stored state (corrupt / diverged): no engineering write may start until the task is re-planned by a person.
    var resumeBlock: String?
    /// The decision taken at completion (nil until then): what the report may claim.
    var completion: EngineeringCompletion?

    init(record: EngineeringRunRecord, before: WorkspaceSnapshot, beforeContents: [String: String], profiles: ProjectVerificationProfiles) {
        self.record = record; self.before = before; self.beforeContents = beforeContents; self.observed = before
        self.loop = RepairLoop(budget: record.assignment.budget); self.profiles = profiles
    }
}

/// What a checkpoint stored for a task (decoded by `loadContext`, revalidated by `engineeringBegin` before ANY write after a restart).
struct EngineeringRestore {
    var record: EngineeringRunRecord
    var before: WorkspaceSnapshot?
    var observed: WorkspaceSnapshot?
}

/// What the engine does with a finished software-engineering task.
enum EngineeringCompletion: Equatable, Sendable {
    /// Every required stage passed at the final revision, nothing blocking: the task may be reported VERIFIED (automated; a person may still owe a manual check).
    case verified(manualRequired: [String])
    /// Changes were applied but cannot be verified: no approved verification profile exists for this project, or only advisory findings remain. Reported as NOT VERIFIED, never as done-and-checked.
    case unverified(reason: String)
    /// The work cannot be claimed: a blocker, a failed or stale required stage, or nothing changed although a change was reported.
    case failed(FailureCategory, String)
}

enum EngineeringSeam {
    /// Names whose changes are side effects of running a verification command, not of the worker (tool caches); they never make evidence stale.
    static let ignoredNames: Set<String> = WorkspaceSnapshotter.defaultIgnored.union([".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", "target", ".gradle", ".idea", ".vscode"])
    static let maxContentFiles = 800
    static let maxContentBytes = 200_000
    static let maxContentTotal = 8_000_000

    // MARK: Applicability — software-engineering work only

    /// Conversation, navigation, application launches, media, status and research never pass through the engineering machinery: only a development task that has a code-change step does.
    static func applies(kind: TaskKind, steps: [TaskStepRecord]) -> Bool { kind == .development && steps.contains { $0.type == .codeChange } }

    // MARK: Assignment (reuses `EngineeringAssignment`; nothing is duplicated)

    private static func mentions(_ goal: String, _ words: [String]) -> Bool {
        let tokens = Set(goal.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return words.contains { tokens.contains($0) }
    }

    /// The labels of the project's approved verification profiles (build / test). Nothing is invented: a project without a declared or discovered profile has none.
    static func profileLabels(_ p: ProjectProfiles) -> ProjectVerificationProfiles {
        ProjectVerificationProfiles(staticCheck: nil, unitTests: p.test?.label, integrationTests: nil, build: p.build?.label, securityGuards: nil, unityCompile: nil)
    }

    /// The assignment of a development task: the user's goal is the objective, the task's own scope (if any) is the write scope, the approved profiles are the acceptance criteria. Authority to touch
    /// tests / build scripts / dependencies exists only when the goal says so; guards never. `.git` and `.jarvis` (where the verification profiles are declared) are never a worker's to edit.
    static func assignment(record: TaskRecord, steps: [TaskStepRecord], profiles: ProjectProfiles, base: RevisionStamp?) -> EngineeringAssignment {
        var scope = WriteScope()
        if let s = record.scope, !s.pathPrefixes.isEmpty {
            scope.allowed = s.pathPrefixes.map { $0.hasSuffix("/") ? $0 + "**" : ($0.contains(".") ? $0 : $0 + "/**") }
        } else { scope.allowed = ["**"] }
        scope.forbidden = [".git/**", ".jarvis/**"]
        scope.mayModifyTests = (record.scope?.testFilesOnly ?? false) || mentions(record.goal, ["test", "tests", "testing", "spec", "specs", "coverage", "unittest", "pytest", "regression"])
        scope.mayModifyBuildScripts = mentions(record.goal, ["build", "makefile", "script", "scripts", "ci", "pipeline", "workflow", "workflows", "cmake", "gradle", "package"])
        scope.mayAddDependencies = mentions(record.goal, ["dependency", "dependencies", "library", "libraries", "package", "packages", "install"])
        scope.mayDelete = (record.scope?.allowDelete ?? false) || steps.contains { $0.type == .delete }
        scope.mayModifyGuards = false
        var a = EngineeringAssignment(objective: String(record.goal.prefix(EngineeringAssignment.maxObjective)), project: projectLabel(record.workspaceRoot))
        a.scope = scope
        a.risk = record.risk
        a.base = base
        a.providerPreference = record.preference?.rawValue ?? "auto"
        let labels = [profiles.build?.label, profiles.test?.label].compactMap { $0 }
        a.verificationProfiles = labels
        a.acceptance = labels.enumerated().map { AcceptanceCriterion(id: "A\($0.offset + 1)", text: "\($0.element) passes at the final revision", check: .profile($0.element)) }
        a.requirements = steps.filter { $0.type == .codeChange }.map(\.title)
        a.budget = EngineeringBudget(workerAttempts: TaskEngine.maxStepAttempts, verificationRuns: 6, providerRequests: 12, wallClock: 30 * 60)
        return a
    }

    private static func projectLabel(_ root: String?) -> String {
        let name = ((root ?? "project") as NSString).lastPathComponent.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        return name.isEmpty ? "project" : String(name.prefix(40))
    }

    // MARK: Observation (read-only)

    /// Snapshot + the text of every small text file, bounded. Tool caches are ignored so that a test run does not make its own evidence stale.
    static func capture(root: String, git: GitFacts, withContents: Bool = true) -> (snapshot: WorkspaceSnapshot, contents: [String: String]) {
        let snap = WorkspaceSnapshotter.capture(root: URL(fileURLWithPath: root), git: git, ignoring: ignoredNames)
        var texts: [String: String] = [:]
        guard withContents else { return (snap, texts) }
        var total = 0
        for path in snap.files.keys.sorted() {
            guard texts.count < maxContentFiles, let f = snap.files[path], !f.isBinary, f.size <= maxContentBytes, total + f.size <= maxContentTotal,
                  let data = FileManager.default.contents(atPath: root + "/" + path), let text = String(data: data, encoding: .utf8) else { continue }
            texts[path] = text; total += f.size
        }
        return (snap, texts)
    }

    /// The deltas of a change set: "before" from the content captured at the start (or, when it was not captured, nil — the file is then judged as created); "after" from the disk now.
    static func deltas(changes: [FileChange], beforeContents: [String: String], afterContents: [String: String]) -> [FileDelta] {
        changes.filter { !$0.isBinary }.map { c in
            FileDelta(path: c.path, before: c.kind == .created ? nil : beforeContents[c.path], after: c.kind == .deleted ? nil : afterContents[c.path])
        }
    }

    // MARK: Evidence (a fact about a command JARVIS ran, bound to the revision it ran against)

    /// `nil` for a cancelled run (a cancelled command proves nothing, in either direction). A timeout is recorded as a FAILED run (exit 124), never as a pass; an exit status 0 with failing test counts
    /// is not a pass either (`VerificationEvidence.passed`). The excerpt is the engine's already-sanitised, bounded tail.
    static func evidence(step: StepType, profile: CommandProfile, result: CommandResult, digest: String, now: Date = Date()) -> VerificationEvidence? {
        if result.cancelled { return nil }
        let stage: VerificationStage = step == .build ? .build : (profile.label.lowercased().contains("integration") ? .integrationTests : .unitTests)
        var counts: EvidenceTestCounts?
        if let c = result.testCounts, c.passed != nil || c.failed != nil { counts = EvidenceTestCounts(passed: c.passed ?? max(0, (c.total ?? 0) - (c.failed ?? 0)), failed: c.failed ?? 0) }
        let status: Int32 = result.timedOut ? 124 : result.exitCode
        let excerpt = result.timedOut ? "timed out after \(Int(result.durationSeconds)) s\n" + String(result.tail.suffix(400)) : String(result.tail.suffix(600))
        return VerificationEvidence(stage: stage, profile: profile.label, exitStatus: status, snapshotDigest: digest, recordedAt: now, excerpt: excerpt, counts: counts)
    }

    // MARK: Review of a prospective edit set (BEFORE anything is written)

    struct ProspectiveEdit: Equatable, Sendable {
        var path: String
        var before: String?
        var after: String?
    }

    /// The deterministic review of what a worker's edit blocks WOULD change, against the assignment: scope, forbidden / protected paths, tampering with tests / guards / build scripts, secrets,
    /// destructive commands, dependencies, magnitude. Judged on the prepared before/after texts JARVIS itself computed — never on what the worker said. The user's own dirty files are the engine's
    /// existing approval (not repeated here), so `userDirtyFileTouched` is not part of this result.
    static func review(_ edits: [ProspectiveEdit], assignment a: EngineeringAssignment, alreadyChanged: Set<String>) -> [EngineeringFinding] {
        let changes = edits.map { e -> FileChange in
            let kind: FileChangeKind = e.before == nil ? .created : (e.after == nil ? .deleted : .modified)
            return FileChange(path: e.path, kind: kind, beforeHash: e.before.map { Redactor.sha256(Data($0.utf8)) }, afterHash: e.after.map { Redactor.sha256(Data($0.utf8)) }, isBinary: false)
        }
        var findings = ScopeEnforcer.check(changes: changes, scope: a.scope, attribution: nil, userDirtyBefore: [])
        let deltas = edits.map { FileDelta(path: $0.path, before: $0.before, after: $0.after) }
        let words = Set(a.requirements.joined(separator: " ").lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 3 })
        findings += TamperingDetector.inspectAll(deltas, scope: a.scope, requirementWords: words)
        var additions: [DependencyAddition] = []
        for d in deltas { additions += DependencyScanner.additions(path: d.path, before: d.before, after: d.after) }
        findings += DependencyCheck.evaluate(additions, evidence: [], scope: a.scope).filter { $0.code == .dependencyAdded }
        findings += ScopeEnforcer.magnitude(changes: changes + alreadyChanged.subtracting(Set(edits.map(\.path))).map { FileChange(path: $0, kind: .modified, beforeHash: nil, afterHash: nil, isBinary: false) }, scope: a.scope)
        return findings.filter { $0.code != .userDirtyFileTouched }
    }

    /// The failure category the engine uses for a blocking finding (the engine's own vocabulary; nothing new).
    static func category(for findings: [EngineeringFinding]) -> FailureCategory {
        let codes = Set(findings.map(\.code))
        if !codes.isDisjoint(with: [.secretIntroduced, .unsafeCommand, .guardWeakened, .guardChanged, .protectedPath, .forbiddenPath, .buildFailureSuppressed, .buildScriptChanged]) { return .securityBlocked }
        if !codes.isDisjoint(with: [.scopeEscape, .readOnlyAssignmentChanged, .deletionNotAllowed, .largeDiff, .dependencyAdded]) { return .scopeExceeded }
        return .validationFailed
    }

    static func summary(_ findings: [EngineeringFinding], limit: Int = 3) -> String {
        findings.prefix(limit).map { "\($0.severity.label) \($0.code.rawValue)\($0.path.map { " (\($0))" } ?? ""): \($0.message)" }.joined(separator: "; ")
    }

    // MARK: Claims (comparison only)

    /// A worker's structured report, if its answer contains one. A plain edit answer simply has no report: claims are optional and are never required to be believed.
    static func claims(from providerText: String) -> (claims: WorkerClaims?, issue: WorkerReportIssue?) {
        guard let open = providerText.range(of: "{\"status\"") ?? providerText.range(of: "{ \"status\"") else { return (nil, nil) }
        switch WorkerReportParser.parse(String(providerText[open.lowerBound...])) {
        case .success(let c): return (c, nil)
        case .failure(let issue): return (nil, issue)
        }
    }

    // MARK: The verdict and what it means for the task

    /// The observed state at this moment: the task-start snapshot against the workspace now, the edits JARVIS applied, the evidence recorded so far.
    static func observed(_ s: EngineeringRunState, after: WorkspaceSnapshot, afterContents: [String: String]) -> ObservedState {
        let changes = SnapshotDiff.between(s.before, after)
        return ObservedState(before: s.before, after: after, deltas: deltas(changes: changes, beforeContents: s.beforeContents, afterContents: afterContents), applied: s.record.applied,
                             evidence: s.record.evidence, contents: afterContents, commit: nil)
    }

    static func verify(_ s: EngineeringRunState, after: WorkspaceSnapshot, afterContents: [String: String]) -> (verdict: VerificationVerdict, plan: VerificationPlan) {
        let o = observed(s, after: after, afterContents: afterContents)
        let plan = VerificationPlanner.plan(changedPaths: o.changes.map(\.path), profiles: s.profiles, sharedCorePatterns: s.record.assignment.sharedCorePatterns, domains: s.record.assignment.domains)
        let v = EngineeringVerifier.verify(assignment: s.record.assignment, claims: s.claims, observed: o, plan: plan, claimsIssue: s.claimsIssue)
        return (v, plan)
    }

    /// The decision about completion. Written as one function so that the rule — no verified action, no completion claim — is in exactly one place and is testable:
    ///   · a blocker, a failed required stage, a stale or missing required run, or a reported change that is not in the repository  → the task FAILS;
    ///   · every required stage passed at the final revision → VERIFIED (and the manual checks that remain are named);
    ///   · otherwise (no approved verification profile exists, or only advisory findings remain) → completed but NOT VERIFIED, and the report says so.
    static func completion(verdict v: VerificationVerdict, plan: VerificationPlan, profilesAvailable: Bool) -> EngineeringCompletion {
        let blockers = v.findings.blockers
        if !blockers.isEmpty { return .failed(category(for: blockers), "not verified — " + summary(blockers)) }
        if plan.requiredStages.contains(where: { $0.status.isTerminalFailure }) {
            return .failed(.validationFailed, "not verified — a required check failed at the final revision: " + plan.requiredStages.filter { $0.status.isTerminalFailure }.map { $0.profile ?? $0.stage.rawValue }.joined(separator: ", "))
        }
        if !v.missingStages.isEmpty {
            return .failed(.validationFailed, "not verified — no passing run at the final revision of: " + v.missingStages.map(\.rawValue).joined(separator: ", ") + " (earlier results do not count for the changed files)")
        }
        if v.diffStats.files == 0 { return .failed(.validationFailed, "not verified — the repository did not change") }
        if v.isVerified { return .verified(manualRequired: v.manualRequired) }
        if !profilesAvailable { return .unverified(reason: "no approved build or test command exists for this project, so nothing could be run against the change") }
        if !v.findings.majors.isEmpty { return .unverified(reason: "needs your review: " + summary(v.findings.majors)) }
        return .unverified(reason: "the verification did not reach a verdict (\(v.status.rawValue))")
    }

    // MARK: Report lines (observable facts only)

    static func reportLines(_ r: EngineeringRunRecord, completion: EngineeringCompletion?) -> [String] {
        var lines = EngineeringReport.build(r).render(language: .en)
        switch completion {
        case .verified?: lines.append("Completion: VERIFIED by JARVIS' own runs at the final revision")
        case .unverified(let why)?: lines.append("Completion: NOT VERIFIED — " + why)
        case .failed(_, let why)?: lines.append("Completion: REFUSED — " + why)
        case nil: break
        }
        return lines.map { String($0.prefix(600)) }
    }
}
