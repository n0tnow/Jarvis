import Foundation
import Observation

// MARK: - Truthful provider state

/// What the user sees for a provider. Distinguishes things that are NOT equivalent: installed/authenticated (READY), a model
/// loaded in memory (LOADED), and an execution actually happening (RUNNING). Pure → unit-tested.
enum ProviderUIState: String, Equatable, Sendable {
    case checking, notInstalled, authRequired, ready, starting, running, loadedIdle, unloaded, rateLimited, cooldown, unavailable, failed

    var label: String {
        switch self {
        case .checking: "CHECKING"
        case .notInstalled: "NOT INSTALLED"
        case .authRequired: "AUTH REQUIRED"
        case .ready: "READY"
        case .starting: "STARTING"
        case .running: "RUNNING"
        case .loadedIdle: "LOADED · IDLE"
        case .unloaded: "UNLOADED"
        case .rateLimited: "RATE LIMITED"
        case .cooldown: "COOLDOWN"
        case .unavailable: "UNAVAILABLE"
        case .failed: "FAILED"
        }
    }

    /// One plain sentence explaining what the state means (shown under the label).
    var explanation: String {
        switch self {
        case .checking: "Status not checked yet."
        case .notInstalled: "Not installed on this Mac."
        case .authRequired: "Installed — sign in with the vendor's own flow."
        case .ready: "Ready. No run in progress."
        case .starting: "Starting."
        case .running: "An execution is running now."
        case .loadedIdle: "Model is loaded in memory; no run in progress."
        case .unloaded: "Not loaded in memory. Starts automatically when needed."
        case .rateLimited: "Usage limit reached for now."
        case .cooldown: "Temporarily skipped after repeated failures."
        case .unavailable: "Installed but not usable right now."
        case .failed: "The last start failed."
        }
    }
}

enum ProviderStateResolver {
    static func resolve(engine: ProviderID, availability: EngineAvailability?, localState: LocalRuntimeState?, activeRuns: Int, now: Date = Date()) -> ProviderUIState {
        // 1. An execution in flight beats everything: this is the ONLY way a provider reads RUNNING.
        if activeRuns > 0 { return .running }
        if engine == .local, let l = localState {
            switch l {
            case .running: return .running
            case .starting: return .starting
            case .ready: return .loadedIdle
            case .stopping: return .starting
            case .idle: if let c = availability?.cooldownUntil, c > now { return .cooldown }; return .unloaded
            case .notConfigured, .runtimeMissing, .modelMissing: return .notInstalled
            case .failed: return .failed
            case .unavailable: return .unavailable
            }
        }
        guard let a = availability else { return .checking }
        if let c = a.cooldownUntil, c > now { return .cooldown }
        switch a.state {
        case .unknown: return .checking
        case .notInstalled: return .notInstalled
        case .authenticationRequired: return .authRequired
        case .ready: return .ready
        case .running: return .running
        case .rateLimited: return .rateLimited
        case .unavailable: return .unavailable
        case .failed: return .failed
        }
    }
}

// MARK: - View models

struct ProviderCardModel: Identifiable, Equatable {
    var id: ProviderID
    var name: String
    var state: ProviderUIState
    var activeRuns: [AgentRunView]
    var currentModel: String?
    var facts: [String]                // only facts that are actually known
    var lastRun: AgentRunView?
    var lastError: String?
    var cooldownUntil: Date?
}

struct TimelineItem: Identifiable, Equatable {
    var id: String
    var time: Date
    var agent: String
    var provider: String
    var text: String
    var severity: EventSeverity
    var runID: UUID
    var kind: ConsoleEventKind
}

struct RunDetailData: Equatable {
    var view: AgentRunView
    var steps: [AgentStep]
    var files: [FileChangeRecord]
    var artifacts: [ArtifactRecord]
    var toolsUsed: [String]
    var filesRead: [String]
    var validation: ValidationStatus
    var resultSummary: String?
    var selectionSummary: String?
    var children: [UUID]
}

/// Read model of the whole Agents area. Everything derives from REAL state: ProviderSupervisor availability, the live
/// `ExecutionHub`, the SQLite audit store and the artifact store. There is no separate "observatory state".
@MainActor
@Observable
final class AgentObservatory {
    let hub: ExecutionHub
    private let supervisor: ProviderSupervisor
    private let openCode: OpenCodeService
    private let local: LocalRuntime
    private let repository: JarvisRepository?
    private let artifacts: ArtifactStore?
    /// Developer-only simulation (never persisted, always labelled SIMULATED).
    var demo: ObservatoryDemo?

