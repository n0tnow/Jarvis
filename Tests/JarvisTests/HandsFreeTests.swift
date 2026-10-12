import Foundation
import Testing
@testable import Jarvis

/// The hands-free orchestration (turn manager effects layer) around the REAL VoiceCoordinator, ConversationService and sentinel runtime — with a fake helper process,
/// a fake microphone and a fake recogniser/speaker. Timings are shortened; nothing here is audio-hardware dependent.
@MainActor
struct HandsFreeRig {
    let h: VoiceHarness
    let hub: MicrophoneHub
    let source: FakeAudioInput
    let sentinel: SentinelRuntime
    let hf: HandsFreeCoordinator

    init(speak: Bool = true) {
        source = FakeAudioInput()
        let src = source
        hub = MicrophoneHub(makeSource: { src })
        h = VoiceHarness(hub: hub, wake: true)
        (sentinel, _, _, _) = FakeSentinel.make()
        hf = HandsFreeCoordinator(hub: hub, sentinel: sentinel, voice: h.voice)
        hf.settings = { VoiceSettings(enabled: true, speakResponses: speak, wakeEnabled: true, wakeAcknowledgement: .off, bargeInEnabled: true) }
        var cfg = TurnConfig()
        cfg.attentiveSeconds = 1.2; cfg.followUpSeconds = 0.6; cfg.continuationSeconds = 0.12; cfg.postSpeechDeafness = 0.05; cfg.wakeDeafness = 0.05
        cfg.endpoint.completeSilence = 0.15; cfg.endpoint.unknownSilence = 0.2; cfg.endpoint.incompleteSilence = 0.3; cfg.endpoint.hardCapSilence = 0.35
        cfg.endpoint.shortCommandSilence = 0.12; cfg.endpoint.minimumSpeech = 0.1
        hf.config = cfg
    }

    /// A 1 kHz tone (the barge-in level measurement high-passes at 250 Hz, so DC test frames would vanish).
    func tone(_ amplitude: Float, count: Int = 1600) -> AudioFrame { AudioFrame(samples: (0..<count).map { amplitude * sin(2 * .pi * 1000 * Float($0) / 16000) }) }
    private func frame(_ amplitude: Int16, seconds: Double = 0.1) -> AudioFrame { AudioFrame(samples: [Float](repeating: Float(amplitude) / 32767, count: Int(seconds * 16000))) }
    /// "speech" for the fake VAD (peak > 3000), a silent frame, the fake wake marker.
    /// Frames are paced (≈ 25 ms per 100 ms of audio) so the helper's events and the timers interleave with the audio like they do with a real microphone.
    func speech(_ seconds: Double) async { for _ in 0..<Int(seconds * 10) { source.emit(frame(6000)); try? await Task.sleep(for: .milliseconds(25)) } }
    func quiet(_ seconds: Double) async { for _ in 0..<Int(seconds * 10) { source.emit(frame(20)); try? await Task.sleep(for: .milliseconds(25)) } }          // ≈ −64 dBFS: a quiet room
    func wakeWord() async { source.emit(frame(12345)); try? await Task.sleep(for: .milliseconds(25)) }

    func settle(_ timeout: Double = 3, _ cond: @MainActor () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    }
}

extension FakeAudioInput {
    /// Delivers one frame immediately (a test microphone does not need real-time pacing).
    func emit(_ frame: AudioFrame) { feedFrame(frame) }
}

@MainActor
@Suite("Hands-free turn taking (fake helper, fake microphone)", .serialized)
struct HandsFreeCoordinatorTests {
    @Test func wakeModeIsOffUntilEnabledAndThenUsesOneMicrophoneEngine() async {
        let r = HandsFreeRig()
        #expect(r.hf.state == .dormant && !r.hub.isCapturing && r.sentinel.host.pid == nil, "nothing listens before wake mode is enabled")
        await r.hf.enable()
        #expect(r.hf.wakeStatus == .listening && r.hf.state == .wakeListening && r.hub.isCapturing && r.hub.subscriberLabels == ["wake"] && r.sentinel.isRunning)
        #expect(r.h.voice.state == .idle && r.h.stt.sessions.isEmpty, "no recogniser session exists before the wake word")
        await r.hf.disable()
        #expect(!r.hub.isCapturing && r.hub.subscriberCount == 0 && r.sentinel.host.pid == nil && r.hf.state == .dormant && r.hf.wakeStatus == .off)
    }

