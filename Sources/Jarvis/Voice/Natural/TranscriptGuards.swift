import Foundation

/// The wake word is an ACTIVATION, not a command: a transcript that only contains it ("Jarvis.") must not become a message.
enum WakePhrase {
    static let words: Set<String> = ["jarvis", "carvis", "jarvıs", "çarvis", "jarvis'", "jarvis’"]
    private static let leaders: Set<String> = ["hey", "hi", "ok", "okay", "hej", "merhaba", "selam", "peki", "tamam", "evet", "efendim"]

    /// The text without a leading wake phrase ("Hey Jarvis, open …" → "open …"). Turkish letters are never altered.
    static func strippingWake(from text: String) -> String {
        var words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        func bare(_ w: String) -> String { w.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)).lowercased() }
        // greetings/fillers before the name are part of the wake phrase ("Hey Jarvis", "Tamam Jarvis")
        if let idx = words.prefix(3).firstIndex(where: isWake), words[..<idx].allSatisfy({ leaders.contains(bare($0)) }) { words.removeFirst(idx + 1) }
        while let first = words.first, isWake(first) { words.removeFirst() }                    // "Jarvis, Jarvis, …"
        return words.joined(separator: " ").trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
    }

    private static func isWake(_ word: String) -> Bool {
        let bare = word.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)).lowercased()
        return words.contains(bare) || bare.hasPrefix("jarvis") && bare.count <= 9
    }

    /// True when nothing but the wake phrase (and greetings/fillers around it) was said.
    static func isWakeOnly(_ text: String) -> Bool {
        let rest = strippingWake(from: text)
        return rest.filter { $0.isLetter || $0.isNumber }.isEmpty
    }
}

/// Safety net for self-speech: a transcript that is (nearly) a quote of what JARVIS has just said is its own voice, not the user's.
/// Used only AFTER recognition, in addition to the level-based `BargeInDetector`; it never drops text that is not a close quote.
enum SelfSpeechFilter {
    /// Normalised comparison tokens: lowercase, Turkish dotless ı → i, diacritics removed. Used for comparison only — never for display or speech.
    static func tokens(_ text: String) -> [String] {
        let folded = text.lowercased().replacingOccurrences(of: "ı", with: "i").folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en"))
        return folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// `heard` counts as an echo when most of its words occur in what JARVIS said (token overlap ≥ `threshold`), or — tolerating different word splits such as
    /// "EditMode" vs "edit mode" — when the joined letters are a near subsequence of the spoken letters. Short utterances (< `minimumTokens` words) are never judged.
    static func isEcho(heard: String, spoken: [String], threshold: Double = 0.7, minimumTokens: Int = 3) -> Bool {
        let h = tokens(heard)
        guard h.count >= minimumTokens else { return false }
        var pool = Set<String>()
        for s in spoken { pool.formUnion(tokens(s)) }
        guard !pool.isEmpty else { return false }
        if Double(h.filter { pool.contains($0) }.count) / Double(h.count) >= threshold { return true }
        let joinedHeard = String(h.joined().prefix(120))
        guard joinedHeard.count >= 12 else { return false }
        return spoken.contains { windowSimilarity(joinedHeard, String(tokens($0).joined().prefix(800))) >= 0.85 }
    }

    /// Best normalised edit similarity (1 − distance / length) of `needle` against any equally long window of `haystack`. Bounded: needle ≤ 120, haystack ≤ 800.
    static func windowSimilarity(_ needle: String, _ haystack: String) -> Double {
        let n = Array(needle), h = Array(haystack)
        guard !n.isEmpty, h.count >= n.count / 2 else { return 0 }
        var best = 0.0
        let width = n.count
        var start = 0
        while start + width / 2 <= h.count {
            let window = Array(h[start..<min(h.count, start + width)])
            let d = editDistance(n, window)
            best = max(best, 1 - Double(d) / Double(max(n.count, window.count)))
            if best >= 0.999 { break }
            start += 2
        }
        return best
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
            prev = cur
        }
        return prev[b.count]
    }
}

/// Within one attentive conversation the answer language follows the conversation, not a single English technical word.
struct LanguageContinuity: Equatable, Sendable {
    private(set) var current: VoiceLanguage?

    /// `detected`: what the recogniser/`LanguageGuess` thinks the new turn is. `confident`: a clear, full sentence (not 1–2 words / mostly technical terms).
    mutating func resolve(detected: VoiceLanguage, text: String, fallback: VoiceLanguage) -> VoiceLanguage {
        guard let cur = current else { current = detected == .auto ? fallback : detected; return current ?? fallback }
        if detected == .auto || detected == cur { return cur }
        let words = SelfSpeechFilter.tokens(text)
        // A different language only wins with a real sentence of its own (≥ 4 words), never because of "Unity" or "GameObject".
        if words.count >= 4 { current = detected; return detected }
        return cur
    }

    mutating func reset() { current = nil }
}
