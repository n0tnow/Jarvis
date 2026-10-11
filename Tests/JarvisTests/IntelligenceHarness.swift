import Foundation
@testable import Jarvis

/// Whole V0.3.1 stack on fakes: temp SQLite, fake `claude` / `opencode` executables (real child processes), a fake local worker.
/// Never touches real providers, the real database or the network.
@MainActor
final class IntelligenceHarness {
    let dir = FakeCLI.makeDir()
    let paths = JarvisPaths.temporary("harness")
    let database: JarvisDatabase
    let repo: JarvisRepository
    let artifacts: ArtifactStore
    let audit: AuditRecorder
    let hub: ExecutionHub
    var observatory: AgentObservatory!
    let prefs = Preferences(defaults: UserDefaults(suiteName: "jarvis-ih-\(UUID().uuidString)")!)
    let store = JarvisStore()
    let conversation = ConversationStore()
    let windows = FakeWindows()
    let providers: ProviderManager
    let openCode: OpenCodeService
    let runtime: LocalRuntime
    let runtimeDir: String
    let runtimePidfile: String
    let resources = ResourceManager()
    let supervisor: ProviderSupervisor
    let coordinator: IntelligenceCoordinator
    let agents: AgentRunManager
    let service: ConversationService
    var states: [ProviderID: ProviderState] = [.claudeCode: .ready, .codex: .notInstalled]
    var providerPaths: [ProviderID: String] = [:]
    var catalog = ""
    /// How many times OpenCode's catalog was read (reading may start OpenCode's background service — must stay lazy).
    var catalogReads = 0
    var now = RouteFixtures.now.addingTimeInterval(3600)

