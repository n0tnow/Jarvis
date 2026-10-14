import Foundation

// MARK: - Skills (V0.14, DEC-222): JARVIS-owned reusable workflow compositions. A Skill is a validated graph template — NOT arbitrary code, NOT a prompt with authority.
// A Skill never executes by itself: matching one only changes which template the V0.12 planner starts from. Planning validation, role contracts, capabilities,
// approvals and every other V0.4/V0.12 rule apply exactly as for any other plan.

enum SkillValidator {
    /// Step types a LEARNED workflow may contain: those that need no typed parameters of their own. Acquisition, import, deletion, delegation and typed Unity/Computer steps are never learned.
    static let learnable: Set<StepType> = [.analysis, .codeChange, .build, .test, .review, .unityCompile, .unityTest]

    static func capabilities(of t: WorkflowTemplate) -> Set<TaskCapability> { t.nodes.reduce(into: Set<TaskCapability>()) { $0.formUnion($1.type.requiredCapabilities) } }

    static func plan(from t: WorkflowTemplate, summary: String) -> TaskPlan {
        TaskPlan(summary: summary, steps: t.nodes.map {
            PlanStep(id: $0.key, title: $0.title.isEmpty ? $0.type.rawValue : $0.title, description: "Part of a learned workflow.", type: $0.type, dependsOn: $0.dependsOn,
                     expected: "", validation: $0.validation.flatMap(ValidationKind.init(rawValue:)) ?? .default(for: $0.type), risk: $0.type.defaultRisk, optional: $0.optional)
        })
    }

    /// Empty = valid. Deterministic: the V0.12 graph validator plus the learned-workflow restrictions.
    static func validate(_ t: WorkflowTemplate) -> [String] {
        var out: [String] = []
        if t.nodes.count < 2 { out.append("a workflow needs at least 2 steps") }
        if t.nodes.count > OrchestrationLimits.maxNodes { out.append("more than \(OrchestrationLimits.maxNodes) steps") }
        for n in t.nodes where !learnable.contains(n.type) { out.append("step type “\(n.type.rawValue)” needs typed parameters and cannot be learned as a generic workflow") }
        guard out.isEmpty else { return out }
        let keys = Set(t.nodes.map(\.key))
        if keys.count != t.nodes.count { out.append("duplicate step keys") }
        for n in t.nodes where !n.dependsOn.allSatisfy(keys.contains) { out.append("step \(n.key) depends on a step that does not exist") }
        guard out.isEmpty else { return out }
        let caps = CapabilitySet(granted: capabilities(of: t))
        let plan = plan(from: t, summary: "learned workflow")
        out += GraphValidator.validate(plan, capabilities: caps).map(\.description)
        out += PlanValidator.validate(plan, kind: .development, capabilities: caps, allowDestructive: false).map(\.description)
        // A change must be followed by a validation; the independent review stays.
        if t.nodes.contains(where: { $0.type == .codeChange }), !t.nodes.contains(where: { $0.type == .test || $0.type == .build || $0.type == .review }) { out.append("a code change without any validation step") }
        return out
    }

    /// Trigger words: significant words present in at least two of the goals the workflow was learned from.
    static func triggers(fromGoals goals: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for g in goals { for w in Set(MemoryText.words(g).filter { $0.count >= 4 }) { counts[w, default: 0] += 1 } }
        return counts.filter { $0.value >= max(2, goals.count / 2) }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(6).map(\.key)
    }
}

/// A built-in Skill: documents an existing deterministic template under the Skill surface. `templateName` is the V0.12 template it stands for.
enum BuiltInSkills {
    static let all: [(name: String, description: String, template: String, triggers: [String], caps: [TaskCapability])] = [
        ("Unity Asset Suitability", "Research an asset, check its licence/price and Unity compatibility, recommend — never acquire or import.", "asset-suitability", ["asset", "suitable", "licence", "license", "compatible"], [.researchWeb, .readProject]),
        ("Fix, Test and Review", "Analyse → change → build → test → independent review.", "fix-flow", ["fix", "bug", "failing", "broken"], [.readProject, .writeProject, .runBuild, .runTests]),
        ("Investigate", "Read-only investigation of a project question.", "investigation", ["investigate", "analyze", "analyse", "explain"], [.readProject])
    ]
}

