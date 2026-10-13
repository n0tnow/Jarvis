import Foundation

// MARK: - Orchestration planner (V0.12, DEC-161…)
//
// Deterministic first. A simple goal is ONE node ("Open Finder" → Computer, "Research X" → Research, "Run the tests" → QA) and never costs a model call. A compound goal
// that matches a known shape becomes a role-labelled graph built from a template. Only a genuinely open-ended compound goal is handed to the planner MODEL, whose graph is
// then validated exactly like a template (a model proposes, JARVIS validates).

/// What the planner knows about the situation — all of it deterministic project truth or settings, never model output.
struct PlanningContext: Equatable, Sendable {
    var hasBuildCommand = false
    var hasTestCommand = false
    var isUnityProject = false
    var projectHasUnityTests = false
    /// Settings → Web research (the master switch). Without it no research node is ever planned.
    var webAllowed = false
    var computerAllowed = false
    /// V0.10: a CURRENT verified answer to the goal's knowledge question already exists in project memory → do not research again.
    var researchCoveredByMemory = false
    var writable = true
}

/// A plan the orchestrator built itself, with the reasoning shown to the user in the activity feed.
struct OrchestratedPlan: Equatable, Sendable {
    var plan: TaskPlan
    var template: String
    var rationale: String
    var addsResearch: Bool
    var addsComputer: Bool
}

enum OrchestrationRoute: Equatable, Sendable {
    /// The goal is one specialist's job: exactly one node.
    case single(AgentRole, template: String)
    /// A known compound shape: a role graph with no planner model call.
    case graph(OrchestratedPlan)
    /// A compound goal with no template: the planner model proposes a graph, JARVIS validates it.
    case needsModelPlanning(reason: String)
}

enum GoalCues {
    private static func tokens(_ raw: String) -> [String] { InputNormalizer.normalize(raw).tokens }
    private static func has(_ t: [String], prefixes: [String]) -> Bool { t.contains { w in prefixes.contains { w.hasPrefix($0) } } }
    private static func hasPhrase(_ raw: String, _ phrases: [String]) -> Bool { let f = ResearchText.fold(raw); return phrases.contains { f.contains($0) } }

    static func fix(_ raw: String) -> Bool {
        has(tokens(raw), prefixes: ["fix", "repair", "solve", "resolv", "correct", "implement", "patch", "refactor", "duzelt", "coz", "onar", "giderm", "gider", "halled", "ekle", "add", "implemente", "degistir", "guncelle"])
    }
    /// Fix verbs that unambiguously mean "change the code" ("add"/"ekle" also appear in "before adding this asset").
    static func fixStrict(_ raw: String) -> Bool {
        has(tokens(raw), prefixes: ["fix", "repair", "solve", "resolv", "correct", "patch", "refactor", "duzelt", "coz", "onar", "giderm", "gider", "halled"])
    }
    static func investigate(_ raw: String) -> Bool {
        has(tokens(raw), prefixes: ["analy", "inspect", "investigat", "diagnos", "audit", "find", "look", "examin", "incele", "analiz", "bul", "tespit", "arastir", "kontrol"]) || hasPhrase(raw, ["sorun", "hata", "bug", "problem", "issue"])
    }
    static func tests(_ raw: String) -> Bool {
        has(tokens(raw), prefixes: ["test", "dogrula", "verify", "validate"]) || hasPhrase(raw, ["unit test", "testleri"])
    }
    static func review(_ raw: String) -> Bool { hasPhrase(raw, ["review", "gozden gecir", "degisikligi incele", "degisiklikleri incele"]) }
    /// Scene / component / prefab work in a Unity project (typed editor operations, planned by the model with the Unity step types).
    static func unitySceneEdit(_ raw: String) -> Bool {
        hasPhrase(raw, ["gameobject", "game object", "component", "bilesen", "prefab", "scene", "sahne", "rigidbody", "collider", "inspector", "hierarchy", "transform", "material", "play mode", "playmode"])
    }
    /// The goal asks for knowledge that may be missing or current: documentation, "latest", "up to date", "research", "güncel", "araştır".
    static func needsResearch(_ raw: String) -> Bool {
        hasPhrase(raw, ["research", "arastir", "guncel", "up to date", "up-to-date", "latest", "official doc", "documentation", "dokuman", "docs", "recent version", "new version", "yeni surum", "current api", "changed api", "internetten", "web'de", "webde", "kaynak"])
    }
    /// The goal explicitly asks to look at a running app's UI (the only reason to add a Computer node to a development graph).
    static func needsGUICheck(_ raw: String) -> Bool {
        hasPhrase(raw, ["open the app and", "check the ui", "check the interface", "arayuzu kontrol", "uygulamayi ac", "run the app and look", "see it on screen", "ekranda kontrol", "gui check", "visually check"])
    }
    static func assetQuestion(_ raw: String) -> Bool {
        hasPhrase(raw, ["asset", "paket", "package"]) && hasPhrase(raw, ["license", "lisans", "compatib", "uyum", "suitable", "uygun", "urp", "hdrp", "recommend", "oner", "price", "ucret", "free", "ucretsiz"])
    }
    /// The asset question must never turn into an acquisition/import: only a separate, explicitly worded request does.
    static func wantsImport(_ raw: String) -> Bool { hasPhrase(raw, ["import it", "add it to the project", "projeye ekle", "indir", "download", "install", "kur"]) }
    /// Two or more distinct jobs in one goal (investigate / research / fix / test / review): the orchestrator decides which specialists are needed.
    static func isCompound(_ raw: String) -> Bool {
        let n = [investigate(raw), needsResearch(raw), fix(raw), tests(raw), review(raw)].filter { $0 }.count
        return n >= 2 && !assetQuestion(raw)
    }
    static func runTestsOnly(_ raw: String) -> Bool {
        let t = tokens(raw)
        guard tests(raw), !fix(raw), !has(t, prefixes: ["analy", "inspect", "review", "investigat", "incele", "research", "arastir", "gozden"]) else { return false }
        return has(t, prefixes: ["run", "execute", "calistir", "kos", "ver"]) || t.count <= 4
    }
}

