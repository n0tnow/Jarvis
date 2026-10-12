import Foundation
import Observation

/// What the speaker needs from Settings, read at the moment a phrase is handed to the synthesiser.
struct VoiceOutputSettings: Equatable, Sendable {
    var rate = 1.0
    var turkishVoiceID = ""
    var englishVoiceID = ""
}

/// Speaks the SAME answer the conversation shows. It watches the JARVIS messages that follow one voice-submitted user message, turns the
/// stable parts into phrases (`SpeechChunker` → `SpeechRenderer`), and hands them to the TTS provider through a bounded queue.
///
///  • One answer, two presentations: there is no second model call and no separate "text to say".
///  • Speech starts as soon as the first phrase is stable — not when the answer is complete.
///  • Long answers: a bounded leading portion, then one short note (`LongAnswerPolicy`); code blocks and tables are never read out.
///  • `stop()` silences everything at once: queued phrases are dropped, so a stale phrase can never play in a later turn.
@MainActor
@Observable
final class VoiceResponseSpeaker {
    /// True from `beginTurn` until the last phrase finished (or `stop`).
    private(set) var isActive = false
    /// True only while audio is actually playing (a started phrase that has not finished).
    private(set) var isSpeaking = false

    @ObservationIgnored var provider: (() -> (any TextToSpeechProvider)?)?
    @ObservationIgnored var settings: () -> VoiceOutputSettings = { VoiceOutputSettings() }
    @ObservationIgnored var policy = LongAnswerPolicy()
    @ObservationIgnored var maxInFlight = 2
    @ObservationIgnored var maxQueued = 12
    /// Turn finished normally (all phrases played, or nothing was speakable).
    @ObservationIgnored var onTurnFinished: ((VoiceTurnMetrics) -> Void)?
    /// Audio of the first phrase began (the user can hear JARVIS now).
    @ObservationIgnored var onFirstAudio: (() -> Void)?
    @ObservationIgnored var onSpeakingChange: ((Bool) -> Void)?
    @ObservationIgnored var onEvent: ((String) -> Void)?

    private struct MessageProgress { var consumed = 0; var chunker = SpeechChunker(); var done = false }
    @ObservationIgnored private var userMessageID: UUID?
    @ObservationIgnored private var progress: [UUID: MessageProgress] = [:]
    @ObservationIgnored private var fallback: VoiceLanguage = .english
    @ObservationIgnored private var queue: [SpeechChunk] = []
    @ObservationIgnored private var inFlight: Set<Int> = []
    @ObservationIgnored private var nextChunkID = 1
    @ObservationIgnored private var spokenCharacters = 0
    @ObservationIgnored private var spokenChunks = 0
    @ObservationIgnored private var truncated = false
    @ObservationIgnored private var codeNoteSpoken = false
    @ObservationIgnored private var tableNoteSpoken = false
    @ObservationIgnored private var inputComplete = false
    @ObservationIgnored private var metrics = VoiceTurnMetrics()
    @ObservationIgnored private var turnStart = Date()
    @ObservationIgnored private var firstTextAt: Date?
    @ObservationIgnored private var firstChunkAt: Date?
    @ObservationIgnored private var firstHandoffAt: Date?
    @ObservationIgnored private var firstAudioAt: Date?
    @ObservationIgnored private var speakingSince: Date?
    @ObservationIgnored private var spokenTotal: TimeInterval = 0
    @ObservationIgnored private var attached: ObjectIdentifier?

    // MARK: Turn lifecycle

    /// Starts following the answer to `userMessage`. Anything still playing from an earlier turn is silenced first.
    func beginTurn(afterUserMessage id: UUID, fallbackLanguage: VoiceLanguage, releasedAt: Date? = nil, metrics base: VoiceTurnMetrics = VoiceTurnMetrics()) {
        stop(reason: "new turn")
        userMessageID = id
        fallback = fallbackLanguage == .auto ? .english : fallbackLanguage
        isActive = true
        inputComplete = false
        metrics = base
        turnStart = releasedAt ?? .now
        attach()
    }

    private func attach() {
        guard let p = provider?() else { return }
        let key = ObjectIdentifier(p)
        guard attached != key else { return }
        p.onEvent = { [weak self] event in self?.handle(event) }
        attached = key
    }

    /// Called whenever the conversation changed (event-driven by the observer in `AppContext`). Idempotent.
    func update(messages: [ConversationMessage], turnInProgress: Bool) {
        guard isActive, let userID = userMessageID else { return }
        guard let idx = messages.lastIndex(where: { $0.id == userID }) else {
            // The conversation was cleared (or the message aged out) while the turn was open: end it quietly — never a stuck THINKING.
            var m = metrics; m.outcome = "cleared"
            stop(reason: "conversation cleared")
            onTurnFinished?(m)
            return
        }
        var allDone = true
        for m in messages[(idx + 1)...] where m.role == .jarvis {
            var p = progress[m.id] ?? MessageProgress()
            if p.done { progress[m.id] = p; continue }
            let content = m.content
            if content.count > p.consumed {
                if firstTextAt == nil { firstTextAt = .now }
                let delta = String(content.dropFirst(p.consumed))
                p.consumed = content.count
                for piece in p.chunker.push(delta) { handle(piece) }
            }
            if m.status == .complete || m.status == .failed {
                for piece in p.chunker.finish() { handle(piece) }
                p.done = true
            } else { allDone = false }
            progress[m.id] = p
            if !p.done { break }                                   // speak messages strictly in order
        }
        inputComplete = allDone && !turnInProgress
        pump()
        finishIfDrained()
    }

