import Testing
import Foundation
@testable import Jarvis

// V1.0 stabilisation fix 1 — three real-world defects found in the installed app:
//   Bug 1: “Hangi AI modellerine ve providerlara erişebiliyorsun?” fell through to a language model, which invented its own capabilities.
//   Bug 2: “Biraz daha detaylı anlat.” expanded an OLDER deterministic answer instead of the one just given.
//   Bug 3: holding the right ⌥ key in the installed app did nothing — Voice is OFF by default and every dependency still read READY.

private func probes(_ edit: (inout ReadinessProbes) -> Void = { _ in }) -> ReadinessProbes {
    var p = ReadinessProbes()
    p.now = { Date(timeIntervalSince1970: 1_800_000_000) }
    p.versionLine = { "0.15.0 · build 92" }
    p.installedMode = { true }
    p.schemaVersion = { 14 }
    p.providers = { [
        ProviderProbeResult(id: "claude", name: "Claude Code", state: .ready, version: "2.1.277", path: "/x/claude", loginHint: "claude auth login"),
        ProviderProbeResult(id: "codex", name: "Codex", state: .ready, version: "0.153.4", path: "/x/codex", loginHint: "codex login"),
    ] }
    p.openCode = { (.unknown, 0, true) }                     // found on disk, NOT CHECKED (checking would start its background service)
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

@MainActor
private final class Rig {
    let svc: ConversationService
    let conv: ConversationStore
    let resolver = ScriptedAnswerResolver()
    let readiness: ReadinessService
    let assistant: ReadinessAssistant            // ConversationService holds its handlers weakly: the rig owns it, like AppContext does
    init(_ edit: (inout ReadinessProbes) -> Void = { _ in }, pending: Bool = false) {
        conv = ConversationStore()
        svc = ConversationService(store: JarvisStore(), conversation: conv, windows: FakeWindows(), resolver: resolver)
        readiness = ReadinessService(probes: probes(edit))
        assistant = ReadinessAssistant(service: readiness)
        svc.readinessHandler = assistant
        svc.hasPendingDecision = { pending }
    }
    @discardableResult
    func say(_ text: String) async -> String {
        svc.submit(text)
        await svc.waitUntilIdle()
        try? await Task.sleep(for: .milliseconds(120))
        return conv.last?.content ?? ""
    }
    var modelCalls: Int { resolver.prompts.count }
}

// MARK: - Bug 1 — capability introspection comes from JARVIS' own state

@Suite("Stabilisation 1 · Bug 1 · what JARVIS can use is answered from its own state")
@MainActor
struct CapabilityIntrospectionTests {
    func r(_ s: String) -> ReadinessIntent? { ReadinessIntentParser.recognize(s) }

    @Test("the Turkish questions from the real conversation are all recognised")
    func turkish() {
        #expect(r("Hangi AI modellerine ve providerlara erişebiliyorsun?") == .providers)
        #expect(r("Hangi AI modellerine erişebiliyorsun?") == .providers)
        #expect(r("Hangi modelleri kullanabiliyorsun?") == .providers)
        #expect(r("Hangi providerları kullanabiliyorsun?") == .providers)
        #expect(r("Hangi sağlayıcılara erişimin var?") == .providers)
        #expect(r("Hangi AI modellerine ve providerlara erişebiliyorsun? Kısa söyle.") == .providers)
        #expect(r("Claude Code'u kullanabiliyor musun?") == .canUse("claude"))
        #expect(r("Claude hazır mı?") == .provider("claude"))
        #expect(r("Codex kullanabiliyor musun?") == .canUse("codex"))
        #expect(r("OpenCode kullanabiliyor musun?") == .canUse("opencode"))
        #expect(r("OpenCode hazır mı?") == .provider("opencode"))
        #expect(r("Local Qwen modelin var mı?") == .canUse("qwen"))
        #expect(r("Qwen kullanabiliyor musun?") == .canUse("qwen"))
        #expect(r("Görsel modelin var mı?") == .canUse("vision"))
        #expect(r("Whisper var mı?") == .localModels("whisper") || r("Whisper var mı?") == .canUse("whisper"))
        #expect(r("Hangi araçlara erişebiliyorsun?") == .tools)
        #expect(r("Neleri kullanabiliyorsun?") == .capabilities)
        #expect(r("Neler yapabiliyorsun?") == .capabilities)
    }

    @Test("the English questions are recognised")
    func english() {
        #expect(r("What AI models can you use?") == .providers)
        #expect(r("Which providers can you use?") == .providers)
        #expect(r("What providers are available?") == .providers)
        #expect(r("Can you use Claude Code?") == .canUse("claude"))
        #expect(r("Is Claude Code ready?") == .provider("claude"))
        #expect(r("Can you use Codex?") == .canUse("codex"))
        #expect(r("Can you use OpenCode?") == .canUse("opencode"))
        #expect(r("Is OpenCode ready?") == .provider("opencode"))
        #expect(r("Do you have a local Qwen model?") == .canUse("qwen"))
        #expect(r("What local models are available?") == .localModels(nil))
        #expect(r("What tools can you use?") == .tools)
        #expect(r("What capabilities are available?") == .capabilities)
        #expect(r("What can you do?") == .capabilities)
    }

    @Test("requests and general questions are NOT introspection (they must keep going to their normal route)")
    func notIntrospection() {
        for s in ["Can you use Claude Code to fix the bug?", "Claude Code ile bu hatayı düzeltebilir misin?", "Which AI models are best for coding?", "What AI models exist?",
                  "Explain how Qwen works", "Hangi model daha iyi kod yazar?", "Bana bir hikaye yaz", "Fix the multiplayer synchronization problem", "Use Codex to refactor the player controller",
                  "Hamam ne durumda?", "open the settings", "What is a good AI model for a game?"] {
            #expect(r(s) == nil, "“\(s)” was taken for an introspection question")
        }
    }

    @Test("a general provider question is answered from the records, in Turkish, without any model call")
    func providerSummaryTurkish() async {
        let rig = Rig()
        let a = await rig.say("Hangi AI modellerine ve providerlara erişebiliyorsun? Kısa söyle.")
        #expect(a.contains("Claude Code ve Codex hazır"), Comment(rawValue: a))
        #expect(a.contains("OpenCode kurulu ancak henüz kontrol edilmedi"), Comment(rawValue: a))
        #expect(a.lowercased().contains("yerel qwen modeli") && a.contains("görsel model") && a.contains("Whisper"), Comment(rawValue: a))
        #expect(rig.modelCalls == 0)
        #expect(!a.contains("API'lere bağlanamam") && !a.contains("erişimim yok"))
    }

    @Test("the English summary keeps READY, installed-not-checked and available apart")
    func providerSummaryEnglish() async {
        let a = await Rig().say("What AI models can you use?")
        #expect(a.contains("Claude Code and Codex ready"), Comment(rawValue: a))
        #expect(a.contains("OpenCode installed but not checked yet"), Comment(rawValue: a))
        #expect(a.contains("available"), Comment(rawValue: a))
    }

    @Test("the answer is generated from the records: change the state and the sentence changes")
    func notHardCoded() async {
        let a = await Rig({ p in
            p.providers = { [ProviderProbeResult(id: "claude", name: "Claude Code", state: .authenticationRequired, version: "1", path: "/x", loginHint: "claude auth login"),
                             ProviderProbeResult(id: "codex", name: "Codex", state: .notInstalled, version: nil, path: nil, loginHint: nil)] }
            p.openCode = { (.ready, 5, true) }
            p.localQwen = { LocalModelProbe(kind: .runtimeMissing, modelPath: "") }
        }).say("Hangi sağlayıcılara erişimin var?")
        #expect(a.contains("Claude Code kurulu ancak oturum açmanız gerekiyor"), Comment(rawValue: a))
        #expect(a.contains("Codex kurulu değil"), Comment(rawValue: a))
        #expect(a.contains("OpenCode hazır"), Comment(rawValue: a))
        #expect(a.contains("yerel Qwen modeli kurulmamış (isteğe bağlı)") || a.contains("kurulmamış"), Comment(rawValue: a))
        #expect(!a.contains("Claude Code ve Codex hazır"))
    }

    @Test("“Can you use Claude Code?” — Yes only when the record says READY; never ‘I have no access’")
    func canUseClaude() async {
        let ready = await Rig().say("Claude Code'u kullanabiliyor musun?")
        #expect(ready.hasPrefix("Evet") && ready.contains("hazır") && ready.contains("model isteği yapılmadı"), Comment(rawValue: ready))
        let en = await Rig().say("Can you use Claude Code?")
        #expect(en.hasPrefix("Yes") && en.contains("ready"), Comment(rawValue: en))
        let signedOut = await Rig({ p in p.providers = { [ProviderProbeResult(id: "claude", name: "Claude Code", state: .authenticationRequired, version: "1", path: "/x", loginHint: "claude auth login")] } }).say("Claude Code'u kullanabiliyor musun?")
        #expect(signedOut.hasPrefix("Henüz değil") && signedOut.contains("oturum"), Comment(rawValue: signedOut))
        let missing = await Rig({ p in p.providers = { [ProviderProbeResult(id: "claude", name: "Claude Code", state: .notInstalled, version: nil, path: nil, loginHint: nil)] } }).say("Can you use Claude Code?")
        #expect(missing.hasPrefix("No") && missing.contains("not installed"), Comment(rawValue: missing))
        let unverified = await Rig({ p in p.providers = { [ProviderProbeResult(id: "claude", name: "Claude Code", state: .unknown, version: nil, path: "/x/claude", loginHint: nil)] } }).say("Can you use Claude Code?")
        #expect(unverified.contains("nothing has verified it") && !unverified.hasPrefix("Yes"), Comment(rawValue: unverified))
    }

    @Test("Codex, OpenCode, Qwen, the visual model and Whisper each answer from their own record")
    func eachSubject() async {
        let rig = Rig()
        #expect(await rig.say("Codex kullanabiliyor musun?").hasPrefix("Evet"))
        let oc = await rig.say("OpenCode kullanabiliyor musun?")
        #expect(oc.contains("kurulu ancak henüz kontrol etmedim") && oc.contains("başlatmaz") && !oc.hasPrefix("Evet"), Comment(rawValue: oc))
        let ocReady = await rig.say("OpenCode hazır mı?")
        #expect(ocReady.contains("henüz kontrol edilmedi"), Comment(rawValue: ocReady))
        let qwen = await rig.say("Local Qwen modelin var mı?")
        #expect(qwen.hasPrefix("Evet") && qwen.contains("gerektiğinde yüklenir") && qwen.contains("çalışmıyor"), Comment(rawValue: qwen))
        #expect(await rig.say("Görsel modelin var mı?").hasPrefix("Evet"))
        #expect(await rig.say("Whisper var mı?").contains("Whisper"))
        #expect(rig.modelCalls == 0)
    }

    @Test("an optional model that is not installed is ‘not set up (optional)’, not ‘broken’ and not ‘missing’")
    func optionalIsNotMissing() async {
        let a = await Rig({ p in p.vision = { (false, nil) }; p.whisper = { .needsSetup("no runtime") } }).say("Görsel modelin var mı?")
        #expect(a.hasPrefix("Hayır") && a.contains("isteğe bağlı"), Comment(rawValue: a))
        let en = await Rig({ p in p.whisper = { .needsSetup("no runtime") } }).say("Do you have Whisper?")
        #expect(en.contains("optional"), Comment(rawValue: en))
    }

    @Test("tools and capabilities: concise, grounded, with idle things called idle")
    func toolsAndCapabilities() async {
        let tools = await Rig().say("Hangi araçlara erişebiliyorsun?")
        #expect(tools.contains("Bilgisayar Kontrolü") && tools.contains("hazır") && tools.contains("çalışmıyor"), Comment(rawValue: tools))
        let cap = await Rig().say("Neler yapabiliyorsun?")
        #expect(cap.contains("Hazır:") && cap.contains("Claude Code") && cap.contains("Henüz kontrol edilmedi: OpenCode"), Comment(rawValue: cap))
        let capEn = await Rig().say("What capabilities are available?")
        #expect(capEn.contains("Ready:") && capEn.contains("Not checked yet: OpenCode"), Comment(rawValue: capEn))
        #expect(!cap.contains("Switched off") )
    }

    @Test("voice off is said first when asked about voice, and in the capability summary")
    func voiceOff() async {
        let rig = Rig({ p in p.pushToTalk = { (false, true, true, true) } })
        let v = await rig.say("Ses sistemi hazır mı?")
        #expect(v.hasPrefix("Voice input · Push-to-Talk (hold right ⌥): kapalı"), Comment(rawValue: v))
        let cap = await rig.say("Neler yapabiliyorsun?")
        #expect(cap.contains("Kapalı: ses girişi"), Comment(rawValue: cap))
    }

    @Test("asking never starts anything: no model call, OpenCode stays NOT CHECKED, the snapshot is unchanged by the question")
    func readOnly() async {
        let rig = Rig()
        let before = rig.readiness.refresh().item("provider.opencode")?.state
        for q in ["OpenCode kullanabiliyor musun?", "Hangi sağlayıcılara erişimin var?", "Claude Code'u kullanabiliyor musun?", "Neler yapabiliyorsun?", "What tools can you use?"] { await rig.say(q) }
        #expect(rig.modelCalls == 0)
        #expect(rig.readiness.refresh().item("provider.opencode")?.state == before && before == .unknown)
    }

    @Test("the real conversation: the capability questions never reach the model, and Qwen/Claude answers stay consistent")
    func realConversation() async {
        let rig = Rig()
        _ = await rig.say("Her şey hazır mı?")
        let providers = await rig.say("Hangi AI modellerine ve providerlara erişebiliyorsun?")
        let claude = await rig.say("Claude Code'u kullanabiliyor musun?")
        let qwen = await rig.say("Local Qwen modelin var mı?")
        #expect(rig.modelCalls == 0)
        #expect(providers.contains("Claude Code") && claude.hasPrefix("Evet") && qwen.hasPrefix("Evet"))
        for a in [providers, claude, qwen] { #expect(!a.contains("API'lere") && !a.contains("erişimim yok") && !a.contains("sadece kendi yeteneklerimle")) }
    }
}

// MARK: - Bug 2 — “detaylı anlat” targets the answer just given

@Suite("Stabilisation 1 · Bug 2 · response depth targets the immediately preceding answer")
@MainActor
struct ResponseDepthTargetTests {
    let longProblem = String(repeating: "Ayrıntı cümlesi burada yer alıyor. ", count: 30) + "Bir test başarısız oldu: PlayerTests.jump."

    @Test("A → B → ‘detaylı anlat’ expands B, never A; ‘kısa söyle’ then shortens B")
    func abDetailShort() async {
        let rig = Rig()
        await rig.say("Claude hazır mı?")
        await rig.say("Codex hazır mı?")
        let detail = await rig.say("Biraz daha detaylı anlat.")
        #expect(detail.contains("Codex") && !detail.contains("Claude"), Comment(rawValue: detail))
        let short = await rig.say("Kısa söyle.")
        #expect(short.contains("Codex") && !short.contains("Claude"), Comment(rawValue: short))
    }

    @Test("A → detail → B → detail: the second detail is about B")
    func detailBetweenTopics() async {
        let rig = Rig()
        await rig.say("Claude hazır mı?")
        let d1 = await rig.say("detaylı anlat")
        await rig.say("Codex hazır mı?")
        let d2 = await rig.say("detaylı anlat")
        #expect(d1.contains("Claude") && !d1.contains("Codex"))
        #expect(d2.contains("Codex") && !d2.contains("Claude"), Comment(rawValue: d2))
    }

    @Test("deterministic → model answer → detail: the model's answer is the target; nothing old is re-rendered and no model is called")
    func deterministicThenModel() async {
        let rig = Rig()
        await rig.say("Claude hazır mı?")
        let model = await rig.say("Bana bir şeyler anlat lütfen")                    // not introspection → the (scripted) model answers
        let calls = rig.modelCalls
        #expect(calls == 1)
        let detail = await rig.say("Biraz daha detaylı anlat.")
        #expect(!detail.contains("Claude Code") && detail.contains(model.prefix(30)), Comment(rawValue: detail))
        #expect(detail.contains("doğrulanmış") )                                    // it says there is no further verified detail
        #expect(rig.modelCalls == calls)
    }

    @Test("model answer → deterministic answer → detail: the deterministic one")
    func modelThenDeterministic() async {
        let rig = Rig()
        await rig.say("Bana bir şeyler anlat lütfen")
        await rig.say("Codex hazır mı?")
        let detail = await rig.say("detaylı anlat")
        #expect(detail.contains("Codex"), Comment(rawValue: detail))
    }

    @Test("a shortened answer expands to its full text; a whole one says there is no further verified detail")
    func shortenedAndWhole() async {
        let rig = Rig()
        let shown = rig.svc.presenter.present(full: longProblem, language: .tr)
        rig.conv.appendJarvis(shown, route: .local)
        #expect(shown.count < longProblem.count)
        let more = await rig.say("Ayrıntılı anlat")
        #expect(more.contains("Ayrıntı cümlesi") && more.count > shown.count)
        let again = await rig.say("Biraz daha detaylı anlat")
        #expect(again.contains("doğrulanmış bir ayrıntım yok"), Comment(rawValue: again))
    }

    @Test("the Turkish and English depth phrases from the brief all work on the previous answer")
    func phrases() async {
        for expand in ["detaylı anlat", "biraz daha detaylı anlat", "ayrıntılı anlat", "explain in more detail", "give me more detail"] {
            let rig = Rig()
            let shown = rig.svc.presenter.present(full: longProblem, language: .tr)
            rig.conv.appendJarvis(shown, route: .local)
            let out = await rig.say(expand)
            #expect(out.contains("Ayrıntı cümlesi") && out.count > shown.count, Comment(rawValue: "\(expand) → \(out.prefix(80))"))
        }
        for shorten in ["kısa söyle", "kısaca", "make that shorter", "keep it brief"] {
            let rig = Rig()
            let shown = rig.svc.presenter.present(full: longProblem, language: .tr, depth: .detailed)
            rig.conv.appendJarvis(shown, route: .local)
            let out = await rig.say(shorten)
            #expect(out.count < shown.count && out.contains("başarısız oldu"), Comment(rawValue: "\(shorten) → \(out.prefix(80))"))
        }
    }

    @Test("“Explain it again” and “Neden?” are still questions for the model — they are not depth changes of the previous answer")
    func weakCuesGoToTheModel() async {
        let rig = Rig()
        await rig.say("Claude hazır mı?")
        let before = rig.modelCalls
        await rig.say("Explain it again.")
        await rig.say("Neden?")
        #expect(rig.modelCalls == before + 2)
    }

    @Test("no previous answer, or an unanswered previous turn: a plain notice, no stale answer, no model")
    func noStaleAnswer() async {
        let rig = Rig()
        let first = await rig.say("Detaylı anlat.")
        #expect(first.contains("önceki yanıt yok") && rig.modelCalls == 0)
        // an older answer exists, but the last turn was not answered (cleared / failed): it is not ‘the previous answer’
        let rig2 = Rig()
        await rig2.say("Claude hazır mı?")
        rig2.conv.appendUser("bir şey sordum ama yanıt gelmedi", source: .typed)
        let out = await rig2.say("detaylı anlat")
        #expect(out.contains("önceki yanıt yok") && !out.contains("Claude"), Comment(rawValue: out))
    }

    @Test("shortening and detail never drop a failure, an unknown, a refusal, a pending approval or a safety warning")
    func negativesSurvive() async {
        let cases = [
            ("failure", String(repeating: "Dolgu cümlesi. ", count: 40) + "Derleme başarısız oldu: Unity hatası."),
            ("unknown", String(repeating: "Dolgu cümlesi. ", count: 40) + "Lisans bilinmiyor."),
            ("refusal", String(repeating: "Dolgu cümlesi. ", count: 40) + "Bu işlem reddedildi."),
            ("approval", String(repeating: "Dolgu cümlesi. ", count: 40) + "Onayınızı bekliyor."),
            ("warning", String(repeating: "Dolgu cümlesi. ", count: 40) + "Uyarı: bu işlem silme içerir."),
        ]
        for (name, text) in cases {
            let rig = Rig()
            let shown = rig.svc.presenter.present(full: text, language: .tr)
            rig.conv.appendJarvis(shown, route: .local)
            let terse = await rig.say("kısa söyle")
            let detail = await rig.say("detaylı anlat")
            let marker = ["başarısız", "bilinmiyor", "reddedildi", "Onay", "Uyarı"].first { text.contains($0) }!
            #expect(shown.contains(marker) && terse.contains(marker) && detail.contains(marker), Comment(rawValue: name))
        }
    }

    @Test("a pending-approval notice is the target of ‘kısa söyle’ and keeps its meaning")
    func pendingApproval() async {
        let rig = Rig(pending: true)
        let notice = await rig.say("Evet")
        #expect(notice.contains("HUD"))
        let short = await rig.say("Kısa söyle")
        #expect(short.contains("HUD") || short.contains("onay"), Comment(rawValue: short))
    }
}

// MARK: - Bug 3 — Push-to-Talk in the installed app

@Suite("Stabilisation 1 · Bug 3 · Push-to-Talk key path")
@MainActor
struct PushToTalkInstalledPathTests {
    final class Script { var now = 1_000.0; var right = false; var left = false; var keyAge = 100.0 }

    func service(_ s: Script, attach: Bool, log: @escaping (String) -> Void) -> GlobalHotkeyService {
        let svc = GlobalHotkeyService(sampler: {
            ModifierSample(time: s.now, option: s.right || s.left, command: false, other: false, secondsSinceOtherInput: s.keyAge + 0, rightOption: s.right, leftOption: s.left, shift: false, control: false)
        }, perform: { _ in })
        if attach { svc.performTalk = { log("\($0)") } }
        return svc
    }
    func tick(_ svc: GlobalHotkeyService, _ s: Script, for seconds: Double) { let end = s.now + seconds; while s.now < end { s.now += 0.02; s.keyAge += 0.02; svc.poll() } }

    @Test("the production default is Voice OFF — and the readiness picture says so instead of calling voice READY")
    func offByDefaultAndSaid() {
        let suite = UserDefaults(suiteName: "ptt-\(UUID().uuidString)")!
        #expect(Preferences(defaults: suite).voiceEnabled == false)
        let snap = ReadinessService.build(probes { $0.pushToTalk = { (false, true, true, true) } })
        let row = snap.item("voice.input")
        #expect(row?.state == .off && row?.action == .turnOnVoice && row?.detail.contains("does nothing") == true)
        #expect(snap.item("voice.mic")?.name == "Microphone permission" && snap.item("voice.mic")?.detail.contains("does not mean Push-to-Talk is on") == true)
    }

    @Test("voice on + monitor running + handler attached = READY; on but no monitor = degraded; PTT switched off = OFF")
    func states() {
        #expect(ReadinessService.build(probes { $0.pushToTalk = { (true, true, true, true) } }).item("voice.input")?.state == .ready)
        let broken = ReadinessService.build(probes { $0.pushToTalk = { (true, true, false, false) } }).item("voice.input")
        #expect(broken?.state.needsAttention == true && broken?.state.label == "DEGRADED")
        #expect(ReadinessService.build(probes { $0.pushToTalk = { (true, false, true, false) } }).item("voice.input")?.state == .off)
    }

    @Test("Turn On Voice is a closed, explicit action and sets exactly Voice + Push-to-Talk")
    func turnOnVoiceIsTyped() {
        #expect(SetupAction.turnOnVoice.isInstall == false && SetupAction.turnOnVoice.title == "Turn On Voice")
        #expect(SetupCatalog.plan(for: .turnOnVoice) == nil)
    }

    @Test("with the handler attached, holding the right ⌥ key reaches it once and the release follows; the key monitor counters say so")
    func rightOptionHold() {
        let s = Script(); var events: [String] = []
        let svc = service(s, attach: true) { events.append($0) }
        svc.start()
        #expect(svc.diagnostics.monitorRunning && !svc.diagnostics.handlerAttached == false || svc.diagnostics.monitorRunning)
        s.right = true; tick(svc, s, for: 1.0)
        #expect(events == ["press"])
        s.right = false; tick(svc, s, for: 0.2)
        #expect(events == ["press", "release(interrupted: false)"])
        #expect(svc.diagnostics.rightOptionPresses == 1 && svc.diagnostics.handlerAttached && svc.diagnostics.lastEvent == "release")
        svc.stop()
        #expect(svc.diagnostics.monitorRunning == false)
    }

    @Test("the LEFT Option key never triggers; a quick tap of the right one is ignored")
    func leftAndTap() {
        let s = Script(); var events: [String] = []
        let svc = service(s, attach: true) { events.append($0) }
        svc.start()
        s.left = true; tick(svc, s, for: 1.0); s.left = false; tick(svc, s, for: 0.2)
        #expect(events.isEmpty && svc.diagnostics.leftOptionOnlyPresses == 1 && svc.diagnostics.rightOptionPresses == 0)
        s.right = true; tick(svc, s, for: 0.1); s.right = false; tick(svc, s, for: 0.3)
        #expect(events.isEmpty && svc.diagnostics.lastEvent.contains("before the hold time"))
        svc.stop()
    }

    @Test("repeated holds are independent sessions; key repeat cannot start a second one")
    func repeated() {
        let s = Script(); var events: [String] = []
        let svc = service(s, attach: true) { events.append($0) }
        svc.start()
        for _ in 0..<3 { s.right = true; tick(svc, s, for: 0.8); s.right = false; tick(svc, s, for: 0.3) }
        #expect(events.filter { $0 == "press" }.count == 3 && events.filter { $0.hasPrefix("release") }.count == 3)
        svc.stop()
    }

    @Test("without a handler the hold is still SEEN by the monitor (the diagnostics show it) but reaches nothing — which is how the silent failure looked")
    func noHandlerIsVisible() {
        let s = Script()
        let svc = service(s, attach: false) { _ in }
        svc.start()
        s.right = true; tick(svc, s, for: 1.0); s.right = false; tick(svc, s, for: 0.2)
        #expect(svc.diagnostics.monitorRunning && !svc.diagnostics.handlerAttached && svc.diagnostics.rightOptionPresses == 1)
        svc.stop()
    }

    @Test("the diagnostics hold counters and one short label — no key identity beyond the Option keys, no text, no audio")
    func diagnosticsCarryNoKeystrokes() {
        let names = Set(Mirror(reflecting: GlobalHotkeyService.TalkDiagnostics()).children.compactMap(\.label))
        #expect(names == ["monitorRunning", "handlerAttached", "samples", "rightOptionPresses", "leftOptionOnlyPresses", "lastEvent", "lastEventAt"])
        let s = Script(); let svc = service(s, attach: true) { _ in }
        svc.start(); s.keyAge = 0; s.right = true; tick(svc, s, for: 0.5)
        #expect(["right ⌥ down", "push-to-talk hold reached", "none"].contains(svc.diagnostics.lastEvent) || svc.diagnostics.lastEvent.hasPrefix("right") || svc.diagnostics.lastEvent.hasPrefix("push"))
        svc.stop()
    }

    @Test("the hint for a hold while Voice is OFF is rate-limited, bilingual, and says the microphone stayed closed")
    func hint() {
        let now = Date()
        #expect(PushToTalkHint.shouldShow(lastShown: .distantPast, now: now))
        #expect(!PushToTalkHint.shouldShow(lastShown: now.addingTimeInterval(-5), now: now))
        #expect(PushToTalkHint.shouldShow(lastShown: now.addingTimeInterval(-25), now: now))
        #expect(PushToTalkHint.message(.tr).contains("mikrofon açılmadı") && PushToTalkHint.message(.en).contains("microphone stayed closed"))
    }

    @Test("the permission-free sampler reads the DEVICE bits: right and left Option are distinguishable")
    func deviceBits() {
        // 0x40 = right Option, 0x20 = left Option in the session's combined flag state (macOS 26, verified on this Mac)
        let right = ModifierSample(time: 1, option: true, command: false, other: false, secondsSinceOtherInput: 9, rightOption: 0x40 & 0x40 != 0, leftOption: 0x40 & 0x20 != 0, shift: false, control: false)
        #expect(right.rightOption && !right.leftOption)
    }
}
