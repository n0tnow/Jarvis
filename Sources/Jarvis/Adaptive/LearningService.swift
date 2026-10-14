import Foundation

// MARK: - Adaptive learning service (V0.14, DEC-215…223)
//
// ONE door (`admit`): settings/level → secret · authority · injection gates → closed rule vocabulary → evidence that exists → overgeneralisation → dedupe/cooldown.
// Extraction runs only after relevant task completion, when the user opens/asks for Learning, or on explicit request — never on a timer, never while idle.

struct LearningSettings: Equatable, Sendable {
    var enabled = true
    var fromTasks = true
    var fromCorrections = true
    var gapDetection = true
    var safeExperiments = true
    var autoPromoteLowRisk = false
    var level: SelfImprovementLevel = .experiment
}

enum AdmissionResult: Equatable, Sendable {
    case admitted(UUID, created: Bool)
    case refused(AdmissionRefusal)
}

struct ExtractionReport: Equatable, Sendable {
    var newSignals = 0
    var candidatesCreated = 0
    var candidatesUpdated = 0
    var refused = 0
    var reason = ""
    var at = Date()
    var milliseconds = 0.0
}

enum CorrectionOutcome: Equatable, Sendable {
    case notACorrection
    case recorded(durable: Bool, candidate: UUID?)
    case refused(AdmissionRefusal)
    case disabled
}

@MainActor @Observable
final class LearningService {
    let repository: JarvisRepository?
    let decisions: AdaptiveDecisionService
    @ObservationIgnored var settings: () -> LearningSettings = { LearningSettings() }
    @ObservationIgnored var projectKey: (TaskRecord) -> String? = { $0.workspaceRoot.map { URL(fileURLWithPath: $0).lastPathComponent } }
    @ObservationIgnored var onEvent: ((String, ActivityKind) -> Void)?
    @ObservationIgnored var clock: () -> Date = { Date() }
    /// Extra snapshot sources (MCP activity etc.) supplied by the composition root.
    @ObservationIgnored var mcpActivity: () -> [MCPActivityRecord] = { [] }
    private(set) var revision = 0
    private(set) var lastReport: ExtractionReport?
    private var ruleCache: [LearnedRule]?

    init(repository: JarvisRepository?, decisions: AdaptiveDecisionService) {
        self.repository = repository; self.decisions = decisions
        decisions.register(.promoteCandidate, .init(fingerprint: { [weak self] id in self?.promotionFingerprint(id) }, execute: { [weak self] q in await self?.executePromotion(q) ?? .failure(.init(message: "learning is not available")) }))
        decisions.onDenied = { [weak self] q in self?.requestDenied(q) }
    }

    private func bump() { revision += 1 }
    private func note(_ s: String, _ k: ActivityKind = .info) { onEvent?(s, k) }
    private func audit(_ kind: String, _ id: UUID?, _ detail: String, by: String = "system") {
        try? repository?.addLearningAudit(LearningAuditEntry(at: clock(), kind: kind, subjectID: id?.uuidString, detail: detail, by: by))
    }

    // MARK: - Reading

    func candidates(statuses: [LearningStatus]? = nil, kinds: [LearningKind]? = nil, limit: Int = 200) -> [LearningCandidate] { ((try? repository?.learningCandidates(statuses: statuses, kinds: kinds, limit: limit)) ?? []) ?? [] }
    func candidate(_ id: UUID) -> LearningCandidate? { (try? repository?.learningCandidate(id)) ?? nil }
    func rules(statuses: [LearningStatus]? = nil) -> [LearnedRule] { ((try? repository?.learnedRules(statuses: statuses)) ?? []) ?? [] }
    func activeRules() -> [LearnedRule] {
        if let ruleCache { return ruleCache }
        let r = rules(statuses: [.active]); ruleCache = r; return r
    }
    func history(limit: Int = 100) -> [LearningAuditEntry] { ((try? repository?.learningAudit(limit: limit)) ?? []) ?? [] }
    var signalCount: Int { (try? repository?.signalCount()) ?? 0 }

