import Foundation
import Observation

// MARK: - State

/// Lifecycle of the local Whisper helper (V0.7). `idle` = installed but NOT loaded; it starts on demand and unloads when idle or under memory pressure.
enum WhisperRuntimeState: Equatable, Sendable {
    case runtimeMissing, modelMissing
    case idle, starting, ready, stopping
    case failed(String)

    var label: String {
        switch self {
        case .runtimeMissing: "NOT INSTALLED"
        case .modelMissing: "MODEL MISSING"
        case .idle: "READY · UNLOADED"
        case .starting: "STARTING"
        case .ready: "READY · LOADED"
        case .stopping: "STOPPING"
        case .failed: "FAILED"
        }
    }
    var isLoaded: Bool { self == .ready }
}

/// Measured values only.
struct WhisperMetrics: Equatable, Sendable {
    var loadSeconds: Double?
    var lastFinalDecodeSeconds: Double?
    var lastAudioSeconds: Double?
    var lastPreviewDecodeSeconds: Double?
    var utterances = 0
    var starts = 0
    /// decode time / audio time of the last final decode (lower is faster; < 1 is faster than real time).
    var realTimeFactor: Double? {
        guard let d = lastFinalDecodeSeconds, let a = lastAudioSeconds, a > 0 else { return nil }
        return d / a
    }
}

struct WhisperRuntimeConfig: Sendable {
    var executable: String
    var arguments: [String]
    var modelPath: String
    var workerScript: String
    var workingDirectory: String
    var environment: [String: String]
    var idleUnloadSeconds: TimeInterval = 120
    var startTimeout: TimeInterval = 60
    var decodeTimeout: TimeInterval = 45

    /// The layout created by `scripts/setup_voice_ai.sh`.
    static func standard(paths: JarvisPaths, modelPath: String, environmentBase: [String: String] = ProcessInfo.processInfo.environment) -> WhisperRuntimeConfig {
        let python = paths.runtime.appendingPathComponent("voice-venv/bin/python").path
        let worker = paths.runtime.appendingPathComponent("jarvis_stt_worker.py").path
        var env = ProviderEnvironment.make(base: environmentBase)
        env["HF_HUB_OFFLINE"] = "1"; env["TRANSFORMERS_OFFLINE"] = "1"; env["PYTHONDONTWRITEBYTECODE"] = "1"
        return WhisperRuntimeConfig(executable: python, arguments: [worker, "--model", modelPath], modelPath: modelPath, workerScript: worker,
                                    workingDirectory: paths.runtime.path, environment: env)
    }

    static let defaultModelPath = NSHomeDirectory() + "/AI/models/whisper-small-mlx"
}

struct WhisperFinal: Sendable {
    var text: String
    var language: String?
    var confidence: Double?
    var decodeSeconds: Double?
    var audioSeconds: Double?
}

// MARK: - Runtime

/// Starts, serves and unloads the Whisper helper. Audio travels over the pipe and lives only in the helper's memory for the length of ONE
/// utterance; nothing is ever written to disk. The helper exits by itself if JARVIS dies (stdin EOF) and `ProcessRegistry` kills it on quit.
@MainActor
@Observable
final class WhisperRuntime {
    private(set) var state: WhisperRuntimeState = .runtimeMissing
    private(set) var metrics = WhisperMetrics()
    private(set) var workerPID: pid_t?
    @ObservationIgnored let config: WhisperRuntimeConfig

    @ObservationIgnored private var process: ManagedProcess?
    @ObservationIgnored private var startWaiters: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var idleTimer: Task<Void, Never>?
    @ObservationIgnored private var utterances: [String: Utterance] = [:]
    @ObservationIgnored var idleUnloadProvider: (() -> TimeInterval)?
    /// Lifecycle events only (loaded, unloaded, crashed) — never audio, never text.
    @ObservationIgnored var onEvent: ((String) -> Void)?

    private final class Utterance {
        var onPartial: ((String, String?) -> Void)?
        var finalWaiter: CheckedContinuation<WhisperFinal, Error>?
        var previewInFlight = false
        var watchdog: Task<Void, Never>?
    }

    init(config: WhisperRuntimeConfig) { self.config = config; inspect() }

    // MARK: Inspection (no process is started)

