import Foundation

// MARK: - The Unity development operator surface (V0.13 — extends V0.6, replaces nothing)
//
// V0.6 gave JARVIS a typed bridge for inspection, three bounded scene mutations, compile, tests and Play Mode. V0.13 widens the SAME closed surface so routine editor work
// (scenes, hierarchy, prefabs, materials, lighting, animation, audio, camera, physics, UI) needs no mouse: every operation is a case of `UnityDevOp`, parameters are
// validated when the value is built (a model-supplied value that does not fit simply cannot be constructed), and there is still NO case that carries code, a menu path,
// a shell line or a URL. The Editor package re-validates everything with its own whitelists (a unit test keeps the two tables equal).

// MARK: Component settings: the whitelist per component kind

enum UnitySettingKind: Equatable, Sendable {
    case number(ClosedRange<Double>)
    case int(ClosedRange<Int>)
    case bool
    case choice([String])
    case choiceList([String])
    case color
    case vec2
    case vec3
    case assetRef
}

enum UnityComponentSchema {
    private static let lightTypes = ["Spot", "Directional", "Point", "Rectangle", "Disc"]
    private static let shadows = ["None", "Hard", "Soft"]
    private static let clearFlags = ["Skybox", "SolidColor", "Depth", "Nothing"]
    private static let castShadows = ["Off", "On", "TwoSided", "ShadowsOnly"]
    private static let constraints = ["None", "FreezePositionX", "FreezePositionY", "FreezePositionZ", "FreezeRotationX", "FreezeRotationY", "FreezeRotationZ", "FreezePosition", "FreezeRotation", "FreezeAll"]
    private static let interpolation = ["None", "Interpolate", "Extrapolate"]
    private static let collisionDetection = ["Discrete", "Continuous", "ContinuousDynamic", "ContinuousSpeculative"]
    private static let rolloff = ["Logarithmic", "Linear", "Custom"]
    private static let updateModes = ["Normal", "AnimatePhysics", "UnscaledTime"]
    private static let cullingModes = ["AlwaysAnimate", "CullUpdateTransforms", "CullCompletely"]
    private static let renderModes = ["ScreenSpaceOverlay", "ScreenSpaceCamera", "WorldSpace"]

    /// kind → key → kind of value. EXACTLY the keys the C# `NeedKeys(…)` calls accept.
    static let table: [String: [String: UnitySettingKind]] = [
        "light": ["type": .choice(lightTypes), "intensity": .number(0...100_000), "range": .number(0.0001...100_000), "spotAngle": .number(1...179), "innerSpotAngle": .number(1...179), "color": .color,
                  "shadows": .choice(shadows), "shadowStrength": .number(0...1), "enabled": .bool, "bounceIntensity": .number(0...8), "colorTemperature": .number(1_000...20_000), "useColorTemperature": .bool],
        "camera": ["fieldOfView": .number(1...179), "nearClipPlane": .number(0.01...1_000_000), "farClipPlane": .number(0.02...1_000_000), "orthographic": .bool, "orthographicSize": .number(0.0001...100_000),
                   "clearFlags": .choice(clearFlags), "backgroundColor": .color, "depth": .number(-100...100), "enabled": .bool],
        "renderer": ["material": .assetRef, "materialIndex": .int(0...32), "enabled": .bool, "castShadows": .choice(castShadows), "receiveShadows": .bool],
        "rigidbody": ["mass": .number(0.0001...1_000_000), "linearDamping": .number(0...1_000_000), "angularDamping": .number(0...1_000_000), "useGravity": .bool, "isKinematic": .bool,
                      "constraints": .choiceList(constraints), "interpolation": .choice(interpolation), "collisionDetectionMode": .choice(collisionDetection)],
        "collider": ["enabled": .bool, "isTrigger": .bool, "center": .vec3, "size": .vec3, "radius": .number(0.0001...100_000), "height": .number(0.0001...100_000)],
        "characterController": ["height": .number(0.0001...1_000), "radius": .number(0.0001...1_000), "center": .vec3, "slopeLimit": .number(0...90), "stepOffset": .number(0...1_000), "skinWidth": .number(0.0001...10),
                                "minMoveDistance": .number(0...10)],
        "audioSource": ["clip": .assetRef, "volume": .number(0...1), "pitch": .number(-3...3), "loop": .bool, "playOnAwake": .bool, "spatialBlend": .number(0...1), "minDistance": .number(0...1_000_000),
                        "maxDistance": .number(0.0001...1_000_000), "rolloffMode": .choice(rolloff), "mute": .bool, "priority": .int(0...256), "dopplerLevel": .number(0...5), "spread": .number(0...360),
                        "outputMixerGroup": .assetRef],
        "animator": ["controller": .assetRef, "avatar": .assetRef, "applyRootMotion": .bool, "updateMode": .choice(updateModes), "cullingMode": .choice(cullingModes), "speed": .number(-10...10), "enabled": .bool],
        "canvas": ["renderMode": .choice(renderModes), "sortingOrder": .int(-32_768...32_767), "pixelPerfect": .bool, "enabled": .bool],
        "rectTransform": ["anchorMin": .vec2, "anchorMax": .vec2, "pivot": .vec2, "anchoredPosition": .vec2, "sizeDelta": .vec2, "offsetMin": .vec2, "offsetMax": .vec2],
    ]
    static var kinds: [String] { table.keys.sorted() }