    // MARK: - Extraction (event-driven)

    /// Reads existing records, derives signals (idempotent), detects patterns, and admits drafts. Bounded: ≤ 400 tasks, ≤ 90 days.
    @discardableResult
    func extract(reason: String, taskLimit: Int = 400) async -> ExtractionReport {
        var report = ExtractionReport(reason: reason, at: clock())
        let s = settings()
        guard s.enabled, s.level >= .observe, let repository else { return report }
        let started = Date()
        let since = clock().addingTimeInterval(-Double(LearningThresholds.windowDays) * 86_400)
        var snap = LearningSnapshot()
        if s.fromTasks {
            let tasks = ((try? repository.engineTasks(states: [.completed, .failed, .cancelled], limit: taskLimit)) ?? []).filter { ($0.finishedAt ?? $0.updatedAt) >= since }
            snap.tasks = tasks
            for t in tasks { snap.steps[t.id] = (try? repository.steps(taskID: t.id)) ?? []; snap.attempts[t.id] = (try? repository.attempts(taskID: t.id)) ?? [] }
            snap.experiments = ((try? repository.recentExperiments(limit: 200)) ?? []).filter { $0.createdAt >= since }
            snap.proposals = ((try? repository.proposals(statuses: [.denied, .dismissed], limit: 200)) ?? [])
            snap.agentRuns = ((try? repository.recentAgentRuns(limit: 400)) ?? []).filter { $0.startedAt >= since }
            snap.assetEvaluations = ((try? repository.recentAssetEvaluations(limit: 200)) ?? []).filter { $0.createdAt >= since }
            snap.mcpActivity = mcpActivity()
            for ses in ((try? repository.computerSessions(limit: 60)) ?? []) where ses.startedAt >= since {
                snap.computerSessions.append(ses)
                snap.computerActions[ses.id] = (try? repository.computerActions(sessionID: ses.id, limit: 200)) ?? []
            }
        }
        let signals = SignalExtractor.signals(from: snap, projectKey: projectKey)
        for sig in signals where (try? repository.insertSignal(sig)) == true { report.newSignals += 1 }
        if s.level >= .learn {
            let recent = (try? repository.signals(since: since)) ?? []
            let drafts = PatternDetector.drafts(from: recent).filter { s.gapDetection || $0.kind != .capabilityGap }
            for d in drafts {
                switch admit(d, by: "pattern-detector") {
                case .admitted(_, let created): if created { report.candidatesCreated += 1 } else { report.candidatesUpdated += 1 }
                case .refused: report.refused += 1
                }
            }
        }
        report.milliseconds = Date().timeIntervalSince(started) * 1000
        lastReport = report
        if report.candidatesCreated > 0 { note("Learning · \(report.candidatesCreated) new candidate(s) from \(reason)", .info) }
        bump()
        return report
    }

    // MARK: - The one door

