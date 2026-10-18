import Foundation

// Lives beside the transport (not in the decision layer): it NAMES credential words in order to refuse sentences that carry one, which the decision layer's own guard (no key-shaped text) must not have to tolerate.

// MARK: Privacy (what may leave the machine at all)

private func wordList(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }

enum JevPrivacyFilter {
    private static let credentialWords = try! NSRegularExpression(pattern: #"(?:password|passwd|parola|parolam|sifre|sifrem|şifre|şifrem|secret|token|api[ _-]?key|apikey|anahtar|authorization|bearer|credential)\b[^\n]{0,24}?[:=\s]\s*['"]?([^\s'",;]{6,})"#, options: [.caseInsensitive])
    private static let email = try! NSRegularExpression(pattern: #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}[.,;:!?]?$"#)
    private static let ipv4 = try! NSRegularExpression(pattern: #"^(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?[.,;:!?]?$"#)

    private static let fileExtensions: Set<String> = Set(wordList("cs swift json py js ts md txt pdf png jpg jpeg unity prefab sqlite db env pem key p12 yml yaml plist sh zip csv log xcodeproj asmdef meta mat shader"))
    /// "Player.cs", "secrets.env", "notes.txt": a token that ends in a known file extension (a sentence about a file does not need the file's name to be classified).
    static func looksLikeFileName(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'()[]")).lowercased()
        guard let dot = t.lastIndex(of: "."), dot != t.startIndex else { return false }
        let ext = String(t[t.index(after: dot)...])
        return fileExtensions.contains(ext) && t.distance(from: t.startIndex, to: dot) >= 1
    }
    static func isEmail(_ token: String) -> Bool { email.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) != nil }
    static func isNetworkAddress(_ token: String) -> Bool { ipv4.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) != nil }

    /// A sentence that carries a credential-SHAPED value is not a classification job and is never sent: a credential word followed by a value (password is hunter42x, token: abc123…), an opaque 24+ character
    /// token with letters and digits, an authorization header. ("Bu API key'i nereye koyacağım?" names a credential but carries none — it may be sent.) Over-refusal costs one request; a leak cannot be undone.
    static func looksSecret(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        if let m = credentialWords.firstMatch(in: text, range: range), m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) {
            let value = String(text[r])
            let hasDigit = value.contains(where: \.isNumber), hasLetter = value.contains(where: \.isLetter)
            // a plain word after "password" ("password manager", "token nedir") is not a value: it must look like one (digits and letters, or long)
            if (hasDigit && hasLetter) || value.count >= 14 { return true }
        }
        for raw in text.split(whereSeparator: { $0.isWhitespace }) {
            let t = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'()[]"))
            guard t.count >= 24, !t.contains("/"), !t.contains("://") else { continue }
            if t.allSatisfy({ $0.isLetter || $0.isNumber || "_-+=".contains($0) }), t.contains(where: \.isNumber), t.contains(where: \.isLetter) { return true }
        }
        return false
    }
}