    var selectedRunID: UUID?
    private(set) var historyRevision = 0

    init(hub: ExecutionHub, supervisor: ProviderSupervisor, openCode: OpenCodeService, local: LocalRuntime, repository: JarvisRepository?, artifacts: ArtifactStore?) {
        self.hub = hub; self.supervisor = supervisor; self.openCode = openCode; self.local = local; self.repository = repository; self.artifacts = artifacts
    }

    func bumpHistory() { historyRevision &+= 1 }

    // MARK: Providers

    func providerCards(now: Date = Date()) -> [ProviderCardModel] {
        let availability = supervisor.availability()
        let last = (try? repository?.lastRunPerEngine()) ?? [:]
        let health = supervisor.health
        return ProviderID.allCases.map { engine in
            let active = hub.activeRuns.filter { $0.engine == engine }
            let a = availability[engine]
            let state = ProviderStateResolver.resolve(engine: engine, availability: a, localState: engine == .local ? local.state : nil, activeRuns: active.count, now: now)
            var facts: [String] = []
            var model: String? = active.first?.model
            switch engine {
            case .local:
                facts.append("Model: Qwen3.5-4B MLX 4-bit")
                if local.state.isLoaded { facts.append("Loaded in memory") }
                if let mb = local.workerResidentBytes { facts.append("Worker memory: \(mb / 1_048_576) MB") }
                if let tps = local.metrics.generationTokensPerSecond { facts.append("Last speed: \(Int(tps)) tok/s") }
            case .openCode:
                if openCode.state == .ready { facts.append("\(openCode.freePool.count) verified free models available") }
                if let v = openCode.version { facts.append("Version \(v)") }
            case .claudeCode, .codex:
                if let v = supervisor.providers.status(engine).version { facts.append("Version \(v)") }
            }
            if !active.isEmpty { facts.append("\(active.count) active run\(active.count == 1 ? "" : "s")") }
            let lastView = hub.recentFinished.first { $0.engine == engine } ?? last[engine].map(Self.view(from:))
            if model == nil { model = lastView?.model }
            let h = health.values.filter { $0.engine == engine }.max { ($0.lastFailureAt ?? .distantPast) < ($1.lastFailureAt ?? .distantPast) }
            let cooldown = h?.cooldownUntil.flatMap { $0 > now ? $0 : nil }
            return ProviderCardModel(id: engine, name: engine.displayName, state: state, activeRuns: active, currentModel: model, facts: facts,
                                     lastRun: lastView, lastError: lastView?.errorCategory ?? h?.lastErrorCategory, cooldownUntil: cooldown)
        }
    }

    // MARK: Runs

    static func view(from r: AgentRunRecord) -> AgentRunView {
        var v = AgentRunView(id: r.id, label: r.label ?? r.agentType, agentType: r.agentType, engine: r.engine, model: r.model, parent: r.parentAgentRunID,
                             phase: RunPhase(r.status), startedAt: r.startedAt, finishedAt: r.finishedAt, activity: r.activity ?? r.status.rawValue.capitalized)
        v.retryCount = r.retryCount; v.escalatedFrom = r.escalatedFrom; v.escalatedTo = r.escalatedTo
        v.inputTokens = r.inputTokens; v.outputTokens = r.outputTokens; v.errorCategory = r.errorCategory
        // Progress is read back from what was PERSISTED (source + fraction) — never recomputed from anything softer.
        if let f = r.progressFraction, r.progressSource != .unknown, let total = r.stepsTotal {
            v.progress = ProgressSnapshot(source: r.progressSource, fraction: f, completed: r.stepsDone ?? 0, total: total, activeTitle: nil)
        }
        return v
    }

    /// Live run if the hub knows it (fresher), else reconstructed from SQLite.
    func runView(_ id: UUID) -> AgentRunView? {
        if let live = hub.run(id) { return live }
        return (try? repository?.agentRun(id)).flatMap { $0 }.map(Self.view(from:))
    }

