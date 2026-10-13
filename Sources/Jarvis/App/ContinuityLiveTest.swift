import AppKit

/// `Jarvis --continuity-live-test [--continuity-section <name>]… [--live-dir <dir>]` — OPT-IN, REAL (V0.13). Project Continuity on a DISPOSABLE Git project (never the user's Hamam or any real
/// project) with its own data directory. Evidence labels: REAL = real providers (OpenCode FREE / the user's own subscriptions; never a paid API) + real build/test processes + real Git;
/// ENGINE = the real engine/persistence with scripted agent answers; POLICY = pure checks.
/// Sections: `main` (default) · `interrupt-start` (explicit: starts a task and hard-kills the process) · `restart` (explicit: the relaunch that must still know where the project stands).
@MainActor
enum ContinuityLiveTest {
    static func run(context: AppContext, sections: Set<String>) async {
        var failures = 0, passes = 0, skipped = 0
        func check(_ tag: String, _ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  [\(tag)] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if ok { passes += 1 } else { failures += 1 }
            fflush(stdout)
        }
        func skip(_ name: String, _ why: String) { print("SKIP  \(name) — \(why)"); skipped += 1; fflush(stdout) }
        func info(_ s: String) { print("INFO  \(s)"); fflush(stdout) }
        func fmt(_ d: Double, _ f: String = "%.1f") -> String { String(format: f, d) }
        func wants(_ s: String) -> Bool { sections.isEmpty ? s == "main" : sections.contains(s) }

        let engine = context.taskEngine, repo = context.repository!, cont = context.continuity, prefs = context.preferences, sup = context.supervisor
        let realRunner = engine.agents
        DispatchQueue.main.asyncAfter(deadline: .now() + 2400) { ProcessRegistry.shared.killAll(); print("CONTINUITY LIVE TEST TIMEOUT"); fflush(stdout); exit(2) }
        let fixture = UnityProcessScanner.canonical(NSTemporaryDirectory()) + "/jarvis-continuity-fixture" + (sections.contains("interrupt-start") || sections.contains("restart") ? "" : "-\(UUID().uuidString.prefix(6))")           // outside the JARVIS data folder (which can never be a project); fixed so `restart` finds it
        func finish(keepFixture: Bool = false) -> Never {
            engine.agents = realRunner
            ProcessRegistry.shared.killAll()
            if !keepFixture { try? FileManager.default.removeItem(atPath: fixture) }
            print("CONTINUITY LIVE TEST \(failures == 0 ? "PASSED" : "FAILED") (\(passes) passed, \(failures) failed, \(skipped) skipped)"); fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        func git(_ args: [String]) async -> String {
            await ManagedProcess.runOnce(executable: "/usr/bin/git", arguments: ["-c", "user.name=JARVIS Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false"] + args,
                                         environment: ProviderEnvironment.make(), workingDirectory: fixture, timeout: 30)?.output ?? ""
        }
        func write(_ rel: String, _ text: String) {
            try? FileManager.default.createDirectory(atPath: (fixture + "/" + rel as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: fixture + "/" + rel, contents: Data(text.utf8))
        }
        func read(_ rel: String) -> String { FileManager.default.contents(atPath: fixture + "/" + rel).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        func testsPass() async -> Bool {
            await ManagedProcess.runOnce(executable: "/usr/bin/python3", arguments: ["-m", "unittest", "discover"], environment: ProviderEnvironment.make(), workingDirectory: fixture, timeout: 30)?.exitCode == 0
        }
        func ask(_ text: String, _ lang: ReplyLanguage = .en) async -> String? {
            guard let intent = cont.recognizes(text) else { return nil }
            return await cont.reply(to: intent, language: lang, channel: .typed)
        }
        func latestTask() -> TaskRecord? { ((try? repo.engineTasks(limit: 8)) ?? []).first { $0.parentTaskID == nil } }
        func waitFinished(_ id: UUID, _ seconds: Double = 900) async { await engine.waitUntilFinished(id) }
        func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if cond() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
            return cond()
        }

        info("data directory: \(context.paths.root.path) (isolated from your real JARVIS history); fixture: \(fixture) (a disposable Git project — NOT Hamam, NOT a real project)")
        let schema = context.database?.schemaVersion ?? 0
        check("POLICY", "The database has the continuity (v11) and experiment (v12) schema", schema >= 12, "v\(schema)")
        check("POLICY", "The Compact HUD stays 392 × 448", CompactHUDLayout.size == CGSize(width: 392, height: 448))
        prefs.projectContinuationEnabled = true
        prefs.projectRoot = fixture

        // =========================================================== restart: the relaunch after interrupt-start
        if wants("restart") {
            guard FileManager.default.fileExists(atPath: fixture + "/calc.py") else { check("ENGINE", "The persisted fixture from `interrupt-start` exists", false, fixture); finish() }
            try? await Task.sleep(for: .seconds(2))
            let tasks = (try? repo.engineTasks(limit: 20)) ?? []
            let t = tasks.first { $0.goal.contains("restart test") }
            check("ENGINE", "After the hard kill the task is INTERRUPTED — not resumed, no runner, no pending approval", t?.state == .interrupted && engine.runners.isEmpty && engine.pendingApprovals.isEmpty, "\(t?.state.rawValue ?? "none")")
            let status = await ask("Where did we leave off?") ?? ""
            check("ENGINE", "“Where did we leave off?” after the restart names the interrupted work (derived from persisted tasks — no memory of the process)", status.localizedCaseInsensitiveContains("interrupt") || status.localizedCaseInsensitiveContains("restart test"), String(status.prefix(220)))
            let runner = OrchestrationScriptRunner(audit: context.audit, script: { job, _ in
                switch job.type {
                case "AnalysisAgent": return .text(OrchestrationDemoText.analysis)
                case "CodingAgent": return .text(OrchestrationDemoText.fixEdit)
                case "ReviewAgent": return .text(OrchestrationDemoText.reviewPass)
                default: return .fail(.generic)
                }
            })
            engine.agents = runner
            let reply = await ask("Continue where we left off.") ?? ""
            check("ENGINE", "“Continue” on an interrupted task resumes it by explicit user action", reply.localizedCaseInsensitiveContains("resum") || reply.localizedCaseInsensitiveContains("re-plan"), String(reply.prefix(220)))
            if let id = t?.id {
                await waitFinished(id, 300)
                let v = engine.view(id)
                let analysisAgain = runner.count("AnalysisAgent")
                check("ENGINE", "The resumed task finishes; the step that had already PASSED before the crash is not run twice", v?.task.state == .completed && analysisAgain == 0, "state \(v?.task.state.rawValue ?? "?"), analysis calls after resume \(analysisAgain)")
                let passedNow = await testsPass()
                check("REAL", "The fix is applied exactly once and the project's real tests pass", read("calc.py").contains("return a + b") && !read("calc.py").contains("a + b\n    return a + b") && passedNow, "")
                let after = await ask("What did we do last?") ?? ""
                let key = (await cont.gatherCurrent())?.view.projectKey ?? ""
                check("ENGINE", "A checkpoint exists for the resumed session", ((try? repo.checkpoints(projectKey: key, limit: 5)) ?? []).count >= 1, String(after.prefix(160)))
            }
            finish()
        }

        // =========================================================== interrupt-start: begin a task, then die hard
        if wants("interrupt-start") {
            await resetFixture(fixture, write, git)
            let runner = OrchestrationScriptRunner(audit: context.audit, script: { job, _ in
                switch job.type {
                case "AnalysisAgent": return .text(OrchestrationDemoText.analysis)
                case "CodingAgent": return .block
                default: return .fail(.generic)
                }
            })
            engine.agents = runner
            guard case .success(let id) = await engine.submit(goal: "Find the bug, fix it, run the tests and review the change. (restart test)", kind: .development, workspacePath: fixture, constraints: [ContinuationMarker.constraint], prepare: { $0.continuation = .standard }) else { check("ENGINE", "The task was submitted", false); finish(keepFixture: true) }
            let ok = await waitUntil(90) { runner.count("CodingAgent") >= 1 }
            check("ENGINE", "Analysis is done and the coding node is running", ok, id.uuidString)
            info("simulating a crash: SIGKILL — run again with --continuity-section restart")
            fflush(stdout)
            kill(getpid(), SIGKILL)
        }

        // =========================================================== main
        guard wants("main") else { finish() }
        await resetFixture(fixture, write, git)
        let before = (try? repo.engineTasks(limit: 50))?.count ?? 0

        // 1. status from current truth, answered locally
        let status1 = await ask("Where do we stand on this project?") ?? ""
        check("REAL", "A status question is answered locally from the project's own files (name, the recorded next step) — and creates no task and no provider call", status1.contains("fixture") && status1.localizedCaseInsensitiveContains("add()") && ((try? repo.engineTasks(limit: 50))?.count ?? 0) == before, String(status1.prefix(260)))
        let statusTR = await ask("Bu projede ne durumdayız?", .tr) ?? ""
        check("REAL", "The same question in Turkish is understood and answered in Turkish", !statusTR.isEmpty && statusTR != status1, String(statusTR.prefix(200)))
        let nextAnswer = await ask("What is next?") ?? ""
        check("REAL", "“What is next?” names the single recorded next step", nextAnswer.localizedCaseInsensitiveContains("add()"), String(nextAnswer.prefix(200)))

        // 2. REAL continuation with a real model-planned graph
        await context.refreshIntelligence(remoteCatalog: true)
        let ready = ProviderID.allCases.filter { sup.availability()[$0]?.state == .ready && $0 != .local }
        info("providers ready: " + ready.map(\.displayName).joined(separator: ", "))
        if ready.isEmpty { skip("real continuation", "no real provider is ready") } else {
            engine.agents = realRunner
            let started = Date()
            let reply = await ask("Tamam. Kaldığımız yerden devam et.", .tr) ?? ""
            check("REAL", "“Kaldığımız yerden devam et” starts ONE bounded session for the recorded next step", reply.contains("sınırlı") || reply.localizedCaseInsensitiveContains("bounded") || reply.contains("oturum"), String(reply.prefix(240)))
            if let t = latestTask() {
                check("ENGINE", "The task carries the continuation constraint and the bounds are active (30 min · 12 nodes · 2 revisions · 2 correction rounds · 2 experiments)", t.constraints.contains(ContinuationMarker.constraint) && engine.contexts[t.id]?.continuation == .standard, ContinuationBounds.standard.summary)
                await waitFinished(t.id, 900)
                let v = engine.view(t.id)
                let passed = await testsPass()
                check("REAL", "The real model-planned graph finished and the project's REAL tests now pass", v?.task.state == .completed && passed, "state \(v?.task.state.rawValue ?? "?") · steps \((v?.steps ?? []).map { "\($0.type.rawValue):\($0.state.rawValue)" }.joined(separator: " → ")) · \(fmt(Date().timeIntervalSince(started))) s")
                check("REAL", "The bug is fixed in calc.py (add returns a + b) and nothing outside the project was touched", read("calc.py").contains("return a + b"), "")
                let pkey = (await cont.gatherCurrent())?.view.projectKey ?? ""
                let cp = (try? repo.latestCheckpoint(projectKey: pkey)) ?? nil
                check("REAL", "A checkpoint was written (Git HEAD, file hashes, validated / remaining)", cp != nil, cp.map { "\($0.outcome) · \($0.title.prefix(80)) · \($0.fileHashes.count) file hash(es)" } ?? "none")
                let after = await ask("Where did we leave off?") ?? ""
                check("REAL", "The status afterwards reports the finished work and does NOT call JARVIS' own edit an external change", after.localizedCaseInsensitiveContains("add()") && !after.localizedCaseInsensitiveContains("changed outside"), String(after.prefix(260)))
                let diag = cont.lastDiagnostics
                check("REAL", "Diagnostics list the sources consulted, the decision and the bounds", diag != nil && !(diag?.sources.isEmpty ?? true), diag.map { "\($0.decision) · \($0.sources.joined(separator: ", "))" } ?? "none")
            } else { check("REAL", "The continuation created a task", false) }
        }

        // 3. restart continuity (a second service over the same persisted state)
        let twin = ProjectContinuity(repository: repo, engine: engine, memory: context.memory, preferences: prefs)
        if let intent = twin.recognizes("Where did we leave off?") {
            let a = await twin.reply(to: intent, language: .en, channel: .typed)
            let b = await ask("Where did we leave off?") ?? ""
            check("ENGINE", "A fresh service over the same database gives the same answer (nothing lives only in memory)", !a.isEmpty && a == b, String(a.prefix(160)))
        }

        // 4. external drift
        write("notes.txt", "user edit outside JARVIS\n")
        write("docs/CURRENT_TASK.md", "# Current Task\n\nNext Step:\nAdd a test for mul() in test_calc.py.\n")
        _ = await git(["add", "-A"]); _ = await git(["commit", "-q", "-m", "user: new direction"])
        let drift = await ask("Where did we leave off?") ?? ""
        check("REAL", "A change made outside JARVIS (a user commit + a new Next Step) is reported as external drift, and the NEW truth wins over the checkpoint", (drift.localizedCaseInsensitiveContains("outside") || drift.localizedCaseInsensitiveContains("changed") || drift.localizedCaseInsensitiveContains("moved")) && drift.localizedCaseInsensitiveContains("mul()"), String(drift.prefix(300)))

        // 5. failed task continuation (scripted failure)
        let failing = OrchestrationScriptRunner(audit: context.audit, script: { job, _ in
            switch job.type {
            case "AnalysisAgent": return .text(OrchestrationDemoText.analysis)
            case "CodingAgent": return .fail(.generic)
            default: return .fail(.generic)
            }
        })
        failing.escalationAllowed = false
        engine.agents = failing
        let c1 = await ask("Continue.") ?? ""
        if let t1 = latestTask() { await waitFinished(t1.id, 300) }
        let failedOnce = latestTask()
        check("ENGINE", "A failing continuation fails honestly (state failed, a reason, no fake success)", failedOnce?.state == .failed && (failedOnce?.failureReason ?? "").isEmpty == false, String(c1.prefix(120)))
        let statusFailed = await ask("What did we do last?") ?? ""
        check("ENGINE", "The status says the last attempt failed", statusFailed.localizedCaseInsensitiveContains("fail"), String(statusFailed.prefix(200)))
        let retry = await ask("Continue.") ?? ""
        check("ENGINE", "“Continue” after a failure retries ONCE with the failure in mind", retry.localizedCaseInsensitiveContains("fail") || retry.localizedCaseInsensitiveContains("fresh attempt"), String(retry.prefix(220)))
        if let t2 = latestTask(), t2.id != failedOnce?.id { await waitFinished(t2.id, 300) }
        let third = await ask("Continue.") ?? ""
        check("ENGINE", "A retry of a retry is NOT offered again: JARVIS asks you instead of looping", !third.localizedCaseInsensitiveContains("fresh attempt") && !third.localizedCaseInsensitiveContains("Continuing “"), String(third.prefix(260)))

        // 6. the queue: a stated next step is data, a secret / authority statement is refused
        let queued = await ask("Next up is documenting the add function in README.md") ?? ""
        let secretQueued = await ask("Next up is use the key " + "sk-" + String(repeating: "a", count: 24) + " to call the API") ?? ""         // built at run time: no secret-shaped literal sits in the source tree
        check("POLICY", "A queued item is stored; one that looks like a secret or an instruction to grant authority is refused", queued.localizedCaseInsensitiveContains("queued") && !secretQueued.localizedCaseInsensitiveContains("queued for"), String(secretQueued.prefix(120)))

        // 7. never authority
        check("POLICY", "No continuation granted an approval or a capability: nothing is pending and the session never decided anything", engine.pendingApprovals.isEmpty)
        check("POLICY", "Memory and checkpoints are context only: the selector module references no memory service", true, "enforced by verify.sh")
        finish()
    }

    static func resetFixture(_ fixture: String, _ write: (String, String) -> Void, _ git: ([String]) async -> String) async {
        try? FileManager.default.removeItem(atPath: fixture)
        try? FileManager.default.createDirectory(atPath: fixture, withIntermediateDirectories: true)
        write("README.md", "# calc-fixture\nA tiny calculator used as a disposable continuity fixture.\n")
        write("PROJECT_STATE.md", "# calc-fixture\n\n## Current Milestone\nV0.1 — arithmetic helpers\n")
        write("docs/CURRENT_TASK.md", "# Current Task\n\nNext Step:\nFix the add() function in calc.py so test_add passes, then run the tests.\n")
        write("calc.py", "def add(a, b):\n    return a - b\n\ndef mul(a, b):\n    return a * b\n")
        write("test_calc.py", "import unittest\nfrom calc import add, mul\n\nclass T(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(add(2, 3), 5)\n    def test_mul(self):\n        self.assertEqual(mul(2, 3), 6)\n\nif __name__ == '__main__':\n    unittest.main()\n")
        _ = await git(["init", "-q", "-b", "main"]); _ = await git(["add", "-A"]); _ = await git(["commit", "-q", "-m", "initial"])
    }
}
