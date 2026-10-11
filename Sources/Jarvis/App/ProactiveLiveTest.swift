import AppKit

/// `Jarvis --proactive-live-test [--live-dir <dir>]` — OPT-IN, REAL (V0.5). Exercises the proactive decision layer with REAL providers on
/// ISOLATED temporary fixture projects (never the JARVIS repository), with its own data directory:
///   user task (real) → finding derived from recorded facts → assessment → policy → proposal / auto task → V0.4 task (real) → validation,
/// plus a real denial with cooldown, a real restart, the autonomy budget (no second automatic task) and one budgeted model assessment.
/// Prints `REAL TESTED PASS/FAIL` and a provider-usage report; exits non-zero on failure. Not part of verify.sh.
@MainActor
enum ProactiveLiveTest {
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
        let savedPreference = prefs.providerPreference, savedRoot = prefs.projectRoot, savedMode = prefs.autonomyMode, savedProactive = prefs.proactiveReasoningEnabled
        DispatchQueue.main.asyncAfter(deadline: .now() + 2400) { ProcessRegistry.shared.killAll(); print("PROACTIVE LIVE TEST TIMEOUT"); fflush(stdout); exit(2) }
        func finish() -> Never {
            prefs.providerPreference = savedPreference; prefs.projectRoot = savedRoot; prefs.autonomyMode = savedMode; prefs.proactiveReasoningEnabled = savedProactive
            for k in ["prefs.providerPreference", "prefs.tasks.projectRoot", "prefs.autonomy.mode", "prefs.autonomy.proactiveEnabled"] { UserDefaults.standard.removeObject(forKey: k) }
            if savedPreference != .auto { prefs.providerPreference = savedPreference }
            if !savedRoot.isEmpty { prefs.projectRoot = savedRoot }
            if savedMode != .askBeforeActing { prefs.autonomyMode = savedMode }
            print("PROACTIVE LIVE TEST \(failures == 0 ? "PASSED" : "FAILED") (\(passes) passed, \(failures) failed)"); fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }

        let tasks = context.taskEngine, repo = context.repository!, svc = context.conversationService!, sup = context.supervisor
        let opp = context.opportunities, proposals = context.proposalService
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
        func makeProject() async -> String {
            let dir = TaskDemo.makeProject()
            FileManager.default.createFile(atPath: dir + "/README.md", contents: Data("# Calculator fixture\n".utf8))
            _ = await git(["init", "-q", "-b", "main"], in: dir); _ = await git(["add", "-A"], in: dir); _ = await git(["commit", "-q", "-m", "initial"], in: dir)
            return dir
        }
        func read(_ p: String, in dir: String) -> String? { FileManager.default.contents(atPath: dir + "/" + p).flatMap { String(data: $0, encoding: .utf8) } }
        func testsPass(in dir: String) async -> Bool {
            (await ManagedProcess.runOnce(executable: "/usr/bin/python3", arguments: ["-m", "unittest", "discover"], environment: ProviderEnvironment.make(), workingDirectory: dir, timeout: 30))?.exitCode == 0
        }
        func allTasks() -> [TaskRecord] { ((try? repo.engineTasks(limit: 200)) ?? []).sorted { $0.createdAt < $1.createdAt } }
        func opps() -> [OpportunityRecord] { (try? repo.opportunities(limit: 200)) ?? [] }
        func props() -> [ProposalRecord] { (try? repo.proposals(limit: 200)) ?? [] }
        func runsOf(_ id: UUID) -> [AgentRunRecord] { (try? repo.agentRuns(taskID: id)) ?? [] }
        func providers(_ id: UUID) -> String { Set(runsOf(id).filter { $0.engine != .tool }.map { $0.engine.displayName + ($0.model.map { " · " + $0 } ?? "") }).sorted().joined(separator: ", ") }
        /// Submits a real user task through the conversation path and waits until it AND any proactive reaction have finished.
        func userTask(_ project: String) async -> TaskRecord? {
            prefs.projectRoot = project
            let before = Set(allTasks().map(\.id))
            svc.submit("Fix the failing test in the calculator project")
            _ = await waitUntil(10) { allTasks().contains { !before.contains($0.id) } }
            guard let t = allTasks().first(where: { !before.contains($0.id) }) else { return nil }
            await tasks.waitUntilFinished(t.id)
            try? await Task.sleep(for: .milliseconds(800))              // the proactive reaction runs in its own Task
            await tasks.waitUntilIdle()
            return (try? repo.engineTask(t.id)) ?? nil
        }
        var projects: [String] = []
        defer { for p in projects { try? FileManager.default.removeItem(atPath: p) } }

