import Foundation

// MARK: - Daily JARVIS presentation (V0.15, DEC-234)
//
// PRESENTATION ONLY. Nothing in this file decides, approves, grants, plans or executes anything; it chooses how much of an already-determined, evidence-based answer is shown or spoken and
// whether the Turkish form of address is used. It never changes a fact: a sentence that carries a failure, a refusal, an unknown or a pending decision is never dropped by shortening.

/// How much the user asked for in THIS turn.
enum ResponseDepth: String, Sendable, CaseIterable {
    case terse, normal, detailed, instructional, report
    var expands: Bool { self == .detailed || self == .instructional || self == .report }
}

/// Settings → Daily JARVIS → Response style. A default for turns that did not ask for a depth.
enum ResponseStyle: String, Sendable, CaseIterable {
    case concise, balanced, detailed
    var label: String { switch self { case .concise: "Concise"; case .balanced: "Balanced"; case .detailed: "Detailed" } }
    /// Characters of a deterministic answer shown in a NORMAL turn before the rest is offered on request.
    var normalLimit: Int { switch self { case .concise: 240; case .balanced: 420; case .detailed: Int.max } }
}

/// Settings → Daily JARVIS → Address style.
enum AddressStyle: String, Sendable, CaseIterable {
    case natural, minimal, off
    var label: String { switch self { case .natural: "Natural"; case .minimal: "Minimal"; case .off: "Off" } }
}

/// The moments at which the form of address may appear. Ordinary answers, statuses and failures never carry it.
enum ReplyMoment: Sendable, Equatable { case wake, greeting, taskAccepted, taskCompleted, decisionNeeded, answer }

// MARK: Depth detection (deterministic; no model)

enum ResponseDepthDetector {
    struct Detection: Equatable, Sendable {
        var depth: ResponseDepth
        /// The utterance contains nothing but the depth request (“Detaylı anlat.”, “Kısa söyle.”): it refers to the PREVIOUS answer.
        var bare: Bool
    }

    private static func fold(_ s: String) -> [String] {
        let f = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en")).lowercased().replacingOccurrences(of: "ı", with: "i")
        return String(f.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : " " }).split(separator: " ").map(String.init)
    }

    /// (phrase tokens, depth). Matched as a contiguous token run, strongest first.
    private static let phrases: [([String], ResponseDepth)] = [
        (["kisa", "soyle"], .terse), (["kisa", "kes"], .terse), (["kisaca"], .terse), (["ozetle"], .terse), (["ozet", "gec"], .terse), (["tek", "cumle"], .terse),
        (["short"], .terse), (["briefly"], .terse), (["be", "brief"], .terse), (["tldr"], .terse), (["tl", "dr"], .terse), (["in", "short"], .terse), (["shorter"], .terse), (["keep", "it", "short"], .terse),
        (["adim", "adim"], .instructional), (["step", "by", "step"], .instructional), (["ogret"], .instructional), (["teach", "me"], .instructional), (["walk", "me", "through"], .instructional),
        (["rapor", "ver"], .report), (["tam", "rapor"], .report), (["detayli", "rapor"], .report), (["rapor", "hazirla"], .report), (["full", "report"], .report), (["give", "me", "a", "report"], .report), (["report", "on"], .report),
        (["detayli", "anlat"], .detailed), (["ayrintili", "anlat"], .detailed), (["detaylandir"], .detailed), (["tum", "detaylari"], .detailed), (["ayrintilari", "goster"], .detailed),
        (["detaylari", "goster"], .detailed), (["ayrintilari"], .detailed), (["detaylari"], .detailed), (["in", "detail"], .detailed), (["detailed"], .detailed), (["elaborate"], .detailed),
        (["more", "detail"], .detailed), (["show", "details"], .detailed), (["details"], .detailed), (["tell", "me", "more"], .detailed), (["daha", "fazla", "detay"], .detailed),
    ]
    /// Weak cues count only as the first word of the utterance (“Neden?”, “Why did it fail?”).
    private static let leadingCues: [String: ResponseDepth] = ["neden": .detailed, "niye": .detailed, "why": .detailed, "acikla": .detailed, "explain": .detailed, "aciklar": .detailed]
    private static let fillers: Set<String> = ["bana", "bunu", "sunu", "onu", "lutfen", "please", "jarvis", "biraz", "it", "this", "that", "me", "now", "simdi", "tekrar", "bir", "daha", "da", "mi", "misin", "musun", "can", "you", "could", "again", "the", "explain", "describe", "tell", "anlat", "acikla", "goster", "show", "soyle", "say", "give"]

    static func detect(_ raw: String) -> Detection? {
        let t = fold(raw)
        guard !t.isEmpty else { return nil }
        for (phrase, depth) in phrases {
            guard let at = find(phrase, in: t) else { continue }
            var rest = t; rest.removeSubrange(at..<(at + phrase.count))
            return Detection(depth: depth, bare: rest.allSatisfy(fillers.contains))
        }
        if let first = t.first, let depth = leadingCues[first] { return Detection(depth: depth, bare: t.dropFirst().allSatisfy(fillers.contains)) }
        return nil
    }

    private static func find(_ phrase: [String], in tokens: [String]) -> Int? {
        guard phrase.count <= tokens.count else { return nil }
        for i in 0...(tokens.count - phrase.count) where Array(tokens[i..<(i + phrase.count)]) == phrase { return i }
        return nil
    }
}

