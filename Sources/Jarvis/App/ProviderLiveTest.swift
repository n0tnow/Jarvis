import AppKit

/// `Jarvis --provider-live-test [--live-dir <dir>]` — OPT-IN. Makes REAL requests (a handful of tiny prompts per provider,
/// using the user's own subscriptions) through the full JARVIS path:
///   ConversationService → ProviderManager → CLIProvider → real CLI → parser → ConversationStore.
/// It never bypasses the architecture to talk to a CLI directly. Prints REAL TESTED lines; exits non-zero on failure.
/// Saves/restores the provider preference. Not part of scripts/verify.sh's default run (it spends quota).
@MainActor
enum ProviderLiveTest {
    static func run(context: AppContext, captureDirectory: String) async {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "REAL TESTED PASS" : "REAL TESTED FAIL")  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        func skip(_ name: String, _ why: String) { print("SKIPPED  \(name) — \(why)") }

        let prefs = context.preferences
        let savedPreference = prefs.providerPreference
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { prefs.providerPreference = savedPreference; ProcessRegistry.shared.killAll(); print("LIVE TEST TIMEOUT"); fflush(stdout); exit(2) }
        try? FileManager.default.createDirectory(atPath: captureDirectory, withIntermediateDirectories: true)

        let svc = context.conversationService!, convo = context.conversation, store = context.store
        let providers = context.providers
        // NOTE: `defer` would never run because this function ends with exit(); restore explicitly before every exit.

        await providers.refresh()
        for id in ProviderID.allCases {
            let s = providers.status(id)
            print("INFO  \(id.displayName): state=\(s.state.label) version=\(s.version ?? "-")")
        }

        func cpuSeconds(_ who: Int32) -> Double {
            var u = rusage(); getrusage(who, &u)
            return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
        }

        func ask(_ text: String) async -> ConversationMessage? {
            svc.submit(text); await svc.waitUntilIdle()
            return convo.messages.last { $0.role == .jarvis }
        }
        func descendants() -> [pid_t] { ProcessTree.descendants(of: getpid()) }
        func waitNoChildren(_ pids: [pid_t]) async -> Bool {
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline { if pids.allSatisfy({ !ProcessTree.isAlive($0) }) { return true }; try? await Task.sleep(for: .milliseconds(50)) }
            return pids.allSatisfy { !ProcessTree.isAlive($0) }
        }

        // Deterministic commands must never launch a provider (checked with the real manager active)
        convo.clear(); context.windows.hideFullHUD(); context.windows.showCompactHUD()
        let before = ProcessRegistry.shared.count
        svc.submit("raporu aç", origin: .compactHUD); await svc.waitUntilIdle()
        check("Deterministic 'raporu aç' launches NO provider; Compact → Full, Report selected",
              ProcessRegistry.shared.count == before && descendants().isEmpty && context.hud.section == .report && context.windows.isFullHUDOpen && !context.windows.isCompactHUDOpen
              && convo.messages.last?.route == .command)
        context.hud.section = .dashboard

        var capturedFirst = false
        var testedProviders = 0
        for id in ProviderID.allCases {
            let name = id.displayName
            guard providers.status(id).state.isUsable else { skip("\(name) real requests", "not READY (\(providers.status(id).state.label))"); continue }
            testedProviders += 1
            prefs.providerPreference = id == .claudeCode ? .claudeCode : .codex
            providers.resetSessions(); convo.clear()
            context.windows.showFullHUD(section: .dashboard); await withCheckedContinuation { c in DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { c.resume() } }

            // 1. Exact reply through the whole stack
            let t0 = Date()
            let r1 = await ask("Reply with exactly: JARVIS_PROVIDER_OK")
            check("\(name): real answer via ConversationService→ProviderManager→provider→parser→store",
                  r1?.content.trimmingCharacters(in: .whitespacesAndNewlines) == "JARVIS_PROVIDER_OK" && r1?.status == .complete && r1?.provider == name && r1?.route == .reasoning,
                  "reply=\"\(r1?.content ?? "nil")\" in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
            check("\(name): JARVIS state returned to idle, no process left", store.state == .idle && !svc.isResponding && descendants().isEmpty && providers.status(id).state == .ready)

            // 2. Streaming evidence: poll the store while a longer answer is generated
            convo.clear(); providers.resetSessions()
            let cpuSelf0 = cpuSeconds(RUSAGE_SELF), cpuKids0 = cpuSeconds(RUSAGE_CHILDREN), wall0 = Date()
            svc.submit("Count from 1 to 40, separated by single spaces. Output only the numbers.")
            var snapshots = Set<Int>(), lastLen = 0, shotMid = false
            while svc.isResponding {
                let len = convo.messages.last?.content.count ?? 0
                if len != lastLen { snapshots.insert(len); lastLen = len }
                if !capturedFirst && !shotMid && len > 0 && len < 60 {
                    shotMid = true
                    DevCapture.snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "live_\(id.rawValue)_streaming", in: captureDirectory)
                }
                try? await Task.sleep(for: .milliseconds(15))
            }
            await svc.waitUntilIdle()
            let wall = max(0.001, Date().timeIntervalSince(wall0))
            print(String(format: "INFO  %@: CPU during real streaming (Full HUD open + neural animation): JARVIS ≈ %.1f%% of one core, provider process ≈ %.1f%% (over %.1fs)",
                         name, (cpuSeconds(RUSAGE_SELF) - cpuSelf0) / wall * 100, (cpuSeconds(RUSAGE_CHILDREN) - cpuKids0) / wall * 100, wall))
            let counted = convo.messages.last?.content ?? ""
            check("\(name): answer content is complete and correct", counted.split(separator: " ").compactMap { Int($0) } == Array(1...40), "got=\"\(counted.prefix(80))\"")
            let streamingKind = id == .claudeCode ? "token-level (expected multiple updates)" : "message-level (documented: complete agent_message)"
            print("INFO  \(name): distinct UI snapshots while generating = \(snapshots.count) — \(streamingKind)")
            if id == .claudeCode { check("\(name): streamed incrementally (real deltas, not one chunk)", snapshots.count >= 2, "snapshots=\(snapshots.sorted())") }
            if !capturedFirst { DevCapture.snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "live_\(id.rawValue)_done", in: captureDirectory); capturedFirst = true }