    /// Environment settings (RenderSettings of the active scene). Never a render-pipeline asset: a global pipeline change is not an operation at all.
    static let environment: [String: UnitySettingKind] = [
        "ambientMode": .choice(["Skybox", "Trilight", "Flat", "Custom"]), "ambientLight": .color, "ambientSkyColor": .color, "ambientEquatorColor": .color, "ambientGroundColor": .color,
        "ambientIntensity": .number(0...8), "fog": .bool, "fogColor": .color, "fogMode": .choice(["Linear", "Exponential", "ExponentialSquared"]), "fogDensity": .number(0...1),
        "fogStartDistance": .number(0...1_000_000), "fogEndDistance": .number(0...1_000_000), "reflectionIntensity": .number(0...1),
    ]

    /// Model importer settings JARVIS may change (each change is recorded with its previous value and re-imported on purpose).
    static let modelImporter: [String: UnitySettingKind] = [
        "animationType": .choice(["None", "Legacy", "Generic", "Humanoid"]), "importAnimation": .bool, "optimizeGameObjects": .bool, "isReadable": .bool,
    ]

    enum Problem: Error, Equatable, CustomStringConvertible { case unknownKind(String), unknownSetting(String, String), invalid(String, String); var description: String {
        switch self {
        case .unknownKind(let k): "“\(k)” is not a supported component kind (\(UnityComponentSchema.kinds.joined(separator: ", ")))."
        case .unknownSetting(let kind, let k): "“\(k)” is not a supported \(kind) setting."
        case .invalid(let k, let why): "“\(k)”: \(why)"
        } } }

    /// Validates `raw` against `schema`; the result is what goes on the wire.
    static func validate(_ raw: [String: UnityValue], against schema: [String: UnitySettingKind], kind: String) throws -> [String: UnityValue] {
        guard !raw.isEmpty, raw.count <= 16 else { throw Problem.invalid(kind, "between 1 and 16 settings are required") }
        for (k, v) in raw {
            guard let t = schema[k] else { throw Problem.unknownSetting(kind, k) }
            try check(v, as: t, key: k)
        }
        return raw
    }

    private static func check(_ v: UnityValue, as t: UnitySettingKind, key k: String) throws {
        func nums(_ n: Int) -> Bool { if case .array(let a) = v, a.count == n { return a.allSatisfy { if case .number(let d) = $0 { return d.isFinite && abs(d) < 1e7 }; return false } }; return false }
        switch t {
        case .number(let r): guard case .number(let d) = v, d.isFinite, r.contains(d) else { throw Problem.invalid(k, "a number between \(r.lowerBound) and \(r.upperBound)") }
        case .int(let r): guard case .number(let d) = v, d == d.rounded(), d.isFinite, r.contains(Int(d)) else { throw Problem.invalid(k, "an integer between \(r.lowerBound) and \(r.upperBound)") }
        case .bool: guard case .bool = v else { throw Problem.invalid(k, "true or false") }
        case .choice(let names): guard case .string(let s) = v, names.contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) else { throw Problem.invalid(k, "one of \(names.joined(separator: ", "))") }
        case .choiceList(let names): guard case .array(let a) = v, !a.isEmpty, a.count <= 8, a.allSatisfy({ if case .string(let s) = $0 { return names.contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) }; return false }) else { throw Problem.invalid(k, "a list of \(names.joined(separator: ", "))") }
        case .color: guard case .array(let a) = v, (a.count == 3 || a.count == 4), nums(a.count) else { throw Problem.invalid(k, "[r, g, b] or [r, g, b, a]") }
        case .vec2: guard nums(2) else { throw Problem.invalid(k, "[x, y]") }
        case .vec3: guard nums(3) else { throw Problem.invalid(k, "[x, y, z]") }
        case .assetRef:
            if case .null = v { return }
            guard case .string(let s) = v, UnityDevOp.validAssetReference(s) else { throw Problem.invalid(k, "an asset path inside Assets/ (or null to clear)") }
        }
    }
}

// MARK: Edits that carry several fields

struct GameObjectEdit: Equatable, Sendable {
    enum Parent: Equatable, Sendable { case unchanged, root, to(UnityTarget) }
    var name: String?
    var active: Bool?
    var parent: Parent = .unchanged
    var siblingIndex: Int?
    var position: [Double]?
    var rotation: [Double]?
    var scale: [Double]?
    var worldSpace = false
    var tag: String?
    var layer: String?
    var isStatic: Bool?

    var isEmpty: Bool { name == nil && active == nil && parent == .unchanged && siblingIndex == nil && position == nil && rotation == nil && scale == nil && tag == nil && layer == nil && isStatic == nil }
    var fields: [String] {
        [name != nil ? "name" : nil, active != nil ? "active" : nil, parent != .unchanged ? "parent" : nil, siblingIndex != nil ? "siblingIndex" : nil, position != nil ? "position" : nil, rotation != nil ? "rotation" : nil,
         scale != nil ? "scale" : nil, tag != nil ? "tag" : nil, layer != nil ? "layer" : nil, isStatic != nil ? "isStatic" : nil].compactMap { $0 }
    }
}

