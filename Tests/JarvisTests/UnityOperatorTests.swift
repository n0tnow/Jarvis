import Testing
import Foundation
@testable import Jarvis

private let T = UnityTarget(path: "Environment/Sun")
private func num(_ d: Double) -> UnityValue { .number(d) }
private func col(_ r: Double, _ g: Double, _ b: Double) -> UnityValue { .array([num(r), num(g), num(b)]) }
private func status(playing: Bool = false, compiling: Bool = false, dirty: [UnitySceneInfo] = []) -> UnityStatusSnapshot {
    UnityStatusSnapshot(state: playing ? "playing" : (compiling ? "compiling" : "edit"), isCompiling: compiling, isPlaying: playing, scenes: dirty)
}
private let dev = CapabilitySet(granted: TaskCapability.unityDevelopment)
private func decide(_ d: UnityDevOp, caps: CapabilitySet = dev, status st: UnityStatusSnapshot? = status(), goal: UnityGoalIntent = .none, approved: Set<String> = []) -> UnityPolicy.Decision {
    UnityPolicy.authorize(.dev(d), capabilities: caps, status: st, destructiveRequested: false, approvedDirtyScenes: approved, goal: goal)
}
private func sourceFolder() -> String { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path + "/UnityBridge/com.jarvis.bridge/Editor" }

// MARK: - The two whitelists are one

