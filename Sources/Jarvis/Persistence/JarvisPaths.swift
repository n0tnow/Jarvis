import Foundation

/// Where JARVIS keeps durable operational data. NEVER inside the git repository: the default is under the user's
/// Application Support directory (`~/Library/Application Support/JARVIS`, case-insensitive on APFS, shared with the
/// provider workspace). Tests use `temporary()` roots.
struct JarvisPaths: Sendable {
    let root: URL

    static func standard() -> JarvisPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return JarvisPaths(root: base.appendingPathComponent("JARVIS", isDirectory: true))
    }

    static func temporary(_ tag: String = "jarvis-test") -> JarvisPaths {
        JarvisPaths(root: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true))
    }

    var database: URL { root.appendingPathComponent("jarvis.sqlite") }
    var artifacts: URL { root.appendingPathComponent("artifacts", isDirectory: true) }

    /// Artifact classes (sub-folders of `artifacts/`). Large content lives here; SQLite only stores references.
    enum Folder: String, CaseIterable, Sendable {
        case reports, screenshots, providerOutput = "provider-output", benchmark, checkpoints, logs
    }
    func folder(_ f: Folder) -> URL { artifacts.appendingPathComponent(f.rawValue, isDirectory: true) }
    var runtime: URL { root.appendingPathComponent("runtime", isDirectory: true) }

    func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [root, artifacts] + Folder.allCases.map(folder) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    /// True if `url` lies under `directory` (symlink-resolved) — used to prove the runtime DB is never in the repo.
    static func isInside(_ url: URL, directory: URL) -> Bool {
        let a = url.resolvingSymlinksInPath().standardizedFileURL.path
        let b = directory.resolvingSymlinksInPath().standardizedFileURL.path
        return a == b || a.hasPrefix(b.hasSuffix("/") ? b : b + "/")
    }
}