    /// A standalone phrase (the Settings "Test voice" buttons): no conversation involved. Goes through the same queue, voice choice and stop path.
    func speakStandalone(_ text: String, language: VoiceLanguage) {
        stop(reason: "new phrase")
        isActive = true
        fallback = language == .auto ? .english : language
        inputComplete = true
        metrics = VoiceTurnMetrics()
        turnStart = .now
        attach()
        let rendered = SpeechRenderer.render(text, language: fallback)
        if !rendered.isEmpty { enqueue(rendered, fallback, counts: true) }
        pump()
        finishIfDrained()
    }

    /// Silences playback NOW and ends the turn. Safe to call at any time.
    func stop(reason: String = "stopped") {
        let had = isActive || isSpeaking || !queue.isEmpty || !inFlight.isEmpty
        queue.removeAll(); inFlight.removeAll()
        resetTurn()                                  // the turn is over BEFORE the provider reports its cancellations
        provider?()?.stop()
        if had { onEvent?("Speech \(reason)") }
        setSpeaking(false)
    }

    private func resetTurn() {
        isActive = false; userMessageID = nil; progress = [:]
        spokenCharacters = 0; spokenChunks = 0; truncated = false; codeNoteSpoken = false; tableNoteSpoken = false
        inputComplete = false; lastSpoken = nil; firstTextAt = nil; firstChunkAt = nil; firstHandoffAt = nil; firstAudioAt = nil; speakingSince = nil; spokenTotal = 0
    }

    // MARK: Pieces → phrases

    private func handle(_ piece: SpeechPiece) {
        guard !truncated else { return }
        switch piece {
        case .text(let raw):
            let lang = LanguageGuess.guess(raw, fallback: fallback)
            let rendered = SpeechRenderer.render(raw, language: lang)
            guard rendered.contains(where: { $0.isLetter || $0.isNumber }) else { return }
            if policy.wouldExceed(spokenCharacters: spokenCharacters, spokenChunks: spokenChunks, next: rendered.count) {
                truncated = true
                enqueue(LongAnswerPolicy.screenNote(lang), lang, counts: false)
                return
            }
            enqueue(rendered, lang, counts: true)
        case .codeOmitted:
            guard !codeNoteSpoken else { return }
            codeNoteSpoken = true
            enqueue(LongAnswerPolicy.codeNote(fallbackOrSpoken), fallbackOrSpoken, counts: false)
        case .tableOmitted:
            guard !tableNoteSpoken else { return }
            tableNoteSpoken = true
            enqueue(LongAnswerPolicy.tableNote(fallbackOrSpoken), fallbackOrSpoken, counts: false)
        }
    }

    @ObservationIgnored private var lastSpoken: VoiceLanguage?
    private var fallbackOrSpoken: VoiceLanguage { lastSpoken ?? fallback }

    private func enqueue(_ text: String, _ language: VoiceLanguage, counts: Bool) {
        guard queue.count < maxQueued else { return }                     // bounded: the policy normally stops us long before this
        if firstChunkAt == nil { firstChunkAt = .now }
        lastSpoken = language
        if counts { spokenCharacters += text.count; spokenChunks += 1 }
        queue.append(SpeechChunk(id: nextChunkID, text: text, language: language))
        nextChunkID += 1
    }

    private func pump() {
        guard let p = provider?(), !queue.isEmpty else { return }
        attach()
        let s = settings()
        while inFlight.count < maxInFlight, !queue.isEmpty {
            let chunk = queue.removeFirst()
            let chosen = chunk.language == .turkish ? s.turkishVoiceID : s.englishVoiceID
            let voice = VoiceSelection.resolve(language: chunk.language, chosenID: chosen, among: p.voices())
            if firstHandoffAt == nil { firstHandoffAt = .now }
            inFlight.insert(chunk.id)
            p.speak(chunk, voice: voice, rate: s.rate)
        }
    }

    // MARK: Provider events

    private func handle(_ event: TTSPlaybackEvent) {
        switch event {
        case .started(let id):
            guard inFlight.contains(id) else { return }
            if firstAudioAt == nil {
                firstAudioAt = .now
                if let a = firstAudioAt {
                    metrics.firstTextToSynthesis = firstChunkAt.flatMap { c in firstHandoffAt.map { $0.timeIntervalSince(c) } }
                    metrics.synthesisToFirstAudio = firstHandoffAt.map { a.timeIntervalSince($0) }
                    metrics.releaseToFirstAudio = a.timeIntervalSince(turnStart)
                    metrics.routingToFirstText = firstTextAt.map { $0.timeIntervalSince(turnStart) }
                }
                onFirstAudio?()
            }
            if speakingSince == nil { speakingSince = .now }
            setSpeaking(true)
        case .finished(let id):
            guard inFlight.remove(id) != nil else { return }
            pump()
            if inFlight.isEmpty && queue.isEmpty { setSpeaking(false) }       // between phrases / waiting for more text: not speaking
            finishIfDrained()
        case .cancelled(let id):
            inFlight.remove(id)
            finishIfDrained()
        case .failed(let id, let why):
            if let id { inFlight.remove(id) }
            onEvent?("Speech failed: \(why)")
            queue.removeAll()                                              // text is still on screen; do not keep retrying audio
            finishIfDrained()
        }
    }

    private func setSpeaking(_ on: Bool) {
        if !on, let since = speakingSince { spokenTotal += Date().timeIntervalSince(since); speakingSince = nil }
        guard isSpeaking != on else { return }
        isSpeaking = on
        onSpeakingChange?(on)
    }

    private func finishIfDrained() {
        guard isActive, inputComplete, queue.isEmpty, inFlight.isEmpty else { return }
        setSpeaking(false)
        var m = metrics
        m.spokenSeconds = spokenTotal > 0 ? spokenTotal : nil
        m.ttsProvider = provider?()?.id
        m.outcome = m.outcome ?? "ok"
        resetTurn()
        onTurnFinished?(m)
    }
}
