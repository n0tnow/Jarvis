import Foundation

// MARK: - JSON value (Sendable, for JSON-LD / API payloads)

enum JSONValue: Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(any: Any?) {
        switch any {
        case nil: self = .null
        case is NSNull: self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSONValue(any: $0) })
        case let o as [String: Any]: self = .object(o.mapValues { JSONValue(any: $0) })
        default: self = .null
        }
    }
    static func parse(_ data: Data) -> JSONValue? { (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])).map { JSONValue(any: $0) } }
    static func parse(_ text: String) -> JSONValue? { parse(Data(text.utf8)) }

    var string: String? { if case .string(let s) = self { return s }; if case .number(let n) = self { return n == n.rounded() ? String(Int(n)) : String(n) }; return nil }
    var double: Double? { if case .number(let n) = self { return n }; if case .string(let s) = self { return Double(s.trimmingCharacters(in: .whitespaces)) }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    subscript(key: String) -> JSONValue? { object?[key] }
    subscript(index: Int) -> JSONValue? { guard let a = array, a.indices.contains(index) else { return nil }; return a[index] }
    /// "a.b.c" path lookup (objects only).
    func at(_ path: String) -> JSONValue? { path.split(separator: ".").reduce(Optional(self)) { $0?[String($1)] } }
}

// MARK: - Extraction result

struct PageLink: Equatable, Sendable { var href: String; var text: String }

struct ExtractedPage: Sendable {
    var title = ""
    var text = ""
    var headings: [String] = []
    var meta: [String: String] = [:]          // lower-cased name/property → content
    var canonical: String?
    var language: String?
    var jsonLD: [JSONValue] = []
    var links: [PageLink] = []
    var scriptCount = 0
    var hasPasswordField = false
    var truncated = false

    var isLoginWall: Bool {
        let lower = text.lowercased()
        let cues = ["sign in to continue", "log in to continue", "please log in", "please sign in", "you must be logged in", "login required", "sign in to view", "anmelden, um"]
        return (hasPasswordField && text.count < 1_500) || (text.count < 1_200 && cues.contains { lower.contains($0) })
    }
    var isCaptchaChallenge: Bool {
        let lower = text.lowercased() + " " + (meta["robots"] ?? "")
        let cues = ["captcha", "verify you are human", "verify you are not a robot", "unusual traffic", "checking your browser", "attention required", "are you a robot", "cf-challenge", "just a moment..."]
        return text.count < 2_500 && cues.contains { lower.contains($0) } || scriptHints.contains("hcaptcha") || scriptHints.contains("recaptcha")
    }
    /// A near-empty shell whose content is produced by JavaScript → worth a rendered (browser) retrieval.
    var looksJavaScriptRendered: Bool {
        let lower = text.lowercased()
        return (text.count < 400 && scriptCount >= 3) || lower.contains("enable javascript") || lower.contains("javascript is required") || lower.contains("you need to enable javascript")
    }
    fileprivate var scriptHints = Set<String>()
}

// MARK: - Tolerant HTML reader (no WebKit, no regex over megabytes)

enum HTMLExtractor {
    static let maxInputBytes = 2_500_000
    private static let skipContent: Set<String> = ["script", "style", "noscript", "template", "svg", "iframe", "canvas", "object", "embed", "nav", "footer", "aside", "form", "select", "button", "dialog"]
    private static let blockTags: Set<String> = ["p", "div", "section", "article", "main", "li", "ul", "ol", "tr", "table", "br", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "blockquote", "dd", "dt", "dl", "figure", "figcaption", "hr", "header", "details", "summary"]
    private static let voidTags: Set<String> = ["br", "hr", "img", "input", "meta", "link", "area", "base", "col", "embed", "source", "track", "wbr"]

