import Foundation
import Testing
@testable import Jarvis

// MARK: - Environment scrub (subscription-first: no silent API billing)

@Suite("Provider environment")
struct ProviderEnvironmentTests {
    @Test func credentialAndBillingVariablesNeverReachProviders() {
        var base: [String: String] = ["HOME": "/Users/x", "PATH": "/usr/bin", "LANG": "tr_TR.UTF-8"]
        for name in ProviderEnvironment.forbidden { base[name] = "secret-value" }
        base["AWS_REGION"] = "eu"; base["GITHUB_TOKEN"] = "gh"; base["SECRET"] = "s"
        let env = ProviderEnvironment.make(base: base)
        for name in ProviderEnvironment.forbidden { #expect(env[name] == nil, "\(name)") }
        #expect(env["GITHUB_TOKEN"] == nil && env["SECRET"] == nil && env["AWS_REGION"] == nil)     // allowlist, not blocklist
        #expect(env["HOME"] == "/Users/x" && env["LANG"] == "tr_TR.UTF-8")
        #expect(!env.values.contains("secret-value"))
    }

    @Test func userChosenConfigLocationsAndProxiesPass() {
        let env = ProviderEnvironment.make(base: ["CLAUDE_CONFIG_DIR": "/c", "CODEX_HOME": "/h", "HTTPS_PROXY": "http://p:1", "PATH": ""])
        #expect(env["CLAUDE_CONFIG_DIR"] == "/c" && env["CODEX_HOME"] == "/h" && env["HTTPS_PROXY"] == "http://p:1")
    }

    @Test func pathIsDeduplicatedAndHasSystemFallbacks() {
        let env = ProviderEnvironment.make(base: ["PATH": "/usr/bin:/custom"], extraPath: ["/opt/homebrew/bin", "/usr/bin"])
        let parts = env["PATH"]!.split(separator: ":").map(String.init)
        #expect(parts.first == "/opt/homebrew/bin")
        #expect(parts.filter { $0 == "/usr/bin" }.count == 1)
        #expect(parts.contains("/bin") && parts.contains("/custom"))
        #expect(env["NO_COLOR"] == "1" && env["TERM"] == "dumb")
    }
}

// MARK: - Executable discovery

@Suite("Executable discovery")
struct ExecutableLocatorTests {
    private func locator(existing: Set<String>, nvm: [String] = [], path: String = "/usr/bin:/bin") -> ExecutableLocator {
        ExecutableLocator(home: "/Users/u", path: path, isExecutableFile: { existing.contains($0) },
                          directoryContents: { $0 == "/Users/u/.nvm/versions/node" ? nvm : [] }, resolveSymlinks: { $0 })
    }

    @Test func overrideComesFirstThenPathThenKnownLocations() {
        let l = locator(existing: ["/custom/claude", "/usr/bin/claude", "/opt/homebrew/bin/claude", "/Users/u/.local/bin/claude"])
        #expect(l.candidates(for: .claudeCode, override: "/custom/claude") == ["/custom/claude", "/usr/bin/claude", "/Users/u/.local/bin/claude", "/opt/homebrew/bin/claude"])
    }

    @Test func guiAppsDoNotNeedTheShellPath() {
        // PATH is minimal (GUI launch) but the Homebrew / ~/.local installs are still found.
        let l = locator(existing: ["/opt/homebrew/bin/claude", "/Users/u/.local/bin/claude"], path: "/usr/bin:/bin")
        #expect(Set(l.candidates(for: .claudeCode)) == ["/opt/homebrew/bin/claude", "/Users/u/.local/bin/claude"])
    }

    @Test func codexIsFoundInsideTheChatGPTApp() {
        let l = locator(existing: ["/Applications/ChatGPT.app/Contents/Resources/codex"])
        #expect(l.candidates(for: .codex) == ["/Applications/ChatGPT.app/Contents/Resources/codex"])
        #expect(l.candidates(for: .claudeCode).isEmpty)           // never confuses providers
    }

    @Test func nvmInstallsAndTildeOverrides() {
        let l = locator(existing: ["/Users/u/.nvm/versions/node/v24.1.0/bin/codex", "/Users/u/mybin/codex"], nvm: ["v22.0.0", "v24.1.0"])
        #expect(l.candidates(for: .codex, override: "~/mybin/codex").first == "/Users/u/mybin/codex")
        #expect(l.candidates(for: .codex).contains("/Users/u/.nvm/versions/node/v24.1.0/bin/codex"))
    }

