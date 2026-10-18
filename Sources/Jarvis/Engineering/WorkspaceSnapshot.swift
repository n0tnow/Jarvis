import Foundation

// MARK: - Project snapshot, change set and change attribution (V1.0 autonomous engineering pipeline)
//
// Before meaningful engineering work JARVIS takes a LIGHTWEIGHT snapshot: a fingerprint (hash, size, binary flag) per file plus the Git facts that already existed (HEAD, branch, the
// user's own dirty / untracked / staged paths). It never copies the repository. Comparing the snapshot after a worker finished gives the ACTUAL change set, which is what verification
// reads — never the worker's list of files. The dirty tree at the start is the USER's work: it is recorded, never attributed to the task and never reset.
// Capture is read-only (FileManager listing + hashing); everything else here is pure.

struct FileFingerprint: Codable, Equatable, Sendable {
    var hash: String
    var size: Int
    var isBinary: Bool
}

/// Git facts as plain data (parsed from `status --porcelain=v1`; produced by `GitTool` in the app, by a fixture in tests).
struct GitFacts: Codable, Equatable, Sendable {
    var isRepository = true
    var head: String?
    var branch: String?
    var dirty: Set<String> = []          // modified / deleted / renamed in the working tree or index
    var untracked: Set<String> = []
    var staged: Set<String> = []
    var conflicted: Set<String> = []
    var detached: Bool { branch == nil || branch == "HEAD" }
}

enum GitStatusParser {
    /// `git status --porcelain=v1 --untracked-files=all` output → facts (paths relative to the repository root; quotes and rename arrows handled).
    static func parse(_ output: String, head: String? = nil, branch: String? = nil) -> GitFacts {
        var f = GitFacts(head: head, branch: branch)
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) where line.count > 3 {
            let code = Array(line.prefix(2))
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let (x, y) = (code[0], code[1])
            if x == "?" && y == "?" { f.untracked.insert(path); continue }
            if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") { f.conflicted.insert(path); f.dirty.insert(path); continue }
            if x != " " { f.staged.insert(path) }
            f.dirty.insert(path)
        }
        return f
    }
}

struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    var files: [String: FileFingerprint]
    var git: GitFacts
    var capturedAt: Date

    /// Order-independent digest of the file fingerprints: the "revision" a verification result belongs to.
    var digest: String {
        var h: UInt64 = 0xcbf29ce484222325
        for path in files.keys.sorted() {
            for b in "\(path)\u{0}\(files[path]!.hash)\u{0}".utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        }
        return String(h, radix: 16)
    }

    var revision: RevisionStamp { RevisionStamp(head: git.head, branch: git.branch, snapshotDigest: digest) }

    /// Folds changes made by someone ELSE (outside the task's scope and read set, seen BEFORE the next worker attempt) into the baseline, so that later diffs show only what the task did.
    /// Files in `own` (the task's own earlier changes) are never rebased.
    func rebased(onto current: WorkspaceSnapshot, own: Set<String> = []) -> WorkspaceSnapshot {
        var out = self
        let ownKeys = Set(own.map(PathGlob.normalize))
        for c in SnapshotDiff.between(self, current) where !ownKeys.contains(PathGlob.normalize(c.path)) {
            switch c.kind {
            case .deleted: out.files[c.path] = nil
            default: out.files[c.path] = current.files[c.path]
            }
        }
        return out
    }
}

enum WorkspaceSnapshotter {
    static let defaultIgnored: Set<String> = [".git", ".build", "node_modules", "DerivedData", "Pods", ".DS_Store", "__pycache__", ".venv", "venv", ".swiftpm", "Library", "Temp", "Obj"]
    static let maxFiles = 4_000
    static let maxHashedBytes = 4 * 1024 * 1024

    /// Read-only capture of `root`. Symlinks are not followed; files above `maxHashedBytes` are fingerprinted by size only (their hash says so).
    static func capture(root: URL, git: GitFacts, ignoring: Set<String> = defaultIgnored, now: Date = Date()) -> WorkspaceSnapshot {
        var files: [String: FileFingerprint] = [:]
        let fm = FileManager.default
        let base = root.standardizedFileURL.path
        var stack = [base]
        while let dir = stack.popLast(), files.count < maxFiles {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted() where !ignoring.contains(name) && !name.hasSuffix(".pyc") {
                let full = dir + "/" + name
                guard let attrs = try? fm.attributesOfItem(atPath: full), let type = attrs[.type] as? FileAttributeType else { continue }
                if type == .typeSymbolicLink { continue }
                if type == .typeDirectory { stack.append(full); continue }
                guard type == .typeRegular else { continue }
                let rel = String(full.dropFirst(base.count + 1))
                let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
                if size > maxHashedBytes { files[rel] = FileFingerprint(hash: "size:\(size)", size: size, isBinary: true); continue }
                guard let data = fm.contents(atPath: full) else { continue }
                files[rel] = FileFingerprint(hash: Redactor.sha256(data), size: size, isBinary: isBinary(data))
            }
        }
        return WorkspaceSnapshot(files: files, git: git, capturedAt: now)
    }

