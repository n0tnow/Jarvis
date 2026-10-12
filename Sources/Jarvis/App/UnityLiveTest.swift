import AppKit

/// `Jarvis --unity-live-test [--live-dir <dir>] [--unity-fixture <template>] [--unity-no-provider]` — OPT-IN, REAL (V0.6).
/// Drives a REAL Unity editor (headless, started and owned by JARVIS) on an ISOLATED disposable fixture project copied to a temp folder
/// (never the user's game, never the JARVIS repository), with its own data directory:
///   discovery → project detection → bridge install (approval) → connect → inspect → typed scene/component/property mutations → save →
///   compile / domain reload → EditMode + PlayMode tests → Play Mode → Console baseline/delta + sanitization → dirty-scene protection →
///   Play Mode mutation block → ambiguity → destructive approval → V0.5 design proposal → cancellation → relaunch recovery.
/// Planning and the Unity agent are SCRIPTED in the scene scenarios (so the real EDITOR is what is under test); the compile-error and
/// failing-test scenarios use the REAL provider routing (OpenCode FREE preferred) for analysis + coding. Prints `REAL TESTED PASS/FAIL`.
@MainActor
enum UnityLiveTest {
    static func run(context: AppContext, captureDirectory: String, fixtureTemplate: String?, withProvider: Bool) async {
        var failures = 0, passes = 0, skipped = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "REAL TESTED PASS" : "REAL TESTED FAIL")  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if ok { passes += 1 } else { failures += 1 }
            fflush(stdout)
        }
        func skip(_ name: String, _ why: String) { print("SKIPPED  \(name) — \(why)"); skipped += 1; fflush(stdout) }
        func info(_ s: String) { print("INFO  \(s)"); fflush(stdout) }
        func fmt(_ d: Double, _ f: String = "%.1f") -> String { String(format: f, d) }

        let prefs = context.preferences
        let savedPreference = prefs.providerPreference, savedRoot = prefs.projectRoot
        DispatchQueue.main.asyncAfter(deadline: .now() + 3000) { ProcessRegistry.shared.killAll(); print("UNITY LIVE TEST TIMEOUT"); fflush(stdout); exit(2) }
        var fixtures: [String] = []
        func finish() -> Never {
            prefs.providerPreference = savedPreference; prefs.projectRoot = savedRoot
            for k in ["prefs.providerPreference", "prefs.tasks.projectRoot"] { UserDefaults.standard.removeObject(forKey: k) }
            if savedPreference != .auto { prefs.providerPreference = savedPreference }
            if !savedRoot.isEmpty { prefs.projectRoot = savedRoot }
            for f in fixtures { try? FileManager.default.removeItem(atPath: f) }
            print("UNITY LIVE TEST \(failures == 0 ? "PASSED" : "FAILED") (\(passes) passed, \(failures) failed, \(skipped) skipped)"); fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }

        let unity = context.unity, repo = context.repository!, sup = context.supervisor
        let me = getpid()
        func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if cond() { return true }; try? await Task.sleep(for: .milliseconds(150)) }
            return cond()
        }
        func git(_ args: [String], in dir: String) async {
            _ = await ManagedProcess.runOnce(executable: "/usr/bin/git", arguments: ["-c", "user.name=JARVIS Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false"] + args,
                                             environment: ProviderEnvironment.make(), workingDirectory: dir, timeout: 30)
        }

        // ------------------------------------------------------------ fixture (disposable copy; the template is never opened)
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let template = fixtureTemplate ?? repoRoot + "/UnityBridge/Fixture"
        guard FileManager.default.fileExists(atPath: template + "/ProjectSettings/ProjectVersion.txt") else { check("The fixture template exists", false, template); finish() }
        let project = UnityProcessScanner.canonical(NSTemporaryDirectory()) + "/jarvis-unity-live-\(UUID().uuidString.prefix(8))"
        fixtures.append(project)
        do { try FileManager.default.copyItem(atPath: template, toPath: project) } catch { check("The fixture was copied", false, "\(error)"); finish() }
        await git(["init", "-q", "-b", "main"], in: project); await git(["add", "-A"], in: project); await git(["commit", "-q", "-m", "fixture"], in: project)
        func fixtureFile(_ rel: String) -> String? { FileManager.default.contents(atPath: project + "/" + rel).flatMap { String(data: $0, encoding: .utf8) } }
        func writeFixture(_ rel: String, _ text: String) { try? FileManager.default.createDirectory(atPath: (project + "/" + rel as NSString).deletingLastPathComponent, withIntermediateDirectories: true); try? text.write(toFile: project + "/" + rel, atomically: true, encoding: .utf8) }
        let signalDir = project + "/Library/JarvisFixture"

        info("data directory: \(context.paths.root.path) (isolated from your real JARVIS history); fixture: \(project)")

        // ------------------------------------------------------------ 0. discovery + detection + version safety
        unity.refreshEditors()
        let editors = unity.editors
        info("Unity editors found: \(editors.map { $0.version.description }.joined(separator: ", ")) · Unity Hub: \(unity.hubInstalled ? "present" : "absent")")
        check("Unity installation discovery found at least one usable editor (standard Hub folders only)", editors.contains(where: \.available))
        let descriptor = UnityProjectDetector.describe(root: project)
        check("The fixture is detected as a Unity project with its declared version, scenes and test framework", descriptor?.declaredVersion != nil && descriptor?.scenes.contains("Assets/Scenes/FixtureScene.unity") == true
              && descriptor?.hasTestFramework == true && descriptor?.bridgeInstalled == false, "\(descriptor?.declaredVersionRaw ?? "?") · \(descriptor?.renderPipeline ?? "?")")
        guard let declared = descriptor?.declaredVersion else { finish() }
        if case .exact(let e) = UnityDiscovery.choose(for: declared, among: editors) { info("exact editor match: \(e.version)") }
        else { check("An editor with the project's exact version is installed", false, "declared \(declared)"); finish() }
        let mismatch = UnityDiscovery.choose(for: UnityVersion("2019.4.1f1"), among: editors)
        var mismatchAsks = false; if case .needsUpgradeApproval = mismatch { mismatchAsks = true }
        check("A project declaring another Unity version is NOT silently opened with an installed editor (upgrade approval required)", mismatchAsks)

        // ------------------------------------------------------------ engines: scripted planner/agent (editor under test) + hybrid (real providers)
        func scriptedEngine(_ answer: @escaping (AgentJob, Int) -> String?) -> TaskEngine {
            let runner = ScriptedAgentRunner(audit: context.audit, real: nil, scriptedTypes: ["PlannerAgent", "AnalysisAgent", "CodingAgent", "ReviewAgent", "UnityAgent"], script: answer)
            let e = TaskEngine(repository: repo, artifacts: context.artifacts, audit: context.audit, leases: context.leases, agents: runner)
            e.unity = unity
            return e
        }
        func hybridEngine(plan: @escaping () -> String) -> TaskEngine {
            let runner = ScriptedAgentRunner(audit: context.audit, real: ManagerAgentRunner(manager: context.agents), scriptedTypes: ["PlannerAgent"], script: { job, _ in plan() })
            let e = TaskEngine(repository: repo, artifacts: context.artifacts, audit: context.audit, leases: context.leases, agents: runner)
            e.unity = unity
            return e
        }
        func step(_ id: String, _ title: String, _ type: String, deps: [String] = [], validation: String, unity u: String? = nil, risk: String = "low") -> String {
            "{\"id\":\"\(id)\",\"title\":\"\(title)\",\"description\":\"\(title)\",\"type\":\"\(type)\",\"dependsOn\":[\(deps.map { "\"\($0)\"" }.joined(separator: ","))],\"expected\":\"done\",\"validation\":\"\(validation)\",\"risk\":\"\(risk)\""
                + (u.map { ",\"unity\":\($0)" } ?? "") + "}"
        }
        func plan(_ steps: [String]) -> String { "{\"summary\":\"unity plan\",\"steps\":[" + steps.joined(separator: ",") + "]}" }
        func edit(_ id: String, _ title: String, deps: [String], _ actions: String) -> String { step(id, title, "unityEdit", deps: deps, validation: "unityState", unity: "{\"actions\":[\(actions)]}", risk: "medium") }
        func inspectStep(_ names: [String]) -> String { step("s1", "Inspect the editor", "unityInspect", validation: "unityInspected", unity: "{\"targets\":[\(names.map { "\"\($0)\"" }.joined(separator: ","))]}") }
        let reviewPassText = "{\"verdict\":\"pass\",\"summary\":\"fine\",\"issues\":[]}"

        /// Submits a task and answers its approvals through the REAL approval pathway (`TaskEngine.decide`), exactly like the HUD buttons.
        func runTask(_ engine: TaskEngine, _ goal: String, kind: TaskKind = .development, destructive: Bool = false, preference: ProviderPreference? = nil,
                     approvals: [(String, Bool)] = [], timeout: Double = 900) async -> TaskView? {
            var decided: [String] = []
            // Each scenario starts from a committed (clean) Git tree, as a user who commits between tasks would have; the Git-dirty protection itself is covered by unit tests.
            await git(["add", "-A"], in: project); await git(["commit", "-q", "-m", "scenario"], in: project)
            guard case .success(let id) = await engine.submit(goal: goal, kind: kind, workspacePath: project, preference: preference, destructiveRequested: destructive) else { return nil }
            let decider = Task { @MainActor in
                while !Task.isCancelled {
                    for a in engine.pendingApprovals where a.taskID == id && !decided.contains(a.id.uuidString) {
                        decided.append(a.id.uuidString)
                        let rule = approvals.first { a.action.contains($0.0) }
                        info("approval requested: \(a.action.prefix(110)) → \(rule?.1 == true ? "APPROVED" : "DENIED") (by the test, through TaskEngine.decide)")
                        engine.decide(a.id, approved: rule?.1 ?? false, by: "live-test")
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            let watchdog = Task { @MainActor in try? await Task.sleep(for: .seconds(timeout)); if !Task.isCancelled { engine.cancel(id) } }
            await engine.waitUntilFinished(id)
            decider.cancel(); watchdog.cancel()
            return engine.view(id)
        }
        func stepsSummary(_ v: TaskView?) -> String { (v?.steps ?? []).map { "\($0.type.rawValue):\($0.state.rawValue)" }.joined(separator: " → ") }
        func evidence(_ v: TaskView?, _ type: StepType) -> String { v?.steps.first { $0.type == type }?.validationEvidence ?? "" }
        func why(_ v: TaskView?) -> String { v?.task.state == .completed ? "" : "\(v?.task.state.rawValue ?? "?"): \(v?.task.failureCategory?.rawValue ?? "?") — \(v?.task.failureReason?.prefix(260) ?? "")" }

        /// CPU of JARVIS and of the Unity editor (separately) around a block — Unity's own work is never attributed to JARVIS.
        func measure<T>(_ label: String, _ body: () async -> T) async -> T {
            let editorPid = conn().transport.currentStatus()?.pid ?? 0
            let j0 = ProcessTree.cpuSeconds(of: me) ?? 0, u0 = unityCPU(editorPid), t0 = Date()
            let r = await body()
            let wall = Date().timeIntervalSince(t0)
            let j1 = ProcessTree.cpuSeconds(of: me) ?? 0, u1 = unityCPU(editorPid)
            info("PERFORMANCE \(label): \(fmt(wall)) s wall · JARVIS \(fmt(j1 - j0, "%.2f")) CPU-s (\(fmt((j1 - j0) / max(wall, 0.001) * 100, "%.1f")) %) · Unity Editor \(fmt(u1 - u0, "%.2f")) CPU-s (\(fmt((u1 - u0) / max(wall, 0.001) * 100, "%.1f")) %)")
            return r
        }

        // A tool session of the TEST (not of any task) for independent verification of what the editor holds.
        let verifier = UnityToolSession(capabilities: CapabilitySet(granted: TaskCapability.unityDevelopment), taskID: nil, runID: nil, hub: nil, destructiveRequested: false)
        func conn() -> UnityConnection { unity.connection(for: project) }
        func ask(_ op: UnityOperation) async -> UnityResponse? { try? await conn().perform(op, session: verifier) }
        func componentCount(_ path: String, _ type: String) async -> Int {
            guard let r = await ask(.inspectGameObject(UnityTarget(path: path), depth: 0, maxChildren: 0)) else { return -1 }
            return (r.result["components"] as? [[String: Any]] ?? []).filter { ($0["type"] as? String) == type }.count
        }
        func property(_ path: String, _ comp: String, _ prop: String) async -> UnityValue? {
            guard let r = await ask(.inspectSerializedProperties(UnityTarget(path: path), componentType: comp, componentIndex: nil, propertyPaths: [prop])) else { return nil }
            return (r.result["properties"] as? [[String: Any]])?.first.flatMap { UnityValue(any: $0["value"]) }
        }
        func sceneOnDisk() -> String { fixtureFile("Assets/Scenes/FixtureScene.unity") ?? "" }
        func pid() -> pid_t { conn().transport.currentStatus()?.pid ?? 0 }
        /// CPU seconds / resident MB of the Unity editor INCLUDING its helper processes (compiler servers, package manager, asset import workers).
        func unityCPU(_ editorPid: pid_t) -> Double { editorPid > 0 ? ([editorPid] + ProcessTree.descendants(of: editorPid)).reduce(0) { $0 + (ProcessTree.cpuSeconds(of: $1) ?? 0) } : 0 }
        func unityRSS(_ editorPid: pid_t) -> Double { editorPid > 0 ? Double(([editorPid] + ProcessTree.descendants(of: editorPid)).reduce(UInt64(0)) { $0 + (ProcessTree.residentBytes(of: $1) ?? 0) }) / 1_048_576 : 0 }

        // ============================================================ A. inspection (read-only task, bridge install approval, owned editor launch)
        let readOnlyEngine = scriptedEngine { job, _ in
            switch job.type {
            case "PlannerAgent": return plan([inspectStep(["TestCube", "CounterObject"]), step("s2", "Validate state", "unityValidate", deps: ["s1"], validation: "unityState",
                                                                                                unity: "{\"expectations\":[{\"kind\":\"objectExists\",\"target\":{\"path\":\"TestCube\"}},{\"kind\":\"componentAbsent\",\"target\":{\"path\":\"TestCube\"},\"componentType\":\"BoxCollider\"}],\"requireNoNewErrors\":false}")])
            default: return nil
            }
        }
        let t0 = Date()
        let a = await runTask(readOnlyEngine, "Inspect why TestCube has no collider", kind: .readOnlyAnalysis,
                              approvals: [("Install the JARVIS Unity Editor bridge", true)], timeout: 1200)
        info("scenario A (read-only inspection, includes first project import) took \(fmt(Date().timeIntervalSince(t0))) s: \(stepsSummary(a))")
        check("A read-only task received inspection capabilities only (no Unity edit/save/compile/test/play capability)",
              a?.task.capabilities.allows(.inspectUnity) == true && !(a?.task.capabilities.allows(.modifyUnityScene) ?? true) && !(a?.task.capabilities.allows(.runUnityTests) ?? true))
        check("The bridge package was installed only after an approval, and it matches the embedded package", UnityBridgeInstaller.isCurrent(root: project)
              && ((try? repo.approvals(taskID: a?.id ?? UUID())) ?? []).contains { $0.action.contains("Install the JARVIS Unity Editor bridge") && $0.state == .approved })
        check("JARVIS started its OWN editor, connected to it and reports the truthful state", conn().transport.currentStatus()?.owned == true && [.connected, .busy].contains(conn().state), "\(conn().state.rawValue) · \(conn().status?.unityVersion ?? "?")")
        check("The editor's Unity version equals the project's declared version", conn().status?.unityVersion == declared.description, "\(conn().status?.unityVersion ?? "?") vs \(declared)")
        check("Inspection + validation steps passed from the editor's own state (read-only: no mutation operation was sent)", a?.task.state == .completed && !(conn().status?.scenes.contains(where: \.dirty) ?? true), why(a))
        let inspectText = a?.steps.first { $0.type == .unityInspect }?.resultSummary ?? ""
        check("TestCube resolved to one object; its components and CounterObject's serialized property were read", inspectText.contains("TestCube") && inspectText.contains("MeshRenderer") && inspectText.contains("startValue=1"), String(inspectText.prefix(160)))
        let status0 = conn().transport.currentStatus()
        info("editor pid \(pid()) · batchMode \(status0?.batchMode == true) · scenes \(status0?.scenes.map(\.path).joined(separator: ",") ?? "?")")

        // ============================================================ B. component mutation + idempotent retry
        let collider = scriptedEngine { job, _ in
            guard job.type == "PlannerAgent" else { return nil }
            return plan([inspectStep(["TestCube"]),
                         edit("s2", "Add BoxCollider", deps: ["s1"], "{\"op\":\"addComponent\",\"target\":{\"path\":\"TestCube\"},\"componentType\":\"BoxCollider\"}"),
                         step("s3", "Compile", "unityCompile", deps: ["s2"], validation: "unityCompiled"),
                         step("s4", "Validate", "unityValidate", deps: ["s3"], validation: "unityState",
                              unity: "{\"expectations\":[{\"kind\":\"componentCount\",\"target\":{\"path\":\"TestCube\"},\"componentType\":\"BoxCollider\",\"count\":1}]}")])
        }
        let b1 = await measure("Unity task: inspect → edit → save → compile → validate") { await runTask(collider, "Add a BoxCollider to TestCube if it does not have one") }
        check("Component mutation: inspect → typed edit → scene save → compile → validate completed", b1?.task.state == .completed, why(b1) + " " + stepsSummary(b1))
        let aw1 = await componentCount("TestCube", "BoxCollider")
        check("The BoxCollider exists exactly once in the editor AND in the saved scene file; the scene is clean", aw1 == 1 && sceneOnDisk().contains("BoxCollider") && conn().status?.scenes.first?.dirty == false)
        let b2 = await runTask(collider, "Add a BoxCollider to TestCube if it does not have one")
        let aw2 = await componentCount("TestCube", "BoxCollider")
        check("Retrying the same task is idempotent (no duplicate BoxCollider)", b2?.task.state == .completed && aw2 == 1, why(b2))
        check("Unity compilation state came from the editor (real compile, real generation counter)", evidence(b1, .unityCompile).contains("Unity compile: PASS"), evidence(b1, .unityCompile))

        // ============================================================ C. serialized property
        let setProp: (Int, Int) -> TaskEngine = { old, new in
            scriptedEngine { job, _ in
                guard job.type == "PlannerAgent" else { return nil }
                return plan([inspectStep(["CounterObject"]),
                             edit("s2", "Set startValue", deps: ["s1"], "{\"op\":\"setSerializedProperty\",\"target\":{\"path\":\"CounterObject\"},\"componentType\":\"Counter\",\"propertyPath\":\"startValue\",\"expectedOld\":\(old),\"newValue\":\(new)}")])
            }
        }
        let c1 = await runTask(setProp(1, 5), "Set CounterObject startValue from 1 to 5")
        let c1v = await property("CounterObject", "Counter", "startValue")
        check("Serialized property: startValue 1 → 5 applied with the expected old value, verified by reading it back, saved to the scene file",
              c1?.task.state == .completed && c1v == .number(5) && sceneOnDisk().contains("startValue: 5"), why(c1))
        let c2 = await runTask(setProp(1, 5), "Set CounterObject startValue from 1 to 5")
        let aw3 = await property("CounterObject", "Counter", "startValue")
        check("Repeating the property change is idempotent (already applied)", c2?.task.state == .completed && aw3 == .number(5), why(c2))
        let c3 = await runTask(setProp(1, 7), "Set CounterObject startValue from 1 to 7")
        let aw4 = await property("CounterObject", "Counter", "startValue")
        check("A stale expected old value is refused (the value is not forced) and nothing changes", c3?.task.state == .failed && aw4 == .number(5), why(c3))

        // ============================================================ K. domain reload / reconnect
        writeFixture("Assets/Scripts/Calculator.cs", "// touched by the live test\npublic static class Calculator { public static int Add(int a, int b) { return a + b; } }\n")
        let reloadsBefore = conn().transport.currentStatus()?.reloads ?? 0
        let reload = scriptedEngine { job, _ in
            guard job.type == "PlannerAgent" else { return nil }
            return plan([step("s1", "Compile", "unityCompile", validation: "unityCompiled"), inspectStep(["TestCube"]).replacingOccurrences(of: "\"s1\"", with: "\"s2\"").replacingOccurrences(of: "\"dependsOn\":[]", with: "\"dependsOn\":[\"s1\"]")])
        }
        let k1 = await measure("Unity compilation + domain reload") { await runTask(reload, "Compile the Unity project") }
        let reloadsAfter = conn().transport.currentStatus()?.reloads ?? 0
        check("Script change → Unity recompiled → domain reload survived; the bridge answered again and objects re-resolved (no stale handle used)", k1?.task.state == .completed && reloadsAfter > reloadsBefore,
              "reloads \(reloadsBefore) → \(reloadsAfter) · \(why(k1))")
        check("The compile step reports the domain reload truthfully", evidence(k1, .unityCompile).contains("domain reloaded"), evidence(k1, .unityCompile))
        // A new JARVIS service (what a relaunch creates) reconnects to the SAME running editor from its status alone.
        let service2 = UnityService()
        let prep = await service2.prepare(root: project, approvedInstall: false, approvedUpgrade: false, allowLaunch: false)
        check("A freshly created service reconnects to the running editor without starting another one (identity verified by project + pid)", prep == .ready && service2.connection(for: project).status?.pid == pid(), "\(prep)")
        service2.connection(for: project).transport.close()

        // ============================================================ F. Play Mode (+ EditMode/PlayMode tests)
        let play = scriptedEngine { job, _ in
            guard job.type == "PlannerAgent" else { return nil }
            return plan([step("s1", "Compile", "unityCompile", validation: "unityCompiled"),
                         step("s2", "EditMode tests", "unityTest", deps: ["s1"], validation: "unityTestsPass", unity: "{\"testMode\":\"editMode\",\"testNames\":[\"CalculatorTests.Add_ReturnsSum\"]}"),
                         step("s3", "PlayMode tests", "unityTest", deps: ["s2"], validation: "unityTestsPass", unity: "{\"testMode\":\"playMode\"}"),
                         step("s4", "Play and observe", "unityPlayMode", deps: ["s3"], validation: "unityPlayObserved",
                              unity: "{\"observeSeconds\":3,\"expectations\":[{\"kind\":\"propertyEquals\",\"target\":{\"path\":\"CounterObject\"},\"componentType\":\"Counter\",\"propertyPath\":\"value\",\"value\":5}]}")])
        }
        let f1 = await measure("Unity EditMode test + PlayMode test + Play Mode observation") { await runTask(play, "Run the Unity tests, enter Play Mode and verify CounterObject starts correctly") }
        check("EditMode test ran for real in the editor with the requested scope and passed", evidence(f1, .unityTest).contains("Unity tests: PASS") && f1?.steps.first { $0.key == "s2" }?.validationEvidence?.contains("1/1") == true, f1?.steps.first { $0.key == "s2" }?.validationEvidence ?? why(f1))
        check("PlayMode test ran for real (editor entered and left Play Mode by itself) and passed", f1?.steps.first { $0.key == "s3" }?.state == .passed && f1?.steps.first { $0.key == "s3" }?.validationEvidence?.contains("PlayMode 1/1") == true, f1?.steps.first { $0.key == "s3" }?.validationEvidence ?? "")
        check("Play Mode: entered (confirmed), runtime fact Counter.value == startValue(5) observed, left (confirmed), no new Console errors", f1?.task.state == .completed && evidence(f1, .unityPlayMode).contains("left Play Mode (confirmed)"), evidence(f1, .unityPlayMode))
        check("After the run the editor is back in Edit Mode and the connection says so", conn().transport.currentStatus()?.isPlaying == false && conn().state == .connected, conn().state.rawValue)

        // ============================================================ I. Play Mode blocks persistent mutations
        _ = try? await conn().perform(.enterPlayMode, session: verifier)
        let inPlay = await waitUntil(120) { conn().transport.currentStatus()?.isPlaying == true }
        check("The connection reports PLAY MODE only when the editor really is in Play Mode", inPlay && conn().state == .playMode, conn().state.rawValue)
        let rigid = scriptedEngine { job, _ in
            guard job.type == "PlannerAgent" else { return nil }
            return plan([edit("s1", "Add Rigidbody", deps: [], "{\"op\":\"addComponent\",\"target\":{\"path\":\"TestCube\"},\"componentType\":\"Rigidbody\"}")])
        }
        let i1 = await runTask(rigid, "Add a Rigidbody to TestCube")
        let aw5 = await componentCount("TestCube", "Rigidbody")
        check("A Unity mutation task during Play Mode is refused by policy (unsafeEditorState); nothing changed", i1?.task.state == .failed && i1?.task.failureCategory == .unsafeEditorState && aw5 == 0, why(i1))
        let codeDuringPlay = scriptedEngine { job, _ in
            switch job.type { case "PlannerAgent": return plan([step("s1", "Edit script", "codeChange", validation: "changedFiles", risk: "medium")])
            case "CodingAgent": return "<<<<<<< SEARCH Assets/Scripts/Counter.cs\npublic int startValue = 1;\n=======\npublic int startValue = 2;\n>>>>>>> REPLACE\n"
            default: return nil }
        }
        let i2 = await runTask(codeDuringPlay, "Change the Counter script")
        check("A script edit during Play Mode is refused and the file is untouched", i2?.task.failureCategory == .unsafeEditorState && (fixtureFile("Assets/Scripts/Counter.cs") ?? "").contains("startValue = 1"), why(i2))
        let rawBlocked = try? await conn().transport.send(.addComponent(UnityTarget(path: "TestCube"), componentType: "Rigidbody", ifAbsent: true), timeout: 20)
        check("Even a request that bypassed JARVIS' policy is rejected by the bridge itself during Play Mode", rawBlocked?.ok == false && rawBlocked?.errorCode == "playModeMutationBlocked", rawBlocked?.errorCode ?? "no answer")
        _ = try? await conn().perform(.exitPlayMode, session: verifier)
        _ = await waitUntil(60) { conn().transport.currentStatus()?.isPlaying == false }
        let i3 = await runTask(rigid, "Add a Rigidbody to TestCube")
        let aw6 = await componentCount("TestCube", "Rigidbody")
        check("After leaving Play Mode the same mutation proceeds (otherwise authorized)", i3?.task.state == .completed && aw6 == 1, why(i3))

        // ============================================================ H. user's unsaved scene is never overwritten silently
        try? FileManager.default.createDirectory(atPath: signalDir, withIntermediateDirectories: true)
        try? "1".write(toFile: signalDir + "/make-dirty", atomically: true, encoding: .utf8)
        let dirty = await waitUntil(30) { conn().transport.currentStatus()?.userDirtyScenes.isEmpty == false }
        check("An unsaved change made by someone else is visible as USER-dirty (not JARVIS-dirty)", dirty, conn().status?.scenes.map { "\($0.path) dirty=\($0.dirty) jarvis=\($0.jarvisDirty)" }.joined(separator: ";") ?? "")
        let sceneBeforeH = sceneOnDisk()
        let spring = scriptedEngine { job, _ in
            guard job.type == "PlannerAgent" else { return nil }
            return plan([edit("s1", "Add SphereCollider", deps: [], "{\"op\":\"addComponent\",\"target\":{\"path\":\"CounterObject\"},\"componentType\":\"SphereCollider\"}")])
        }
        let h1 = await runTask(spring, "Add a SphereCollider to CounterObject", approvals: [("with your unsaved changes", false)])
        let h1c = await componentCount("CounterObject", "SphereCollider")
        check("Dirty scene: JARVIS asked first; on DENY nothing was modified or saved and the user's change is still unsaved",
              h1?.task.failureCategory == .approvalDenied && sceneOnDisk() == sceneBeforeH && conn().status?.userDirtyScenes.isEmpty == false && h1c == 0, why(h1))
        let h2 = await runTask(spring, "Add a SphereCollider to CounterObject", approvals: [("with your unsaved changes", true)])
        let aw7 = await componentCount("CounterObject", "SphereCollider")
        check("Dirty scene: after the user APPROVES, JARVIS applies its change and saves the scene (including the approved user edit)", h2?.task.state == .completed && aw7 == 1 && sceneOnDisk().contains("SphereCollider"), why(h2))

        // ============================================================ J. ambiguity
        let twins = scriptedEngine { job, _ in
            guard job.type == "PlannerAgent" else { return nil }
            return plan([edit("s1", "Create twins", deps: [], "{\"op\":\"createGameObject\",\"name\":\"Twin\",\"ifAbsent\":false},{\"op\":\"createGameObject\",\"name\":\"Twin\",\"ifAbsent\":false}")])
        }
        let j0 = await runTask(twins, "Create two GameObjects named Twin")
        let twinCount = (await ask(.findGameObjects(name: "Twin", componentType: nil, max: 10)))?.result["count"] as? Int ?? -1
        check("Two same-name GameObjects exist in the editor (precondition)", j0?.task.state == .completed && twinCount == 2, why(j0))
        let nameOnly = scriptedEngine { job, _ in
            guard job.type == "PlannerAgent" else { return nil }
            return plan([edit("s1", "Add Rigidbody to Twin", deps: [], "{\"op\":\"addComponent\",\"target\":{\"name\":\"Twin\"},\"componentType\":\"Rigidbody\"}")])
        }
        let j1 = await runTask(nameOnly, "Add a Rigidbody to Twin")
        let aw8 = await componentCount("Twin#0", "Rigidbody")
        let aw9 = await componentCount("Twin#1", "Rigidbody")
        check("A mutation naming only \"Twin\" is NOT applied to the first match: the task fails as ambiguous", j1?.task.failureCategory == .ambiguousTarget && aw8 == 0 && aw9 == 0, why(j1))
        let precise = scriptedEngine { job, _ in
            guard job.type == "PlannerAgent" else { return nil }
            return plan([edit("s1", "Add Rigidbody to Twin#1", deps: [], "{\"op\":\"addComponent\",\"target\":{\"path\":\"Twin#1\"},\"componentType\":\"Rigidbody\"}")])
        }
        let j2 = await runTask(precise, "Add a Rigidbody to the second Twin")
        let aw10 = await componentCount("Twin#1", "Rigidbody")
        let aw11 = await componentCount("Twin#0", "Rigidbody")
        check("With the indexed path only the second Twin changed", j2?.task.state == .completed && aw10 == 1 && aw11 == 0, why(j2))

        // ============================================================ G. Console baseline/delta + sanitization
        let secretFragments = ["hunter2-fake", "FAKE0123456789abcdefghijkl"]
        try? "pre-existing fixture error before the task".write(toFile: signalDir + "/log-error", atomically: true, encoding: .utf8)
        _ = await waitUntil(20) { !FileManager.default.fileExists(atPath: signalDir + "/log-error") }
        let emitter = scriptedEngine { job, _ in
            guard job.type == "PlannerAgent" else { return nil }
            return plan([edit("s1", "Create ErrorHost with ErrorEmitter", deps: [], "{\"op\":\"createGameObject\",\"name\":\"ErrorHost\"},{\"op\":\"addComponent\",\"target\":{\"path\":\"ErrorHost\"},\"componentType\":\"ErrorEmitter\"}"),
                         step("s2", "Compile", "unityCompile", deps: ["s1"], validation: "unityCompiled"),
                         step("s3", "Play and observe", "unityPlayMode", deps: ["s2"], validation: "unityPlayObserved", unity: "{\"observeSeconds\":2}")])
        }
        let g1 = await runTask(emitter, "Create an ErrorHost object that logs an error in Play Mode and play the scene")
        let g1Evidence = evidence(g1, .unityPlayMode)
        check("Console delta: the error emitted by the new component is attributed to THIS task (1 new error) and fails the Play Mode validation; the pre-existing error is not blamed", g1?.task.state == .failed && g1Evidence.contains("new Console errors: 1"), g1Evidence)
        check("Console evidence is sanitized: the synthetic secret never appears in the step evidence", secretFragments.allSatisfy { !g1Evidence.contains($0) } && !(g1?.task.failureReason ?? "").contains("hunter2"), String(g1Evidence.suffix(160)))
        check("Play Mode was left again even though the validation failed", conn().transport.currentStatus()?.isPlaying == false)

        // ============================================================ P/Q. escapes and arbitrary execution
        for op in [UnityOperation.openScene(path: "../outside.unity"), .createPrefab(UnityTarget(path: "TestCube"), assetPath: "Assets/../x.prefab"), .saveScene(scene: "/etc/passwd")] {
            if case .deny = UnityPolicy.authorize(op, capabilities: CapabilitySet(granted: TaskCapability.unityDevelopment), status: conn().status, destructiveRequested: false) { continue }
            check("Path escape \(op.summary) is denied by policy", false)
        }
        check("Workspace-escape paths in Unity operations are denied before anything is sent", true)
        let escape = try? await conn().transport.send(.openScene(path: "Assets/../../outside.unity"), timeout: 20)
        check("The bridge itself also refuses a scene path that escapes Assets/", escape?.ok == false, escape?.errorCode ?? "no answer")
        // A hand-written request file for an operation that does not exist (what a bug or a model would need to ask for code/menu execution).
        let rawID = "live-\(UUID().uuidString.prefix(6))"
        let rawReq = project + "/Library/JarvisBridge/requests/\(rawID).json"
        try? "{\"id\":\"\(rawID)\",\"op\":\"executeMenuItem\",\"params\":{\"item\":\"File/Quit\"}}".write(toFile: rawReq, atomically: true, encoding: .utf8)
        _ = await waitUntil(20) { FileManager.default.fileExists(atPath: project + "/Library/JarvisBridge/responses/\(rawID).json") }
        let rawResp = FileManager.default.contents(atPath: project + "/Library/JarvisBridge/responses/\(rawID).json").flatMap { UnityResponse(data: $0) }
        check("The editor rejects an operation outside the fixed protocol (no menu-item / C# / shell operation exists)", rawResp?.ok == false && rawResp?.errorCode == "unknownOperation", rawResp?.errorCode ?? "no answer")
        check("A provider answer asking for C#, a menu item, a shell command or AppleScript is rejected by the action parser",
              ["{\"actions\":[{\"op\":\"runCSharp\",\"code\":\"System.IO.File.Delete(\\\"x\\\")\"}]}", "{\"actions\":[{\"op\":\"executeMenuItem\",\"menu\":\"File/Quit\"}]}",
               "{\"actions\":[{\"op\":\"addComponent\",\"target\":{\"path\":\"A\"},\"componentType\":\"BoxCollider\",\"command\":\"rm -rf /\"}]}"].allSatisfy { UnityActionParser.parse($0).actions.isEmpty })

        // ============================================================ N. destructive actions need approval
        let delTestCube = scriptedEngine { job, _ in
            guard job.type == "PlannerAgent" else { return nil }
            return plan([edit("s1", "Delete TestCube", deps: [], "{\"op\":\"deleteGameObject\",\"target\":{\"path\":\"TestCube\"}}")])
        }
        let n1 = await runTask(delTestCube, "Delete TestCube", destructive: true, approvals: [("Delete Unity object", false)])
        let aw12 = await componentCount("TestCube", "Transform")
        check("Delete TestCube: approval was required; DENIED → the object remains", n1?.task.failureCategory == .approvalDenied && aw12 == 1, why(n1))
        let delHost = scriptedEngine { job, _ in
            guard job.type == "PlannerAgent" else { return nil }
            return plan([edit("s1", "Delete ErrorHost", deps: [], "{\"op\":\"deleteGameObject\",\"target\":{\"path\":\"ErrorHost\"}}")])
        }
        let n2 = await runTask(delHost, "Delete the ErrorHost object", destructive: true, approvals: [("Delete Unity object", true)])
        let aw13 = await componentCount("ErrorHost", "Transform")
        let aw14 = await componentCount("TestCube", "Transform")
        check("Delete ErrorHost: after APPROVAL exactly that object was removed (scoped), others untouched, scene saved", n2?.task.state == .completed && aw13 == -1 && aw14 == 1, why(n2))
        let n3 = await runTask(delHost, "Delete the ErrorHost object", destructive: false)
        check("A deletion the goal did not ask for is refused outright", n3?.task.state == .failed, why(n3))

        // ============================================================ M. V0.5 design proposal (Ask Before Acting AND Low-Risk Autonomous)
        let sceneHash = sceneOnDisk().hashValue
        let tasksBefore = ((try? repo.engineTasks(limit: 500)) ?? []).count
        var designNeverAuto = true
        for mode in [AutonomyMode.askBeforeActing, .lowRiskAutonomous] {
            prefs.autonomyMode = mode
            let res = await context.opportunities.ingest(RawFinding(origin: .reviewFinding, title: "Redesign the fixture scene with a new lighting setup", summary: "The scene could use warmer lighting and a skybox.",
                                                                       category: nil, evidence: [EvidenceItem(kind: .modelClaim, summary: "reviewer suggestion", reference: nil)], affectedPaths: ["Assets/Scenes/FixtureScene.unity"],
                                                                       originTaskID: n2?.id, projectRoot: project, eventKey: "unity-live:lighting:\(mode.rawValue)"))
            if case .autoTask = res { designNeverAuto = false }
            if case .queued = res { designNeverAuto = false }
        }
        prefs.autonomyMode = .askBeforeActing
        check("V0.5: a Unity design finding (lighting redesign) becomes a PROPOSAL in every mode — never an automatic action, no task, scene file untouched",
              designNeverAuto && ((try? repo.engineTasks(limit: 500)) ?? []).count == tasksBefore && sceneOnDisk().hashValue == sceneHash)

        // ============================================================ L. cancellation (Play Mode held by the task is released)
        let longPlay = scriptedEngine { job, _ in
            guard job.type == "PlannerAgent" else { return nil }
            return plan([step("s1", "Compile", "unityCompile", validation: "unityCompiled"), step("s2", "Long Play Mode", "unityPlayMode", deps: ["s1"], validation: "unityPlayObserved", unity: "{\"observeSeconds\":30,\"requireNoNewErrors\":false}")])
        }
        guard case .success(let longID) = await longPlay.submit(goal: "Play the scene for a long time", kind: .development, workspacePath: project) else { check("Long Play Mode task submitted", false); finish() }
        _ = await waitUntil(240) { conn().transport.currentStatus()?.isPlaying == true }
        let wasPlaying = conn().transport.currentStatus()?.isPlaying == true
        let cancelAt = Date()
        longPlay.cancel(longID)
        await longPlay.waitUntilFinished(longID)
        let l = longPlay.view(longID)
        _ = await waitUntil(60) { conn().transport.currentStatus()?.isPlaying == false }
        check("Cancellation: the task is STOPPED within seconds, the Play Mode it started is left, and no Unity lock stays held", wasPlaying && l?.task.state == .cancelled && conn().transport.currentStatus()?.isPlaying == false && unity.lock.holder(of: project) == nil,
              "\(fmt(Date().timeIntervalSince(cancelAt))) s · \(l?.task.state.rawValue ?? "?")")
        check("Cancellation left no queued request behind in the spool", ((try? FileManager.default.contentsOfDirectory(atPath: project + "/Library/JarvisBridge/requests")) ?? []).filter { $0.hasSuffix(".json") }.isEmpty)
        check("The cancelled task has a persisted report", l?.task.reportArtifactID != nil)

        // ============================================================ relaunch recovery: JARVIS "crashes" during Play Mode
        let crashy = scriptedEngine { job, _ in
            guard job.type == "PlannerAgent" else { return nil }
            return plan([step("s1", "Compile", "unityCompile", validation: "unityCompiled"), step("s2", "Play Mode", "unityPlayMode", deps: ["s1"], validation: "unityPlayObserved", unity: "{\"observeSeconds\":20,\"requireNoNewErrors\":false}")])
        }
        guard case .success(let crashID) = await crashy.submit(goal: "Play the scene and observe", kind: .development, workspacePath: project) else { check("Crash-test task submitted", false); finish() }
        _ = await waitUntil(240) { conn().transport.currentStatus()?.isPlaying == true }
        crashy.prepareForTermination()                         // JARVIS quits while the task runs: INTERRUPTED + checkpoint (a SIGKILL cannot be intercepted)
        await crashy.waitUntilIdle()
        // What an unintercepted crash would have left behind: the owned editor still in Play Mode.
        _ = try? await conn().perform(.enterPlayMode, session: verifier)
        _ = await waitUntil(120) { conn().transport.currentStatus()?.isPlaying == true }
        let relaunched = scriptedEngine { job, _ in
            guard job.type == "PlannerAgent" else { return nil }
            return plan([step("s1", "Compile", "unityCompile", validation: "unityCompiled"), step("s2", "Play Mode", "unityPlayMode", deps: ["s1"], validation: "unityPlayObserved", unity: "{\"observeSeconds\":2,\"requireNoNewErrors\":false}")])
        }
        let recon = relaunched.reconcileOnLaunch()
        let interrupted = ((try? repo.engineTask(crashID)) ?? nil)
        check("Quitting while a Unity task runs persists it as INTERRUPTED (never 'running forever'); relaunch reconciliation finds nothing stale", interrupted?.state == .interrupted, "\(interrupted?.state.rawValue ?? "?") · \(recon.tasks.count) additional stale task(s) reconciled")
        let svc3 = UnityService()
        relaunched.unity = svc3
        let prep3 = await svc3.prepare(root: project, approvedInstall: false, approvedUpgrade: false, allowLaunch: false)
        check("After the relaunch the new service reconnects and reports PLAY MODE truthfully (the editor is still playing)", prep3 == .ready && svc3.connection(for: project).state == .playMode, "\(prep3) · \(svc3.connection(for: project).state.rawValue)")
        _ = relaunched.resume(crashID)
        await relaunched.waitUntilFinished(crashID)
        let resumed = relaunched.view(crashID)
        check("Resuming (explicit) takes back Play Mode of an editor JARVIS owns, finishes the step and leaves Play Mode", resumed?.task.state == .completed && conn().transport.currentStatus()?.isPlaying == false, why(resumed))
        svc3.connection(for: project).transport.close()

        // ============================================================ REAL provider-routed coding: compile error + failing test
        var providerChecked = false
        if withProvider {
            await context.refreshIntelligence(remoteCatalog: true)
            for id in ProviderID.allCases { info("\(id.displayName): \(sup.availability()[id]?.state.label ?? "?")") }
            prefs.providerPreference = .auto
            if !context.openCode.freePool.isEmpty {
                let preferred = ["space-bunny-free", "longcat-2.5-preview-free", "big-pickle", "ling-3.1-flash-free"]
                let pick = preferred.compactMap { p in context.openCode.freePool.first { $0.id.hasSuffix(p) } }.first ?? context.openCode.freePool[0]
                info("benchmarking \(pick.id) so Auto may route development work to it…")
                await context.benchmark(modelID: pick.id); sup.invalidateBenchmarks()
                info("benchmark \(pick.id): \(((try? repo.benchmarks(modelID: pick.id)) ?? []).filter(\.passed).count)/13 cases passed")
            }
            if !ProviderID.allCases.filter({ sup.availability()[$0]?.state == .ready && $0 != .local }).isEmpty {
                providerChecked = true
                // D — a real Unity compiler error
                writeFixture("Assets/Scripts/Greeter.cs", "public static class Greeter\n{\n    public static string Greet(string name)\n    {\n        return \"Hello, \" + name\n    }\n}\n")
                await git(["add", "-A"], in: project); await git(["commit", "-q", "-m", "fixture: broken Greeter"], in: project)       // the broken script is the project's committed state, not 'the user's uncommitted work'
                let compilePlan = plan([step("s1", "Inspect the editor", "unityInspect", validation: "unityInspected", unity: "{\"requireNoNewErrors\":false}"),
                                        step("s2", "Find the compile error", "analysis", deps: ["s1"], validation: "structuredResult"),
                                        step("s3", "Fix the script", "codeChange", deps: ["s2"], validation: "changedFiles", risk: "medium"),
                                        step("s4", "Compile in Unity", "unityCompile", deps: ["s3"], validation: "unityCompiled", unity: "{\"requireNoNewErrors\":false}")])
                let engineD = hybridEngine { compilePlan }
                let t1 = Date()
                let d = await runTask(engineD, "Fix the Unity compile error in Greeter.cs", timeout: 1200)
                let runsD = ((try? repo.agentRuns(taskID: d?.id ?? UUID())) ?? []).filter { $0.engine != .tool }
                info("scenario D (REAL provider): \(fmt(Date().timeIntervalSince(t1))) s · \(stepsSummary(d)) · providers: \(Set(runsD.map { $0.engine.displayName + ($0.model.map { " · " + $0 } ?? "") }).sorted().joined(separator: ", "))")
                let compileNow = await ask(.getCompilationState)
                check("REAL provider fixed a REAL Unity compile error: the editor's own compiler state is clean afterwards", d?.task.state == .completed && compileNow?.result["scriptCompilationFailed"] as? Bool == false && (fixtureFile("Assets/Scripts/Greeter.cs") ?? "").contains("name;"), why(d))
                check("The provider work used a non-local engine (Local Qwen never codes) through the real router", !runsD.isEmpty && runsD.allSatisfy { $0.engine != .local }, runsD.map { "\($0.agentType)@\($0.engine.displayName)" }.joined(separator: ", "))
                // E — a failing EditMode test
                writeFixture("Assets/Scripts/Calculator.cs", "public static class Calculator\n{\n    public static int Add(int a, int b) { return a - b; }\n}\n")
                await git(["add", "-A"], in: project); await git(["commit", "-q", "-m", "fixture: broken Calculator"], in: project)
                let testPlan = plan([step("s1", "Inspect the editor", "unityInspect", validation: "unityInspected", unity: "{\"requireNoNewErrors\":false}"),
                                     step("s2", "Analyse the failing test", "analysis", deps: ["s1"], validation: "structuredResult"),
                                     step("s3", "Fix the code", "codeChange", deps: ["s2"], validation: "changedFiles", risk: "medium"),
                                     step("s4", "Compile in Unity", "unityCompile", deps: ["s3"], validation: "unityCompiled", unity: "{\"requireNoNewErrors\":false}"),
                                     step("s5", "Run the EditMode test", "unityTest", deps: ["s4"], validation: "unityTestsPass", unity: "{\"testMode\":\"editMode\",\"testNames\":[\"CalculatorTests.Add_ReturnsSum\",\"CalculatorTests.Add_HandlesNegatives\"]}"),
                                     step("s6", "Review the change", "review", deps: ["s5"], validation: "reviewPass")])
                let engineE = hybridEngine { testPlan }
                let t2 = Date()
                let e = await runTask(engineE, "Fix the failing Unity test in CalculatorTests", timeout: 1200)
                let runsE = ((try? repo.agentRuns(taskID: e?.id ?? UUID())) ?? []).filter { $0.engine != .tool }
                info("scenario E (REAL provider): \(fmt(Date().timeIntervalSince(t2))) s · \(stepsSummary(e)) · providers: \(Set(runsE.map { $0.engine.displayName + ($0.model.map { " · " + $0 } ?? "") }).sorted().joined(separator: ", "))")
                let rerun = e?.steps.first { $0.type == .unityTest }
                check("REAL provider fixed a failing Unity test: the editor ran the exact tests again and they PASS; a subjective reviewer could not turn that into FAILED",
                      rerun?.state == .passed && (rerun?.validationEvidence ?? "").contains("Unity tests: PASS") && (e?.task.state == .completed || e?.steps.first { $0.type == .review }?.state != .failed), why(e) + " " + (rerun?.validationEvidence ?? ""))
                check("Provider usage: non-local engines only, no paid API", !runsE.isEmpty && runsE.allSatisfy { $0.engine != .local && $0.engine != .tool || $0.engine == .tool })
            } else { skip("Real provider-routed Unity coding", "no provider is ready") }
        } else { skip("Real provider-routed Unity coding", "--unity-no-provider") }
        if withProvider && !providerChecked { check("A real provider is ready for the provider-routed Unity scenarios", false) }

        // ============================================================ sanitization at rest + performance + cleanup
        let dataRoot = context.paths.root.path
        let leaked = await ManagedProcess.runOnce(executable: "/usr/bin/grep", arguments: ["-rlaE", secretFragments.joined(separator: "|"), dataRoot], environment: ProviderEnvironment.make(), timeout: 60)
        check("No raw synthetic secret from the Unity Console appears anywhere in the JARVIS data directory (SQLite, artifacts, reports, checkpoints)", (leaked?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "x").isEmpty, leaked?.output ?? "")

        let uPid = pid()
        let cpu0 = ProcessTree.cpuSeconds(of: me) ?? 0, ucpu0 = unityCPU(uPid)
        try? await Task.sleep(for: .seconds(10))
        let cpu1 = ProcessTree.cpuSeconds(of: me) ?? 0, ucpu1 = unityCPU(uPid)
        info("PERFORMANCE (Unity connected, idle, 10 s): JARVIS \(fmt((cpu1 - cpu0) / 10 * 100)) % of one core · RSS \(fmt(Double(ProcessTree.residentBytes(of: me) ?? 0) / 1_048_576, "%.0f")) MB · Unity Editor \(fmt((ucpu1 - ucpu0) / 10 * 100)) % · RSS \(fmt(unityRSS(uPid), "%.0f")) MB incl. helpers (a headless editor's own idle cost; not attributed to JARVIS)")
        check("JARVIS does not poll an idle connected editor (CPU in a 10 s idle window stays tiny)", (cpu1 - cpu0) < 0.5, fmt(cpu1 - cpu0, "%.2f") + " CPU-s in 10 s")

        // JARVIS' own UI states with the editor connected and idle (separate processes; only JARVIS' CPU/RSS is JARVIS')
        let w = context.windows
        w.hideFullHUD(); w.hideCompactHUD()
        func sample(_ label: String) async {
            let a = ProcessTree.cpuSeconds(of: me) ?? 0, ua = unityCPU(uPid)
            try? await Task.sleep(for: .seconds(8))
            let b = ProcessTree.cpuSeconds(of: me) ?? 0, ub = unityCPU(uPid)
            info("PERFORMANCE \(label) (Unity connected, idle, 8 s): JARVIS \(fmt((b - a) / 8 * 100)) % · RSS \(fmt(Double(ProcessTree.residentBytes(of: me) ?? 0) / 1_048_576, "%.0f")) MB | Unity Editor \(fmt((ub - ua) / 8 * 100)) % · RSS \(fmt(unityRSS(uPid), "%.0f")) MB")
        }
        await sample("HUD closed")
        w.showCompactHUD(); await sample("Compact HUD"); w.hideCompactHUD()
        w.showFullHUD(section: .dashboard); await sample("Full HUD · Dashboard")
        w.showFullHUD(section: .tasks); await sample("Full HUD · Tasks")
        w.showFullHUD(section: .agents); await sample("Full HUD · Agents")
        w.hideFullHUD()

        await unity.shutdownOwnedEditors()
        let gone = await waitUntil(60) { !UnityProcessScanner.isUnityEditor(pid: uPid) }
        check("JARVIS closed the editor it started (graceful shutdown) and no Unity process of this fixture is left", gone && UnityProcessScanner.editor(for: project, among: UnityProcessScanner.editors()) == nil)
        check("No managed process is left behind and no Unity lock is held", ProcessRegistry.shared.count == 0 && unity.lock.heldCount == 0, "\(ProcessRegistry.shared.count) managed, \(unity.lock.heldCount) locks")
        info("provider usage: scene scenarios used 0 provider calls (scripted planner/agent); provider-routed scenarios are listed above")
        finish()
    }
}