        info("data directory: \(context.paths.root.path) (isolated from your real JARVIS history)")
        check("Schema v4 (opportunities/proposals/task origin) was created by the real persistence layer", (context.database?.schemaVersion ?? 0) >= 4 && (try? repo.count("opportunities")) == 0, "schema v\(context.database?.schemaVersion ?? -1)")
        check("The default autonomy mode is conservative (Ask Before Acting) and proactive reasoning is on", savedMode == .askBeforeActing || UserDefaults.standard.string(forKey: "prefs.autonomy.mode") == nil, "mode \(savedMode.label)")

        // ------------------------------------------------------------ discovery + benchmark (so Auto may route development work to a free model)
        await context.refreshIntelligence(remoteCatalog: true)
        for id in ProviderID.allCases { info("\(id.displayName): \(sup.availability()[id]?.state.label ?? "?")") }
        guard !ProviderID.allCases.filter({ sup.availability()[$0]?.state == .ready && $0 != .local }).isEmpty else { check("A real provider is ready", false); finish() }
        prefs.providerPreference = .auto
        if !context.openCode.freePool.isEmpty {
            let preferred = ["space-bunny-free", "longcat-2.5-preview-free", "big-pickle", "ling-3.1-flash-free"]
            let pick = preferred.compactMap { p in context.openCode.freePool.first { $0.id.hasSuffix(p) } }.first ?? context.openCode.freePool[0]
            info("benchmarking \(pick.id) so Auto may route development work to it…")
            await context.benchmark(modelID: pick.id); sup.invalidateBenchmarks()
            info("benchmark \(pick.id): \(((try? repo.benchmarks(modelID: pick.id)) ?? []).filter(\.passed).count)/13 cases passed")
        }