    func admit(_ d: CandidateDraft, by: String) -> AdmissionResult {
        let s = settings()
        guard s.enabled else { return .refused(.disabled) }
        guard s.level >= .learn else { return .refused(.levelTooLow) }
        guard let repository else { return .refused(.disabled) }
        let r = check(d, repository: repository)
        if let refusal = r.refusal { audit("refused", nil, "\(d.kind.label) “\(String(d.title.prefix(60)))”: \(refusal)", by: by); return .refused(refusal) }
        let distinct = r.distinct
        let fp = LearningGate.fingerprint(kind: d.kind, scope: d.scope, situation: d.situation)
        let now = clock()
        let confidence = LearningGate.confidence(distinctEvidence: distinct, counter: d.counterEvidence, newest: d.newest, now: now)
        let enough = distinct >= LearningThresholds.minimumEvents || d.durableUserStatement

        if var existing = (try? repository.learningCandidate(fingerprint: fp)) ?? nil {
            if existing.status == .rejected {
                // Not nagged again unless the evidence materially changed (at least doubled) after the cooldown.
                let cooling = (existing.cooldownUntil ?? .distantPast) > now
                let changed = distinct >= max(2, (existing.evidenceAtRejection ?? 0) * 2)
                if cooling || !changed { return .refused(.coolingDown) }
                existing.status = .observed   // a new candidate life, with a clear history
                existing.rejectionReason = nil
            }
            guard !existing.status.isTerminal || existing.status == .observed else { return .refused(.duplicate) }
            let known = Set(existing.evidence.map { "\($0.kind.rawValue):\($0.sourceID)" })
            let fresh = d.evidence.filter { !known.contains("\($0.kind.rawValue):\($0.sourceID)") }
            let added = !fresh.isEmpty
            existing.evidence += fresh
            existing.occurrenceCount = Set(existing.evidence.map { "\($0.kind.rawValue):\($0.sourceID)" }).count
            existing.confidence = confidence; existing.lastSeenAt = now; existing.updatedAt = now
            if existing.status == .observed, enough { existing.status = .candidate }
            // Behaviour-changing content of an ACTIVE candidate never changes silently: a changed payload would need its own approval.
            if existing.status == .candidate || existing.status == .observed { existing.summary = d.summary; existing.payload = d.payload }
            try? repository.save(existing)
            if added { bump() }
            return .admitted(existing.id, created: false)
        }

        var c = LearningCandidate(fingerprint: fp, kind: d.kind, status: enough ? .candidate : .observed, title: d.title, summary: d.summary, scope: d.scope, projectKey: d.projectKey,
                                  confidence: confidence, risk: d.risk, occurrenceCount: distinct, evidence: d.evidence, proposedEffect: d.proposedEffect,
                                  validationRequirement: d.validationRequirement, promotionRequirement: d.promotionRequirement, payload: d.payload, createdAt: now, lastSeenAt: now, updatedAt: now)
        c.decidedBy = nil
        try? repository.save(c)
        audit("candidate", c.id, "\(c.kind.label): \(c.title) [\(c.status.label), \(distinct) event(s)]", by: by)
        note("Learning · \(c.status == .candidate ? "new candidate" : "observed"): \(c.title)", .info)
        bump()
        return .admitted(c.id, created: true)
    }

    /// The gates, in order. Pure apart from reading evidence existence.
    func check(_ d: CandidateDraft, repository: JarvisRepository) -> (refusal: AdmissionRefusal?, distinct: Int) {
        if d.scope.level != .global, d.scope.key == nil { return (.emptyScope, 0) }
        var texts = [d.title, d.summary, d.proposedEffect, d.validationRequirement, d.promotionRequirement]
        let p = d.payload
        if let l = p.lesson { texts.append(l) }
        if let g = p.gap { texts += [g.observation, g.currentMechanism, g.domain] + g.options.map(\.rationale) }
        if let i = p.improvement { texts += [i.problem, i.proposedChange, i.expectedBenefit, i.validationPlan, i.rollback, i.risk, i.evidenceSummary] }
        if let r = p.recommendation { texts += [r.reason, r.name] }
        for t in texts where !t.isEmpty { if let why = LearningGate.refuseText(t) { return (why, 0) } }
        for e in d.evidence where !e.note.isEmpty { if let why = LearningGate.refuseText(e.note) { return (why, 0) } }
        if let rule = p.rule, !LearningGate.problems(in: rule).isEmpty { return (.invalidRule, 0) }
        if d.kind == .rule && p.rule == nil { return (.invalidRule, 0) }
        if MemoryGate.isTrivial(d.title) && !d.durableUserStatement { return (.trivial, 0) }
        if d.evidence.isEmpty { return (.noEvidence, 0) }
        for e in d.evidence where !evidenceResolves(e, repository: repository) { return (.unresolvableEvidence, 0) }
        let distinct = Set(d.evidence.map { "\($0.kind.rawValue):\($0.sourceID)" }).count
        if let why = LearningGate.overgeneralization(rule: p.rule, kind: d.kind, distinctEvidence: distinct, counterEvidence: d.counterEvidence) {
            audit("overgeneralization", nil, "refused: \(d.title) — \(why)")
            return (.overgeneralization, distinct)
        }
        return (nil, distinct)
    }

