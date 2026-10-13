import Foundation
@testable import Jarvis

/// MOCK TESTED ONLY. A simulated Unity editor behind the same `UnityTransport` protocol the real file-spool transport implements. It mirrors the
/// semantics of the C# bridge (identity resolution, idempotent mutations, Play Mode block, dirty scenes, compilation, tests) so the engine
/// logic can be tested fast and deterministically. Nothing here is evidence about a real editor — that is `--unity-live-test`.
@MainActor
final class SimulatedUnityEditor: UnityTransport {
    struct Obj {
        var uid: Int
        var name: String
        var parent: Int?
        var scene: String
        var components: [String]
        var props: [String: [String: UnityValue]] = [:]     // component type → property path → value
    }
    struct SimScene { var path: String; var name: String; var dirty: Bool; var jarvisDirty: Bool }

    let root: String
    var onStatusChange: ((UnityStatusSnapshot?) -> Void)?
    var session = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    var reloads = 0
    var isPlaying = false
    var isCompiling = false
    var compileGeneration = 0
    var compileErrors: [UnityCompilerError] = []
    var compileFailed: Bool { !compileErrors.isEmpty }
    var scenes: [SimScene] = [SimScene(path: "Assets/Scenes/FixtureScene.unity", name: "FixtureScene", dirty: false, jarvisDirty: false)]
    var objects: [Obj] = []
    var console: [UnityConsoleEntry] = []
    var nextSeq: Int64 = 1
    var nextUID = 1
    var testRun: UnityTestRunSummary?
    var testRunCases: [UnityTestCase] = []
    var owned = true
    var alive = true
    var delay: Duration = .milliseconds(5)
    /// Every operation the simulator received (wire name), in order.
    private(set) var received: [String] = []
    private(set) var receivedOps: [UnityOperation] = []
    /// Set to simulate a hung editor.
    var unresponsive = false
    /// Test oracle: given the project's .cs files (path → text), the mode and the requested names → test cases.
    var testOracle: ([String: String], UnityTestMode, [String]) -> [UnityTestCase] = { _, _, _ in [UnityTestCase(name: "Sample.Passes", status: "Passed", message: "")] }
    /// Scripts that make the "compiler" fail (token in a .cs file) and the Console lines a Play Mode run emits.
    static let syntaxErrorToken = "@@SYNTAX_ERROR@@"
    var playConsole: [(UnityLogType, String)] = []
    var onPlay: (() -> Void)?

    private struct Waiter { let predicate: (UnityStatusSnapshot) -> Bool; let continuation: CheckedContinuation<UnityStatusSnapshot?, Never>; var timeout: Task<Void, Never>? }
    private var waiters: [UUID: Waiter] = [:]

    init(root: String) {
        self.root = UnityProcessScanner.canonical(root)
        let cube = add("TestCube", components: ["Transform", "MeshFilter", "MeshRenderer"])
        _ = cube
        let counter = add("CounterObject", components: ["Transform", "Counter"])
        objects[objects.firstIndex { $0.uid == counter }!].props["Counter"] = ["startValue": .number(1), "value": .number(0), "label": .string("fixture")]
        add("Main Camera", components: ["Transform", "Camera"])
    }

    @discardableResult
    func add(_ name: String, parent: Int? = nil, components: [String] = ["Transform"], scene: String = "Assets/Scenes/FixtureScene.unity") -> Int {
        let uid = nextUID; nextUID += 1
        objects.append(Obj(uid: uid, name: name, parent: parent, scene: scene, components: components))
        return uid
    }

    // MARK: Identity (mirrors the C# bridge)

