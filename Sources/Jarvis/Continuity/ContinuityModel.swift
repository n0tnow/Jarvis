import Foundation

// MARK: - Project Continuity (V0.13, DEC-191…)
//
// A project OPERATOR resumes real work. Continuity is a DERIVED view: it is rebuilt from current project truth (files, Git, the Unity descriptor), the task history, the last
// checkpoint and project memory. It owns almost no state of its own — only the checkpoints (what a session left behind) are persisted, because they cannot be derived cheaply.
// Memory is context, never truth: where the two disagree the current project wins, and the disagreement is reported.

enum ContinuityLimits {
    static let recentTasks = 8
    static let maxCandidates = 6
    /// A failed task is a retry candidate only while it is recent and has not already been retried.
    static let failedRetryWindow: TimeInterval = 7 * 86_400
    static let maxRetriesPerGoal = 1
    static let maxFileHashes = 200
    static let maxChangedLines = 6
    static let maxReplyChars = 700
}

/// The bounds of ONE continuation session. "Continue" is bounded project authority, not "work forever": the user simply says "continue" again for the next session.
struct ContinuationBounds: Codable, Equatable, Sendable {
    var wallClockSeconds: TimeInterval
    var maxNodes: Int
    var maxRevisions: Int
    var maxCorrectionRounds: Int
    var maxExperiments: Int

    static let standard = ContinuationBounds(wallClockSeconds: 30 * 60, maxNodes: OrchestrationLimits.maxNodes, maxRevisions: OrchestrationLimits.maxRevisions,
                                             maxCorrectionRounds: 2, maxExperiments: 2)
    var summary: String { "≤ \(Int(wallClockSeconds / 60)) min · ≤ \(maxNodes) steps · ≤ \(maxRevisions) revisions · ≤ \(maxCorrectionRounds) correction rounds · ≤ \(maxExperiments) experiments" }
}

/// Persisted on the task (as a constraint) so a continuation session stays bounded across a restart. It adds no capability.
enum ContinuationMarker { static let constraint = "continuation session (bounded)" }

// MARK: Facts about the project right now

struct ContinuityGit: Codable, Equatable, Sendable {
    var isRepository: Bool
    var branch: String?
    var head: String?
    var subject: String?
    var dirtyPaths: [String]
    var untrackedPaths: [String]
    static let none = ContinuityGit(isRepository: false, branch: nil, head: nil, subject: nil, dirtyPaths: [], untrackedPaths: [])
    var isClean: Bool { dirtyPaths.isEmpty && untrackedPaths.isEmpty }
    var shortHead: String? { head.map { String($0.prefix(7)) } }
}

struct ContinuityUnity: Codable, Equatable, Sendable {
    var version: String?
    var renderPipeline: String
    var packageCount: Int
    var sceneCount: Int
    var bridgeInstalled: Bool
    var hasTests: Bool
    /// "NOT RUNNING" / "CONNECTED" / "PLAY MODE" … as the Unity service reports it (live state, not persisted).
    var editor: String?
}

/// CURRENT truth gathered for one reconciliation. Every field is read from the project itself.
struct ProjectSnapshot: Equatable, Sendable {
    var root: String
    var git: ContinuityGit
    /// path → short content hash for the paths a checkpoint cares about (the files a session changed + the dirty set).
    var fileHashes: [String: String]
    /// Non-Git projects: one cheap fingerprint of the source tree (path + size + mtime).
    var treeFingerprint: String?
    var unity: ContinuityUnity?
    var capturedAt = Date()
}

// MARK: Tasks, as the continuity layer sees them

struct TaskDigest: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var goal: String
    var kind: String
    var state: TaskState
    var failureCategory: String?
    var failureReason: String?
    var summary: String?
    var updatedAt: Date
    var finishedAt: Date?
    var originTaskID: UUID?
    /// Started by a “continue”. A failed continuation that is itself a retry is never retried again (one retry per failure, then the user decides).
    var isContinuation = false
    var stepsPassed: Int = 0
    var stepsTotal: Int = 0

    init(_ t: TaskRecord, passed: Int = 0, total: Int = 0) {
        id = t.id; title = t.title; goal = t.goal; kind = t.kind.rawValue; state = t.state
        failureCategory = t.failureCategory?.rawValue; failureReason = t.failureReason; summary = t.summary
        updatedAt = t.updatedAt; finishedAt = t.finishedAt; originTaskID = t.originTaskID; isContinuation = t.constraints.contains(ContinuationMarker.constraint); stepsPassed = passed; stepsTotal = total
    }
    init(id: UUID = UUID(), title: String, goal: String? = nil, kind: String = "development", state: TaskState, failureCategory: String? = nil, failureReason: String? = nil,
         summary: String? = nil, updatedAt: Date = Date(), finishedAt: Date? = nil, originTaskID: UUID? = nil, isContinuation: Bool = false, passed: Int = 0, total: Int = 0) {
        self.id = id; self.title = title; self.goal = goal ?? title; self.kind = kind; self.state = state; self.failureCategory = failureCategory; self.failureReason = failureReason
        self.summary = summary; self.updatedAt = updatedAt; self.finishedAt = finishedAt ?? (state.isTerminal ? updatedAt : nil); self.originTaskID = originTaskID; self.isContinuation = isContinuation
        stepsPassed = passed; stepsTotal = total
    }
}