    func inspect() {
        switch state { case .starting, .ready, .stopping, .failed: return; default: break }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: config.executable), fm.fileExists(atPath: config.workerScript) else { state = .runtimeMissing; return }
        let hasConfig = fm.fileExists(atPath: config.modelPath + "/config.json")
        let weights = ((try? fm.contentsOfDirectory(atPath: config.modelPath)) ?? []).contains { $0.hasPrefix("weights.") }
        guard hasConfig, weights else { state = .modelMissing; return }
        state = .idle
    }

    var hasActiveUtterance: Bool { !utterances.isEmpty }

    // MARK: Start / stop

    func ensureStarted() async throws {
        idleTimer?.cancel()
        switch state {
        case .ready:
            if process?.isRunning == true { return }
            markCrashed("helper not running")
        case .starting:
            if await waitReady(timeout: config.startTimeout) { return }
            throw VoiceError.sttUnavailable("the speech helper did not start in time")
        case .stopping: while state == .stopping { try? await Task.sleep(for: .milliseconds(20)) }
        case .failed: state = .idle; inspect()
        default: break
        }
        inspect()
        guard state == .idle else { throw VoiceError.sttUnavailable(state.label.lowercased()) }

        state = .starting
        metrics.starts += 1
        generation += 1
        let mine = generation
        let proc = ManagedProcess(executable: config.executable, arguments: config.arguments, environment: config.environment, workingDirectory: config.workingDirectory)
        let stream: AsyncStream<Data>
        do { stream = try proc.start(stdin: nil, keepStdinOpen: true) } catch { state = .failed("launch failed"); throw VoiceError.sttUnavailable("the speech helper could not be started") }
        process = proc
        workerPID = proc.processIdentifier
        Task { [weak self] in
            for await line in stream { self?.handle(line: line, generation: mine) }
            await self?.processEnded(proc, generation: mine)
        }
        if await waitReady(timeout: config.startTimeout) { onEvent?("Speech helper loaded (\(String(format: "%.1f", metrics.loadSeconds ?? 0)) s)"); return }
        await proc.cancel()
        if process === proc { process = nil; workerPID = nil }
        state = .failed("start timed out or helper exited")
        throw VoiceError.sttUnavailable("the speech helper did not start")
    }

    /// Controlled unload (idle timer, memory pressure). Does nothing while an utterance is in flight.
    func unload() async {
        guard state == .ready, utterances.isEmpty, let proc = process else { return }
        idleTimer?.cancel()
        state = .stopping
        proc.send(Data("{\"op\":\"shutdown\"}\n".utf8))
        proc.closeStdin()
        let exited = await Task.detached { () -> Bool in
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline { if !proc.isRunning { return true }; try? await Task.sleep(for: .milliseconds(25)) }
            return !proc.isRunning
        }.value
        if !exited { await proc.cancel() }
        if process === proc { process = nil; workerPID = nil }
        generation += 1
        state = .idle
        onEvent?("Speech helper unloaded")
    }

    /// Synchronous kill for application termination / tests: no helper may outlive JARVIS.
    func shutdownNow() {
        idleTimer?.cancel()
        failAll(VoiceError.cancelled)
        process?.killTreeNow()
        process = nil; workerPID = nil
        if state == .ready || state == .starting || state == .stopping { state = .idle }
        generation += 1
    }

    private func scheduleIdleUnload() {
        idleTimer?.cancel()
        let seconds = idleUnloadProvider?() ?? config.idleUnloadSeconds
        guard seconds > 0 else { return }
        let gen = generation
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.generation == gen, self.utterances.isEmpty, self.state == .ready else { return }
            await self.unload()
        }
    }

    // MARK: Utterances

    func begin(id: String, language: String?, prompt: String, onPartial: @escaping (String, String?) -> Void) async throws {
        try await ensureStarted()
        guard let proc = process, proc.isRunning else { throw VoiceError.sttUnavailable("the speech helper is not running") }
        let u = Utterance(); u.onPartial = onPartial
        utterances[id] = u
        proc.send(Self.line(["op": "begin", "id": id, "language": (language as Any?) ?? NSNull(), "prompt": prompt]))
    }

    func append(id: String, samples: [Float]) {
        guard utterances[id] != nil, let proc = process, proc.isRunning, !samples.isEmpty else { return }
        var pcm = Data(count: samples.count * 2)
        pcm.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (i, s) in samples.enumerated() { out[i] = Int16(max(-1, min(1, s)) * 32767).littleEndian }
        }
        proc.send(Data("{\"op\":\"audio\",\"id\":\"\(id)\",\"pcm\":\"\(pcm.base64EncodedString())\"}\n".utf8))
    }

    /// Asks for a preview decode unless one is already running (at most one outstanding).
    func requestPreview(id: String) {
        guard let u = utterances[id], !u.previewInFlight, let proc = process, proc.isRunning else { return }
        u.previewInFlight = true
        proc.send(Self.line(["op": "preview", "id": id]))
    }

    func finish(id: String) async throws -> WhisperFinal {
        guard let u = utterances[id], let proc = process, proc.isRunning else { throw VoiceError.sttFailed("the speech helper is not running") }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<WhisperFinal, Error>) in
            u.finalWaiter = cont
            proc.send(Self.line(["op": "finish", "id": id]))
            let timeout = config.decodeTimeout
            u.watchdog = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled, let self, let u = self.utterances[id], let c = u.finalWaiter else { return }
                u.finalWaiter = nil
                self.utterances[id] = nil
                c.resume(throwing: VoiceError.sttFailed("recognition timed out"))
                await self.process?.cancel()                           // a hung helper is killed; it restarts on demand
            }
        }
    }

    func cancel(id: String) {
        guard let u = utterances.removeValue(forKey: id) else { return }
        u.watchdog?.cancel()
        process?.send(Self.line(["op": "cancel", "id": id]))
        if let c = u.finalWaiter { u.finalWaiter = nil; c.resume(throwing: VoiceError.cancelled) }
        if utterances.isEmpty { scheduleIdleUnload() }
    }

    private static func line(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)).map { $0 + Data("\n".utf8) } ?? Data("\n".utf8)
    }

    // MARK: Helper output (untrusted: text passes through `TranscriptText.clean` before anything else sees it)

    private func handle(line: Data, generation gen: Int) {
        guard gen == generation, let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        func num(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        let id = o["id"] as? String
        switch o["type"] as? String {
        case "ready":
            metrics.loadSeconds = num("load_seconds")
            state = .ready
            resolveStart(true)
            if utterances.isEmpty { scheduleIdleUnload() }
        case "partial":
            guard let id, let u = utterances[id] else { return }
            u.previewInFlight = false
            metrics.lastPreviewDecodeSeconds = num("decode_seconds")
            let text = TranscriptText.clean((o["text"] as? String) ?? "")
            if !text.isEmpty { u.onPartial?(text, o["language"] as? String) }
        case "final":
            guard let id, let u = utterances.removeValue(forKey: id) else { return }
            u.watchdog?.cancel()
            metrics.lastFinalDecodeSeconds = num("decode_seconds"); metrics.lastAudioSeconds = num("audio_seconds"); metrics.utterances += 1
            let result = WhisperFinal(text: TranscriptText.clean((o["text"] as? String) ?? ""), language: o["language"] as? String, confidence: num("confidence"),
                                      decodeSeconds: num("decode_seconds"), audioSeconds: num("audio_seconds"))
            if let c = u.finalWaiter { u.finalWaiter = nil; c.resume(returning: result) }
            if utterances.isEmpty { scheduleIdleUnload() }
        case "error":
            if let id, let u = utterances.removeValue(forKey: id) {
                u.watchdog?.cancel()
                if let c = u.finalWaiter { u.finalWaiter = nil; c.resume(throwing: VoiceError.sttFailed("the recogniser reported an error")) }
            } else if state == .starting { resolveStart(false) }
        default: break
        }
    }

    private func processEnded(_ proc: ManagedProcess, generation gen: Int) async {
        let code = await proc.waitForExit()
        guard gen == generation else { return }
        let wasStarting = state == .starting
        if state == .stopping { return }
        resolveStart(false)
        failAll(VoiceError.sttFailed("the speech helper stopped"))
        if process === proc { process = nil; workerPID = nil }
        if proc.wasCancelled && !wasStarting { generation += 1; state = .idle; onEvent?("Speech helper stopped"); return }
        if wasStarting { state = .failed("helper exited while starting (\(code))") } else { markCrashed("helper exited (\(code))") }
    }

    private func markCrashed(_ why: String) {
        generation += 1
        state = .failed(why)
        process = nil; workerPID = nil
        failAll(VoiceError.sttFailed("the speech helper stopped"))
        onEvent?("Speech helper stopped unexpectedly")
    }

    private func failAll(_ error: Error) {
        let all = utterances; utterances = [:]
        for (_, u) in all { u.watchdog?.cancel(); if let c = u.finalWaiter { u.finalWaiter = nil; c.resume(throwing: error) } }
    }

    private func waitReady(timeout: TimeInterval) async -> Bool {
        if state == .ready { return true }
        return await withCheckedContinuation { cont in
            startWaiters.append(cont)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.resolveStart(false)
            }
        }
    }
    private func resolveStart(_ ok: Bool) { let w = startWaiters; startWaiters = []; for c in w { c.resume(returning: ok) } }

    /// Resident memory of the helper right now (bytes), for reporting. NOT attributed to JARVIS' own process.
    var workerResidentBytes: UInt64? { workerPID.flatMap { ProcessTree.residentBytes(of: $0) } }
}

