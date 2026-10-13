import Foundation

// MARK: - The typed operation surface (V0.6 — DEC-048)

/// EVERY thing JARVIS can ask the Unity Editor to do. A closed enum: there is no case that carries code, a menu path, a shell command
/// or a free-form command string, so neither a provider nor a bug can express one. Parameters are bounded on construction.
enum UnityOperation: Equatable, Sendable {
    // Inspection (read-only)
    case ping
    case getProjectInfo
    case listScenes
    case getActiveScene
    case openScene(path: String)
    case listRootGameObjects(scene: String?, max: Int)
    case findGameObjects(name: String?, componentType: String?, max: Int)
    case inspectGameObject(UnityTarget, depth: Int, maxChildren: Int)
    case inspectComponents(UnityTarget, types: [String], maxProperties: Int)
    case inspectSerializedProperties(UnityTarget, componentType: String, componentIndex: Int?, propertyPaths: [String])
    case inspectPrefab(UnityTarget)
    case readConsole(afterSeq: Int64, max: Int, types: [String])
    case getCompilationState
    case getPlayModeState
    case getTestAvailability
    case getTestRun
    // Controlled state transitions
    case requestCompilation
    case enterPlayMode
    case exitPlayMode
    case runTests(mode: UnityTestMode, testNames: [String], groupNames: [String], assemblyNames: [String])
    case cancelTests
    case shutdown                        // only honoured by an editor JARVIS started itself
    // Bounded mutations
    case createGameObject(name: String, scene: String?, parent: UnityTarget?, primitive: String, position: [Double]?, rotation: [Double]?, scale: [Double]?, ifAbsent: Bool)
    case addComponent(UnityTarget, componentType: String, ifAbsent: Bool)
    case setSerializedProperty(UnityTarget, componentType: String, componentIndex: Int?, propertyPath: String, expectedOld: UnityValue?, newValue: UnityValue)
    case deleteGameObject(UnityTarget)
    case saveScene(scene: String)
    case createPrefab(UnityTarget, assetPath: String)
    /// V0.13: the development-operator operations (scene, hierarchy, prefab, material, lighting, animation, audio, runtime snapshot, capture) — one closed enum of their own.
    case dev(UnityDevOp)

    var wireName: String {
        switch self {
        case .ping: "ping"; case .getProjectInfo: "getProjectInfo"; case .listScenes: "listScenes"; case .getActiveScene: "getActiveScene"; case .openScene: "openScene"
        case .listRootGameObjects: "listRootGameObjects"; case .findGameObjects: "findGameObjects"; case .inspectGameObject: "inspectGameObject"
        case .inspectComponents: "inspectComponents"; case .inspectSerializedProperties: "inspectSerializedProperties"; case .inspectPrefab: "inspectPrefab"
        case .readConsole: "readConsole"; case .getCompilationState: "getCompilationState"; case .getPlayModeState: "getPlayModeState"
        case .getTestAvailability: "getTestAvailability"; case .getTestRun: "getTestRun"; case .requestCompilation: "requestCompilation"
        case .enterPlayMode: "enterPlayMode"; case .exitPlayMode: "exitPlayMode"; case .runTests: "runTests"; case .cancelTests: "cancelTests"; case .shutdown: "shutdown"
        case .createGameObject: "createGameObject"; case .addComponent: "addComponent"; case .setSerializedProperty: "setSerializedProperty"
        case .deleteGameObject: "deleteGameObject"; case .saveScene: "saveScene"; case .createPrefab: "createPrefab"
        case .dev(let d): d.wireName
        }
    }

    /// Every wire name the protocol defines (the C# bridge registers exactly these).
    static let allWireNames: Set<String> = Set(["ping", "getProjectInfo", "listScenes", "getActiveScene", "openScene", "listRootGameObjects", "findGameObjects", "inspectGameObject",
        "inspectComponents", "inspectSerializedProperties", "inspectPrefab", "readConsole", "getCompilationState", "getPlayModeState", "getTestAvailability", "getTestRun",
        "requestCompilation", "enterPlayMode", "exitPlayMode", "runTests", "cancelTests", "shutdown", "createGameObject", "addComponent", "setSerializedProperty",
        "deleteGameObject", "saveScene", "createPrefab"]).union(UnityDevOp.allWireNames)

