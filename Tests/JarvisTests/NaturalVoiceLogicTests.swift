import Foundation
import Testing
@testable import Jarvis

// MARK: - Endpointing

@Suite("Endpoint policy")
struct EndpointPolicyTests {
    let p = EndpointPolicy()

    @Test func hintFromPartialTranscript() {
        #expect(EndpointPolicy.hint(for: nil) == .unknown)
        #expect(EndpointPolicy.hint(for: "") == .unknown)
        #expect(EndpointPolicy.hint(for: "Open the Tasks screen.") == .complete)
        #expect(EndpointPolicy.hint(for: "Görevler ekranını aç?") == .complete)
        #expect(EndpointPolicy.hint(for: "Jarvis, görevler ekranını aç.") == .complete)
        #expect(EndpointPolicy.hint(for: "Stop.") == .complete && EndpointPolicy.hint(for: "Dur.") == .complete, "one-word commands")
        #expect(EndpointPolicy.hint(for: "Jarvis, Unity'deki") == .incomplete, "«-deki» needs a noun")
        #expect(EndpointPolicy.hint(for: "Jarvis, Unity'deki.") == .incomplete, "a recogniser's full stop after a hesitation is not trusted")
        #expect(EndpointPolicy.hint(for: "Jarvis, check.") == .unknown, "a full stop after almost nothing proves nothing")
        #expect(EndpointPolicy.hint(for: "Open it.") == .unknown)
        #expect(EndpointPolicy.hint(for: "Jarvis, Unity testleri nasıl") == .unknown)
        #expect(EndpointPolicy.hint(for: "Jarvis, Unity'deki,") == .incomplete)
        #expect(EndpointPolicy.hint(for: "Jarvis, check the") == .incomplete)
        #expect(EndpointPolicy.hint(for: "Unity testlerini kontrol et ve") == .incomplete)
        #expect(EndpointPolicy.hint(for: "bir şey…") == .incomplete)
        #expect(EndpointPolicy.hint(for: "he said \"stop.\"") == .complete)
    }

    @Test func aShortSilenceDoesNotEndTheTurn() {
        // "Jarvis, Unity'deki … son testlere bak": a 0.55 s hesitation after an unfinished phrase must wait.
        #expect(p.verdict(speech: 2.4, silence: 0.55, hint: .unknown) == .wait)
        #expect(p.verdict(speech: 2.4, silence: 0.9, hint: .unknown) == .wait)
        #expect(p.verdict(speech: 2.4, silence: 0.9, hint: .incomplete) == .wait)
        #expect(p.verdict(speech: 2.4, silence: 1.0, hint: .unknown) == .endTurn)
    }

    @Test func aFinishedSentenceEndsSooner() {
        #expect(p.verdict(speech: 3.0, silence: 0.5, hint: .complete) == .wait)
        #expect(p.verdict(speech: 3.0, silence: 0.65, hint: .complete) == .endTurn)
        #expect(p.verdict(speech: 1.2, silence: 0.5, hint: .complete) == .endTurn, "a short complete command ends fastest")
    }

    @Test func noHintEverWaitsBeyondTheHardCap() {
        for hint in [EndpointPolicy.Hint.complete, .unknown, .incomplete] {
            #expect(p.requiredSilence(speech: 5, hint: hint) <= p.hardCapSilence)
            #expect(p.verdict(speech: 5, silence: p.hardCapSilence, hint: hint) == .endTurn)
        }
    }

    @Test func tooLittleSpeechIsNotATurn() {
        #expect(p.verdict(speech: 0.12, silence: 0.3, hint: .unknown) == .wait)
        #expect(p.verdict(speech: 0.12, silence: 1.1, hint: .unknown) == .tooShort)
    }
}

// MARK: - Turn machine

/// Drives a `TurnMachine` the way the coordinator does: remembers the newest token of every armed timer so tests can "fire" it.
private struct Driver {
    var m = TurnMachine()
    var armed: [TurnTimer: (token: Int, after: TimeInterval)] = [:]
    var last: [TurnEffect] = []

    init(wake: Bool = true, config: TurnConfig = TurnConfig()) {
        m = TurnMachine(config: config)
        _ = send(.wakeModeChanged(enabled: wake, available: wake), at: 0)
    }
    @discardableResult mutating func send(_ e: TurnEvent, at t: TimeInterval) -> [TurnEffect] {
        let fx = m.handle(e, at: t)
        for f in fx {
            if case .arm(let k, let after, let token) = f { armed[k] = (token, after) }
            if case .cancel(let k) = f { armed[k] = nil }
        }
        last = fx
        return fx
    }
    /// Fires the currently armed timer of that kind (as the effect runner would), at time `t`.
    @discardableResult mutating func fire(_ k: TurnTimer, at t: TimeInterval) -> [TurnEffect] {
        guard let a = armed[k] else { return [] }
        armed[k] = nil
        return send(.timer(k, token: a.token), at: t)
    }
    var state: HandsFreeState { m.state }
}

