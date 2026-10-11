import Foundation
import CryptoKit

/// Data minimisation for anything that reaches the audit trail. Prompts and outputs are NEVER stored whole: only a
/// SHA-256, the length, and (unless the task is sensitive) a short redacted excerpt.
enum Redactor {
    static let mask = OutputSanitizer.mask

    /// Delegates to the ONE central sanitization layer (`OutputSanitizer`) — there are no scattered regex sets.
    static func redact(_ text: String) -> String { OutputSanitizer.sanitize(text) }

    /// True if the text contains something that looks like a credential (fail-closed: true if the engine fails).
    static func containsSecret(_ text: String) -> Bool { OutputSanitizer.containsSecret(text) }

    /// Redacted, whitespace-collapsed, truncated excerpt (empty when `allowExcerpt` is false).
    static func excerpt(_ text: String, max: Int = 120, allowExcerpt: Bool = true) -> String {
        guard allowExcerpt else { return "" }
        let flat = redact(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count <= max ? flat : String(flat.prefix(max)) + "…"
    }

    static func sha256(_ text: String) -> String { sha256(Data(text.utf8)) }
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
