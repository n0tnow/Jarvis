import Foundation

// MARK: - Controlled self-improvement (V0.14, DEC-220)
//
// Levels 0–4; there is NO level 5. JARVIS may find a way to improve itself and write it down (problem · evidence · change · benefit · risk · validation · rollback), and it may
// test low-risk candidates in disposable environments. It NEVER edits its own production source because it found an idea: at level 4, after an explicit HUD approval, the change
// becomes an ORDINARY V0.12 development task (Analysis → Coding → QA → Review, independent review as for any task), started from a recorded checkpoint on a clean tree.
// A failed self-change is never promoted. Nothing here runs while idle, and nothing pulls code from the internet.

enum SelfImprovementMarker { static let constraint = "self-improvement (approved by the user)" }

@MainActor @Observable
final class SelfImprovementService {
    private let repository: JarvisRepository?
    private let learning: LearningService
    private let decisions: AdaptiveDecisionService
    @ObservationIgnored weak var engine: TaskEngine?
    @ObservationIgnored var level: () -> SelfImprovementLevel = { .experiment }
    /// The checkout of JARVIS itself (production). Tests and live tests pass a DISPOSABLE Git fixture instead.
    @ObservationIgnored var selfRepositoryPath: () -> String? = { nil }
    @ObservationIgnored var version: () -> String = { "0.14" }
    @ObservationIgnored var activeMCPs: () -> [String] = { [] }
    @ObservationIgnored var providerState: () -> String = { "unknown" }
    @ObservationIgnored var testsState: () -> String = { "not run in this session" }
    @ObservationIgnored var onEvent: ((String, ActivityKind) -> Void)?
    @ObservationIgnored var clock: () -> Date = { Date() }
    private(set) var revision = 0

    init(repository: JarvisRepository?, learning: LearningService, decisions: AdaptiveDecisionService) {
        self.repository = repository; self.learning = learning; self.decisions = decisions
        decisions.register(.selfImprovement, .init(fingerprint: { [weak self] id in self?.fingerprint(id) }, execute: { [weak self] q in await self?.execute(q) ?? .failure(.init(message: "self-improvement is not available")) }))
    }

    func proposals(limit: Int = 50) -> [ImprovementProposal] { ((try? repository?.improvementProposals(limit: limit)) ?? []) ?? [] }
    func proposal(_ id: UUID) -> ImprovementProposal? { ((try? repository?.improvementProposal(id)) ?? nil) }

    /// A self-improvement task that was running when JARVIS stopped is never promoted: the proposal becomes FAILED (interrupted) and keeps its checkpoint so the user can roll back.
    func reconcileAfterLaunch() {
        for var p in proposals() where p.status == .running {
            p.status = .failed; p.result = "NOT promoted: JARVIS stopped while the task was running. Roll back to \(String((p.checkpoint?.gitHead ?? "?").prefix(7))) if anything was written."; p.updatedAt = clock()
            try? repository?.save(p)
        }
    }

    // MARK: Level 3 — propose

    enum ProposeError: Error, Equatable, CustomStringConvertible {
        case levelTooLow(SelfImprovementLevel), notFound, notImprovement, incomplete, refused(AdmissionRefusal)
        var description: String {
            switch self {
            case .levelTooLow(let l): "Proposing changes to JARVIS itself needs the level “\(SelfImprovementLevel.propose.label)” or higher (now: \(l.label))."
            case .notFound: "That candidate no longer exists."
            case .notImprovement: "Only improvement candidates can become a proposal."
            case .incomplete: "The improvement draft is incomplete (problem, change, benefit, risk, validation and rollback are all required)."
            case .refused(let r): "The proposal was refused: \(r)."
            }
        }
    }

