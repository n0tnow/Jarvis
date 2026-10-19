import Foundation

/// Read-only Git inspection (status / branch / HEAD) through `ManagedProcess` (argv, no shell). JARVIS never commits, pushes, resets,
/// cleans or checks out in V0.4 — there is no such operation in this type, and `verify.sh` forbids those commands in the sources.
enum GitTool {
    static let executable = "/usr/bin/git"
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: executable) }

    private static func run(_ args: [String], in dir: String) async -> ManagedProcess.RunResult? {
        guard isAvailable else { return nil }
        var env = ProviderEnvironment.make()
        env["GIT_TERMINAL_PROMPT"] = "0"; env["GIT_OPTIONAL_LOCKS"] = "0"; env["GIT_PAGER"] = "cat"
        return await ManagedProcess.runOnce(executable: executable, arguments: ["-c", "core.quotepath=false"] + args, environment: env, workingDirectory: dir, timeout: 20)
    }

    /// Read-only identity of a repository (V0.10 project memory): root commit (stable across moves and clones), branch, HEAD and the origin URL. Nothing is changed.
    struct Identity: Equatable, Sendable { var rootCommit: String?; var branch: String?; var head: String?; var remote: String? }
    static func identity(at dir: String) async -> Identity? {
        guard let inside = await run(["rev-parse", "--is-inside-work-tree"], in: dir), inside.exitCode == 0, inside.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { return nil }
        func out(_ r: ManagedProcess.RunResult?) -> String? { (r?.exitCode == 0) ? r?.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) : nil }
        let root = out(await run(["rev-list", "--max-parents=0", "HEAD"], in: dir))
        return Identity(rootCommit: root, branch: out(await run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir)), head: out(await run(["rev-parse", "HEAD"], in: dir)),
                        remote: out(await run(["remote", "get-url", "origin"], in: dir)))
    }

    /// State BEFORE any write: which paths already carry the user's own uncommitted work.
    static func baseline(workspace: WorkspaceGuard, now: Date = Date()) async -> GitBaseline {
        let none = GitBaseline(isRepository: false, branch: nil, head: nil, dirtyPaths: [], untrackedPaths: [], capturedAt: now)
        guard let inside = await run(["rev-parse", "--is-inside-work-tree"], in: workspace.root), inside.exitCode == 0,
              inside.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { return none }
        let prefix = (await run(["rev-parse", "--show-prefix"], in: workspace.root))?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let branch = await run(["rev-parse", "--abbrev-ref", "HEAD"], in: workspace.root)
        let head = await run(["rev-parse", "HEAD"], in: workspace.root)
        let status = await run(["status", "--porcelain=v1", "--untracked-files=all"], in: workspace.root)
        var dirty: [String] = [], untracked: [String] = []
        for line in (status?.output ?? "").split(separator: "\n") where line.count > 3 {
            let code = line.prefix(2)
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }       // rename: the new path
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !prefix.isEmpty { guard path.hasPrefix(prefix) else { continue }; path = String(path.dropFirst(prefix.count)) }
            if code == "??" { untracked.append(path) } else { dirty.append(path) }
        }
        return GitBaseline(isRepository: true, branch: (branch?.exitCode == 0) ? branch?.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                           head: (head?.exitCode == 0) ? head?.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                           dirtyPaths: dirty.sorted(), untrackedPaths: untracked.sorted(), capturedAt: now)
    }

    /// V1.0 final integration: the engineering pipeline's Git facts (HEAD, branch, modified / untracked / STAGED / CONFLICTED paths) through the same read-only `status`, parsed by the pure `GitStatusParser`
    /// (JARVIS-V1EP-4). Paths are relative to the workspace root even when the workspace is a subdirectory of the repository. nil = not a Git repository (or no Git).
    static func facts(workspace: WorkspaceGuard) async -> GitFacts? {
        guard let inside = await run(["rev-parse", "--is-inside-work-tree"], in: workspace.root), inside.exitCode == 0, inside.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { return nil }
        func out(_ r: ManagedProcess.RunResult?) -> String? { (r?.exitCode == 0) ? r?.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) : nil }
        let prefix = (await run(["rev-parse", "--show-prefix"], in: workspace.root))?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let status = await run(["status", "--porcelain=v1", "--untracked-files=all"], in: workspace.root)
        let scoped = (status?.output ?? "").split(separator: "\n").compactMap { line -> String? in
            guard line.count > 3 else { return nil }
            if prefix.isEmpty { return String(line) }
            let head = line.prefix(3)
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            let unquoted = path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard unquoted.hasPrefix(prefix) else { return nil }
            return head + String(unquoted.dropFirst(prefix.count))
        }.joined(separator: "\n")
        return GitStatusParser.parse(scoped, head: out(await run(["rev-parse", "HEAD"], in: workspace.root)), branch: out(await run(["rev-parse", "--abbrev-ref", "HEAD"], in: workspace.root)))
    }

    /// The content of `path` at `commit` (read-only `git show`), for the "before" side of a diff when the file was clean at the baseline. nil = not available.
    static func contents(of path: String, at commit: String, workspace: WorkspaceGuard) async -> String? {
        guard commit.range(of: "^[0-9a-f]{7,40}$", options: .regularExpression) != nil else { return nil }
        guard let prefix = await run(["rev-parse", "--show-prefix"], in: workspace.root)?.output.trimmingCharacters(in: .whitespacesAndNewlines),
              let r = await run(["show", "\(commit):\(prefix)\(path)"], in: workspace.root), r.exitCode == 0 else { return nil }
        return r.output
    }

    /// V0.13 project continuity: the same read-only facts as the baseline plus the HEAD commit subject, as one value. Nothing is changed.
    static func continuity(at dir: String) async -> ContinuityGit {
        guard let inside = await run(["rev-parse", "--is-inside-work-tree"], in: dir), inside.exitCode == 0, inside.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { return .none }
        func out(_ r: ManagedProcess.RunResult?) -> String? { (r?.exitCode == 0) ? r?.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) : nil }
        let prefix = (await run(["rev-parse", "--show-prefix"], in: dir))?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let status = await run(["status", "--porcelain=v1", "--untracked-files=all"], in: dir)
        var dirty: [String] = [], untracked: [String] = []
        for line in (status?.output ?? "").split(separator: "\n") where line.count > 3 {
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !prefix.isEmpty { guard path.hasPrefix(prefix) else { continue }; path = String(path.dropFirst(prefix.count)) }
            if line.prefix(2) == "??" { untracked.append(path) } else { dirty.append(path) }
        }
        return ContinuityGit(isRepository: true, branch: out(await run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir)), head: out(await run(["rev-parse", "HEAD"], in: dir)),
                             subject: out(await run(["log", "-1", "--format=%s"], in: dir)).map { OutputSanitizer.sanitize(String($0.prefix(120))) }, dirtyPaths: dirty.sorted(), untrackedPaths: untracked.sorted())
    }

    /// Paths that changed between two commits (read-only `git diff --name-only`). Used to say WHAT an external commit touched after the last checkpoint.
    static func changedFiles(from old: String, to new: String, at dir: String) async -> [String] {
        guard old.range(of: "^[0-9a-f]{7,40}$", options: .regularExpression) != nil, new.range(of: "^[0-9a-f]{7,40}$", options: .regularExpression) != nil,
              let r = await run(["diff", "--name-only", "\(old)..\(new)"], in: dir), r.exitCode == 0 else { return [] }
        return r.output.split(separator: "\n").prefix(200).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }.sorted()
    }
}
