import Foundation
import Testing
@testable import Jarvis

// MARK: - Helpers

enum FakeCLI {
    static func makeDir() -> String {
        let d = NSTemporaryDirectory() + "jarvis-tests-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    /// Writes an executable /bin/sh script (TEST CODE ONLY — product code never uses a shell).
    @discardableResult
    static func script(_ body: String, in dir: String, name: String = "fake") -> String {
        let path = "\(dir)/\(name)"
        try! ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    static func env() -> [String: String] { ProviderEnvironment.make(base: ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()]) }

    static func alive(_ pid: pid_t) -> Bool { ProcessTree.isAlive(pid) }

    static func pid(from file: String, waitingUpTo seconds: Double = 3) async -> pid_t? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let s = try? String(contentsOfFile: file, encoding: .utf8), let p = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) { return p }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return nil
    }

    static func waitDead(_ pid: pid_t, upTo seconds: Double = 4) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if !alive(pid) { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
        return !alive(pid)
    }

    static func request(_ prompt: String = "hi", session: String? = nil, history: [ConversationMessage] = []) -> IntelligenceRequest {
        IntelligenceRequest(id: UUID(), kind: .reasoning, prompt: prompt, history: history, language: .en, sessionID: session)
    }

    /// Drains a provider stream into (events, error).
    static func collect(_ stream: AsyncThrowingStream<IntelligenceEvent, Error>) async -> (events: [IntelligenceEvent], error: Error?) {
        var events: [IntelligenceEvent] = []
        do { for try await e in stream { events.append(e) }; return (events, nil) } catch { return (events, error) }
    }

    static func text(_ events: [IntelligenceEvent]) -> String { events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined() }
}

// MARK: - ManagedProcess (REAL child processes)

@Suite("Managed process", .serialized)
struct ManagedProcessTests {
    private func run(_ exe: String, _ args: [String] = [], stdin: String? = nil) async throws -> (lines: [String], code: Int32, p: ManagedProcess) {
        let p = ManagedProcess(executable: exe, arguments: args, environment: FakeCLI.env(), workingDirectory: NSTemporaryDirectory())
        let stream = try p.start(stdin: stdin.map { Data($0.utf8) })
        var out: [String] = []
        for await l in stream { out.append(String(decoding: l, as: UTF8.self)) }
        return (out, await p.waitForExit(), p)
    }

    @Test func capturesStdoutLinesAndExitCode() async throws {
        let dir = FakeCLI.makeDir()
        let s = FakeCLI.script("printf 'a\\nb\\nc'; exit 7", in: dir)
        let r = try await run(s)
        #expect(r.lines == ["a", "b", "c"] && r.code == 7)
    }

    @Test func stdinPromptIsDeliveredIntactWithUnicodeAndNewlines() async throws {
        let prompt = "func f() {\n    print(\"Türkçe ğüşiöç İ ✓ 😀\")\n}\n"
        let r = try await run("/bin/cat", stdin: prompt)
        #expect(r.lines.joined(separator: "\n") + "\n" == prompt)
    }

    @Test func largeOutputHasNoLossOrDuplication() async throws {
        let r = try await run("/usr/bin/seq", ["1", "30000"])
        #expect(r.lines.count == 30000 && r.lines.first == "1" && r.lines.last == "30000")
        #expect(r.lines.enumerated().allSatisfy { $0.element == String($0.offset + 1) })
    }

    @Test func stderrIsBoundedAndSeparateFromOutput() async throws {
        let dir = FakeCLI.makeDir()
        let s = FakeCLI.script("i=0; while [ $i -lt 4000 ]; do echo 'diagnostic line xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' >&2; i=$((i+1)); done; echo answer", in: dir)
        let r = try await run(s)
        #expect(r.lines == ["answer"])
        #expect(r.p.stderrTail.utf8.count <= ManagedProcess.stderrLimit + 64 && r.p.stderrTail.contains("diagnostic"))
    }

    @Test func launchFailureThrows() {
        let p = ManagedProcess(executable: "/nonexistent/claude", arguments: [], environment: [:], workingDirectory: "/tmp")
        #expect(throws: (any Error).self) { _ = try p.start(stdin: nil) }
    }

    @Test func cancelStopsTheRealProcess() async throws {
        let dir = FakeCLI.makeDir()
        let s = FakeCLI.script("echo $$ > \(dir)/pid; sleep 60", in: dir)
        let p = ManagedProcess(executable: s, arguments: [], environment: FakeCLI.env(), workingDirectory: dir)
        let stream = try p.start(stdin: nil)
        let pid = await FakeCLI.pid(from: "\(dir)/pid")!
        #expect(p.isRunning && FakeCLI.alive(pid))
        let t0 = Date()
        await p.cancel()
        #expect(Date().timeIntervalSince(t0) < 4)
        #expect(!p.isRunning)
        #expect(await FakeCLI.waitDead(pid))
        for await _ in stream {}                                   // stream terminates
        #expect(p.wasCancelled)
    }

