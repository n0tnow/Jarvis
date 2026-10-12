import Foundation

// MARK: - States, events, effects

/// Where the hands-free conversation is (V0.8). A truthful reflection of reality, never of intent: ATTENTIVE means the local VAD is waiting for the user
/// (no speech recognition runs), USER_SPEAKING means an utterance capture/STT session is open, JARVIS_SPEAKING means audio is really playing.
enum HandsFreeState: Equatable, Sendable {
    case dormant            // wake mode off or unavailable (push-to-talk still works)
    case wakeListening      // only the local wake detector hears the microphone
    case attentive          // woke up (or a follow-up window is open): waiting for the user to start speaking
    case userSpeaking       // the user is speaking; an utterance session is open
    case endpointing        // silence after speech: deciding whether the turn is over
    case transcribing       // the turn is over; the final transcript is being produced
    case thinking           // the transcript went into the conversation
    case jarvisSpeaking     // JARVIS' answer is audible
    case interrupting       // the user spoke over JARVIS; the speech is being stopped
    case error(String)

    var label: String {
        switch self {
        case .dormant: "WAKE OFF"; case .wakeListening: "WAKE"; case .attentive: "ATTENTIVE"; case .userSpeaking: "LISTENING"
        case .endpointing: "LISTENING"; case .transcribing: "TRANSCRIBING"; case .thinking: "THINKING"; case .jarvisSpeaking: "SPEAKING"
        case .interrupting: "INTERRUPTED"; case .error: "ERROR"
        }
    }
}

enum TurnOwner: Equatable, Sendable { case handsFree, pushToTalk }

enum TurnTimer: String, Equatable, Sendable { case attentive, endpoint, maxTurn, continuation, watchdog, deaf }

enum TurnEvent: Equatable, Sendable {
    case wakeModeChanged(enabled: Bool, available: Bool)
    /// The local wake detector fired. `speechActive`: the VAD currently hears speech (the user kept talking after the word); `speechAgo`: how long ago it began.
    case wakeDetected(speechActive: Bool, speechAgo: TimeInterval)
    case speechStarted          // VAD: the user started speaking
    case speechEnded            // VAD: the user stopped
    case partial(String)        // provisional transcript of the open utterance (only a hint for the endpoint)
    case timer(TurnTimer, token: Int)
    case transcriptReady(wakeOnly: Bool)   // a final transcript exists; `wakeOnly` = it contained nothing but the wake word
    case transcriptEmpty        // nothing usable was heard / recognition failed
    case submitted              // the transcript entered the conversation
    case speechPlaybackStarted
    case speechPlaybackEnded    // every phrase finished or speech was stopped
    case turnEndedSilently      // the answer needs no speech (speech off, nothing speakable, task acknowledged silently)
    case bargeIn(onsetAgo: TimeInterval)
    case speechStopped          // the old speech is silent (follows .bargeIn)
    case ackFinished            // a spoken wake acknowledgement ended (the room still rings for a moment)
    case pushToTalkBegan, pushToTalkEnded
    case failure(String)
    case reset
    case shutdown
}

enum TurnEffect: Equatable, Sendable {
    case startUtterance(preroll: TimeInterval)
    case endUtterance           // finish the open utterance → final transcript
    case discardUtterance       // close it without a result
    case stopSpeaking
    case acknowledgeWake
    case arm(TurnTimer, after: TimeInterval, token: Int)
    case cancel(TurnTimer)
    case note(String)           // a content-free activity line
}

/// The wake word must be UTTERANCE-INITIAL: the word (and what follows in the same breath) starts a speech segment, it does not appear in the middle of
/// continuous speech. This single rule removes essentially every false wake caused by ordinary conversation (measured, docs/NATURAL_VOICE.md) at the price of not
/// waking on «… so, Jarvis, do X» said in the middle of a long sentence. Pure; the VAD supplies the segment timing.
enum WakeContextGate {
    /// `startedAgo`: how long ago the current/last speech segment began; `endedAgo`: how long ago it ended (nil while it is still going on).
    static func accepts(vadActive: Bool, startedAgo: TimeInterval?, endedAgo: TimeInterval?, maxSegment: TimeInterval) -> Bool {
        guard let startedAgo else { return false }                          // no speech segment at all: not a spoken word
        if vadActive { return startedAgo <= maxSegment }
        guard let endedAgo, endedAgo <= 0.5 else { return false }           // the segment ended long ago: this is not its word
        return startedAgo - endedAgo <= maxSegment                          // its length
    }
}

