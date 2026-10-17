import Foundation
import Observation

/// The ONE authority over the voice lifecycle (V0.7, DEC-057…): microphone → streaming recogniser → FINAL transcript → the existing
/// conversation pipeline → the answer spoken by `VoiceResponseSpeaker`.
///
/// Voice is an I/O layer, not an intelligence engine. This class coordinates; it never routes, plans, approves, edits or runs anything:
/// the final transcript goes through `submit` — the same `ConversationService.submit` a typed message uses.
///
///   IDLE ─press→ [REQUESTING PERMISSION] → LISTENING ─release→ TRANSCRIBING ─final→ THINKING ─first audio→ SPEAKING ─done→ IDLE
///
///  • LISTENING means microphone capture is actually running; it ends the instant the key is released (before any recognition work).
///  • Only the FINAL transcript is submitted; partials are provisional and never become messages.
///  • One session owns the microphone: a press while listening/transcribing is ignored (no double submission, no stale transcript);
///    a press while JARVIS is speaking first stops the speech (explicit stop — NOT conversational barge-in, which is V0.8).
///  • Voice never approves anything: there is no code path from here to an approval.
/// What the hands-free layer (`HandsFreeCoordinator`) needs to learn about the voice session. Content-free: never text, never audio.
enum VoiceSignal: Equatable, Sendable {
    case pttBegan, pttEnded
    case transcriptEmpty            // nothing usable was heard (or too short / recognition failed softly)
    case wakeOnly                   // the transcript contained only the wake word
    case selfSpeech                 // the transcript was a quote of JARVIS' own speech and was dropped
    case submitted                  // the final transcript entered the conversation
    case playbackStarted            // JARVIS' answer became audible
    case playbackEnded              // every phrase finished (or speech was stopped)
    case turnEndedSilently          // the turn finished without any speech
    case failed(String)
}

@MainActor
@Observable
final class VoiceCoordinator {
    // Observable state (UI)
    private(set) var state: VoiceSessionState = .idle
    private(set) var partialTranscript = ""
    private(set) var permission: MicrophonePermission
    private(set) var lastNotice: String?
    private(set) var lastMetrics: VoiceTurnMetrics?
    private(set) var level: Float = 0
    private(set) var sttChoice = VoiceProviderChoice(id: nil, reason: "Not checked yet")
    private(set) var ttsChoice = VoiceProviderChoice(id: nil, reason: "Not checked yet")
    private(set) var sttAvailability: [String: STTAvailability] = [:]
    private(set) var turns = 0

    // Collaborators
    @ObservationIgnored let sttProviders: [any SpeechToTextProvider]
    @ObservationIgnored let ttsProviders: [any TextToSpeechProvider]
    @ObservationIgnored let speaker: VoiceResponseSpeaker
    @ObservationIgnored private let permissionProvider: any MicrophonePermissionProviding
    @ObservationIgnored var makeInput: @MainActor () -> any AudioInput          // replaced only by the live test (fixture audio)
    @ObservationIgnored private weak var store: JarvisStore?
    @ObservationIgnored var settings: () -> VoiceSettings = { VoiceSettings() }
    @ObservationIgnored var memoryPressureNormal: () -> Bool = { true }
    /// Hands a FINAL transcript to the conversation pipeline; returns the id of the user message it created (nil = nothing was submitted).
    @ObservationIgnored var submit: ((String, VoiceLanguage) -> UUID?)?
    @ObservationIgnored var conversationBusy: () -> Bool = { false }
    @ObservationIgnored var conversation: (() -> [ConversationMessage])?
    /// Activity feed hook: meaningful lifecycle events only (never audio, never transcript text).
    @ObservationIgnored var onEvent: ((String, ActivityKind) -> Void)?
    /// Provisional transcript updates for the endpoint policy (V0.8): text only as a hint, never a message.
    @ObservationIgnored var onPartial: ((String) -> Void)?
    /// Session signals for the hands-free layer (V0.8).
    @ObservationIgnored var onSignal: ((VoiceSignal) -> Void)?
    /// Language of the current hands-free conversation (kept across turns inside one attentive session).
    @ObservationIgnored var languageContinuity = LanguageContinuity()
    private(set) var handsFreeUtterance = false
    /// Set by the hands-free coordinator right before an utterance starts: how the capture relates to JARVIS' own playback (Fix 4). Push-to-Talk never sets it.
    var utteranceProvenance: UtteranceProvenance = .clean
    @ObservationIgnored var diagnostics: VoiceDiagnostics?
    @ObservationIgnored var diagnosticsClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Settings → Voice previews a preset without changing the saved choice; cleared when the preview ends.
    @ObservationIgnored let presetOverride: PresetOverride
    final class PresetOverride { var value: JarvisVoicePreset? }