@Suite("Turn machine")
struct TurnMachineTests {
    /// wake → user speaks `speech` seconds → endpoint → submitted. Returns the time after submission.
    private func oneTurn(_ d: inout Driver, from t: Double, partial: String = "What is the status?") -> Double {
        d.send(.speechStarted, at: t + 1)
        d.send(.partial(partial), at: t + 1.5)
        d.send(.speechEnded, at: t + 2)
        d.fire(.endpoint, at: t + 2.8)
        d.send(.transcriptReady(wakeOnly: false), at: t + 3)
        d.send(.submitted, at: t + 3)
        return t + 3
    }

    @Test func startsDormantAndWakeModeIsOptIn() {
        var m = TurnMachine()
        #expect(m.state == .dormant)
        _ = m.handle(.wakeDetected(speechActive: false, speechAgo: 0), at: 1)
        #expect(m.state == .dormant, "a wake event does nothing while wake mode is off")
        _ = m.handle(.wakeModeChanged(enabled: true, available: false), at: 2)
        #expect(m.state == .dormant, "enabled but unavailable stays off")
        _ = m.handle(.wakeModeChanged(enabled: true, available: true), at: 3)
        #expect(m.state == .wakeListening)
        _ = m.handle(.wakeModeChanged(enabled: false, available: true), at: 4)
        #expect(m.state == .dormant)
    }

    @Test func wakeOpensABoundedAttentiveWindowThenReturns() {
        var d = Driver()
        let fx = d.send(.wakeDetected(speechActive: false, speechAgo: 0), at: 10)
        #expect(d.state == .attentive)
        #expect(fx.contains(.acknowledgeWake))
        #expect(d.armed[.attentive]?.after == d.m.config.attentiveSeconds)
        let end = d.fire(.attentive, at: 17)
        #expect(d.state == .wakeListening, "nobody spoke: back to wake-only listening")
        #expect(end.contains(.note("Returned to wake mode")))
    }

    @Test func staleTimersAreIgnored() {
        var d = Driver()
        d.send(.wakeDetected(speechActive: false, speechAgo: 0), at: 0)
        let old = d.armed[.attentive]!.token
        d.send(.speechStarted, at: 1)
        #expect(d.state == .userSpeaking)
        d.send(.timer(.attentive, token: old), at: 7)
        #expect(d.state == .userSpeaking, "the attentive timer was cancelled by speech")
    }

    @Test func fullHandsFreeTurnWithFollowUp() {
        var d = Driver()
        d.send(.wakeDetected(speechActive: false, speechAgo: 0), at: 0)
        var fx = d.send(.speechStarted, at: 1.0)
        #expect(d.state == .userSpeaking)
        #expect(fx.contains(.startUtterance(preroll: 0.35)))
        fx = d.send(.partial("Unity testleri geçti mi?"), at: 2)
        #expect(fx.isEmpty)
        d.send(.speechEnded, at: 3.0)
        #expect(d.state == .endpointing)
        #expect(d.armed[.endpoint]!.after == d.m.config.endpoint.completeSilence)
        fx = d.fire(.endpoint, at: 3.7)
        #expect(d.state == .transcribing)
        #expect(fx.contains(.endUtterance))
        d.send(.transcriptReady(wakeOnly: false), at: 3.9)
        d.send(.submitted, at: 3.9)
        #expect(d.state == .thinking)
        d.send(.speechPlaybackStarted, at: 4.3)
        #expect(d.state == .jarvisSpeaking)
        d.send(.speechPlaybackEnded, at: 7)
        #expect(d.state == .attentive, "a follow-up window opens — no wake word needed")
        #expect(d.armed[.attentive]?.after == d.m.config.followUpSeconds)
        d.send(.speechStarted, at: 7.1)
        #expect(d.state == .attentive, "the room is still ringing: ignored")
        d.send(.speechStarted, at: 8)
        #expect(d.state == .userSpeaking)
    }

    @Test func aMidSentencePauseKeepsOneTurn() {
        var d = Driver()
        d.send(.wakeDetected(speechActive: false, speechAgo: 0), at: 0)
        d.send(.speechStarted, at: 1)
        d.send(.partial("Jarvis, Unity'deki"), at: 2)
        d.send(.speechEnded, at: 2.4)
        let first = d.armed[.endpoint]!
        #expect(first.after >= 1.0, "an unfinished phrase waits at least a second")
        let fx = d.send(.speechStarted, at: 3.3)                       // the user resumes after 0.9 s
        #expect(d.state == .userSpeaking && fx.contains(.cancel(.endpoint)))
        let stale = d.send(.timer(.endpoint, token: first.token), at: 3.4)
        #expect(stale.isEmpty && d.state == .userSpeaking, "the old endpoint timer is stale")
        let end = d.send(.speechEnded, at: 5)
        #expect(d.state == .endpointing && !end.contains(.discardUtterance))
    }

    @Test func aGrowingPartialShortensTheWait() {
        var d = Driver()
        d.send(.wakeDetected(speechActive: false, speechAgo: 0), at: 0)
        d.send(.speechStarted, at: 1)
        d.send(.partial("check the tests"), at: 2)
        d.send(.speechEnded, at: 3)            // unknown → 1.0 s
        let fx = d.send(.partial("check the tests."), at: 3.2)
        guard case .arm(.endpoint, let remaining, _)? = fx.first else { Issue.record("no re-arm"); return }
        #expect(remaining > 0.3 && remaining < 0.6, "complete hint: 0.65 s total, 0.2 s already elapsed")
    }