enum OrchestrationPlanner {
    /// Which route a development / analysis goal takes. Computer and research goals are routed by their own intake earlier; this answers the question for the project goals.
    static func route(goal: String, kind: TaskKind, context c: PlanningContext) -> OrchestrationRoute {
        // A single QA job: "Run the project tests."
        if GoalCues.runTestsOnly(goal), c.hasTestCommand { return .single(.qa, template: "run-tests") }
        // Asset suitability: research → Unity compatibility → recommendation. Never acquires or imports.
        if GoalCues.assetQuestion(goal), !GoalCues.wantsImport(goal), !GoalCues.fixStrict(goal) { return .graph(assetSuitability(goal: goal, c)) }
        let fix = GoalCues.fix(goal)
        let research = c.webAllowed && GoalCues.needsResearch(goal) && !c.researchCoveredByMemory
        // Scene / component / prefab edits in a Unity project are typed editor operations (V0.6): the planner model knows those step types, no template does.
        if c.isUnityProject, GoalCues.unitySceneEdit(goal) { return .needsModelPlanning(reason: "Unity scene operations need the typed Unity step types") }
        // Code fix shapes: [research] → analysis → (reproduce) → coding → (compile) → build → test → [UI check] → review.
        if kind == .development, fix, c.writable {
            return .graph(fixFlow(goal: goal, c, research: research, review: true, gui: c.computerAllowed && GoalCues.needsGUICheck(goal)))
        }
        // Read-only investigation: code scan ∥ optional research → synthesis, or inspect → explain.
        if kind == .readOnlyAnalysis || (GoalCues.investigate(goal) && !fix) {
            return .graph(research ? investigationWithResearch(goal: goal, c) : investigation(goal: goal, c))
        }
        return .needsModelPlanning(reason: "the goal does not match a known shape")
    }

    // MARK: Templates

    private static func step(_ id: String, _ title: String, _ desc: String, _ type: StepType, after: [String] = [], expected: String = "", validation: ValidationKind? = nil, optional: Bool = false, delegate: DelegateParams? = nil, risk: RiskClass? = nil) -> PlanStep {
        PlanStep(id: id, title: title, description: desc, type: type, dependsOn: after, expected: expected, validation: validation ?? .default(for: type), risk: risk ?? type.defaultRisk, optional: optional, delegate: delegate)
    }