// MARK: - Provider

/// Whisper (MLX) on this Mac: best measured accuracy for Turkish, English and technical vocabulary, REAL language detection (Turkish/English),
/// but not natively streaming — while the key is held JARVIS re-decodes the audio so far to show a preview, then decodes the full utterance at release.
@MainActor
final class WhisperSTTProvider: SpeechToTextProvider {
    let id = "whisper-local"
    let displayName = "Whisper (local, MLX)"
    let runtime: WhisperRuntime
    private(set) var state: STTState = .ready
    let capabilities = STTCapabilities(languages: [.turkish, .english], partials: .incrementalRedecode, autoDetectsLanguage: true, exposesConfidence: true,
                                       costClass: .local, needsNetwork: false, runtime: "JARVIS helper process (MLX, Apple silicon GPU)")

    init(runtime: WhisperRuntime) { self.runtime = runtime }

    func availability(for language: VoiceLanguage) async -> STTAvailability {
        runtime.inspect()
        switch runtime.state {
        case .idle, .ready, .starting, .stopping: return .ready
        case .runtimeMissing: return .needsSetup("Not installed. Press Set Up in System & Readiness (downloads a ≈460 MB model once; development builds: scripts/setup_voice_ai.sh).")
        case .modelMissing: return .needsSetup("The Whisper model is missing at \(runtime.config.modelPath). Press Set Up in System & Readiness (development builds: scripts/setup_voice_ai.sh).")
        case .failed(let why): return .unavailable("The speech helper failed (\(why)). It restarts on the next use.")
        }
    }

