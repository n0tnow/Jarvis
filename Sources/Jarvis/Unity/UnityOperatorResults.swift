import Foundation
import CryptoKit

// MARK: - Typed results of the operator operations (V0.13)
//
// Everything the editor answers is already sanitized at `UnityConnection.perform`. These types only read structured fields; they never execute or interpret text.

/// One object's visibility in a capture, from the editor's own geometry (frustum, projected area) and the rendered pixels (contrast against the rest of the frame).
struct UnityObjectVisibility: Equatable, Sendable {
    var path: String
    var exists: Bool
    var inFrustum: Bool
    var partlyBehindCamera: Bool
    var areaFraction: Double
    var regionLuminance: Double?
    var restLuminance: Double?
    var contrast: Double
    var visible: Bool
    var reason: String?

    /// Thresholds for “clearly visible”: a real share of the frame AND a luminance difference from the rest of the picture (an object lit like its background is invisible).
    static let minArea = 0.001, minContrast = 0.03

    init?(json d: [String: Any]) {
        exists = d["exists"] as? Bool ?? false
        path = d["object"] as? String ?? ""
        inFrustum = d["inFrustum"] as? Bool ?? false
        partlyBehindCamera = d["partlyBehindCamera"] as? Bool ?? false
        areaFraction = (d["areaFraction"] as? NSNumber)?.doubleValue ?? 0
        regionLuminance = (d["regionLuminance"] as? NSNumber)?.doubleValue
        restLuminance = (d["restLuminance"] as? NSNumber)?.doubleValue
        contrast = (d["contrast"] as? NSNumber)?.doubleValue ?? 0
        visible = exists && (d["visible"] as? Bool ?? false)
        reason = d["reason"] as? String
    }

    var summary: String {
        guard exists else { return "\(path.isEmpty ? "object" : path): does not exist" }
        if let r = reason { return "\(path): not visible (\(r))" }
        if !inFrustum { return "\(path): OUTSIDE the camera frustum" }
        return "\(path): \(visible ? "visible" : "not clearly visible") (area \(String(format: "%.1f", areaFraction * 100)) % of the frame, contrast \(String(format: "%.2f", contrast)))"
    }
}

struct UnityLuminance: Equatable, Sendable {
    var mean: Double, stddev: Double, p5: Double, p50: Double, p95: Double, darkFraction: Double, brightFraction: Double
    init(json d: [String: Any]) {
        func n(_ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }
        mean = n("mean"); stddev = n("stddev"); p5 = n("p5"); p50 = n("p50"); p95 = n("p95"); darkFraction = n("darkFraction"); brightFraction = n("brightFraction")
    }
    /// Objective frame checks (never taste): almost everything black, almost everything blown out, or no variation at all.
    var verdicts: [String] {
        var v: [String] = []
        if darkFraction > 0.9 { v.append("the frame is almost entirely dark (\(Int(darkFraction * 100)) % of pixels)") }
        if brightFraction > 0.9 { v.append("the frame is almost entirely blown out (\(Int(brightFraction * 100)) % of pixels)") }
        if stddev < 0.01 { v.append("the frame is uniform (no variation)") }
        return v
    }
}

/// A camera capture held in MEMORY only. The PNG was read from the bridge spool and the spool file deleted immediately; nothing here is ever written to disk or the project.
struct UnityCaptureResult: Sendable {
    var png: Data
    var width: Int
    var height: Int
    var camera: String
    var luminance: UnityLuminance
    var objects: [UnityObjectVisibility]
    var capturedAt = Date()
    /// Identity of the picture for evidence records (the hash, never the pixels).
    var hash: String { SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined().prefix(16).description }
    func visibility(of path: String) -> UnityObjectVisibility? { objects.first { $0.path == path } }

    var summary: String {
        "capture \(width)×\(height) from \(camera) · mean luminance \(String(format: "%.2f", luminance.mean))" + (luminance.verdicts.isEmpty ? "" : " · " + luminance.verdicts.joined(separator: "; "))
            + (objects.isEmpty ? "" : " · " + objects.map(\.summary).joined(separator: "; "))
    }
}

