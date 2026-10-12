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
        }
    }

    /// Every wire name the protocol defines (the C# bridge registers exactly these).
    static let allWireNames: Set<String> = ["ping", "getProjectInfo", "listScenes", "getActiveScene", "openScene", "listRootGameObjects", "findGameObjects", "inspectGameObject",
        "inspectComponents", "inspectSerializedProperties", "inspectPrefab", "readConsole", "getCompilationState", "getPlayModeState", "getTestAvailability", "getTestRun",
        "requestCompilation", "enterPlayMode", "exitPlayMode", "runTests", "cancelTests", "shutdown", "createGameObject", "addComponent", "setSerializedProperty",
        "deleteGameObject", "saveScene", "createPrefab"]

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
        }
    }

    /// Persistent project/scene change (blocked in Play Mode, serialised by the Unity lock, needs a clean-or-approved scene).
    var isPersistentMutation: Bool {
        switch self {
        case .createGameObject, .addComponent, .setSerializedProperty, .deleteGameObject, .saveScene, .createPrefab: true
        default: false
        }
    }
    var isDestructive: Bool { if case .deleteGameObject = self { true } else { false } }
    /// Safe to repeat after a lost response without looking first.
    var isRetryable: Bool {
        switch self {
        case .createGameObject, .addComponent, .setSerializedProperty, .deleteGameObject, .createPrefab, .runTests, .enterPlayMode, .exitPlayMode: false
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
    static let allowedOperations: Set<String> = ["createGameObject", "addComponent", "setSerializedProperty", "deleteGameObject", "createPrefab"]
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
            guard ["None", "Cube", "Sphere", "Capsule", "Cylinder", "Plane", "Quad"].contains(prim) else { return .failure("unknown primitive") }
            return .success(.createGameObject(name: n, scene: a["scene"] as? String, parent: target(a["parent"]), primitive: prim, position: vec(a["position"]), rotation: vec(a["rotation"]),
                                              scale: vec(a["scale"]), ifAbsent: a["ifAbsent"] as? Bool ?? true))
        case "deleteGameObject":
            guard let t = target(a["target"]) else { return .failure("needs a target") }
            return .success(.deleteGameObject(t))
        case "createPrefab":
            guard let t = target(a["target"]) else { return .failure("needs a target") }
            guard let p = a["assetPath"] as? String, validAssetPath(p) else { return .failure("needs a new .prefab path under Assets/") }
            return .success(.createPrefab(t, assetPath: p))
        default: return .failure("unsupported")
        }
    }

    private struct BuildProblem: Error, ExpressibleByStringLiteral, CustomStringConvertible { let description: String; init(stringLiteral v: String) { description = v } }
}
