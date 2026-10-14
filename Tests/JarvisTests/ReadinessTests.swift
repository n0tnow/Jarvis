import Testing
import Foundation
@testable import Jarvis

// V0.15 — readiness (read-only), the readiness questions, the typed setup runner, model folders, notifications and the single-instance rule.

private func probes(_ edit: (inout ReadinessProbes) -> Void = { _ in }) -> ReadinessProbes {
    var p = ReadinessProbes()
    p.now = { Date(timeIntervalSince1970: 1_800_000_000) }
    p.versionLine = { "0.15.0 · build 1" }
    p.installedMode = { true }
    p.schemaVersion = { 14 }
    p.providers = { [
        ProviderProbeResult(id: "claude", name: "Claude Code", state: .ready, version: "2.1.0", path: "/x/claude", loginHint: "claude"),
        ProviderProbeResult(id: "codex", name: "Codex", state: .ready, version: "0.15", path: "/x/codex", loginHint: "codex login"),
    ] }
    p.openCode = { (.ready, 4) }
    p.localQwen = { LocalModelProbe(kind: .ready(loaded: false), modelPath: "/models/qwen") }
    p.vision = { (true, nil) }
    p.memoryEmbedding = { (true, nil) }
    p.whisper = { .ready }
    p.appleSTT = { .ready }
    p.naturalVoice = { (true, "local neural voice") }
    p.wakeWord = { (true, false, "off") }
    p.tts = { [("Apple System Voice", .ready)] }
    p.microphone = { .granted }
    p.accessibility = { .granted }
    p.screenRecording = { .granted }
    p.notifications = { .granted }
    p.unity = { UnityProbe(editorVersions: ["6000.5.1f1"], hubInstalled: true, connectedProject: nil, bridge: nil, editorRunning: false) }
    p.mcp = { MCPProbe(installed: 0, active: 0, degraded: 0, recommended: 0, newestHealthCheck: nil) }
    p.launchAtLogin = { .disabled }
    edit(&p)
    return p
}