/// Facts read at runtime (Play Mode): what an Animator / AudioSource / Rigidbody is doing right now.
struct UnityRuntimeObject: Equatable, Sendable {
    var path: String
    var exists: Bool
    var animatorState: [String: Bool] = [:]
    var normalizedTime: Double?
    var animatorClips: [String] = []
    var hasController = false
    var audioPlaying: Bool?
    var audioClip: String?
    var speed: Double?
    var visibleToAnyCamera = false

    init(json d: [String: Any]) {
        exists = d["exists"] as? Bool ?? false
        path = ((d["object"] as? [String: Any])?["indexedPath"] as? String) ?? ((d["object"] as? [String: Any])?["path"] as? String) ?? ""
        visibleToAnyCamera = d["visibleToAnyCamera"] as? Bool ?? false
        if let a = d["animator"] as? [String: Any] {
            hasController = a["hasController"] as? Bool ?? false
            normalizedTime = (a["normalizedTime"] as? NSNumber)?.doubleValue
            animatorClips = (a["clips"] as? [String]) ?? []
            for (k, v) in (a["inState"] as? [String: Any] ?? [:]) { animatorState[k] = v as? Bool ?? false }
        }
        if let au = d["audio"] as? [String: Any] { audioPlaying = au["isPlaying"] as? Bool; audioClip = au["clip"] as? String }
        if let rb = d["rigidbody"] as? [String: Any] { speed = (rb["speed"] as? NSNumber)?.doubleValue }
    }
}

// MARK: Verification of an applied operation (pure: a response in, a verdict out)