    /// The task capability this operation needs. A task that does not hold it cannot send the operation.
    var capability: TaskCapability {
        switch self {
        case .ping, .getProjectInfo, .listScenes, .getActiveScene, .getPlayModeState, .getTestAvailability, .getTestRun, .getCompilationState: .inspectUnity
        case .openScene, .listRootGameObjects, .findGameObjects, .inspectGameObject, .inspectComponents, .inspectSerializedProperties, .inspectPrefab: .inspectUnity
        case .readConsole: .readUnityConsole
        case .requestCompilation: .runUnityCompile
        case .enterPlayMode, .exitPlayMode: .controlUnityPlayMode
        case .runTests, .cancelTests: .runUnityTests
        case .shutdown: .inspectUnity
        case .createGameObject, .addComponent, .setSerializedProperty: .modifyUnityScene
        case .deleteGameObject: .deleteUnityObject
        case .saveScene: .saveUnityScene
        case .createPrefab: .createUnityPrefab
        case .dev(let d): d.capability
        }
    }

    /// Persistent project/scene change (blocked in Play Mode, serialised by the Unity lock, needs a clean-or-approved scene).
    var isPersistentMutation: Bool {
        switch self {
        case .createGameObject, .addComponent, .setSerializedProperty, .deleteGameObject, .saveScene, .createPrefab: true
        case .dev(let d): d.isPersistentMutation
        default: false
        }
    }
    var isDestructive: Bool { if case .deleteGameObject = self { true } else if case .dev(let d) = self { d.isDestructive } else { false } }
    /// Safe to repeat after a lost response without looking first.
    var isRetryable: Bool {
        switch self {
        case .createGameObject, .addComponent, .setSerializedProperty, .deleteGameObject, .createPrefab, .runTests, .enterPlayMode, .exitPlayMode: false
        case .dev(let d): d.isRetryable
        default: true
        }
    }

    /// Human-readable one-liner for the Observatory / audit (no values that could be secrets: property VALUES are not included).
    var summary: String {
        switch self {
        case .openScene(let p): "open scene \(p)"
        case .inspectGameObject(let t, _, _): "inspect \(t.display)"
        case .inspectComponents(let t, _, _): "inspect components of \(t.display)"
        case .inspectSerializedProperties(let t, let c, _, _): "inspect \(c) properties of \(t.display)"
        case .findGameObjects(let n, let c, _): "find objects" + (n.map { " named \($0)" } ?? "") + (c.map { " with \($0)" } ?? "")
        case .createGameObject(let n, _, _, _, _, _, _, _): "create GameObject \(n)"
        case .addComponent(let t, let c, _): "add \(c) to \(t.display)"
        case .setSerializedProperty(let t, let c, _, let p, _, _): "set \(c).\(p) on \(t.display)"
        case .deleteGameObject(let t): "delete \(t.display)"
        case .saveScene(let s): "save scene \(s)"
        case .createPrefab(let t, let p): "create prefab \(p) from \(t.display)"
        case .dev(let d): d.summary
        case .runTests(let m, let n, let g, _): "run \(m.rawValue) tests" + (n.isEmpty && g.isEmpty ? "" : " (\((n + g).prefix(2).joined(separator: ", ")))")
        default: wireName
        }
    }

    static let maxList = 20
    static let maxString = 240

