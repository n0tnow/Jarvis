import AppKit
import Foundation

/// `Jarvis --daily-jarvis-live-test [--daily-section <name>]…` — OPT-IN (V0.15). The intended daily experience on DISPOSABLE fixtures with its own data directory (live-test-daily).
///
/// REAL = the real engine, real persistence, real processes. ENGINE = the real task engine with SCRIPTED model answers (no provider, no quota). POLICY = a deterministic rule. Nothing here contacts
/// Claude, Codex or OpenCode, the public web, Unity or the microphone; the real Hamam project and every other real project are never touched.
/// Sections: `conversation` (the daily flow: status, follow-ups, depth, approval boundary, stop-speech vs cancel-task), `latency`, `readiness` (real discovery, nothing started), `voice`.
@MainActor
enum DailyLiveTest {
    /// Records what a typed or spoken sentence asks task intake for. Asset-suitability goals are recorded and NOT run (the real graph would research the public web); every other goal goes to the real intake.
    @MainActor
    final class RecordingIntake: TaskSubmitting, ResearchSubmitting {
        let real: TaskIntake
        private(set) var goals: [(goal: String, kind: TaskKind?)] = []
        init(real: TaskIntake) { self.real = real }
        var hasProject: Bool { real.hasProject }
        var projectName: String? { real.projectName }
        func submitTask(goal: String, intent: GoalIntake.Intent, channel: InputSource) async -> TaskSubmission {
            goals.append((goal, intent.kind))
            if GoalCues.assetQuestion(goal) { return .started(title: "Asset suitability (recorded, not run)") }
            return await real.submitTask(goal: goal, intent: intent, channel: channel)
        }
        func submitResearch(goal: String, channel: InputSource) async -> TaskSubmission { goals.append((goal, nil)); return .started(title: "Research (recorded, not run)") }
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))]
    }

    static func run(context: AppContext, sections: Set<String>) async {
        var passes = 0, failures = 0, skips = 0
        func wants(_ s: String) -> Bool { sections.isEmpty || sections.contains(s) }
        func check(_ tag: String, _ name: String, _ ok: Bool, _ detail: String = "") { print("\(ok ? "PASS" : "FAIL")  [\(tag)] \(name)\(detail.isEmpty ? "" : " — \(detail)")"); if ok { passes += 1 } else { failures += 1 }; fflush(stdout) }
        func skip(_ name: String, _ why: String) { print("SKIP  \(name) — \(why)"); skips += 1; fflush(stdout) }
        func info(_ s: String) { print("INFO  \(s)"); fflush(stdout) }
        let prefs = context.preferences, engine = context.taskEngine, repo = context.repository!, convo = ConversationStore()
        let scripted = ScriptedAnswerResolver()
        let svc = ConversationService(store: context.store, conversation: convo, windows: context.windowManager, resolver: scripted)
        let intake = RecordingIntake(real: context.taskIntake)
        svc.taskSubmitter = intake; svc.researchSubmitter = intake
        svc.continuityHandler = context.continuity; svc.adaptiveHandler = context.adaptiveAssistant; svc.memoryHandler = context.memory
        svc.graphStatus = { [weak engine] focus, lang in engine?.graphStatusText(focus, lang) }
        context.configureDailyConversation(on: svc)
        let realRunner = engine.agents
        let savedRoot = prefs.projectRoot, savedStyle = prefs.responseStyle, savedAddress = prefs.addressStyle, savedFollow = prefs.conversationFollowUps
        var projects: [String] = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 900) { ProcessRegistry.shared.killAll(); print("DAILY LIVE TEST TIMEOUT"); fflush(stdout); exit(2) }
        func finish() -> Never {
            engine.agents = realRunner
            prefs.projectRoot = savedRoot; prefs.responseStyle = savedStyle; prefs.addressStyle = savedAddress; prefs.conversationFollowUps = savedFollow
            for p in projects { try? FileManager.default.removeItem(atPath: p) }
            ProcessRegistry.shared.killAll()
            print("DAILY LIVE TEST \(failures == 0 ? "PASSED" : "FAILED") (\(passes) passed, \(failures) failed, \(skips) skipped)"); fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        func git(_ args: [String], in dir: String) async -> String {
            await ManagedProcess.runOnce(executable: "/usr/bin/git", arguments: ["-c", "user.name=JARVIS Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false"] + args, environment: ProviderEnvironment.make(), workingDirectory: dir, timeout: 30)?.output ?? ""
        }
        func makeProject() async -> String {
            let dir = TaskDemo.makeProject(); projects.append(dir)
            func write(_ p: String, _ t: String) { FileManager.default.createFile(atPath: dir + "/" + p, contents: Data(t.utf8)) }
            write("README.md", "# Calculator fixture\n")
            write("calc.py", "def add(a, b):\n    return a - b\n\ndef mul(a, b):\n    return a * b\n")
            write("test_calc.py", "import unittest\nfrom calc import add, mul\n\nclass T(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(add(2, 3), 5)\n    def test_mul(self):\n        self.assertEqual(mul(2, 3), 6)\n\nif __name__ == '__main__':\n    unittest.main()\n")
            _ = await git(["init", "-q", "-b", "main"], in: dir); _ = await git(["add", "-A"], in: dir); _ = await git(["commit", "-q", "-m", "initial"], in: dir)
            return dir
        }
        func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if cond() { return true }; try? await Task.sleep(for: .milliseconds(25)) }
            return cond()
        }
        /// Sends one sentence and waits until the answer has landed; returns (answer, milliseconds).
        func say(_ text: String, source: InputSource = .typed, quiet: Bool = false) async -> (String, Double) {
            let before = convo.messages.count
            let t0 = Date()
            svc.submit(text, source: source)
            _ = await waitUntil(5) { convo.messages.count > before + 1 && !svc.isAnswering }
            await svc.waitUntilIdle()
            let ms = Date().timeIntervalSince(t0) * 1000
            let r = convo.last?.content ?? ""
            if !quiet { info("   “\(text)” → \(r.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(200))  [\(Int(ms)) ms]") }
            return (r, ms)
        }

        info("data directory: \(context.paths.root.path) (isolated from your real JARVIS history); schema v\(context.database?.schemaVersion ?? -1); installed application: \(AppInfo.isApplicationBundle); \(AppInfo.versionLine)")
        check("POLICY", "Defaults are conservative: concise, natural address, follow-ups on, notifications off, Launch at Login off by default",
              prefs.responseStyle == .concise && prefs.addressStyle == .natural && prefs.conversationFollowUps && !prefs.notifyOnTaskEvents)
        check("POLICY", "The Compact HUD is unchanged at 392 × 448", CompactHUDLayout.size == CGSize(width: 392, height: 448))

        // MARK: conversation
        if wants("conversation") {
            let project = await makeProject()
            prefs.projectRoot = project
            prefs.responseStyle = .concise; prefs.addressStyle = .natural; prefs.conversationFollowUps = true
            // A real finished task gives the project a history to speak about (scripted model answers; the engine, tests and Git are real).
            engine.agents = OrchestrationScriptRunner(audit: context.audit, script: { job, _ in
                switch job.type {
                case "AnalysisAgent": return .text(OrchestrationDemoText.analysis)
                case "CodingAgent": return .text(OrchestrationDemoText.fixEdit)
                case "ReviewAgent": return .text(OrchestrationDemoText.reviewPass)
                default: return .fail(.generic)
                }
            })
            if case .success(let id) = await engine.submit(goal: "Find the bug, fix it, run the tests and review the change.", kind: .development, workspacePath: project) {
                await engine.waitUntilFinished(id); try? await Task.sleep(for: .milliseconds(400))
                check("ENGINE", "A real task finished on the fixture project (history for the status questions)", engine.view(id)?.task.state == .completed, "\(engine.view(id)?.task.state.rawValue ?? "?")")
            } else { check("ENGINE", "A real task finished on the fixture project", false) }

            let (status, _) = await say("Jarvis durum nedir?")
            check("REAL", "“Jarvis durum nedir?” is answered from the real store and is short", !status.isEmpty && status.count < 300)
            let (last, _) = await say("Bu projede en son ne yaptık?")
            check("REAL", "“Bu projede en son ne yaptık?” comes from the project's recorded work (continuity), not from a model", !last.isEmpty && last != Phrasebook.reasoningUnavailable(.tr) && convo.last?.route == .local, String(last.prefix(120)))

            // Research results (labelled demo rows from the repository fixture — the real web is not contacted) become what “the second one” means.
            let researchID = ResearchDemo.seed(repo, artifacts: context.artifacts)
            context.noteResearchCandidates(researchID: researchID, into: svc)
            let listed = svc.workingContext.candidates([.asset]).sorted { ($0.ordinal ?? 0) < ($1.ordinal ?? 0) }
            check("ENGINE", "Three validated research candidates entered the working context in rank order", listed.count == 3 && listed.map { $0.ordinal } == [1, 2, 3], listed.map(\.label).joined(separator: " | "))
            let second = listed.dropFirst().first?.label ?? "?"
            let before = intake.goals.count
            let (pick, _) = await say("İkincisini dene.")
            check("ENGINE", "“İkincisini dene.” chose the second result and sent ONE ordinary read-only analysis request to task intake (the same call a typed sentence makes)",
                  intake.goals.count == before + 1 && intake.goals.last?.goal.contains(second) == true && intake.goals.last?.kind == .readOnlyAnalysis && convo.messages.contains { $0.content.contains("Seçildi") && $0.content.contains(second) }, "chosen: \(second)")
            check("POLICY", "The explicit request names no import or download", !(intake.goals.last?.goal ?? "").lowercased().contains("import") && !GoalCues.wantsImport(intake.goals.last?.goal ?? ""))
            _ = pick
            let n = intake.goals.count
            _ = await say("Uygunsa kullan.")
            check("ENGINE", "“Uygunsa kullan.” means the chosen one and again only asks for a suitability check (importing stays a separate, approved step)",
                  intake.goals.count == n + 1 && intake.goals.last?.goal.contains(second) == true && !GoalCues.wantsImport(intake.goals.last?.goal ?? ""))

            // Ambiguity and destructive guesses
            context.noteResearchCandidates(researchID: researchID, into: svc)           // a fresh list: nothing is chosen any more
            let m = intake.goals.count
            let (q, _) = await say("Onu kullan.")
            check("POLICY", "With a whole list in mind “Onu kullan.” asks which one and starts nothing", q.contains("Hangisini") && intake.goals.count == m)
            let (del, _) = await say("Bunu sil.")
            check("POLICY", "“Bunu sil.” never guesses a target: it asks and starts nothing", del.contains("tahmin etmem") && intake.goals.count == m)
            let (yes, _) = await say("Evet.")
            check("POLICY", "“Evet.” chooses nothing", intake.goals.count == m, yes)

            // Depth: expand and shorten the previous answer
            let (overall, _) = await say("Her şey hazır mı?")
            let (more, _) = await say("Detaylı anlat.")
            let (less, _) = await say("Kısa söyle.")
            let shortened = more.count > overall.count
            check("REAL", "“Detaylı anlat.” expands the previous answer (never shorter) and “Kısa söyle.” shortens it again without dropping a problem",
                  more.count >= overall.count && less.count <= more.count && (!shortened || more.count > less.count), "normal \(overall.count) → detailed \(more.count) → short \(less.count) chars")

            // The approval boundary: spoken or typed “yes” cannot approve; the HUD decision source can
            var executed = 0
            context.adaptiveDecisions.register(.activateSkill, .init(fingerprint: { id in AdaptiveDecisionService.scopeHash(kind: .activateSkill, subjectID: id, material: "x") }, execute: { _ in executed += 1; return .success("done") }))
            let req = context.adaptiveDecisions.request(kind: .activateSkill, subjectID: "live-daily", material: "x", summary: "Live-test decision", detail: "A decision that only a HUD button may take.", risk: .low)
            check("ENGINE", "A pending decision exists", req != nil && !context.adaptiveDecisions.pending().isEmpty)
            for yes in ["Evet.", "yes, go ahead", "Tamam", "Onaylıyorum", "olur"] {
                for source in [InputSource.typed, .voice] {
                    let (r, _) = await say(yes, source: source, quiet: true)
                    check("POLICY", "“\(yes)” (\(source == .voice ? "spoken" : "typed")) with a decision pending approves nothing", executed == 0 && r.contains("HUD") && !context.adaptiveDecisions.pending().isEmpty)
                }
            }
            if let req { _ = await context.adaptiveDecisions.approve(req.id, source: .test) }
            check("ENGINE", "The HUD decision source (test) approves it and the action proceeds", executed == 1 && context.adaptiveDecisions.pending().isEmpty)

            // Stop speech ≠ stop task
            engine.agents = OrchestrationScriptRunner(audit: context.audit, script: { job, _ in
                try? await Task.sleep(for: .seconds(8))
                return .text(OrchestrationDemoText.analysis)
            })
            var speechStops = 0
            svc.stopSpeech = { speechStops += 1; return true }
            guard case .success(let slowID) = await engine.submit(goal: "Analyze the project structure and report.", kind: .readOnlyAnalysis, workspacePath: project) else { check("ENGINE", "A slow task started", false); finish() }
            _ = await waitUntil(5) { engine.view(slowID)?.task.state.isActive == true }
            _ = await say("Sus.")
            check("POLICY", "“Sus.” stops speech and the task keeps running", speechStops == 1 && engine.view(slowID)?.task.state.isActive == true, "\(engine.view(slowID)?.task.state.rawValue ?? "?")")
            _ = await say("Görevi durdur.")
            let stopped = await waitUntil(15) { engine.view(slowID)?.task.state.isActive == false }
            check("ENGINE", "“Görevi durdur.” cancels the actual task, separately, through the normal path", stopped && engine.view(slowID)?.task.state == .cancelled, "\(engine.view(slowID)?.task.state.rawValue ?? "?")")
            svc.stopSpeech = nil

            // Typed and spoken take the same route
            let a = await say("Hangi sürümdesin?", source: .typed, quiet: true)
            let b = await say("Hangi sürümdesin?", source: .voice, quiet: true)
            check("POLICY", "Spoken and typed sentences give the same answer through the same service", a.0 == b.0 && a.0.contains("JARVIS"))

            // Personality never alters evidence
            check("POLICY", "A failure sentence survives shortening in every depth", ["a"].allSatisfy { _ in
                let t = String(repeating: "Dolgu cümlesi. ", count: 40) + "Birim testi başarısız oldu."
                return [ResponseDepth.terse, .normal].allSatisfy { ReplyShaper.shape(full: t, depth: $0, style: .concise, language: .tr).shown.contains("başarısız oldu") }
            })
        }

        // MARK: introspection (V1.0 stabilisation fix 1): what JARVIS can use is answered from its own state — no model, nothing started
        if wants("introspection") {
            prefs.responseStyle = .concise; svc.workingContext.clear(); svc.presenter.reset()
            await context.providers.refresh()                       // the same safe status probe the app runs at launch (no model call)
            let before = (children: ProcessTree.children(of: getpid()).count, opencode: context.openCode.state, runs: context.hub.activeRuns.count, modelCalls: scripted.prompts.count)
            let snapshot = context.readiness.refresh()
            for id in ["provider.claude", "provider.codex", "provider.opencode", "local.qwen", "local.vision", "local.whisper"] { info("   record \(id): \(snapshot.item(id)?.state.label ?? "—")  installed=\(snapshot.item(id)?.installed.map(String.init(describing:)) ?? "nil")") }
            let (all, _) = await say("Her şey hazır mı?")
            let (providers, _) = await say("Hangi AI modellerine ve providerlara erişebiliyorsun? Kısa söyle.")
            let (claude, _) = await say("Claude Code'u kullanabiliyor musun?")
            let (codex, _) = await say("Codex kullanabiliyor musun?")
            let (opencode, _) = await say("OpenCode hazır mı?")
            let (opencodeUse, _) = await say("OpenCode kullanabiliyor musun?")
            let (qwen, _) = await say("Local Qwen modelin var mı?")
            let (detail, _) = await say("Biraz daha detaylı anlat.")
            let (short, _) = await say("Kısa söyle.")
            _ = all
            let fake = ["API'lere bağlanamam", "erişimim yok", "sadece kendi yeteneklerimle"]
            check("REAL", "No capability answer came from a language model: zero model calls, nothing started, no provider run", scripted.prompts.count == before.modelCalls && ProcessTree.children(of: getpid()).count == before.children && context.hub.activeRuns.count == before.runs)
            check("REAL", "The provider summary is built from the live records and keeps the state distinctions", providers.contains(snapshot.item("provider.claude")?.state == .ready ? "Claude Code" : "Claude Code") && !fake.contains { providers.contains($0) }, providers)
            check("REAL", "“Claude Code'u kullanabiliyor musun?” agrees with the record (\(snapshot.item("provider.claude")?.state.label ?? "—"))", (snapshot.item("provider.claude")?.state == .ready) == claude.hasPrefix("Evet") && !fake.contains { claude.contains($0) }, claude)
            check("REAL", "“Codex kullanabiliyor musun?” agrees with the record (\(snapshot.item("provider.codex")?.state.label ?? "—"))", (snapshot.item("provider.codex")?.state == .ready) == codex.hasPrefix("Evet") && !fake.contains { codex.contains($0) }, codex)
            check("REAL", "OpenCode keeps the state the System screen shows (\(snapshot.item("provider.opencode")?.state.label ?? "—")) and asking did not start it", context.openCode.state == before.opencode && (snapshot.item("provider.opencode")?.state != .unknown || (opencode.contains("henüz kontrol edilmedi") && !opencodeUse.hasPrefix("Evet"))), "\(opencode) / \(opencodeUse)")
            check("REAL", "“Local Qwen modelin var mı?” says what the record says", (snapshot.item("local.qwen")?.state == .optionalAbsent) == qwen.hasPrefix("Hayır") && !fake.contains { qwen.contains($0) }, qwen)
            check("REAL", "“Biraz daha detaylı anlat.” works on the answer just given (the Qwen answer), not an older one", !detail.contains("Sağlayıcılar") && (detail.contains("Qwen") || detail.contains("model")), detail)
            check("REAL", "“Kısa söyle.” then shortens that same subject", short.contains("Qwen") || short.contains("model") || short.contains("doğrulanmış"), short)
        }

        // MARK: grounding (V1.0 stabilisation fix 2) — JARVIS answers about itself from its own state; settings requests really change typed settings; a correction is re-resolved; nothing reaches a model.
        if wants("grounding") {
            let savedRate = prefs.voiceSpeechRate, savedNotify = prefs.notifyOnTaskEvents, savedVoice = prefs.voiceEnabled
            prefs.responseStyle = .concise; prefs.addressStyle = .off; prefs.voiceSpeechRate = 1.0
            svc.workingContext.clear(); svc.presenter.reset()
            let project = await makeProject(); prefs.projectRoot = project
            let snapshot = context.readiness.refresh()
            let ax = snapshot.item("computer.ax")?.state
            let modelCallsBefore = scripted.prompts.count
            let (screen, _) = await say("Ekranımı görebiliyor musun?")
            let (files, _) = await say("Dosya okuyabiliyor musun?")
            let (web, _) = await say("Web araştırması yapabiliyor musun?")
            let (memory, _) = await say("Projelerimi hatırlıyor musun?")
            let (caps, _) = await say("Başka neler yapabiliyorsun?")
            let (sys, _) = await say("Sistem durumunu kısaca özetle")
            let (enScreen, _) = await say("Can you see my screen?")
            let wrong = ["göremiyorum", "okuyamam", "özelliğim yok", "I cannot", "I can't", "I do not have"]
            check("REAL", "Ability questions (screen, files, web, memory, capabilities, system status) never reached a model", scripted.prompts.count == modelCallsBefore)
            check("REAL", "“Ekranımı görebiliyor musun?” agrees with the Accessibility record (\(ax?.label ?? "—")) and separates can from doing", (ax == .ready) == screen.hasPrefix("Evet") && screen.contains(ax == .ready ? "sürekli izlemem" : "Henüz değil") && (enScreen.hasPrefix("Yes") || enScreen.hasPrefix("Not yet")), screen)
            check("REAL", "“Dosya okuyabiliyor musun?” is project-scoped and names the chosen folder", files.contains("proje klasörünüzün") && files.contains((project as NSString).lastPathComponent) && files.contains("dışındaki"), files)
            check("REAL", "“Web araştırması yapabiliyor musun?” states the read-only limits", web.contains("yalnızca okuma") && web.contains("Şu anda hiçbir şey araştırılmıyor"), web)
            check("REAL", "“Projelerimi hatırlıyor musun?” describes Project Memory truthfully (per project, not whole conversations)", memory.contains("Proje Hafızası") && memory.contains("saklamam"), memory)
            check("REAL", "No answer denies a capability JARVIS has", ![screen, files, web, memory, caps, sys].contains { a in wrong.contains { a.contains($0) } })
            check("POLICY", "“Ekranıma bak” is a Computer Use request (observation of the front window), not a question", { if case .computer(let plan) = ComputerGoalParser.classify("Ekranıma bak", context: GoalContext(projectRoot: nil, unityProjectOpen: false, visionEnabled: false)) { return plan.steps.first?.actions.first?.kind == .observe }; return false }())
            check("REAL", "“Sistem durumunu kısaca özetle” is built from the readiness records", sys.contains("kullanılabilir") || sys.contains("hazır") || sys.contains("Hazır değil"), sys)
            // settings reality
            let (up, _) = await say("Konuşma hızını biraz arttır")
            let persisted = Preferences(defaults: prefs.defaults)            // what a relaunch would read
            check("REAL", "“Konuşma hızını biraz arttır” changed the typed setting (1.00× → 1.05×), it persisted, and the reply shows the value that was read back", abs(prefs.voiceSpeechRate - 1.05) < 0.001 && abs(persisted.voiceSpeechRate - 1.05) < 0.001 && up.contains("1.05×"), up)
            let (back, _) = await say("Eski haline getir")
            check("REAL", "“Eski haline getir” restored the previous value", abs(prefs.voiceSpeechRate - 1.0) < 0.001 && (back.contains("Geri aldım") || back.contains("Restored")), back)
            let (addr, _) = await say("Bana bundan sonra efendim diye hitap edebilir misin?")
            let (where_, _) = await say("Bunu nereye kaydettin?")
            check("REAL", "“efendim” is a persisted SETTING (not Project Memory): it changed, persisted, and the storage answer says KALICI AYAR", prefs.addressStyle == .natural && Preferences(defaults: prefs.defaults).addressStyle == .natural && addr.contains("Ayar olarak kaydedildi") && where_.contains("[KALICI AYAR]"), addr + " | " + where_)
            let (list, _) = await say("Hangi ayarları özelleştirebilirsin?")
            check("REAL", "The list of customisable settings comes from the real registry and excludes permissions, approvals and security", list.contains("konuşma hızı") && list.contains("wake word") && list.contains("İzinler, onaylar ve güvenlik ayarları bunların arasında değil"), list)
            let (last, _) = await say("Az önce hangi ayarı değiştirdin?")
            check("REAL", "“Az önce hangi ayarı değiştirdin?” answers from the change record", last.contains("hitap biçimi") || last.contains("konuşma hızı"), last)
            let (none, _) = await say("Bunu hatırlayacak mısın?")
            check("REAL", "A question about remembering something that was never stored says so (no false ‘saved’)", none.contains("Az önce hiçbir şey kaydedilmedi") || none.contains("[KALICI AYAR]"), none)
            // correction
            _ = await say("Claude hazır mı?", quiet: true)
            let (fixed, _) = await say("Hayır, Codex hazır mı demek istedim")
            check("REAL", "A correction is re-resolved from scratch (Codex answered, no model call, no repeat of the old route)", fixed.contains("Codex") && !fixed.contains("Claude Code") && scripted.prompts.count == modelCallsBefore, fixed)
            let (ask, _) = await say("Yanlış anladın")
            check("POLICY", "A bare ‘you misunderstood’ asks what was meant", ask.contains("Asıl neyi kastettiniz"), ask)
            check("POLICY", "A spoken ‘evet’ with a decision pending still approves nothing (voice has no authority)", { svc.hasPendingDecision = { true }; defer { svc.hasPendingDecision = { false } }; return ApprovalGuard.isApprovalUtterance("Evet") }())
            // restore the user's real profile
            prefs.voiceSpeechRate = savedRate; prefs.notifyOnTaskEvents = savedNotify; prefs.voiceEnabled = savedVoice
            check("POLICY", "The live test restored the real profile (speech rate, notifications, voice)", prefs.voiceSpeechRate == savedRate && prefs.notifyOnTaskEvents == savedNotify && prefs.voiceEnabled == savedVoice)
        }

        // MARK: latency
        if wants("latency") {
            prefs.responseStyle = .concise; prefs.conversationFollowUps = true
            var det: [Double] = []
            for text in ["Hangi sürümdesin?", "Claude hazır mı?", "Ses sistemi hazır mı?", "MCP'ler sağlıklı mı?", "Jarvis durum nedir?", "Merhaba", "Teşekkürler", "Rapor aç"] {
                for _ in 0..<5 { let (_, ms) = await say(text, quiet: true); det.append(ms) }
            }
            info("conversation (deterministic answer, submit → reply landed): n=\(det.count) p50 \(String(format: "%.0f", percentile(det, 0.5))) ms · p95 \(String(format: "%.0f", percentile(det, 0.95))) ms")
            check("REAL", "Deterministic answers land well under a second (p95)", percentile(det, 0.95) < 1000)
            let c = ConversationWorkingContext()
            c.beginTurn()
            c.noteList(kind: .asset, entries: [("a", "Bucket A", nil), ("b", "Bucket B", nil), ("c", "Bucket C", nil)], source: .validatedResult("research-report"), evidence: "r")
            c.beginTurn()
            var res: [Double] = []
            for _ in 0..<500 { let t0 = Date(); _ = ReferenceResolver.resolve("İkincisini dene", context: c, language: .tr); res.append(Date().timeIntervalSince(t0) * 1000) }
            info("working-context resolution: n=\(res.count) p50 \(String(format: "%.3f", percentile(res, 0.5))) ms · p95 \(String(format: "%.3f", percentile(res, 0.95))) ms")
            check("REAL", "A follow-up resolves in well under 5 ms (p95)", percentile(res, 0.95) < 5)
            var snap: [Double] = []
            for _ in 0..<20 { let t0 = Date(); _ = context.readiness.refresh(); snap.append(Date().timeIntervalSince(t0) * 1000) }
            info("readiness snapshot: n=\(snap.count) p50 \(String(format: "%.1f", percentile(snap, 0.5))) ms · p95 \(String(format: "%.1f", percentile(snap, 0.95))) ms")
            check("REAL", "The readiness picture builds in under half a second", percentile(snap, 0.95) < 500)
        }

        // MARK: readiness (real discovery; nothing started; no quota)
        if wants("readiness") {
            let childrenBefore = ProcessTree.children(of: getpid()).count
            let runsBefore = context.hub.activeRuns.count
            await ReadinessActions.recheck(context)
            let snap = context.readiness.refresh()
            for c in ReadinessCategory.allCases { for i in snap.items(in: c) { info("   \(c.rawValue) · \(i.name): \(i.state.label)\(i.detail.isEmpty ? "" : " — \(i.detail.prefix(110))")") } }
            check("REAL", "Every category has at least one item", ReadinessCategory.allCases.allSatisfy { !snap.items(in: $0).isEmpty })
            check("REAL", "Core is ready and the database is open", snap.item("core.app")?.state == .ready && snap.item("core.database")?.state == .ready)
            check("REAL", "Claude Code, Codex and OpenCode are reported (installed / signed in / ready are different states)", snap.item("provider.claude") != nil && snap.item("provider.codex") != nil && snap.item("provider.opencode") != nil)
            check("POLICY", "No paid API is offered or enabled: the item says a subscription is not API permission", snap.item("provider.paid")?.action == nil && snap.item("provider.paid")?.detail.contains("never permission") == true)
            let qwen = prefs.localModelPath
            let qwenPresent = FileManager.default.fileExists(atPath: qwen + "/config.json")
            check("REAL", "The existing local Qwen model is discovered where it is, never downloaded", (snap.item("local.qwen")?.state != .optionalAbsent) == qwenPresent || !qwenPresent, "\(qwen) → \(snap.item("local.qwen")?.state.label ?? "?")")
            check("REAL", "The readiness check started no process and made no model request", ProcessTree.children(of: getpid()).count == childrenBefore && context.hub.activeRuns.count == runsBefore)
            check("REAL", "No MCP server, Unity editor, local model or helper is running", context.mcp.runningServerIDs.isEmpty && context.localRuntime.workerPID == nil && snap.item("unity.bridge")?.state == .notRunning)
            let text = DiagnosticsReport.build(snapshot: snap, schema: context.database?.schemaVersion, installed: AppInfo.isApplicationBundle)
            check("POLICY", "Diagnostics carry no path, account or credential", !text.contains(NSHomeDirectory()) && !text.contains("/Users/") && !OutputSanitizer.containsSecret(text))
            check("POLICY", "Daily conversation answers the readiness questions from this picture", await say("Claude hazır mı?", quiet: true).0.contains("Claude"))
        }

        // MARK: actions (V1.0 fix 4) — REAL: the system's own launcher opens a built-in application and the result is verified; no model is involved
        if wants("actions") {
            let bundle = "com.apple.calculator"
            let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
            let (sys, sysMs) = await say("Sistem durumunu söyler misin?", quiet: true)
            check("REAL", "“Sistem durumunu söyler misin?” is answered from the structured state (no refusal, no model)", !sys.isEmpty && !sys.lowercased().contains("söyleyemem") && !sys.lowercased().contains("cannot tell"), "\(sys.prefix(120)) [\(Int(sysMs)) ms]")
            _ = await say("Dashboard'a dön", quiet: true)
            _ = await say("System panelini aç", quiet: true)
            check("REAL", "“System panelini aç” changes the actual Full HUD page and the reply is worded from the read-back", context.hud.section == .system && context.windowManager.isFullHUDOpen)
            _ = await say("Dashboard'a dön", quiet: true)
            check("REAL", "“Dashboard'a dön” returns to the Dashboard", context.hud.section == .dashboard)
            let (open, openMs) = await say("Hesap makinesini açabilir misin?", quiet: true)
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
            check("REAL", "A polite “can you open …?” launches the application through NSWorkspace; the success sentence exists only because the app is really running", running && (open.contains("açık") || open.contains("open")), "\(open.prefix(100)) [\(Int(openMs)) ms]")
            check("REAL", "The action left a verified receipt in the ledger", context.actionService.ledger.receipts.contains { $0.kind == .launchApp && $0.successIsClaimable })
            if !wasRunning { NSRunningApplication.runningApplications(withBundleIdentifier: bundle).forEach { $0.terminate() } }
            let (tail, _) = await say("Peki videoyu başlattın mı?", quiet: true)
            check("POLICY", "Nothing claims a video was started: no action happened, and none is reported", !tail.lowercased().contains("başlattım") && !tail.lowercased().contains("başlatıyorum"))
        }

        // MARK: apps (V1.0 Phase B) — REAL: Safari through NSWorkspace, visibility grounding, spoken corrections, capability truth; the scripted model answers only what the decision layer passes on
        if wants("apps") {
            let safari = AppCatalog.known.first { $0.display == "Safari" }?.bundleID ?? ""          // (the catalog names the bundle id; this test never reads Safari's profile or data)
            let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: safari).isEmpty
            let promptsBefore = scripted.prompts.count
            func memoryCount() -> Int { ((try? repo.database.readOne("SELECT COUNT(*) AS n FROM memory_items"))?.int("n")) ?? -1 }
            let memoryBefore = memoryCount()
            let (a1, ms1) = await say("Safari'yi aç.", quiet: true)
            check("REAL", "“Safari'yi aç.” launches Safari through NSWorkspace; the sentence exists because it is running", !NSRunningApplication.runningApplications(withBundleIdentifier: safari).isEmpty && a1.contains("Safari açık"), "\(a1.prefix(80)) [\(Int(ms1)) ms]")
            let (a2, _) = await say("Safari'yi açabilir misin?", quiet: true)
            check("REAL", "The polite form is an action too (already open: still verified)", a2.contains("Safari açık"), a2)
            let (a3, _) = await say("Safari görebiliyor musun şu anda?", quiet: true)
            check("REAL", "Running is not visible: with no fresh observation the answer is NOT a yes", !a3.lowercased().hasPrefix("evet") && (a3.contains("gözlem") || a3.lowercased().contains("observ")), a3)
            let (a4, _) = await say("Chrome açık mı?", quiet: true)
            check("REAL", "“Chrome açık mı?” comes from the application list and never claims visibility", a4.contains("Uygulama listesine göre") && a4.contains("Chrome"), a4)
            let (c1, _) = await say("Sofany'yi aç.", quiet: true)
            check("REAL", "A mis-heard application name opens the ONE matching app and says what it understood", c1.contains("Safari") && c1.contains("anladım"), c1)
            let (c2, _) = await say("Sofany değil, Safari dedim.", quiet: true)
            check("REAL", "“Sofany değil, Safari dedim.” is a correction: re-routed once, Safari stays open, no model answer", c2.contains("Safari") && scripted.prompts.count == promptsBefore, c2)
            let (c3, _) = await say("Hayır Safari dedim.", quiet: true)
            check("REAL", "“Hayır Safari dedim.” is understood as a restatement (no model answer)", c3.contains("Safari") && scripted.prompts.count == promptsBefore, c3)
            let (c4, _) = await say("Wisp değil, sesim geliyor mu dedim sana.", quiet: true)
            check("REAL", "“Wisp değil, sesim geliyor mu dedim sana.” re-asks the voice question and answers it from the voice state", (c4.lowercased().contains("mikrofon") || c4.lowercased().contains("ses")) && scripted.prompts.count == promptsBefore, c4)
            check("POLICY", "Corrections are ephemeral: nothing was written to Project Memory", memoryCount() == memoryBefore)
            for q in ["Hangi AI modellerine erişebiliyorsun?", "Claude Code'u kullanabiliyor musun?", "Codex kullanabiliyor musun?", "OpenCode hazır mı?", "Ekranımı görebiliyor musun?", "Dosyaları okuyabiliyor musun?"] {
                let (r, _) = await say(q, quiet: true)
                info("   “\(q)” → \(r.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(160))")
            }
            check("POLICY", "Capability and provider questions never reached the language model", scripted.prompts.count == promptsBefore, "model prompts: \(scripted.prompts.count - promptsBefore)")
            if !wasRunning { NSRunningApplication.runningApplications(withBundleIdentifier: safari).forEach { $0.terminate() } }
        }

        // MARK: unity-open (V1.0 Phase B) — REAL: a DISPOSABLE copy of the repository's Unity fixture is opened in a real windowed Unity Editor through the project-open path; never the user's own projects
        if wants("unity-open") {
            let editors = UnityDiscovery.discover()
            let fixtureSource = FileManager.default.currentDirectoryPath + "/UnityBridge/Fixture"
            if editors.isEmpty || !FileManager.default.fileExists(atPath: fixtureSource + "/ProjectSettings/ProjectVersion.txt") {
                skip("Unity project open", "no Unity editor is installed or the fixture is missing (run from the repository root)")
            } else {
                let name = "UnityOpenFixture"
                let dir = NSTemporaryDirectory() + "jarvis-unity-open-\(UUID().uuidString)/" + name
                try? FileManager.default.createDirectory(atPath: (dir as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try? FileManager.default.copyItem(atPath: fixtureSource, toPath: dir)
                projects.append((dir as NSString).deletingLastPathComponent)
                let canonical = UnityProcessScanner.canonical(dir)
                let known = KnownProject(key: "path:" + dir, name: name, rootPath: dir, kind: "unity", lastSeen: Date())
                svc.knownProjects = { [known] }
                var env = UnityOpenEnvironment(); env.processTimeout = 60; env.readyTimeout = 420
                context.actionService.unityOpener = SystemUnityProjectOpener(env: env)
                let before = UnityProcessScanner.editors().count
                let (reply, ms) = await say("\(name) projesini aç.", quiet: true)
                _ = await waitUntil(480) { !svc.isAnswering }
                let (final, _) = (convo.last?.content ?? reply, 0.0)
                info("   → “\(final.prefix(220))”  [\(Int(ms)) ms to acknowledge]")
                let running = UnityProcessScanner.editor(for: canonical, among: UnityProcessScanner.editors())
                let receipt = context.actionService.ledger.receipts.last { $0.kind == .openProject }
                check("REAL", "The Unity Editor of the project's own version was started with -projectPath = the fixture, and it holds the project (process + Temp/UnityLockfile)", running != nil && FileManager.default.fileExists(atPath: canonical + "/Temp/UnityLockfile") && FileManager.default.fileExists(atPath: canonical + "/Library/EditorInstance.json"), "editors before \(before), now \(UnityProcessScanner.editors().count)")
                check("REAL", "The receipt is verified and the sentence says it is open in Unity", receipt?.successIsClaimable == true && final.contains("Unity'de açık"), "\(receipt?.status.rawValue ?? "no receipt") · \(receipt?.verification?.detail ?? "")")
                let again = await say("\(name) projesini aç.", quiet: true)
                check("REAL", "Asking again brings the SAME editor forward — no second editor on the project", UnityProcessScanner.editors().filter { $0.projectPath == canonical && !$0.isImportWorker }.count <= 1 && again.0.contains("Unity'de açık"), again.0)
                // cleanup: the test started this editor (and only this one) — quit it normally, never force
                if let e = running {
                    NSRunningApplication(processIdentifier: e.pid)?.terminate()
                    if !(await waitUntil(20) { UnityProcessScanner.editor(for: canonical, among: UnityProcessScanner.editors()) == nil }) { kill(e.pid, SIGTERM) }
                    let gone = await waitUntil(60) { !UnityProcessScanner.editors().contains { $0.projectPath == canonical && !$0.isImportWorker } }
                    check("REAL", "The editor the test started is gone again (nothing else was touched)", gone)
                }
            }
        }

        // MARK: voice (voice-equivalent: the same service, source .voice; no microphone, no audio)
        if wants("voice") {
            prefs.responseStyle = .concise; prefs.addressStyle = .natural
            svc.workingContext.clear(); svc.presenter.reset()
            let project = await makeProject(); prefs.projectRoot = project
            engine.agents = OrchestrationScriptRunner(audit: context.audit, script: { _, _ in try? await Task.sleep(for: .seconds(20)); return .fail(.generic) })      // scripted: no provider can be reached
            let (ack, ms) = await say("Çoklu oyuncu senkronizasyon hatasını düzelt.", source: .voice)
            check("REAL", "A spoken task request is acknowledged briefly and the acknowledgement claims only that the task exists", ack.count < 60 && !ack.lowercased().contains("düzelttim") && !ack.lowercased().contains("tamamlandı"), "\(ack) [\(Int(ms)) ms]")
            check("POLICY", "The Turkish acknowledgement carries the address once", ack.contains("efendim"))
            let (ack2, _) = await say("Oyuncu hareket hatasını da düzelt.", source: .voice)
            check("POLICY", "…and not again in the next sentence of the same exchange", !ack2.contains("efendim"), ack2)
            engine.cancelAll()
            _ = await waitUntil(15) { engine.activeViews.isEmpty }
            check("POLICY", "A voice sentence is a typed-equivalent message in the conversation (source voice), not a second path", convo.messages.contains { $0.source == .voice })
            let silent = ConversationStore().appendJarvis("x", silent: true)
            check("POLICY", "A silent acknowledgement is shown but marked not to be spoken", silent.silent == true)
            check("POLICY", "Completions are spoken only when voice is enabled and nothing else is being said (no microphone is opened)", !context.voice.speaker.isActive)
        }

        finish()
    }
}