    static func isBinary(_ data: Data) -> Bool { data.prefix(8_000).contains(0) }
}

enum FileChangeKind: String, Codable, Equatable, Sendable { case created, modified, deleted }

struct FileChange: Codable, Equatable, Sendable {
    var path: String
    var kind: FileChangeKind
    var beforeHash: String?
    var afterHash: String?
    var isBinary: Bool
}

enum SnapshotDiff {
    static func between(_ before: WorkspaceSnapshot, _ after: WorkspaceSnapshot) -> [FileChange] {
        var out: [FileChange] = []
        for (path, f) in after.files {
            if let old = before.files[path] {
                if old.hash != f.hash { out.append(FileChange(path: path, kind: .modified, beforeHash: old.hash, afterHash: f.hash, isBinary: f.isBinary || old.isBinary)) }
            } else { out.append(FileChange(path: path, kind: .created, beforeHash: nil, afterHash: f.hash, isBinary: f.isBinary)) }
        }
        for (path, old) in before.files where after.files[path] == nil { out.append(FileChange(path: path, kind: .deleted, beforeHash: old.hash, afterHash: nil, isBinary: old.isBinary)) }
        return out.sorted { $0.path < $1.path }
    }
}

// MARK: Attribution

/// An edit JARVIS itself applied on behalf of a worker (what `ProjectTools` records as a `TaskFileChange`).
struct AppliedEdit: Codable, Equatable, Sendable {
    var path: String
    var workerID: String
    var stepKey: String
    var beforeHash: String?
    var afterHash: String?
}

enum Attribution: String, Codable, Equatable, Sendable {
    /// Changed during the task, explained by an edit JARVIS applied for a worker.
    case taskProduced
    /// Changed during the task, but the file was the user's own uncommitted work before it started: needs the engine's user-dirty approval.
    case taskTouchedUserDirty
    /// Changed during the task and NO applied edit explains it: an external actor (the user, a tool) or a worker side effect. Never silently attributed to the task.
    case unexplained
}

struct AttributedChange: Codable, Equatable, Sendable {
    var change: FileChange
    var attribution: Attribution
    var workerID: String?
    var stepKey: String?
}

struct AttributionReport: Codable, Equatable, Sendable {
    var changes: [AttributedChange]
    /// Applied edits whose effect is not visible in the observed diff (reverted, overwritten, or never landed).
    var lostEdits: [AppliedEdit]
    /// The user's own uncommitted work before the task and NOT changed by it: left exactly as it was.
    var preexistingUntouched: [String]

    var taskProduced: [AttributedChange] { changes.filter { $0.attribution == .taskProduced } }
    var unexplained: [AttributedChange] { changes.filter { $0.attribution == .unexplained } }
    var touchedUserDirty: [AttributedChange] { changes.filter { $0.attribution == .taskTouchedUserDirty } }
    func files(ofWorker id: String) -> [String] { changes.filter { $0.workerID == id }.map(\.change.path).sorted() }
}

enum ChangeAttribution {
    /// `baseline` = the Git facts BEFORE the task. Which files changed during the task, which existed before it, which worker touched which file — from observation + JARVIS' own edit records.
    static func attribute(changes: [FileChange], applied: [AppliedEdit], baseline: GitFacts) -> AttributionReport {
        let userDirty = baseline.dirty.union(baseline.untracked).union(baseline.staged)
        var byPath: [String: AppliedEdit] = [:]
        for e in applied { byPath[PathGlob.normalize(e.path)] = e }
        var out: [AttributedChange] = []
        for c in changes {
            let key = PathGlob.normalize(c.path)
            let edit = byPath[key]
            let explained = edit.map { $0.afterHash == c.afterHash || ($0.afterHash == nil && c.kind == .deleted) } ?? false
            let wasUserDirty = userDirty.contains { PathGlob.normalize($0) == key }
            if explained { out.append(AttributedChange(change: c, attribution: wasUserDirty ? .taskTouchedUserDirty : .taskProduced, workerID: edit?.workerID, stepKey: edit?.stepKey)) }
            else { out.append(AttributedChange(change: c, attribution: .unexplained, workerID: nil, stepKey: nil)) }
        }
        let observed = Set(changes.map { PathGlob.normalize($0.path) })
        let lost = applied.filter { e in !observed.contains(PathGlob.normalize(e.path)) || changes.first { PathGlob.normalize($0.path) == PathGlob.normalize(e.path) }?.afterHash != e.afterHash }
        let untouched = userDirty.filter { !observed.contains(PathGlob.normalize($0)) }.sorted()
        return AttributionReport(changes: out, lostEdits: lost, preexistingUntouched: untouched)
    }
}