    func history(filter: JarvisRepository.RunFilter, limit: Int = 25, offset: Int = 0) -> [AgentRunView] {
        _ = historyRevision
        // Live (unfinished) runs come from the hub; finished ones from SQLite — never the same run twice.
        let rows = (try? repository?.agentRuns(filter: filter, limit: limit, offset: offset)) ?? []
        return rows.map { hub.run($0.id) ?? Self.view(from: $0) }
    }

    func detail(_ id: UUID) -> RunDetailData? {
        guard let view = runView(id) else { return nil }
        let record = (try? repository?.agentRun(id)).flatMap { $0 }
        let steps = view.steps.isEmpty ? ((try? repository?.steps(runID: id)) ?? []) : view.steps
        var v = view
        if v.steps.isEmpty && !steps.isEmpty { v.steps = steps; v.progress = ProgressCalculator.compute(steps) }
        return RunDetailData(view: v, steps: steps, files: (try? repository?.fileChanges(agentRunID: id)) ?? [],
                             artifacts: (try? artifacts?.artifacts(agentRunID: id)) ?? [], toolsUsed: record?.toolsUsed ?? [], filesRead: record?.filesRead ?? [],
                             validation: record?.validationStatus ?? .notRun, resultSummary: record?.resultSummary,
                             selectionSummary: record?.selectionReason.flatMap(Self.summarize(reason:)),
                             children: ((try? repository?.children(of: id)) ?? []).map(\.id))
    }

    /// "development-free-first · benchmark coding 4/4 · data zeroRetention" from the persisted machine-readable reason.
    static func summarize(reason json: String) -> String? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: String] else { return nil }
        var parts: [String] = []
        if let t = o["tier"] { parts.append(t) }
        if let e = o["escalationReason"] { parts.append("escalated: \(e)") }
        if let b = o.first(where: { $0.key.hasPrefix("benchmark.") }) { parts.append("benchmark \(b.key.dropFirst(10)) \(b.value)") }
        if let d = o["dataPolicy"] { parts.append("data \(d)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Sanitized console of a run: live buffer if the hub has it, else persisted events (lazy, bounded).
    func consoleEvents(_ id: UUID) -> [AgentConsoleEvent] {
        let live = hub.consoleSnapshot(id)
        return live.events.isEmpty ? hub.loadHistory(id) : live.events
    }

    // MARK: Timeline

    func timeline(limit: Int = 60) -> [TimelineItem] {
        var items: [TimelineItem] = []
        let liveIDs = Set(hub.runs.keys)
        for run in hub.runs.values {
            for e in hub.consoleSnapshot(run.id, maxEvents: 600).events where e.kind != .providerOutput {
                items.append(TimelineItem(id: "\(run.id)-\(e.id)", time: e.timestamp, agent: run.agentType, provider: Self.providerLabel(run), text: e.summary, severity: e.severity, runID: run.id, kind: e.kind))
            }
        }
        for row in (try? repository?.recentTimeline(limit: limit, excludingRuns: liveIDs)) ?? [] {
            items.append(TimelineItem(id: "\(row.event.runID)-\(row.event.id)", time: row.event.timestamp, agent: row.agentType,
                                      provider: row.model.map { "\(row.engine.displayName) · \($0.split(separator: "/").last.map(String.init) ?? $0)" } ?? row.engine.displayName,
                                      text: row.event.summary, severity: row.event.severity, runID: row.event.runID, kind: row.event.kind))
        }
        return items.sorted { $0.time > $1.time }.prefix(limit).map { $0 }
    }

    static func providerLabel(_ r: AgentRunView) -> String {
        r.model.map { "\(r.engine.displayName) · \($0.split(separator: "/").last.map(String.init) ?? $0)" } ?? r.engine.displayName
    }

    // MARK: Reports (answers for the future Report screen)

    func todayStats() -> JarvisRepository.RunStats? {
        try? repository?.runStats(since: Calendar.current.startOfDay(for: Date()))
    }

    // MARK: Safe artifact reading

    /// Artifact text for the viewer — artifacts are written from sanitized data only; sanitized once more on read.
    func artifactText(_ a: ArtifactRecord, maxChars: Int = 60_000) -> String? {
        guard let artifacts, artifacts.verify(a), let data = try? artifacts.read(a) else { return nil }
        return OutputSanitizer.sanitize(String(decoding: data.prefix(maxChars * 2), as: UTF8.self).prefix(maxChars).description)
    }
}