    @Test func symlinkedDuplicatesAreRemovedAndMissingFilesIgnored() {
        let l = ExecutableLocator(home: "/h", path: "/a:/b", isExecutableFile: { $0 == "/a/claude" || $0 == "/b/claude" },
                                  directoryContents: { _ in [] }, resolveSymlinks: { _ in "/real/claude" })
        #expect(l.candidates(for: .claudeCode) == ["/a/claude"])
        #expect(locator(existing: []).candidates(for: .claudeCode).isEmpty)
    }

    @Test func versionParsingAndComparison() {
        #expect(ExecutableLocator.parseVersion("2.1.277 (Claude Code)")?.parts == [2, 1, 277])
        #expect(ExecutableLocator.parseVersion("codex-cli 0.153.4")?.display == "0.153.4")
        #expect(ExecutableLocator.parseVersion("no version here") == nil)
        #expect(ExecutableLocator.isNewer([2, 1, 277], than: [2, 1, 267]))
        #expect(!ExecutableLocator.isNewer([2, 1], than: [2, 1, 0]))
        #expect(ExecutableLocator.isNewer([0, 153, 4], than: [0, 99, 99]))
    }
}

// MARK: - Line splitting (byte-safe, Unicode-safe)

@Suite("Line splitter")
struct LineSplitterTests {
    @Test func splitsLinesAndHandlesCRLFAndRemainder() {
        var s = LineSplitter()
        #expect(s.feed(Data("a\nb\r\nc".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["a", "b"])
        #expect(s.feed(Data("d\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["cd"])
        #expect(s.flush() == nil)
        _ = s.feed(Data("tail".utf8))
        #expect(String(decoding: s.flush() ?? Data(), as: UTF8.self) == "tail")
    }

    @Test func multiByteCharactersSplitAcrossReadsAreNotCorrupted() {
        let line = "{\"t\":\"Türkçe ğüşiöç İI ıi 😀 ✓\"}\n"
        let bytes = Array(line.utf8)
        for chunk in 1...7 {                                   // every possible split point pattern
            var s = LineSplitter(); var out: [String] = []
            var i = 0
            while i < bytes.count { out += s.feed(Data(bytes[i..<min(i + chunk, bytes.count)])).map { String(decoding: $0, as: UTF8.self) }; i += chunk }
            #expect(out == [String(line.dropLast())], "chunk=\(chunk)")
        }
    }

    @Test func noLossNoDuplicationUnderRandomChunking() {
        let lines = (0..<500).map { "line \($0) türkçe ğ😀" }
        let blob = Array((lines.joined(separator: "\n") + "\n").utf8)
        var rng = SeededGenerator(seed: 7)
        var s = LineSplitter(); var out: [String] = []
        var i = 0
        while i < blob.count { let n = Int.random(in: 1...37, using: &rng); out += s.feed(Data(blob[i..<min(i + n, blob.count)])).map { String(decoding: $0, as: UTF8.self) }; i += n }
        #expect(out == lines)
    }
}

// MARK: - Parsers (shapes taken from real runs of Claude Code 2.1.277 and codex-cli 0.153.4)

private func lines(_ text: String) -> [Data] { text.split(separator: "\n").map { Data($0.utf8) } }

@Suite("Claude stream parser")
struct ClaudeParserTests {
    static let happy = """
    {"type":"system","subtype":"init","session_id":"9d16530c-134f-4b8d-a816-c19510c9e732","model":"claude-sonnet-5"}
    {"type":"system","subtype":"status"}
    {"type":"stream_event","event":{"type":"message_start","message":{"role":"assistant"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"J"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"AR"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"VIS_PROV"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"IDER_O"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"K"}}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"JARVIS_PROVIDER_OK"}]}}
    {"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1791672000}}
    {"type":"result","subtype":"success","is_error":false,"result":"JARVIS_PROVIDER_OK","session_id":"9d16530c-134f-4b8d-a816-c19510c9e732"}
    """

