import Foundation

/// Deterministic Unity project detection from the folder structure and a few small files. Nothing is sent anywhere; the whole project is
/// never read — only `ProjectVersion.txt`, `Packages/manifest.json`, `Packages/com.jarvis.bridge/package.json` and file NAMES.
enum UnityProjectDetector {
    static func isUnityProject(root: String, fileManager fm: FileManager = .default) -> Bool {
        var isDir: ObjCBool = false
        func dir(_ rel: String) -> Bool { fm.fileExists(atPath: root + "/" + rel, isDirectory: &isDir) && isDir.boolValue }
        return dir("Assets") && dir("ProjectSettings") && fm.fileExists(atPath: root + "/ProjectSettings/ProjectVersion.txt")
    }

    static func declaredVersion(root: String, fileManager fm: FileManager = .default) -> (raw: String, version: UnityVersion?)? {
        guard let data = fm.contents(atPath: root + "/ProjectSettings/ProjectVersion.txt"), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("m_EditorVersion:") && !line.hasPrefix("m_EditorVersionWithRevision") {
            let raw = line.dropFirst("m_EditorVersion:".count).trimmingCharacters(in: .whitespaces)
            return (raw, UnityVersion(raw))
        }
        return nil
    }

    static func describe(root: String, fileManager fm: FileManager = .default) -> UnityProjectDescriptor? {
        guard isUnityProject(root: root, fileManager: fm) else { return nil }
        let declared = declaredVersion(root: root, fileManager: fm)
        var packages: [String: String] = [:]
        if let data = fm.contents(atPath: root + "/Packages/manifest.json"), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let deps = obj["dependencies"] as? [String: Any] {
            for (k, v) in deps.sorted(by: { $0.key < $1.key }).prefix(UnityProjectDescriptor.maxPackages) { packages[k] = (v as? String).map { String($0.prefix(120)) } ?? "" }
        }
        let pipeline: String
        if packages["com.unity.render-pipelines.universal"] != nil { pipeline = "Universal (URP)" }
        else if packages["com.unity.render-pipelines.high-definition"] != nil { pipeline = "High Definition (HDRP)" }
        else if packages["com.unity.render-pipelines.core"] != nil { pipeline = "Scriptable" }
        else { pipeline = "Built-in" }

        var scenes: [String] = [], asmdefs: [String] = []
        if let en = fm.enumerator(atPath: root + "/Assets") {
            for case let rel as String in en {
                if scenes.count >= UnityProjectDescriptor.maxScenes && asmdefs.count >= UnityProjectDescriptor.maxAsmdefs { break }
                if rel.hasSuffix(".unity") && scenes.count < UnityProjectDescriptor.maxScenes { scenes.append("Assets/" + rel) }
                else if rel.hasSuffix(".asmdef") && asmdefs.count < UnityProjectDescriptor.maxAsmdefs { asmdefs.append("Assets/" + rel) }
            }
        }
        let bridgeJSON = (fm.contents(atPath: root + "/Packages/com.jarvis.bridge/package.json")).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        return UnityProjectDescriptor(
            workspace: root, projectName: (root as NSString).lastPathComponent, declaredVersion: declared?.version, declaredVersionRaw: declared?.raw, renderPipeline: pipeline,
            packages: packages, hasTestFramework: packages["com.unity.test-framework"] != nil, testFrameworkVersion: packages["com.unity.test-framework"],
            scenes: scenes.sorted(), buildScenes: buildScenes(root: root, fileManager: fm), assemblyDefinitions: asmdefs.sorted(),
            bridgeInstalled: bridgeJSON != nil, bridgeVersion: bridgeJSON?["version"] as? String, hasLibrary: fm.fileExists(atPath: root + "/Library"))
    }

    /// Scene paths enabled in EditorBuildSettings.asset (simple YAML line scan; bounded).
    private static func buildScenes(root: String, fileManager fm: FileManager) -> [String] {
        guard let data = fm.contents(atPath: root + "/ProjectSettings/EditorBuildSettings.asset"), let text = String(data: data.prefix(200_000), encoding: .utf8) else { return [] }
        var out: [String] = []
        var enabled = false
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- enabled:") { enabled = t.hasSuffix("1") }
            else if t.hasPrefix("path:"), enabled { out.append(String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
            if out.count >= 50 { break }
        }
        return out
    }
}
