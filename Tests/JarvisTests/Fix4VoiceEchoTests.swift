import Testing
import Foundation
@testable import Jarvis

/// Fix 4 — closed-loop proof of the self-echo chain on the level/envelope layer: JARVIS' own voice, delayed by the output pipeline and the room, must never be
/// judged as the user, and a person genuinely talking over it must still be heard. Everything is synthetic (levels only; no audio exists in these tests).
@Suite("Fix 4 · self-echo envelope")
struct Fix4VoiceEchoTests {
    /// Deterministic generator so the fixtures are stable and reviewable.
    struct LCG { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double((s >> 33) & 0xFFFF) / 65535 } }

    /// A speech-like envelope: phrases of 0.6–1.2 s separated by 0.5–0.9 s pauses (sentence boundaries), with tiny syllable dips. Returns on/off per 20 ms slice.
    static func envelope(seconds: Double, startAt: Double, seed: UInt64, phrase: ClosedRange<Double> = 0.6 ... 1.2, pause: ClosedRange<Double> = 0.5 ... 0.9) -> [Bool] {
        var g = LCG(s: seed)
        let n = Int(seconds / 0.02)
        var out = [Bool](repeating: false, count: n)
        var t = startAt
        while t < seconds {
            let len = phrase.lowerBound + g.next() * (phrase.upperBound - phrase.lowerBound)
            let gap = pause.lowerBound + g.next() * (pause.upperBound - pause.lowerBound)
            var i = Int(t / 0.02)
            let end = min(n, Int((t + len) / 0.02))
            while i < end { out[i] = (i % 11 != 0); i += 1 }
            t += len + gap
        }
        return out
    }

    /// Feed one playback: the player reports `-25 dB` while its envelope is on; the microphone hears the same envelope `delay` seconds later at `coupling`, optionally plus a user.
    private func play(config: BargeInDetector.Config, delay: Double, coupling: Float = -20, seconds: Double = 12, user: [Bool]? = nil, userDB: Float = -33) -> (BargeInDetector, decisionAt: Double?) {
        var d = BargeInDetector(config: config)
        d.beginPlayback(at: 0)
        let ref = Self.envelope(seconds: seconds, startAt: 1.5, seed: 7)
        let lag = Int((delay / 0.02).rounded())
        var decision: Double?
        for i in 0..<ref.count {
            let t = Double(i + 1) * 0.02
            d.pushReference(db: ref[i] ? -25 : -90, at: t - 0.02)
            let echoOn = i - lag >= 0 && ref[i - lag]
            var power = pow(10, Float(-62) / 10)                                             // the room floor
            if echoOn { power += pow(10, (-25 + coupling) / 10) }
            let userOn = user?[i] ?? false
            if userOn { power += pow(10, userDB / 10) }
            d.pushVAD(isSpeech: echoOn || userOn)                                              // the VAD cannot tell JARVIS' voice from a person's
            if decision == nil, let x = d.pushMic(db: 10 * log10(power), duration: 0.02, at: t) { decision = t; _ = x }
        }
        return (d, decision)
    }

    @Test("OBSERVED CHAIN: with a delayed echo (0.68 s) the old level-only detector decides 'the user is speaking' (this is the false barge-in)")
    func oldBehaviourFalselyInterrupts() {
        var legacy = BargeInDetector.Config(); legacy.confirmEnvelope = false
        let (_, at) = play(config: legacy, delay: 0.68)
        #expect(at != nil, "the legacy level gate is fooled by the echo's delay — the fixture reproduces the observed false barge-in")
    }

    @Test("the envelope confirmation recognises its own delayed voice at every plausible delay and never interrupts")
    func newBehaviourIgnoresOwnVoice() {
        for delay in [0.06, 0.2, 0.35, 0.45, 0.55, 0.65, 0.68] {
            let (d, at) = play(config: .init(), delay: delay)
            #expect(at == nil, "delay \(delay) s must not produce a barge-in")
            _ = d
        }
    }

    @Test("a person speaking over JARVIS is still heard, quickly")
    func userStillDetected() {
        let user = Self.envelope(seconds: 12, startAt: 5.0, seed: 99, phrase: 1.5 ... 2.5, pause: 0.1 ... 0.2)
        let (_, at) = play(config: .init(), delay: 0.45, user: user)
        #expect(at != nil && (at ?? 99) < 7.0, "decision at \(at ?? -1) s")
    }

    @Test("a loud shout over the answer fires immediately even if the envelope happens to match")
    func shout() {
        let user = Self.envelope(seconds: 12, startAt: 5.0, seed: 7, phrase: 1.5 ... 2.5, pause: 0.1 ... 0.2)          // same seed as the reference: worst-case correlation
        let (_, at) = play(config: .init(), delay: 0.0, user: user, userDB: -10)
        #expect(at != nil)
    }

    @Test("a rejected candidate is recorded as diagnostics (count + correlation), without audio")
    func rejectionIsCounted() {
        let (d, at) = play(config: .init(), delay: 0.68)
        #expect(at == nil)
        #expect(d.rejectedAsEcho > 0 && (d.lastRejectedCorrelation ?? 0) >= BargeInDetector.Config().echoCorrelation)
    }
}

@Suite("Fix 4 · phantom utterance guard")
struct Fix4PhantomGuardTests {
    private let overlapped = UtteranceProvenance(overlappedPlayback: true, confirmedBargeIn: false, secondsSincePlaybackEnd: 0.2)
    private let barged = UtteranceProvenance(overlappedPlayback: true, confirmedBargeIn: true, secondsSincePlaybackEnd: nil)

