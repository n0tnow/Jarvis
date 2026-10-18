import Foundation

// MARK: - Rollback planning, temporary-artifact hygiene, commit verification, external-action policy
//
// Rollback is a PLAN, never a reset: it names exactly the files the TASK produced and can still be restored, and it refuses everything else. A file that was the user's own uncommitted work before
// the task, a file that changed again after the task wrote it, or a file for which no pre-task content is on record is NEVER reverted — the plan asks a person instead. There is no "restore the
// whole tree" operation anywhere in this layer; applying a plan is the engine's job through its guarded file tools (and approval where needed). Temporary artifacts are cleaned only when JARVIS
// created them and their content is still what JARVIS wrote; an unknown file is never deleted.

struct PreTaskBackup: Codable, Equatable, Sendable {
    var path: String
    var hash: String
    /// Whether the pre-task content is stored (a JARVIS-owned patch / backup artifact). Without it a modified file cannot be restored.
    var hasContent: Bool
}

enum RevertAction: Codable, Hashable, Sendable {
    /// Restore the file's pre-task content (it still equals what the task wrote).
    case restore(path: String, toHash: String)
    /// Remove a file the task created (it still equals what the task wrote).
    case removeCreated(path: String)
}

struct RollbackPlan: Codable, Equatable, Sendable {
    var revert: [RevertAction]
    /// Paths that need a person's decision, with the reason.
    var needsDecision: [String: String]
    /// Paths the plan will never touch (user's work, or not changed by the task).
    var untouchable: [String]
    var isSafeToApplyAutomatically: Bool { needsDecision.isEmpty }
}

enum RollbackPlanner {
    static func plan(attribution: AttributionReport, current: WorkspaceSnapshot, baseline: GitFacts, backups: [PreTaskBackup]) -> RollbackPlan {
        var revert: [RevertAction] = []
        var decide: [String: String] = [:]
        let userOwned = Set(baseline.dirty.union(baseline.untracked).union(baseline.staged).map(PathGlob.normalize))
        let backupFor = Dictionary(backups.map { (PathGlob.normalize($0.path), $0) }, uniquingKeysWith: { a, _ in a })
        for item in attribution.changes {
            let c = item.change
            let key = PathGlob.normalize(c.path)
            let now = current.files[c.path]?.hash
            switch item.attribution {
            case .unexplained:
                decide[c.path] = "changed during the task but not by an edit JARVIS applied: it may be someone else's work"
            case .taskTouchedUserDirty:
                if let b = backupFor[key], b.hasContent, now == c.afterHash { revert.append(.restore(path: c.path, toHash: b.hash)) }
                else { decide[c.path] = "the file held the user's own uncommitted work; without a stored pre-task copy it cannot be restored safely" }
            case .taskProduced:
                if now != c.afterHash { decide[c.path] = "the file changed again after the task wrote it"; continue }
                switch c.kind {
                case .created: revert.append(.removeCreated(path: c.path))
                case .modified, .deleted:
                    if let b = backupFor[key], b.hasContent, b.hash == c.beforeHash { revert.append(.restore(path: c.path, toHash: b.hash)) }
                    else { decide[c.path] = "no stored pre-task content for this file" }
                }
                if userOwned.contains(key), c.kind == .created { decide[c.path] = "an untracked file with this name existed before the task" ; revert.removeAll { if case .removeCreated(let p) = $0 { return PathGlob.normalize(p) == key }; return false } }
            }
        }
        let changed = Set(attribution.changes.map { PathGlob.normalize($0.change.path) })
        return RollbackPlan(revert: revert, needsDecision: decide, untouchable: attribution.preexistingUntouched.filter { !changed.contains(PathGlob.normalize($0)) })
    }
}

struct OwnedTemporary: Codable, Equatable, Sendable {
    var path: String
    var hash: String
    var taskID: UUID
}

struct TempArtifactRegistry: Codable, Equatable, Sendable {
    private(set) var owned: [String: OwnedTemporary] = [:]
    mutating func register(path: String, hash: String, taskID: UUID) { owned[PathGlob.normalize(path)] = OwnedTemporary(path: path, hash: hash, taskID: taskID) }

    struct CleanupPlan: Equatable, Sendable { var remove: [String]; var keep: [String: String] }

