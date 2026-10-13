import Foundation

// MARK: - Pure continuity logic (V0.13)
//
// Everything here is a pure function of plain data, so it is unit-tested without a project, a database or a model:
//   • ContinuityBuilder   — inputs → the derived project view
//   • ContinuityReconciler — expected state (checkpoint + what JARVIS did since) vs CURRENT project state → drift
//   • ContinuationSelector — what "continue" means (interrupted → failed → accepted next → known issue), never inventing a direction
//   • ContinuityStatus    — the short factual answer (EN/TR), no model
//   • ContinuationGoal    — the bounded goal text handed to the normal V0.4/V0.12 task path

enum MajorDesign {
    /// Direction changes JARVIS may PROPOSE but never decide under a plain "continue": art direction, main character, core mechanic, networking architecture, render
    /// pipeline, redesigning a whole scene, deleting a large content set.
    static func isMajor(_ text: String) -> Bool {
        let t = ResearchText.fold(text)
        let verbs = ["replace", "redesign", "rewrite", "overhaul", "migrate", "switch to", "swap", "rebuild", "yeniden tasarla", "degistir", "gecis", "yeniden yaz", "sil", "delete all", "remove all"]
        let subjects = ["art direction", "art style", "main character", "player character", "core mechanic", "gameplay loop", "networking", "netcode", "render pipeline", "urp", "hdrp", "architecture",
                        "whole scene", "entire scene", "all scenes", "tum sahne", "bütün", "butun", "mimari", "ana karakter", "oyun mekanigi", "sanat"]
        return verbs.contains { t.contains($0) } && subjects.contains { t.contains($0) }
    }
}

// MARK: Builder

enum ContinuityBuilder {
    struct Inputs {
        var key: String
        var name: String
        var root: String
        var aliases: [String] = []
        var docs: ProjectDocsSummary?
        /// Root tasks of this project, newest first.
        var tasks: [TaskDigest] = []
        var checkpoint: ContinuityCheckpoint?
        /// Steps the USER queued (“next up is …”) — an accepted next task.
        var queue: [String] = []
        var lastContinuationAt: Date?
        var git: ContinuityGit = .none
        var unity: ContinuityUnity?
        var memory: [MemoryDigest] = []
        var pendingApprovals = 0
        var now = Date()
    }

    /// Non-retryable failures need a decision from the user (policy, approvals, capability); retrying them blindly would just hit the same wall.
    static let userDecisionFailures: Set<String> = Set([FailureCategory.securityBlocked, .capabilityDenied, .approvalDenied, .workspaceViolation, .scopeExceeded, .cancelled].map(\.rawValue))

