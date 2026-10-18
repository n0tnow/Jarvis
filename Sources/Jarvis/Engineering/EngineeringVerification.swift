import Foundation

// MARK: - Verification evidence, plan and verdict (V1.0 autonomous engineering pipeline)
//
// WORKER SAID DONE is not WORK VERIFIED. A worker's claims (`WorkerClaims`) can only ever be COMPARED with evidence, never become it. Evidence is an observed fact:
// a command that JARVIS ran (its executable, exit status, the revision of the workspace it ran against, a timestamp, a bounded excerpt) or a property of the repository read
// after the worker finished. Evidence belongs to ONE revision (`snapshotDigest`): a green test run from before the last edit proves nothing about the last edit.

enum VerificationStage: String, Codable, CaseIterable, Sendable {
    case staticCheck, unitTests, integrationTests, build, securityGuards, artifactInspection, runtimeValidation
}

enum StageStatus: Equatable, Codable, Sendable {
    case planned
    case passed
    case failed
    case skipped(String)
    case notAvailable(String)
    /// Needs a person and a real environment (macOS, Unity editor, browser, hardware): never auto-verifiable.
    case manualRequired(String)

    var isSatisfied: Bool { if case .passed = self { return true }; return false }
    var isTerminalFailure: Bool { if case .failed = self { return true }; return false }
}

struct EvidenceTestCounts: Codable, Equatable, Sendable {
    var passed: Int
    var failed: Int
    var skipped: Int = 0
}

/// A fact about a command JARVIS ran. Only the verification runner constructs this (from `ManagedProcess` results in the app, from real fixture processes in tests).
struct VerificationEvidence: Codable, Equatable, Sendable {
    var stage: VerificationStage
    /// The approved profile label that ran ("swift test", "python3 -m unittest"), never a free-form command.
    var profile: String
    var exitStatus: Int32
    /// The workspace digest the command ran against.
    var snapshotDigest: String
    var recordedAt: Date
    var excerpt: String
    var counts: EvidenceTestCounts?

    var passed: Bool { exitStatus == 0 && (counts.map { $0.failed == 0 } ?? true) }
}

struct PlannedStage: Codable, Equatable, Sendable {
    var stage: VerificationStage
    var profile: String?
    var required: Bool
    var reason: String
    var status: StageStatus = .planned
}

struct VerificationPlan: Codable, Equatable, Sendable {
    var stages: [PlannedStage]
    /// What only a person can check, stated plainly — never converted into a pass.
    var manualRequired: [String]
    /// The change is sensitive: a reviewer is required.
    var elevatedReview: Bool
    var reasons: [String]

    func stageStatus(_ s: VerificationStage) -> StageStatus? { stages.first { $0.stage == s }?.status }
    var requiredStages: [PlannedStage] { stages.filter(\.required) }
    var allRequiredPassed: Bool { requiredStages.allSatisfy { $0.status.isSatisfied } }

    /// Records evidence for the matching stage — but only evidence for the CURRENT revision counts.
    mutating func record(_ e: VerificationEvidence, currentDigest: String) {
        guard let i = stages.firstIndex(where: { $0.stage == e.stage && ($0.profile == nil || $0.profile == e.profile) }) else { return }
        stages[i].status = (e.snapshotDigest == currentDigest) ? (e.passed ? .passed : .failed) : .planned     // stale evidence leaves the stage open
    }
}

/// Which approved profiles exist for this project (labels). Not hard-coded to a project: the engine supplies them.
struct ProjectVerificationProfiles: Equatable, Sendable {
    var staticCheck: String?
    var unitTests: String?
    var integrationTests: String?
    var build: String?
    var securityGuards: String?
    var unityCompile: String?
}

