import Foundation

/// THE security boundary of the Agent Observatory (V0.3.2, DEC-029).
///
/// Everything a provider/process/tool prints is UNTRUSTED and POTENTIALLY SENSITIVE (a real V0.3.1 incident: an exploratory
/// OpenCode `credential.list` printed an API key). Therefore raw output crosses this boundary BEFORE it reaches anything
/// observable or durable — SwiftUI state, console buffers, activity events, SQLite, artifact files. UI-only redaction is not
/// accepted. If sanitization itself fails, the payload is WITHHELD (fail closed); the raw text is never used as a fallback.
protocol SanitizerEngine: Sendable {
    func redact(_ text: String) throws -> String
    func detectsSecret(_ text: String) throws -> Bool
}

struct SanitizerFailure: Error {}

/// Pattern engine: provider-style keys, tokens, headers, credential-like assignments and fields, key blocks, URL credentials.
struct PatternSanitizerEngine: SanitizerEngine {
    static let mask = "[REDACTED]"

    /// Field names whose VALUES are secrets wherever they appear (JSON fields, env-like assignments, query strings).
    static let sensitiveNames = "(?:api[_-]?key|apikey|access[_-]?token|refresh[_-]?token|id[_-]?token|auth[_-]?token|session[_-]?(?:token|secret|id)|client[_-]?secret|private[_-]?key|secret(?:[_-]?key)?|passw(?:or)?d|passwd|pwd|token|authorization|credentials?|cookie|bearer|signature|otp)"

    private static let patterns: [NSRegularExpression] = {
        let raw = [
            "-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)",
            "eyJ[A-Za-z0-9_\\-]{8,}\\.[A-Za-z0-9_\\-]{8,}\\.[A-Za-z0-9_\\-]{8,}",                          // JWT
            "\\bsk-[A-Za-z0-9_\\-]{12,}",                                                                // provider-style secret keys
            "\\bgh[pousr]_[A-Za-z0-9]{20,}|\\bgithub_pat_[A-Za-z0-9_]{20,}",
            "\\bxox[abprs]-[A-Za-z0-9\\-]{10,}",
            "\\bAKIA[0-9A-Z]{16}\\b|\\bASIA[0-9A-Z]{16}\\b",
            "\\bAIza[0-9A-Za-z_\\-]{30,}",
            "\\bya29\\.[0-9A-Za-z_\\-]{20,}|\\bglpat-[0-9A-Za-z_\\-]{16,}|\\bnpm_[A-Za-z0-9]{30,}|\\bhf_[A-Za-z0-9]{30,}",
            "(?i)\\b(?:proxy-)?authorization\\s*[:=]\\s*[^\\r\\n]+",                                      // whole header value
            "(?i)\\b(?:set-)?cookie\\s*:\\s*[^\\r\\n]+",
            "(?i)\\bbearer\\s+[A-Za-z0-9._~+/=\\-]{8,}",
            // JSON field-aware: "password": "…" / 'token': '…'
            "(?i)([\"'])\(sensitiveNames)\\1\\s*:\\s*([\"']).*?\\2",
            // env-like / assignment: PASSWORD=…, MY_SECRET_KEY: …, api_key = …
            "(?i)\\b[A-Z0-9_]*\(sensitiveNames)[A-Z0-9_]*\\b\\s*[:=]\\s*[\"']?[^\\s\"',;&]{3,}",
            // credentials in URLs and query strings
            "(?i)://[^/\\s:@]+:[^/\\s@]+@",
            "(?i)[?&]\(sensitiveNames)=[^&\\s]+",
            // any long opaque blob (base64/hex-looking), last so specific masks stay readable
            "(?=[A-Za-z+_\\-]*[0-9])[A-Za-z0-9+_\\-]{40,}={0,2}",         // needs a digit and no "/": file paths and long words stay readable
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    func redact(_ text: String) throws -> String {
        guard Self.patterns.count >= 15 else { throw SanitizerFailure() }       // a pattern failed to compile ⇒ fail closed
        var out = text
        for re in Self.patterns {
            let range = NSRange(out.startIndex..., in: out)
            // URL credentials keep the scheme/host readable: only the user:pass part is replaced.
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: re.pattern.hasPrefix("(?i)://") ? "://\(Self.mask)@" : Self.mask)
        }
        return out
    }

    func detectsSecret(_ text: String) throws -> Bool {
        guard Self.patterns.count >= 15 else { throw SanitizerFailure() }
        return Self.patterns.contains { $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
    }
}

/// Thread-safe holder so tests can inject a failing engine.
final class SanitizerHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: SanitizerEngine = PatternSanitizerEngine()
    func get() -> SanitizerEngine { lock.lock(); defer { lock.unlock() }; return engine }
    func set(_ e: SanitizerEngine) { lock.lock(); engine = e; lock.unlock() }
}

enum OutputSanitizer {
    static let holder = SanitizerHolder()
    static let mask = PatternSanitizerEngine.mask
    /// What replaces a payload when sanitization fails. The raw payload is NEVER shown or stored instead.
    static let withheld = "[output withheld: sanitizer failure]"

    /// Sanitizes free text. Never throws; never returns the input unchecked: on engine failure → `withheld`.
    static func sanitize(_ text: String) -> String {
        do { return try holder.get().redact(text) } catch { return withheld }
    }

    /// True if the text looks like it contains a credential. On engine failure: true (fail closed).
    static func containsSecret(_ text: String) -> Bool {
        (try? holder.get().detectsSecret(text)) ?? true
    }

