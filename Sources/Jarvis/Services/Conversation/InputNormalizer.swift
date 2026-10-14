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
    /// "ok"/"okay" never carry meaning; "hey/hi/yo/hello" are dropped only when a real request follows (≥2 tokens),
    /// so "hey there" / "hi" stay greetings.
    private static let silentLeaders: Set<String> = ["ok", "okay"]
    private static let greetingLeaders: Set<String> = ["hey", "hi", "yo", "hello", "selam", "merhaba"]
    private static let fillers: Set<String> = ["the", "a", "me", "my", "please", "pls", "lutfen", "bana", "simdi", "now"]
    /// Polite lead-ins, removed only when something follows them (apostrophes are deleted before matching: "I'd" → "id").
    private static let leadIns: [[String]] = [
        ["can", "you"], ["could", "you"], ["would", "you"], ["will", "you"],
        ["i", "want", "you", "to"], ["i", "would", "like", "to"], ["id", "like", "to"], ["id", "like"], ["i", "want", "to"], ["i", "wanna"],
        ["lets"], ["let", "s"],
    ]
    private static let turkishLetters = CharacterSet(charactersIn: "çğıöşüÇĞİÖŞÜ")
    /// Folded Turkish function/content words — lets "bana bir hikaye anlat" (no diacritics) get a Turkish reply.
    private static let turkishWords: Set<String> = [
        "bana", "bir", "ne", "nasil", "neden", "icin", "anlat", "hakkinda", "nedir", "musun", "misin", "selam", "merhaba",
        "tesekkurler", "sagol", "lutfen", "gorevi", "gorevleri", "raporu", "ayarlari", "sistemi", "gunaydin", "yapiyorsun", "durumun",
        // V0.15 follow-ups written without Turkish letters (“onu kullan”, “ikincisini dene”, “biraz sola al”)
        "onu", "bunu", "sunu", "dene", "kullan", "ikincisini", "birincisini", "ucuncusunu", "sil", "kaldir", "koy", "ekle", "sola", "saga", "yukari", "asagi", "biraz", "tekrar", "hayir", "evet", "uygunsa", "sus", "kisa", "soyle", "detayli", "ayrintili",
    ]

    static func normalize(_ raw: String) -> NormalizedInput {
        // Fold: lowercase + strip diacritics (ç→c ğ→g ö→o ş→s ü→u, İ→i), then dotless ı→i.
        var folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en"))
            .lowercased()
            .replacingOccurrences(of: "ı", with: "i")
        for quote in ["'", "’", "‘", "ʼ", "`"] { folded = folded.replacingOccurrences(of: quote, with: "") }

        // Anything that isn't a-z / 0-9 becomes a separator; split collapses repeated whitespace.
        let cleaned = String(folded.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : " " })
        var tokens = cleaned.split(separator: " ").map(String.init)

        let language: ReplyLanguage =
            (raw.rangeOfCharacter(from: turkishLetters) != nil || tokens.contains(where: turkishWords.contains)) ? .tr : .en

        // 1. Fillers first, so "please", "now"… can't hide an address or a lead-in
        //    ("please can you open the report", "stop jarvis please").
        tokens.removeAll { fillers.contains($0) }

        // 2. Optional "Jarvis" address, leading or trailing ("hey jarvis, …", "… jarvis").
        var addressed = false
        if let i = tokens.firstIndex(where: jarvisTokens.contains), i <= 1,
           tokens[..<i].allSatisfy({ silentLeaders.contains($0) || greetingLeaders.contains($0) }) {
            addressed = true
            tokens.removeFirst(i + 1)
        }
        if let last = tokens.last, jarvisTokens.contains(last) {
            addressed = true
            tokens.removeLast()
        }

        // 3. Leaders: "ok stop" → "stop"; "hey open the report" → "open report" (but "hey there" stays a greeting).
        if let first = tokens.first {
            if silentLeaders.contains(first), tokens.count > 1 { tokens.removeFirst() }
            else if greetingLeaders.contains(first), tokens.count > 2 { tokens.removeFirst() }
        }

        // 4. Polite lead-ins ("can you pause the task" → "pause task"), only if something follows.
        for lead in leadIns where tokens.count > lead.count && Array(tokens.prefix(lead.count)) == lead {
            tokens.removeFirst(lead.count)
            break
        }

        return NormalizedInput(original: raw, text: tokens.joined(separator: " "), tokens: tokens,
                               addressedJarvis: addressed, language: language)
    }
}
