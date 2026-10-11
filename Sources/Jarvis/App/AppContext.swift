import Foundation
import Observation
import SwiftUI

/// Composition root: owns the long-lived objects. Everything here outlives every window —
/// closing the Full HUD or Compact HUD never tears any of it down.
@MainActor
@Observable
final class AppContext {
    let store: JarvisStore
    let hud: HUDState
    let preferences: Preferences

    let conversation: ConversationStore
    let providers: ProviderManager

    // V0.3.1 intelligence infrastructure
    let paths: JarvisPaths
    /// nil if the database could not be opened — JARVIS keeps working without persistence (auditing becomes a no-op).
    let database: JarvisDatabase?
    let repository: JarvisRepository?
    let artifacts: ArtifactStore?
    let audit: AuditRecorder
    let resources: ResourceManager
    let openCode: OpenCodeService
    let localRuntime: LocalRuntime
    let supervisor: ProviderSupervisor
    let coordinator: IntelligenceCoordinator
    let agents: AgentRunManager
    let benchmarks: BenchmarkRunner
    private(set) var persistenceError: String?
    /// Automated runs (smoke/capture/--no-providers) use a throw-away data directory and NEVER touch real providers.
    let intelligenceIsStubbed: Bool

    @ObservationIgnored private(set) var conversationService: ConversationService!
    @ObservationIgnored private(set) var windowManager: WindowManager!

    /// Views and (later) the intent layer talk to windows only through this protocol.
    var windows: any JarvisWindowControlling { windowManager }

    init(seedDemoData: Bool = true, stubIntelligence: Bool = false) {
        store = JarvisStore()
        hud = HUDState()
        preferences = Preferences()
        conversation = ConversationStore()
        providers = ProviderManager(preferences: preferences)
        intelligenceIsStubbed = stubIntelligence

        // --- persistence ---
        let p = stubIntelligence ? JarvisPaths.temporary("jarvis-stub") : JarvisPaths.standard()
        paths = p
        var db: JarvisDatabase?
        var dbError: String?
        do { try p.ensureDirectories(); db = try JarvisDatabase(url: p.database) } catch { dbError = String(describing: error); Log.app.error("database unavailable: \(dbError ?? "", privacy: .public)") }
        database = db
        persistenceError = dbError
        let repo = db.map(JarvisRepository.init)
        repository = repo
        artifacts = db.map { ArtifactStore(paths: p, database: $0) }
        audit = AuditRecorder(repository: repo)
        if let corrupt = db?.recoveredFromCorruptionAt { Log.app.error("recovered from a corrupt database; old file kept at \(corrupt.lastPathComponent, privacy: .public)") }

        // --- engines ---
        resources = ResourceManager()
        openCode = OpenCodeService(repository: repo, preferences: preferences, providerWorkspace: providers.workingDirectory)
        let modelPath = stubIntelligence ? "/nonexistent/jarvis-stub-model" : preferences.localModelPath
        var localConfig = LocalRuntimeConfig.standard(paths: stubIntelligence ? JarvisPaths(root: URL(fileURLWithPath: "/nonexistent/jarvis-stub")) : p, modelPath: modelPath)
        localConfig.idleUnloadSeconds = preferences.localIdleUnloadSeconds
        localRuntime = LocalRuntime(config: localConfig)
        supervisor = ProviderSupervisor(providers: providers, openCode: openCode, local: localRuntime, resources: resources, repository: repo)
        coordinator = IntelligenceCoordinator(providers: providers, supervisor: supervisor, audit: audit, preferences: preferences)
        agents = AgentRunManager(coordinator: coordinator, resources: resources)
        benchmarks = BenchmarkRunner(repository: repo, artifacts: artifacts)

        if seedDemoData { DemoScenario.seed(store) }
        windowManager = WindowManager(context: self)
        conversationService = ConversationService(store: store, conversation: conversation, windows: windowManager, resolver: coordinator)

        // Activity: meaningful events only (lifecycle, escalation, cooldown) — never tokens or health checks.
        let sink: (String) -> Void = { [weak store] in store?.log($0, kind: .info) }
        supervisor.onEvent = sink
        coordinator.onEvent = sink
        agents.onEvent = sink
        let audit = self.audit
        store.onLog = { event in audit.activity(event.kind.rawValue, event.message) }
    }

    /// Discovery for every engine (event-driven, once at launch and on demand). Stubbed runs skip real providers entirely.
    func refreshIntelligence(remoteCatalog: Bool = true) async {
        if intelligenceIsStubbed {
            providers.probeOverride = { id, _ in ProviderStatus(id: id, state: .notInstalled) }
            await providers.refresh()
            return
        }
        resources.start()
        await supervisor.refreshAll(remoteCatalog: remoteCatalog)
    }
}