// MARK: Shaping (never hides a negative fact)

/// An answer that was shortened can be expanded again: the full text is kept for the next “tell me more”.
struct ShapedReply: Equatable, Sendable {
    var shown: String
    var full: String
    var wasShortened: Bool
}

enum ReplyShaper {
    /// Folded markers of a sentence that must survive shortening: failures, refusals, unknowns, missing pieces and pending decisions.
    private static let critical: [String] = [
        "fail", "error", "hata", "basarisiz", "blocked", "engel", "refus", "reddedil", "cannot", "cant ", "can t", "yapamam", "unable", "not installed", "kurulu degil", "not found", "bulunamadi",
        "permission", "izin", "approval", "onay", "karar", "warning", "uyari", "unknown", "bilinmiyor", "stale", "eski", "interrupted", "kesildi", "missing", "eksik", "degraded", "denied",
        "not granted", "verilmedi", "unavailable", "kullanilamiyor", "not ready", "hazir degil", "timed out", "zaman asimi", "partial", "kismi", "needs", "gerekiyor", "gerekli",
    ]

    private static func folded(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en")).lowercased().replacingOccurrences(of: "ı", with: "i").replacingOccurrences(of: "'", with: " ")
    }
    static func isCritical(_ sentence: String) -> Bool { let f = folded(sentence); return critical.contains { f.contains($0) } }