    private func run(_ text: String) -> (events: [ProviderStreamEvent], parser: ClaudeStreamParser) {
        let p = ClaudeStreamParser(); return (lines(text).flatMap { p.parse(line: $0) }, p)
    }

    @Test func streamsTokenDeltasInOrderWithSessionAndFinish() {
        let (events, _) = run(Self.happy)
        #expect(events.first == .session("9d16530c-134f-4b8d-a816-c19510c9e732"))
        let text = events.compactMap { if case .text(let t) = $0 { t } else { nil } }
        #expect(text == ["J", "AR", "VIS_PROV", "IDER_O", "K"])          // real deltas, not re-chunked
        #expect(text.joined() == "JARVIS_PROVIDER_OK")                    // and the final result is NOT appended again
        #expect(events.last == .finished)
    }

    @Test func turkishAndEmojiDeltasStayIntact() {
        let t = """
        {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Merhaba ğüş"}}}
        {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"iöç İ ı 😀"}}}
        {"type":"result","is_error":false,"result":"Merhaba ğüşiöç İ ı 😀"}
        """
        let (events, _) = run(t)
        #expect(events.compactMap { if case .text(let s) = $0 { s } else { nil } }.joined() == "Merhaba ğüşiöç İ ı 😀")
    }

    @Test func fallsBackToResultTextWhenNoPartialsArrived() {
        let (events, _) = run("{\"type\":\"result\",\"is_error\":false,\"result\":\"whole answer\"}")
        #expect(events == [.text("whole answer"), .finished])
    }

    @Test func notLoggedInIsAuthenticationRequired() {
        let (events, _) = run("""
        {"type":"assistant","error":"authentication_failed"}
        {"type":"result","is_error":true,"result":"Not logged in · Please run /login"}
        """)
        #expect(events == [.failure(.authenticationRequired(.claudeCode))])    // exactly one failure, no duplicates
    }

    @Test func errorCodesAndMessagesMap() {
        #expect(ClaudeStreamParser.map(code: "rate_limit", text: nil, id: .claudeCode) == .rateLimited(.claudeCode, resetsAt: nil))
        #expect(ClaudeStreamParser.map(code: nil, text: "Claude usage limit reached", id: .claudeCode) == .rateLimited(.claudeCode, resetsAt: nil))
        #expect(ClaudeStreamParser.map(code: "overloaded", text: nil, id: .claudeCode) == .unavailable(.claudeCode, "overloaded"))
        #expect(ClaudeStreamParser.map(code: nil, text: "No conversation found with session ID abc", id: .claudeCode) == .sessionLost(.claudeCode))
        #expect(ClaudeStreamParser.map(code: nil, text: "getaddrinfo ENOTFOUND api", id: .claudeCode) == .networkUnavailable(.claudeCode))
    }

    @Test func rejectedRateLimitEventSurfaces() {
        let (events, _) = run("{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"rejected\",\"resetsAt\":1791672000}}")
        #expect(events == [.rateLimited(resetsAt: Date(timeIntervalSince1970: 1791672000))])
    }

    @Test func malformedLinesAreCountedNotFatalAndMissingResultIsAFailure() {
        let (events, parser) = run("garbage\n{not json\n{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}}")
        #expect(events == [.text("hi")])
        #expect(parser.malformedLines == 2)
        #expect(parser.finalFailure(exitCode: 0, stderrTail: "") == .processFailed(.claudeCode, exitCode: 0))
        let none = ClaudeStreamParser(); _ = none.parse(line: Data("junk".utf8))
        #expect(none.finalFailure(exitCode: 0, stderrTail: "") == .malformedOutput(.claudeCode))
    }
}

@Suite("Codex event parser")
struct CodexParserTests {
    static let happy = """
    {"type":"thread.started","thread_id":"01a12798-6495-7a81-ae96-8eae8d098a5b"}
    {"type":"turn.started"}
    {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"JARVIS_PROVIDER_OK"}}
    {"type":"turn.completed","usage":{"input_tokens":14132,"cached_input_tokens":12032,"output_tokens":9}}
    """
    private func run(_ text: String) -> (events: [ProviderStreamEvent], parser: CodexEventParser) {
        let p = CodexEventParser(); return (lines(text).flatMap { p.parse(line: $0) }, p)
    }

