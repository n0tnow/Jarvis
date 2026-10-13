import Foundation

/// Goal intake (V0.4): decides whether a user's text is a TASK (durable, planned, executed by the engine) or stays what it was before
/// (conversation / deterministic command / read-only knowledge answer). Pure and conservative: nothing here starts anything.
///
///   "How are you?"                       → not a task (local reply)
///   "Open Agents."                       → not a task (deterministic command — decided earlier by `CommandRouter`)
///   "Explain NetworkPlayer."             → not a task (knowledge answer from a provider, no project access)
///   "Analyze the multiplayer issue."     → read-only task        (needs a project)
///   "Fix the multiplayer issue."         → development task      (needs a project)
///   "Delete the old networking system."  → development task with `destructive` (deletions will wait for approval)
///
/// Long prompts are NOT routed here merely for being long.
enum GoalIntake {
    struct Intent: Equatable, Sendable {
        var kind: TaskKind
        var destructive: Bool
    }

    private static let analysisVerbs: Set<String> = ["analyze", "analyse", "inspect", "investigate", "diagnose", "audit", "review", "incele", "analiz", "arastir"]
    private static let destructiveVerbs: Set<String> = ["delete", "remove", "wipe", "purge", "erase", "drop", "sil", "kaldir"]
    private static let technicalNouns: Set<String> = [
        "code", "unity", "project", "bug", "bugs", "script", "scripts", "test", "tests", "repo", "repository", "multiplayer", "networking", "network",
        "class", "function", "app", "error", "errors", "issue", "problem", "synchronization", "sync", "feature", "codebase", "compiler", "implementation",
        "system", "module", "hata", "proje", "kod", "oyun",
        "gameobject", "gameobjects", "collider", "prefab", "prefabs", "monobehaviour", "playmode", "editmode",
    ]
    private static let everydayNouns: Set<String> = ["email", "mail", "story", "poem", "essay", "letter", "calendar", "meeting", "song", "speech", "joke", "message"]
    /// "explain", "what is", "how does …" are knowledge questions even when they mention technical nouns.
    private static let questionLeaders: Set<String> = ["explain", "what", "why", "how", "describe", "tell", "compare", "who", "when", "nedir", "neden", "nasil", "acikla"]

    /// A read-only analysis request ("analyze the multiplayer issue"). Only meaningful when a project is available; the caller decides.
    static func analysis(for raw: String) -> Intent? {
        let t = InputNormalizer.normalize(raw).tokens
        guard let first = t.first, !questionLeaders.contains(first) else { return nil }
        let words = Set(t)
        guard words.isDisjoint(with: everydayNouns), !words.isDisjoint(with: analysisVerbs), !words.isDisjoint(with: technicalNouns) else { return nil }
        return Intent(kind: .readOnlyAnalysis, destructive: false)
    }

    /// For a request the router already classified as "worker required" (verb + technical noun): the development intent.
    static func development(for raw: String) -> Intent {
        let words = Set(InputNormalizer.normalize(raw).tokens)
        return Intent(kind: .development, destructive: !words.isDisjoint(with: destructiveVerbs))
    }
}

enum TaskSubmission: Equatable, Sendable {
    case started(title: String)
    case needsProject
    case rejected(String)
}

/// What `ConversationService` needs from the task layer. Tests without an engine simply don't set it (old behaviour).
@MainActor
protocol TaskSubmitting: AnyObject {
    var hasProject: Bool { get }
    var projectName: String? { get }
    func submitTask(goal: String, intent: GoalIntake.Intent, channel: InputSource) async -> TaskSubmission
}

extension TaskSubmitting {
    func submitTask(goal: String, intent: GoalIntake.Intent) async -> TaskSubmission { await submitTask(goal: goal, intent: intent, channel: .typed) }
}

/// V0.9: research requests become ordinary web research TASKS (no project needed). Voice and typed text take the same path.
@MainActor
protocol ResearchSubmitting: AnyObject {
    func submitResearch(goal: String, channel: InputSource) async -> TaskSubmission
}

/// V0.11: requests to operate native macOS applications. The classification is deterministic (EN/TR) and consults the capability ladder FIRST: anything a stronger
/// mechanism owns (project tools, the Unity bridge, web research, Git) is NOT taken by Computer Use. Voice and typed text take this same path.
@MainActor
protocol ComputerSubmitting: AnyObject {
    func classifyComputer(_ text: String) -> GoalClassification
    func submitComputer(goal: String, channel: InputSource) async -> TaskSubmission
}

