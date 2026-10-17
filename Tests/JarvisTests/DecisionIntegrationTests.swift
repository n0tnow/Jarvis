import Testing
import Foundation
@testable import Jarvis

// V1.0 decision milestone — Phase A (Cloud). The Decision layer wired into ConversationService, ActionService and VoiceCoordinator, with fakes only: no real window, application, microphone, model, network or
// Jev request. (These suites need macOS to compile and run; they are AUTOMATED TESTED only where `scripts/verify.sh` ran them — see docs/V1_DECISION_INTELLIGENCE_PHASE_B.md for what still needs the real Mac.)

// MARK: C · JARVIS self-navigation is verified, not predicted

@MainActor
@Suite("V1.0 decision · self-navigation mutates the canonical state and is read back")
struct SelfNavigationVerificationTests {
    private func rig(requireAck: Bool) -> (service: ActionService, windows: HUDFakeWindows) {
        let windows = HUDFakeWindows()
        let service = ActionService(launcher: FakeAppLauncher(), windows: windows, selfState: { [windows] in
            SelfUIState(section: windows.hud.section, fullOpen: windows.isFullHUDOpen, compactOpen: windows.isCompactHUDOpen, renderedSection: windows.hud.renderedSection, requiresRenderAck: requireAck)
        })
        service.verificationTimeout = 0.2; service.pollInterval = 0.02; service.navigationSettle = 0.1
        return (service, windows)
    }

    @Test("canonical state changed and read back → success may be claimed")
    func stateLevel() async {
        let (service, windows) = rig(requireAck: false)
        let r = await service.perform(.navigate(.system))
        #expect(r.successIsClaimable && windows.hud.section == .system && windows.isFullHUDOpen)
        #expect(ActionPhrasebook.render(r, language: .tr).contains("Sistem sayfası açık"))
    }

    @Test("the state did not change (the window ignored it) → FAILED, and the sentence never says the page is open")
    func mutationFails() async {
        let (service, windows) = rig(requireAck: false)
        windows.ignoreNavigation = true
        let r = await service.perform(.navigate(.system))
        #expect(r.status == .failed && !r.successIsClaimable)
        let said = ActionPhrasebook.render(r, language: .tr)
        #expect(!said.contains("açık.") && said.contains("açılamadı"), Comment(rawValue: said))
    }

    @Test("the observed bug: the selection says System but the window still draws the Dashboard → UNVERIFIED, never ‘Sistem sayfası açık’")
    func stateWithoutRendering() async {
        let (service, windows) = rig(requireAck: true)
        windows.hud.renderedSection = .dashboard                       // what the screenshot showed
        let r = await service.perform(.navigate(.system))
        #expect(windows.hud.section == .system)                         // the model of the UI says System …
        #expect(r.status == .unverified && !r.successIsClaimable)       // … but nothing drew it
        let said = ActionPhrasebook.render(r, language: .tr)
        #expect(!said.contains("Sistem sayfası açık") && said.contains("doğrulayamadım"), Comment(rawValue: said))
    }

    @Test("the window acknowledges the page it draws → verified")
    func rendered() async {
        let (service, windows) = rig(requireAck: true)
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(40)); windows.hud.renderedSection = .system }          // the view's onChange after layout
        let r = await service.perform(.navigate(.system))
        #expect(r.successIsClaimable)
        #expect(r.verification?.method.contains("render acknowledgement") == true)
    }

    @Test("something resets the page right after it was selected → UNVERIFIED (the settled second read-back)")
    func resetsLater() async {
        let (service, windows) = rig(requireAck: false)
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(30)); windows.hud.section = .dashboard }
        let r = await service.perform(.navigate(.system))
        #expect(r.status == .unverified && !r.successIsClaimable)
    }
}

// MARK: The Decision layer inside the conversation

@MainActor
private final class FakeContinuity: ContinuityConversing {
    private(set) var recognized: [String] = []
    private(set) var intents: [ContinuityIntent] = []
    func recognizes(_ text: String) -> ContinuityIntent? { recognized.append(text); return ContinuityIntent.recognize(text) }
    func reply(to intent: ContinuityIntent, language: ReplyLanguage, channel: InputSource) async -> String { intents.append(intent); return "Tamam." }
}