    // Limits
    static let minimumAudioSeconds = 0.35
    static let maximumAudioSeconds = 60.0
    static let preBufferFrames = 700                  // ≈ 70 s: frames captured while the recogniser is still starting

    // Session
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private var held = false
    @ObservationIgnored private var input: (any AudioInput)?
    @ObservationIgnored private var stt: (any STTSession)?
    @ObservationIgnored private var sttProvider: (any SpeechToTextProvider)?
    @ObservationIgnored private var sessionStart: Task<Void, Never>?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var partials: Task<Void, Never>?
    @ObservationIgnored private var frameSink: AsyncStream<AudioFrame>.Continuation?
    @ObservationIgnored private var preBuffer: [AudioFrame] = []
    @ObservationIgnored private var audioSeconds = 0.0
    @ObservationIgnored private var metrics = VoiceTurnMetrics()
    @ObservationIgnored private var pressedAt = Date()
    @ObservationIgnored private var firstFrameAt: Date?
    @ObservationIgnored private var firstPartialAt: Date?
    @ObservationIgnored private var releasedAt = Date()
    @ObservationIgnored private var ownsListeningState = false
    @ObservationIgnored private var levelStamp = Date.distantPast
    @ObservationIgnored private var lastReplyLanguage: VoiceLanguage = .english

    init(sttProviders: [any SpeechToTextProvider], ttsProviders: [any TextToSpeechProvider], speaker: VoiceResponseSpeaker? = nil,
         permission: (any MicrophonePermissionProviding)? = nil, store: JarvisStore? = nil,
         makeInput: (@MainActor () -> any AudioInput)? = nil, presetOverride: PresetOverride? = nil) {
        self.presetOverride = presetOverride ?? PresetOverride()
        let speaker = speaker ?? VoiceResponseSpeaker()
        let permission = permission ?? SystemMicrophonePermission()
        self.sttProviders = sttProviders
        self.ttsProviders = ttsProviders
        self.speaker = speaker
        self.permissionProvider = permission
        self.permission = permission.status          // a read, never a request
        self.store = store
        self.makeInput = makeInput ?? { MicrophoneInput() }
        speaker.provider = { [weak self] in self?.activeTTS }
        speaker.settings = { [weak self] in self?.settings().output ?? VoiceOutputSettings() }
        speaker.onSpeakingChange = { [weak self] speaking in self?.speakingChanged(speaking) }
        speaker.onFirstAudio = { [weak self] in self?.firstAudio() }
        speaker.onTurnFinished = { [weak self] m in self?.turnFinished(m) }
        speaker.onEvent = { [weak self] text in self?.onEvent?(text, .info) }
    }

    // MARK: Providers

    var activeTTS: (any TextToSpeechProvider)? {
        let choice = VoiceProviderSelection.chooseTTS(preference: settings().ttsProvider,
                                                       candidates: ttsProviders.map { ($0.id, $0.displayName, $0.availability(), $0.capabilities.costClass) },
                                                       memoryPressureNormal: memoryPressureNormal(), preset: presetOverride.value ?? settings().voicePreset)
        return ttsProviders.first { $0.id == choice.id }
    }

    /// Re-evaluates provider availability and selection (Settings opened, language changed, setup finished). Starts nothing.
    func refreshProviders() async {
        let s = settings()
        var avail: [String: STTAvailability] = [:]
        var candidates: [VoiceProviderSelection.STTCandidate] = []
        for p in sttProviders {
            let a = await p.availability(for: s.language)
            avail[p.id] = a
            candidates.append(.init(id: p.id, name: p.displayName, availability: a, capabilities: p.capabilities, loadsModel: p.id != "apple-speech"))
        }
        sttAvailability = avail
        sttChoice = VoiceProviderSelection.chooseSTT(preference: s.sttProvider, candidates: candidates, memoryPressureNormal: memoryPressureNormal())
        ttsChoice = VoiceProviderSelection.chooseTTS(preference: s.ttsProvider, candidates: ttsProviders.map { ($0.id, $0.displayName, $0.availability(), $0.capabilities.costClass) },
                                                     memoryPressureNormal: memoryPressureNormal(), preset: presetOverride.value ?? s.voicePreset)
        permission = permissionProvider.status
    }

