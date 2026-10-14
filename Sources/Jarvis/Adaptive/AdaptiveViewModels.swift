import Foundation
import Observation

// MARK: - View models for the Learning and Capabilities screens (V0.14). Read on appear and when a service reports a change — never on a timer. Every decision button passes
// `.hud`: there is no other way to decide a request.

@MainActor @Observable
final class LearningViewModel {
    enum Tab: String, CaseIterable, Identifiable {
        case insights = "Insights", candidates = "Candidate rules", rules = "Active rules", skills = "Skills", gaps = "Capability gaps", proposals = "Self-improvement", history = "History"
        var id: String { rawValue }
    }
    private let learning: LearningService
    private let skillsRegistry: SkillRegistry
    private let decisions: AdaptiveDecisionService
    private let selfImprovement: SelfImprovementService
    let preferences: Preferences

    var tab: Tab = .insights
    var message: String?
    var busy = false
    private(set) var insights: [LearningCandidate] = []
    private(set) var candidates: [LearningCandidate] = []
    private(set) var rules: [LearnedRule] = []
    private(set) var skills: [Skill] = []
    private(set) var gaps: [LearningCandidate] = []
    private(set) var improvementCandidates: [LearningCandidate] = []
    private(set) var proposals: [ImprovementProposal] = []
    private(set) var history: [LearningAuditEntry] = []
    private(set) var pending: [AdaptiveRequest] = []
    private(set) var signals = 0
    var selected: UUID?

    init(learning: LearningService, skills: SkillRegistry, decisions: AdaptiveDecisionService, selfImprovement: SelfImprovementService, preferences: Preferences) {
        self.learning = learning; self.skillsRegistry = skills; self.decisions = decisions; self.selfImprovement = selfImprovement; self.preferences = preferences
    }

    var level: SelfImprovementLevel { preferences.selfImprovementLevel }
    var isEnabled: Bool { preferences.adaptiveLearningEnabled }
    var selectedCandidate: LearningCandidate? { selected.flatMap(learning.candidate) }
    var suggestionCount: Int { candidates.filter { [.candidate, .validated, .proposed].contains($0.status) }.count + insights.filter { $0.status == .candidate }.count + pending.count }

    func refresh() {
        let open: [LearningStatus] = [.observed, .candidate, .testing, .validated, .proposed, .approved, .active]
        let all = learning.candidates(statuses: open, limit: 300)
        insights = all.filter { [.lesson, .preference, .knownLimitation].contains($0.kind) }.sorted { ($0.status == .observed ? 1 : 0, -$0.confidence) < ($1.status == .observed ? 1 : 0, -$1.confidence) }
        candidates = all.filter { [.rule, .workflow, .routingAdjustment, .skillRecommendation].contains($0.kind) }
        gaps = all.filter { $0.kind == .capabilityGap || $0.kind == .mcpRecommendation }
        improvementCandidates = all.filter { $0.kind == .sourceCodeImprovement }
        rules = learning.rules(statuses: [.active, .disabled])
        skills = skillsRegistry.all()
        proposals = selfImprovement.proposals()
        history = learning.history(limit: 60)
        pending = decisions.pending().filter { [.promoteCandidate, .activateRule, .activateSkill, .selfImprovement].contains($0.kind) }
        signals = learning.signalCount
    }

    func extractNow() async { busy = true; let r = await learning.extract(reason: "your request"); message = "Looked at recent work: \(r.newSignals) new signal(s), \(r.candidatesCreated) new candidate(s), \(r.candidatesUpdated) updated."; busy = false; refresh() }