struct AnimatorCondition: Equatable, Sendable { var parameter: String; var mode: String; var threshold: Double }

enum AnimatorEdit: Equatable, Sendable {
    case addParameter(name: String, type: String, defaultValue: UnityValue?)
    case addState(layer: Int, name: String, motion: String?, speed: Double?)
    case setDefaultState(layer: Int, name: String)
    case setStateSpeed(layer: Int, name: String, speed: Double)
    case setStateMotion(layer: Int, name: String, motion: String)
    case addTransition(layer: Int, from: String, to: String, hasExitTime: Bool?, exitTime: Double?, duration: Double?, conditions: [AnimatorCondition])
    case addBlendTreeState(layer: Int, name: String, parameter: String, children: [(motion: String, threshold: Double)])

    static func == (a: AnimatorEdit, b: AnimatorEdit) -> Bool { a.wireAction == b.wireAction && NSDictionary(dictionary: a.fields).isEqual(to: b.fields) }

    var wireAction: String {
        switch self {
        case .addParameter: "addParameter"; case .addState: "addState"; case .setDefaultState: "setDefaultState"; case .setStateSpeed: "setStateSpeed"
        case .setStateMotion: "setStateMotion"; case .addTransition: "addTransition"; case .addBlendTreeState: "addBlendTreeState"
        }
    }
    var fields: [String: Any] {
        switch self {
        case .addParameter(let n, let t, let d): var f: [String: Any] = ["name": n, "type": t]; if let d { f["default"] = d.any }; return f
        case .addState(let l, let n, let m, let s): var f: [String: Any] = ["layer": l, "name": n]; if let m { f["motion"] = m }; if let s { f["speed"] = s }; return f
        case .setDefaultState(let l, let n): return ["layer": l, "name": n]
        case .setStateSpeed(let l, let n, let s): return ["layer": l, "name": n, "speed": s]
        case .setStateMotion(let l, let n, let m): return ["layer": l, "name": n, "motion": m]
        case .addTransition(let l, let from, let to, let ex, let et, let du, let cs):
            var f: [String: Any] = ["layer": l, "from": from, "to": to, "conditions": cs.map { ["parameter": $0.parameter, "mode": $0.mode, "threshold": $0.threshold] }]
            if let ex { f["hasExitTime"] = ex }; if let et { f["exitTime"] = et }; if let du { f["duration"] = du }
            return f
        case .addBlendTreeState(let l, let n, let p, let ch): return ["layer": l, "name": n, "parameter": p, "children": ch.map { ["motion": $0.motion, "threshold": $0.threshold] }]
        }
    }
    var summary: String {
        switch self {
        case .addParameter(let n, let t, _): "add \(t) parameter \(n)"; case .addState(_, let n, _, _): "add state \(n)"; case .setDefaultState(_, let n): "default state \(n)"
        case .setStateSpeed(_, let n, _): "speed of \(n)"; case .setStateMotion(_, let n, _): "motion of \(n)"; case .addTransition(_, let f, let t, _, _, _, _): "transition \(f) → \(t)"
        case .addBlendTreeState(_, let n, _, _): "blend tree \(n)"
        }
    }
    var motionAssets: [String] {
        switch self {
        case .addState(_, _, let m?, _), .setStateMotion(_, _, let m): [m]
        case .addBlendTreeState(_, _, _, let ch): ch.map(\.motion)
        default: []
        }
    }
}

// MARK: The operations

enum UnityDevOp: Equatable, Sendable {
    // scene & hierarchy
    case createScene(path: String, empty: Bool)
    case sceneProfile(scene: String?, maxObjects: Int)
    case editGameObject(UnityTarget, GameObjectEdit)
    case duplicateGameObject(UnityTarget, name: String?)
    case removeComponent(UnityTarget, componentType: String, index: Int?)
    case setObjectReference(UnityTarget, componentType: String, index: Int?, propertyPath: String, assetPath: String?)
    case configureComponent(UnityTarget, kind: String, settings: [String: UnityValue])
    // prefabs
    case instantiatePrefab(assetPath: String, scene: String?, parent: UnityTarget?, name: String?, position: [Double]?, rotation: [Double]?, scale: [Double]?, ifAbsent: Bool)
    case prefabOverrides(UnityTarget)
    case revertPrefabOverrides(UnityTarget)
    case applyPrefabOverrides(UnityTarget)
    case createPrefabVariant(source: String, assetPath: String)
    case unpackPrefab(UnityTarget, completely: Bool)
    // assets
    case inspectAsset(path: String)
    case createMaterial(assetPath: String, shader: String?, copyFrom: String?)
    case setMaterialProperty(assetPath: String, property: String, value: UnityValue)
    // lighting & environment
    case inspectLighting(scene: String?)
    case setEnvironment(property: String, value: UnityValue)
    // animation
    case createAnimatorController(assetPath: String)
    case editAnimatorController(assetPath: String, edit: AnimatorEdit, layer: Int)
    case setModelImporter(assetPath: String, settings: [String: UnityValue])
    /// V0.13.1: a deterministic animation clip (one transform property moved linearly) — the fixture the animation experiment plays; no arbitrary curves, no code.
    case createAnimationClip(assetPath: String, property: String, axis: String, from: Double, to: Double, duration: Double, loop: Bool)
    // Input System (V0.13.1): InputActionAssets edited through Unity's own InputActionAsset API (never by hand-editing JSON/YAML); only bindings JARVIS created can be changed or removed
    case inspectInput(assetPath: String?)
    case createInputAsset(assetPath: String)
    case createInputMap(assetPath: String, name: String)
    case createInputAction(assetPath: String, map: String, name: String, actionType: String, expectedControlType: String?)
    case addInputBinding(assetPath: String, map: String, action: String, path: String, groups: String?)
    case changeInputBinding(assetPath: String, map: String, action: String, bindingID: String, path: String)
    case removeInputBinding(assetPath: String, map: String, action: String, bindingID: String)
    // runtime & capture (reads; allowed in Play Mode)
    case inspectRuntime(targets: [UnityTarget], animatorStates: [String])
    case captureView(camera: UnityTarget?, width: Int, height: Int, targets: [UnityTarget])

