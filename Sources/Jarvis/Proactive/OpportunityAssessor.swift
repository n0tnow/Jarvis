import Foundation

/// What the assessor may look at: facts JARVIS recorded (never raw provider/tool output).
struct AssessmentContext: Sendable {
    var taskChangedPaths: [String] = []
    var knownFiles: [String] = []
    var originAutonomyDepth = 0
}

/// Builds the structured assessment deterministically from a finding and the task it came from. A model may only ADD caution later
/// (`mergeModelAssessment`): it can never lower a risk, remove a design impact, drop an external effect or grant a capability.
enum OpportunityAssessor {
    // MARK: Keyword safety nets (deterministic; applied regardless of what a model says)

    private static let designWords = ["redesign", "new flow", "navigation flow", "new screen", "new ui", "user interface flow", "gameplay", "mechanic", "waiting room", "lobby", "visual style",
                                      "art style", "layout", "theme", "new feature", "new level", "balance", "character", "ux ", "user experience", "branding", "color scheme", "animation style",
                                      // Unity content decisions (V0.6): these are design/product choices, never automatic.
                                      "lighting", "skybox", "post-processing", "post processing", "color grading", "scene layout", "level layout", "ui flow", "art direction", "shader look", "material look", "camera angle", "playable character"]
    private static let effectWords: [(ExternalEffect, [String])] = [
        (.purchase, ["purchase", "buy ", "paid asset", "pay for", "subscription", "license fee", "checkout", "buy the", "asset store"]),
        (.paidProvider, ["paid api", "paid model", "paid plan", "billing", "metered"]),
        (.credentialChange, ["credential", "api key", "api_key", "password", "access token", "secret key", "rotate key", "keychain", "private key"]),
        (.accountChange, ["account", "sign up", "sign in", "login flow for the account", "oauth app"]),
        (.gitPush, ["git push", "force push", "push to origin", "push the branch", "push --force"]),
        (.deployment, ["deploy", "release build to", "publish to", "ship to", "testflight", "app store"]),
        (.production, ["production", "prod environment", "live server"]),
        (.networkMutation, ["post request", "webhook", "register with the server", "call the remote api to change"]),
        (.upload, ["upload", "push the asset", "share publicly"]),
        (.message, ["send an email", "send email", "message the team", "post to slack", "tweet", "notify the team"]),
        (.permissionChange, ["permission", "chmod", "entitlement", "grant access", "sudo"]),
    ]
    private static let destructiveWords = ["delete", "remove the file", "remove files", "wipe", "purge", "drop table", "erase", "rm -rf", "replace the whole", "rewrite the entire", "delete everything"]
    private static let securityWords = ["vulnerab", "exploit", "injection", "xss", "csrf", "authentication", "authorization", "encrypt", "security"]

    private static func lower(_ f: RawFinding) -> String { (f.title + " " + f.summary + " " + (f.proposedAction?.goal ?? "")).lowercased() }

    static func inferCategory(_ f: RawFinding) -> OpportunityCategory {
        if let c = f.category { return c }
        let t = lower(f)
        if securityWords.contains(where: t.contains) { return .security }
        if designWords.contains(where: t.contains) { return t.contains("gameplay") || t.contains("mechanic") ? .gameplay : .design }
        if t.contains("asset") || t.contains("texture") || t.contains("model pack") { return .asset }
        if t.contains("dependency") || t.contains("package") || t.contains("library") { return .dependency }
        if t.contains("test") || t.contains("coverage") || t.contains("regression") { return .testCoverage }
        if t.contains("documentation") || t.contains("readme") || t.contains("docs") { return .documentation }
        if t.contains("performance") || t.contains("slow") || t.contains("optimi") { return .performance }
        if t.contains("refactor") || t.contains("restructure") || t.contains("architecture") { return .refactor }
        if t.contains("config") || t.contains("build setting") { return .configuration }
        if t.contains("bug") || t.contains("crash") || t.contains("null") || t.contains("fail") { return .bug }
        return .maintenance
    }

    // MARK: Deterministic assessment

