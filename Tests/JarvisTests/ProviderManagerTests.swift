import Foundation
import Testing
@testable import Jarvis

// MARK: - Harness

@MainActor
final class ProviderHarness {
    let dir = FakeCLI.makeDir()
    let store = JarvisStore()
    let conversation = ConversationStore()
    let windows = FakeWindows()
    let prefs = Preferences(defaults: UserDefaults(suiteName: "jarvis-test-\(UUID().uuidString)")!)
    let manager: ProviderManager
    let service: ConversationService
    var states: [ProviderID: ProviderState]
    var paths: [ProviderID: String] = [:]

    init(states: [ProviderID: ProviderState] = [.claudeCode: .ready, .codex: .ready], environment: [String: String] = ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()]) {
        self.states = states
        manager = ProviderManager(preferences: prefs, environmentBase: environment, workingDirectory: dir + "/work")
        DemoScenario.seed(store)
        service = ConversationService(store: store, conversation: conversation, windows: windows, resolver: manager)
        let me = self
        manager.probeOverride = { id, _ in
            await MainActor.run { ProviderStatus(id: id, state: me.states[id] ?? .notInstalled, version: "1.0.0", executablePath: me.paths[id]) }
        }
    }

    /// Installs a fake provider executable that records every launch (marker + args + env) and then runs `body`.
    @discardableResult
    func install(_ id: ProviderID, _ body: String) -> String {
        let marker = "\(dir)/\(id.rawValue).launches"
        let path = FakeCLI.script("""
        echo "$$" >> \(marker)
        echo "$@" > \(dir)/\(id.rawValue).args
        env > \(dir)/\(id.rawValue).env
        \(body)
        """, in: dir, name: id.executableName)
        paths[id] = path
        return path
    }

    func launches(_ id: ProviderID) -> Int {
        ((try? String(contentsOfFile: "\(dir)/\(id.rawValue).launches", encoding: .utf8)) ?? "").split(separator: "\n").count
    }
    func args(_ id: ProviderID) -> String { (try? String(contentsOfFile: "\(dir)/\(id.rawValue).args", encoding: .utf8)) ?? "" }
    func env(_ id: ProviderID) -> String { (try? String(contentsOfFile: "\(dir)/\(id.rawValue).env", encoding: .utf8)) ?? "" }

    func claudeAnswer(_ chunks: [String], session: String = "sess-1") -> String {
        let deltas = chunks.map { "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"\($0)\"}}}" }.joined(separator: "\n")
        return "cat >/dev/null\ncat <<'EOF'\n{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"\(session)\"}\n\(deltas)\n{\"type\":\"result\",\"is_error\":false,\"result\":\"\(chunks.joined())\"}\nEOF"
    }

    func codexAnswer(_ text: String, thread: String = "thread-1") -> String {
        "cat >/dev/null\ncat <<'EOF'\n{\"type\":\"thread.started\",\"thread_id\":\"\(thread)\"}\n{\"type\":\"turn.started\"}\n{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"\(text)\"}}\n{\"type\":\"turn.completed\",\"usage\":{}}\nEOF"
    }

    func ask(_ text: String, origin: InputOrigin = .fullHUD) async { service.submit(text, origin: origin); await service.waitUntilIdle() }
    var lastReply: ConversationMessage? { conversation.messages.last { $0.role == .jarvis } }
}

// MARK: - Selection and states

@MainActor
@Suite("Provider manager", .serialized)
struct ProviderManagerTests {
    @Test func autoPrefersClaudeCodeThenCodexAndOnlyReadyProviders() async {
        let h = ProviderHarness(states: [.claudeCode: .ready, .codex: .ready]); h.paths = [.claudeCode: "/c", .codex: "/x"]
        await h.manager.refresh()
        guard case .ready(let r) = await h.manager.resolve(.reasoning) else { Issue.record("expected ready"); return }
        #expect(r.id == .claudeCode)
        h.states = [.claudeCode: .authenticationRequired, .codex: .ready]; await h.manager.refresh()
        guard case .ready(let r2) = await h.manager.resolve(.reasoning) else { Issue.record("expected codex"); return }
        #expect(r2.id == .codex)
        #expect(h.manager.selectedProvider == .codex)
    }

