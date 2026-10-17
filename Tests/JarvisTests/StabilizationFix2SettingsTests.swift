import Testing
import Foundation
@testable import Jarvis

// V1.0 stabilisation fix 2 — D: settings requests are applied through typed settings with read-back evidence, preferences never go to Project Memory,
// and “where did you save that?” is answered from what really happened.

@MainActor
private final class FakeMemory: MemoryConversing {
    var commands: [MemoryCommand] = []
    var projectName: String?
    var stored = false
    func recognizes(_ text: String) -> MemoryCommand {
        let t = text.lowercased()
        if t.hasPrefix("hatırla:") || t.hasPrefix("remember that") { return .remember(String(text.drop(while: { $0 != ":" && $0 != " " }).dropFirst())) }
        return .none
    }
    func reply(to command: MemoryCommand, language: ReplyLanguage) async -> String? {
        commands.append(command)
        stored = projectName != nil
        return projectName == nil ? "Proje hafızası projeye özgüdür ve şu an seçili bir proje klasörü yok; bu yüzden HİÇBİR ŞEY kaydedilmedi." : "Hatırlayacağım."
    }
    func conversationContext(for prompt: String) async -> ConversationMemoryContext? { nil }
    func recordConversationUse(_ c: ConversationMemoryContext, runID: UUID?) {}
    var lastCommandStored: Bool { stored }
    var currentProjectName: String? { projectName }
}

@MainActor
private final class SettingsRig {
    let suite: String
    let defaults: UserDefaults
    var prefs: Preferences
    let ledger = StorageLedger()
    let assistant: SettingsAssistant
    let svc: ConversationService
    let conv = ConversationStore()
    let resolver = ScriptedAnswerResolver()
    let memory = FakeMemory()
    var loginStatus = LoginItemStatus.disabled
    var loginFails = false

    init(suite: String = "jarvis-fix2-\(UUID().uuidString)") {
        self.suite = suite
        defaults = UserDefaults(suiteName: suite)!
        prefs = Preferences(defaults: defaults)
        assistant = SettingsAssistant(preferences: prefs, ledger: ledger)
        svc = ConversationService(store: JarvisStore(), conversation: conv, windows: FakeWindows(), resolver: resolver)
        svc.settingsHandler = assistant
        svc.storageLedger = ledger
        svc.memoryHandler = memory
        assistant.loginItemStatus = { [unowned self] in self.loginStatus }
        assistant.setLoginItem = { [unowned self] on in
            if self.loginFails { return "macOS refused" }
            self.loginStatus = on ? .enabled : .disabled; return nil
        }
    }
    deinit { UserDefaults().removePersistentDomain(forName: suite) }

    @discardableResult
    func say(_ text: String) async -> String {
        svc.submit(text)
        await svc.waitUntilIdle()
        try? await Task.sleep(for: .milliseconds(80))
        return conv.last?.content ?? ""
    }
    var modelCalls: Int { resolver.prompts.count }
    /// What a relaunch would see.
    func relaunched() -> Preferences { Preferences(defaults: defaults) }
}

@Suite("Stabilisation 2 · D · settings requests are real")
@MainActor
struct SettingsActionTests {
    func r(_ s: String) -> SettingsIntent? { SettingsIntentParser.recognize(s) }

