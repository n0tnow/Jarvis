import Foundation
import CryptoKit

/// Data minimisation for anything that reaches the audit trail. Prompts and outputs are NEVER stored whole: only a
/// SHA-256, the length, and (unless the task is sensitive) a short redacted excerpt.
enum Redactor {
    private static let patterns: [String] = [
        "sk-[A-Za-z0-9_\\-]{16,}",                                   // provider-style secret keys
        "(?i)bearer\\s+[A-Za-z0-9._~+/=\\-]{16,}",
        "gh[pousr]_[A-Za-z0-9]{20,}",                                // GitHub tokens
        "xox[abprs]-[A-Za-z0-9\\-]{10,}",                            // Slack tokens
        "AKIA[0-9A-Z]{16}",                                          // AWS access key id
        "eyJ[A-Za-z0-9_\\-]{8,}\\.[A-Za-z0-9_\\-]{8,}\\.[A-Za-z0-9_\\-]{8,}",   // JWT
        "-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)",
        "(?i)\\b(api[_-]?key|access[_-]?token|auth[_-]?token|secret|passw(or)?d|passwd|token)\\b\\s*[:=]\\s*[\"']?[^\\s\"']{4,}",
        "[A-Za-z0-9+/_\\-]{40,}={0,2}",                              // any long opaque blob
    ]
    private static let compiled: [NSRegularExpression] = patterns.compactMap { try? NSRegularExpression(pattern: $0) }

    static let mask = "[REDACTED]"

    static func redact(_ text: String) -> String {
        var out = text
        for re in compiled {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: mask)
        }
        return out
    }

    /// True if the text contains something that looks like a credential.
    static func containsSecret(_ text: String) -> Bool {
        compiled.contains { $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
    }

    /// Redacted, whitespace-collapsed, truncated excerpt (empty when `allowExcerpt` is false).
    static func excerpt(_ text: String, max: Int = 120, allowExcerpt: Bool = true) -> String {
        guard allowExcerpt else { return "" }
        let flat = redact(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count <= max ? flat : String(flat.prefix(max)) + "…"
    }

    static func sha256(_ text: String) -> String { sha256(Data(text.utf8)) }
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