    static func assess(_ f: RawFinding, category: OpportunityCategory, context: AssessmentContext) -> OpportunityAssessment {
        let t = lower(f)
        let files = OpportunityNormalizer.normalizedScope(f.affectedPaths)
        let changed = Set(OpportunityNormalizer.normalizedScope(context.taskChangedPaths))

        // relation to the originating task's work
        let relation: ScopeRelation
        if f.originTaskID == nil { relation = .unrelated }
        else if files.contains(where: { changed.contains($0) }) || files.contains(where: { isTestCounterpart($0, of: changed) }) { relation = .direct }
        else if files.contains(where: { f in changed.contains { sameDirectory(f, $0) } }) { relation = .adjacent }
        else if files.isEmpty && !changed.isEmpty && f.origin != .userDeferredIdea { relation = .adjacent }
        else { relation = .unrelated }

        // external effects / destructiveness / capabilities: keywords OR claims — the union, never less
        var effects = f.claimedExternalEffects
        for (e, words) in effectWords where words.contains(where: t.contains) { effects.insert(e) }
        let destructive: Destructiveness = destructiveWords.contains(where: t.contains) ? (t.contains("delete everything") || t.contains("rm -rf") || t.contains("entire") ? .significant : .limited) : .none
        var caps = f.requestedCapabilities.union(f.proposedAction?.taskKind == .development ? [.readProject, .writeProject, .runTests] : f.proposedAction?.taskKind == .research ? [] : [.readProject])
        if destructive != .none { caps.insert(.destructiveFileOperation) }
        for (e, cap) in [(ExternalEffect.gitPush, TaskCapability.gitPush), (.purchase, .purchase), (.deployment, .useNetwork), (.upload, .useNetwork), (.networkMutation, .useNetwork)] where effects.contains(e) { caps.insert(cap) }

        let design: DesignImpact = (f.claimedDesignImpact || category.isProductDecision || designWords.contains(where: t.contains)) ? .meaningful : .none
        let reversibility: Reversibility = (destructive != .none || !effects.isEmpty) ? .irreversible : .reversible
        let size = ScopeSize.of(fileCount: max(files.count, f.proposedAction?.expectedFiles.count ?? 0))

        var risk: RiskClass
        switch category {
        case .testCoverage, .documentation, .maintenance: risk = .low
        case .bug, .configuration, .performance, .refactor: risk = .medium
        case .security, .asset, .dependency, .design, .gameplay: risk = .high
        }
        // a tiny, direct, deterministic fix is low risk
        if category == .bug, relation == .direct, size == .small, design == .none { risk = .low }
        if size == .broad { risk = max(risk, .high) }
        if !effects.isEmpty || destructive == .significant { risk = .critical } else if destructive == .limited { risk = max(risk, .high) }

        // evidence strength from what is actually checkable
        let existing = Set(context.knownFiles.map { $0.lowercased() })
        let verified = f.evidence.filter { e in e.isDeterministic && (e.reference.map { existing.isEmpty || existing.contains($0.lowercased()) } ?? true) }
        let strength: EvidenceStrength
        if !verified.isEmpty { strength = .strong }
        else if f.evidence.contains(where: { $0.kind == .reviewClaim && ($0.reference.map { existing.contains($0.lowercased()) } ?? false) }) { strength = .medium }
        else if f.evidence.contains(where: { $0.kind == .reviewClaim || $0.kind == .modelClaim }) { strength = .weak }
        else { strength = .none }

        let derivedConfidence: Double = strength == .strong ? 0.8 : strength == .medium ? 0.6 : strength == .weak ? 0.35 : 0.1
        let confidence = min(1, max(0, f.claimedConfidence ?? derivedConfidence))      // evidence only: it feeds the policy as a floor, never as a grant
        let relevance: Double = (relation == .direct ? 0.9 : relation == .adjacent ? 0.6 : 0.4) + (strength >= .medium ? 0.05 : 0)

        return OpportunityAssessment(relevance: min(1, relevance), confidence: confidence, scopeSize: size, affectedFileCount: files.count, relation: relation, risk: risk,
                                     reversibility: reversibility, destructiveness: destructive, designImpact: design, externalEffects: effects, requiredCapabilities: caps,
                                     evidenceStrength: strength)
    }