    /// Splits into sentences/lines keeping their text and separators. A dot between digits ("0.15", "1.2.3") or inside a word-like token ("scripts/verify.sh") does not end a sentence.
    static func pieces(_ text: String) -> [String] {
        let chars = Array(text)
        var out: [String] = [], current = ""
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            switch ch {
            case "\n": out.append(current); current = ""
            case ".", "!", "?":
                if ch == ".", let n = next, !n.isWhitespace { continue }          // "0.15", "verify.sh", "e.g."
                out.append(current); current = ""
            default: break
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// `depth`/`style` choose how much of `full` is shown. `short` (when the caller built a purpose-made short form) wins for terse/normal turns.
    static func shape(full: String, short: String? = nil, depth: ResponseDepth, style: ResponseStyle, language: ReplyLanguage) -> ShapedReply {
        let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
        if depth.expands { return ShapedReply(shown: trimmed, full: trimmed, wasShortened: false) }
        if depth == .normal, style == .detailed { return ShapedReply(shown: trimmed, full: trimmed, wasShortened: false) }
        let limit = depth == .terse ? min(style.normalLimit, 140) : style.normalLimit
        if let short, !short.isEmpty, short.count < trimmed.count {
            // A purpose-built short form still has to carry every critical sentence of the full text.
            let lost = pieces(trimmed).filter { isCritical($0) && !folded(short).contains(folded($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
            let shown = lost.isEmpty ? short : short + " " + lost.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            return ShapedReply(shown: withPointer(shown, language), full: trimmed, wasShortened: true)
        }
        guard trimmed.count > limit else { return ShapedReply(shown: trimmed, full: trimmed, wasShortened: false) }
        var kept: [String] = [], used = 0
        let all = pieces(trimmed)
        for (i, p) in all.enumerated() {
            let critical = isCritical(p)
            if critical || used + p.count <= limit || kept.isEmpty { kept.append(p); used += p.count }
            else if i == 0 { kept.append(p); used += p.count }
        }
        let shown = kept.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard shown.count < trimmed.count else { return ShapedReply(shown: trimmed, full: trimmed, wasShortened: false) }
        return ShapedReply(shown: withPointer(shown, language), full: trimmed, wasShortened: true)
    }

    private static func withPointer(_ text: String, _ l: ReplyLanguage) -> String {
        text + (l == .tr ? " Ayrıntı için “detaylı anlat” deyin." : " Say “tell me more” for the details.")
    }
}

// MARK: Address policy

/// Decides whether the Turkish “efendim” belongs at a given moment. It tracks only a turn counter and the last use — nothing else.
struct AddressPolicy: Sendable {
    var style: AddressStyle = .natural
    /// Replies in a row without it before it may return (a short exchange is ≈ 3 JARVIS replies).
    static let spacing = 4
    private(set) var turn = 0
    private(set) var lastUse: Int?

    mutating func advance() { turn += 1 }
    /// “Efendim?” was said (the wake acknowledgement): it counts as a use.
    mutating func markUsed() { lastUse = turn }

    /// Reserves a use when allowed. `wake` always counts as a use (JARVIS says “Efendim?” when called) but is never suppressed.
    mutating func allows(_ moment: ReplyMoment, language: ReplyLanguage) -> Bool {
        guard language == .tr, style != .off else { return false }
        switch moment {
        case .wake:
            lastUse = turn; return true
        case .decisionNeeded:
            lastUse = turn; return true                                  // a decision request is important enough to be addressed every time
        case .greeting, .taskAccepted, .taskCompleted:
            guard style == .natural else { return false }
            if let last = lastUse, turn - last < Self.spacing { return false }
            lastUse = turn; return true
        case .answer:
            return false
        }
    }

    /// Inserts “efendim” after the first clause of `text` (“Başlıyorum.” → “Başlıyorum efendim.”). Idempotent; empty text is untouched.
    static func insert(into text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.lowercased().contains("efendim") else { return text }
        if let i = t.firstIndex(where: { ".!?…".contains($0) }) {
            var head = String(t[..<i]); let tail = String(t[i...])
            while head.last == " " { head.removeLast() }
            let sep = tail.hasPrefix("?") && head.isEmpty ? "" : " "
            return head.isEmpty ? "Efendim" + tail : head + sep + "efendim" + tail
        }
        return t + " efendim"
    }
}

// MARK: Presenter

/// The one object conversation code asks “how do I show this?”. Main-actor, in-memory, resettable; it holds the previous full answer so “Detaylı anlat” can expand it.
@MainActor
final class ResponsePresenter {
    var style: () -> ResponseStyle = { .concise }
    var addressStyle: () -> AddressStyle = { .natural }
    private(set) var address = AddressPolicy()
    private(set) var lastFull: ShapedReply?
    private(set) var lastDepth: ResponseDepth = .normal

    /// Call once per accepted user message.
    func beginTurn(_ text: String) -> ResponseDepthDetector.Detection? {
        address.advance()
        address.style = addressStyle()
        let d = ResponseDepthDetector.detect(text)
        lastDepth = d?.depth ?? .normal
        return d
    }

    func noteWakeAddressed() { address.markUsed() }

    func reset() { address = AddressPolicy(); address.style = addressStyle(); lastFull = nil; lastDepth = .normal }

    /// Shapes a deterministic answer for the current turn and remembers the full text.
    /// `evidence`: the answer carries citations or records (Project Memory, status from persisted facts). Those are shown whole unless the user asked for a short one.
    func present(full: String, short: String? = nil, moment: ReplyMoment = .answer, language: ReplyLanguage, depth: ResponseDepth? = nil, evidence: Bool = false) -> String {
        var d = depth ?? lastDepth
        if evidence, d == .normal { d = .detailed }
        let shaped = ReplyShaper.shape(full: full, short: short, depth: d, style: style(), language: language)
        lastFull = shaped
        return addressed(shaped.shown, moment: moment, language: language)
    }

    /// The previous answer again, at another depth. nil = there is nothing to re-render (the previous answer was not a shaped deterministic one).
    func rerender(depth: ResponseDepth, language: ReplyLanguage) -> String? {
        guard let last = lastFull else { return nil }
        let shaped = ReplyShaper.shape(full: last.full, depth: depth, style: style(), language: language)
        lastFull = ShapedReply(shown: shaped.shown, full: last.full, wasShortened: shaped.wasShortened)
        return shaped.shown
    }

    func addressed(_ text: String, moment: ReplyMoment, language: ReplyLanguage) -> String {
        address.style = addressStyle()
        return address.allows(moment, language: language) ? AddressPolicy.insert(into: text) : text
    }
}

// MARK: Concise wording for moments that used to be long

/// Short, evidence-safe wording. Each line says only what is true at that moment: a task WAS created (acceptance), not that any specific step has happened.
enum DailyPhrasebook {
    private static func pick(_ l: ReplyLanguage, _ en: String, _ tr: String) -> String { l == .tr ? tr : en }

    static func taskAccepted(readOnly: Bool, _ l: ReplyLanguage) -> String {
        readOnly ? pick(l, "Looking into it.", "İnceliyorum.") : pick(l, "On it.", "Başlıyorum.")
    }
    static func orchestratedAccepted(_ l: ReplyLanguage) -> String { pick(l, "On it. I will inspect first and use the other specialists only if needed.", "Başlıyorum. Önce inceleyeceğim; gerekirse diğer uzmanları kullanırım.") }
    static func researchAccepted(_ l: ReplyLanguage) -> String { pick(l, "Researching.", "Araştırıyorum.") }
    static func computerAccepted(_ l: ReplyLanguage) -> String { pick(l, "On it. Say stop to cancel.", "Başlıyorum. İptal için “durdur” deyin.") }
    static func decisionNeeded(_ what: String, _ l: ReplyLanguage) -> String {
        pick(l, "I need your decision: \(what)", "Bir kararınıza ihtiyacım var: \(what)")
    }
    static func notified(completed: Bool, _ l: ReplyLanguage) -> String {
        completed ? pick(l, "JARVIS completed your task.", "JARVIS görevinizi tamamladı.") : pick(l, "JARVIS could not finish your task.", "JARVIS görevinizi tamamlayamadı.")
    }
}