enum VerificationPlanner {
    /// Verification proportional to the change: docs-only needs guards but no build; source needs build + unit tests; shared core adds integration; build scripts and guards widen everything and
    /// require review; Unity C# adds the (future) editor validation as a MANUAL requirement; UI / hardware work is never claimed verified.
    static func plan(changedPaths: [String], profiles: ProjectVerificationProfiles, sharedCorePatterns: [String] = [], domains: Set<EngineeringDomain> = []) -> VerificationPlan {
        let classes = changedPaths.map { PathClassifier.classes(of: $0) }
        func any(_ c: PathClass) -> Bool { classes.contains { $0.contains(c) } }
        let sourcePaths = changedPaths.filter { let c = PathClassifier.classes(of: $0); return c.contains(.source) || c.contains(.test) || c.contains(.config) }
        let onlyDocs = !changedPaths.isEmpty && classes.allSatisfy { $0.contains(.documentation) }
        let touchesShared = changedPaths.contains { p in sharedCorePatterns.contains { PathGlob.matches($0, p) } }
        let unityCS = changedPaths.contains { $0.lowercased().hasSuffix(".cs") } || domains.contains(.unityScripts)
        var stages: [PlannedStage] = []
        var manual: [String] = []
        var reasons: [String] = []
        func add(_ s: VerificationStage, _ profile: String?, required: Bool, _ reason: String) {
            guard !stages.contains(where: { $0.stage == s }) else { return }
            if let profile { stages.append(PlannedStage(stage: s, profile: profile, required: required, reason: reason)) }
            else { stages.append(PlannedStage(stage: s, profile: nil, required: false, reason: reason, status: .notAvailable("no approved profile for this project"))) }
        }
        if changedPaths.isEmpty { reasons.append("nothing changed: nothing to verify, and nothing may be claimed"); return VerificationPlan(stages: [], manualRequired: [], elevatedReview: false, reasons: reasons) }
        if onlyDocs {
            reasons.append("documentation only: guards and a truth check, no build")
            add(.securityGuards, profiles.securityGuards, required: profiles.securityGuards != nil, "documentation claims must match the evidence")
        } else {
            if !sourcePaths.isEmpty {
                reasons.append("source changed: build and unit tests")
                add(.build, profiles.build, required: true, "source changed")
                add(.unitTests, profiles.unitTests, required: true, "source changed")
                add(.staticCheck, profiles.staticCheck, required: false, "source changed")
            }
            if touchesShared { reasons.append("shared core changed: regression (integration) tests"); add(.integrationTests, profiles.integrationTests ?? profiles.unitTests, required: true, "shared core changed") }
            if any(.test) { reasons.append("tests changed: the changed tests must be run and reviewed"); add(.unitTests, profiles.unitTests, required: true, "tests changed") }
            if any(.buildScript) || any(.securityGuard) || any(.dependencyManifest) {
                reasons.append("build / guard / dependency files changed: full verification and review")
                add(.build, profiles.build, required: true, "build or guard files changed")
                add(.unitTests, profiles.unitTests, required: true, "build or guard files changed")
                add(.securityGuards, profiles.securityGuards, required: profiles.securityGuards != nil, "build or guard files changed")
            }
            if any(.config) && sourcePaths.isEmpty { add(.build, profiles.build, required: true, "configuration changed") }
        }
        if unityCS {
            reasons.append("Unity C# changed: editor compile / tests are a future validation path")
            if let c = profiles.unityCompile { add(.runtimeValidation, c, required: false, "Unity compile") }
            manual.append("Unity editor validation (compile, scene / prefab behaviour, play mode) on a real editor")
        }
        if domains.contains(.ui) { manual.append("visual and interaction check on the real application") }
        let elevated = any(.buildScript) || any(.securityGuard) || any(.dependencyManifest) || any(.test) && changedPaths.contains { PathClassifier.classes(of: $0).contains(.securityGuard) }
        return VerificationPlan(stages: stages, manualRequired: manual, elevatedReview: elevated, reasons: reasons)
    }
}

// MARK: Observed state and verdict

/// Everything JARVIS OBSERVED after a worker (or a repair attempt) — the only input to a verdict besides the assignment.
struct ObservedState: Sendable {
    var before: WorkspaceSnapshot
    var after: WorkspaceSnapshot
    var deltas: [FileDelta]
    var applied: [AppliedEdit]
    var evidence: [VerificationEvidence]
    /// Content of files for `fileContains` checks and artifact validation (path → text); only paths JARVIS read.
    var contents: [String: String] = [:]
    var commit: CommitObservation?
    var changes: [FileChange] { SnapshotDiff.between(before, after) }
}

