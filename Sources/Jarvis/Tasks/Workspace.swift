import Foundation
import Darwin

/// The project a task may touch. Every project path JARVIS resolves goes through here: relative to the root, no `..`,
/// no symlink that leaves the root (resolved with `realpath`), no `.git` internals, no secret-looking files.
struct WorkspaceGuard: Sendable, Equatable {
    /// Canonical (symlink-resolved) absolute path of the workspace root.
    let root: String

    enum Violation: Error, Equatable, CustomStringConvertible {
        case invalidRoot(String)
        case emptyPath
        case outsideWorkspace(String)
        case traversal(String)
        case symlinkEscape(String)
        case protected(String)

        var description: String {
            switch self {
            case .invalidRoot(let why): "invalid workspace: \(why)"
            case .emptyPath: "empty path"
            case .outsideWorkspace(let p): "path is outside the workspace: \(p)"
            case .traversal(let p): "path traversal is not allowed: \(p)"
            case .symlinkEscape(let p): "path escapes the workspace through a symbolic link: \(p)"
            case .protected(let p): "path is protected: \(p)"
            }
        }
    }

    // MARK: Root

    /// Never usable as a project root: the filesystem root, the home folder itself, system locations and JARVIS' own data.
    private static let forbiddenRoots: [String] = ["/", "/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/var", "/private", "/Applications", "/Users", "/Volumes", "/opt", "/dev", "/cores"]

    init(rootPath: String) throws {
        guard rootPath.hasPrefix("/") else { throw Violation.invalidRoot("the project folder must be an absolute path") }
        guard let real = Self.realpath(rootPath) else { throw Violation.invalidRoot("the folder does not exist") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue else { throw Violation.invalidRoot("not a folder") }
        let home = Self.realpath(NSHomeDirectory()) ?? NSHomeDirectory()
        if Self.forbiddenRoots.contains(real) || real == home { throw Violation.invalidRoot("that folder is too broad to be a project") }
        if real.hasPrefix("/System/") || real.hasPrefix("/usr/") || real.hasPrefix("/bin/") || real.hasPrefix("/sbin/") || real.contains("/Library/Application Support/JARVIS") {
            throw Violation.invalidRoot("system and JARVIS data folders cannot be projects")
        }
        root = real
    }

    /// V0.9: JARVIS' own, permanently EMPTY research workspace (inside its data folder, which `init(rootPath:)` refuses for projects). Web tasks carry no
    /// project capability, so nothing can be read or written through it; it only gives the task engine a root to anchor on.
    init(researchRoot path: String) throws {
        guard path.hasPrefix("/"), path.contains("/Library/Application Support/JARVIS/research-workspace") || path.contains("/research-workspace"), let real = Self.realpath(path) else { throw Violation.invalidRoot("research workspace is not available") }
        root = real
    }

    private static func realpath(_ path: String) -> String? {
        guard let p = Darwin.realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    // MARK: Resolution

    /// Names (any path component) that are never readable or writable: git internals and secret stores.
    static func isProtected(_ components: [String]) -> Bool {
        for c in components {
            let l = c.lowercased()
            if l == ".git" || l == ".ssh" || l == ".gnupg" || l == ".aws" || l == ".kube" { return true }
            if l == ".env" || l.hasPrefix(".env.") || l == ".npmrc" || l == ".netrc" || l == ".pypirc" || l == ".htpasswd" { return true }
            if l.hasSuffix(".pem") || l.hasSuffix(".key") || l.hasSuffix(".p12") || l.hasSuffix(".pfx") || l.hasSuffix(".keystore") { return true }
            if l.hasPrefix("id_rsa") || l.hasPrefix("id_ed25519") || l.hasPrefix("id_ecdsa") { return true }
            if l.hasPrefix("credentials") || l == "secrets.json" || l == "secrets.yml" || l == "secrets.yaml" { return true }
        }
        return false
    }

    /// Resolves a workspace-relative path (an absolute path is accepted only if it already lies inside the root).
    /// The returned URL is canonical: parent symlinks are resolved and verified to stay inside the root.
    func resolve(_ path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else { throw Violation.emptyPath }
        var rel = trimmed
        if rel.hasPrefix("/") {
            guard rel == root || rel.hasPrefix(root + "/") else { throw Violation.outsideWorkspace(path) }
            rel = String(rel.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let components = rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if components.contains("..") { throw Violation.traversal(path) }
        if components.contains(where: { $0 == "~" }) || rel.hasPrefix("~") { throw Violation.outsideWorkspace(path) }
        let clean = components.filter { $0 != "." }
        if Self.isProtected(clean) { throw Violation.protected(path) }

        // Resolve symlinks of the deepest EXISTING ancestor, then append the not-yet-existing remainder.
        var existing = root
        var remainder: [String] = []
        for (i, c) in clean.enumerated() {
            let candidate = existing + "/" + c
            if FileManager.default.fileExists(atPath: candidate) || (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate)) != nil {
                guard let real = Self.realpath(candidate) else { throw Violation.symlinkEscape(path) }   // dangling link
                guard real == root || real.hasPrefix(root + "/") else { throw Violation.symlinkEscape(path) }
                existing = real
            } else {
                remainder = Array(clean[i...]); break
            }
        }
        let full = ([existing] + remainder).joined(separator: "/")
        guard full == root || full.hasPrefix(root + "/") else { throw Violation.outsideWorkspace(path) }
        if Self.isProtected(full.dropFirst(root.count).split(separator: "/").map(String.init)) { throw Violation.protected(path) }
        return URL(fileURLWithPath: full)
    }

    /// Workspace-relative form of an absolute path inside the root.
    func relative(_ url: URL) -> String {
        let p = url.path
        return p == root ? "." : (p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : p)
    }

    /// Directories skipped when listing/searching (build products, dependencies, VCS, caches).
    static let ignoredDirectories: Set<String> = [".git", "node_modules", ".build", "build", "DerivedData", "Pods", "__pycache__", ".venv", "venv", ".idea",
                                                  ".vscode", ".gradle", "target", "dist", ".next", ".cache", ".swiftpm", ".mypy_cache", ".pytest_cache", "Library", "Temp", "Obj", "Logs"]
}