    @Test func wakeWordFollowedByContinuousSpeechStartsTheUtteranceWithPreRoll() {
        var d = Driver()
        var fx = d.send(.speechStarted, at: 4.2)                          // the user is speaking: «Jarvis, open …»
        fx = d.send(.wakeDetected(speechActive: true, speechAgo: 0.8), at: 5)
        #expect(d.state == .attentive && d.armed[.continuation] != nil, "the recogniser is NOT opened yet: a lone «Jarvis» must not start speech recognition")
        #expect(!fx.contains(.acknowledgeWake), "the user is probably still talking: no beep over them")
        fx = d.fire(.continuation, at: 5.45)                               // the VAD still hears speech 0.45 s later → same breath
        #expect(d.state == .userSpeaking)
        #expect(fx.contains(.startUtterance(preroll: 0.8 + 0.45 + 0.3)), "the word itself is part of the utterance")
    }

    @Test func aLoneWakeWordNeverOpensTheRecogniserAndIsAcknowledged() {
        var d = Driver()
        d.send(.speechStarted, at: 4.2)
        d.send(.wakeDetected(speechActive: true, speechAgo: 0.6), at: 4.8)
        let fx = d.send(.speechEnded, at: 4.9)                             // the VAD closes the word before the continuation window ends
        #expect(fx.contains(.acknowledgeWake) && fx.contains(.cancel(.continuation)) && d.state == .attentive)
        #expect(d.fire(.continuation, at: 5.3).isEmpty, "the continuation timer was cancelled")
        d.send(.speechStarted, at: 6.0)                                    // the command, after the pause
        #expect(d.state == .userSpeaking)
    }

    @Test func speechThatResumesInsideTheAcknowledgementWindowIsNotLost() {
        var d = Driver()
        d.send(.speechStarted, at: 4.2)
        d.send(.wakeDetected(speechActive: true, speechAgo: 0.6), at: 4.8)
        d.send(.speechEnded, at: 4.9)                                      // «Jarvis,» — a comma pause; the cue is acknowledged, deaf for 0.5 s
        var fx = d.send(.speechStarted, at: 5.1)                           // «open the Tasks screen» resumes inside the deaf window and the VAD reports no further edge
        #expect(d.state == .attentive && d.armed[.deaf] != nil, "not an utterance yet (the cue could still be audible) but it is looked at again")
        fx = d.fire(.deaf, at: 5.4)
        #expect(d.state == .userSpeaking && fx.contains(where: { if case .startUtterance = $0 { return true } else { return false } }))
    }

    @Test func speechThatStoppedInsideTheDeafWindowDoesNotOpenTheRecogniser() {
        var d = Driver()
        d.send(.speechStarted, at: 4.2)
        d.send(.wakeDetected(speechActive: true, speechAgo: 0.6), at: 4.8)
        d.send(.speechEnded, at: 4.9)
        d.send(.speechStarted, at: 5.0)                                    // a blip right after the cue …
        d.send(.speechEnded, at: 5.1)                                      // … that is over before the window ends
        d.fire(.deaf, at: 5.4)
        #expect(d.state == .attentive, "nothing was said: the follow-up window simply continues")
    }

    @Test func aWakeWordNoOneIsSpeakingOverAcknowledgesAtOnce() {
        var d = Driver()
        let fx = d.send(.wakeDetected(speechActive: false, speechAgo: 0), at: 3)
        #expect(fx.contains(.acknowledgeWake) && d.armed[.continuation] == nil)
    }

    @Test func aWakeOnlyTranscriptStaysAttentive() {
        var d = Driver()
        d.send(.wakeDetected(speechActive: false, speechAgo: 0), at: 0)
        d.send(.speechStarted, at: 1)
        d.send(.partial("Jarvis."), at: 1.5)
        d.send(.speechEnded, at: 1.8)
        d.fire(.endpoint, at: 2.3)
        #expect(d.state == .transcribing)
        d.send(.transcriptReady(wakeOnly: true), at: 2.5)
        #expect(d.state == .attentive, "the lone wake word is not a message")
        #expect(d.armed[.attentive] != nil)
    }

    @Test func noSelfWakeWhileJarvisSpeaksOrThinks() {
        var d = Driver()
        d.send(.wakeDetected(speechActive: false, speechAgo: 0), at: 0)
        _ = oneTurn(&d, from: 0)
        #expect(d.state == .thinking)
        var e = d.send(.wakeDetected(speechActive: false, speechAgo: 0), at: 6)
        #expect(e.isEmpty && d.state == .thinking, "JARVIS saying its own name must not wake it")
        d.send(.speechPlaybackStarted, at: 6.5)
        e = d.send(.wakeDetected(speechActive: false, speechAgo: 0), at: 7)
        #expect(e.isEmpty && d.state == .jarvisSpeaking)
    }

    @Test func bargeInStopsSpeechAndStartsAnUtteranceWithPreRoll() {
        var d = Driver()
        d.send(.wakeDetected(speechActive: false, speechAgo: 0), at: 0)
        _ = oneTurn(&d, from: 0)
        d.send(.speechPlaybackStarted, at: 4)
        let fx = d.send(.bargeIn(onsetAgo: 0.4), at: 6)
        #expect(d.state == .interrupting)
        #expect(fx.contains(.stopSpeaking))
        #expect(fx.contains(.startUtterance(preroll: 0.65)))
        #expect(d.m.lastBargeIn)
        d.send(.speechStopped, at: 6.01)
        #expect(d.state == .userSpeaking)
        d.send(.speechEnded, at: 7.5)
        #expect(d.state == .endpointing && d.armed[.endpoint] != nil)
    }

