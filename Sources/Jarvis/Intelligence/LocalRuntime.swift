import Foundation
import Observation

// MARK: - State

/// Lifecycle of the on-device model (V0.3.1 §16). `idle` = installed but NOT loaded (starts on demand);
/// `ready` = worker alive with the model in memory; `running` = a job is generating.
enum LocalRuntimeState: Equatable, Sendable {
    case notConfigured, modelMissing, runtimeMissing
    case idle, starting, ready, running, stopping
    case unavailable(String), failed(String)

    var label: String {
        switch self {
        case .notConfigured: "NOT CONFIGURED"
        case .modelMissing: "MODEL MISSING"
        case .runtimeMissing: "RUNTIME MISSING"
        case .idle: "READY · UNLOADED"
        case .starting: "STARTING"
        case .ready: "READY · LOADED"
        case .running: "RUNNING"
        case .stopping: "STOPPING"
        case .unavailable: "UNAVAILABLE"
        case .failed: "FAILED"
        }
    }

    /// The router may pick the local engine (it will start the worker on demand).
    var isUsableForRouting: Bool { self == .idle || self == .ready }
    var isLoaded: Bool { self == .ready || self == .running }
}

/// Measured values only — nothing here is estimated.
struct LocalRuntimeMetrics: Equatable, Sendable {
    var loadSeconds: Double?
    var firstTokenSeconds: Double?
    var generationTokensPerSecond: Double?
    var promptTokensPerSecond: Double?
    var peakMemoryGB: Double?
    var lastJobTokens: Int?
    var jobsCompleted = 0
    var startsAttempted = 0
}

struct LocalRuntimeConfig: Sendable {
    var executable: String                  // venv python
    var arguments: [String]                 // [worker.py, "--model", modelPath]
    var modelPath: String
    var workerScript: String
    var workingDirectory: String
    var environment: [String: String]
    var idleUnloadSeconds: TimeInterval = 300
    var startTimeout: TimeInterval = 90
    var cancelGrace: TimeInterval = 2
    var jobIdleTimeout: TimeInterval = 60   // no token for this long ⇒ the job is considered hung

    /// The standard layout created by `scripts/setup_local_ai.sh`.
    static func standard(paths: JarvisPaths, modelPath: String, environmentBase: [String: String] = ProcessInfo.processInfo.environment) -> LocalRuntimeConfig {
        let python = paths.runtime.appendingPathComponent("mlx-venv/bin/python").path
        let worker = paths.runtime.appendingPathComponent("jarvis_local_worker.py").path
        var env = ProviderEnvironment.make(base: environmentBase)
        env["HF_HUB_OFFLINE"] = "1"; env["TRANSFORMERS_OFFLINE"] = "1"; env["PYTHONDONTWRITEBYTECODE"] = "1"
        return LocalRuntimeConfig(executable: python, arguments: [worker, "--model", modelPath], modelPath: modelPath, workerScript: worker,
                                  workingDirectory: paths.runtime.path, environment: env)
    }

    static let defaultModelPath = NSHomeDirectory() + "/AI/models/Qwen3.5-4B-MLX-4bit"
}

enum LocalEvent: Sendable, Equatable {
    case token(String)
    case done(LocalJobStats)
}

struct LocalJobStats: Sendable, Equatable {
    var promptTokens: Int?
    var generationTokens: Int?
    var promptTPS: Double?
    var generationTPS: Double?
    var firstTokenSeconds: Double?
    var peakMemoryGB: Double?
    var cancelled = false
}

// MARK: - Runtime

/// Starts, health-checks, serves and unloads the local model worker. ONE job at a time (`maxLocalInferenceJobs` = 1 on a
/// 16 GB machine). The user never starts anything by hand: `generate` starts the worker on demand and an idle timer
/// unloads it again. The worker exits by itself if JARVIS dies (stdin EOF); `ProcessRegistry` kills it on app quit.
@MainActor
@Observable
final class LocalRuntime {
    private(set) var state: LocalRuntimeState = .notConfigured
    private(set) var metrics = LocalRuntimeMetrics()
    private(set) var workerPID: pid_t?
    @ObservationIgnored let config: LocalRuntimeConfig