    func refreshPermission() { permission = permissionProvider.status }

    /// The user pressed "Allow microphone" in Settings (an explicit action — never called by launch, tests or wake mode on its own).
    func requestMicrophoneFromSettings() async {
        guard permission == .notDetermined else { return }
        permission = await permissionProvider.request()
    }

    // MARK: Push-to-Talk

    /// The key went down (and stayed down past the hold threshold).
    func pushToTalkPressed() {
        let s = settings()
        guard s.enabled else { return }
        switch state {
        case .listening, .requestingPermission, .transcribing: return                 // one session owns the microphone
        case .speaking, .idle, .thinking, .error: break
        }
        // Whatever JARVIS is saying stops BEFORE the microphone opens (explicit stop — not conversational barge-in, which is V0.8).
        if speaker.isActive || speaker.isSpeaking { speaker.stop(reason: "stopped by a new push-to-talk") }
        // A hands-free utterance in progress yields to the explicit key (the capture is dropped, push-to-talk owns the turn).
        if handsFreeUtterance { handsFreeUtterance = false; invalidate(); stopInput(); stopRecogniserSession(); partialTranscript = ""; setState(.idle); releaseListeningState() }
        onSignal?(.pttBegan)
        beginSession(settings: s)
    }

    /// The key went up (or a chord interrupted it: the audio is then discarded).
    func pushToTalkReleased(interrupted: Bool = false) {
        held = false
        switch state {
        case .requestingPermission:
            invalidate(); setState(.idle)
        case .listening:
            endListening(interrupted: interrupted)
        default: break
        }
    }

    /// Hard stop of everything voice-related (settings turned voice off, app quit, device loss …). Idempotent.
    func cancelAll(reason: String = "cancelled") {
        let wasBusy = state != .idle
        held = false
        handsFreeUtterance = false
        invalidate()
        speaker.stop(reason: reason)
        stopInput()
        partialTranscript = ""
        setState(.idle)
        releaseListeningState()
        if wasBusy { onEvent?("Voice \(reason)", .warning) }
    }

    /// Application termination: nothing may keep recording, speaking or running.
    func shutdown() {
        cancelAll(reason: "stopped at quit")
        for p in sttProviders { p.shutdownNow() }
        for p in ttsProviders { p.shutdownNow() }
    }

    /// The explicit "Stop speaking" control and the typed-message rule. Returns true if something was being spoken.
    @discardableResult
    /// V0.15: a short spoken line for a task that finished while nothing else is being said (Settings → Speak task completions). Never interrupts speech that is already playing, never
    /// opens the microphone. It goes through the same queue, voice choice and stop path as every other phrase.
    func speakCompletion(_ text: String, language: ReplyLanguage) {
        guard settings().enabled, settings().speakResponses, !speaker.isActive, !speaker.isSpeaking else { return }
        speaker.speakStandalone(String(text.prefix(280)), language: language == .tr ? .turkish : .english)
    }

    func stopSpeaking() -> Bool {
        let was = speaker.isSpeaking || speaker.isActive
        let t0 = Date()
        speaker.stop(reason: "stopped by you")
        if was {
            metrics.stopLatency = Date().timeIntervalSince(t0)
            if state == .speaking || state == .thinking { setState(.idle) }
            onSignal?(.playbackEnded)
        }
        return was
    }

    // MARK: Session start

    // MARK: Hands-free utterances (V0.8)

    /// A hands-free utterance starts (the turn manager decided the user is speaking). `prefill` is the audio just BEFORE the decision, taken from the
    /// bounded in-memory ring. Same session pipeline as Push-to-Talk: capture → recogniser → FINAL transcript → `submit`. Never requests permission.
    func beginUtterance(prefill: [AudioFrame]) {
        let s = settings()
        guard s.enabled, s.wakeEnabled else { return }
        switch state { case .listening, .requestingPermission, .transcribing: return; default: break }
        permission = permissionProvider.status
        guard permission == .granted else { onSignal?(.failed("microphone not allowed")); return }
        invalidate()
        token = UUID()
        handsFreeUtterance = true
        held = false
        pressedAt = Date(); metrics = VoiceTurnMetrics(); partialTranscript = ""; lastNotice = nil
        audioSeconds = prefill.reduce(0) { $0 + $1.seconds }; firstFrameAt = nil; firstPartialAt = nil
        startCapture(token: token, settings: s, prefill: prefill)
    }