    static func build(_ i: Inputs) -> ProjectContinuityView {
        var v = ProjectContinuityView(projectKey: i.key, name: i.name, root: i.root)
        v.aliases = i.aliases
        v.projectType = i.unity != nil ? "unity" : (i.git.isRepository ? "git" : "folder")
        v.primaryGoal = i.docs?.goal
        v.milestone = i.docs?.milestone
        v.checkpoint = i.checkpoint
        v.git = i.git
        v.unity = i.unity
        v.lastContinuationAt = i.lastContinuationAt
        v.pendingApprovals = i.pendingApprovals

        let followedBy = Dictionary(grouping: i.tasks.compactMap { t in t.originTaskID.map { ($0, t) } }, by: { $0.0 }).mapValues { $0.map(\.1) }
        let actionable: Set<String> = [TaskKind.development.rawValue, TaskKind.readOnlyAnalysis.rawValue]
        let mine = i.tasks.filter { actionable.contains($0.kind) }
        v.running = mine.filter { $0.state.isActive }
        v.recentCompleted = Array(mine.filter { $0.state == .completed }.prefix(3))
        v.interrupted = mine.filter { $0.state == .interrupted && (followedBy[$0.id] ?? []).isEmpty }
        let retriable = mine.filter { t in
            t.state == .failed && now(i, t) <= ContinuityLimits.failedRetryWindow && (followedBy[t.id] ?? []).count < ContinuityLimits.maxRetriesPerGoal
                && !userDecisionFailures.contains(t.failureCategory ?? "") && !(t.isContinuation && t.originTaskID != nil)
        }
        v.failed = retriable
        let blocked = mine.filter { $0.state == .failed && userDecisionFailures.contains($0.failureCategory ?? "") && (followedBy[$0.id] ?? []).isEmpty && now(i, $0) <= ContinuityLimits.failedRetryWindow }
        v.blockers = blocked.prefix(2).map { "“\($0.title)” needs your decision (\($0.failureCategory ?? "blocked"))" } + (i.pendingApprovals > 0 ? ["\(i.pendingApprovals) approval(s) waiting in the HUD"] : [])

        let live = i.memory
        v.openIssues = live.filter { $0.type == .knownIssue }.sorted { ($0.importance, $0.updatedAt) > ($1.importance, $1.updatedAt) }.prefix(5).map { MemoryText.clip($0.summary, 140) }
        v.constraints = live.filter { $0.type == .constraint }.sorted { ($0.isPinned ? 1 : 0, $0.importance) > ($1.isPinned ? 1 : 0, $1.importance) }.prefix(4).map { MemoryText.clip($0.summary, 140) }
        v.decisions = live.filter { $0.type == .decision }.sorted { $0.updatedAt > $1.updatedAt }.prefix(3).map { MemoryText.clip($0.summary, 140) }
        v.validations = (i.checkpoint?.validated ?? []).prefix(4).map { $0 } + live.filter { $0.type == .validationResult }.sorted { $0.updatedAt > $1.updatedAt }.prefix(2).map { MemoryText.clip($0.summary, 120) }
        v.currentWork = (v.running + v.interrupted).prefix(3).map(\.title)
        var seenNext = Set<String>()
        for (text, origin) in i.queue.map({ ($0, "queued by you") }) + (i.checkpoint?.next ?? []).map({ ($0, "recorded at the last checkpoint") }) + (i.docs?.next ?? []).map({ ($0, "listed in the project docs") }) {
            if seenNext.insert(ResearchText.fold(text).filter { $0.isLetter || $0.isNumber }).inserted { v.recordedNext.append(RecordedNext(text: text, origin: origin)) }
        }
        v.candidates = ContinuationSelector.candidates(v)
        return v
    }

    private static func now(_ i: Inputs, _ t: TaskDigest) -> TimeInterval { i.now.timeIntervalSince(t.finishedAt ?? t.updatedAt) }
}

// MARK: Reconciliation

/// What the project SHOULD look like if nobody but JARVIS touched it since the last checkpoint.
struct ExpectedState: Equatable, Sendable {
    var head: String?
    var dirtyPaths: Set<String>
    /// Hashes JARVIS recorded for the files it changed (checkpoint hashes overlaid with the after-hashes of later JARVIS tasks).
    var hashes: [String: String]
    var fingerprint: String?
    var hasCheckpoint: Bool

    init(checkpoint: ContinuityCheckpoint?, laterChanges: [String: String] = [:]) {
        head = checkpoint?.gitHead
        dirtyPaths = Set(checkpoint?.dirtyPaths ?? [])
        hashes = (checkpoint?.fileHashes ?? [:]).merging(laterChanges) { _, new in new }
        fingerprint = checkpoint?.treeFingerprint
        hasCheckpoint = checkpoint != nil
    }
}

enum ContinuityReconciler {
    /// Current truth wins. Memory corrections (already computed against the probes) are carried through as report lines.
    static func reconcile(expected e: ExpectedState, current c: ProjectSnapshot, committedSince: [String] = [], memoryCorrections: [String] = []) -> ReconciliationReport {
        var r = ReconciliationReport()
        r.memoryCorrections = memoryCorrections
        r.sources = ["files", c.git.isRepository ? "git" : "tree", c.unity != nil ? "unity descriptor" : nil, "tasks", "memory"].compactMap { $0 }
        guard e.hasCheckpoint else { r.firstSession = true; return r }
        if c.git.isRepository {
            if let eh = e.head, let ch = c.git.head, eh != ch { r.headMoved = true }
            var changed: Set<String> = []
            for (path, hash) in e.hashes {
                if let now = c.fileHashes[path] { if now != hash { changed.insert(path) } } else if hash != "deleted" { changed.insert(path) }       // a file JARVIS wrote has vanished
            }
            // Anything dirty now that was neither dirty at the checkpoint nor written by JARVIS is somebody else's work.
            for p in (c.git.dirtyPaths + c.git.untrackedPaths) where !e.dirtyPaths.contains(p) && e.hashes[p] == nil { changed.insert(p) }
            // A checkpoint-dirty path whose content moved on (no recorded hash to compare): visible through the hash map only; covered above when hashed.
            // Files an external commit touched after the checkpoint (JARVIS-written ones are judged by their hashes above, not by the commit).
            for p in committedSince where e.hashes[p] == nil { changed.insert(p) }
            r.changedPaths = changed.sorted()
        } else if let ef = e.fingerprint, let cf = c.treeFingerprint, ef != cf {
            r.changedPaths = ["the project files (no Git to say which)"]
        }
        return r
    }
}

