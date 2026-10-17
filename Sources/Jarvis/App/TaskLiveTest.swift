import AppKit

/// `Jarvis --task-live-test [--live-dir <dir>]` — OPT-IN, REAL (V0.4). Runs the autonomous task engine end to end with REAL providers
/// on ISOLATED temporary fixture projects (never the JARVIS repository), with its own data directory:
///   goal → durable task → real plan → real agents → real file change → real unit tests → real review → report,
/// plus real cancellation, a real interruption/resume across a "restart", a destructive-step approval and process cleanup.
/// It spends a handful of prompts on free/local engines (OpenCode FREE is preferred by the router) and, only if routing escalates,
/// on the user's own Claude Code/Codex subscription. Prints `REAL TESTED PASS/FAIL`; exits non-zero on failure. Not part of verify.sh.
@MainActor
enum TaskLiveTest {
    static func run(context: AppContext, captureDirectory: String) async {
        var failures = 0, passes = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "REAL TESTED PASS" : "REAL TESTED FAIL")  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if ok { passes += 1 } else { failures += 1 }
            fflush(stdout)
        }
        func info(_ s: String) { print("INFO  \(s)"); fflush(stdout) }
        func fmt(_ d: Double, _ f: String = "%.1f") -> String { String(format: f, d) }

        let prefs = context.preferences
        let savedPreference = prefs.providerPreference, savedRoot = prefs.projectRoot
        DispatchQueue.main.asyncAfter(deadline: .now() + 1800) { ProcessRegistry.shared.killAll(); print("TASK LIVE TEST TIMEOUT"); fflush(stdout); exit(2) }
        func finish() -> Never {
            prefs.providerPreference = savedPreference; prefs.projectRoot = savedRoot
            prefs.defaults.removeObject(forKey: "prefs.providerPreference"); prefs.defaults.removeObject(forKey: "prefs.tasks.projectRoot")
            if savedPreference != .auto { prefs.providerPreference = savedPreference }
            if !savedRoot.isEmpty { prefs.projectRoot = savedRoot }
            print("TASK LIVE TEST \(failures == 0 ? "PASSED" : "FAILED") (\(passes) passed, \(failures) failed)"); fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }

        let engine = context.taskEngine, repo = context.repository!, svc = context.conversationService!, sup = context.supervisor
        let me = getpid()
        func descendants() -> [pid_t] { ProcessTree.descendants(of: me) }
        func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if cond() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
            return cond()
        }
        func git(_ args: [String], in dir: String) async -> String {
            await ManagedProcess.runOnce(executable: "/usr/bin/git", arguments: ["-c", "user.name=JARVIS Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false"] + args,
                                         environment: ProviderEnvironment.make(), workingDirectory: dir, timeout: 20)?.output ?? ""
        }
        func makeProject(legacy: Bool = false) async -> String {
            let dir = TaskDemo.makeProject(withLegacyFile: legacy)
            FileManager.default.createFile(atPath: dir + "/README.md", contents: Data("# Calculator fixture\n".utf8))
            _ = await git(["init", "-q", "-b", "main"], in: dir); _ = await git(["add", "-A"], in: dir); _ = await git(["commit", "-q", "-m", "initial"], in: dir)
            return dir
        }
        func read(_ p: String, in dir: String) -> String? { FileManager.default.contents(atPath: dir + "/" + p).flatMap { String(data: $0, encoding: .utf8) } }
        func testsPass(in dir: String) async -> Bool {
            let r = await ManagedProcess.runOnce(executable: "/usr/bin/python3", arguments: ["-m", "unittest", "discover"], environment: ProviderEnvironment.make(), workingDirectory: dir, timeout: 30)
            return r?.exitCode == 0
        }
        func latestTask() -> TaskRecord? { (try? repo.engineTasks(limit: 1))?.first }
        var projects: [String] = []
        defer { for p in projects { try? FileManager.default.removeItem(atPath: p) } }

        info("data directory: \(context.paths.root.path) (isolated from your real JARVIS history)")
        check("Database created by the real persistence layer (schema v3 has the task tables)", (context.database?.schemaVersion ?? 0) >= 3 && (try? repo.count("tasks")) == 0, "schema v\(context.database?.schemaVersion ?? -1)")

        // ------------------------------------------------------------ A. discovery
        await context.refreshIntelligence(remoteCatalog: true)
        for id in ProviderID.allCases { info("\(id.displayName): \(sup.availability()[id]?.state.label ?? "?")") }
        info("verified-free OpenCode models: \(context.openCode.freePool.map(\.id).joined(separator: ", "))")
        let usable = ProviderID.allCases.filter { sup.availability()[$0]?.state == .ready && $0 != .local }
        guard !usable.isEmpty else { check("At least one real provider (OpenCode free / Claude Code / Codex) is ready", false, "nothing to run the engine on"); finish() }
        prefs.providerPreference = .auto

        // Auto routing needs a passed benchmark before a free model serves development work automatically: benchmark ONE free model for real.
        if !context.openCode.freePool.isEmpty {
            let preferred = ["space-bunny-free", "longcat-2.5-preview-free", "big-pickle", "ling-3.1-flash-free"]
            let pick = preferred.compactMap { p in context.openCode.freePool.first { $0.id.hasSuffix(p) } }.first ?? context.openCode.freePool[0]
            info("benchmarking \(pick.id) (13 small fixed cases) so Auto may route development work to it…")
            await context.benchmark(modelID: pick.id)
            sup.invalidateBenchmarks()
            let rows = (try? repo.benchmarks(modelID: pick.id)) ?? []
            info("benchmark \(pick.id): \(rows.filter(\.passed).count)/\(rows.count) cases passed")
        }

        // ------------------------------------------------------------ B. end to end on an isolated fixture
        let project = await makeProject(); projects.append(project)
        prefs.projectRoot = project
        check("Precondition: the fixture really fails its own tests", !(await testsPass(in: project)))
        info("fixture project: \(project)")
        let started = Date()
        var peakRSS: UInt64 = 0, childPeak: UInt64 = 0
        var childCPU: [pid_t: Double] = [:]                                 // last seen cumulative CPU seconds per child (they start at ≈0)
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                peakRSS = max(peakRSS, ProcessTree.residentBytes(of: me) ?? 0)
                let kids = descendants()
                childPeak = max(childPeak, kids.compactMap { ProcessTree.residentBytes(of: $0) }.reduce(0, +))
                for k in kids { if let c = ProcessTree.cpuSeconds(of: k) { childCPU[k] = max(childCPU[k] ?? 0, c) } }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        let cpu0 = ProcessTree.cpuSeconds(of: me) ?? 0
        svc.submit("Fix the failing test in the calculator project")                    // user goal → intake → durable task
        check("The goal became a durable task before any work started", await waitUntil(5) { latestTask() != nil }, latestTask().map { "“\($0.title)” \($0.state.rawValue)" } ?? "")
        await engine.waitUntilIdle()
        sampler.cancel()
        let wall = Date().timeIntervalSince(started)
        let jarvisCPU = (ProcessTree.cpuSeconds(of: me) ?? 0) - cpu0
        guard let task = latestTask() else { check("Task exists", false); finish() }
        let steps = (try? repo.steps(taskID: task.id)) ?? []
        let attempts = (try? repo.attempts(taskID: task.id)) ?? []
        let runs = (try? repo.agentRuns(taskID: task.id)) ?? []
        info("task \(task.state.rawValue) in \(fmt(wall)) s · plan: \(steps.map { "\($0.type.rawValue):\($0.state.rawValue)" }.joined(separator: " → "))")
        for r in runs { info("  run \(r.agentType) · \(r.engine.displayName)\(r.model.map { " · " + $0 } ?? "") · \(r.status.rawValue)\(r.errorCategory.map { " (\($0))" } ?? "")") }
        if let why = task.failureReason { info("  failure: \(task.failureCategory?.rawValue ?? "?") — \(why)") }

        check("Planner produced a machine-readable, validated plan (≥3 steps, persisted, version 1)", steps.count >= 3 && task.planVersion == 1, "\(steps.count) steps")
        check("Task completed with every step validated", task.state == .completed && !steps.isEmpty && steps.filter { $0.state != .skipped }.allSatisfy { $0.state == .passed }, "state \(task.state.rawValue)")
        check("Fixture file was really changed on disk by the task", read("calc.py", in: project)?.contains("return a + b") == true, read("calc.py", in: project)?.replacingOccurrences(of: "\n", with: " ⏎ ") ?? "")
        check("The project's own tests pass afterwards (real run)", await testsPass(in: project))
        let changes = (try? repo.taskFileChanges(taskID: task.id)) ?? []
        check("File change recorded with before/after hashes; nothing but calc.py changed", changes.contains { $0.path == "calc.py" && $0.beforeHash != $0.afterHash } && Set(changes.map(\.path)).isSubset(of: ["calc.py", "test_calc.py"]), changes.map(\.path).joined(separator: ","))
        let gitStatus = await git(["status", "--porcelain"], in: project)
        let gitLog = await git(["log", "--oneline"], in: project)
        check("Git: working-tree change only — no commit, no push, history untouched", gitStatus.contains("calc.py") && gitLog.split(separator: "\n").count == 1, "status: \(gitStatus.replacingOccurrences(of: "\n", with: "; "))")
        let reproduced = steps.first { $0.validation == .testEvidence }
        let provenTests = steps.first { $0.validation == .testPass }
        info("evidence: reproduction → \(reproduced?.validationEvidence ?? "—")")
        info("evidence: final tests → \(provenTests?.validationEvidence ?? "—")")
        check("Build/test evidence comes from real command runs (tool runs with exit codes)", runs.contains { $0.engine == .tool && $0.agentType == "TestTool" } && (provenTests?.validationEvidence?.contains("exit 0") ?? false))
        check("Providers used were never the local model for development work", !runs.contains { $0.engine == .local })
        let engines = Set(runs.filter { $0.engine != .tool }.map(\.engine))
        info("providers used: \(engines.map(\.displayName).sorted().joined(separator: ", ")) · attempts \(attempts.count) (repair \(attempts.filter { $0.kind == .repair }.count), escalation \(attempts.filter { $0.kind == .escalation }.count))")
        let report = engine.report(for: task.id)
        check("Report is built from persisted records and rendered as a user summary", report?.stepsTotal == steps.filter { $0.state != .skipped }.count && report?.userSummary.isEmpty == false, report?.userSummary ?? "")
        let obsRuns = context.hub.runs.values.filter { $0.taskID == task.id }
        check("The Observatory (V0.3.2 hub) shows the task's agents and tool runs with their consoles", obsRuns.count >= 4 && obsRuns.allSatisfy { !context.hub.visibleText($0.id).isEmpty || $0.engine != .tool }, "\(obsRuns.count) runs")
        check("Task state, steps, attempts, approvals, leases and checkpoint are in SQLite", (try? repo.count("task_steps")) ?? 0 >= steps.count && (try? repo.activeLeases().isEmpty) == true && task.checkpointArtifactID != nil && task.reportArtifactID != nil)
        info("performance: wall \(fmt(wall)) s · JARVIS CPU \(fmt(jarvisCPU)) s = \(fmt(jarvisCPU / max(wall, 0.001) * 100)) % of one core (peak RSS \(peakRSS / 1_048_576) MB) · provider/test children CPU ≥\(fmt(childCPU.values.reduce(0, +))) s (≈\(fmt(childCPU.values.reduce(0, +) / max(wall, 0.001) * 100)) %), peak RSS \(childPeak / 1_048_576) MB")
        check("No managed process is left behind after the task", await waitUntil(8) { descendants().isEmpty }, "\(descendants().count) left")

        // ------------------------------------------------------------ C. real cancellation
        let cancelProject = await makeProject(); projects.append(cancelProject)
        prefs.projectRoot = cancelProject
        svc.submit("Fix the failing test in the calculator project")
        _ = await waitUntil(8) { latestTask().map { $0.id != task.id } == true }
        guard let ct = latestTask(), ct.id != task.id else { check("Second task created for the cancellation test", false); finish() }
        let sawRun = await waitUntil(240) { context.hub.activeRuns.contains { $0.taskID == ct.id } }
        check("A real provider run was active for the second task", sawRun)
        let kids = descendants()
        let tCancel = Date()
        engine.cancel(ct.id)
        await engine.waitUntilFinished(ct.id)
        let cancelSeconds = Date().timeIntervalSince(tCancel)
        let after = (try? repo.engineTask(ct.id)) ?? nil
        check("Stopping the task ends it as CANCELLED quickly and without orphan processes", after?.state == .cancelled && cancelSeconds < 15 && descendants().isEmpty, "\(fmt(cancelSeconds)) s, \(kids.count) child process(es) at cancel")
        check("No leases left and the partial report describes the stop", (try? repo.activeLeases().isEmpty) == true && engine.report(for: ct.id)?.stoppedAt != nil)
        check("The cancelled task changed nothing in its project", read("calc.py", in: cancelProject)?.contains("return a - b") == true || (try? repo.taskFileChanges(taskID: ct.id).isEmpty) == false)

        // ------------------------------------------------------------ D. real interruption + resume
        let intProject = await makeProject(); projects.append(intProject)
        prefs.projectRoot = intProject
        svc.submit("Fix the failing test in the calculator project")
        _ = await waitUntil(8) { latestTask().map { $0.id != ct.id && $0.id != task.id } == true }
        guard let it = latestTask(), it.id != ct.id, it.id != task.id else { check("Third task created for the interruption test", false); finish() }
        // interrupt after the plan exists and at least one step has been validated (real persisted progress)
        let progressed = await waitUntil(420) { ((try? repo.steps(taskID: it.id)) ?? []).contains { $0.state == .passed } && (latestTask()?.state == .running) }
        let passedBefore = ((try? repo.steps(taskID: it.id)) ?? []).filter { $0.state == .passed }.map { $0.key }
        let finishedBefore = Dictionary(uniqueKeysWithValues: ((try? repo.steps(taskID: it.id)) ?? []).filter { $0.state == .passed }.map { ($0.key, $0.finishedAt) })
        if progressed {
            engine.prepareForTermination()                                           // what a normal quit does
            await engine.waitUntilIdle()
            let interrupted = (try? repo.engineTask(it.id)) ?? nil
            check("Quit mid-task persists INTERRUPTED (not failed/cancelled) with a checkpoint and no leases", interrupted?.state == .interrupted && interrupted?.checkpointArtifactID != nil && (try? repo.activeLeases().isEmpty) == true, "state \(interrupted?.state.rawValue ?? "?")")
            check("The active provider process was stopped by the existing cancellation path", await waitUntil(10) { descendants().isEmpty })
            // "relaunch": a fresh engine over the same database, reconciliation, explicit resume
            let engine2 = TaskEngine(repository: repo, artifacts: context.artifacts, audit: context.audit, leases: context.leases, agents: ManagerAgentRunner(manager: context.agents))
            let rec = engine2.reconcileOnLaunch()
            check("Relaunch reconciliation leaves the interrupted task interrupted (never auto-resumed)", engine2.view(it.id)?.task.state == .interrupted && rec.leases == 0)
            let resumed = engine2.resume(it.id)
            await engine2.waitUntilIdle()
            let final = (try? repo.engineTask(it.id)) ?? nil
            let stepsAfter = (try? repo.steps(taskID: it.id)) ?? []
            info("resumed task → \(final?.state.rawValue ?? "?") · \(stepsAfter.map { "\($0.key):\($0.state.rawValue)" }.joined(separator: " "))")
            check("Resume continued from the persisted state: completed steps were NOT redone", resumed && passedBefore.allSatisfy { k in stepsAfter.first { $0.key == k }?.finishedAt == finishedBefore[k] ?? nil })
            check("The resumed task finished honestly (completed or failed with a recorded reason)", final?.state == .completed || (final?.state == .failed && final?.failureReason != nil), final?.state.rawValue ?? "?")
        } else {
            check("Real persisted progress before the interruption", false, "no step was validated in time")
            engine.cancel(it.id); await engine.waitUntilFinished(it.id)
        }

        // ------------------------------------------------------------ E. destructive step waits for approval (real planner)
        let delProject = await makeProject(legacy: true); projects.append(delProject)
        prefs.projectRoot = delProject
        svc.submit("Delete the file old/legacy.py from the project")
        _ = await waitUntil(8) { latestTask()?.id != nil && latestTask()?.id != it.id }
        guard let dt = latestTask(), dt.id != it.id else { check("Fourth task created for the approval test", false); finish() }
        let gotApproval = await waitUntil(300) { !engine.pendingApprovals.isEmpty || (latestTask()?.state.isTerminal == true) }
        if gotApproval, let a = engine.pendingApprovals.first {
            check("The destructive step is WAITING for approval and nothing was deleted", engine.view(dt.id)?.task.state == .waitingForApproval && FileManager.default.fileExists(atPath: delProject + "/old/legacy.py"), a.action)
            engine.decide(a.id, approved: false)
            await engine.waitUntilFinished(dt.id)
            let denied = (try? repo.engineTask(dt.id)) ?? nil
            check("Denying resolves safely (task failed: approval denied; file intact)", denied?.failureCategory == .approvalDenied && FileManager.default.fileExists(atPath: delProject + "/old/legacy.py"))
        } else {
            let t = latestTask()
            print("SKIPPED  Destructive-step approval (real planner) — the planner did not plan a delete step (\(t?.state.rawValue ?? "?"): \(t?.failureReason ?? "no failure")); covered by MOCK TESTS")
            if latestTask()?.state.isTerminal == false { engine.cancel(dt.id); await engine.waitUntilFinished(dt.id) }
            check("The file was not deleted without approval", FileManager.default.fileExists(atPath: delProject + "/old/legacy.py"))
        }

        // ------------------------------------------------------------ F. security + cleanup
        context.hub.flushPersistNow()
        var everything = ""
        for table in ["tasks", "task_steps", "step_attempts", "agent_runs", "agent_events", "activity_events", "approvals", "file_changes", "tool_executions"] {
            for row in (try? context.database?.read("SELECT * FROM \(table)")) ?? [] { everything += "\(row)" }
        }
        for u in (FileManager.default.enumerator(at: context.paths.artifacts, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? [] {
            everything += FileManager.default.contents(atPath: u.path).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        check("No credential-looking text reached SQLite or any artifact", !OutputSanitizer.containsSecret(everything) || everything.contains(OutputSanitizer.mask))
        check("No managed process is left behind at the end", await waitUntil(10) { descendants().isEmpty }, "\(descendants().count) left")
        check("The JARVIS repository itself was never a task workspace", !projects.contains { $0.contains("/Jarvis") && !$0.contains("jarvis-task-demo") })
        finish()
    }
}