    private static let sensitiveKey = try! NSRegularExpression(pattern: "^\(PatternSanitizerEngine.sensitiveNames)$", options: .caseInsensitive)
    private static func isSensitiveKey(_ k: String) -> Bool {
        sensitiveKey.firstMatch(in: k, range: NSRange(k.startIndex..., in: k)) != nil
            || k.lowercased().contains("secret") || k.lowercased().contains("token") || k.lowercased().contains("password") || k.lowercased().hasSuffix("key")
    }

    /// Field-aware sanitization of structured data: values of credential-like fields are masked wholesale, every other string
    /// still passes the text engine.
    static func sanitize(json value: Any) -> Any {
        switch value {
        case let d as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in d { out[k] = isSensitiveKey(k) ? mask : sanitize(json: v) }
            return out
        case let a as [Any]: return a.map { sanitize(json: $0) }
        case let s as String: return sanitize(s)
        default: return value
        }
    }

    /// For provider lines that may be JSON: parse → field-aware sanitize → compact re-serialization. Not JSON → text engine.
    static func sanitizeStructured(_ text: String) -> String {
        guard let data = text.data(using: .utf8), text.first == "{" || text.first == "[",
              let obj = try? JSONSerialization.jsonObject(with: data) else { return sanitize(text) }
        let safe = sanitize(json: obj)
        guard let out = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys, .withoutEscapingSlashes]) else { return withheld }
        return String(decoding: out, as: UTF8.self)       // every string value already passed the text engine; keys stay intact
    }
}

/// Incremental sanitizer for a token/text stream. The danger of chunked output is a secret SPLIT across chunks, so text is only
/// released at word boundaries, lines containing credential-ish words are held until the line ends (bounded), and key blocks are
/// suppressed until their end marker. Ordinary prose is released word by word (no visible latency).
final class StreamSanitizer: @unchecked Sendable {
    private var pending = ""
    private var suppressingKeyBlock = false
    private let maxHold: Int
    private let lock = NSLock()

    private static let risky = try! NSRegularExpression(pattern: "(?i)bearer|authorization|passw|secret|token|api[_-]?key|cookie|credential|private key|sk-|ghp_|github_pat|xox[abprs]|akia|asia[0-9A-Z]|aiza|eyj|hf_|npm_|glpat|ya29|://[^/\\s]+:", options: [])
    private static let dangling = try! NSRegularExpression(pattern: "(?i)\\b(password|passphrase|passwd|pwd|token|secret|api[_ -]?key|key|authorization|bearer|credentials?)\\b[\\s:=\"']*$")

    init(maxHold: Int = 4096) { self.maxHold = maxHold }

    private func matches(_ re: NSRegularExpression, _ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    /// Returns the text that is now safe to release (possibly empty).
    func feed(_ chunk: String) -> String {
        lock.lock(); defer { lock.unlock() }
        pending += chunk

        if suppressingKeyBlock {
            if let r = pending.range(of: "-----END ") {
                // drop everything through the end of the END line
                let rest = pending[r.lowerBound...]
                if let nl = rest.firstIndex(of: "\n") { pending = String(rest[rest.index(after: nl)...]) } else { pending = ""; return "" }
                suppressingKeyBlock = false
                return OutputSanitizer.mask + "\n" + drain()
            }
            pending = String(pending.suffix(64))          // keep only enough to spot the END marker
            return ""
        }
        if let begin = pending.range(of: "-----BEGIN ") {
            let before = String(pending[..<begin.lowerBound])
            pending = String(pending[begin.lowerBound...])
            if let end = pending.range(of: "-----END ") {
                let rest = pending[end.lowerBound...]
                pending = rest.firstIndex(of: "\n").map { String(rest[rest.index(after: $0)...]) } ?? ""
                return OutputSanitizer.sanitize(before) + OutputSanitizer.mask + "\n" + drain()
            }
            suppressingKeyBlock = true
            pending = String(pending.suffix(64))
            return OutputSanitizer.sanitize(before)
        }
        return drain()
    }

    private func drain() -> String {
        guard !pending.isEmpty else { return "" }
        let lastNewline = pending.lastIndex(of: "\n")
        let currentLineStart = lastNewline.map { pending.index(after: $0) } ?? pending.startIndex
        let currentLine = String(pending[currentLineStart...])
        var cut: String.Index

        if matches(Self.risky, currentLine) && currentLine.count < maxHold {
            // A credential-ish word is on the line being written: hold the WHOLE line until it is complete.
            cut = currentLineStart
        } else if let ws = pending.lastIndex(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            cut = pending.index(after: ws)
            if currentLine.count >= maxHold { cut = pending.index(pending.endIndex, offsetBy: -min(160, pending.count)) }
        } else if pending.count > 256 {
            cut = pending.index(pending.endIndex, offsetBy: -128)            // one very long unbroken token: keep a tail window
        } else { return "" }

        // A complete line that ends with a credential word and no value ("password:") is held until its value line arrives.
        if cut > pending.startIndex {
            let head = pending[..<cut]
            let lines = head.split(separator: "\n", omittingEmptySubsequences: false)
            if let last = lines.last(where: { !$0.isEmpty }), matches(Self.dangling, String(last)), head.hasSuffix("\n") {
                if let idx = head.range(of: String(last), options: .backwards)?.lowerBound { cut = idx }
            }
        }
        guard cut > pending.startIndex else { return "" }
        let out = String(pending[..<cut])
        pending = String(pending[cut...])
        return OutputSanitizer.sanitize(out)
    }

    /// End of stream: release (sanitized) whatever is still held.
    func flush() -> String {
        lock.lock(); defer { lock.unlock() }
        defer { pending = ""; suppressingKeyBlock = false }
        if suppressingKeyBlock { return OutputSanitizer.mask }
        return OutputSanitizer.sanitize(pending)
    }

    var heldCharacters: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
}