@Suite("Readiness · states")
@MainActor
struct ReadinessStateTests {
    @Test("everything present reads as ready; the picture covers every category")
    func allReady() {
        let s = ReadinessService.build(probes())
        #expect(s.summary == .ready || { if case .usable = s.summary { return true }; return false }())
        for c in ReadinessCategory.allCases { #expect(!s.items(in: c).isEmpty, "\(c.rawValue)") }
        #expect(s.item("provider.claude")?.state == .ready)
        #expect(s.item("core.app")?.detail.contains("installed application") == true)
    }

    @Test("an executable that was never probed is AVAILABLE, never READY; a missing one is NOT INSTALLED; sign-in is its own state")
    func providerStates() {
        let s = ReadinessService.build(probes { p in
            p.providers = { [ProviderProbeResult(id: "claude", name: "Claude Code", state: .unknown, version: nil, path: "/x/claude", loginHint: "claude"),
                             ProviderProbeResult(id: "codex", name: "Codex", state: .notInstalled, version: nil, path: nil, loginHint: nil)] }
            p.openCode = { (.authenticationRequired, 0) }
        })
        #expect(s.item("provider.claude")?.state == .available)
        #expect(s.item("provider.codex")?.state == .notInstalled)
        #expect(s.item("provider.opencode")?.state.needsAttention == true)
        let signIn = ReadinessService.build(probes { p in p.providers = { [ProviderProbeResult(id: "codex", name: "Codex", state: .authenticationRequired, version: "1", path: "/x", loginHint: "codex login")] } })
        #expect(signIn.item("provider.codex")?.state == .signInRequired)
        #expect(signIn.item("provider.codex")?.detail.contains("codex login") == true)
    }

    @Test("a paid API is never offered: the item is present and says a subscription is not API permission")
    func paidAPI() {
        let s = ReadinessService.build(probes())
        let paid = s.item("provider.paid")
        #expect(paid?.state == .notRunning && paid?.action == nil && paid?.detail.contains("never permission") == true)
    }

    @Test("a stubbed (automated) run says nothing was contacted")
    func stubbed() {
        let s = ReadinessService.build(probes { $0.stubbed = { true } })
        #expect(s.item("provider.stub")?.state == .unknown && s.item("provider.claude") == nil)
    }

    @Test("optional components that are absent are not warnings; broken ones are")
    func optionalVersusBroken() {
        let s = ReadinessService.build(probes { p in
            p.localQwen = { LocalModelProbe(kind: .runtimeMissing, modelPath: "") }
            p.vision = { (false, "not installed") }
            p.whisper = { .needsSetup("no runtime") }
            p.naturalVoice = { (false, "") }
            p.memoryEmbedding = { (false, nil) }
        })
        for id in ["local.qwen", "local.vision", "local.whisper", "voice.neural", "local.embedding"] {
            #expect(s.item(id)?.state == .optionalAbsent && s.item(id)?.state.needsAttention == false, "\(id)")
        }
        #expect(s.item("local.qwen")?.action == .installLocalModelRuntime)
        let bad = ReadinessService.build(probes { $0.localQwen = { LocalModelProbe(kind: .failed("worker crashed"), modelPath: "/m") } })
        #expect(bad.item("local.qwen")?.state.needsAttention == true)
    }

    @Test("permissions: not asked ≠ denied; Accessibility is a warning only while Computer Use is on")
    func permissions() {
        let s = ReadinessService.build(probes { p in p.microphone = { .notDetermined }; p.accessibility = { .notDetermined }; p.screenRecording = { .notDetermined }; p.notifications = { .denied } })
        #expect(s.item("voice.mic")?.state == .optionalAbsent && s.item("voice.mic")?.action == .allowMicrophone)
        #expect(s.item("computer.ax")?.state == .permissionNeeded && s.item("computer.ax")?.action == .allowAccessibility)
        #expect(s.item("computer.screen")?.state == .optionalAbsent)
        #expect(s.item("perm.notifications")?.state == .permissionNeeded && s.item("perm.notifications")?.action == .openNotificationSettings)
        let denied = ReadinessService.build(probes { $0.microphone = { .denied } })
        #expect(denied.item("voice.mic")?.state == .permissionNeeded && denied.item("voice.mic")?.action == .openMicrophoneSettings)
        let off = ReadinessService.build(probes { p in p.accessibility = { .notDetermined }; p.computerUseEnabled = { false } })
        #expect(off.item("computer.ax")?.state == .optionalAbsent)
    }

    @Test("Unity and MCP are shown without being started: idle is NOT RUNNING, stored health is labelled stored")
    func idleThings() {
        let s = ReadinessService.build(probes { p in
            p.mcp = { MCPProbe(installed: 2, active: 1, degraded: 0, recommended: 1, newestHealthCheck: Date(timeIntervalSince1970: 1_800_000_000 - 7200)) }
        })
        #expect(s.item("mcp.summary")?.state == .notRunning && s.item("mcp.summary")?.detail.contains("stored, not live") == true)
        #expect(s.item("unity.bridge")?.state == .notRunning && s.item("unity.editor")?.state == .available)
        let degraded = ReadinessService.build(probes { $0.mcp = { MCPProbe(installed: 2, active: 1, degraded: 1, recommended: 0, newestHealthCheck: nil) } })
        #expect(degraded.item("mcp.summary")?.state.needsAttention == true)
    }

    @Test("a required piece that is broken makes the whole picture NOT READY")
    func requiredBroken() {
        let s = ReadinessService.build(probes { $0.persistenceError = { "disk full" } })
        guard case .notReady = s.summary else { Issue.record("expected not ready"); return }
    }

    @Test("no negative state is ever described with positive words")
    func negativesStayNegative() {
        let l = ReplyLanguage.en
        for s in [ReadinessState.notInstalled, .signInRequired, .permissionNeeded, .degraded("slow"), .unavailable("x"), .stale("old"), .unknown, .optionalAbsent] {
            let phrase = ReadinessAssistant.phrase(s, l).lowercased()
            #expect(!phrase.hasPrefix("ready") && phrase != "ready", "\(s) → \(phrase)")
        }
        #expect(ReadinessAssistant.phrase(.available, .tr).contains("doğrulanmadı"))
    }

    @Test("Launch at Login labels")
    func login() {
        #expect(LoginItemStatus.requiresApproval.label.contains("approval"))
        #expect(ReadinessService.build(probes { $0.launchAtLogin = { .enabled } }).item("startup.login")?.state == .ready)
        #expect(ReadinessService.build(probes { $0.launchAtLogin = { .requiresApproval } }).item("startup.login")?.state == .permissionNeeded)
    }
}

@Suite("Readiness · questions")
@MainActor
struct ReadinessQuestionTests {
    func r(_ s: String) -> ReadinessIntent? { ReadinessIntentParser.recognize(s) }