    @Test func missingHelperMeansWakeUnavailableAndNoMicrophone() async {
        let r = HandsFreeRig()
        let (missing, _, _, _) = FakeSentinel.make(existingFiles: false)
        let hf = HandsFreeCoordinator(hub: r.hub, sentinel: missing, voice: r.h.voice)
        hf.settings = { VoiceSettings(enabled: true, wakeEnabled: true) }
        await hf.enable()
        if case .unavailable = hf.wakeStatus {} else { Issue.record("expected unavailable, got \(hf.wakeStatus)") }
        #expect(!r.hub.isCapturing && hf.state == .dormant)
    }

    @Test func deniedMicrophoneMeansWakeUnavailable() async {
        let r = HandsFreeRig()
        r.h.mic.status = .denied
        r.h.voice.refreshPermission()
        await r.hf.enable()
        if case .unavailable(let why) = r.hf.wakeStatus { #expect(why.contains("microphone")) } else { Issue.record("expected unavailable") }
        #expect(!r.hub.isCapturing && r.sentinel.host.pid == nil)
    }

    @Test func aQuietRoomSendsNothingToTheSentinel() async {
        let r = HandsFreeRig()
        await r.hf.enable()
        await r.quiet(5)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(r.sentinel.metrics.framesSent == 0, "the energy gate keeps the helper fed with nothing while the room is quiet")
        await r.hf.disable()
    }

    @Test func fullHandsFreeTurnGoesThroughTheSharedSubmissionPath() async {
        let r = HandsFreeRig()
        r.h.stt.script = { $0.finalText = "Jarvis, open the tasks screen" }
        await r.hf.enable()
        await r.quiet(1.0)
        await r.speech(0.5); await r.wakeWord()                                   // «Jarvis, open …» in one breath: the word arrives while the VAD already hears speech
        await r.speech(0.5)
        await r.quiet(0.6)
        await r.settle { r.h.userMessages.count == 1 }
        print("DIAG state \(r.hf.state.label) transitions \(r.hf.transitions.map(\.state)) voice \(r.h.voice.state.label) sessions \(r.h.stt.sessions.count) sent \(r.sentinel.metrics.framesSent) wake \(r.sentinel.metrics.wakeEvents) vad \(r.sentinel.metrics.vadTransitions) rejected \(r.hf.rejectedWakes) status \(r.hf.wakeStatus.label) hub \(r.hub.subscriberLabels)")
        #expect(r.h.userMessages.count == 1 && r.h.userMessages.first?.source == .voice, "the final transcript entered the conversation as a normal voice message · state \(r.hf.state.label) · transitions \(r.hf.transitions.map(\.state)) · voice \(r.h.voice.state.label) · sessions \(r.h.stt.sessions.count) · sentinel sent \(r.sentinel.metrics.framesSent) wake \(r.sentinel.metrics.wakeEvents) vad \(r.sentinel.metrics.vadTransitions) · rejected \(r.hf.rejectedWakes)")
        #expect(r.h.stt.sessions.count == 1 && r.hf.wakeCount == 1)
        await r.settle { r.hf.state == .attentive || r.hf.state == .wakeListening }
        #expect(r.h.base.conversation.messages.contains { $0.role == .jarvis }, "the same router answered")
        await r.settle(3) { r.hf.state == .wakeListening }
        #expect(r.hf.state == .wakeListening, "the follow-up window expired and wake-only listening returned")
        await r.hf.disable()
    }

    @Test func aLoneWakeWordNeverOpensTheRecogniserAndOpensTheAttentiveWindow() async {
        let r = HandsFreeRig()
        r.h.stt.script = { $0.finalText = "Jarvis." }
        await r.hf.enable()
        await r.quiet(1.0); await r.speech(0.4); await r.wakeWord(); await r.quiet(0.8)
        await r.settle { r.hf.state == .attentive }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(r.hf.state == .attentive && r.h.stt.sessions.isEmpty && r.h.userMessages.isEmpty, "the word alone: attentive, NO recogniser session, no message")
        await r.hf.disable()
    }

    @Test func aTranscriptThatIsOnlyTheWakeWordIsNotAMessage() async {
        let r = HandsFreeRig()
        r.h.stt.script = { $0.finalText = "Jarvis." }                       // e.g. «Jarvis» + a cough: the recogniser hears only the name
        await r.hf.enable()
        await r.quiet(1.0); await r.speech(0.4); await r.wakeWord(); await r.speech(0.5); await r.quiet(0.8)
        await r.settle { r.h.stt.sessions.first?.finished == true }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(r.h.userMessages.isEmpty && r.hf.state == .attentive, "a lone wake word opens the attentive window, it is not a command")
        await r.hf.disable()
    }

    @Test func aQuoteOfJarvisOwnSpeechIsDroppedBeforeItBecomesATurn() async {
        let r = HandsFreeRig()
        // JARVIS just said this (the speaker keeps a short memory of its own phrases for exactly this check)
        r.h.voice.speaker.speakStandalone("The Unity tests are complete. No new console errors were detected.", language: .english)
        await r.settle { !r.h.tts.spoken.isEmpty }
        r.h.stt.script = { $0.finalText = "the unity tests are complete no new console errors were detected" }
        await r.hf.enable()
        await r.settle { !r.h.voice.speaker.isActive }
        await r.quiet(1.0); await r.speech(0.4); await r.wakeWord(); await r.speech(0.4); await r.quiet(0.6)
        await r.settle { r.h.stt.sessions.first?.finished == true }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(r.h.userMessages.isEmpty, "self-speech never becomes a user turn")
        await r.hf.disable()
    }

    @Test func pushToTalkKeepsWorkingNextToWakeModeOnTheSameEngine() async {
        let r = HandsFreeRig()
        await r.hf.enable()
        let starts = r.hub.startCount
        r.h.voice.pushToTalkPressed()
        await r.settle { r.h.voice.state == .listening }
        #expect(r.hub.subscriberLabels == ["push-to-talk", "wake"] && r.hub.startCount == starts, "one engine, two subscribers")
        await r.speech(0.6)
        r.h.stt.script = { $0.finalText = "open the tasks screen" }
        r.h.voice.pushToTalkReleased()
        await r.settle { r.h.userMessages.count == 1 }
        #expect(r.h.userMessages.count == 1 && r.hub.subscriberLabels == ["wake"], "the key release closed ITS subscription only")
        await r.hf.disable()
    }

    @Test func pushToTalkWorksWithWakeModeOffAndTheEngineExistsOnlyWhileHeld() async {
        let source = FakeAudioInput()
        let hub = MicrophoneHub(makeSource: { source })
        let h = VoiceHarness(hub: hub, wake: false)
        h.stt.script = { $0.finalText = "open the tasks screen" }
        #expect(!hub.isCapturing)
        h.voice.pushToTalkPressed()
        await h.settle { h.voice.state == .listening }
        #expect(hub.isCapturing && hub.subscriberLabels == ["push-to-talk"])
        source.feed(seconds: 0.6)
        h.voice.pushToTalkReleased()
        #expect(!hub.isCapturing, "released: the microphone is closed")
        await h.settle { h.userMessages.count == 1 }
        #expect(h.userMessages.count == 1)
    }

    @Test func spokenApprovalsNeverApproveInHandsFreeEither() async {
        let r = HandsFreeRig()
        r.h.base.store.setEngineApproval(ApprovalRequest(title: "Delete build (fixture)", detail: "isolated"), id: UUID())
        r.h.stt.script = { $0.finalText = "Jarvis, evet onayla" }
        await r.hf.enable()
        await r.quiet(1.0); await r.speech(0.4); await r.wakeWord(); await r.speech(0.4); await r.quiet(0.6)
        await r.settle { r.h.base.conversation.messages.contains { $0.role == .jarvis } }
        #expect(r.h.base.store.pendingApproval != nil, "the approval is still pending")
        let reply = r.h.base.conversation.messages.last(where: { $0.role == .jarvis })?.content.lowercased() ?? ""
        #expect(reply.contains("hud"), "JARVIS says approvals are HUD-only: \(reply)")
        await r.hf.disable()
    }

    @Test func disablingWakeModeInTheMiddleOfAnUtteranceDiscardsIt() async {
        let r = HandsFreeRig()
        r.h.stt.script = { $0.finalText = "should never be submitted" }
        await r.hf.enable()
        await r.quiet(1.0); await r.speech(0.4); await r.wakeWord(); await r.speech(0.3)
        await r.settle { r.h.voice.state == .listening }
        await r.hf.disable()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(r.h.userMessages.isEmpty && r.h.voice.state == .idle && !r.hub.isCapturing)
    }

    @Test func bargeInStopsSpeechAndStartsANewUtterance() async {
        let r = HandsFreeRig()
        r.h.tts.auto = false
        r.h.stt.script = { $0.finalText = "open the tasks screen" }
        await r.hf.enable()
        // a turn whose answer is being spoken
        await r.quiet(1.0); await r.speech(0.4); await r.wakeWord(); await r.speech(0.4); await r.quiet(0.6)
        await r.settle { !r.h.tts.spoken.isEmpty }
        let id = r.h.tts.spoken[0].id
        r.h.tts.begin(id)                                                   // JARVIS is audible
        await r.settle { r.hf.state == .jarvisSpeaking }
        #expect(r.hf.state == .jarvisSpeaking)
        // the speaker's own level (reference) and the microphone hears it quietly; the VAD calls it speech — still no interruption
        for k in 0..<60 { r.hf.referenceLevel(-20, at: ProcessInfo.processInfo.systemUptime + Double(k) * 0.02) }
        for _ in 0..<12 { r.source.emit(r.tone(0.0057)); try? await Task.sleep(for: .milliseconds(100)) }      // 1.2 s: past the calibration window
        try? await Task.sleep(for: .milliseconds(150))
        #expect(r.hf.state == .jarvisSpeaking && r.hf.bargeInCount == 0, "its own voice at the echo level never interrupts it")
        // the user speaks clearly louder than the echo: sustained, with VAD speech
        r.h.stt.script = { $0.finalText = "stop, open the system screen" }
        for _ in 0..<8 {
            r.hf.referenceLevel(-20, at: ProcessInfo.processInfo.systemUptime)
            r.source.emit(r.tone(0.28))
            try? await Task.sleep(for: .milliseconds(40))
        }
        await r.settle { r.hf.bargeInCount == 1 }
        #expect(r.hf.bargeInCount == 1 && r.h.tts.stopCount >= 1, "barge-in stopped the speech")
        #expect(r.hf.state == .userSpeaking || r.hf.state == .interrupting || r.h.voice.state == .listening)
        await r.hf.disable()
    }

    @Test func shutdownKillsTheHelperAndClosesTheMicrophone() async {
        let r = HandsFreeRig()
        await r.hf.enable()
        let pid = r.sentinel.host.pid
        r.hf.shutdown()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!r.hub.isCapturing && (pid.map { !ProcessTree.isAlive($0) } ?? false) && r.hf.state == .dormant)
    }

    @Test func presenceIsTruthfulAndNeverColourOnly() {
        #expect(VoicePresence.resolve(session: .idle, handsFree: .wakeListening, wake: .listening) == .wake)
        #expect(VoicePresence.resolve(session: .idle, handsFree: .wakeListening, wake: .unavailable("x")) == .off, "unavailable wake mode is never shown as WAKE")
        #expect(VoicePresence.resolve(session: .listening, handsFree: .wakeListening, wake: .listening) == .listening)
        #expect(VoicePresence.resolve(session: .idle, handsFree: .attentive, wake: .listening) == .attentive)
        #expect(VoicePresence.resolve(session: .speaking, handsFree: .jarvisSpeaking, wake: .listening) == .speaking)
        #expect(VoicePresence.resolve(session: .idle, handsFree: .interrupting, wake: .listening) == .interrupted)
        for p in [VoicePresence.wake, .attentive, .listening, .transcribing, .thinking, .speaking, .interrupted, .error("x")] {
            #expect(!p.label.isEmpty && !p.symbolName.isEmpty && !p.spokenLabel.isEmpty, "words + an icon for every state")
        }
    }
}