@MainActor
private final class DecisionRig {
    let launcher = FakeAppLauncher()
    let windows = HUDFakeWindows()
    let conv = ConversationStore()
    /// A model that would happily claim it did things — every claim in a test comes from JARVIS' own code or it is a bug.
    let resolver = FixedReplyResolver("Tamam efendim, Safari'yi açtım ve ekranınızı görüyorum, her şey hazır.")
    let svc: ConversationService
    let actions: ActionService
    let engine = DecisionEngine()
    let continuity = FakeContinuity()
    private(set) var assistant: ReadinessAssistant!              // (ConversationService holds its handlers weakly: the rig must own them)
    var opened: [KnownProject] = []
    var observations: [ObservedApp] = []
    var projects: [KnownProject] = []
    var voice = VoiceStatusFacts(voiceOn: true, pushToTalkOn: true, wakeEnabled: false, wakeRunning: false, microphone: .granted, recogniserReady: true, heardViaVoice: false)

    init() {
        let windows = self.windows, launcher = self.launcher
        let service = ActionService(launcher: launcher, windows: windows, selfState: { SelfUIState(section: windows.hud.section, fullOpen: windows.isFullHUDOpen, compactOpen: windows.isCompactHUDOpen) })
        service.verificationTimeout = 0.15; service.pollInterval = 0.02; service.navigationSettle = 0.02; service.installedLookup = { _ in nil }
        actions = service
        svc = ConversationService(store: JarvisStore(), conversation: conv, windows: windows, resolver: resolver)
        svc.actionService = service
        let readiness = ReadinessService(probes: probes2())
        let assistant = ReadinessAssistant(service: readiness)
        self.assistant = assistant
        assistant.statusProvider = { SystemStatusSnapshot(state: .idle, versionLine: "0.15.0 · build 1", readiness: readiness.refresh(), project: nil, activeTasks: 0, activeAgents: 0, voiceOn: true, pushToTalkOn: true, wakeEnabled: false, wakeDetector: .stopped, providerPreference: "Auto") }
        svc.readinessHandler = assistant
        svc.continuityHandler = continuity
        var parsers = DecisionParsers()
        parsers.action = { text in service.recognizes(text) }
        engine.recognizer = DeterministicCommandRecognizer(parsers: parsers)
        svc.decisionEngine = engine
        launcher.installed["com.apple.Safari"] = URL(fileURLWithPath: "/Applications/Safari.app")
        svc.voiceFacts = { [unowned self] heard in var v = self.voice; v.heardViaVoice = heard; return v }
        svc.observedApps = { [unowned self] in self.observations }
        svc.knownProjects = { [unowned self] in self.projects }
        svc.currentProjectRoot = { nil }
        svc.openProject = { [unowned self] p in
            self.opened.append(p)
            var r = ActionReceipt(kind: .openProject, target: p.name, executor: "NSWorkspace")
            r.start(); r.succeed(ActionVerification(method: "frontmost application", passed: true, detail: "Finder is frontmost"))
            return r
        }
    }

    @discardableResult func say(_ text: String, source: InputSource = .typed) async -> String {
        svc.submit(text, source: source)
        await svc.waitUntilIdle()
        let end = Date().addingTimeInterval(2)
        while Date() < end, conv.last?.role != .jarvis || svc.isAnswering { try? await Task.sleep(for: .milliseconds(20)) }
        return conv.last?.content ?? ""
    }
    var modelCalls: Int { resolver.prompts.count }
    var replies: [String] { conv.messages.filter { $0.role == .jarvis }.map(\.content) }
}

