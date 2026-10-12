import Foundation
import Observation

/// Bounded restart policy for a helper that dies unexpectedly: at most `maxStarts` launches per `window`, then a cooldown. Pure and testable.
struct RestartBudget: Equatable, Sendable {
    var maxStarts = 3
    var window: TimeInterval = 600
    var cooldown: TimeInterval = 180
    private var starts: [TimeInterval] = []
    private(set) var blockedUntil: TimeInterval = -.infinity

    init(maxStarts: Int = 3, window: TimeInterval = 600, cooldown: TimeInterval = 180) { self.maxStarts = maxStarts; self.window = window; self.cooldown = cooldown }

    /// Records a launch attempt at `t` and says whether it may proceed.
    mutating func allowStart(at t: TimeInterval) -> Bool {
        if t < blockedUntil { return false }
        if blockedUntil.isFinite { starts.removeAll(); blockedUntil = -.infinity }          // the cooldown is over: a fresh budget
        starts.removeAll { t - $0 > window }
        if starts.count >= maxStarts { blockedUntil = t + cooldown; return false }
        starts.append(t)
        return true
    }
    mutating func reset() { starts.removeAll(); blockedUntil = -.infinity }
    var recentStarts: Int { starts.count }
}

enum HelperState: Equatable, Sendable {
    case notInstalled(String)       // runtime or model missing (nothing is started, nothing is downloaded)
    case idle                       // installed, not running
    case starting
    case running
    case stopping
    case failed(String)

    var label: String {
        switch self {
        case .notInstalled: "NOT INSTALLED"; case .idle: "READY · NOT RUNNING"; case .starting: "STARTING"; case .running: "RUNNING"
        case .stopping: "STOPPING"; case .failed: "FAILED"
        }
    }
    var isRunning: Bool { self == .running }
}

struct HelperConfig: Sendable {
    var name: String
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    var workingDirectory: String
    /// Files/folders that must exist for the helper to be considered installed (`inspect()` never starts anything).
    var requiredPaths: [String]
    var startTimeout: TimeInterval = 60
}

/// Supervises ONE long-lived helper process (V0.8: wake/VAD sentinel, neural voice). All helpers go through `ManagedProcess` (the audited launch point),
/// speak JSON lines, never download anything, exit when stdin closes and are killed with their tree at quit. Output is UNTRUSTED: consumers sanitise
/// whatever text they use. Mirrors the V0.7 `WhisperRuntime` lifecycle (on-demand start, controlled unload, crash → bounded restart).
@MainActor
@Observable
final class HelperHost {
    private(set) var state: HelperState = .idle
    private(set) var pid: pid_t?
    private(set) var startCount = 0
    private(set) var lastReady: [String: Any] = [:]
    private(set) var lastLoadSeconds: Double?
    @ObservationIgnored let config: HelperConfig
    @ObservationIgnored var budget = RestartBudget()
    /// Every protocol line of the running helper (already parsed). Called on the main actor.
    @ObservationIgnored var onMessage: (([String: Any]) -> Void)?
    /// Lifecycle activity (content-free).
    @ObservationIgnored var onEvent: ((String) -> Void)?
    /// The helper exited without being asked to.
    @ObservationIgnored var onUnexpectedExit: (() -> Void)?

    @ObservationIgnored private var process: ManagedProcess?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var waiters: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored private var waitToken = 0
    @ObservationIgnored private let clock: @Sendable () -> TimeInterval

    init(config: HelperConfig, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.config = config; self.clock = clock; inspect()
    }