    @Test("Turkish and English readiness questions are recognised")
    func recognise() {
        #expect(r("Claude hazır mı?") == .provider("claude"))
        #expect(r("Is Codex ready?") == .provider("codex"))
        #expect(r("OpenCode hazır mı") == .provider("opencode"))
        #expect(r("Ses sistemi hazır mı?") == .voice)
        #expect(r("is the voice system ready") == .voice)
        #expect(r("MCP'ler sağlıklı mı?") == .mcp)
        #expect(r("Qwen kurulu mu?") == .localModels("qwen"))
        #expect(r("Is Whisper installed?") == .localModels("whisper"))
        #expect(r("İzinler tamam mı, accessibility hazır mı?") == .permissions)
        #expect(r("Unity hazır mı?") == .unity)
        #expect(r("Her şey hazır mı?") == .overall)
        #expect(r("Hangi sürümdesin?") == .version)
    }

    @Test("other sentences are not readiness questions")
    func notRecognised() {
        #expect(r("Fix the multiplayer sync problem") == nil)
        #expect(r("Claude ile bir hikaye yaz") == nil)
        #expect(r("Hamam ne durumda?") == nil)
        #expect(r("open the settings") == nil)
    }

    @Test("answers come from the picture, say negatives plainly and never claim a model call")
    func answers() {
        let svc = ReadinessService(probes: probes { p in
            p.providers = { [ProviderProbeResult(id: "claude", name: "Claude Code", state: .ready, version: "2.1.0", path: "/x", loginHint: "claude"),
                             ProviderProbeResult(id: "codex", name: "Codex", state: .authenticationRequired, version: nil, path: "/y", loginHint: "codex login")] }
            p.microphone = { .denied }
        })
        let a = ReadinessAssistant(service: svc)
        #expect(a.reply(to: .provider("claude"), language: .tr).contains("hazır"))
        #expect(a.reply(to: .provider("claude"), language: .en).contains("no model request"))
        #expect(a.reply(to: .provider("codex"), language: .en).contains("sign in"))
        #expect(a.reply(to: .provider("codex"), language: .en).contains("cannot sign in for you"))
        #expect(a.reply(to: .voice, language: .en).lowercased().contains("needs a permission"))
        let overall = a.reply(to: .overall, language: .en)
        #expect(overall.contains("Codex") && overall.contains("Microphone"))
    }
}

// MARK: Setup runner

@MainActor
private func fakeBundle(scripts: [String: String] = ["setup_local_ai.sh": "#!/bin/sh\necho hello\nexit 0\n"]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-setup-\(UUID().uuidString)", isDirectory: true)
    let dir = root.appendingPathComponent("scripts", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, body) in scripts {
        let url = dir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    return root
}

@Suite("Setup · typed, allowlisted, bounded")
@MainActor
struct SetupRunnerTests {
    func runner(_ root: URL?, free: Int64 = 100_000_000_000, uv: Bool = true) -> SetupRunner {
        let r = SetupRunner()
        r.resourceRoot = { root }
        r.freeBytes = { free }
        r.findTool = { _ in uv }
        r.environment = { ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()] }
        return r
    }

    @Test("only the five install actions have a plan, and each plan's script exists in the repository")
    func catalog() {
        let installs = SetupAction.allCases.filter(\.isInstall)
        #expect(installs.count == 5)
        for a in SetupAction.allCases { #expect((SetupCatalog.plan(for: a) != nil) == a.isInstall, "\(a)") }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for a in installs {
            let plan = SetupCatalog.plan(for: a)!
            #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("scripts/\(plan.script)").path), "\(plan.script)")
            #expect(!plan.script.contains("/") && !plan.arguments.contains { $0.contains("http") || $0.contains(";") || $0.contains("|") })
        }
    }

    @Test("a run executes the packaged script, streams sanitised lines, and ends FINISHED")
    func success() async throws {
        let root = try fakeBundle(scripts: ["setup_local_ai.sh": "#!/bin/sh\necho step-one\necho token=sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\nexit 0\n"])
        let r = runner(root)
        let refusal = await r.start(.installLocalModelRuntime)
        #expect(refusal == nil)
        guard case .finished(.installLocalModelRuntime, ok: true, _) = r.state else { Issue.record("state \(r.state)"); return }
        #expect(r.log.contains { $0.contains("step-one") }, "log: \(r.log)")
        #expect(r.log.contains { $0.contains("step-one") } && !r.log.joined().contains("sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))
    }

    @Test("a failing script ends FINISHED/not ok with the reason; it is safe to run again")
    func failure() async throws {
        let root = try fakeBundle(scripts: ["setup_local_ai.sh": "#!/bin/sh\necho 'uv is required'\nexit 3\n"])
        let r = runner(root)
        _ = await r.start(.installLocalModelRuntime)
        guard case .finished(_, ok: false, let summary) = r.state else { Issue.record("state \(r.state)"); return }
        #expect(summary.contains("uv is required") && summary.contains("safe to run again"))
    }

    @Test("not enough disk space: nothing starts")
    func disk() async throws {
        let r = runner(try fakeBundle(), free: 10_000_000)
        let refusal = await r.start(.installLocalModelRuntime)
        guard case .notEnoughSpace = refusal else { Issue.record("expected a disk refusal, got \(String(describing: refusal))"); return }
        #expect(r.state == .idle && r.log.isEmpty)
    }

    @Test("missing uv, a development build, and a stubbed run are refused")
    func refusals() async throws {
        #expect(await runner(try fakeBundle(), uv: false).start(.installLocalModelRuntime) == .uvMissing)
        #expect(await runner(nil).start(.installLocalModelRuntime) == .noPackagedScripts)
        let stub = runner(try fakeBundle()); stub.stubbed = true
        #expect(await stub.start(.installLocalModelRuntime) == .stubbedRun)
        #expect(await runner(try fakeBundle()).start(.recheck) == .notAnInstallAction)
    }

    @Test("a symlinked or outside script is never run")
    func symlinkEscape() async throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).sh")
        try "#!/bin/sh\necho pwned\n".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path)
        let root = try fakeBundle(scripts: [:])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("scripts/setup_local_ai.sh"), withDestinationURL: outside)
        let r = runner(root)
        let refusal = await r.start(.installLocalModelRuntime)
        #expect(refusal == .noPackagedScripts || { if case .scriptNotSafe = refusal { return true }; return false }())
        #expect(r.log.isEmpty)
        let noexec = try fakeBundle(scripts: [:])
        let f = noexec.appendingPathComponent("scripts/setup_local_ai.sh")
        try "#!/bin/sh\nexit 0\n".write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.path)
        let again = await runner(noexec).start(.installLocalModelRuntime)
        guard case .scriptNotSafe = again else { Issue.record("a non-executable script must be refused, got \(String(describing: again))"); return }
    }

    @Test("a second request while one runs is refused; cancel stops the whole process and the state says cancelled")
    func duplicateAndCancel() async throws {
        let root = try fakeBundle(scripts: ["setup_local_ai.sh": "#!/bin/sh\necho started\nsleep 30\n"])
        let r = runner(root)
        let first = Task { await r.start(.installLocalModelRuntime) }
        for _ in 0..<100 where !r.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        #expect(r.isRunning)
        #expect(await r.start(.installSpeechRecognizer) == .alreadyRunning)
        for _ in 0..<50 where r.log.isEmpty { try await Task.sleep(for: .milliseconds(40)) }
        await r.cancel()
        _ = await first.value
        #expect(r.state == .cancelled(.installLocalModelRuntime))
    }

    @Test("the script runs with the provider allowlist: API keys in the app's environment never reach it")
    func environmentIsScrubbed() async throws {
        setenv("OPENAI_API_KEY", "sk-test-should-not-leak-0123456789abcdef", 1); setenv("ANTHROPIC_API_KEY", "sk-ant-should-not-leak-0123456789", 1)
        defer { unsetenv("OPENAI_API_KEY"); unsetenv("ANTHROPIC_API_KEY") }
        let root = try fakeBundle(scripts: ["setup_local_ai.sh": "#!/bin/sh\nenv | grep -c -E 'OPENAI_API_KEY|ANTHROPIC_API_KEY' || true\nexit 0\n"])
        let r = SetupRunner(); r.resourceRoot = { root }; r.freeBytes = { 1 << 40 }; r.findTool = { _ in true }      // default environment closure
        _ = await r.start(.installLocalModelRuntime)
        #expect(r.log.contains("0"))
    }
}