// MARK: Selection

enum ContinuationSelector {
    /// All candidate directions, highest tier first. Tiers: unfinished (interrupted) → failed-and-retriable → accepted next steps → known issues.
    static func candidates(_ v: ProjectContinuityView) -> [NextCandidate] {
        var out: [NextCandidate] = []
        var seen = Set<String>()
        func add(_ c: NextCandidate) {
            let k = ResearchText.fold(c.title).filter { $0.isLetter || $0.isNumber }
            guard !k.isEmpty, seen.insert(k).inserted else { return }
            var c = c; c.designSensitive = MajorDesign.isMajor(c.title + " " + c.detail)
            out.append(c)
        }
        for t in v.interrupted { add(NextCandidate(id: "interrupted:\(t.id)", source: .interrupted, title: t.title, detail: "interrupted at \(t.stepsPassed)/\(t.stepsTotal) steps", taskID: t.id)) }
        for t in v.failed { add(NextCandidate(id: "failed:\(t.id)", source: .failed, title: t.title, detail: "failed: \(MemoryText.clip(t.failureReason ?? t.failureCategory ?? "unknown", 120))", taskID: t.id)) }
        for (n, s) in v.recordedNext.prefix(ContinuityLimits.maxCandidates).enumerated() { add(NextCandidate(id: "next:\(n)", source: .checkpoint, title: s.text, detail: s.origin)) }
        for (n, s) in v.openIssues.prefix(3).enumerated() { add(NextCandidate(id: "issue:\(n)", source: .knownIssue, title: s, detail: "open issue from project memory")) }
        return Array(out.prefix(ContinuityLimits.maxCandidates))
    }

    static func decide(_ v: ProjectContinuityView, drift r: ReconciliationReport) -> ContinuationDecision {
        if let running = v.running.first { return .alreadyRunning(running) }
        let all = v.candidates
        guard let top = all.first?.source else {
            return .nothingToContinue(v.blockers.first ?? "There is no unfinished work, failed task or recorded next step for this project.")
        }
        let tier = all.filter { $0.source == top }
        if tier.count > 1 { return .needsChoice(Array(tier.prefix(3))) }
        let only = tier[0]
        // Several tiers are NOT several directions: the highest tier is the unfinished business. Only a design-sensitive choice is never taken for the user.
        if only.designSensitive { return .needsChoice([only]) }
        switch only.source {
        case .interrupted:
            guard let t = v.interrupted.first(where: { $0.id == only.taskID }) else { return .needsChoice([only]) }
            return r.hasDrift ? .replanInterrupted(t, drift: r.lines) : .resumeInterrupted(t)
        case .failed:
            guard let t = v.failed.first(where: { $0.id == only.taskID }) else { return .needsChoice([only]) }
            return .retryFailed(t)
        case .checkpoint, .knownIssue:
            return .startNext(only)
        }
    }
}

// MARK: Goal text for the normal task path

