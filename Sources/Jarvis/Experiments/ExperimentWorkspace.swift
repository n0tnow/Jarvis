import Foundation

/// The disposable environments live ONLY under one JARVIS-owned root. Creating one writes an ownership marker; removing one (after a run, or when a crashed run is found at the
/// next launch) checks that the folder is INSIDE the root, is not a symlink, and carries a valid marker for a known experiment — so JARVIS can never delete a user's file.
struct ExperimentWorkspace: Equatable, Sendable {
    static let markerName = ".jarvis-experiment.json"
    let root: URL                     // …/experiments
    let id: UUID
    var path: URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    var projectPath: String { path.appendingPathComponent("project", isDirectory: true).path }

    struct Marker: Codable, Equatable, Sendable { var id: UUID; var createdAt: Date; var taskID: UUID?; var kind: String; var pid: Int32 }

    init(root: URL, id: UUID = UUID()) { self.root = root; self.id = id }

    @discardableResult
    func create(taskID: UUID?, kind: ExperimentKind) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: path, withIntermediateDirectories: true)
        let marker = Marker(id: id, createdAt: Date(), taskID: taskID, kind: kind.rawValue, pid: getpid())
        try JSONEncoder().encode(marker).write(to: path.appendingPathComponent(Self.markerName), options: .atomic)
        try fm.createDirectory(atPath: projectPath, withIntermediateDirectories: true)
        return path
    }

    /// Bytes under the environment (the disk budget); counts symlinks as themselves, never follows them out.
    func sizeBytes() -> Int {
        guard let en = FileManager.default.enumerator(at: path, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []) else { return 0 }
        var total = 0
        for case let u as URL in en { if let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true { total += v.fileSize ?? 0 } }
        return total
    }

    /// Deletes THIS environment if (and only if) it is inside the root, is a real directory and has its own marker.
    @discardableResult
    func delete() -> Bool { Self.remove(path, under: root, expectedID: id) }

    static func remove(_ dir: URL, under root: URL, expectedID: UUID? = nil) -> Bool {
        let fm = FileManager.default
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let target = dir.standardizedFileURL
        guard target.path.hasPrefix(canonicalRoot + "/") || target.resolvingSymlinksInPath().path.hasPrefix(canonicalRoot + "/") else { return false }
        guard let attrs = try? fm.attributesOfItem(atPath: target.path), (attrs[.type] as? FileAttributeType) == .typeDirectory else { return false }          // not a symlink, not a file
        guard let data = fm.contents(atPath: target.appendingPathComponent(markerName).path), let m = try? JSONDecoder().decode(Marker.self, from: data) else { return false }
        if let expectedID, m.id != expectedID { return false }
        guard m.id.uuidString == target.lastPathComponent else { return false }
        do { try fm.removeItem(at: target); return true } catch { return false }
    }

    struct Orphan: Equatable, Sendable { var path: String; var marker: Marker; var reason: String }

    /// At launch: environments whose run did not finish (the process that owned them is gone). Pure listing; `reconcile` deletes the safe ones.
    static func orphans(under root: URL, isAlive: (Int32) -> Bool = { pid in kill(pid, 0) == 0 }, finishedIDs: Set<UUID> = []) -> [Orphan] {
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [Orphan] = []
        for k in kids {
            guard let data = fm.contents(atPath: k.appendingPathComponent(markerName).path), let m = try? JSONDecoder().decode(Marker.self, from: data), m.id.uuidString == k.lastPathComponent else { continue }      // not ours: never touched
            if finishedIDs.contains(m.id) { out.append(Orphan(path: k.path, marker: m, reason: "its experiment finished but the folder was left")); continue }
            if m.pid != getpid(), !isAlive(m.pid) { out.append(Orphan(path: k.path, marker: m, reason: "the JARVIS process that owned it is gone")) }
        }
        return out
    }

    @discardableResult
    static func reconcile(under root: URL, isAlive: (Int32) -> Bool = { pid in kill(pid, 0) == 0 }, finishedIDs: Set<UUID> = []) -> [Orphan] {
        var removed: [Orphan] = []
        for o in orphans(under: root, isAlive: isAlive, finishedIDs: finishedIDs) where remove(URL(fileURLWithPath: o.path), under: root, expectedID: o.marker.id) { removed.append(o) }
        return removed
    }
}