@Suite("Setup · existing model folders")
struct ModelFolderTests {
    func folder(_ files: [String]) throws -> URL {
        let u = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/jarvis-test-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        for f in files { try Data("x".utf8).write(to: u.appendingPathComponent(f)) }
        return u
    }

    @Test("a folder with config.json and weights is accepted where it is (not copied)")
    func accepted() throws {
        let u = try folder(["config.json", "model.safetensors"]); defer { try? FileManager.default.removeItem(at: u) }
        guard case .ok(let path) = ModelFolderValidator.validate(u) else { Issue.record("refused"); return }
        #expect(path.hasSuffix(u.lastPathComponent))
    }

    @Test("missing config or weights, a file, an outside folder and an escaping link are refused")
    func refused() throws {
        let noConfig = try folder(["model.safetensors"]); defer { try? FileManager.default.removeItem(at: noConfig) }
        let noWeights = try folder(["config.json"]); defer { try? FileManager.default.removeItem(at: noWeights) }
        if case .ok = ModelFolderValidator.validate(noConfig) { Issue.record("no config accepted") }
        if case .ok = ModelFolderValidator.validate(noWeights) { Issue.record("no weights accepted") }
        if case .ok = ModelFolderValidator.validate(URL(fileURLWithPath: "/etc")) { Issue.record("/etc accepted") }
        let esc = try folder(["config.json", "model.safetensors"]); defer { try? FileManager.default.removeItem(at: esc) }
        try FileManager.default.createSymbolicLink(at: esc.appendingPathComponent("leak.safetensors"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        guard case .refused(let why) = ModelFolderValidator.validate(esc) else { Issue.record("escaping link accepted"); return }
        #expect(why.contains("leak.safetensors"))
    }
}

@Suite("App lifecycle · notifications, login item, single instance, diagnostics")
@MainActor
struct LifecycleTests {
    @Test("notifications: nothing is delivered unless enabled AND allowed; the text carries no content")
    func notifier() async {
        let n = JarvisNotifier()
        var sent: [(String, String)] = []
        n.deliver = { t, b, _ in sent.append((t, b)) }
        n.enabled = { false }
        await n.post(completed: true, language: .en)
        #expect(sent.isEmpty)
        n.enabled = { true }
        await n.post(completed: true, language: .en)               // status is notDetermined: still nothing
        #expect(sent.isEmpty && n.posted == 0)
    }

    @Test("a granted notifier says only that a task finished, failed, or needs a decision")
    func wording() {
        #expect(DailyPhrasebook.notified(completed: true, .en) == "JARVIS completed your task.")
        #expect(DailyPhrasebook.notified(completed: false, .tr) == "JARVIS görevinizi tamamlayamadı.")
        #expect(JarvisNotifier.map(.denied) == .denied && JarvisNotifier.map(.notDetermined) == .notDetermined && JarvisNotifier.map(.authorized) == .granted)
    }

    @Test("a development binary cannot register a login item and says so; the state is reported honestly")
    func loginItem() {
        #expect(LaunchAtLogin.status == .unsupported || LaunchAtLogin.status == .disabled || LaunchAtLogin.status == .notFound)
        if !AppInfo.isApplicationBundle { #expect(LaunchAtLogin.set(true)?.contains("installed JARVIS.app") == true) }
    }

    @Test("only a plain launch is single-instance restricted; developer and live-test launches are not")
    func plainLaunch() {
        #expect(SingleInstance.isPlainLaunch(["/Applications/JARVIS.app/Contents/MacOS/Jarvis"]))
        #expect(SingleInstance.isPlainLaunch(["Jarvis", "-NSDocumentRevisionsDebugMode", "YES"]))
        #expect(!SingleInstance.isPlainLaunch(["Jarvis", "--smoke-test"]))
        #expect(!SingleInstance.isPlainLaunch(["Jarvis", "--adaptive-live-test", "--adaptive-section", "soak"]))
        #expect(SingleInstance.handOverToRunningInstance(bundleID: "dev.jarvis.nonexistent.test", myPID: 1) == false || !SingleInstance.isPlainLaunch())
    }

    @Test("diagnostics carry versions and component states only")
    func diagnostics() {
        let snap = ReadinessService.build(probes { $0.providers = { [ProviderProbeResult(id: "claude", name: "Claude Code", state: .authenticationRequired, version: "9.9.9", path: "/Users/someone/.local/bin/claude", loginHint: "claude")] } })
        let text = DiagnosticsReport.build(snapshot: snap, schema: 14, installed: true)
        #expect(text.contains("JARVIS") && text.contains("macOS") && text.contains("Claude Code — SIGN-IN REQUIRED"))
        #expect(!text.contains("/Users/") && !text.contains(NSHomeDirectory()) && !text.contains("9.9.9"))
    }

    @Test("the app identity comes from the bundle when there is one and from the source otherwise")
    func identity() {
        #expect(!AppInfo.version.isEmpty && AppInfo.milestone == "V0.15" && AppInfo.sourceVersion == "0.15.0")
        #expect(AppInfo.versionLine.contains("build"))
    }

    @Test("daily preferences default to the conservative values")
    func defaults() {
        let suite = "jarvis-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!; defer { d.removePersistentDomain(forName: suite) }
        let p = Preferences(defaults: d)
        #expect(p.responseStyle == .concise && p.addressStyle == .natural && p.conversationFollowUps)
        #expect(p.notifyOnTaskEvents == false && p.firstRunCompleted == false && p.openCompactOnLaunch == false)
        #expect(p.voiceSpeakTaskAcks && p.voiceSpeakCompletions)
    }
}
