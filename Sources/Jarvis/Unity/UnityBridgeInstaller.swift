import Foundation

/// Installs the JARVIS-owned Editor bridge as an EMBEDDED package (`Packages/com.jarvis.bridge`, no manifest edit, no registry, no
/// download). This changes the user's project, so callers go through an approval first — it is never done silently.
enum UnityBridgeInstaller {
    static let packageFolder = "Packages/" + UnityBridgePackage.folderName

    static var expectedVersion: String {
        UnityBridgePackage.files.first { $0.path == "package.json" }
            .flatMap { (try? JSONSerialization.jsonObject(with: Data($0.content.utf8))) as? [String: Any] }?["version"] as? String ?? "0"
    }

    static func isCurrent(root: String, fileManager fm: FileManager = .default) -> Bool {
        for f in UnityBridgePackage.files {
            guard let data = fm.contents(atPath: root + "/" + packageFolder + "/" + f.path), String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines) == f.content.trimmingCharacters(in: .newlines) else { return false }
        }
        return true
    }

    enum InstallError: Error, Equatable, CustomStringConvertible {
        case notAUnityProject
        case writeFailed(String)
        var description: String { switch self { case .notAUnityProject: "not a Unity project"; case .writeFailed(let w): "could not write the bridge package: \(w)" } }
    }

    /// Writes (or refreshes) the package. Only files of this package are written, inside `Packages/com.jarvis.bridge`.
    @discardableResult
    static func install(root: String, fileManager fm: FileManager = .default) throws -> [String] {
        guard UnityProjectDetector.isUnityProject(root: root, fileManager: fm) else { throw InstallError.notAUnityProject }
        var written: [String] = []
        for f in UnityBridgePackage.files {
            let rel = packageFolder + "/" + f.path
            guard !rel.contains(".."), !f.path.hasPrefix("/") else { throw InstallError.writeFailed("unsafe path") }
            let url = URL(fileURLWithPath: root + "/" + rel)
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data((f.content + "\n").utf8).write(to: url, options: .atomic)
                written.append(rel)
            } catch { throw InstallError.writeFailed("\(rel): \(error.localizedDescription)") }
        }
        return written
    }
}