    /// JSON parameters for the wire. Strings are length-bounded; nothing here can carry executable text.
    var parameters: [String: Any] {
        func t(_ x: UnityTarget) -> [String: Any] {
            var d: [String: Any] = [:]
            if let g = x.globalId { d["globalId"] = String(g.prefix(Self.maxString)) }
            if let p = x.path { d["path"] = String(p.prefix(Self.maxString)) }
            if let s = x.scene { d["scene"] = String(s.prefix(Self.maxString)) }
            if let n = x.name { d["name"] = String(n.prefix(Self.maxString)) }
            return d
        }
        func clip(_ xs: [String]) -> [String] { xs.prefix(Self.maxList).map { String($0.prefix(Self.maxString)) } }
        switch self {
        case .openScene(let p): return ["path": p]
        case .listRootGameObjects(let s, let m): var d: [String: Any] = ["max": min(max(m, 1), 200)]; if let s { d["scene"] = s }; return d
        case .findGameObjects(let n, let c, let m): var d: [String: Any] = ["max": min(max(m, 1), 50)]; if let n { d["name"] = n }; if let c { d["componentType"] = c }; return d
        case .inspectGameObject(let x, let depth, let kids): return ["target": t(x), "depth": min(max(depth, 0), 4), "maxChildren": min(max(kids, 0), 200)]
        case .inspectComponents(let x, let types, let mp): return ["target": t(x), "types": clip(types), "maxProperties": min(max(mp, 1), 60)]
        case .inspectSerializedProperties(let x, let c, let i, let paths):
            var d: [String: Any] = ["target": t(x), "componentType": c, "propertyPaths": clip(paths)]; if let i { d["componentIndex"] = i }; return d
        case .inspectPrefab(let x): return ["target": t(x)]
        case .readConsole(let after, let m, let types): return ["afterSeq": after, "max": min(max(m, 1), 200), "types": clip(types)]
        case .runTests(let mode, let names, let groups, let asm): return ["mode": mode.rawValue, "testNames": Array(names.prefix(50)), "groupNames": clip(groups), "assemblyNames": clip(asm)]
        case .createGameObject(let name, let scene, let parent, let prim, let pos, let rot, let sc, let ifAbsent):
            var d: [String: Any] = ["name": name, "primitive": prim, "ifAbsent": ifAbsent]
            if let scene { d["scene"] = scene }; if let parent { d["parent"] = t(parent) }
            if let pos { d["position"] = pos }; if let rot { d["rotation"] = rot }; if let sc { d["scale"] = sc }
            return d
        case .addComponent(let x, let c, let ifAbsent): return ["target": t(x), "componentType": c, "ifAbsent": ifAbsent]
        case .setSerializedProperty(let x, let c, let i, let path, let old, let new):
            var d: [String: Any] = ["target": t(x), "componentType": c, "propertyPath": path, "newValue": new.any]
            if let i { d["componentIndex"] = i }; if let old { d["expectedOld"] = old.any }
            return d
        case .deleteGameObject(let x): return ["target": t(x)]
        case .saveScene(let s): return ["scene": s]
        case .createPrefab(let x, let p): return ["target": t(x), "assetPath": p]
        case .dev(let d): return d.parameters
        default: return [:]
        }
    }
}

enum UnityTestMode: String, Codable, Sendable { case editMode, playMode
    var label: String { self == .editMode ? "EditMode" : "PlayMode" }
}

// MARK: - Wire envelope

struct UnityRequest: Sendable {
    var id: String
    var operation: UnityOperation

    static func makeID() -> String { "\(Int64(Date().timeIntervalSince1970 * 1000))-\(String(UUID().uuidString.prefix(8)).lowercased())" }

    func data() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": id, "op": operation.wireName, "params": operation.parameters], options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

/// A decoded bridge answer. `result` values are NOT yet sanitized; typed accessors sanitize on the way out.
struct UnityResponse: @unchecked Sendable {
    var id: String
    var ok: Bool
    var result: [String: Any]
    var errorCode: String?
    var errorMessage: String?
    var errorDetails: Any?
    var session: String
    var reloads: Int

    init(id: String, ok: Bool, result: [String: Any] = [:], errorCode: String? = nil, errorMessage: String? = nil, errorDetails: Any? = nil, session: String = "", reloads: Int = 0) {
        self.id = id; self.ok = ok; self.result = result; self.errorCode = errorCode; self.errorMessage = errorMessage; self.errorDetails = errorDetails; self.session = session; self.reloads = reloads
    }

    init?(data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let id = root["id"] as? String, let ok = root["ok"] as? Bool else { return nil }
        let err = root["error"] as? [String: Any]
        self.init(id: id, ok: ok, result: root["result"] as? [String: Any] ?? [:], errorCode: err?["code"] as? String, errorMessage: err?["message"] as? String,
                  errorDetails: err?["details"], session: root["session"] as? String ?? "", reloads: (root["reloads"] as? NSNumber)?.intValue ?? 0)
    }

    /// Candidate objects an `ambiguousTarget` error lists (identity only).
    var candidates: [UnityObjectRef] {
        ((errorDetails as? [Any]) ?? []).compactMap { ($0 as? [String: Any]).flatMap(UnityObjectRef.init(json:)) }
    }
}

enum UnityBridgeError: Error, Equatable, CustomStringConvertible, Sendable {
    case notConnected(String)
    case timedOut(String)
    case cancelled
    case rejected(code: String, message: String)
    case ambiguous(count: Int, message: String)
    case policy(String)
    case malformed(String)
    case editorExited
    case sessionChanged

