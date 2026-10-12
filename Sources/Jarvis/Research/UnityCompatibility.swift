import Foundation

/// Reads what a listing STATES about Unity/pipeline/format/rig (never invents it) and judges it against the project's real facts.
enum AssetMetadataExtractor {
    static func extract(page: ExtractedPage?, text: String) -> AssetMetadata {
        var m = AssetMetadata()
        let blob = ((page?.title ?? "") + "\n" + text).prefix(60_000)
        let s = String(blob)
        func firstMatch(_ pattern: String, group: Int = 0) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), let mt = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(mt.range(at: group), in: s) else { return nil }
            return String(s[r])
        }
        // Unity versions as the listing states them ("2021.3 or newer", "Unity 6", "6000.0+", "2019.4.x")
        if let v = firstMatch("(?:requires |minimum |supports |compatible with |for )?Unity\\s*(?:version\\s*)?((?:20\\d\\d(?:\\.\\d+)?|6000(?:\\.\\d+)?|6|5(?:\\.\\d+)?)(?:\\s?(?:\\+|LTS|or (?:newer|later|above|higher)|and (?:newer|later|above)))?)", group: 1) { m.unityVersions = v.collapsedWhitespace }
        else if let v = firstMatch("\\b((?:20\\d\\d\\.\\d+|6000\\.\\d+)(?:\\.x)?\\s?(?:\\+|LTS)?)\\b", group: 1) { m.unityVersions = v }
        let lower = s.lowercased()
        if lower.contains("universal render pipeline") || lower.range(of: "\\burp\\b", options: .regularExpression) != nil { m.pipelines.append("URP") }
        if lower.contains("high definition render pipeline") || lower.range(of: "\\bhdrp\\b", options: .regularExpression) != nil { m.pipelines.append("HDRP") }
        if lower.contains("built-in render pipeline") || lower.contains("built-in pipeline") || lower.contains("standard render pipeline") || lower.range(of: "built[- ]in rp", options: .regularExpression) != nil { m.pipelines.append("Built-in") }
        let formats: [(String, String)] = [("fbx", "FBX"), ("gltf", "glTF"), ("glb", "GLB"), ("\\.blend\\b|blender file", "Blend"), ("unitypackage", "unitypackage"), ("\\.obj\\b", "OBJ"), ("\\bwav\\b", "WAV"), ("\\bogg\\b", "OGG"), ("\\bmp3\\b", "MP3"), ("\\bpng\\b", "PNG"), ("\\bexr\\b|\\.hdr\\b", "HDR/EXR"), ("\\bbvh\\b", "BVH"), ("\\bupm\\b|package\\.json", "UPM")]
        for (pat, label) in formats where lower.range(of: pat, options: .regularExpression) != nil && m.format.count < 8 { m.format.append(label) }
        if lower.contains("humanoid") { m.animationType = "Humanoid" } else if lower.contains("generic rig") || lower.contains("generic animation") { m.animationType = "Generic" } else if lower.contains("legacy animation") { m.animationType = "Legacy" }
        if lower.contains("mixamo") && m.animationType == nil { m.rigRequirement = "Mixamo-compatible rig" } else if lower.contains("requires humanoid") || lower.contains("humanoid rig") { m.rigRequirement = "Humanoid rig" }
        m.polycount = firstMatch("(?:poly(?:gon)?s?|tris|triangles|vertices)\\s*[:\\-]?\\s*([\\d][\\d.,kK]*)", group: 1) ?? firstMatch("([\\d][\\d.,kK]*)\\s*(?:polys|polygons|tris|triangles)", group: 1)
        m.textureResolution = firstMatch("\\b(\\d{3,4}\\s?[x×]\\s?\\d{3,4}|[1-8]k)\\s*(?:px|pixels?|textures?|resolution)?", group: 1)
        m.version = firstMatch("(?:version|v)\\s*[:]?\\s*(\\d+\\.\\d+(?:\\.\\d+)?)", group: 1)
        m.lastUpdate = page?.meta["article:modified_time"] ?? page?.meta["og:updated_time"] ?? firstMatch("(?:last updated|updated|published)\\s*[:]?\\s*([A-Z][a-z]{2,8} \\d{1,2},? \\d{4}|\\d{4}-\\d{2}-\\d{2})", group: 1)
        if lower.contains("requires") && lower.contains("dependency") || lower.contains("dependencies:") { m.dependencies = ["listing mentions dependencies"] }
        m.publisher = page?.meta["author"] ?? page?.meta["og:site_name"]
        return m
    }
}

struct UnityVersionNumber: Comparable, Equatable, Sendable {
    var major: Int           // Unity 6 is 6000
    var minor: Int = 0