@MainActor @Observable
final class SkillRegistry {
    private let repository: JarvisRepository?
    @ObservationIgnored var onEvent: ((String, ActivityKind) -> Void)?
    @ObservationIgnored var clock: () -> Date = { Date() }
    private(set) var revision = 0

    init(repository: JarvisRepository?) { self.repository = repository }

    func all() -> [Skill] { ((try? repository?.skills()) ?? []) ?? [] }
    func active() -> [Skill] { all().filter { $0.status == .active } }
    func skill(_ id: UUID) -> Skill? { ((try? repository?.skill(id)) ?? nil) }

    /// Registers the built-in Skills once (idempotent by name).
    func seedBuiltIns() {
        guard let repository else { return }
        let existing = Set(all().filter(\.builtIn).map(\.name))
        for b in BuiltInSkills.all where !existing.contains(b.name) {
            let s = Skill(name: b.name, description: b.description, scope: .global, version: 1, status: .active, triggerPatterns: b.triggers, requiredCapabilities: b.caps.map(\.rawValue), requiredMCPs: [],
                          graph: WorkflowTemplate(nodes: []), approvalGates: ["destructive steps ask", "import and acquisition are separate approvals"], validationGates: ["V0.12 graph validation", "role contracts"],
                          maxNodes: OrchestrationLimits.maxNodes, origin: "built in (\(b.template))", evidence: [], createdAt: clock(), builtIn: true)
            try? repository.save(s, reason: "built in")
        }
    }

    @discardableResult
    func setStatus(_ id: UUID, _ status: SkillStatus, reason: String) -> Bool {
        guard var s = skill(id) else { return false }
        s.status = status
        try? repository?.save(s, reason: reason); revision += 1
        try? repository?.addLearningAudit(LearningAuditEntry(at: clock(), kind: "skill-\(status.rawValue)", subjectID: id.uuidString, detail: s.name, by: "hud"))
        return true
    }

    func recordOutcome(_ id: UUID, success: Bool) {
        guard var s = skill(id) else { return }
        if success { s.successCount += 1 } else { s.failureCount += 1 }
        s.lastUsedAt = clock()
        try? repository?.save(s); revision += 1
    }

    // MARK: Matching (the intent must match; the capabilities must be available; learned skills must have a track record)

    struct Match: Equatable { var skill: Skill; var score: Double }

    func match(goal: String, kind: TaskKind, available: Set<TaskCapability>, preferred: [String] = []) -> Match? {
        let words = Set(MemoryText.words(goal))
        var best: Match?
        for s in active() where !s.builtIn {                       // built-in Skills describe templates the planner already routes to deterministically
            guard kind == .development || kind == .readOnlyAnalysis else { continue }
            let hits = s.triggerPatterns.filter { words.contains($0) }.count
            guard hits >= min(2, max(1, s.triggerPatterns.count)), !s.triggerPatterns.isEmpty else { continue }
            guard Set(s.requiredCapabilities.compactMap(TaskCapability.init(rawValue:))).isSubset(of: available) else { continue }
            guard s.successCount >= s.failureCount else { continue }                         // evidence stays current: a skill that keeps failing is not preferred
            guard SkillValidator.validate(s.graph).isEmpty else { continue }
            let score = Double(hits) + (preferred.contains(s.name) ? 0.5 : 0) + Double(s.successCount) * 0.05
            if best == nil || score > best!.score { best = Match(skill: s, score: score) }
        }
        return best
    }

    func orchestratedPlan(for m: Match, goal: String) -> OrchestratedPlan {
        OrchestratedPlan(plan: SkillValidator.plan(from: m.skill.graph, summary: "Skill: \(m.skill.name)"), template: "skill:\(m.skill.id.uuidString)",
                         rationale: "the learned Skill “\(m.skill.name)” matches this goal (\(m.skill.successCount) earlier success(es))", addsResearch: false, addsComputer: false)
    }

    /// Learned-skill triggers are derived from the goals of the tasks the workflow was learned from.
    func deriveTriggers(from evidence: [LearningEvidenceRef]) -> [String] {
        let goals = evidence.filter { $0.kind == .task }.compactMap { UUID(uuidString: $0.sourceID) }.compactMap { ((try? repository?.engineTask($0)) ?? nil)?.goal }
        return SkillValidator.triggers(fromGoals: goals)
    }
}
