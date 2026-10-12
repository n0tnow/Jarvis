import Foundation

/// Which language a piece of text is written in (drives the TTS voice and the wording of spoken notes).
/// Deterministic and conservative: a Turkish-only letter wins at once; otherwise function words decide; ties fall back to `fallback`.
enum LanguageGuess {
    private static let turkishLetters = CharacterSet(charactersIn: "çğıöşüÇĞİÖŞÜ")
    private static let turkishWords: Set<String> = [
        "ve", "bir", "bu", "şu", "için", "ile", "da", "de", "mi", "mı", "mu", "mü", "ne", "değil", "var", "yok", "gibi", "ama", "çok", "olarak",
        "tamam", "evet", "hayır", "görev", "görevi", "hata", "testleri", "geçti", "başarılı", "bağlı", "çalışıyor", "tamamlandı", "bana", "sana",
        "ben", "sen", "biz", "siz", "onlar", "ki", "daha", "en", "her", "hiç", "şimdi", "sonra", "önce", "kadar", "ise", "veya", "yani",
        "tamamladım", "başladım", "kontrol", "gerekiyor", "onay", "ekranda", "adım", "adımı", "ayrıca", "henüz",
    ]
    private static let englishWords: Set<String> = [
        "the", "and", "is", "are", "was", "were", "of", "to", "in", "for", "with", "that", "this", "not", "no", "has", "have", "been", "it",
        "on", "at", "by", "from", "or", "as", "an", "be", "will", "can", "you", "your", "i", "we", "they", "which", "but", "all", "any",
        "tests", "passed", "task", "error", "errors", "yes", "ok", "done", "please", "there", "what", "how", "when", "if", "so", "than",
    ]

    static func guess(_ text: String, fallback: VoiceLanguage = .english) -> VoiceLanguage {
        if text.rangeOfCharacter(from: turkishLetters) != nil { return .turkish }
        var tr = 0, en = 0
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" }) {
            let w = String(raw)
            if turkishWords.contains(w) { tr += 1 }
            if englishWords.contains(w) { en += 1 }
        }
        if tr > en { return .turkish }
        if en > tr { return .english }
        return fallback == .auto ? .english : fallback
    }
}