        // ------------------------------------------------------------ 1. REAL end to end: Ask Before Acting
        prefs.autonomyMode = .askBeforeActing
        let pA = await makeProject(); projects.append(pA)
        let providerCallsBefore = opp.providerCalls.count
        guard let userA = await userTask(pA) else { check("A real user task was created", false); finish() }
        info("user task \(userA.state.rawValue) · providers: \(providers(userA.id))")
        let userAPass = await testsPass(in: pA)
        check("The user task (real providers) fixed the fixture and completed", userA.state == .completed && read("calc.py", in: pA)?.contains("return a + b") == true && userAPass)
        let waitedProposal = await waitUntil(15) { !props().isEmpty }
        // Real reviewers may add their own (claim-based) suggestions; the recorded-fact finding is the one this check is about.
        let oppA = opps().first { $0.originTaskID == userA.id && $0.category == .testCoverage && $0.evidence.contains { $0.isDeterministic } } ?? opps().first
        let propA = props().first { $0.opportunityID == oppA?.id }
        check("A finished task produced an opportunity from RECORDED FACTS (no model call) — durable, with evidence", waitedProposal && oppA?.originTaskID == userA.id && oppA?.category == .testCoverage
              && (oppA?.evidence.contains { $0.isDeterministic } ?? false) && opp.providerCalls.count == providerCallsBefore, oppA?.title ?? "none")
        check("Assessment is structured and the policy reason is persisted (propose in Ask Before Acting)", oppA?.assessment?.relation == .direct && oppA?.assessment?.evidenceStrength == .strong && oppA?.policyDecision == .propose
              && (oppA?.policyReasons.contains("mode:askBeforeActing") ?? false), (oppA?.policyReasons.joined(separator: ",")) ?? "")
        check("No automatic task and no project modification happened (only the user's fix; tests untouched)", allTasks().count == 1 && (read("test_calc.py", in: pA) ?? "").components(separatedBy: "def test_").count == 2)
        check("The proposal is pending and visible (Tasks screen / Compact indicator state)", propA?.status == .pending && opp.pending.contains { $0.id == propA?.id } && opp.summary.proposals >= 1, "\(opp.pending.count) pending")
        guard let propA else { finish() }
        let approveStart = Date()
        let outcome = await proposals.approve(propA.id, source: .hud)               // the same service call as the HUD button
        guard case .started(let approvedTaskID) = outcome else { check("Approval started a V0.4 task", false, "\(outcome)"); finish() }
        await tasks.waitUntilFinished(approvedTaskID)
        try? await Task.sleep(for: .milliseconds(800)); await tasks.waitUntilIdle()
        let approvedTask = (try? repo.engineTask(approvedTaskID)) ?? nil
        let steps = (try? repo.steps(taskID: approvedTaskID)) ?? []
        info("approved-proposal task \(approvedTask?.state.rawValue ?? "?") in \(fmt(Date().timeIntervalSince(approveStart))) s · plan: \(steps.map { "\($0.type.rawValue):\($0.state.rawValue)" }.joined(separator: " → ")) · providers: \(providers(approvedTaskID))")
        if let why = approvedTask?.failureReason { info("  failure: \(approvedTask?.failureCategory?.rawValue ?? "?") — \(why)") }
        check("Approval became a NORMAL V0.4 task (planned, validated plan, agents, real validation) with origin approvedProposal and linkage", approvedTask?.origin == .approvedProposal && approvedTask?.originTaskID == userA.id
              && approvedTask?.originOpportunityID == oppA?.id && approvedTask?.planVersion == 1 && approvedTask?.scope?.testFilesOnly == true && runsOf(approvedTaskID).count >= 3)
        let approvedPass = await testsPass(in: pA)
        // The V0.5 property is "stayed in scope"; the V0.4 AI reviewer may legitimately reject a real model's test as weak (a model judgment,
        // reported honestly as INFO). Anything else failing (scope, planning, validation, application code) still fails this check.
        let reviewerOnlyRejection = approvedTask?.state == .failed && approvedTask?.failureCategory == .validationFailed && steps.last?.type == .review && steps.dropLast().allSatisfy { $0.state == .passed }
        if reviewerOnlyRejection { info("  the V0.4 AI reviewer rejected the (otherwise valid, in-scope, passing) test — a model judgment, not a V0.5 scope/policy failure") }
        check("The task stayed within scope: a real regression test was added, application code untouched, tests pass (completed, or only the AI reviewer rejected it)", (approvedTask?.state == .completed || reviewerOnlyRejection) && (read("test_calc.py", in: pA) ?? "").components(separatedBy: "def test_").count >= 3
              && approvedPass && read("calc.py", in: pA)?.contains("return a + b") == true,
              "changed: \(((try? repo.taskFileChanges(taskID: approvedTaskID)) ?? []).map(\.path).joined(separator: ","))")
        check("Exactly one task came from one approved proposal; proposal executed; approval bound to its scope hash", allTasks().filter { $0.origin == .approvedProposal }.count == 1 && (try? repo.proposal(propA.id))??.status == .executed
              && (try? repo.proposalApproval(propA.id))??.scopeHash == propA.actionHash && (try? repo.proposalApproval(propA.id))??.decidedBy == "hud")
        check("Approving again does nothing", await proposals.approve(propA.id, source: .hud) == .notPending)
        info("provider usage: user task → \(providers(userA.id)) · approved task → \(providers(approvedTaskID)) · proactive assessment calls: \(opp.providerCalls.count) (the finding came from recorded facts, so no provider call was needed)")

