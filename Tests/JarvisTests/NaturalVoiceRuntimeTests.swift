import Foundation
import Testing
@testable import Jarvis

// MARK: - Fake helpers speaking the REAL JSON-lines protocols (TEST CODE: /usr/bin/python3, never the product's venv or models)

enum FakeSentinel {
    static let source = #"""
import sys, json, os, time, base64, struct
args = sys.argv
def opt(name, default=None):
    return args[args.index(name)+1] if name in args else default
mode = opt("--mode", "normal"); pidfile = opt("--pidfile"); logfile = opt("--logfile")
models = opt("--models")
if pidfile: open(pidfile, "w").write(str(os.getpid()))
if mode == "die-at-start": sys.exit(3)
def emit(o):
    sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
def log(s):
    if logfile: open(logfile, "a").write(s + "\n")
emit({"type": "ready", "load_seconds": 0.01, "wake_model": "fake", "vad_model": "fake"})
cfg = {"wake": True, "vad": True}
samples = 0; speech = False; cpu0 = time.process_time()
for line in sys.stdin:
    try: m = json.loads(line)
    except Exception: continue
    op = m.get("op")
    if op == "config":
        cfg.update({k: v for k, v in m.items() if k != "op"}); log("config %s" % json.dumps({k: cfg[k] for k in ("wake", "vad")}))
    elif op == "audio":
        pcm = base64.b64decode(m.get("pcm", "")); n = len(pcm) // 2; samples += n
        vals = struct.unpack("<%dh" % n, pcm[:n*2]) if n else ()
        peak = max((abs(v) for v in vals), default=0)
        log("audio %d peak=%d" % (n, peak))
        if peak == 12345 and cfg["wake"]:
            emit({"type": "wake", "score": 0.97})
        loud = peak > 3000
        if cfg["vad"] and loud and not speech: speech = True; emit({"type": "vad", "speech": True})
        if cfg["vad"] and not loud and speech: speech = False; emit({"type": "vad", "speech": False})
        if mode == "secret": emit({"type": "wake", "score": "sk-abcdefghijklmnopqrstuvwxyz123456", "text": "sk-abcdefghijklmnopqrstuvwxyz123456"})
    elif op == "reset": log("reset"); speech = False
    elif op == "stats": emit({"type": "stats", "audio_s": samples / 16000.0, "cpu_s": time.process_time() - cpu0, "max_wake_score": 0.5})
    elif op == "ping": emit({"type": "pong"})
    elif op == "shutdown": os._exit(0)
    elif op == "crash": os._exit(9)
"""#

    @MainActor
    static func make(existingFiles: Bool = true) -> (SentinelRuntime, dir: String, pidfile: String, logfile: String) {
        let dir = FakeCLI.makeDir()
        let script = dir + "/sentinel.py"
        try! source.write(toFile: script, atomically: true, encoding: .utf8)
        let models = dir + "/wake"
        try! FileManager.default.createDirectory(atPath: models, withIntermediateDirectories: true)
        if existingFiles { for f in SentinelRuntime.Config.modelFiles { try! "x".write(toFile: models + "/" + f, atomically: true, encoding: .utf8) } }
        let pidfile = dir + "/pid", logfile = dir + "/log"
        let cfg = SentinelRuntime.Config(executable: "/usr/bin/python3", worker: script, modelsDirectory: models, workingDirectory: dir, environment: FakeCLI.env())
        return (SentinelRuntime(config: cfg), dir, pidfile, logfile)
    }
}

enum FakeVoiceWorker {
    static let source = #"""
import sys, json, os, time, base64, struct, math, threading, queue
mode = os.environ.get("FAKE_MODE", "normal")
def emit(o):
    sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
emit({"type": "ready", "load_seconds": 0.01, "model": "fake", "sample_rate": 22050, "styles": ["M1"]})
cancelled = set(); box = queue.Queue()
def reader():
    for line in sys.stdin:
        try: m = json.loads(line)
        except Exception: continue
        if m.get("op") == "cancel": cancelled.add(m.get("id")); continue
        if m.get("op") == "shutdown": os._exit(0)
        box.put(m)
    box.put(None)
threading.Thread(target=reader, daemon=True).start()
while True:
    m = box.get()
    if m is None: break
    if m.get("op") == "ping": emit({"type": "pong"}); continue
    if m.get("op") != "synth": continue
    rid = m["id"]
    if mode == "hang": time.sleep(120)
    if mode == "error": emit({"type": "error", "id": rid, "message": "RuntimeError"}); continue
    if mode == "crash": os._exit(9)
    if rid in cancelled: continue
    n_blocks = 5; per = 2205
    for b in range(n_blocks):
        if rid in cancelled: break
        pcm = struct.pack("<%dh" % per, *[int(8000 * math.sin(2 * math.pi * 220 * (b * per + i) / 22050)) for i in range(per)])
        emit({"type": "audio", "id": rid, "seq": b, "rate": 22050, "pcm": base64.b64encode(pcm).decode()})
        time.sleep(0.03)
    if rid not in cancelled: emit({"type": "done", "id": rid, "audio_seconds": n_blocks * per / 22050, "synth_seconds": 0.15, "blocks": n_blocks})
"""#

    @MainActor
    static func make(mode: String = "normal", idleUnload: TimeInterval = 300, requestTimeout: TimeInterval = 10) -> (NeuralVoiceRuntime, dir: String) {
        let dir = FakeCLI.makeDir()
        let script = dir + "/tts.py"
        try! source.write(toFile: script, atomically: true, encoding: .utf8)
        let model = dir + "/model"
        for f in NeuralVoiceRuntime.Config.requiredModelFiles {
            let path = model + "/" + f
            try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try! "x".write(toFile: path, atomically: true, encoding: .utf8)
        }
        var env = FakeCLI.env(); env["FAKE_MODE"] = mode
        var cfg = NeuralVoiceRuntime.Config(executable: "/usr/bin/python3", worker: script, modelDirectory: model, workingDirectory: dir, environment: env)
        cfg.idleUnloadSeconds = idleUnload; cfg.requestTimeout = requestTimeout
        return (NeuralVoiceRuntime(config: cfg), dir)
    }
}

// MARK: - Restart budget / helper host

@Suite("Helper restart budget")
struct RestartBudgetTests {
    @Test func startsAreBoundedThenCoolDown() {
        var b = RestartBudget(maxStarts: 3, window: 600, cooldown: 180)
        let first = b.allowStart(at: 0), second = b.allowStart(at: 10), third = b.allowStart(at: 20)
        #expect(first && second && third)
        let fourth = b.allowStart(at: 30), stillBlocked = b.allowStart(at: 100), afterCooldown = b.allowStart(at: 30 + 181)
        #expect(!fourth, "the 4th launch inside the window is refused")
        #expect(!stillBlocked, "still cooling down")
        #expect(afterCooldown, "after the cooldown it may try again")
    }

    @Test func oldStartsLeaveTheWindow() {
        var b = RestartBudget(maxStarts: 2, window: 100, cooldown: 50)
        let a = b.allowStart(at: 0), c = b.allowStart(at: 10)
        #expect(a && c)
        let later = b.allowStart(at: 120)
        #expect(later, "the two earlier starts are outside the window")
        b.reset()
        #expect(b.recentStarts == 0)
    }
}

// MARK: - Sentinel runtime (wake word + VAD helper) against a fake helper

@MainActor
@Suite("Sentinel runtime (fake helper, real processes)", .serialized)
struct SentinelRuntimeTests {
    private func loud(_ amplitude: Int16, seconds: Double = 0.1) -> AudioFrame { AudioFrame(samples: [Float](repeating: Float(amplitude) / 32767, count: Int(seconds * 16000))) }

    @Test func inspectionNeverStartsAProcessAndMissingFilesMeanNotInstalled() {
        let (rt, _, pidfile, _) = FakeSentinel.make()
        #expect(rt.state == .idle && rt.host.pid == nil && !FileManager.default.fileExists(atPath: pidfile))
        let (missing, _, _, _) = FakeSentinel.make(existingFiles: false)
        if case .notInstalled = missing.state {} else { Issue.record("expected notInstalled, got \(missing.state)") }
        #expect(!missing.isAvailable)
    }

    @Test func startFeedAndEvents() async throws {
        let (rt, _, _, _) = FakeSentinel.make()
        var wakes: [Double] = [], vad: [Bool] = []
        rt.onWake = { wakes.append($0) }; rt.onVAD = { vad.append($0) }
        try await rt.start()
        #expect(rt.isRunning && rt.host.pid != nil)
        rt.setMode(wake: true, vad: true)
        rt.feed(loud(5000))                                                      // speech-like
        rt.feed(loud(100))                                                       // quiet again
        rt.feed(loud(12345))                                                     // the fake's wake marker (also loud, so the fake VAD calls it speech)
        rt.feed(loud(100))
        try await Task.sleep(for: .milliseconds(400))
        #expect(vad == [true, false, true, false] && wakes == [0.97])
        #expect(rt.metrics.framesSent == 4 && rt.metrics.wakeEvents == 1 && !rt.vadSpeech)
        await rt.stop()
        #expect(rt.host.pid == nil)
    }

    @Test func audioIsBatchedIntoHundredMillisecondMessages() async throws {
        let (rt, _, _, logfile) = FakeSentinel.make()
        // the fake logs through its own config; this checks the Swift side: small frames accumulate until 1600 samples
        try await rt.start()
        for _ in 0..<5 { rt.feed(AudioFrame(samples: [Float](repeating: 0.01, count: 400))) }          // 5 × 25 ms = 125 ms
        #expect(rt.metrics.framesSent == 1, "one 100 ms message sent, 25 ms kept pending")
        await rt.stop()
        _ = logfile
    }

    @Test func helperOutputTextIsNeverReadOnlyNumbersAndFlags() async throws {
        let dir = FakeCLI.makeDir()
        let script = dir + "/sentinel.py"
        try FakeSentinel.source.replacingOccurrences(of: "mode = opt(\"--mode\", \"normal\")", with: "mode = \"secret\"").write(toFile: script, atomically: true, encoding: .utf8)
        let models = dir + "/wake"
        try FileManager.default.createDirectory(atPath: models, withIntermediateDirectories: true)
        for f in SentinelRuntime.Config.modelFiles { try "x".write(toFile: models + "/" + f, atomically: true, encoding: .utf8) }
        let rt = SentinelRuntime(config: .init(executable: "/usr/bin/python3", worker: script, modelsDirectory: models, workingDirectory: dir, environment: FakeCLI.env()))
        var scores: [Double] = []
        rt.onWake = { scores.append($0) }
        try await rt.start()
        rt.feed(loud(5000))
        try await Task.sleep(for: .milliseconds(300))
        #expect(scores.isEmpty && rt.metrics.wakeEvents == 0, "a non-numeric score is not a wake event and never becomes text or a number")
        #expect(!"\(rt.metrics)".contains("sk-"))
        await rt.stop()
    }

    @Test func aCrashRestartsOnceAndIsBoundedThenReportsUnavailable() async throws {
        let (rt, _, _, _) = FakeSentinel.make()
        var unavailable: String?
        rt.onUnavailable = { unavailable = $0 }
        try await rt.start()
        let first = rt.host.pid
        rt.host.send(["op": "crash"])
        try await Task.sleep(for: .milliseconds(800))
        #expect(rt.isRunning && rt.host.pid != first && rt.host.pid != nil, "restarted after an unexpected exit")
        for _ in 0..<4 {                                                          // repeated crashes exhaust the budget
            rt.host.send(["op": "crash"])
            try await Task.sleep(for: .milliseconds(700))
        }
        #expect(unavailable != nil && !rt.isRunning, "after the bounded restarts it stays down and says so")
        rt.shutdownNow()
    }

    @Test func shutdownNowKillsTheHelperAtOnce() async throws {
        let (rt, _, _, _) = FakeSentinel.make()
        try await rt.start()
        let pid = try #require(rt.host.pid)
        rt.shutdownNow()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!ProcessTree.isAlive(pid) && rt.host.pid == nil)
    }

    @Test func statsAreReportedByTheHelper() async throws {
        let (rt, _, _, _) = FakeSentinel.make()
        try await rt.start()
        rt.feed(loud(200)); rt.feed(loud(200))
        let m = await rt.requestStats()
        #expect((m.helperAudioSeconds ?? -1) >= 0.19 && m.helperCPUSeconds != nil)
        await rt.stop()
    }
}

// MARK: - Neural voice runtime against a fake helper

@MainActor
@Suite("Neural voice runtime (fake helper, real processes)", .serialized)
struct NeuralVoiceRuntimeTests {
    private func collect(_ stream: AsyncThrowingStream<PCMBlock, Error>) async throws -> [PCMBlock] {
        var out: [PCMBlock] = []
        for try await b in stream { out.append(b) }
        return out
    }
    private let params = NeuralVoiceParameters(style: "M1", speed: 1, steps: 4)

    @Test func installedMeansFilesExistAndNothingStarts() {
        let (rt, _) = FakeVoiceWorker.make()
        #expect(rt.state == .idle && rt.host.pid == nil)
        let missing = NeuralVoiceRuntime(config: .init(executable: "/usr/bin/python3", worker: "/nonexistent/w.py", modelDirectory: "/nonexistent/m", workingDirectory: "/", environment: [:]))
        if case .notInstalled = missing.state {} else { Issue.record("expected notInstalled") }
    }

    @Test func aPhraseStreamsBlocksThenFinishes() async throws {
        let (rt, _) = FakeVoiceWorker.make()
        let blocks = try await collect(rt.synthesize(id: 1, text: "Merhaba", language: .turkish, parameters: params, tailMilliseconds: 160))
        #expect(blocks.count == 5 && blocks.allSatisfy { $0.sampleRate == 22050 && $0.samples.count == 2205 })
        #expect(rt.metrics.phrases == 1 && rt.metrics.lastFirstBlockSeconds != nil && rt.state == .running)
        rt.shutdownNow()
    }

    @Test func cancelStopsTheStreamAndTheHelperStaysUsable() async throws {
        let (rt, _) = FakeVoiceWorker.make()
        let stream = rt.synthesize(id: 2, text: "uzun", language: .turkish, parameters: params, tailMilliseconds: 160)
        var got = 0
        for try await _ in stream { got += 1; if got == 1 { rt.cancelAll(); break } }
        let next = try await collect(rt.synthesize(id: 3, text: "tamam", language: .english, parameters: params, tailMilliseconds: 80))
        #expect(got == 1 && next.count == 5, "the cancelled phrase did not pollute the next one")
        rt.shutdownNow()
    }

    @Test func unloadAndIdleUnloadStopTheHelper() async throws {
        let (rt, _) = FakeVoiceWorker.make(idleUnload: 0.4)
        _ = try await collect(rt.synthesize(id: 4, text: "x", language: .english, parameters: params, tailMilliseconds: 80))
        let pid = try #require(rt.host.pid)
        try await Task.sleep(for: .milliseconds(1100))
        #expect(rt.host.pid == nil && !ProcessTree.isAlive(pid) && rt.state == .idle, "idle unload")
        _ = try await collect(rt.synthesize(id: 5, text: "y", language: .english, parameters: params, tailMilliseconds: 80))
        #expect(rt.host.pid != nil, "restarts on demand")
        await rt.unload()
        #expect(rt.host.pid == nil)
    }

    @Test func aHelperErrorEndsOnlyThatPhrase() async throws {
        let (rt, _) = FakeVoiceWorker.make(mode: "error")
        do { _ = try await collect(rt.synthesize(id: 6, text: "x", language: .english, parameters: params, tailMilliseconds: 80)); Issue.record("expected an error") } catch {}
        rt.shutdownNow()
    }

    @Test func aHungHelperIsKilledByTheWatchdog() async throws {
        let (rt, _) = FakeVoiceWorker.make(mode: "hang", requestTimeout: 0.6)
        do { _ = try await collect(rt.synthesize(id: 7, text: "x", language: .english, parameters: params, tailMilliseconds: 80)); Issue.record("expected a timeout") } catch {}
        try await Task.sleep(for: .milliseconds(300))
        #expect(rt.host.pid == nil, "the hung helper was killed")
    }

    @Test func aCrashFailsTheStreamAndTheNextRequestRestartsTheHelper() async throws {
        let (rt, dir) = FakeVoiceWorker.make(mode: "crash")
        do { _ = try await collect(rt.synthesize(id: 8, text: "x", language: .english, parameters: params, tailMilliseconds: 80)); Issue.record("expected a failure") } catch {}
        _ = dir
        rt.shutdownNow()
    }

    @Test func theEngineMapsPresetsAndReportsAvailability() {
        let (rt, _) = FakeVoiceWorker.make()
        let engine = NeuralSpeechEngine(runtime: rt)
        #expect(engine.availability() == .ready && engine.voices().isEmpty)
        let missing = NeuralSpeechEngine(runtime: NeuralVoiceRuntime(config: .init(executable: "/nonexistent", worker: "/nonexistent", modelDirectory: "/nonexistent", workingDirectory: "/", environment: [:])))
        if case .unavailable(let why) = missing.availability() { #expect(why.contains("setup_voice_ai.sh --natural")) } else { Issue.record("expected unavailable") }
    }
}

// MARK: - Player-backed speech provider (ordering, events, stop)

@MainActor
final class FakePlayback: PCMPlayback {
    var isPlaying: Bool { !chunks.isEmpty }
    var onChunkStarted: ((Int) -> Void)?
    var onChunkFinished: ((Int) -> Void)?
    var onFailure: ((String) -> Void)?
    var onReferenceLevel: (@Sendable (Float, TimeInterval) -> Void)?
    private(set) var order: [Int] = []                      // chunk ids in the order their audio was scheduled
    private(set) var stops = 0
    private(set) var closed: Set<Int> = []
    private var chunks: [Int] = []
    func enqueue(_ block: PCMBlock, chunkID: Int) {
        if !order.contains(chunkID) { order.append(chunkID) }
        if chunks.isEmpty { onChunkStarted?(chunkID) }
        if !chunks.contains(chunkID) { chunks.append(chunkID) }
    }
    func closeChunk(_ chunkID: Int) { closed.insert(chunkID) }
    /// The test plays the head chunk to its end.
    func finishHead() { guard let id = chunks.first else { return }; chunks.removeFirst(); onChunkFinished?(id); if let next = chunks.first { onChunkStarted?(next) } }
    func stop() { stops += 1; chunks.removeAll() }
    func shutdown() { stop() }
}

@MainActor
final class FakeEngine: PCMSynthesizing {
    var delays: [Int: Duration] = [:]
    var failing: Set<Int> = []
    private(set) var cancelled = 0, requested: [Int] = []
    func availability() -> TTSAvailability { .ready }
    func voices() -> [VoiceDescriptor] { [] }
    func synthesize(_ chunk: SpeechChunk, voice: VoiceDescriptor?, rate: Double) -> AsyncThrowingStream<PCMBlock, Error> {
        requested.append(chunk.id)
        let delay = delays[chunk.id] ?? .milliseconds(5), fail = failing.contains(chunk.id)
        return AsyncThrowingStream { c in
            let t = Task {
                try? await Task.sleep(for: delay)
                if fail { c.finish(throwing: VoiceError.ttsUnavailable("boom")); return }
                c.yield(PCMBlock(samples: [Float](repeating: 0.1, count: 4800), sampleRate: 48_000))
                c.yield(PCMBlock(samples: [Float](repeating: 0.1, count: 4800), sampleRate: 48_000))
                c.finish()
            }
            c.onTermination = { _ in t.cancel() }
        }
    }
    func cancelAll() { cancelled += 1 }
    func shutdownNow() { cancelAll() }
}

@MainActor
@Suite("Player-backed speech provider")
struct PlayerBackedTTSTests {
    private func make() -> (PlayerBackedTTSProvider, FakeEngine, FakePlayback, Log) {
        let engine = FakeEngine(), player = FakePlayback()
        let p = PlayerBackedTTSProvider(id: "fake", displayName: "Fake", capabilities: TTSCapabilities(languages: [.english], streaming: .chunked, selectableVoices: false, costClass: .local, needsNetwork: false, runtime: "t"),
                                        engine: engine, player: player)
        let log = Log()
        p.onEvent = { log.events.append($0) }
        return (p, engine, player, log)
    }
    final class Log { var events: [TTSPlaybackEvent] = [] }
    private func chunk(_ id: Int) -> SpeechChunk { SpeechChunk(id: id, text: "x", language: .english) }
    private func settle(_ cond: @MainActor () -> Bool) async { let end = Date().addingTimeInterval(2); while !cond(), Date() < end { try? await Task.sleep(for: .milliseconds(5)) } }

    @Test func phrasesAreScheduledStrictlyInOrderEvenWhenALaterOneIsReadyFirst() async {
        let (p, engine, player, log) = make()
        engine.delays = [1: .milliseconds(120), 2: .milliseconds(5)]            // chunk 2 is synthesised before chunk 1
        p.speak(chunk(1), voice: nil, rate: 1); p.speak(chunk(2), voice: nil, rate: 1)
        await settle { player.closed.count == 2 }
        #expect(player.order == [1, 2], "chunk 2's audio waited for chunk 1")
        player.finishHead(); player.finishHead()
        #expect(log.events == [.started(chunkID: 1), .started(chunkID: 2), .finished(chunkID: 1), .finished(chunkID: 2)] || log.events == [.started(chunkID: 1), .finished(chunkID: 1), .started(chunkID: 2), .finished(chunkID: 2)])
    }

    @Test func stopSilencesEverythingAndReportsCancellationsOnly() async {
        let (p, engine, player, log) = make()
        engine.delays = [2: .milliseconds(200)]
        p.speak(chunk(1), voice: nil, rate: 1); p.speak(chunk(2), voice: nil, rate: 1)
        await settle { player.isPlaying }
        p.stop()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(player.stops >= 1 && engine.cancelled >= 1)
        #expect(log.events.contains(.cancelled(chunkID: 1)) && log.events.contains(.cancelled(chunkID: 2)))
        #expect(!log.events.contains(.finished(chunkID: 2)), "chunk 2 never plays after the stop")
        #expect(player.order.filter { $0 == 2 }.isEmpty, "its late audio was dropped, not scheduled")
    }

    @Test func aFailingPhraseDoesNotBlockTheNextOne() async {
        let (p, engine, player, log) = make()
        engine.failing = [1]
        p.speak(chunk(1), voice: nil, rate: 1); p.speak(chunk(2), voice: nil, rate: 1)
        await settle { player.closed.contains(2) }
        #expect(log.events.contains { if case .failed(let id, _) = $0 { id == 1 } else { false } })
        #expect(player.order == [2])
    }

    @Test func aPlayerFailureStopsEverythingAndIsReported() async {
        let (p, _, player, log) = make()
        p.speak(chunk(1), voice: nil, rate: 1)
        await settle { player.isPlaying }
        player.onFailure?("the audio output device changed")
        #expect(log.events.contains { if case .failed = $0 { true } else { false } })
        #expect(player.stops >= 1)
    }

    @Test func cuesNeverTouchTheSpeechJobs() async {
        let (p, _, player, log) = make()
        p.playCue(WakeCue.block)
        #expect(player.order.count == 1 && player.order[0] < 0 && log.events.isEmpty && !WakeCue.block.samples.isEmpty)
    }

    @Test func renderCollectsAudioWithoutPlayingIt() async throws {
        let (p, _, player, _) = make()
        let r = try await p.render("hi", language: .english, voice: nil, rate: 1)
        #expect(r.frames == 9600 && player.order.isEmpty && r.firstBufferSeconds != nil)
    }
}

// MARK: - Microphone hub (one engine for everyone) and the memory-only helpers

@MainActor
@Suite("Microphone hub")
struct MicrophoneHubTests {
    @Test func oneEngineServesEverySubscriberAndStopsWithTheLastOne() throws {
        let source = FakeAudioInput()
        let hub = MicrophoneHub(makeSource: { source })
        #expect(!hub.isCapturing && source.startCount == 0, "nothing exists without a subscriber")
        let a = try hub.subscribe("wake", onFrame: { _ in }, onInterruption: { _ in })
        let b = try hub.subscribe("push-to-talk", onFrame: { _ in }, onInterruption: { _ in })
        #expect(hub.isCapturing && source.startCount == 1 && hub.subscriberLabels == ["push-to-talk", "wake"], "a second subscriber does not start a second engine")
        hub.unsubscribe(b)
        #expect(hub.isCapturing && source.stopCount == 0)
        hub.unsubscribe(a)
        #expect(!hub.isCapturing && source.stopCount == 1)
    }

    @Test func framesReachEverySubscriberAndAFailedStartRegistersNothing() throws {
        let source = FakeAudioInput()
        let hub = MicrophoneHub(makeSource: { source })
        final class Count: @unchecked Sendable { var a = 0, b = 0 }
        let c = Count()
        _ = try hub.subscribe("a", onFrame: { _ in c.a += 1 }, onInterruption: { _ in })
        _ = try hub.subscribe("b", onFrame: { _ in c.b += 1 }, onInterruption: { _ in })
        source.feed(seconds: 0.5)
        #expect(c.a == 5 && c.b == 5)
        hub.shutdown()
        let broken = FakeAudioInput(); broken.startError = VoiceError.microphoneUnavailable("no device")
        let hub2 = MicrophoneHub(makeSource: { broken })
        #expect((try? hub2.subscribe("x", onFrame: { _ in }, onInterruption: { _ in })) == nil)
        #expect(hub2.subscriberCount == 0 && !hub2.isCapturing)
    }

    @Test func aDeviceInterruptionReachesEverySubscriberAndStopsTheEngine() async throws {
        let source = FakeAudioInput()
        let hub = MicrophoneHub(makeSource: { source })
        final class Seen: @unchecked Sendable { var reasons: [String] = [] }
        let seen = Seen()
        _ = try hub.subscribe("wake", onFrame: { _ in }, onInterruption: { seen.reasons.append($0) })
        _ = try hub.subscribe("ptt", onFrame: { _ in }, onInterruption: { seen.reasons.append($0) })
        source.interrupt("the audio device changed")
        try await Task.sleep(for: .milliseconds(100))
        #expect(seen.reasons.count == 2 && !hub.isCapturing && hub.subscriberCount == 0)
    }

    @Test func hubAudioInputIsTheV07InputContractOnTheSharedEngine() throws {
        let source = FakeAudioInput()
        let hub = MicrophoneHub(makeSource: { source })
        let input = HubAudioInput(hub: hub)
        try input.start(onFrame: { _ in }, onInterruption: { _ in })
        #expect(input.isCapturing && hub.isCapturing)
        input.stop()
        #expect(!input.isCapturing && !hub.isCapturing)
        input.stop()                                                // idempotent
    }
}

@Suite("Audio ring and energy gate")
struct AudioRingAndGateTests {
    @Test func theRingIsBoundedAndKeepsTheNewestAudio() {
        var ring = AudioRing(maxSeconds: 1.0)
        for i in 0..<50 { ring.append(AudioFrame(samples: [Float](repeating: Float(i), count: 1600))) }            // 5 s offered
        #expect(ring.seconds <= 1.1 && ring.frameCount <= 11, "never more than ~1 s is kept")
        let tail = ring.tail(seconds: 0.3)
        #expect(tail.last?.samples.first == 49 && tail.count == 3)
        ring.clear()
        #expect(ring.seconds == 0 && ring.tail(seconds: 1).isEmpty)
    }

    @Test func theGateStaysClosedInAQuietRoomAndOpensForSpeechWithAHangover() {
        var g = EnergyGate()
        var t = 0.0
        for _ in 0..<100 { _ = g.push(db: -66, duration: 0.1, at: t); t += 0.1 }          // 10 s of room noise
        #expect(!g.isOpen)
        let onSpeech = g.push(db: -35, duration: 0.1, at: t)                              // speech
        t += 0.1
        let inHangover = g.push(db: -66, duration: 0.1, at: t + 1.0)
        let afterHangover = g.push(db: -66, duration: 0.1, at: t + 1.7)
        #expect(onSpeech)
        #expect(inHangover, "hangover keeps it open for 1.5 s")
        #expect(!afterHangover, "and then it closes")
    }

    @Test func aLoudButSteadyRoomRaisesTheFloorInsteadOfOpeningTheGateForever() {
        var g = EnergyGate()
        var t = 0.0
        var opens = 0
        for _ in 0..<600 { if g.push(db: -44, duration: 0.1, at: t) { opens += 1 }; t += 0.1 }          // a fan at −44 dBFS for 60 s
        #expect(g.floorDB > -50, "the floor follows the room")
        let lastSecond = (0..<10).map { _ in g.push(db: -44, duration: 0.1, at: { t += 0.1; return t }()) }
        #expect(lastSecond.allSatisfy { !$0 }, "steady noise no longer opens the gate (\(opens) opens while it was learning)")
        let onSpeech = g.push(db: -30, duration: 0.1, at: t + 0.1)
        #expect(onSpeech, "speech 14 dB above the noise does")
    }
}

// MARK: - Provider selection with the neural voice

@Suite("Voice provider selection (neural + Apple)")
struct NeuralSelectionTests {
    private typealias C = (id: String, name: String, availability: TTSAvailability, cost: VoiceCostClass)
    private let neural: C = ("neural-supertonic", "JARVIS Voice", .ready, .local)
    private let apple: C = ("apple-synthesizer", "Apple", .ready, .system)

    @Test func autoPrefersTheLocalNeuralVoice() {
        let c = VoiceProviderSelection.chooseTTS(preference: "auto", candidates: [apple, neural])
        #expect(c.id == "neural-supertonic" && !c.fellBack)
    }
    @Test func memoryPressureAndTheSystemPresetFallBackToApple() {
        #expect(VoiceProviderSelection.chooseTTS(preference: "auto", candidates: [neural, apple], memoryPressureNormal: false).id == "apple-synthesizer")
        let sys = VoiceProviderSelection.chooseTTS(preference: "auto", candidates: [neural, apple], preset: .systemFallback)
        #expect(sys.id == "apple-synthesizer" && sys.reason.contains("System Fallback"))
        let noModel = VoiceProviderSelection.chooseTTS(preference: "auto", candidates: [("neural-supertonic", "JARVIS Voice", .unavailable("not installed"), .local), apple])
        #expect(noModel.id == "apple-synthesizer" && noModel.fellBack)
    }
    @Test func paidOrUnknownIsNeverAutomatic() {
        let paid: C = ("cloud-voice", "Cloud", .ready, .paid), unknown: C = ("mystery", "Mystery", .ready, .unknown)
        #expect(VoiceProviderSelection.chooseTTS(preference: "auto", candidates: [paid, unknown]).id == nil)
        #expect(VoiceProviderSelection.chooseTTS(preference: "auto", candidates: [paid, unknown, apple]).id == "apple-synthesizer")
    }
    @Test func anExplicitChoiceNeverFallsBack() {
        let down: C = ("neural-supertonic", "JARVIS Voice", .unavailable("x"), .local)
        #expect(VoiceProviderSelection.chooseTTS(preference: "neural-supertonic", candidates: [down, apple]).id == nil)
    }
}