@MainActor
protocol EngineTaskControlling: AnyObject {
    func stopTask(_ id: UUID)
    func resumeTask(_ id: UUID)
    func decideApproval(_ id: UUID, approved: Bool)
}

extension TaskEngine: EngineTaskControlling {
    func stopTask(_ id: UUID) { cancel(id) }
    func resumeTask(_ id: UUID) { resume(id) }
    func decideApproval(_ id: UUID, approved: Bool) { decide(id, approved: approved) }
}

/// Production `TaskSubmitting`: the project folder comes from the user's Settings choice; everything else is the engine.
@MainActor
final class TaskIntake: TaskSubmitting, ResearchSubmitting, ComputerSubmitting {
    private let engine: TaskEngine
    private let preferences: Preferences
    init(engine: TaskEngine, preferences: Preferences) { self.engine = engine; self.preferences = preferences }

    var hasProject: Bool { !preferences.projectRoot.isEmpty && (try? WorkspaceGuard(rootPath: preferences.projectRoot)) != nil }
    var projectName: String? { hasProject ? (preferences.projectRoot as NSString).lastPathComponent : nil }

    func submitTask(goal: String, intent: GoalIntake.Intent, channel: InputSource) async -> TaskSubmission {
        guard hasProject else { return .needsProject }
        let preference = preferences.providerPreference
        switch await engine.submit(goal: goal, kind: intent.kind, workspacePath: preferences.projectRoot, preference: preference == .auto ? nil : preference,
                                   destructiveRequested: intent.destructive, inputChannel: channel) {
        case .success(let id): return .started(title: engine.view(id)?.task.title ?? goal)
        case .failure(let e): return .rejected(e.description)
        }
    }

    // MARK: Research (V0.9)

    /// Facts about the connected Unity game, read-only, only when the goal talks about "the game / the project / our Unity project".
    static func projectFacts(root: String) -> ProjectFacts? {
        guard let d = UnityProjectDetector.describe(root: root) else { return nil }
        let pipeline = d.renderPipeline.contains("URP") ? "URP" : d.renderPipeline.contains("HDRP") ? "HDRP" : d.renderPipeline == "Built-in" ? "Built-in" : nil
        return ProjectFacts(name: d.projectName, unityVersion: d.declaredVersionRaw, renderPipeline: pipeline, hasTestFramework: d.hasTestFramework)
    }

    private func goalRefersToProject(_ goal: String) -> Bool {
        let t = ResearchText.fold(goal)
        return ["my game", "our game", "the game", "my project", "our project", "this project", "the project", "our unity", "my unity", "oyunum", "oyunumuz", "projem", "projemiz", "bu proje", "projeye", "oyuna", "oyunuma", "oyun icin", "icin uygun"].contains { t.contains($0) }
    }

    func submitResearch(goal: String, channel: InputSource) async -> TaskSubmission {
        let facts = (hasProject && goalRefersToProject(goal)) ? Self.projectFacts(root: preferences.projectRoot) : nil
        let request = ResearchIntake.parse(goal: goal, project: facts)
        let preference = preferences.providerPreference
        switch await engine.submitResearch(request, preference: preference == .auto ? nil : preference, inputChannel: channel) {
        case .success(let id): return .started(title: engine.view(id)?.task.title ?? goal)
        case .failure(let e): return .rejected(e.description)
        }
    }

    // MARK: Computer Use (V0.11)

    func classifyComputer(_ text: String) -> GoalClassification {
        guard engine.computer != nil, preferences.computerUseEnabled else { return .notComputer }
        let root = hasProject ? preferences.projectRoot : nil
        return ComputerGoalParser.classify(text, context: GoalContext(projectRoot: root, unityProjectOpen: root.map { UnityProjectDetector.isUnityProject(root: $0) } ?? false, visionEnabled: preferences.computerVisionEnabled))
    }

    func submitComputer(goal: String, channel: InputSource) async -> TaskSubmission {
        guard case .computer(let parsed) = classifyComputer(goal) else { return .rejected("That is not something Computer Use does.") }
        let preference = preferences.providerPreference
        switch await engine.submitComputer(goal: goal, steps: parsed.steps, capability: parsed.capability, apps: parsed.apps, preference: preference == .auto ? nil : preference, inputChannel: channel) {
        case .success(let id): return .started(title: engine.view(id)?.task.title ?? goal)
        case .failure(let e): return .rejected(e.description)
        }
    }
}
