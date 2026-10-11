import Foundation
import Observation

/// Owns the health of every engine and turns it into routing input (DEC-027).
///  - discovers / inspects (subscription CLIs via `ProviderManager`, OpenCode catalog, local model files),
///  - keeps persistent failure/cooldown records (a broken free model is not retried every few seconds),
///  - supervises the local worker: crash → mark unhealthy → ONE bounded restart attempt → health check → ready | unavailable,
///  - unloads the local model on memory pressure and when idle, and stops everything it manages on shutdown.
/// It does NOT keep CLI providers running: Claude Code / Codex / OpenCode stay per-request child processes.
@MainActor
@Observable
final class ProviderSupervisor {
    let providers: ProviderManager
    let openCode: OpenCodeService
    let local: LocalRuntime?
    let resources: ResourceManager
    @ObservationIgnored let repository: JarvisRepository?

    var cooldownPolicy = CooldownPolicy()
    /// Bounded automatic recovery of the local worker after a crash: at most `maxRestarts` inside `restartWindow`.
    var maxRestarts = 1
    var restartWindow: TimeInterval = 600
    var autoRestartLocal = true

    private(set) var health: [String: ProviderHealthRecord] = [:]
    private(set) var restartTimes: [Date] = []
    private(set) var lastRefresh: Date?
    @ObservationIgnored var clock: () -> Date = { Date() }
    /// Meaningful lifecycle events only (never health-check noise).
    @ObservationIgnored var onEvent: ((String) -> Void)?
    @ObservationIgnored private var benchmarkCache: [String: [BenchmarkGroup: BenchmarkSummary]]?

    init(providers: ProviderManager, openCode: OpenCodeService, local: LocalRuntime?, resources: ResourceManager, repository: JarvisRepository?) {
        self.providers = providers; self.openCode = openCode; self.local = local; self.resources = resources; self.repository = repository
        for h in (try? repository?.allHealth()) ?? [] { health[Self.key(h.engine, h.subject)] = h }
        local?.onCrash = { [weak self] why in self?.localCrashed(why) }
        local?.onEvent = { [weak self] message in self?.onEvent?(message) }
        openCode.onEvent = { [weak self] message in self?.onEvent?(message) }
        resources.onPressureRise = { [weak self] level in self?.memoryPressureRose(level) }
    }

    static func key(_ e: ProviderID, _ subject: String) -> String { "\(e.rawValue)|\(subject)" }

    // MARK: Discovery

    /// Refreshes every engine. `remoteCatalog` asks OpenCode to refresh its price snapshot (needed before trusting "free").
    func refreshAll(remoteCatalog: Bool = true, includeOpenCode: Bool = true) async {
        async let sub: Void = providers.refresh()
        if includeOpenCode { async let oc: Void = openCode.refresh(remote: remoteCatalog); _ = await (sub, oc) } else { _ = await sub }
        local?.inspect()
        benchmarkCache = nil
        lastRefresh = clock()
    }

    /// Re-read OpenCode prices if the verification is stale (called before a free-cloud routing decision).
    func ensureFreshCatalog() async {
        if openCode.state != .notInstalled && !openCode.verificationIsFresh { await openCode.refresh(remote: true); benchmarkCache = nil }
    }

    // MARK: Routing input

    func availability() -> [ProviderID: EngineAvailability] {
        let now = clock()
        var out: [ProviderID: EngineAvailability] = [:]
        for id in ProviderID.subscription {
            let st = providers.status(id)
            out[id] = EngineAvailability(id, state: st.state, cooldownUntil: cooldownUntil(id, nil, now: now))
        }
        out[.openCode] = EngineAvailability(.openCode, state: openCode.state, cooldownUntil: cooldownUntil(.openCode, nil, now: now))
        let localState: ProviderState = {
            guard let local else { return .notInstalled }
            switch local.state {
            case .idle, .ready, .starting: return .ready
            case .running: return .running
            case .notConfigured, .runtimeMissing: return .notInstalled
            case .modelMissing: return .unavailable("model missing")
            case .stopping: return .unavailable("stopping")
            case .unavailable(let w): return .unavailable(w)
            case .failed(let w): return .failed(w)
            }
        }()
        out[.local] = EngineAvailability(.local, state: localState, cooldownUntil: cooldownUntil(.local, nil, now: now))
        return out
    }

    func snapshot(preference: ProviderPreference, settings: RoutingSettings) -> RouterSnapshot {
        let now = clock()
        var s = RouterSnapshot()
        s.now = now
        s.preference = preference
        s.engines = availability()
        s.models = openCode.models.filter { $0.engine == .openCode }
        s.benchmarks = benchmarkSummaries()
        for (_, h) in health where h.engine == .openCode && !h.subject.isEmpty { if let c = h.cooldownUntil, c > now { s.modelCooldowns[h.subject] = c } }
        s.resources = resources.pressure
        s.settings = settings
        return s
    }

    func invalidateBenchmarks() { benchmarkCache = nil }

    func benchmarkSummary(_ modelID: String, _ group: BenchmarkGroup) -> BenchmarkSummary? { benchmarkSummaries()[modelID]?[group] }