    /// Analysis → (reproduce) → Coding → Build → Tests → (UI check) → Review, with Research in front only when knowledge is genuinely missing.
    static func fixFlow(goal: String, _ c: PlanningContext, research: Bool, review: Bool, gui: Bool) -> OrchestratedPlan {
        var steps: [PlanStep] = []
        var last: [String] = []
        var n = 0
        func id() -> String { n += 1; return "s\(n)" }
        var firstAnalysisDeps: [String] = []
        if research {
            let rid = id()
            steps.append(step(rid, "Research the missing knowledge", "Find the current, official facts this fix depends on; verified claims with sources only.", .delegateResearch, expected: "verified findings with citations (or an honest 'nothing found')",
                              optional: true, delegate: DelegateParams(goal: researchQuestion(from: goal), reason: "the goal depends on current information that is not in project memory")))
            firstAnalysisDeps = [rid]
        }
        let analysis = id()
        steps.append(step(analysis, "Find the cause", "Inspect the relevant files and explain the root cause.", .analysis, after: firstAnalysisDeps, expected: "root cause and relevant files"))
        last = [analysis]
        if c.hasTestCommand {
            let repro = id()
            steps.append(step(repro, "Reproduce with the tests", "Run the project's tests to record the current failure (evidence only).", .test, after: last, expected: "a recorded test run", validation: .testEvidence))
            last = [repro]
        }
        let code = id()
        steps.append(step(code, "Make the fix", "Change only what the cause requires.", .codeChange, after: last, expected: "the minimal change is applied", risk: .medium))
        last = [code]
        if c.isUnityProject {
            let compile = id()
            steps.append(step(compile, "Compile in Unity", "Let Unity compile the scripts and check its own compiler state.", .unityCompile, after: last, expected: "Unity compiles without errors"))
            last = [compile]
        }
        if c.hasBuildCommand {
            let b = id()
            steps.append(step(b, "Build", "Run the project's build.", .build, after: last, expected: "the build passes"))
            last = [b]
        }
        if c.hasTestCommand {
            let t = id()
            steps.append(step(t, "Run the tests", "Run the project's tests after the change.", .test, after: last, expected: "the tests pass", validation: .testPass))
            last = [t]
        }
        if gui {
            let g = id()
            steps.append(step(g, "Check it on screen", "Open the result and confirm the interface looks right (best effort).", .delegateComputer, after: last, expected: "the interface is observed",
                              optional: true, delegate: DelegateParams(goal: "Open " + (c.isUnityProject ? "Unity" : "the app"), reason: "the goal asks for a visual check")))
            last = [g]
        }
        if review {
            let r = id()
            steps.append(step(r, "Review the change", "Review the final diff against the evidence and the project's constraints.", .review, after: last, expected: "no blocking finding"))
        }
        let roles = TaskGraph(plan: TaskPlan(summary: "", steps: steps)).roles.map(\.label).joined(separator: " → ")
        return OrchestratedPlan(plan: TaskPlan(summary: "Fix flow: \(roles)", steps: steps), template: "fix-flow", rationale: "development goal with a fix → \(roles)", addsResearch: research, addsComputer: gui)
    }

    /// Code scan ∥ research → synthesis (the two read-only branches may run side by side; the synthesis waits for both).
    static func investigationWithResearch(goal: String, _ c: PlanningContext) -> OrchestratedPlan {
        let steps = [
            step("s1", "Research current facts", "Find current, official facts relevant to the question; verified claims with sources only.", .delegateResearch, expected: "verified findings (or an honest 'nothing found')", optional: true,
                 delegate: DelegateParams(goal: researchQuestion(from: goal), reason: "the question depends on current information that is not in project memory")),
            step("s2", "Scan the code", "Inspect the relevant project files for the question.", .analysis, expected: "relevant files and findings"),
            step("s3", "Synthesize", "Combine the code findings with the research into the answer; say what is uncertain.", .analysis, after: ["s1", "s2"], expected: "a cited, bounded answer"),
        ]
        return OrchestratedPlan(plan: TaskPlan(summary: "Investigation: code scan ∥ research → synthesis", steps: steps), template: "investigation-research", rationale: "knowledge may be missing → research runs next to the code scan", addsResearch: true, addsComputer: false)
    }

    /// A read-only investigation: one analysis, then (if the question is broad) a second pass that states the answer.
    static func investigation(goal: String, _ c: PlanningContext) -> OrchestratedPlan {
        let steps = [
            step("s1", "Inspect the code", "Inspect the files the question is about.", .analysis, expected: "relevant files and findings"),
            step("s2", "Explain the answer", "State the answer, the evidence (files) and what remains uncertain.", .analysis, after: ["s1"], expected: "a bounded answer with evidence"),
        ]
        return OrchestratedPlan(plan: TaskPlan(summary: "Investigation: inspect → explain", steps: steps), template: "investigation", rationale: "read-only question → inspection then an evidence-based answer", addsResearch: false, addsComputer: false)
    }

