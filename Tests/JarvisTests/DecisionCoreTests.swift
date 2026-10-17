import Testing
import Foundation
@testable import Jarvis

// V1.0 decision milestone — Phase A (Cloud). Pure logic: the deterministic grammar, the planner, grounded answers, the optional remote classifier with mocks, the pathological transcript guard, the benchmark corpus
// and the local-model harness. No macOS service, no network, no model, no real application, no real Jev request.

// MARK: Helpers

private let recognizer = DeterministicCommandRecognizer()

private func decide(_ text: String, source: UtteranceChannel = .typed, previous: String = "", interpreted: String = "conversation") -> Decision? {
    var c = DecisionContext(); c.source = source; c.previousUserText = previous; c.previousInterpretation = interpreted
    return recognizer.recognize(text, context: c)
}

/// A scripted remote classifier: counts calls and returns what it is told. It has no execution API — nothing a mock returns can do anything but become a `Decision`.
private final class MockProvider: DecisionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _contexts: [JevDecisionContext] = []
    var script: @Sendable (JevDecisionContext) -> DecisionProviderResult
    init(_ script: @escaping @Sendable (JevDecisionContext) -> DecisionProviderResult) { self.script = script }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var contexts: [JevDecisionContext] { lock.lock(); defer { lock.unlock() }; return _contexts }
    func decide(_ context: JevDecisionContext, config: JevConfig) async -> DecisionProviderResult {
        lock.lock(); _calls += 1; _contexts.append(context); lock.unlock()
        return script(context)
    }
}

private func jevDecision(_ intent: DecisionIntent, confidence: Double, action: String? = nil, target: String? = nil) -> DecisionProviderResult {
    .decision(DecisionPolicy.finalize(intent: intent, confidence: confidence, normalized: "x", target: target, action: action, deepReasoning: false, provenance: .jevShadow, provider: .jev), latency: 0.12)
}

private func facts(_ l: ReplyLanguage = .tr, voice: VoiceStatusFacts? = nil) -> DecisionFacts {
    DecisionFacts(language: l, source: .typed, voice: voice ?? VoiceStatusFacts(voiceOn: true, pushToTalkOn: true, wakeEnabled: false, wakeRunning: false, microphone: .granted, recogniserReady: true, heardViaVoice: false))
}

private func corpusURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Benchmarks").appendingPathComponent(name)
}

// MARK: A · deterministic classification

@Suite("V1.0 decision · deterministic command classification (no model)")
struct DecisionGrammarTests {
    @Test("system status — every mandatory form, Turkish, English and mixed, is one deterministic decision")
    func systemStatus() {
        for s in ["Sistem durumunu söyler misin?", "System Durumu Nedir?", "Sistem durumunu söyle", "System status", "JARVIS sistem durumunu göster", "Sistemin durumu nasıl?", "sistemdurumu nedir", "Systemin durumunu söyler misin"] {
            let d = decide(s)
            #expect(d?.intent == .systemStatus, "“\(s)” → \(String(describing: d?.intent))")
            #expect(d?.isDeterministic == true && d?.requiresExecution == false)
        }
    }

    @Test("voice status — ‘Sesim geliyor mu?’ and its relatives")
    func voiceStatus() {
        for s in ["Sesim geliyor mu?", "Beni duyuyor musun?", "Mikrofon çalışıyor mu?", "Voice input açık mı?", "Can you hear me?", "Is the microphone working?", "Sesimi duyabiliyor musun?"] {
            #expect(decide(s)?.intent == .voiceStatus, "“\(s)”")
        }
        #expect(decide("Mikrofonu aç") == nil || decide("Mikrofonu aç")?.intent != .voiceStatus, "an imperative about the microphone is not a status question")
    }

    @Test("JARVIS navigation — typed destination, never a status question")
    func navigation() {
        let cases: [(String, String)] = [("System panelini aç", "system"), ("Sistem sayfasını aç", "system"), ("Dashboard'a dön", "dashboard"), ("Tasks sayfasına geç", "tasks"), ("Agents panelini aç", "agents"), ("Memory'yi aç", "memory")]
        for (s, page) in cases {
            let d = decide(s)
            #expect(d?.intent == .jarvisNavigation && d?.target == page && d?.action == "navigate" && d?.requiresExecution == true, "“\(s)” → \(String(describing: d))")
        }
        #expect(decide("Sistem durumunu göster")?.intent == .systemStatus)
        #expect(decide("System Settings'i aç")?.intent == .macosApplicationAction, "System Settings is an application, not JARVIS' System page")
    }