enum UnityDevVerifier {
    /// `(verified, one-line description)`. The editor's own read-back decides; a response that merely says “ok” is not enough for the operations that return a read-back.
    static func verify(_ op: UnityDevOp, _ r: UnityResponse) -> (Bool, String) {
        let res = r.result
        func b(_ k: String) -> Bool { res[k] as? Bool ?? false }
        func changedWord() -> String { b("alreadyApplied") ? "already" : "applied" }
        switch op {
        case .createScene(let p, _): return (b("created"), "created scene \(p)")
        case .editGameObject(let t, let e): return (res["verified"] as? Bool ?? b("changed") || b("alreadyApplied") || !(res["changed"] as? Bool ?? true), "\(res["changed"] as? Bool == true ? "edited" : "already as requested:") \(t.display) (\(e.fields.joined(separator: ", ")))")
        case .duplicateGameObject(let t, _): return (b("created") && res["object"] != nil, "duplicated \(t.display)")
        case .removeComponent(let t, let c, _): return (b("removed"), "removed \(c) from \(t.display)")
        case .setObjectReference(let t, let c, _, let path, let asset):
            let value = res["value"] as? String
            let ok = asset == nil ? (value == nil || value?.isEmpty == true) : (value == asset || value == (asset?.components(separatedBy: "::").last) || value == (asset as NSString?)?.lastPathComponent)
            return (ok, "\(c).\(path) on \(t.display) → \(value ?? "nothing")")
        case .configureComponent(let t, let kind, let s): return (res["verified"] as? Bool ?? false, "\(b("alreadyApplied") ? "\(kind) already as requested on" : "configured \(kind) on") \(t.display) (\(String(s.keys.sorted().map { "\($0)=\(s[$0]?.description ?? "…")" }.joined(separator: ", ").prefix(220))) — read back from the editor)")
        case .instantiatePrefab(let p, _, _, let n, _, _, _, _): return ((b("created") || b("alreadyExists")) && res["object"] != nil, "\(b("alreadyExists") ? "prefab instance already existed:" : "instantiated") \(p)\(n.map { " as \($0)" } ?? "")")
        case .revertPrefabOverrides(let t): return (res["reverted"] != nil, "reverted \(res["reverted"] as? Int ?? 0) JARVIS override(s) on \(t.display); \(res["protectedUserOverrides"] as? Int ?? 0) user override(s) left untouched")
        case .applyPrefabOverrides(let t): return (res["applied"] != nil, "applied \(res["applied"] as? Int ?? 0) JARVIS override(s) of \(t.display) to the prefab; \(res["protectedUserOverrides"] as? Int ?? 0) user override(s) left untouched")
        case .createPrefabVariant(_, let p): return (b("created") && res["assetType"] as? String == "Variant", "created prefab variant \(p)")
        case .unpackPrefab(let t, _): return (b("unpacked"), "unpacked \(t.display)")
        case .createMaterial(let p, _, _): return (b("created"), "created material \(p) (\(res["shader"] as? String ?? "?"))" + (b("pipelineMismatch") ? " — WARNING: this shader does not render under the project's render pipeline" : ""))
        case .setMaterialProperty(let p, let n, let v):
            let now = UnityValue(any: res["value"]) ?? .null
            let ok = now.matches(v) || (v.string.map { s in (now.string ?? "") == s || (now.string ?? "") == ((s.components(separatedBy: "::").last) ?? s) } ?? false) || (res["type"] as? String == "Texture" && (v == .null ? now == .null : now != .null))
            return (ok, "\(b("alreadyApplied") ? "\(n) of \(p) was already" : "set \(n) of \(p) =") \(now)")
        case .setEnvironment(let prop, let v):
            let now = UnityValue(any: res["value"]) ?? .null
            return (now.matches(v) || (v.string?.caseInsensitiveCompare(now.string ?? "") == .orderedSame), "\(b("alreadyApplied") ? "environment \(prop) was already" : "set environment \(prop) =") \(now)")
        case .createAnimatorController(let p): return (b("created"), "created animator controller \(p)")
        case .editAnimatorController(let p, let e, let layer): return controller(p, e, layer, res)
        case .createAnimationClip(let p, let pr, let ax, let f, let t, let d, _):
            let length = (res["length"] as? NSNumber)?.doubleValue ?? -1
            return (b("created") && abs(length - d) < 0.01, "created animation clip \(p) (\(pr).\(ax) \(f) → \(t) over \(String(format: "%.1f", length)) s, read back)")
        case .setModelImporter(let p, let s):
            let after = res["after"] as? [String: Any] ?? [:]
            var ok = true
            if let t = s["animationType"]?.string { ok = ok && (after["animationType"] as? String)?.caseInsensitiveCompare(t) == .orderedSame }
            if case .bool(let v)? = s["importAnimation"] { ok = ok && after["importAnimation"] as? Bool == v }
            if case .bool(let v)? = s["optimizeGameObjects"] { ok = ok && after["optimizeGameObjects"] as? Bool == v }
            if case .bool(let v)? = s["isReadable"] { ok = ok && after["isReadable"] as? Bool == v }
            if case .array(let a)? = s["clipLoop"], case .string(let clip) = a[0], case .bool(let loop) = a[1] {
                ok = ok && ((after["clips"] as? [[String: Any]])?.first { $0["name"] as? String == clip }?["loop"] as? Bool == loop)
            }
            return (ok, "\(b("changed") ? "re-imported" : "import settings already as requested:") \(p) (\(s.keys.sorted().joined(separator: ", ")))")
        case .createInputAsset(let p): return (b("created") ? res["verified"] as? Bool ?? false : b("alreadyExists"), "\(b("alreadyExists") ? "input actions asset already existed:" : "created input actions asset") \(p)")
        case .createInputMap(let p, let n): return (res["verified"] as? Bool ?? false, "\(b("alreadyExists") ? "action map \(n) already existed in" : "created action map \(n) in") \(p) (read back from the saved file)")
        case .createInputAction(let p, let m, let n, let t, _): return (res["verified"] as? Bool ?? false, "\(b("alreadyExists") ? "action \(m)/\(n) already existed in" : "created \(t) action \(m)/\(n) in") \(p) (read back from the saved file)")
        case .addInputBinding(let p, let m, let a, let path, _):
            if b("duplicate") { return (true, "\(m)/\(a) already had exactly this binding (\(path)); nothing was added") }
            return (b("added") && (res["verified"] as? Bool ?? false), "bound \(path) to \(m)/\(a) in \(p) (binding \((res["bindingId"] as? String ?? "?").prefix(8)), read back from the saved file)")
        case .changeInputBinding(let p, let m, let a, _, let path): return (res["verified"] as? Bool ?? false, "\(b("changed") ? "changed" : "kept") the JARVIS-created binding of \(m)/\(a) in \(p) → \(path) (read back)")
        case .removeInputBinding(let p, let m, let a, _): return (b("removed") && (res["verified"] as? Bool ?? false), "removed a JARVIS-created binding of \(m)/\(a) in \(p) (read back)")
        default: return (true, op.summary)
        }
    }

