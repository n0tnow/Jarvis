import Testing
import Foundation
@testable import Jarvis

// V1.0 stabilisation fix 4 — "Sistem durumunu söyler misin?" is answered from the structured system state, never by a language model.

@MainActor
private func statusRig(wake: Bool = true, detector: WakeDetectorProbe = .running, voiceOn: Bool = true, project: String? = nil, tasks: Int = 0, agents: Int = 0, edit: @escaping (inout ReadinessProbes) -> Void = { _ in }) -> Rig2 {
    let rig = Rig2(reply: "Şu an sesini duyuyorum. Bunu söyleyemem.", edit: edit)       // the model's own (false) answer, in case it is ever reached
    rig.assistant.statusProvider = {
        SystemStatusSnapshot(state: .idle, versionLine: "0.15.0 · build 102", readiness: rig.readiness.refresh(), project: project, activeTasks: tasks, activeAgents: agents,
                             voiceOn: voiceOn, pushToTalkOn: true, wakeEnabled: wake, wakeDetector: detector, providerPreference: "Auto")
    }
    return rig
}

@Suite("Fix 4 · system status is deterministic and says what the HUD says")
@MainActor
struct SystemStatusTests {
    @Test("every phrasing the user used reaches the structured status — zero model calls, no ‘bunu söyleyemem’")
    func variants() async {
        let rig = statusRig()
        for s in ["Sistem durumunu söyle.", "Sistem durumunu söyler misin?", "Her şey hazır mı?", "Sistem durumunu kısaca özetle", "System status", "Is everything ready?"] {
            let a = await rig.say(s)
            #expect(!a.contains("söyleyemem") && !a.contains("sesini duyuyorum"), "“\(s)” → \(a)")
            #expect(a.contains("Wake word") || a.contains("wake word") || a.contains("Wake Word"), "“\(s)” → \(a)")
        }
        let running = await rig.say("Neler çalışıyor?")
        #expect(running.contains("wake word algılayıcısı") && running.contains("Push-to-Talk"), Comment(rawValue: running))
        let features = await rig.say("Şu an hangi özelliklerin aktif?")
        #expect(features.contains("Ses girişi açık"), Comment(rawValue: features))
        let providers = await rig.say("Providerların ne durumda?")
        #expect(providers.contains("Claude Code") && providers.contains("Codex"), Comment(rawValue: providers))
        let wake = await rig.say("Wake word çalışıyor mu?")
        #expect(wake.contains("Wake word çalışıyor"), Comment(rawValue: wake))
        let computer = await rig.say("Computer Use hazır mı?")
        #expect(computer.contains("Evet") || computer.contains("hazır"), Comment(rawValue: computer))
        #expect(rig.calls() == 0)
    }

    @Test("the answer is generated from the state: change the state and the sentence changes (wake off / stopped / error, no project / a project, tasks)")
    func followsState() async {
        let on = await statusRig(detector: .running).say("Sistem durumunu söyle")
        #expect(on.contains("Wake word çalışıyor"), Comment(rawValue: on))
        let off = await statusRig(wake: false).say("Sistem durumunu söyle")
        #expect(off.contains("Wake word kapalı") && !off.contains("Wake word çalışıyor"), Comment(rawValue: off))
        let err = await statusRig(detector: .error("mikrofon izni yok")).say("Sistem durumunu söyle")
        #expect(err.contains("Wake word hatalı: mikrofon izni yok"), Comment(rawValue: err))
        let none = await statusRig().say("Sistem durumunu söyle")
        #expect(none.contains("Aktif görev yok") && none.contains("seçili proje yok"), Comment(rawValue: none))
        let busy = await statusRig(project: "Hamam", tasks: 2, agents: 1).say("Sistem durumunu söyle")
        #expect(busy.contains("2 aktif görev") && busy.contains("1 ajan çalışıyor") && busy.contains("proje: Hamam"), Comment(rawValue: busy))
        let voiceOff = await statusRig(wake: false, voiceOn: false).say("Sistem durumunu söyle")
        #expect(voiceOff.contains("Ses girişi kapalı"), Comment(rawValue: voiceOff))
    }

    @Test("permissions are reported as the readiness records say — and a missing one says what JARVIS cannot do")
    func permissions() async {
        let ok = await statusRig().say("Sistem durumunu söyle")
        #expect(ok.contains("Accessibility ve Screen Recording hazır"), Comment(rawValue: ok))
        let noAX = await statusRig(edit: { $0.accessibility = { .denied } }).say("Sistem durumunu söyle")
        #expect(noAX.contains("Accessibility izni yok") && noAX.contains("diğer uygulamaları kullanamam"), Comment(rawValue: noAX))
        #expect(noAX.contains("Dikkat gerektiren") && noAX.contains("Accessibility"))
    }

    @Test("‘detaylı anlat’ expands the same snapshot (more facts, same truth)")
    func detail() async {
        let rig = statusRig()
        let brief = await rig.say("Sistem durumunu söyle")
        let more = await rig.say("Detaylı anlat")
        #expect(more.count > brief.count && more.contains("Sürüm") && more.contains("Unity"), Comment(rawValue: more))
    }

    @Test("with nothing wrong it says so in English too, and the same words come from the same state")
    func english() async {
        let a = await statusRig().say("What's the system status?")
        #expect(a.contains("wake word is running") && a.contains("No active task"), Comment(rawValue: a))
    }
}

@Suite("Fix 4 · a model can never claim an action that no receipt backs")
@MainActor
struct ActionClaimGuardTests {
    @Test("the claims JARVIS made in the real session are detected; ordinary sentences are not")
    func detection() {
        for s in ["Şimdi Safari'yi açıyorum.", "Safari'daki videoyu oynatmaya devam ediyorum.", "Videoyu başlatıyorum.", "Dosyayı kaydettim.", "Ayarı değiştirdim.", "Görevi tamamladım", "Klasörü sildim",
                  "I've opened Safari.", "I'm playing the video now.", "I just started it", "I pressed nothing but I have saved the file"] {
            #expect(!ActionClaimGuard.claims(in: s).isEmpty, "“\(s)” must be treated as an action claim")
        }
        for s in ["Safari bir web tarayıcısıdır.", "Şu an sesini duyuyorum ve seninle konuşuyorum.", "Safari'yi açmanı öneririm.", "You can open Safari from the Dock.", "Bunu yapabilirim, istersen söyle.", "The video will start when you press play.", "Sistem hazır."] {
            #expect(ActionClaimGuard.claims(in: s).isEmpty, "“\(s)” is not a claim of an action")
        }
    }

    @Test("a model answer that claims it opened/played something is replaced by a true notice (typed or spoken — it is one text)")
    func replaced() async {
        let rig = Rig2(reply: "Tabii. Safari'yi açıyorum. Videoyu başlatıyorum, bir saniye.")
        let a = await rig.say("Bana kısa bir hikaye anlat lütfen")
        #expect(!a.contains("açıyorum") && !a.contains("başlatıyorum"), Comment(rawValue: a))
        #expect(a.contains("hiçbir eylem gerçekleştirilmedi"), Comment(rawValue: a))
        let en = await Rig2(reply: "Sure! I've opened Safari and I'm playing the video.").say("Tell me a short story please")
        #expect(!en.contains("I've opened") && en.contains("nothing was executed"), Comment(rawValue: en))
    }

    @Test("an honest model answer is left alone")
    func honestUntouched() async {
        let text = "Safari, Apple'ın web tarayıcısıdır. İstersen onu açmamı söyleyebilirsin."
        #expect(await Rig2(reply: text).say("Safari nedir anlatır mısın") == text)
    }
}