    static let allWireNames: Set<String> = ["createScene", "sceneProfile", "editGameObject", "duplicateGameObject", "removeComponent", "setObjectReference", "configureComponent", "instantiatePrefab", "prefabOverrides",
        "revertPrefabOverrides", "applyPrefabOverrides", "createPrefabVariant", "unpackPrefab", "inspectAsset", "createMaterial", "setMaterialProperty", "inspectLighting", "setEnvironment", "createAnimatorController",
        "editAnimatorController", "setModelImporter", "inspectRuntime", "captureView", "createAnimationClip", "inspectInput", "createInputAsset", "createInputMap", "createInputAction", "addInputBinding", "changeInputBinding", "removeInputBinding"]

    var wireName: String {
        switch self {
        case .createScene: "createScene"; case .sceneProfile: "sceneProfile"; case .editGameObject: "editGameObject"; case .duplicateGameObject: "duplicateGameObject"; case .removeComponent: "removeComponent"
        case .setObjectReference: "setObjectReference"; case .configureComponent: "configureComponent"; case .instantiatePrefab: "instantiatePrefab"; case .prefabOverrides: "prefabOverrides"
        case .revertPrefabOverrides: "revertPrefabOverrides"; case .applyPrefabOverrides: "applyPrefabOverrides"; case .createPrefabVariant: "createPrefabVariant"; case .unpackPrefab: "unpackPrefab"
        case .inspectAsset: "inspectAsset"; case .createMaterial: "createMaterial"; case .setMaterialProperty: "setMaterialProperty"; case .inspectLighting: "inspectLighting"; case .setEnvironment: "setEnvironment"
        case .createAnimatorController: "createAnimatorController"; case .editAnimatorController: "editAnimatorController"; case .setModelImporter: "setModelImporter"; case .createAnimationClip: "createAnimationClip"
        case .inspectRuntime: "inspectRuntime"; case .captureView: "captureView"
        case .inspectInput: "inspectInput"; case .createInputAsset: "createInputAsset"; case .createInputMap: "createInputMap"; case .createInputAction: "createInputAction"
        case .addInputBinding: "addInputBinding"; case .changeInputBinding: "changeInputBinding"; case .removeInputBinding: "removeInputBinding"
        }
    }

    var capability: TaskCapability {
        switch self {
        case .sceneProfile, .prefabOverrides, .inspectAsset, .inspectLighting, .inspectRuntime, .inspectInput: .inspectUnity
        case .captureView: .captureUnityView
        case .createScene: .saveUnityScene
        case .editGameObject, .duplicateGameObject, .setObjectReference, .configureComponent, .instantiatePrefab, .revertPrefabOverrides, .setEnvironment: .modifyUnityScene
        case .removeComponent, .unpackPrefab: .deleteUnityObject
        case .applyPrefabOverrides: .createUnityPrefab
        case .createPrefabVariant, .createMaterial, .setMaterialProperty, .createAnimatorController, .editAnimatorController, .setModelImporter, .createAnimationClip, .createInputAsset, .createInputMap, .createInputAction, .addInputBinding, .changeInputBinding, .removeInputBinding: .editUnityAssets
        }
    }

    /// Changes the project on disk or the open scene (blocked in Play Mode by the policy AND the bridge, serialised by the Unity lock).
    var isPersistentMutation: Bool {
        switch self {
        case .sceneProfile, .prefabOverrides, .inspectAsset, .inspectLighting, .inspectRuntime, .captureView, .inspectInput: false
        default: true
        }
    }
    /// The change lands in an OPEN SCENE (so the user's unsaved scene work is protected); asset-only operations leave scenes alone.
    var touchesScene: Bool {
        switch self {
        case .createScene, .editGameObject, .duplicateGameObject, .removeComponent, .setObjectReference, .configureComponent, .instantiatePrefab, .revertPrefabOverrides, .applyPrefabOverrides, .unpackPrefab, .setEnvironment: true
        default: false
        }
    }
    var isDestructive: Bool { switch self { case .removeComponent, .unpackPrefab: true; default: false } }
    var isRetryable: Bool {
        switch self {
        case .createScene, .duplicateGameObject, .removeComponent, .createPrefabVariant, .createMaterial, .createAnimatorController, .applyPrefabOverrides, .unpackPrefab, .setModelImporter, .createAnimationClip, .createInputAsset, .addInputBinding: false
        default: true
        }
    }