    static func extract(_ data: Data, maxChars: Int = 80_000, baseURL: URL? = nil) -> ExtractedPage {
        let bytes = Array(data.prefix(maxInputBytes))
        var page = ExtractedPage()
        var out: [UInt8] = []; out.reserveCapacity(min(bytes.count, maxChars * 2))
        var i = 0, skipDepth = 0, skipName = ""
        var inTitle = false, titleBytes: [UInt8] = []
        var headingTag: String?; var headingBytes: [UInt8] = []
        var anchor: (href: String, text: [UInt8])?
        let n = bytes.count

        func lower(_ s: ArraySlice<UInt8>) -> String { String(decoding: s, as: UTF8.self).lowercased() }
        func appendText(_ b: UInt8) {
            if inTitle { titleBytes.append(b) }
            if headingTag != nil { headingBytes.append(b) }
            if anchor != nil { anchor!.text.append(b) }
            if skipDepth == 0, !inTitle { out.append(b) }
        }
        func newline() { if skipDepth == 0, out.last != 10 { out.append(10) } }

        while i < n {
            if out.count > maxChars * 2 { page.truncated = true; break }
            let b = bytes[i]
            let nextIsTag = b == 0x3C && i + 1 < n && (bytes[i + 1] == 0x2F || bytes[i + 1] == 0x21 || bytes[i + 1] == 0x3F || (bytes[i + 1] | 0x20) >= 0x61 && (bytes[i + 1] | 0x20) <= 0x7A)
            if !nextIsTag {                                      // text (a lone "<" in prose is text, not a tag)
                if skipDepth == 0 || inTitle || headingTag != nil { appendText(b) }
                i += 1; continue
            }
            // comment
            if i + 3 < n, bytes[i + 1] == 0x21, bytes[i + 2] == 0x2D, bytes[i + 3] == 0x2D {
                var j = i + 4
                while j + 2 < n, !(bytes[j] == 0x2D && bytes[j + 1] == 0x2D && bytes[j + 2] == 0x3E) { j += 1 }
                i = min(n, j + 3); continue
            }
            // find the end of the tag, respecting quotes
            var j = i + 1; var quote: UInt8 = 0
            while j < n {
                let c = bytes[j]
                if quote != 0 { if c == quote { quote = 0 } } else if c == 0x22 || c == 0x27 { quote = c } else if c == 0x3E { break }
                j += 1
            }
            guard j < n else { break }
            let inner = bytes[(i + 1)..<j]
            i = j + 1
            guard let first = inner.first else { continue }
            if first == 0x21 || first == 0x3F { continue }       // <!doctype>, <?xml
            let closing = first == 0x2F
            let body = closing ? inner.dropFirst() : inner
            let nameEnd = body.firstIndex(where: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D || $0 == 0x2F }) ?? body.endIndex
            let name = lower(body[body.startIndex..<nameEnd])
            let attrs = parseAttributes(body[nameEnd...])

            if closing {
                if skipDepth > 0 {
                    if name == skipName { skipDepth -= 1; if skipDepth == 0 { skipName = "" } }
                    continue
                }
                if name == "title" { inTitle = false; page.title = decodeEntities(String(decoding: titleBytes, as: UTF8.self)).collapsedWhitespace }
                if name == headingTag { let h = decodeEntities(String(decoding: headingBytes, as: UTF8.self)).collapsedWhitespace; if !h.isEmpty, page.headings.count < 60 { page.headings.append(String(h.prefix(200))) }; headingTag = nil; headingBytes = [] }
                if name == "a", let a = anchor { let t = decodeEntities(String(decoding: a.text, as: UTF8.self)).collapsedWhitespace; if page.links.count < 400 { page.links.append(PageLink(href: a.href, text: String(t.prefix(160)))) }; anchor = nil }
                if blockTags.contains(name) { newline() }
                continue
            }
            if skipDepth > 0 {
                if name == skipName, !voidTags.contains(name) { skipDepth += 1 }
                continue
            }
            switch name {
            case "title": inTitle = true; titleBytes = []
            case "meta":
                let key = (attrs["name"] ?? attrs["property"] ?? attrs["itemprop"] ?? attrs["http-equiv"])?.lowercased()
                if let key, let content = attrs["content"], page.meta[key] == nil { page.meta[key] = decodeEntities(String(content.prefix(600))) }
            case "link":
                if (attrs["rel"] ?? "").lowercased().contains("canonical"), let href = attrs["href"] { page.canonical = href }
            case "html": if let l = attrs["lang"] { page.language = l }
            case "input": if (attrs["type"] ?? "").lowercased() == "password" { page.hasPasswordField = true }
            case "script":
                page.scriptCount += 1
                let src = (attrs["src"] ?? "").lowercased()
                for hint in ["hcaptcha", "recaptcha", "challenges.cloudflare"] where src.contains(hint) { page.scriptHints.insert(hint == "challenges.cloudflare" ? "recaptcha" : hint) }
                // the JSON-LD / __NEXT_DATA__ body is the one script we read
                var k = i
                while k + 8 < n, !(bytes[k] == 0x3C && bytes[k + 1] == 0x2F && lower(bytes[(k + 2)..<min(n, k + 8)]) == "script") { k += 1 }
                let type = (attrs["type"] ?? "").lowercased()
                if type == "application/ld+json", k > i, k - i < 400_000, let v = JSONValue.parse(Data(bytes[i..<k])) { page.jsonLD.append(contentsOf: flatten(v)) }
                i = min(n, k)       // the </script> tag itself is consumed next iteration
                continue
            default: break
            }
            if skipContent.contains(name), !voidTags.contains(name) { skipDepth = 1; skipName = name; continue }
            if /* heading */ ["h1", "h2", "h3", "h4"].contains(name) { headingTag = name; headingBytes = [] }
            if name == "a", let href = attrs["href"], !href.hasPrefix("#"), !href.lowercased().hasPrefix("javascript:") { anchor = (href, []) }
            if blockTags.contains(name) { newline() }
            if name == "li" { out.append(contentsOf: Array("• ".utf8)) }
        }
        if page.title.isEmpty, let t = page.meta["og:title"] ?? page.meta["twitter:title"] { page.title = t }
        let text = decodeEntities(String(decoding: out, as: UTF8.self))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.collapsedWhitespace }.filter { !$0.isEmpty }
        var joined = lines.joined(separator: "\n")
        if joined.count > maxChars { joined = String(joined.prefix(maxChars)); page.truncated = true }
        page.text = joined
        if let base = baseURL {
            page.links = page.links.compactMap { l in URL(string: l.href, relativeTo: base).map { PageLink(href: $0.absoluteURL.absoluteString, text: l.text) } }
            if let c = page.canonical, let u = URL(string: c, relativeTo: base) { page.canonical = u.absoluteURL.absoluteString }
        }
        return page
    }

    private static func flatten(_ v: JSONValue) -> [JSONValue] {
        if let graph = v["@graph"]?.array { return graph.flatMap(flatten) }
        if let a = v.array { return a.flatMap(flatten) }
        return [v]
    }

    private static func parseAttributes(_ s: ArraySlice<UInt8>) -> [String: String] {
        var result: [String: String] = [:]
        let b = Array(s); var i = 0; let n = b.count
        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x2F }
        while i < n {
            while i < n, isSpace(b[i]) { i += 1 }
            let ns = i
            while i < n, !isSpace(b[i]), b[i] != 0x3D { i += 1 }
            let key = String(decoding: b[ns..<i], as: UTF8.self).lowercased()
            while i < n, isSpace(b[i]) { i += 1 }
            var value = ""
            if i < n, b[i] == 0x3D {
                i += 1
                while i < n, isSpace(b[i]) { i += 1 }
                if i < n, b[i] == 0x22 || b[i] == 0x27 {
                    let q = b[i]; i += 1; let vs = i
                    while i < n, b[i] != q { i += 1 }
                    value = String(decoding: b[vs..<min(i, n)], as: UTF8.self); i += 1
                } else {
                    let vs = i
                    while i < n, !(b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D) { i += 1 }
                    value = String(decoding: b[vs..<i], as: UTF8.self)
                }
            }
            if !key.isEmpty, result.count < 24 { result[key] = decodeEntities(value) }
        }
        return result
    }

    // MARK: Entities

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "copy": "©", "reg": "®", "trade": "™", "mdash": "—", "ndash": "–", "hellip": "…",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "laquo": "«", "raquo": "»", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "bull": "•", "middot": "·",
        "times": "×", "deg": "°", "eacute": "é", "egrave": "è", "uuml": "ü", "ouml": "ö", "auml": "ä", "szlig": "ß", "ccedil": "ç", "ntilde": "ñ", "iacute": "í", "oacute": "ó", "aacute": "á",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""; out.reserveCapacity(s.count)
        var idx = s.startIndex
        while idx < s.endIndex {
            let c = s[idx]
            if c == "&", let semi = s[idx...].prefix(12).firstIndex(of: ";") {
                let name = String(s[s.index(after: idx)..<semi])
                if name.hasPrefix("#") {
                    let digits = name.dropFirst()
                    let code: UInt32? = (digits.first == "x" || digits.first == "X") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
                    if let code, let u = Unicode.Scalar(code) { out.unicodeScalars.append(u); idx = s.index(after: semi); continue }
                }
                if let r = named[name] { out += r; idx = s.index(after: semi); continue }
            }
            out.append(c); idx = s.index(after: idx)
        }
        return out
    }
}