    func test(_ id: UUID) async { let r = await learning.test(id); message = r.passed ? "Test passed: \(r.detail)" : "Test failed: \(r.detail)"; refresh() }
    func propose(_ id: UUID) async {
        if await learning.requestPromotion(id) != nil { message = "Waiting for your decision below." } else { message = "That candidate is not ready to propose (rules and workflows must pass the test first)." }
        refresh()
    }
    func reject(_ id: UUID) { _ = learning.reject(id); message = "Rejected. It will not be proposed again unless the evidence changes materially."; refresh() }
    func approve(_ q: AdaptiveRequest) async { let o = await decisions.approve(q.id, source: .hud); message = Self.describe(o); refresh() }
    func deny(_ q: AdaptiveRequest) { _ = decisions.deny(q.id, source: .hud); message = "Declined."; refresh() }
    func disable(_ r: LearnedRule) { _ = learning.disableRule(r.id); message = "Disabled “\(r.title)”."; refresh() }
    func enable(_ r: LearnedRule) { _ = learning.enableRule(r.id); message = "Enabled “\(r.title)”."; refresh() }
    func revert(_ r: LearnedRule) { message = learning.revertRule(r.id) ? "Reverted to the previous definition (history is kept)." : "There is no earlier version to revert to."; refresh() }
    func retire(_ r: LearnedRule) { _ = learning.retireRule(r.id); message = "Retired “\(r.title)”."; refresh() }
    func setSkill(_ s: Skill, _ status: SkillStatus) { _ = skillsRegistry.setStatus(s.id, status, reason: "by you"); refresh() }
    func writeProposal(_ candidate: UUID) {
        switch selfImprovement.propose(from: candidate) { case .success: message = "Written as a proposal (nothing was changed)."; case .failure(let e): message = e.description }
        refresh()
    }
    func requestApply(_ p: ImprovementProposal) async {
        switch await selfImprovement.requestApplication(p.id) { case .success: message = "Waiting for your decision below."; case .failure(let e): message = e.description }
        refresh()
    }
    func explanation(_ p: ImprovementProposal) -> String { selfImprovement.explanation(p) }
    func ruleText(_ r: LearnedRule) -> String { RuleEngine.describe(r.definition) }

    static func describe(_ o: AdaptiveOutcome) -> String {
        switch o {
        case .executed(let t): t
        case .denied: "Declined."
        case .notPending: "That request is no longer open."
        case .tampered: "Refused: it changed after it was shown. Ask again."
        case .refused(let w): "Refused: \(w)"
        case .failed(let w): "Not done: \(w)"
        }
    }
}

@MainActor @Observable
final class CapabilitiesViewModel {
    enum Filter: String, CaseIterable, Identifiable { case all = "All", active = "Active", candidates = "Candidates", attention = "Needs attention", skills = "Skills"; var id: String { rawValue } }
    private let registry: MCPRegistry
    private let decisions: AdaptiveDecisionService
    private let assistant: AdaptiveAssistant
    let preferences: Preferences

    var filter: Filter = .all
    var query = ""
    var message: String?
    var busy = false
    var domain: MCPDomain = .audio
    var selected: String?
    private(set) var servers: [MCPServerRecord] = []
    private(set) var advice: [MCPRegistry.Advice] = []
    private(set) var pending: [AdaptiveRequest] = []
    private(set) var running: Set<String> = []

    init(registry: MCPRegistry, decisions: AdaptiveDecisionService, assistant: AdaptiveAssistant, preferences: Preferences) {
        self.registry = registry; self.decisions = decisions; self.assistant = assistant; self.preferences = preferences
    }

    var discoveryEnabled: Bool { preferences.mcpDiscoveryEnabled }
    var selectedServer: MCPServerRecord? { selected.flatMap(registry.server) }

    func refresh() {
        servers = registry.servers().filter { $0.status != .removed }.sorted { $0.name.lowercased() < $1.name.lowercased() }
        advice = registry.advice()
        pending = decisions.pending().filter { [.installCapability, .updateCapability, .removeCapability, .enableCapability].contains($0.kind) }
        running = Set(registry.runningServerIDs)
        if let s = selected, registry.server(s) == nil { selected = nil }
    }