    private func benchmarkSummaries() -> [String: [BenchmarkGroup: BenchmarkSummary]] {
        if let c = benchmarkCache { return c }
        var out: [String: [BenchmarkGroup: BenchmarkSummary]] = [:]
        guard let repository else { return out }
        for m in openCode.models where m.engine == .openCode {
            guard let results = try? repository.benchmarks(modelID: m.id), !results.isEmpty else { continue }
            var perGroup: [BenchmarkGroup: BenchmarkSummary] = [:]
            for g in BenchmarkGroup.allCases { if let s = BenchmarkSummary.summarize(results, group: g, suite: BenchmarkSuite.id) { perGroup[g] = s } }
            out[m.id] = perGroup
        }
        benchmarkCache = out
        return out
    }

    // MARK: Health + cooldown

    func cooldownUntil(_ engine: ProviderID, _ subject: String?, now: Date? = nil) -> Date? {
        let n = now ?? clock()
        guard let c = health[Self.key(engine, subject ?? "")]?.cooldownUntil, c > n else { return nil }
        return c
    }

    func consecutiveFailures(_ engine: ProviderID, _ subject: String? = nil) -> Int { health[Self.key(engine, subject ?? "")]?.consecutiveFailures ?? 0 }

    func recordSuccess(_ engine: ProviderID, subject: String? = nil) {
        let k = Self.key(engine, subject ?? "")
        var h = health[k] ?? ProviderHealthRecord(engine: engine, subject: subject ?? "")
        let wasCooling = h.consecutiveFailures > 0
        h.consecutiveFailures = 0; h.cooldownUntil = nil; h.lastSuccessAt = clock()
        store(h)
        if wasCooling { onEvent?("\(engine.displayName) recovered") }
        if let subject, engine == .openCode { try? repository?.markModelRun(subject, success: true, at: clock()) }
    }

    /// Records a failure and (deterministically) decides whether the subject enters cooldown.
    /// User cancellations / busy / routing refusals are not provider failures and are ignored.
    @discardableResult
    func recordFailure(_ engine: ProviderID, subject: String? = nil, error: ProviderError) -> Date? {
        switch error { case .cancelled, .busy, .refused, .sessionLost: return nil; default: break }
        let now = clock()
        let k = Self.key(engine, subject ?? "")
        var h = health[k] ?? ProviderHealthRecord(engine: engine, subject: subject ?? "")
        h.consecutiveFailures += 1; h.totalFailures += 1; h.lastFailureAt = now; h.lastErrorCategory = AuditRecorder.category(error)
        var until: TimeInterval = cooldownPolicy.duration(forConsecutiveFailures: h.consecutiveFailures)
        if case .rateLimited(_, let reset) = error { until = max(until, reset.map { max(0, $0.timeIntervalSince(now)) } ?? 15 * 60) }
        if case .authenticationRequired = error { until = max(until, 10 * 60) }
        h.cooldownUntil = until > 0 ? now.addingTimeInterval(until) : nil
        store(h)
        if let subject, engine == .openCode { try? repository?.markModelRun(subject, success: false, at: now) }
        if until > 0 { onEvent?("\(subject ?? engine.displayName) entered cooldown (\(Int(until)) s)") }
        return h.cooldownUntil
    }

    private func store(_ h: ProviderHealthRecord) {
        health[Self.key(h.engine, h.subject)] = h
        try? repository?.save(h)
    }

    // MARK: Local worker supervision

    /// Worker died unexpectedly: mark unhealthy, then at most ONE bounded restart + health check.
    private func localCrashed(_ why: String) {
        recordFailure(.local, error: .processFailed(.local, exitCode: -1))
        guard autoRestartLocal, let local else { return }
        let now = clock()
        restartTimes = restartTimes.filter { now.timeIntervalSince($0) < restartWindow }
        guard restartTimes.count < maxRestarts, cooldownUntil(.local, nil) == nil else {
            onEvent?("Local Qwen unavailable (restart limit reached)")
            return
        }
        restartTimes.append(now)
        Task { @MainActor in
            local.reset()
            do {
                try await local.ensureStarted()
                if await local.healthCheck() { self.recordSuccess(.local); self.onEvent?("Local Qwen restarted") }
                else { await local.unload(); _ = self.recordFailure(.local, error: .unavailable(.local, "health check failed")) }
            } catch {
                _ = self.recordFailure(.local, error: (error as? ProviderError) ?? .generic)
            }
        }
    }

    /// Memory pressure: free the 3 GB model if nothing is using it.
    private func memoryPressureRose(_ level: MemoryPressureLevel) {
        guard let local, local.state == .ready else { return }
        Task { @MainActor in
            await local.unload()
            self.onEvent?("Local Qwen unloaded (memory pressure)")
        }
    }

    // MARK: Shutdown

    /// Stops everything this supervisor manages (the local worker). CLI providers are per-request and are killed by
    /// `ProcessRegistry.killAll()` at termination.
    func shutdown() {
        autoRestartLocal = false                       // terminating: a killed worker is not a crash to recover from
        local?.shutdownNow()
        resources.stop()
    }
}