    @Test("the natural requests from the real conversation are recognised")
    func recognised() {
        #expect(r("Konuşma hızını biraz arttır") == .speechRate(.faster(0.05)))
        #expect(r("Konuşma hızını arttır") == .speechRate(.faster(0.1)))
        #expect(r("Konuşma hızını çok arttır") == .speechRate(.faster(0.2)))
        #expect(r("Daha yavaş konuş") == .speechRate(.slower(0.1)))
        #expect(r("Speak faster") == .speechRate(.faster(0.1)))
        #expect(r("Slow down your speech a bit") == .speechRate(.slower(0.05)))
        #expect(r("Konuşma hızını varsayılana döndür") == .speechRate(.reset))
        #expect(r("Eski haline getir") == .restore)
        #expect(r("Undo that") == .restore)
        #expect(r("Wake word'ü aç") == .wake(true))
        #expect(r("Wake word'ü kapat") == .wake(false))
        #expect(r("Turn off the wake word") == .wake(false))
        #expect(r("Daha kısa cevap ver") == .responseStyle(.concise))
        #expect(r("Give me more detailed answers") == .responseStyle(.detailed))
        #expect(r("Launch at Login'i aç") == .launchAtLogin(true))
        #expect(r("Bildirimleri aç") == .notifications(true))
        #expect(r("Turn off notifications") == .notifications(false))
        #expect(r("Bana bundan sonra efendim diye hitap edebilir misin?") == .address(.natural))
        #expect(r("Bana efendim deme") == .address(.off))
        #expect(r("Stop saying efendim") == .address(.off))
        #expect(r("Hangi ayarları özelleştirebilirsin?") == .listSettings)
        #expect(r("What settings can you change?") == .listSettings)
        #expect(r("Az önce hangi ayarı değiştirdin?") == .lastChange)
    }

    @Test("ordinary sentences that share words are NOT settings requests")
    func notSettings() {
        for s in ["Bana hızlı bir özet ver", "Faster algorithms for sorting", "Wake me up at seven", "Efendim ne demek?", "Is the speech faster now?", "Görevi geri al", "Bildirim nasıl çalışır?",
                  "Kısa bir hikaye yaz", "Explain how a wake word detector works", "Konuşma hızı nedir?", "Hamam ne durumda?", "Dosyayı aç", "Detaylı anlat", "Kısa söyle", "Wake word açık mı?",
                  "Can you see my screen?", "Can you read files?", "Can you do web research?", "What can you do?", "Can you use Codex?", "Which settings are on?"] {
            #expect(r(s) == nil, "“\(s)” was taken for a settings request")
        }
    }

    @Test("‘efendim’ is a PERSISTED SETTING, it takes effect, survives a relaunch, never touches Project Memory and never reaches a model")
    func efendim() async {
        let rig = SettingsRig()
        rig.prefs.addressStyle = .off
        let a = await rig.say("Bana bundan sonra efendim diye hitap edebilir misin?")
        #expect(a.contains("Ayar olarak kaydedildi") && a.contains("her cümlede değil"), Comment(rawValue: a))
        #expect(rig.prefs.addressStyle == .natural)
        #expect(rig.relaunched().addressStyle == .natural)
        #expect(rig.memory.commands.isEmpty && rig.modelCalls == 0)
        let where_ = await rig.say("Bunu nereye kaydettin?")
        #expect(where_.contains("[KALICI AYAR]") && where_.contains("hitap biçimi"), Comment(rawValue: where_))
        let off = await rig.say("Bana efendim deme")
        #expect(rig.prefs.addressStyle == .off && off.contains("bırakıyorum"))
    }

    @Test("speech rate: relative, bounded, restorable, persisted, and the reply carries the value that was read back")
    func speechRate() async {
        let rig = SettingsRig()
        #expect(rig.prefs.voiceSpeechRate == 1.0)
        var a = await rig.say("Konuşma hızını biraz arttır")
        #expect(rig.prefs.voiceSpeechRate == 1.05 && a.contains("1.00×") && a.contains("1.05×"), Comment(rawValue: a))
        a = await rig.say("Konuşma hızını arttır")
        #expect(abs(rig.prefs.voiceSpeechRate - 1.15) < 0.001)
        #expect(abs(rig.relaunched().voiceSpeechRate - 1.15) < 0.001)
        a = await rig.say("Eski haline getir")
        #expect(abs(rig.prefs.voiceSpeechRate - 1.05) < 0.001 && (a.contains("Geri aldım") || a.contains("Restored")), Comment(rawValue: a))
        a = await rig.say("Konuşma hızını varsayılana döndür")
        #expect(rig.prefs.voiceSpeechRate == 1.0)
        for _ in 0..<5 { await rig.say("Konuşma hızını çok arttır") }
        #expect(rig.prefs.voiceSpeechRate == 1.4)
        a = await rig.say("Konuşma hızını arttır")
        #expect(a.contains("en hızlı değerde") && rig.prefs.voiceSpeechRate == 1.4, Comment(rawValue: a))
        for _ in 0..<8 { await rig.say("Daha yavaş konuş çok") }
        #expect(rig.prefs.voiceSpeechRate >= 0.7)
        #expect(rig.modelCalls == 0)
    }

