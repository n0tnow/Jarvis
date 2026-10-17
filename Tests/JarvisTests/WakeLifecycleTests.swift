import Foundation
import Testing
@testable import Jarvis

// V1.0 stabilisation fix 2 — B: wake-word lifecycle on top of the V0.8 stack (fake helper, fake microphone; no real audio, no model, no quota).

@MainActor
@Suite("Stabilisation 2 · B · wake lifecycle", .serialized)
struct WakeLifecycleTests {
    @Test("sleep mode releases the microphone and the helper at once, keeps the SETTING, and an explicit resume brings wake listening back")
    func sleepMode() async {
        let r = HandsFreeRig()
        await r.hf.enable()
        #expect(r.hf.wakeStatus == .listening && r.hub.isCapturing)
        let slept = await r.hf.enterSleepMode()
        #expect(slept && r.hf.wakeStatus == .paused && !r.hub.isCapturing && r.sentinel.host.pid == nil && r.hf.isSleepingByUser)
        // A settings re-application (the preference observers call this) must NOT silently end sleep mode.
        await r.hf.applySettings()
        #expect(r.hf.wakeStatus == .paused && !r.hub.isCapturing)
        await r.hf.resumeFromSleepMode()
        #expect(r.hf.wakeStatus == .listening && r.hub.isCapturing && !r.hf.isSleepingByUser)
        await r.hf.disable()
    }

    @Test("sleep mode with nothing running is a truthful no-op")
    func sleepNothing() async {
        let r = HandsFreeRig()
        let slept = await r.hf.enterSleepMode()
        #expect(!slept && !r.hf.isSleepingByUser)
    }

    @Test("‘Dinlemeyi bırak’ ends an open hands-free exchange and returns to wake-only listening; with nothing open it says so")
    func endSession() async {
        let r = HandsFreeRig()
        r.h.stt.script = { $0.finalText = "Jarvis." }
        await r.hf.enable()
        #expect(!r.hf.endHandsFreeSession())                                             // wake-only listening: nothing to end
        await r.quiet(1.0); await r.speech(0.4); await r.wakeWord(); await r.quiet(0.8)
        await r.settle { r.hf.state == .attentive }
        #expect(r.hf.state == .attentive)
        #expect(r.hf.endHandsFreeSession())
        #expect(r.hf.state == .wakeListening && r.h.userMessages.isEmpty && r.hf.wakeStatus == .listening)
        await r.hf.disable()
    }

    @Test("the Mac going to sleep releases the microphone; waking brings wake listening back — but only if it was on")
    func systemSleep() async {
        let r = HandsFreeRig()
        r.hf.recoveryDelays = [0.05, 0.1]
        await r.hf.enable()
        await r.hf.suspendForSystemSleep()
        #expect(!r.hub.isCapturing && r.sentinel.host.pid == nil)
        r.hf.resumeAfterSystemWake()
        await r.settle { r.hf.wakeStatus == .listening }
        #expect(r.hf.wakeStatus == .listening && r.hub.isCapturing)
        await r.hf.disable()
        // wake was OFF before sleep: waking must not turn it on
        let off = HandsFreeRig()
        off.hf.recoveryDelays = [0.05]
        await off.hf.suspendForSystemSleep()
        off.hf.resumeAfterSystemWake()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!off.hub.isCapturing && off.hf.wakeStatus == .off)
    }

    @Test("an audio-device change is recovered with a bounded retry; if it keeps failing it stops and says so (no endless loop)")
    func deviceChange() async {
        let r = HandsFreeRig()
        r.hf.recoveryDelays = [0.05, 0.1]
        var events: [String] = []
        r.hf.onEvent = { message, _ in events.append(message) }
        await r.hf.enable()
        r.source.interrupt("the audio device changed")
        await r.settle { events.contains { $0.contains("recovered") } }
        #expect(r.hf.wakeStatus == .listening && events.contains { $0.contains("recovered") }, "\(events)")
        // now the device stays broken
        r.source.startError = VoiceError.microphoneUnavailable("no input device")
        r.source.interrupt("the audio device changed")
        try? await Task.sleep(for: .milliseconds(500))
        if case .unavailable = r.hf.wakeStatus {} else { Issue.record("expected unavailable, got \(r.hf.wakeStatus)") }
        #expect(events.contains { $0.contains("could not be restored") }, "\(events)")
        let starts = r.source.startCount
        try? await Task.sleep(for: .milliseconds(400))
        #expect(r.source.startCount == starts, "recovery gave up: no further attempts")
    }

    @Test("turning the Wake Word setting off cancels a pending recovery and clears sleep mode")
    func settingOffClears() async {
        let r = HandsFreeRig()
        await r.hf.enable()
        _ = await r.hf.enterSleepMode()
        r.hf.settings = { VoiceSettings(enabled: true, speakResponses: true, wakeEnabled: false, wakeAcknowledgement: .off, bargeInEnabled: true) }
        await r.hf.applySettings()
        #expect(!r.hf.isSleepingByUser && r.hf.wakeStatus == .off && !r.hub.isCapturing)
    }

    @Test("nothing before the wake word leaves the helper's pipe except bounded audio: no transcript, no recogniser, no message")
    func privacyBeforeWake() async {
        let r = HandsFreeRig()
        await r.hf.enable()
        await r.quiet(2)
        await r.speech(1.0)                                                          // someone talks, no wake word
        await r.quiet(0.5)
        #expect(r.h.stt.sessions.isEmpty && r.h.userMessages.isEmpty && r.hf.state == .wakeListening)
        await r.hf.disable()
    }
}