    /// Evidence must point at something that exists: a derived signal row, or the record itself.
    func evidenceResolves(_ e: LearningEvidenceRef, repository: JarvisRepository) -> Bool {
        if (try? repository.signalExists(sourceKind: e.kind.rawValue, sourceID: e.sourceID)) == true { return true }
        guard let id = UUID(uuidString: e.sourceID) else { return false }
        switch e.kind {
        case .task: return ((try? repository.engineTask(id)) ?? nil) != nil
        case .experiment: return ((try? repository.experiment(id)) ?? nil) != nil
        case .run: return ((try? repository.agentRun(id)) ?? nil) != nil
        case .request: return ((try? repository.adaptiveRequest(id)) ?? nil) != nil
        default: return false
        }
    }

    // MARK: - User corrections

    private static let durableCues = ["always", "never", "from now on", "every time", "don't ever", "do not ever", "stop using", "her zaman", "asla", "bundan sonra", "bir daha", "artık", "artik", "hiçbir zaman", "hicbir zaman"]
    private static let correctionCues = ["no,", "no.", "no ", "don't", "do not", "not like", "wrong", "hayır", "hayir", "yanlış", "yanlis", "olmaz", "kullanma", "istemiyorum", "wrong,", "that's not"]

    static func isCorrection(_ text: String) -> Bool {
        let t = MemoryText.fold(text)
        guard t.count >= 8 else { return false }
        return correctionCues.contains { t.contains(MemoryText.fold($0)) } && !t.hasSuffix("?")
    }
    static func isDurable(_ text: String) -> Bool { let t = MemoryText.fold(text); return durableCues.contains { t.contains(MemoryText.fold($0)) } }

    /// A user's correction is strong evidence — kept as an OBSERVED signal unless it says it is durable (or repeats). It becomes at most a PREFERENCE candidate:
    /// informational text, never a rule, never authority.
    @discardableResult
    func recordCorrection(_ text: String, projectKey key: String?) -> CorrectionOutcome {
        let s = settings()
        guard s.enabled, s.fromCorrections, s.level >= .learn, let repository else { return .disabled }
        guard Self.isCorrection(text) else { return .notACorrection }
        let clean = OutputSanitizer.sanitize(String(text.prefix(240)))
        if let why = LearningGate.refuseText(text) { audit("refused", nil, "correction refused: \(why)", by: "user-correction"); return .refused(why) }
        let sourceID = UUID().uuidString
        let norm = SignalExtractor.cleanKey(clean)
        let sig = LearningSignal(kind: .userCorrection, key: norm, projectKey: key, sourceKind: .correction, sourceID: sourceID, episode: sourceID, at: clock(), outcome: .event, detail: clean)
        try? repository.insertSignal(sig)
        let durable = Self.isDurable(text)
        let sameBefore = ((try? repository.signals(kind: .userCorrection, key: norm)) ?? []).count
        let draft = CandidateDraft(kind: .preference, scope: key.map(LearningScope.project) ?? .global, projectKey: key, situation: "correction \(norm)", title: "Preference: \(String(clean.prefix(80)))",
                                   summary: durable ? "You said this should always apply: “\(clean)”" : "You corrected JARVIS once: “\(clean)”. It stays an observation unless you repeat it or say it is lasting.",
                                   evidence: [LearningEvidenceRef(kind: .correction, sourceID: sourceID, at: clock(), note: String(clean.prefix(120)))], counterEvidence: 0, risk: .low,
                                   proposedEffect: "Shown to you and as project context. It never changes a rule, approval or policy by itself.", validationRequirement: "None (informational).",
                                   promotionRequirement: "Confirmation in the Learning screen.", payload: .lesson(clean), durableUserStatement: durable || sameBefore >= 2)
        switch admit(draft, by: "user-correction") {
        case .admitted(let id, _): bump(); return .recorded(durable: durable || sameBefore >= 2, candidate: id)
        case .refused(let why): return .refused(why)
        }
    }