    private static func controller(_ path: String, _ e: AnimatorEdit, _ layer: Int, _ res: [String: Any]) -> (Bool, String) {
        let layers = res["layers"] as? [[String: Any]] ?? []
        let l = layer < layers.count ? layers[layer] : [:]
        let states = (l["states"] as? [[String: Any]]) ?? []
        func state(_ n: String) -> [String: Any]? { states.first { $0["name"] as? String == n } }
        let params = (res["parameters"] as? [[String: Any]]) ?? []
        let ok: Bool
        switch e {
        case .addParameter(let n, let t, _): ok = params.contains { $0["name"] as? String == n && ($0["type"] as? String)?.caseInsensitiveCompare(t) == .orderedSame }
        case .addState(_, let n, let m, _): ok = state(n) != nil && (m == nil || (state(n)?["motion"] as? String) == m || (state(n)?["motion"] as? String) == m.flatMap { $0.components(separatedBy: "::").last })
        case .setDefaultState(_, let n): ok = state(n)?["isDefault"] as? Bool == true
        case .setStateSpeed(_, let n, let s): ok = abs(((state(n)?["speed"] as? NSNumber)?.doubleValue ?? .nan) - s) < 1e-4
        case .setStateMotion(_, let n, let m): ok = state(n)?["motion"] as? String == m || state(n)?["motion"] as? String == m.components(separatedBy: "::").last
        case .addTransition(_, let from, let to, _, _, _, let cs):
            let trans: [[String: Any]] = from == "Any" ? ((l["anyStateTransitions"] as? [[String: Any]]) ?? []) : ((state(from)?["transitions"] as? [[String: Any]]) ?? [])
            ok = trans.contains { t in t["to"] as? String == to && ((t["conditions"] as? [[String: Any]])?.count ?? 0) == cs.count }
        case .addBlendTreeState(_, let n, _, _): ok = (state(n)?["motion"] as? String)?.hasPrefix("BlendTree:") == true
        }
        return (ok, "\(res["changed"] as? Bool == true ? "" : "already: ")\(e.summary) in \(path)")
    }
}

// MARK: Rendering (bounded text for a provider or the report)

extension UnityRender {
    static func sceneProfile(_ r: [String: Any]) -> String {
        func n(_ k: String) -> Int { (r[k] as? NSNumber)?.intValue ?? 0 }
        var s = "Scene profile \(r["scene"] as? String ?? "?")\(r["dirty"] as? Bool == true ? " (UNSAVED changes)" : ""): \(n("objectCount")) objects · \(n("cameras")) camera(s) · \(n("lights")) light(s) · \(n("audioSources")) audio source(s) · \(n("animators")) animator(s) · \(n("rigidbodies")) rigidbody(ies) · \(n("canvases")) canvas(es)"
        if n("missingScripts") > 0 || n("missingReferences") > 0 { s += " · BROKEN: \(n("missingScripts")) missing script(s), \(n("missingReferences")) missing reference(s)" }
        let prefabs = (r["prefabInstances"] as? [[String: Any]] ?? []).prefix(5).map { "\($0["asset"] as? String ?? "?") ×\(($0["count"] as? NSNumber)?.intValue ?? 0)" }
        if !prefabs.isEmpty { s += "\n  prefab instances: " + prefabs.joined(separator: ", ") }
        let imp = (r["important"] as? [[String: Any]] ?? []).prefix(10).map { "\($0["path"] as? String ?? "?") [\((($0["components"] as? [String]) ?? []).prefix(4).joined(separator: ", "))]" }
        if !imp.isEmpty { s += "\n  notable: " + imp.joined(separator: "; ") }
        let roots = (r["roots"] as? [[String: Any]] ?? []).prefix(12).map { "\($0["name"] as? String ?? "?")(\(($0["descendants"] as? NSNumber)?.intValue ?? 0))" }
        if !roots.isEmpty { s += "\n  roots: " + roots.joined(separator: ", ") }
        return s
    }