struct CommitObservation: Equatable, Sendable {
    var headBefore: String?
    var headAfter: String?
    var commitExists: Bool
    var files: [String]
    var message: String
}

enum WorkVerificationStatus: String, Codable, Equatable, Sendable {
    /// Every required stage passed at the final revision, no blocker, no unresolved major finding, every criterion met and nothing left for a person.
    case verified
    /// Everything JARVIS can check passed, but a person must still validate on a real environment (MANUAL TEST REQUIRED). Never "manually verified".
    case verifiedAutomated
    case failed
    /// No blocker, but a major finding needs a person's or a reviewer's decision, or required evidence is missing.
    case needsReview
    /// Useful partial work: nothing unsafe, but not complete.
    case partial
    case inconclusive
}

struct ClaimMismatch: Codable, Equatable, Sendable {
    var claim: String
    var observed: String
}

struct VerificationVerdict: Equatable, Sendable {
    var status: WorkVerificationStatus
    var findings: [EngineeringFinding]
    var mismatches: [ClaimMismatch]
    var unmetCriteria: [String]
    var missingStages: [VerificationStage]
    var revision: String
    var attribution: AttributionReport
    var diffStats: DiffStats

    var isVerified: Bool { status == .verified || status == .verifiedAutomated }
    /// What still needs a person on a real environment.
    var manualRequired: [String] = []
}

enum EngineeringVerifier {
    /// The one verdict function. `claims` (if any) is only compared, never trusted; `manualRecorded` is the set of manual criterion ids a PERSON recorded.
    static func verify(assignment a: EngineeringAssignment, claims: WorkerClaims?, observed o: ObservedState, plan: VerificationPlan, dependencyEvidence: [DependencyEvidence] = [], docEvidence: EvidenceSummary? = nil,
                       manualRecorded: Set<String> = [], declaredAPISymbols: Set<String> = [], existingTypes: Set<String> = [], claimsIssue: WorkerReportIssue? = nil) -> VerificationVerdict {
        let changes = o.changes
        let digest = o.after.digest
        let attribution = ChangeAttribution.attribute(changes: changes, applied: o.applied, baseline: o.before.git)
        var findings: [EngineeringFinding] = []
        var mismatches: [ClaimMismatch] = []

        // 1. scope, ownership, magnitude (observed change set)
        findings += ScopeEnforcer.check(changes: changes, scope: a.scope, attribution: attribution, userDirtyBefore: o.before.git.dirty.union(o.before.git.untracked))
        // 2. content-level tampering and quality
        let words = Set(a.requirements.joined(separator: " ").lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 3 })
        findings += TamperingDetector.inspectAll(o.deltas, scope: a.scope, requirementWords: words)
        findings += ArchitectureDriftDetector.scan(deltas: o.deltas, existingTypes: existingTypes)
        // 3. dependencies, docs
        var additions: [DependencyAddition] = []
        for d in o.deltas { additions += DependencyScanner.additions(path: d.path, before: d.before, after: d.after) }
        findings += DependencyCheck.evaluate(additions, evidence: dependencyEvidence, scope: a.scope)
        let testsPassed = o.evidence.contains { ($0.stage == .unitTests || $0.stage == .integrationTests) && $0.snapshotDigest == digest && $0.passed }
        let buildPassed = o.evidence.contains { $0.stage == .build && $0.snapshotDigest == digest && $0.passed }
        let summary = docEvidence ?? EvidenceSummary(testsPassedAtCurrentRevision: testsPassed, buildPassedAtCurrentRevision: buildPassed)
        for d in o.deltas { findings += DocumentationTruth.check(path: d.path, delta: LineDiffer.diff(d.before, d.after), evidence: summary) }
        if let c = claims {
            findings += APIAssumptionCheck.evaluate(c.apiAssumptions.map { APIAssumption(symbol: $0, reference: nil) }, declaredInProject: declaredAPISymbols, buildPassedAtFinalRevision: buildPassed)
        }