@MainActor
@Suite("V1.0 decision · known commands reach existing capabilities without a model")
struct DecisionRoutingTests {
    @Test("‘Sistem durumunu söyler misin?’ / ‘System Durumu Nedir?’ are answered from the status snapshot — zero model calls")
    func systemStatus() async {
        let rig = DecisionRig()
        for s in ["Sistem durumunu söyler misin?", "System Durumu Nedir?", "JARVIS sistem durumunu göster"] {
            let a = await rig.say(s)
            #expect(a.contains("Sistem hazır") || a.contains("kullanılabilir") || a.contains("Hazır değil"), Comment(rawValue: "“\(s)” → \(a)"))
            #expect(!a.contains("elimde doğrulanmış") && !a.contains("Elimde doğrulanmış"))
        }
        #expect(rig.modelCalls == 0)
        #expect(rig.engine.audit.last?.production?.intent == .systemStatus && rig.engine.audit.last?.route == "system status")
    }

    @Test("‘Jarvis System Panelini aç.’ navigates the canonical state and the reply comes from the verified receipt")
    func navigation() async {
        let rig = DecisionRig()
        let a = await rig.say("Jarvis System Panelini aç.")
        #expect(rig.windows.hud.section == .system && a.contains("Sistem sayfası açık"), Comment(rawValue: a))
        #expect(rig.modelCalls == 0 && rig.actions.ledger.last?.successIsClaimable == true)
        rig.windows.ignoreNavigation = true
        rig.windows.hud.section = .dashboard
        let b = await rig.say("Sistem panelini aç")
        #expect(!b.contains("açık.") && rig.actions.ledger.last?.status == .failed, Comment(rawValue: b))
    }

    @Test("‘Sesim geliyor mu?’ — typed proves nothing, spoken proves the microphone, voice off says so")
    func voiceStatus() async {
        let rig = DecisionRig()
        let typed = await rig.say("Sesim geliyor mu?")
        #expect(!typed.contains("sizi duyuyorum") && typed.contains("yazı olarak"), Comment(rawValue: typed))
        let spoken = await rig.say("Beni duyuyor musun?", source: .voice)
        #expect(spoken.contains("sizi duyuyorum"), Comment(rawValue: spoken))
        rig.voice.voiceOn = false
        let off = await rig.say("Mikrofon çalışıyor mu?")
        #expect(off.contains("kapalı"), Comment(rawValue: off))
        #expect(rig.modelCalls == 0)
    }

    @Test("‘Safari görebiliyor musun şu anda?’ is never answered ‘Evet’ without a fresh observation")
    func visibility() async {
        let rig = DecisionRig()
        let none = await rig.say("Safari görebiliyor musun şu anda?")
        #expect(!none.contains("Evet") && none.contains("Ekranıma bak"), Comment(rawValue: none))
        rig.observations = [ObservedApp(name: "Safari", at: Date().addingTimeInterval(-300))]
        let stale = await rig.say("Safari görebiliyor musun şu anda?")
        #expect(!stale.contains("Evet"), Comment(rawValue: stale))
        rig.observations = [ObservedApp(name: "Safari", at: Date().addingTimeInterval(-2))]
        let fresh = await rig.say("Safari'yi görebiliyor musun?")
        #expect(fresh.contains("Evet — "), Comment(rawValue: fresh))
        #expect(rig.modelCalls == 0)
    }

    @Test("blocked requests are refused in one sentence: no model, no task, nothing executed")
    func blocked() async {
        let rig = DecisionRig()
        for s in ["GitHub'a pushla.", "Satın al", "Şifremi göster"] {
            let a = await rig.say(s)
            #expect(!a.contains("hallettim") && !a.contains("açtım"), Comment(rawValue: "“\(s)” → \(a)"))
        }
        #expect(rig.modelCalls == 0)
        #expect(rig.engine.audit.entries.suffix(3).allSatisfy { $0.production?.gate == .blocked })
    }

    @Test("a deterministic stop / cancel reaches the executor, not the model")
    func controls() async {
        let rig = DecisionRig()
        _ = await rig.say("Sus")
        _ = await rig.say("Görevi durdur")
        #expect(rig.modelCalls == 0)
        #expect(rig.engine.audit.entries.map { $0.production?.intent } == [.stopSpeech, .cancelTask])
    }