    /// The endpoint policy decided the turn is over: stop capturing and produce the final transcript.
    func endUtterance() {
        guard handsFreeUtterance, state == .listening else { return }
        endListening(interrupted: false)
    }

    /// The user just went quiet: ask the recogniser for a fresh provisional transcript (the endpoint policy reads it as a "finished sentence?" hint).
    func requestEndpointHint() { if handsFreeUtterance, state == .listening { stt?.requestPreview() } }

    /// Drop the current hands-free utterance without a result (wake mode turned off, push-to-talk took over, a cough).
    func discardUtterance() {
        guard handsFreeUtterance else { return }
        handsFreeUtterance = false
        invalidate(); stopInput(); stopRecogniserSession(); partialTranscript = ""; level = 0
        if state == .listening || state == .transcribing { setState(.idle) }
        releaseListeningState()
    }

    private func beginSession(settings s: VoiceSettings) {
        handsFreeUtterance = false
        invalidate()
        token = UUID()
        let mine = token
        held = true
        pressedAt = Date()
        metrics = VoiceTurnMetrics()
        partialTranscript = ""
        lastNotice = nil
        audioSeconds = 0; firstFrameAt = nil; firstPartialAt = nil
        permission = permissionProvider.status
        switch permission {
        case .granted: startCapture(token: mine, settings: s)
        case .notDetermined:
            setState(.requestingPermission)
            Task { @MainActor in
                let result = await permissionProvider.request()
                permission = result
                guard token == mine else { return }
                guard result.allowsCapture else { fail(.microphoneDenied(result)); return }
                guard held else { setState(.idle); return }                              // released while the system dialog was open
                startCapture(token: mine, settings: s)
            }
        case .denied, .restricted: fail(.microphoneDenied(permission))
        }
    }

    private func startCapture(token mine: UUID, settings s: VoiceSettings, prefill: [AudioFrame] = []) {
        let device = makeInput()
        let (stream, sink) = AsyncStream<AudioFrame>.makeStream(bufferingPolicy: .bufferingNewest(Self.preBufferFrames))
        do {
            try device.start(onFrame: { sink.yield($0) },
                             onInterruption: { [weak self] why in Task { @MainActor in self?.deviceInterrupted(token: mine, why: why) } })
        } catch {
            sink.finish()
            fail((error as? VoiceError) ?? .microphoneUnavailable("\(error)"))
            return
        }
        input = device
        frameSink = sink
        preBuffer = prefill
        // LISTENING only now — capture is genuinely running.
        setState(.listening)
        claimListeningState()
        onEvent?("Voice: listening", .info)
        pump = Task { @MainActor [weak self] in
            for await frame in stream { self?.receive(frame, token: mine) }
        }
        sessionStart = Task { @MainActor [weak self] in await self?.openRecogniser(token: mine, settings: s) }
    }

    /// Chooses the recogniser and opens its session while audio is already being captured (frames wait in `preBuffer`).
    private func openRecogniser(token mine: UUID, settings s: VoiceSettings) async {
        await refreshProviders()
        guard token == mine else { return }
        guard let id = sttChoice.id, let provider = sttProviders.first(where: { $0.id == id }) else {
            fail(.sttUnavailable(sttChoice.reason)); return
        }
        let language = provider.capabilities.autoDetectsLanguage ? s.language : (s.language == .auto ? .systemDefault : s.language)
        do {
            let session = try await provider.makeSession(language: language)
            guard token == mine else { session.cancel(); return }
            stt = session; sttProvider = provider
            metrics.sttProvider = provider.id
            metrics.language = language == .auto ? "auto" : language.rawValue
            metrics.sttStartup = Date().timeIntervalSince(pressedAt)
            partials = Task { @MainActor [weak self] in
                for await event in session.events { self?.receivePartial(event, token: mine) }
            }
            for f in preBuffer { session.append(f) }
            preBuffer = []
        } catch {
            guard token == mine else { return }
            fail((error as? VoiceError) ?? .sttFailed("\(error)"))
        }
    }

