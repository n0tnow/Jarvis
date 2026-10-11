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
    /// V0.3.2: live registry of runs + sanitized consoles (the Agent Observatory's data plane).
    let hub: ExecutionHub
    let observatory: AgentObservatory
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

    init(seedDemoData: Bool = true, stubIntelligence: Bool = false, dataDirectory: URL? = nil) {
        store = JarvisStore()
        hud = HUDState()
        preferences = Preferences()
        conversation = ConversationStore()
        providers = ProviderManager(preferences: preferences)
        intelligenceIsStubbed = stubIntelligence

        // --- persistence ---
        // Data (SQLite/artifacts) may live in a separate directory (the live test never pollutes the user's real history);
        // the local-model RUNTIME always comes from the standard location.
        let runtimePaths = stubIntelligence ? JarvisPaths(root: URL(fileURLWithPath: "/nonexistent/jarvis-stub")) : JarvisPaths.standard()
        let p = stubIntelligence ? JarvisPaths.temporary("jarvis-stub") : (dataDirectory.map { JarvisPaths(root: $0) } ?? JarvisPaths.standard())
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
        hub = ExecutionHub(repository: repo, artifacts: artifacts, audit: audit)
        audit.hub = hub
        // Restart reconciliation: runs still recorded as running belong to a previous process → INTERRUPTED (never "running forever").
        if !stubIntelligence { audit.reconcileStaleRuns(); try? repo?.pruneEvents(olderThan: Date().addingTimeInterval(-30 * 24 * 3600)) }
        if let corrupt = db?.recoveredFromCorruptionAt { Log.app.error("recovered from a corrupt database; old file kept at \(corrupt.lastPathComponent, privacy: .public)") }

        // --- engines ---
        resources = ResourceManager()
        openCode = OpenCodeService(repository: repo, preferences: preferences, providerWorkspace: providers.workingDirectory)
        let modelPath = stubIntelligence ? "/nonexistent/jarvis-stub-model" : preferences.localModelPath
        var localConfig = LocalRuntimeConfig.standard(paths: runtimePaths, modelPath: modelPath)
        localConfig.idleUnloadSeconds = preferences.localIdleUnloadSeconds
        localRuntime = LocalRuntime(config: localConfig)
        let prefsRef = preferences
        localRuntime.idleUnloadProvider = { [weak prefsRef] in prefsRef?.localIdleUnloadSeconds ?? 300 }
        supervisor = ProviderSupervisor(providers: providers, openCode: openCode, local: localRuntime, resources: resources, repository: repo)
        coordinator = IntelligenceCoordinator(providers: providers, supervisor: supervisor, audit: audit, preferences: preferences)
        agents = AgentRunManager(coordinator: coordinator, resources: resources)
        benchmarks = BenchmarkRunner(repository: repo, artifacts: artifacts)
        observatory = AgentObservatory(hub: hub, supervisor: supervisor, openCode: openCode, local: localRuntime, repository: repo, artifacts: artifacts)
        observatory.demo = ObservatoryDemo(hub: hub)

        if stubIntelligence {
            // Stub at construction (not on first refresh): nothing may reach a real provider, its service, or the network.
            providers.probeOverride = { id, _ in ProviderStatus(id: id, state: .notInstalled) }
            openCode.isStubbed = true
        }

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

        // Stop is the EXISTING cancellation, addressed by run id (see ExecutionHub.installStopRouting).
        hub.installStopRouting(conversation: conversationService, agents: agents, userTask: { [weak self] in self?.userTasks[$0] }, demo: { [weak self] in self?.observatory.demo })
    }

    /// User-triggered runs (benchmark, local test) whose Task can be cancelled from the Observatory.
    @ObservationIgnored fileprivate var userTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: User-triggered actions (Settings)

    /// modelID → progress text while a benchmark runs ("3/13"), absent otherwise. Bumps `benchmarkRevision` so views refresh.
    private(set) var benchmarkProgress: [String: String] = [:]
    private(set) var benchmarkRevision = 0
    private(set) var localTestResult: String?
    private(set) var isTestingLocal = false

    /// Runs the benchmark suite on ONE verified-free model (explicit user action: sends the fixed, non-sensitive fixtures to that model).
    /// It is an observed, audited run with REAL structured steps (one per case) — the Observatory's measurable-progress example.
    func benchmark(modelID: String) async {
        guard benchmarkProgress[modelID] == nil, !intelligenceIsStubbed else { return }
        let total = BenchmarkSuite.all.count
        benchmarkProgress[modelID] = "0/\(total)"
        let name = openCode.model(modelID)?.displayName ?? modelID
        let runID = audit.begin(agentType: "BenchmarkAgent", engine: .openCode, model: modelID, decision: nil, prompt: "benchmark suite \(BenchmarkSuite.id)",
                                privacy: .normal, label: "Benchmark · \(name)", owner: .benchmark)
        let ordered = BenchmarkGroup.allCases.flatMap { BenchmarkSuite.cases($0) }
        hub.setSteps(runID, ordered.map { ("\($0.group.rawValue): \($0.title)", 1.0) })
        let task = Task { @MainActor in await self.runBenchmark(modelID: modelID, runID: runID, total: total) }
        userTasks[runID] = task
        await task.value
        userTasks[runID] = nil
    }

    private func runBenchmark(modelID: String, runID: UUID, total: Int) async {
        defer { benchmarkProgress[modelID] = nil; benchmarkRevision += 1; supervisor.invalidateBenchmarks(); openCode.reloadFromStore() }
        await openCode.refresh(remote: true)                                    // never benchmark on stale price data
        var done = 0
        let openCode = self.openCode, hub = self.hub
        hub.setPhase(runID, .running, activity: "Benchmarking")
        let outcomes = await benchmarks.run(modelID: modelID, groups: BenchmarkGroup.allCases, makeProvider: {
            guard let m = openCode.model(modelID), let p = openCode.provider(for: m) else { return nil }
            return SafeProvider(base: p, runID: runID, hub: hub)                  // same boundary as every other run
        }, progress: { [weak self] o in
            hub.setStep(runID, index: done, o.passed ? .done : .failed)
            done += 1
            self?.benchmarkProgress[modelID] = "\(done)/\(total)"
        }, onModelRemoved: { openCode.markModelGone(modelID) }, onCaseStart: { i, _ in hub.setStep(runID, index: i, .active) })
        let passed = outcomes.filter(\.passed).count
        if Task.isCancelled { audit.finish(runID, status: .cancelled, resultText: "stopped after \(outcomes.count)/\(total) cases") }
        else { audit.finish(runID, status: .succeeded, resultText: "passed \(passed)/\(outcomes.count) cases") }
        store.log("Benchmark finished for \(modelID)", kind: .info)
    }

    func benchmarkAllFreeModels() async {
        for m in openCode.freePool where m.enabled { await benchmark(modelID: m.id) }
    }

    /// "Test local model": one bounded, observed request through the local provider (starts the worker on demand).
    func testLocalModel() async {
        guard !isTestingLocal, !intelligenceIsStubbed else { return }
        isTestingLocal = true; localTestResult = nil
        defer { isTestingLocal = false }
        let profile = TaskProfile(category: .conversation, complexity: .trivial)
        let runID = audit.begin(agentType: "LocalTest", engine: .local, model: nil, decision: nil, prompt: "local model test", privacy: .normal,
                                label: "Test local model", owner: .agent)
        let provider = SafeProvider(base: LocalQwenProvider(runtime: localRuntime, profile: profile, maxTokens: 24), runID: runID, hub: hub)
        let task = Task { @MainActor in
            let r = await OneShotRunner.run(provider: provider, prompt: "Reply with exactly: JARVIS_LOCAL_OK", timeout: 120)
            if r.succeeded {
                self.localTestResult = "“\(r.text.trimmingCharacters(in: .whitespacesAndNewlines))” in \(String(format: "%.1f", r.durationMS / 1000)) s"
                self.audit.finish(runID, status: .succeeded, resultText: r.text, usage: (r.inputTokens, r.outputTokens))
            } else {
                self.localTestResult = "failed: \(r.error.map { AuditRecorder.category($0) } ?? (r.timedOut ? "timeout" : "cancelled"))"
                self.audit.finish(runID, status: r.cancelled ? .cancelled : .failed, error: r.error)
            }
        }
        userTasks[runID] = task
        await task.value
        userTasks[runID] = nil
    }

    /// Discovery for every engine (event-driven, once at launch and on demand). Stubbed runs skip real providers entirely.
    func refreshIntelligence(remoteCatalog: Bool = true, includeOpenCode: Bool = true) async {
        if intelligenceIsStubbed {
            providers.probeOverride = { id, _ in ProviderStatus(id: id, state: .notInstalled) }
            await providers.refresh()
            return
        }
        resources.start()
        await supervisor.refreshAll(remoteCatalog: remoteCatalog, includeOpenCode: includeOpenCode)
    }
}
