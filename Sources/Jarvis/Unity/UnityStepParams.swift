import Foundation

/// A machine-checkable statement about the editor state. The planner (a model) may PROPOSE expectations; JARVIS verifies them against
/// the editor itself, so an expectation is evidence only when the editor confirms it.
struct UnityExpectation: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case objectExists, objectAbsent, componentPresent, componentAbsent, propertyEquals, componentCount }
    var kind: Kind
    var target: UnityTarget?
    var componentType: String?
    var componentIndex: Int?
    var propertyPath: String?
    var value: UnityValue?
    var count: Int?

    var display: String {
        let t = target?.display ?? "?"
        switch kind {
        case .objectExists: return "\(t) exists"
        case .objectAbsent: return "\(t) does not exist"
        case .componentPresent: return "\(t) has \(componentType ?? "?")"
        case .componentAbsent: return "\(t) has no \(componentType ?? "?")"
        case .propertyEquals: return "\(t).\(componentType ?? "?").\(propertyPath ?? "?") == \(value?.description ?? "?")"
        case .componentCount: return "\(t) has \(count ?? 0) × \(componentType ?? "?")"
        }
    }
}

/// Typed parameters of a Unity plan step. Every field is bounded and validated by the PlanValidator; none can carry code.
struct UnityStepParams: Codable, Equatable, Sendable {
    var scene: String?
    var targets: [String] = []
    var testMode: UnityTestMode?
    var testNames: [String] = []
    var groupNames: [String] = []
    var assemblyNames: [String] = []
    var observeSeconds: Int?
    var expectations: [UnityExpectation] = []
    /// Optional explicit edit actions (typed JSON, same schema the Unity agent answers with). Parsed by `UnityActionParser`.
    var actionsJSON: String?
    var requireNoNewErrors = true
    var save = true

    static let maxTargets = 8, maxExpectations = 10, maxObserve = 30, maxNames = 20

    /// Lenient decode of the `"unity"` object of a plan step (unknown keys are ignored here and rejected by the validator when dangerous).
    static func parse(_ raw: Any?) -> UnityStepParams? {
        guard let d = raw as? [String: Any] else { return nil }
        var p = UnityStepParams()
        p.scene = d["scene"] as? String
        p.targets = (d["targets"] as? [Any] ?? []).compactMap { $0 as? String }
        if let m = d["testMode"] as? String ?? d["mode"] as? String { p.testMode = UnityTestMode(rawValue: m) ?? (m.lowercased().contains("play") ? .playMode : m.lowercased().contains("edit") ? .editMode : nil) }
        p.testNames = (d["testNames"] as? [Any] ?? d["tests"] as? [Any] ?? []).compactMap { $0 as? String }
        p.groupNames = (d["groupNames"] as? [Any] ?? []).compactMap { $0 as? String }
        p.assemblyNames = (d["assemblyNames"] as? [Any] ?? []).compactMap { $0 as? String }
        p.observeSeconds = (d["observeSeconds"] as? NSNumber)?.intValue
        p.requireNoNewErrors = d["requireNoNewErrors"] as? Bool ?? true
        p.save = d["save"] as? Bool ?? true
        if let acts = d["actions"] as? [Any], let data = try? JSONSerialization.data(withJSONObject: ["actions": acts]) { p.actionsJSON = String(decoding: data, as: UTF8.self) }
        p.expectations = (d["expectations"] as? [[String: Any]] ?? []).compactMap { e in
            guard let k = (e["kind"] as? String).flatMap(UnityExpectation.Kind.init(rawValue:)) else { return nil }
            return UnityExpectation(kind: k, target: UnityActionParser.target(e["target"]), componentType: e["componentType"] as? String, componentIndex: (e["componentIndex"] as? NSNumber)?.intValue,
                                    propertyPath: e["propertyPath"] as? String, value: e.keys.contains("value") ? UnityValue(any: e["value"]) : nil, count: (e["count"] as? NSNumber)?.intValue)
        }
        return p
    }

    /// Problems that make the parameters unusable (empty = fine). Bounds and shapes only; nothing is guessed.
    func problems() -> [String] {
        var out: [String] = []
        if let s = scene, !UnityPolicy.isSafeProjectPath(s) || !s.hasSuffix(".unity") { out.append("scene must be a .unity path inside Assets/") }
        if targets.count > Self.maxTargets { out.append("too many targets") }
        for t in targets where t.isEmpty || t.count > 160 || t.contains("..") || t.contains("\0") { out.append("invalid target \"\(t.prefix(40))\"") }
        for n in testNames + groupNames + assemblyNames where n.isEmpty || n.count > 200 || n.range(of: #"^[A-Za-z0-9_.\-\[\]\(\)\*\^\$\\ ,:+]+$"#, options: .regularExpression) == nil { out.append("invalid test filter \"\(n.prefix(40))\"") }
        if testNames.count > Self.maxNames || groupNames.count > Self.maxNames || assemblyNames.count > Self.maxNames { out.append("too many test filters") }
        if let o = observeSeconds, !(1...Self.maxObserve).contains(o) { out.append("observeSeconds must be 1–\(Self.maxObserve)") }
        if expectations.count > Self.maxExpectations { out.append("too many expectations") }
        for e in expectations {
            if let c = e.componentType, !UnityActionParser.validComponentType(c) { out.append("invalid component type in an expectation") }
            if let p = e.propertyPath, !UnityActionParser.validPropertyPath(p) { out.append("invalid property path in an expectation") }
            if let t = e.target { if !(t.isPrecise || t.name?.isEmpty == false) { out.append("an expectation needs a target") } } else { out.append("an expectation needs a target") }
        }
        if let a = actionsJSON {
            let parsed = UnityActionParser.parse(a)
            if !parsed.problems.isEmpty { out.append("actions: " + parsed.problems.joined(separator: "; ")) }
        }
        return out
    }

    /// True when any provider-supplied text in the parameters would turn them into code/menu/shell execution.
    func containsForbiddenContent(raw: Any?) -> String? { raw.flatMap { UnityActionParser.forbiddenContent(in: $0) } }
}
