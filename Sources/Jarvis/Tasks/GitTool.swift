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
}