    @ObservationIgnored private var process: ManagedProcess?
    @ObservationIgnored private var startWaiters: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored private var pongWaiters: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored private var job: Job?
    @ObservationIgnored private var idleTimer: Task<Void, Never>?
    @ObservationIgnored private var generation = 0                 // identifies the current worker process
    /// Lets Settings change the idle-unload time at runtime (falls back to `config`).
    @ObservationIgnored var idleUnloadProvider: (() -> TimeInterval)?
    /// Called for meaningful lifecycle events (loaded, unloaded, crashed) — never per token.
    @ObservationIgnored var onEvent: ((String) -> Void)?
    /// Called when the worker dies unexpectedly (supervisor records the failure).
    @ObservationIgnored var onCrash: ((String) -> Void)?

    private struct Job {
        let id: String
        let continuation: AsyncThrowingStream<LocalEvent, Error>.Continuation
        var lastActivity = Date()
        var finish: CheckedContinuation<Void, Never>?
        var tokens = 0
    }

    init(config: LocalRuntimeConfig) { self.config = config; inspect() }

    // MARK: Inspection (no process is started)

    /// Looks at the files only. Does not touch a running worker.
    func inspect() {
        switch state { case .starting, .ready, .running, .stopping, .failed: return; default: break }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: config.executable), fm.fileExists(atPath: config.workerScript) else { state = .runtimeMissing; return }
        let model = config.modelPath
        let hasConfig = fm.fileExists(atPath: model + "/config.json")
        let weights = ((try? fm.contentsOfDirectory(atPath: model)) ?? []).contains { $0.hasSuffix(".safetensors") }
        guard hasConfig, weights else { state = .modelMissing; return }
        state = .idle
    }
    // MARK: Start / stop

    /// Ensures a healthy worker with the model loaded. Throws a typed error; never leaves a half-started process behind.
    func ensureStarted() async throws {
        switch state {
        case .ready, .running:
            if process?.isRunning == true { return }
            markCrashed("worker not running")                       // state said ready but the process is gone
        case .starting:
            if await waitReady(timeout: config.startTimeout) { return }
            throw ProviderError.timedOut(.local)
        case .stopping: await waitUntilStopped()
        case .failed: reset()                                      // supervisor cooldown decides WHEN; the runtime may start again
        default: break
        }
        inspect()
        guard state == .idle else { throw ProviderError.unavailable(.local, state.label.lowercased()) }

        state = .starting
        metrics.startsAttempted += 1
        generation += 1
        let myGeneration = generation
        let proc = ManagedProcess(executable: config.executable, arguments: config.arguments, environment: config.environment,
                                  workingDirectory: config.workingDirectory)
        let stream: AsyncStream<Data>
        do { stream = try proc.start(stdin: nil, keepStdinOpen: true) }
        catch { state = .failed("launch failed"); throw ProviderError.unavailable(.local, "launch failed") }
        process = proc
        workerPID = proc.processIdentifier
        Task { [weak self] in
            for await line in stream { self?.handle(line: line, generation: myGeneration) }
            await self?.processEnded(proc, generation: myGeneration)
        }
        if await waitReady(timeout: config.startTimeout) { onEvent?("Local Qwen started (\(String(format: "%.1f", metrics.loadSeconds ?? 0)) s)"); return }
        // Timeout or died while starting.
        await proc.cancel()
        if process === proc { process = nil; workerPID = nil }
        state = .failed("start timed out or worker exited")
        throw ProviderError.timedOut(.local)
    }

    /// Round-trip health check ("ping" → "pong").
    func healthCheck(timeout: TimeInterval = 5) async -> Bool {
        guard state == .ready, let proc = process, proc.isRunning else { return false }
        return await withCheckedContinuation { cont in
            pongWaiters.append(cont)
            proc.send(Data("{\"op\":\"ping\"}\n".utf8))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.resolvePong(false)
            }
        }
    }

    /// Unloads the model (controlled stop). No-op while a job runs.
    func unload() async {
        guard state == .ready, job == nil, let proc = process else { return }
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
        onEvent?("Local Qwen unloaded")
    }

    /// Synchronous kill (application termination / tests).
    func shutdownNow() {
        idleTimer?.cancel()
        process?.killTreeNow()
        process = nil; workerPID = nil
        if state.isLoaded || state == .starting || state == .stopping { state = .idle }
    }

    /// Resolves once no job is in flight (a cancelled consumer stops iterating at once; the worker acknowledges a moment later).
    func waitForJobEnd() async {
        while job != nil { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func waitUntilStopped() async {
        while state == .stopping { try? await Task.sleep(for: .milliseconds(20)) }
    }

    // MARK: Generation

    /// Streams tokens. Cancelling the consuming task asks the worker to stop (kills it if it doesn't within `cancelGrace`).
    func generate(prompt: String, maxTokens: Int, temperature: Double = 0) -> AsyncThrowingStream<LocalEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in await self.runJob(prompt: prompt, maxTokens: maxTokens, temperature: temperature, continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runJob(prompt: String, maxTokens: Int, temperature: Double, _ cont: AsyncThrowingStream<LocalEvent, Error>.Continuation) async {
        guard job == nil else { cont.finish(throwing: ProviderError.busy); return }
        if Task.isCancelled { cont.finish(throwing: CancellationError()); return }
        idleTimer?.cancel()
        do { try await ensureStarted() } catch { cont.finish(throwing: error); scheduleIdleUnload(); return }
        if Task.isCancelled { cont.finish(throwing: CancellationError()); scheduleIdleUnload(); return }
        guard let proc = process, proc.isRunning else { cont.finish(throwing: ProviderError.processFailed(.local, exitCode: -1)); return }

        let id = UUID().uuidString
        state = .running
        let req: [String: Any] = ["op": "generate", "id": id, "prompt": prompt, "max_tokens": maxTokens, "temperature": temperature]
        guard let data = try? JSONSerialization.data(withJSONObject: req) else { cont.finish(throwing: ProviderError.generic); state = .ready; return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (finish: CheckedContinuation<Void, Never>) in
                job = Job(id: id, continuation: cont, finish: finish)
                proc.send(data + Data("\n".utf8))
                startJobWatchdog(id: id, generation: generation)
            }
        } onCancel: {
            Task { @MainActor in self.cancelJob(id: id) }
        }
        scheduleIdleUnload()
    }

    private func cancelJob(id: String) {
        guard let j = job, j.id == id, let proc = process else { return }
        proc.send(Data("{\"op\":\"cancel\",\"id\":\"\(id)\"}\n".utf8))
        let gen = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.config.cancelGrace ?? 2))
            guard let self, self.generation == gen, self.job?.id == id else { return }
            await proc.cancel()                                  // worker didn't acknowledge: kill it (restarts on demand)
        }
    }

    private func startJobWatchdog(id: String, generation gen: Int) {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.generation == gen, let j = self.job, j.id == id else { return }
                if Date().timeIntervalSince(j.lastActivity) > self.config.jobIdleTimeout {
                    self.job?.continuation.finish(throwing: ProviderError.timedOut(.local))
                    await self.process?.cancel()
                    return
                }
            }
        }
    }

    // MARK: Worker output

    private func handle(line: Data, generation gen: Int) {
        guard gen == generation, let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        switch o["type"] as? String {
        case "ready":
            metrics.loadSeconds = (o["load_seconds"] as? NSNumber)?.doubleValue
            state = .ready
            resolveStart(true)
        case "pong": resolvePong(true)
        case "token":
            guard var j = job, j.id == (o["id"] as? String), let t = o["text"] as? String else { return }
            j.lastActivity = Date(); j.tokens += 1; job = j
            j.continuation.yield(.token(t))
        case "done":
            guard let j = job, j.id == (o["id"] as? String) else { return }
            func num(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
            func int(_ k: String) -> Int? { (o[k] as? NSNumber)?.intValue }
            let stats = LocalJobStats(promptTokens: int("prompt_tokens"), generationTokens: int("generation_tokens"), promptTPS: num("prompt_tps"),
                                      generationTPS: num("generation_tps"), firstTokenSeconds: num("first_token_seconds"),
                                      peakMemoryGB: num("peak_memory_gb"), cancelled: (o["cancelled"] as? Bool) ?? false)
            if !stats.cancelled {
                metrics.firstTokenSeconds = stats.firstTokenSeconds; metrics.generationTokensPerSecond = stats.generationTPS
                metrics.promptTokensPerSecond = stats.promptTPS; metrics.peakMemoryGB = stats.peakMemoryGB
                metrics.lastJobTokens = stats.generationTokens; metrics.jobsCompleted += 1
            }
            job = nil; state = .ready
            j.continuation.yield(.done(stats))
            if stats.cancelled { j.continuation.finish(throwing: CancellationError()) } else { j.continuation.finish() }
            j.finish?.resume()
        case "error":
            if let j = job, j.id == (o["id"] as? String) {
                job = nil; state = .ready
                j.continuation.finish(throwing: ProviderError.processFailed(.local, exitCode: 1))
                j.finish?.resume()
            } else if state == .starting {                       // load failed
                resolveStart(false)
            }
        default: break
        }
    }

    private func processEnded(_ proc: ManagedProcess, generation gen: Int) async {
        let code = await proc.waitForExit()
        guard gen == generation else { return }                  // an intentional stop already moved on
        let wasStarting = state == .starting
        if state == .stopping { return }
        resolveStart(false); resolvePong(false)
        if let j = job {
            job = nil
            let err: Error = proc.wasCancelled ? CancellationError() : ProviderError.processFailed(.local, exitCode: code)
            j.continuation.finish(throwing: err)
            j.finish?.resume()
        }
        if process === proc { process = nil; workerPID = nil }
        if proc.wasCancelled && !wasStarting {                   // WE killed it (cancel grace expired / watchdog): not a crash
            generation += 1; state = .idle; onEvent?("Local Qwen stopped"); return
        }
        if !wasStarting { markCrashed("worker exited (\(code))") }
        else { state = .failed("worker exited while starting (\(code))") }
    }

    private func markCrashed(_ why: String) {
        generation += 1
        state = .failed(why)
        process = nil; workerPID = nil
        onEvent?("Local Qwen stopped unexpectedly")
        onCrash?(why)
    }

    /// After a failure the runtime may be started again (the supervisor's cooldown decides WHEN); this re-arms it.
    func reset() { if case .failed = state { state = .idle; inspect() } }

    private func waitReady(timeout: TimeInterval) async -> Bool {
        if state == .ready || state == .running { return true }
        return await withCheckedContinuation { cont in
            startWaiters.append(cont)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.resolveStart(false)
            }
        }
    }
    private func resolveStart(_ ok: Bool) { let w = startWaiters; startWaiters = []; for c in w { c.resume(returning: ok) } }
    private func resolvePong(_ ok: Bool) { let w = pongWaiters; pongWaiters = []; for c in w { c.resume(returning: ok) } }

    private func scheduleIdleUnload() {
        idleTimer?.cancel()
        let seconds = idleUnloadProvider?() ?? config.idleUnloadSeconds
        guard seconds > 0 else { return }
        let gen = generation
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.generation == gen, self.job == nil, self.state == .ready else { return }
            await self.unload()
        }
    }

    /// Resident memory of the worker right now (bytes), for reporting.
    var workerResidentBytes: UInt64? { workerPID.flatMap { ProcessTree.residentBytes(of: $0) } }
}