    @Test func bargeInOutsideSpeechIsIgnored() {
        var d = Driver()
        #expect(d.send(.bargeIn(onsetAgo: 0.3), at: 1).isEmpty)
        #expect(d.state == .wakeListening)
    }

    @Test func aCoughIsNotATurn() {
        var d = Driver()
        d.send(.wakeDetected(speechActive: false, speechAgo: 0), at: 0)
        d.send(.speechStarted, at: 1)
        d.send(.speechEnded, at: 1.1)                       // 0.1 s of "speech"
        let fx = d.fire(.endpoint, at: 2.2)
        #expect(fx.contains(.discardUtterance))
        #expect(d.state == .attentive, "back to waiting, nothing was transcribed")
    }

    @Test func pushToTalkTakesOwnershipSafely() {
        var d = Driver()
        d.send(.wakeDetected(speechActive: false, speechAgo: 0), at: 0)
        var fx = d.send(.pushToTalkBegan, at: 1)
        #expect(d.state == .userSpeaking && d.m.owner == .pushToTalk)
        #expect(fx.contains(.cancel(.attentive)))
        d.send(.pushToTalkEnded, at: 2)
        #expect(d.state == .transcribing)
        fx = d.send(.pushToTalkBegan, at: 2.1)
        #expect(fx.isEmpty && d.state == .transcribing, "a press while the previous turn is being finalised is ignored")

        var n = Driver()
        n.send(.wakeDetected(speechActive: false, speechAgo: 0), at: 0)
        _ = oneTurn(&n, from: 0)
        n.send(.speechPlaybackStarted, at: 4)
        fx = n.send(.pushToTalkBegan, at: 5)
        #expect(fx.contains(.stopSpeaking), "speech stops first (explicit stop)")
        #expect(n.m.owner == .pushToTalk && n.state == .userSpeaking)

        var o = Driver()
        o.send(.wakeDetected(speechActive: false, speechAgo: 0), at: 0)
        o.send(.speechStarted, at: 1)
        fx = o.send(.pushToTalkBegan, at: 1.5)
        #expect(fx.contains(.discardUtterance), "the hands-free capture is dropped, push-to-talk owns the microphone")
    }

    @Test func transcribingNeverSticksForever() {
        var d = Driver()
        d.send(.pushToTalkBegan, at: 1)
        d.send(.pushToTalkEnded, at: 2)
        #expect(d.state == .transcribing && d.armed[.watchdog]?.after == d.m.config.transcribingWatchdog)
        let fx = d.fire(.watchdog, at: 62)
        #expect(d.state == .wakeListening && fx.contains(.discardUtterance))
        // an interrupted push-to-talk release (the key chord was disturbed) ends cleanly through «nothing heard»
        var e = Driver()
        e.send(.pushToTalkBegan, at: 1); e.send(.pushToTalkEnded, at: 1.5); e.send(.transcriptEmpty, at: 1.5)
        #expect(e.state == .wakeListening && e.armed[.watchdog] == nil)
    }

    @Test func pushToTalkWorksWithWakeDisabled() {
        var d = Driver(wake: false)
        d.send(.pushToTalkBegan, at: 1)
        #expect(d.state == .dormant)
        d.send(.pushToTalkEnded, at: 2)
        #expect(d.state == .dormant)
    }

    @Test func aPushToTalkAnswerDoesNotOpenAFollowUpWindow() {
        var d = Driver()
        d.send(.pushToTalkBegan, at: 1)
        d.send(.pushToTalkEnded, at: 2)
        d.send(.submitted, at: 2.2)
        d.send(.speechPlaybackStarted, at: 2.5)
        d.send(.speechPlaybackEnded, at: 4)
        #expect(d.state == .wakeListening, "explicit push-to-talk is explicit: no hidden listening afterwards")
    }

    @Test func followUpsAreBounded() {
        var cfg = TurnConfig(); cfg.maxConsecutiveTurns = 2
        var d = Driver(config: cfg)
        d.send(.wakeDetected(speechActive: false, speechAgo: 0), at: 0)
        var t = 0.0
        for _ in 0..<2 {
            t = oneTurn(&d, from: t)
            d.send(.speechPlaybackStarted, at: t + 0.5)
            d.send(.speechPlaybackEnded, at: t + 2)
            t += 4
        }
        #expect(d.state == .wakeListening, "after the allowed follow-ups the wake word is needed again")
    }

    @Test func unintelligibleAttemptsFallBackToWakeOnly() {
        var d = Driver()
        d.send(.wakeDetected(speechActive: false, speechAgo: 0), at: 0)
        var t = 1.0
        for _ in 0..<2 {
            d.send(.speechStarted, at: t); d.send(.speechEnded, at: t + 1.5)
            d.fire(.endpoint, at: t + 2.5)
            d.send(.transcriptEmpty, at: t + 2.7)
            t += 6
        }
        #expect(d.state == .wakeListening)
    }

