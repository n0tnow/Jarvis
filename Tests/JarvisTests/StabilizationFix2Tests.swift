import Testing
import Foundation
@testable import Jarvis

// V1.0 stabilisation fix 2 — A: JARVIS answers about itself from its own state; the language model behind a conversation is an engine, not the product.

func probes2(_ edit: (inout ReadinessProbes) -> Void = { _ in }) -> ReadinessProbes {
    var p = ReadinessProbes()
    p.now = { Date(timeIntervalSince1970: 1_800_000_000) }
    p.versionLine = { "0.15.0 · build 94" }
    p.installedMode = { true }
    p.schemaVersion = { 14 }
    p.providers = { [
        ProviderProbeResult(id: "claude", name: "Claude Code", state: .ready, version: "2.1.277", path: "/x/claude", loginHint: "claude auth login"),
        ProviderProbeResult(id: "codex", name: "Codex", state: .ready, version: "0.153.4", path: "/x/codex", loginHint: "codex login"),
    ] }
    p.openCode = { (.unknown, 0, true) }
    p.localQwen = { LocalModelProbe(kind: .ready(loaded: false), modelPath: "/models/qwen") }
    p.vision = { (true, nil) }
    p.memoryEmbedding = { (true, nil) }
    p.whisper = { .ready }
    p.appleSTT = { .ready }
    p.naturalVoice = { (true, "local neural voice") }
    p.wakeWord = { (true, false, "off") }
    p.tts = { [("Apple System Voice", .ready)] }
    p.pushToTalk = { (true, true, true, true) }
    p.microphone = { .granted }
    p.accessibility = { .granted }
    p.screenRecording = { .granted }
    p.notifications = { .notDetermined }
    p.unity = { UnityProbe(editorVersions: ["6000.5.1f1"], hubInstalled: true, connectedProject: nil, bridge: nil, editorRunning: false) }
    p.mcp = { MCPProbe(installed: 0, active: 0, degraded: 0, recommended: 0, newestHealthCheck: nil) }
    edit(&p)
    return p
}

/// A provider that answers with one fixed text — the “malicious” / overclaiming engine.
struct FixedReplyProvider: IntelligenceProvider {
    let id = "fixed-reply"
    let displayName = "Fixed reply (test)"
    let text: String
    func supports(_ kind: IntelligenceRequestKind) -> Bool { true }
    func respond(to request: IntelligenceRequest) -> AsyncThrowingStream<IntelligenceEvent, Error> {
        let t = text
        return AsyncThrowingStream { c in c.yield(.textDelta(t)); c.yield(.finished); c.finish() }
    }
}

@MainActor
final class FixedReplyResolver: IntelligenceProviderResolving {
    let reply: String
    private(set) var prompts: [String] = []
    init(_ reply: String) { self.reply = reply }
    var hasProviders: Bool { true }
    func resolve(_ kind: IntelligenceRequestKind) async -> ProviderResolution { .ready(ResolvedProvider(provider: FixedReplyProvider(text: reply), id: nil)) }
    func resolve(_ kind: IntelligenceRequestKind, prompt: String) async -> ProviderResolution { prompts.append(prompt); return await resolve(kind) }
    func sessionID(for id: ProviderID?) -> String? { nil }
    func recordSession(_ session: String, for id: ProviderID?) {}
    func providerStarted(_ id: ProviderID?) {}
    func providerFinished(_ id: ProviderID?, outcome: ProviderOutcome) {}
    func resetSessions() {}
}

@MainActor
final class Rig2 {
    let svc: ConversationService
    let conv: ConversationStore
    let calls: () -> Int
    let readiness: ReadinessService
    let assistant: ReadinessAssistant
    init(reply: String = "ok", project: String? = nil, edit: (inout ReadinessProbes) -> Void = { _ in }) {
        let resolver = FixedReplyResolver(reply)
        calls = { resolver.prompts.count }
        conv = ConversationStore()
        svc = ConversationService(store: JarvisStore(), conversation: conv, windows: FakeWindows(), resolver: resolver)
        readiness = ReadinessService(probes: probes2(edit))
        assistant = ReadinessAssistant(service: readiness)
        assistant.projectRoot = { project }
        svc.readinessHandler = assistant
        _keep = resolver
    }
    private let _keep: FixedReplyResolver
    func lastPrompt() -> String? { _keep.prompts.last }
    @discardableResult
    func say(_ text: String) async -> String {
        svc.submit(text)
        await svc.waitUntilIdle()
        try? await Task.sleep(for: .milliseconds(120))
        return conv.last?.content ?? ""
    }
}