/// A memory record reduced to what continuity needs (never the full item; never an instruction).
struct MemoryDigest: Equatable, Sendable {
    var type: MemoryType
    var subject: String
    var summary: String
    var key: String?
    var value: String?
    var importance: MemoryImportance
    var updatedAt: Date
    var isPinned = false
    init(_ m: MemoryItem) { type = m.type; subject = m.subject; summary = m.summary; key = m.key; value = m.value; importance = m.importance; updatedAt = m.updatedAt; isPinned = m.pinned }
    init(type: MemoryType, subject: String, summary: String, key: String? = nil, value: String? = nil, importance: MemoryImportance = .normal, updatedAt: Date = Date()) {
        self.type = type; self.subject = subject; self.summary = summary; self.key = key; self.value = value; self.importance = importance; self.updatedAt = updatedAt
    }
}

// MARK: Checkpoint (the only persisted continuity state)

/// What a finished session left behind: enough to answer "what changed, what was validated, what remains, what is next, what Git/Unity state was left, are approvals open,
/// were experiments inconclusive?" — and to detect, next time, that someone else touched the project. No chain-of-thought, no screenshots, no raw output.
struct ContinuityCheckpoint: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var projectKey: String
    var taskID: UUID?
    var createdAt = Date()
    /// "task" (an ordinary finished task) or "continuation" (a continuation session).
    var kind = "task"
    var outcome: String                     // SUCCESS / PARTIAL / FAILED / STOPPED / INTERRUPTED
    var title: String
    var gitHead: String?
    var gitBranch: String?
    var dirtyPaths: [String] = []
    var fileHashes: [String: String] = [:]
    var treeFingerprint: String?
    var changed: [String] = []
    var validated: [String] = []
    var remaining: [String] = []
    var next: [String] = []
    var unresolvedApprovals = 0
    var inconclusive: [String] = []
    var unity: [String] = []
    var summary: String = ""
}

// MARK: Candidates and decisions

struct NextCandidate: Codable, Equatable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable { case interrupted, checkpoint, failed, knownIssue }
    var id: String
    var source: Source
    var title: String
    var detail: String
    var taskID: UUID?
    /// A major design direction (art direction, core mechanic, architecture, render pipeline, large deletion): JARVIS proposes, the user decides.
    var designSensitive = false
}

enum ContinuationDecision: Equatable, Sendable {
    /// An INTERRUPTED task of this project: the user's "continue" is the explicit Resume (the engine re-validates what it had already done).
    case resumeInterrupted(TaskDigest)
    /// An INTERRUPTED task whose files the project changed under it: the old plan is not trusted; a fresh task starts from the same goal.
    case replanInterrupted(TaskDigest, drift: [String])
    /// The last attempt failed for a reason that a second try can address; the failure evidence goes into the new goal.
    case retryFailed(TaskDigest)
    case startNext(NextCandidate)
    /// Several equally meaningful directions (or a design-sensitive one): JARVIS asks, it does not invent.
    case needsChoice([NextCandidate])
    case nothingToContinue(String)
    case alreadyRunning(TaskDigest)
}

struct ReconciliationReport: Equatable, Sendable {
    var firstSession = false
    var headMoved = false
    var changedPaths: [String] = []
    /// Memory said one thing, the project says another (the project wins; the memory item is superseded by the existing memory reconcile).
    var memoryCorrections: [String] = []
    /// What was actually consulted — shown in developer diagnostics.
    var sources: [String] = []
    var hasDrift: Bool { headMoved || !changedPaths.isEmpty }
    var lines: [String] {
        var l: [String] = []
        if headMoved { l.append("Git HEAD moved since the last checkpoint") }
        l += changedPaths.prefix(ContinuityLimits.maxChangedLines).map { "changed outside JARVIS: \($0)" }
        if changedPaths.count > ContinuityLimits.maxChangedLines { l.append("… and \(changedPaths.count - ContinuityLimits.maxChangedLines) more") }
        l += memoryCorrections
        return l
    }
}