    @Test func cancelLeavesNoOrphanedGrandchildren() async throws {
        let dir = FakeCLI.makeDir()
        // The shell dies on SIGINT but its background child would normally survive and be re-parented to launchd.
        let s = FakeCLI.script("sleep 60 &\necho $! > \(dir)/child\necho $$ > \(dir)/pid\nwait", in: dir)
        let p = ManagedProcess(executable: s, arguments: [], environment: FakeCLI.env(), workingDirectory: dir)
        _ = try p.start(stdin: nil)
        let child = await FakeCLI.pid(from: "\(dir)/child")!
        #expect(FakeCLI.alive(child))
        await p.cancel()
        #expect(await FakeCLI.waitDead(child), "grandchild \(child) survived cancel")
    }

    @Test func processIgnoringSigintAndSigtermIsKilled() async throws {
        let dir = FakeCLI.makeDir()
        let s = FakeCLI.script("trap '' INT TERM\necho $$ > \(dir)/pid\nwhile true; do sleep 1; done", in: dir)
        let p = ManagedProcess(executable: s, arguments: [], environment: FakeCLI.env(), workingDirectory: dir)
        _ = try p.start(stdin: nil)
        let pid = await FakeCLI.pid(from: "\(dir)/pid")!
        await p.cancel()
        #expect(await FakeCLI.waitDead(pid, upTo: 6))
    }

    @Test func aGrandchildHoldingStdoutDoesNotHangTheStream() async throws {
        let dir = FakeCLI.makeDir()
        let s = FakeCLI.script("sleep 6 &\necho $! > \(dir)/child\necho hello", in: dir)
        let t0 = Date()
        let r = try await run(s)
        #expect(r.lines == ["hello"])
        #expect(Date().timeIntervalSince(t0) < 4)
        if let child = await FakeCLI.pid(from: "\(dir)/child", waitingUpTo: 1) { kill(child, SIGKILL) }
    }

    @Test func applicationTerminationKillsEveryProviderProcess() async throws {
        let dir = FakeCLI.makeDir()
        let s = FakeCLI.script("echo $$ > \(dir)/pid; sleep 60", in: dir)
        let p = ManagedProcess(executable: s, arguments: [], environment: FakeCLI.env(), workingDirectory: dir)
        _ = try p.start(stdin: nil)
        let pid = await FakeCLI.pid(from: "\(dir)/pid")!
        #expect(ProcessRegistry.shared.count >= 1)
        ProcessRegistry.shared.killAll()
        #expect(await FakeCLI.waitDead(pid))
    }

    @Test func runOnceReportsOutputExitAndTimeout() async {
        let dir = FakeCLI.makeDir()
        let ok = FakeCLI.script("echo '2.1.277 (Claude Code)'", in: dir, name: "ok")
        let r = await ManagedProcess.runOnce(executable: ok, arguments: ["--version"], environment: FakeCLI.env(), timeout: 5)
        #expect(r?.exitCode == 0 && r?.output.contains("2.1.277") == true && r?.timedOut == false)
        let slow = FakeCLI.script("sleep 30", in: dir, name: "slow")
        let t = await ManagedProcess.runOnce(executable: slow, arguments: [], environment: FakeCLI.env(), timeout: 0.5)
        #expect(t?.timedOut == true)
        #expect(await ManagedProcess.runOnce(executable: "/nonexistent", arguments: [], environment: [:], timeout: 1) == nil)
    }
}

// MARK: - CLIProvider end-to-end with fake CLIs emitting the REAL event shapes

private let claudeOK = """
{"type":"system","subtype":"init","session_id":"sess-1"}
{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Mer"}}}
{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"haba ğüş"}}}
{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"iöç 😀"}}}
{"type":"result","is_error":false,"result":"Merhaba ğüşiöç 😀"}
"""

@Suite("CLI provider (fake CLIs)", .serialized)
struct CLIProviderTests {
    private func provider(_ script: String, spec: CLIProviderSpec = ClaudeCodeSpec(), dir: String, idle: TimeInterval = 20, total: TimeInterval = 60) -> CLIProvider {
        CLIProvider(spec: spec, executablePath: script, workingDirectory: dir + "/work", environment: FakeCLI.env(), idleTimeout: idle, totalTimeout: total)
    }