enum ContinuationGoal {
    /// The goal handed to `TaskEngine.submit`. It is ordinary user-level text derived from records; it grants nothing (capabilities come from the task kind and policy).
    static func build(_ d: ContinuationDecision, view v: ProjectContinuityView, drift r: ReconciliationReport, bounds: ContinuationBounds = .standard) -> String? {
        var lines: [String] = []
        switch d {
        case .resumeInterrupted, .alreadyRunning, .nothingToContinue, .needsChoice: return nil
        case .replanInterrupted(let t, _):
            lines.append(t.goal)
            lines.append("This continues the interrupted task “\(t.title)” (\(t.stepsPassed)/\(t.stepsTotal) steps were validated). The project changed since — re-read the current files before changing anything and do not assume the old plan still fits.")
        case .retryFailed(let t):
            lines.append(t.goal)
            lines.append("The previous attempt (“\(t.title)”) failed: \(MemoryText.clip(t.failureReason ?? t.failureCategory ?? "unknown", 240)). Find out why before trying again and do not repeat the same approach.")
        case .startNext(let c):
            lines.append(c.title)
            lines.append("This is the next step recorded for the project (\(c.detail)).")
        }
        if r.hasDrift { lines.append("Changed outside JARVIS since the last checkpoint: " + r.changedPaths.prefix(6).joined(separator: ", ") + (r.headMoved ? "; Git HEAD moved" : "") + ".") }
        if !v.constraints.isEmpty { lines.append("Project constraints to respect: " + v.constraints.prefix(3).joined(separator: " · ")) }
        lines.append("Session bounds: \(bounds.summary). Do not change the project's core design; propose it instead.")
        return OutputSanitizer.sanitize(lines.joined(separator: "\n"))
    }
}

// MARK: Status answers

enum ContinuityStatus {
    private static func tr(_ l: ReplyLanguage, _ en: String, _ trk: String) -> String { l == .tr ? trk : en }

    static func ago(_ d: Date?, now: Date = Date(), _ l: ReplyLanguage) -> String {
        guard let d else { return tr(l, "earlier", "daha önce") }
        let s = max(0, now.timeIntervalSince(d))
        switch s {
        case ..<90: return tr(l, "just now", "az önce")
        case ..<5_400: return tr(l, "\(Int(s / 60)) min ago", "\(Int(s / 60)) dk önce")
        case ..<172_800: return tr(l, "\(Int(s / 3600)) h ago", "\(Int(s / 3600)) saat önce")
        default: return tr(l, "\(Int(s / 86_400)) days ago", "\(Int(s / 86_400)) gün önce")
        }
    }

    static func gitLine(_ g: ContinuityGit, _ l: ReplyLanguage) -> String? {
        guard g.isRepository else { return nil }
        let where_ = [g.branch, g.shortHead].compactMap { $0 }.joined(separator: "@")
        let n = g.dirtyPaths.count + g.untrackedPaths.count
        return n == 0 ? tr(l, "Git is clean (\(where_)).", "Git temiz (\(where_)).") : tr(l, "Git: \(n) uncommitted change\(n == 1 ? "" : "s") (\(where_)).", "Git: \(n) kaydedilmemiş değişiklik (\(where_)).")
    }