    @Test func typedInputAfterThinkingStillEndsTheTurn() {
        var d = Driver()
        d.send(.wakeDetected(speechActive: false, speechAgo: 0), at: 0)
        _ = oneTurn(&d, from: 0)
        d.send(.turnEndedSilently, at: 5)
        #expect(d.state == .attentive, "an answer that needs no speech still opens the bounded follow-up window")
    }

    @Test func disablingWakeModeMidUtteranceDiscardsIt() {
        var d = Driver()
        d.send(.wakeDetected(speechActive: false, speechAgo: 0), at: 0)
        d.send(.speechStarted, at: 1)
        let fx = d.send(.wakeModeChanged(enabled: false, available: true), at: 2)
        #expect(fx.contains(.discardUtterance))
        #expect(d.state == .dormant)
    }

    @Test func shutdownAndFailureNeverLeaveActiveStates() {
        var d = Driver()
        d.send(.wakeDetected(speechActive: false, speechAgo: 0), at: 0)
        d.send(.speechStarted, at: 1)
        let fx = d.send(.shutdown, at: 2)
        #expect(d.state == .dormant)
        #expect(fx.contains(.discardUtterance) && fx.contains(.stopSpeaking))
        var f = Driver()
        f.send(.failure("device lost"), at: 3)
        #expect(f.state == .error("device lost"))
        f.send(.reset, at: 9)
        #expect(f.state == .wakeListening)
    }

    @Test func restartNeverRestoresActiveStates() {
        #expect(TurnMachine().state == .dormant, "a new machine (the app restarted) is dormant until wake mode is explicitly enabled")
    }
}

// MARK: - Barge-in / self-speech suppression

@Suite("Barge-in detector")
struct BargeInDetectorTests {

    @Test func speechBandFilterRemovesThudsAndKeepsVoices() {
        func level(_ hz: Float) -> Float {
            var f = SpeechBandFilter()
            let x = (0..<16000).map { 0.3 * sin(2 * .pi * hz * Float($0) / 16000) }
            let y = f.process(x)
            return AudioLevel.db(Array(y[8000...])) - AudioLevel.db(Array(x[8000...]))
        }
        #expect(level(90) < -15, "a 90 Hz door thud is attenuated by more than 15 dB")
        #expect(level(1000) > -1, "a voice-band tone passes")
        #expect(level(400) > -3)
    }
    /// Plays a reference of constant `refDB` for `seconds`, with the microphone hearing the echo at `refDB + couplingDB` and optionally a user at `userDB`.
    private func run(refDB: Float = -20, coupling: Float = -27, seconds: Double = 4, userFrom: Double? = nil, userDB: Float = -30, vadAlways: Bool = false,
                     config: BargeInDetector.Config = .init()) -> (BargeInDetector.Decision?, Double?) {
        var d = BargeInDetector(config: config)
        d.beginPlayback(at: 0)
        var t = 0.0
        let dt = 0.02
        while t < seconds {
            d.pushReference(db: refDB, at: t)
            t += dt
            var mic = refDB + coupling
            var vad = vadAlways
            if let u = userFrom, t >= u {
                mic = 10 * log10(pow(10, mic / 10) + pow(10, userDB / 10)); vad = true
            }
            d.pushVAD(isSpeech: vad)
            if let decision = d.pushMic(db: mic, duration: dt, at: t) { return (decision, t) }
        }
        return (nil, nil)
    }

    @Test func itsOwnVoiceNeverInterruptsItself() {
        // the VAD hears speech the whole time (it is JARVIS' own voice) — the level gate must still say no
        let (decision, _) = run(vadAlways: true)
        #expect(decision == nil)
    }

    @Test func louderEchoStillCalibratesAway() {
        // a speaker louder than the prior (coupling −14 dB instead of −24) is learned during the calibration window
        let (decision, _) = run(coupling: -14, vadAlways: true)
        #expect(decision == nil)
    }

    @Test func aUserSpeakingOverTheEchoIsDetectedQuickly() {
        let (decision, when) = run(userFrom: 2.0, userDB: -32)
        #expect(decision != nil)
        #expect((when ?? 99) >= 2.25 && (when ?? 99) < 2.6, "sustained for ≈ 0.3 s")
        #expect((decision?.onsetAgo ?? 0) >= 0.28)
    }

    @Test func aUserWhoInterruptsInTheFirstInstantsIsStillDetectedLater() {
        // the user speaks 20 dB above the echo from the very first moment: the calibration must not learn the user as "echo"
        let (decision, when) = run(userFrom: 0.1, userDB: -26)
        #expect(decision != nil && (when ?? 99) < 1.6, "detected just after the calibration window, not swallowed by it (decision at \(when ?? -1) s)")
    }

    @Test func aQuietUserBelowTheEchoIsNotDetectedAndThatIsDocumented() {
        let (decision, _) = run(userFrom: 2.0, userDB: -52)
        #expect(decision == nil)
    }

    @Test func aShortBlipDoesNotFire() {
        var d = BargeInDetector()
        d.beginPlayback(at: 0)
        var t = 0.0
        var fired = false
        while t < 4 {
            d.pushReference(db: -20, at: t); t += 0.02
            let blip = t > 2.0 && t < 2.12                               // a 120 ms keyboard clack / chair
            d.pushVAD(isSpeech: blip)
            let mic: Float = blip ? -25 : -47
            if d.pushMic(db: mic, duration: 0.02, at: t) != nil { fired = true }
        }
        #expect(!fired)
    }