            // 3. Follow-up context (official session continuation)
            convo.clear(); providers.resetSessions()
            _ = await ask("Remember this secret word: PINEAPPLE. Reply with exactly: OK")
            let sessionAfterFirst = providers.sessionID(for: id)
            let r3 = await ask("What was the secret word I asked you to remember? Answer with just the word.")
            check("\(name): follow-up is context-aware (session continued)", (r3?.content.uppercased().contains("PINEAPPLE") ?? false) && sessionAfterFirst != nil,
                  "session=\(sessionAfterFirst != nil) reply=\"\(r3?.content.prefix(60) ?? "nil")\"")

            // 4. Real cancellation: kill the real process, verify no orphans, UI recovers
            convo.clear(); providers.resetSessions()
            svc.submit("Write a very long, detailed essay (at least 1500 words) about the history of computing.")
            let t1 = Date()
            var kids: [pid_t] = []
            while Date().timeIntervalSince(t1) < 8 {
                kids = descendants()
                let partial = (convo.messages.last?.content.count ?? 0) > 0
                if !kids.isEmpty && (id == .codex || partial) { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if id == .codex { try? await Task.sleep(for: .seconds(2)) }          // let it get going; Codex only emits whole messages
            kids = descendants()
            check("\(name): provider process is running before STOP", !kids.isEmpty && svc.isResponding, "pids=\(kids)")
            let partialBefore = convo.messages.last?.content.count ?? 0
            let t2 = Date()
            svc.cancelCurrentResponse()
            await svc.waitUntilIdle()
            let stopTime = Date().timeIntervalSince(t2)
            let gone = await waitNoChildren(kids)
            let last = convo.messages.last { $0.role == .jarvis }
            check("\(name): STOP GENERATION really killed the provider process tree (no orphans)", gone && descendants().isEmpty && ProcessRegistry.shared.count == 0, "stopped in \(String(format: "%.1f", stopTime))s, pids=\(kids)")
            check("\(name): UI recovered after STOP (idle, composer free, message marked cancelled)",
                  !svc.isResponding && store.state == .idle && last?.tone == .notice && last?.status == .complete && providers.status(id).state == .ready,
                  "partial chars=\(partialBefore) status=\(String(describing: last?.status))")
            check("\(name): partial answer kept (\(id == .claudeCode ? "streamed text" : "none expected: message-level"))", id == .codex || partialBefore > 0)
        }

        // Worker boundary with the real manager active: no provider may start
        convo.clear()
        let beforeWorker = ProcessRegistry.shared.count
        svc.submit("Fix my Unity multiplayer implementation, run the project and keep working until it passes."); await svc.waitUntilIdle()
        check("Worker request stays workerRequired: no provider launched, truthful message",
              ProcessRegistry.shared.count == beforeWorker && descendants().isEmpty && convo.messages.last?.route == .worker && convo.messages.last?.content.contains("isn't enabled yet") == true)

        providers.shutdown()
        prefs.providerPreference = savedPreference
        if testedProviders == 0 {
            print("PROVIDER LIVE TEST INCONCLUSIVE — no provider was READY, so nothing real was tested")
            fflush(stdout); exit(3)
        }
        print(failures == 0 ? "PROVIDER LIVE TEST PASSED (\(testedProviders) provider(s) tested for real)" : "PROVIDER LIVE TEST FAILED (\(failures))")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}
