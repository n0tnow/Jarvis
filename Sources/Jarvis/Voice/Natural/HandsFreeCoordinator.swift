import Foundation
import Observation

/// Wake mode as the user sees it.
enum WakeStatus: Equatable, Sendable {
    case off
    case starting
    case listening
    case unavailable(String)
    /// “Uyku moduna geç”: the user paused the detector for now. The Wake Word SETTING is unchanged; Push-to-Talk still works.
    case paused

    var label: String {
        switch self { case .off: "OFF"; case .starting: "STARTING"; case .listening: "LISTENING FOR \"JARVIS\""; case .unavailable: "UNAVAILABLE"; case .paused: "PAUSED (SLEEP MODE)" }
    }
}

/// What the user should see, combining the PTT/session state and the hands-free turn state. Words and icons, never colour alone.
enum VoicePresence: Equatable, Sendable {
    case off, wake, attentive, listening, transcribing, thinking, speaking, interrupted, error(String)

    var label: String {
        switch self {
        case .off: "VOICE OFF"; case .wake: "WAKE"; case .attentive: "ATTENTIVE"; case .listening: "LISTENING"; case .transcribing: "TRANSCRIBING"
        case .thinking: "THINKING"; case .speaking: "SPEAKING"; case .interrupted: "INTERRUPTED"; case .error: "VOICE ERROR"
        }
    }

    static func resolve(session: VoiceSessionState, handsFree: HandsFreeState, wake: WakeStatus) -> VoicePresence {
        switch session {
        case .listening, .requestingPermission: return .listening
        case .transcribing: return .transcribing
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .error(let m): return .error(m)
        case .idle: break
        }
        switch handsFree {
        case .interrupting: return .interrupted
        case .attentive: return .attentive
        case .userSpeaking, .endpointing: return .listening
        case .transcribing: return .transcribing
        case .thinking: return .thinking
        case .jarvisSpeaking: return .speaking
        case .error(let m): return .error(m)
        case .wakeListening: return wake == .listening ? .wake : .off
        case .dormant: return .off
        }
    }
}

/// Latencies of the last natural turn, all measured intervals in seconds (nil = not reached). No audio, no text.
struct NaturalTurnMetrics: Equatable, Sendable {
    var wakeScore: Double?
    var wakeToAttentive: Double?          // wake event handled → acknowledgement issued
    var speechEndToEndpoint: Double?      // the user stopped → the turn manager closed the utterance
    var endpointToFinal: Double?          // utterance closed → final transcript
    var endpointToFirstAudio: Double?     // utterance closed → JARVIS audible
    var bargeInOnsetToDecision: Double?   // the user began speaking over JARVIS → barge-in decided
    var bargeInDecisionToSilence: Double? // decision → JARVIS silent
    var wasBargeIn = false
}

/// The turn manager's effects layer (V0.8): it wires the shared microphone, the local sentinel (wake word + VAD), the pure `TurnMachine`, the V0.7 voice session
/// and JARVIS' playback together — and nothing else. It coordinates input/output; it never routes, plans, approves, edits files or runs tasks: a hands-free
/// utterance ends in the very same `VoiceCoordinator` → `ConversationService.submit(source: .voice)` path as Push-to-Talk.
///
/// Privacy: wake mode is OFF unless the user turned it on. Before the wake word only the local sentinel hears the (bounded, in-memory) audio; no recogniser
/// runs, nothing is transcribed, stored or sent anywhere. Full speech recognition exists only between "the user started speaking" and "the turn ended".
@MainActor
@Observable
final class HandsFreeCoordinator {
    // Observable state
    private(set) var state: HandsFreeState = .dormant
    private(set) var wakeStatus: WakeStatus = .off
    private(set) var metrics = NaturalTurnMetrics()
    private(set) var wakeCount = 0
    private(set) var bargeInCount = 0
    /// Detector hits that were not utterance-initial (diagnostics only).
    private(set) var rejectedWakes = 0
    /// Why the last barge-in fired (levels only) — diagnostics.
    private(set) var lastBargeIn: String?
    private(set) var level: Float = 0
    /// The last 60 turn-manager transitions (state names and monotonic times only) — diagnostics and the live test; no audio, no text.
    private(set) var transitions: [(at: TimeInterval, state: String)] = []