    /// The short, factual answer to “where are we?”. Every sentence comes from a record or a probe.
    static func summary(_ v: ProjectContinuityView, drift r: ReconciliationReport?, language l: ReplyLanguage, detailed: Bool = false, now: Date = Date()) -> String {
        var parts: [String] = []
        if let t = v.recentCompleted.first {
            let tests = (v.checkpoint?.validated ?? []).first(where: { $0.lowercased().hasPrefix("tests") })
            parts.append(tr(l, "\(v.name): the last validated work was “\(t.title)” (\(ago(t.finishedAt ?? t.updatedAt, now: now, l))\(tests.map { ", " + $0.lowercased() } ?? "")).",
                            "\(v.name): son doğrulanan iş “\(t.title)” (\(ago(t.finishedAt ?? t.updatedAt, now: now, l))\(tests.map { ", " + $0.lowercased() } ?? "")).")) }
        else if let c = v.checkpoint { parts.append(tr(l, "\(v.name): the last checkpoint is “\(c.title)” (\(ago(c.createdAt, now: now, l)), \(c.outcome.lowercased())).", "\(v.name): son kayıt “\(c.title)” (\(ago(c.createdAt, now: now, l)), \(c.outcome.lowercased())).")) }
        else { parts.append(tr(l, "\(v.name): I have no finished work recorded for this project yet.", "\(v.name): bu proje için henüz kayıtlı tamamlanmış bir iş yok.")) }
        if let m = v.milestone, detailed || v.recentCompleted.isEmpty { parts.append(tr(l, "Milestone: \(m).", "Aşama: \(m).")) }
        if let g = gitLine(v.git, l) { parts.append(g) }
        if let u = v.unity { parts.append(tr(l, "Unity \(u.version ?? "?") · \(u.renderPipeline)\(u.editor.map { " · editor \($0.lowercased())" } ?? "").", "Unity \(u.version ?? "?") · \(u.renderPipeline)\(u.editor.map { " · editor \($0.lowercased())" } ?? "").")) }
        if let t = v.running.first { parts.append(tr(l, "Right now: “\(t.title)” is running.", "Şu an “\(t.title)” çalışıyor.")) }
        for t in v.interrupted.prefix(2) { parts.append(tr(l, "Unfinished: “\(t.title)” was interrupted.", "Yarım kalan: “\(t.title)” kesintiye uğradı.")) }
        for t in v.failed.prefix(1) { parts.append(tr(l, "Failed: “\(t.title)” (\(MemoryText.clip(t.failureReason ?? t.failureCategory ?? "unknown", 80))).", "Başarısız: “\(t.title)” (\(MemoryText.clip(t.failureReason ?? t.failureCategory ?? "bilinmiyor", 80))).")) }
        for b in v.blockers.prefix(1) { parts.append(tr(l, "Waiting on you: \(b).", "Sizden bekleyen: \(b).")) }
        if let next = v.candidates.first(where: { $0.source == .checkpoint }) ?? v.candidates.first(where: { $0.source == .knownIssue }) {
            parts.append(tr(l, "Next: \(MemoryText.clip(next.title, 110)).", "Sırada: \(MemoryText.clip(next.title, 110)).")) }
        if let r, r.hasDrift {
            parts.append(tr(l, "The project changed outside JARVIS since then (\(r.changedPaths.count) file\(r.changedPaths.count == 1 ? "" : "s")\(r.headMoved ? ", Git HEAD moved" : "")); I would re-read it before continuing.",
                            "Proje o zamandan beri JARVIS dışında değişmiş (\(r.changedPaths.count) dosya\(r.headMoved ? ", Git HEAD ilerlemiş" : "")); devam etmeden önce yeniden okurum."))
        }
        if detailed {
            if let g = v.primaryGoal { parts.append(tr(l, "Goal: \(g).", "Hedef: \(g).")) }
            if !v.decisions.isEmpty { parts.append(tr(l, "Decisions: " + v.decisions.joined(separator: " · "), "Kararlar: " + v.decisions.joined(separator: " · "))) }
            if !v.constraints.isEmpty { parts.append(tr(l, "Constraints: " + v.constraints.joined(separator: " · "), "Kısıtlar: " + v.constraints.joined(separator: " · "))) }
            if !v.openIssues.isEmpty { parts.append(tr(l, "Open issues: " + v.openIssues.prefix(3).joined(separator: " · "), "Açık sorunlar: " + v.openIssues.prefix(3).joined(separator: " · "))) }
            if let c = v.checkpoint, !c.inconclusive.isEmpty { parts.append(tr(l, "Inconclusive: " + c.inconclusive.joined(separator: "; "), "Sonuçsuz: " + c.inconclusive.joined(separator: "; "))) }
        }
        return OutputSanitizer.sanitize(String(parts.joined(separator: " ").prefix(detailed ? 1_600 : ContinuityLimits.maxReplyChars)))
    }

