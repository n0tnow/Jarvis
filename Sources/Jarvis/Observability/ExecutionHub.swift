import Foundation
import Observation

/// Bounded, sanitized console of ONE run. A class on purpose (not observable): the view polls a snapshot when the hub's coalesced
/// `revision` ticks, so a token stream never invalidates SwiftUI per token.
final class ConsoleBuffer {
    private(set) var events: [AgentConsoleEvent] = []
    private(set) var tail = ""                       // the line currently being written (already sanitized)
    private(set) var droppedEvents = 0
    private(set) var charCount = 0
    private(set) var nextSeq = 1
    var pendingPersist: [AgentConsoleEvent] = []
    /// Full sanitized output text, capped; becomes an artifact when the run ends.
    private(set) var outputLog = ""
    private(set) var outputTruncated = false
    let isSimulated: Bool
    private let maxEvents: Int, maxChars: Int, maxOutputLog: Int

    init(isSimulated: Bool, maxEvents: Int, maxChars: Int, maxOutputLog: Int) {
        self.isSimulated = isSimulated; self.maxEvents = maxEvents; self.maxChars = maxChars; self.maxOutputLog = maxOutputLog
    }

    func add(_ e: AgentConsoleEvent, persist: Bool) {
        events.append(e)
        charCount += e.summary.count + (e.detail?.count ?? 0)
        if persist && !isSimulated { pendingPersist.append(e) }
        // Bounded memory: drop the OLDEST events (they stay in SQLite) once either limit is exceeded.
        var drop = 0
        while events.count - drop > maxEvents || (charCount > maxChars && events.count - drop > 1) {
            let old = events[drop]; charCount -= old.summary.count + (old.detail?.count ?? 0); drop += 1
        }
        if drop > 0 { events.removeFirst(drop); droppedEvents += drop }
    }

    func allocateSeq() -> Int { defer { nextSeq += 1 }; return nextSeq }
    func setTail(_ t: String) { tail = t }

    func appendOutput(_ safe: String) {
        guard !outputTruncated else { return }
        if outputLog.count + safe.count > maxOutputLog { outputLog += "\n[output truncated: limit reached]"; outputTruncated = true } else { outputLog += safe }
    }
}

/// The single live registry of run state and consoles (V0.3.2). It observes the SAME execution the agent runtime consumes —
/// `SafeProvider` feeds it from the one provider stream — so monitoring never starts a second provider process or request.
/// Everything entering the hub is text that already crossed `OutputSanitizer`; events cannot be constructed from raw text.
@MainActor
@Observable
final class ExecutionHub {
    struct Limits: Sendable {
        var maxEventsInMemory = 600
        var maxConsoleChars = 80_000
        var maxOutputLog = 1_000_000
        var maxRuns = 80
        var coalesce: Duration = .milliseconds(120)
        var persistInterval: Duration = .milliseconds(500)
    }

    private(set) var runs: [UUID: AgentRunView] = [:]
    /// Bumped at most once per coalescing interval while consoles change; console views key off it.
    private(set) var revision = 0
    var limits = Limits()
    /// Wired by `AppContext`: routes Stop to the EXISTING cancellation (conversation STOP / AgentRunManager.cancel).
    @ObservationIgnored var stopHandler: ((UUID) -> Bool)?

    @ObservationIgnored private var consoles: [UUID: ConsoleBuffer] = [:]
    @ObservationIgnored private let repository: JarvisRepository?
    @ObservationIgnored private let artifacts: ArtifactStore?
    @ObservationIgnored private var revisionScheduled = false
    @ObservationIgnored private var persistScheduled = false
    @ObservationIgnored private weak var audit: AuditRecorder?
    @ObservationIgnored private(set) var persistenceFailures = 0

    init(repository: JarvisRepository?, artifacts: ArtifactStore?, audit: AuditRecorder? = nil) {
        self.repository = repository; self.artifacts = artifacts; self.audit = audit
    }

    // MARK: Registry