    // Collaborators
    @ObservationIgnored let hub: MicrophoneHub
    @ObservationIgnored let sentinel: SentinelRuntime
    @ObservationIgnored unowned let voice: VoiceCoordinator
    @ObservationIgnored var settings: () -> VoiceSettings = { VoiceSettings() }
    @ObservationIgnored var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    @ObservationIgnored var onEvent: ((String, ActivityKind) -> Void)?

    // Internals
    @ObservationIgnored private var machine: TurnMachine
    @ObservationIgnored private var ring = AudioRing(maxSeconds: 3.0)
    @ObservationIgnored private var gate = EnergyGate()
    @ObservationIgnored private var bargeIn = BargeInDetector()
    /// Fix 4: when JARVIS' last ANSWER playback ended (acknowledgement cues do not count) and when a barge-in was last confirmed — the provenance of the next capture.
    @ObservationIgnored private var lastAnswerPlaybackEnd: TimeInterval?
    @ObservationIgnored private var lastBargeConfirmedAt: TimeInterval?
    @ObservationIgnored let diagnostics = VoiceDiagnostics()
    /// Seconds after an answer during which a capture counts as overlapping JARVIS' own voice (tests shorten it to control the timing).
    @ObservationIgnored var postSpeechGuard: TimeInterval = PhantomGuard.postSpeechGuard
    @ObservationIgnored private var bandFilter = SpeechBandFilter()
    @ObservationIgnored private var subscription: UUID?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var frameSink: AsyncStream<AudioFrame>.Continuation?
    @ObservationIgnored private var timers: [TurnTimer: Task<Void, Never>] = [:]
    @ObservationIgnored private var sentinelFlowing = false
    @ObservationIgnored private var vadStartedAt: TimeInterval?
    @ObservationIgnored private var lastSegmentStart: TimeInterval?
    @ObservationIgnored private var lastSegmentEnd: TimeInterval?
    @ObservationIgnored private var enabling = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var times = Times()
    @ObservationIgnored private var wakeDeafUntil: TimeInterval = 0
    @ObservationIgnored private var sleepingByUser = false
    @ObservationIgnored private var resumeAfterSystemSleep = false
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored var recoveryDelays: [Double] = [2, 6]

    private struct Times {
        var wake: TimeInterval?; var speechEnd: TimeInterval?; var endpoint: TimeInterval?; var bargeOnset: TimeInterval?; var bargeDecision: TimeInterval?
    }

    init(hub: MicrophoneHub, sentinel: SentinelRuntime, voice: VoiceCoordinator, config: TurnConfig = TurnConfig()) {
        self.hub = hub; self.sentinel = sentinel; self.voice = voice
        machine = TurnMachine(config: config)
        sentinel.onWake = { [weak self] score in self?.wakeHeard(score: score) }
        sentinel.onVAD = { [weak self] speech in self?.vadChanged(speech) }
        sentinel.onUnavailable = { [weak self] why in self?.markUnavailable(why) }
        voice.onSignal = { [weak self] signal in self?.handle(signal) }
        voice.onPartial = { [weak self] text in guard let self, self.machine.state == .endpointing || self.machine.state == .userSpeaking else { return }; self.dispatch(.partial(text)) }
    }

    var isWakeEnabled: Bool { subscription != nil }