    /// "6000.0.23f1", "2022.3.10f1", "Unity 6", "2021.3+", "6" → comparable number.
    static func parse(_ raw: String) -> UnityVersionNumber? {
        let s = raw.lowercased()
        guard let re = try? NSRegularExpression(pattern: "(\\d{4}|\\d{1,2})(?:\\.(\\d+))?"), let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r1 = Range(m.range(at: 1), in: s), var major = Int(s[r1]) else { return nil }
        let minor = Range(m.range(at: 2), in: s).flatMap { Int(s[$0]) } ?? 0
        if major == 6 { major = 6000 }
        guard major >= 5 else { return nil }
        if major < 2000 && major != 6000 && major != 5 { return nil }
        return UnityVersionNumber(major: major, minor: minor)
    }
    static func < (a: UnityVersionNumber, b: UnityVersionNumber) -> Bool { (a.major, a.minor) < (b.major, b.minor) }
}

enum UnityCompatibilityAssessor {
    private static func rank(_ s: CompatibilityState) -> Int { switch s { case .incompatible: 0; case .unknown: 1; case .likely: 2; case .compatible: 3 } }

    static func assess(meta: AssetMetadata, kind: AssetKind?, codeBearing: CodeBearing, project: ProjectFacts?) -> CompatibilityAssessment {
        guard let project else { return CompatibilityAssessment(overall: .unknown, unityVersion: .unknown, renderPipeline: .unknown, reasons: ["no project facts were available — compatibility cannot be judged"]) }
        var reasons: [String] = []
        let versionIndependent = [.animation, .model3D, .texture, .audio, .music, .font].contains(kind ?? .any) || meta.format.contains(where: { ["FBX", "glTF", "GLB", "OBJ", "WAV", "OGG", "MP3", "PNG", "BVH", "Blend"].contains($0) }) && codeBearing == .none

        // Unity version
        var version: CompatibilityState = .unknown
        if let stated = meta.unityVersions, let need = UnityVersionNumber.parse(stated) {
            let orNewer = stated.contains("+") || stated.lowercased().contains("newer") || stated.lowercased().contains("later") || stated.lowercased().contains("above") || stated.lowercased().contains("higher") || stated.lowercased().contains("lts")
            if let have = project.unityVersion.flatMap(UnityVersionNumber.parse) {
                if have.major == need.major, have.minor >= need.minor || orNewer { version = .compatible; reasons.append("listing states Unity \(stated); project uses \(project.unityVersion ?? "?")") }
                else if have >= need, orNewer { version = .compatible; reasons.append("listing states “\(stated)”; project Unity \(project.unityVersion ?? "?") is newer") }
                else if have > need { version = codeBearing == .none || versionIndependent ? .likely : .unknown; reasons.append("listing was made for Unity \(stated), older than the project (\(project.unityVersion ?? "?")) — \(versionIndependent ? "plain assets usually import fine" : "scripts may need API updates")") }
                else { version = .incompatible; reasons.append("listing needs Unity \(stated) or newer; project is \(project.unityVersion ?? "?")") }
            } else { reasons.append("project Unity version is unknown") }
        } else if versionIndependent {
            version = .likely; reasons.append("engine-independent file formats (\(meta.format.joined(separator: ", ").isEmpty ? "plain assets" : meta.format.joined(separator: ", "))); no Unity version is stated")
        } else { reasons.append("the listing does not state a Unity version") }

        // Render pipeline
        var pipeline: CompatibilityState = .unknown
        let wants = (project.renderPipeline ?? "")
        let stated = meta.pipelines
        let pipelineSensitive = [.shader, .tool].contains(kind ?? .any) || (kind == nil || kind == .any) && !versionIndependent
        if wants.isEmpty { reasons.append("project render pipeline is unknown") }
        else if stated.contains(wants) { pipeline = .compatible; reasons.append("listing states \(wants) support") }
        else if !stated.isEmpty {
            if pipelineSensitive { pipeline = .incompatible; reasons.append("listing states \(stated.joined(separator: "/")) only; the project uses \(wants) (materials/shaders would need conversion)") }
            else { pipeline = .likely; reasons.append("listing states \(stated.joined(separator: "/")) only; meshes/animations/audio do not depend on it but materials need \(wants) conversion") }
        } else if versionIndependent {
            pipeline = .likely; reasons.append("geometry/animation/audio assets do not depend on the render pipeline (materials may need conversion)")
        } else { reasons.append("the listing does not state a render pipeline") }

        if codeBearing == .nativeLibraries { reasons.append("contains native libraries — platform/architecture support must be checked") }
        var overall: CompatibilityState = rank(version) <= rank(pipeline) ? version : pipeline
        if version == .compatible && pipeline == .compatible { overall = .compatible }
        if codeBearing == .nativeLibraries, overall == .compatible { overall = .likely }
        return CompatibilityAssessment(overall: overall, unityVersion: version, renderPipeline: pipeline, reasons: reasons)
    }
}
