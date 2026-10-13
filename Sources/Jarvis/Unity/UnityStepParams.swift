import Foundation

/// A machine-checkable statement about the editor state. The planner (a model) may PROPOSE expectations; JARVIS verifies them against
/// the editor itself, so an expectation is evidence only when the editor confirms it.
struct UnityExpectation: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case objectExists, objectAbsent, componentPresent, componentAbsent, propertyEquals, componentCount
        /// V0.13 (evidence from the editor itself): visible in a camera capture (in the frustum, a real area, contrast against the frame) · Animator in the named state / advancing (Play Mode) · an AudioSource is playing (Play Mode).
        case objectVisible, animatorInState, animatorAdvancing, audioPlaying
    }
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
        case .objectVisible: return "\(t) is visible to the camera"
        case .animatorInState: return "\(t) animator is in state \(value?.string ?? "?")"
        case .animatorAdvancing: return "\(t) animation is advancing"
        case .audioPlaying: return "\(t) audio is playing"
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
    /// V0.13 read-side additions of `unityInspect`: asset paths to inspect, a scene/lighting profile, and a camera capture (memory only) with the named objects analysed.
    var assets: [String] = []
    var profile = false
    var capture: UnityCaptureSpec?
    /// V0.13: observe → act → inspect → correct, bounded: make an object clearly visible (aim the camera, add or raise a light, raise the ambient) and PROVE it with the editor's capture analysis.
    var correction: UnityCorrectionSpec?
    /// V0.13: a bounded experiment (`experiment` steps only).
    var experiment: ExperimentSpec?

    static let maxTargets = 8, maxExpectations = 10, maxObserve = 30, maxNames = 20, maxAssets = 6

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
        p.assets = (d["assets"] as? [Any] ?? []).compactMap { $0 as? String }
        p.profile = d["profile"] as? Bool ?? false
        if let c = d["capture"] as? [String: Any] { p.capture = UnityCaptureSpec(width: (c["width"] as? NSNumber)?.intValue ?? 640, height: (c["height"] as? NSNumber)?.intValue ?? 360, targets: (c["targets"] as? [Any] ?? []).compactMap { $0 as? String }) }
        else if d["capture"] as? Bool == true { p.capture = UnityCaptureSpec() }
        if let c = d["correct"] as? [String: Any] ?? d["correction"] as? [String: Any], let t = c["target"] as? String {
            p.correction = UnityCorrectionSpec(target: t, maxRounds: (c["rounds"] as? NSNumber)?.intValue ?? (c["maxRounds"] as? NSNumber)?.intValue ?? UnityCorrectionSpec.defaultRounds)
        }
        if let e = d["experiment"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: e), let spec = try? JSONDecoder().decode(ExperimentSpec.self, from: data) { p.experiment = spec }
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
        if assets.count > Self.maxAssets { out.append("too many assets") }
        for a in assets where !UnityDevOp.validAssetReference(a) { out.append("invalid asset \"\(a.prefix(40))\"") }
        if let c = capture { out += c.problems() }
        if let c = correction { out += c.problems() }
        if let e = experiment { out += ExperimentValidator.validate(e).map(\.description) }
        if let a = actionsJSON {
            let parsed = UnityActionParser.parse(a)
            if !parsed.problems.isEmpty { out.append("actions: " + parsed.problems.joined(separator: "; ")) }
        }
        return out
    }

    /// True when any provider-supplied text in the parameters would turn them into code/menu/shell execution.
    func containsForbiddenContent(raw: Any?) -> String? { raw.flatMap { UnityActionParser.forbiddenContent(in: $0) } }
}


/// A camera capture the plan asks for. The picture is rendered by the editor, read into MEMORY and analysed; nothing is written into the project and nothing is stored.
struct UnityCaptureSpec: Codable, Equatable, Sendable {
    var width = 640
    var height = 360
    /// Objects to check for visibility (names, hierarchy paths or global ids; each is resolved to exactly one object).
    var targets: [String] = []

    func problems() -> [String] {
        var out: [String] = []
        if !(64...1_280).contains(width) || !(64...1_280).contains(height) { out.append("capture size must be 64–1280 pixels") }
        if targets.count > 8 { out.append("too many capture targets") }
        for t in targets where t.isEmpty || t.count > 160 || t.contains("..") { out.append("invalid capture target") }
        return out
    }
}


/// Bounded visual correction of ONE objective: the object is clearly visible to the camera. At most `maxRounds` rounds (default 2); then the remaining uncertainty is reported.
struct UnityCorrectionSpec: Codable, Equatable, Sendable {
    var target: String
    var maxRounds = UnityCorrectionSpec.defaultRounds
    static let defaultRounds = 2, maxAllowedRounds = 3
    func problems() -> [String] {
        var out: [String] = []
        if target.isEmpty || target.count > 160 || target.contains("..") { out.append("invalid correction target") }
        if !(1...Self.maxAllowedRounds).contains(maxRounds) { out.append("correction rounds must be 1–\(Self.maxAllowedRounds)") }
        return out
    }
}
