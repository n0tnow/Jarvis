import Foundation

enum ReplyLanguage: String, Sendable { case en, tr }

/// Routing-only view of what the user typed. The ORIGINAL text is never altered or discarded — it is what
/// gets stored and shown; `text`/`tokens` exist only for matching.
struct NormalizedInput: Equatable, Sendable {
    let original: String
    /// Folded, punctuation-free, filler-free, "Jarvis"-prefix/suffix-free text, single-spaced.
    let text: String
    let tokens: [String]
    /// The user addressed JARVIS by name ("Jarvis, …", "hey Jarvis").
    let addressedJarvis: Bool
    /// Language of the user's input (drives the language of canned replies).
    let language: ReplyLanguage
}

/// Case/diacritic/punctuation folding so simple English and Turkish aliases are cheap to maintain:
/// "Raporu Aç!" → "raporu ac", "Jarvis, show me the report." → "show report".
enum InputNormalizer {
    private static let jarvisTokens: Set<String> = ["jarvis", "jarvisi", "jarvise", "jarvisin", "jarvisle"]
    private static let greetingLeaders: Set<String> = ["hey", "ok", "okay", "hi", "yo", "hello", "selam", "merhaba"]
    private static let fillers: Set<String> = ["the", "a", "me", "my", "please", "pls", "lutfen", "bana", "simdi", "now"]
    /// Polite lead-ins, removed only when something follows them.
    private static let leadIns: [[String]] = [
        ["can", "you"], ["could", "you"], ["would", "you"], ["will", "you"],
        ["i", "want", "you", "to"], ["i", "would", "like", "to"], ["i", "d", "like", "to"], ["i", "want", "to"],
        ["let", "s"], ["lets"],
    ]
    private static let turkishLetters = CharacterSet(charactersIn: "çğıöşüÇĞİÖŞÜ")

    static func normalize(_ raw: String) -> NormalizedInput {
        let language: ReplyLanguage = raw.rangeOfCharacter(from: turkishLetters) != nil ? .tr : .en

        // Fold: lowercase + strip diacritics (ç→c ğ→g ö→o ş→s ü→u, İ→i), then dotless ı→i.
        var folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en"))
            .lowercased()
            .replacingOccurrences(of: "ı", with: "i")
        folded = folded.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")

        // Anything that isn't a-z / 0-9 becomes a separator; split collapses repeated whitespace.
        let cleaned = String(folded.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : " " })
        var tokens = cleaned.split(separator: " ").map(String.init)

        // Optional "Jarvis" address: leading ("hey jarvis, …", "jarvis …") and trailing ("… jarvis").
        var addressed = false
        if tokens.count >= 2, greetingLeaders.contains(tokens[0]), jarvisTokens.contains(tokens[1]) {
            addressed = true               // "hey jarvis, open report" → "open report"; "hey jarvis" → ""
            tokens.removeFirst(2)
        } else if let first = tokens.first, jarvisTokens.contains(first) {
            addressed = true
            tokens.removeFirst()
        }
        if let last = tokens.last, jarvisTokens.contains(last) {
            addressed = true
            tokens.removeLast()
        }

        // Polite lead-ins ("can you pause the task" → "pause task"), only if something follows.
        for lead in leadIns where tokens.count > lead.count && Array(tokens.prefix(lead.count)) == lead {
            tokens.removeFirst(lead.count)
            break
        }

        tokens.removeAll { fillers.contains($0) }
        return NormalizedInput(original: raw, text: tokens.joined(separator: " "), tokens: tokens,
                               addressedJarvis: addressed, language: language)
    }
}
