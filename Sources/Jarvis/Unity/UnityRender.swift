import Foundation

/// Compact, bounded text renderings of (already sanitized) editor data — what a provider may see instead of a scene dump.
enum UnityRender {
    static func object(_ d: [String: Any]) -> String {
        var s = "\(d["name"] as? String ?? "?")  [path \(d["indexedPath"] as? String ?? d["path"] as? String ?? "?")"
        if let g = d["globalId"] as? String { s += ", globalId \(g)" }
        s += ", scene \((d["scene"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unsaved")"
        s += ", \(d["active"] as? Bool == false ? "inactive" : "active")]"
        return s
    }

    static func components(of d: [String: Any]) -> String {
        let comps = (d["components"] as? [[String: Any]] ?? []).map { c -> String in
            let t = c["type"] as? String ?? "?"
            let i = (c["index"] as? NSNumber)?.intValue ?? 0
            return i == 0 ? t : "\(t)#\(i)"
        }
        return comps.joined(separator: ", ")
    }

    static func properties(_ d: [String: Any], limit: Int = 12) -> String {
        let comps = d["components"] as? [[String: Any]] ?? []
        var lines: [String] = []
        for c in comps {
            let t = c["type"] as? String ?? "?"
            if t == "Transform" { continue }
            let props = (c["properties"] as? [[String: Any]] ?? []).prefix(limit).compactMap { p -> String? in
                guard let path = p["path"] as? String, (p["representable"] as? Bool) != false else { return nil }
                return "\(path)=\(UnityValue(any: p["value"]).map(\.description) ?? "?")"
            }
            if !props.isEmpty { lines.append("  \(t): " + props.joined(separator: ", ")) }
        }
        return lines.joined(separator: "\n")
    }

    static func compilation(_ s: UnityCompilationState) -> String {
        s.failed || !s.errors.isEmpty
            ? "Unity compilation FAILED (\(s.errors.count) error\(s.errors.count == 1 ? "" : "s")): " + s.errors.prefix(5).map(\.display).joined(separator: " | ")
            : "Unity compilation OK (generation \(s.generation), \(s.warnings) warning\(s.warnings == 1 ? "" : "s"))"
    }
}

/// Finds object names a goal talks about (CamelCase / quoted identifiers) so the inspection can look them up — a convenience that never
/// decides anything: each name is still resolved to exactly one object or reported as ambiguous/missing.
enum UnityNameGuess {
    private static let ignore: Set<String> = ["Unity", "GameObject", "Component", "BoxCollider", "Collider", "Rigidbody", "Editor", "Console", "Play", "Mode", "Scene", "Test", "Tests",
                                              "EditMode", "PlayMode", "MonoBehaviour", "Transform", "Camera", "Prefab", "Assets", "Fix", "Add", "Set", "Run", "Enter", "Exit"]
    static func names(from texts: [String], max: Int = 5) -> [String] {
        var seen = Set<String>(), out: [String] = []
        let patterns = [#"["“'`]([A-Za-z_][A-Za-z0-9_ ]{1,40})["”'`]"#, #"\b([A-Z][a-z0-9]+(?:[A-Z][A-Za-z0-9]*)+)\b"#]
        for t in texts {
            for p in patterns {
                guard let re = try? NSRegularExpression(pattern: p) else { continue }
                for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)) where m.numberOfRanges > 1 {
                    guard let r = Range(m.range(at: 1), in: t) else { continue }
                    let w = String(t[r]).trimmingCharacters(in: .whitespaces)
                    if ignore.contains(w) || w.hasSuffix(".cs") || !seen.insert(w).inserted { continue }
                    out.append(w)
                }
            }
        }
        return Array(out.prefix(max))
    }
}
