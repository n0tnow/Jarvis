import Foundation

/// One unit of a streamed response that is worth speaking (or deliberately not speaking).
enum SpeechPiece: Equatable, Sendable {
    case text(String)       // a complete, stable sentence/phrase of RAW (UI) text — rendering happens later
    case codeOmitted        // a fenced code block was skipped
    case tableOmitted       // a markdown table was skipped
}

/// Deterministic streaming chunker: turns a stream of response text into stable, speakable phrases.
///
///  • Emits only text that can no longer change: a sentence ends at . ! ? … followed by whitespace (a terminator at the very end of
///    the buffer is ambiguous — "3." might become "3.14" — so it waits for more text or the end of the stream).
///  • Never splits inside inline code, URLs, decimals, version numbers, file names or common abbreviations (EN + TR).
///  • Avoids tiny fragments (merges short sentences), except the very first phrase, which may be short so speech starts early.
///  • Splits an over-long sentence at a clause boundary (, ; : —), then at a space — bounded by `maxCharacters`.
///  • Fenced code blocks and tables are never spoken character by character: they surface as `.codeOmitted` / `.tableOmitted`.
///  • Headings and list items are their own phrases; blank lines end a paragraph.
///  • `finish()` flushes whatever remains, however short.
struct SpeechChunker: Sendable {
    var firstMinCharacters = 4
    var minCharacters = 24
    var maxCharacters = 220
    var hardMaxCharacters = 320

    private var inbox = ""                  // unconsumed raw text (always starts at a line start unless `midLine`)
    private var carry = ""                  // plain text of the current paragraph, not yet emitted
    private var midLine = false
    private var needsSeparator = false      // a paragraph continues on a new line → join with a space
    private var structuralUnit = false      // the current line is a heading/list item: it ends at the newline
    private var inFence = false
    private var inTable = false
    private var emittedAny = false
    private(set) var pieces = 0

    private static let abbreviations: Set<String> = [
        "e.g", "i.e", "etc", "vs", "dr", "mr", "mrs", "ms", "prof", "st", "no", "fig", "approx", "inc", "ltd", "jr", "sr", "cf", "al", "ex",
        "vb", "vs", "örn", "sn", "dk", "yy", "sk", "bkz", "dr", "doç", "yrd", "uzm", "av", "mah", "cad", "no", "tel", "org",
    ]

    init() {}

    // MARK: Public

    mutating func push(_ delta: String) -> [SpeechPiece] {
        inbox += delta
        return drain(final: false)
    }

    mutating func finish() -> [SpeechPiece] {
        var out = drain(final: true)
        out += flushCarry(paragraphEnd: true)
        inFence = false; inTable = false
        return out
    }

    // MARK: Line machine