        // 4. claims versus observation (an unparseable answer is a protocol failure: harmless when the observed state verifies on its own, a failure when nothing changed)
        if let issue = claimsIssue {
            findings.append(EngineeringFinding(.malformedWorkerOutput, changes.isEmpty && !a.scope.isReadOnly ? .blocker : .minor, path: ".", "the worker's answer could not be read: \(issue)", evidence: "unparseable report"))
        }
        if let c = claims {
            if c.status == .done, !a.scope.isReadOnly, changes.isEmpty { findings.append(EngineeringFinding(.noChange, .blocker, "the worker reports the work done, but the repository did not change", evidence: "no file differs between the snapshots")); mismatches.append(ClaimMismatch(claim: "status done", observed: "no change in the repository")) }
            let actual = Set(changes.map { PathGlob.normalize($0.path) })
            let claimed = Set(c.filesChanged.map(PathGlob.normalize))
            for p in c.filesChanged.sorted() where !actual.contains(PathGlob.normalize(p)) {
                findings.append(EngineeringFinding(.claimedChangeNotInDiff, .major, path: p, "the worker claims a change that is not in the repository", evidence: p)); mismatches.append(ClaimMismatch(claim: "changed \(p)", observed: "unchanged"))
            }
            for p in actual.subtracting(claimed).sorted() { findings.append(EngineeringFinding(.unclaimedChange, a.scope.allows(p) ? .minor : .major, path: p, "a file changed that the worker did not report", evidence: p)); mismatches.append(ClaimMismatch(claim: "(not reported)", observed: "changed \(p)")) }
            if let t = c.tests, t.allGreen == true, !testsPassed {
                let contradicted = o.evidence.contains { ($0.stage == .unitTests || $0.stage == .integrationTests) && $0.snapshotDigest == digest && !$0.passed }
                findings.append(EngineeringFinding(contradicted ? .testClaimContradicted : .claimUnverified, contradicted ? .blocker : .note, path: ".", "the worker says the tests pass; \(contradicted ? "the real run at the final revision failed" : "no test run at the final revision confirms it")", evidence: contradicted ? "test run failed at \(digest)" : "no evidence"))
                mismatches.append(ClaimMismatch(claim: "tests pass", observed: contradicted ? "tests failed" : "no test evidence at this revision"))
            }
            for cmd in c.commandsRun where cmd.exitCode == 0 && !o.evidence.contains(where: { cmd.command.contains($0.profile) }) {
                mismatches.append(ClaimMismatch(claim: "ran \(cmd.command.prefix(60)) → 0", observed: "no recorded run"))
            }
            if let h = c.claimedCommit, let obs = o.commit {
                if obs.headAfter?.hasPrefix(h) != true || obs.headAfter == obs.headBefore || !obs.commitExists {
                    findings.append(EngineeringFinding(.commitClaimContradicted, .blocker, path: ".", "the worker claims a commit that the repository does not show", evidence: "claimed \(h.prefix(12)), HEAD \(obs.headAfter?.prefix(12) ?? "none")")); mismatches.append(ClaimMismatch(claim: "commit \(h.prefix(12))", observed: "HEAD \(obs.headAfter?.prefix(12) ?? "unchanged")"))
                }
            } else if claims?.claimedCommit != nil, o.commit == nil { findings.append(EngineeringFinding(.commitClaimContradicted, .major, path: ".", "a claimed commit cannot be checked: no commit observation", evidence: "claimed \(claims!.claimedCommit!.prefix(12))")) }
        }

