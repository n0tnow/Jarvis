import Foundation

/// CURRENT deterministic truth: what the project's files / Git / descriptors say RIGHT NOW. It outranks any memory (DEC-107).
struct TruthValue: Equatable, Sendable {
    var value: String
    var source: MemorySource
}

protocol TruthProbing: Sendable {
    /// nil = this probe does not know the key (memory then keeps its own status, flagged by age).
    func truth(for key: String, projectRoot: String?) -> TruthValue?
    /// Keys this probe can answer for the project (used to list the CURRENT TRUTH section of a context packet).
    func knownKeys(projectRoot: String?) -> [String]
}

/// Files + Unity descriptor + cached Git facts + app-registered constants. Cheap and synchronous; Git facts are refreshed explicitly (`refreshGit`).
final class ProjectTruth: TruthProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var git: [String: GitTool.Identity] = [:]
    private var constants: [String: () -> String?] = [:]

    init() {}

    /// App-level truths (e.g. the Compact HUD size is a constant of the running build).
    func register(key: String, label: String, _ value: @escaping () -> String?) {
        lock.lock(); constants[key] = value; labels[key] = label; lock.unlock()
    }
    private var labels: [String: String] = [:]

    func refreshGit(root: String) async {
        let id = await GitTool.identity(at: root)
        lock.withLock { git[ProjectIdentityResolver.realPath(root)] = id }
    }

    func truth(for key: String, projectRoot: String?) -> TruthValue? {
        lock.lock(); let c = constants[key]; let label = labels[key]; lock.unlock()
        if let c, let v = c() { return TruthValue(value: v, source: MemorySource(kind: .projectInspection, ref: key, label: label ?? key)) }
        guard let rootRaw = projectRoot else { return nil }
        let root = ProjectIdentityResolver.realPath(rootRaw)
        func src(_ kind: MemorySourceKind, _ ref: String, _ label: String) -> MemorySource { MemorySource(kind: kind, ref: ref, label: label) }
        if key.hasPrefix("unity."), let d = UnityProjectDetector.describe(root: root) {
            switch key {
            case "unity.version": return d.declaredVersionRaw.map { TruthValue(value: $0, source: src(.unityInspection, "ProjectSettings/ProjectVersion.txt", "ProjectVersion.txt")) }
            case "unity.pipeline": return TruthValue(value: d.renderPipeline, source: src(.unityInspection, "Packages/manifest.json", "Packages/manifest.json"))
            case "unity.tests": return TruthValue(value: d.hasTestFramework ? "true" : "false", source: src(.unityInspection, "Packages/manifest.json", "Packages/manifest.json"))
            default:
                if key.hasPrefix("unity.package:") { let name = String(key.dropFirst("unity.package:".count)); return TruthValue(value: d.packages[name] ?? "absent", source: src(.unityInspection, "Packages/manifest.json", "Packages/manifest.json")) }
            }
            return nil
        }
        if key.hasPrefix("file.exists:") {
            let rel = String(key.dropFirst("file.exists:".count))
            guard !rel.contains(".."), !rel.hasPrefix("/") else { return nil }
            return TruthValue(value: FileManager.default.fileExists(atPath: root + "/" + rel) ? "true" : "false", source: src(.projectInspection, rel, "file " + rel))
        }
        lock.lock(); let g = git[root]; lock.unlock()
        if key == "git.branch", let b = g?.branch { return TruthValue(value: b, source: src(.gitCommit, "HEAD", "Git branch")) }
        if key == "git.head", let h = g?.head { return TruthValue(value: String(h.prefix(12)), source: src(.gitCommit, h, "Git HEAD")) }
        return nil
    }

    func knownKeys(projectRoot: String?) -> [String] {
        lock.lock(); var keys = Array(constants.keys); lock.unlock()
        if let root = projectRoot.map(ProjectIdentityResolver.realPath), UnityProjectDetector.isUnityProject(root: root) { keys += ["unity.version", "unity.pipeline", "unity.tests"] }
        return keys.sorted()
    }

    func label(_ key: String) -> String { lock.lock(); defer { lock.unlock() }; return labels[key] ?? key }
}

/// A truth probe for tests and fixtures.
final class StaticTruth: TruthProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    init(_ values: [String: String] = [:]) { self.values = values }
    func set(_ key: String, _ v: String?) { lock.lock(); values[key] = v; lock.unlock() }
    func truth(for key: String, projectRoot: String?) -> TruthValue? {
        lock.lock(); defer { lock.unlock() }
        return values[key].map { TruthValue(value: $0, source: MemorySource(kind: .projectInspection, ref: key, label: "inspection: \(key)")) }
    }
    func knownKeys(projectRoot: String?) -> [String] { lock.lock(); defer { lock.unlock() }; return values.keys.sorted() }
}