/// Deterministic speech rendering: UI text → text that sounds right when read aloud. PRESENTATION ONLY — it never adds facts,
/// never calls a model, never folds Turkish letters. Markdown syntax, links, long code, paths and symbols are made speakable.
enum SpeechRenderer {
    static func render(_ raw: String, language: VoiceLanguage) -> String {
        let tr = language == .turkish
        var s = raw

        // Control characters (keep newlines → spaces later), zero-width marks, emoji/pictographs and dingbats.
        s = String(s.unicodeScalars.filter { u in
            if u == "\n" || u == "\t" { return true }
            if u.value < 0x20 || u.value == 0x7F { return false }
            if (0x200B...0x200F).contains(u.value) || u.value == 0xFEFF { return false }
            if u.properties.isEmojiPresentation { return false }
            if (0x2600...0x27BF).contains(u.value) || (0x1F000...0x1FAFF).contains(u.value) || u.value == 0xFE0F { return false }
            return true
        })

        // Markdown links / images → their text; HTML-ish autolinks.
        s = sub(s, #"!\[([^\]]*)\]\([^)]*\)"#, "$1")
        s = sub(s, #"\[([^\]]+)\]\([^)]*\)"#, "$1")
        // Bare URLs → the host only ("link" wording would need a language; the host is what a listener can use).
        s = replaceMatches(s, #"https?://[^\s)>\]]+"#) { url in hostOf(url) }
        // File-system paths with 3+ components → the last component (a listener cannot use /Users/x/y/z/File.swift).
        s = replaceMatches(s, #"(?<![\w.])(?:~|\.{1,2})?(?:/[\w.\-@+]+){3,}"#) { path in
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? path : name
        }
        // Inline code: short identifiers stay (BoxCollider, Play Mode), long snippets become a note.
        s = replaceMatches(s, #"`([^`\n]+)`"#) { m in
            let inner = String(m.dropFirst().dropLast())
            let simple = inner.count <= 32 && !inner.contains("{") && !inner.contains(";") && !inner.contains("=>")
            return simple ? inner : (tr ? "kod" : "code")
        }
        s = s.replacingOccurrences(of: "`", with: "")

        // Per-line markdown structure.
        var lines: [String] = []
        for rawLine in s.components(separatedBy: "\n") {
            var l = rawLine.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { continue }
            if l.hasPrefix("Sources:") || l.hasPrefix("Kaynaklar:") { continue }          // provenance is shown, never read aloud (V0.10)
            if l.hasPrefix("|") {                                              // table row → cells joined; separator rows dropped
                if l.contains("---") && l.allSatisfy({ "|-: ".contains($0) }) { continue }
                l = l.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
            }
            l = sub(l, #"^#{1,6}\s+"#, "")                                    // headings
            l = sub(l, #"^>+\s*"#, "")                                         // blockquote
            l = sub(l, #"^(?:[-*+•]|\d{1,3}[.)])\s+"#, "")                     // bullets / numbering
            l = sub(l, #"^[-*_]{3,}$"#, "")                                    // rules
            if !l.isEmpty { lines.append(l) }
        }
        s = lines.joined(separator: ". ").replacingOccurrences(of: "..", with: ".")
        // A line that already ended with punctuation must not get a second ". ": normalise ".. " / "!. " style joins.
        s = sub(s, #"([.!?…:;])\s*\.\s"#, "$1 ")

        // Emphasis markers (not snake_case identifiers, not multiplication).
        s = sub(s, #"\*\*\*(.+?)\*\*\*"#, "$1")
        s = sub(s, #"\*\*(.+?)\*\*"#, "$1")
        s = sub(s, #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, "$1")
        s = sub(s, #"(?<![A-Za-z0-9])__(.+?)__(?![A-Za-z0-9])"#, "$1")
        s = sub(s, #"(?<![A-Za-z0-9])_(?!\s)(.+?)(?<!\s)_(?![A-Za-z0-9])"#, "$1")
        s = sub(s, #"~~(.+?)~~"#, "$1")

        // Abbreviations and symbols that a synthesiser reads badly.
        s = sub(s, #"(?i)\be\.g\.,?"#, tr ? "örneğin" : "for example")
        s = sub(s, #"(?i)\bi\.e\.,?"#, tr ? "yani" : "that is")
        s = sub(s, #"(?i)\bvs\.?(?=\s)"#, tr ? "karşı" : "versus")
        s = sub(s, #"(\d+(?:[.,]\d+)?)\s?%"#, tr ? "yüzde $1" : "$1 percent")
        s = s.replacingOccurrences(of: "→", with: tr ? ", " : " to ")
        s = s.replacingOccurrences(of: "->", with: tr ? ", " : " to ")
        s = s.replacingOccurrences(of: "=>", with: tr ? ", " : " to ")
        s = s.replacingOccurrences(of: "≈", with: tr ? " yaklaşık " : " about ")
        s = s.replacingOccurrences(of: "×", with: tr ? " çarpı " : " times ")
        s = s.replacingOccurrences(of: " & ", with: tr ? " ve " : " and ")
        s = s.replacingOccurrences(of: "…", with: ".")
        s = s.replacingOccurrences(of: "—", with: ", ").replacingOccurrences(of: "–", with: ", ")
        s = s.replacingOccurrences(of: " · ", with: ", ").replacingOccurrences(of: "·", with: ", ")
        s = s.replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
        s = sub(s, #"[\[\]{}<>|\\^]"#, " ")
        s = sub(s, #"\s+"#, " ")
        s = sub(s, #"\s+([,.;:!?])"#, "$1")
        s = sub(s, #",\s*,"#, ",")
        return s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;")))
    }

    // MARK: Helpers

    private static func sub(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    private static func replaceMatches(_ s: String, _ pattern: String, _ transform: (String) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        var out = "", last = s.startIndex
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s) else { continue }
            out += s[last..<r.lowerBound] + transform(String(s[r]))
            last = r.upperBound
        }
        return out + s[last...]
    }

    private static func hostOf(_ url: String) -> String {
        guard let h = URLComponents(string: url)?.host else { return "" }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

/// How much of a response is read aloud. Long answers are NOT read out: a bounded leading portion is spoken (complete
/// sentences only), then one short note says the rest is on screen. No second model call, ever.
struct LongAnswerPolicy: Equatable, Sendable {
    /// Rendered characters spoken per response (≈ 35 s of speech at the default rate).
    var maxSpokenCharacters = 520
    var maxSpokenChunks = 7

    /// True once adding `next` would exceed the budget (the first chunk is always allowed).
    func wouldExceed(spokenCharacters: Int, spokenChunks: Int, next: Int) -> Bool {
        guard spokenChunks > 0 else { return false }
        return spokenChunks >= maxSpokenChunks || spokenCharacters + next > maxSpokenCharacters
    }

    static func screenNote(_ l: VoiceLanguage) -> String {
        l == .turkish ? "Yanıtın tamamı ekranda." : "The full answer is on screen."
    }
    static func codeNote(_ l: VoiceLanguage) -> String {
        l == .turkish ? "Kod ekranda." : "The code is on screen."
    }
    static func tableNote(_ l: VoiceLanguage) -> String {
        l == .turkish ? "Tablo ekranda." : "The table is on screen."
    }
}
