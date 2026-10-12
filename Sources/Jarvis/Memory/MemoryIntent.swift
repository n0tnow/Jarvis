import Foundation

/// Deterministic reading of a user's memory-related sentence (typed or spoken — the same text path). EN + TR.
struct StatementClass: Equatable, Sendable {
    var type: MemoryType
    var subject: String
    var key: String?
    var value: String?
    var summary: String
    var importance: MemoryImportance
    var scope: MemoryScope
    var area: String?
    var tags: [String]
}

enum MemoryStatementClassifier {
    private static let constraintCues = ["must", "never", "do not", "don't", "dont", "should not", "shouldn't", "always", "only ", "required", "forbidden", "cannot", "remain", "stay ", "asla", "gerekir", "zorunda", "yasak", "olmamali", "kalmali", "yapma", "etme", "degistirme", "kullanma", "gerek"]
    private static let decisionCues = ["we decided", "decided to", "decision", "we chose", "we picked", "we selected", "karar", "sectik", "secildi", "kullanmaya karar"]
    private static let preferenceCues = ["prefer", "i like", "we like", "tercih", "tarzi", "stilinde"]
    private static let failureCues = ["failed", "did not work", "didn't work", "regression", "broke ", "caused a bug", "calismadi", "bozuldu", "hata verdi", "basarisiz"]
    private static let taskLocalCues = ["for this task", "for now", "this time", "just for this", "only for this", "for this run", "bu gorev icin", "simdilik", "bu seferlik", "bu is icin", "bu islem icin"]
    private static let areas: [(String, [String])] = [
        ("camera", ["camera", "kamera"]), ("voice", ["voice", "speech", "wake word", "ses ", "sesli"]), ("research", ["research", "arastir", "web ", "browser", "tarayici"]), ("hud", ["hud", "compact", "window", "pencere"]),
        ("unity", ["unity", "scene", "prefab", "urp", "hdrp"]), ("multiplayer", ["multiplayer", "netcode", "ngo", "co-op"]), ("animation", ["animation", "animasyon", "rig"]),
        ("assets", ["asset", "varlik", "license", "lisans", "download", "indir"]), ("security", ["security", "approval", "onay", "credential", "secret", "guvenlik"]), ("models", ["model", "provider", "qwen", "claude", "codex"]),
    ]

    static func classify(_ raw: String) -> StatementClass {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = MemoryText.fold(clean)
        var type: MemoryType = .projectFact
        if failureCues.contains(where: { f.contains($0) }) { type = .failure }
        else if decisionCues.contains(where: { f.contains($0) }) { type = .decision }
        else if constraintCues.contains(where: { f.contains($0) }) { type = .constraint }
        else if preferenceCues.contains(where: { f.contains($0) }) { type = .preference }
        let scope: MemoryScope = taskLocalCues.contains(where: { f.contains($0) }) ? .taskLocal : .project
        let hard = ["never", "must", "asla", "do not", "yasak", "zorunda"].contains { f.contains($0) }
        let importance: MemoryImportance = type == .constraint && hard ? .high : .normal
        let area = areas.first { _, words in words.contains { f.contains($0) } }?.0
        var key: String?, value: String?
        if let m = clean.range(of: "(6000\\.\\d+(\\.\\d+)?[a-z0-9]*|20\\d\\d\\.\\d+(\\.\\d+)?[a-z0-9]*)", options: .regularExpression), f.contains("unity") { key = "unity.version"; value = String(clean[m]) }
        else if f.contains("render pipeline") || f.contains("urp") || f.contains("hdrp") || f.contains("built-in") {
            if f.contains("urp") || f.contains("universal") { key = "unity.pipeline"; value = "Universal (URP)" }
            else if f.contains("hdrp") || f.contains("high definition") { key = "unity.pipeline"; value = "High Definition (HDRP)" }
            else if f.contains("built-in") { key = "unity.pipeline"; value = "Built-in" }
        }
        // a negated pipeline statement ("we no longer use URP") is not a value for the key
        if key == "unity.pipeline", MemoryText.hasNegation(clean) || f.contains("no longer") || f.contains("artik") { key = nil; value = nil }
        let words = MemoryText.words(clean).filter { !["remember", "that", "project", "must", "never", "always", "hatirla", "unutma"].contains($0) }
        let subject = words.prefix(3).joined(separator: " ")
        return StatementClass(type: type, subject: subject.isEmpty ? "note" : subject, key: key, value: value, summary: clean, importance: importance, scope: scope, area: area,
                              tags: area.map { [$0] } ?? [])
    }
}