    /// Research → Unity compatibility analysis → recommendation. Never downloads or imports (those are separate, approval-gated tasks).
    static func assetSuitability(goal: String, _ c: PlanningContext) -> OrchestratedPlan {
        var steps: [PlanStep] = []
        var deps: [String] = []
        if c.webAllowed {
            steps.append(step("s1", "Research the asset", "Verify price, licence and compatibility from official sources.", .delegateResearch, expected: "price, licence and compatibility with evidence",
                              delegate: DelegateParams(goal: goal, reason: "asset facts must come from the sources, not from memory of the model")))
            deps = ["s1"]
        }
        let a = "s\(steps.count + 1)"
        steps.append(step(a, "Check Unity compatibility", "Compare the researched facts with this project's Unity version and render pipeline.", .analysis, after: deps, expected: "compatible / not compatible / unknown, with reasons"))
        steps.append(step("s\(steps.count + 1)", "Recommendation", "State whether the asset is suitable, what is uncertain, and what the user must decide. Do not acquire or import anything.", .analysis, after: [a], expected: "a recommendation, no acquisition"))
        return OrchestratedPlan(plan: TaskPlan(summary: "Asset suitability: research → compatibility → recommendation", steps: steps), template: "asset-suitability", rationale: "asset question → Research → Unity compatibility → recommendation (no import)", addsResearch: c.webAllowed, addsComputer: false)
    }

    /// The research child gets a clean question: the user's own words, bounded (the child re-derives its plan from it through the V0.9 intake).
    static func researchQuestion(from goal: String) -> String { String(goal.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)) }
}

// MARK: - Graph revision (bounded)

/// A specialist may REQUEST more knowledge; only the orchestrator changes the graph. Revisions are validated, audited and limited (`OrchestrationLimits.maxRevisions`).
enum GraphRevision {
    struct Result: Equatable, Sendable {
        var plan: TaskPlan
        var addedKeys: [String]
        var summary: String
    }

    /// Inserts a research node right AFTER `key` (a specialist reported missing knowledge); every node that depended on `key` now also waits for the research.
    static func insertResearch(into plan: TaskPlan, after key: String, goal: String, reason: String, revision: Int) -> Result? {
        guard revision <= OrchestrationLimits.maxRevisions, plan.steps.count < OrchestrationLimits.maxNodes,
              let i = plan.steps.firstIndex(where: { $0.id == key }) else { return nil }
        var steps = plan.steps
        var newKey = "r\(revision)"
        while steps.contains(where: { $0.id == newKey }) { newKey += "x" }
        for j in steps.indices where steps[j].dependsOn.contains(key) { steps[j].dependsOn = Array(Set(steps[j].dependsOn + [newKey])).sorted() }
        let node = PlanStep(id: newKey, title: "Research the missing knowledge", description: reason, type: .delegateResearch, dependsOn: [key], expected: "verified findings with citations",
                            validation: .researchDelegated, risk: .low, optional: true, delegate: DelegateParams(goal: String(goal.prefix(400)), reason: reason))
        steps.insert(node, at: i + 1)
        return Result(plan: TaskPlan(summary: plan.summary, steps: steps, version: plan.version + 1), addedKeys: [newKey], summary: "inserted research after “\(steps[i].title)”")
    }
}

// MARK: - Planner prompt section (only when the orchestrator is on)

enum OrchestratorPrompt {
    static func section(_ c: PlanningContext, kind: TaskKind) -> String {
        var s = """

        ORCHESTRATION (you are proposing a GRAPH of specialist nodes; JARVIS validates it and decides everything else):
        - Roles: analysis = Analysis, codeChange = Coding, build/test = QA (deterministic, run by JARVIS), review = Review. Each node uses ONLY its own role's capabilities. Nodes never create nodes or agents.
        - A node may be "optional": true only for analysis\(c.webAllowed ? ", delegateResearch" : "")\(c.computerAllowed ? ", delegateComputer" : ""); its failure then makes the task PARTIAL instead of FAILED. Everything that changes, tests or reviews is required.
        - Independent read-only nodes (two analyses, or analysis + research) may run side by side: give them no dependency on each other. Nodes that change things must be ordered by dependencies.
        - Anything that proves a change (build, test, compile) must depend on the change; a review must depend on the change AND on its build/test nodes.
        """
        if c.webAllowed {
            s += "\n- delegateResearch: ONLY when current or missing knowledge is needed (never for something the project files answer). {\"params\": {\"goal\": \"the research question\", \"reason\": \"why it is needed\"}}, validation researchDelegated, usually optional."
        }
        if c.computerAllowed {
            s += "\n- delegateComputer: ONLY when a result must be seen on screen. {\"params\": {\"goal\": \"Open <app>\"}}, validation computerDelegated, optional. Never for anything a project tool, Unity or web research can do."
        }
        s += "\n- approvalGate: a node that waits for the USER's HUD approval before later nodes run. {\"params\": {\"action\": \"what the user is approving\"}}, validation gateApproved. Use it before anything irreversible; never plan an agent that approves."
        s += "\n- Keep the graph small: at most \(OrchestrationLimits.maxNodes) nodes; one node per job; no purchases, accounts, installs or shell commands anywhere."
        return s + "\n"
    }
}