    static func lighting(_ r: [String: Any]) -> String {
        let lights = (r["lights"] as? [[String: Any]] ?? []).prefix(8).map { l -> String in
            "\(l["path"] as? String ?? "?") \(l["type"] as? String ?? "?") \(l["enabled"] as? Bool == false ? "OFF" : "on") intensity \(UnityValue(any: l["intensity"]).map(\.description) ?? "?")"
        }
        let env = r["environment"] as? [String: Any] ?? [:]
        return "Lighting (\(r["renderPipeline"] as? String ?? "?")): \(lights.isEmpty ? "NO LIGHTS" : lights.joined(separator: "; ")) · ambient \(env["ambientMode"] as? String ?? "?") intensity \(UnityValue(any: env["ambientIntensity"]).map(\.description) ?? "?")\(env["fog"] as? Bool == true ? " · fog" : "")"
    }

    /// The Input System: package, assets, and (for one asset) maps → actions → bindings with the ids JARVIS needs. Bounded.
    static func input(_ r: [String: Any]) -> String {
        let pkg = r["package"] as? [String: Any] ?? [:]
        var s = "Input System: " + (pkg["installed"] as? Bool == true ? "installed \(pkg["version"] as? String ?? "")" : "NOT installed")
        let assets = (r["assets"] as? [String]) ?? []
        s += " · \(assets.count) .inputactions asset(s)" + (assets.isEmpty ? "" : ": " + assets.prefix(6).joined(separator: ", "))
        if let a = r["asset"] as? [String: Any] {
            s += "\n  \(a["path"] as? String ?? "?")"
            for m in (a["maps"] as? [[String: Any]] ?? []).prefix(8) {
                s += "\n    map \(m["name"] as? String ?? "?")"
                for act in (m["actions"] as? [[String: Any]] ?? []).prefix(16) {
                    s += "\n      action \(act["name"] as? String ?? "?") [\(act["type"] as? String ?? "?")\((act["expectedControlType"] as? String).flatMap { $0.isEmpty ? nil : " → " + $0 } ?? "")]"
                    for b in (act["bindings"] as? [[String: Any]] ?? []).prefix(12) {
                        s += "\n        \(b["path"] as? String ?? "(composite)") id \((b["id"] as? String ?? "?").prefix(8))\(b["ownedByJarvis"] as? Bool == true ? " (created by JARVIS)" : "")"
                    }
                }
            }
            let schemes = (a["controlSchemes"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            s += "\n  control schemes: " + (schemes.isEmpty ? "none" : schemes.joined(separator: ", "))
        }
        return String(s.prefix(2_400))
    }

    static func asset(_ r: [String: Any]) -> String {
        var s = "\(r["path"] as? String ?? "?") (\(r["type"] as? String ?? "?"))"
        if let sh = r["shader"] as? String { s += " shader \(sh)" + (r["pipelineMismatch"] as? Bool == true ? " — NOT SUPPORTED by the active render pipeline" : "") }
        if let at = r["animationType"] as? String { s += " rig \(at)" }
        if let clips = r["clips"] as? [[String: Any]] { s += " · \(clips.count) clip(s): " + clips.prefix(6).map { "\($0["name"] as? String ?? "?")\($0["loop"] as? Bool == true ? " (loop)" : "")" }.joined(separator: ", ") }
        if let av = r["avatar"] as? [String: Any] { s += " · avatar \(av["valid"] as? Bool == true ? "valid" : "INVALID")\(av["human"] as? Bool == true ? " humanoid" : "")" }
        if let l = (r["length"] as? NSNumber)?.doubleValue { s += " · \(String(format: "%.2f", l)) s" }
        if let ps = r["parameters"] as? [[String: Any]] { s += " · parameters: " + ps.prefix(8).map { $0["name"] as? String ?? "?" }.joined(separator: ", ") }
        if let ls = r["layers"] as? [[String: Any]] { s += " · states: " + ls.flatMap { ($0["states"] as? [[String: Any]]) ?? [] }.prefix(10).map { $0["name"] as? String ?? "?" }.joined(separator: ", ") }
        return String(s.prefix(700))
    }
}
