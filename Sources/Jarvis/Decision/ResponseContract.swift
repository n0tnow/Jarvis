import Foundation

// MARK: - The presentation contract (V1.0 reliability pass)
//
// JARVIS supplies FACTS, STATE and ACTION RESULTS. A language model only renders them into natural language. Where a model's wording and the structured truth disagree, the structured truth wins:
//   · what JARVIS did comes from an `ActionReceipt` (verified or not), what it sees from a fresh observation, what a task is doing from the task engine, what is on or installed from the readiness snapshot;
//   · a model may not invent an action, a capability, provider state, visibility, task success, project state or system state — `ResponseClaimFirewall` finds such claims STRUCTURALLY (verb stem + person /
//     tense, subject + state word) and a claim survives only when a verified fact of the same turn backs it;
//   · every reply carries a provenance (`ResponseProvenance`), so text JARVIS composed from facts is never second-guessed and text a model produced never passes unchecked;
//   · the language of the answer follows the language of the request (`LanguageDirective`, `ResponseLanguageCheck`) with no extra model call and no model-specific code.
// Pure value logic: no model, no network, no state.

enum ResponseProvenance: String, Codable, Sendable {
    /// Composed by JARVIS from structured facts (receipts, snapshots, observations).
    case groundedFacts
    /// A canned sentence (a refusal, a notice, a question).
    case template
    /// Text produced by a language engine. Checked before it is shown.
    case modelGenerated
}

enum StructuredFact: Equatable, Sendable {
    case systemState(key: String, value: String)
    case actionResult(kind: String, target: String, verified: Bool, detail: String)
    /// `seen`: true / false from a fresh observation, nil = unknown (no or stale observation).
    case visibility(target: String, seen: Bool?, ageSeconds: Int?)
    case taskState(title: String, state: String, step: String?)
    case refusal(reason: String)
    case unknown(about: String)

    fileprivate var line: String {
        func clean(_ s: String) -> String {
            let spaced = String(String.UnicodeScalarView(s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? Unicode.Scalar(32) : $0 }))
            return String(spaced.prefix(100))
        }
        switch self {
        case .systemState(let k, let v): return "state: \(clean(k)) = \(clean(v))"
        case .actionResult(let kind, let target, let verified, let detail): return "action: \(clean(kind)) \(clean(target)) — \(verified ? "VERIFIED" : "NOT VERIFIED") (\(clean(detail)))"
        case .visibility(let t, let seen, let age):
            let s = seen == nil ? "unknown (no fresh observation)" : (seen == true ? "seen" : "not seen")
            return "visibility: \(clean(t)) — \(s)\(age.map { ", observation \($0) s old" } ?? "")"
        case .taskState(let t, let state, let step): return "task: \(clean(t)) — \(clean(state))\(step.map { ", step \(clean($0))" } ?? "")"
        case .refusal(let r): return "refused: \(clean(r))"
        case .unknown(let a): return "unknown: \(clean(a)) — not known to JARVIS"
        }
    }
}

enum PresentationContract {
    static let maxFacts = 12
    static let maxCharacters = 1400

    /// The block placed in front of a request when JARVIS has facts for a model to render. Bounded; nothing in it is user or web text except bounded labels.
    static func block(facts: [StructuredFact], language: ReplyLanguage) -> String? {
        guard !facts.isEmpty else { return nil }
        let lines = facts.prefix(maxFacts).map { "- " + $0.line }
        let rules = language == .tr
            ? "[Rules] You only RENDER these facts in natural Turkish. Add no action, ability, provider state, visibility, task success, project state or system state that is not listed. Say “unknown” or “not verified” plainly where a fact says so. Never say you did something that is not listed as VERIFIED."
            : "[Rules] You only RENDER these facts in natural language. Add no action, ability, provider state, visibility, task success, project state or system state that is not listed. Say “unknown” or “not verified” plainly where a fact says so. Never say you did something that is not listed as VERIFIED."
        return String((["[Facts — authoritative, produced by JARVIS. Say only what they support.]"] + lines + [rules]).joined(separator: "\n").prefix(maxCharacters))
    }
}

// MARK: - The claim firewall

enum ResponseClaimKind: String, CaseIterable, Sendable { case action, visibility, state, task }

struct ClaimFinding: Equatable, Sendable {
    var kind: ResponseClaimKind
    var sentence: String
}