    @Test("‘Hamam projesini aç.’ — resolved from the registry fixture, executed through the receipt; ambiguous or unknown → a question, nothing opened")
    func projectOpen() async {
        let rig = DecisionRig()
        rig.svc.projectPathExists = { _ in true }; rig.svc.projectIsKind = { _, _ in false }
        let t = Date()
        rig.projects = [KnownProject(key: "git:h", name: "Hamam", rootPath: "/fixture/Hamam", kind: "git", lastSeen: t), KnownProject(key: "path:n", name: "Notes", rootPath: "/fixture/Notes", kind: "path", lastSeen: t.addingTimeInterval(-86_400))]
        let ok = await rig.say("Hamam projesini aç.")
        #expect(rig.opened.map(\.name) == ["Hamam"] && ok.contains("Finder"), Comment(rawValue: ok))
        let unknown = await rig.say("Zeta projesini aç.")
        #expect(rig.opened.count == 1 && unknown.contains("tanımıyorum"), Comment(rawValue: unknown))
        let last = await rig.say("En son çalıştığımız projeyi aç.")
        #expect(rig.opened.map(\.name) == ["Hamam", "Hamam"], Comment(rawValue: last))
        rig.projects[1].lastSeen = t.addingTimeInterval(-10)
        let ambiguous = await rig.say("En son çalıştığımız projeyi aç.")
        #expect(rig.opened.count == 2 && ambiguous.contains("Hangi proje"), Comment(rawValue: ambiguous))
        #expect(rig.modelCalls == 0)
    }

    @Test("‘Hamam'da kaldığımız yerden devam et.’ is a project continuation that KEEPS the project name — not conversation")
    func continuation() async {
        let rig = DecisionRig()
        _ = await rig.say("Hamam'da kaldığımız yerden devam et.")
        #expect(rig.continuity.recognized.last == "hamam projesine devam et")
        #expect(rig.continuity.intents == [.continueProject(project: "hamam")])
        #expect(rig.modelCalls == 0)
    }

    @Test("a spoken restatement corrects the previous sentence and routes it again; the transcript keeps what was said")
    func correction() async {
        let rig = DecisionRig()
        _ = await rig.say("Sofany görebiliyor musun şu anda?")          // not understood: the router (the model) answers this one
        let before = rig.modelCalls
        let a = await rig.say("Sofany değil, Safari dedim.")
        #expect(a.contains("Safari") && !a.contains("Evet"), Comment(rawValue: a))
        #expect(rig.conv.messages.contains { $0.role == .user && $0.content == "Sofany değil, Safari dedim." })
        #expect(rig.replies.contains { $0.contains("Anladım — “Safari görebiliyor musun şu anda?”") })
        #expect(rig.modelCalls == before, "a correction is not a question for the model or for Project Memory")
    }

    @Test("provider identity firewall: a capability question is answered from JARVIS' state, whatever the model would say")
    func identityFirewall() async {
        let rig = DecisionRig()
        let a = await rig.say("Claude Code'u kullanabiliyor musun?")
        #expect(a.contains("hazır") || a.contains("Claude"), Comment(rawValue: a))
        #expect(rig.modelCalls == 0)
        #expect(rig.engine.audit.last?.production?.intent == .providerCapability)
    }

    @Test("a decision with high confidence is not proof: an action whose verification fails is not reported as done")
    func noFalseCompletion() async {
        let rig = DecisionRig()
        rig.launcher.launchWorks = false                                  // the request is accepted but nothing appears
        let a = await rig.say("Safari'yi aç.")
        #expect(rig.engine.audit.last?.production?.confidence ?? 0 >= 0.9)
        #expect(!a.hasSuffix("Safari açık.") && a.contains("doğrulayamadım"), Comment(rawValue: a))
    }
}

// MARK: Jev in the conversation (mock): gated routing is limited to read-only intents and is still verified