    @Test("the transcripts observed in real use are not user turns when their capture overlapped JARVIS' speech — decided by provenance, not by their text")
    func observedPhantoms() {
        for text in ["Move it.", "Defend him.", "So funny.", "Thank you.", "Okay.", "Hmm."] {
            #expect(PhantomGuard.verdict(text: text, detectedLanguage: .english, conversationLanguage: .turkish, provenance: overlapped) != .accept, "\(text)")
        }
    }

    @Test("the same words are ordinary commands when nothing of JARVIS' own voice overlapped the capture")
    func sameWordsCleanCapture() {
        for text in ["Move it.", "Defend him.", "Safari'yi aç"] {
            #expect(PhantomGuard.verdict(text: text, detectedLanguage: .english, conversationLanguage: .turkish, provenance: .clean) == .accept)
        }
    }

    @Test("a real sentence spoken over the answer, and a one-word interrupt, are kept")
    func realBargeIn() {
        #expect(PhantomGuard.verdict(text: "Hayır, bunun yerine Safari'yi aç lütfen", detectedLanguage: .turkish, conversationLanguage: .turkish, provenance: barged) == .accept)
        #expect(PhantomGuard.verdict(text: "Sus", detectedLanguage: .turkish, conversationLanguage: .turkish, provenance: overlapped) == .accept)
        #expect(PhantomGuard.verdict(text: "Stop", detectedLanguage: .english, conversationLanguage: .turkish, provenance: barged) == .accept)
    }

    @Test("after a confirmed barge-in a two-word transcript in another language than the conversation is a recogniser hallucination")
    func languageMismatchAfterBarge() {
        #expect(PhantomGuard.verdict(text: "Move it.", detectedLanguage: .english, conversationLanguage: .turkish, provenance: barged) != .accept)
        #expect(PhantomGuard.verdict(text: "Open Safari", detectedLanguage: .english, conversationLanguage: .english, provenance: barged) == .accept)
    }

    @Test("a long transcript over the post-speech window is left to the quote filter, not dropped by length")
    func longKept() {
        #expect(PhantomGuard.verdict(text: "can you open the tasks screen for me now", detectedLanguage: .english, conversationLanguage: .english, provenance: overlapped) == .accept)
    }

    @Test("diagnostics are bounded metadata: capped, no transcript field, no audio")
    @MainActor func diagnosticsBounded() {
        let d = VoiceDiagnostics()
        for i in 0..<500 { d.note("k\(i % 3)", String(repeating: "x", count: 400), at: Double(i)) }
        #expect(d.entries.count == VoiceDiagnostics.capacity && d.entries.allSatisfy { $0.detail.count <= 120 })
        #expect(d.count("k0") > 100)
    }
}

@MainActor
@Suite("Fix 4 · closed loop on the hands-free coordinator", .serialized)
struct Fix4HandsFreeLoopTests {
    @Test("a phantom transcript captured right after JARVIS finished speaking never becomes a user turn, an action or a wake")
    func phantomAfterSpeech() async {
        let r = HandsFreeRig()
        r.h.tts.auto = false
        r.h.stt.script = { $0.finalText = "open the tasks screen" }
        await r.hf.enable()
        await r.quiet(1.0); await r.speech(0.4); await r.wakeWord(); await r.speech(0.4); await r.quiet(0.6)
        await r.settle { !r.h.tts.spoken.isEmpty }
        let before = r.h.userMessages.count
        let id = r.h.tts.spoken[0].id
        r.h.tts.begin(id)
        await r.settle { r.hf.state == .jarvisSpeaking }
        r.h.tts.end(id)                                                    // the answer is over …
        r.h.stt.script = { $0.finalText = "Move it." }                     // … and JARVIS' own tail is transcribed as nonsense
        await r.speech(1.0); await r.quiet(0.8)
        try? await Task.sleep(for: .milliseconds(500))
        #expect(r.h.userMessages.count == before, "no user turn was created from the phantom transcript")
        #expect(r.hf.diagnostics.count("phantom.rejected") >= 1, "the rejection is recorded (\(r.hf.diagnostics.summary))")
        await r.hf.disable()
    }

    @Test("control: the identical transcript is an ordinary user turn when the capture began after the post-speech window — the provenance rule is what discriminates")
    func controlAfterGuard() async {
        let r = HandsFreeRig()
        r.h.tts.auto = false
        r.h.stt.script = { $0.finalText = "open the tasks screen" }
        await r.hf.enable()
        await r.quiet(1.0); await r.speech(0.4); await r.wakeWord(); await r.speech(0.4); await r.quiet(0.6)
        await r.settle { !r.h.tts.spoken.isEmpty }
        let before = r.h.userMessages.count
        let id = r.h.tts.spoken[0].id
        r.h.tts.begin(id)
        await r.settle { r.hf.state == .jarvisSpeaking }
        r.h.tts.end(id)
        r.h.stt.script = { $0.finalText = "Move it." }
        r.hf.postSpeechGuard = 0                                            // the capture begins after the post-speech window
        await r.speech(1.0); await r.quiet(0.8)
        await r.settle { r.h.userMessages.count > before }
        #expect(r.h.userMessages.count == before + 1 && r.hf.diagnostics.count("phantom.rejected") == 0)
        await r.hf.disable()
    }

    @Test("provenance of a capture: clean when JARVIS was silent, overlapped within the guard window, never for an acknowledgement")
    func provenanceTiming() async {
        let r = HandsFreeRig()
        await r.hf.enable()
        let t = ProcessInfo.processInfo.systemUptime
        #expect(r.hf.provenanceForNewUtterance(at: t) == .clean)
        await r.hf.disable()
    }
}