    @Test func streamsRealDeltasInOrderAndReportsTheSession() async {
        let dir = FakeCLI.makeDir()
        let s = FakeCLI.script("cat > \(dir)/stdin.txt\ncat <<'EOF'\n\(claudeOK)\nEOF", in: dir)
        let r = await FakeCLI.collect(provider(s, dir: dir).respond(to: FakeCLI.request("Selam, nasılsın?")))
        #expect(r.error == nil)
        #expect(FakeCLI.text(r.events) == "Merhaba ğüşiöç 😀")
        let deltas = r.events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }
        #expect(deltas == ["Mer", "haba ğüş", "iöç 😀"])                      // real chunks, not re-split
        if case .session(let id)? = r.events.first { #expect(!id.isEmpty) } else { Issue.record("session first") }
        #expect(r.events.contains { if case .session("sess-1") = $0 { true } else { false } })
        #expect((try? String(contentsOfFile: "\(dir)/stdin.txt", encoding: .utf8)) == "Selam, nasılsın?")
    }

    @Test func promptIsPassedOnStdinNeverOnTheCommandLine() async {
        let dir = FakeCLI.makeDir()
        let s = FakeCLI.script("echo \"$@\" > \(dir)/args.txt\ncat > \(dir)/stdin.txt\ncat <<'EOF'\n\(claudeOK)\nEOF", in: dir)
        let secret = "SUPER-SECRET-PROMPT-TEXT"
        _ = await FakeCLI.collect(provider(s, dir: dir).respond(to: FakeCLI.request(secret)))
        let args = (try? String(contentsOfFile: "\(dir)/args.txt", encoding: .utf8)) ?? ""
        #expect(!args.contains(secret) && args.contains("--tools") && args.contains("--safe-mode"))
        #expect((try? String(contentsOfFile: "\(dir)/stdin.txt", encoding: .utf8)) == secret)
    }

    @Test func authenticationFailureIsTyped() async {
        let dir = FakeCLI.makeDir()
        let s = FakeCLI.script("cat >/dev/null\necho '{\"type\":\"assistant\",\"error\":\"authentication_failed\"}'\necho '{\"type\":\"result\",\"is_error\":true,\"result\":\"Not logged in · Please run /login\"}'\nexit 1", in: dir)
        let r = await FakeCLI.collect(provider(s, dir: dir).respond(to: FakeCLI.request()))
        #expect(r.error as? ProviderError == .authenticationRequired(.claudeCode))
    }

    @Test func crashWithoutOutputIsProcessFailedNotACrashOfJarvis() async {
        let dir = FakeCLI.makeDir()
        let s = FakeCLI.script("cat >/dev/null; echo 'boom: internal detail' >&2; exit 3", in: dir)
        let r = await FakeCLI.collect(provider(s, dir: dir).respond(to: FakeCLI.request()))
        #expect(r.error as? ProviderError == .processFailed(.claudeCode, exitCode: 3))
        #expect(!(r.error as! ProviderError).userMessage().contains("boom"))      // stderr never becomes the answer
    }

    @Test func garbageOutputIsMalformed() async {
        let dir = FakeCLI.makeDir()
        let s = FakeCLI.script("cat >/dev/null; echo 'not json'; echo '<html>'; exit 0", in: dir)
        let r = await FakeCLI.collect(provider(s, dir: dir).respond(to: FakeCLI.request()))
        #expect(r.error as? ProviderError == .malformedOutput(.claudeCode))
    }

    @Test func usageLimitAndNetworkErrorsAreDistinguished() async {
        let dir = FakeCLI.makeDir()
        let limit = FakeCLI.script("cat >/dev/null\necho '{\"type\":\"result\",\"is_error\":true,\"result\":\"Claude usage limit reached. Your limit will reset at 5pm\"}'\nexit 1", in: dir, name: "limit")
        let limited = await FakeCLI.collect(provider(limit, dir: dir).respond(to: FakeCLI.request()))
        #expect(limited.error as? ProviderError == .rateLimited(.claudeCode, resetsAt: nil), "got \(String(describing: limited.error)) events=\(limited.events)")
        let net = FakeCLI.script("cat >/dev/null\necho '{\"type\":\"result\",\"is_error\":true,\"result\":\"Unable to connect to API: ENOTFOUND\"}'\nexit 1", in: dir, name: "net")
        #expect((await FakeCLI.collect(provider(net, dir: dir).respond(to: FakeCLI.request()))).error as? ProviderError == .networkUnavailable(.claudeCode))
    }

