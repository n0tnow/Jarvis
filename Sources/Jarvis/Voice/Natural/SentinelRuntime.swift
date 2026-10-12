import Foundation
import Observation

/// The LOCAL wake-word detector + voice-activity detector (V0.8), served by the sentinel helper (`scripts/voice-ai/jarvis_sentinel_worker.py`).
///
/// Privacy: audio goes over the pipe to a process on this Mac, is kept in memory only for the few seconds the two models need, and nothing is ever
/// written to disk. There is no transcript, no STT, no network and no API key here. The helper exits when JARVIS does.
@MainActor
@Observable
final class SentinelRuntime {
    struct Config: Sendable {
        var executable: String
        var worker: String
        var modelsDirectory: String
        var workingDirectory: String
        var environment: [String: String]

        /// The layout created by `scripts/setup_voice_ai.sh --natural`.
        static func standard(paths: JarvisPaths, environmentBase: [String: String] = ProcessInfo.processInfo.environment) -> Config {
            var env = ProviderEnvironment.make(base: environmentBase)
            env["PYTHONDONTWRITEBYTECODE"] = "1"; env["HF_HUB_OFFLINE"] = "1"; env["OMP_NUM_THREADS"] = "1"
            return Config(executable: paths.runtime.appendingPathComponent("natural-venv/bin/python").path,
                          worker: paths.runtime.appendingPathComponent("jarvis_sentinel_worker.py").path,
                          modelsDirectory: paths.runtime.appendingPathComponent("wake").path,
                          workingDirectory: paths.runtime.path, environment: env)
        }
        static let modelFiles = ["melspectrogram.onnx", "embedding_model.onnx", "silero_vad.onnx", "jarvis_head.npz"]
    }

    struct Metrics: Equatable, Sendable {
        var framesSent = 0
        var secondsSent = 0.0
        var wakeEvents = 0
        var lastWakeScore: Double?
        var vadTransitions = 0
        var helperAudioSeconds: Double?
        var helperCPUSeconds: Double?
        var helperMaxScore: Double?
    }

    private(set) var metrics = Metrics()
    private(set) var vadSpeech = false
    let host: HelperHost
    @ObservationIgnored var onWake: ((Double) -> Void)?
    @ObservationIgnored var onVAD: ((Bool) -> Void)?
    @ObservationIgnored var onUnavailable: ((String) -> Void)?
    @ObservationIgnored var onEvent: ((String) -> Void)?
    @ObservationIgnored private var pending: [Float] = []
    @ObservationIgnored private var wakeOn = false
    @ObservationIgnored private var vadOn = false
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var wantRunning = false
    @ObservationIgnored private var statsWaiter: CheckedContinuation<Metrics, Never>?
    @ObservationIgnored private var lastPong = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var pingOutstanding = false
    /// Hang detection WITHOUT a timer that runs when idle: while audio flows, a ping goes out at most every 20 s and must be answered within 4 s.
    static let pingInterval: TimeInterval = 20
    static let pongTimeout: TimeInterval = 4
    static let messageSamples = 1600                       // 100 ms per message

    init(config: Config) {
        let files = Config.modelFiles.map { config.modelsDirectory + "/" + $0 }
        host = HelperHost(config: HelperConfig(name: "Wake", executable: config.executable, arguments: [config.worker, "--models", config.modelsDirectory],
                                               environment: config.environment, workingDirectory: config.workingDirectory,
                                               requiredPaths: [config.worker] + files, startTimeout: 30))
        host.onMessage = { [weak self] m in self?.handle(m) }
        host.onEvent = { [weak self] s in self?.onEvent?(s) }
        host.onUnexpectedExit = { [weak self] in self?.helperDied() }
    }

    var state: HelperState { host.state }
    var isAvailable: Bool { if case .notInstalled = host.state { return false }; return true }
    var isRunning: Bool { host.isRunning }

    func inspect() { host.inspect() }

    // MARK: Lifecycle

    /// Starts the helper (wake mode turned on). Throws when it is not installed or cannot start; nothing is downloaded.
    func start() async throws {
        wantRunning = true
        try await host.ensureStarted()
        lastPong = ProcessInfo.processInfo.systemUptime; pingOutstanding = false
        sendConfig()
    }

    func stop() async {
        wantRunning = false
        pending.removeAll()
        wakeOn = false; vadOn = false
        await host.stop()
    }

    func shutdownNow() {
        wantRunning = false
        pending.removeAll()
        host.shutdownNow()
    }