    @Test func installedIsNotReady() async {
        let h = ProviderHarness(states: [.claudeCode: .authenticationRequired, .codex: .notInstalled]); await h.manager.refresh()
        guard case .unavailable(let e) = await h.manager.resolve(.reasoning) else { Issue.record("must not resolve"); return }
        if case .noProviderReady(let summary) = e { #expect(summary.contains("sign-in required") && summary.contains("not installed")) } else { Issue.record("\(e)") }
        #expect(h.manager.selectedProvider == nil && !h.manager.hasProviders)
    }

    @Test func explicitPreferenceNeverFallsBackToAnotherProvider() async {
        let h = ProviderHarness(states: [.claudeCode: .authenticationRequired, .codex: .ready]); h.paths = [.codex: "/x"]
        h.manager.preference = .claudeCode
        await h.manager.refresh()
        guard case .unavailable(let e) = await h.manager.resolve(.reasoning) else { Issue.record("silent fallback!"); return }
        #expect(e == .authenticationRequired(.claudeCode))
        #expect(e.userMessage().contains("claude auth login"))                    // actionable, official flow
        h.manager.preference = .codex
        guard case .ready(let r) = await h.manager.resolve(.reasoning) else { Issue.record("codex ready"); return }
        #expect(r.id == .codex)
    }

    @Test func preferenceIsPersisted() {
        let suite = "jarvis-pref-\(UUID().uuidString)"
        let a = Preferences(defaults: UserDefaults(suiteName: suite)!)
        a.providerPreference = .codex; a.claudePathOverride = "/opt/x/claude"
        let b = Preferences(defaults: UserDefaults(suiteName: suite)!)
        #expect(b.providerPreference == .codex && b.claudePathOverride == "/opt/x/claude" && b.codexPathOverride.isEmpty)
    }

    @Test func workerKindsNeverResolveToAProvider() async {
        let h = ProviderHarness(); h.paths = [.claudeCode: "/c"]; await h.manager.refresh()
        guard case .unavailable = await h.manager.resolve(.worker) else { Issue.record("worker must not resolve"); return }
    }

    @Test func runningAndRateLimitStatesAndRecovery() async {
        let h = ProviderHarness(); h.paths = [.claudeCode: "/c", .codex: "/x"]; await h.manager.refresh()
        h.manager.providerStarted(.claudeCode)
        #expect(h.manager.status(.claudeCode).state == .running && h.manager.activeProvider == .claudeCode)
        await h.manager.refresh()                                                    // a refresh must not clobber a live run
        #expect(h.manager.status(.claudeCode).state == .running)
        h.manager.providerFinished(.claudeCode, outcome: .failed(.rateLimited(.claudeCode, resetsAt: Date().addingTimeInterval(600))))
        if case .rateLimited(let until) = h.manager.status(.claudeCode).state { #expect(until! > Date()) } else { Issue.record("rate limited") }
        await h.manager.refresh()                                                    // still within the limit window → stays limited
        if case .rateLimited = h.manager.status(.claudeCode).state {} else { Issue.record("must stay limited until reset") }
        guard case .ready(let r) = await h.manager.resolve(.reasoning) else { Issue.record("codex fallback under Auto is allowed"); return }
        #expect(r.id == .codex)
        h.manager.providerFinished(.claudeCode, outcome: .failed(.rateLimited(.claudeCode, resetsAt: Date().addingTimeInterval(-5))))
        h.manager.providerStarted(.claudeCode); h.manager.providerFinished(.claudeCode, outcome: .completed)
        #expect(h.manager.status(.claudeCode).state == .ready)
    }

    @Test func authFailureDuringARunUpdatesTheState() {
        let h = ProviderHarness()
        h.manager.providerStarted(.codex); h.manager.providerFinished(.codex, outcome: .failed(.authenticationRequired(.codex)))
        #expect(h.manager.status(.codex).state == .authenticationRequired)
        h.manager.providerStarted(.codex); h.manager.providerFinished(.codex, outcome: .failed(.networkUnavailable(.codex)))
        #expect(h.manager.status(.codex).state == .ready)                           // transient errors don't brick a provider
    }

    @Test func sessionsArePerProviderAndResettable() {
        let h = ProviderHarness()
        h.manager.recordSession("a", for: .claudeCode); h.manager.recordSession("b", for: .codex)
        #expect(h.manager.sessionID(for: .claudeCode) == "a" && h.manager.sessionID(for: .codex) == "b" && h.manager.sessionID(for: nil) == nil)
        h.manager.providerStarted(.claudeCode); h.manager.providerFinished(.claudeCode, outcome: .failed(.sessionLost(.claudeCode)))
        #expect(h.manager.sessionID(for: .claudeCode) == nil && h.manager.sessionID(for: .codex) == "b")
        h.manager.resetSessions()
        #expect(h.manager.sessionID(for: .codex) == nil)
    }
}

// MARK: - Real discovery probes against fake executables

@MainActor
@Suite("Provider probe", .serialized)
struct ProviderProbeTests {
    private func locator(root: String, dirs: [String]) -> ExecutableLocator {
        ExecutableLocator(home: root, path: dirs.joined(separator: ":"),
                          isExecutableFile: { $0.hasPrefix(root) && FileManager.default.isExecutableFile(atPath: $0) },
                          directoryContents: { _ in [] }, resolveSymlinks: { $0 })
    }

    @Test func notInstalledWhenNothingIsFound() async {
        let root = FakeCLI.makeDir()
        let s = await ProviderProbe.check(.claudeCode, locator: locator(root: root, dirs: [root + "/bin"]), override: nil, environment: FakeCLI.env(), timeout: 5)
        #expect(s.state == .notInstalled && s.executablePath == nil)
    }

    @Test func picksTheHighestVersionAndMapsAuthExitCodes() async {
        let root = FakeCLI.makeDir()
        for (dir, version) in [("a", "2.1.267 (Claude Code)"), ("b", "2.1.277 (Claude Code)")] {
            try! FileManager.default.createDirectory(atPath: "\(root)/\(dir)", withIntermediateDirectories: true)
            FakeCLI.script("case \"$1\" in --version) echo '\(version)';; auth) echo '{\"loggedIn\":true}'; exit 0;; esac", in: "\(root)/\(dir)", name: "claude")
        }
        let s = await ProviderProbe.check(.claudeCode, locator: locator(root: root, dirs: [root + "/a", root + "/b"]), override: nil, environment: FakeCLI.env(), timeout: 5)
        #expect(s.version == "2.1.277" && s.executablePath == root + "/b/claude" && s.state == .ready)

        for (code, expected) in [(1, ProviderState.authenticationRequired), (0, .ready)] {
            let dir = FakeCLI.makeDir()
            FakeCLI.script("case \"$1\" in --version) echo 'codex-cli 0.153.4';; login) echo 'status'; exit \(code);; esac", in: dir, name: "codex")
            let st = await ProviderProbe.check(.codex, locator: locator(root: dir, dirs: [dir]), override: nil, environment: FakeCLI.env(), timeout: 5)
            #expect(st.state == expected && st.version == "0.153.4")
        }
        let weird = FakeCLI.makeDir()
        FakeCLI.script("case \"$1\" in --version) echo 'codex-cli 0.1.0';; login) exit 9;; esac", in: weird, name: "codex")
        #expect((await ProviderProbe.check(.codex, locator: locator(root: weird, dirs: [weird]), override: nil, environment: FakeCLI.env(), timeout: 5)).state == .unavailable("auth check exit 9"))
    }

    @Test func brokenOrHungExecutablesAreUnavailableNotReady() async {
        let broken = FakeCLI.makeDir()
        FakeCLI.script("exit 1", in: broken, name: "claude")
        #expect((await ProviderProbe.check(.claudeCode, locator: locator(root: broken, dirs: [broken]), override: nil, environment: FakeCLI.env(), timeout: 5)).state == .unavailable("version check failed"))
        let hung = FakeCLI.makeDir()
        FakeCLI.script("case \"$1\" in --version) echo '2.0.0';; *) sleep 30;; esac", in: hung, name: "claude")
        let t0 = Date()
        let s = await ProviderProbe.check(.claudeCode, locator: locator(root: hung, dirs: [hung]), override: nil, environment: FakeCLI.env(), timeout: 0.6)
        #expect(s.state == .unavailable("auth check timed out") && Date().timeIntervalSince(t0) < 6)
    }

    @Test func userOverrideBeatsSearchLocations() async {
        let root = FakeCLI.makeDir()
        let custom = FakeCLI.script("case \"$1\" in --version) echo '9.9.9';; *) exit 0;; esac", in: root, name: "my-claude")
        let s = await ProviderProbe.check(.claudeCode, locator: locator(root: root, dirs: []), override: custom, environment: FakeCLI.env(), timeout: 5)
        #expect(s.executablePath == custom && s.state == .ready)
    }
}

// MARK: - Full chain: ConversationService → ProviderManager → CLIProvider → parser → ConversationStore

@MainActor
@Suite("Conversation + providers (full chain)", .serialized)
struct ProviderChainTests {
    @Test func deterministicCommandsNeverLaunchAProvider() async {
        let h = ProviderHarness()
        h.install(.claudeCode, h.claudeAnswer(["should not run"])); h.install(.codex, h.codexAnswer("should not run"))
        for cmd in ["open report", "raporu aç", "show tasks", "görevleri göster", "open settings", "what are you doing?",
                    "pause the current task", "resume the current task", "stop the current task", "hello", "thanks", "clear conversation", "close jarvis"] {
            await h.ask(cmd)
        }
        #expect(h.launches(.claudeCode) == 0 && h.launches(.codex) == 0)
        #expect(!h.conversation.messages.contains { $0.provider != nil })
    }

    @Test func realReasoningRequestStreamsIntoTheStoreAndCompletes() async {
        let h = ProviderHarness()
        h.install(.claudeCode, h.claudeAnswer(["A neural ", "network is a ", "function approximator."]))
        h.service.submit("Explain what a neural network is.")
        #expect(h.conversation.last?.status == .pending && h.service.isResponding)       // pending message exists immediately
        #expect(h.store.state == .thinking)                                              // real generation → Thinking
        await h.service.waitUntilIdle()
        let reply = h.lastReply!
        #expect(reply.content == "A neural network is a function approximator.")
        #expect(reply.status == .complete && reply.route == .reasoning && reply.provider == "Claude Code")
        #expect(h.launches(.claudeCode) == 1 && h.launches(.codex) == 0)
        #expect(h.store.state == .idle && !h.service.isResponding)
        #expect(h.store.activity.map(\.message).contains("Claude Code response started") && h.store.activity.map(\.message).contains("Claude Code response completed"))
        #expect(h.manager.status(.claudeCode).state == .ready)
    }

    @Test func turkishAndUnicodeStreamingIsExact() async {
        let h = ProviderHarness()
        let chunks = ["Merhaba, ", "ğüşiöç İ ı ", "😀 ✓ ", "bitti."]
        h.install(.claudeCode, h.claudeAnswer(chunks))
        await h.ask("Bana kısaca anlat: sinir ağı nedir?")
        #expect(h.lastReply?.content == chunks.joined())
    }

    @Test func followUpResumesTheProviderSessionWithoutResendingHistory() async {
        let h = ProviderHarness()
        h.install(.claudeCode, h.claudeAnswer(["First answer."], session: "sess-42"))
        await h.ask("What is Unity Netcode?")
        #expect(h.args(.claudeCode).contains("--session-id"))
        h.install(.claudeCode, h.claudeAnswer(["Simpler answer."], session: "sess-42"))
        await h.ask("Explain ownership more simply.")
        #expect(h.args(.claudeCode).contains("--resume sess-42"))
        #expect(h.lastReply?.content == "Simpler answer.")
        #expect(h.launches(.claudeCode) == 2)
    }

    @Test func codexIsUsedWhenSelectedAndRecordsItsThread() async {
        let h = ProviderHarness()
        h.install(.claudeCode, h.claudeAnswer(["wrong"])); h.install(.codex, h.codexAnswer("Codex says hi", thread: "thr-7"))
        h.manager.preference = .codex
        await h.ask("Compare actor isolation and locks.")
        #expect(h.lastReply?.content == "Codex says hi" && h.lastReply?.provider == "Codex")
        #expect(h.launches(.claudeCode) == 0 && h.manager.sessionID(for: .codex) == "thr-7")
        await h.ask("And in one sentence?")
        #expect(h.args(.codex).contains("exec resume thr-7"))
    }

    @Test func providerSwitchStartsAFreshSessionWithBoundedContext() async {
        let h = ProviderHarness()
        h.install(.claudeCode, h.claudeAnswer(["Claude first."])); h.install(.codex, h.codexAnswer("Codex second."))
        await h.ask("What is a monad?")
        h.manager.preference = .codex
        h.install(.codex, "cat > \(h.dir)/codex.stdin\n" + h.codexAnswer("Codex second.").dropFirst("cat >/dev/null\n".count))
        await h.ask("Explain it again.")
        let stdin = (try? String(contentsOfFile: "\(h.dir)/codex.stdin", encoding: .utf8)) ?? ""
        #expect(stdin.contains("What is a monad?") && stdin.contains("Claude first.") && stdin.hasSuffix("[Request]\nExplain it again."))
        #expect(!h.args(.codex).contains("resume"))                                       // brand-new Codex thread
    }

    @Test func unavailableSelectedProviderIsTruthfulAndNeverFallsBackOrLaunches() async {
        let h = ProviderHarness(states: [.claudeCode: .authenticationRequired, .codex: .ready])
        h.install(.claudeCode, h.claudeAnswer(["no"])); h.install(.codex, h.codexAnswer("must not be used"))
        h.manager.preference = .claudeCode
        await h.ask("Explain neural networks.")
        let r = h.lastReply!
        #expect(r.tone == .notice && r.content.contains("Claude Code") && r.content.contains("claude auth login"))
        #expect(h.launches(.claudeCode) == 0 && h.launches(.codex) == 0)                  // no silent paid/other-provider fallback
        #expect(!h.service.isResponding && h.store.state == .idle)
    }

    @Test func noProviderReadyGivesAnActionableMessage() async {
        let h = ProviderHarness(states: [.claudeCode: .notInstalled, .codex: .authenticationRequired])
        await h.ask("Explain neural networks.")
        #expect(h.lastReply?.content.contains("No intelligence provider is ready") == true && h.lastReply?.tone == .notice)
    }

    @Test func workerRequestsStayWorkerRequestsAndNeverStartAProvider() async {
        let h = ProviderHarness()
        h.install(.claudeCode, h.claudeAnswer(["x"])); h.install(.codex, h.codexAnswer("x"))
        for text in ["Fix my Unity multiplayer implementation, run the project and keep working until it passes.", "Modify my Unity project and test it.",
                     "Fix this repository and commit the changes.", "implement the networking code"] {
            let decision = h.service.submit(text); await h.service.waitUntilIdle()
            #expect(decision?.kind == .worker, "\(text)")
            #expect(h.lastReply?.content.contains("isn't enabled yet") == true && h.lastReply?.route == .worker)
        }
        #expect(h.launches(.claudeCode) == 0 && h.launches(.codex) == 0)
    }

    @Test func stopGenerationReallyKillsTheProviderAndRestoresTheComposer() async {
        let h = ProviderHarness()
        h.install(.claudeCode, "cat >/dev/null\necho $$ > \(h.dir)/long.pid\nprintf '%s\\n' '{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"s\"}' '{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"partial answer \"}}}'\nsleep 60")
        h.service.submit("Write a very long explanation.")
        let pid = await FakeCLI.pid(from: "\(h.dir)/long.pid")!
        for _ in 0..<100 where h.lastReply?.content.isEmpty ?? true { try? await Task.sleep(nanoseconds: 20_000_000) }
        #expect(h.lastReply?.content.hasPrefix("partial answer") == true && h.service.isResponding)
        h.service.submit("stop generating")                                              // deterministic command path
        await h.service.waitUntilIdle()
        #expect(await FakeCLI.waitDead(pid), "provider process survived STOP GENERATION")
        let streamed = h.conversation.messages.first { $0.route == .reasoning }!
        #expect(streamed.content.hasPrefix("partial answer") && streamed.status == .complete && streamed.tone == .notice)
        #expect(!h.service.isResponding && h.store.state == .idle && h.manager.status(.claudeCode).state == .ready)
        #expect(h.store.activity.map(\.message).contains("Claude Code response cancelled"))
        // composer availability restored: a new request is accepted
        h.install(.claudeCode, h.claudeAnswer(["fine again"]))
        await h.ask("Next question")
        #expect(h.lastReply?.content == "fine again")
    }

    @Test func aSecondRequestWhileAnsweringIsRefusedNotQueuedOrDoubled() async {
        let h = ProviderHarness()
        h.install(.claudeCode, "cat >/dev/null\nsleep 3\n" + h.claudeAnswer(["late"]).dropFirst("cat >/dev/null\n".count))
        h.service.submit("First question please.")
        for _ in 0..<200 where h.launches(.claudeCode) == 0 { try? await Task.sleep(nanoseconds: 25_000_000) }   // wait until it is really running
        h.service.submit("Second question please.")
        #expect(h.lastReply?.content.contains("still answering") == true)
        h.service.cancelCurrentResponse(); await h.service.waitUntilIdle()
        #expect(h.launches(.claudeCode) == 1)
    }

    @Test func crashMidStreamKeepsPartialTextAndAddsANotice() async {
        let h = ProviderHarness()
        h.install(.claudeCode, "cat >/dev/null\nprintf '%s\\n' '{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"half an ans\"}}}'\nexit 9")
        await h.ask("Explain something.")
        let msgs = h.conversation.messages.filter { $0.role == .jarvis }
        #expect(msgs.first?.content == "half an ans" && msgs.last?.tone == .notice && msgs.last?.content.contains("stopped unexpectedly") == true)
        #expect(h.store.state == .idle)
    }

    @Test func errorsAreConciseAndNeverLeakProviderOutput() async {
        let h = ProviderHarness()
        h.install(.claudeCode, "cat >/dev/null\necho 'secret stack trace /Users/me/.claude/token' >&2\nexit 4")
        await h.ask("Explain something.")
        #expect(h.lastReply?.status == .failed && h.lastReply?.content.contains("secret") == false && h.lastReply?.content.contains("/Users") == false)
    }

    @Test func fromCompactAProviderConversationMovesToTheFullHUD() async {
        let h = ProviderHarness()
        h.install(.claudeCode, h.claudeAnswer(["ok"]))
        await h.ask("Explain neural networks.", origin: .compactHUD)
        #expect(h.windows.calls.first == .showFull(.dashboard))
    }

    @Test func apiKeysAndCloudCredentialsNeverReachTheProvider() async {
        let h = ProviderHarness(environment: ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory(), "ANTHROPIC_API_KEY": "sk-ant-LEAK", "OPENAI_API_KEY": "sk-LEAK",
                                              "CODEX_API_KEY": "sk-LEAK2", "AWS_SECRET_ACCESS_KEY": "aws-LEAK", "CLAUDE_CODE_USE_BEDROCK": "1"])
        h.install(.claudeCode, h.claudeAnswer(["ok"]))
        await h.ask("Explain neural networks.")
        let env = h.env(.claudeCode)
        #expect(!env.contains("LEAK") && !env.contains("ANTHROPIC_API_KEY") && !env.contains("OPENAI") && !env.contains("BEDROCK") && !env.contains("AWS_"))
        #expect(env.contains("NO_COLOR=1"))
        let args = h.args(.claudeCode)
        #expect(!args.contains("--bare") && !args.contains("dangerously") && args.contains("--safe-mode"))
    }

    @Test func clearConversationCancelsAndResetsSessions() async {
        let h = ProviderHarness()
        h.install(.claudeCode, h.claudeAnswer(["one"], session: "sess-A"))
        await h.ask("First question about X?")
        #expect(h.manager.sessionID(for: .claudeCode) == "sess-A")
        h.service.submit("clear conversation")
        #expect(h.manager.sessionID(for: .claudeCode) == nil && h.conversation.messages.count == 1)
        h.install(.claudeCode, h.claudeAnswer(["two"], session: "sess-B"))
        await h.ask("Second question about Y?")
        #expect(h.args(.claudeCode).contains("--session-id") && !h.args(.claudeCode).contains("--resume"))
    }

    @Test func providerFailuresNeverLeaveJarvisInErrorState() async {
        let h = ProviderHarness()
        h.install(.claudeCode, "cat >/dev/null\necho '{\"type\":\"result\",\"is_error\":true,\"result\":\"Not logged in · Please run /login\"}'\nexit 1")
        await h.ask("Explain neural networks.")
        #expect(h.store.state == .idle)
        #expect(h.manager.status(.claudeCode).state == .authenticationRequired)           // state learned from the run
        #expect(h.lastReply?.content.contains("claude auth login") == true)
        #expect(h.store.activity.last?.message.contains("authentication required") == true)
    }
}

// MARK: - Streaming coalescer

@MainActor
@Suite("Stream coalescer")
struct StreamCoalescerTests {
    @Test func manyTinyDeltasBecomeFewStoreUpdatesWithoutLossOrReorder() async {
        let store = ConversationStore()
        let id = store.beginJarvisResponse(route: .reasoning)
        let c = StreamCoalescer(conversation: store, id: id)
        var expected = ""
        for i in 0..<300 { let piece = "ğ\(i) "; expected += piece; c.append(piece); if i % 25 == 0 { try? await Task.sleep(nanoseconds: 15_000_000) } }
        c.flushNow()
        #expect(store.messages.last?.content == expected)
        #expect(c.flushCount < 60)                                                         // far fewer UI updates than tokens
    }
}