    @Test func idleTimeoutStopsTheProcess() async {
        let dir = FakeCLI.makeDir()
        let s = FakeCLI.script("echo $$ > \(dir)/pid\ncat >/dev/null\nsleep 60", in: dir)
        let t0 = Date()
        let r = await FakeCLI.collect(provider(s, dir: dir, idle: 2.5).respond(to: FakeCLI.request()))
        #expect(r.error as? ProviderError == .timedOut(.claudeCode))
        #expect(Date().timeIntervalSince(t0) < 12)
        if let pid = await FakeCLI.pid(from: "\(dir)/pid", waitingUpTo: 5) { #expect(await FakeCLI.waitDead(pid)) } else { Issue.record("script never started") }
    }

    @Test func consumerCancellationKillsTheRealProcessAndStopsStreaming() async {
        let dir = FakeCLI.makeDir()
        let s = FakeCLI.script("echo $$ > \(dir)/pid\ncat >/dev/null\necho '{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"first\"}}}'\nsleep 60\necho SHOULD-NOT-BE-REACHED > \(dir)/late", in: dir)
        let stream = provider(s, dir: dir).respond(to: FakeCLI.request())
        let consumer = Task { () -> (String, Bool) in
            var text = ""
            do { for try await e in stream { if case .textDelta(let t) = e { text += t } } } catch is CancellationError { return (text, true) } catch { return (text, false) }
            return (text, Task.isCancelled)          // a cancelled consumer's loop may end silently (the service checks Task.isCancelled)
        }
        let pid = await FakeCLI.pid(from: "\(dir)/pid")!
        try? await Task.sleep(nanoseconds: 400_000_000)
        let t0 = Date()
        consumer.cancel()
        let (text, wasCancel) = await consumer.value
        #expect(text == "first" && wasCancel)
        #expect(await FakeCLI.waitDead(pid))
        #expect(Date().timeIntervalSince(t0) < 5)
        #expect(!FileManager.default.fileExists(atPath: "\(dir)/late"))
    }

    @Test func lostSessionIsRetriedOnceAsAFreshSessionWithBoundedContext() async {
        let dir = FakeCLI.makeDir()
        let s = FakeCLI.script("""
        n=$(cat \(dir)/count 2>/dev/null || echo 0); c=$((n+1)); echo $c > \(dir)/count
        cat > "\(dir)/stdin.$c.txt"
        case "$*" in
          *--resume*) echo '{"type":"result","is_error":true,"result":"No conversation found with session ID old"}'; exit 1 ;;
        esac
        cat <<'EOF'
        \(claudeOK)
        EOF
        """, in: dir)
        let history = [ConversationMessage(role: .user, content: "earlier question"), ConversationMessage(role: .jarvis, content: "earlier answer", route: .reasoning)]
        let r = await FakeCLI.collect(provider(s, dir: dir).respond(to: FakeCLI.request("follow-up", session: "old", history: history)))
        #expect(r.error == nil && FakeCLI.text(r.events) == "Merhaba ğüşiöç 😀", "error=\(String(describing: r.error)) text=\(FakeCLI.text(r.events)) count=\((try? String(contentsOfFile: "\(dir)/count", encoding: .utf8)) ?? "nil")")
        #expect((try? String(contentsOfFile: "\(dir)/count", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "2")
        let second = (try? String(contentsOfFile: "\(dir)/stdin.2.txt", encoding: .utf8)) ?? ""
        #expect(second.contains("earlier question") && second.hasSuffix("follow-up"))        // fresh session got the bounded context
    }

    @Test func codexFakeRunUsesReadOnlyDisabledToolsAndMessageLevelStreaming() async {
        let dir = FakeCLI.makeDir()
        let s = FakeCLI.script("""
        echo "$@" > \(dir)/args.txt
        cat > \(dir)/stdin.txt
        cat <<'EOF'
        {"type":"thread.started","thread_id":"thread-9"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"type":"agent_message","text":"first part"}}
        {"type":"item.completed","item":{"type":"agent_message","text":"ikinci kısım"}}
        {"type":"turn.completed","usage":{}}
        EOF
        """, in: dir)
        let r = await FakeCLI.collect(provider(s, spec: CodexSpec(), dir: dir).respond(to: FakeCLI.request("Explain")))
        #expect(r.error == nil)
        #expect(FakeCLI.text(r.events) == "first part\n\nikinci kısım")
        #expect(r.events.contains { if case .session("thread-9") = $0 { true } else { false } })
        let args = (try? String(contentsOfFile: "\(dir)/args.txt", encoding: .utf8)) ?? ""
        #expect(args.contains("-s read-only") && args.contains("--disable shell_tool") && args.hasPrefix("exec --json"))
        #expect((try? String(contentsOfFile: "\(dir)/stdin.txt", encoding: .utf8))?.hasSuffix("[Request]\nExplain") == true)
    }

    @Test func workerRequestsAreNotSupportedByProviders() {
        let p = CLIProvider(spec: ClaudeCodeSpec(), executablePath: "/x", workingDirectory: "/w", environment: [:])
        #expect(p.supports(.reasoning) && !p.supports(.worker))
    }
}
