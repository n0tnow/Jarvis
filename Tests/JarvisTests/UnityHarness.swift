import Foundation
@testable import Jarvis

/// A throw-away Unity-shaped project folder (temp dir): enough structure for detection; the editor behind it is `SimulatedUnityEditor`.
enum UnityFixture {
    static func make(bridgeInstalled: Bool = true, version: String = "6000.5.1f1", scripts: [String: String] = [:]) -> String {
        let dir = NSTemporaryDirectory() + "jarvis-unity-fixture-\(UUID().uuidString.prefix(8))"
        let fm = FileManager.default
        for d in ["Assets/Scenes", "Assets/Scripts", "ProjectSettings", "Packages"] { try! fm.createDirectory(atPath: dir + "/" + d, withIntermediateDirectories: true) }
        try! "m_EditorVersion: \(version)\nm_EditorVersionWithRevision: \(version) (abcdef)\n".write(toFile: dir + "/ProjectSettings/ProjectVersion.txt", atomically: true, encoding: .utf8)
        try! "{\"dependencies\":{\"com.unity.test-framework\":\"1.7.0\"}}".write(toFile: dir + "/Packages/manifest.json", atomically: true, encoding: .utf8)
        try! "scene".write(toFile: dir + "/Assets/Scenes/FixtureScene.unity", atomically: true, encoding: .utf8)
        var files = ["Assets/Scripts/Counter.cs": "public class Counter : UnityEngine.MonoBehaviour { public int startValue = 1; }\n",
                     "Assets/Scripts/Calculator.cs": "public static class Calculator { public static int Add(int a, int b) { return a - b; } }\n"]
        for (k, v) in scripts { files[k] = v }
        for (rel, text) in files { try! text.write(toFile: dir + "/" + rel, atomically: true, encoding: .utf8) }
        if bridgeInstalled { _ = try! UnityBridgeInstaller.install(root: dir) }
        return UnityProcessScanner.canonical(dir)
    }
}

@MainActor
final class UnityHarness {
    let task: TaskHarness
    var service = UnityService()
    var editor: SimulatedUnityEditor!
    let launcher = FakeLauncher()
    let project: String

    init(script: @escaping (AgentJob, Int) async -> ScriptedRunner.Answer, project: String? = nil, editorAlive: Bool = true, editorOwned: Bool = true) {
        task = TaskHarness(script: script)
        self.project = project ?? UnityFixture.make()
        let sim = SimulatedUnityEditor(root: self.project)
        sim.alive = editorAlive; sim.owned = editorOwned
        editor = sim
        service.transportFactory = { [sim] _ in sim }
        service.launcher = launcher
        service.scanProcesses = { [] }
        service.discoverEditors = { [UnityEditorInstall(version: UnityVersion("6000.5.1f1")!, appPath: "/x/Unity.app", executablePath: "/x/Unity.app/Contents/MacOS/Unity", available: true, lastCheckedAt: Date())] }
        service.connectTimeout = 5
        task.engine.unity = service
        launcher.onLaunch = { [sim] in sim.alive = true }
    }

    var engine: TaskEngine { task.engine }

    /// A relaunch of JARVIS: new engine + new Unity service over the same database and the same (still running) simulated editor.
    func relaunch(script: ((AgentJob, Int) async -> ScriptedRunner.Answer)? = nil) {
        task.restart(script: script)
        let sim = editor!
        service = UnityService()
        service.transportFactory = { _ in sim }
        service.launcher = launcher
        service.scanProcesses = { [] }
        service.discoverEditors = { [UnityEditorInstall(version: UnityVersion("6000.5.1f1")!, appPath: "/x/Unity.app", executablePath: "/x/Unity.app/Contents/MacOS/Unity", available: true, lastCheckedAt: Date())] }
        service.connectTimeout = 5
        task.engine.unity = service
    }