    @Test func aTrainOfLoudClicksNeverFiresEvenIfTheVADCallsThemSpeech() {
        // 7 clicks per second, each loud enough to exceed the echo by 20 dB, with the VAD stuck on "speech": the duty cycle (≈ 33 %) says it is not a voice
        var d = BargeInDetector()
        d.beginPlayback(at: 0)
        var t = 0.0; var fired = false
        while t < 5 {
            d.pushReference(db: -20, at: t); t += 0.04
            d.pushVAD(isSpeech: true)
            let phase = Int(t / 0.04) % 4                                      // 1 hot frame in every 3.5 frames ≈ one click every 140 ms
            let mic: Float = (t > 1.5 && phase == 0) ? -28 : -47
            if d.pushMic(db: mic, duration: 0.04, at: t) != nil { fired = true }
        }
        #expect(!fired)
    }

    @Test func speechWithShortInternalDipsStillFires() {
        var d = BargeInDetector()
        d.beginPlayback(at: 0)
        var t = 0.0; var when: Double?
        while t < 4 && when == nil {
            d.pushReference(db: -20, at: t); t += 0.02
            d.pushVAD(isSpeech: t > 2.0)
            let dip = t > 2.0 && Int((t - 2.0) / 0.02) % 12 == 0                 // a 20 ms dip every 240 ms (a plosive, a breath)
            let mic: Float = t > 2.0 ? (dip ? -47 : -30) : -47
            if d.pushMic(db: mic, duration: 0.02, at: t) != nil { when = t }
        }
        #expect(when != nil && (when ?? 9) < 2.6)
    }

    @Test func louderNoiseWithoutSpeechDoesNotFire() {
        var d = BargeInDetector()
        d.beginPlayback(at: 0)
        var t = 0.0; var fired = false
        while t < 4 {
            d.pushReference(db: -20, at: t); t += 0.02
            d.pushVAD(isSpeech: false)
            if d.pushMic(db: t > 2 ? -30 : -47, duration: 0.02, at: t) != nil { fired = true }
        }
        #expect(!fired, "a fan or a door is not speech")
    }

    @Test func nothingFiresWhenNothingPlays() {
        var d = BargeInDetector()
        d.pushVAD(isSpeech: true)
        #expect(d.pushMic(db: -20, duration: 1, at: 1) == nil)
    }

    @Test func echoTailAfterTheReferenceStopsDoesNotFire() {
        var d = BargeInDetector()
        d.beginPlayback(at: 0)
        var t = 0.0; var fired = false
        while t < 3 {
            if t < 2 { d.pushReference(db: -20, at: t) } else { d.pushReference(db: -90, at: t) }
            t += 0.02
            d.pushVAD(isSpeech: true)
            // the room keeps ringing for 150 ms after the reference ends
            let mic: Float = t < 2 ? -47 : (t < 2.15 ? -50 : -65)
            if d.pushMic(db: mic, duration: 0.02, at: t) != nil { fired = true }
        }
        #expect(!fired)
    }

    @Test func audioLevelOfSilenceAndSignal() {
        #expect(AudioLevel.db([]) == -120)
        #expect(abs(AudioLevel.db([Float](repeating: 0.1, count: 100)) - (-20)) < 0.01)
    }
}

// MARK: - Transcript guards

@Suite("Wake phrase and self-speech guards")
struct TranscriptGuardTests {
    @Test func wakeOnlyTranscripts() {
        for t in ["Jarvis", "Jarvis.", "jarvis,", "Hey Jarvis", "Hey, Jarvis!", "Tamam Jarvis.", "Jarvis Jarvis", "Carvis"] {
            #expect(WakePhrase.isWakeOnly(t), "\(t)")
        }
        for t in ["Jarvis, open the Tasks screen", "Jarvis görevler ekranını aç", "stop", "Jarvis status"] {
            #expect(!WakePhrase.isWakeOnly(t), "\(t)")
        }
    }

    @Test func strippingKeepsTurkishLetters() {
        #expect(WakePhrase.strippingWake(from: "Jarvis, görevler ekranını aç.") == "görevler ekranını aç")
        #expect(WakePhrase.strippingWake(from: "Hey Jarvis, Ünity'deki şu testi çalıştır") == "Ünity'deki şu testi çalıştır")
        #expect(WakePhrase.strippingWake(from: "open it") == "open it")
    }

    @Test func aQuoteOfJarvisOwnSpeechIsAnEcho() {
        let spoken = ["The Unity tests are complete. No new Console errors were detected."]
        #expect(SelfSpeechFilter.isEcho(heard: "the unity tests are complete no new console errors", spoken: spoken))
        #expect(SelfSpeechFilter.isEcho(heard: "Unity tests are complete, no new errors", spoken: spoken))
        #expect(!SelfSpeechFilter.isEcho(heard: "Now check the multiplayer tests", spoken: spoken))
        #expect(!SelfSpeechFilter.isEcho(heard: "stop", spoken: spoken), "too short to judge")
        #expect(!SelfSpeechFilter.isEcho(heard: "Unity", spoken: []))
    }