@MainActor
@Suite("V1.0 decision · the remote classifier inside ConversationService (mock only)")
struct DecisionGatedConversationTests {
    private final class Scripted: DecisionProviding, @unchecked Sendable {
        let result: DecisionProviderResult
        private let lock = NSLock(); private var n = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return n }
        init(_ r: DecisionProviderResult) { result = r }
        func decide(_ context: JevDecisionContext, config: JevConfig) async -> DecisionProviderResult { lock.lock(); n += 1; lock.unlock(); return result }
    }

    @Test("disabled (the default): nothing is consulted and the router answers; gated: a confident read-only decision is routed, an executing one never is")
    func modes() async {
        let navigate = DecisionPolicy.finalize(intent: .systemStatus, confidence: 0.97, normalized: "x", target: "all", action: "query", deepReasoning: false, provenance: .jevShadow, provider: .jev)
        let provider = Scripted(.decision(navigate, latency: 0.1))
        let rig = DecisionRig()
        rig.engine.jev = provider
        rig.engine.config = { JevConfig(mode: .disabled) }
        _ = await rig.say("Şu anki durumu bir özetle")
        #expect(provider.calls == 0 && rig.modelCalls == 1, "disabled → the existing router (the model) answers")
        rig.engine.config = { JevConfig(mode: .gated) }
        let a = await rig.say("Şu anki durumu bir özetle")
        #expect(provider.calls == 1 && rig.modelCalls == 1 && (a.contains("Sistem hazır") || a.contains("kullanılabilir")), Comment(rawValue: a))
        let exec = DecisionPolicy.finalize(intent: .macosApplicationAction, confidence: 0.99, normalized: "x", target: "Safari", action: "launch", deepReasoning: false, provenance: .jevShadow, provider: .jev)
        let provider2 = Scripted(.decision(exec, latency: 0.1))
        rig.engine.jev = provider2
        _ = await rig.say("Bir şeyler yapsana lütfen")
        #expect(provider2.calls == 1 && rig.launcher.launched.isEmpty, "an executing remote decision is never accepted")
    }
}

// MARK: M · a rejected transcript never reaches the conversation

@MainActor
@Suite("V1.0 decision · a pathological transcript dies upstream")
struct PathologicalVoiceTests {
    @Test("‘Kutu, Kutu, …’ is dropped: no user turn, no model call, a diagnostic without text, and the next utterance works")
    func rejectedNeverReachesTheConversation() async {
        let h = VoiceHarness()
        let diagnostics = VoiceDiagnostics()
        h.voice.diagnostics = diagnostics
        h.stt.script = { $0.finalText = Array(repeating: "Kutu,", count: 40).joined(separator: " ") }
        await h.hold()
        await h.settle { h.voice.state == .idle }
        #expect(h.userMessages.isEmpty)
        #expect(h.base.replies.isEmpty)
        #expect(diagnostics.count("origin.decoderHallucination") == 1)
        #expect(!diagnostics.entries.contains { $0.detail.contains("Kutu") }, "the diagnostic keeps counts, never the text")
        h.stt.script = { $0.finalText = "open the tasks screen" }
        await h.hold()
        await h.settle { h.userMessages.count == 1 }
        #expect(h.userMessages.count == 1, "capture recovers for the next utterance")
    }

    @Test("legitimate repetition (‘hayır hayır hayır’) is delivered as a normal turn")
    func legitimateRepetition() async {
        let h = VoiceHarness()
        h.stt.script = { $0.finalText = "dur dur dur" }
        await h.hold()
        await h.settle { h.userMessages.count == 1 }
        #expect(h.userMessages.map(\.content) == ["dur dur dur"])
    }
}

// MARK: U · nothing paid or remote is switched on by itself

@MainActor
@Suite("V1.0 decision · defaults")
struct DecisionDefaultsTests {
    @Test("the remote classifier is disabled by default, and an unknown stored value cannot enable it")
    func defaultsAreOff() {
        let suite = "jarvis-decision-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.decisionJevMode == "disabled" && prefs.decisionJevMinConfidence == 0.92 && prefs.decisionJevModel.isEmpty)
        defaults.set("everything", forKey: "prefs.decision.jev.mode")
        #expect(Preferences(defaults: defaults).decisionJevMode == "disabled")
        defaults.set(0.01, forKey: "prefs.decision.jev.minConfidence")
        #expect(Preferences(defaults: defaults).decisionJevMinConfidence >= 0.5, "the gated threshold has a floor")
        UserDefaults().removePersistentDomain(forName: suite)
    }
}