    /// Every asset path / reference this operation names (the policy checks each one stays inside Assets/).
    var assetPaths: [String] {
        func base(_ r: String) -> String { r.components(separatedBy: "::").first ?? r }
        switch self {
        case .createScene(let p, _): return [p]
        case .instantiatePrefab(let p, _, _, _, _, _, _, _): return [p]
        case .createPrefabVariant(let s, let p): return [s, p]
        case .inspectAsset(let p), .createAnimatorController(let p), .createInputAsset(let p): return [p]
        case .inspectInput(let p): return p.map { [$0] } ?? []
        case .createInputMap(let p, _), .createInputAction(let p, _, _, _, _), .addInputBinding(let p, _, _, _, _), .changeInputBinding(let p, _, _, _, _), .removeInputBinding(let p, _, _, _): return [p]
        case .createMaterial(let p, _, let c): return [p] + (c.map { [base($0)] } ?? [])
        case .setMaterialProperty(let p, _, let v): return [p] + (v.string.map { [base($0)] } ?? [])
        case .setModelImporter(let p, _), .createAnimationClip(let p, _, _, _, _, _, _): return [p]
        case .editAnimatorController(let p, let e, _): return [p] + e.motionAssets.map(base)
        case .setObjectReference(_, _, _, _, let a): return a.map { [base($0)] } ?? []
        case .configureComponent(_, _, let s): return s.values.compactMap { $0.string }.filter { $0.hasPrefix("Assets/") }.map(base)
        case .sceneProfile(let s, _): return s.map { [$0] } ?? []
        case .inspectLighting(let s): return s.map { [$0] } ?? []
        default: return []
        }
    }

    /// Every GameObject target a mutation names (each must be precise — a name alone is only valid for lookups).
    var mutationTargets: [UnityTarget] {
        switch self {
        case .editGameObject(let t, let e): var l = [t]; if case .to(let p) = e.parent { l.append(p) }; return l
        case .duplicateGameObject(let t, _), .removeComponent(let t, _, _), .setObjectReference(let t, _, _, _, _), .configureComponent(let t, _, _), .unpackPrefab(let t, _), .revertPrefabOverrides(let t), .applyPrefabOverrides(let t): return [t]
        case .instantiatePrefab(_, _, let p, _, _, _, _, _): return p.map { [$0] } ?? []
        default: return []
        }
    }

    var summary: String {
        switch self {
        case .createScene(let p, _): "create scene \(p)"
        case .sceneProfile: "profile the scene"
        case .editGameObject(let t, let e): "edit \(t.display) (\(e.fields.joined(separator: ", ")))"
        case .duplicateGameObject(let t, _): "duplicate \(t.display)"
        case .removeComponent(let t, let c, _): "remove \(c) from \(t.display)"
        case .setObjectReference(let t, let c, _, let p, let a): "assign \(a ?? "nothing") to \(c).\(p) on \(t.display)"
        case .configureComponent(let t, let k, let s): "configure \(k) on \(t.display) (\(s.keys.sorted().joined(separator: ", ")))"
        case .instantiatePrefab(let p, _, _, let n, _, _, _, _): "instantiate \(p)\(n.map { " as \($0)" } ?? "")"
        case .prefabOverrides(let t): "list prefab overrides of \(t.display)"
        case .revertPrefabOverrides(let t): "revert JARVIS' prefab overrides on \(t.display)"
        case .applyPrefabOverrides(let t): "apply JARVIS' prefab overrides of \(t.display) to the prefab"
        case .createPrefabVariant(let s, let p): "create prefab variant \(p) of \(s)"
        case .unpackPrefab(let t, _): "unpack prefab instance \(t.display)"
        case .inspectAsset(let p): "inspect asset \(p)"
        case .createMaterial(let p, let s, _): "create material \(p)\(s.map { " (\($0))" } ?? "")"
        case .setMaterialProperty(let p, let n, _): "set \(n) of \(p)"
        case .inspectLighting: "inspect lighting"
        case .setEnvironment(let p, _): "set environment \(p)"
        case .createAnimatorController(let p): "create animator controller \(p)"
        case .editAnimatorController(let p, let e, _): "\(e.summary) in \(p)"
        case .setModelImporter(let p, let s): "change import settings of \(p) (\(s.keys.sorted().joined(separator: ", ")))"
        case .createAnimationClip(let p, let pr, let ax, let f, let t, _, _): "create animation clip \(p) (\(pr).\(ax) \(f) → \(t))"
        case .inspectRuntime(let t, _): "inspect \(t.count) object(s) at runtime"
        case .captureView(_, let w, let h, _): "capture the game camera (\(w)×\(h))"
        case .inspectInput(let p): "inspect the Input System\(p.map { " asset \($0)" } ?? "")"
        case .createInputAsset(let p): "create input actions asset \(p)"
        case .createInputMap(let p, let n): "create action map \(n) in \(p)"
        case .createInputAction(let p, let m, let n, let t, _): "create \(t) action \(m)/\(n) in \(p)"
        case .addInputBinding(let p, let m, let a, let path, _): "bind \(path) to \(m)/\(a) in \(p)"
        case .changeInputBinding(let p, let m, let a, _, let path): "change a JARVIS-created binding of \(m)/\(a) in \(p) to \(path)"
        case .removeInputBinding(let p, let m, let a, _): "remove a JARVIS-created binding of \(m)/\(a) in \(p)"
        }
    }