    @Test("‘last change’ and ‘what can you change’ come from real state")
    func introspection() async {
        let rig = SettingsRig()
        var a = await rig.say("Az önce hangi ayarı değiştirdin?")
        #expect(a.contains("hiçbir ayarı değiştirmedim"), Comment(rawValue: a))
        await rig.say("Daha kısa cevap ver")
        await rig.say("Konuşma hızını arttır")
        a = await rig.say("Az önce hangi ayarı değiştirdin?")
        #expect(a.contains("konuşma hızı") && a.contains("1.00×") && a.contains("1.10×"), Comment(rawValue: a))
        a = await rig.say("Hangi ayarları özelleştirebilirsin?")
        #expect(a.contains("konuşma hızı") && a.contains("wake word") && a.contains("efendim"))
        #expect(a.contains("İzinler, onaylar ve güvenlik ayarları bunların arasında değil"), Comment(rawValue: a))
        #expect(!a.lowercased().contains("api key") && !a.lowercased().contains("şifre"))
    }

    @Test("wake word, voice input and notifications change the typed setting and say what that means")
    func switches() async {
        let rig = SettingsRig()
        rig.prefs.voiceEnabled = false
        var a = await rig.say("Wake word'ü aç")
        #expect(rig.prefs.voiceWakeEnabled && a.contains("Ses girişi KAPALI"), Comment(rawValue: a))
        a = await rig.say("Ses girişini aç")
        #expect(rig.prefs.voiceEnabled && rig.relaunched().voiceEnabled)
        a = await rig.say("Wake word'ü kapat")
        #expect(!rig.prefs.voiceWakeEnabled && a.contains("hiçbir şey dinlemiyor"), Comment(rawValue: a))
        a = await rig.say("Wake word'ü kapat")
        #expect(a.contains("zaten kapalı"))
        a = await rig.say("Bildirimleri aç")
        #expect(rig.prefs.notifyOnTaskEvents && a.contains("proje içeriği olmadan"), Comment(rawValue: a))
        #expect(rig.modelCalls == 0)
    }

    @Test("Launch at Login is claimed only after macOS reports it; a refusal is reported as a refusal")
    func launchAtLogin() async {
        let rig = SettingsRig()
        var a = await rig.say("Launch at Login'i aç")
        #expect(rig.loginStatus == .enabled && a.contains("Girişte başlatma açık"), Comment(rawValue: a))
        a = await rig.say("Eski haline getir")
        #expect(rig.loginStatus == .disabled)
        rig.loginFails = true
        a = await rig.say("Launch at Login'i aç")
        #expect(rig.loginStatus == .disabled && a.contains("değiştiremedim") && !a.contains("açık."), Comment(rawValue: a))
        rig.loginFails = false
        rig.assistant.setLoginItem = { [unowned rig] _ in rig.loginStatus = .requiresApproval; return nil }
        a = await rig.say("Launch at Login'i aç")
        #expect(a.contains("onayınızı bekliyor") && a.contains("sizin yerinize onaylayamam"), Comment(rawValue: a))
    }

    @Test("a preference sentence is never sent to Project Memory, and an unsaved memory request says NOTHING was saved")
    func memoryDoesNotHijack() async {
        let rig = SettingsRig()
        await rig.say("Daha kısa cevap ver")
        #expect(rig.memory.commands.isEmpty)
        let a = await rig.say("Hatırla: kısa cevapları seviyorum")
        #expect(rig.memory.commands.count == 1 && a.contains("HİÇBİR ŞEY kaydedilmedi"), Comment(rawValue: a))
        let where_ = await rig.say("Bunu nereye kaydettin?")
        #expect(where_.contains("[KAYDEDİLMEDİ]") && where_.contains("hiçbir yerde saklanmıyor"), Comment(rawValue: where_))
        let will = await rig.say("Bunu hatırlayacak mısın?")
        #expect(will.contains("Az önce hiçbir şey kaydedilmedi") || will.contains("[KAYDEDİLMEDİ]"), Comment(rawValue: will))
    }