    /// Submits a task and answers its approvals through the REAL approval pathway (`TaskEngine.decide`), like the HUD buttons.
    @discardableResult
    func runWithApprovals(_ goal: String, kind: TaskKind = .development, destructive: Bool = false, answers: [(String, Bool)] = []) async -> TaskView {
        let id = await task.submit(goal, project: project, kind: kind, destructive: destructive)
        var decided = Set<UUID>()
        let eng = engine
        let decider = Task { @MainActor in
            while !Task.isCancelled {
                for a in eng.pendingApprovals where a.taskID == id && !decided.contains(a.id) {
                    decided.insert(a.id)
                    eng.decide(a.id, approved: answers.first { a.action.contains($0.0) }?.1 ?? false, by: "test")
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        await eng.waitUntilFinished(id)
        decider.cancel()
        return eng.view(id)!
    }

    /// Edit-plan helper: one unityEdit step with explicit typed actions.
    static func editPlan(_ actions: String, inspect: [String] = []) -> String {
        var steps: [String] = []
        var deps: [String] = []
        if !inspect.isEmpty { steps.append(UnityScripts.step("s0", "Inspect", "unityInspect", validation: "unityInspected", unity: "{\"targets\":[\(inspect.map { "\"\($0)\"" }.joined(separator: ","))]}")); deps = ["s0"] }
        steps.append(UnityScripts.step("s1", "Edit", "unityEdit", deps: deps, validation: "unityState", unity: "{\"actions\":[\(actions)]}", risk: "medium"))
        return UnityScripts.plan(steps)
    }

    @discardableResult
    func run(_ goal: String, kind: TaskKind = .development, destructive: Bool = false) async -> TaskView {
        let id = await task.submit(goal, project: project, kind: kind, destructive: destructive)
        await engine.waitUntilFinished(id)
        return engine.view(id)!
    }
}

enum UnityScripts {
    static func step(_ id: String, _ title: String, _ type: String, deps: [String] = [], validation: String, unity: String? = nil, risk: String = "low") -> String {
        "{\"id\":\"\(id)\",\"title\":\"\(title)\",\"description\":\"\(title)\",\"type\":\"\(type)\",\"dependsOn\":[\(deps.map { "\"\($0)\"" }.joined(separator: ","))],\"expected\":\"done\",\"validation\":\"\(validation)\",\"risk\":\"\(risk)\"" + (unity.map { ",\"unity\":\($0)" } ?? "") + "}"
    }
    static func plan(_ steps: [String]) -> String { "{\"summary\":\"unity plan\",\"steps\":[" + steps.joined(separator: ",") + "]}" }

    /// Add a BoxCollider to TestCube (inspect → edit → compile → validate).
    static let addCollider = plan([
        step("s1", "Inspect TestCube", "unityInspect", validation: "unityInspected", unity: "{\"targets\":[\"TestCube\"]}"),
        step("s2", "Add BoxCollider", "unityEdit", deps: ["s1"], validation: "unityState", unity: "{\"actions\":[{\"op\":\"addComponent\",\"target\":{\"path\":\"TestCube\"},\"componentType\":\"BoxCollider\"}]}", risk: "medium"),
        step("s3", "Compile", "unityCompile", deps: ["s2"], validation: "unityCompiled"),
        step("s4", "Validate", "unityValidate", deps: ["s3"], validation: "unityState",
             unity: "{\"expectations\":[{\"kind\":\"componentCount\",\"target\":{\"path\":\"TestCube\"},\"componentType\":\"BoxCollider\",\"count\":1}]}"),
    ])
    static let setProperty = plan([
        step("s1", "Inspect CounterObject", "unityInspect", validation: "unityInspected", unity: "{\"targets\":[\"CounterObject\"]}"),
        step("s2", "Set startValue", "unityEdit", deps: ["s1"], validation: "unityState",
             unity: "{\"actions\":[{\"op\":\"setSerializedProperty\",\"target\":{\"path\":\"CounterObject\"},\"componentType\":\"Counter\",\"propertyPath\":\"startValue\",\"expectedOld\":1,\"newValue\":5}]}", risk: "medium"),
        step("s3", "Validate", "unityValidate", deps: ["s2"], validation: "unityState",
             unity: "{\"expectations\":[{\"kind\":\"propertyEquals\",\"target\":{\"path\":\"CounterObject\"},\"componentType\":\"Counter\",\"propertyPath\":\"startValue\",\"value\":5}]}"),
    ])
    static let reviewPass = "{\"verdict\":\"pass\",\"summary\":\"fine\",\"issues\":[]}"

    static func standard(plan: String, unityAgent: String? = nil, coding: String? = nil, review: String = reviewPass) -> (AgentJob, Int) async -> ScriptedRunner.Answer {
        { job, index in
            switch job.type {
            case "PlannerAgent": return .text(plan)
            case "AnalysisAgent": return .text(Scripts.analysis)
            case "CodingAgent": return .text(coding ?? Scripts.addEdit(from: "-", to: "+"))
            case "ReviewAgent": return .text(review)
            case "UnityAgent": return unityAgent.map { .text($0) } ?? .fail(.generic)
            default: return .fail(.generic)
            }
        }
    }
}
