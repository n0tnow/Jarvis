import Foundation
import Observation

/// The local neural voice (V0.8): Supertonic 3 (ONNX Runtime, CPU) in a JARVIS-supervised helper process.
///
/// Truthful category: INCREMENTAL CHUNK TTS — the model synthesises one complete phrase per request (it is not a streaming model); JARVIS sends stable
/// phrases from the response stream while the rest of the answer is still being generated, and plays each phrase's audio block by block as the helper returns it.
/// Offline (the model folder is read from disk; the helper has no network code and never downloads), key-less, free; started on demand, unloaded when idle
/// or under memory pressure, killed with its process tree at quit.
@MainActor
@Observable
final class NeuralVoiceRuntime {
    struct Config: Sendable {
        var executable: String
        var worker: String
        var modelDirectory: String
        var workingDirectory: String
        var environment: [String: String]
        var idleUnloadSeconds: TimeInterval = 180
        var requestTimeout: TimeInterval = 40

        static let defaultModelDirectory = NSHomeDirectory() + "/AI/models/supertonic-3"
        static let requiredModelFiles = ["onnx/duration_predictor.onnx", "onnx/text_encoder.onnx", "onnx/vector_estimator.onnx", "onnx/vocoder.onnx",
                                         "onnx/unicode_indexer.json", "onnx/tts.json", "voice_styles/M5.json", "voice_styles/M3.json"]

        /// The layout created by `scripts/setup_voice_ai.sh --natural`.
        static func standard(paths: JarvisPaths, modelDirectory: String = defaultModelDirectory, environmentBase: [String: String] = ProcessInfo.processInfo.environment) -> Config {
            var env = ProviderEnvironment.make(base: environmentBase)
            env["PYTHONDONTWRITEBYTECODE"] = "1"; env["HF_HUB_OFFLINE"] = "1"
            env["SUPERTONIC_INTRA_OP_THREADS"] = "2"; env["SUPERTONIC_INTER_OP_THREADS"] = "1"
            return Config(executable: paths.runtime.appendingPathComponent("natural-venv/bin/python").path,
                          worker: paths.runtime.appendingPathComponent("jarvis_tts_worker.py").path,
                          modelDirectory: modelDirectory, workingDirectory: paths.runtime.path, environment: env)
        }
    }

    struct Metrics: Equatable, Sendable {
        var phrases = 0
        var loadSeconds: Double?
        var lastSynthSeconds: Double?
        var lastAudioSeconds: Double?
        var lastFirstBlockSeconds: Double?       // request → first audio block back in JARVIS
        var realTimeFactor: Double? { guard let s = lastSynthSeconds, let a = lastAudioSeconds, a > 0 else { return nil }; return s / a }
    }

    private final class Request {
        let continuation: AsyncThrowingStream<PCMBlock, Error>.Continuation
        let started = Date()
        var firstBlock = false
        var watchdog: Task<Void, Never>?
        init(_ c: AsyncThrowingStream<PCMBlock, Error>.Continuation) { continuation = c }
    }

    private(set) var metrics = Metrics()
    let host: HelperHost
    @ObservationIgnored let config: Config
    @ObservationIgnored private var requests: [String: Request] = [:]
    @ObservationIgnored private var idleTimer: Task<Void, Never>?
    @ObservationIgnored var idleUnloadProvider: (() -> TimeInterval)?
    @ObservationIgnored var onEvent: ((String) -> Void)?

    init(config: Config) {
        self.config = config
        let required = [config.worker] + Config.requiredModelFiles.map { config.modelDirectory + "/" + $0 }
        host = HelperHost(config: HelperConfig(name: "Neural voice", executable: config.executable, arguments: [config.worker, "--model-dir", config.modelDirectory],
                                               environment: config.environment, workingDirectory: config.workingDirectory, requiredPaths: required, startTimeout: 60))
        host.onMessage = { [weak self] m in self?.handle(m) }
        host.onEvent = { [weak self] s in self?.onEvent?(s) }
        host.onUnexpectedExit = { [weak self] in self?.failAll(VoiceError.ttsUnavailable("the neural voice helper stopped")) }
    }

    var state: HelperState { host.state }
    func inspect() { host.inspect() }

    // MARK: Synthesis