    private func helperDied() {
        guard wantRunning else { return }
        onEvent?("Wake helper stopped unexpectedly")
        Task { [weak self] in
            guard let self, self.wantRunning else { return }
            do { try await self.start() } catch { self.onUnavailable?("the wake helper keeps stopping") }
        }
    }

    // MARK: Control + audio

    /// Which of the two detectors should run right now (JARVIS speaking ⇒ wake off, so it can never wake itself).
    func setMode(wake: Bool, vad: Bool) {
        guard wake != wakeOn || vad != vadOn else { return }
        wakeOn = wake; vadOn = vad
        sendConfig()
    }

    private func sendConfig() {
        host.send(["op": "config", "wake": wakeOn, "vad": vadOn, "threshold": wakeThreshold, "patience": wakePatience])
    }

    /// Conservative production threshold (a missed wake is retried by saying it again; a false wake is a stranger in the conversation). Tunable in diagnostics.
    @ObservationIgnored var wakeThreshold = 0.9 { didSet { if host.isRunning { sendConfig() } } }
    @ObservationIgnored var wakePatience = 3 { didSet { if host.isRunning { sendConfig() } } }

    /// Forgets the helper's audio history (call after a gap in the stream so a word cannot straddle it).
    func resetStream() {
        pending.removeAll()
        host.send(["op": "reset"])
        if vadSpeech { vadSpeech = false }
    }

    func feed(_ frame: AudioFrame) {
        guard host.isRunning else { return }
        checkLiveness()
        pending.append(contentsOf: frame.samples)
        while pending.count >= Self.messageSamples {
            let chunk = Array(pending.prefix(Self.messageSamples))
            pending.removeFirst(Self.messageSamples)
            send(chunk)
        }
    }

    private func checkLiveness() {
        let now = ProcessInfo.processInfo.systemUptime
        guard !pingOutstanding, now - lastPong > Self.pingInterval else { return }
        pingOutstanding = true
        host.send(["op": "ping"])
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pongTimeout))
            guard let self, self.pingOutstanding, self.wantRunning else { return }
            self.pingOutstanding = false
            self.onEvent?("Wake helper did not answer — restarting it")
            self.host.shutdownNow()                                  // a hung helper is killed; the bounded restart policy brings it back
            self.helperDied()
        }
    }

    private func send(_ samples: [Float]) {
        var pcm = Data(count: samples.count * 2)
        pcm.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (i, s) in samples.enumerated() { out[i] = Int16(max(-1, min(1, s)) * 32767).littleEndian }
        }
        host.sendRaw(Data("{\"op\":\"audio\",\"pcm\":\"\(pcm.base64EncodedString())\"}\n".utf8))
        metrics.framesSent += 1
        metrics.secondsSent += Double(samples.count) / AudioFrame.sampleRate
    }

    /// Asks the helper for its own counters (CPU seconds, audio seconds, strongest wake score since the last call). Times out after 2 s.
    func requestStats() async -> Metrics {
        guard host.isRunning else { return metrics }
        return await withCheckedContinuation { cont in
            statsWaiter?.resume(returning: metrics)
            statsWaiter = cont
            host.send(["op": "stats"])
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                if let self, let w = self.statsWaiter { self.statsWaiter = nil; w.resume(returning: self.metrics) }
            }
        }
    }

    // MARK: Helper output (untrusted: only numbers and booleans are read; no helper text is ever shown or stored)

    private func handle(_ o: [String: Any]) {
        switch o["type"] as? String {
        case "wake":
            // only a real number in [0, 1] counts as a wake event; anything else the helper might say is dropped (never shown, stored or acted on)
            guard let score = (o["score"] as? NSNumber)?.doubleValue, score.isFinite, (0 ... 1).contains(score) else { return }
            metrics.wakeEvents += 1
            metrics.lastWakeScore = score
            onWake?(score)
        case "vad":
            let speech = (o["speech"] as? Bool) ?? false
            vadSpeech = speech
            metrics.vadTransitions += 1
            onVAD?(speech)
        case "pong":
            lastPong = ProcessInfo.processInfo.systemUptime; pingOutstanding = false
        case "stats":
            metrics.helperAudioSeconds = (o["audio_s"] as? NSNumber)?.doubleValue
            metrics.helperCPUSeconds = (o["cpu_s"] as? NSNumber)?.doubleValue
            metrics.helperMaxScore = (o["max_wake_score"] as? NSNumber)?.doubleValue
            if let w = statsWaiter { statsWaiter = nil; w.resume(returning: metrics) }
        default: break
        }
    }
}