struct RecordedNext: Equatable, Sendable { var text: String; var origin: String }

/// The derived project view.
struct ProjectContinuityView: Equatable, Sendable {
    var projectKey: String
    var name: String
    var root: String
    var aliases: [String] = []
    var projectType: String = "folder"            // unity · git · folder
    var primaryGoal: String?
    var milestone: String?
    var checkpoint: ContinuityCheckpoint?
    var git: ContinuityGit = .none
    var recentCompleted: [TaskDigest] = []
    var interrupted: [TaskDigest] = []
    var failed: [TaskDigest] = []
    var running: [TaskDigest] = []
    var openIssues: [String] = []
    var blockers: [String] = []
    var currentWork: [String] = []
    var candidates: [NextCandidate] = []
    var recordedNext: [RecordedNext] = []
    var constraints: [String] = []
    var decisions: [String] = []
    var validations: [String] = []
    var unity: ContinuityUnity?
    var lastContinuationAt: Date?
    var pendingApprovals = 0
}

// MARK: Project documents (conventional files that name the milestone / goal)

struct ProjectDocsSummary: Equatable, Sendable {
    var milestone: String?
    var goal: String?
    /// The “Next Step” / “Remaining Work” lines and unchecked TODO boxes the project's own docs list (bounded).
    var next: [String] = []

    /// Bounded, deterministic: only conventional status files, only their first lines. Never executed, never sent anywhere.
    static func read(root: String) -> ProjectDocsSummary {
        func lines(_ rel: String) -> [String] {
            guard let d = FileManager.default.contents(atPath: root + "/" + rel), let s = String(data: d.prefix(8_000), encoding: .utf8) else { return [] }
            return s.split(separator: "\n", omittingEmptySubsequences: false).prefix(60).map(String.init)
        }
        func value(after label: String, in ls: [String]) -> String? {
            guard let i = ls.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(label.lowercased()) }) else { return nil }
            let same = ls[i].split(separator: ":", maxSplits: 1).dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if !same.isEmpty { return String(OutputSanitizer.sanitize(same).prefix(160)) }
            return ls.dropFirst(i + 1).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map { String(OutputSanitizer.sanitize($0.trimmingCharacters(in: .whitespaces)).prefix(160)) }
        }
        let current = lines("docs/CURRENT_TASK.md")
        var s = ProjectDocsSummary(milestone: value(after: "Version", in: current), goal: value(after: "Task", in: current))
        if s.milestone == nil || s.goal == nil {
            let state = lines("PROJECT_STATE.md")
            if s.milestone == nil { s.milestone = value(after: "Current milestone", in: state) ?? value(after: "Milestone", in: state) }
            if s.goal == nil { s.goal = value(after: "Goal", in: state) }
        }
        s.next = nextItems(root: root, current: current)
        return s
    }

    /// Conventional places a project lists what comes next. Read as DATA: a line here can name work, it can never grant anything.
    static func nextItems(root: String, current: [String]) -> [String] {
        var out: [String] = []
        func clean(_ x: String) -> String? {
            let t = OutputSanitizer.sanitize(x.trimmingCharacters(in: CharacterSet(charactersIn: " \t-*•>[]x")).trimmingCharacters(in: .whitespaces))
            return t.count >= 4 && !t.hasSuffix(":") ? String(t.prefix(140)) : nil
        }
        for label in ["Next Step", "Next Steps", "Remaining Work"] {
            guard let i = current.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(label.lowercased() + ":") }) else { continue }
            let same = current[i].split(separator: ":", maxSplits: 1).dropFirst().first.map { String($0) } ?? ""
            if let c = clean(same) { out.append(c) }
            for line in current.dropFirst(i + 1).prefix(6) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { if !out.isEmpty { break } else { continue } }
                if t.hasSuffix(":") && !t.hasPrefix("-") { break }
                if let c = clean(t) { out.append(c) }
            }
        }
        if let d = FileManager.default.contents(atPath: root + "/TODO.md"), let text = String(data: d.prefix(8_000), encoding: .utf8) {
            for line in text.split(separator: "\n").prefix(80) where line.trimmingCharacters(in: .whitespaces).hasPrefix("- [ ]") { if let c = clean(String(line.dropFirst(line.firstIndex(of: "]").map { line.distance(from: line.startIndex, to: $0) + 1 } ?? 0))) { out.append(c) } }
        }
        var seen = Set<String>()
        return out.filter { seen.insert(ResearchText.fold($0)).inserted }.prefix(5).map { $0 }
    }
}