    func synthesize(id: Int, text: String, language: VoiceLanguage, parameters: NeuralVoiceParameters, tailMilliseconds: Int) -> AsyncThrowingStream<PCMBlock, Error> {
        AsyncThrowingStream { continuation in
            let req = Request(continuation)
            let key = String(id)
            requests[key] = req
            continuation.onTermination = { [weak self] reason in
                Task { @MainActor in
                    guard let self, self.requests[key] === req else { return }
                    self.requests[key] = nil
                    req.watchdog?.cancel()
                    if case .cancelled = reason { self.host.send(["op": "cancel", "id": key]) }
                }
            }
            Task { [weak self] in
                guard let self else { return }
                self.idleTimer?.cancel()
                do { try await self.host.ensureStarted() } catch {
                    if self.requests[key] === req { self.requests[key] = nil; continuation.finish(throwing: error) }
                    return
                }
                guard self.requests[key] === req else { return }                  // cancelled while the helper was starting
                self.host.send(["op": "synth", "id": key, "text": text, "lang": language == .turkish ? "tr" : "en", "style": parameters.style,
                                "speed": parameters.speed, "steps": parameters.steps, "tail_ms": tailMilliseconds])
                let timeout = self.config.requestTimeout
                req.watchdog = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled, let self, self.requests[key] === req else { return }
                    self.requests[key] = nil
                    continuation.finish(throwing: VoiceError.ttsUnavailable("the neural voice timed out"))
                    self.host.shutdownNow()                                         // a hung helper is killed; it restarts on demand
                }
            }
        }
    }

    func cancelAll() {
        let all = requests; requests = [:]
        for (id, r) in all { r.watchdog?.cancel(); host.send(["op": "cancel", "id": id]); r.continuation.finish() }
        if host.isRunning { scheduleIdleUnload() }
    }

    // MARK: Helper output (untrusted: only audio and numbers are read)

    private func handle(_ o: [String: Any]) {
        func num(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        guard let id = o["id"] as? String else { return }
        switch o["type"] as? String {
        case "audio":
            guard let r = requests[id], let b64 = o["pcm"] as? String, let data = Data(base64Encoded: b64), let rate = num("rate"), rate >= 8000, rate <= 96000 else { return }
            let n = data.count / 2
            var samples = [Float](repeating: 0, count: n)
            data.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: Int16.self)
                for i in 0..<n { samples[i] = Float(Int16(littleEndian: p[i])) / 32768.0 }
            }
            if !r.firstBlock { r.firstBlock = true; metrics.lastFirstBlockSeconds = Date().timeIntervalSince(r.started) }
            r.continuation.yield(PCMBlock(samples: samples, sampleRate: rate))
        case "done":
            guard let r = requests.removeValue(forKey: id) else { return }
            r.watchdog?.cancel()
            metrics.phrases += 1; metrics.lastSynthSeconds = num("synth_seconds"); metrics.lastAudioSeconds = num("audio_seconds")
            r.continuation.finish()
            if requests.isEmpty { scheduleIdleUnload() }
        case "error":
            guard let r = requests.removeValue(forKey: id) else { return }
            r.watchdog?.cancel()
            r.continuation.finish(throwing: VoiceError.ttsUnavailable("the neural voice reported an error"))
        default: break
        }
    }

    private func failAll(_ error: Error) {
        let all = requests; requests = [:]
        for (_, r) in all { r.watchdog?.cancel(); r.continuation.finish(throwing: error) }
    }

    // MARK: Unload

    private func scheduleIdleUnload() {
        idleTimer?.cancel()
        let seconds = idleUnloadProvider?() ?? config.idleUnloadSeconds
        guard seconds > 0 else { return }
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.requests.isEmpty else { return }
            await self.unload()
        }
    }

    /// Idle timer / memory pressure. Does nothing while a phrase is being synthesised.
    func unload() async {
        guard requests.isEmpty, host.state == .running else { return }
        idleTimer?.cancel()
        await host.stop()
    }

    func shutdownNow() {
        idleTimer?.cancel()
        failAll(VoiceError.cancelled)
        host.shutdownNow()
    }
}

/// Neural synthesis as a `PCMSynthesizing` engine. The voice comes from the JARVIS Voice Identity preset (`VoiceIdentityMapper`), never from a per-voice picker.
@MainActor
final class NeuralSpeechEngine: PCMSynthesizing {
    let runtime: NeuralVoiceRuntime
    /// Current preset (set by the coordinator from Settings).
    var preset: () -> JarvisVoicePreset = { .jarvisDefault }
    private var activeIDs: Set<Int> = []

    init(runtime: NeuralVoiceRuntime) { self.runtime = runtime }

    func availability() -> TTSAvailability {
        runtime.inspect()
        switch runtime.state {
        case .notInstalled(let why): return .unavailable("Not installed (\(why)). Press Set Up in System & Readiness (development builds: scripts/setup_voice_ai.sh --natural).")
        case .failed(let why): return .unavailable("The neural voice failed (\(why)). It restarts on the next use.")
        default: return .ready
        }
    }

    func voices() -> [VoiceDescriptor] { [] }

    func synthesize(_ chunk: SpeechChunk, voice: VoiceDescriptor?, rate: Double) -> AsyncThrowingStream<PCMBlock, Error> {
        guard let params = VoiceIdentityMapper.neural(preset: preset(), rate: rate) else {
            return AsyncThrowingStream { $0.finish(throwing: VoiceError.ttsUnavailable("no neural preset is selected")) }
        }
        activeIDs.insert(chunk.id)
        let last = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).last
        let tail = (last.map { ".!?…".contains($0) } ?? true) ? 160 : 70           // a sentence end breathes a little longer than a clause break
        return runtime.synthesize(id: chunk.id, text: chunk.text, language: chunk.language, parameters: params, tailMilliseconds: tail)
    }

    func cancelAll() { activeIDs.removeAll(); runtime.cancelAll() }
    func shutdownNow() { activeIDs.removeAll(); runtime.shutdownNow() }
}

/// The preferred JARVIS voice: local neural synthesis behind JARVIS' own player. Falls back to Apple system voices when unavailable (see `VoiceProviderSelection`).
@MainActor
final class NeuralSpeechProvider: PlayerBackedTTSProvider {
    var outputVolume: Float = 1.0 { didSet { (player as? SpeechPlayer)?.volume = outputVolume } }
    let runtime: NeuralVoiceRuntime

    init(runtime: NeuralVoiceRuntime, preset: @escaping () -> JarvisVoicePreset, player: (any PCMPlayback)? = nil) {
        self.runtime = runtime
        let engine = NeuralSpeechEngine(runtime: runtime)
        engine.preset = preset
        super.init(id: "neural-supertonic", displayName: "JARVIS Voice (Supertonic 3, local)",
                   capabilities: TTSCapabilities(languages: [.turkish, .english], streaming: .chunked, selectableVoices: false, costClass: .local,
                                                 needsNetwork: false, runtime: "JARVIS helper process (ONNX Runtime, CPU) + JARVIS audio player"),
                   engine: engine, player: player ?? SpeechPlayer())
    }
}