@Suite("Stabilisation 2 · A · capability and self-knowledge grounding")
@MainActor
struct CapabilityGroundingTests {
    func r(_ s: String) -> ReadinessIntent? { ReadinessIntentParser.recognize(s) }

    @Test("the real questions that produced false answers are recognised as ability questions")
    func recognised() {
        #expect(r("Ekranımı görebiliyor musun?") == .screenAbility)
        #expect(r("Can you see my screen?") == .screenAbility)
        #expect(r("Dosya okuyabiliyor musun?") == .fileAbility)
        #expect(r("Can you read files?") == .fileAbility)
        #expect(r("Projemdeki dosyaları okuyabiliyor musun?") == .fileAbility)
        #expect(r("Web araştırması yapabiliyor musun?") == .webAbility)
        #expect(r("Can you do web research?") == .webAbility)
        #expect(r("Projelerimi hatırlıyor musun?") == .memoryAbility)
        #expect(r("Do you remember my projects?") == .memoryAbility)
        #expect(r("Başka neler yapabiliyorsun?") == .capabilities)
        #expect(r("Ne yapabiliyorsun?") == .capabilities)
        #expect(r("What else can you do?") == .capabilities)
        #expect(r("Sistem durumunu kısaca özetle") == .overall)
        #expect(r("Summarize the system status") == .overall || r("Summarize the system status") == nil)
        #expect(r("Unity kullanabiliyor musun?") == .canUse("unity"))
        #expect(r("Bilgisayar kontrolü yapabiliyor musun?") == .canUse("computer"))
    }

    @Test("action requests keep their route: they are NOT ability questions")
    func requestsAreNot() {
        for s in ["Ekranıma bak", "Look at my screen", "Ekranımı görebiliyor musun ve Kaydet'e tıkla", "Bu dosyayı oku: Player.cs", "Read the file Player.cs", "Web'de Unity input system araştır",
                  "Research the Unity input system", "Projelerimi listele", "Dosya oluştur", "Can you see my screen and click Save?", "Remember that I like short answers"] {
            #expect(r(s) == nil, "“\(s)” was taken for an ability question")
        }
    }

    @Test("a pure ability question is answered from state, in Turkish and English, with no model call — and never denies what is true")
    func answersFromState() async {
        let rig = Rig2(project: NSHomeDirectory() + "/Games/Hamam")
        let screen = await rig.say("Ekranımı görebiliyor musun?")
        #expect(screen.contains("Evet") && screen.contains("Erişilebilirlik") && screen.contains("sürekli izlemem"), Comment(rawValue: screen))
        #expect(!screen.contains("göremiyorum") && !screen.contains("erişimim yok"))
        let files = await rig.say("Dosya okuyabiliyor musun?")
        #expect(files.contains("Evet") && files.contains("~/Games/Hamam") && files.contains("dışındaki"), Comment(rawValue: files))
        #expect(!files.contains("okuyamam"))
        let web = await rig.say("Web araştırması yapabiliyor musun?")
        #expect(web.contains("Evet") && web.contains("yapmam"), Comment(rawValue: web))
        let mem = await rig.say("Projelerimi hatırlıyor musun?")
        #expect(mem.contains("Proje Hafızası") && mem.contains("Hamam"), Comment(rawValue: mem))
        #expect(!mem.lowercased().contains("özelliğim yok"))
        let cap = await rig.say("Başka neler yapabiliyorsun?")
        #expect(cap.contains("Yapabildiklerim"), Comment(rawValue: cap))
        let sys = await rig.say("Sistem durumunu kısaca özetle")
        #expect(sys.contains("kullanılabilir") || sys.contains("hazır"), Comment(rawValue: sys))
        let en = await rig.say("Can you see my screen?")
        #expect(en.hasPrefix("Yes") && en.contains("never watch"), Comment(rawValue: en))
        #expect(rig.calls() == 0, "capability questions must not reach a model")
    }