    /// Turns a SOURCE-CODE IMPROVEMENT candidate into a written proposal. Changes nothing: it is text and a plan.
    func propose(from candidateID: UUID) -> Result<ImprovementProposal, ProposeError> {
        let lvl = level()
        guard lvl >= .propose else { return .failure(.levelTooLow(lvl)) }
        guard let c = learning.candidate(candidateID) else { return .failure(.notFound) }
        guard c.kind == .sourceCodeImprovement, let d = c.payload.improvement else { return .failure(.notImprovement) }
        let fields = [d.problem, d.proposedChange, d.expectedBenefit, d.risk, d.validationPlan, d.rollback]
        guard fields.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return .failure(.incomplete) }
        for f in fields + [d.evidenceSummary, d.affectedArea] { if let why = LearningGate.refuseText(f) { return .failure(.refused(why)) } }
        if let existing = proposals().first(where: { $0.candidateID == candidateID && [.proposed, .approved, .running].contains($0.status) }) { return .success(existing) }
        let p = ImprovementProposal(candidateID: candidateID, title: c.title, draft: d, createdAt: clock(), updatedAt: clock())
        try? repository?.save(p)
        _ = learning.move(candidateID, to: .validated, by: "system", reason: "written as a proposal")
        _ = learning.move(candidateID, to: .proposed, by: "system")
        try? repository?.addLearningAudit(LearningAuditEntry(at: clock(), kind: "improvement-proposed", subjectID: p.id.uuidString, detail: c.title, by: "system"))
        onEvent?("Improvement proposed: \(c.title)", .info)
        revision += 1
        return .success(p)
    }

    /// The plain-language explanation the brief asks for: problem, evidence, change, benefit, risk, validation, rollback — factual, no “I have evolved”.
    func explanation(_ p: ImprovementProposal) -> String {
        let d = p.draft
        return "Problem: \(d.problem)\nEvidence: \(d.evidenceSummary)\nProposed change: \(d.proposedChange)\nExpected benefit: \(d.expectedBenefit)\nRisk: \(d.risk)\nValidation plan: \(d.validationPlan)\nRollback: \(d.rollback)"
    }

    // MARK: Level 4 — approved application

    func checkpoint() async -> SelfChangeCheckpoint? {
        guard let path = selfRepositoryPath() else { return nil }
        let git = await GitTool.continuity(at: path)
        guard git.isRepository, let head = git.head else { return nil }
        return SelfChangeCheckpoint(gitHead: head, dirtyFiles: git.dirtyPaths + git.untrackedPaths, testsState: testsState(), version: version(),
                                    activeRuleIDs: learning.activeRules().map { $0.id.uuidString }, activeMCPs: activeMCPs(), activeSkills: [], providerState: providerState(), at: clock())
    }

    /// Asks for the user's decision. Refuses below level 4, on an unreadable repository, and on a dirty or unexplained working tree.
    func requestApplication(_ id: UUID) async -> Result<AdaptiveRequest, ProposeError> {
        guard level() >= .approvedSelfImprovement else { return .failure(.levelTooLow(level())) }
        guard let p = proposal(id), p.status == .proposed else { return .failure(.notFound) }
        guard let q = decisions.request(kind: .selfImprovement, subjectID: id.uuidString, material: material(p), summary: "Apply to JARVIS itself: \(p.title)",
                                        detail: explanation(p), risk: .high) else { return .failure(.notFound) }
        return .success(q)
    }

    private func material(_ p: ImprovementProposal) -> String { "\(p.title)|\(p.status.rawValue)|\(p.draft.proposedChange)|\(p.draft.validationPlan)|\(p.draft.rollback)" }
    private func fingerprint(_ subject: String) -> String? {
        guard let id = UUID(uuidString: subject), let p = proposal(id), p.status == .proposed else { return nil }
        return AdaptiveDecisionService.scopeHash(kind: .selfImprovement, subjectID: subject, material: material(p))
    }

    private func execute(_ q: AdaptiveRequest) async -> Result<String, AdaptiveDecisionService.AdaptiveExecutionError> {
        typealias E = AdaptiveDecisionService.AdaptiveExecutionError
        guard level() >= .approvedSelfImprovement else { return .failure(E(message: "the self-improvement level was lowered after you were asked", refused: true)) }
        guard let id = UUID(uuidString: q.subjectID), var p = proposal(id), p.status == .proposed else { return .failure(E(message: "the proposal is no longer open")) }
        guard let engine, let path = selfRepositoryPath() else { return .failure(E(message: "no repository of JARVIS itself is configured")) }
        guard let cp = await checkpoint() else { return .failure(E(message: "the repository could not be read (not a Git checkout?)", refused: true)) }
        guard cp.isClean else { return .failure(E(message: "the working tree has changes that are not explained (\(cp.dirtyFiles.prefix(3).joined(separator: ", "))) — commit or stash them first; JARVIS does not work on a dirty tree", refused: true)) }
        p.checkpoint = cp
        let goal = "Implement this approved improvement to the project: \(p.draft.proposedChange) Reason: \(p.draft.problem) Keep the change minimal, run the build and the tests, and do not touch unrelated files."
        let r = await engine.submit(goal: goal, kind: .development, workspacePath: path, constraints: [SelfImprovementMarker.constraint], title: "Self-improvement: \(p.title)")
        switch r {
        case .success(let taskID):
            p.status = .running; p.taskID = taskID; p.updatedAt = clock()
            try? repository?.save(p); revision += 1
            if let cid = p.candidateID { _ = learning.move(cid, to: .approved, by: q.decidedBy ?? "hud") }
            return .success("Started the development task for “\(p.title)” on a clean checkpoint (\(String(cp.gitHead.prefix(7)))). It runs through the normal pipeline: analysis, coding, tests and an independent review.")
        case .failure(let e):
            return .failure(E(message: "the task could not be started (\(e))"))
        }
    }

    /// Called when ANY task finishes. A self-improvement task is promoted only when it completed and every required step (tests, review) passed.
    func taskFinished(_ view: TaskView, report: TaskReport?) {
        guard view.task.constraints.contains(SelfImprovementMarker.constraint), var p = proposals().first(where: { $0.taskID == view.task.id }) else { return }
        let ok = view.task.state == .completed
        p.status = ok ? .applied : .failed
        let validated = view.steps.filter { !$0.optional }
        let passed = validated.filter { $0.state == .passed }.count
        p.result = ok ? "Completed: \(passed) of \(validated.count) required steps passed (including the independent review). Run scripts/verify.sh before you keep the change. Roll back with: git revert (base \(String((p.checkpoint?.gitHead ?? "?").prefix(7))))."
                      : "NOT promoted: the task ended \(view.task.state.label.lowercased())\(view.task.failureReason.map { " (\($0))" } ?? ""). Roll back to \(String((p.checkpoint?.gitHead ?? "?").prefix(7))) if anything was written."
        p.updatedAt = clock()
        try? repository?.save(p)
        if let cid = p.candidateID { _ = learning.move(cid, to: ok ? .active : .disabled, by: "system", reason: ok ? "applied" : "failed") }
        try? repository?.addLearningAudit(LearningAuditEntry(at: clock(), kind: ok ? "improvement-applied" : "improvement-failed", subjectID: p.id.uuidString, detail: p.result ?? "", by: "system"))
        onEvent?(ok ? "Self-improvement applied: \(p.title)" : "Self-improvement NOT promoted: \(p.title)", ok ? .success : .warning)
        revision += 1
    }
}
