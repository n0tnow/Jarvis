import Foundation

// MARK: - A bounded, de-duplicated, secret-free event log for long tasks (V1.0 background pass)
//
// An overnight task produces many events. The log keeps what a person needs and nothing that can grow without limit or leak:
//   · structured kinds only (no free prose from a model, no chain-of-thought field exists), detail clipped and passed through the secret gate;
//   · identical repeated failures collapse into ONE entry "same failure ×17" with first and last time — the first occurrence's detail is kept, the count and the last time are updated;
//   · important kinds (approval, blocked, resumed, completed, failed, checkpoint, started) are never merged or dropped;
//   · a hard capacity: when full, the OLDEST aggregatable entries go first; counters of dropped entries are kept (`dropped`) so nothing silently disappears;
//   · O(1) amortised per event (a dictionary for the open aggregate), measured by a scaling test.
// Pure value type with an injected clock-by-argument: no timer, no I/O. Persistence (if any) is an artifact written by the engine.

enum TaskEventKind: String, Codable, Equatable, Sendable, CaseIterable {
    case taskStarted, planAccepted, stepStarted, stepCompleted, verificationPassed, verificationFailed, retryScheduled, providerFallback, checkpointWritten
    case approvalRequested, approvalDecided, blocked, resumed, interrupted, budgetWarning, budgetExhausted, driftDetected, stuckDetected, failure, taskCompleted, taskFailed, taskCancelled

    /// Never merged with another event and never evicted before aggregatable ones.
    var isImportant: Bool {
        switch self {
        case .taskStarted, .planAccepted, .approvalRequested, .approvalDecided, .blocked, .resumed, .interrupted, .budgetExhausted, .driftDetected, .stuckDetected, .taskCompleted, .taskFailed, .taskCancelled, .checkpointWritten: true
        default: false
        }
    }
    /// Repeated identical occurrences collapse.
    var isAggregatable: Bool { !isImportant }
}

struct TaskEvent: Codable, Equatable, Sendable {
    var kind: TaskEventKind
    var stepKey: String?
    /// A machine code ("provider-timeout", "build-failed"); the part that identifies "the same failure".
    var code: String
    /// Bounded, redacted detail of the FIRST occurrence.
    var detail: String
    var first: Date
    var last: Date
    var count: Int
}

struct TaskEventLog: Equatable, Sendable {
    static let maxDetail = 200
    private(set) var entries: [TaskEvent] = []
    private(set) var dropped = 0
    let capacity: Int
    private var openAggregate: [String: Int] = [:]      // key → index in `entries` of the latest aggregatable entry

    init(capacity: Int = 400) { self.capacity = max(8, capacity) }

    mutating func record(_ kind: TaskEventKind, step: String? = nil, code: String, detail: String = "", at: Date) {
        let key = "\(kind.rawValue)|\(step ?? "")|\(code)"
        if kind.isAggregatable, let i = openAggregate[key], i < entries.count, entries[i].kind == kind, entries[i].code == code {
            entries[i].count += 1; entries[i].last = at
            return
        }
        let clean = Self.redact(detail)
        entries.append(TaskEvent(kind: kind, stepKey: step, code: String(code.prefix(60)), detail: clean, first: at, last: at, count: 1))
        if kind.isAggregatable { openAggregate[key] = entries.count - 1 }
        if entries.count > capacity { evict() }
    }

    private mutating func evict() {
        // remove the oldest AGGREGATABLE entry; if every entry is important, remove the oldest of all (still counted)
        let victim = entries.firstIndex { $0.kind.isAggregatable } ?? 0
        dropped += entries[victim].count
        entries.remove(at: victim)
        openAggregate = [:]
        for (i, e) in entries.enumerated() where e.kind.isAggregatable { openAggregate["\(e.kind.rawValue)|\(e.stepKey ?? "")|\(e.code)"] = i }
    }

    static func redact(_ s: String) -> String {
        let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? Unicode.Scalar(32) : $0 }))
        let clipped = String(cleaned.prefix(maxDetail))
        return SecretGate.containsSecret(clipped) ? "<redacted>" : clipped
    }

    /// "same failure ×17 (first 02:11, last 04:40)"-style summary lines for the UI / report; counts, not repeats.
    func summaryLines(language l: ReplyLanguage, clock: (Date) -> String = { "\(Int($0.timeIntervalSince1970))" }) -> [String] {
        entries.filter { $0.count > 1 }.map { e in
            l == .tr ? "Aynı olay ×\(e.count): \(e.code) (ilk \(clock(e.first)), son \(clock(e.last)))" : "Same event ×\(e.count): \(e.code) (first \(clock(e.first)), last \(clock(e.last)))"
        }
    }

    func count(of kind: TaskEventKind) -> Int { entries.filter { $0.kind == kind }.reduce(0) { $0 + $1.count } }
}

// MARK: - Which events deserve a notification (retries never do)

enum NotificationWorthiness: Equatable, Sendable { case notify(String), silent }

struct NotificationPolicy: Equatable, Sendable {
    var minimumInterval: TimeInterval = 15 * 60
    private(set) var lastSent: [String: Date] = [:]

    /// completed, needs the person (blocked / approval), critical approval, terminal failure — nothing else. Rate-limited per class so a flapping task cannot spam.
    mutating func evaluate(_ kind: TaskEventKind, critical: Bool = false, at: Date) -> NotificationWorthiness {
        let cls: String
        switch kind {
        case .taskCompleted: cls = "completed"
        case .taskFailed: cls = "failed"
        case .blocked: cls = "blocked"
        case .approvalRequested: cls = critical ? "critical-approval" : "approval"
        case .budgetExhausted: cls = "blocked"
        default: return .silent
        }
        if let prev = lastSent[cls], at.timeIntervalSince(prev) < minimumInterval, cls != "critical-approval", cls != "completed", cls != "failed" { return .silent }
        lastSent[cls] = at
        return .notify(cls)
    }
}