    @Test func turkishEchoIsRecognisedDespiteDiacriticVariants() {
        let spoken = ["Unity testleri tamamlandı. Tüm EditMode ve PlayMode testleri geçti."]
        #expect(SelfSpeechFilter.isEcho(heard: "unity testleri tamamlandi tum edit mode ve play mode testleri gecti", spoken: spoken))
    }

    @Test func languageContinuityIgnoresEnglishTechnicalTerms() {
        var c = LanguageContinuity()
        #expect(c.resolve(detected: .turkish, text: "Unity'deki son testler ne durumda", fallback: .english) == .turkish)
        #expect(c.resolve(detected: .english, text: "Unity GameObject BoxCollider", fallback: .turkish) == .turkish, "technical words do not switch the language")
        #expect(c.resolve(detected: .english, text: "what is the status of the multiplayer tests", fallback: .turkish) == .english, "a clear English sentence does")
        #expect(c.resolve(detected: .english, text: "ok", fallback: .turkish) == .english)
        c.reset()
        #expect(c.current == nil)
    }
}

// MARK: - Voice identity

@Suite("JARVIS voice identity")
struct VoiceIdentityTests {
    @Test func identityIsProviderIndependent() {
        let id = JarvisVoiceIdentity.v1
        #expect(id.version == 1)
        #expect(id.pitchTargetHz.lowerBound >= 80 && id.pitchTargetHz.upperBound <= 140)
        #expect(id.phraseGap.upperBound < 0.5, "no dramatic pauses")
    }

    @Test func presetsMapToRealNeuralStylesOrFallBack() {
        let d = VoiceIdentityMapper.neural(preset: .jarvisDefault, rate: 1.0)
        #expect(d?.style == "M5" && d?.speed == 1.0)
        let c = VoiceIdentityMapper.neural(preset: .jarvisCalm, rate: 1.0)
        #expect(c?.style == "M3" && (c?.speed ?? 2) < 1.0)
        #expect(VoiceIdentityMapper.neural(preset: .systemFallback, rate: 1.0) == nil)
        #expect(VoiceIdentityMapper.neural(preset: .jarvisDefault, rate: 9)?.speed == 1.4, "the user's rate is clamped")
    }

    @Test func appleFallbackPrefersAnInstalledMaleEnglishVoice() {
        let voices = [VoiceDescriptor(id: "a", name: "Samantha", language: "en-US", quality: 1), VoiceDescriptor(id: "b", name: "Daniel", language: "en-GB", quality: 1),
                      VoiceDescriptor(id: "c", name: "Yelda", language: "tr-TR", quality: 1)]
        #expect(VoiceIdentityMapper.appleVoiceID(language: .english, among: voices) == "b")
        #expect(VoiceIdentityMapper.appleVoiceID(language: .turkish, among: voices) == nil, "no male Turkish Apple voice: the compromise is documented, not hidden")
        #expect(VoiceIdentityMapper.appleVoiceID(language: .english, among: [voices[0]]) == nil)
    }
}

@Suite("Self-speech similarity")
struct SelfSpeechSimilarityTests {
    @Test func aRealNewRequestIsNeverTreatedAsAnEchoOfALongAnswer() {
        let long = ["The Unity tests are complete. All EditMode and PlayMode tests passed and the Console shows no new errors. The multiplayer suite still needs a fixture, and I will keep an eye on the task while you review the report. Nothing needs your approval right now."]
        for request in ["Show me the latest task report", "Open the settings and turn off wake mode", "What about the multiplayer tests", "Please run the EditMode tests again"] {
            #expect(!SelfSpeechFilter.isEcho(heard: request, spoken: long), "\(request)")
        }
    }
    @Test func aBlurredQuoteIsStillAnEcho() {
        let spoken = ["The Unity tests are complete. No new Console errors were detected."]
        #expect(SelfSpeechFilter.isEcho(heard: "the unity test are complete no new console error were detected", spoken: spoken))
    }
}

@Suite("Wake context gate")
struct WakeContextGateTests {
    @Test func theWordMustStartTheUtterance() {
        // «Jarvis, open …»: the segment began a moment ago and is still going
        #expect(WakeContextGate.accepts(vadActive: true, startedAgo: 0.7, endedAgo: nil, maxSegment: 1.6))
        // the same word in the middle of a long sentence
        #expect(!WakeContextGate.accepts(vadActive: true, startedAgo: 6, endedAgo: nil, maxSegment: 1.6))
        // the word alone, VAD already closed it 0.2 s ago
        #expect(WakeContextGate.accepts(vadActive: false, startedAgo: 0.9, endedAgo: 0.2, maxSegment: 1.6))
        // the segment ended long ago, or never existed: not a spoken word
        #expect(!WakeContextGate.accepts(vadActive: false, startedAgo: 3, endedAgo: 2, maxSegment: 1.6))
        #expect(!WakeContextGate.accepts(vadActive: false, startedAgo: nil, endedAgo: nil, maxSegment: 1.6))
        // a long closed segment (a sentence that just ended) is not a wake word either
        #expect(!WakeContextGate.accepts(vadActive: false, startedAgo: 5, endedAgo: 0.1, maxSegment: 1.6))
    }
}

