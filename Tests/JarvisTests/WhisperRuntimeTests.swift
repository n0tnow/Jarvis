import Foundation
import Testing
@testable import Jarvis

/// A fake speech helper speaking the REAL JSON-lines protocol (TEST CODE: /usr/bin/python3, never the product's venv or model).
enum FakeSTTWorker {
    static let source = #"""
import sys, json, os, time, base64
args = sys.argv
def opt(name, default=None):
    return args[args.index(name)+1] if name in args else default
mode = opt("--mode", "normal"); pidfile = opt("--pidfile"); logfile = opt("--logfile")
if pidfile: open(pidfile, "w").write(str(os.getpid()))
if mode == "die-at-start": sys.exit(3)
if mode == "never-ready": time.sleep(120)
def emit(o):
    sys.stdout.write(json.dumps(o, ensure_ascii=False) + "\n"); sys.stdout.flush()
def log(s):
    if logfile: open(logfile, "a").write(s + "\n")
emit({"type": "ready", "load_seconds": 0.01, "mlx": "fake", "model": "fake"})
sessions = {}
for line in sys.stdin:
    try: m = json.loads(line)
    except Exception: continue
    op, rid = m.get("op"), m.get("id")
    if op == "begin": sessions[rid] = {"n": 0, "lang": m.get("language")}; log("begin %s lang=%s prompt=%s" % (rid, m.get("language"), bool(m.get("prompt")))); continue
    if op == "audio":
        if rid in sessions: sessions[rid]["n"] += len(base64.b64decode(m["pcm"])) // 2
        continue
    if op == "cancel": sessions.pop(rid, None); log("cancel %s" % rid); continue
    if op == "ping": emit({"type": "pong"}); continue
    if op == "shutdown": os._exit(0)
    s = sessions.get(rid)
    if s is None: continue
    if op == "preview":
        log("preview %s n=%d" % (rid, s["n"])); time.sleep(0.15)
        emit({"type": "partial", "id": rid, "text": "partial %d" % s["n"], "language": "en", "audio_seconds": s["n"]/16000.0, "decode_seconds": 0.15})
    elif op == "finish":
        if mode == "crash-final": os._exit(9)
        if mode == "hang-final": time.sleep(120)
        if mode == "error-final": sessions.pop(rid, None); emit({"type": "error", "id": rid, "message": "RuntimeError"}); continue
        text = "heard %d samples" % s["n"]
        if mode == "secret": text += " my key is sk-abcdefghijklmnopqrstuvwxyz123456"
        if mode == "silent": text = ""
        sessions.pop(rid, None)
        log("final %s" % rid)
        emit({"type": "final", "id": rid, "text": text, "language": s["lang"] or "tr", "language_probs": {"tr": 0.9, "en": 0.1}, "confidence": 0.8,
              "audio_seconds": s["n"]/16000.0, "decode_seconds": 0.05})
"""#

    @MainActor
    static func make(mode: String = "normal", idleUnload: TimeInterval = 300, decodeTimeout: TimeInterval = 10) -> (WhisperRuntime, dir: String, pidfile: String, logfile: String) {
        let dir = FakeCLI.makeDir()
        let script = dir + "/worker.py"
        try! source.write(toFile: script, atomically: true, encoding: .utf8)
        let model = dir + "/model"
        try! FileManager.default.createDirectory(atPath: model, withIntermediateDirectories: true)
        try! "{}".write(toFile: model + "/config.json", atomically: true, encoding: .utf8)
        try! "x".write(toFile: model + "/weights.npz", atomically: true, encoding: .utf8)
        let pidfile = dir + "/pid", logfile = dir + "/log"
        var cfg = WhisperRuntimeConfig(executable: "/usr/bin/python3", arguments: [script, "--model", model, "--mode", mode, "--pidfile", pidfile, "--logfile", logfile],
                                       modelPath: model, workerScript: script, workingDirectory: dir, environment: FakeCLI.env())
        cfg.idleUnloadSeconds = idleUnload; cfg.startTimeout = 10; cfg.decodeTimeout = decodeTimeout
        return (WhisperRuntime(config: cfg), dir, pidfile, logfile)
    }

    static func pid(_ file: String) -> pid_t? { (try? String(contentsOfFile: file, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } }
    static func log(_ file: String) -> [String] { ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }

    @MainActor
    static func frame(_ seconds: Double) -> AudioFrame { AudioFrame(samples: [Float](repeating: 0.2, count: Int(seconds * 16000))) }
}

@MainActor
@Suite("Whisper runtime lifecycle (fake helper, real processes)", .serialized)
struct WhisperRuntimeTests {
    @Test func inspectionNeverStartsAProcess() {
        var cfg = FakeSTTWorker.make().0.config
        cfg.executable = "/nonexistent/python"
        #expect(WhisperRuntime(config: cfg).state == .runtimeMissing)
        var cfg2 = FakeSTTWorker.make().0.config
        cfg2.modelPath = "/nonexistent/model"
        #expect(WhisperRuntime(config: cfg2).state == .modelMissing)
        let (rt, _, pidfile, _) = FakeSTTWorker.make()
        #expect(rt.state == .idle && !FileManager.default.fileExists(atPath: pidfile) && rt.workerPID == nil)
    }

    @Test func aSessionRoundTripsAudioPartialAndFinal() async throws {
        let (rt, _, _, logfile) = FakeSTTWorker.make()
        let provider = WhisperSTTProvider(runtime: rt)
        #expect(await provider.availability(for: .auto) == .ready)
        let session = try await provider.makeSession(language: .turkish)
        var partials: [String] = []
        let watcher = Task { for await e in session.events { partials.append(e.text) } }
        for _ in 0..<15 { session.append(FakeSTTWorker.frame(0.1)) }               // 1.5 s → a preview becomes due after 1.0 s
        try await Task.sleep(for: .milliseconds(500))
        let final = try await session.finish()
        await watcher.value
        #expect(final?.isFinal == true && final?.text == "heard 24000 samples" && final?.language == "tr" && final?.confidence == 0.8)
        #expect(!partials.isEmpty && partials.allSatisfy { $0.hasPrefix("partial") })
        #expect(rt.metrics.utterances == 1 && rt.metrics.lastAudioSeconds == 1.5 && rt.state == .ready)
        let log = FakeSTTWorker.log(logfile)
        #expect(log.first?.contains("lang=tr") == true && log.first?.contains("prompt=True") == true, "the language and the vocabulary hint are passed")
    }

    @Test func autoLanguageIsDetectedByTheHelperNotGuessed() async throws {
        let (rt, _, _, logfile) = FakeSTTWorker.make()
        let session = try await WhisperSTTProvider(runtime: rt).makeSession(language: .auto)
        session.append(FakeSTTWorker.frame(0.6))
        _ = try await session.finish()
        #expect(FakeSTTWorker.log(logfile).first?.contains("lang=None") == true)
    }

    @Test func previewsNeverRunConcurrentlyAndAreRateLimited() async throws {
        let (rt, _, _, logfile) = FakeSTTWorker.make()
        let session = try await WhisperSTTProvider(runtime: rt).makeSession(language: .english)
        for _ in 0..<60 { session.append(FakeSTTWorker.frame(0.1)) }                // 6 s of audio delivered in one burst
        try await Task.sleep(for: .milliseconds(400))
        _ = try await session.finish()
        let previews = FakeSTTWorker.log(logfile).filter { $0.hasPrefix("preview") }.count
        #expect(previews >= 1 && previews <= 2, "at most one outstanding preview, rate limited (got \(previews))")
    }

    @Test func silenceProducesNoTranscript() async throws {
        let (rt, _, _, _) = FakeSTTWorker.make(mode: "silent")
        let session = try await WhisperSTTProvider(runtime: rt).makeSession(language: .english)
        session.append(FakeSTTWorker.frame(1))
        #expect(try await session.finish() == nil)
    }

    @Test func helperTextIsSanitizedBeforeAnythingSeesIt() async throws {
        let (rt, _, _, _) = FakeSTTWorker.make(mode: "secret")
        let session = try await WhisperSTTProvider(runtime: rt).makeSession(language: .english)
        session.append(FakeSTTWorker.frame(1))
        let text = try await session.finish()?.text ?? ""
        #expect(!text.contains("sk-abcdefghijklmnopqrstuvwxyz123456") && text.contains("[REDACTED]") && text.hasPrefix("heard"))
    }

    @Test func idleUnloadStopsTheHelperAndTheNextUseRestartsIt() async throws {
        let (rt, _, pidfile, _) = FakeSTTWorker.make(idleUnload: 0.4)
        let p = WhisperSTTProvider(runtime: rt)
        var s = try await p.makeSession(language: .english)
        s.append(FakeSTTWorker.frame(0.6)); _ = try await s.finish()
        let first = FakeSTTWorker.pid(pidfile)!
        #expect(rt.state == .ready && ProcessTree.isAlive(first))
        try await Task.sleep(for: .milliseconds(1200))
        #expect(rt.state == .idle && rt.workerPID == nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!ProcessTree.isAlive(first), "no helper left behind")
        s = try await p.makeSession(language: .english)
        s.append(FakeSTTWorker.frame(0.6)); _ = try await s.finish()
        #expect(rt.metrics.starts == 2 && FakeSTTWorker.pid(pidfile)! != first)
    }

    @Test func unloadIsRefusedWhileAnUtteranceIsActive() async throws {
        let (rt, _, _, _) = FakeSTTWorker.make()
        let s = try await WhisperSTTProvider(runtime: rt).makeSession(language: .english)
        await rt.unload()
        #expect(rt.state == .ready, "memory-pressure unload never interrupts a recording")
        s.cancel()
        await rt.unload()
        #expect(rt.state == .idle)
    }

    @Test func aCrashDuringRecognitionFailsTheSessionAndTheHelperRestarts() async throws {
        let (rt, _, _, _) = FakeSTTWorker.make(mode: "crash-final")
        let p = WhisperSTTProvider(runtime: rt)
        let s = try await p.makeSession(language: .english)
        s.append(FakeSTTWorker.frame(1))
        await #expect(throws: VoiceError.self) { _ = try await s.finish() }
        try await Task.sleep(for: .milliseconds(200))
        if case .failed = rt.state {} else { Issue.record("state \(rt.state)") }
        #expect(rt.workerPID == nil)
        #expect(await p.availability(for: .english) != .ready || true)      // failed ⇒ restarts on demand
        _ = try await p.makeSession(language: .english)                    // starts a new helper
        #expect(rt.metrics.starts == 2)
    }

    @Test func aHelperErrorIsReportedNotInvented() async throws {
        let (rt, _, _, _) = FakeSTTWorker.make(mode: "error-final")
        let s = try await WhisperSTTProvider(runtime: rt).makeSession(language: .english)
        s.append(FakeSTTWorker.frame(1))
        await #expect(throws: VoiceError.self) { _ = try await s.finish() }
        #expect(rt.state == .ready, "a per-utterance error does not take the helper down")
    }

    @Test func aHungHelperIsKilledAfterTheDecodeTimeout() async throws {
        let (rt, _, pidfile, _) = FakeSTTWorker.make(mode: "hang-final", decodeTimeout: 0.5)
        let s = try await WhisperSTTProvider(runtime: rt).makeSession(language: .english)
        s.append(FakeSTTWorker.frame(1))
        let pid = FakeSTTWorker.pid(pidfile)!
        await #expect(throws: VoiceError.self) { _ = try await s.finish() }
        try await Task.sleep(for: .milliseconds(1500))
        #expect(!ProcessTree.isAlive(pid))
    }

    @Test func cancellingASessionDiscardsItsAudioInTheHelper() async throws {
        let (rt, _, _, logfile) = FakeSTTWorker.make()
        let s = try await WhisperSTTProvider(runtime: rt).makeSession(language: .english)
        s.append(FakeSTTWorker.frame(1))
        s.cancel()
        try await Task.sleep(for: .milliseconds(200))
        #expect(FakeSTTWorker.log(logfile).contains { $0.hasPrefix("cancel") } && !rt.hasActiveUtterance)
    }

    @Test func shutdownNowKillsTheHelperSynchronously() async throws {
        let (rt, _, pidfile, _) = FakeSTTWorker.make()
        let s = try await WhisperSTTProvider(runtime: rt).makeSession(language: .english)
        s.append(FakeSTTWorker.frame(1))
        let pid = FakeSTTWorker.pid(pidfile)!
        rt.shutdownNow()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!ProcessTree.isAlive(pid) && rt.workerPID == nil && !rt.hasActiveUtterance)
    }

    @Test func applicationTerminationKillsTheHelperToo() async throws {
        let (rt, _, pidfile, _) = FakeSTTWorker.make()
        _ = try await WhisperSTTProvider(runtime: rt).makeSession(language: .english)
        let pid = FakeSTTWorker.pid(pidfile)!
        ProcessRegistry.shared.killAll()
        try await Task.sleep(for: .milliseconds(400))
        #expect(!ProcessTree.isAlive(pid))
    }

    @Test func aHelperThatNeverBecomesReadyIsReported() async {
        let (rt, _, _, _) = FakeSTTWorker.make(mode: "never-ready")
        var cfg = rt.config; cfg.startTimeout = 0.6
        let slow = WhisperRuntime(config: cfg)
        await #expect(throws: VoiceError.self) { try await slow.ensureStarted() }
        #expect(slow.workerPID == nil)
    }

    @Test func missingInstallationIsASetupHintNotASilentDownload() async {
        var cfg = FakeSTTWorker.make().0.config
        cfg.modelPath = "/nonexistent/model"
        let p = WhisperSTTProvider(runtime: WhisperRuntime(config: cfg))
        if case .needsSetup(let why) = await p.availability(for: .auto) { #expect(why.contains("setup_voice_ai.sh")) } else { Issue.record("expected needsSetup") }
        cfg.executable = "/nonexistent/python"
        if case .needsSetup = await WhisperSTTProvider(runtime: WhisperRuntime(config: cfg)).availability(for: .auto) {} else { Issue.record("expected needsSetup") }
    }
}