extension StringProtocol {
    var collapsedWhitespace: String { split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
}

// MARK: - Evidence helpers (grounding: an excerpt must really be in what the source said)

enum Grounding {
    /// Lower-cases, folds quotes/dashes/nbsp and collapses whitespace so a quotation can be matched against page text despite typography.
    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        for (a, b) in [("’", "'"), ("‘", "'"), ("“", "\""), ("”", "\""), ("–", "-"), ("—", "-"), ("\u{00a0}", " "), ("…", "...")] { t = t.replacingOccurrences(of: a, with: b) }
        return t.collapsedWhitespace
    }

    /// True when `excerpt` (after normalisation) occurs in `haystack` — the check that keeps model-invented "evidence" out of the report.
    static func isGrounded(_ excerpt: String, in haystack: String, minLength: Int = 8) -> Bool {
        let e = normalize(excerpt).trimmingCharacters(in: CharacterSet(charactersIn: ".…\"' "))
        guard e.count >= minLength else { return false }
        return normalize(haystack).contains(e)
    }

    /// A short excerpt around the first match of `pattern` (case-insensitive regex), cleaned and bounded.
    static func excerpt(in text: String, matching pattern: String, radius: Int = 110) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range, in: text) else { return nil }
        let lo = text.index(r.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let hi = text.index(r.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        return OutputSanitizer.sanitize(String(text[lo..<hi]).collapsedWhitespace).prefix(240).description
    }
}