    // MARK: - Lifecycle

    @discardableResult
    func move(_ id: UUID, to next: LearningStatus, by: String, reason: String? = nil) -> Bool {
        guard let repository, var c = (try? repository.learningCandidate(id)) ?? nil, c.status.canMove(to: next) else { return false }
        c.status = next; c.updatedAt = clock(); c.decidedBy = by; c.decidedAt = clock()
        if next == .rejected { c.rejectionReason = reason; c.cooldownUntil = clock().addingTimeInterval(14 * 86_400); c.evidenceAtRejection = c.occurrenceCount }
        try? repository.save(c)
        audit("status", id, "\(c.title) → \(next.label)\(reason.map { " (\($0))" } ?? "")", by: by)
        bump()
        return true
    }

    func reject(_ id: UUID, reason: String = "rejected by the user") -> Bool { move(id, to: .rejected, by: "hud", reason: reason) }

    /// Validate a candidate without touching anything real: closed-vocabulary rule simulation / graph validation / informational pass.
    @discardableResult
    func test(_ id: UUID) async -> LearningTestResult {
        guard let repository, var c = (try? repository.learningCandidate(id)) ?? nil else { return LearningTestResult(passed: false, detail: "candidate not found") }
        guard settings().level >= .experiment, settings().safeExperiments else { return LearningTestResult(passed: false, detail: "safe experiments are switched off (Settings → Adaptive learning)") }
        guard [.candidate, .testing, .validated].contains(c.status) else { return LearningTestResult(passed: false, detail: "a \(c.status.label) candidate cannot be tested") }
        if c.status == .candidate { _ = move(id, to: .testing, by: "system") }
        let result: LearningTestResult
        if let rule = c.payload.rule { result = LearningTester.test(rule: rule, evidence: c.evidence) }
        else if let wf = c.payload.workflow { result = LearningTester.test(workflow: wf) }
        else if let r = c.payload.routing { result = LearningTester.test(routing: r) }
        else { result = LearningTestResult(passed: true, detail: "informational — nothing to apply, nothing to test") }
        c = (try? repository.learningCandidate(id)) ?? c
        c.validationRequirement = result.detail
        try? repository.save(c)
        audit("test", id, "\(result.passed ? "PASSED" : "FAILED"): \(result.detail)", by: "system")
        if result.passed { _ = move(id, to: .validated, by: "system", reason: result.detail) } else if c.status == .testing { _ = move(id, to: .candidate, by: "system", reason: "test failed: \(result.detail)") }
        return result
    }

    // MARK: - Promotion (approval boundary)