    init(localMode: String = "normal") {
        try! paths.ensureDirectories()
        database = try! JarvisDatabase(url: paths.database)
        repo = JarvisRepository(database: database)
        artifacts = ArtifactStore(paths: paths, database: database)
        audit = AuditRecorder(repository: repo)
        hub = ExecutionHub(repository: repo, artifacts: artifacts, audit: audit)
        audit.hub = hub
        providers = ProviderManager(preferences: prefs, environmentBase: ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()], workingDirectory: dir + "/work")
        openCode = OpenCodeService(repository: repo, preferences: prefs, environmentBase: ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()], providerWorkspace: dir + "/work")
        let (rt, rdir, pidfile) = FakeWorker.makeRuntime(mode: localMode, idleUnload: 300)
        runtime = rt; runtimeDir = rdir; runtimePidfile = pidfile
        supervisor = ProviderSupervisor(providers: providers, openCode: openCode, local: runtime, resources: resources, repository: repo)
        coordinator = IntelligenceCoordinator(providers: providers, supervisor: supervisor, audit: audit, preferences: prefs)
        agents = AgentRunManager(coordinator: coordinator, resources: resources)
        observatory = AgentObservatory(hub: hub, supervisor: supervisor, openCode: openCode, local: runtime, repository: repo, artifacts: artifacts)
        observatory.demo = ObservatoryDemo(hub: hub)
        DemoScenario.seed(store)
        service = ConversationService(store: store, conversation: conversation, windows: windows, resolver: coordinator)
        hub.installStopRouting(conversation: service, agents: agents, userTask: { _ in nil }, demo: { [weak self] in self?.observatory.demo })
        let me = self
        providers.probeOverride = { id, _ in
            await MainActor.run { ProviderStatus(id: id, state: me.states[id] ?? .notInstalled, version: "1.0.0", executablePath: me.providerPaths[id]) }
        }
        openCode.catalogOverride = { _ in await MainActor.run { me.catalogReads += 1; return ("opencode 1.18.34", me.catalog) } }
        openCode.testExecutablePath = nil
        installOpenCode(.text("OPENCODE_OK"))
        installClaude(text: "CLAUDE_OK")
        setCatalog([("alpha-free", 0, 0)])
    }

    // MARK: Catalog + benchmarks

    func setCatalog(_ models: [(id: String, input: Double, output: Double)], provider: String = "opencode") {
        catalog = models.map { m in
            """
            \(provider)/\(m.id)
            {"id":"\(m.id)","providerID":"\(provider)","name":"\(m.id)","status":"active","api":{"url":"https://opencode.ai/zen/v1"},"cost":{"input":\(m.input),"output":\(m.output),"cache":{"read":0,"write":0}},"limit":{"context":200000},"capabilities":{"toolcall":true,"reasoning":true}}
            """
        }.joined(separator: "\n")
    }

    /// Records passing benchmark evidence for every group (what a real benchmark run would write).
    func passBenchmarks(_ modelID: String, passed: Int? = nil) {
        for g in BenchmarkGroup.allCases {
            let cases = BenchmarkSuite.cases(g)
            for (i, c) in cases.enumerated() {
                let ok = passed.map { i < $0 } ?? true
                try! repo.add(BenchmarkResultRecord(modelID: modelID, suite: BenchmarkSuite.id, caseID: c.id, category: g, passed: ok, validation: "test",
                                                    latencyMS: 500, durationMS: 900, ranAt: Date()))
            }
        }
        supervisor.invalidateBenchmarks()
    }

    // MARK: Fake executables

    enum OpenCodeBehavior { case text(String), noTerminalEvent(String), fail503, gone410, toolsOnly, slow(String), badThenGood(bad: String, good: String) }

    @discardableResult
    func installOpenCode(_ b: OpenCodeBehavior) -> String {
        let marker = "\(dir)/opencode.launches"
        var body: String
        let finish = #"{"type":"step_finish","sessionID":"ses_h1","part":{"reason":"stop","tokens":{"total":120,"input":100,"output":20}}}"#
        func textEvent(_ t: String) -> String { #"{"type":"text","sessionID":"ses_h1","part":{"text":"\#(t)"}}"# }
        switch b {
        case .text(let t):
            body = "cat >/dev/null\ncat <<'EOF'\n\(textEvent(t))\n\(finish)\nEOF"
        case .noTerminalEvent(let t):
            // OpenCode 1.19 behaviour: text part, then the stream just ends (exit 0), no step_finish.
            body = "cat >/dev/null\ncat <<'EOF'\n{\"type\":\"step_start\",\"sessionID\":\"ses_h1\",\"part\":{}}\n\(textEvent(t))\nEOF"
        case .fail503:
            body = "cat >/dev/null\ncat <<'EOF'\n{\"type\":\"error\",\"sessionID\":\"ses_h1\",\"error\":{\"name\":\"APIError\",\"data\":{\"message\":\"unavailable\",\"statusCode\":503}}}\nEOF\nexit 1"
        case .gone410:
            body = "cat >/dev/null\ncat <<'EOF'\n{\"type\":\"error\",\"sessionID\":\"ses_h1\",\"error\":{\"name\":\"APIError\",\"data\":{\"message\":\"Model alpha-free has been deprecated.\",\"statusCode\":410}}}\nEOF\nexit 1"
        case .toolsOnly:
            body = "cat >/dev/null\ncat <<'EOF'\n{\"type\":\"tool_use\",\"sessionID\":\"ses_h1\",\"part\":{\"tool\":\"bash\",\"state\":{\"status\":\"error\",\"error\":\"rejected\"}}}\n{\"type\":\"step_finish\",\"sessionID\":\"ses_h1\",\"part\":{\"reason\":\"tool-calls\"}}\nEOF"
        case .slow(let t):
            body = "echo $$ > \(dir)/opencode.pid\ncat >/dev/null\nsleep \(slowSeconds)\ncat <<'EOF'\n\(textEvent(t))\n\(finish)\nEOF"
        case .badThenGood(let bad, let good):
            // First launch answers `bad`, later launches `good` (launch count = lines in the marker file).
            body = "cat >/dev/null\nn=$(wc -l < \(marker))\nif [ \"$n\" -le 1 ]; then T='\(bad)'; else T='\(good)'; fi\nprintf '%s\\n%s\\n' \"{\\\"type\\\":\\\"text\\\",\\\"sessionID\\\":\\\"ses_h1\\\",\\\"part\\\":{\\\"text\\\":\\\"$T\\\"}}\" '\(finish)'"
        }
        let path = FakeCLI.script("echo \"$$\" >> \(marker)\necho \"$@\" > \(dir)/opencode.args\n\(body)", in: dir, name: "opencode")
        openCode.testExecutablePath = path
        return path
    }
    var slowSeconds = 30

    @discardableResult
    func installClaude(text: String, fail: Bool = false) -> String {
        let marker = "\(dir)/claude.launches"
        let events = fail
            ? "{\"type\":\"result\",\"is_error\":true,\"result\":\"boom\"}"
            : "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"sess-1\"}\n{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"\(text)\"}}}\n{\"type\":\"result\",\"is_error\":false,\"result\":\"\(text)\"}"
        let path = FakeCLI.script("echo \"$$\" >> \(marker)\necho \"$@\" > \(dir)/claude.args\ncat >/dev/null\ncat <<'EOF'\n\(events)\nEOF", in: dir, name: "claude")
        providerPaths[.claudeCode] = path
        return path
    }

    /// Claude answering in several deltas (a secret may be split across them).
    @discardableResult
    func installClaude(chunks: [String]) -> String {
        let marker = "\(dir)/claude.launches"
        let deltas = chunks.map { "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"\($0)\"}}}" }.joined(separator: "\n")
        let path = FakeCLI.script("echo \"$$\" >> \(marker)\ncat >/dev/null\ncat <<'EOF'\n{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"sess-1\"}\n\(deltas)\n{\"type\":\"result\",\"is_error\":false,\"result\":\"x\"}\nEOF", in: dir, name: "claude")
        providerPaths[.claudeCode] = path
        return path
    }

    /// Every artifact file's text (to prove nothing sensitive was written to disk).
    func artifactFilesText() -> String {
        var out = ""
        if let e = FileManager.default.enumerator(at: paths.artifacts, includingPropertiesForKeys: nil) {
            for case let url as URL in e { if let d = try? Data(contentsOf: url) { out += String(decoding: d, as: UTF8.self) + "\n" } }
        }
        return out
    }

    func launches(_ name: String) -> Int {
        ((try? String(contentsOfFile: "\(dir)/\(name).launches", encoding: .utf8)) ?? "").split(separator: "\n").count
    }
    func args(_ name: String) -> String { (try? String(contentsOfFile: "\(dir)/\(name).args", encoding: .utf8)) ?? "" }

    // MARK: Driving

    func refresh() async { await supervisor.refreshAll(remoteCatalog: false) }

    func ask(_ text: String) async { service.submit(text, origin: .fullHUD); await service.waitUntilIdle() }
    var lastReply: ConversationMessage? { conversation.messages.last { $0.role == .jarvis } }

    func runs() -> [AgentRunRecord] { ((try? repo.recentAgentRuns(limit: 50)) ?? []).sorted { $0.startedAt < $1.startedAt } }

    /// Everything stored in SQLite as one string (to assert that nothing sensitive was persisted).
    func databaseText() -> String {
        var out = ""
        for table in ["agent_runs", "activity_events", "tool_executions", "tasks", "artifacts", "model_benchmarks", "model_registry", "provider_health", "agent_events", "agent_run_steps"] {
            for row in (try? database.read("SELECT * FROM \(table)")) ?? [] { out += "\(row)\n" }
        }
        return out
    }

    func shutdown() { runtime.shutdownNow() }
}