    private static func sameDirectory(_ a: String, _ b: String) -> Bool {
        (a as NSString).deletingLastPathComponent == (b as NSString).deletingLastPathComponent
    }

    /// `test_calc.py` / `CalcTests.cs` / `calc.test.js` count as the test counterpart of a changed `calc.py`/`Calc.cs`/`calc.js`.
    private static func isTestCounterpart(_ path: String, of changed: Set<String>) -> Bool {
        guard TaskScope.isTestPath(path) else { return false }
        let name = (path as NSString).lastPathComponent
        let stem = ((name as NSString).deletingPathExtension).replacingOccurrences(of: "test_", with: "").replacingOccurrences(of: "_test", with: "")
            .replacingOccurrences(of: "tests", with: "").replacingOccurrences(of: ".test", with: "").replacingOccurrences(of: ".spec", with: "")
        guard stem.count >= 2 else { return false }
        return changed.contains { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension.contains(stem) }
    }

    // MARK: Proposed action (deterministic; a model's scope is never trusted)

    static func proposedAction(for f: RawFinding, category: OpportunityCategory, assessment a: OpportunityAssessment, knownFiles: [String]) -> ProposedAction {
        let existing = Set(knownFiles.map { $0.lowercased() })
        let files = f.affectedPaths.filter { existing.contains($0.lowercased()) }
        let types: Set<StepType> = [.analysis, .codeChange, .test, .review, .build]
        let title = OutputSanitizer.sanitize(String(f.title.prefix(140)))
        let goalFromModel = f.proposedAction.map { OutputSanitizer.sanitize(String($0.goal.prefix(400))) }
        // V0.9: a RESEARCH proposal is rebuilt deterministically too — read-only web research steps only, no project paths, no file changes.
        if f.proposedAction?.taskKind == .research {
            return ProposedAction(kind: .other, goal: goalFromModel ?? title, expectedFiles: [], scope: TaskScope(allowedStepTypes: [.researchSearch, .researchRead, .researchExtract, .researchVerify, .researchReport], maxChangedFiles: 0, maxSteps: 6),
                                  validationPlan: "A cited report: facts with evidence, assessments labelled, unknowns listed; nothing is downloaded or changed.", expectedBenefit: "Evidence for a decision, with sources you can open.", taskKind: .research)
        }
        switch category {
        case .testCoverage:
            let testFiles = files.filter(TaskScope.isTestPath)
            let scope = TaskScope(allowedStepTypes: types, pathPrefixes: testFiles, testFilesOnly: true, maxChangedFiles: 2, maxSteps: 8)
            return ProposedAction(kind: .addRegressionTest,
                                  goal: goalFromModel ?? "Add one focused regression test: \(title). Only add or modify test files; do not change application code.",
                                  expectedFiles: testFiles, scope: scope, validationPlan: "Run the project's tests; the new test must pass and the existing tests must still pass.",
                                  expectedBenefit: "Protects the recent change against regressions. No behaviour change.")
        case .bug, .maintenance, .documentation, .configuration:
            let scope = TaskScope(allowedStepTypes: types, pathPrefixes: files, testFilesOnly: false, maxChangedFiles: max(2, files.count), maxSteps: 8)
            return ProposedAction(kind: category == .bug ? .fixIssue : .maintenance, goal: goalFromModel ?? "\(title). Make the smallest change that resolves it and change nothing else.",
                                  expectedFiles: files, scope: scope, validationPlan: "Build/run the project's tests and review the diff.", expectedBenefit: "Resolves the noticed issue with a minimal change.")
        default:
            let scope = TaskScope(allowedStepTypes: types, pathPrefixes: files, testFilesOnly: false, maxChangedFiles: max(3, files.count), maxSteps: 8)
            return ProposedAction(kind: category == .refactor ? .refactor : .other, goal: goalFromModel ?? title, expectedFiles: files, scope: scope,
                                  validationPlan: "Plan, implement, build/test and review as a normal task.", expectedBenefit: "As described in the proposal.")
        }
    }