    var description: String {
        switch self {
        case .notConnected(let w): w
        case .timedOut(let w): "timed out: \(w)"
        case .cancelled: "cancelled"
        case .rejected(let c, let m): "\(c): \(m)"
        case .ambiguous(_, let m): m
        case .policy(let m): m
        case .malformed(let m): "malformed bridge data: \(m)"
        case .editorExited: "the Unity Editor exited"
        case .sessionChanged: "the Unity Editor restarted (object handles are no longer valid)"
        }
    }
}

// MARK: - The only place model-supplied Unity actions are accepted

/// One edit a provider may REQUEST. Parsed strictly from JSON: unknown operations, unknown keys that look like code/menu/shell and
/// out-of-bounds values are rejected before anything reaches the bridge. The provider chooses structured parameters, never code.
struct UnityEditAction: Equatable, Sendable {
    var operation: UnityOperation
    var title: String { operation.summary }
}

enum UnityActionParser {
    static let allowedOperations: Set<String> = Set(["createGameObject", "addComponent", "setSerializedProperty", "deleteGameObject", "createPrefab"]).union(devOperations)
    static let maxActions = 8
    /// Keys that would turn an action into code/menu/shell execution. Present anywhere in an action ⇒ the whole answer is rejected.
    static let forbiddenKeys: Set<String> = ["code", "script", "csharp", "cs", "eval", "execute", "exec", "command", "cmd", "shell", "bash", "menu", "menuitem", "menupath",
                                              "applescript", "osascript", "url", "download", "reflection", "assembly", "method", "invoke"]
    static let forbiddenTokens = ["executemenuitem", "menuitem(", "system.diagnostics", "process.start", "runcsharp", "applescript", "osascript", "unityeditor.", "assetdatabase.", "eval("]

    struct Result: Equatable, Sendable {
        var actions: [UnityEditAction]
        var summary: String
        var problems: [String]
        /// A policy block (code/menu/shell requested) as opposed to a malformed answer a re-ask could fix.
        var policyBlock: Bool
    }