    static func lastDone(_ v: ProjectContinuityView, language l: ReplyLanguage, now: Date = Date()) -> String {
        guard let c = v.checkpoint else { return tr(l, "\(v.name): nothing is recorded as done yet.", "\(v.name): henüz kayıtlı bir iş yok.") }
        var s = tr(l, "\(v.name): last \(c.outcome.lowercased()) — “\(c.title)”, \(ago(c.createdAt, now: now, l)).", "\(v.name): son durum \(c.outcome.lowercased()) — “\(c.title)”, \(ago(c.createdAt, now: now, l)).")
        if !c.changed.isEmpty { s += tr(l, " Changed: \(c.changed.prefix(4).joined(separator: ", "))\(c.changed.count > 4 ? " +\(c.changed.count - 4)" : "").", " Değişenler: \(c.changed.prefix(4).joined(separator: ", "))\(c.changed.count > 4 ? " +\(c.changed.count - 4)" : "").") }
        if !c.validated.isEmpty { s += tr(l, " Validated: \(c.validated.prefix(3).joined(separator: "; ")).", " Doğrulanan: \(c.validated.prefix(3).joined(separator: "; ")).") }
        if !c.remaining.isEmpty { s += tr(l, " Remaining: \(c.remaining.prefix(3).joined(separator: "; ")).", " Kalan: \(c.remaining.prefix(3).joined(separator: "; ")).") }
        return OutputSanitizer.sanitize(String(s.prefix(ContinuityLimits.maxReplyChars)))
    }

    static func next(_ v: ProjectContinuityView, language l: ReplyLanguage) -> String {
        if v.candidates.isEmpty { return tr(l, "\(v.name): nothing is queued. Tell me what to work on.", "\(v.name): sırada kayıtlı bir iş yok. Ne yapmamı istediğinizi söyleyin.") }
        let list = v.candidates.prefix(3).enumerated().map { "\($0.offset + 1). \(MemoryText.clip($0.element.title, 90))" }.joined(separator: " ")
        return tr(l, "\(v.name) — up next: \(list)", "\(v.name) — sırada: \(list)")
    }

    static func choice(_ cs: [NextCandidate], view v: ProjectContinuityView, language l: ReplyLanguage) -> String {
        let list = cs.prefix(3).enumerated().map { "\($0.offset + 1). \(MemoryText.clip($0.element.title, 90))" }.joined(separator: " ")
        let design = cs.contains { $0.designSensitive }
        if design {
            return tr(l, "\(v.name): the next step changes the project's design (\(list)). I won't decide that under a plain “continue” — tell me explicitly which direction you want.",
                      "\(v.name): sıradaki adım projenin tasarımını değiştiriyor (\(list)). Düz bir “devam et” ile bunu ben seçmem; hangi yönü istediğinizi açıkça söyleyin.")
        }
        return tr(l, "\(v.name): several things are equally open — \(list) Which one should I take?", "\(v.name): birkaç iş aynı derecede açık — \(list) Hangisinden devam edeyim?")
    }
}

// MARK: Intent recognition (typed and spoken text alike)

enum ContinuityIntent: Equatable, Sendable {
    case status(project: String?, detailed: Bool)
    case lastDone(project: String?)
    case lastReport(project: String?, detailed: Bool)
    case next(project: String?)
    case continueProject(project: String?)
    /// “Next up is the pickup polish” — the USER queues an accepted next step (data for a later “continue”, never authority).
    case queueNext(project: String?, text: String)
    /// A follow-up to a question JARVIS asked (“which one?”): 1-based.
    case choose(Int)

    var project: String? {
        switch self {
        case .status(let p, _), .lastDone(let p), .lastReport(let p, _), .next(let p), .continueProject(let p), .queueNext(let p, _): p
        case .choose: nil
        }
    }

    /// “1”, “the first one”, “ilki”, “ikincisi”, “second” … (only consulted while a choice is pending).
    static func ordinal(_ raw: String) -> Int? {
        let t = fold(raw)
        let table: [(Int, [String])] = [(1, ["1", "one", "first", "the first", "first one", "the first one", "ilki", "birincisi", "birinci", "bir"]), (2, ["2", "two", "second", "the second", "second one", "the second one", "ikincisi", "ikinci", "iki"]),
                                         (3, ["3", "three", "third", "the third", "third one", "the third one", "ucuncusu", "ucuncu", "uc"])]
        return table.first { $0.1.contains(t) }?.0
    }