@Suite("Stabilisation 2 · B · voice commands stay distinct and the Voice settings tell the truth")
@MainActor
struct VoiceCommandDistinctnessTests {
    private func parse(_ s: String) -> SettingsIntent? { SettingsIntentParser.recognize(s) }

    @Test("five different phrases, five different handlers")
    func distinct() {
        #expect(parse("Dinlemeyi bırak") == .stopListening)
        #expect(parse("Uyku moduna geç") == .sleepMode)
        #expect(parse("Wake word'ü kapat") == .wake(false))
        #expect(parse("Sus") == nil)                                                 // CommandRouter: cancelGeneration (silence speech, stop generating)
        #expect(parse("Görevi durdur") == nil)                                       // CommandRouter: stopTask
        let router = IntelligenceRouter()
        #expect(router.route("Sus") == .command(.cancelGeneration, .tr))
        #expect(router.route("Görevi durdur") == .command(.stopTask, .tr))
        #expect(router.route("Wake word'ü kapat") != .command(.stopTask, .tr))
        #expect(parse("Stop listening") == .stopListening)
        #expect(parse("Go to sleep") == .sleepMode)
    }

    @Test("the status rows map the detector and the microphone truthfully")
    func rows() {
        func input(_ w: WakeStatus, wake: Bool = true, voice: Bool = true, sleeping: Bool = false, mic: MicrophonePermission = .granted) -> VoiceStatusRows.Input {
            .init(voiceEnabled: voice, pushToTalkEnabled: true, pttMonitorRunning: true, pttHandlerAttached: true, wakeEnabled: wake, wakeStatus: w, sleeping: sleeping, microphone: mic, sttReason: "Apple Speech", ttsReason: "Apple System Voice", sessionLabel: "WAKE")
        }
        func row(_ id: String, _ i: VoiceStatusRows.Input) -> VoiceStatusRow { VoiceStatusRows.rows(i).first { $0.id == id }! }
        #expect(row("detector", input(.listening)).value == "RUNNING")
        #expect(row("detector", input(.off, wake: false)).value == "STOPPED")
        #expect(row("detector", input(.unavailable("the wake-word helper is not installed"))).value == "ERROR")
        #expect(row("detector", input(.unavailable("x"))).detail == "x")
        #expect(row("detector", input(.paused, sleeping: true)).value.hasPrefix("PAUSED"))
        #expect(row("mic", input(.listening)).detail?.contains("In use now by the local wake detector") == true)
        #expect(row("mic", input(.off, wake: false)).detail?.contains("Closed") == true)
        #expect(row("voice", input(.off, wake: false, voice: false)).value == "OFF")
        #expect(row("ptt", input(.off, wake: false, voice: false)).value == "ON · VOICE IS OFF")
        #expect(VoiceStatusRows.rows(input(.listening)).map(\.title) == ["Voice", "Push-to-Talk", "Wake Word “Jarvis”", "Wake detector", "Microphone", "Speech recognition", "Speech output", "Hands-free session"])
    }

    @Test("the settings assistant routes the two session commands to the hands-free hooks and says what really happened")
    func hooks() async {
        let suite = "jarvis-fix2-voice-\(UUID().uuidString)"
        let prefs = Preferences(defaults: UserDefaults(suiteName: suite)!)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let a = SettingsAssistant(preferences: prefs, ledger: StorageLedger())
        var active = true, slept = false, ended = false
        a.wakeIsActive = { active }
        a.endListening = { ended = true; return false }
        a.enterSleep = { if active { slept = true; active = false; return true }; return false }
        a.isSleeping = { slept }
        var resumed = false
        a.resumeFromSleep = { resumed = true; slept = false }
        let notListening = a.perform(.stopListening, language: .tr)
        #expect(ended && notListening.contains("yalnızca “Jarvis” kelimesi için yerel wake algılayıcı"), Comment(rawValue: notListening))
        let sleepReply = a.perform(.sleepMode, language: .tr)
        #expect(slept && sleepReply.contains("Wake Word ayarı değişmedi"), Comment(rawValue: sleepReply))
        #expect(a.perform(.sleepMode, language: .tr).contains("Zaten uyku modundayım"))
        prefs.voiceWakeEnabled = true
        let wakeBack = a.perform(.wake(true), language: .tr)
        #expect(resumed && wakeBack.contains("Uyku modundan çıktım"), Comment(rawValue: wakeBack))
        #expect(a.changes.isEmpty, "session commands are not settings changes and cannot be ‘undone’ as one")
    }
}