    @Test func realRunShape() {
        let (events, parser) = run(Self.happy)
        #expect(events == [.session("01a12798-6495-7a81-ae96-8eae8d098a5b"), .text("JARVIS_PROVIDER_OK"), .finished])
        #expect(parser.finalFailure(exitCode: 0, stderrTail: "") == nil)
    }

    @Test func multipleAgentMessagesAreSeparatedAndOtherItemsIgnored() {
        let (events, _) = run("""
        {"type":"item.completed","item":{"type":"agent_message","text":"first"}}
        {"type":"item.completed","item":{"type":"command_execution","command":"ls","status":"completed"}}
        {"type":"item.completed","item":{"type":"reasoning","text":"thinking"}}
        {"type":"item.completed","item":{"type":"agent_message","text":"ikinci ğüş"}}
        {"type":"turn.completed"}
        """)
        #expect(events == [.text("first"), .text("\n\nikinci ğüş"), .finished])
    }

    @Test func unauthenticatedReconnectLoopBecomesAuthRequired() {
        let (events, parser) = run("""
        {"type":"thread.started","thread_id":"t"}
        {"type":"turn.started"}
        {"type":"error","message":"Reconnecting... 2/5 (unexpected status 401 Unauthorized: Missing bearer or basic authentication in header)"}
        {"type":"error","message":"Reconnecting... 5/5 (unexpected status 401 Unauthorized: Missing bearer or basic authentication in header)"}
        """)
        #expect(events == [.session("t")])                                      // transient errors are not surfaced
        #expect(parser.finalFailure(exitCode: 1, stderrTail: "") == .authenticationRequired(.codex))
    }

    @Test func turnFailedAndLimitsAndNetwork() {
        let (events, _) = run("{\"type\":\"turn.failed\",\"error\":{\"message\":\"You've hit your usage limit\"}}")
        #expect(events == [.failure(.rateLimited(.codex, resetsAt: nil))])
        let net = CodexEventParser(); _ = net.parse(line: Data("{\"type\":\"error\",\"message\":\"failed to lookup address information\"}".utf8))
        #expect(net.finalFailure(exitCode: 1, stderrTail: "") == .networkUnavailable(.codex))
        let crash = CodexEventParser(); _ = crash.parse(line: Data("{\"type\":\"turn.started\"}".utf8))
        #expect(crash.finalFailure(exitCode: 137, stderrTail: "") == .processFailed(.codex, exitCode: 137))
    }

    @Test func nonJSONOutputIsMalformed() {
        let p = CodexEventParser(); _ = p.parse(line: Data("some banner".utf8))
        #expect(p.malformedLines == 1)
        #expect(p.finalFailure(exitCode: 0, stderrTail: "") == .malformedOutput(.codex))
    }
}

// MARK: - Specs: restricted, no paid API, bounded context

@Suite("Provider specs")
struct ProviderSpecTests {
    static let forbiddenTokens = ["--bare", "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions", "bypassPermissions",
                                  "danger-full-access", "--dangerously-bypass-approvals-and-sandbox", "--dangerously-bypass-hook-trust",
                                  "--full-auto", "--with-api-key", "--with-access-token", "workspace-write", "--approve-for-me", "--enable"]