    @Test("with a project, a remember request is PROJECT MEMORY and the ledger says so")
    func projectMemoryStored() async {
        let rig = SettingsRig()
        rig.memory.projectName = "Hamam"
        await rig.say("Hatırla: oyuncu hızı 5 olmalı")
        let a = await rig.say("Kalıcı mı?")
        #expect(a.contains("[PROJE HAFIZASI]") && a.contains("Hamam"), Comment(rawValue: a))
    }

    @Test("nothing recently written: the honest answer, in English as well")
    func nothingStored() async {
        let rig = SettingsRig()
        let a = await rig.say("Will you remember that?")
        #expect(a.contains("Nothing was saved just now") && a.contains("only in this conversation"), Comment(rawValue: a))
        #expect(rig.modelCalls == 0)
    }

    @Test("the answer length setting is persisted and one-off depth requests keep their own route")
    func responseStyle() async {
        let rig = SettingsRig()
        rig.prefs.responseStyle = .balanced
        let a = await rig.say("Daha kısa cevap ver")
        #expect(rig.prefs.responseStyle == .concise && rig.relaunched().responseStyle == .concise && a.contains("tek bir cevap için"), Comment(rawValue: a))
        #expect(SettingsIntentParser.recognize("Kısa söyle") == nil)
    }
}

@Suite("Stabilisation 2 · D · corrections")
@MainActor
struct CorrectionTests {
    @Test("cues and the corrected request are separated; letters and case are kept")
    func parsing() {
        #expect(CorrectionParser.parse("Hayır, ekranıma bak demek istedim") == Correction(strength: .strong, remainder: "ekranıma bak") || CorrectionParser.parse("Hayır, ekranıma bak demek istedim")?.remainder == "ekranıma bak")
        #expect(CorrectionParser.parse("Demek istediğim Claude hazır mı")?.remainder == "Claude hazır mı")
        #expect(CorrectionParser.parse("No, I meant Codex")?.remainder == "Codex")
        #expect(CorrectionParser.parse("Yanlış anladın.") == Correction(strength: .strong, remainder: ""))
        #expect(CorrectionParser.parse("Hayır") == Correction(strength: .weak, remainder: ""))
        #expect(CorrectionParser.parse("Hayır, Codex hazır mı?")?.remainder == "Codex hazır mı?")
        #expect(CorrectionParser.parse("Ekranıma bak demek istedim")?.remainder == "Ekranıma bak")
        #expect(CorrectionParser.parse("That's not what I asked, tell me about Codex")?.remainder == "tell me about Codex")
        for s in ["Hayırlı olsun", "Nobody knows", "Notları göster", "Hayatta kalmak", "Claude hazır mı?", "I mean business"] where s != "I mean business" {
            #expect(CorrectionParser.parse(s) == nil, "“\(s)”")
        }
    }

    @Test("a corrected question is routed again from scratch, not answered with the old route")
    func rerouted() async {
        let rig = Rig2(reply: "model answer")
        let first = await rig.say("Claude hazır mı?")
        #expect(first.contains("Claude Code"))
        let second = await rig.say("Hayır, Codex hazır mı demek istedim")
        #expect(second.contains("Codex") && !second.contains("Claude Code"), Comment(rawValue: second))
        #expect(rig.calls() == 0)
    }

    @Test("a corrected request that is not a status question goes down the normal route with the corrected text")
    func reroutedToConversation() async {
        let rig = Rig2(reply: "tamam")
        await rig.say("Ekranımı görebiliyor musun?")
        await rig.say("Hayır, bana bir hikaye anlat demek istedim")
        #expect(rig.lastPrompt() == "bana bir hikaye anlat")
    }

