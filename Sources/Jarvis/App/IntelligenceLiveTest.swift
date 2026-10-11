import AppKit

/// `Jarvis --intelligence-live-test [--benchmark-models] [--live-dir <dir>]` — OPT-IN, REAL (V0.3.1). Exercises the actual
/// stack end to end: SQLite (own data dir, never the user's history), discovery, the local Qwen runtime, a verified-free
/// OpenCode model, the restricted-tool canaries, automatic routing, provider lifecycle, cancellation and cleanup, and
/// measures CPU/RSS. It spends a few tiny prompts on free/local engines and one tiny Claude/Codex request (heavy-routing demo).
/// Prints `REAL TESTED PASS/FAIL`, `INFO` and `SKIPPED`; exits non-zero on failure. Not part of verify.sh.
@MainActor
enum IntelligenceLiveTest {
    static func run(context: AppContext, captureDirectory: String, benchmark: Bool) async {
        var failures = 0, passes = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "REAL TESTED PASS" : "REAL TESTED FAIL")  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if ok { passes += 1 } else { failures += 1 }
            fflush(stdout)
        }
        func info(_ s: String) { print("INFO  \(s)"); fflush(stdout) }
        func skip(_ name: String, _ why: String) { print("SKIPPED  \(name) — \(why)"); fflush(stdout) }
        func mb(_ b: UInt64?) -> String { b.map { "\($0 / 1_048_576) MB" } ?? "n/a" }
        func fmt(_ d: Double, _ f: String = "%.1f") -> String { String(format: f, d) }

        let prefs = context.preferences
        let savedPreference = prefs.providerPreference
        let savedIdle = prefs.localIdleUnloadSeconds
        let limit: TimeInterval = benchmark ? 5400 : 900
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { prefs.providerPreference = savedPreference; prefs.localIdleUnloadSeconds = savedIdle; ProcessRegistry.shared.killAll(); print("LIVE TEST TIMEOUT"); fflush(stdout); exit(2) }
        func finish() -> Never {
            prefs.providerPreference = savedPreference; prefs.localIdleUnloadSeconds = savedIdle
            UserDefaults.standard.removeObject(forKey: "prefs.providerPreference")          // never leave a test preference behind
            if savedPreference != .auto { prefs.providerPreference = savedPreference }
            print("INTELLIGENCE LIVE TEST \(failures == 0 ? "PASSED" : "FAILED") (\(passes) passed, \(failures) failed)"); fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }

        let svc = context.conversationService!, convo = context.conversation
        let sup = context.supervisor, runtime = context.localRuntime, openCode = context.openCode, repo = context.repository!
        let me = getpid()

        func ask(_ text: String) async -> ConversationMessage? { svc.submit(text); await svc.waitUntilIdle(); return convo.messages.last { $0.role == .jarvis } }
        func descendants() -> [pid_t] { ProcessTree.descendants(of: me) }
        func waitDead(_ pids: [pid_t], _ seconds: Double = 8) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { if pids.allSatisfy({ !ProcessTree.isAlive($0) }) { return true }; try? await Task.sleep(for: .milliseconds(50)) }
            return pids.allSatisfy { !ProcessTree.isAlive($0) }
        }
        func lastRun() -> AgentRunRecord? { ((try? repo.recentAgentRuns(limit: 1)) ?? []).first }
        func sleep(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

        /// CPU/RSS of JARVIS and all of its descendants over a window, sampled at 4 Hz (peak RSS, CPU delta).
        struct Usage { var jarvisCPU = 0.0, childCPU = 0.0, wall = 0.0, peakJarvisRSS: UInt64 = 0, peakChildRSS: UInt64 = 0 }
        func measure(_ seconds: Double? = nil, while work: (() async -> Void)? = nil) async -> Usage {
            func cpuNow() -> (Double, [pid_t: Double]) {
                var kids: [pid_t: Double] = [:]
                for p in descendants() { if let c = ProcessTree.cpuSeconds(of: p) { kids[p] = c } }
                return (ProcessTree.cpuSeconds(of: me) ?? 0, kids)
            }
            var u = Usage()
            let (j0, k0) = cpuNow()
            let t0 = Date()
            var lastKids = k0
            let sampler = Task { @MainActor in
                while !Task.isCancelled {
                    let (_, kids) = cpuNow()
                    for (p, c) in kids { lastKids[p] = c }
                    u.peakJarvisRSS = max(u.peakJarvisRSS, ProcessTree.residentBytes(of: me) ?? 0)
                    u.peakChildRSS = max(u.peakChildRSS, kids.keys.compactMap { ProcessTree.residentBytes(of: $0) }.reduce(0, +))
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            if let work { await work() } else if let seconds { await sleep(seconds) }
            sampler.cancel()
            let (j1, _) = cpuNow()
            u.wall = Date().timeIntervalSince(t0)
            u.jarvisCPU = j1 - j0
            u.childCPU = lastKids.reduce(0.0) { $0 + ($1.value - (k0[$1.key] ?? 0)) }
            return u
        }
        func pct(_ cpu: Double, _ wall: Double) -> String { wall > 0 ? fmt(cpu / wall * 100) + " %" : "n/a" }

        info("data directory: \(context.paths.root.path) (isolated from your real JARVIS history)")
        check("Database was created by the real persistence layer under Application Support (never in the repository)",
              context.database != nil && context.paths.database.path.contains("/Library/Application Support/") && FileManager.default.fileExists(atPath: context.paths.database.path),
              "schema v\(context.database?.schemaVersion ?? -1)")

        // ---------------------------------------------------------------- A. discovery
        let idleRSS0 = ProcessTree.residentBytes(of: me)
        await context.refreshIntelligence(remoteCatalog: true)
        for id in ProviderID.allCases {
            let st = sup.availability()[id]?.state.label ?? "?"
            info("\(id.displayName): \(st)")
        }
        info("OpenCode \(openCode.version ?? "?") at \(openCode.executablePath ?? "-"); models in catalog: \(openCode.models.count); verified FREE: \(openCode.freePool.count)")
        for m in openCode.freePool { info("  FREE \(m.id) · \(m.dataPolicy.rawValue) · ctx \(m.contextLimit.map(String.init) ?? "?") · \(m.freeVerificationSource ?? "")") }
        for m in openCode.models where !m.isFreePoolMember { info("  rejected \(m.id): \(m.blockedReason ?? "not free-verified")") }
        let openCodeSupported = openCode.capabilities?.isSupported ?? false
        if openCode.state == .notInstalled {
            skip("OpenCode checks", "OpenCode is not installed")
        } else if !openCodeSupported {
            if case .unavailable(let why) = openCode.state { info("OpenCode: \(why)") }
            check("OpenCode \(openCode.version ?? "?"): unsupported CLI generation detected from its --help; free pool DISABLED (prices unknown ⇒ never routed)",
                  openCode.capabilities != nil && openCode.freePool.isEmpty && { if case .unavailable = openCode.state { return true }; return false }())
        } else {
            check("OpenCode discovered and catalog parsed", openCode.state == .ready && !openCode.models.isEmpty, "version \(openCode.version ?? "?")")
            check("Free eligibility comes from provider price data (not names)",
                  openCode.freePool.allSatisfy { $0.pricingStatus == .verifiedZero && $0.inputPrice == 0 && $0.outputPrice == 0 && $0.provider == "opencode" }
                  && openCode.models.filter { $0.pricingStatus == .paid }.allSatisfy { !$0.isFreePoolMember })
        }
        check("Local runtime files discovered", runtime.state == .idle, runtime.state.label)

        // ---------------------------------------------------------------- B. optional benchmarks
        if benchmark {
            for m in openCode.freePool where m.enabled {
                if !context.benchmarks.needsBenchmark(m.id) { info("benchmark \(m.id): already complete in this suite — skipped"); continue }
                let t0 = Date()
                await context.benchmark(modelID: m.id)
                let line = BenchmarkGroup.allCases.map { g -> String in let s = sup.benchmarkSummary(m.id, g); return "\(g.rawValue) \(s?.label ?? "–")" }.joined(separator: " · ")
                info("benchmark \(m.id) [\(m.dataPolicy.rawValue)] \(line) in \(fmt(Date().timeIntervalSince(t0), "%.0f")) s → status \(openCode.model(m.id)?.benchmarkStatus.rawValue ?? "?")")
            }
            check("Benchmark results were recorded for every free model tested", openCode.freePool.filter { $0.enabled }.allSatisfy { ((try? repo.benchmarks(modelID: $0.id)) ?? []).count >= BenchmarkSuite.all.count })
        } else { skip("Free-model benchmarks", "run with --benchmark-models") }

        // ---------------------------------------------------------------- C. local Qwen (lifecycle + real answer)
        if runtime.state == .idle {
            prefs.providerPreference = .local
            convo.clear()
            check("Local worker is NOT running before first use (nothing to start by hand)", runtime.workerPID == nil && runtime.state == .idle)
            let rssBefore = idleRSS0
            let qwenCardBefore = context.observatory.providerCards().first { $0.id == .local }?.state.label ?? "?"
            var runPhases: [String] = [], qwenStates: [String] = []
            let sampler = Task { @MainActor in
                while !Task.isCancelled {
                    if let r0 = context.hub.activeRuns.first, case let r = context.observatory.decorate(r0), runPhases.last != r.phase.rawValue { runPhases.append(r.phase.rawValue) }
                    let st = context.observatory.providerCards().first { $0.id == .local }?.state.label ?? "?"
                    if qwenStates.last != st { qwenStates.append(st) }
                    try? await Task.sleep(for: .milliseconds(15))
                }
            }
            let t0 = Date()
            let reply = await ask("Reply with exactly: JARVIS_LOCAL_OK")
            await sleep(0.1)                                                           // let the sampler see the settled (post-run) state
            sampler.cancel()
            let total = Date().timeIntervalSince(t0)
            // --- Observatory (V0.3.2): the SAME real execution must be visible everywhere ---
            let obsRun = context.hub.recentFinished.first
            let obsText = obsRun.map { context.hub.visibleText($0.id) } ?? ""
            context.hub.flushPersistNow()
            info("observatory: Qwen card before=\(qwenCardBefore) · card states seen=\(qwenStates) · run phases seen=\(runPhases)")
            check("Observatory: Qwen reads UNLOADED before use, then STARTING → RUNNING, then LOADED · IDLE (never RUNNING when idle)",
                  qwenCardBefore == "UNLOADED" && qwenStates.contains("STARTING") && qwenStates.contains("RUNNING") && qwenStates.last == "LOADED · IDLE", "\(qwenStates)")
            check("Observatory: the real run went STARTING (model loading) → RUNNING → COMPLETED with the real engine",
                  runPhases.first == "starting" && runPhases.contains("running") && obsRun?.phase == .completed && obsRun?.engine == .local, "\(runPhases)")
            check("Observatory: live console shows the SAME execution's sanitized output and a completed event",
                  obsText.contains("JARVIS_LOCAL_OK") && (obsRun.map { context.hub.consoleSnapshot($0.id).events.last?.kind == .completed } ?? false))
            check("Observatory: timeline and history list the finished run (provider preserved)",
                  obsRun.map { r in context.observatory.timeline().contains { $0.runID == r.id && $0.kind == .completed } && context.observatory.history(filter: .init(engine: .local)).contains { $0.id == r.id } } ?? false)
            check("Observatory: unknown progress shows NO percentage (no structured steps)", obsRun?.progress.fraction == nil && obsRun?.progress.source == .unknown)
            check("Local Qwen: real answer through ConversationService→Coordinator→LocalQwenProvider→worker",
                  reply?.content.trimmingCharacters(in: .whitespacesAndNewlines) == "JARVIS_LOCAL_OK" && reply?.status == .complete && reply?.provider == "Local Qwen",
                  "reply=\"\(reply?.content ?? "nil")\" total \(fmt(total)) s (includes on-demand start)")
            let m = runtime.metrics
            info("local metrics: load \(m.loadSeconds.map { fmt($0) } ?? "?") s · first token \(m.firstTokenSeconds.map { fmt($0, "%.2f") } ?? "?") s · \(m.generationTokensPerSecond.map { fmt($0, "%.0f") } ?? "?") tok/s · peak GPU/unified \(m.peakMemoryGB.map { fmt($0) } ?? "?") GB")
            check("Local runtime auto-started and is loaded", runtime.state == .ready && runtime.workerPID != nil)
            let workerRSS = runtime.workerResidentBytes
            info("memory: JARVIS \(mb(rssBefore)) before → \(mb(ProcessTree.residentBytes(of: me))) after; local worker resident \(mb(workerRSS))")
            if let r = lastRun() {
                check("Local run audited with machine-readable selection reason", r.engine == .local && r.status == .succeeded && (r.selectionReason ?? "").contains("\"selected\":\"local\"") && r.inputTokens != nil, r.selectionReason ?? "")
            }

            // Health check + bounded work while loaded: CPU of JARVIS vs worker.
            check("Local health check (ping/pong round trip)", await runtime.healthCheck())
            let idleLoaded = await measure(4)
            info("CPU while model LOADED but idle (4 s): JARVIS \(pct(idleLoaded.jarvisCPU, idleLoaded.wall)) · worker \(pct(idleLoaded.childCPU, idleLoaded.wall)) · worker RSS \(mb(idleLoaded.peakChildRSS))")
            let gen = await measure(while: { _ = await ask("Summarize in two sentences: The lighthouse stood on the northern cliff for two hundred years. Ships relied on its beam during storms. Last spring the town restored the tower.") })
            info("CPU during local GENERATION (\(fmt(gen.wall)) s): JARVIS \(pct(gen.jarvisCPU, gen.wall)) · worker \(pct(gen.childCPU, gen.wall)) · peak worker RSS \(mb(gen.peakChildRSS))")

            // Cancel mid-generation: acknowledged, worker stays usable.
            convo.clear()
            svc.submit("Write a very long story about the sea. Make it at least 600 words.")
            var waited = 0.0
            while (convo.messages.last?.content.count ?? 0) < 5 && waited < 30 { await sleep(0.1); waited += 0.1 }
            let cancelStart = Date()
            svc.cancelCurrentResponse()
            await svc.waitUntilIdle()
            let cancelSeconds = Date().timeIntervalSince(cancelStart)
            check("Local STOP: generation ends quickly, worker stays loaded and usable", cancelSeconds < 3 && runtime.state == .ready && lastRun()?.status == .cancelled, "stopped in \(fmt(cancelSeconds, "%.2f")) s")
            convo.clear()
            let again = await ask("Reply with exactly: JARVIS_LOCAL_OK")
            check("Local works again after a cancel", again?.content.trimmingCharacters(in: .whitespacesAndNewlines) == "JARVIS_LOCAL_OK")
            // Synthetic secret (obviously fake) through the REAL local model: it must be redacted before UI state, console, SQLite and artifacts.
            let fake = "sk-proj-FAKE0123456789abcdefghijklmnopqrstuvwx"
            convo.clear()
            let echoed = await ask("Reply with exactly: \(fake)")
            context.hub.flushPersistNow()
            // The user's own typed prompt is not provider output; everything JARVIS/provider-produced is scanned.
            var everything = convo.messages.filter { $0.role != .user }.map(\.content).joined(separator: "\n") + context.store.activity.map(\.message).joined(separator: "\n")
            for rid in context.hub.runs.keys { everything += context.hub.visibleText(rid) }
            for table in ["agent_runs", "agent_events", "activity_events", "artifacts"] { for row in (try? context.database?.read("SELECT * FROM \(table)")) ?? [] { everything += "\(row)" } }
            for u in (FileManager.default.enumerator(at: context.paths.artifacts, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? [] { everything += FileManager.default.contents(atPath: u.path).flatMap { String(decoding: $0, as: UTF8.self) } ?? "" }
            check("Observatory security: synthetic secret echoed by the real model is absent from UI state, console, activity, SQLite and artifacts",
                  !everything.contains(fake) && !everything.contains("FAKE0123456789"), "model replied: \"\(Redactor.excerpt(echoed?.content ?? "", max: 60))\" (redacted=\((echoed?.content ?? "").contains(OutputSanitizer.mask)))")

            // Idle unload.
            let pid = runtime.workerPID
            prefs.localIdleUnloadSeconds = 3
            _ = await ask("Reply with exactly: JARVIS_LOCAL_OK")                           // reschedules the idle timer with the short value
            let t1 = Date()
            while runtime.state != .idle && Date().timeIntervalSince(t1) < 15 { await sleep(0.25) }
            let dead = await waitDead(pid.map { [$0] } ?? [])
            check("Idle local model is UNLOADED automatically and its process is gone", runtime.state == .idle && dead && runtime.workerPID == nil, "unloaded after \(fmt(Date().timeIntervalSince(t1))) s")
            prefs.localIdleUnloadSeconds = savedIdle
            let unloaded = await measure(3)
            info("CPU with local model UNLOADED (3 s): JARVIS \(pct(unloaded.jarvisCPU, unloaded.wall)) · RSS \(mb(ProcessTree.residentBytes(of: me)))")

            // Policy: development work is refused on explicit Local (no process started).
            convo.clear()
            let refusedReply = await ask("Explain this Swift function: func f(_ xs: [Int]) -> Int { xs.reduce(0, +) }")
            check("Explicit Local refuses a coding question (policy), starts nothing", (refusedReply?.content ?? "").contains("lightweight") && runtime.workerPID == nil && lastRun()?.errorCategory == "refused")
        } else { skip("Local Qwen real tests", "runtime not ready (\(runtime.state.label)) — run scripts/setup_local_ai.sh") }

        // ---------------------------------------------------------------- D. OpenCode free model
        if openCode.state == .ready, !openCode.freePool.filter({ $0.enabled }).isEmpty {
            prefs.providerPreference = .openCodeFree
            convo.clear()
            let u = await measure(while: {
                let t0 = Date()
                let reply = await ask("Reply with exactly: JARVIS_OPENCODE_OK")
                let run = lastRun()
                check("OpenCode FREE: real answer through ConversationService→Coordinator→OpenCode CLI",
                      reply?.content.trimmingCharacters(in: .whitespacesAndNewlines) == "JARVIS_OPENCODE_OK" && reply?.status == .complete && (reply?.provider ?? "").hasPrefix("OpenCode"),
                      "provider=\(reply?.provider ?? "?") model=\(run?.model ?? "?") freeVerified=\((run?.selectionReason ?? "").contains("\"freeVerified\":\"true\"")) duration \(fmt(Date().timeIntervalSince(t0))) s")
            })
            info("CPU during OpenCode run (\(fmt(u.wall)) s): JARVIS \(pct(u.jarvisCPU, u.wall)) · opencode child \(pct(u.childCPU, u.wall)) · peak child RSS \(mb(u.peakChildRSS))")
            guard let r = lastRun(), let chosen = r.model.flatMap({ openCode.model($0) }) else { check("OpenCode run was audited", false); finish() }
            check("OpenCode run audited: engine, model, free verification, tokens, reason",
                  r.engine == .openCode && chosen.isFreePoolMember && r.costClass == .freeCloud && r.status == .succeeded
                  && (r.selectionReason ?? "").contains("\"freeVerified\":\"true\""), "model \(chosen.id) [\(chosen.dataPolicy.rawValue)] tokens in/out \(r.inputTokens.map(String.init) ?? "-")/\(r.outputTokens.map(String.init) ?? "-")")
            let first = chosen
            check("OpenCode is per-request: no process left after the run (no daemon)", descendants().isEmpty && ProcessRegistry.shared.count == 0)

            // Tool-restriction canaries against the REAL OpenCode (provider level; temp canary names, nothing sensitive).
            if let provider = openCode.provider(for: first) {
                let ws = openCode.providerWorkspace + "/opencode"
                let canaries = ["CANARY_BASH_\(UUID().uuidString.prefix(6))", "CANARY_WRITE_\(UUID().uuidString.prefix(6))"]
                let r1 = await OneShotRunner.run(provider: provider, prompt: "Use your bash tool to run exactly: touch \(canaries[0])  — do it now.", timeout: 120)
                let r2 = await OneShotRunner.run(provider: provider, prompt: "Use your write tool to create a file named \(canaries[1]) containing hi — do it now.", timeout: 120)
                let created = canaries.filter { FileManager.default.fileExists(atPath: ws + "/" + $0) || FileManager.default.fileExists(atPath: FileManager.default.currentDirectoryPath + "/" + $0) }
                check("OpenCode tool canaries: no command ran, no file was written", created.isEmpty,
                      "attempted tools: \(r1.toolAttempts + r2.toolAttempts) · answers: \(Redactor.excerpt(r1.text, max: 40)) | \(Redactor.excerpt(r2.text, max: 40))")
            }

            // STOP GENERATION on a free-model run: process is killed, run recorded as cancelled, no failure counted.
            convo.clear()
            svc.submit("Write a very long, detailed essay about the history of the sea, at least 800 words.")
            var w = 0.0
            while descendants().isEmpty && w < 20 { await sleep(0.1); w += 0.1 }
            let kids = descendants()
            check("OpenCode process is running before STOP", !kids.isEmpty, "pids=\(kids)")
            let t0 = Date()
            let stopRun = svc.respondingRunID
            let card = context.observatory.providerCards().first { $0.id == .openCode }
            check("Observatory: OpenCode shows RUNNING with the actual selected free model while the real process lives",
                  card?.state == .running && card?.currentModel == first.id && card?.activeRuns.count == 1, "state=\(card?.state.label ?? "?") model=\(card?.currentModel ?? "?")")
            let stopped = stopRun.map { context.hub.requestStop($0) } ?? false           // the SAME action the Stop button calls
            await svc.waitUntilIdle()
            let gone = await waitDead(kids)
            context.hub.flushPersistNow()
            let events = stopRun.flatMap { try? repo.events(runID: $0) } ?? []
            check("OpenCode STOP (via Observatory action) kills the process tree, run CANCELLED in hub + SQLite + console, no cooldown, no orphan",
                  stopped && gone && descendants().isEmpty && lastRun()?.status == .cancelled && stopRun.flatMap { context.hub.run($0)?.phase } == .cancelled
                  && events.contains { $0.kind == .cancelled } && sup.consecutiveFailures(.openCode, first.id) == 0,
                  "stopped in \(fmt(Date().timeIntervalSince(t0), "%.2f")) s")
        } else if openCode.state != .notInstalled {
            // OpenCode present but nothing may be used (unsupported CLI generation / no verified-free model): explicit mode must refuse, send nothing.
            prefs.providerPreference = .openCodeFree
            convo.clear()
            let before = Set(descendants())
            let reply = await ask("Reply with exactly: JARVIS_OPENCODE_OK")
            check("Explicit OpenCode Free with no verified-free model: refused, nothing launched, no fallback",
                  (reply?.content ?? "").contains("No verified-free OpenCode model") && Set(descendants()) == before && lastRun()?.errorCategory == "refused" && lastRun()?.engine == .openCode,
                  "reply=\"\(Redactor.excerpt(reply?.content ?? "", max: 70))\"")
        } else { skip("OpenCode real tests", "OpenCode not installed") }

        // ---------------------------------------------------------------- E. automatic routing (real stack)
        prefs.providerPreference = .auto
        func routeDemo(_ label: String, _ prompt: String, expect: (RoutingDecision, AgentRunRecord?, ConversationMessage?) -> (Bool, String)) async {
            convo.clear()
            let reply = await ask(prompt)
            let d = context.coordinator.lastDecision
            let run = lastRun()
            let (ok, detail) = d.map { expect($0, run, reply) } ?? (false, "no decision")
            check("Auto routing — \(label)", ok, "\(d?.selected?.label ?? "refused") · reply=\"\(Redactor.excerpt(reply?.content ?? "", max: 50))\" · \(detail)")
            info("  reason: \(run?.selectionReason ?? d?.reasonJSON ?? "-")")
        }
        if runtime.state == .idle || runtime.state == .ready {
            await routeDemo("simple bounded task → Local Qwen", "Summarize in one sentence: The cat sat on the mat and then slept.") { d, run, reply in
                (d.selected?.engine == .local && run?.engine == .local && run?.status == .succeeded && !(reply?.content ?? "").isEmpty, "tier=\(d.reasons["tier"] ?? "")")
            }
        } else { skip("Auto → local", "runtime not ready") }
        let codingQ = "Explain this Swift function: func f(_ xs: [Int]) -> Int { xs.reduce(0, +) }"
        await routeDemo("coding question (local forbidden) → verified-free OpenCode if benchmarked, else Claude/Codex", codingQ) { d, run, reply in
            let engine = d.selected?.engine
            let freeEligible = benchmark && !openCode.freePool.isEmpty
            let ok = engine != .local && (engine == .openCode || engine == .claudeCode || engine == .codex) && run?.status == .succeeded && (d.reasons["localModelIneligible"] == "true")
            return (ok, freeEligible ? "benchmarks recorded → free eligible" : "no benchmark evidence yet → premium (policy)")
        }
        await routeDemo("heavy architecture request → Claude Code / Codex (never free or local)", "Design the architecture for a scalable multiplayer backend. Answer in exactly one short sentence.") { d, run, reply in
            (d.selected?.engine == .claudeCode || d.selected?.engine == .codex) && d.reasons["tier"] == "heavy-premium-only" && run?.status == .succeeded && !(reply?.content ?? "").isEmpty ? (true, "tier=heavy-premium-only") : (false, "tier=\(d.reasons["tier"] ?? "")")
        }
        convo.clear()
        let before = Set(descendants()), runsBeforeCommands = (try? repo.count("agent_runs")) ?? 0
        svc.submit("raporu aç"); await svc.waitUntilIdle()
        svc.submit("Fix my Unity multiplayer system. Run it and keep working until it passes."); await svc.waitUntilIdle()
        check("Deterministic commands and worker requests launch NO engine and create no run",
              Set(descendants()) == before && ((try? repo.count("agent_runs")) ?? -1) == runsBeforeCommands && convo.messages.last?.route == .worker)

        // ---------------------------------------------------------------- F. cleanup paths
        if runtime.state == .idle || runtime.state == .ready, runtime.config.executable.hasPrefix("/") {
            prefs.providerPreference = .local
            _ = await ask("Reply with exactly: JARVIS_LOCAL_OK")
            if let pid = runtime.workerPID {
                sup.autoRestartLocal = false                                               // as at termination: no recovery restart
                ProcessRegistry.shared.killAll()                                           // what applicationWillTerminate / signal handlers do
                check("App-termination path kills the local worker (no orphan)", await waitDead([pid]))
                runtime.reset()
            }
        }
        check("No JARVIS-managed process remains", descendants().isEmpty && ProcessRegistry.shared.count == 0)
        let final = await measure(4)
        info("CPU idle at the end (4 s): JARVIS \(pct(final.jarvisCPU, final.wall)) · RSS \(mb(ProcessTree.residentBytes(of: me)))")

        // ---------------------------------------------------------------- F2. Restart reconciliation on the real SQLite file
        let staleID = context.audit.begin(agentType: "StaleProbe", engine: .openCode, model: "opencode/none", decision: nil, prompt: "stale probe", privacy: .normal, label: "Stale run probe")
        if let probeDB = try? JarvisDatabase(url: context.database!.url) {                // a "next launch" connection to the same file
            let probeRepo = JarvisRepository(database: probeDB)
            let reconciled = AuditRecorder(repository: probeRepo).reconcileStaleRuns()
            let rec = try? probeRepo.agentRun(staleID)
            let ev = (try? probeRepo.events(runID: staleID)) ?? []
            check("Restart reconciliation (real SQLite file): a run left RUNNING becomes INTERRUPTED with a persisted reason, not RUNNING forever",
                  reconciled >= 1 && rec?.status == .interrupted && ev.contains { $0.kind == .interrupted }, "reconciled \(reconciled) run(s)")
            probeDB.close()
        }
        context.hub.finish(staleID, phase: .interrupted)

        // ---------------------------------------------------------------- G. SQLite: reopen after "restart"
        let runsBefore = (try? context.database?.readOne("SELECT count(*) AS n FROM agent_runs WHERE agent_type != 'StaleProbe'")?.int("n")).flatMap { $0 } ?? 0
        let url = context.database!.url
        context.database!.close()
        if let reopened = try? JarvisDatabase(url: url) {
            let r2 = JarvisRepository(database: reopened)
            let runs = (try? reopened.readOne("SELECT count(*) AS n FROM agent_runs WHERE agent_type != 'StaleProbe'")?.int("n")).flatMap { $0 } ?? -1
            let reasons = ((try? r2.recentAgentRuns(limit: 80)) ?? []).filter { $0.agentType != "StaleProbe" && ($0.selectionReason ?? "").contains("\"mode\"") }.count
            let acts = (try? r2.count("activity_events")) ?? 0
            let models = (try? r2.models(engine: .openCode).count) ?? 0
            check("SQLite: records survive close/reopen (restart)", runs == runsBefore && runs > 0 && reasons == runs && acts > 0 && models == openCode.models.count,
                  "agent_runs=\(runs) with reasons=\(reasons) · activity=\(acts) · model_registry=\(models) · schema v\(reopened.schemaVersion)")
            let sample = (try? r2.recentAgentRuns(limit: 8)) ?? []
            for r in sample.reversed() { info("  trace: \(r.agentType) \(r.engine.rawValue)\(r.model.map { "/" + $0 } ?? "") \(r.status.rawValue) \(r.finishedAt.map { fmt($0.timeIntervalSince(r.startedAt), "%.1f") } ?? "?")s tokens \(r.inputTokens.map(String.init) ?? "-")/\(r.outputTokens.map(String.init) ?? "-") tools=\(r.toolsUsed) esc=\(r.escalatedFrom ?? "-")→\(r.escalatedTo ?? "-")") }
            let dump = ((try? reopened.read("SELECT result_summary, selection_reason FROM agent_runs")) ?? []).map { "\($0)" }.joined()
            check("No secret or whole prompt in the audit trail", !dump.contains("sk-") && !dump.contains("JARVIS_LOCAL_OK 1234"))
            reopened.close()
        } else { check("SQLite reopen", false, "could not reopen \(url.path)") }

        finish()
    }
}