    var activeRuns: [AgentRunView] { runs.values.filter { $0.phase.isActive }.sorted { $0.startedAt < $1.startedAt } }
    var recentFinished: [AgentRunView] { runs.values.filter { $0.phase.isTerminal }.sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) } }
    func run(_ id: UUID) -> AgentRunView? { runs[id] }
    func activeCount(_ engine: ProviderID) -> Int { runs.values.filter { $0.phase.isActive && $0.engine == engine }.count }

    func begin(_ view: AgentRunView) {
        runs[view.id] = view
        consoles[view.id] = ConsoleBuffer(isSimulated: view.isSimulated, maxEvents: limits.maxEventsInMemory, maxChars: limits.maxConsoleChars, maxOutputLog: limits.maxOutputLog)
        var detail = "provider \(view.engine.displayName)"
        if let m = view.model { detail += " · model \(m)" }
        emit(view.id, .agentStarted, source: "JARVIS", summary: "\(view.agentType) started", detail: detail)
        trimRegistry()
        scheduleRevision()
    }

    private func trimRegistry() {
        guard runs.count > limits.maxRuns else { return }
        for old in recentFinished.dropFirst(limits.maxRuns / 2) { runs[old.id] = nil; consoles[old.id] = nil }
    }

    // MARK: Events

    func emit(_ runID: UUID, _ kind: ConsoleEventKind, source: String? = nil, summary: String, detail: String? = nil,
              severity: EventSeverity = .info, artifactID: UUID? = nil) {
        guard let buf = consoles[runID], let view = runs[runID] else { return }
        let e = AgentConsoleEvent(id: buf.allocateSeq(), runID: runID, kind: kind, source: source ?? view.engine.displayName, summary: summary,
                                  detail: detail, severity: severity, artifactID: artifactID)
        buf.add(e, persist: true)
        schedulePersist(); scheduleRevision()
    }

    /// Provider text (ALREADY sanitized by `SafeProvider`'s `StreamSanitizer`; sanitized once more here as a safety net).
    /// Complete lines become `providerOutput` events; the unfinished line is the live tail.
    func appendOutput(_ runID: UUID, _ text: String) {
        guard let buf = consoles[runID], let view = runs[runID], !text.isEmpty else { return }
        let safe = OutputSanitizer.sanitize(text)
        buf.appendOutput(safe)
        var combined = buf.tail + safe
        while let nl = combined.firstIndex(of: "\n") {
            let line = String(combined[..<nl]); combined = String(combined[combined.index(after: nl)...])
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let e = AgentConsoleEvent(id: buf.allocateSeq(), runID: runID, kind: .providerOutput, source: view.engine.displayName,
                                          summary: String(line.prefix(AgentConsoleEvent.maxSummary)), detail: line.count > AgentConsoleEvent.maxSummary ? line : nil)
                buf.add(e, persist: true)
            }
        }
        // A tail that never gets a newline must not grow without bound: promote it to an event.
        if combined.count > 600 {
            let e = AgentConsoleEvent(id: buf.allocateSeq(), runID: runID, kind: .providerOutput, source: view.engine.displayName, summary: String(combined.prefix(AgentConsoleEvent.maxSummary)),
                                      detail: combined)
            buf.add(e, persist: true); combined = ""
        }
        buf.setTail(combined)
        schedulePersist(); scheduleRevision()
    }

    // MARK: State changes

    func setPhase(_ runID: UUID, _ phase: RunPhase, activity: String? = nil) {
        guard var v = runs[runID], v.phase != phase || activity != nil else { return }
        guard !v.phase.isTerminal else { return }                       // a finished run never goes back to running
        v.phase = phase
        if let a = activity { v.activity = OutputSanitizer.sanitize(a) }
        runs[runID] = v
        persistRunState(v)
        scheduleRevision()
    }

    func setActivity(_ runID: UUID, _ activity: String) {
        guard var v = runs[runID], !v.phase.isTerminal else { return }
        v.activity = OutputSanitizer.sanitize(activity); runs[runID] = v
        scheduleRevision()
    }

    /// Declares the structured steps of a run (the ONLY source of progress).
    func setSteps(_ runID: UUID, _ titles: [(String, Double)]) {
        guard var v = runs[runID] else { return }
        v.steps = titles.enumerated().map { AgentStep(index: $0.offset, title: OutputSanitizer.sanitize($0.element.0), weight: $0.element.1) }
        v.progress = ProgressCalculator.compute(v.steps); runs[runID] = v
        persistSteps(v); scheduleRevision()
    }

    func setStep(_ runID: UUID, index: Int, _ state: StepState) {
        guard var v = runs[runID], v.steps.indices.contains(index) else { return }
        v.steps[index].state = state
        v.progress = ProgressCalculator.compute(v.steps)
        if state == .active { v.activity = v.steps[index].title }
        runs[runID] = v
        persistSteps(v); scheduleRevision()
    }

    func setUsage(_ runID: UUID, input: Int?, output: Int?) {
        guard var v = runs[runID] else { return }
        v.inputTokens = input; v.outputTokens = output; runs[runID] = v
        if input != nil || output != nil { emit(runID, .usage, source: "JARVIS", summary: "Tokens reported by the provider: in \(input.map(String.init) ?? "–") / out \(output.map(String.init) ?? "–")") }
    }

    func noteRetry(_ runID: UUID, count: Int) {
        guard var v = runs[runID] else { return }
        v.retryCount = count; runs[runID] = v
        emit(runID, .retry, source: "JARVIS", summary: "Repair attempt #\(count)", severity: .warning)
    }

    func noteEscalation(_ runID: UUID, from: String?, to: String?) {
        guard var v = runs[runID] else { return }
        v.escalatedFrom = from ?? v.escalatedFrom; v.escalatedTo = to ?? v.escalatedTo
        // A run that failed and was handed over reads ESCALATED (its provider failed; the work continues elsewhere).
        if v.phase == .failed { v.phase = .escalated; v.activity = "Escalated" + (to.map { " to \($0)" } ?? "") }
        runs[runID] = v
        emit(runID, .escalation, source: "JARVIS", summary: "Escalated \(from.map { "from \($0) " } ?? "")\(to.map { "to \($0)" } ?? "")", severity: .warning)
    }

    /// Terminal transition. Flushes the unfinished output line, emits the terminal event, persists, stores the sanitized output artifact.
    func finish(_ runID: UUID, phase: RunPhase, errorCategory: String? = nil, summary: String? = nil) {
        guard var v = runs[runID], !v.phase.isTerminal, phase.isTerminal else { return }
        if let buf = consoles[runID], !buf.tail.isEmpty {
            let e = AgentConsoleEvent(id: buf.allocateSeq(), runID: runID, kind: .providerOutput, source: v.engine.displayName, summary: String(buf.tail.prefix(AgentConsoleEvent.maxSummary)),
                                      detail: buf.tail.count > AgentConsoleEvent.maxSummary ? buf.tail : nil)
            buf.add(e, persist: true); buf.setTail("")
        }
        v.phase = phase; v.finishedAt = Date(); v.errorCategory = errorCategory
        v.activity = Self.terminalActivity(phase, errorCategory)
        runs[runID] = v
        var artifactID: UUID?
        if let buf = consoles[runID], !buf.isSimulated, let artifacts, !buf.outputLog.isEmpty {
            artifactID = try? artifacts.store(Data(buf.outputLog.utf8), type: "console-output", folder: .providerOutput, agentRunID: runID, meta: "sanitized").id
        }
        let (kind, severity): (ConsoleEventKind, EventSeverity) = {
            switch phase {
            case .completed: (.completed, .success)
            case .failed: (.error, .error)
            case .cancelled: (.cancelled, .warning)
            case .interrupted: (.interrupted, .warning)
            default: (.completed, .info)
            }
        }()
        emit(runID, kind, source: "JARVIS", summary: summary ?? Self.terminalActivity(phase, errorCategory), severity: severity, artifactID: artifactID)
        flushPersistNow()
        scheduleRevision()
    }

    static func terminalActivity(_ phase: RunPhase, _ category: String?) -> String {
        switch phase {
        case .completed: "Completed"
        case .failed: "Failed" + (category.map { " (\($0))" } ?? "")
        case .cancelled: "Cancelled"
        case .interrupted: "Interrupted"
        case .escalated: "Escalated to another provider"
        default: phase.label.capitalized
        }
    }

    // MARK: Stop (existing cancellation only)

    @discardableResult
    func requestStop(_ runID: UUID) -> Bool {
        guard let v = runs[runID], v.phase.isActive, !v.isSimulated || stopHandler != nil else { return false }
        emit(runID, .warning, source: "JARVIS", summary: "Stop requested", severity: .warning)
        return stopHandler?(runID) ?? false
    }

    // MARK: Snapshots for views

    struct ConsoleSnapshot: Equatable {
        var events: [AgentConsoleEvent]
        var tail: String
        var droppedEvents: Int
    }

    func consoleSnapshot(_ runID: UUID, maxEvents: Int = 400) -> ConsoleSnapshot {
        guard let b = consoles[runID] else { return ConsoleSnapshot(events: [], tail: "", droppedEvents: 0) }
        return ConsoleSnapshot(events: Array(b.events.suffix(maxEvents)), tail: b.tail, droppedEvents: b.droppedEvents)
    }

    /// Everything the on-screen console holds as plain sanitized text (what ⌘C copies from the selectable view).
    func visibleText(_ runID: UUID) -> String {
        let s = consoleSnapshot(runID)
        var lines = s.events.map { Self.format($0) }
        if !s.tail.isEmpty { lines.append(s.tail) }
        return lines.joined(separator: "\n")
    }

    static func format(_ e: AgentConsoleEvent) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return "\(f.string(from: e.timestamp))  \(e.summary)"
    }

    /// Historical console (lazy, bounded): events persisted in SQLite — all sanitized.
    func loadHistory(_ runID: UUID, limit: Int = 500) -> [AgentConsoleEvent] {
        (try? repository?.events(runID: runID, limit: limit)) ?? []
    }

    func bufferStats(_ runID: UUID) -> (events: Int, chars: Int, dropped: Int)? {
        consoles[runID].map { ($0.events.count, $0.charCount, $0.droppedEvents) }
    }

    // MARK: Coalescing + persistence

    private func scheduleRevision() {
        guard !revisionScheduled else { return }
        revisionScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: self?.limits.coalesce ?? .milliseconds(120))
            guard let self else { return }
            self.revisionScheduled = false
            self.revision &+= 1
        }
    }

    private func schedulePersist() {
        guard repository != nil, !persistScheduled else { return }
        persistScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: self?.limits.persistInterval ?? .milliseconds(500))
            self?.flushPersistNow()
        }
    }

    /// Writes pending (sanitized) events in ONE transaction per run.
    func flushPersistNow() {
        persistScheduled = false
        guard let repository else { return }
        for (_, buf) in consoles where !buf.pendingPersist.isEmpty {
            let batch = buf.pendingPersist; buf.pendingPersist = []
            do { try repository.appendEvents(batch) } catch { persistenceFailures += 1 }
        }
    }

    private func persistRunState(_ v: AgentRunView) {
        guard !v.isSimulated else { return }
        audit?.update(v.id) { $0.activity = v.activity }
    }

    private func persistSteps(_ v: AgentRunView) {
        guard !v.isSimulated else { return }
        audit?.update(v.id) {
            $0.progressSource = v.progress.source; $0.stepsTotal = v.progress.total > 0 ? v.progress.total : nil
            $0.stepsDone = v.progress.total > 0 ? v.progress.completed : nil; $0.progressFraction = v.progress.fraction; $0.activity = v.activity
        }
        try? repository?.saveSteps(runID: v.id, v.steps)
    }
}

extension ExecutionHub {
    /// Stop is NEVER a second kill mechanism: it is routed to the cancellation that already owns the run —
    /// conversation STOP (→ provider cancel → SIGINT/SIGTERM/SIGKILL tree), `AgentRunManager.cancel`, or the cancellable user task.
    func installStopRouting(conversation: ConversationService, agents: AgentRunManager, userTask: @escaping (UUID) -> Task<Void, Never>?, demo: @escaping () -> ObservatoryDemo?) {
        stopHandler = { [weak self, weak conversation, weak agents] runID in
            guard let self, let v = self.run(runID) else { return false }
            switch v.owner {
            case .conversation:
                guard let conversation, conversation.respondingRunID == runID else { return false }
                return conversation.cancelCurrentResponse()
            case .agent, .benchmark:
                if let t = userTask(runID) { t.cancel(); return true }
                guard v.owner == .agent, let agents else { return false }
                agents.cancel(runID); return true
            case .simulated:
                return demo()?.stop(runID) ?? false
            }
        }
    }
}