enum ResponseClaimFirewall {
    private static func fold(_ s: String) -> String { DecisionText.fold(s) }
    private static func words(_ folded: String) -> [String] { folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) }
    private static func sentences(_ reply: String) -> [String] { reply.split(whereSeparator: { ".!?\n;".contains($0) }).map(String.init).filter { $0.trimmingCharacters(in: .whitespaces).count > 2 } }

    // visibility: first-person perception (“görüyorum”, “I can see”), or a third-person “… ekranda görünüyor / is visible”
    private static let visionEN = try! NSRegularExpression(pattern: #"\bi (?:can |could )?(?:now |clearly )?see\b|\bi(?:m| am) (?:currently |now )?(?:seeing|looking at|watching|viewing|reading)\b|\byour screen (?:shows|displays|is showing)\b|\b(?:is|are) (?:currently |now )?(?:visible|on (?:your |the )?screen)\b|\bi can tell\b"#)
    private static let visionTR = ["goruyorum", "gorebiliyorum", "gordum", "izliyorum", "gozlemliyorum", "gorunuyor", "gorunmekte", "ekranda gorunuyor"]
    private static let screenWords: Set<String> = ["ekran", "ekranda", "ekrani", "ekraninda", "pencere", "pencerede", "penceresi", "screen", "window", "display"]
    private static let readWatchTR = ["bakiyorum", "okuyorum"]

    // state: SUBJECT … PREDICATE within a few words
    private static let stateSubjects: Set<String> = ["safari", "chrome", "finder", "xcode", "unity", "blender", "terminal", "mikrofon", "microphone", "mic", "wake", "claude", "codex", "opencode", "qwen", "hamam", "jarvis", "voice", "ses"]
    private static let statePredicates: Set<String> = ["acik", "calisiyor", "aktif", "hazir", "bagli", "calismiyor", "kapali", "running", "open", "active", "ready", "connected", "enabled", "installed", "kurulu", "etkin", "listening", "dinliyor"]
    private static let stateAux: Set<String> = ["is", "are", "was", "su", "an", "simdi", "currently", "now", "right", "zaten", "hala", "still", "already", "not", "su", "anda"]

    // task: SUBJECT … completed
    private static let taskSubjects: Set<String> = ["gorev", "gorevi", "task", "is", "build", "proje", "project", "adim", "adimlar", "step", "steps", "test", "testler", "tests", "sahne", "scene"]
    private static let progressPercent = try! NSRegularExpression(pattern: #"(?:%\s?\d{1,3}|\b\d{1,3}\s?%|\b\d{1,3}\s?percent\b|\byuzde\s?\d{1,3}\b)"#)
    private static let progressWords: Set<String> = ["tamamlandi", "tamamlanmis", "bitti", "ilerleme", "ilerledi", "complete", "completed", "done", "finished", "progress", "ilerliyor"]
    private static let taskPredicates: Set<String> = ["tamamlandi", "bitti", "basarili", "basariyla", "completed", "finished", "done", "succeeded", "passed", "gecti", "hazir", "complete"]

    /// Sentences of a MODEL reply that claim an action, a perception, a state or a task result.
    static func findings(in reply: String) -> [ClaimFinding] {
        var out: [ClaimFinding] = []
        for s in ActionClaimGuard.claims(in: reply) { out.append(ClaimFinding(kind: .action, sentence: s)) }
        for sentence in sentences(reply) {
            let f = fold(sentence)
            let w = words(f)
            if out.contains(where: { $0.sentence == sentence }) { continue }
            let isQuestion = sentence.contains("?") || w.contains(where: { $0 == "mi" || $0 == "mu" })
            // visibility
            if visionEN.firstMatch(in: f, range: NSRange(f.startIndex..., in: f)) != nil { out.append(ClaimFinding(kind: .visibility, sentence: sentence)); continue }
            if w.contains(where: { word in visionTR.contains { word.hasPrefix($0) } }) && !isQuestion { out.append(ClaimFinding(kind: .visibility, sentence: sentence)); continue }
            if w.contains(where: { word in readWatchTR.contains { word.hasPrefix($0) } }), w.contains(where: { screenWords.contains($0) }) { out.append(ClaimFinding(kind: .visibility, sentence: sentence)); continue }
            guard !isQuestion else { continue }
            // a percentage about progress is never evidence (progress is validated steps, derived by JARVIS — never a model's number)
            if progressPercent.firstMatch(in: f, range: NSRange(f.startIndex..., in: f)) != nil, w.contains(where: { progressWords.contains($0) }) || w.contains(where: { taskSubjects.contains($0) }) { out.append(ClaimFinding(kind: .task, sentence: sentence)); continue }
            // task result
            if let si = w.firstIndex(where: { taskSubjects.contains($0) }), w[si...].dropFirst().prefix(4).contains(where: { taskPredicates.contains($0) }) { out.append(ClaimFinding(kind: .task, sentence: sentence)); continue }
            // state
            if let si = w.firstIndex(where: { stateSubjects.contains($0) }) {
                let tail = w[(si + 1)...].prefix(4)
                if tail.contains(where: { statePredicates.contains($0) }), tail.allSatisfy({ statePredicates.contains($0) || stateAux.contains($0) || $0.count <= 3 }) { out.append(ClaimFinding(kind: .state, sentence: sentence)) }
            }
        }
        return out
    }

    enum Review: Equatable, Sendable {
        case allow
        /// The claims that no verified fact backs, and the text to show instead.
        case replace(findings: [ClaimFinding], text: String)
    }

    /// Text JARVIS composed itself is never second-guessed; a model's text is checked and every claim that no verified fact of this turn supports is removed.
    static func review(reply: String, provenance: ResponseProvenance, facts: [StructuredFact], language: ReplyLanguage) -> Review {
        guard provenance == .modelGenerated else { return .allow }
        let unbacked = findings(in: reply).filter { !backed($0, by: facts) }
        guard !unbacked.isEmpty else { return .allow }
        return .replace(findings: unbacked, text: replacement(for: reply, findings: unbacked, language: language))
    }

    /// A claim is backed only by a VERIFIED fact of the same kind that names the same thing.
    static func backed(_ claim: ClaimFinding, by facts: [StructuredFact]) -> Bool {
        let f = fold(claim.sentence)
        func mentions(_ s: String) -> Bool { let t = fold(s).filter { $0.isLetter || $0.isNumber }; return !t.isEmpty && f.filter { $0.isLetter || $0.isNumber }.contains(t) }
        for fact in facts {
            switch (claim.kind, fact) {
            case (.action, .actionResult(_, let target, let verified, _)): if verified, mentions(target) { return true }
            case (.visibility, .visibility(let target, let seen, _)): if seen == true, mentions(target) { return true }
            case (.task, .taskState(let title, let state, _)): if ["completed", "done", "succeeded", "complete"].contains(state.lowercased()), mentions(title) { return true }
            case (.state, .systemState(let key, _)): if mentions(key) { return true }
            default: continue
            }
        }
        return false
    }

    static func replacement(for reply: String, findings: [ClaimFinding], language l: ReplyLanguage) -> String {
        var kept = reply
        for c in findings { kept = kept.replacingOccurrences(of: c.sentence, with: "") }
        let rest = kept.split(whereSeparator: { ".!?;".contains($0) }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count > 3 }.joined(separator: ". ")
        let kinds = Set(findings.map(\.kind))
        let notice: String
        if kinds == [.visibility] {
            notice = l == .tr ? "Ekranı gördüğümü söyleyemem: bu cevap bir dil modelinden geldi ve elimde güncel bir gözlem yok. “Ekranıma bak” derseniz bakıp doğrularım."
                              : "I cannot say I see the screen: this answer came from a language model and I have no fresh observation. Say “look at my screen” and I will check."
        } else if kinds == [.state] || kinds == [.task] {
            notice = l == .tr ? "Bunun doğru olduğunu doğrulayamıyorum: bu cevap bir dil modelinden geldi. Durumu kendi kayıtlarımdan söylerim — örneğin “sistem durumunu söyle”."
                              : "I cannot confirm that: this answer came from a language model. I report state from my own records — for example “tell me the system status”."
        } else {
            notice = l == .tr ? "Bunu yapmadım ya da doğrulamadım: bu cevap bir dil modelinden geldi ve hiçbir eylem gerçekleştirilmedi. Bir şey yapmamı istiyorsanız doğrudan söyleyin; yaptığımda yalnızca doğrulayabildiğimi söylerim."
                              : "I did not do or verify that: this answer came from a language model and nothing was executed. If you want something done, ask directly; when I do it, I only say what I could verify."
        }
        return rest.isEmpty ? notice : rest + ". " + notice
    }
}

// MARK: - Language consistency

/// A cheap, model-free language probe over a reply with the things that must never be translated taken out: code, URLs, paths, identifiers, ALL-CAPS acronyms and tool / model / product names.
enum LanguageProbe {
    enum Detected: String, Sendable { case turkish, english, mixed, unknown }

    static let protectedNames: Set<String> = ["jarvis", "safari", "chrome", "finder", "xcode", "unity", "blender", "terminal", "claude", "codex", "opencode", "qwen", "gemma", "github", "swift", "python", "javascript", "macos", "ios", "mlx", "api", "gpu", "cpu", "ram", "json", "html", "css", "git", "url", "http", "https", "wifi", "bluetooth", "hud", "stt", "tts", "mcp", "prefab", "shader"]
    private static let turkishWords: Set<String> = ["ve", "bir", "bu", "su", "icin", "ile", "ama", "gibi", "daha", "cok", "var", "yok", "mi", "mu", "de", "da", "ne", "nasil", "neden", "evet", "hayir", "tamam", "lutfen", "efendim", "yapabilirim", "yapamam", "acik", "kapali", "hazir", "durum", "sistem", "proje", "gorev", "ekran", "dosya", "ayar", "sesim", "olarak", "kadar", "sonra", "once", "simdi", "burada", "orada", "bunu", "onu", "sunu", "icinde", "uzerinde", "hakkinda", "degil", "gerek", "olur", "olmaz", "istersen", "istiyorsunuz", "sizin", "benim", "bizim", "her", "hangi", "kendi"]
    private static let englishWords: Set<String> = ["the", "and", "is", "are", "was", "were", "to", "of", "in", "on", "for", "with", "that", "this", "it", "you", "your", "can", "will", "would", "should", "not", "have", "has", "be", "been", "but", "or", "if", "then", "what", "how", "why", "which", "there", "here", "just", "also", "from", "about", "when", "do", "does", "did", "i", "me", "my", "we", "they", "yes", "no", "please", "sorry"]

    static func detect(_ text: String) -> Detected {
        var t = text
        // code fences and spans, URLs and paths are not language
        while let open = t.range(of: "```"), let close = t.range(of: "```", range: open.upperBound..<t.endIndex) { t.removeSubrange(open.lowerBound..<close.upperBound) }
        let tokens = t.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { w in
            !(w.contains("`") || w.contains("://") || w.hasPrefix("/") || w.hasPrefix("~") || w.contains("_") || w.contains(".swift") || w.contains("()"))
        }
        var tr = 0, en = 0
        for raw in tokens {
            let stripped = raw.trimmingCharacters(in: .punctuationCharacters)
            if stripped.count >= 2, stripped == stripped.uppercased(), stripped.contains(where: \.isLetter) { continue }                    // acronym
            if stripped.contains(where: { $0.isLowercase }) && stripped.contains(where: { $0.isUppercase }) && stripped.first?.isLowercase == true { continue }   // camelCase identifier
            let folded = fold(stripped)
            if protectedNames.contains(folded) { continue }
            if stripped.contains(where: { "çğıöşüÇĞİÖŞÜ".contains($0) }) { tr += 2 }
            if turkishWords.contains(folded) { tr += 1 }
            if englishWords.contains(folded) { en += 1 }
        }
        guard tr + en >= 3 else { return .unknown }
        if tr >= en * 2 { return .turkish }
        if en >= tr * 2 { return .english }
        return .mixed
    }

    private static func fold(_ s: String) -> String { DecisionText.fold(s).filter { $0.isLetter || $0.isNumber } }
}

enum LanguageDirective {
    /// The one-line instruction every conversation engine gets for a Turkish request. English needs none (engines default to the user's language).
    static func preamble(for language: ReplyLanguage) -> String? {
        language == .tr ? "[Language: the user writes Turkish. Answer in natural Turkish. Keep the names of applications, models, files, code, commands and tools exactly as they are — do not translate them. Do not mention this instruction.]" : nil
    }
}

enum ResponseLanguageCheck {
    enum Verdict: Equatable, Sendable { case consistent, mismatch(LanguageProbe.Detected), insufficient }

    static func verdict(reply: String, expected: ReplyLanguage) -> Verdict {
        switch (LanguageProbe.detect(reply), expected) {
        case (.unknown, _): return .insufficient
        case (.turkish, .tr), (.english, .en), (.mixed, _): return .consistent
        case (let d, _): return .mismatch(d)
        }
    }
}