    func inspect() {
        switch state { case .starting, .running, .stopping: return; default: break }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: config.executable) else { state = .notInstalled("runtime missing: \(config.executable)"); return }
        for p in config.requiredPaths where !fm.fileExists(atPath: p) { state = .notInstalled("missing: \(p)"); return }
        if case .failed = state { return }
        state = .idle
    }

    var isRunning: Bool { state == .running && process?.isRunning == true }

    // MARK: Start / stop

    func ensureStarted() async throws {
        switch state {
        case .running where process?.isRunning == true: return
        case .running: markCrashed("helper not running")
        case .starting:
            if await waitReady(config.startTimeout) { return }
            throw VoiceError.sttUnavailable("the \(config.name) helper did not start in time")
        case .stopping: while state == .stopping { try? await Task.sleep(for: .milliseconds(20)) }
        case .failed: state = .idle; inspect()
        default: break
        }
        inspect()
        guard state == .idle else { throw VoiceError.sttUnavailable("\(config.name): \(state.label.lowercased())") }
        guard budget.allowStart(at: clock()) else {
            state = .failed("restart limit reached; cooling down")
            throw VoiceError.sttUnavailable("the \(config.name) helper keeps stopping; it will be retried later")
        }
        state = .starting
        startCount += 1
        generation += 1
        let mine = generation
        let proc = ManagedProcess(executable: config.executable, arguments: config.arguments, environment: config.environment, workingDirectory: config.workingDirectory)
        let stream: AsyncStream<Data>
        do { stream = try proc.start(stdin: nil, keepStdinOpen: true) } catch { state = .failed("launch failed"); throw VoiceError.sttUnavailable("the \(config.name) helper could not be started") }
        process = proc; pid = proc.processIdentifier
        Task { [weak self] in
            for await line in stream { self?.handle(line, generation: mine) }
            await self?.ended(proc, generation: mine)
        }
        if await waitReady(config.startTimeout) { onEvent?("\(config.name) helper started (\(String(format: "%.1f", lastLoadSeconds ?? 0)) s)"); return }
        await proc.cancel()
        if process === proc { process = nil; pid = nil }
        state = .failed("start timed out or helper exited")
        throw VoiceError.sttUnavailable("the \(config.name) helper did not start")
    }

    /// Controlled stop: asks the helper to quit, kills it if it does not.
    func stop() async {
        guard state == .running || state == .starting, let proc = process else { return }
        state = .stopping
        proc.send(Data("{\"op\":\"shutdown\"}\n".utf8))
        proc.closeStdin()
        let exited = await Task.detached { () -> Bool in
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline { if !proc.isRunning { return true }; try? await Task.sleep(for: .milliseconds(25)) }
            return !proc.isRunning
        }.value
        if !exited { await proc.cancel() }
        if process === proc { process = nil; pid = nil }
        generation += 1
        state = .idle
        onEvent?("\(config.name) helper stopped")
    }

    /// Synchronous kill for application termination and tests: no helper may outlive JARVIS.
    func shutdownNow() {
        process?.killTreeNow()
        process = nil; pid = nil
        if state == .running || state == .starting || state == .stopping { state = .idle }
        generation += 1
        resolve(false)
    }

    func send(_ object: [String: Any]) {
        guard let proc = process, proc.isRunning, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        proc.send(data + Data("\n".utf8))
    }

    func sendRaw(_ data: Data) {
        guard let proc = process, proc.isRunning else { return }
        proc.send(data)
    }

    /// Resident memory right now (bytes) — reported separately, never attributed to JARVIS' own process.
    var residentBytes: UInt64? { pid.flatMap { ProcessTree.residentBytes(of: $0) } }
    var cpuSeconds: Double? { pid.flatMap { ProcessTree.cpuSeconds(of: $0) } }

    // MARK: Output

    private func handle(_ line: Data, generation gen: Int) {
        guard gen == generation, let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if o["type"] as? String == "ready" {
            lastReady = o
            lastLoadSeconds = (o["load_seconds"] as? NSNumber)?.doubleValue
            state = .running
            resolve(true)
            return
        }
        if o["type"] as? String == "error", state == .starting, o["id"] == nil || o["id"] is NSNull { resolve(false); return }
        onMessage?(o)
    }

    private func ended(_ proc: ManagedProcess, generation gen: Int) async {
        let code = await proc.waitForExit()
        guard gen == generation else { return }
        if state == .stopping { return }
        let wasStarting = state == .starting
        resolve(false)
        if process === proc { process = nil; pid = nil }
        if proc.wasCancelled && !wasStarting { generation += 1; state = .idle; return }
        if wasStarting { state = .failed("helper exited while starting (\(code))") } else { markCrashed("helper exited (\(code))") }
    }

    private func markCrashed(_ why: String) {
        generation += 1
        state = .failed(why)
        process = nil; pid = nil
        onEvent?("\(config.name) helper stopped unexpectedly")
        onUnexpectedExit?()
    }

    private func waitReady(_ timeout: TimeInterval) async -> Bool {
        if state == .running { return true }
        waitToken += 1
        let token = waitToken
        return await withCheckedContinuation { cont in
            waiters.append(cont)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, self.waitToken == token else { return }          // a newer wait owns the waiters now
                self.resolve(false)
            }
        }
    }
    private func resolve(_ ok: Bool) { let w = waiters; waiters = []; for c in w { c.resume(returning: ok) } }
}