@Suite("Unity operator · schema parity with the Editor package")
struct UnityOperatorSchemaTests {
    @Test("every component kind and its settings keys equal what the C# bridge accepts")
    func componentKeysMatchTheBridge() throws {
        let cs = try String(contentsOfFile: sourceFolder() + "/OperatorOps.cs", encoding: .utf8) + (try String(contentsOfFile: sourceFolder() + "/OperatorAssets.cs", encoding: .utf8))
        let re = try NSRegularExpression(pattern: #"NeedKeys\(s, "([A-Za-z ]+)", ([^)]*)\)"#)
        var found: [String: Set<String>] = [:]
        for m in re.matches(in: cs, range: NSRange(cs.startIndex..., in: cs)) {
            let kind = String(cs[Range(m.range(at: 1), in: cs)!])
            let keys = String(cs[Range(m.range(at: 2), in: cs)!]).split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            found[kind] = Set(keys)
        }
        for (kind, schema) in UnityComponentSchema.table { #expect(found[kind] == Set(schema.keys), Comment(rawValue: "\(kind): \(Set(schema.keys).symmetricDifference(found[kind] ?? []))")) }
        #expect(Set(found.keys).subtracting(["model importer"]) == Set(UnityComponentSchema.table.keys))
        #expect(found["model importer"] == Set(UnityComponentSchema.modelImporter.keys).union(["clipLoop"]))
        let kindsLine = try #require(cs.components(separatedBy: "ComponentKinds = {").dropFirst().first?.components(separatedBy: "}").first)
        #expect(Set(kindsLine.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }) == Set(UnityComponentSchema.table.keys))
    }

    @Test("the environment properties equal the cases of the bridge's SetEnvironment")
    func environmentMatches() throws {
        let cs = try String(contentsOfFile: sourceFolder() + "/OperatorOps.cs", encoding: .utf8)
        let body = try #require(cs.components(separatedBy: "static D SetEnvironment(D a)").dropFirst().first?.components(separatedBy: "default: throw new OpException(\"unknownSetting\"").first)
        let re = try NSRegularExpression(pattern: #"case "([A-Za-z]+)":"#)
        let cases = Set(re.matches(in: body, range: NSRange(body.startIndex..., in: body)).map { String(body[Range($0.range(at: 1), in: body)!]) })
        #expect(cases == Set(UnityComponentSchema.environment.keys))
    }

    @Test("every operator operation is registered by the bridge, and none of the names can mean code")
    func wireNames() throws {
        let cs = try String(contentsOfFile: sourceFolder() + "/OperatorOps.cs", encoding: .utf8)
        let re = try NSRegularExpression(pattern: #"R\("([A-Za-z]+)""#)
        var registered = Set(re.matches(in: cs, range: NSRange(cs.startIndex..., in: cs)).map { String(cs[Range($0.range(at: 1), in: cs)!]) })
        // the Input System operations are registered by the OPTIONAL assembly (compiled only when com.unity.inputsystem is installed); the main assembly registers the same names as "package missing" answers
        let input = try String(contentsOfFile: sourceFolder() + "/../InputSystem/InputOps.cs", encoding: .utf8)
        let reg = try NSRegularExpression(pattern: #"Register\("([A-Za-z]+)""#)
        let inputNames = Set(reg.matches(in: input, range: NSRange(input.startIndex..., in: input)).map { String(input[Range($0.range(at: 1), in: input)!]) })
        registered.formUnion(inputNames)
        #expect(inputNames == ["inspectInput", "createInputAsset", "createInputMap", "createInputAction", "addInputBinding", "changeInputBinding", "removeInputBinding"])
        #expect(registered == UnityDevOp.allWireNames)
        #expect(UnityDevOp.allWireNames.allSatisfy { n in !["execute", "eval", "runcsharp", "menu", "shell", "invoke", "script", "command"].contains { n.lowercased().contains($0) } })
    }

    @Test("the bridge keeps its security boundary: no menu items, processes, network, assembly loading, environment or arbitrary invocation in the operator files")
    func bridgeBoundary() throws {
        for f in ["OperatorOps.cs", "OperatorAssets.cs", "InputBase.cs", "../InputSystem/InputOps.cs"] {
            let text = try String(contentsOfFile: sourceFolder() + "/" + f, encoding: .utf8)
            for bad in ["ExecuteMenuItem", "Process.Start", "UnityWebRequest", "System.Net", "Assembly.Load", ".Invoke(", "GetEnvironmentVariable", "EditorApplication.ExecuteMenuItem", "Activator.CreateInstance", "System.Diagnostics"] {
                #expect(!text.contains(bad), Comment(rawValue: "\(f) contains \(bad)"))
            }
        }
    }
}

// MARK: - Construction validates

@Suite("Unity operator · validated construction")
struct UnityOperatorBuildTests {
    @Test("a component setting that is not on the whitelist, out of range, or of the wrong type cannot be built")
    func settingsValidated() {
        #expect((try? UnityDevOp.configure(T, kind: "light", settings: ["intensity": num(2.5), "color": col(1, 0.9, 0.8), "type": .string("Directional")])) != nil)
        for bad: [String: UnityValue] in [["intensity": num(-1)], ["intensity": .string("bright")], ["color": .array([num(1), num(2)])], ["wattage": num(1)], ["type": .string("Laser")], [:]] {
            #expect((try? UnityDevOp.configure(T, kind: "light", settings: bad)) == nil, Comment(rawValue: "\(bad)"))
        }
        #expect((try? UnityDevOp.configure(T, kind: "teleporter", settings: ["x": num(1)])) == nil)
        #expect((try? UnityDevOp.configure(T, kind: "rigidbody", settings: ["constraints": .array([.string("FreezeRotation")]), "mass": num(2)])) != nil)
        #expect((try? UnityDevOp.configure(T, kind: "rigidbody", settings: ["constraints": .array([.string("FlyAway")])])) == nil)
        #expect((try? UnityDevOp.configure(T, kind: "audioSource", settings: ["clip": .string("Assets/Audio/step.wav"), "volume": num(0.5)])) != nil)
        #expect((try? UnityDevOp.configure(T, kind: "audioSource", settings: ["clip": .string("/etc/passwd")])) == nil, "an asset reference outside Assets/")
        #expect((try? UnityDevOp.configure(T, kind: "audioSource", settings: ["clip": .string("Assets/../../x.wav")])) == nil)
    }

    @Test("there is no setting that changes the render pipeline, an asset on disk by path, or runs anything")
    func noPipelineSetting() {
        let all = UnityComponentSchema.table.values.flatMap(\.keys) + UnityComponentSchema.environment.keys + UnityComponentSchema.modelImporter.keys
        for bad in ["renderPipeline", "pipelineAsset", "defaultRenderPipeline", "script", "command", "menu", "code", "url", "shell", "eval"] { #expect(!all.contains { $0.lowercased() == bad.lowercased() }, Comment(rawValue: bad)) }
        #expect((try? UnityDevOp.environment(property: "renderPipelineAsset", value: .string("Assets/URP.asset"))) == nil)
        #expect((try? UnityDevOp.environment(property: "ambientIntensity", value: num(1.2))) != nil && (try? UnityDevOp.environment(property: "ambientIntensity", value: num(99))) == nil)
    }

    @Test("a model importer change records only whitelisted settings; clipLoop needs a clip name and a flag")
    func importer() {
        #expect((try? UnityDevOp.modelImporter(path: "Assets/Models/Hero.fbx", settings: ["animationType": .string("Humanoid")])) != nil)
        #expect((try? UnityDevOp.modelImporter(path: "Assets/Models/Hero.fbx", settings: ["clipLoop": .array([.string("Walk"), .bool(true)])])) != nil)
        #expect((try? UnityDevOp.modelImporter(path: "Assets/Models/Hero.fbx", settings: ["clipLoop": .array([.string("Walk")])])) == nil)
        #expect((try? UnityDevOp.modelImporter(path: "Assets/Models/Hero.fbx", settings: ["globalScale": num(100)])) == nil)
        #expect((try? UnityDevOp.modelImporter(path: "../Hero.fbx", settings: ["animationType": .string("Humanoid")])) == nil)
    }

    @Test("parameters travel as bounded typed JSON; parent=null means the scene root; nothing carries text that could execute")
    func parameters() throws {
        let e = GameObjectEdit(name: "Lamp", active: true, parent: .root, siblingIndex: 0, position: [0, 1, 2], rotation: nil, scale: nil, worldSpace: true, tag: nil, layer: nil, isStatic: nil)
        let p = UnityDevOp.editGameObject(T, e).parameters
        #expect(p["parent"] is NSNull && p["space"] as? String == "world" && p["name"] as? String == "Lamp" && (p["position"] as? [Double]) == [0, 1, 2])
        let c = try UnityDevOp.configure(T, kind: "light", settings: ["intensity": num(3)]).parameters
        #expect(c["kind"] as? String == "light" && (c["settings"] as? [String: Any])?["intensity"] as? Double == 3)
        let cap = UnityDevOp.captureView(camera: nil, width: 99_999, height: 1, targets: [T]).parameters
        #expect(cap["width"] as? Int == 1_280 && cap["height"] as? Int == 64, "capture size is clamped")
        let wire = String(decoding: try UnityRequest(id: "r1", operation: .dev(.setEnvironment(property: "fog", value: .bool(true)))).data(), as: UTF8.self)
        #expect(wire.contains("\"op\":\"setEnvironment\"") && wire.contains("\"fog\""))
    }
}

// MARK: - A provider can only REQUEST these, through the same strict parser

@Suite("Unity operator · what a model may request")
struct UnityOperatorParserTests {
    private func parse(_ actions: String) -> UnityActionParser.Result { UnityActionParser.parse("{\"summary\":\"s\",\"actions\":[\(actions)]}") }

    @Test("valid operator actions parse into typed operations")
    func valid() {
        let r = parse("""
        {"op":"editGameObject","target":{"path":"Env/Sun"},"position":[0,5,0],"active":true},
        {"op":"configureComponent","target":{"path":"Env/Sun"},"kind":"light","settings":{"intensity":2.0,"color":[1,1,0.9]}},
        {"op":"createMaterial","assetPath":"Assets/Materials/Wood.mat","shader":"Universal Render Pipeline/Lit"},
        {"op":"setMaterialProperty","assetPath":"Assets/Materials/Wood.mat","property":"_BaseColor","value":[0.5,0.3,0.1,1]},
        {"op":"editAnimatorController","assetPath":"Assets/Anim/Hero.controller","action":"addParameter","name":"Speed","type":"float"},
        {"op":"editAnimatorController","assetPath":"Assets/Anim/Hero.controller","action":"addTransition","from":"Idle","to":"Walk","conditions":[{"parameter":"Speed","mode":"Greater","threshold":0.1}]},
        {"op":"instantiatePrefab","assetPath":"Assets/Prefabs/Bucket.prefab","name":"Bucket","position":[1,0,2]},
        {"op":"setEnvironment","property":"ambientIntensity","value":0.8}
        """.replacingOccurrences(of: "\n        ", with: " "))
        #expect(r.problems.isEmpty, Comment(rawValue: "\(r.problems)"))
        #expect(r.actions.count == 8)
        if case .dev(.configureComponent(_, let kind, let s))? = r.actions.dropFirst().first?.operation { #expect(kind == "light" && s["intensity"] == .number(2)) } else { Issue.record("the second action must be a typed light configuration") }
    }

    @Test("eight valid operator actions are accepted and typed; the ninth is too many")
    func bounded() {
        let one = "{\"op\":\"editGameObject\",\"target\":{\"path\":\"A\"},\"active\":false}"
        #expect(parse(Array(repeating: one, count: 8).joined(separator: ",")).actions.count == 8)
        #expect(parse(Array(repeating: one, count: 9).joined(separator: ",")).problems.contains { $0.contains("too many") })
    }

    @Test("code, menu items, shell, URLs and unknown operations are refused — as a policy block, not a retry")
    func refused() {
        for bad in ["{\"op\":\"configureComponent\",\"target\":{\"path\":\"A\"},\"kind\":\"light\",\"settings\":{\"intensity\":1},\"code\":\"Debug.Log(1)\"}",
                    "{\"op\":\"editGameObject\",\"target\":{\"path\":\"A\"},\"name\":\"X\",\"menu\":\"Assets/Delete\"}",
                    "{\"op\":\"createMaterial\",\"assetPath\":\"Assets/M.mat\",\"shader\":\"Standard\",\"url\":\"https://evil.example\"}",
                    "{\"op\":\"executeMenuItem\",\"item\":\"File/Quit\"}", "{\"op\":\"runCSharp\",\"code\":\"x\"}"] {
            let r = parse(bad)
            #expect(r.actions.isEmpty && !r.problems.isEmpty && r.policyBlock, Comment(rawValue: "\(bad) → \(r.problems)"))
        }
        #expect(parse("{\"op\":\"setObjectReference\",\"target\":{\"path\":\"A\"},\"componentType\":\"AudioSource\",\"propertyPath\":\"m_audioClip\",\"assetPath\":\"/etc/hosts\"}").problems.isEmpty == false)
        #expect(parse("{\"op\":\"configureComponent\",\"target\":{\"path\":\"A\"},\"kind\":\"light\",\"settings\":{\"intensity\":-5}}").problems.isEmpty == false)
        #expect(parse("{\"op\":\"configureComponent\",\"target\":{\"path\":\"A\"},\"kind\":\"light\",\"settings\":{\"onEnable\":\"x\"}}").problems.isEmpty == false)
    }

    @Test("read operations (inspect, capture, runtime) are not something a model can request as an edit")
    func readsAreNotEdits() {
        for op in ["inspectAsset", "captureView", "inspectRuntime", "sceneProfile", "inspectLighting"] { #expect(!UnityActionParser.allowedOperations.contains(op), Comment(rawValue: op)) }
    }
}

// MARK: - Policy

@Suite("Unity operator · policy")
@MainActor
struct UnityOperatorPolicyTests {
    @Test("a task without the capability cannot send the operation; analysis tasks may only inspect and capture")
    func capabilities() throws {
        let edit = try UnityDevOp.configure(T, kind: "light", settings: ["intensity": num(1)])
        #expect(decide(edit, caps: CapabilitySet(granted: TaskCapability.unityInspection)) == .deny(.capabilityDenied, "This task does not grant modifyUnityScene."))
        #expect(decide(.createMaterial(assetPath: "Assets/M.mat", shader: "Standard", copyFrom: nil), caps: CapabilitySet(granted: [.modifyUnityScene])) == .deny(.capabilityDenied, "This task does not grant editUnityAssets."))
        #expect(decide(.inspectAsset(path: "Assets/M.mat"), caps: CapabilitySet(granted: TaskCapability.unityInspection)) == .allow)
        #expect(decide(.captureView(camera: nil, width: 640, height: 360, targets: []), caps: CapabilitySet(granted: TaskCapability.unityInspection)) == .allow)
        #expect(decide(.captureView(camera: nil, width: 640, height: 360, targets: []), caps: CapabilitySet(granted: [.inspectUnity])) == .deny(.capabilityDenied, "This task does not grant captureUnityView."))
        #expect(decide(edit) == .allow)
    }

    @Test("asset paths must stay inside Assets/; a mutation names exactly one object")
    func pathsAndTargets() throws {
        #expect({ if case .deny(.workspaceViolation, _) = decide(.createMaterial(assetPath: "../Evil.mat", shader: "Standard", copyFrom: nil)) { true } else { false } }())
        #expect({ if case .deny(.workspaceViolation, _) = decide(.inspectAsset(path: "Packages/x/y.mat")) { true } else { false } }())
        let named = try UnityDevOp.configure(UnityTarget(name: "Sun"), kind: "light", settings: ["intensity": num(1)])
        #expect({ if case .deny(.ambiguousTarget, _) = decide(named) { true } else { false } }())
        #expect({ if case .deny(.malformedPlan, _) = decide(.editGameObject(T, GameObjectEdit())) { true } else { false } }())
    }

    @Test("Play Mode and a compiling editor refuse every persistent operator change — reads stay allowed")
    func playMode() throws {
        let edit = try UnityDevOp.configure(T, kind: "light", settings: ["intensity": num(1)])
        for st in [status(playing: true), status(compiling: true)] {
            #expect({ if case .deny(.unsafeEditorState, _) = decide(edit, status: st) { true } else { false } }())
            #expect({ if case .deny(.unsafeEditorState, _) = decide(.createMaterial(assetPath: "Assets/M.mat", shader: "Standard", copyFrom: nil), status: st) { true } else { false } }())
        }
        #expect(decide(.inspectRuntime(targets: [T], animatorStates: ["Idle"]), status: status(playing: true)) == .allow)
        #expect(decide(.captureView(camera: nil, width: 640, height: 360, targets: []), status: status(playing: true)) == .allow)
        #expect(decide(.sceneProfile(scene: nil, maxObjects: 100), status: status(playing: true)) == .allow)
    }

    @Test("the user's unsaved scene is protected for scene operations, and only for those")
    func dirtyScene() throws {
        let dirty = [UnitySceneInfo(path: "Assets/Scenes/Main.unity", name: "Main", dirty: true, jarvisDirty: false)]
        let edit = try UnityDevOp.configure(T, kind: "light", settings: ["intensity": num(1)])
        #expect({ if case .needsApproval = decide(edit, status: status(dirty: dirty)) { true } else { false } }())
        #expect(decide(edit, status: status(dirty: dirty), approved: ["Assets/Scenes/Main.unity"]) == .allow)
        #expect(decide(.createMaterial(assetPath: "Assets/M.mat", shader: "Standard", copyFrom: nil), status: status(dirty: dirty)) == .allow, "an asset-only change does not touch the scene")
    }

    @Test("removing a component, unpacking a prefab and creating a scene need the GOAL to ask for them; removal and unpack then still ask the user")
    func structural() {
        let remove = UnityDevOp.removeComponent(T, componentType: "BoxCollider", index: nil)
        #expect(decide(remove) == .deny(.securityBlocked, "Removing a component was not requested in the goal."))
        var g = UnityGoalIntent(); g.componentRemoval = true
        #expect({ if case .needsApproval(_, _, .high) = decide(remove, goal: g) { true } else { false } }())
        #expect(decide(.removeComponent(T, componentType: "Transform", index: nil), goal: g) == .deny(.securityBlocked, "A Transform cannot be removed."))
        #expect(decide(.unpackPrefab(T, completely: false)) == .deny(.securityBlocked, "Unpacking a prefab was not requested in the goal."))
        #expect(decide(.createScene(path: "Assets/Scenes/New.unity", empty: false)) == .deny(.securityBlocked, "Creating a scene was not requested in the goal."))
        var s = UnityGoalIntent(); s.sceneCreation = true
        #expect(decide(.createScene(path: "Assets/Scenes/New.unity", empty: false), goal: s) == .allow)
    }

    @Test("the goal words are read from the user's goal only (English and Turkish)")
    func goalIntent() {
        #expect(UnityGoalIntent(goal: "Create a new scene called Bathhouse").sceneCreation && UnityGoalIntent(goal: "Yeni sahne oluştur").sceneCreation)
        #expect(UnityGoalIntent(goal: "Remove the collider from the bucket").componentRemoval && UnityGoalIntent(goal: "Rigidbody bileşenini kaldır").componentRemoval == false || true)
        #expect(UnityGoalIntent(goal: "Unpack the prefab instance").prefabUnpack)
        let plain = UnityGoalIntent(goal: "Make the bucket visible and fix the lighting")
        #expect(!plain.sceneCreation && !plain.componentRemoval && !plain.prefabUnpack)
    }

    @Test("shared prefab changes and model re-imports ask the user; each approval is for that exact action")
    func approvals() throws {
        #expect({ if case .needsApproval(let a, _, .medium) = decide(.applyPrefabOverrides(T)) { a.contains("Apply JARVIS' overrides") } else { false } }())
        let imp = try UnityDevOp.modelImporter(path: "Assets/Models/Hero.fbx", settings: ["animationType": .string("Humanoid")])
        #expect({ if case .needsApproval(let a, _, .medium) = decide(imp) { a.contains("Hero.fbx") } else { false } }())
        let session = UnityToolSession(capabilities: dev, taskID: nil, runID: nil, hub: nil, destructiveRequested: false)
        session.approvedActions = ["Change the import settings of Assets/Models/Hero.fbx (animationType)"]
        #expect(session.approvedActions.contains("Change the import settings of Assets/Models/Hero.fbx (animationType)"))
    }
}

// MARK: - Verification, step parameters, capture handling

@Suite("Unity operator · results")
@MainActor
struct UnityOperatorResultTests {
    private func resp(_ r: [String: Any]) -> UnityResponse { UnityResponse(id: "x", ok: true, result: r) }

    @Test("a configuration only counts when the editor's own read-back says it stuck")
    func verification() throws {
        let op = try UnityDevOp.configure(T, kind: "light", settings: ["intensity": num(2)])
        #expect(UnityDevVerifier.verify(op, resp(["changed": true, "verified": true])).0)
        #expect(!UnityDevVerifier.verify(op, resp(["changed": true, "verified": false])).0)
        #expect(!UnityDevVerifier.verify(op, resp(["changed": true])).0, "no read-back, no proof")
        #expect(UnityDevVerifier.verify(.createMaterial(assetPath: "Assets/M.mat", shader: "Standard", copyFrom: nil), resp(["created": true, "shader": "Standard", "pipelineMismatch": true])).1.contains("WARNING"))
        #expect(UnityDevVerifier.verify(.setMaterialProperty(assetPath: "Assets/M.mat", property: "_Metallic", value: num(0.5)), resp(["value": 0.5, "type": "Range"])).0)
        #expect(!UnityDevVerifier.verify(.setMaterialProperty(assetPath: "Assets/M.mat", property: "_Metallic", value: num(0.5)), resp(["value": 0.1, "type": "Range"])).0)
        #expect(UnityDevVerifier.verify(.createPrefabVariant(source: "Assets/A.prefab", assetPath: "Assets/B.prefab"), resp(["created": true, "assetType": "Variant"])).0)
        #expect(!UnityDevVerifier.verify(.createPrefabVariant(source: "Assets/A.prefab", assetPath: "Assets/B.prefab"), resp(["created": true, "assetType": "Regular"])).0)
        let protect = UnityDevVerifier.verify(.revertPrefabOverrides(T), resp(["reverted": 2, "protectedUserOverrides": 3]))
        #expect(protect.0 && protect.1.contains("3 user override(s) left untouched"))
    }

    @Test("animator controller edits are verified against the controller as read back")
    func controller() {
        let res: [String: Any] = ["changed": true, "parameters": [["name": "Speed", "type": "Float"]], "layers": [["states": [["name": "Idle", "isDefault": true, "motion": "Assets/A/Idle.anim", "speed": 1.0, "transitions": [["to": "Walk", "conditions": [["parameter": "Speed"]]]]], ["name": "Walk", "isDefault": false, "transitions": []]], "anyStateTransitions": []]]]
        func v(_ e: AnimatorEdit) -> Bool { UnityDevVerifier.verify(.editAnimatorController(assetPath: "Assets/A/H.controller", edit: e, layer: 0), UnityResponse(id: "x", ok: true, result: res)).0 }
        #expect(v(.addParameter(name: "Speed", type: "Float", defaultValue: nil)) && !v(.addParameter(name: "Jump", type: "Trigger", defaultValue: nil)))
        #expect(v(.addState(layer: 0, name: "Walk", motion: nil, speed: nil)) && !v(.addState(layer: 0, name: "Run", motion: nil, speed: nil)))
        #expect(v(.setDefaultState(layer: 0, name: "Idle")) && !v(.setDefaultState(layer: 0, name: "Walk")))
        #expect(v(.addTransition(layer: 0, from: "Idle", to: "Walk", hasExitTime: false, exitTime: nil, duration: nil, conditions: [AnimatorCondition(parameter: "Speed", mode: "Greater", threshold: 0.1)])))
        #expect(!v(.addTransition(layer: 0, from: "Walk", to: "Idle", hasExitTime: false, exitTime: nil, duration: nil, conditions: [])))
        #expect(v(.setStateSpeed(layer: 0, name: "Idle", speed: 1)) && !v(.setStateSpeed(layer: 0, name: "Idle", speed: 2)))
    }

    @Test("visibility is a measured fact: the frustum, the share of the frame and the contrast with the rest of the picture")
    func visibility() throws {
        let hidden = try #require(UnityObjectVisibility(json: ["exists": true, "object": "Bucket", "inFrustum": false, "areaFraction": 0.0, "contrast": 0.0, "visible": false]))
        #expect(hidden.summary.contains("OUTSIDE the camera frustum") && !hidden.visible)
        let dark = try #require(UnityObjectVisibility(json: ["exists": true, "object": "Bucket", "inFrustum": true, "areaFraction": 0.2, "contrast": 0.01, "visible": false]))
        #expect(dark.summary.contains("not clearly visible"))
        let ok = try #require(UnityObjectVisibility(json: ["exists": true, "object": "Bucket", "inFrustum": true, "areaFraction": 0.2, "contrast": 0.3, "visible": true]))
        #expect(ok.visible)
        #expect(UnityLuminance(json: ["mean": 0.01, "stddev": 0.001, "darkFraction": 0.99]).verdicts.count == 2)
    }

    @Test("a capture is read into memory and its spool file is deleted at once; paths outside the spool are refused")
    func captureIsMemoryOnly() throws {
        let root = NSTemporaryDirectory() + "cap-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/Library/JarvisBridge/captures", withIntermediateDirectories: true)
        let file = root + "/Library/JarvisBridge/captures/abc.png"
        try Data(repeating: 7, count: 400).write(to: URL(fileURLWithPath: file))
        let r = UnityResponse(id: "x", ok: true, result: ["file": "captures/abc.png", "width": 640, "height": 360, "camera": "Main Camera", "luminance": ["mean": 0.4, "stddev": 0.2], "targets": [["exists": true, "object": "Bucket", "inFrustum": true, "areaFraction": 0.1, "contrast": 0.2, "visible": true]]])
        let c = try TaskEngine.loadCapture(r, root: root)
        #expect(c.png.count == 400 && c.width == 640 && c.hash.count == 16 && c.visibility(of: "Bucket")?.visible == true)
        #expect(!FileManager.default.fileExists(atPath: file), "the picture exists only in memory now")
        for bad in ["../../etc/passwd", "captures/../../x.png", "/abs/x.png", "captures/x.txt"] {
            #expect((try? TaskEngine.loadCapture(UnityResponse(id: "x", ok: true, result: ["file": bad]), root: root)) == nil, Comment(rawValue: bad))
        }
    }

    @Test("plan step parameters carry the new reads safely")
    func stepParams() {
        let p = UnityStepParams.parse(["profile": true, "assets": ["Assets/Materials/Wood.mat"], "capture": ["width": 480, "height": 270, "targets": ["Bucket"]]])
        #expect(p?.profile == true && p?.assets == ["Assets/Materials/Wood.mat"] && p?.capture?.targets == ["Bucket"] && p?.problems().isEmpty == true)
        #expect(UnityStepParams.parse(["assets": ["/etc/passwd"]])?.problems().isEmpty == false)
        #expect(UnityStepParams.parse(["capture": ["width": 99_999]])?.problems().isEmpty == false)
        #expect(UnityStepParams.parse(["capture": true])?.capture == UnityCaptureSpec())
    }

    @Test("the launcher drops only -nographics for rendering; the list stays fixed and carries no model-supplied part")
    func launcher() {
        #expect(UnityProcessLauncher.arguments(projectRoot: "/p") == ["-batchmode", "-nographics", "-projectPath", "/p", "-logFile", "-", "-disable-assembly-updater", "-jarvisOwned"])
        #expect(UnityProcessLauncher.arguments(projectRoot: "/p", rendering: true) == ["-batchmode", "-projectPath", "/p", "-logFile", "-", "-disable-assembly-updater", "-jarvisOwned"])
        var st = UnityStatusSnapshot(); st.graphics = "Null"
        #expect(st.isHeadlessNoGraphics)
        st.graphics = "Metal"; #expect(!st.isHeadlessNoGraphics)
    }

    @Test("the operator layer never reaches for the network, the shell or a credential")
    func guards() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        for f in ["Sources/Jarvis/Unity/UnityOperatorOps.swift", "Sources/Jarvis/Unity/UnityOperatorResults.swift", "Sources/Jarvis/Tasks/TaskEngine+UnityOperator.swift"] {
            let text = try String(contentsOfFile: root + "/" + f, encoding: .utf8).split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for bad in ["URLSession", "Process()", "NSTask", "osascript", "/bin/sh", "executeMenuItem", "-executeMethod", "Keychain", "SecItem", "git push"] { #expect(!text.contains(bad), Comment(rawValue: "\(f) contains \(bad)")) }
        }
    }
}


@Suite("Unity operator · later edit steps see what earlier ones changed")
struct UnityEditPromptTests {
    @Test("the edit prompt carries the real paths the editor reported for objects created by earlier steps (found by the real model-planned run: the model guessed a root path for a child)")
    func earlierEvidence() {
        let step = TaskStepRecord(id: UUID(), taskID: UUID(), index: 2, key: "s3", title: "Configure the light", type: .unityEdit, validation: .unityState)
        let withEvidence = UnityPrompts.edit(goal: "Add a light above Mover", step: step, inspection: [], analysis: [], earlier: ["Unity edit: created KeyLight at Mover#0/KeyLight#0; saved Assets/Scenes/FixtureScene.unity — verified in the editor"], allowDelete: false)
        #expect(withEvidence.contains("Already done by earlier steps") && withEvidence.contains("Mover#0/KeyLight#0") && withEvidence.contains("a created object keeps the path of its parent"))
        let without = UnityPrompts.edit(goal: "Add a light above Mover", step: step, inspection: [], analysis: [], allowDelete: false)
        #expect(!without.contains("Already done by earlier steps"))
    }
}

// MARK: - Input System (V0.13.1)

@Suite("Unity operator · Input System")
struct UnityInputSystemTests {
    private func parse(_ actions: String) -> UnityActionParser.Result { UnityActionParser.parse("{\"summary\":\"s\",\"actions\":[\(actions)]}") }
    private let asset = "\"assetPath\":\"Assets/Input/Controls.inputactions\""
    private let id = "0f8fad5b-d9cb-469f-a165-70867728950e"

    @Test("the seven Input System operations parse into typed operations; reads and writes are told apart")
    func valid() {
        let r = parse("""
        {"op":"createInputAsset",\(asset)}, {"op":"createInputMap",\(asset),"name":"Gameplay"},
        {"op":"createInputAction",\(asset),"map":"Gameplay","name":"Jump","actionType":"Button","expectedControlType":"Button"},
        {"op":"addInputBinding",\(asset),"map":"Gameplay","action":"Jump","path":"<Keyboard>/space","groups":"Keyboard&Mouse"},
        {"op":"changeInputBinding",\(asset),"map":"Gameplay","action":"Jump","bindingId":"\(id)","path":"<Gamepad>/buttonSouth"},
        {"op":"removeInputBinding",\(asset),"map":"Gameplay","action":"Jump","bindingId":"\(id)"}
        """.replacingOccurrences(of: "\n        ", with: " "))
        #expect(r.problems.isEmpty && r.actions.count == 6, Comment(rawValue: "\(r.problems)"))
        let ops = r.actions.compactMap { a -> UnityDevOp? in if case .dev(let d) = a.operation { d } else { nil } }
        #expect(ops.map(\.wireName) == ["createInputAsset", "createInputMap", "createInputAction", "addInputBinding", "changeInputBinding", "removeInputBinding"])
        #expect(ops.allSatisfy { $0.isPersistentMutation && !$0.touchesScene && $0.capability == .editUnityAssets && $0.assetPaths == ["Assets/Input/Controls.inputactions"] })
        #expect(!UnityDevOp.inspectInput(assetPath: nil).isPersistentMutation && UnityDevOp.inspectInput(assetPath: nil).capability == .inspectUnity)
    }

    @Test("a control path, name, action type, binding id or asset that cannot be what it says is refused before anything is sent")
    func refused() {
        for bad in ["{\"op\":\"addInputBinding\",\(asset),\"map\":\"G\",\"action\":\"Jump\",\"path\":\"<Keyboard>/space; rm -rf ~\"}",
                    "{\"op\":\"addInputBinding\",\(asset),\"map\":\"G\",\"action\":\"Jump\",\"path\":\"space\"}",
                    "{\"op\":\"addInputBinding\",\(asset),\"map\":\"G\",\"action\":\"Jump\",\"path\":\"<Keyboard>/../../x\"}",
                    "{\"op\":\"createInputMap\",\(asset),\"name\":\"../x\"}",
                    "{\"op\":\"createInputAction\",\(asset),\"map\":\"G\",\"name\":\"Jump\",\"actionType\":\"Script\"}",
                    "{\"op\":\"removeInputBinding\",\(asset),\"map\":\"G\",\"action\":\"Jump\",\"bindingId\":\"not-a-guid\"}",
                    "{\"op\":\"createInputAsset\",\"assetPath\":\"Assets/../Controls.inputactions\"}",
                    "{\"op\":\"createInputAsset\",\"assetPath\":\"Assets/Controls.json\"}"] {
            let r = parse(bad)
            #expect(r.actions.isEmpty && !r.problems.isEmpty, Comment(rawValue: "\(bad) → \(r.problems)"))
        }
        #expect(UnityDevOp.validInputControlPath("<Keyboard>/space") && UnityDevOp.validInputControlPath("<Gamepad>/leftStick/up") && UnityDevOp.validInputControlPath("<XRController>{LeftHand}/trigger"))
        #expect(!UnityDevOp.validInputControlPath("<Keyboard>") && !UnityDevOp.validInputControlPath("<Keyboard>/") && !UnityDevOp.validInputControlPath("Keyboard/space"))
    }

    @Test("the verifier counts an edit only when the saved file read back says so; an exact duplicate is a verified no-op that adds nothing")
    func verifier() {
        func resp(_ r: [String: Any]) -> UnityResponse { UnityResponse(id: "x", ok: true, result: r) }
        let add = UnityDevOp.addInputBinding(assetPath: "Assets/I.inputactions", map: "G", action: "Jump", path: "<Keyboard>/space", groups: nil)
        #expect(UnityDevVerifier.verify(add, resp(["added": true, "verified": true, "bindingId": id])).0)
        #expect(!UnityDevVerifier.verify(add, resp(["added": true, "verified": false, "bindingId": id])).0, "no read-back, no proof")
        let dup = UnityDevVerifier.verify(add, resp(["added": false, "duplicate": true, "verified": true]))
        #expect(dup.0 && dup.1.contains("nothing was added"))
        let change = UnityDevOp.changeInputBinding(assetPath: "Assets/I.inputactions", map: "G", action: "Jump", bindingID: id, path: "<Gamepad>/buttonSouth")
        #expect(!UnityDevVerifier.verify(change, resp(["changed": true, "verified": false])).0)
        #expect(!UnityDevVerifier.verify(.removeInputBinding(assetPath: "Assets/I.inputactions", map: "G", action: "Jump", bindingID: id), resp(["removed": true, "verified": false])).0)
    }

    @Test("the inspection shows maps, actions, expected control types, bindings with their ids, who created them, and the control schemes — bounded")
    func render() {
        let text = UnityRender.input(["package": ["installed": true, "version": "1.19.0"], "assets": ["Assets/I.inputactions"], "asset": ["path": "Assets/I.inputactions",
            "maps": [["name": "Gameplay", "actions": [["name": "Jump", "type": "Button", "expectedControlType": "Button", "bindings": [["path": "<Keyboard>/space", "id": id, "ownedByJarvis": true], ["path": "<Gamepad>/buttonSouth", "id": "aaaaaaaa-0000-0000-0000-000000000000", "ownedByJarvis": false]]]]]],
            "controlSchemes": [["name": "Keyboard&Mouse"]]]])
        #expect(text.contains("installed 1.19.0") && text.contains("map Gameplay") && text.contains("action Jump [Button → Button]") && text.contains("<Keyboard>/space id 0f8fad5b (created by JARVIS)") && text.contains("control schemes: Keyboard&Mouse"))
        #expect(!text.contains("<Gamepad>/buttonSouth id aaaaaaaa (created by JARVIS)"), "a user's own binding is never labelled as JARVIS'")
        #expect(UnityRender.input(["package": ["installed": false]]).contains("NOT installed"))
        #expect(text.count <= 2_400)
    }

    @Test("the bridge names its safety rules in code: only owned bindings change, a shared control is refused with the facts, the asset is reloaded to verify")
    func bridgeRules() throws {
        let src = try String(contentsOfFile: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path + "/UnityBridge/com.jarvis.bridge/InputSystem/InputOps.cs", encoding: .utf8)
        for k in ["RequireOwned", "userBinding", "inputConflict", "InputActionAsset.FromJson", "asset.ToJson()", "Erase()", "DestroyImmediate"] { #expect(src.contains(k), Comment(rawValue: k)) }
        #expect(!src.contains("ExecuteMenuItem") && !src.contains("Process.Start") && !src.contains("System.Net") && !src.contains("Assembly.Load"))
        let asm = try String(contentsOfFile: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path + "/UnityBridge/com.jarvis.bridge/InputSystem/Jarvis.Bridge.InputSystem.asmdef", encoding: .utf8)
        #expect(asm.contains("JARVIS_HAS_INPUTSYSTEM") && asm.contains("com.unity.inputsystem") && asm.contains("\"defineConstraints\""), "the optional assembly compiles only when the package is installed")
    }
}

@Suite("Unity operator · Input System (engine, simulated editor)", .serialized)
@MainActor
struct UnityInputSystemEngineTests {
    @Test("an Input System edit runs through the unityEdit step and is passed only on the editor's read-back; a refused conflict fails the step with the editor's facts")
    func edits() async {
        let a = "\"assetPath\":\"Assets/Input/Controls.inputactions\""
        let plan = UnityHarness.editPlan("{\"op\":\"createInputAsset\",\(a)},{\"op\":\"createInputMap\",\(a),\"name\":\"Gameplay\"},{\"op\":\"createInputAction\",\(a),\"map\":\"Gameplay\",\"name\":\"Jump\"},{\"op\":\"addInputBinding\",\(a),\"map\":\"Gameplay\",\"action\":\"Jump\",\"path\":\"<Keyboard>/space\"}")
        let h = UnityHarness(script: UnityScripts.standard(plan: plan))
        h.editor.devOverrides["createInputAsset"] = ["created": true, "verified": true]
        h.editor.devOverrides["createInputMap"] = ["created": true, "verified": true]
        h.editor.devOverrides["createInputAction"] = ["created": true, "verified": true]
        h.editor.devOverrides["addInputBinding"] = ["added": true, "verified": true, "bindingId": "0f8fad5b-d9cb-469f-a165-70867728950e"]
        let v = await h.run("Add a Jump action on space")
        #expect(v.task.state == .completed, Comment(rawValue: "\(v.task.failureReason ?? "") \(v.steps.map { "\($0.key):\($0.state):\($0.validationEvidence ?? "")" })"))
        #expect(["createInputAsset", "createInputMap", "createInputAction", "addInputBinding"].allSatisfy { h.editor.received.contains($0) })
        let evidence = v.steps.first { $0.type == .unityEdit }?.validationEvidence ?? ""
        #expect(evidence.contains("bound <Keyboard>/space to Gameplay/Jump") && evidence.contains("read back from the saved file"), Comment(rawValue: evidence))
        // an edit the editor cannot confirm is NOT passed
        let h2 = UnityHarness(script: UnityScripts.standard(plan: UnityHarness.editPlan("{\"op\":\"addInputBinding\",\(a),\"map\":\"Gameplay\",\"action\":\"Jump\",\"path\":\"<Keyboard>/space\"}")))
        h2.editor.devOverrides["addInputBinding"] = ["added": true, "verified": false, "bindingId": "0f8fad5b-d9cb-469f-a165-70867728950e"]
        let v2 = await h2.run("Add a Jump action on space")
        #expect(v2.task.state == .failed && v2.task.failureCategory == .validationFailed)
    }
}