/// What the user's sentence asks of memory.
enum MemoryCommand: Equatable, Sendable {
    case remember(String)
    case correct(String)            // free text: "actually, we no longer use X"
    case forget(String)             // phrase naming the memory
    case question(MemoryQuestion)
    case none
}

/// A direct question about project history/state. `topic` is what remains of the sentence after the question frame is removed.
struct MemoryQuestion: Equatable, Sendable {
    enum Kind: String, Sendable { case decision, why, tried, failure, current, changed, constraints, assets, issues, known, general }
    var kind: Kind
    var topic: String
    var historical: Bool
    var raw: String
    /// A strong frame names history/state explicitly ("we decided", "what failed", "what do you know about"). A weak one ("we" + a question word) falls through to normal conversation when memory has nothing relevant.
    var strongFrame = true
}

enum MemoryIntentParser {
    private static func f(_ s: String) -> String { MemoryText.fold(s) }

    private static let rememberPrefixes = ["remember that ", "remember: ", "remember ", "please remember ", "note that ", "keep in mind that ", "hatirla ki ", "hatirla: ", "sunu hatirla: ", "sunu hatirla ", "bunu hatirla: ", "bunu hatirla ", "not al: ", "unutma: ", "unutma ki "]
    private static let correctPrefixes = ["actually, ", "actually ", "correction: ", "correction, ", "that's wrong. ", "no, ", "no. ", "aslinda ", "duzeltme: ", "hayir, ", "yanlis. ", "yanlis, "]
    private static let forgetPrefixes = ["forget the ", "forget that ", "forget about ", "forget ", "unut ", "bunu unut: ", "sunu unut: ", "unut: ", "hafizandan sil: "]