@MainActor
@Suite("Voice conversation presentation")
struct VoicePresentationTests {
    private func request(_ presentation: ResponsePresentation, session: String? = nil) -> IntelligenceRequest {
        IntelligenceRequest(id: UUID(), kind: .reasoning, prompt: "explain the multiplayer bug", history: [], language: .en, sessionID: session, presentation: presentation)
    }

    @Test func typedRequestsAreUnchangedAndVoiceRequestsAskForSpeakableAnswers() {
        #expect(request(.text).providerPrompt == "explain the multiplayer bug")
        let spoken = request(.voiceConversation).providerPrompt
        #expect(spoken.hasPrefix(VoicePresentation.preamble) && spoken.hasSuffix("explain the multiplayer bug"))
        #expect(VoicePresentation.preamble.lowercased().contains("read aloud") && VoicePresentation.preamble.lowercased().contains("no markdown"))
    }

    @Test func everyProviderSpecCarriesThePreambleOnlyForVoiceTurns() {
        let specs: [any CLIProviderSpec] = [ClaudeCodeSpec(), CodexSpec(), OpenCodeSpec(modelID: "opencode/test", flavor: .standalone)]
        for spec in specs {
            for session in [nil, "abc"] as [String?] {
                let typed = spec.stdinPrompt(for: request(.text, session: session)), spoken = spec.stdinPrompt(for: request(.voiceConversation, session: session))
                #expect(!typed.contains("Spoken conversation"), "\(spec.id) typed")
                #expect(spoken.contains("Spoken conversation") && spoken.contains("explain the multiplayer bug"), "\(spec.id) voice, session \(session ?? "new")")
            }
        }
    }

    @Test func aVoiceSubmissionAsksTheExistingProviderForASpeakableAnswerExactlyOnce() async {
        let provider = RecordingProvider()
        let h = VoiceHarness(providers: IntelligenceProviderRegistry(providers: [provider]))
        h.stt.script = { $0.finalText = "explain the multiplayer bug in detail" }
        await h.hold()
        await h.settle(timeout: 5) { provider.requests.count == 1 }
        #expect(provider.requests.count == 1, "one model call for the turn — the answer is never rewritten by a second call")
        #expect(provider.requests.first?.presentation == .voiceConversation)
        h.base.service.submit("explain the multiplayer bug in detail")
        await h.base.service.waitUntilIdle()
        #expect(provider.requests.last?.presentation == .text, "typed turns keep the normal presentation")
    }
}

final class RecordingProvider: IntelligenceProvider, @unchecked Sendable {
    let id = "recording", displayName = "Recording"
    private let lock = NSLock()
    private var _requests: [IntelligenceRequest] = []
    var requests: [IntelligenceRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    func supports(_ kind: IntelligenceRequestKind) -> Bool { true }
    func respond(to request: IntelligenceRequest) -> AsyncThrowingStream<IntelligenceEvent, Error> {
        lock.lock(); _requests.append(request); lock.unlock()
        return AsyncThrowingStream { c in c.yield(.textDelta("It is a race condition.")); c.yield(.finished); c.finish() }
    }
}

@Suite("Technical term normalisation")
struct TechnicalTermsTests {
    @Test func restoresCanonicalSpellingOfTheFixedTermList() {
        #expect(TechnicalTerms.normalize("Jarvis, run the edit mode tests in play mode") == "Jarvis, run the EditMode tests in Play Mode")
        #expect(TechnicalTerms.normalize("check the box collider on the game object") == "check the BoxCollider on the GameObject")
        #expect(TechnicalTerms.normalize("ask claude and codex about opencode") == "ask Claude and Codex about OpenCode")
        #expect(TechnicalTerms.normalize("let's do an open code review") == "let's do an open code review", "two common English words are never merged into a product name")
        #expect(TechnicalTerms.normalize("unity'deki son testler ve playmode") == "Unity'deki son testler ve PlayMode")
    }

    @Test func neverAddsRemovesOrGuessesWords() {
        for text in ["Jarvis Youte'deki son task'ın durumunu göster", "Jarvis Bucks color değişikliğini kontrol et", "Show me the latest task report", "Play more testlerini çalıştır",
                     "günaydın, bugün hava nasıl olacak?", "I need a mode to play with", "the code is open", "ÇIKIŞ yap"] {
            #expect(TechnicalTerms.normalize(text) == text, "unchanged: \(text)")
        }
    }

    @Test func isIdempotentAndKeepsPunctuationAndTurkishSuffixes() {
        let once = TechnicalTerms.normalize("Jarvis, unity'deki edit mode, play mode! testlerini çalıştır.")
        #expect(once == "Jarvis, Unity'deki EditMode, Play Mode! testlerini çalıştır.")
        #expect(TechnicalTerms.normalize(once) == once)
    }

    @Test func aPunctuationBreakBetweenTheWordsMeansTheyAreSeparateTerms() {
        #expect(TechnicalTerms.normalize("play, mode") == "play, mode")
        #expect(TechnicalTerms.normalize("edit. mode") == "edit. mode")
    }

    @Test func wordCountIsPreservedExceptForMergedCompounds() {
        let text = "please open the game object and the rigid body then run edit mode"
        let n = TechnicalTerms.normalize(text)
        #expect(n == "please open the GameObject and the Rigidbody then run EditMode")
        #expect(n.split(separator: " ").count == text.split(separator: " ").count - 3)
    }
}