    private func path(_ o: Obj) -> String { (o.parent.flatMap { p in objects.first { $0.uid == p } }.map { path($0) + "/" } ?? "") + o.name }
    private func siblings(_ o: Obj) -> [Obj] { objects.filter { $0.parent == o.parent && $0.scene == o.scene } }
    private func indexedPath(_ o: Obj) -> String {
        let idx = siblings(o).prefix { $0.uid != o.uid }.filter { $0.name == o.name }.count
        return (o.parent.flatMap { p in objects.first { $0.uid == p } }.map { indexedPath($0) + "/" } ?? "") + "\(o.name)#\(idx)"
    }
    private func gid(_ o: Obj) -> String { "GlobalObjectId_V1-2-" + String(format: "%032x", 0xA11CE + o.scene.hashValue & 0xFFFF) + "-\(1000 + o.uid)-0" }
    func ref(_ o: Obj) -> [String: Any] { ["name": o.name, "scene": o.scene, "path": path(o), "indexedPath": indexedPath(o), "globalId": gid(o), "active": true, "activeInHierarchy": true] }

    private enum Resolve { case one(Obj), notFound, ambiguous([Obj]), invalid(String) }
    private func resolve(_ t: [String: Any]?, allowName: Bool) -> Resolve {
        guard let t else { return .invalid("A target is required.") }
        if let g = t["globalId"] as? String, !g.isEmpty {
            guard let o = objects.first(where: { gid($0) == g }) else { return .notFound }
            if let p = t["path"] as? String, !p.isEmpty, path(o) != p, indexedPath(o) != p { return .invalid("identityMismatch") }
            return .one(o)
        }
        if let p = t["path"] as? String, !p.isEmpty {
            let hits = objects.filter { path($0) == p || indexedPath($0) == p }
            if hits.count > 1 && !p.contains("#") { return .ambiguous(hits) }
            return hits.first.map { .one($0) } ?? .notFound
        }
        if let n = t["name"] as? String, !n.isEmpty {
            guard allowName else { return .invalid("nameOnly") }
            let hits = objects.filter { $0.name == n }
            return hits.count == 1 ? .one(hits[0]) : (hits.isEmpty ? .notFound : .ambiguous(hits))
        }
        return .invalid("A target is required.")
    }

    // MARK: Transport

    func currentStatus() -> UnityStatusSnapshot? {
        guard alive else { return nil }
        return UnityStatusSnapshot(pid: getpid(), session: session, owned: owned, project: root, projectName: (root as NSString).lastPathComponent, unityVersion: "6000.5.1f1",
                                   state: isCompiling ? "compiling" : (isPlaying ? "playing" : "edit"), isCompiling: isCompiling, isPlaying: isPlaying, reloads: reloads,
                                   compileGeneration: compileGeneration, compileFailed: compileFailed, compileRunning: isCompiling,
                                   activeScene: scenes.first?.path ?? "", scenes: scenes.map { UnitySceneInfo(path: $0.path, name: $0.name, dirty: $0.dirty, jarvisDirty: $0.jarvisDirty) }, testRun: testRun)
    }

    private func publish() {
        let s = currentStatus()
        onStatusChange?(s)
        guard let s else { return }
        for (id, w) in waiters where w.predicate(s) { waiters[id] = nil; w.timeout?.cancel(); w.continuation.resume(returning: s) }
    }