    static func parse(_ raw: String) -> MemoryCommand {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 600 else { return .none }
        let t = f(text)
        for p in forgetPrefixes where t.hasPrefix(f(p)) {
            let rest = String(text.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return rest.isEmpty ? .none : .forget(rest)
        }
        // "bunu unut" at the end ("kamera kararini unut")
        if t.hasSuffix(" unut") || t.hasSuffix(" unutur musun") || t.hasSuffix(" forget it") {
            let rest = text.replacingOccurrences(of: "(?i)\\s+(unut(?: lutfen)?|unutur musun|forget it)[.!?]*$", with: "", options: .regularExpression)
            return rest.isEmpty ? .none : .forget(rest)
        }
        for p in rememberPrefixes where t.hasPrefix(f(p)) {
            let rest = String(text.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return rest.count > 3 ? .remember(rest) : .none
        }
        if t.hasSuffix(" hatirla") || t.hasSuffix(" hatirla.") {
            let rest = text.replacingOccurrences(of: "(?i)\\s+hatırla[.!?]*$", with: "", options: .regularExpression)
            return rest.count > 3 ? .remember(rest) : .none
        }
        for p in correctPrefixes where t.hasPrefix(f(p)) {
            let rest = String(text.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            // only a statement that denies/changes something is a correction; "actually, how do I…" is a question
            let tf = f(rest)
            if rest.count > 6, !tf.hasSuffix("?"), (MemoryText.hasNegation(rest) || tf.contains("no longer") || tf.contains("artik") || tf.contains("instead") || tf.contains("now ") || tf.contains("simdi") || tf.contains("yerine")) { return .correct(rest) }
        }
        if let q = parseQuestion(text) { return .question(q) }
        return .none
    }

    // MARK: Questions

    private static let historyCues = ["before", "previously", "earlier", "last time", "used to", "in the past", "originally", "old ", "daha once", "onceden", "eskiden", "onceki", "ilk basta", "gecmiste", "en son", "son kez"]

    static func parseQuestion(_ raw: String) -> MemoryQuestion? {
        let t = f(raw)
        func has(_ cues: [String]) -> Bool { cues.contains { t.contains($0) } }
        let isQuestion = raw.contains("?") || has(["what ", "why ", "which ", "have we ", "did we ", "do we ", "does ", "how ", "who ", "ne ", "neden", "nasil", "hangi", "miydi", "muydu", "miyiz", "ediyor muyuz", "ogren", "anlat", "hatirla", "tell me", "show me", "list ", "goster"])
        guard isQuestion else { return nil }
        // a question about the OUTSIDE world / a generic request is not a memory question: the frame must refer to "we/our/project/this project/JARVIS" history or state
        let frame = has(["we decided", "did we decide", "we decide", "we tried", "have we tried", "did we try", "we use", "do we use", "are we using", "we chose", "our ", "this project", "the project", "project's", "jarvis", "we rejected", "we reject", "we researched", "we did", "we changed", "we change", "did not we", "didn't we", "didnt we", "we ", "reject", "since yesterday",
                         "what changed", "what failed", "what remains", "what do you know about", "what do we know", "remember", "karar vermis", "denemis", "denedik", "kullaniyor muyuz", "kullaniyoruz", "neden ", "reddettik", "arastirdik", "ne degisti", "ne biliyorsun", "ne biliyoruz", "bildigin", "aklinda", "hatirliyor", "projede", "projemizde", "bizim", "vermistik", "ettik", "yaptik", "secmistik"])
        guard frame else { return nil }
        var kind: MemoryQuestion.Kind = .general
        if has(["constraint", "kisit", "limitation", "must not", "rules", "kurallar", "yasak"]) { kind = .constraints }
        else if has(["assets did we", "asset did we", "which assets", "what assets", "rejected asset", "varlik", "varliklari"]) { kind = .assets }
        else if has(["what failed", "failed", "failure", "went wrong", "basarisiz", "calismadi", "bozuldu", "hata", "regression"]) { kind = .failure }
        else if has(["what changed", "changed since", "ne degisti", "degisti", "since yesterday", "dunden beri"]) { kind = .changed }
        else if has(["have we tried", "did we try", "tried before", "already tried", "what did we try", "denemis", "denedik", "denemistik", "denedigimiz"]) { kind = .tried }
        else if has(["known issue", "remains broken", "what remains", "open issues", "bilinen sorun", "acik sorun", "kalan"]) { kind = .issues }
        else if has(["decide", "decision", "decided", "karar", "chose", "secmistik", "secildi"]) { kind = has(["why", "neden", "reason"]) ? .why : .decision }
        else if has(["why ", "why?", "neden", "niye", "reason", "sebep"]) { kind = .why }
        else if has(["what do you know", "what do we know", "ne biliyorsun", "ne biliyoruz", "bildigin"]) { kind = .known }
        else if has(["current", "now", "right now", "currently", "su an", "simdi", "guncel", "which version", "hangi surum"]) { kind = .current }
        let historical = has(historyCues) || kind == .tried || kind == .changed || kind == .failure
        let strong = has(["decide", "decision", "tried", "try ", "failed", "changed", "rejected", "reject", "researched", "know about", "constraint", "remember", "karar", "denedik", "denemis", "degisti", "ne biliyor", "reddet", "arastir", "kisit", "this project", "our project", "known issue", "remains"])
        return MemoryQuestion(kind: kind, topic: topic(of: raw), historical: historical, raw: raw, strongFrame: strong)
    }

    /// The question's subject: content words minus the question frame.
    static func topic(of raw: String) -> String {
        let frame: Set<String> = ["decide", "decided", "decision", "tried", "try", "failed", "changed", "know", "about", "remember", "project", "jarvis", "current", "currently", "now", "before", "previously", "earlier", "last", "time", "use", "using", "used",
                                  "karar", "vermistik", "denedik", "denemis", "biliyorsun", "biliyoruz", "hakkinda", "degisti", "projede", "nedir", "neydi", "ne", "kullaniyoruz", "kullaniyor", "muyuz", "miydik", "daha", "once", "simdi", "neden", "why", "what", "did", "have", "do", "does", "tell", "show", "list"]
        let words = MemoryText.words(raw).filter { !frame.contains($0) }
        return words.joined(separator: " ")
    }
}
