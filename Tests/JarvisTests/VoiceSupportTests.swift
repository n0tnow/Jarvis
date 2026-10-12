import Foundation
import Testing
@testable import Jarvis

@Suite("Speech metrics (benchmark support)")
struct SpeechMetricsTests {
    @Test func normalisationKeepsTurkishLettersAndDropsPunctuation() {
        #expect(SpeechMetrics.normalize("Jarvis, Unity'deki SON task'ın durumunu göster.") == "jarvis unity deki son task ın durumunu göster")
        #expect(SpeechMetrics.normalize("İSTANBUL IŞIK") == "istanbul ışık", "Turkish case folding: İ→i, I→ı")
        #expect(SpeechMetrics.normalize("çğıöşü").count == 6)
    }
    @Test func werAndCerAreEditDistances() {
        #expect(SpeechMetrics.wer(reference: "open the tasks screen", hypothesis: "open the tasks screen") == 0)
        #expect(SpeechMetrics.wer(reference: "open the tasks screen", hypothesis: "open tasks screen") == 0.25)
        #expect(SpeechMetrics.wer(reference: "a b c d", hypothesis: "") == 1)
        #expect(SpeechMetrics.wer(reference: "", hypothesis: "") == 0)
        #expect(SpeechMetrics.cer(reference: "kontrol", hypothesis: "kontrol") == 0)
        #expect(abs(SpeechMetrics.cer(reference: "kontrol", hypothesis: "kontrole") - 1.0 / 7.0) < 1e-9)
        #expect(SpeechMetrics.wer(reference: "Görevler ekranını aç", hypothesis: "gorevler ekranini ac") == 1, "ASCII-folded Turkish is NOT silently equal")
    }
    @Test func p50IsTheMedian() {
        #expect(SpeechMetrics.p50([]) == nil && SpeechMetrics.p50([3]) == 3 && SpeechMetrics.p50([5, 1, 3]) == 3 && SpeechMetrics.p50([4, 1, 2, 3]) == 2.5)
    }
}

@MainActor
@Suite("Voice: conversation records where input came from")
struct VoiceMessageSourceTests {
    @Test func typedMessagesCarryNoSourceVoiceMessagesAreMarked() {
        let c = ConversationStore()
        let a = c.appendUser("hello"), b = c.appendUser("merhaba", source: .voice)
        #expect(a.source == nil && b.source == .voice)
    }
    @Test func theSourceSurvivesCodingAndOldRecordsStillDecode() throws {
        let m = ConversationMessage(role: .user, content: "x", source: .voice)
        let back = try JSONDecoder().decode(ConversationMessage.self, from: JSONEncoder().encode(m))
        #expect(back.source == .voice)
        let legacy = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"user","content":"old","timestamp":0,"status":"complete","tone":"normal"}"#
        #expect(try JSONDecoder().decode(ConversationMessage.self, from: Data(legacy.utf8)).source == nil)
    }
}

@MainActor
@Suite("Voice: fixture audio input behaves like a microphone")
struct FixtureAudioInputTests {
    @Test func deliversTheClipThenSilenceUntilStoppedAndNeverAfter() async {
        let input = FixtureAudioInput(clip: [Float](repeating: 0.5, count: 3200), speed: 20)
        final class Box: @unchecked Sendable { var frames: [AudioFrame] = []; let lock = NSLock(); func add(_ f: AudioFrame) { lock.lock(); frames.append(f); lock.unlock() } }
        let box = Box()
        try? input.start(onFrame: { box.add($0) }, onInterruption: { _ in })
        await input.waitUntilDelivered()
        try? await Task.sleep(for: .milliseconds(50))
        input.stop()
        let count = box.frames.count
        try? await Task.sleep(for: .milliseconds(100))
        #expect(box.frames.count == count && !input.isCapturing, "no frame after stop")
        #expect(box.frames.first?.samples.allSatisfy { $0 == 0.5 } == true && box.frames.dropFirst(2).first?.samples.allSatisfy { $0 == 0 } == true)
        #expect(box.frames.allSatisfy { $0.samples.count == 1600 })
    }
    @Test func resamplingKeepsTheDurationRoughlyAndTheSignalAlive() {
        let tone = (0..<22050).map { Float(sin(Double($0) / 22050 * 2 * .pi * 440)) * 0.5 }
        let out = AudioFixtures.resample(tone, from: 22050)
        #expect(abs(Double(out.count) / 16000 - 1.0) < 0.02 && (out.map { abs($0) }.max() ?? 0) > 0.3)
    }
}

@Suite("Voice: language preference defaults")
struct VoicePreferenceTests {
    @MainActor
    @Test func voiceIsOffByDefaultAndSettingsRoundTrip() {
        let defaults = UserDefaults(suiteName: "jarvis-voice-\(UUID().uuidString)")!
        let p = Preferences(defaults: defaults)
        #expect(!p.voiceEnabled && p.voicePushToTalk && p.voiceSpeakResponses && p.voiceLanguage == .auto && p.voiceSTTProvider == "auto" && p.voiceTTSProvider == "auto")
        #expect(!p.voiceSettings.enabled, "the microphone feature is opt-in")
        p.voiceEnabled = true; p.voiceLanguage = .turkish; p.voiceSpeechRate = 1.2
        let again = Preferences(defaults: defaults)
        #expect(again.voiceEnabled && again.voiceLanguage == .turkish && again.voiceSpeechRate == 1.2)
        #expect(again.voiceSettings.language == .turkish && again.voiceSettings.output.rate == 1.2)
    }
    @Test func autoResolvesToTheSystemLanguageOnlyWhenNotDetecting() {
        #expect([VoiceLanguage.turkish, .english].contains(VoiceLanguage.systemDefault))
        #expect(VoiceLanguage.turkish.tag == "tr-TR" && VoiceLanguage.english.tag == "en-US" && VoiceLanguage.auto.tag == nil)
    }
}
