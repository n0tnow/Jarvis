import Foundation

/// Stable identity of a project for memory scoping (DEC-106). A folder path alone is not identity: projects move, clones exist.
/// Priority: Git root commit (identical in every clone, unchanged by moves) → Unity `productGUID` → the real path (last resort).
/// Two unrelated histories can never share a key; a fork that still shares the root commit does (documented limit JARVIS-V10-3).
struct ProjectIdentity: Equatable, Sendable {
    var key: String
    var name: String
    var kind: String            // "git" | "unity" | "path"
    var rootPath: String
    var branch: String? = nil
    var head: String? = nil
    var remote: String? = nil
}

final class ProjectIdentityResolver: @unchecked Sendable {
    private let repo: JarvisRepository?
    private let lock = NSLock()
    private var cache: [String: ProjectIdentity] = [:]
    init(repository: JarvisRepository?) { repo = repository }

    static func realPath(_ p: String) -> String { (realpath(p, nil).map { String(cString: $0) }) ?? p }

    /// Pure part (no Git): the Unity GUID, if any.
    static func unityGUID(root: String) -> String? {
        guard let data = FileManager.default.contents(atPath: root + "/ProjectSettings/ProjectSettings.asset"), let text = String(data: data.prefix(400_000), encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("  productGUID:") { return line.dropFirst("  productGUID:".count).trimmingCharacters(in: .whitespaces) }
        return nil
    }

    func resolve(root rawRoot: String) async -> ProjectIdentity {
        let root = Self.realPath(rawRoot)
        if let hit = lock.withLock({ cache[root] }) { return hit }
        let name = (root as NSString).lastPathComponent
        var id: ProjectIdentity
        if let git = await GitTool.identity(at: root), let rc = git.rootCommit {
            id = ProjectIdentity(key: "git:" + String(rc.prefix(16)), name: name, kind: "git", rootPath: root, branch: git.branch, head: git.head, remote: git.remote)
        } else if let guid = Self.unityGUID(root: root) {
            id = ProjectIdentity(key: "unity:" + guid, name: name, kind: "unity", rootPath: root)
        } else {
            id = ProjectIdentity(key: "path:" + root, name: name, kind: "path", rootPath: root)
        }
        if let repo {
            let existing = (try? repo.memoryProject(id.key)) ?? nil
            var aliases = existing?.aliases ?? []
            if existing?.rootPath != root, let old = existing?.rootPath, !aliases.contains(old) { aliases.append(old) }      // the project moved: remember where it was
            try? repo.upsertMemoryProject(MemoryProjectRow(key: id.key, name: existing?.name ?? name, rootPath: root, aliases: Array(aliases.suffix(8)), identityKind: id.kind, createdAt: existing?.createdAt ?? Date(), lastSeen: Date()))
        }
        lock.withLock { cache[root] = id }
        return id
    }

    func forgetCache() { lock.lock(); cache = [:]; lock.unlock() }
}