    private func receive(_ frame: AudioFrame, token mine: UUID) {
        guard token == mine, state == .listening || state == .transcribing else { return }
        if firstFrameAt == nil { firstFrameAt = Date() }
        audioSeconds += frame.seconds
        if let stt { stt.append(frame) } else if preBuffer.count < Self.preBufferFrames { preBuffer.append(frame) }
        // Level indicator: at most 10 updates per second, only while listening.
        if state == .listening, Date().timeIntervalSince(levelStamp) > 0.1 {
            levelStamp = Date()
            let rms = (frame.samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(frame.samples.count, 1))).squareRoot()
            level = min(1, rms * 8)
        }
        if audioSeconds >= Self.maximumAudioSeconds, state == .listening {
            lastNotice = "Reached the \(Int(Self.maximumAudioSeconds)) second limit."
            endListening(interrupted: false)
        }
    }

    private func receivePartial(_ event: SpeechTranscriptEvent, token mine: UUID) {
        guard token == mine, state == .listening || state == .transcribing, !event.isFinal else { return }
        if firstPartialAt == nil, let first = firstFrameAt { firstPartialAt = Date(); metrics.firstPartial = Date().timeIntervalSince(first) }
        partialTranscript = event.text                 // provisional: shown in the composer area, never a message
        onPartial?(event.text)
    }

    // MARK: Release → final transcript → shared submission path

    private func endListening(interrupted: Bool) {
        releasedAt = Date()
        // 1. The microphone stops FIRST, before any recognition work.
        stopInput()
        level = 0
        releaseListeningState()
        if interrupted { invalidate(); partialTranscript = ""; setState(.idle); if !handsFreeUtterance { onSignal?(.pttEnded); onSignal?(.transcriptEmpty) }; onEvent?("Voice: recording discarded (shortcut interrupted)", .info); return }
        setState(.transcribing)
        if !handsFreeUtterance { onSignal?(.pttEnded) }
        let mine = token
        Task { @MainActor [weak self] in await self?.finalize(token: mine) }
    }

    private func finalize(token mine: UUID) async {
        // Wait until every captured frame has been forwarded and the recogniser session exists.
        await pump?.value
        guard token == mine else { return }
        if audioSeconds < Self.minimumAudioSeconds {                    // judged AFTER the last captured frame was counted
            invalidate(); partialTranscript = ""; setState(.idle)
            metrics.outcome = "tooShort"; lastMetrics = metrics
            lastNotice = VoiceError.tooShort.message()
            handsFreeUtterance = false
            onSignal?(.transcriptEmpty)
            return
        }
        metrics.audioSeconds = audioSeconds
        await sessionStart?.value
        guard token == mine, let session = stt else { return }
        do {
            let event = try await session.finish()
            guard token == mine else { return }
            metrics.sttFinalization = Date().timeIntervalSince(releasedAt)
            partials?.cancel()
            let text = TechnicalTerms.normalize((event?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))          // canonical spelling of the product's own terms only
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else {
                partialTranscript = ""
                metrics.outcome = "noSpeech"; lastMetrics = metrics
                lastNotice = VoiceError.noSpeech.message()
                handsFreeUtterance = false
                finishSession()
                onSignal?(.transcriptEmpty)
                return
            }
            metrics.transcriptLength = text.count
            metrics.language = event?.language ?? metrics.language
            if handsFreeUtterance {
                if WakePhrase.isWakeOnly(text) {                              // "Jarvis." alone is an activation, not a message
                    partialTranscript = ""; handsFreeUtterance = false; metrics.outcome = "wakeOnly"; finishSession(); onSignal?(.wakeOnly); return
                }
                if SelfSpeechFilter.isEcho(heard: text, spoken: speaker.recentSpoken) {         // JARVIS' own voice must never become a user turn
                    partialTranscript = ""; handsFreeUtterance = false; metrics.outcome = "selfSpeech"; lastMetrics = metrics
                    onEvent?("Voice: dropped a transcript that quoted JARVIS' own speech", .info)
                    finishSession(); onSignal?(.selfSpeech); return
                }
                let detected: VoiceLanguage? = event?.language.map { $0.hasPrefix("tr") ? .turkish : ($0.hasPrefix("en") ? .english : .auto) }
                if case .rejectSelfEcho(let reason) = PhantomGuard.verdict(text: text, detectedLanguage: detected, conversationLanguage: languageContinuity.current, provenance: utteranceProvenance) {
                    partialTranscript = ""; handsFreeUtterance = false; metrics.outcome = "selfEcho"; lastMetrics = metrics
                    diagnostics?.note("phantom.rejected", reason, at: diagnosticsClock())
                    onEvent?("Voice: dropped a short transcript captured over JARVIS' own speech (\(text.count) characters)", .info)
                    finishSession(); onSignal?(.selfSpeech); return
                }
            }
            deliver(text, language: event?.language)
        } catch {
            guard token == mine else { return }
            fail((error as? VoiceError) ?? .sttFailed("\(error)"))
        }
    }

    /// The FINAL transcript enters the same pipeline as typed text.
    private func deliver(_ text: String, language: String?) {
        var reply: VoiceLanguage = language.map { $0.hasPrefix("tr") ? .turkish : .english } ?? LanguageGuess.guess(text, fallback: lastReplyLanguage)
        if handsFreeUtterance { reply = languageContinuity.resolve(detected: reply, text: text, fallback: lastReplyLanguage) }        // one conversation, one language
        lastReplyLanguage = reply
        partialTranscript = ""
        turns += 1
        onEvent?("Voice: transcript submitted (\(text.count) characters, \(reply.rawValue))", .info)
        let s = settings()
        let userMessage = submit?(text, reply)
        stopRecogniserSession()
        handsFreeUtterance = false
        if userMessage != nil { onSignal?(.submitted) }
        guard s.speakResponses, activeTTS != nil, let userMessage else {
            metrics.outcome = metrics.outcome ?? "ok"; lastMetrics = metrics
            setState(.idle)
            onSignal?(userMessage == nil ? .transcriptEmpty : .turnEndedSilently)
            return
        }
        setState(.thinking)
        speaker.beginTurn(afterUserMessage: userMessage, fallbackLanguage: reply, releasedAt: releasedAt, metrics: metrics)
        speaker.update(messages: conversation?() ?? [], turnInProgress: conversationBusy())
    }

    /// Called by the conversation observer whenever messages change; cheap and idempotent.
    func conversationChanged() {
        guard speaker.isActive else { return }
        speaker.update(messages: conversation?() ?? [], turnInProgress: conversationBusy())
    }

    /// Settings → "Test Turkish / English": speaks a short fixed phrase with the chosen voice (an explicit user click; no microphone, no conversation).
    func speakSample(_ language: VoiceLanguage) {
        guard activeTTS != nil else { lastNotice = VoiceError.ttsUnavailable("no voice engine is available").message(); return }
        let text = language == .turkish ? "Merhaba, ben Jarvis. Sesim böyle." : "Hello, I am Jarvis. This is how I sound."
        speaker.speakStandalone(text, language: language)
    }

    /// Settings → voice preview: a fixed, restrained phrase in the chosen preset (A/B between JARVIS Default, JARVIS Calm and the Apple fallback). Starts no
    /// conversation and no microphone; the saved preset is untouched.
    func previewVoice(_ preset: JarvisVoicePreset, language: VoiceLanguage) {
        presetOverride.value = preset
        guard activeTTS != nil else { presetOverride.value = nil; lastNotice = VoiceError.ttsUnavailable("no voice engine is available").message(); return }
        let text = language == .turkish ? "Efendim? Sistemler hazır." : "Yes? All systems are ready."
        speaker.speakStandalone(text, language: language)
        Task { @MainActor [weak self] in            // the override lives exactly as long as the preview speech
            while let self, self.speaker.isActive { try? await Task.sleep(for: .milliseconds(100)) }
            self?.presetOverride.value = nil
        }
    }

    /// The short sound that acknowledges the wake word (default): no speech, no added latency, nothing for the microphone to mistake for the user.
    func playWakeCue() { (activeTTS as? PlayerBackedTTSProvider)?.playCue(WakeCue.block) }

    /// Optional spoken acknowledgement ("Efendim?" / "Yes?") through the normal speech path.
    func speakWakeAcknowledgement() {
        guard activeTTS != nil else { return }
        let s = settings()
        let lang: VoiceLanguage = s.language != .auto ? s.language : (languageContinuity.current ?? (turns > 0 ? lastReplyLanguage : VoiceLanguage.systemDefault))
        speaker.speakStandalone(lang == .turkish ? "Efendim?" : "Yes?", language: lang)
        if lang == .turkish { onAddressed?() }
    }
    /// V0.15: told when “Efendim?” was said, so the address policy does not repeat it a moment later.
    @ObservationIgnored var onAddressed: (() -> Void)?

    /// A typed message while JARVIS is speaking: the speech is stopped (the text conversation keeps going).
    func typedInputArrived() {
        if speaker.isActive || speaker.isSpeaking { stopSpeaking() }
    }

    // MARK: Speaker callbacks

    private func firstAudio() {
        if state == .thinking { setState(.speaking) }
        onSignal?(.playbackStarted)
    }

    private func speakingChanged(_ speaking: Bool) {
        if speaking, state == .thinking { setState(.speaking) }
        else if !speaking, state == .speaking { setState(.thinking) }                 // between phrases / waiting for more text
    }

    private func turnFinished(_ m: VoiceTurnMetrics) {
        metrics.firstTextToSynthesis = m.firstTextToSynthesis; metrics.synthesisToFirstAudio = m.synthesisToFirstAudio
        metrics.releaseToFirstAudio = m.releaseToFirstAudio; metrics.routingToFirstText = m.routingToFirstText
        metrics.spokenSeconds = m.spokenSeconds; metrics.ttsProvider = m.ttsProvider; metrics.outcome = m.outcome
        lastMetrics = metrics
        if let t = metrics.releaseToFirstAudio { onEvent?("Voice: first audio \(Int(t * 1000)) ms after release", .info) }
        if state == .thinking || state == .speaking { setState(.idle) }
        onSignal?(m.releaseToFirstAudio != nil ? .playbackEnded : .turnEndedSilently)
    }

    // MARK: Failure / cleanup

    private func deviceInterrupted(token mine: UUID, why: String) {
        guard token == mine, state == .listening else { return }
        stopInput()
        fail(.microphoneUnavailable(why))
    }

    private func fail(_ error: VoiceError) {
        handsFreeUtterance = false
        invalidate()
        stopInput()
        stopRecogniserSession()
        releaseListeningState()
        partialTranscript = ""
        level = 0
        metrics.outcome = "error"; lastMetrics = metrics
        let message = error.message(lastReplyLanguage == .turkish ? .tr : .en)
        lastNotice = message
        state = .error(message)
        onEvent?("Voice problem: \(Self.category(error))", .warning)
        onSignal?(.failed(Self.category(error)))
        // An error is shown, then the session returns to idle (a failure never leaves a stuck state).
        let mine = token
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, self.token == mine, case .error = self.state else { return }
            self.state = .idle
        }
    }

    private static func category(_ e: VoiceError) -> String {
        switch e {
        case .microphoneDenied: "microphone not allowed"; case .microphoneUnavailable: "microphone unavailable"
        case .sttUnavailable: "recogniser unavailable"; case .sttFailed: "recognition failed"; case .ttsUnavailable: "speech unavailable"
        default: "error"
        }
    }

    private func finishSession() {
        stopRecogniserSession()
        setState(.idle)
    }

    /// Retires the current session token so every late callback of the old session is ignored.
    private func invalidate() {
        token = UUID()
        sessionStart?.cancel(); sessionStart = nil
        pump?.cancel(); pump = nil
        partials?.cancel(); partials = nil
        stt?.cancel(); stt = nil
        preBuffer = []
    }

    private func stopRecogniserSession() {
        partials?.cancel(); partials = nil
        stt = nil; sttProvider = nil
    }

    private func stopInput() {
        input?.stop()
        input = nil
        frameSink?.finish(); frameSink = nil
    }

    private func setState(_ new: VoiceSessionState) {
        guard state != new else { return }
        state = new
        if new == .idle { level = 0 }
        switch new {
        case .listening: Announcer.announce("Listening", high: false)
        case .error(let m): Announcer.announce(m, high: true)
        default: break
        }
    }

    // MARK: JarvisState ownership (never clobber a state someone else set)

    private func claimListeningState() {
        guard let store, store.state == .idle || store.state == .completed else { return }
        store.setState(.listening)
        ownsListeningState = true
    }

    private func releaseListeningState() {
        guard ownsListeningState else { return }
        ownsListeningState = false
        if let store, store.state == .listening { store.setState(.idle) }
    }

    /// Developer / smoke-test / capture hook: shows a voice state in the HUD without touching the microphone or any provider. Never persisted.
    func simulate(state new: VoiceSessionState, partial: String = "", level: Float = 0) { state = new; partialTranscript = partial; self.level = level }

    /// True while the microphone engine exists — used by tests and the idle-microphone guard.
    var isMicrophoneOpen: Bool { input?.isCapturing ?? false }
}
