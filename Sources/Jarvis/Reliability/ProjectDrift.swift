import Foundation

// MARK: - Project binding, drift and Git safety for long tasks (V1.0 background pass)
//
// A task is bound to ONE project (the persisted `workspaceRoot`) for its whole life: focusing another project after a restart changes nothing (`TaskProjectBinding`). While it runs, the world can change under
// it. `ProjectFingerprint` records the facts that matter (the folder exists, the Git state, the files the task touched with their hashes); `ProjectDrift.assess` compares it with the present and returns the
// issues and what to do — never "fix it": JARVIS does not reset, clean, checkout, commit or push (AGENTS.md), never force anything, never discards the person's work, and an edit to a file the person changed
// still needs an approval. Pure: the caller supplies the observed state.

enum TaskProjectBinding {
    /// The workspace a task works in: ALWAYS its own recorded one. `focused` (whichever project is selected right now) is accepted as an argument only to make the rule testable: it is ignored.
    static func workspace(recorded: String?, focused: String?) -> String? { recorded }
}

struct GitSnapshot: Equatable, Sendable {
    var isRepository = true
    var branch: String?
    var head: String?
    var detachedHead = false
    var dirtyPaths: Set<String> = []
    var untrackedPaths: Set<String> = []
    /// A merge / rebase / cherry-pick is in progress or conflicts exist (MERGE_HEAD, rebase-merge, unmerged paths).
    var conflictInProgress = false
}

struct ProjectFingerprint: Equatable, Sendable {
    var rootExists = true
    var git: GitSnapshot?
    /// Files the task changed or read, workspace-relative, with their content hash (nil = did not exist).
    var fileHashes: [String: String?] = [:]
}

enum DriftSeverity: String, Equatable, Sendable { case info, revalidate, block }

enum DriftIssue: Equatable, Sendable {
    case rootMissing
    case headMoved(from: String?, to: String?)
    case branchChanged(from: String?, to: String?)
    case detachedHead
    case conflictInProgress
    case newDirtyPaths([String])
    case newUntracked([String])
    case fileChanged(String)
    case fileRemoved(String)
    case fileAppeared(String)

    var severity: DriftSeverity {
        switch self {
        case .rootMissing, .conflictInProgress, .branchChanged, .detachedHead: return .block
        case .headMoved, .fileChanged, .fileRemoved, .fileAppeared, .newDirtyPaths: return .revalidate
        case .newUntracked: return .info
        }
    }
}

enum DriftAction: String, Equatable, Sendable {
    case continueNormally, revalidateThenContinue, blockAndReport
}

enum ProjectDrift {
    static func assess(recorded r: ProjectFingerprint, current c: ProjectFingerprint, touchedByTask: Set<String> = []) -> [DriftIssue] {
        guard c.rootExists else { return [.rootMissing] }
        var out: [DriftIssue] = []
        if let rg = r.git, let cg = c.git {
            if cg.conflictInProgress { out.append(.conflictInProgress) }
            if cg.detachedHead, !rg.detachedHead { out.append(.detachedHead) }
            if rg.branch != cg.branch, !cg.detachedHead { out.append(.branchChanged(from: rg.branch, to: cg.branch)) }
            // JARVIS never commits: a different HEAD is somebody else's commit
            if rg.head != cg.head { out.append(.headMoved(from: rg.head, to: cg.head)) }
            let newDirty = cg.dirtyPaths.subtracting(rg.dirtyPaths).subtracting(touchedByTask)
            if !newDirty.isEmpty { out.append(.newDirtyPaths(newDirty.sorted())) }
            let newUntracked = cg.untrackedPaths.subtracting(rg.untrackedPaths).subtracting(touchedByTask)
            if !newUntracked.isEmpty { out.append(.newUntracked(newUntracked.sorted())) }
        }
        for (path, hash) in r.fileHashes.sorted(by: { $0.key < $1.key }) {
            switch (hash, c.fileHashes[path] ?? nil) {
            case (.some(let a), .some(let b)): if a != b { out.append(.fileChanged(path)) }
            case (.some, .none): out.append(.fileRemoved(path))
            case (.none, .some): out.append(.fileAppeared(path))
            case (.none, .none): break
            }
        }
        return out
    }

    static func action(for issues: [DriftIssue]) -> DriftAction {
        if issues.contains(where: { $0.severity == .block }) { return .blockAndReport }
        if issues.contains(where: { $0.severity == .revalidate }) { return .revalidateThenContinue }
        return .continueNormally
    }

    /// Whether a WRITE to `path` may proceed on its own: never over a file the person changed (that is the engine's user-dirty approval) and never while the repository is in conflict or on another branch.
    static func mayWrite(path: String, drift: [DriftIssue], userDirty: Set<String>) -> Bool {
        if action(for: drift) == .blockAndReport { return false }
        if userDirty.contains(path) { return false }
        if drift.contains(where: { if case .fileChanged(let p) = $0 { return p == path }; return false }) { return false }
        return true
    }

    /// The things JARVIS must never do about drift (documented as data so a guard / test can assert it): it only ever reports and asks. Named as cases, never as command strings — nothing here can be executed.
    enum ForbiddenReaction: CaseIterable, Sendable { case resetRepository, cleanWorkingTree, checkoutOverChanges, commitOnTheUsersBehalf, pushToRemote, forceAnything, discardUserChanges }
    static let forbiddenReactions: Set<ForbiddenReaction> = Set(ForbiddenReaction.allCases)
}