struct TurnConfig: Equatable, Sendable {
    var attentiveSeconds: TimeInterval = 7        // after the wake word: how long to wait for the user to start speaking
    var followUpSeconds: TimeInterval = 8         // after an answer: how long a follow-up needs no wake word
    var maxConsecutiveTurns = 8                   // follow-ups without a new wake word
    var postSpeechDeafness: TimeInterval = 0.4    // the room still rings after JARVIS stops: ignore VAD for this long
    var wakeDeafness: TimeInterval = 0.5          // the acknowledgement cue itself must not count as the user speaking
    var continuationSeconds: TimeInterval = 0.45  // the wake word is followed by more speech in the same breath only if the VAD still hears it this long after the detection
    var maxEmptyAttempts = 2                      // unintelligible attempts before returning to wake-only listening
    var transcribingWatchdog: TimeInterval = 60   // recognition never keeps the turn manager in TRANSCRIBING longer than this (the helper's own timeout is 45 s)
    var maxWakeSegmentSeconds: TimeInterval = 1.6 // see `WakeContextGate`
    var endpoint = EndpointPolicy()
}

// MARK: - Machine

/// The hands-free turn state machine (V0.8): pure, deterministic, time passed explicitly. It decides WHAT happens next and emits effects; the
/// `HandsFreeCoordinator` performs them. It never routes, plans, approves, edits or runs anything — it has no reference to any of those.
struct TurnMachine: Sendable {
    private(set) var state: HandsFreeState = .dormant
    private(set) var owner: TurnOwner = .handsFree
    private(set) var consecutiveTurns = 0
    private(set) var emptyAttempts = 0
    private(set) var lastBargeIn = false
    var config: TurnConfig
    private var wakeEnabled = false
    private var wakeAvailable = false
    private var tokens: [TurnTimer: Int] = [:]
    private var deafUntil: TimeInterval = -.infinity
    private var speechStartedAt: TimeInterval?
    private var speechAccumulated: TimeInterval = 0
    private var silenceStartedAt: TimeInterval?
    private var partialText = ""
    private var vadActive = false
    private var pendingContinuation: TimeInterval?        // `speechAgo` of a wake word whose continuation is still being observed

    init(config: TurnConfig = TurnConfig()) { self.config = config }

    private var restingState: HandsFreeState { wakeEnabled && wakeAvailable ? .wakeListening : .dormant }

    mutating func handle(_ event: TurnEvent, at t: TimeInterval) -> [TurnEffect] {
        let before = state
        var fx = handleEvent(event, at: t)
        // Safety net: TRANSCRIBING must always end (final transcript, nothing heard, failure) — never a stuck state.
        if state == .transcribing, before != .transcribing { fx.append(arm(.watchdog, config.transcribingWatchdog)) }
        else if before == .transcribing, state != .transcribing { fx.append(.cancel(.watchdog)) }
        return fx
    }