    func makeSession(language: VoiceLanguage) async throws -> STTSession {
        state = .starting
        let session = WhisperSession(runtime: runtime, language: language) { [weak self] s in self?.state = s }
        do { try await session.open() } catch { state = .error("\(error)"); throw error }
        state = .listening
        return session
    }

    func unload() async { await runtime.unload() }
    func shutdownNow() { runtime.shutdownNow(); state = .ready }
}

@MainActor
final class WhisperSession: STTSession {
    let events: AsyncStream<SpeechTranscriptEvent>
    private let continuation: AsyncStream<SpeechTranscriptEvent>.Continuation
    private let runtime: WhisperRuntime
    private let id = UUID().uuidString
    private let language: String?
    private let report: (STTState) -> Void
    private var audioSeconds = 0.0
    private var lastPreviewAt = Date.distantPast
    private var ended = false
    static let firstPreviewSeconds = 1.0
    static let previewInterval: TimeInterval = 1.2

    init(runtime: WhisperRuntime, language: VoiceLanguage, report: @escaping (STTState) -> Void) {
        self.runtime = runtime
        self.language = language == .auto ? nil : language.rawValue
        self.report = report
        (events, continuation) = AsyncStream<SpeechTranscriptEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    func open() async throws {
        let cont = continuation
        try await runtime.begin(id: id, language: language, prompt: VoiceVocabulary.prompt) { text, lang in
            cont.yield(SpeechTranscriptEvent(text: text, isFinal: false, language: lang, confidence: nil))
        }
    }

    func append(_ frame: AudioFrame) {
        guard !ended else { return }
        audioSeconds += frame.seconds
        runtime.append(id: id, samples: frame.samples)
        // Preview decodes piggyback on audio frames (10 per second): no timer exists.
        if audioSeconds >= Self.firstPreviewSeconds, Date().timeIntervalSince(lastPreviewAt) >= Self.previewInterval {
            lastPreviewAt = Date()
            runtime.requestPreview(id: id)
        }
    }

    func finish() async throws -> SpeechTranscriptEvent? {
        guard !ended else { return nil }
        ended = true
        report(.finalizing)
        defer { continuation.finish(); report(.ready) }
        let result = try await runtime.finish(id: id)
        return result.text.isEmpty ? nil : SpeechTranscriptEvent(text: result.text, isFinal: true, language: result.language, confidence: result.confidence)
    }

    func requestPreview() {
        guard !ended, audioSeconds >= 0.5 else { return }
        lastPreviewAt = Date()
        runtime.requestPreview(id: id)
    }

    func cancel() {
        guard !ended else { return }
        ended = true
        runtime.cancel(id: id)
        continuation.finish()
        report(.ready)
    }
}