    var visible: [MCPServerRecord] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return servers.filter { s in
            let hay = (s.name + " " + s.domain + " " + s.status.rawValue).lowercased()
            guard q.isEmpty || hay.contains(q) else { return false }
            switch filter {
            case .all: return true
            case .active: return s.status.isLive || s.status == .installed
            case .candidates: return [.discovered, .inspected, .sandboxed, .benchmarked, .recommended, .approved].contains(s.status)
            case .attention: return s.status == .degraded || s.revalidationRequired || s.health == .failed || advice.contains { $0.serverID == s.id }
            case .skills: return false
            }
        }
    }

    func trust(_ s: MCPServerRecord) -> String {
        let f = (s.discovery?.findings ?? []) + (s.benchmark?.findings ?? [])
        let high = f.filter { $0.severity == .high }.count
        if s.benchmark == nil && f.isEmpty { return "not examined" }
        return "\(s.benchmark.map { "benchmark \($0.passedCount)/\($0.cases.count)" } ?? "no benchmark") · \(high) high-risk finding\(high == 1 ? "" : "s")"
    }

    func setEnabled(_ s: MCPServerRecord, _ on: Bool) async {
        if on {
            switch registry.enable(s.id) {
            case .enabled: message = "\(s.name) is on."
            case .needsApproval: message = "\(s.name) asks for more than read access — approve it below."
            case .refused(let w): message = "Cannot switch on: \(w)."
            case .notFound: message = "Not found."
            }
        } else {
            switch await registry.disable(s.id) {
            case .disabled: message = "\(s.name) is off. Nothing was deleted."
            case .inUse(let ids): message = "In use by \(ids.count) active task(s) — stop or finish them first."
            default: message = "Nothing to switch off."
            }
        }
        refresh()
    }
    func benchmark(_ s: MCPServerRecord) async {
        busy = true; defer { busy = false }
        guard !s.launch.executable.isEmpty else { message = "\(s.name) is only a research lead — there is nothing to run yet."; return }
        if s.status == .discovered { registry.inspect(s.id, sourceDirectory: nil) }
        let r = await MCPBenchmarkRunner.run(registry: registry, serverID: s.id, spec: s.isFixture ? .fixture : .domain(s.domain), allowNetwork: s.envelope.contains(.network))
        if let r, MCPBenchmarkRunner.recommendation(for: registry.server(s.id) ?? s).recommend, registry.server(s.id)?.status == .benchmarked { registry.transition(s.id, to: .recommended, reason: "clears the bar") }
        message = r.map { "Benchmarked in the sandbox: \($0.passedCount)/\($0.cases.count) passed, cleanup \($0.cleanupOK ? "complete" : "incomplete")." } ?? "Not found."
        refresh()
    }
    func requestInstall(_ s: MCPServerRecord) { message = registry.requestInstall(s.id, allowedProjects: assistant.projectKey().map { [$0] } ?? []) != nil ? "Waiting for your decision below." : "Only a recommended server can be registered."; refresh() }
    func requestRemoval(_ s: MCPServerRecord) {
        switch registry.requestRemoval(s.id) {
        case .requested: message = "Waiting for your decision below. Nothing is deleted until you approve."
        case .inUse: message = "In use by an active task — stop or finish it first."
        case .notFound: message = "Not found."
        }
        refresh()
    }
    func requestUpdate(_ s: MCPServerRecord) { if let v = s.discovery?.version, v != s.version, registry.requestUpdate(s.id, toVersion: v) != nil { message = "Update request created." } else { message = "No newer version is known." }; refresh() }
    func checkDrift(_ s: MCPServerRecord) { message = registry.checkDrift(s.id) ? "Changed since it was approved — it must be revalidated." : "Unchanged since it was approved."; refresh() }
    func reject(_ s: MCPServerRecord) { registry.transition(s.id, to: .rejected, reason: "by you", by: "hud"); message = "Rejected \(s.name). It stays in the list so it is not researched again as new."; refresh() }
    func approve(_ q: AdaptiveRequest) async { let o = await decisions.approve(q.id, source: .hud); message = LearningViewModel.describe(o); refresh() }
    func deny(_ q: AdaptiveRequest) { _ = decisions.deny(q.id, source: .hud); message = "Declined."; refresh() }
    func discover() async {
        busy = true; defer { busy = false }
        message = await assistant.reply(to: .findMCP(domain: domain, words: domain.label), language: .en, channel: .typed)
        refresh()
    }
    func activity(_ s: MCPServerRecord) -> [MCPActivityRecord] { registry.activity(s.id, limit: 8) }
    func ownership(_ s: MCPServerRecord) -> MCPOwnership? { registry.ownership(s.id) }
}