    private mutating func handleEvent(_ event: TurnEvent, at t: TimeInterval) -> [TurnEffect] {
        var fx: [TurnEffect] = []
        switch event {
        case .wakeModeChanged(let enabled, let available):
            wakeEnabled = enabled; wakeAvailable = available
            if enabled && available {
                if state == .dormant { state = .wakeListening; fx.append(.note("Wake mode on")) }
            } else {
                switch state {
                case .dormant: break
                case .userSpeaking, .endpointing: fx += closeUtterance(discard: true)
                default: break
                }
                if !isBusySpeakingOrThinking { state = .dormant }
                fx += cancelAll()
                fx.append(.note(enabled ? "Wake mode unavailable" : "Wake mode off"))
            }

        case .wakeDetected(let active, let ago):
            guard state == .wakeListening else { return [] }          // never while JARVIS speaks/thinks or an utterance is open: no self-wake
            consecutiveTurns = 0; emptyAttempts = 0; owner = .handsFree; lastBargeIn = false
            state = .attentive
            fx.append(.note("Wake word heard"))
            if active {
                // The detector fires at (or just before) the end of the word, so the VAD usually still hears speech. Whether the user keeps talking in the same
                // breath is decided `continuationSeconds` later: the recogniser is opened only if they do — a lone «Jarvis» never starts speech recognition.
                pendingContinuation = ago
                fx.append(arm(.continuation, config.continuationSeconds))
            } else {
                deafUntil = t + config.wakeDeafness
                fx.append(.acknowledgeWake)
            }
            fx.append(arm(.attentive, config.attentiveSeconds))

        case .speechStarted:
            vadActive = true
            switch state {
            case .attentive where t >= deafUntil:
                pendingContinuation = nil
                beginUtterance(at: t)
                fx.append(.cancel(.attentive)); fx.append(.cancel(.continuation)); fx.append(.cancel(.deaf)); fx.append(.startUtterance(preroll: 0.35)); fx.append(arm(.maxTurn, config.endpoint.maximumTurn))
            case .attentive:
                // Speech began while the acknowledgement cue (or JARVIS' last word) may still be audible. The VAD reports no second edge if it keeps talking, so
                // look again when the deaf window is over: still speaking → that is the user ("Jarvis, … open the Tasks screen" with a comma pause).
                fx.append(arm(.deaf, max(0.01, deafUntil - t)))
            case .endpointing:
                state = .userSpeaking; silenceStartedAt = nil; speechStartedAt = t
                fx.append(.cancel(.endpoint))
            case .userSpeaking:
                if speechStartedAt == nil { speechStartedAt = t }
                silenceStartedAt = nil
            default: break
            }

        case .speechEnded:
            vadActive = false
            if state == .attentive, pendingContinuation != nil {          // the word was said alone: acknowledge it now
                pendingContinuation = nil
                deafUntil = t + config.wakeDeafness
                return [.cancel(.continuation), .acknowledgeWake]
            }
            guard state == .userSpeaking, owner == .handsFree else { return [] }
            if let s = speechStartedAt { speechAccumulated += max(0, t - s) }
            speechStartedAt = nil; silenceStartedAt = t
            state = .endpointing
            fx.append(arm(.endpoint, config.endpoint.requiredSilence(speech: speechAccumulated, hint: EndpointPolicy.hint(for: partialText))))

        case .partial(let text):
            partialText = text
            if state == .endpointing, let since = silenceStartedAt {
                let need = config.endpoint.requiredSilence(speech: speechAccumulated, hint: EndpointPolicy.hint(for: text))
                fx.append(arm(.endpoint, max(0.05, need - (t - since))))
            }

        case .timer(let kind, let token):
            guard tokens[kind] == token else { return [] }             // stale timer
            switch (kind, state) {
            case (.endpoint, .endpointing):
                if speechAccumulated < config.endpoint.minimumSpeech {
                    fx += closeUtterance(discard: true)
                    fx += afterUtteranceWithoutResult()
                } else {
                    state = .transcribing
                    fx.append(.cancel(.maxTurn)); fx.append(.endUtterance)
                }
            case (.maxTurn, .userSpeaking), (.maxTurn, .endpointing):
                if let s = speechStartedAt { speechAccumulated += max(0, t - s); speechStartedAt = nil }
                state = .transcribing
                fx.append(.cancel(.endpoint)); fx.append(.endUtterance); fx.append(.note("Turn limit reached"))
            case (.continuation, .attentive):
                guard let ago = pendingContinuation else { return [] }
                pendingContinuation = nil
                if vadActive {                                             // still talking, in the same breath: this IS the utterance (the word included)
                    beginUtterance(at: t - ago - config.continuationSeconds)
                    fx.append(.cancel(.attentive)); fx.append(.cancel(.deaf)); fx.append(.startUtterance(preroll: ago + config.continuationSeconds + 0.3)); fx.append(arm(.maxTurn, config.endpoint.maximumTurn))
                } else {
                    deafUntil = t + config.wakeDeafness
                    fx.append(.acknowledgeWake)
                }
            case (.deaf, .attentive):
                guard vadActive, t >= deafUntil else { return [] }
                pendingContinuation = nil
                beginUtterance(at: t)
                fx.append(.cancel(.attentive)); fx.append(.cancel(.continuation)); fx.append(.startUtterance(preroll: 0.6)); fx.append(arm(.maxTurn, config.endpoint.maximumTurn))
            case (.watchdog, .transcribing):
                emptyAttempts = 0
                state = restingState; owner = .handsFree
                fx.append(.discardUtterance); fx.append(.note("Recognition took too long — back to listening"))
            case (.attentive, .attentive):
                pendingContinuation = nil
                state = restingState
                fx.append(.note("Returned to wake mode"))
            default: break
            }

        case .transcriptReady(let wakeOnly):
            guard state == .transcribing else { return [] }
            emptyAttempts = 0
            if wakeOnly { fx += enterAttentive(window: config.attentiveSeconds, t: t) }
            // otherwise `.submitted` follows

        case .transcriptEmpty:
            guard state == .transcribing else { return [] }
            fx += afterUtteranceWithoutResult()

        case .submitted:
            guard state == .transcribing || state == .userSpeaking || state == .endpointing else { return [] }
            state = .thinking
            consecutiveTurns += 1
            fx.append(.cancel(.maxTurn)); fx.append(.cancel(.endpoint))

        case .speechPlaybackStarted:
            if state == .thinking { state = .jarvisSpeaking }

        case .speechPlaybackEnded:
            if state == .jarvisSpeaking || state == .thinking { fx += finishAnswer(t: t) }

        case .turnEndedSilently:
            if state == .thinking { fx += finishAnswer(t: t) }

        case .bargeIn(let onsetAgo):
            guard state == .jarvisSpeaking else { return [] }
            lastBargeIn = true; owner = .handsFree
            beginUtterance(at: t - onsetAgo)
            state = .interrupting
            fx.append(.note("Barge-in")); fx.append(.stopSpeaking)
            fx.append(.startUtterance(preroll: onsetAgo + 0.25)); fx.append(arm(.maxTurn, config.endpoint.maximumTurn))

        case .speechStopped:
            if state == .interrupting { state = .userSpeaking }

        case .ackFinished:
            if state == .attentive { deafUntil = t + config.postSpeechDeafness }

        case .pushToTalkBegan:
            guard state != .dormant || wakeEnabled else {
                owner = .pushToTalk
                return []                                              // wake mode off: the V0.7 path runs on its own
            }
            switch state {
            case .transcribing: return []                                 // finishing the previous turn: ignored, like V0.7
            case .userSpeaking where owner == .handsFree, .endpointing where owner == .handsFree: fx += closeUtterance(discard: true)
            case .jarvisSpeaking, .thinking, .interrupting: fx.append(.stopSpeaking)
            default: break
            }
            fx += cancelAll()
            owner = .pushToTalk; state = .userSpeaking
            fx.append(.note("Push-to-talk"))

        case .pushToTalkEnded:
            if owner == .pushToTalk, state == .userSpeaking || state == .endpointing { state = .transcribing }
            if !wakeEnabled { owner = .handsFree }

        case .failure(let message):
            fx += cancelAll()
            if state == .userSpeaking || state == .endpointing { fx.append(.discardUtterance) }
            state = .error(message)

        case .reset:
            fx += cancelAll()
            state = restingState; owner = .handsFree

        case .shutdown:
            fx += cancelAll()
            if state == .userSpeaking || state == .endpointing || state == .transcribing { fx.append(.discardUtterance) }
            fx.append(.stopSpeaking)
            state = .dormant; owner = .handsFree
        }
        return fx
    }