    /// Wire parameters (bounded; nothing here can carry executable text).
    var parameters: [String: Any] {
        func t(_ x: UnityTarget) -> [String: Any] {
            var d: [String: Any] = [:]
            if let g = x.globalId { d["globalId"] = String(g.prefix(UnityOperation.maxString)) }
            if let p = x.path { d["path"] = String(p.prefix(UnityOperation.maxString)) }
            if let s = x.scene { d["scene"] = String(s.prefix(UnityOperation.maxString)) }
            if let n = x.name { d["name"] = String(n.prefix(UnityOperation.maxString)) }
            return d
        }
        func s(_ x: String) -> String { String(x.prefix(UnityOperation.maxString)) }
        switch self {
        case .createScene(let p, let e): return ["path": s(p), "template": e ? "empty" : "default"]
        case .sceneProfile(let sc, let m): var d: [String: Any] = ["maxObjects": min(max(m, 10), 5_000)]; if let sc { d["scene"] = s(sc) }; return d
        case .editGameObject(let tg, let e):
            var d: [String: Any] = ["target": t(tg)]
            if let v = e.name { d["name"] = s(v) }; if let v = e.active { d["active"] = v }; if let v = e.siblingIndex { d["siblingIndex"] = min(max(v, 0), 100_000) }
            switch e.parent { case .unchanged: break; case .root: d["parent"] = NSNull(); case .to(let p): d["parent"] = t(p) }
            if let v = e.position { d["position"] = v }; if let v = e.rotation { d["rotation"] = v }; if let v = e.scale { d["scale"] = v }
            if e.position != nil || e.rotation != nil { d["space"] = e.worldSpace ? "world" : "local" }
            if let v = e.tag { d["tag"] = s(v) }; if let v = e.layer { d["layer"] = s(v) }; if let v = e.isStatic { d["isStatic"] = v }
            return d
        case .duplicateGameObject(let tg, let n): var d: [String: Any] = ["target": t(tg)]; if let n { d["name"] = s(n) }; return d
        case .removeComponent(let tg, let c, let i): var d: [String: Any] = ["target": t(tg), "componentType": c]; if let i { d["componentIndex"] = i }; return d
        case .setObjectReference(let tg, let c, let i, let p, let a):
            var d: [String: Any] = ["target": t(tg), "componentType": c, "propertyPath": p, "assetPath": a.map { s($0) as Any } ?? NSNull()]; if let i { d["componentIndex"] = i }; return d
        case .configureComponent(let tg, let k, let st): return ["target": t(tg), "kind": k, "settings": st.mapValues(\.any)]
        case .instantiatePrefab(let p, let sc, let par, let n, let pos, let rot, let scl, let ifAbsent):
            var d: [String: Any] = ["assetPath": s(p), "ifAbsent": ifAbsent]
            if let sc { d["scene"] = s(sc) }; if let par { d["parent"] = t(par) }; if let n { d["name"] = s(n) }
            if let pos { d["position"] = pos }; if let rot { d["rotation"] = rot }; if let scl { d["scale"] = scl }
            return d
        case .prefabOverrides(let tg), .revertPrefabOverrides(let tg), .applyPrefabOverrides(let tg): return ["target": t(tg)]
        case .createPrefabVariant(let src, let p): return ["sourceAssetPath": s(src), "assetPath": s(p)]
        case .unpackPrefab(let tg, let c): return ["target": t(tg), "mode": c ? "completely" : "outermostRoot"]
        case .inspectAsset(let p): return ["path": s(p)]
        case .createMaterial(let p, let sh, let c): var d: [String: Any] = ["assetPath": s(p)]; if let sh { d["shader"] = s(sh) }; if let c { d["copyFrom"] = s(c) }; return d
        case .setMaterialProperty(let p, let n, let v): return ["assetPath": s(p), "property": s(n), "value": v.any]
        case .inspectLighting(let sc): return sc.map { ["scene": s($0)] } ?? [:]
        case .setEnvironment(let p, let v): return ["property": p, "value": v.any]
        case .createAnimatorController(let p): return ["assetPath": s(p)]
        case .editAnimatorController(let p, let e, let l): var d = e.fields; d["assetPath"] = s(p); d["action"] = e.wireAction; if d["layer"] == nil { d["layer"] = l }; return d
        case .setModelImporter(let p, let st): return ["assetPath": s(p), "settings": st.mapValues(\.any)]
        case .createAnimationClip(let p, let pr, let ax, let f, let t, let d, let l): return ["assetPath": s(p), "property": pr, "axis": ax, "from": f, "to": t, "duration": d, "loop": l]
        case .inspectRuntime(let ts, let states): return ["targets": ts.prefix(12).map(t), "animatorStates": Array(states.prefix(12)).map(s)]
        case .captureView(let cam, let w, let h, let ts):
            var d: [String: Any] = ["width": min(max(w, 64), 1_280), "height": min(max(h, 64), 1_280), "targets": ts.prefix(8).map(t)]; if let cam { d["camera"] = t(cam) }; return d
        case .inspectInput(let p): return p.map { ["assetPath": s($0)] } ?? [:]
        case .createInputAsset(let p): return ["assetPath": s(p)]
        case .createInputMap(let p, let n): return ["assetPath": s(p), "name": s(n)]
        case .createInputAction(let p, let m, let n, let ty, let ex): var d: [String: Any] = ["assetPath": s(p), "map": s(m), "name": s(n), "actionType": ty]; if let ex { d["expectedControlType"] = ex }; return d
        case .addInputBinding(let p, let m, let a, let path, let g): var d: [String: Any] = ["assetPath": s(p), "map": s(m), "action": s(a), "path": s(path)]; if let g { d["groups"] = s(g) }; return d
        case .changeInputBinding(let p, let m, let a, let id, let path): return ["assetPath": s(p), "map": s(m), "action": s(a), "bindingId": s(id), "path": s(path)]
        case .removeInputBinding(let p, let m, let a, let id): return ["assetPath": s(p), "map": s(m), "action": s(a), "bindingId": s(id)]
        }
    }

