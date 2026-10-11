import Testing
import Foundation
@testable import Jarvis

/// A fake local-model worker speaking the real JSON-lines protocol (TEST CODE: /usr/bin/python3, never the product's venv).
enum FakeWorker {
    static let source = #"""
import sys, json, time, os, threading
args = sys.argv
def opt(name, default=None):
    return args[args.index(name)+1] if name in args else default
mode = opt("--mode", "normal")
pidfile = opt("--pidfile")
if pidfile: open(pidfile, "w").write(str(os.getpid()))
if mode == "die-at-start": sys.exit(3)
if mode == "never-ready": time.sleep(120)
lock = threading.Lock()
def emit(o):
    with lock:
        sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
emit({"type": "ready", "load_seconds": 0.01, "mlx": "fake"})
cancelled = set(); inbox = []
cv = threading.Condition()
def reader():
    for line in sys.stdin:
        try: m = json.loads(line)
        except Exception: continue
        if m.get("op") == "cancel" and mode != "ignore-cancel": cancelled.add(m.get("id"))
        elif m.get("op") == "shutdown":
            os._exit(0)
        else:
            with cv: inbox.append(m); cv.notify()
    os._exit(0)          # stdin EOF: parent gone
threading.Thread(target=reader, daemon=True).start()
while True:
    with cv:
        while not inbox: cv.wait()
        m = inbox.pop(0)
    if m.get("op") == "ping": emit({"type": "pong"}); continue
    rid = m.get("id"); prompt = m.get("prompt", "")
    n = 200 if "LONG" in prompt else 3
    c = False
    for i in range(n):
        if rid in cancelled: c = True; break
        if "CRASH" in prompt and i == 1: os._exit(9)
        emit({"type": "token", "id": rid, "text": "t%d " % i}); time.sleep(0.03)
    cancelled.discard(rid)
    emit({"type": "done", "id": rid, "cancelled": c, "prompt_tokens": 7, "generation_tokens": i + 1, "prompt_tps": 100.0,
          "generation_tps": 50.0, "first_token_seconds": 0.05, "peak_memory_gb": 1.5})
"""#

    @MainActor
    static func makeRuntime(mode: String = "normal", idleUnload: TimeInterval = 300, startTimeout: TimeInterval = 10, cancelGrace: TimeInterval = 2,
                            jobIdle: TimeInterval = 30) -> (LocalRuntime, dir: String, pidfile: String) {
        let dir = FakeCLI.makeDir()
        let script = dir + "/worker.py"
        try! source.write(toFile: script, atomically: true, encoding: .utf8)
        let model = dir + "/model"
        try! FileManager.default.createDirectory(atPath: model, withIntermediateDirectories: true)
        try! "{}".write(toFile: model + "/config.json", atomically: true, encoding: .utf8)
        try! "x".write(toFile: model + "/model.safetensors", atomically: true, encoding: .utf8)
        let pidfile = dir + "/pid"
        var cfg = LocalRuntimeConfig(executable: "/usr/bin/python3", arguments: [script, "--model", model, "--mode", mode, "--pidfile", pidfile], modelPath: model,
                                     workerScript: script, workingDirectory: dir, environment: FakeCLI.env())
        cfg.idleUnloadSeconds = idleUnload; cfg.startTimeout = startTimeout; cfg.cancelGrace = cancelGrace; cfg.jobIdleTimeout = jobIdle
        return (LocalRuntime(config: cfg), dir, pidfile)
    }

    @MainActor
    static func drain(_ runtime: LocalRuntime, _ prompt: String, maxTokens: Int = 50) async -> (tokens: String, stats: LocalJobStats?, error: Error?) {
        var text = "", stats: LocalJobStats?
        do {
            for try await e in runtime.generate(prompt: prompt, maxTokens: maxTokens) {
                switch e { case .token(let t): text += t; case .done(let s): stats = s }
            }
            return (text, stats, nil)
        } catch { return (text, stats, error) }
    }
}

@MainActor
@Suite("Local runtime lifecycle (fake worker, real processes)", .serialized)
struct LocalRuntimeTests {
    @Test func inspectionReportsMissingRuntimeAndMissingModelWithoutStartingAnything() {
        var cfg = FakeWorker.makeRuntime().0.config
        cfg.executable = "/nonexistent/python"
        #expect(LocalRuntime(config: cfg).state == .runtimeMissing)
        var cfg2 = FakeWorker.makeRuntime().0.config
        cfg2.modelPath = "/nonexistent/model"
        #expect(LocalRuntime(config: cfg2).state == .modelMissing)
        let (ok, _, pidfile) = FakeWorker.makeRuntime()
        #expect(ok.state == .idle && !FileManager.default.fileExists(atPath: pidfile))        // inspection never launches the worker
        #expect(ok.state.isUsableForRouting && !LocalRuntimeState.modelMissing.isUsableForRouting)
    }

    @Test func theWorkerIsStartedOnDemandStreamsAndStaysLoaded() async throws {
        let (rt, _, pidfile) = FakeWorker.makeRuntime()
        #expect(rt.state == .idle)
        let r = await FakeWorker.drain(rt, "hello")
        #expect(r.error == nil && r.tokens == "t0 t1 t2 ")
        #expect(r.stats?.generationTokens == 3 && r.stats?.promptTokens == 7 && r.stats?.cancelled == false)
        #expect(rt.state == .ready && rt.workerPID != nil)
        #expect(rt.metrics.generationTokensPerSecond == 50 && rt.metrics.jobsCompleted == 1 && rt.metrics.loadSeconds == 0.01)
        let pid = try #require(await FakeCLI.pid(from: pidfile))
        #expect(FakeCLI.alive(pid))
        let again = await FakeWorker.drain(rt, "second")                                         // same worker, no second start
        #expect(again.error == nil && rt.metrics.startsAttempted == 1)
        rt.shutdownNow()
        #expect(await FakeCLI.waitDead(pid))
    }

    @Test func healthCheckIsARealRoundTrip() async throws {
        let (rt, _, _) = FakeWorker.makeRuntime()
        #expect(await rt.healthCheck() == false)                                                   // not started → not healthy
        try await rt.ensureStarted()
        #expect(await rt.healthCheck())
        rt.shutdownNow()
    }

    @Test func anIdleWorkerIsUnloadedAndNoProcessRemains() async throws {
        let (rt, _, pidfile) = FakeWorker.makeRuntime(idleUnload: 0.4)
        var events: [String] = []
        rt.onEvent = { events.append($0) }
        _ = await FakeWorker.drain(rt, "hello")
        let pid = try #require(await FakeCLI.pid(from: pidfile))
        #expect(rt.state == .ready)
        let deadline = Date().addingTimeInterval(5)
        while rt.state != .idle && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(rt.state == .idle && rt.workerPID == nil)
        #expect(await FakeCLI.waitDead(pid))                                                       // really gone, not just "idle" in the UI
        #expect(events.contains("Local Qwen unloaded"))
        // …and it comes back on demand.
        let r = await FakeWorker.drain(rt, "again")
        #expect(r.error == nil && rt.metrics.startsAttempted == 2)
        rt.shutdownNow()
    }

    @Test func cancellingMidGenerationStopsTheJobAndKeepsTheWorkerUsable() async throws {
        let (rt, _, pidfile) = FakeWorker.makeRuntime()
        var seen = 0
        let task = Task { @MainActor () -> Error? in
            do { for try await e in rt.generate(prompt: "LONG story", maxTokens: 500) { if case .token = e { seen += 1 } }; return nil } catch { return error }
        }
        while seen < 3 { try await Task.sleep(nanoseconds: 20_000_000) }
        let started = Date()
        task.cancel()
        let err = await task.value
        #expect(err == nil || err is CancellationError)                                            // a cancelled consumer just stops iterating
        await rt.waitForJobEnd()
        #expect(Date().timeIntervalSince(started) < 1.5)                                           // worker acknowledged the cancel
        #expect(seen < 100)
        #expect(rt.state == .ready)
        let pid = try #require(await FakeCLI.pid(from: pidfile))
        #expect(FakeCLI.alive(pid))
        let next = await FakeWorker.drain(rt, "after cancel")
        #expect(next.error == nil && next.tokens == "t0 t1 t2 ")
        rt.shutdownNow()
    }

    @Test func aWorkerThatIgnoresCancelIsKilledAfterTheGracePeriodAndIsNotAnOrphan() async throws {
        let (rt, _, pidfile) = FakeWorker.makeRuntime(mode: "ignore-cancel", cancelGrace: 0.5)
        var crashes = 0
        rt.onCrash = { _ in crashes += 1 }
        var seen = 0
        let task = Task { @MainActor () -> Error? in
            do { for try await e in rt.generate(prompt: "LONG story", maxTokens: 500) { if case .token = e { seen += 1 } }; return nil } catch { return error }
        }
        while seen < 3 { try await Task.sleep(nanoseconds: 20_000_000) }
        let pid = try #require(await FakeCLI.pid(from: pidfile))
        task.cancel()
        _ = await task.value
        await rt.waitForJobEnd()
        #expect(await FakeCLI.waitDead(pid, upTo: 6))
        let deadline = Date().addingTimeInterval(3)
        while rt.state != .idle && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(rt.state == .idle && crashes == 0)                                                 // our own kill is not reported as a crash
        let next = await FakeWorker.drain(rt, "recovered")                                         // restarts on demand
        #expect(next.error == nil)
        rt.shutdownNow()
    }

    @Test func aCrashDuringGenerationFailsTheJobMarksTheRuntimeFailedAndRecovers() async throws {
        let (rt, _, _) = FakeWorker.makeRuntime()
        var crashes: [String] = []
        rt.onCrash = { crashes.append($0) }
        let r = await FakeWorker.drain(rt, "CRASH now")
        guard let e = r.error as? ProviderError, case .processFailed(.local, _) = e else { Issue.record("expected processFailed, got \(String(describing: r.error))"); return }
        #expect(crashes.count == 1)
        if case .failed = rt.state {} else { Issue.record("state must be failed, got \(rt.state)") }
        #expect(!rt.state.isUsableForRouting)
        let again = await FakeWorker.drain(rt, "hello")                                            // on-demand restart after the supervisor allows it
        #expect(again.error == nil && rt.state == .ready)
        rt.shutdownNow()
    }

    @Test func aWorkerThatNeverBecomesReadyTimesOutAndIsKilled() async throws {
        let (rt, _, pidfile) = FakeWorker.makeRuntime(mode: "never-ready", startTimeout: 1)
        let started = Date()
        let r = await FakeWorker.drain(rt, "hello")
        guard let e = r.error as? ProviderError, case .timedOut(.local) = e else { Issue.record("expected timeout, got \(String(describing: r.error))"); return }
        #expect(Date().timeIntervalSince(started) < 8)
        let pid = try #require(await FakeCLI.pid(from: pidfile))
        #expect(await FakeCLI.waitDead(pid))
        if case .failed = rt.state {} else { Issue.record("state must be failed, got \(rt.state)") }
    }

    @Test func aWorkerThatDiesWhileStartingFailsFast() async {
        let (rt, _, _) = FakeWorker.makeRuntime(mode: "die-at-start", startTimeout: 10)
        let started = Date()
        let r = await FakeWorker.drain(rt, "hello")
        #expect(r.error != nil && Date().timeIntervalSince(started) < 5)
    }

    @Test func onlyOneLocalJobRunsAtATime() async throws {
        let (rt, _, _) = FakeWorker.makeRuntime()
        try await rt.ensureStarted()
        var n = 0
        let first = Task { @MainActor in for try await e in rt.generate(prompt: "LONG", maxTokens: 500) { if case .token = e { n += 1 } } }
        while n < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        let second = await FakeWorker.drain(rt, "concurrent")
        #expect((second.error as? ProviderError) == .busy)
        first.cancel(); _ = await first.result
        rt.shutdownNow()
    }

    @Test func theWorkerExitsByItselfWhenItsParentGoesAway() async throws {
        // Simulates "JARVIS died": stdin closes → the worker must exit (no orphan even after kill -9 of JARVIS).
        let (rt, _, pidfile) = FakeWorker.makeRuntime()
        try await rt.ensureStarted()
        let pid = try #require(await FakeCLI.pid(from: pidfile))
        rt.shutdownNow()                                                                            // SIGKILL path
        #expect(await FakeCLI.waitDead(pid))
        let (rt2, _, pidfile2) = FakeWorker.makeRuntime()
        try await rt2.ensureStarted()
        let pid2 = try #require(await FakeCLI.pid(from: pidfile2))
        await rt2.unload()                                                                          // graceful path: shutdown op + stdin close
        #expect(await FakeCLI.waitDead(pid2) && rt2.state == .idle)
    }
}

@MainActor
@Suite("Local provider policy (defence in depth)", .serialized)
struct LocalProviderPolicyTests {
    @Test func theLocalProviderRefusesDevelopmentWorkEvenIfRoutedToByMistake() async {
        let (rt, _, pidfile) = FakeWorker.makeRuntime()
        for prompt in ["Write unit tests for this function and run them", "Fix the bug in PlayerController.cs", "Refactor my Unity multiplayer code"] {
            let provider = LocalQwenProvider(runtime: rt, profile: TaskClassifier.profile(for: prompt))
            let r = await FakeCLI.collect(provider.respond(to: FakeCLI.request(prompt)))
            guard let e = r.error as? ProviderError, case .unavailable(.local, let why) = e else { Issue.record("must refuse: \(prompt)"); continue }
            #expect(why.contains("not allowed on the local model"))
            #expect(r.events.isEmpty)
        }
        #expect(rt.metrics.startsAttempted == 0 && !FileManager.default.fileExists(atPath: pidfile))      // the worker was never even started
    }

    @Test func aLightweightTaskStreamsThroughTheProvider() async {
        let (rt, _, _) = FakeWorker.makeRuntime()
        let prompt = "Summarize in one sentence: the cat sat on the mat."
        let provider = LocalQwenProvider(runtime: rt, profile: TaskClassifier.profile(for: prompt))
        let r = await FakeCLI.collect(provider.respond(to: FakeCLI.request(prompt)))
        #expect(r.error == nil && FakeCLI.text(r.events) == "t0 t1 t2 ")
        #expect(r.events.contains { if case .usage(7, 3) = $0 { true } else { false } })
        #expect(r.events.contains { if case .finished = $0 { true } else { false } })
        rt.shutdownNow()
    }

    @Test func stoppedMeansTheWorkerHasReallyEndedTheJobSoTheNextRequestIsNeverRefusedAsBusy() async {
        // Regression found by the REAL live test: provider.waitUntilStopped returned before the worker acknowledged the cancel.
        let (rt, _, _) = FakeWorker.makeRuntime()
        let prompt = "LONG hello"
        let provider = LocalQwenProvider(runtime: rt, profile: TaskProfile(category: .conversation, complexity: .trivial))
        let req = FakeCLI.request(prompt)
        let consumer = Task { @MainActor in for try await _ in provider.respond(to: req) {} }
        while rt.state != .running { try? await Task.sleep(nanoseconds: 10_000_000) }
        consumer.cancel()
        await provider.waitUntilStopped(req.id)
        #expect(rt.state == .ready)                                                                // not .running: the job has ended
        let next = await FakeCLI.collect(provider.respond(to: FakeCLI.request("hi")))
        #expect(next.error == nil && FakeCLI.text(next.events) == "t0 t1 t2 ")
        rt.shutdownNow()
    }

    @Test func aCancelledLocalStreamIsNeverReportedAsFinished() async {
        let (rt, _, _) = FakeWorker.makeRuntime()
        let provider = LocalQwenProvider(runtime: rt, profile: TaskProfile(category: .conversation, complexity: .trivial))
        let req = FakeCLI.request("LONG hello")
        var sawFinished = false
        let consumer = Task { @MainActor in for try await e in provider.respond(to: req) { if case .finished = e { sawFinished = true } } }
        while rt.state != .running { try? await Task.sleep(nanoseconds: 10_000_000) }
        consumer.cancel(); _ = await consumer.result
        await provider.waitUntilStopped(req.id)
        #expect(!sawFinished)
        rt.shutdownNow()
    }

    @Test func theLocalPromptCarriesTheNoToolsInstruction() {
        let p = LocalQwenProvider.prompt(for: FakeCLI.request("hello"))
        #expect(p.contains("NO tools") && p.contains("[Request]\nhello") && p.contains("Keep answers short"))
    }
}