    /// The user states what comes next. Matched on the ORIGINAL text so the item keeps its wording.
    static func queueStatement(_ raw: String) -> String? {
        let patterns = ["^(?:jarvis[, ]+)?(?:next up(?: is)?|the next step is|next step is|next we (?:need|have) to|add to the queue|queue)\\s*[:,\\-]?\\s*(.{4,200}?)[.!]?$",
                        "^(?:jarvis[, ]+)?(?:s[iı]rada|s[iı]radaki (?:i[sş]|ad[iı]m)|sonraki ad[iı]m)\\s*[:,\\-]?\\s*(.{4,200}?)(?:\\s+var)?[.!]?$"]
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]), let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: t) else { continue }
            let item = String(t[r]).trimmingCharacters(in: .whitespaces)
            let f = fold(item)
            // questions are not statements: “sirada ne var”, “what is next”
            if f.hasPrefix("ne ") || f == "ne" || f.hasPrefix("what") || f.hasPrefix("is ") || item.hasSuffix("?") { return nil }
            return item
        }
        return nil
    }

    // MARK: Recognition

    private static func fold(_ s: String) -> String {
        var t = ResearchText.fold(s)
        for q in ["'", "’", "‘", "`"] { t = t.replacingOccurrences(of: q, with: "") }
        let cleaned = String(t.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return cleaned.split(separator: " ").joined(separator: " ")
    }

    private static let projectWords = ["proje", "project", "oyun", "game"]
    private static let leadFillers = ["jarvis", "tamam", "ok", "okay", "peki", "evet", "hey", "lutfen", "please", "simdi", "now", "hadi", "pekala", "iyi"]

    static func recognize(_ raw: String) -> ContinuityIntent? {
        let f = fold(raw)
        guard !f.isEmpty, f.count < 140 else { return nil }
        var words = f.split(separator: " ").map(String.init)
        while let w = words.first, leadFillers.contains(w) { words.removeFirst() }
        while let w = words.last, ["jarvis", "lutfen", "please", "efendim"].contains(w) { words.removeLast() }
        let t = words.joined(separator: " ")
        guard !t.isEmpty else { return nil }
        if let item = queueStatement(raw) { return .queueNext(project: projectName(in: t), text: item) }
        let project = projectName(in: t)
        let mentionsProject = words.contains { w in projectWords.contains { w.hasPrefix($0) } }

        // Continue — only a whole-utterance request (never a sentence that merely contains the word).
        let continueExact: Set<String> = ["devam et", "devam", "continue", "carry on", "go on", "devam edelim", "sonraki ise gec", "siradaki ise gec", "move on", "next task", "keep going", "sonraki is"]
        if continueExact.contains(t) { return .continueProject(project: nil) }
        let continuePhrases = ["kaldigimiz yerden devam", "kaldigimiz yerden surdur", "pick up where we left off", "continue where we left off", "continue from where we left off", "devam et projeye", "continue the project", "continue with the project",
                               "projeye devam", "projede devam", "projeyi devam", "continue working on the project", "resume the project", "resume work"]
        if continuePhrases.contains(where: { t.contains($0) }) || (words.first == "continue" && mentionsProject && words.count <= 5) || (t.hasSuffix("projesine devam et") || t.hasSuffix("projesine devam")) {
            return .continueProject(project: project)
        }

        // Detailed / last report
        let reportPhrases = ["son rapor", "son raporu", "last report", "latest report", "the last report", "son gorev raporu"]
        if reportPhrases.contains(where: { t.contains($0) }) { return .lastReport(project: project, detailed: t.contains("detay") || t.contains("detail")) }
        if (t.contains("detayli rapor") || t.contains("detailed report") || t.contains("detayli durum") || t.contains("detailed status")) && (mentionsProject || t.contains("durum") || t.contains("status")) {
            return .status(project: project, detailed: true)
        }

        // Where did we leave off / what did we do last
        let lastDonePhrases = ["en son ne yaptik", "son ne yaptik", "ne yapmistik", "what did we do last", "what did we do last time", "what did we last do", "what was the last thing we did", "what did we finish", "en son neydi"]
        if lastDonePhrases.contains(where: { t.contains($0) }) { return .lastDone(project: project) }
        let leftOff = ["nerede kalmistik", "nerede kaldik", "nerede birakmistik", "where did we leave off", "where we left off", "where were we", "where did we stop"]
        if leftOff.contains(where: { t.contains($0) }) { return .status(project: project, detailed: false) }

        // What is next
        let nextPhrases = ["simdi sirada ne var", "sirada ne var", "siradaki is ne", "siradaki is", "what is next", "whats next", "what is up next", "what should we do next", "what next", "sirada ne"]
        if nextPhrases.contains(where: { t.contains($0) }) { return .next(project: project) }

        // Status: needs a project cue, or the unmistakable "ne durumdayiz" / "where are we".
        let statusPhrases = ["ne durumdayiz", "durumdayiz", "ne durumda", "projenin durumu", "proje durumu", "project status", "status of the project", "status of the", "status of our", "where are we on", "where are we with", "where are we at", "how is the project", "how far are we",
                             "how is the project going", "nasil gidiyor", "neredeyiz", "ne asamadayiz", "ne asamada"]
        if statusPhrases.contains(where: { t.contains($0) }) {
            // "durum ne?" / "what are you doing?" stay the V0.12 TASK status; this is about the PROJECT.
            if mentionsProject || project != nil || t.contains("durumdayiz") || t.contains("where are we") || t.contains("neredeyiz") || t.contains("asamadayiz") || t.contains("how far are we") { return .status(project: project, detailed: t.contains("detay") || t.contains("detail")) }
        }
        return nil
    }

    /// "hamam projesinde ne durumdayız" → "hamam"; "status of the Hamam project" → "hamam". Only a candidate: the service matches it against KNOWN projects.
    static func projectName(in folded: String) -> String? {
        let words = folded.split(separator: " ").map(String.init)
        let stop: Set<String> = ["bu", "bizim", "the", "our", "my", "this", "that", "su", "projede", "projeye", "projesi", "projeyi", "proje", "project", "oyun", "game", "bizim", "benim", "on", "in", "of", "for", "icin", "ve", "ne", "nasil"]
        for (i, w) in words.enumerated() {
            let isProjectWord = ["projesinde", "projesine", "projesi", "projesini", "projemizde", "projemizin", "projemde", "projemizi", "oyununda", "oyunumuzda", "oyunumuzun"].contains(w)
            if isProjectWord, i > 0, !stop.contains(words[i - 1]) { return words[i - 1] }
            if ["project", "game"].contains(w), i > 0, !stop.contains(words[i - 1]), !["the", "our", "my"].contains(words[i - 1]) { return words[i - 1] }
        }
        return nil
    }
}