    // MARK: Validation helpers (shared with the parser)

    static func validAssetReference(_ s: String) -> Bool {
        let base = s.components(separatedBy: "::").first ?? s
        let sub = s.contains("::") ? s.components(separatedBy: "::").dropFirst().joined(separator: "::") : ""
        return UnityPolicy.isSafeProjectPath(base) && base.range(of: #"^[A-Za-z0-9_ ./#()+-]{1,240}$"#, options: .regularExpression) != nil && sub.count <= 80 && !sub.contains("\n")
    }
    static func validAssetPath(_ s: String, ext: String) -> Bool { s.hasSuffix(ext) && validAssetReference(s) && !s.contains("::") }
    /// An Input System control path: `<Keyboard>/space`, `<Gamepad>/buttonSouth`, `<Mouse>/leftButton`, `<XRController>{LeftHand}/trigger`. Bounded; no code, no wildcard-only paths, no `..`.
    static func validInputControlPath(_ s: String) -> Bool { s.range(of: #"^<[A-Za-z][A-Za-z0-9 ]{0,40}>(\{[A-Za-z0-9 ]{1,30}\})?(/[A-Za-z0-9 \[\]#]{1,40}){1,3}$"#, options: .regularExpression) != nil }
    static let inputActionTypes: Set<String> = ["Button", "Value", "PassThrough"]
    static func validInputName(_ s: String) -> Bool { s.range(of: #"^[A-Za-z][A-Za-z0-9 _-]{0,39}$"#, options: .regularExpression) != nil }
    static func validBindingID(_ s: String) -> Bool { s.range(of: #"^[0-9a-fA-F-]{36}$"#, options: .regularExpression) != nil }
}

extension UnityValue {
    var string: String? { if case .string(let s) = self { s } else { nil } }
}

// MARK: Validated construction (the ONLY place model-supplied dev operations are built)

extension UnityDevOp {
    struct Rejection: Error, Equatable, CustomStringConvertible { let description: String; init(_ d: String) { description = d } }

    static func configure(_ target: UnityTarget, kind: String, settings: [String: UnityValue]) throws -> UnityDevOp {
        guard let schema = UnityComponentSchema.table[kind] else { throw Rejection(UnityComponentSchema.Problem.unknownKind(kind).description) }
        do { return .configureComponent(target, kind: kind, settings: try UnityComponentSchema.validate(settings, against: schema, kind: kind)) }
        catch { throw Rejection("\(error)") }
    }

    static func environment(property: String, value: UnityValue) throws -> UnityDevOp {
        guard let t = UnityComponentSchema.environment[property] else { throw Rejection("“\(property)” is not a supported environment setting (\(UnityComponentSchema.environment.keys.sorted().joined(separator: ", ")))") }
        do { _ = try UnityComponentSchema.validate([property: value], against: [property: t], kind: "environment") } catch { throw Rejection("\(error)") }
        return .setEnvironment(property: property, value: value)
    }

    static func modelImporter(path: String, settings: [String: UnityValue]) throws -> UnityDevOp {
        guard UnityPolicy.isSafeProjectPath(path) else { throw Rejection("assetPath must be inside Assets/") }
        var rest = settings
        var out: [String: UnityValue] = [:]
        if let clip = rest.removeValue(forKey: "clipLoop") {
            guard case .array(let a) = clip, a.count == 2, case .string(let name) = a[0], case .bool = a[1], !name.isEmpty, name.count <= 80 else { throw Rejection("clipLoop must be [clip name, true|false]") }
            out["clipLoop"] = .array(a)
        }
        do { out.merge(try UnityComponentSchema.validate(rest.isEmpty && !out.isEmpty ? [:] : rest, against: UnityComponentSchema.modelImporter, kind: "model importer")) { $1 } }
        catch UnityComponentSchema.Problem.invalid(_, let why) where rest.isEmpty && why.contains("between 1 and 16") { /* only clipLoop was given */ }
        catch { throw Rejection("\(error)") }
        guard !out.isEmpty else { throw Rejection("no import setting given") }
        return .setModelImporter(assetPath: path, settings: out)
    }
}


// MARK: What the goal itself asked for (destructive / structural operations are never inferred from a model's plan)

struct UnityGoalIntent: Equatable, Sendable {
    var sceneCreation = false
    var componentRemoval = false
    var prefabUnpack = false
    static let none = UnityGoalIntent()

    init() {}
    /// Only the user's own goal words count (EN/TR). A plan, a model answer or a research page can never set these.
    init(goal: String) {
        let t = ResearchText.fold(goal)
        func has(_ ps: [String]) -> Bool { ps.contains { t.contains($0) } }
        sceneCreation = has(["create a scene", "create a new scene", "new scene", "add a scene", "create scene", "yeni sahne", "sahne olustur", "sahne yarat"])
        componentRemoval = has(["remove the component", "remove component", "delete the component", "remove its", "bileseni kaldir", "bileseni sil", "bileseni cikar", "remove the collider", "remove the rigidbody", "remove the light", "remove the audiosource"])
        prefabUnpack = has(["unpack", "break the prefab", "prefab baglantisini", "prefab'i coz", "unlink the prefab"])
    }
}

// MARK: Policy for the operator operations

extension UnityPolicy {
    /// Pure. Order: capability → paths inside Assets/ → goal-explicit structural changes → precise targets → editor state (Play Mode, compiling) → unsaved scene work → approvals.
    static func authorizeDev(_ d: UnityDevOp, capabilities: CapabilitySet, status: UnityStatusSnapshot?, goal: UnityGoalIntent, destructiveRequested: Bool, approvedDirtyScenes: Set<String>) -> Decision {
        // Removing a component / unpacking a prefab is a structural, hard-to-undo change: the GOAL must ask for it, then each action asks the user (like deleteGameObject).
        switch d {
        case .removeComponent(let t, let c, _):
            guard goal.componentRemoval else { return .deny(.securityBlocked, "Removing a component was not requested in the goal.") }
            guard t.isPrecise else { return .deny(.ambiguousTarget, "A component to remove must be on an object identified by path or global ID.") }
            if ["Transform", "RectTransform"].contains(c) { return .deny(.securityBlocked, "A Transform cannot be removed.") }
            if let denied = editorStateDenial(.dev(d), status: status) { return denied }
            return .needsApproval(action: "Remove \(c) from \(t.display)", reason: "The task asked for it explicitly. JARVIS records an Undo step, but the removal is permanent once the scene is saved.", risk: .high)
        case .unpackPrefab(let t, _):
            guard goal.prefabUnpack else { return .deny(.securityBlocked, "Unpacking a prefab was not requested in the goal.") }
            guard t.isPrecise else { return .deny(.ambiguousTarget, "A prefab instance to unpack must be identified by path or global ID.") }
            if let denied = editorStateDenial(.dev(d), status: status) { return denied }
            return .needsApproval(action: "Unpack the prefab instance \(t.display)", reason: "Unpacking breaks the link to the prefab asset: later changes to the prefab no longer reach this object.", risk: .high)
        case .createScene:
            guard goal.sceneCreation else { return .deny(.securityBlocked, "Creating a scene was not requested in the goal.") }
        default: break
        }
        guard capabilities.allows(d.capability) else { return .deny(.capabilityDenied, "This task does not grant \(d.capability.rawValue).") }
        for p in d.assetPaths where !isSafeProjectPath(p.components(separatedBy: "::").first ?? p) { return .deny(.workspaceViolation, "\(p) is not a path inside Assets/.") }
        if d.isPersistentMutation {
            for t in d.mutationTargets where !t.isPrecise { return .deny(.ambiguousTarget, "A GameObject must be identified by path or global ID, not by name \"\(t.name ?? "?")\".") }
            if case .editGameObject(_, let e) = d, e.isEmpty { return .deny(.malformedPlan, "The edit changes nothing.") }
        }
        if let denied = editorStateDenial(.dev(d), status: status) { return denied }
        if d.isPersistentMutation, d.touchesScene, let status {
            let dirty = status.userDirtyScenes.filter { !approvedDirtyScenes.contains($0.path) }
            if !dirty.isEmpty {
                let names = dirty.map { $0.path.isEmpty ? "(untitled)" : $0.path }.joined(separator: ", ")
                return .needsApproval(action: "Modify Unity scene with your unsaved changes: \(names)", reason: "The scene has unsaved changes JARVIS did not make. Saving it would include them. JARVIS only continues if you approve.", risk: .high)
            }
        }
        switch d {
        case .applyPrefabOverrides(let t): return .needsApproval(action: "Apply JARVIS' overrides of \(t.display) to its prefab asset", reason: "The prefab asset is shared: every instance of it receives these changes. Only overrides JARVIS made are applied; yours are left alone.", risk: .medium)
        case .setModelImporter(let p, let s): return .needsApproval(action: "Change the import settings of \(p) (\(s.keys.sorted().joined(separator: ", ")))", reason: "Import settings change how the model is re-imported for the whole project. JARVIS records the previous values and verifies the result after the re-import.", risk: .medium)
        default: return .allow
        }
    }
}