        // 5. expected artifacts
        for art in a.expectedArtifacts {
            guard let fp = o.after.files[art.path] ?? o.after.files.first(where: { PathGlob.normalize($0.key) == PathGlob.normalize(art.path) })?.value else {
                findings.append(EngineeringFinding(.artifactMissing, .blocker, path: art.path, "an expected artifact does not exist", evidence: art.path)); continue
            }
            if art.mustBeNonEmpty, fp.size == 0 { findings.append(EngineeringFinding(.artifactInvalid, .blocker, path: art.path, "the artifact is empty", evidence: art.path)) }
            if o.before.files[art.path]?.hash == fp.hash { findings.append(EngineeringFinding(.artifactInvalid, .major, path: art.path, "the artifact existed unchanged before the task: it does not belong to this task", evidence: art.path)) }
        }

        // 6. acceptance criteria
        var unmet: [String] = []
        for crit in a.acceptance {
            switch crit.check {
            case .profile(let label):
                let ok = o.evidence.contains { $0.profile == label && $0.snapshotDigest == digest && $0.passed }
                if !ok {
                    let stale = o.evidence.contains { $0.profile == label && $0.snapshotDigest != digest }
                    unmet.append(crit.id)
                    findings.append(EngineeringFinding(stale ? .staleEvidence : .criterionUnmet, .blocker, path: ".", stale ? "the only run of \"\(label)\" is from an earlier revision" : "no passing run of \"\(label)\" at the final revision", evidence: crit.id))
                }
            case .fileExists(let p):
                if o.after.files.keys.first(where: { PathGlob.normalize($0) == PathGlob.normalize(p) }) == nil { unmet.append(crit.id); findings.append(EngineeringFinding(.criterionUnmet, .blocker, path: p, "the required file does not exist", evidence: crit.id)) }
            case .fileContains(let p, let text):
                if !(o.contents[p] ?? "").contains(text) { unmet.append(crit.id); findings.append(EngineeringFinding(.criterionUnmet, .blocker, path: p, "the required content is not in the file", evidence: crit.id)) }
            case .fileDoesNotContain(let p, let text):
                if (o.contents[p] ?? "").contains(text) { unmet.append(crit.id); findings.append(EngineeringFinding(.criterionUnmet, .blocker, path: p, "forbidden content is still in the file", evidence: crit.id)) }
            case .manual:
                if !manualRecorded.contains(crit.id) { unmet.append(crit.id) }
            }
        }

        // 7. the plan
        var currentPlan = plan
        for e in o.evidence { currentPlan.record(e, currentDigest: digest) }
        let missing = currentPlan.requiredStages.filter { !$0.status.isSatisfied }.map(\.stage)
        for s in currentPlan.requiredStages where s.status.isTerminalFailure { findings.append(EngineeringFinding(.criterionUnmet, .blocker, path: ".", "required stage \(s.stage.rawValue) failed at the final revision", evidence: s.profile ?? s.stage.rawValue)) }

        // verdict
        let stats = DiffInspector.stats(changes: changes, deltas: o.deltas)
        let manualOnly = unmet.filter { id in a.acceptance.first { $0.id == id }.map { if case .manual = $0.check { return true }; return false } ?? false }
        let autoUnmet = unmet.filter { !manualOnly.contains($0) }
        let status: WorkVerificationStatus
        if !findings.blockers.isEmpty || currentPlan.requiredStages.contains(where: { $0.status.isTerminalFailure }) { status = .failed }
        else if !autoUnmet.isEmpty || !missing.isEmpty { status = changes.isEmpty && !a.scope.isReadOnly ? .inconclusive : (o.evidence.isEmpty ? .inconclusive : .partial) }
        else if !findings.majors.isEmpty { status = .needsReview }
        else if a.scope.isReadOnly == false && changes.isEmpty { status = .inconclusive }
        else if claims?.status == .partial || claims?.status == .blocked || claims?.status == .failed { status = .partial }
        else if !manualOnly.isEmpty || !plan.manualRequired.isEmpty { status = .verifiedAutomated }
        else { status = .verified }
        return VerificationVerdict(status: status, findings: findings, mismatches: mismatches, unmetCriteria: unmet, missingStages: missing, revision: digest, attribution: attribution, diffStats: stats, manualRequired: plan.manualRequired + a.acceptance.filter { manualOnly.contains($0.id) }.map(\.text))
    }
}