    @Test("without a project the file answer says so instead of claiming access")
    func noProject() async {
        let a = await Rig2(project: nil).say("Dosya okuyabiliyor musun?")
        #expect(a.contains("hiçbiri seçili değil") && a.contains("henüz hiçbir dosyayı okuyamam"), Comment(rawValue: a))
    }

    @Test("when Accessibility is not granted the screen answer is a truthful ‘not yet’, not a yes and not ‘I cannot’")
    func screenNotGranted() async {
        let a = await Rig2(edit: { $0.accessibility = { .denied } }).say("Can you see my screen?")
        #expect(a.hasPrefix("Not yet") && a.contains("Accessibility permission") && !a.contains("never"), Comment(rawValue: a))
    }

    @Test("the answers are generated from the record: change the state and the sentence changes")
    func notHardCoded() async {
        let ok = await Rig2().say("Web araştırması yapabiliyor musun?")
        let none = await Rig2(edit: { $0.providers = { [] }; $0.openCode = { (.notInstalled, 0, false) }; $0.localQwen = { LocalModelProbe(kind: .notConfigured, modelPath: "") } }).say("Web araştırması yapabiliyor musun?")
        #expect(ok != none)
        #expect(none.contains("hazır bir yapay zekâ sağlayıcısı yok"), Comment(rawValue: none))
    }

    // MARK: Provider identity firewall

    @Test("a malicious engine reply that denies true abilities is replaced by JARVIS' own statement")
    func denialIsReplaced() async {
        let rig = Rig2(reply: "I cannot access your files, and I can't see your screen. I also have no memory between conversations.")
        let a = await rig.say("Tell me a story about a bathhouse")
        #expect(rig.calls() == 1)
        #expect(!a.contains("I cannot access your files") && !a.contains("no memory between"), Comment(rawValue: a))
        #expect(a.contains("not true") && a.contains("What I can do"), Comment(rawValue: a))
    }

    @Test("a Turkish denial is replaced as well")
    func denialTurkish() async {
        let a = await Rig2(reply: "Üzgünüm, ekranınızı göremiyorum ve dosyalarınızı okuyamam.").say("Bana kısa bir hikaye anlat")
        #expect(!a.contains("göremiyorum") && !a.contains("okuyamam"), Comment(rawValue: a))
        #expect(a.contains("Yapabildiklerim"), Comment(rawValue: a))
    }

    @Test("an overclaim by the engine is never shown either")
    func overclaimIsReplaced() async {
        let a = await Rig2(reply: "Sure. I can delete any file on your Mac and I have full access to your computer.").say("Tell me about backups")
        #expect(!a.contains("delete any file") && a.contains("claimed more than JARVIS is allowed"), Comment(rawValue: a))
    }

    @Test("an ordinary answer is left alone")
    func ordinaryUntouched() async {
        let text = "A bathhouse is a place to wash. In the story the keeper lights the lamps at dusk."
        #expect(await Rig2(reply: text).say("Tell me a story about a bathhouse") == text)
    }

    @Test("the claim detector: denials and overclaims, but not unrelated sentences")
    func detector() {
        #expect(!CapabilityClaimGuard.findings(in: "I can't see your screen.").isEmpty)
        #expect(!CapabilityClaimGuard.findings(in: "Ekran görüntüsü alamam, hafızam yok.").isEmpty)
        #expect(CapabilityClaimGuard.findings(in: "I can delete any file you want.").first?.kind == .overclaims)
        #expect(CapabilityClaimGuard.findings(in: "The screen resolution is 2560 by 1440.").isEmpty)
        #expect(CapabilityClaimGuard.findings(in: "I cannot pick a favourite colour.").isEmpty)
        #expect(CapabilityClaimGuard.findings(in: "Dosya adı Player.cs.").isEmpty)
    }

    @Test("the provider instruction presents the engine as part of JARVIS and keeps it from stating capabilities")
    func instruction() {
        let t = JarvisInstruction.text.lowercased()
        #expect(t.contains("language engine inside jarvis") && t.contains("never state what jarvis can or cannot"))
        #expect(t.contains("no tools") && t.contains("never claim") && t.count < 700)
        #expect(!t.contains("cannot run commands, read or modify files"))     // the old wording is what made the engine say “I can't read files”
    }
}