    /// One short line of the last natural turn's measured latencies (Full HUD, content-free).
    var latencySummary: String? {
        func ms(_ v: Double?) -> String? { v.map { "\(Int($0 * 1000)) ms" } }
        var parts: [String] = []
        if let v = ms(metrics.speechEndToEndpoint) { parts.append("endpoint \(v)") }
        if let v = ms(metrics.endpointToFinal) { parts.append("final \(v)") }
        if let v = ms(metrics.endpointToFirstAudio) { parts.append("first audio \(v)") }
        if metrics.wasBargeIn, let v = ms(metrics.bargeInDecisionToSilence) { parts.append("barge-in stop \(v)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    var presence: VoicePresence { .resolve(session: voice.state, handsFree: state, wake: wakeStatus) }
    var config: TurnConfig { get { machine.config } set { machine.config = newValue } }

    // MARK: Enable / disable (Settings, launch, quit)

    /// Applies the current settings. Idempotent. Wake mode only starts when voice AND wake are enabled, the microphone is allowed, and the sentinel is installed.
    func applySettings() async {
        let s = settings()
        if !(s.enabled && s.wakeEnabled) { sleepingByUser = false; recoveryTask?.cancel(); recoveryTask = nil }
        if s.enabled && s.wakeEnabled {
            if sleepingByUser { return }                         // the user paused wake listening; only an explicit resume (or turning the setting off and on) ends it
            await enable()
        } else { await disable() }
    }

    // MARK: Sleep mode and system lifecycle (V1.0 stabilisation fix 2)

    /// The user said “Uyku moduna geç”: the microphone and the detector stop NOW. Not a setting change — the Wake Word switch stays as it is (so a relaunch listens again) — and Push-to-Talk keeps working.
    @discardableResult
    func enterSleepMode() async -> Bool {
        guard subscription != nil || wakeStatus == .listening || wakeStatus == .starting else { return false }
        sleepingByUser = true
        recoveryTask?.cancel(); recoveryTask = nil
        await disable()
        wakeStatus = .paused
        onEvent?("Wake mode paused (sleep mode)", .info)
        return true
    }

    /// Ends sleep mode (menu, Settings, or “wake word aç”).
    func resumeFromSleepMode() async {
        guard sleepingByUser else { return }
        sleepingByUser = false
        await applySettings()
    }
    var isSleepingByUser: Bool { sleepingByUser }

    /// “Dinlemeyi bırak”: ends the hands-free exchange that is open right now (listening, waiting for a follow-up, transcribing) and returns to wake-only listening. Nothing is submitted.
    /// Returns false when there was nothing to end. It is NOT the setting, not Stop Speaking and not Stop Task.
    @discardableResult
    func endHandsFreeSession() -> Bool {
        let busy: [HandsFreeState] = [.attentive, .userSpeaking, .endpointing, .transcribing]
        guard busy.contains(machine.state) else { return false }
        voice.cancelAll(reason: "stopped listening")
        dispatch(.reset)
        return true
    }

    /// The Mac is going to sleep: nothing may hold the microphone across it.
    func suspendForSystemSleep() async {
        resumeAfterSystemSleep = (subscription != nil || wakeStatus == .listening || wakeStatus == .starting) && !sleepingByUser
        recoveryTask?.cancel(); recoveryTask = nil
        if resumeAfterSystemSleep { await disable() }
    }

    /// The Mac woke up: if wake listening was on before, bring it back (bounded retries — audio devices need a moment).
    func resumeAfterSystemWake() {
        guard resumeAfterSystemSleep else { return }
        resumeAfterSystemSleep = false
        scheduleRecovery(reason: "the Mac woke up")
    }

    /// Bounded recovery: at most `recoveryDelays.count` attempts, each after its delay; then the state stays UNAVAILABLE with an explicit instruction. No polling, no endless loop.
    private func scheduleRecovery(reason: String) {
        recoveryTask?.cancel()
        let delays = recoveryDelays
        recoveryTask = Task { @MainActor [weak self] in
            for delay in delays {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                await self.applySettings()
                if self.wakeStatus == .listening { self.onEvent?("Wake mode recovered after \(reason)", .info); return }
            }
            guard !Task.isCancelled, let self else { return }
            if self.settings().enabled && self.settings().wakeEnabled && !self.sleepingByUser && self.wakeStatus != .listening {
                self.onEvent?("Wake mode could not be restored after \(reason). Turn Wake Word off and on again to retry.", .warning)
            }
        }
    }

    func enable() async {
        guard subscription == nil, !enabling else { return }
        enabling = true
        defer { enabling = false }
        generation += 1
        let mine = generation
        voice.refreshPermission()
        guard voice.permission == .granted else { markUnavailable(voice.permission == .notDetermined ? "microphone access has not been allowed yet" : "microphone access is not allowed"); return }
        sentinel.inspect()
        if case .notInstalled(let why) = sentinel.state { markUnavailable("the wake-word helper is not installed (\(why))"); return }
        wakeStatus = .starting
        do { try await sentinel.start() } catch { markUnavailable("the wake-word helper could not start"); return }
        guard mine == generation, settings().enabled, settings().wakeEnabled else { await sentinel.stop(); wakeStatus = .off; return }
        let (stream, sink) = AsyncStream<AudioFrame>.makeStream(bufferingPolicy: .bufferingNewest(120))
        do {
            subscription = try hub.subscribe("wake", onFrame: { sink.yield($0) },
                                             onInterruption: { [weak self] why in Task { @MainActor in self?.micInterrupted(why) } })
        } catch {
            sink.finish()
            await sentinel.stop()
            markUnavailable("the microphone could not be opened")
            return
        }
        frameSink = sink
        ring.clear(); gate.reset(); sentinelFlowing = false; bargeIn.endPlayback()
        pump = Task { @MainActor [weak self] in for await frame in stream { self?.receive(frame) } }
        wakeStatus = .listening
        dispatch(.wakeModeChanged(enabled: true, available: true))
        onEvent?("Wake mode on", .info)
    }

    func disable() async {
        generation += 1
        let was = subscription != nil || wakeStatus != .off
        dispatch(.wakeModeChanged(enabled: false, available: true))
        teardownCapture()
        wakeStatus = .off
        await sentinel.stop()
        if was { onEvent?("Wake mode off", .info) }
    }

    /// Developer / smoke-test / capture hook: shows a hands-free state in the HUD without touching the microphone, a helper or the turn machine. Never persisted.
    func simulate(state new: HandsFreeState, wake: WakeStatus) { state = new; wakeStatus = wake }

    /// Application quit: everything stops synchronously, nothing may keep listening.
    func shutdown() {
        generation += 1
        recoveryTask?.cancel(); recoveryTask = nil
        for (_, t) in timers { t.cancel() }
        timers = [:]
        _ = machine.handle(.shutdown, at: now())
        state = machine.state
        teardownCapture()
        hub.shutdown()
        sentinel.shutdownNow()
        wakeStatus = .off
    }

    private func teardownCapture() {
        pump?.cancel(); pump = nil
        frameSink?.finish(); frameSink = nil
        if let subscription { hub.unsubscribe(subscription) }
        subscription = nil
        ring.clear(); gate.reset(); sentinelFlowing = false
        vadStartedAt = nil
        bargeIn.endPlayback()
        level = 0
    }

    private func markUnavailable(_ why: String) {
        wakeStatus = .unavailable(why)
        dispatch(.wakeModeChanged(enabled: settings().wakeEnabled, available: false))
        teardownCapture()
        onEvent?("Wake mode unavailable: \(why)", .warning)
    }

    private func micInterrupted(_ why: String) {
        guard subscription != nil else { return }
        subscription = nil
        markUnavailable("the audio device changed")
        // The device may come back (a headset replugged or switched): a bounded recovery tries twice (2 s, then 6 s later), then waits for the user. Never an endless loop.
        scheduleRecovery(reason: "an audio device change")
    }

    // MARK: Frames

    private func receive(_ frame: AudioFrame) {
        let t = now()
        let db = AudioLevel.db(frame.samples)
        if t - (levelStamp) > 0.1 { levelStamp = t; level = min(1, max(0, (db + 60) / 45)) }
        if machine.state == .jarvisSpeaking, settings().bargeInEnabled {
            // Speech-band level in 20 ms slices: a click train or a thud is hot in only a few slices (or not at all after the high-pass), a voice in most of them.
            let band = bandFilter.process(frame.samples)
            let step = Int(AudioFrame.sampleRate * 0.02)
            var index = 0, sliceEnd = t - frame.seconds
            while index < band.count {
                let end = min(index + step, band.count), length = Double(end - index) / AudioFrame.sampleRate
                sliceEnd += length
                if let d = bargeIn.pushMic(db: AudioLevel.db(Array(band[index..<end])), duration: length, at: sliceEnd) {
                    times.bargeDecision = t; times.bargeOnset = t - d.onsetAgo
                    lastBargeIn = "excess +\(Int(d.excessDB)) dB over the expected echo (coupling \(Int(bargeIn.coupling)) dB), onset \(Int(d.onsetAgo * 1000)) ms before the decision"
                    lastBargeConfirmedAt = t
                    diagnostics.note("bargeIn.confirmed", "excess \(Int(d.excessDB)) dB, envelope correlation \(d.echoCorrelation.map { String(format: "%.2f", $0) } ?? "n/a")", at: t)
                    dispatch(.bargeIn(onsetAgo: d.onsetAgo))
                    break
                }
                index = end
            }
        }
        if bargeIn.rejectedAsEcho != lastRejectedEchoCount {
            diagnostics.note("bargeIn.rejectedAsEcho", "envelope correlation \(bargeIn.lastRejectedCorrelation.map { String(format: "%.2f", $0) } ?? "n/a")", at: t)
            lastRejectedEchoCount = bargeIn.rejectedAsEcho
        }
        // Gate: in a quiet room the sentinel receives nothing; any active conversation state keeps it fed.
        let active = machine.state != .wakeListening
        let open = gate.push(db: db, duration: frame.seconds, at: t) || active
        if open {
            if !sentinelFlowing {
                sentinelFlowing = true
                sentinel.resetStream()
                for f in ring.tail(seconds: 1.5) { sentinel.feed(f) }          // the second before the gate opened (bounded, in memory)
            }
            sentinel.feed(frame)
        } else {
            sentinelFlowing = false
        }
        // The last seconds BEFORE a decision belong to the utterance (pre-roll); the ring is overwritten continuously and never leaves memory.
        ring.append(frame)
    }
    @ObservationIgnored private var levelStamp: TimeInterval = 0
    @ObservationIgnored private var lastRejectedEchoCount = 0

    /// Level of what JARVIS is playing right now (from the output player's meter). Only used while JARVIS speaks.
    func referenceLevel(_ db: Float, at t: TimeInterval) { bargeIn.pushReference(db: db, at: t) }

    // MARK: Sentinel events

    private func wakeHeard(score: Double) {
        guard machine.state == .wakeListening else { return }          // ignored while JARVIS speaks/thinks or a turn is open: no self-wake
        guard !voice.speaker.isSpeaking, !voice.speaker.isActive, now() >= wakeDeafUntil else { return }          // also while ANY speech plays (previews, acknowledgements)
        let t = now()
        let accepted = WakeContextGate.accepts(vadActive: sentinel.vadSpeech, startedAgo: lastSegmentStart.map { t - $0 },
                                               endedAgo: sentinel.vadSpeech ? nil : lastSegmentEnd.map { t - $0 }, maxSegment: machine.config.maxWakeSegmentSeconds)
        guard accepted else { rejectedWakes += 1; return }                  // mid-sentence or non-speech: ordinary conversation does not wake JARVIS
        wakeCount += 1
        metrics = NaturalTurnMetrics(wakeScore: score)
        times = Times(wake: now())
        let ago = vadStartedAt.map { now() - $0 } ?? 0
        dispatch(.wakeDetected(speechActive: sentinel.vadSpeech, speechAgo: ago))
    }

    private func vadChanged(_ speech: Bool) {
        let t = now()
        if speech { vadStartedAt = t; lastSegmentStart = t; lastSegmentEnd = nil } else { vadStartedAt = nil; lastSegmentEnd = t; times.speechEnd = t }
        switch machine.state {
        case .jarvisSpeaking, .interrupting, .thinking: bargeIn.pushVAD(isSpeech: speech)      // JARVIS' own voice also looks like speech: only the level gate decides
        default:
            dispatch(speech ? .speechStarted : .speechEnded)
            if !speech, machine.state == .endpointing { voice.requestEndpointHint() }          // "is that a finished sentence?" — answered in ≈ 0.2 s by a fresh preview
        }
    }

    // MARK: Voice session signals

    private func handle(_ signal: VoiceSignal) {
        switch signal {
        case .pttBegan: dispatch(.pushToTalkBegan)
        case .pttEnded: dispatch(.pushToTalkEnded)
        case .transcriptEmpty, .selfSpeech: dispatch(.transcriptEmpty)
        case .wakeOnly: dispatch(.transcriptReady(wakeOnly: true))
        case .submitted:
            if let e = times.endpoint { metrics.endpointToFinal = now() - e }
            dispatch(.transcriptReady(wakeOnly: false))
            dispatch(.submitted)
        case .playbackStarted:
            if let e = times.endpoint { metrics.endpointToFirstAudio = now() - e }
            bargeIn.beginPlayback(at: now())
            dispatch(.speechPlaybackStarted)
        case .playbackEnded:
            if machine.state != .attentive { lastAnswerPlaybackEnd = now() }          // a wake acknowledgement is not an answer: the user answers it at once
            bargeIn.endPlayback()
            // The room still rings and the detector's history holds JARVIS' own voice: forget both before wake detection resumes.
            ring.clear(); sentinelFlowing = false; wakeDeafUntil = now() + 0.7
            if machine.state == .attentive { dispatch(.ackFinished) } else { dispatch(.speechPlaybackEnded) }
        case .turnEndedSilently: dispatch(.turnEndedSilently)
        case .failed(let message):
            dispatch(.failure(message))
            scheduleReset()
        }
    }

    private func scheduleReset() {
        timers[.attentive]?.cancel()
        let mine = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, self.generation == mine, case .error = self.machine.state else { return }
            self.dispatch(.reset)
        }
    }

    // MARK: Machine

    /// Event names with times and the endpoint hint class (never transcript text, never audio): bounded, in memory, for diagnostics and the live test only.
    private(set) var eventTrace: [(at: TimeInterval, event: String)] = []
    private func recordTrace(_ event: TurnEvent, at t: TimeInterval) {
        let label: String
        switch event {
        case .partial(let text): label = "partial(\(text.count) chars, hint \(EndpointPolicy.hint(for: text).rawValue))"
        case .timer(let kind, _): label = "timer(\(kind.rawValue))"
        case .wakeDetected(let active, let ago): label = "wakeDetected(active \(active), ago \(Int(ago * 1000)) ms)"
        case .transcriptReady(let wakeOnly): label = "transcriptReady(wakeOnly \(wakeOnly))"
        default: label = String(String(describing: event).prefix(40))
        }
        eventTrace.append((t, label))
        if eventTrace.count > 80 { eventTrace.removeFirst(eventTrace.count - 80) }
    }

    func dispatch(_ event: TurnEvent) {
        let t = now()
        let before = machine.state
        recordTrace(event, at: t)
        let effects = machine.handle(event, at: t)
        state = machine.state
        if state != before { stateChanged(from: before, to: state, at: t) }
        for effect in effects { perform(effect, at: t) }
        syncSentinelMode()
    }

    private func stateChanged(from: HandsFreeState, to: HandsFreeState, at t: TimeInterval) {
        transitions.append((t, to.label))
        if transitions.count > 60 { transitions.removeFirst(transitions.count - 60) }
        // VoiceOver hears states, politely, and only the ones that matter: never VAD transitions, never partial transcripts.
        switch (from, to) {
        case (.dormant, .wakeListening): Announcer.announce("Wake mode on", high: false)
        case (.wakeListening, .attentive): Announcer.announce("Listening", high: false)
        case (_, .interrupting): Announcer.announce("Interrupted", high: false)
        case (_, .error(let m)): Announcer.announce("Voice problem. \(m)", high: true)
        default: break
        }
        if to == .attentive, from == .wakeListening, let w = times.wake { metrics.wakeToAttentive = t - w }
        if to == .wakeListening || to == .dormant { voice.languageContinuity.reset() }          // a new wake word starts a new conversation language
    }

    private func perform(_ effect: TurnEffect, at t: TimeInterval) {
        switch effect {
        case .startUtterance(let preroll):
            times.endpoint = nil
            voice.utteranceProvenance = provenanceForNewUtterance(at: t)
            voice.diagnostics = diagnostics
            voice.beginUtterance(prefill: ring.tail(seconds: preroll))
        case .endUtterance:
            times.endpoint = t
            if let e = times.speechEnd { metrics.speechEndToEndpoint = t - e; onEvent?("Voice: turn ended (\(Int((t - e) * 1000)) ms after the last speech)", .info) }
            voice.endUtterance()
        case .discardUtterance:
            voice.discardUtterance()
        case .stopSpeaking:
            voice.stopSpeaking()
            bargeIn.endPlayback()
            if let d = times.bargeDecision { metrics.bargeInDecisionToSilence = now() - d; metrics.wasBargeIn = true }
            if let o = times.bargeOnset, let d = times.bargeDecision { metrics.bargeInOnsetToDecision = d - o }
            if machine.state == .interrupting { bargeInCount += 1; dispatch(.speechStopped) }
        case .acknowledgeWake:
            acknowledge()
        case .arm(let kind, let after, let token):
            timers[kind]?.cancel()
            timers[kind] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(after))
                guard !Task.isCancelled, let self else { return }
                self.dispatch(.timer(kind, token: token))
            }
        case .cancel(let kind):
            timers[kind]?.cancel(); timers[kind] = nil
        case .note(let text):
            onEvent?("Voice: \(text)", .info)
        }
    }