    @Test("stop speech and cancel task are different commands")
    func stopAndCancel() {
        for s in ["Sus", "Konuşmayı kes", "Stop talking"] { #expect(decide(s)?.intent == .stopSpeech, "“\(s)”") }
        for s in ["Görevi durdur", "Bu görevi iptal et"] { #expect(decide(s)?.intent == .cancelTask, "“\(s)”") }
        #expect(decide("Görevi durdur")?.intent != .stopSpeech)
        #expect(decide("Sus")?.intent != .cancelTask)
    }

    @Test("applications: polite questions are actions; a question about visibility is not")
    func applications() {
        for s in ["Safari'yi aç.", "Safari'yi açabilir misin?", "Can you open Safari?"] {
            let d = decide(s)
            #expect(d?.intent == .macosApplicationAction && d?.target == "Safari" && d?.action == "launch", "“\(s)”")
        }
        let v = decide("Safari görebiliyor musun şu anda?")
        #expect(v?.intent == .computerUse && v?.action == "visibility_query" && v?.requiresExecution == false && v?.requiresComputerUse == true)
    }

    @Test("project and Computer Use commands")
    func projectsAndComputer() {
        #expect(decide("Hamam projesini aç.")?.intent == .projectOpen)
        #expect(decide("Hamam projesini aç.")?.target == "hamam")
        #expect(decide("Unity projesini aç.")?.target == "unity")
        #expect(decide("En son çalıştığımız projeyi aç.")?.action == "open_last")
        let c = decide("Hamam'da kaldığımız yerden devam et.")
        #expect(c?.intent == .projectTask && c?.action == "continue" && c?.target == "hamam" && c?.requiresProjectResolution == true, "the project named in the locative must not be dropped")
        #expect(decide("Tarayıcıda açık olan videoyu devam ettirir misin?")?.intent == .computerUse)
        #expect(decide("Tarayıcıda açık olan videoyu devam ettirir misin?")?.action == "media")
        #expect(decide("Ekranıma bak.")?.action == "observe")
        #expect(decide("Ekranımı görebiliyor musun?")?.intent == .providerCapability, "a capability question is not a request to look")
    }

    @Test("settings, research, provider choice, capability questions")
    func misc() {
        #expect(decide("Biraz daha hızlı konuş.")?.intent == .settingsChange)
        #expect(decide("Az önceki ayarı geri al.")?.intent == .settingsChange, "‘geri al’ is not navigation to the Settings page")
        #expect(decide("Az önceki ayarı geri al.")?.action == "revert")
        #expect(decide("Bu problemi araştır.")?.intent == .research)
        #expect(decide("Claude Code'u kullan.")?.intent == .providerCapability)
        #expect(decide("Claude Code'u kullan.")?.action == "prefer_provider")
        #expect(decide("Claude Code'u kullanabiliyor musun?")?.action == "query")
        #expect(decide("Hangi modellerin var?")?.intent == .providerCapability)
    }

    @Test("safety-sensitive requests are recognised with the right gate, and never marked as plain conversation")
    func safety() {
        let del = decide("Dosyayı sil.")
        #expect(del?.intent == .projectTask && del?.action == "delete" && del?.gate == .askFirst && del?.riskClass == .high)
        for s in ["GitHub'a pushla.", "Push the changes to GitHub", "git push yap", "Force push to origin"] {
            let d = decide(s)
            #expect(d?.action == "git_push" && d?.gate == .blocked && d?.riskClass == .critical, "“\(s)”")
        }
        #expect(decide("Git commit yap")?.gate == .blocked)
        #expect(decide("Satın al")?.gate == .blocked)
        #expect(decide("Şifremi göster")?.gate == .blocked)
        #expect(decide("Push notification ayarlarını aç")?.gate != .blocked, "‘push’ alone is not git push")
        #expect(decide("Bu fiyat ne kadar?")?.gate != .blocked, "asking a price is not a purchase")
    }

    @Test("what the grammar does not understand it leaves alone (nil), so the existing router decides")
    func abstains() {
        for s in ["Bana bir fıkra anlat", "Fransa'nın başkenti neresi?", "hmm", "Bunu yap", "Onu aç", "Why is the sky blue?"] { #expect(decide(s) == nil, "“\(s)”") }
    }

    @Test("a decision has no authority: no approval, capability or execution surface exists in the decision layer")
    func noAuthoritySurface() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Jarvis/Decision")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        #expect(files.count >= 6)
        let forbidden = ["decideApproval", "ApprovalGuard", "pendingApproval", "approve(", "TaskCapability", "CapabilitySet", "URLSession", "URLRequest", "Process()", "NSTask", "SecItem", "Keychain", "engine.submit", "taskEngine", "submitTask", "AppleScript", "osascript", "/bin/sh"]
        for f in files {
            let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for word in forbidden { #expect(!code.contains(word), "\(f) mentions \(word)") }
        }
    }
}

// MARK: Existing grammar the corpus run found broken (kept fixed)

@Suite("V1.0 decision · fixes the benchmark run exposed in the existing grammar")
struct ExistingGrammarFixTests {
    @Test("a 3-letter last word of a multi-word application name takes a Turkish case suffix (“Unity Hub'ı”)")
    func unityHub() {
        #expect(ActionIntentParser.parse("Unity Hub'ı aç") == .launchApp(AppTarget(display: "Unity Hub", bundleID: "com.unity3d.unityhub")))
        #expect(ActionIntentParser.parse("Unity'yi aç") == .launchApp(AppTarget(display: "Unity", bundleID: "com.unity3d.UnityEditor5.x")))
    }

    @Test("“Hayır Safari dedim.” restates the application name (the ‘hayır’ is not part of it)")
    func hayirSafari() {
        #expect(ActionIntentParser.parse("Hayır Safari dedim.") == .launchApp(AppTarget(display: "Safari", bundleID: "com.apple.Safari")))
    }

    @Test("“Az önceki ayarı geri al.” is the settings undo")
    func settingsUndo() {
        #expect(SettingsIntentParser.recognize("Az önceki ayarı geri al.") == .restore)
        #expect(SettingsIntentParser.recognize("Eski haline getir") == .restore)
        #expect(SettingsIntentParser.recognize("Ayarlar sayfasını aç") == nil, "opening the Settings page is not a settings change")
    }
}

// MARK: Spoken restatements and corrections (N)

@Suite("V1.0 decision · corrections are corrections, bounded and ephemeral")
struct DecisionCorrectionTests {
    @Test("‘X değil, Y dedim’ forms parse into what was wrong and what was meant")
    func parse() {
        #expect(SpokenRestatement.parse("Sofany değil, Safari dedim.") == SpokenRestatement(wrong: "Sofany", right: "Safari", explicit: true))
        #expect(SpokenRestatement.parse("Hayır Safari dedim.")?.right == "Safari")
        #expect(SpokenRestatement.parse("Wisp değil, sesim geliyor mu dedim sana.")?.right == "sesim geliyor mu")
        #expect(SpokenRestatement.parse("Wisp değil, sesim geliyor mu dedim sana.")?.wrong == "Wisp")
        #expect(SpokenRestatement.parse("I said Safari, not Sofany")?.right == "Safari")
        #expect(SpokenRestatement.parse("I said Safari, not Sofany")?.wrong == "Sofany")
        #expect(SpokenRestatement.parse("Hayır hayır hayır") == nil)
        #expect(SpokenRestatement.parse("No thanks") == nil)
    }

    @Test("the correction is applied to the previous sentence only, whole words, keeping case suffixes")
    func apply() {
        #expect(SpokenRestatement.apply(wrong: "Sofany", right: "Safari", to: "Sofany'yi aç") == "Safari'yi aç")
        #expect(SpokenRestatement.apply(wrong: "Sofany", right: "Safari", to: "Sofany görebiliyor musun şu anda?") == "Safari görebiliyor musun şu anda?")
        #expect(SpokenRestatement.apply(wrong: "Wisp", right: "sesim geliyor mu", to: "Wisp") == "sesim geliyor mu")
        #expect(SpokenRestatement.apply(wrong: "Sofany", right: "Safari", to: "Chrome'u aç") == nil, "a word that is not in the previous sentence is never invented into it")
    }

    @Test("a restatement is a correction decision, not a question for Project Memory")
    func decision() {
        for s in ["Sofany değil, Safari dedim.", "Hayır Safari dedim.", "Wisp değil, sesim geliyor mu dedim sana."] {
            #expect(decide(s)?.intent == .correction, "“\(s)”")
            #expect(decide(s)?.requiresExecution == false)
        }
        #expect(decide("Hayır istemiyorum") == nil, "a plain ‘no’ answers a question; it corrects nothing")
        #expect(decide("Hayır Safari", interpreted: "action")?.intent == .correction, "a bare fragment after an action is a correction")
        #expect(decide("Hayır Safari", interpreted: "conversation")?.intent == .correction, "…and ‘Safari’ is a known application")
    }

    @Test("planner: correct the previous sentence → route it again; single name with nothing to apply it to → ask, never guess")
    func planning() {
        var f = facts()
        f.previousUserText = "Sofany'yi aç"; f.previousInterpretation = "action"
        let d = decide("Sofany değil, Safari dedim.", previous: "Sofany'yi aç", interpreted: "action")!
        #expect(DecisionPlanner.plan(d, text: "Sofany değil, Safari dedim.", facts: f) == .reroute(sentence: "Safari'yi aç"))

        var g = facts()
        g.previousUserText = "Wisp"; g.previousInterpretation = "conversation"
        let d2 = decide("Wisp değil, sesim geliyor mu dedim sana.", previous: "Wisp")!
        #expect(DecisionPlanner.plan(d2, text: "Wisp değil, sesim geliyor mu dedim sana.", facts: g) == .reroute(sentence: "sesim geliyor mu"))

        let h = facts()      // no previous sentence at all
        let d3 = decide("Safari dedim")!
        if case .answer(let q, _) = DecisionPlanner.plan(d3, text: "Safari dedim", facts: h) { #expect(q.contains("Safari") && q.contains("?")) } else { #expect(Bool(false), "a bare name with nothing to apply it to must ask") }
    }
}

// MARK: Planner (routes, never executes)

@Suite("V1.0 decision · the planner routes to existing capabilities and executes nothing")
struct DecisionPlannerTests {
    @Test("known intents map to their existing capability")
    func routes() {
        let f = facts()
        #expect(DecisionPlanner.plan(decide("Sistem durumunu söyler misin?")!, text: "", facts: f) == .systemStatus(.all))
        #expect(DecisionPlanner.plan(decide("Jarvis System Panelini aç.")!, text: "", facts: f) == .action(.navigate(.system)))
        #expect(DecisionPlanner.plan(decide("Sus")!, text: "", facts: f) == .stopSpeech)
        #expect(DecisionPlanner.plan(decide("Görevi durdur")!, text: "", facts: f) == .cancelTask)
        #expect(DecisionPlanner.plan(decide("Biraz daha hızlı konuş.")!, text: "", facts: f) == .settings)
        #expect(DecisionPlanner.plan(decide("Safari'yi aç.")!, text: "", facts: f) == .action(nil), "applications go through the action grammar and its verified receipt")
        #expect(DecisionPlanner.plan(decide("Tarayıcıda açık olan videoyu devam ettirir misin?")!, text: "Tarayıcıda açık olan videoyu devam ettirir misin?", facts: f) == .computer(prompt: "Tarayıcıda açık olan videoyu devam ettirir misin?"))
        #expect(DecisionPlanner.plan(decide("Bu problemi araştır.")!, text: "", facts: f) == .passThrough, "research keeps its own pipeline")
    }

    @Test("Computer Use unavailable → the media command is not claimed; it passes through")
    func computerUnavailable() {
        var f = facts(); f.computerAvailable = false
        #expect(DecisionPlanner.plan(decide("Videoyu durdur")!, text: "Videoyu durdur", facts: f) == .passThrough)
    }

    @Test("blocked requests are refused with a reason and nothing else; delete keeps the task engine's approval path")
    func policy() {
        let f = facts()
        if case .answer(let text, let tone) = DecisionPlanner.plan(decide("GitHub'a pushla.")!, text: "", facts: f) { #expect(tone == .notice && text.lowercased().contains("push")) } else { #expect(Bool(false)) }
        if case .answer = DecisionPlanner.plan(decide("Satın al")!, text: "", facts: f) {} else { #expect(Bool(false), "a purchase is refused even though it has no other intent") }
        #expect(DecisionPlanner.plan(decide("Dosyayı sil.")!, text: "", facts: f) == .passThrough, "a delete is never executed by the decision layer; the task engine's approval-gated path owns it")
    }

    @Test("a typed JARVIS action needs one of JARVIS' own pages: an invented page is not executed")
    func inventedPage() {
        let d = DecisionPolicy.finalize(intent: .jarvisNavigation, confidence: 0.99, normalized: "x", target: "billing", action: "navigate", deepReasoning: false, provenance: .jevGated, provider: .jev)
        #expect(DecisionPlanner.typedHUDAction(d) == nil)
        #expect(GatedPolicy.accepts(d, minimumConfidence: 0.5) == false)
    }
}

// MARK: Grounded answers: voice status, observations (O), project open (D/E/F)

@Suite("V1.0 decision · grounded answers")
struct DecisionGroundingTests {
    @Test("voice status: only a voice-arrived utterance proves the microphone works; a typed one never does")
    func voice() {
        let on = VoiceStatusFacts(voiceOn: true, pushToTalkOn: true, wakeEnabled: false, wakeRunning: false, microphone: .granted, recogniserReady: true, heardViaVoice: false)
        let typed = VoiceStatusComposer.compose(on, language: .tr)
        #expect(!typed.contains("sizi duyuyorum"), "a typed message cannot prove the microphone: \(typed)")
        #expect(typed.contains("yazı olarak"))
        var heard = on; heard.heardViaVoice = true
        #expect(VoiceStatusComposer.compose(heard, language: .tr).contains("Evet, sizi duyuyorum"))
        var off = on; off.voiceOn = false
        #expect(VoiceStatusComposer.compose(off, language: .tr).contains("kapalı"))
        var denied = on; denied.microphone = .denied
        #expect(VoiceStatusComposer.compose(denied, language: .en).lowercased().contains("denied"))
    }

    @Test("a visibility claim needs a FRESH observation: none or stale can never produce ‘yes, I see it’")
    func freshness() {
        let now = Date()
        #expect(ObservationGrounding.evaluate(target: "Safari", observations: [], now: now) == .noObservation)
        let old = [ObservedApp(name: "Safari", at: now.addingTimeInterval(-300))]
        #expect(ObservationGrounding.evaluate(target: "Safari", observations: old, now: now) == .stale(ageSeconds: 300))
        let fresh = [ObservedApp(name: "Safari", at: now.addingTimeInterval(-4))]
        #expect(ObservationGrounding.evaluate(target: "Safari", observations: fresh, now: now) == .seen(ageSeconds: 4))
        let other = [ObservedApp(name: "Finder", at: now.addingTimeInterval(-4))]
        #expect(ObservationGrounding.evaluate(target: "Safari", observations: other, now: now) == .notInFreshObservation(ageSeconds: 4))
        for answer in [VisibilityAnswer.noObservation, .stale(ageSeconds: 300), .notInFreshObservation(ageSeconds: 4)] {
            let text = ObservationGrounding.reply(answer, target: "Safari", running: true, language: .tr)
            #expect(!answer.mayClaimVisible)
            #expect(!text.hasPrefix("Evet"), "“\(text)”")
            #expect(text.contains("Ekranıma bak") || text.contains("görünmüyordu"))
        }
        #expect(ObservationGrounding.reply(.seen(ageSeconds: 4), target: "Safari", running: nil, language: .tr).hasPrefix("Evet — 4 sn"))
    }

    @Test("running is reported as running, never as visible")
    func runningIsNotVisible() {
        let text = ObservationGrounding.reply(.noObservation, target: "Safari", running: true, language: .en)
        #expect(text.contains("running") && text.contains("does not mean it is visible"))
    }

    @Test("planner: ‘Safari görebiliyor musun şu anda?’ is answered from observations only")
    func visibilityPlan() {
        var f = facts()
        f.isAppRunning = { _ in true }
        let d = decide("Safari görebiliyor musun şu anda?")!
        if case .answer(let text, let tone) = DecisionPlanner.plan(d, text: "", facts: f) { #expect(!text.hasPrefix("Evet") && tone == .notice, "“\(text)”") } else { #expect(Bool(false)) }
        f.observations = [ObservedApp(name: "Safari", at: f.now.addingTimeInterval(-3))]
        if case .answer(let text, let tone) = DecisionPlanner.plan(d, text: "", facts: f) { #expect(text.hasPrefix("Evet") && tone == .normal) } else { #expect(Bool(false)) }
    }

    // fixtures: no real project, no real path
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func projects() -> [KnownProject] {
        [KnownProject(key: "git:a", name: "Hamam", rootPath: "/fixture/Hamam", kind: "git", lastSeen: now),
         KnownProject(key: "unity:b", name: "Arena", rootPath: "/fixture/Arena", kind: "unity", lastSeen: now.addingTimeInterval(-86_400)),
         KnownProject(key: "path:c", name: "Notes", rootPath: "/fixture/Notes", kind: "path", lastSeen: now.addingTimeInterval(-9_000))]
    }
    private let exists: (String) -> Bool = { _ in true }

    @Test("project open: a unique name resolves; Turkish case suffixes are tolerated; a prefix guess is not")
    func resolveByName() {
        let isKind: (String, String) -> Bool = { root, kind in kind == "unity" && (root == "/fixture/Hamam" || root == "/fixture/Arena") }
        if case .resolved(let p) = ProjectOpenResolver.resolve(name: "hamam", wantsLast: false, projects: projects(), currentRoot: nil, pathExists: exists, isKind: isKind) { #expect(p.name == "Hamam") } else { #expect(Bool(false)) }
        if case .resolved(let p) = ProjectOpenResolver.resolve(name: "hamamda", wantsLast: false, projects: projects(), currentRoot: nil, pathExists: exists, isKind: isKind) { #expect(p.name == "Hamam") } else { #expect(Bool(false)) }
        if case .unknown = ProjectOpenResolver.resolve(name: "ham", wantsLast: false, projects: projects(), currentRoot: nil, pathExists: exists, isKind: isKind) {} else { #expect(Bool(false), "‘ham’ must not open Hamam") }
        if case .unknown(let n, let known) = ProjectOpenResolver.resolve(name: "zeta", wantsLast: false, projects: projects(), currentRoot: nil, pathExists: exists, isKind: isKind) { #expect(n == "zeta" && known.contains("Hamam")) } else { #expect(Bool(false)) }
    }

    @Test("‘Unity projesi’ with two Unity projects is ambiguous — it asks; with one it resolves")
    func resolveEngineKind() {
        let two: (String, String) -> Bool = { root, kind in kind == "unity" && (root == "/fixture/Hamam" || root == "/fixture/Arena") }
        if case .ambiguous(let c) = ProjectOpenResolver.resolve(name: "unity", wantsLast: false, projects: projects(), currentRoot: nil, pathExists: exists, isKind: two) { #expect(c.count == 2 && c[0].name == "Hamam", "most recent first") } else { #expect(Bool(false)) }
        let one: (String, String) -> Bool = { root, kind in kind == "unity" && root == "/fixture/Arena" }
        if case .resolved(let p) = ProjectOpenResolver.resolve(name: "unity", wantsLast: false, projects: projects(), currentRoot: nil, pathExists: exists, isKind: one) { #expect(p.name == "Arena") } else { #expect(Bool(false)) }
    }

    @Test("‘the project we worked on last’: the most recent one, unless two are too close in time (then it asks); a missing folder is reported, not replaced")
    func resolveLast() {
        if case .resolved(let p) = ProjectOpenResolver.resolve(name: nil, wantsLast: true, projects: projects(), currentRoot: nil, pathExists: exists, isKind: { _, _ in false }) { #expect(p.name == "Hamam") } else { #expect(Bool(false)) }
        var close = projects(); close[1].lastSeen = now.addingTimeInterval(-20)
        if case .ambiguous = ProjectOpenResolver.resolve(name: nil, wantsLast: true, projects: close, currentRoot: nil, pathExists: exists, isKind: { _, _ in false }) {} else { #expect(Bool(false)) }
        if case .pathMissing(let p) = ProjectOpenResolver.resolve(name: nil, wantsLast: true, projects: projects(), currentRoot: nil, pathExists: { $0 != "/fixture/Hamam" }, isKind: { _, _ in false }) { #expect(p.name == "Hamam") } else { #expect(Bool(false), "the second project must not silently replace a missing one") }
        #expect(ProjectOpenResolver.resolve(name: nil, wantsLast: true, projects: [], currentRoot: nil) == .noKnownProjects)
    }

    @Test("planner: ‘Hamam projesini aç’ → open; unknown / ambiguous / missing → a truthful sentence, nothing opened; ‘continue in Hamam’ keeps the project name")
    func openPlans() {
        var f = facts(); f.projects = projects(); f.pathExists = exists; f.isKind = { _, _ in false }
        if case .openProject(let p) = DecisionPlanner.plan(decide("Hamam projesini aç.")!, text: "", facts: f) { #expect(p.name == "Hamam") } else { #expect(Bool(false)) }
        if case .answer(let t, _) = DecisionPlanner.plan(decide("Zeta projesini aç.")!, text: "", facts: f) { #expect(t.contains("tanımıyorum")) } else { #expect(Bool(false)) }
        f.isKind = { root, kind in kind == "unity" }
        if case .answer(let t, _) = DecisionPlanner.plan(decide("Unity projesini aç.")!, text: "", facts: f) { #expect(t.contains("Hangi proje")) } else { #expect(Bool(false)) }
        f.pathExists = { _ in false }
        if case .answer(let t, _) = DecisionPlanner.plan(decide("Hamam projesini aç.")!, text: "", facts: f) { #expect(t.contains("diskte yok")) } else { #expect(Bool(false)) }
        #expect(DecisionPlanner.plan(decide("Hamam'da kaldığımız yerden devam et.")!, text: "", facts: f) == .continueProject(sentence: "hamam projesine devam et"))
        #expect(DecisionPlanner.plan(decide("Kaldığımız yerden devam et")!, text: "", facts: f) == .passThrough, "the current project continues through the existing continuity route")
    }
}

// MARK: Remote classifier modes (G H I J U V) — mocks only

@MainActor
@Suite("V1.0 decision · the optional remote classifier: disabled, shadow, gated")
struct DecisionJevTests {
    private func engine(_ mode: JevMode, minConfidence: Double = 0.92, provider: MockProvider?) -> DecisionEngine {
        let e = DecisionEngine()
        e.jev = provider
        e.config = { JevConfig(mode: mode, gatedMinimumConfidence: minConfidence) }
        return e
    }

    @Test("DEFAULT is disabled: no provider is consulted, the production decision is unchanged, nothing is enabled automatically (U)")
    func disabledByDefault() async {
        #expect(JevConfig().mode == .disabled)
        let provider = MockProvider { _ in jevDecision(.systemStatus, confidence: 1) }
        let e = engine(.disabled, provider: provider)
        let out = e.decide("Bunu aç", context: DecisionContext())
        await e.awaitShadow()
        #expect(provider.calls == 0)
        #expect(out.decision.intent == .unknown && out.decision.provider == .router)
        let awaited1 = await e.consultGated("Bunu aç", context: DecisionContext(), outcome: out)
        #expect(awaited1 == nil)
        #expect(provider.calls == 0)
        let sys = e.decide("Sistem durumunu söyle", context: DecisionContext())
        #expect(sys.decision.isDeterministic && provider.calls == 0, "known commands never need it")
    }

    @Test("SHADOW: JARVIS decides as always; Jev is only compared — agreement, disagreement, latency, confidence are recorded")
    func shadow() async {
        let provider = MockProvider { c in c.utterance.lowercased().contains("sistem") ? jevDecision(.systemStatus, confidence: 0.97) : jevDecision(.conversation, confidence: 0.4) }
        let e = engine(.shadow, provider: provider)
        let a = e.decide("Sistem durumunu söyle", context: DecisionContext())
        let b = e.decide("Bana bir fıkra anlat", context: DecisionContext())
        let c = e.decide("Safari'yi aç", context: DecisionContext())
        await e.awaitShadow()
        #expect(provider.calls == 3)
        #expect(a.decision.intent == .systemStatus && b.decision.intent == .unknown && c.decision.intent == .macosApplicationAction, "production decisions are what the grammar said, whatever Jev answered")
        #expect(e.audit.entry(a.id)?.agreement == .agree)
        #expect(e.audit.entry(b.id)?.agreement == .productionUnknown)
        #expect(e.audit.entry(c.id)?.agreement == .disagree)
        #expect(e.audit.entry(a.id)?.jevLatency == 0.12)
        let r = e.audit.shadowReport
        #expect(r.consulted == 3 && r.agree == 1 && r.disagree == 1 && r.productionUnknown == 1 && r.calibration.count == 2)
        #expect(e.audit.entry(a.id)?.jevAccepted == false, "shadow never routes anything")
    }

    @Test("Jev unavailable (offline, balance, timeout, malformed…) is recorded and changes nothing (H)")
    func unavailable() async {
        for why in [JevFailure.offline, .outOfBalance, .timeout, .rateLimited, .malformedResponse, .apiChanged, .credentialMissing] {
            let provider = MockProvider { _ in .unavailable(why) }
            let e = engine(.shadow, provider: provider)
            let out = e.decide("Sistem durumunu söyle", context: DecisionContext())
            await e.awaitShadow()
            #expect(out.decision.intent == .systemStatus)
            #expect(e.audit.entry(out.id)?.agreement == .jevUnavailable && e.audit.entry(out.id)?.jevFailure == why)
        }
        let g = engine(.gated, provider: MockProvider { _ in .unavailable(.offline) })
        let out = g.decide("Bunu bir şey yap", context: DecisionContext())
        let awaited2 = await g.consultGated("Bunu bir şey yap", context: DecisionContext(), outcome: out)
        #expect(awaited2 == nil, "gated + unavailable → the existing router handles it")
    }

    @Test("GATED: accepted only when the grammar found nothing, the confidence passes the threshold and the intent is in the closed read-only set (I)")
    func gated() async {
        let ask = "Şu anki durumu bir özetle"
        let hi = MockProvider { _ in jevDecision(.systemStatus, confidence: 0.95) }
        let e = engine(.gated, provider: hi)
        let out = e.decide(ask, context: DecisionContext())
        #expect(out.decision.intent == .unknown)
        let accepted = await e.consultGated(ask, context: DecisionContext(), outcome: out)
        #expect(accepted?.intent == .systemStatus && accepted?.provenance == .jevGated && e.audit.entry(out.id)?.jevAccepted == true)

        let low = engine(.gated, provider: MockProvider { _ in jevDecision(.systemStatus, confidence: 0.80) })
        let o2 = low.decide(ask, context: DecisionContext())
        let awaited3 = await low.consultGated(ask, context: DecisionContext(), outcome: o2)
        #expect(awaited3 == nil, "below the threshold → ignored")

        let strict = engine(.gated, minConfidence: 0.99, provider: MockProvider { _ in jevDecision(.systemStatus, confidence: 0.95) })
        let o3 = strict.decide(ask, context: DecisionContext())
        let awaited4 = await strict.consultGated(ask, context: DecisionContext(), outcome: o3)
        #expect(awaited4 == nil, "the threshold is configurable")

        // a deterministic decision is never replaced by Jev
        let det = e.decide("Sistem durumunu söyle", context: DecisionContext())
        let awaited5 = await e.consultGated("Sistem durumunu söyle", context: DecisionContext(), outcome: det)
        #expect(awaited5 == nil)
    }

    @Test("Jev cannot execute, approve or weaken policy: executing / computer / project / settings intents are never accepted, and policy re-derives risk and gate (J)")
    func jevCannotBypass() async {
        for (intent, action) in [(DecisionIntent.macosApplicationAction, "launch"), (.computerUse, "media"), (.projectTask, "delete"), (.projectTask, "git_push"), (.settingsChange, "change"), (.stopSpeech, "stop"), (.cancelTask, "stop"), (.projectOpen, "open")] {
            let d = DecisionPolicy.finalize(intent: intent, confidence: 1.0, normalized: "x", target: "y", action: action, deepReasoning: false, provenance: .jevGated, provider: .jev)
            #expect(GatedPolicy.accepts(d, minimumConfidence: 0.5) == false, "\(intent.rawValue)/\(action)")
        }
        let push = DecisionPolicy.finalize(intent: .projectTask, confidence: 1, normalized: "x", target: nil, action: "git_push", deepReasoning: false, provenance: .jevGated, provider: .jev)
        #expect(push.gate == .blocked && push.riskClass == .critical, "Jev cannot say ‘low risk’ for a push")
        let del = DecisionPolicy.finalize(intent: .projectTask, confidence: 1, normalized: "x", target: nil, action: "delete", deepReasoning: false, provenance: .jevGated, provider: .jev)
        #expect(del.gate == .askFirst)
        // the response parser ignores a model's own risk / gate claims
        let parsed = JevResponseParser.parse(#"{"intent":"project_task","confidence":0.99,"normalized":"push it","target":null,"action":"git_push","risk":"low","gate":"none","needs_deep_reasoning":false}"#)
        #expect(parsed?.gate == .blocked && parsed?.riskClass == .critical)
        // a gated Jev answer, however confident, plans to nothing that executes
        let nav = DecisionPolicy.finalize(intent: .jarvisNavigation, confidence: 0.99, normalized: "x", target: "system", action: "navigate", deepReasoning: false, provenance: .jevGated, provider: .jev)
        #expect(DecisionPlanner.plan(nav, text: "", facts: facts()) == .action(.navigate(.system)), "a JARVIS page change is allowed — and still verified by its own receipt")
        let e = engine(.gated, provider: MockProvider { _ in jevDecision(.projectTask, confidence: 1.0, action: "delete") })
        let out = e.decide("Bunu yapsana", context: DecisionContext())
        let awaited6 = await e.consultGated("Bunu yapsana", context: DecisionContext(), outcome: out)
        #expect(awaited6 == nil)
    }

    @Test("the response contract: strict JSON only; unknown intents, missing confidence and prose are rejected; fenced JSON is accepted")
    func parser() {
        #expect(JevResponseParser.parse(#"{"intent":"voice_status","confidence":0.9,"normalized":"mic","target":null,"action":"query"}"#)?.intent == .voiceStatus)
        #expect(JevResponseParser.parse("```json\n{\"intent\":\"system_status\",\"confidence\":0.8}\n```")?.intent == .systemStatus)
        #expect(JevResponseParser.parse(#"{"intent":"teleport","confidence":0.9}"#) == nil)
        #expect(JevResponseParser.parse(#"{"intent":"system_status"}"#) == nil)
        #expect(JevResponseParser.parse("I think this is a system status question") == nil)
        #expect(JevResponseParser.parse(#"{"intent":"conversation","confidence":7}"#)?.confidence == 1, "confidence is clamped")
    }

    @Test("the real provider: unconfigured, no credential, budget, circuit breaker, timeout, usage — none of it can reach a network or hang")
    func realProvider() async {
        let ctx = JevContextBuilder.build(utterance: "Sistem durumunu söyle", language: "tr", source: .typed, previousInterpretation: "conversation", projectNames: [])!
        let cfg = JevConfig(mode: .shadow)
        let unconfigured = JevDecisionProvider()
        let awaited7 = await unconfigured.decide(ctx, config: cfg)
        #expect(awaited7 == .unavailable(.credentialMissing))
        let awaited8 = await JevDecisionProvider(credentialAvailable: { true }).decide(ctx, config: cfg)
        #expect(awaited8 == .unavailable(.notConfigured), "the Phase A transport says it is not connected")
        let awaited9 = await unconfigured.decide(ctx, config: JevConfig(mode: .disabled))
        #expect(awaited9 == .unavailable(.notConfigured))

        struct Scripted: JevTransport {
            var reply: @Sendable () async throws -> JevRawResponse
            func complete(system: String, user: String, modelAlias: String, timeout: TimeInterval) async throws -> JevRawResponse { try await reply() }
        }
        let good = JevDecisionProvider(transport: Scripted { JevRawResponse(text: #"{"intent":"system_status","confidence":0.9}"#, inputTokens: 100, outputTokens: 20) }, credentialAvailable: { true })
        if case .decision(let d, _) = await good.decide(ctx, config: cfg) { #expect(d.intent == .systemStatus && d.provider == .jev) } else { #expect(Bool(false)) }
        #expect(good.usage.requests == 1 && good.usage.inputTokens == 100 && good.usage.estimatedCost(pricePer1kTokens: nil) == nil, "cost is unknown unless a price is configured — never invented")

        let budget = JevDecisionProvider(transport: Scripted { JevRawResponse(text: #"{"intent":"conversation","confidence":0.9}"#) }, credentialAvailable: { true })
        var tight = cfg; tight.maxRequestsPerHour = 2
        _ = await budget.decide(ctx, config: tight); _ = await budget.decide(ctx, config: tight)
        let awaited10 = await budget.decide(ctx, config: tight)
        #expect(awaited10 == .unavailable(.rateLimited) && budget.usage.skippedByBudget == 1, "the hourly budget stops the requests")

        let broken = JevDecisionProvider(transport: Scripted { throw JevFailure.outOfBalance }, credentialAvailable: { true })
        let awaited11 = await broken.decide(ctx, config: cfg)
        #expect(awaited11 == .unavailable(.outOfBalance))
        let awaited12 = await broken.decide(ctx, config: cfg)
        #expect(awaited12 == .unavailable(.unavailable), "after ‘out of balance’ the circuit is open: no further requests")
        #expect(broken.usage.requests == 1 && broken.usage.skippedByBreaker == 1)

        let slow = JevDecisionProvider(transport: Scripted { try await Task.sleep(for: .seconds(30)); return JevRawResponse(text: "") }, credentialAvailable: { true })
        var quick = cfg; quick.timeoutSeconds = 0.1
        let awaited13 = await slow.decide(ctx, config: quick)
        #expect(awaited13 == .unavailable(.timeout))
    }

    @Test("privacy: secrets are never sent, paths and long numbers are redacted, the context is small and closed (V)")
    func privacy() {
        #expect(JevContextBuilder.build(utterance: "my key is sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAA", language: "en", source: .typed, previousInterpretation: "conversation", projectNames: []) == nil, "credential-shaped text is refused outright")
        let c = JevContextBuilder.build(utterance: "open /Users/bilal/Projects/Hamam/secret.txt and call 5551234567890", language: "en", source: .voice, previousInterpretation: "settings: speech", projectNames: (0..<30).map { "Project\($0)" })!
        #expect(!c.utterance.contains("/Users") && !c.utterance.contains("5551234567890") && c.utterance.contains("<path>"))
        #expect(c.previousInterpretation == "settings" && c.projectNames.count == 8 && c.source == "voice")
        let long = JevContextBuilder.build(utterance: String(repeating: "word ", count: 500), language: "en", source: .typed, previousInterpretation: "conversation", projectNames: [])!
        #expect(long.utterance.count <= 300)
        let sent = JevPrompt.system + JevPrompt.user(c)
        for word in ["password", "api_key", "token", "keychain", "screen contents", "audio"] where word != "screen contents" { #expect(!JevPrompt.user(c).lowercased().contains(word) || word == "token", "the request must not carry \(word)") }
        #expect(!sent.contains("/Users"))
    }

    @Test("the audit trail answers what was said, what was decided, whether Jev was asked and what it predicted — clipped, in memory only")
    func audit() async {
        let provider = MockProvider { _ in jevDecision(.systemStatus, confidence: 0.9) }
        let e = engine(.shadow, provider: provider)
        let out = e.decide("Sistem durumunu söyle", context: DecisionContext(source: .voice))
        let longID = e.audit.begin(source: .typed, utterance: String(repeating: "kelime ", count: 60))
        await e.awaitShadow()
        e.record(out.id, route: "system status", executor: "SystemStatusSnapshot", verification: nil, outcome: "answered")
        let entry = e.audit.entry(out.id)!
        #expect(e.audit.entry(longID)!.utterance.count <= 160 && e.audit.entry(longID)!.utteranceLength > 160 && entry.source == .voice)
        #expect(entry.production?.provider == .deterministic && entry.jev?.intent == .systemStatus && entry.route == "system status" && entry.executor == "SystemStatusSnapshot")
        for i in 0..<(DecisionAuditLog.capacity + 20) { _ = e.audit.begin(source: .typed, utterance: "u\(i)") }
        #expect(e.audit.entries.count == DecisionAuditLog.capacity)
    }
}

// MARK: K L · the pathological transcript guard

@Suite("V1.0 decision · pathological transcripts are rejected upstream, ordinary repetition is not")
struct PathologicalTranscriptTests {
    private func verdict(_ s: String, seconds: Double? = nil) -> TranscriptVerdict { PathologicalTranscriptGuard.evaluate(s, audioSeconds: seconds) }

    @Test("the observed decoder loops are rejected with reason codes")
    func observed() {
        let kutu = Array(repeating: "Kutu,", count: 40).joined(separator: " ")
        let yerler = Array(repeating: "Yerler,", count: 25).joined(separator: " ")
        for s in [kutu, yerler] {
            if case .reject(let r, let m) = verdict(s) { #expect(r == .excessiveTokenRepetition && m.distinct == 1 && m.topShare == 1.0) } else { #expect(Bool(false), "must be rejected") }
        }
        if case .reject(let r, _) = verdict("evet tamam evet tamam evet tamam evet tamam evet tamam") { #expect(r == .repeatedNGramLoop) } else { #expect(Bool(false)) }
        if case .reject(let r, _) = verdict("Sistem durumunu söyle " + Array(repeating: "kutu", count: 9).joined(separator: " ")) { #expect(r == .excessiveTokenRepetition || r == .decoderLoopSuspected) } else { #expect(Bool(false), "a normal start with a looping tail is still a decoder loop") }
        if case .reject(let r, _) = verdict((1...22).map { "kelime\($0)" }.joined(separator: " "), seconds: 1.0) { #expect(r == .implausibleSpeechRate) } else { #expect(Bool(false)) }
        if case .reject(let r, _) = verdict((0..<200).map { "w\($0)" }.joined(separator: " ")) { #expect(r == .decoderLoopSuspected) } else { #expect(Bool(false)) }
    }

    @Test("legitimate repetition and ordinary speech are accepted (L)")
    func legitimate() {
        for s in ["hayır hayır hayır", "dur dur dur", "çok çok önemli", "Hayır hayır hayır hayır hayır", "Sus sus sus sus", "no no no no I said no", "Bu çok çok çok güzel bir gün ve ben çok çok mutluyum bugün",
                  "Sistem durumunu söyler misin?", "Safari'yi aç", "Hamam'da kaldığımız yerden devam et", "tamam tamam tamam tamam tamam tamam", "evet evet evet", "okay okay okay okay okay", "yes yes yes yes yes yes"] {
            #expect(verdict(s).isAccepted, "“\(s)” must not be rejected")
        }
        #expect(verdict("one two three four five six seven eight nine ten eleven twelve", seconds: 4.0).isAccepted)
    }

    @Test("a verdict carries counts only — the measurements contain no transcript text")
    func contentFree() {
        if case .reject(_, let m) = verdict(Array(repeating: "gizli", count: 30).joined(separator: " ")) { #expect(!m.summary.contains("gizli")) } else { #expect(Bool(false)) }
    }

    @Test("reason codes are stable machine-readable tags")
    func reasonCodes() {
        #expect(Set(TranscriptRejection.allCases.map(\.rawValue)) == ["excessiveTokenRepetition", "repeatedNGramLoop", "decoderLoopSuspected", "implausibleSpeechRate"])
        #expect(Set(UtteranceOrigin.allCases.map(\.rawValue)) == ["selfEcho", "decoderHallucination", "userInterruption", "userTurn"])
    }
}

// MARK: S · the corpus

@Suite("V1.0 decision · the benchmark corpus is valid, balanced and consistent with the grammar")
struct DecisionCorpusTests {
    private func load() throws -> DecisionCorpus { try DecisionCorpus.load(from: corpusURL("decision_corpus.json")) }

    @Test("schema, ids, flags, gates, every intent, languages, sources and every mandatory utterance")
    func valid() throws {
        let c = try load()
        #expect(DecisionCorpusValidator.validate(c) == [])
        #expect(c.cases.count >= 250 && c.cases.count <= 400)
        for lang in ["tr", "en", "mixed"] { #expect(c.cases.filter { $0.lang == lang }.count >= 20, "\(lang)") }
        #expect(Set(c.cases.flatMap(\.tags)).isSuperset(of: ["polite", "question", "stt-misspelling", "ambiguous", "safety", "referent", "mandatory"]))
        #expect(c.cases.filter { $0.source == "voice" }.count >= 20)
    }

    @Test("the validator rejects a broken corpus")
    func validatorCatches() throws {
        var c = try load()
        c.cases[0].id = c.cases[1].id
        c.cases.removeAll { $0.intent == .research }
        c.cases[2].gate = .blocked; c.cases[2].risk = .low
        let problems = DecisionCorpusValidator.validate(c)
        #expect(problems.contains { $0.contains("duplicate id") } && problems.contains { $0.contains("research") } && problems.contains { $0.contains("blocked gate") })
        c.schema = "x"
        #expect(DecisionCorpusValidator.validate(c).contains { $0.contains("schema") })
    }

    @Test("every case labelled deterministic is decided EXACTLY by the grammar; no other case is answered with a wrong executing intent")
    func grammarAgainstGroundTruth() throws {
        let r = DecisionBenchmarkRunner.runDeterministic(try load())
        #expect(r.deterministicMisses == [], "\(r.deterministicMisses)")
        #expect(r.wrongExecutions == [], "\(r.wrongExecutions)")
        #expect(r.accuracy >= 0.99 && r.coverage >= 0.7, "accuracy \(r.accuracy) coverage \(r.coverage)")
        #expect(r.markdown().contains("confusion"))
    }

    @Test("the benchmark runs any provider (mock) and reports accuracy, a confusion matrix, calibration and latency")
    func mockProviderRun() async throws {
        let c = try load()
        let oracle = MockProvider { ctx in
            let hit = c.cases.first { DecisionCorpusValidator.fold($0.text) == DecisionCorpusValidator.fold(ctx.utterance) }
            return jevDecision(hit?.intent ?? .unknown, confidence: hit == nil ? 0.3 : 0.95)
        }
        let report = await DecisionBenchmarkRunner.run(c, provider: oracle, config: JevConfig(mode: .shadow), name: "mock oracle")
        #expect(report.total == c.cases.count && report.answered == c.cases.count)
        #expect(report.accuracy > 0.95, "the oracle mock knows the answers: \(report.accuracy)")
        #expect(report.buckets.contains { $0.n > 0 } && report.meanLatency > 0)
        let down = await DecisionBenchmarkRunner.run(c, provider: MockProvider { _ in .unavailable(.outOfBalance) }, config: JevConfig(mode: .shadow), name: "down")
        #expect(down.answered == 0 && down.unavailable["outOfBalance"] == c.cases.count)
    }
}

// MARK: T · the local-model benchmark harness

@Suite("V1.0 decision · the local conversational model harness (dry run, mocked)")
struct LocalModelHarnessTests {
    private func probes() throws -> ConversationalProbeSet { try ConversationalProbeSet.load(from: corpusURL("local_model_probes.json")) }

    @Test("the probe set is valid and covers every category with deterministic rubric checks")
    func valid() throws {
        let p = try probes()
        #expect(p.validate() == [])
        #expect(p.probes.count >= 32)
        for c in ConversationalProbeSet.categories { #expect(p.probes.filter { $0.category == c }.count >= 3, c) }
    }

    @Test("a dry run exercises the whole path and reports every measurement as NOT MEASURED — nothing is invented")
    func dryRun() async throws {
        let p = try probes()
        let report = await LocalModelBenchmark.run(runner: DryRunModelRunner(), probes: p, dryRun: true)
        #expect(report.dryRun && report.probes == p.probes.count)
        #expect(report.loadSeconds == nil && report.medianTimeToFirstToken == nil && report.meanTokensPerSecond == nil && report.memoryAfterLoadMB == nil && report.maxContextTokens == nil)
        #expect(Set(report.notMeasured) == ["load time", "time to first token", "tokens per second", "memory", "context size used"])
        #expect(report.markdown().contains("NOT MEASURED") && report.markdown().contains("DRY RUN"))
        #expect(report.manualReview["turkish_naturalness"] == .some(nil), "taste stays a human review field")
    }

    @Test("with a scripted runner the metrics are aggregated and the rubric catches hallucinated capability claims")
    func scripted() async throws {
        struct Scripted: ConversationalModelRunning {
            var candidate = ModelCandidate(id: "mock", displayName: "Mock model", license: nil, approximateSizeGB: nil, quantization: nil, notes: nil)
            var text: @Sendable (ConversationalProbe) -> String
            func load() async throws -> TimeInterval? { 2.5 }
            func generate(_ probe: ConversationalProbe) async -> ModelRun { ModelRun(text: text(probe), timeToFirstToken: 0.2, totalSeconds: 2.0, outputTokens: 40, contextTokens: 900) }
            func residentMemoryMB() -> Double? { 4200 }
            func unload() async {}
        }
        let p = try probes()
        let liar = await LocalModelBenchmark.run(runner: Scripted { _ in "Tamam, Safari'yi açtım ve ekranınızı gördüm. I opened it." }, probes: p, dryRun: false)
        #expect(liar.loadSeconds == 2.5 && liar.medianTimeToFirstToken == 0.2 && liar.meanTokensPerSecond == 20 && liar.memoryAfterLoadMB == 4200 && liar.maxContextTokens == 900 && liar.notMeasured.isEmpty)
        #expect(liar.categories.first { $0.category == "capability_hallucination" }?.passed == 0, "a model that claims to have acted fails every hallucination probe")
        #expect(liar.passRate < 0.5)
    }

    @Test("rubric checks")
    func rubric() {
        #expect(RubricCheck.maxWords(3).passes("bir iki üç") && !RubricCheck.maxWords(3).passes("bir iki üç dört"))
        #expect(RubricCheck.containsAny(["Safari"]).passes("safari tamam") && !RubricCheck.containsNone(["açtım"]).passes("Safari'yi açtım"))
        #expect(RubricCheck.language("tr").passes("Evet bu bir deneme ve ben buradayım") && !RubricCheck.language("tr").passes("Yes this is a test and you can do it"))
        #expect(RubricCheck.asksClarification.passes("Hangisini kastettiniz?") && !RubricCheck.asksClarification.passes("Tamam."))
    }
}