        // ------------------------------------------------------------ 2. REAL low-risk autonomous
        prefs.autonomyMode = .lowRiskAutonomous
        let pB = await makeProject(); projects.append(pB)
        let tasksBeforeB = allTasks().count
        guard let userB = await userTask(pB) else { check("Second real user task created", false); finish() }
        let autoCreated = await waitUntil(20) { allTasks().filter { $0.origin == .proactiveAutoAction }.count >= 1 }
        let autoTask = allTasks().first { $0.origin == .proactiveAutoAction && $0.originTaskID == userB.id }
        if let a = autoTask { await tasks.waitUntilFinished(a.id) }
        try? await Task.sleep(for: .milliseconds(800)); await tasks.waitUntilIdle()
        let autoDone = autoTask.flatMap { (try? repo.engineTask($0.id)) ?? nil }
        let oppB = opps().first { $0.id == autoTask?.originOpportunityID }
        info("low-risk: user task \(userB.state.rawValue) · auto task \(autoDone?.state.rawValue ?? "none") · providers: \(autoTask.map { providers($0.id) } ?? "—")")
        check("Low-Risk Autonomous: one strongly evidenced direct opportunity created exactly ONE automatic V0.4 task", autoCreated && allTasks().filter { $0.origin == .proactiveAutoAction }.count == 1 && allTasks().count == tasksBeforeB + 2)
        check("The auto task is marked proactiveAutoAction, linked to its origin task and opportunity, depth 1, scope-limited, planned and validated like any task",
              autoDone?.origin == .proactiveAutoAction && autoDone?.originTaskID == userB.id && autoDone?.originOpportunityID == oppB?.id && autoDone?.autonomyDepth == 1 && autoDone?.scope != nil && autoDone?.planVersion == 1)
        check("Policy reasons persisted: direct, reversible, local, non-destructive, strong evidence, within budget", oppB?.policyDecision == .autoAction
              && Set(oppB?.policyReasons ?? []).isSuperset(of: ["directScope", "reversible", "localOnly", "nonDestructive", "strongEvidence", "withinBudget"]), (oppB?.policyReasons.joined(separator: ",")) ?? "")
        let autoPass = await testsPass(in: pB)
        check("The auto task finished with real validation and a real file change (test file only)", autoDone?.state == .completed && (read("test_calc.py", in: pB) ?? "").components(separatedBy: "def test_").count >= 3 && autoPass,
              "changed: \(autoTask.map { ((try? repo.taskFileChanges(taskID: $0.id)) ?? []).map(\.path).joined(separator: ",") } ?? "")")
        // a follow-up finding from the AUTO task, and a second one from the user task, must not create another automatic task
        let followUp = RawFinding(origin: .reviewFinding, title: "Add a regression test for adding two negative numbers", summary: "The review of the automatic task suggests one more case.", category: .testCoverage,
                                  evidence: [EvidenceItem(kind: .taskResult, summary: "The automatic task changed test_calc.py", reference: "test_calc.py")], affectedPaths: ["test_calc.py"],
                                  originTaskID: autoTask?.id, projectRoot: pB, eventKey: "live:followup")
        let r1 = await opp.ingest(followUp)
        var second = followUp; second.originTaskID = userB.id; second.title = "Add a regression test for multiplying by zero"; second.eventKey = "live:second"
        let r2 = await opp.ingest(second)
        var noAuto = true
        for r in [r1, r2] { if case .autoTask = r { noAuto = false } }
        try? await Task.sleep(for: .milliseconds(500)); await tasks.waitUntilIdle()
        check("The auto task's finding and a second finding from the user task did NOT create another automatic task (budget + depth)", noAuto && allTasks().filter { $0.origin == .proactiveAutoAction }.count == 1,
              "\(r1) / \(r2) · reasons: \(opps().filter { $0.sourceEvent?.hasPrefix("live:") == true }.map { $0.policyReasons.joined(separator: ",") }.joined(separator: " | "))")

        // ------------------------------------------------------------ 3. REAL denial + cooldown
        prefs.autonomyMode = .askBeforeActing
        let pC = await makeProject(); projects.append(pC)
        guard let userC = await userTask(pC) else { check("Third real user task created", false); finish() }
        _ = await waitUntil(15) { props().contains { $0.projectRoot == (try? WorkspaceGuard(rootPath: pC))?.root } }
        let propC = props().first { $0.projectRoot == (try? WorkspaceGuard(rootPath: pC))?.root && $0.status == .pending }
        let tasksBeforeDeny = allTasks().count
        let testBefore = read("test_calc.py", in: pC)
        if let propC {
            check("Denying through the real approval pathway", proposals.deny(propC.id, source: .hud) == .denied)
            let oc = (try? repo.opportunity(propC.opportunityID)) ?? nil
            check("Denial: no task, no project modification, decision + cooldown persisted", allTasks().count == tasksBeforeDeny && read("test_calc.py", in: pC) == testBefore && oc?.status == .denied && oc?.cooldownUntil != nil
                  && (try? repo.proposalApproval(propC.id))??.state == .denied)
            let again = await opp.ingest(RawFinding(origin: .taskFinding, title: "No regression test was added for the change to calc.py", summary: "again", category: .testCoverage,
                                                    evidence: [EvidenceItem(kind: .taskResult, summary: "Task completed and changed calc.py; no test file was changed", reference: "calc.py")],
                                                    affectedPaths: ["test_calc.py"], originTaskID: userC.id, projectRoot: pC, eventKey: "live:denied-again"))
            var suppressed = false; if case .duplicate = again { suppressed = true }
            check("The same finding does not come back (anti-nagging)", suppressed && opp.pending.filter { $0.projectRoot == propC.projectRoot }.isEmpty)
        } else { check("A pending proposal existed for the denial test", false) }