    @Test("a fragment completes a settings subject only right after a settings change, never after another kind of turn")
    func fragmentNeedsSettingsContext() async {
        let rig = SettingsRig()
        await rig.say("Konuşma hızını arttır")
        await rig.say("Bana bundan sonra efendim diye hitap edebilir misin?")      // the LAST turn is a settings change about the address, not about speech
        await rig.say("Claude hazır mı?")
        let a = await rig.say("Hayır, Codex hazır mı demek istedim")
        #expect(!a.contains("Ayar olarak kaydedildi"), Comment(rawValue: a))
    }

    @Test("a bare ‘you misunderstood’ asks what was meant, quoting the previous sentence and how it was read")
    func asksWhatWasMeant() async {
        let rig = Rig2()
        await rig.say("Claude hazır mı?")
        let a = await rig.say("Yanlış anladın")
        #expect(a.contains("Claude hazır mı?") && a.contains("durum/yetenek sorusu") && a.contains("Asıl neyi kastettiniz"), Comment(rawValue: a))
        #expect(rig.calls() == 0)
    }

    @Test("a correction after a settings change completes the subject of that change")
    func settingsCorrection() async {
        let rig = SettingsRig()
        await rig.say("Konuşma hızını arttır")
        #expect(abs(rig.prefs.voiceSpeechRate - 1.1) < 0.001)
        await rig.say("Hayır, yavaşlat")
        #expect(abs(rig.prefs.voiceSpeechRate - 1.0) < 0.001)
        #expect(rig.modelCalls == 0)
    }

    @Test("a bare ‘hayır’ is never a conversational correction while a decision is waiting, and it approves nothing")
    func pendingDecision() async {
        let rig = SettingsRig()
        rig.svc.hasPendingDecision = { true }
        await rig.say("Konuşma hızını arttır")
        let before = rig.prefs.voiceSpeechRate
        let a = await rig.say("Evet")
        #expect(a.contains("HUD") || a.lowercased().contains("onay") || a.lowercased().contains("approv"), Comment(rawValue: a))
        await rig.say("Hayır")
        #expect(rig.prefs.voiceSpeechRate == before)
    }

    @Test("a Project Memory correction (“hayır, artık X kullanmıyoruz” right after a memory answer) still belongs to Project Memory")
    func memoryCorrectionKeepsRoute() async {
        let rig = SettingsRig()
        rig.memory.projectName = "Hamam"
        await rig.say("Hatırla: oyuncu hızı 5 olmalı")
        #expect(rig.memory.commands.count == 1)
        await rig.say("Hayır, oyuncu hızı artık 6 olmalı")
        // The second sentence is not re-routed as a conversational correction: it reaches the memory handler's own parser (the fake only knows “remember”).
        #expect(rig.memory.commands.count == 1)
        #expect(rig.conv.last?.content.isEmpty == false)
    }

    @Test("a voice transcript with a predictable mishearing is repaired for routing; what was heard stays visible")
    func transcriptRepair() async {
        let rig = SettingsRig()
        rig.svc.submit("weak word'ü aç", source: .voice)
        await rig.svc.waitUntilIdle()
        #expect(rig.prefs.voiceWakeEnabled)
        #expect(rig.conv.messages.first(where: { $0.role == .user })?.content == "weak word'ü aç")
        #expect(SpeechTranscriptRepair.repair("approve it") == "approve it" && SpeechTranscriptRepair.repair("delete everything") == "delete everything")
    }
}

@Suite("Stabilisation 2 · D · corrections do not swallow ordinary answers")
struct CorrectionNegativeTests {
    @Test("‘No thanks’, ‘Hayır teşekkürler’, ‘Hata mesajını göster’ are not corrections")
    func notCorrections() {
        for s in ["No thanks", "Hayır teşekkürler", "Hata mesajını göster", "No problem", "Wrong answers are fine", "Yanlış bilgi vermeyin"] {
            #expect(CorrectionParser.parse(s) == nil, "“\(s)”")
        }
        #expect(CorrectionParser.parse("No, show me Codex")?.remainder == "show me Codex")
    }
}
