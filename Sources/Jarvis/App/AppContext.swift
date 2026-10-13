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
    // V0.4 autonomous task engine
    let leases: FileLeaseManager
    let taskEngine: TaskEngine
    let unity: UnityService          // V0.6: typed Unity tool layer (discovery, connections, mutation lock, owned editors)
    let taskBridge: TaskBridge
    let taskIntake: TaskIntake
    /// V0.9: web research + acquisition (nil in stubbed automated runs: they never touch the network).
    let research: ResearchServices?
    let researchModel: ResearchViewModel
    /// V0.10: derived, provenance-backed project knowledge (decisions, constraints, failures, research/asset decisions) with hybrid retrieval and a bounded agent context.
    let memory: ProjectMemory
    let memoryModel: MemoryViewModel
    /// V0.11: General Computer Use (Accessibility / NSWorkspace / window-scoped vision) as an ordinary V0.4 task kind. Stubbed runs get a backend that can reach nothing.
    let computer: ComputerRuntime
    let computerModel: ComputerViewModel
    let orchestrationModel: OrchestrationViewModel
    /// V0.13: project continuity — status questions and “continue” resolved against current project truth; checkpoints when tasks finish. Derived view, no execution path of its own.
    let continuity: ProjectContinuity
    /// V0.13: general visual grounding (perception only; its proposals pass through the same Computer Use validation as everything else).
    let visual: VisualGrounder
    let visionRuntime: LocalVLMRuntime
    let operatorModel: ProjectOperatorViewModel
    // V0.5 proactive layer: decides (never executes) — approved/auto actions become normal V0.4 tasks
    let opportunities: OpportunityEngine
    let proposalService: ProposalService
    // V0.7 voice I/O: an input/output layer around the SAME conversation pipeline (never a second assistant)
    let whisper: WhisperRuntime
    let voice: VoiceCoordinator
    // V0.8 natural voice: ONE microphone hub, the local wake/VAD sentinel, the local neural voice, and the hands-free turn manager.
    let micHub: MicrophoneHub
    let sentinel: SentinelRuntime
    let neuralVoice: NeuralVoiceRuntime
    let handsFree: HandsFreeCoordinator
    @ObservationIgnored private var sleepObservers: [NSObjectProtocol] = []
    private(set) var persistenceError: String?
    /// Automated runs (smoke/capture/--no-providers) use a throw-away data directory and NEVER touch real providers.
    let intelligenceIsStubbed: Bool

    @ObservationIgnored private(set) var conversationService: ConversationService!
    @ObservationIgnored private(set) var windowManager: WindowManager!

    /// Views and (later) the intent layer talk to windows only through this protocol.
    var windows: any JarvisWindowControlling { windowManager }

    /// `voiceRig`: only the natural-voice live test passes one (a scripted microphone + simulated speaker in a closed acoustic loop; no hardware).
    init(seedDemoData: Bool = true, stubIntelligence: Bool = false, dataDirectory: URL? = nil, voiceRig: VoiceTestRig? = nil) {
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
        leases = FileLeaseManager(repository: repo)
        taskEngine = TaskEngine(repository: repo, artifacts: artifacts, audit: audit, leases: leases, agents: ManagerAgentRunner(manager: agents))
        unity = UnityService()
        taskEngine.unity = unity
        taskIntake = TaskIntake(engine: taskEngine, preferences: preferences)
        research = stubIntelligence ? nil : ResearchServices.standard(paths: p, repository: repo, artifacts: artifacts)
        taskEngine.web = research
        let webPrefs = preferences
        taskEngine.orchestrationEnabled = true                              // V0.12: JARVIS is the orchestrator (role contracts, graphs, artifacts, routing records)
        taskEngine.resourcePressure = { [weak resources] in resources?.pressure ?? ResourcePressure() }
        taskEngine.webAllowed = { [weak webPrefs] in webPrefs?.webResearchEnabled ?? true }
        let webResources = resources
        taskEngine.browserTierAllowed = { [weak webPrefs, weak webResources] in
            (webPrefs?.webBrowserTierEnabled ?? true) && ResearchResourcePolicy.allowsBrowser(memory: webResources?.pressure.memory ?? .normal, thermalSerious: webResources?.pressure.thermalSerious ?? false)
        }
        researchModel = ResearchViewModel(repository: repo, artifacts: artifacts, engine: taskEngine, preferences: preferences)
        // V0.10 Project Memory (the embedding helper is only ever started on demand; in stubbed runs its runtime path does not exist)
        let embeddingController = EmbeddingHostController(config: .standard(paths: runtimePaths))
        // (if the real database could not be opened the app already reports it; memory then works on a throw-away database for this run instead of failing)
        let memoryRepo = repo ?? JarvisRepository(database: try! JarvisDatabase(url: JarvisPaths.temporary("jarvis-memory-fallback").database))
        memory = ProjectMemory(repository: memoryRepo, preferences: preferences, embedding: embeddingController)
        memoryModel = MemoryViewModel(memory: memory, preferences: preferences)
        memory.start()
        taskEngine.memory = memory
        // V0.11 Computer Use (nothing is observed or operated until a task you started needs it; the emergency-stop sampler exists only while a session runs)
        computer = ComputerRuntime(backend: stubIntelligence ? DisabledUIBackend() : AXBackend(), repository: repo, workspacePath: p.researchWorkspace.path)
        computer.isStubbed = stubIntelligence
        computer.quarantineRoot = p.acquisitions.path
        let computerPrefs = preferences, computerResources = resources
        computer.enabled = { [weak computerPrefs] in computerPrefs?.computerUseEnabled ?? true }
        computer.visionEnabled = { [weak computerPrefs] in computerPrefs?.computerVisionEnabled ?? false }
        computer.pressureNormal = { [weak computerResources] in (computerResources?.pressure.memory ?? .normal) == .normal }
        // V0.13 general visual grounding: Apple text recognition + the local vision model (on demand, unloaded when idle or under memory pressure). Stubbed runs get no providers.
        let visionPrefs = preferences
        visionRuntime = LocalVLMRuntime(config: .standard(paths: runtimePaths, model: preferences.visualModel))
        visionRuntime.pressureNormal = { [weak computerResources] in (computerResources?.pressure.memory ?? .normal) == .normal }
        visual = VisualGrounder(providers: stubIntelligence ? [] : [AppleVisionProvider(), LocalVLMProvider(runtime: visionRuntime)])
        visual.mode = { [weak visionPrefs] in visionPrefs?.visualGroundingMode ?? .auto }
        visual.pressureNormal = { [weak computerResources] in (computerResources?.pressure.memory ?? .normal) == .normal }
        if !stubIntelligence { computer.vision = GroundedVisionProposer(grounder: visual) }
        taskEngine.computer = computer
        taskEngine.visual = stubIntelligence ? nil : visual
        taskEngine.experimentsRoot = ExperimentWorkspace.defaultRoot(dataRoot: paths.root)
        taskEngine.experimentsEnabled = { [weak preferences] in preferences?.experimentsEnabled ?? true }
        taskEngine.computerAllowed = { [weak computerPrefs] in computerPrefs?.computerUseEnabled ?? true }
        computerModel = ComputerViewModel(runtime: computer, engine: taskEngine, preferences: preferences)
        orchestrationModel = OrchestrationViewModel(repository: repo)
        continuity = ProjectContinuity(repository: repo, engine: taskEngine, memory: memory, preferences: preferences)
        continuity.enabled = { [weak webPrefs] in webPrefs?.projectContinuationEnabled ?? true }
        continuity.unityEditorState = { [weak unity] root in unity?.existingConnection(for: root)?.state.label }
        operatorModel = ProjectOperatorViewModel(continuity: continuity, preferences: preferences)
        let engineRef = taskEngine
        computer.onEmergencyStop = { [weak engineRef] in engineRef?.cancelComputerTasks(reason: "emergency stop") }
        computer.onEvent = { [weak engineRef] id, e in engineRef?.note(e.summary, e.isWarning ? .warning : .info, taskID: id) }
        opportunities = OpportunityEngine(repository: repo, audit: audit, tasks: taskEngine)
        proposalService = ProposalService(repository: repo, engine: opportunities)
        whisper = WhisperRuntime(config: .standard(paths: runtimePaths, modelPath: stubIntelligence ? "/nonexistent/jarvis-stub-whisper" : preferences.whisperModelPath))
        let stubbedVoice = stubIntelligence
        var sentinelConfig = SentinelRuntime.Config.standard(paths: runtimePaths)
        if stubbedVoice { sentinelConfig.modelsDirectory = "/nonexistent/jarvis-stub-wake" }
        sentinel = SentinelRuntime(config: sentinelConfig)
        neuralVoice = NeuralVoiceRuntime(config: .standard(paths: runtimePaths, modelDirectory: stubbedVoice ? "/nonexistent/jarvis-stub-voice" : preferences.neuralVoiceModelPath))
        let presetPrefs = preferences
        let presetBox = VoiceCoordinator.PresetOverride()
        let microphoneHub = MicrophoneHub(makeSource: { voiceRig.map { $0.microphone as any AudioInput } ?? MicrophoneInput() })
        micHub = microphoneHub
        let makePlayer: () -> any PCMPlayback = { voiceRig.map { $0.makePlayback() as any PCMPlayback } ?? SpeechPlayer() }
        voice = VoiceCoordinator(sttProviders: [WhisperSTTProvider(runtime: whisper), AppleSpeechSTTProvider()],
                                 ttsProviders: [NeuralSpeechProvider(runtime: neuralVoice, preset: { [weak presetPrefs] in presetBox.value ?? presetPrefs?.voicePreset ?? .jarvisDefault }, player: makePlayer()),
                                                AppleSpeechSynthesizerProvider(player: makePlayer())],
                                 permission: voiceRig.map { _ in RigMicrophonePermission() }, store: store, makeInput: { HubAudioInput(hub: microphoneHub) }, presetOverride: presetBox)
        handsFree = HandsFreeCoordinator(hub: microphoneHub, sentinel: sentinel, voice: voice)

        if stubIntelligence {
            // Stub at construction (not on first refresh): nothing may reach a real provider, its service, or the network.
            providers.probeOverride = { id, _ in ProviderStatus(id: id, state: .notInstalled) }
            openCode.isStubbed = true
        }

        if seedDemoData { DemoScenario.seed(store) }
        taskBridge = TaskBridge(engine: taskEngine, store: store, hub: hub)
        windowManager = WindowManager(context: self)
        // (The closed-loop natural voice test answers from a script: non-command turns must never reach a real model or spend quota.)
        conversationService = ConversationService(store: store, conversation: conversation, windows: windowManager, resolver: voiceRig != nil ? ScriptedAnswerResolver() : coordinator)
        // Autonomous work is only enabled for the real app: stubbed automated runs never start tasks (and never reach providers).
        if !stubIntelligence { conversationService.taskSubmitter = taskIntake; conversationService.researchSubmitter = taskIntake; conversationService.computerSubmitter = taskIntake }
        conversationService.graphStatus = { [weak taskEngine] focus, lang in taskEngine?.graphStatusText(focus, lang) }
        if !stubIntelligence { conversationService.continuityHandler = continuity }       // V0.13: stubbed automated runs never start continuation tasks
        conversationService.memoryHandler = memory                         // V0.10: remember / correct / forget / "what did we decide…" — typed and spoken text alike
        memory.onActivity = { [weak store] message, kind in store?.log(message, kind: kind, persist: false) }
        memory.modelCall = { [weak self] task, prompt in
            guard let self else { return nil }
            var profile = TaskProfile(category: .summarization, complexity: .simple, privacy: task.privacy)
            profile.wantsStructuredOutput = true; profile.estimatedContextTokens = prompt.count / 4
            let job = AgentJob(type: "MemoryAgent", title: "Memory · lessons from “\(OutputSanitizer.sanitize(String(task.title.prefix(40))))”", prompt: prompt, profile: profile, taskID: task.id,
                               validator: { text in PlanParser.extractJSONObject(text).flatMap { JSONValue.parse($0) }?["memories"]?.array != nil ? BenchmarkSuite.Verdict(passed: true, detail: "") : BenchmarkSuite.Verdict(passed: false, detail: "reply with the JSON object") },
                               timeout: 180, policy: EscalationPolicy(maxRepairAttempts: 1, maxEscalations: 0, maxTotalAttempts: 2), preference: task.preference)
            if case .completed(let text, _, let cand, _) = await self.taskEngine.agents.run(job) { return (text, cand.label) }
            return nil
        }

        // --- V0.7 voice: wiring (nothing starts here: no microphone, no helper process, no permission request) ---
        let voicePrefs = preferences
        voice.settings = { stubIntelligence ? VoiceSettings(enabled: false) : voicePrefs.voiceSettings }          // automated runs never use voice
        whisper.idleUnloadProvider = { [weak voicePrefs] in voicePrefs?.whisperIdleUnloadSeconds ?? 120 }
        voice.memoryPressureNormal = { [weak self] in self?.resources.pressure.memory == .normal }
        voice.conversation = { [weak self] in self?.conversation.messages ?? [] }
        voice.conversationBusy = { [weak self] in self?.conversationService.isAnswering ?? false }
        voice.submit = { [weak self] text, _ in
            guard let self else { return nil }
            // Same entry point as typed text; only the origin surface differs (Compact open → Compact behaviour, exactly like typing there).
            self.conversationService.submit(text, origin: self.hud.isCompactVisible ? .compactHUD : .other, source: .voice)
            return self.conversation.messages.last(where: { $0.role == .user })?.id
        }
        conversationService.onSubmit = { [weak self] source in if source == .typed { self?.voice.typedInputArrived() } }
        conversationService.stopSpeech = { [weak self] in self?.voice.stopSpeaking() ?? false }
        voice.onEvent = { [weak store] message, kind in store?.log(message, kind: kind) }
        whisper.onEvent = { [weak store] message in store?.log(message, kind: .info) }
        resources.observePressureRise { [weak self] _ in Task { @MainActor in await self?.whisper.unload(); await self?.neuralVoice.unload(); self?.research?.browser?.releaseUnderPressure(); self?.memory.onMemoryPressure(); self?.computer.onMemoryPressure(); await self?.visual.unloadHeavyProviders() } }          // the small wake sentinel stays
        handsFree.settings = { stubIntelligence ? VoiceSettings(enabled: false) : voicePrefs.voiceSettings }
        handsFree.onEvent = { [weak store] message, kind in store?.log(message, kind: kind) }
        sentinel.onEvent = { [weak store] message in store?.log(message, kind: .info) }
        neuralVoice.onEvent = { [weak store] message in store?.log(message, kind: .info) }
        neuralVoice.idleUnloadProvider = { [weak voicePrefs] in voicePrefs?.neuralIdleUnloadSeconds ?? 180 }
        // JARVIS knows exactly what it plays: the level of every output slice is the reference that lets barge-in tell the user from JARVIS' own voice.
        for case let provider as PlayerBackedTTSProvider in voice.ttsProviders {
            provider.player.onReferenceLevel = { [weak hf = handsFree] db, t in Task { @MainActor in hf?.referenceLevel(db, at: t) } }
        }
        if !stubIntelligence {
            observeContinuously(track: { _ = voicePrefs.voiceEnabled; _ = voicePrefs.voiceWakeEnabled }, onChange: { [weak self] in Task { @MainActor in await self?.handsFree.applySettings() } })
            Task { @MainActor [weak self] in await self?.handsFree.applySettings() }          // wake mode returns after launch only if the user left it on (and the microphone is allowed)
        }
        observeContinuously(track: { [weak self] in _ = self?.conversation.messages; _ = self?.conversationService.isAnswering },
                            onChange: { [weak self] in self?.voice.conversationChanged() })

        // Activity: meaningful events only (lifecycle, escalation, cooldown) — never tokens or health checks.
        let sink: (String) -> Void = { [weak store] in store?.log($0, kind: .info) }
        supervisor.onEvent = sink
        coordinator.onEvent = sink
        agents.onEvent = sink
        let audit = self.audit
        store.onLog = { event in audit.activity(event.kind.rawValue, event.message) }

        // Stop is the EXISTING cancellation, addressed by run id (see ExecutionHub.installStopRouting).
        let engine = taskEngine
        hub.installStopRouting(conversation: conversationService, agents: agents, userTask: { [weak self] in self?.userTasks[$0] }, demo: { [weak self] in self?.observatory.demo },
                               taskStop: { [weak engine] runID in engine?.cancelTask(owningRun: runID) ?? false })

        // --- V0.4: task engine glue (events → activity feed; finished tasks → conversation; launch recovery; sleep/wake) ---
        let store = self.store
        taskEngine.onEvent = { [weak store] message, kind in store?.log(message, kind: kind, persist: false) }       // the engine already persisted it with its task id
        let prefs = preferences
        opportunities.settings = { [weak prefs] in prefs?.autonomySettings ?? AutonomySettings() }
        opportunities.onEvent = { [weak store] message, kind in store?.log(message, kind: kind, persist: false) }
        taskEngine.onReviewSuggestions = { [weak self] task, step, run, suggestions in
            guard let self else { return }
            Task { @MainActor in await self.opportunities.reviewSuggestions(task: task, stepID: step, runID: run, suggestions: suggestions) }
        }
        taskEngine.onFinished = { [weak self] v in
            guard let self else { return }
            self.taskBridge.finished(v)
            let finishedReport = self.taskEngine.report(for: v.id)
            Task { @MainActor in await self.memory.taskFinished(v, report: finishedReport) }          // V0.10: only meaningful outcomes become memory
            Task { @MainActor in await self.continuity.taskFinished(v, report: finishedReport) }       // V0.13: the checkpoint this task leaves behind (Git HEAD, file hashes, validated / remaining)
            // V0.12: a child task (research / computer node of a graph) reports to its PARENT's graph — it never speaks to the user or triggers the proactive layer on its own.
            if v.task.parentTaskID != nil { return }
            Task { @MainActor in await self.opportunities.taskFinished(v) }          // event-driven post-task reflection (bounded; no polling)
            if let report = self.taskEngine.report(for: v.id) {
                let text = self.taskEngine.researchSummary(for: v) ?? report.userSummary          // V0.9: a research task's message is its cited recommendation
                self.conversation.appendJarvis(text, tone: v.task.state == .completed ? .normal : .notice, route: .worker)
                Announcer.announce(text, high: v.task.state != .completed)
            }
        }
        if !stubIntelligence {
            // Restart reconciliation: stale RUNNING tasks → INTERRUPTED (resumed only by the user); leases of the dead process → stale;
            // tasks that were waiting for an approval wait again.
            let r = taskEngine.reconcileOnLaunch()
            _ = try? repository?.reconcileComputerAfterRestart()                       // V0.11: GUI sessions are INTERRUPTED, never resumed silently
            _ = try? repository?.reconcileExperimentsAfterRestart()                   // V0.13: an experiment that was running is INTERRUPTED (never resumed by itself) …
            if let root = taskEngine.experimentsRoot { let finished = Set(((try? repository?.recentExperiments(limit: 200)) ?? []).filter { $0.status != "running" }.map(\.id)); ExperimentWorkspace.reconcile(under: root, finishedIDs: finished) }       // … and its JARVIS-owned temporary folder is removed (marker-checked, inside the experiments root only)
            _ = try? repository?.pruneCheckpoints(keep: 30); _ = try? repository?.pruneVisualObservations(keep: 500)
            _ = try? repository?.pruneOrchestration(keepTasks: 150)                  // V0.12: artifacts/routing rows of old finished tasks fall away (history stays)
            try? repository?.pruneComputerSessions(keep: 100)                          // bounded history: old sessions (and their action/observation rows) fall away
            if let repo = self.repository {                                            // V0.9: in-flight research/downloads are INTERRUPTED, never resumed silently
                _ = try? repo.reconcileResearchAfterRestart()
                if let web = research, let active = try? repo.acquisitions(states: [.verifying, .approved, .downloading, .downloaded, .inspecting]) { for rec in web.acquisition.reconcile(active) { web.persistence?.save(rec) } }
            }
            if r.leases > 0 { Log.app.info("released \(r.leases) stale file lease(s)") }
            taskEngine.restoreWaitingTasks()
            let nc = NSWorkspace.shared.notificationCenter
            sleepObservers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak engine, weak self] _ in MainActor.assumeIsolated { engine?.willSleep(); self?.voice.cancelAll(reason: "stopped for sleep") } })
            sleepObservers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak engine] _ in MainActor.assumeIsolated { engine?.didWake() } })
        }
        taskEngine.refreshHistory()
        taskBridge.sync()
        if !stubIntelligence { Task { @MainActor [opportunities] in await opportunities.reconcileOnLaunch() } }
        opportunities.refresh()
    }

    /// Normal termination / SIGTERM: stop scheduling, persist the interrupted state + checkpoints, release leases (processes are killed by `ProcessRegistry`).
    func prepareForTermination() { visionRuntime.shutdownNow(); taskEngine.prepareForTermination(); research?.browser?.shutdown(); memory.shutdown(); unity.forgetOwnedEditors(); handsFree.shutdown(); voice.shutdown() }

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

    /// V0.12: the ROLE benchmark (planning, analysis, coding, review, research synthesis, strict JSON, security discipline) for one engine/model. Real requests (OpenCode free, or the
    /// user's own Claude Code / Codex subscription — never a paid API). Results are recorded under suite `roles-v1`; they never change the V0.3.1 Auto gates.
    @discardableResult
    func benchmarkRoles(engine: ProviderID, modelID: String? = nil) async -> [BenchmarkRunner.CaseOutcome] {
        guard !intelligenceIsStubbed else { return [] }
        let key = modelID ?? "engine:\(engine.rawValue)"
        let runID = audit.begin(agentType: "BenchmarkAgent", engine: engine, model: modelID, decision: nil, prompt: "role benchmark \(RoleBenchmarkSuite.id)", privacy: .normal, label: "Role benchmark · \(modelID ?? engine.displayName)", owner: .benchmark)
        hub.setPhase(runID, .running, activity: "Role benchmark")
        let openCode = self.openCode, hub = self.hub, providers = self.providers
        let outcomes = await benchmarks.run(modelID: key, cases: RoleBenchmarkSuite.all, suite: RoleBenchmarkSuite.id, makeProvider: {
            switch engine {
            case .openCode:
                guard let id = modelID, let m = openCode.model(id), let p = openCode.provider(for: m) else { return nil }
                return SafeProvider(base: p, runID: runID, hub: hub)
            case .claudeCode, .codex:
                guard let path = providers.status(engine).executablePath, providers.status(engine).state.isUsable else { return nil }
                return SafeProvider(base: providers.makeProvider(engine, path: path), runID: runID, hub: hub)
            default: return nil
            }
        })
        audit.finish(runID, status: .succeeded, resultText: "\(outcomes.filter(\.passed).count)/\(outcomes.count) role cases passed")
        return outcomes
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