    /// Removable only when JARVIS registered it for this task AND the file still has the registered content. Everything else is kept.
    func cleanup(taskID: UUID, present: [String: String]) -> CleanupPlan {
        var remove: [String] = [], keep: [String: String] = [:]
        for (path, hash) in present.sorted(by: { $0.key < $1.key }) {
            guard let o = owned[PathGlob.normalize(path)] else { keep[path] = "not created by JARVIS"; continue }
            if o.taskID != taskID { keep[path] = "belongs to another task"; continue }
            if o.hash != hash { keep[path] = "changed since JARVIS wrote it"; continue }
            remove.append(path)
        }
        return CleanupPlan(remove: remove, keep: keep)
    }
}

struct CommitPolicy: Equatable, Sendable {
    var allowLocalCommit = false
    var forbidAIAttribution = true
    var requireConventionalMessage = true
}

enum CommitVerifier {
    private static let trailer = try! NSRegularExpression(pattern: #"(?:co-authored-by:\s*(?:claude|anthropic|gpt|openai|copilot|gemini|codex)|generated with \[?claude|🤖 generated|claude-session:)"#, options: [.caseInsensitive])
    private static let conventional = try! NSRegularExpression(pattern: #"^(feat|fix|refactor|perf|test|docs|build|chore|style|ci)(\([\w./-]+\))?!?: .{3,}"#)

    static func verify(claimedHash: String?, observed o: CommitObservation, scope: WriteScope, policy: CommitPolicy) -> [EngineeringFinding] {
        var out: [EngineeringFinding] = []
        if let h = claimedHash, !h.isEmpty {
            if o.headAfter == o.headBefore || o.headAfter?.hasPrefix(h) != true || !o.commitExists {
                out.append(EngineeringFinding(.commitClaimContradicted, .blocker, path: ".", "the claimed commit is not the repository's new HEAD", evidence: "claimed \(h.prefix(12)), HEAD \(o.headAfter?.prefix(12) ?? "none")"))
            }
        }
        guard o.headAfter != o.headBefore else { return out }
        if !policy.allowLocalCommit { out.append(EngineeringFinding(.commitClaimContradicted, .blocker, path: ".", "a commit was made although this assignment does not allow commits", evidence: "HEAD moved to \(o.headAfter?.prefix(12) ?? "?")")) }
        for f in o.files where !scope.allows(f) { out.append(EngineeringFinding(.scopeEscape, .blocker, path: f, "the commit includes a file outside the assignment's scope", evidence: f)) }
        let msg = o.message
        if policy.forbidAIAttribution, trailer.firstMatch(in: msg, range: NSRange(msg.startIndex..., in: msg)) != nil { out.append(EngineeringFinding(.commitClaimContradicted, .major, path: ".", "the commit message carries an AI attribution trailer", evidence: "message trailer")) }
        if policy.requireConventionalMessage, conventional.firstMatch(in: msg, range: NSRange(msg.startIndex..., in: msg)) == nil { out.append(EngineeringFinding(.commitClaimContradicted, .minor, path: ".", "the commit message does not follow the project's Conventional Commits style", evidence: String(msg.prefix(60)))) }
        return out
    }
}

/// External, outward-facing actions are separate, critical decisions: a passing test never authorises them.
enum ExternalAction: String, CaseIterable, Sendable { case localCommit, push, forcePush, createPullRequest, mergePullRequest, publish, tag, deleteBranch }

enum ExternalActionPolicy {
    /// Nothing outward-facing is automatic. A local commit needs an explicit allowance on the assignment; everything else is a critical action that needs its own HUD-released gate.
    static func mayRunAutomatically(_ a: ExternalAction, policy: CommitPolicy) -> Bool { a == .localCommit && policy.allowLocalCommit }
    static func isCritical(_ a: ExternalAction) -> Bool { a != .localCommit }
}

enum ProjectConventionDiscovery {
    /// The instruction files a project already has; the worker is told to follow them. For JARVIS itself AGENTS.md is authoritative; other projects are never assumed to share its conventions.
    static func candidates(in files: [String]) -> [String] {
        let wanted: [(String, Int)] = [("agents.md", 0), ("claude.md", 1), ("contributing.md", 2), (".editorconfig", 3), ("conventions.md", 4), ("style.md", 5), ("readme.md", 6)]
        var found: [(String, Int)] = []
        for f in files where f.split(separator: "/").count <= 2 {
            let base = (f as NSString).lastPathComponent.lowercased()
            if let w = wanted.first(where: { $0.0 == base }) { found.append((f, w.1)) }
        }
        return found.sorted { ($0.1, $0.0) < ($1.1, $1.0) }.map(\.0)
    }
}