    /// Binds an approval to exactly this action: opportunity, workspace, goal, scope, category and risk.
    static func actionHash(opportunityID: UUID, projectRoot: String, action: ProposedAction, risk: RiskClass, category: OpportunityCategory) -> String {
        let raw = "\(opportunityID.uuidString)|\(projectRoot)|\(action.goal)|\(action.scope.canonical)|\(action.kind.rawValue)|\(risk.rawValue)|\(category.rawValue)"
        return Redactor.sha256(Data(raw.utf8))
    }

    // MARK: Model assistance — may only ADD caution

    static func modelAssessmentPrompt(_ f: RawFinding, knownFiles: [String]) -> String {
        """
        You assess ONE software-project observation for a task engine. You cannot act; you only classify.
        Observation: \(OutputSanitizer.sanitize(String(f.title.prefix(300))))
        Details: \(OutputSanitizer.sanitize(String(f.summary.prefix(600))))
        Project files (truncated): \(knownFiles.prefix(60).joined(separator: ", "))

        Reply with ONE JSON object and nothing else:
        {"category": "bug|testCoverage|maintenance|refactor|performance|security|documentation|design|gameplay|asset|dependency|configuration",
         "affectedFiles": ["project-relative paths from the list above"],
         "designImpact": true or false,
         "risk": "low|medium|high|critical",
         "externalEffects": ["purchase|paidProvider|credentialChange|accountChange|gitPush|deployment|production|networkMutation|upload|message|permissionChange"],
         "requiredCapabilities": ["readProject|writeProject|runBuild|runTests|destructiveFileOperation|gitPush|gitCommit|purchase|useNetwork"],
         "confidence": 0.0-1.0,
         "summary": "one sentence"}
        Be cautious: set designImpact true for anything about look, flow, gameplay or behaviour users would notice; list every external effect you see.
        """
    }

    /// Parses the model's JSON. Fields that carry authority (anything like "decision", "approved", "autoAction") are not parsed at all.
    static func parseModelAssessment(_ text: String) -> (category: OpportunityCategory?, files: [String], design: Bool, risk: RiskClass?, effects: Set<ExternalEffect>, caps: Set<TaskCapability>, confidence: Double?, summary: String?)? {
        guard let json = PlanParser.extractJSONObject(text), let d = json.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return (
            (o["category"] as? String).flatMap(OpportunityCategory.init(rawValue:)),
            (o["affectedFiles"] as? [Any] ?? []).compactMap { $0 as? String },
            (o["designImpact"] as? Bool) ?? false,
            (o["risk"] as? String).flatMap { RiskClass(rawValue: $0.lowercased()) },
            Set((o["externalEffects"] as? [Any] ?? []).compactMap { ($0 as? String).flatMap(ExternalEffect.init(rawValue:)) }),
            Set((o["requiredCapabilities"] as? [Any] ?? []).compactMap { ($0 as? String).flatMap(TaskCapability.init(rawValue:)) }),
            (o["confidence"] as? Double),
            (o["summary"] as? String).map { OutputSanitizer.sanitize(String($0.prefix(300))) })
    }

    /// Merges a model's answer into the deterministic assessment CAUTIOUSLY (monotone): risk only up, design impact only on, effects/capabilities only added.
    static func mergeModelAssessment(_ a: OpportunityAssessment, category: OpportunityCategory, model m: (category: OpportunityCategory?, files: [String], design: Bool, risk: RiskClass?, effects: Set<ExternalEffect>, caps: Set<TaskCapability>, confidence: Double?, summary: String?),
                                     knownFiles: [String]) -> (OpportunityAssessment, OpportunityCategory, [String]) {
        var out = a
        out.modelAssisted = true
        if m.design { out.designImpact = .meaningful }
        if let r = m.risk { out.risk = max(out.risk, r) }
        out.externalEffects.formUnion(m.effects)
        out.requiredCapabilities.formUnion(m.caps)
        if !m.effects.isEmpty { out.reversibility = .irreversible; out.risk = .critical }
        // The model's own confidence is NOT merged: confidence stays derived from checkable evidence.
        var cat = category
        if let mc = m.category, mc.isProductDecision || mc == .security { cat = mc }              // a more restrictive category may be adopted; a looser one never
        let existing = Set(knownFiles.map { $0.lowercased() })
        return (out, cat, m.files.filter { existing.contains($0.lowercased()) })
    }
}