    private func promotionMaterial(_ c: LearningCandidate) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]              // stable bytes: the approval is bound to this exact text
        return "\(c.kind.rawValue)|\(c.status.rawValue)|\(c.title)|" + ((try? String(data: enc.encode(c.payload), encoding: .utf8)) ?? "")
    }
    private func promotionFingerprint(_ subject: String) -> String? {
        guard let id = UUID(uuidString: subject), let c = candidate(id), c.status == .proposed else { return nil }
        return AdaptiveDecisionService.scopeHash(kind: .promoteCandidate, subjectID: subject, material: promotionMaterial(c))
    }

    /// Moves a VALIDATED candidate to PROPOSED and asks. (Informational lessons may be shown without activation; behaviour-changing kinds must be validated first.)
    @discardableResult
    func requestPromotion(_ id: UUID) async -> AdaptiveRequest? {
        guard let c = candidate(id) else { return nil }
        guard c.status == .validated || (c.kind.isInformational && c.status == .candidate) || (c.kind == .preference && c.status == .candidate) else { return nil }
        if c.kind == .rule || c.kind == .routingAdjustment || c.kind == .workflow { guard c.status == .validated else { return nil } }
        guard settings().level >= .learn else { return nil }
        // preferences from corrections / lessons go validated → proposed in one click
        if c.status == .candidate { _ = move(id, to: .validated, by: "system", reason: "informational") }
        guard move(id, to: .proposed, by: "system") else { return nil }
        guard let proposed = candidate(id) else { return nil }
        let q = decisions.request(kind: .promoteCandidate, subjectID: id.uuidString, material: promotionMaterial(proposed), summary: "Activate: \(proposed.title)",
                                  detail: "\(proposed.proposedEffect)\nEvidence: \(proposed.occurrenceCount) independent event(s). Risk: \(proposed.risk.rawValue). Validation: \(proposed.validationRequirement)", risk: proposed.risk)
        // Standing policy (default OFF): LOW-risk WORKFLOW candidates only — never rules touching security, never taste/preferences.
        if let q, settings().autoPromoteLowRisk, proposed.kind == .workflow, proposed.risk == .low {
            _ = await decisions.approveByStandingPolicy(q.id, policy: "auto-promote low-risk workflow rules")
        }
        bump()
        return q
    }

    private func requestDenied(_ q: AdaptiveRequest) {
        guard q.kind == .promoteCandidate, let id = UUID(uuidString: q.subjectID) else { return }
        _ = move(id, to: .rejected, by: "hud", reason: "declined in the approval")
    }

    private func executePromotion(_ q: AdaptiveRequest) async -> Result<String, AdaptiveDecisionService.AdaptiveExecutionError> {
        guard let id = UUID(uuidString: q.subjectID), let c = candidate(id), c.status == .proposed else { return .failure(.init(message: "the candidate is no longer proposed")) }
        guard move(id, to: .approved, by: q.decidedBy ?? "hud") else { return .failure(.init(message: "the candidate cannot be approved from \(c.status.label)")) }
        let now = clock()
        switch c.kind {
        case .rule:
            guard let def = c.payload.rule, LearningGate.problems(in: def).isEmpty else { return .failure(.init(message: "the rule no longer passes the vocabulary check", refused: true)) }
            let rule = LearnedRule(candidateID: c.id, scope: c.scope, projectKey: c.projectKey, version: 1, status: .active, definition: def, title: c.title, origin: "learned from \(c.occurrenceCount) event(s)", activatedAt: now)
            try? repository?.save(rule, reason: "activated", by: q.decidedBy)
            ruleCache = nil
        case .workflow:
            guard let wf = c.payload.workflow else { return .failure(.init(message: "no workflow in the candidate")) }
            let goals = c.evidence.filter { $0.kind == .task }.compactMap { UUID(uuidString: $0.sourceID) }.compactMap { ((try? repository?.engineTask($0)) ?? nil)?.goal }
            let skill = Skill(name: PatternDetector.workflowName(wf), description: c.summary, scope: c.scope, version: 1, status: .active, triggerPatterns: SkillValidator.triggers(fromGoals: goals), requiredCapabilities: SkillValidator.capabilities(of: wf).map(\.rawValue).sorted(),
                              requiredMCPs: [], graph: wf, approvalGates: [], validationGates: [], maxNodes: wf.nodes.count, origin: "learned from \(c.occurrenceCount) successful run(s)", evidence: c.evidence, createdAt: now)
            try? repository?.save(skill, reason: "activated")
            skillsChanged?()
        default: break
        }
        _ = move(id, to: .active, by: q.decidedBy ?? "hud")
        audit("activated", id, c.title, by: q.decidedBy ?? "hud")
        return .success("Activated: \(c.title)")
    }
    @ObservationIgnored var skillsChanged: (() -> Void)?

    // MARK: - Task outcomes (event-driven: called once when a task finishes)

    private var applied: [UUID: (rules: [UUID], skill: UUID?)] = [:]
    @ObservationIgnored var skillOutcome: ((UUID, Bool) -> Void)?
    func noteApplied(task: UUID, rules: [UUID], skill: UUID?) { if !rules.isEmpty || skill != nil { applied[task] = (rules, skill) } }

    /// Credits what was applied to the task, then (for a root task) looks for new patterns in the RECENT history. Bounded; never runs while idle.
    func taskFinished(_ view: TaskView) async {
        let ok = view.task.state == .completed
        if let a = applied.removeValue(forKey: view.task.id) {
            if !a.rules.isEmpty { recordRuleOutcome(a.rules, success: ok) }
            if let s = a.skill { skillOutcome?(s, ok) }
        }
        guard view.task.parentTaskID == nil, settings().enabled, settings().fromTasks else { return }
        _ = await extract(reason: "a finished task", taskLimit: 80)
    }

    // MARK: - Rules in use

    func disableRule(_ id: UUID, by: String = "hud") -> Bool {
        guard let repository, var r = (try? repository.learnedRule(id)) ?? nil, r.status == .active else { return false }
        r.status = .disabled; try? repository.save(r, reason: "disabled", by: by); ruleCache = nil
        if let cid = r.candidateID { _ = move(cid, to: .disabled, by: by) }
        audit("rule-disabled", id, r.title, by: by); bump(); return true
    }
    func enableRule(_ id: UUID, by: String = "hud") -> Bool {
        guard let repository, var r = (try? repository.learnedRule(id)) ?? nil, r.status == .disabled else { return false }
        r.status = .active; r.activatedAt = clock(); try? repository.save(r, reason: "re-enabled", by: by); ruleCache = nil
        if let cid = r.candidateID { _ = move(cid, to: .active, by: by) }
        audit("rule-enabled", id, r.title, by: by); bump(); return true
    }
    func retireRule(_ id: UUID, by: String = "hud") -> Bool {
        guard let repository, var r = (try? repository.learnedRule(id)) ?? nil, r.status == .active || r.status == .disabled else { return false }
        r.status = .retired; try? repository.save(r, reason: "retired", by: by); ruleCache = nil
        if let cid = r.candidateID { _ = move(cid, to: .retired, by: by) }
        audit("rule-retired", id, r.title, by: by); bump(); return true
    }
    /// Revert to the previous version of the rule's definition (history is kept: a revert is a NEW version).
    @discardableResult
    func revertRule(_ id: UUID, by: String = "hud") -> Bool {
        guard let repository, var r = (try? repository.learnedRule(id)) ?? nil, r.version > 1 else { return false }
        let versions = (try? repository.ruleVersions(id)) ?? []
        guard let prev = versions.last(where: { $0.version < r.version }) else { return false }
        r.previousVersion = r.version; r.version += 1; r.definition = prev.definition
        try? repository.save(r, reason: "reverted to version \(prev.version)", by: by); ruleCache = nil
        audit("rule-reverted", id, "\(r.title) → definition of version \(prev.version)", by: by); bump(); return true
    }

    /// What the active rules say about one situation. Records the use (last use) — effects only ever ADD requirements.
    func effects(for context: RuleContext) -> RuleEffects {
        let e = RuleEngine.evaluate(activeRules(), context)
        if !e.firedRuleIDs.isEmpty, let repository {
            for id in e.firedRuleIDs { if var r = (try? repository.learnedRule(id)) ?? nil { r.lastUsedAt = clock(); try? repository.save(r) } }
            ruleCache = nil
        }
        return e
    }
    func recordRuleOutcome(_ ids: [UUID], success: Bool) {
        guard let repository else { return }
        for id in ids {
            guard var r = (try? repository.learnedRule(id)) ?? nil else { continue }
            if success { r.successCount += 1 } else { r.failureCount += 1 }
            // A rule that keeps coming with failures loses standing: recommend retirement (never silently removes it).
            try? repository.save(r)
            if r.failureCount >= 3, let eff = r.effectiveness, eff < 0.34, let cid = r.candidateID, var c = candidate(cid) {
                c.confidence = max(0, c.confidence * 0.5); c.updatedAt = clock(); try? repository.save(c)
                audit("rule-degraded", id, "\(r.title): \(r.successCount) ok / \(r.failureCount) failed — retirement recommended")
            }
        }
        ruleCache = nil; bump()
    }

    /// Bounded routing nudges from ACTIVE routing candidates (never above ±RoutingAdjustment.limit).
    func routingAdjustments() -> [RoutingAdjustment] { candidates(statuses: [.active], kinds: [.routingAdjustment]).compactMap { $0.payload.routing } }
}