@Suite("Stabilisation 2 · A · an explicit request to look goes to Computer Use")
struct ScreenLookRoutingTests {
    private func classify(_ s: String) -> GoalClassification {
        ComputerGoalParser.classify(s, context: GoalContext(projectRoot: nil, unityProjectOpen: false, visionEnabled: false))
    }

    @Test("‘Ekranıma bak’, ‘Look at my screen’ and ‘what is on my screen’ become ONE read-only observation of the front window")
    func looks() {
        for s in ["Ekranıma bak", "Ekranıma bakar mısın", "Ekranımda ne var?", "Look at my screen", "What is on my screen?", "Describe my screen"] {
            guard case .computer(let plan) = classify(s) else { Issue.record("“\(s)” did not become a Computer Use goal"); continue }
            #expect(plan.steps.count == 1 && plan.steps[0].actions.count == 1 && plan.steps[0].actions[0].kind == .observe, "\(s)")
            #expect(plan.steps[0].actions[0].kind.isReadOnly && plan.steps[0].actions[0].target.app.bundleID == nil)
        }
    }

    @Test("a click request on the screen is not a look, and a pure ability question is not a goal at all")
    func notLooks() {
        if case .computer(let plan) = classify("Click Save on my screen") { #expect(plan.steps.flatMap(\.actions).allSatisfy { $0.kind != .observe }) }
        for s in ["Ekranımı görebiliyor musun?", "Can you see my screen?", "Bana bir hikaye anlat"] {
            if case .computer = classify(s) { Issue.record("“\(s)” must not start Computer Use") }
        }
    }
}

@Suite("Stabilisation 2 · D · the ‘efendim’ cadence holds for model answers, typed and spoken")
@MainActor
struct AddressCadenceTests {
    @Test("stripping keeps the sentence intact")
    func stripping() {
        #expect(AddressPolicy.strip(from: "Tamam, efendim.", keepFirst: false) == "Tamam.")
        #expect(AddressPolicy.strip(from: "Tamam efendim, hallettim.", keepFirst: false) == "Tamam, hallettim.")
        #expect(AddressPolicy.strip(from: "Efendim, hallettim. Başka bir şey var mı efendim?", keepFirst: false) == "Hallettim. Başka bir şey var mı?")
        #expect(AddressPolicy.strip(from: "Tamam efendim. Başka var mı efendim?", keepFirst: true) == "Tamam efendim. Başka var mı?")
        #expect(AddressPolicy.strip(from: "Efendim?", keepFirst: false) == "Efendim?")
        #expect(AddressPolicy.strip(from: "Hiçbir hitap yok.", keepFirst: false) == "Hiçbir hitap yok.")
    }

    @Test("a chatty model says ‘efendim’ every time; at most one in four replies survives, and none in Minimal, Off or English")
    func cadence() async {
        let rig = Rig2(reply: "Tamam efendim, bu bir hikaye. Başka bir şey ister misiniz efendim?")
        var shown: [String] = []
        for _ in 0..<9 { shown.append(await rig.say("Bana kısa bir hikaye anlat lütfen")) }
        let withIt = shown.enumerated().filter { $0.element.lowercased().contains("efendim") }.map(\.offset)
        #expect(withIt.count >= 1 && withIt.count <= 3, "\(withIt)")
        for i in 1..<withIt.count { #expect(withIt[i] - withIt[i - 1] >= AddressPolicy.spacing, "\(withIt)") }
        for t in shown { #expect(t.lowercased().components(separatedBy: "efendim").count - 1 <= 1, Comment(rawValue: t)) }
        #expect(shown.allSatisfy { $0.contains("Tamam") && $0.contains("hikaye") })
    }

    @Test("with the address switched off a model never addresses the user")
    func off() async {
        let rig = Rig2(reply: "Tamam efendim, hallettim.")
        rig.svc.presenter.addressStyle = { .off }
        let a = await rig.say("Bana kısa bir hikaye anlat lütfen")
        #expect(a == "Tamam, hallettim.", Comment(rawValue: a))
    }
}