    // MARK: Helpers

    private var isBusySpeakingOrThinking: Bool { state == .thinking || state == .jarvisSpeaking || state == .transcribing }

    private mutating func beginUtterance(at t: TimeInterval) {
        state = .userSpeaking
        speechStartedAt = t; speechAccumulated = 0; silenceStartedAt = nil; partialText = ""
    }

    private mutating func arm(_ kind: TurnTimer, _ seconds: TimeInterval) -> TurnEffect {
        let token = (tokens[kind] ?? 0) + 1
        tokens[kind] = token
        return .arm(kind, after: seconds, token: token)
    }

    private mutating func cancelAll() -> [TurnEffect] {
        for k in tokens.keys { tokens[k] = (tokens[k] ?? 0) + 1 }
        pendingContinuation = nil
        return [.cancel(.attentive), .cancel(.endpoint), .cancel(.maxTurn), .cancel(.continuation), .cancel(.watchdog), .cancel(.deaf)]
    }

    private mutating func closeUtterance(discard: Bool) -> [TurnEffect] {
        speechStartedAt = nil; silenceStartedAt = nil; speechAccumulated = 0; partialText = ""
        return discard ? [.discardUtterance, .cancel(.maxTurn), .cancel(.endpoint)] : []
    }

    private mutating func enterAttentive(window: TimeInterval, t: TimeInterval) -> [TurnEffect] {
        state = .attentive
        return [arm(.attentive, window)]
    }

    /// Nothing usable came out of an utterance.
    private mutating func afterUtteranceWithoutResult() -> [TurnEffect] {
        guard owner == .handsFree, wakeEnabled else { state = restingState; return [] }
        emptyAttempts += 1
        if emptyAttempts >= config.maxEmptyAttempts { emptyAttempts = 0; state = restingState; return [.note("Returned to wake mode")] }
        state = .attentive
        return [arm(.attentive, config.attentiveSeconds)]
    }

    /// The answer is done (spoken, or needed no speech): open a bounded follow-up window — or go back to wake-only listening.
    private mutating func finishAnswer(t: TimeInterval) -> [TurnEffect] {
        deafUntil = t + config.postSpeechDeafness
        let wasPTT = owner == .pushToTalk
        owner = .handsFree
        guard wakeEnabled, wakeAvailable, !wasPTT, consecutiveTurns < config.maxConsecutiveTurns else {
            state = restingState
            return consecutiveTurns >= config.maxConsecutiveTurns && !wasPTT ? [.note("Returned to wake mode")] : []
        }
        state = .attentive
        return [arm(.attentive, config.followUpSeconds)]
    }
}