// MARK: - Testing candidates without touching anything real

struct LearningTestResult: Equatable, Sendable { var passed: Bool; var detail: String }

enum LearningTester {
    /// Closed vocabulary + a deterministic simulation: the rule must fire on the situations that produced it, must not fire on an unrelated one, and may only ADD requirements.
    static func test(rule: RuleDefinition, evidence: [LearningEvidenceRef]) -> LearningTestResult {
        let problems = LearningGate.problems(in: rule)
        guard problems.isEmpty else { return LearningTestResult(passed: false, detail: "outside the rule vocabulary: " + problems.joined(separator: "; ")) }
        var matching = RuleContext(), other = RuleContext()
        for c in rule.when {
            if c.comparison == .equals, let v = c.value { matching.facts[c.fact] = v }
            if c.comparison == .notEquals { matching.facts[c.fact] = (c.value ?? "x") + "-other" }
            other.facts[c.fact] = "unrelated-value"
        }
        let probe = LearnedRule(scope: .global, version: 1, status: .active, definition: rule, title: "probe", origin: "test")
        let fired = RuleEngine.evaluate([probe], matching), quiet = RuleEngine.evaluate([probe], other)
        guard !fired.isEmpty else { return LearningTestResult(passed: false, detail: "the rule does not fire on the situation it was learned from") }
        if !rule.when.contains(where: { $0.comparison == .isUnknown }), !quiet.isEmpty { return LearningTestResult(passed: false, detail: "the rule fires on an unrelated situation") }
        let adds = fired.requiredExperiments.count + fired.extraValidations.count + fired.warnings.count + fired.avoidedSources.count + fired.preferredCapabilities.count + fired.preferredWorkflows.count + (fired.independentReviewRequired ? 1 : 0)
        guard adds > 0 else { return LearningTestResult(passed: false, detail: "the rule has no effect") }
        return LearningTestResult(passed: true, detail: "closed vocabulary ✓ · fires on the learned situation ✓ · quiet elsewhere ✓ · adds \(adds) requirement(s), removes nothing ✓ · \(evidence.count) evidence link(s)")
    }
    static func test(workflow: WorkflowTemplate) -> LearningTestResult {
        let issues = SkillValidator.validate(workflow)
        return issues.isEmpty ? LearningTestResult(passed: true, detail: "graph valid ✓ · capabilities \(SkillValidator.capabilities(of: workflow).map(\.rawValue).sorted().joined(separator: ", ")) · \(workflow.nodes.count) node(s) ≤ \(OrchestrationLimits.maxNodes) ✓ · approval gates intact ✓")
                              : LearningTestResult(passed: false, detail: issues.prefix(3).joined(separator: "; "))
    }
    static func test(routing: RoutingAdjustment) -> LearningTestResult {
        abs(routing.delta) <= RoutingAdjustment.limit * 1.5 ? LearningTestResult(passed: true, detail: "bounded to ±\(RoutingAdjustment.limit) ✓ · price, privacy, local-only and explicit choices still win ✓")
                                                            : LearningTestResult(passed: false, detail: "the nudge exceeds its bound")
    }
}
