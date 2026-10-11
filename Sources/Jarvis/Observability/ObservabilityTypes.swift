import Foundation

// MARK: - Safe console events

enum ConsoleEventKind: String, Codable, Sendable, CaseIterable {
    case agentStarted, providerStarted, providerOutput, toolStarted, toolFinished, fileRead, fileChanged
    case validationStarted, validationFinished, retry, escalation, usage, warning, error, cancelled, completed, interrupted
}

enum EventSeverity: String, Codable, Sendable { case info, success, warning, error }

/// One entry of an agent's console. EVERY text field is sanitized in the initializer (`OutputSanitizer`, DEC-029): there is no
/// way to construct an event holding raw provider text, so nothing observable or persistent can carry a secret.
struct AgentConsoleEvent: Identifiable, Equatable, Sendable {
    let id: Int                         // per-run sequence number (also the persistence key)
    let runID: UUID
    let timestamp: Date
    let kind: ConsoleEventKind
    let source: String                  // "JARVIS" or the engine's display name
    let summary: String
    let detail: String?
    let severity: EventSeverity
    let artifactID: UUID?

    static let maxSummary = 400
    static let maxDetail = 4000

    init(id: Int, runID: UUID, timestamp: Date = Date(), kind: ConsoleEventKind, source: String, summary: String, detail: String? = nil,
         severity: EventSeverity = .info, artifactID: UUID? = nil) {
        self.id = id; self.runID = runID; self.timestamp = timestamp; self.kind = kind
        self.source = OutputSanitizer.sanitize(String(source.prefix(80)))
        self.summary = OutputSanitizer.sanitize(String(summary.prefix(Self.maxSummary)))
        self.detail = detail.map { OutputSanitizer.sanitize(String($0.prefix(Self.maxDetail))) }
        self.severity = severity; self.artifactID = artifactID
    }
}

// MARK: - Progress (never invented)

enum ProgressSource: String, Codable, Sendable {
    case structuredSteps            // equally weighted measurable steps
    case weightedSteps              // steps with deterministic weights
    case providerReportedVerified   // reserved: a provider exposing VERIFIED structured progress (none does today)
    case unknown                    // no measurable structure ⇒ no percentage, ever
}

enum StepState: String, Codable, Sendable { case pending, active, done, failed, skipped }

struct AgentStep: Equatable, Sendable, Identifiable {
    var id: Int { index }
    var index: Int
    var title: String
    var weight: Double = 1
    var state: StepState = .pending
}

/// Progress derived ONLY from structured steps. Text a provider prints ("90% complete"), elapsed time, token counts and
/// amount of output are never inputs — there is no API that accepts them.
struct ProgressSnapshot: Equatable, Sendable {
    var source: ProgressSource
    var fraction: Double?          // nil ⇒ indeterminate
    var completed: Int
    var total: Int
    var activeTitle: String?

    static let unknown = ProgressSnapshot(source: .unknown, fraction: nil, completed: 0, total: 0, activeTitle: nil)

    /// "3 / 5 steps" — or nil when there is nothing measurable.
    var label: String? { total > 0 ? "\(completed) / \(total) steps" : nil }
    var isMeasurable: Bool { fraction != nil }
}

enum ProgressCalculator {
    static func compute(_ steps: [AgentStep]) -> ProgressSnapshot {
        let counted = steps.filter { $0.state != .skipped }                    // a skipped step is not measurable work
        guard !counted.isEmpty, counted.allSatisfy({ $0.weight > 0 && $0.weight.isFinite }) else { return .unknown }
        let done = counted.filter { $0.state == .done }
        let weighted = Set(counted.map(\.weight)).count > 1
        let total = counted.reduce(0) { $0 + $1.weight }
        let finished = done.reduce(0) { $0 + $1.weight }
        return ProgressSnapshot(source: weighted ? .weightedSteps : .structuredSteps, fraction: finished / total,
                                completed: done.count, total: counted.count, activeTitle: steps.first { $0.state == .active }?.title)
    }
}

// MARK: - Live run view

/// What the user sees for a run. A pure value assembled from the audit record + live state; never a parallel "fake" state.
enum RunPhase: String, Codable, Sendable {
    case queued, starting, running, verifying, waiting, completed, failed, cancelled, interrupted, escalated

    var label: String { rawValue.uppercased() }
    var isActive: Bool { [.queued, .starting, .running, .verifying, .waiting].contains(self) }
    var isTerminal: Bool { !isActive }

    init(_ status: AgentRunStatus) {
        switch status {
        case .queued: self = .queued
        case .running: self = .running
        case .succeeded: self = .completed
        case .failed: self = .failed
        case .cancelled: self = .cancelled
        case .escalated: self = .escalated
        case .interrupted: self = .interrupted
        }
    }
}

enum RunOwner: String, Sendable { case conversation, agent, benchmark, simulated }

struct AgentRunView: Identifiable, Equatable, Sendable {
    var id: UUID
    var label: String                   // task / what it is doing (sanitized)
    var agentType: String
    var engine: ProviderID
    var model: String?
    var parent: UUID?
    var phase: RunPhase
    var startedAt: Date
    var finishedAt: Date?
    var activity: String                // current activity, e.g. "Generating", "Validating"
    var steps: [AgentStep] = []
    var progress: ProgressSnapshot = .unknown
    var retryCount = 0
    var escalatedFrom: String?
    var escalatedTo: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var errorCategory: String?
    var owner: RunOwner = .conversation
    var isSimulated = false

    func elapsed(at now: Date = Date()) -> TimeInterval { (finishedAt ?? now).timeIntervalSince(startedAt) }

    /// VoiceOver sentence: provider, agent, state, progress where it exists.
    var spoken: String {
        var parts = [engine.displayName, agentType, phase.rawValue]
        if let l = progress.label { parts.append("step \(progress.completed) of \(progress.total)") ; _ = l }
        if isSimulated { parts.append("simulated") }
        return parts.joined(separator: ", ")
    }
}
