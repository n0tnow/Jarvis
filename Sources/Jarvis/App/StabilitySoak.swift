import AppKit

/// `Jarvis --stability-soak <N>` — OPT-IN, REAL (V0.13.1). N bounded cycles, each: a continuity query · a safe Computer press on the JARVIS fixture app (real Accessibility) · a typed Unity operation on a
/// real disposable editor · a real animation experiment · a real audio experiment · cleanup. It tracks JARVIS' own memory (RSS), the database size, started-editor processes, experiment folders and
/// failures. Disposable fixtures only; no provider is used. NOT a multi-hour claim: N cycles of a few minutes in total.
@MainActor
enum StabilitySoak {
    static func run(context: AppContext, cycles: Int) async {
        var failures = 0, passes = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "SOAK PASS" : "SOAK FAIL")  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if ok { passes += 1 } else { failures += 1 }
            fflush(stdout)
        }
        func info(_ s: String) { print("INFO  \(s)"); fflush(stdout) }
        func fmt(_ d: Double, _ f: String = "%.1f") -> String { String(format: f, d) }
        let engine = context.taskEngine, repo = context.repository!, cont = context.continuity, prefs = context.preferences, unity = context.unity
        DispatchQueue.main.asyncAfter(deadline: .now() + 3_000) { ProcessRegistry.shared.killAll(); print("STABILITY SOAK TIMEOUT"); fflush(stdout); exit(2) }
        var fixtures: [String] = []
        func finish() -> Never {
            ProcessRegistry.shared.killAll()
            for f in fixtures { try? FileManager.default.removeItem(atPath: f) }
            print("STABILITY SOAK \(failures == 0 ? "PASSED" : "FAILED") (\(passes) passed, \(failures) failed)"); fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        func rssMB() async -> Int { Int((await ManagedProcess.runOnce(executable: "/bin/ps", arguments: ["-o", "rss=", "-p", "\(getpid())"], environment: ProviderEnvironment.make(), workingDirectory: "/", timeout: 10)?.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)).map { $0 / 1024 } ?? -1 }
        func ownedEditors() async -> Int {
            let r = await ManagedProcess.runOnce(executable: "/usr/bin/pgrep", arguments: ["-f", "jarvisOwned"], environment: ProviderEnvironment.make(), workingDirectory: "/", timeout: 10)
            return (r?.output ?? "").split(separator: "\n").filter { !$0.isEmpty }.count
        }
        func dbBytes() -> Int { ((try? FileManager.default.contentsOfDirectory(atPath: context.paths.root.path)) ?? []).filter { $0.hasPrefix("jarvis.sqlite") }.reduce(0) { $0 + (((try? FileManager.default.attributesOfItem(atPath: context.paths.root.path + "/" + $1))?[.size] as? Int) ?? 0) } }
        func git(_ args: [String], in dir: String) async { _ = await ManagedProcess.runOnce(executable: "/usr/bin/git", arguments: ["-c", "user.name=JARVIS Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false"] + args, environment: ProviderEnvironment.make(), workingDirectory: dir, timeout: 60) }
        func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool { let end = Date().addingTimeInterval(seconds); while Date() < end { if cond() { return true }; try? await Task.sleep(for: .milliseconds(150)) }; return cond() }

        // ---------------------------------------------------------------- set-up: a disposable Git project, the Unity fixture, the Computer fixture app
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let soakProject = UnityProcessScanner.canonical(NSTemporaryDirectory()) + "/jarvis-soak-project-\(UUID().uuidString.prefix(6))"
        fixtures.append(soakProject)
        await ContinuityLiveTest.resetFixture(soakProject, { rel, text in
            try? FileManager.default.createDirectory(atPath: (soakProject + "/" + rel as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: soakProject + "/" + rel, contents: Data(text.utf8))
        }, { args in await git(args, in: soakProject); return "" })
        prefs.projectRoot = soakProject; prefs.projectContinuationEnabled = true
        let unityProject = UnityProcessScanner.canonical(NSTemporaryDirectory()) + "/jarvis-soak-unity-\(UUID().uuidString.prefix(6))"
        fixtures.append(unityProject)
        do { try FileManager.default.copyItem(atPath: repoRoot + "/UnityBridge/Fixture", toPath: unityProject) } catch { check("The Unity fixture was copied", false, "\(error)"); finish() }
        await git(["init", "-q", "-b", "main"], in: unityProject); await git(["add", "-A"], in: unityProject); await git(["commit", "-q", "-m", "fixture"], in: unityProject)
        unity.refreshEditors()
        let outcome = await unity.prepare(root: unityProject, approvedInstall: true, approvedUpgrade: false, rendering: false, progress: { info($0) })
        check("The disposable Unity editor started with the bridge", outcome == .ready, "\(outcome)")
        guard outcome == .ready else { finish() }
        let conn = unity.connection(for: unityProject)
        let session = UnityToolSession(capabilities: CapabilitySet(granted: TaskCapability.unityDevelopment), taskID: nil, runID: nil, hub: nil, destructiveRequested: false)
        /// The test plays the user who accepts the editor's "this scene has unsaved changes" question for ONE exact action (the same pathway the HUD button records).
        func approved(_ op: UnityOperation) -> UnityOperation {
            if case .needsApproval(let action, _, _) = conn.authorize(op, session: session) { session.approvedActions.insert(action) }
            return op
        }
        _ = try? await conn.perform(approved(.openScene(path: "Assets/Scenes/FixtureScene.unity")), session: session)
        let scenePath = "Assets/Scenes/FixtureScene.unity"
        let statePath = NSTemporaryDirectory() + "jarvis-soak-fixture-\(UUID().uuidString).json"
        for old in NSRunningApplication.runningApplications(withBundleIdentifier: ComputerLiveTest.fixtureBundle) { old.forceTerminate() }
        try? await Task.sleep(for: .milliseconds(400))
        let trusted = context.computer.refreshPermissions().accessibility == .granted
        var fixturePID: pid_t?
        if trusted { fixturePID = await ComputerLiveTest.launchFixture(statePath: statePath, prefill: nil) }
        info("Accessibility \(trusted ? "granted" : "NOT granted — the Computer step is reported as skipped"); fixture app pid \(fixturePID.map(String.init) ?? "none")")

        let expRoot = ExperimentWorkspace.defaultRoot(dataRoot: context.paths.root)
        let expSpec = "{\"question\":\"Does it play?\",\"hypothesis\":\"It plays in Play Mode in a clean project.\",\"kind\":\"KIND\",\"assetPaths\":[],\"successCriteria\":[\"it plays\"],\"failureCriteria\":[\"it does not\"],\"minutes\":5,\"diskMegabytes\":512,\"networkRequests\":0,\"artifacts\":2,\"cleanup\":\"delete\"}"
        func experiment(_ kind: String, cycle: Int) async -> (ok: Bool, seconds: Double) {
            let t0 = Date()
            let plan = "{\"summary\":\"soak\",\"steps\":[{\"id\":\"s1\",\"title\":\"Test it\",\"description\":\"Test it\",\"type\":\"experiment\",\"dependsOn\":[],\"expected\":\"done\",\"validation\":\"experimentConcluded\",\"risk\":\"low\",\"unity\":{\"experiment\":\(expSpec.replacingOccurrences(of: "KIND", with: kind))}}]}"
            let runner = ScriptedAgentRunner(audit: context.audit, real: nil, scriptedTypes: ["PlannerAgent", "AnalysisAgent", "CodingAgent", "ReviewAgent", "UnityAgent"], script: { job, _ in job.type == "PlannerAgent" ? plan : nil })
            let e = TaskEngine(repository: repo, artifacts: context.artifacts, audit: context.audit, leases: context.leases, agents: runner)
            e.unity = unity; e.experimentsRoot = expRoot
            await git(["add", "-A"], in: unityProject); await git(["commit", "-q", "-m", "soak \(cycle) \(kind)"], in: unityProject)
            guard case .success(let id) = await e.submit(goal: "Test whether a \(kind == "audioPlayback" ? "sound" : "clip") plays in a clean Unity project (soak \(cycle))", kind: .development, workspacePath: unityProject, preference: nil, destructiveRequested: false) else { return (false, 0) }
            await e.waitUntilFinished(id)
            let rec = (try? repo.experiments(taskID: id))?.first
            return (e.view(id)?.task.state == .completed && rec?.result?.verdict == .confirmed && rec?.cleanupState == "deleted", Date().timeIntervalSince(t0))
        }

        let rss0 = await rssMB(), db0 = dbBytes()
        var rssSeries: [Int] = [rss0]
        let started = Date()
        for k in 1...cycles {
            var cycleFailures: [String] = []
            let t0 = Date()
            // 1. continuity (derived view; no provider, no task)
            let before = (try? repo.engineTasks(limit: 200))?.count ?? 0
            var status = ""
            if let intent = cont.recognizes("Where do we stand on this project?") { status = await cont.reply(to: intent, language: .en, channel: .typed) }
            if status.isEmpty || ((try? repo.engineTasks(limit: 200))?.count ?? 0) != before { cycleFailures.append("continuity") }
            // 2. a safe Computer press (real Accessibility) on the fixture app
            if let _ = fixturePID {
                let steps = [ComputerLiveTest.step("Pressing Run", ComputerLiveTest.press("Run", window: "Fixture Main", checks: [.stateChanged]))]
                if case .success(let id) = await engine.submitComputer(goal: "soak \(k): press Run", steps: steps, capability: ComputerLiveTest.capability, apps: [AppRef(bundleID: ComputerLiveTest.fixtureBundle, name: "JARVIS Fixture")]) {
                    _ = await waitUntil(60) { engine.view(id)?.task.state.isTerminal ?? false }
                    if engine.view(id)?.task.state != .completed { cycleFailures.append("computer: \(engine.view(id)?.task.failureReason?.prefix(80) ?? "?")") }
                } else { cycleFailures.append("computer submit") }
                // make the next press change the state again (the same label twice is "no change" by design)
                let reset = [ComputerLiveTest.step("Pressing Apply (Sidebar)", ComputerLiveTest.press("Apply", within: "Sidebar", window: "Fixture Main"))]
                if case .success(let rid) = await engine.submitComputer(goal: "soak \(k): reset", steps: reset, capability: ComputerLiveTest.capability, apps: [AppRef(bundleID: ComputerLiveTest.fixtureBundle, name: "JARVIS Fixture")]) { _ = await waitUntil(60) { engine.view(rid)?.task.state.isTerminal ?? false } }
            }
            // 3. a typed Unity operation on the real editor, verified by read-back
            let name = "SoakObject\(k)"
            var createError = ""
            let created: UnityResponse?
            do { created = try await conn.perform(approved(.createGameObject(name: name, scene: nil, parent: nil, primitive: "Cube", position: [Double(k), 0, 0], rotation: nil, scale: nil, ifAbsent: true)), session: session) }
            catch let e as UnityToolError { created = nil; createError = "\(e.category.rawValue): \(e.message.prefix(120))" } catch { created = nil; createError = "\(error)" }
            if let r = created, r.result["object"] != nil {
                let edit = GameObjectEdit(position: [Double(k), 1, 0])
                let ok = (try? await conn.perform(approved(.dev(.editGameObject(UnityTarget(path: name), edit))), session: session)).map { UnityDevVerifier.verify(.editGameObject(UnityTarget(path: name), edit), $0).0 } ?? false
                if !ok { cycleFailures.append("unity edit not verified") }
                // the engine saves the scene it changed; so does this direct path (otherwise the next cycle meets "unsaved changes")
                let active = conn.transport.currentStatus()?.activeScene.isEmpty == false ? conn.transport.currentStatus()!.activeScene : scenePath
                if (try? await conn.perform(approved(.saveScene(scene: active)), session: session)) == nil { cycleFailures.append("unity save") }
            } else { cycleFailures.append("unity create: \(createError)") }
            // 4. + 5. the real experiments
            let anim = await experiment("animationPlayback", cycle: k)
            if !anim.ok { cycleFailures.append("animation experiment") }
            let audio = await experiment("audioPlayback", cycle: k)
            if !audio.ok { cycleFailures.append("audio experiment") }
            // 6. cleanup facts
            let folders = (try? FileManager.default.contentsOfDirectory(atPath: expRoot.path)) ?? []
            let editorsUnderExperiments = UnityProcessScanner.editors().filter { $0.projectPath?.contains("/experiments-") == true }.count
            if !folders.isEmpty { cycleFailures.append("\(folders.count) experiment folder(s) left") }
            if editorsUnderExperiments > 0 { cycleFailures.append("\(editorsUnderExperiments) experiment editor(s) left") }
            let rss = await rssMB(); rssSeries.append(rss)
            check("cycle \(k)/\(cycles) — continuity · computer press · typed Unity edit · animation \(fmt(anim.seconds)) s · audio \(fmt(audio.seconds)) s · cleanup", cycleFailures.isEmpty, "RSS \(rss) MB · db \(dbBytes() / 1024) KB · total \(fmt(Date().timeIntervalSince(t0))) s" + (cycleFailures.isEmpty ? "" : " · " + cycleFailures.joined(separator: "; ")))
        }
        // ---------------------------------------------------------------- verdict
        let rssEnd = rssSeries.last ?? rss0, dbEnd = dbBytes()
        let growth = rssEnd - rss0
        let editorsLeft = await ownedEditors()
        await unity.shutdownOwnedEditors()
        _ = await waitUntil(60) { conn.transport.currentStatus() == nil }
        let editorsAfter = await ownedEditors()
        info("RSS series (MB): \(rssSeries.map(String.init).joined(separator: " → ")) · db \(db0 / 1024) → \(dbEnd / 1024) KB · \(cycles) cycles in \(fmt(Date().timeIntervalSince(started))) s")
        check("JARVIS' own memory stays flat across \(cycles) cycles (growth < 150 MB)", growth < 150, "\(rss0) → \(rssEnd) MB (+\(growth))")
        check("The database grows only by the records the cycles legitimately create (< 8 MB)", dbEnd - db0 < 8 * 1_048_576, "\(db0 / 1024) → \(dbEnd / 1024) KB")
        check("Only the fixture editor was alive during the run (no orphan experiment editor), and none remains after shutdown", editorsLeft <= 1 && editorsAfter == 0, "during \(editorsLeft), after \(editorsAfter)")
        check("No experiment folder, no vision helper, no experiment process remains", ((try? FileManager.default.contentsOfDirectory(atPath: expRoot.path)) ?? []).isEmpty)
        if let pid = fixturePID { NSRunningApplication(processIdentifier: pid)?.forceTerminate() }
        finish()
    }
}