    static func parse(_ text: String) -> Result {
        guard let json = PlanParser.extractJSONObject(text), let data = json.data(using: .utf8), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return Result(actions: [], summary: "", problems: ["the answer is not a JSON object"], policyBlock: false)
        }
        let summary = (root["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = root["actions"] as? [[String: Any]] else { return Result(actions: [], summary: summary, problems: ["missing \"actions\" array"], policyBlock: false) }
        if raw.isEmpty { return Result(actions: [], summary: summary, problems: ["no actions"], policyBlock: false) }
        if raw.count > maxActions { return Result(actions: [], summary: summary, problems: ["too many actions (\(raw.count), maximum \(maxActions))"], policyBlock: false) }
        var actions: [UnityEditAction] = [], problems: [String] = []
        var blocked = false
        for (i, a) in raw.enumerated() {
            if let bad = forbiddenContent(in: a) { problems.append("action \(i + 1): contains \(bad), which JARVIS never accepts from a provider"); blocked = true; continue }
            guard let op = (a["op"] as? String) ?? (a["operation"] as? String) else { problems.append("action \(i + 1): missing \"op\""); continue }
            guard allowedOperations.contains(op) else { problems.append("action \(i + 1): operation \"\(op)\" is not available"); blocked = blocked || looksLikeExecution(op); continue }
            switch build(op, a) {
            case .success(let operation): actions.append(UnityEditAction(operation: operation))
            case .failure(let why): problems.append("action \(i + 1) (\(op)): \(why)")
            }
        }
        return Result(actions: problems.isEmpty ? actions : [], summary: summary, problems: problems, policyBlock: blocked)
    }

    private static func looksLikeExecution(_ s: String) -> Bool {
        let l = s.lowercased()
        return forbiddenTokens.contains { l.contains($0) } || ["runcsharp", "execute", "eval", "menu", "shell", "script", "command"].contains { l.contains($0) }
    }

    /// Scans keys AND string values (recursively).
    static func forbiddenContent(in value: Any) -> String? {
        switch value {
        case let d as [String: Any]:
            for (k, v) in d {
                if forbiddenKeys.contains(k.lowercased()) { return "the field \"\(k)\"" }
                if let bad = forbiddenContent(in: v) { return bad }
            }
        case let a as [Any]: for v in a { if let bad = forbiddenContent(in: v) { return bad } }
        case let s as String:
            let l = s.lowercased()
            if let tok = forbiddenTokens.first(where: { l.contains($0) }) { return "\"\(tok)\"" }
        default: break
        }
        return nil
    }

    static func target(_ any: Any?) -> UnityTarget? {
        guard let d = any as? [String: Any] else { return nil }
        let t = UnityTarget(globalId: d["globalId"] as? String, path: d["path"] as? String, scene: d["scene"] as? String, name: d["name"] as? String)
        return t.globalId != nil || t.path != nil || t.name != nil ? t : nil
    }

    static func vec(_ any: Any?) -> [Double]? {
        guard let a = any as? [Any], a.count == 3 else { return nil }
        let n = a.compactMap { ($0 as? NSNumber)?.doubleValue }
        return n.count == 3 && n.allSatisfy({ $0.isFinite && abs($0) < 1e6 }) ? n : nil
    }

    static func validComponentType(_ s: String) -> Bool { s.range(of: #"^[A-Za-z_][A-Za-z0-9_.]{0,120}$"#, options: .regularExpression) != nil }
    static func validPropertyPath(_ s: String) -> Bool { s.range(of: #"^[A-Za-z_][A-Za-z0-9_.\[\]]{0,120}$"#, options: .regularExpression) != nil }
    static func validAssetPath(_ s: String) -> Bool {
        s.hasPrefix("Assets/") && s.hasSuffix(".prefab") && !s.contains("..") && !s.contains("//") && s.range(of: #"^[A-Za-z0-9_ ./-]{1,200}$"#, options: .regularExpression) != nil
    }

    private static func build(_ op: String, _ a: [String: Any]) -> Swift.Result<UnityOperation, BuildProblem> {
        switch op {
        case "addComponent":
            guard let t = target(a["target"]) else { return .failure("needs a target") }
            guard let c = a["componentType"] as? String, validComponentType(c) else { return .failure("needs a valid componentType") }
            return .success(.addComponent(t, componentType: c, ifAbsent: a["ifAbsent"] as? Bool ?? true))
        case "setSerializedProperty":
            guard let t = target(a["target"]) else { return .failure("needs a target") }
            guard let c = a["componentType"] as? String, validComponentType(c) else { return .failure("needs a valid componentType") }
            guard let p = a["propertyPath"] as? String, validPropertyPath(p) else { return .failure("needs a valid propertyPath") }
            guard a.keys.contains("newValue"), let new = UnityValue(any: a["newValue"]), new != .null else { return .failure("needs a representable newValue") }
            var old: UnityValue?
            if a.keys.contains("expectedOld") { old = UnityValue(any: a["expectedOld"]); if old == nil { return .failure("expectedOld is not representable") } }
            return .success(.setSerializedProperty(t, componentType: c, componentIndex: (a["componentIndex"] as? NSNumber)?.intValue, propertyPath: p, expectedOld: old, newValue: new))
        case "createGameObject":
            guard let n = a["name"] as? String, !n.isEmpty, n.count <= 80, !n.contains("/"), !n.contains("#") else { return .failure("needs a valid name (no / or #)") }
            let prim = (a["primitive"] as? String) ?? "None"
            guard ["None", "RectTransform", "Cube", "Sphere", "Capsule", "Cylinder", "Plane", "Quad"].contains(prim) else { return .failure("unknown primitive") }
            return .success(.createGameObject(name: n, scene: a["scene"] as? String, parent: target(a["parent"]), primitive: prim, position: vec(a["position"]), rotation: vec(a["rotation"]),
                                              scale: vec(a["scale"]), ifAbsent: a["ifAbsent"] as? Bool ?? true))
        case "deleteGameObject":
            guard let t = target(a["target"]) else { return .failure("needs a target") }
            return .success(.deleteGameObject(t))
        case "createPrefab":
            guard let t = target(a["target"]) else { return .failure("needs a target") }
            guard let p = a["assetPath"] as? String, validAssetPath(p) else { return .failure("needs a new .prefab path under Assets/") }
            return .success(.createPrefab(t, assetPath: p))
        default: return buildDev(op, a)
        }
    }

    fileprivate struct BuildProblem: Error, ExpressibleByStringLiteral, CustomStringConvertible { let description: String; init(stringLiteral v: String) { description = v } }
}


// MARK: - Dev (operator) operations a provider may request: built through the SAME strict validation as everything else

extension UnityActionParser {
    static let devOperations: Set<String> = ["createScene", "editGameObject", "duplicateGameObject", "removeComponent", "setObjectReference", "configureComponent", "instantiatePrefab", "revertPrefabOverrides",
                                              "applyPrefabOverrides", "createPrefabVariant", "unpackPrefab", "createMaterial", "setMaterialProperty", "setEnvironment", "createAnimatorController", "editAnimatorController", "setModelImporter"]

    static func validName(_ s: String) -> Bool { !s.isEmpty && s.count <= 80 && !s.contains("/") && !s.contains("#") && !s.contains("\n") }
    static func validIdentifier(_ s: String) -> Bool { s.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,80}$"#, options: .regularExpression) != nil }

    private static func values(_ any: Any?) -> [String: UnityValue]? {
        guard let d = any as? [String: Any] else { return nil }
        var out: [String: UnityValue] = [:]
        for (k, v) in d { guard let u = UnityValue(any: v) else { return nil }; out[k] = u }
        return out
    }

    fileprivate static func buildDev(_ op: String, _ a: [String: Any]) -> Swift.Result<UnityOperation, BuildProblem> {
        func target() -> UnityTarget? { UnityActionParser.target(a["target"]) }
        func ref(_ k: String) -> String? { (a[k] as? String).flatMap { UnityDevOp.validAssetReference($0) ? $0 : nil } }
        func path(_ k: String, _ ext: String) -> String? { (a[k] as? String).flatMap { UnityDevOp.validAssetPath($0, ext: ext) ? $0 : nil } }
        func fail(_ s: String) -> Swift.Result<UnityOperation, BuildProblem> { .failure(BuildProblem(stringLiteral: s)) }
        do {
            switch op {
            case "createScene":
                guard let p = path("path", ".unity") else { return fail("needs a new .unity path under Assets/") }
                return .success(.dev(.createScene(path: p, empty: (a["template"] as? String) == "empty")))
            case "editGameObject":
                guard let t = target() else { return fail("needs a target") }
                var e = GameObjectEdit()
                if let n = a["name"] as? String { guard validName(n) else { return fail("invalid name") }; e.name = n }
                e.active = a["active"] as? Bool
                if a.keys.contains("parent") { if a["parent"] is NSNull { e.parent = .root } else if let p = UnityActionParser.target(a["parent"]) { e.parent = .to(p) } else { return fail("invalid parent") } }
                if let i = (a["siblingIndex"] as? NSNumber)?.intValue { guard i >= 0, i < 100_000 else { return fail("invalid siblingIndex") }; e.siblingIndex = i }
                for (k, set) in [("position", { (v: [Double]) in e.position = v }), ("rotation", { (v: [Double]) in e.rotation = v }), ("scale", { (v: [Double]) in e.scale = v })] as [(String, ([Double]) -> Void)] where a[k] != nil {
                    guard let v = vec(a[k]) else { return fail("\(k) must be [x, y, z]") }
                    set(v)
                }
                e.worldSpace = (a["space"] as? String) == "world"
                if let tg = a["tag"] as? String { guard validIdentifier(tg.replacingOccurrences(of: " ", with: "_")), tg.count <= 64 else { return fail("invalid tag") }; e.tag = tg }
                if let ly = a["layer"] as? String { guard ly.count <= 64, !ly.contains("\n") else { return fail("invalid layer") }; e.layer = ly }
                e.isStatic = a["isStatic"] as? Bool
                guard !e.isEmpty else { return fail("changes nothing") }
                return .success(.dev(.editGameObject(t, e)))
            case "duplicateGameObject":
                guard let t = target() else { return fail("needs a target") }
                if let n = a["name"] as? String, !validName(n) { return fail("invalid name") }
                return .success(.dev(.duplicateGameObject(t, name: a["name"] as? String)))
            case "removeComponent":
                guard let t = target() else { return fail("needs a target") }
                guard let c = a["componentType"] as? String, validComponentType(c) else { return fail("needs a valid componentType") }
                return .success(.dev(.removeComponent(t, componentType: c, index: (a["componentIndex"] as? NSNumber)?.intValue)))
            case "setObjectReference":
                guard let t = target() else { return fail("needs a target") }
                guard let c = a["componentType"] as? String, validComponentType(c) else { return fail("needs a valid componentType") }
                guard let p = a["propertyPath"] as? String, validPropertyPath(p) else { return fail("needs a valid propertyPath") }
                if a["assetPath"] is NSNull || a["assetPath"] == nil { return .success(.dev(.setObjectReference(t, componentType: c, index: (a["componentIndex"] as? NSNumber)?.intValue, propertyPath: p, assetPath: nil))) }
                guard let r = ref("assetPath") else { return fail("assetPath must be an asset inside Assets/") }
                return .success(.dev(.setObjectReference(t, componentType: c, index: (a["componentIndex"] as? NSNumber)?.intValue, propertyPath: p, assetPath: r)))
            case "configureComponent":
                guard let t = target() else { return fail("needs a target") }
                guard let k = a["kind"] as? String, let st = values(a["settings"]) else { return fail("needs a kind and settings") }
                return .success(.dev(try UnityDevOp.configure(t, kind: k, settings: st)))
            case "instantiatePrefab":
                guard let p = ref("assetPath"), !p.contains("::"), [".prefab", ".fbx", ".obj", ".dae", ".blend", ".gltf", ".glb"].contains(where: { p.lowercased().hasSuffix($0) }) else { return fail("needs a prefab or model under Assets/") }
                if let n = a["name"] as? String, !validName(n) { return fail("invalid name") }
                for k in ["position", "rotation", "scale"] where a[k] != nil && vec(a[k]) == nil { return fail("\(k) must be [x, y, z]") }
                return .success(.dev(.instantiatePrefab(assetPath: p, scene: (a["scene"] as? String).flatMap { UnityPolicy.isSafeProjectPath($0) && $0.hasSuffix(".unity") ? $0 : nil }, parent: UnityActionParser.target(a["parent"]), name: a["name"] as? String,
                                                        position: vec(a["position"]), rotation: vec(a["rotation"]), scale: vec(a["scale"]), ifAbsent: a["ifAbsent"] as? Bool ?? true)))
            case "revertPrefabOverrides": guard let t = target() else { return fail("needs a target") }; return .success(.dev(.revertPrefabOverrides(t)))
            case "applyPrefabOverrides": guard let t = target() else { return fail("needs a target") }; return .success(.dev(.applyPrefabOverrides(t)))
            case "unpackPrefab": guard let t = target() else { return fail("needs a target") }; return .success(.dev(.unpackPrefab(t, completely: (a["mode"] as? String) == "completely")))
            case "createPrefabVariant":
                guard let s = path("sourceAssetPath", ".prefab"), let p = path("assetPath", ".prefab") else { return fail("needs a source .prefab and a new .prefab under Assets/") }
                return .success(.dev(.createPrefabVariant(source: s, assetPath: p)))
            case "createMaterial":
                guard let p = path("assetPath", ".mat") else { return fail("needs a new .mat under Assets/") }
                let sh = (a["shader"] as? String).flatMap { $0.range(of: #"^[A-Za-z0-9_ ./()-]{1,120}$"#, options: .regularExpression) != nil ? $0 : nil }
                let cp = ref("copyFrom")
                guard (sh != nil) != (cp != nil) else { return fail("needs exactly one of shader or copyFrom") }
                return .success(.dev(.createMaterial(assetPath: p, shader: sh, copyFrom: cp)))
            case "setMaterialProperty":
                guard let p = path("assetPath", ".mat") else { return fail("needs a .mat under Assets/") }
                guard let n = a["property"] as? String, validIdentifier(n) else { return fail("needs a valid property name") }
                guard a.keys.contains("value"), let v = UnityValue(any: a["value"]) else { return fail("needs a representable value") }
                if case .string(let s) = v, !s.isEmpty, !UnityDevOp.validAssetReference(s) { return fail("a texture value must be an asset path inside Assets/") }
                return .success(.dev(.setMaterialProperty(assetPath: p, property: n, value: v)))
            case "setEnvironment":
                guard let pn = a["property"] as? String, a.keys.contains("value"), let v = UnityValue(any: a["value"]) else { return fail("needs a property and a value") }
                return .success(.dev(try UnityDevOp.environment(property: pn, value: v)))
            case "createAnimatorController":
                guard let p = path("assetPath", ".controller") else { return fail("needs a new .controller under Assets/") }
                return .success(.dev(.createAnimatorController(assetPath: p)))
            case "editAnimatorController":
                guard let p = path("assetPath", ".controller") else { return fail("needs a .controller under Assets/") }
                let layer = (a["layer"] as? NSNumber)?.intValue ?? 0
                guard (0...7).contains(layer) else { return fail("layer must be 0–7") }
                func nm(_ k: String) -> String? { (a[k] as? String).flatMap { validName($0) ? $0 : nil } }
                func mo(_ k: String) -> String? { ref(k) }
                switch a["action"] as? String {
                case "addParameter"?:
                    guard let n = nm("name"), let ty = a["type"] as? String, ["Float", "Int", "Bool", "Trigger"].contains(where: { $0.caseInsensitiveCompare(ty) == .orderedSame }) else { return fail("addParameter needs a name and a type (Float, Int, Bool, Trigger)") }
                    return .success(.dev(.editAnimatorController(assetPath: p, edit: .addParameter(name: n, type: ty.prefix(1).uppercased() + ty.dropFirst().lowercased(), defaultValue: a.keys.contains("default") ? UnityValue(any: a["default"]) : nil), layer: layer)))
                case "addState"?:
                    guard let n = nm("name") else { return fail("addState needs a name") }
                    if a["motion"] != nil, mo("motion") == nil { return fail("motion must be an asset inside Assets/") }
                    return .success(.dev(.editAnimatorController(assetPath: p, edit: .addState(layer: layer, name: n, motion: mo("motion"), speed: (a["speed"] as? NSNumber)?.doubleValue), layer: layer)))
                case "setDefaultState"?: guard let n = nm("name") else { return fail("needs a name") }; return .success(.dev(.editAnimatorController(assetPath: p, edit: .setDefaultState(layer: layer, name: n), layer: layer)))
                case "setStateSpeed"?:
                    guard let n = nm("name"), let sp = (a["speed"] as? NSNumber)?.doubleValue, (-10...10).contains(sp) else { return fail("needs a name and a speed between -10 and 10") }
                    return .success(.dev(.editAnimatorController(assetPath: p, edit: .setStateSpeed(layer: layer, name: n, speed: sp), layer: layer)))
                case "setStateMotion"?:
                    guard let n = nm("name"), let m = mo("motion") else { return fail("needs a name and a motion asset") }
                    return .success(.dev(.editAnimatorController(assetPath: p, edit: .setStateMotion(layer: layer, name: n, motion: m), layer: layer)))
                case "addTransition"?:
                    guard let from = nm("from"), let to = nm("to") else { return fail("addTransition needs from and to state names") }
                    var cs: [AnimatorCondition] = []
                    for c in (a["conditions"] as? [[String: Any]] ?? []).prefix(6) {
                        guard let pn = c["parameter"] as? String, validName(pn), ["If", "IfNot", "Greater", "Less", "Equals", "NotEqual"].contains(c["mode"] as? String ?? "If") else { return fail("invalid transition condition") }
                        cs.append(AnimatorCondition(parameter: pn, mode: c["mode"] as? String ?? "If", threshold: (c["threshold"] as? NSNumber)?.doubleValue ?? 0))
                    }
                    return .success(.dev(.editAnimatorController(assetPath: p, edit: .addTransition(layer: layer, from: from, to: to, hasExitTime: a["hasExitTime"] as? Bool, exitTime: (a["exitTime"] as? NSNumber)?.doubleValue, duration: (a["duration"] as? NSNumber)?.doubleValue, conditions: cs), layer: layer)))
                case "addBlendTreeState"?:
                    guard let n = nm("name"), let pr = nm("parameter") else { return fail("addBlendTreeState needs a name and a parameter") }
                    var ch: [(motion: String, threshold: Double)] = []
                    for c in (a["children"] as? [[String: Any]] ?? []).prefix(8) { guard let m = (c["motion"] as? String).flatMap({ UnityDevOp.validAssetReference($0) ? $0 : nil }), let th = (c["threshold"] as? NSNumber)?.doubleValue else { return fail("a blend tree child needs a motion asset and a threshold") }; ch.append((m, th)) }
                    guard !ch.isEmpty else { return fail("a blend tree needs at least one child") }
                    return .success(.dev(.editAnimatorController(assetPath: p, edit: .addBlendTreeState(layer: layer, name: n, parameter: pr, children: ch), layer: layer)))
                default: return fail("unsupported controller action")
                }
            case "setModelImporter":
                guard let p = (a["assetPath"] as? String).flatMap({ UnityPolicy.isSafeProjectPath($0) ? $0 : nil }), let st = values(a["settings"]) else { return fail("needs an assetPath and settings") }
                return .success(.dev(try UnityDevOp.modelImporter(path: p, settings: st)))
            default: return fail("unsupported")
            }
        } catch { return fail("\(error)") }
    }
}