    func waitForStatus(timeout: TimeInterval, _ predicate: @escaping (UnityStatusSnapshot) -> Bool) async -> UnityStatusSnapshot? {
        if let s = currentStatus(), predicate(s) { return s }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<UnityStatusSnapshot?, Never>) in
                if Task.isCancelled { cont.resume(returning: nil); return }
                let t = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard let self, let w = self.waiters.removeValue(forKey: id) else { return }
                    w.continuation.resume(returning: nil)
                }
                waiters[id] = Waiter(predicate: predicate, continuation: cont, timeout: t)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let w = self.waiters.removeValue(forKey: id) else { return }
                w.timeout?.cancel(); w.continuation.resume(returning: nil)
            }
        }
    }

    func cancelPending() {}
    func close() {}

    /// Simulates the editor process dying.
    func crash() { alive = false; publish() }

    private(set) var maxConcurrentMutations = 0
    private var inflightMutations = 0

    func send(_ op: UnityOperation, timeout: TimeInterval) async throws -> UnityResponse {
        guard alive else { throw UnityBridgeError.notConnected("no editor") }
        received.append(op.wireName); receivedOps.append(op)
        if op.isPersistentMutation { inflightMutations += 1; maxConcurrentMutations = max(maxConcurrentMutations, inflightMutations) }
        defer { if op.isPersistentMutation { inflightMutations -= 1 } }
        if unresponsive { try await Task.sleep(for: .seconds(timeout)); throw UnityBridgeError.timedOut("\(op.wireName) after \(Int(timeout)) s") }
        try await Task.sleep(for: delay)
        if Task.isCancelled { throw UnityBridgeError.cancelled }
        return handle(op)
    }

    private func fail(_ id: String, _ code: String, _ msg: String, details: Any? = nil) -> UnityResponse { UnityResponse(id: id, ok: false, errorCode: code, errorMessage: msg, errorDetails: details, session: session, reloads: reloads) }
    private func ok(_ id: String, _ r: [String: Any]) -> UnityResponse { UnityResponse(id: id, ok: true, result: r, session: session, reloads: reloads) }

    private func mutationBlocked(_ id: String) -> UnityResponse? {
        if isPlaying { return fail(id, "playModeMutationBlocked", "Persistent project changes are not allowed while Play Mode is active.") }
        if isCompiling { return fail(id, "editorBusy", "The editor is compiling or importing.") }
        return nil
    }

    private func markDirty(_ scene: String) {
        if let i = scenes.firstIndex(where: { $0.path == scene }) { scenes[i].dirty = true; scenes[i].jarvisDirty = true }
        publish()
    }

    // MARK: V0.13 operator operations (a faithful-enough model: shapes, Play Mode blocking, dirty marking; the real editor is covered by the live test)

    /// Wire name → a fixed answer a test wants instead of the default.
    var devOverrides: [String: [String: Any]] = [:]
    var captureVisible = true
    private(set) var captureFiles: [String] = []

    private func handleDev(_ d: UnityDevOp, _ id: String) -> UnityResponse {
        if d.isPersistentMutation, let b = mutationBlocked(id) { return b }
        if let o = devOverrides[d.wireName] { return ok(id, o) }
        let scene = scenes.first?.path ?? ""
        if d.isPersistentMutation && d.touchesScene { markDirty(scene) }
        switch d {
        case .configureComponent(_, _, let s): return ok(id, ["changed": true, "alreadyApplied": false, "verified": true, "applied": s.mapValues(\.any)])
        case .editGameObject: return ok(id, ["changed": true, "verified": true])
        case .duplicateGameObject: return ok(id, ["created": true, "object": ["name": "Copy", "path": "Copy", "scene": scene]])
        case .instantiatePrefab(let p, _, _, let n, _, _, _, _): return ok(id, ["created": true, "object": ["name": n ?? "Instance", "path": n ?? "Instance", "scene": scene], "prefab": ["isPartOfPrefab": true, "sourceAsset": p]])
        case .createMaterial(let p, let sh, _):
            try? FileManager.default.createDirectory(atPath: (root + "/" + p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: root + "/" + p, contents: Data("material".utf8))
            return ok(id, ["created": true, "assetPath": p, "shader": sh ?? "copied", "pipelineMismatch": false])
        case .setMaterialProperty(_, _, let v): return ok(id, ["changed": true, "value": v.any, "type": "Float"])
        case .setObjectReference(_, _, _, _, let a): return ok(id, ["changed": true, "value": a as Any])
        case .setEnvironment(_, let v): return ok(id, ["changed": true, "value": v.any])
        case .applyPrefabOverrides: return ok(id, ["applied": 1, "protectedUserOverrides": 1])
        case .revertPrefabOverrides: return ok(id, ["reverted": 1, "protectedUserOverrides": 1])
        case .createPrefabVariant: return ok(id, ["created": true, "assetType": "Variant"])
        case .removeComponent: return ok(id, ["removed": true])
        case .unpackPrefab: return ok(id, ["unpacked": true])
        case .createAnimatorController: return ok(id, ["created": true, "parameters": [], "layers": []])
        case .setModelImporter(_, let s): return ok(id, ["changed": true, "previous": ["animationType": "Generic"], "after": ["animationType": s["animationType"]?.string ?? "Generic"]])
        case .sceneProfile: return ok(id, ["scene": scene, "objectCount": objects.count, "cameras": 1, "lights": 0, "audioSources": 0, "animators": 0, "rigidbodies": 0, "canvases": 0, "missingScripts": 0, "missingReferences": 0])
        case .inspectLighting: return ok(id, ["scene": scene, "lights": [], "environment": ["ambientMode": "Skybox", "ambientIntensity": 1.0], "renderPipeline": "Built-in"])
        case .inspectAsset(let p): return ok(id, ["path": p, "type": "Material", "shader": "Standard", "properties": []])
        case .prefabOverrides: return ok(id, ["overrides": [], "jarvisOverrides": 0, "otherOverrides": 0])
        case .inspectRuntime(let ts, _): return ok(id, ["playing": isPlaying, "targets": ts.map { _ in ["exists": true, "object": ["path": "Hero"], "animator": ["hasController": true, "normalizedTime": 0.5, "inState": ["Walk": true], "clips": ["Walk"]], "audio": ["isPlaying": true, "clip": "Assets/Audio/step.wav"]] as [String: Any] }])
        case .captureView(_, let w, let h, let ts):
            let dir = root + "/Library/JarvisBridge/captures"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let name = "sim-\(captureFiles.count).png"
            FileManager.default.createFile(atPath: dir + "/" + name, contents: Data(repeating: 9, count: 300))
            captureFiles.append(name)
            let visible = captureVisible
            return ok(id, ["file": "captures/" + name, "width": w, "height": h, "camera": "Main Camera", "isPlaying": isPlaying,
                           "luminance": ["mean": visible ? 0.45 : 0.01, "stddev": visible ? 0.2 : 0.002, "darkFraction": visible ? 0.1 : 0.99, "brightFraction": 0.0],
                           "targets": ts.map { t in ["exists": true, "object": t.path ?? t.name ?? "?", "inFrustum": visible, "areaFraction": visible ? 0.12 : 0.0, "contrast": visible ? 0.3 : 0.0, "visible": visible] as [String: Any] }])
        case .createScene(let p, _): return ok(id, ["created": true, "path": p])
        case .editAnimatorController: return ok(id, ["changed": true, "parameters": [], "layers": []])
        }
    }

    // MARK: Operations

    private func handle(_ op: UnityOperation) -> UnityResponse {
        let id = UnityRequest.makeID()
        let p = op.parameters
        switch op {
        case .ping: return ok(id, ["pong": true])
        case .getProjectInfo: return ok(id, ["unityVersion": "6000.5.1f1", "projectName": (root as NSString).lastPathComponent, "renderPipeline": "Built-in", "batchMode": true])
        case .listScenes:
            return ok(id, ["loaded": scenes.map { ["path": $0.path, "name": $0.name, "dirty": $0.dirty, "jarvisDirty": $0.jarvisDirty, "loaded": true] as [String: Any] }, "inProject": scenes.map(\.path), "active": scenes.first?.path ?? ""])
        case .getActiveScene:
            let s = scenes[0]; return ok(id, ["path": s.path, "name": s.name, "dirty": s.dirty, "jarvisDirty": s.jarvisDirty, "loaded": true])
        case .openScene(let path):
            if scenes.contains(where: \.dirty) { return fail(id, "dirtySceneProtected", "A scene has unsaved changes.") }
            return ok(id, ["path": path, "name": "FixtureScene", "dirty": false, "jarvisDirty": false, "loaded": true])
        case .listRootGameObjects: return ok(id, ["total": objects.filter { $0.parent == nil }.count, "objects": objects.filter { $0.parent == nil }.map { ref($0) }])
        case .findGameObjects(let name, let comp, _):
            let hits = objects.filter { (name == nil || $0.name == name) && (comp == nil || $0.components.contains(comp!)) }
            return ok(id, ["count": hits.count, "objects": hits.map { ref($0) }])
        case .inspectGameObject:
            switch resolve(p["target"] as? [String: Any], allowName: true) {
            case .one(let o):
                var d = ref(o)
                var counts: [String: Int] = [:]
                d["components"] = o.components.map { c -> [String: Any] in let i = counts[c, default: 0]; counts[c] = i + 1; return ["type": c, "fullType": c, "index": i] }
                return ok(id, d)
            case .notFound: return fail(id, "targetNotFound", "The target does not exist.")
            case .ambiguous(let h): return fail(id, "ambiguousTarget", "ambiguous", details: h.map { ref($0) })
            case .invalid(let m): return fail(id, m == "identityMismatch" ? "identityMismatch" : "invalidArguments", m)
            }
        case .inspectComponents:
            guard case .one(let o) = resolve(p["target"] as? [String: Any], allowName: true) else { return fail(id, "targetNotFound", "The target does not exist.") }
            return ok(id, ["target": ref(o), "components": o.components.map { c in ["type": c, "fullType": c, "index": 0, "properties": (o.props[c] ?? [:]).map { ["path": $0.key, "type": "x", "representable": true, "value": $0.value.any] as [String: Any] }] as [String: Any] }])
        case .inspectSerializedProperties(_, let comp, _, let paths):
            guard case .one(let o) = resolve(p["target"] as? [String: Any], allowName: true) else { return fail(id, "targetNotFound", "The target does not exist.") }
            guard o.components.contains(comp) else { return fail(id, "componentNotFound", "no \(comp)") }
            let props = o.props[comp] ?? [:]
            return ok(id, ["properties": (paths.isEmpty ? Array(props.keys) : paths).map { k in props[k].map { ["path": k, "exists": true, "representable": true, "value": $0.any] as [String: Any] } ?? ["path": k, "exists": false] }])
        case .inspectPrefab: return ok(id, ["isPartOfPrefab": false])
        case .readConsole(let after, let max, let types):
            let hits = console.filter { $0.seq > after && (types.isEmpty || types.contains($0.type.rawValue)) }.prefix(max)
            return ok(id, ["entries": hits.map { ["seq": NSNumber(value: $0.seq), "type": $0.type.rawValue, "message": $0.message, "stack": "", "t": 0] as [String: Any] }, "lastSeq": NSNumber(value: console.last?.seq ?? 0)])
        case .getCompilationState:
            return ok(id, ["isCompiling": isCompiling, "generation": compileGeneration, "scriptCompilationFailed": compileFailed, "warnings": 0, "reloads": reloads,
                           "errors": compileErrors.map { ["file": $0.file, "line": $0.line, "message": $0.message] as [String: Any] }])
        case .getPlayModeState: return ok(id, ["state": isPlaying ? "playing" : "edit", "isPlaying": isPlaying])
        case .getTestAvailability: return ok(id, ["available": true])
        case .getTestRun:
            guard let r = testRun else { return fail(id, "noTestRun", "none") }
            return ok(id, ["runId": r.runId, "mode": r.mode, "state": r.state, "total": r.total, "passed": r.passed, "failed": r.failed, "skipped": r.skipped, "inconclusive": r.inconclusive,
                           "durationSeconds": 0.01, "cases": testRunCases.map { ["name": $0.name, "status": $0.status, "message": $0.message] as [String: Any] }])
        case .cancelTests: return ok(id, ["cancelled": false])
        case .shutdown:
            guard owned else { return fail(id, "notOwned", "not owned") }
            alive = false; publish(); return ok(id, ["accepted": true])
        case .requestCompilation:
            if isPlaying { return fail(id, "playModeActive", "play") }
            startCompile(); return ok(id, ["isCompiling": isCompiling, "generation": compileGeneration])
        case .enterPlayMode:
            if isCompiling { return fail(id, "editorBusy", "compiling") }
            if compileFailed { return fail(id, "compileErrors", "The project has script compile errors; Play Mode cannot be entered.") }
            if isPlaying { return ok(id, ["alreadyPlaying": true]) }
            Task { @MainActor in
                try? await Task.sleep(for: delay)
                reloads += 1; isPlaying = true
                for (t, m) in playConsole { console.append(UnityConsoleEntry(seq: nextSeq, type: t, rawMessage: m)); nextSeq += 1 }
                onPlay?(); publish()
            }
            return ok(id, ["accepted": true])
        case .exitPlayMode:
            if !isPlaying { return ok(id, ["alreadyStopped": true]) }
            Task { @MainActor in try? await Task.sleep(for: delay); isPlaying = false; reloads += 1; publish() }
            return ok(id, ["accepted": true])
        case .runTests(let mode, let names, _, _):
            if isPlaying { return fail(id, "playModeActive", "play") }
            if scenes.contains(where: \.dirty) { return fail(id, "dirtyScene", "A scene has unsaved changes.") }
            if compileFailed { return fail(id, "compileErrors", "compile errors") }
            let cases = testOracle(projectScripts(), mode, names)
            let runId = UUID().uuidString
            testRunCases = cases
            let passed = cases.filter { $0.status == "Passed" }.count, failed = cases.filter { $0.status == "Failed" }.count
            testRun = UnityTestRunSummary(runId: runId, mode: mode.rawValue, state: "finished", total: cases.count, passed: passed, failed: failed, skipped: 0, inconclusive: 0)
            Task { @MainActor in try? await Task.sleep(for: delay); publish() }
            return ok(id, ["accepted": true, "runId": runId, "mode": mode.rawValue])
        // Mutations
        case .createGameObject(let name, let scene, let parent, _, _, _, _, let ifAbsent):
            if let b = mutationBlocked(id) { return b }
            let sc = scene ?? scenes[0].path
            var parentUID: Int?
            if let parent { guard case .one(let po) = resolve(["globalId": parent.globalId as Any, "path": parent.path as Any].compactMapValues { $0 }, allowName: false) else { return fail(id, "targetNotFound", "parent") }; parentUID = po.uid }
            if ifAbsent, let ex = objects.first(where: { $0.name == name && $0.parent == parentUID && $0.scene == sc }) { return ok(id, ["created": false, "alreadyExists": true, "object": ref(ex)]) }
            let uid = add(name, parent: parentUID, scene: sc)
            markDirty(sc)
            return ok(id, ["created": true, "alreadyExists": false, "undoRecorded": true, "object": ref(objects.first { $0.uid == uid }!)])
        case .addComponent(_, let type, let ifAbsent):
            if let b = mutationBlocked(id) { return b }
            switch resolve(p["target"] as? [String: Any], allowName: false) {
            case .one(let o):
                let i = objects.firstIndex { $0.uid == o.uid }!
                if ifAbsent, objects[i].components.contains(type) { return ok(id, ["added": false, "alreadyPresent": true, "count": 1, "target": ref(o)]) }
                objects[i].components.append(type); markDirty(o.scene)
                return ok(id, ["added": true, "alreadyPresent": false, "count": 1, "target": ref(objects[i])])
            case .notFound: return fail(id, "targetNotFound", "The target does not exist.")
            case .ambiguous(let h): return fail(id, "ambiguousTarget", "ambiguous", details: h.map { ref($0) })
            case .invalid(let m): return fail(id, m == "nameOnly" ? "ambiguousTarget" : "invalidArguments", m)
            }
        case .setSerializedProperty(_, let comp, _, let path, let old, let new):
            if let b = mutationBlocked(id) { return b }
            guard case .one(let o) = resolve(p["target"] as? [String: Any], allowName: false) else { return fail(id, "targetNotFound", "The target does not exist.") }
            guard let cur = o.props[comp]?[path] else { return fail(id, "propertyNotFound", "no such property") }
            if cur.matches(new) { return ok(id, ["changed": false, "alreadyApplied": true, "value": cur.any, "target": ref(o)]) }
            if let old, !cur.matches(old) { return fail(id, "expectedValueMismatch", "mismatch", details: ["current": cur.any]) }
            let i = objects.firstIndex { $0.uid == o.uid }!
            objects[i].props[comp]?[path] = new; markDirty(o.scene)
            return ok(id, ["changed": true, "alreadyApplied": false, "value": new.any, "undoRecorded": true, "target": ref(o)])
        case .deleteGameObject:
            if let b = mutationBlocked(id) { return b }
            guard case .one(let o) = resolve(p["target"] as? [String: Any], allowName: false) else { return fail(id, "targetNotFound", "The target does not exist.") }
            objects.removeAll { $0.uid == o.uid }; markDirty(o.scene)
            return ok(id, ["deleted": true, "object": ref(o)])
        case .saveScene(let scene):
            if let b = mutationBlocked(id) { return b }
            guard let i = scenes.firstIndex(where: { $0.path == scene }) else { return fail(id, "sceneNotLoaded", "not loaded") }
            let was = scenes[i].dirty
            scenes[i].dirty = false; scenes[i].jarvisDirty = false; publish()
            return ok(id, ["saved": was, "wasDirty": was, "scene": scene])
        case .dev(let d): return handleDev(d, id)
        case .createPrefab(_, let assetPath):
            if let b = mutationBlocked(id) { return b }
            let url = URL(fileURLWithPath: root + "/" + assetPath)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("prefab".utf8).write(to: url)
            return ok(id, ["created": true, "assetPath": assetPath])
        }
    }

    // MARK: Compilation

    func projectScripts() -> [String: String] {
        var out: [String: String] = [:]
        guard let en = FileManager.default.enumerator(atPath: root + "/Assets") else { return out }
        for case let rel as String in en where rel.hasSuffix(".cs") { out["Assets/" + rel] = (try? String(contentsOfFile: root + "/Assets/" + rel, encoding: .utf8)) ?? "" }
        return out
    }

    private func startCompile() {
        isCompiling = true; compileGeneration += 1; publish()
        Task { @MainActor in
            try? await Task.sleep(for: delay * 3)
            var errors: [UnityCompilerError] = []
            for (path, text) in projectScripts().sorted(by: { $0.key < $1.key }) where text.contains(Self.syntaxErrorToken) {
                errors.append(UnityCompilerError(file: path, line: 1, rawMessage: "error CS1002: ; expected"))
            }
            compileErrors = errors
            for e in errors { console.append(UnityConsoleEntry(seq: nextSeq, type: .error, rawMessage: e.display)); nextSeq += 1 }
            isCompiling = false
            if errors.isEmpty { reloads += 1 }
            publish()
        }
    }

    // MARK: Test helpers

    /// The user types something in the editor (unsaved change NOT made by JARVIS).
    func userEditsScene() {
        if let i = scenes.firstIndex(where: { _ in true }) { scenes[i].dirty = true; scenes[i].jarvisDirty = false }
        publish()
    }
    func logError(_ message: String) { console.append(UnityConsoleEntry(seq: nextSeq, type: .error, rawMessage: message)); nextSeq += 1 }
    func restartEditor() { session = UUID().uuidString.replacingOccurrences(of: "-", with: ""); reloads = 0; isPlaying = false; publish() }
}

/// Launcher for service tests: never starts a process.
@MainActor
final class FakeLauncher: UnityLaunching {
    var launched: [String] = []
    var onLaunch: (() -> Void)?
    var failure: Error?
    final class Owned: UnityOwnedEditor {
        var pid: pid_t = 99999
        var isRunning = true
        var outputTail = ""
        var onExit: (() -> Void)?
        func terminate() async { isRunning = false; onExit?() }
    }
    func launch(editor: UnityEditorInstall, projectRoot: String) throws -> any UnityOwnedEditor {
        if let failure { throw failure }
        launched.append(editor.version.description + " " + projectRoot)
        onLaunch?()
        return Owned()
    }
}
