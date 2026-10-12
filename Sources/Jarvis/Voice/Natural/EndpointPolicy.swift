import Foundation

/// Decides when a hands-free utterance is FINISHED (V0.8). Pure and deterministic: no model call, no I/O.
///
/// A short silence is not the end of a turn — "Jarvis, Unity'deki … şey … son testlere bak" must stay ONE turn. The wait therefore depends on what the
/// recogniser has heard so far (`Hint`): a finished sentence needs little silence, an obviously unfinished one a lot. The hint is only a hint — it never
/// overrides the hard cap — and a missing/stale partial simply means `.unknown`.
///
/// Measured on the synthetic pause fixtures (`docs/NATURAL_VOICE.md`): with 1.0 s no 0.9 s hesitation is cut; with 0.6 s only the 0.55 s ones survive.
struct EndpointPolicy: Equatable, Sendable {
    /// Speech shorter than this never becomes a turn (a cough, a click that fooled the VAD).
    var minimumSpeech: TimeInterval = 0.30
    /// Silence needed to end the turn, by what the partial transcript looks like.
    var completeSilence: TimeInterval = 0.65
    var unknownSilence: TimeInterval = 1.0
    var incompleteSilence: TimeInterval = 1.5
    /// A very short command ("Dur.", "Stop.", "Tamam.") that already looks complete may end sooner.
    var shortCommandSilence: TimeInterval = 0.5
    var shortCommandSpeech: TimeInterval = 1.6
    /// No turn waits longer than this, whatever the hint says.
    var hardCapSilence: TimeInterval = 1.7
    /// A turn never lasts longer than this (the V0.7 capture limit applies as well).
    var maximumTurn: TimeInterval = 45

    enum Hint: String, Sendable { case complete, unknown, incomplete }

    /// How long the silence after speech must last before the turn ends.
    func requiredSilence(speech: TimeInterval, hint: Hint) -> TimeInterval {
        let base: TimeInterval
        switch hint {
        case .complete: base = speech <= shortCommandSpeech ? shortCommandSilence : completeSilence
        case .unknown: base = unknownSilence
        case .incomplete: base = incompleteSilence
        }
        return min(base, hardCapSilence)
    }

    enum Verdict: Equatable, Sendable { case tooShort, wait, endTurn }

    /// `speech`: seconds of speech heard in this turn. `silence`: seconds of continuous silence since the last speech.
    func verdict(speech: TimeInterval, silence: TimeInterval, hint: Hint) -> Verdict {
        if speech < minimumSpeech { return silence >= unknownSilence ? .tooShort : .wait }
        return silence >= requiredSilence(speech: speech, hint: hint) ? .endTurn : .wait
    }

    // MARK: Hint from the partial transcript

    private static let connectorsEN: Set<String> = ["and", "or", "but", "the", "a", "an", "to", "of", "in", "on", "at", "for", "with", "about", "from", "that", "which",
                                                    "is", "are", "was", "my", "your", "our", "their", "this", "these", "those", "if", "then", "so", "because", "like", "um", "uh", "er"]
    private static let connectorsTR: Set<String> = ["ve", "ile", "ama", "fakat", "çünkü", "ki", "bir", "bu", "şu", "o", "için", "gibi", "kadar", "ya", "yani",
                                                    "şey", "hani", "işte", "mesela", "şunu", "bunu", "sonra", "veya", "hem", "en", "daha"]

    /// One-word replies that are complete commands on their own.
    private static let standaloneCommands: Set<String> = ["dur", "stop", "tamam", "evet", "hayır", "hayir", "iptal", "cancel", "yes", "no", "ok", "okay", "geç", "gec", "next", "back", "geri", "devam", "continue", "pause", "resume",
                                                         "durdur", "sus", "quiet", "enough", "yeter"]

    /// Turkish relative-adjective endings («Unity'deki …», «masadaki …») need a following noun: a sentence never ends on them.
    private static let unfinishedSuffixes = ["deki", "daki", "teki", "taki", "ndeki", "ndaki"]

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map { String($0).trimmingCharacters(in: .punctuationCharacters).lowercased(with: Locale(identifier: "tr_TR")) }.filter { !$0.isEmpty }
    }

    /// `complete` when the text ends a sentence, `incomplete` when it visibly stops mid-thought, `unknown` otherwise (no text yet, or no cue).
    /// A recogniser adds a full stop to «Jarvis, Unity'deki.» just as readily as to a real command, so a stop alone is trusted only when the sentence has substance
    /// (≥ 3 words besides the wake word, or a known one-word command) and does not end on a word that needs a continuation.
    static func hint(for partial: String?) -> Hint {
        guard let raw = partial?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return .unknown }
        var text = raw
        while let last = text.last, "\"'”’)]»".contains(last) { text.removeLast() }
        guard let last = text.last else { return .unknown }
        let all = words(text)
        let lastWord = all.last ?? ""
        let unfinishedEnd = connectorsEN.contains(lastWord) || connectorsTR.contains(lastWord) || unfinishedSuffixes.contains { lastWord.hasSuffix($0) }
        if ",;:–—-…".contains(last) || text.hasSuffix("...") { return .incomplete }
        if unfinishedEnd { return .incomplete }
        if ".?!".contains(last) {
            let content = all.filter { !WakePhrase.words.contains($0) && $0 != "hey" }
            if content.count >= 3 || (content.count == 1 && standaloneCommands.contains(content[0])) { return .complete }
            return .unknown
        }
        return .unknown
    }
}