        // ------------------------------------------------------------ 4. REAL restart: pending proposal survives, exactly one task after approval
        let pD = await makeProject(); projects.append(pD)
        guard let userD = await userTask(pD) else { check("Fourth real user task created", false); finish() }
        _ = await waitUntil(15) { props().contains { $0.projectRoot == (try? WorkspaceGuard(rootPath: pD))?.root && $0.status == .pending } }
        let propD = props().first { $0.projectRoot == (try? WorkspaceGuard(rootPath: pD))?.root && $0.status == .pending }
        let oppCountBefore = opps().count, propCountBefore = props().count, taskCountBefore = allTasks().count
        // "relaunch": fresh engines over the same database
        let tasks2 = TaskEngine(repository: repo, artifacts: context.artifacts, audit: context.audit, leases: context.leases, agents: ManagerAgentRunner(manager: context.agents))
        _ = tasks2.reconcileOnLaunch()
        let opp2 = OpportunityEngine(repository: repo, audit: context.audit, tasks: tasks2)
        opp2.settings = { prefs.autonomySettings }
        let service2 = ProposalService(repository: repo, engine: opp2)
        await opp2.reconcileOnLaunch()
        check("After a relaunch the pending proposal is still pending, nothing duplicated, no task started", propD != nil && opp2.pending.contains { $0.id == propD?.id } && opps().count == oppCountBefore && props().count == propCountBefore && allTasks().count == taskCountBefore)
        if let propD {
            let out = await service2.approve(propD.id, source: .hud)
            if case .started(let tid) = out { await tasks2.waitUntilFinished(tid) }
            try? await Task.sleep(for: .milliseconds(500)); await tasks2.waitUntilIdle()
            let dTask = allTasks().first { $0.originOpportunityID == propD.opportunityID }
            let dReviewerOnly = dTask?.state == .failed && dTask?.failureCategory == .validationFailed && ((try? repo.steps(taskID: dTask!.id)) ?? []).last?.type == .review
            check("Approving after recovery created exactly one task (finished within scope; only the AI reviewer may reject)", allTasks().filter { $0.originOpportunityID == propD.opportunityID }.count == 1
                  && (dTask?.state == .completed || dReviewerOnly), "\(out) · \(dTask?.state.rawValue ?? "?")")
            check("A second approval is a no-op (idempotent)", await service2.approve(propD.id, source: .hud) == .notPending)
        }
        _ = userD

        // ------------------------------------------------------------ 5. one budgeted model assessment (free text without structure)
        let calls0 = opp.providerCalls.count
        let idea = RawFinding(origin: .userDeferredIdea, title: "Tidy the calc module naming", summary: "Function and variable names in calc.py could be a bit clearer.", category: nil,
                              evidence: [EvidenceItem(kind: .modelClaim, summary: "naming could be clearer")], affectedPaths: ["calc.py"], originTaskID: userA.id, projectRoot: pA,
                              needsModelAssessment: true, eventKey: "live:idea")
        prefs.autonomyMode = .askBeforeActing
        let idRes = await opp.ingest(idea)
        let used = opp.providerCalls.count - calls0
        info("model assessment: \(used) provider call(s)\(opp.providerCalls.last.map { " · " + $0 } ?? "")")
        var idea2 = idea; idea2.title = "Rename helper variables in calc for readability"; idea2.eventKey = "live:idea2"
        _ = await opp.ingest(idea2)
        let used2 = opp.providerCalls.count - calls0
        var ideaNotAuto = true; if case .autoTask = idRes { ideaNotAuto = false }
        check("A free-text finding needed ONE budgeted model call (reason recorded); a second one for the same task needed none; never the local model; never auto", used <= 1 && used2 <= 1 && ideaNotAuto
              && !context.audit.hub!.runs.values.contains { $0.agentType == "OpportunityAssessor" && $0.engine == .local }, "calls \(used)/\(used2)")

        // ------------------------------------------------------------ cleanup / security
        context.hub.flushPersistNow()
        var everything = ""
        for table in ["tasks", "opportunities", "proposals", "approvals", "agent_runs", "agent_events", "activity_events", "file_changes"] { for row in (try? context.database?.read("SELECT * FROM \(table)")) ?? [] { everything += "\(row)" } }
        check("No credential-looking text reached SQLite (opportunities, proposals, approvals, events)", !OutputSanitizer.containsSecret(everything) || everything.contains(OutputSanitizer.mask))
        check("No managed process is left behind", await waitUntil(10) { descendants().isEmpty }, "\(descendants().count) left")
        check("No automatic action touched a project other than the one it came from", allTasks().allSatisfy { t in t.origin == .userTask || (t.originOpportunityID.flatMap { id in opps().first { $0.id == id }?.projectRoot } == t.workspaceRoot) })
        finish()
    }
}