    /// How the capture that starts now relates to JARVIS' own voice (see `UtteranceProvenance`). Timing only; no audio, no text.
    func provenanceForNewUtterance(at t: TimeInterval) -> UtteranceProvenance {
        let sinceEnd = lastAnswerPlaybackEnd.map { t - $0 }
        let confirmed = lastBargeConfirmedAt.map { t - $0 < 1.5 } ?? false
        let playing = bargeIn.isPlaying
        let guarded = sinceEnd.map { $0 >= 0 && $0 < postSpeechGuard } ?? false
        return UtteranceProvenance(overlappedPlayback: playing || confirmed || guarded, confirmedBargeIn: confirmed, secondsSincePlaybackEnd: sinceEnd.flatMap { $0 < 10 ? $0 : nil })
    }

    private func syncSentinelMode() {
        guard sentinel.isRunning else { return }
        // Both detectors keep running while hands-free is on so the wake model's audio history is never discontinuous (a word right after an attentive
        // window or a spoken answer is not lost to re-priming). WHAT a wake event may do is decided here, never in the helper: it is ignored unless the turn
        // manager is in WAKE (not speaking, not in a turn) and the room has settled after JARVIS spoke (`wakeDeafUntil`).
        sentinel.setMode(wake: machine.state != .dormant, vad: machine.state != .dormant)
    }

    // MARK: Acknowledgement

    private func acknowledge() {
        switch settings().wakeAcknowledgement {
        case .off: break
        case .sound: voice.playWakeCue()
        case .voice: voice.speakWakeAcknowledgement()
        }
    }
}