    @Test func claudeArgumentsAreConversationOnlyAndSubscriptionSafe() {
        for session in [nil, "abc"] {
            let a = ClaudeCodeSpec().arguments(sessionID: session, newSessionID: "NEW", workingDirectory: "/w")
            #expect(a.contains("-p") && a.contains("stream-json") && a.contains("--include-partial-messages") && a.contains("--safe-mode"))
            let i = a.firstIndex(of: "--tools")!; #expect(a[i + 1] == "")                      // no tools at all
            #expect(a.contains("--permission-prompts") && a.contains(JarvisInstruction.text))
            for t in Self.forbiddenTokens { #expect(!a.contains(t), "\(t)") }
            #expect(session == nil ? a.contains("--session-id") && a.contains("NEW") : a.contains("--resume") && a.contains("abc"))
            #expect(!a.contains { $0.contains("api") && $0.contains("key") })
        }
    }

    @Test func codexArgumentsAreReadOnlyWithToolsDisabled() {
        let first = CodexSpec().arguments(sessionID: nil, newSessionID: "x", workingDirectory: "/work")
        #expect(Array(first.prefix(2)) == ["exec", "--json"] && first.last == "-")
        #expect(zip(first, first.dropFirst()).contains { $0 == "-s" && $1 == "read-only" })
        let resume = CodexSpec().arguments(sessionID: "tid", newSessionID: "x", workingDirectory: "/work")
        #expect(Array(resume.prefix(3)) == ["exec", "resume", "tid"] && resume.contains("sandbox_mode=\"read-only\""))
        for a in [first, resume] {
            for f in CodexSpec.disabledFeatures { #expect(zip(a, a.dropFirst()).contains { $0 == "--disable" && $1 == f }, "\(f)") }
            #expect(CodexSpec.disabledFeatures.contains("shell_tool") && CodexSpec.disabledFeatures.contains("computer_use"))
            for t in Self.forbiddenTokens { #expect(!a.contains(t), "\(t)") }
        }
    }

    @Test func noShellIsEverInvolved() {
        for spec in [ClaudeCodeSpec() as CLIProviderSpec, CodexSpec()] {
            let a = spec.arguments(sessionID: nil, newSessionID: "n", workingDirectory: "/w")
            #expect(!a.contains("sh") && !a.contains("bash") && !a.contains("zsh") && !a.contains("-c") || spec.id == .codex && a.contains("-c"))
        }
    }

    private func req(_ prompt: String, history: [ConversationMessage], session: String?) -> IntelligenceRequest {
        IntelligenceRequest(id: UUID(), kind: .reasoning, prompt: prompt, history: history, language: .en, sessionID: session)
    }

    @Test func contextOnlyIncludesProviderExchangesAndIsBounded() {
        let history: [ConversationMessage] = [
            ConversationMessage(role: .user, content: "open the report"), ConversationMessage(role: .jarvis, content: "Opening the report.", route: .command),
            ConversationMessage(role: .user, content: "What is Unity Netcode?"), ConversationMessage(role: .jarvis, content: "Netcode is …", route: .reasoning),
            ConversationMessage(role: .user, content: "hello"), ConversationMessage(role: .jarvis, content: "Hello.", route: .local),
            ConversationMessage(role: .user, content: "Explain ownership more simply"),
        ]
        let pre = ContextBuilder.preface(from: history, excluding: "Explain ownership more simply")!
        #expect(pre.contains("What is Unity Netcode?") && pre.contains("Netcode is …"))
        #expect(!pre.contains("Opening the report") && !pre.contains("Hello.") && !pre.contains("open the report"))   // no command chatter
        let big = (0..<50).flatMap { i in [ConversationMessage(role: .user, content: "q\(i) " + String(repeating: "x", count: 900)),
                                            ConversationMessage(role: .jarvis, content: String(repeating: "y", count: 900), route: .reasoning)] }
        let bounded = ContextBuilder.preface(from: big, excluding: "")!
        #expect(bounded.count <= ContextBuilder.maxCharacters + 400)
        #expect(bounded.components(separatedBy: "User: ").count - 1 <= ContextBuilder.maxMessages / 2)
        #expect(bounded.contains("q49") && !bounded.contains("q0 "))                               // newest kept
        #expect(ContextBuilder.preface(from: [], excluding: "") == nil)
    }

    @Test func resumedSessionsSendOnlyTheNewPrompt() {
        let h = [ConversationMessage(role: .user, content: "a"), ConversationMessage(role: .jarvis, content: "b", route: .reasoning)]
        #expect(ClaudeCodeSpec().stdinPrompt(for: req("next", history: h, session: "S")) == "next")
        #expect(CodexSpec().stdinPrompt(for: req("next", history: h, session: "S")) == "next")
        #expect(ClaudeCodeSpec().stdinPrompt(for: req("next", history: h, session: nil)).contains("User: a"))
        let codexFirst = CodexSpec().stdinPrompt(for: req("hi", history: [], session: nil))
        #expect(codexFirst.contains(JarvisInstruction.text) && codexFirst.hasSuffix("[Request]\nhi"))
    }

    @Test func instructionForbidsFakeActions() {
        let t = JarvisInstruction.text.lowercased()
        #expect(t.contains("no tools") && t.contains("never claim") && t.count < 700)
    }
}
