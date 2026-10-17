import Foundation

// MARK: - “Hayır, demek istediğim …” / “No, I meant …” (V1.0 stabilisation fix 2)
//
// A person who is misunderstood says so. A correction is a CONVERSATION act: the corrected sentence is routed again from scratch (so the old route is not repeated), with the previous utterance,
// the interpretation JARVIS gave it and the previous answer kept — bounded and in memory only — in the working context. A correction never carries authority (it cannot approve anything) and never
// guesses: a bare “yanlış anladın” asks what was meant, and a corrected request goes through exactly the same checks, approvals and clarifications as if it had been typed first.
// Voice transcripts also get a small CLOSED repair table for words a recogniser predictably mishears (“weak word” for “wake word”); it never touches approvals or destructive words.

struct Correction: Equatable, Sendable {
    enum Strength: Sendable, Equatable { case strong, weak }   // strong: “demek istediğim”, “I meant”, “yanlış anladın”; weak: a bare “hayır,” / “no,”
    var strength: Strength
    var remainder: String      // the corrected request (original case and letters), possibly empty
}

enum CorrectionParser {
    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en")).lowercased().replacingOccurrences(of: "ı", with: "i")
            .filter { $0.isLetter || $0.isNumber }
    }
    private static let strong: [[String]] = [
        ["yanlis", "anladin"], ["yanlis", "anladiniz"], ["yanlis", "anlamissin"], ["yanlis", "oldu"], ["demek", "istedigim"], ["demek", "istemistim"], ["kastettigim"], ["kastetmistim"], ["ben", "demek", "istedim"],
        ["i", "meant"], ["i", "mean"], ["what", "i", "meant"], ["what", "i", "mean"], ["thats", "not", "what", "i", "asked"], ["thats", "not", "what", "i", "meant"], ["you", "misunderstood"], ["you", "misheard"], ["not", "what", "i", "meant"],
    ]
    private static let weak: [[String]] = [["hayir", "hayir"], ["hayir"], ["yok", "hayir"], ["no", "no"], ["no"], ["nope"], ["not", "that"]]
    private static let bridge: Set<String> = ["ben", "yani", "aslinda", "ama", "well", "i", "actually", "so", "um", "uh"]

    static func parse(_ raw: String) -> Correction? {
        let words = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty, words.count <= 30 else { return nil }
        let folded = words.map(fold)
        for (cues, strength) in [(strong, Correction.Strength.strong), (weak, .weak)] {
            for cue in cues.sorted(by: { $0.count > $1.count }) where folded.count >= cue.count && Array(folded.prefix(cue.count)) == cue {
                if strength == .weak, folded.count > cue.count {
                    // “No thanks”, “Hayır teşekkürler” are answers, not corrections: a weak cue needs punctuation after it (“Hayır, …”) or a strong cue right behind it.
                    let lastRaw = words[cue.count - 1]
                    let punctuated = lastRaw.last.map { ",.;:!—–-".contains($0) } ?? false
                    let strongNext = Self.strong.contains { c2 in folded.count >= cue.count + c2.count && Array(folded[cue.count..<(cue.count + c2.count)]) == c2 }
                    if !punctuated && !strongNext { continue }
                }
                var rest = Array(words.dropFirst(cue.count))
                var foldedRest = Array(folded.dropFirst(cue.count))
                // “Hayır, ben Claude'u kastettim” — drop a bridging word after the cue; a trailing “demek istedim / kastettim” belongs to the cue, not to the request.
                var strength = strength
                // “No, I meant Codex” / “Hayır, demek istediğim Codex”: a weak cue followed by a strong one is a strong correction.
                for cue2 in Self.strong.sorted(by: { $0.count > $1.count }) where foldedRest.count >= cue2.count && Array(foldedRest.prefix(cue2.count)) == cue2 {
                    rest.removeFirst(cue2.count); foldedRest.removeFirst(cue2.count); strength = .strong; break
                }
                while let f = foldedRest.first, bridge.contains(f), rest.count > 1 { rest.removeFirst(); foldedRest.removeFirst() }
                for tail in [["demek", "istedim"], ["demek", "istemistim"], ["kastettim"], ["kastetmistim"], ["i", "meant"], ["is", "what", "i", "meant"]] where foldedRest.count >= tail.count && Array(foldedRest.suffix(tail.count)) == tail {
                    rest.removeLast(tail.count); foldedRest.removeLast(tail.count)
                }
                var remainder = rest.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:!-–—"))
                if strength == .weak, foldedRest.isEmpty { remainder = "" }
                return Correction(strength: strength, remainder: remainder)
            }
        }
        // “… demek istedim.” at the END of a full sentence (“Ekranıma bak demek istedim”).
        for tail in [["demek", "istedim"], ["demek", "istemistim"], ["kastettim"], ["i", "meant"]] where folded.count > tail.count && Array(folded.suffix(tail.count)) == tail {
            let remainder = words.dropLast(tail.count).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:!-–—"))
            return Correction(strength: .strong, remainder: remainder)
        }
        return nil
    }
}

/// What the last turn was, kept so that a correction can be resolved against it. Bounded, in memory, cleared with the working context. Never an authority.
struct TurnMemory: Equatable, Sendable {
    var userText: String
    var interpretation: String       // “readiness: can-use claude”, “settings: speech rate”, “conversation”…
    var answer: String
    static func clip(_ s: String) -> String { s.count <= 240 ? s : String(s.prefix(240)) + "…" }
}

struct CorrectionMarker: Equatable, Sendable {
    var previous: TurnMemory
    var turn: Int
}

enum SpeechTranscriptRepair {
    /// Closed table of mishearings of JARVIS' own vocabulary. Whole words/phrases only; the replacement is the canonical word. Approvals, “delete”-like words and names of projects are never in this list.
    private static let table: [(String, String)] = [
        ("weak word", "wake word"), ("wait word", "wake word"), ("wake wood", "wake word"), ("wake wort", "wake word"), ("weyk word", "wake word"), ("wake vurt", "wake word"), ("ayık kelime", "wake word"), ("weik word", "wake word"),
        ("efendi diye", "efendim diye"), ("efendin diye", "efendim diye"), ("efendim di ye", "efendim diye"),
        ("konuşma hızını artır", "konuşma hızını arttır"), ("konuşma hızını azaltır", "konuşma hızını azalt"),
        ("launch at log in", "launch at login"), ("launch a login", "launch at login"), ("lunch at login", "launch at login"), ("launch at lock in", "launch at login"),
        ("push the talk", "push to talk"), ("pushed to talk", "push to talk"),
    ]
    static func repair(_ text: String) -> String {
        var out = text
        for (heard, canonical) in table where heard != canonical {
            if let r = out.range(of: heard, options: [.caseInsensitive, .diacriticInsensitive]) { out.replaceSubrange(r, with: canonical) }
        }
        return out
    }
}