// MARK: Operator phase (the truthful high-level state shown while a session runs — no fake percentage)

enum OperatorPhase: String, Sendable {
    case planning = "Planning", observing = "Observing", editing = "Editing", testing = "Testing", inspecting = "Inspecting", correcting = "Correcting", experimenting = "Experimenting", waitingForApproval = "Waiting for approval"

    static func of(taskState: TaskState, step: TaskStepRecord?, repairing: Bool = false) -> OperatorPhase {
        if taskState == .waitingForApproval { return .waitingForApproval }
        if taskState == .created || taskState == .planning { return .planning }
        if repairing { return .correcting }
        guard let step else { return .planning }
        switch step.type {
        case .analysis, .researchSearch, .researchRead, .researchExtract, .researchVerify, .researchReport, .delegateResearch, .delegateComputer, .computerAct: return .observing
        case .codeChange, .unityEdit, .delete, .importAsset, .acquire: return .editing
        case .build, .test, .unityCompile, .unityTest: return .testing
        case .unityInspect, .unityValidate, .review, .unityPlayMode: return .inspecting
        case .approvalGate: return .waitingForApproval
        case .experiment: return .experimenting
        }
    }
}

extension TaskEngine {
    /// “Hamam · Continuing · Editing” for the Compact HUD while a continuation session runs.
    func compactOperatorLine(_ v: TaskView) -> String? {
        guard v.task.constraints.contains(ContinuationMarker.constraint), v.task.state.isActive || v.task.state == .waitingForApproval else { return nil }
        let name = ((v.task.workspaceRoot ?? "") as NSString).lastPathComponent
        let repairing = (contexts[v.id]?.repairCount ?? 0) > 0 && v.currentStep.map { $0.type == .codeChange } == true
        return "\(name.isEmpty ? "Project" : name) · Continuing · \(OperatorPhase.of(taskState: v.task.state, step: v.currentStep, repairing: repairing).rawValue)"
    }
}