    private mutating func drain(final: Bool) -> [SpeechPiece] {
        var out: [SpeechPiece] = []
        while !inbox.isEmpty {
            let nl = inbox.firstIndex(of: "\n")
            if inFence {
                guard let nl else { if final { inbox = "" }; break }                    // wait for the whole line (closing fence?)
                let line = inbox[..<nl].trimmingCharacters(in: .whitespaces)
                inbox.removeSubrange(...nl)
                if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence = false }
                continue
            }
            if !midLine {
                let head = nl.map { String(inbox[..<$0]) } ?? inbox
                let trimmed = head.trimmingCharacters(in: .whitespaces)
                if nl == nil && !final && Self.isUndecided(trimmed) { break }           // "-", "1", "`", "|" … need more characters
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    guard nl != nil || final else { break }
                    out += flushCarry(paragraphEnd: true)
                    out.append(.codeOmitted)
                    inFence = true; inTable = false
                    inbox.removeSubrange(inbox.startIndex..<(nl.map { inbox.index(after: $0) } ?? inbox.endIndex))
                    continue
                }
                if trimmed.hasPrefix("|") {
                    guard nl != nil || final else { break }
                    out += flushCarry(paragraphEnd: true)
                    if !inTable { out.append(.tableOmitted); inTable = true }
                    inbox.removeSubrange(inbox.startIndex..<(nl.map { inbox.index(after: $0) } ?? inbox.endIndex))
                    continue
                }
                inTable = false
                if nl != nil && trimmed.isEmpty {                                      // blank line = paragraph end
                    out += flushCarry(paragraphEnd: true)
                    inbox.removeSubrange(...nl!)
                    continue
                }
                if let marker = Self.structuralMarker(in: head) {
                    out += flushCarry(paragraphEnd: true)
                    inbox.removeFirst(marker)
                    structuralUnit = true
                } else {
                    structuralUnit = false
                    if !carry.isEmpty { needsSeparator = true }
                }
                midLine = true
                continue
            }
            // Mid-line: move text into the carry, up to the newline.
            let upTo = nl ?? inbox.endIndex
            let text = String(inbox[..<upTo])
            if !text.isEmpty {
                if needsSeparator { carry += " "; needsSeparator = false }
                carry += text
            }
            inbox.removeSubrange(inbox.startIndex..<upTo)
            if nl != nil {
                inbox.removeFirst()
                midLine = false
                if structuralUnit { out += flushCarry(paragraphEnd: true); structuralUnit = false }
            }
            out += extract(final: false)
        }
        if final { out += extract(final: false) }
        return out
    }

    /// Prefixes that could still become a fence / table / list marker once more characters arrive.
    private static func isUndecided(_ s: String) -> Bool {
        if s.isEmpty { return true }
        if s.count <= 3, s.allSatisfy({ "`~".contains($0) }) { return true }
        if s.count <= 3, s.allSatisfy({ $0.isNumber || $0 == "." || $0 == ")" }) { return true }        // "1", "12.", "3)"
        if s.count == 1, "-*+•#>|".contains(s) { return true }
        if s.allSatisfy({ $0 == "#" }), s.count <= 6 { return true }
        return false
    }

    /// Length in characters of a heading / bullet / numbering / quote marker at the start of `line` (0-prefix ⇒ nil).
    private static func structuralMarker(in line: String) -> Int? {
        let chars = Array(line)
        var i = 0
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        let start = i
        guard i < chars.count else { return nil }
        if chars[i] == "#" {
            while i < chars.count, chars[i] == "#" { i += 1 }
            guard i - start <= 6, i < chars.count, chars[i] == " " else { return nil }
            return i + 1
        }
        if chars[i] == ">" { return i + (i + 1 < chars.count && chars[i + 1] == " " ? 2 : 1) }
        if "-*+•".contains(chars[i]), i + 1 < chars.count, chars[i + 1] == " " { return i + 2 }
        if chars[i].isNumber {
            var j = i
            while j < chars.count, chars[j].isNumber, j - i < 3 { j += 1 }
            if j < chars.count, chars[j] == "." || chars[j] == ")", j + 1 < chars.count, chars[j + 1] == " " { return j + 2 }
        }
        return nil
    }

    // MARK: Sentences

    private mutating func flushCarry(paragraphEnd: Bool) -> [SpeechPiece] {
        guard paragraphEnd else { return [] }
        var out = extract(final: true)
        needsSeparator = false
        if !out.isEmpty { emittedAny = true }
        out.removeAll { if case .text(let t) = $0 { return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } else { return false } }
        return out
    }

    /// Splits complete sentences off `carry`. `final` also releases the unterminated tail.
    private mutating func extract(final: Bool) -> [SpeechPiece] {
        var out: [SpeechPiece] = []
        while true {
            let limit = emittedAny || !out.isEmpty ? minCharacters : firstMinCharacters
            guard let cut = nextBoundary(in: carry, minLength: limit, final: final) else { break }
            let sentence = String(carry[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            carry = String(carry[cut...].drop(while: { $0 == " " || $0 == "\t" }))            // only LEADING blanks: a trailing space belongs to the next phrase
            if !sentence.isEmpty { out.append(.text(sentence)); pieces += 1 }
            if carry.isEmpty { break }
        }
        if final, !carry.isEmpty {
            let tail = carry.trimmingCharacters(in: .whitespacesAndNewlines)
            carry = ""
            if !tail.isEmpty { out.append(.text(tail)); pieces += 1 }
        }
        if !out.isEmpty { emittedAny = true }
        return out
    }

    /// The index just after the first usable boundary, or nil when the text is not yet stable enough to speak.
    private func nextBoundary(in text: String, minLength: Int, final: Bool) -> String.Index? {
        guard !text.isEmpty else { return nil }
        var inCode = false
        var i = text.startIndex
        var lastClause: String.Index?
        var count = 0
        while i < text.endIndex {
            let c = text[i]
            if c == "`" { inCode.toggle() }
            count += 1
            let next = text.index(after: i)
            if !inCode {
                if ",;:—–".contains(c), count >= minCharacters / 2 { lastClause = next }
                if ".!?…".contains(c) {
                    // include trailing closers: ." )" etc.
                    var end = next
                    while end < text.endIndex, "\"'”’)]»".contains(text[end]) { end = text.index(after: end) }
                    // also swallow a run of terminators ("?!", "...")
                    while end < text.endIndex, ".!?…".contains(text[end]) { end = text.index(after: end) }
                    let followed = end < text.endIndex ? text[end].isWhitespace : false
                    let atEndOfFinal = end == text.endIndex && final
                    if (followed || atEndOfFinal), !isAbbreviationOrDecimal(text, dot: i), text.distance(from: text.startIndex, to: end) >= minLength {
                        return end
                    }
                    if end > next { i = text.index(before: end); count = text.distance(from: text.startIndex, to: end) }
                }
            }
            // Over-long without a sentence end: split at the last clause boundary, else at a space.
            if count >= maxCharacters {
                if let lastClause, text.distance(from: text.startIndex, to: lastClause) >= minLength { return lastClause }
                if count >= hardMaxCharacters, let sp = text[..<next].lastIndex(of: " ") { return text.index(after: sp) }
                if count >= hardMaxCharacters { return next }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// "e.g.", "Dr.", "J.", "3.14", "v0.7", "main.swift" are not sentence ends.
    private func isAbbreviationOrDecimal(_ text: String, dot: String.Index) -> Bool {
        guard text[dot] == "." else { return false }
        let before = text[..<dot]
        // word before the dot (letters, digits and inner dots)
        var start = before.endIndex
        while start > before.startIndex {
            let p = before.index(before: start)
            let ch = before[p]
            if ch.isLetter || ch.isNumber || ch == "." || ch == "'" { start = p } else { break }
        }
        let word = String(before[start...]).lowercased()
        if word.isEmpty { return false }
        if Self.abbreviations.contains(word) { return true }
        if word.count == 1, word.first!.isLetter, let w = before[start...].first, w.isUppercase {            // an initial: "J. Smith"
            let after = text[text.index(after: dot)...].drop(while: { $0 == " " })
            return after.first?.isUppercase ?? false
        }
        if word.allSatisfy({ $0.isNumber }) {                                                                   // "step 3. Then" is a sentence end, "3.14" is not
            let after = text.index(after: dot)
            return after < text.endIndex && text[after].isNumber
        }
        return false
    }
}
