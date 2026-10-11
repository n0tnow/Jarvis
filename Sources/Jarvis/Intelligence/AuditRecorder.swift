import Foundation

/// Writes the audit trail (`agent_runs`, `tool_executions`, `file_changes`, activity) with data minimisation:
/// prompts/answers are stored as SHA-256 + length + (non-sensitive only) a short redacted excerpt. Never throws into the
/// caller's path: auditing must not break a conversation, so failures are logged and swallowed.
@MainActor
final class AuditRecorder {
    let repository: JarvisRepository?
    /// V0.3.2: the live observer of run lifecycle (set by `AppContext`). Receives only sanitized data.
    var hub: ExecutionHub?
    private var runs: [UUID: AgentRunRecord] = [:]
    private(set) var failures = 0

    init(repository: JarvisRepository?) { self.repository = repository }

    @discardableResult
    func begin(agentType: String, taskID: UUID? = nil, parent: UUID? = nil, engine: ProviderID, model: String?,
               decision: RoutingDecision?, prompt: String, privacy: PrivacyLevel, label: String? = nil, owner: RunOwner = .conversation,
               now: Date = Date()) -> UUID {
        var run = AgentRunRecord(id: UUID(), taskID: taskID, parentAgentRunID: parent, agentType: agentType, engine: engine, model: model, startedAt: now)
        // What the run is for: an explicit label, else a short REDACTED excerpt of the prompt — none for sensitive tasks.
        run.label = label.map { OutputSanitizer.sanitize(String($0.prefix(80))) }
            ?? (privacy == .sensitive ? "Private request" : Redactor.excerpt(prompt, max: 70))
        run.activity = "Starting"
        run.selectionReason = decision?.reasonJSON
        run.privacy = privacy
        run.status = .running
        run.promptHash = Redactor.sha256(prompt)
        run.promptChars = prompt.count
        runs[run.id] = run
        save { try $0.insert(run) }
        hub?.begin(AgentRunView(id: run.id, label: run.label ?? agentType, agentType: agentType, engine: engine, model: model, parent: parent, phase: .starting,
                                startedAt: now, activity: "Starting", owner: owner))
        return run.id
    }

    func record(_ id: UUID) -> AgentRunRecord? { runs[id] }

    func update(_ id: UUID, _ edit: (inout AgentRunRecord) -> Void) {
        guard var run = runs[id] else { return }
        edit(&run)
        runs[id] = run
        save { try $0.update(run) }
    }

    func finish(_ id: UUID, status: AgentRunStatus, resultText: String? = nil, error: ProviderError? = nil, usage: (input: Int?, output: Int?)? = nil,
                toolAttempts: [String] = [], validation: ValidationStatus? = nil, now: Date = Date()) {
        update(id) { run in
            run.status = status
            run.finishedAt = now
            if let resultText {
                // Minimised result: length + short redacted excerpt (none for sensitive tasks).
                let excerpt = Redactor.excerpt(resultText, max: 120, allowExcerpt: run.privacy != .sensitive)
                run.resultSummary = "\(resultText.count) chars" + (excerpt.isEmpty ? "" : " · " + excerpt)
            }
            if let error { run.errorCategory = Self.category(error) }
            if let usage { run.inputTokens = usage.input; run.outputTokens = usage.output }
            if !toolAttempts.isEmpty { run.toolsUsed = Array(Set(run.toolsUsed + toolAttempts.map { "attempted-refused:\($0)" })).sorted() }
            if let validation { run.validationStatus = validation }
        }
        hub?.finish(id, phase: RunPhase(status), errorCategory: error.map(Self.category), summary: nil)
        // Finished runs are written; keep memory bounded.
        if runs.count > 200 { runs = runs.filter { $0.value.finishedAt == nil } }
    }

    /// Restart reconciliation (V0.3.2): runs recorded as running/queued belong to a previous JARVIS process that no longer exists.
    /// They become `interrupted` (never "running forever") and a console event records why. Returns how many were reconciled.
    @discardableResult
    func reconcileStaleRuns(now: Date = Date()) -> Int {
        guard let repository else { return 0 }
        guard let ids = try? repository.markInterrupted(at: now), !ids.isEmpty else { return 0 }
        for id in ids {
            let next = ((try? repository.eventCount(runID: id)) ?? 0) + 1
            let e = AgentConsoleEvent(id: next, runID: id, timestamp: now, kind: .interrupted, source: "JARVIS",
                                      summary: "Run interrupted: JARVIS stopped before it finished (the provider process did not survive the restart).", severity: .warning)
            save { try $0.appendEvents([e]) }
        }
        try? repository.addActivity(kind: "warning", message: "\(ids.count) run(s) were interrupted by a restart and marked as such")
        return ids.count
    }

    func recordTool(_ runID: UUID, tool: String, summary: String?, status: String, exitCode: Int? = nil) {
        let t = ToolExecutionRecord(agentRunID: runID, tool: tool, summary: summary.map { Redactor.redact($0) }, status: status, finishedAt: Date(), exitCode: exitCode)
        save { try $0.insert(t) }
    }

    func recordFileChange(_ change: FileChangeRecord) { save { try $0.insert(change) } }

    func activity(_ kind: String, _ message: String, runID: UUID? = nil, taskID: UUID? = nil) {
        save { try $0.addActivity(kind: kind, message: message, taskID: taskID, agentRunID: runID) }
    }

    static func category(_ e: ProviderError) -> String {
        switch e {
        case .notInstalled: "notInstalled"
        case .authenticationRequired: "authentication"
        case .rateLimited: "rateLimited"
        case .unavailable: "unavailable"
        case .networkUnavailable: "network"
        case .processFailed: "processFailed"
        case .malformedOutput: "malformedOutput"
        case .timedOut: "timeout"
        case .sessionLost: "sessionLost"
        case .cancelled: "cancelled"
        case .noProviderReady: "noProvider"
        case .busy: "busy"
        case .refused: "refused"
        case .generic: "generic"
        }
    }

    private func save(_ body: (JarvisRepository) throws -> Void) {
        guard let repository else { return }
        do { try body(repository) } catch { failures += 1; Log.providers.error("audit write failed: \(String(describing: error), privacy: .public)") }
    }
}
