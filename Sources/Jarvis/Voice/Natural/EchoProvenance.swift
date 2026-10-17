import Foundation

/// Where an utterance's audio came from, in terms of JARVIS' own playback (Fix 4). Pure data, no text, no audio.
///
/// The self-echo chain observed in real use was: JARVIS speaks → its voice leaks into the microphone → a false barge-in stops the speech → the residue is transcribed
/// (a recogniser in auto-language mode turns a Turkish voice into short English nonsense) → the nonsense became a user turn. Text similarity cannot catch that
/// (the garbage shares no words with the answer), so the decision uses what is KNOWN about the capture: did it start while JARVIS was audible, or right after,
/// and did anything independent of JARVIS' output confirm that a person was speaking?
struct UtteranceProvenance: Equatable, Sendable {
    /// The capture began while JARVIS' speech was playing, right after a barge-in decision, or within the post-speech guard window.
    var overlappedPlayback: Bool
    /// The barge-in detector confirmed a voice that is not explained by JARVIS' own output (envelope-independent, or far above any plausible echo).
    var confirmedBargeIn: Bool
    /// Seconds between the end of JARVIS' last playback and the start of this capture (nil: it never played, or long ago).
    var secondsSincePlaybackEnd: Double?

    static let clean = UtteranceProvenance(overlappedPlayback: false, confirmedBargeIn: false, secondsSincePlaybackEnd: nil)
}

enum PhantomVerdict: Equatable, Sendable {
    case accept
    /// Not a user turn. `reason` is a stable machine-readable tag (diagnostics/audit), never user text.
    case rejectSelfEcho(reason: String)
}

enum PhantomGuard {
    /// The seconds after JARVIS stops speaking during which the room still rings and a capture that starts is suspect.
    static let postSpeechGuard: TimeInterval = 0.6
    /// A short transcript from an overlapped capture is not trusted without a confirmed voice; longer sentences are judged by the other filters.
    static let shortWordLimit = 4
    /// With a confirmed barge-in, a transcript this short whose language differs from the conversation's is a recogniser hallucination, not a command.
    static let hallucinationWordLimit = 3

    /// One-word interrupt/control utterances stay valid even when overlapped (“Sus”, “Dur”, “Stop”): they carry no authority (they only silence JARVIS).
    private static let interruptWords: Set<String> = ["sus", "dur", "stop", "durdur", "yeter", "quiet", "enough", "cancel", "iptal", "bekle", "wait"]

    static func verdict(text: String, detectedLanguage: VoiceLanguage?, conversationLanguage: VoiceLanguage?, provenance p: UtteranceProvenance) -> PhantomVerdict {
        guard p.overlappedPlayback else { return .accept }
        let words = SelfSpeechFilter.tokens(text)
        guard !words.isEmpty else { return .rejectSelfEcho(reason: "empty") }
        if words.count <= 2, words.allSatisfy({ interruptWords.contains($0) }) { return .accept }
        if !p.confirmedBargeIn {
            if words.count <= shortWordLimit { return .rejectSelfEcho(reason: "short transcript over JARVIS' own playback without a confirmed voice") }
            return .accept
        }
        if words.count <= hallucinationWordLimit, let d = detectedLanguage, let c = conversationLanguage, d != .auto, c != .auto, d != c {
            return .rejectSelfEcho(reason: "short transcript in a different language than the conversation, right after a barge-in")
        }
        return .accept
    }
}

/// Bounded, in-memory trace of the voice pipeline's decisions (Fix 4 instrumentation): event kinds, times, levels, correlations and counters — never audio, never transcripts.
@MainActor
final class VoiceDiagnostics {
    struct Entry: Equatable, Sendable {
        var at: TimeInterval
        var kind: String
        var detail: String
    }
    static let capacity = 200
    private(set) var entries: [Entry] = []
    private(set) var counts: [String: Int] = [:]

    func note(_ kind: String, _ detail: String = "", at t: TimeInterval) {
        entries.append(Entry(at: t, kind: kind, detail: String(detail.prefix(120))))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        counts[kind, default: 0] += 1
    }
    func count(_ kind: String) -> Int { counts[kind] ?? 0 }
    func reset() { entries.removeAll(); counts.removeAll() }
    var summary: String { counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") }
}
