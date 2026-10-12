import Foundation
import CryptoKit

/// Language-light text helpers shared by dedupe, lexical retrieval and the safety gates. Turkish and English only; no model, no network.
enum MemoryText {
    static let stop: Set<String> = ["the", "a", "an", "of", "to", "in", "on", "and", "or", "is", "are", "was", "were", "be", "do", "does", "did", "we", "our", "us", "what", "why", "how", "which", "can", "could", "should",
                                    "it", "that", "this", "for", "with", "from", "by", "at", "as", "not", "no", "i", "you", "about", "have", "has", "had", "there", "their", "they", "will", "would", "when", "where", "who",
                                    "bir", "ve", "ile", "mi", "mu", "ne", "neden", "nasil", "hangi", "bu", "su", "o", "da", "de", "ki", "icin", "gibi", "ama", "veya", "daha", "cok", "ise", "var", "yok", "biz", "bizim", "miydi", "miyiz", "muydu"]

    static let negations: Set<String> = ["not", "never", "no", "without", "cannot", "dont", "doesnt", "isnt", "arent", "wont", "avoid", "degil", "asla", "hicbir", "yok", "yoktur", "olmaz", "etmez", "edilmez", "kalmaz", "sayilmaz"]

    static func fold(_ s: String) -> String { ResearchText.fold(s) }

    /// Raw folded words (letters/digits), stop words removed, NOT stemmed.
    static func words(_ s: String) -> [String] {
        fold(s).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 && !stop.contains($0) }
    }

    /// Crude stem shared by Turkish suffixes and English inflection: a 6-character prefix (calibrated on the benchmark corpus, `scripts/memory-ai/bench`).
    static func stem(_ w: String) -> String { w.count <= 6 ? w : String(w.prefix(6)) }

    static func tokens(_ s: String) -> [String] { words(s).map(stem) }

    static func numbers(_ s: String) -> Set<String> {
        Set(fold(s).split(whereSeparator: { !$0.isNumber && $0 != "." }).map(String.init).filter { $0.contains(where: \.isNumber) })
    }

    static func hasNegation(_ s: String) -> Bool {
        fold(s).split(whereSeparator: { !$0.isLetter }).contains { negations.contains(String($0)) }
    }

    static func jaccard(_ a: [String], _ b: [String]) -> Double {
        let x = Set(a), y = Set(b)
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    /// A stable hash of the MEANING-bearing tokens (order- and filler-insensitive): "Project uses URP" and "uses URP project" collide on purpose.
    static func canonicalHash(type: MemoryType, summary: String, key: String?, value: String?) -> String {
        let basis: String
        if let key { basis = "\(type.rawValue)|\(key)|\(fold(value ?? summary))" }
        else { basis = "\(type.rawValue)|" + Set(tokens(summary)).sorted().joined(separator: " ") + "|#" + numbers(summary).sorted().joined(separator: ",") + (hasNegation(summary) ? "|neg" : "") }
        return SHA256.hash(data: Data(basis.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Turkish if it has Turkish letters or several Turkish function words; otherwise English.
    static func guessLanguage(_ s: String) -> String {
        let l = s.lowercased()
        if l.contains(where: { "çğıöşü".contains($0) }) { return "tr" }
        let w = Set(l.split(whereSeparator: { !$0.isLetter }).map(String.init))
        let tr: Set<String> = ["ve", "bir", "icin", "neden", "nasil", "hangi", "mi", "bu", "ile", "gibi", "degil", "kullan", "karar"]
        return w.intersection(tr).count >= 2 ? "tr" : "en"
    }

    static func clip(_ s: String, _ n: Int) -> String {
        let flat = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count <= n ? flat : String(flat.prefix(n - 1)) + "…"
    }
}

/// The decision gates every candidate passes before it can become memory (DEC-105…110). Pure functions: the same input gives the same verdict.
enum MemoryGate {
    /// Statements that try to hand out authority. Neither a web page, a model nor an old conversation can store these — and an explicit user statement is
    /// refused too: memory is context, never policy (approvals come from the current approval records only).
    private static let authorityPatterns: [NSRegularExpression] = [
        "(user|you|they|jarvis)\\s+(always\\s+|already\\s+)?(approve[sd]?|authori[sz]e[sd]?|allow[s]?|trust[s]?|consent[s]?)\\b",
        "\\b(always|auto(matically)?)\\s+(approve|authori[sz]e)", "\\bnever\\s+(ask|prompt|confirm|require)\\w*\\s+(for\\s+)?(approval|confirmation|permission|consent)",
        "\\b(approve|approved)\\s+(all|any|every|purchases?|deletions?|downloads?|payments?|installs?)",
        "\\b(skip|bypass|disable|ignore|turn\\s+off|waive)\\s+(the\\s+)?(approval|confirmation|security|safety|policy|policies|sandbox|quarantine|checks?)",
        "\\b(purchases?|payments?|deletions?|downloads?)\\s+(are|is)\\s+(approved|allowed|pre-?approved|authori[sz]ed)",
        "trust(s|ed)?\\s+this\\s+(site|page|domain|source|website)",
        "(her\\s*zaman|otomatik(?:man)?)\\s+(onayla|onay\\s*ver)", "onay(?:ı|i)?\\s+(atla|kapat|gerekmez)", "(satın\\s*alma|silme)\\w*\\s+(onaylandı|serbest|izinli)"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func grantsAuthority(_ text: String) -> Bool {
        let r = NSRange(text.startIndex..., in: text)
        return authorityPatterns.contains { $0.firstMatchIfAny(in: text, range: r) }
    }

    private static let trivialStarts = ["hello", "hi ", "hi,", "thanks", "thank you", "ok ", "okay", "merhaba", "tesekkur", "teşekkür", "tamam", "evet", "hayir", "hayır"]
    private static let trivialPhrases = ["opened file", "ran test command", "test command ran", "command ran", "ran the tests", "clicked", "user said hello", "typed a message", "dosyayı açtı", "komut çalıştırıldı"]

    static func isTrivial(_ summary: String) -> Bool {
        let f = MemoryText.fold(summary).trimmingCharacters(in: .whitespacesAndNewlines)
        if f.count < 12 { return true }
        if trivialStarts.contains(where: { f.hasPrefix(MemoryText.fold($0)) }) && f.count < 40 { return true }
        if trivialPhrases.contains(where: { f.contains(MemoryText.fold($0)) }) { return true }
        return MemoryText.words(summary).count < 3
    }

    /// Does the text contain something shaped like a credential (the central sanitizer fails closed)?
    static func containsSecret(_ s: String) -> Bool { OutputSanitizer.containsSecret(s) }

    /// Instruction-shaped text aimed at an AI assistant (the V0.9 web scanner) — never durable memory.
    static func looksInjected(_ s: String) -> Bool { !UntrustedContent.scan(s).isEmpty }
}

private extension NSRegularExpression {
    func firstMatchIfAny(in s: String, range: NSRange) -> Bool { firstMatch(in: s, range: range) != nil }
}
