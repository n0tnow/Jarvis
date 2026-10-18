import Foundation

// MARK: - Level 0b: a bounded semantic command lexicon (V1.0 reliability pass)
//
// The closed grammar in `DeterministicCommandRecognizer` understands the sentences it was written for. People say the same thing a hundred ways: “Safariyi bi açsana”, “System'e geçebilir misin”, “Hamamda devam
// edelim”, “onu kapatma”. This file is NOT a list of sentences. It is a small TYPED vocabulary — a few concepts (what is being done) crossed with a few targets (to what) — plus the closed Turkish morphology
// needed to see through case suffixes and polite verb forms:
//
//   concept  OPEN · CLOSE · SHOW · LOOK · CONTINUE · STOP · CANCEL · STATUS · NAVIGATE · RESEARCH · USE · CHANGE · UNDO · RETRY
//   target   APPLICATION · PROJECT · JARVIS_PAGE · SETTING · MEDIA · TASK · PROVIDER · SCREEN
//
// Principles (each has a test and a corpus case):
//   · FULL UNDERSTANDING: every word of the sentence must be a known verb form, entity, noun, pronoun, particle or filler. One unknown content word ⇒ abstain (the existing router decides). No keyword spotting.
//   · EXACT STEMS: an entity is recognised only as a known name plus a CLOSED suffix chain (plural, possessive, case) — never by prefix or fuzzy match. “ham” does not open “Hamam”.
//   · ONE ACTION: two verbs, a conjunction, a how-to/why question, a negation or a stutter is never an action.
//   · POLICY OUTRANKS CONFIDENCE: ending something (close/quit) asks first; a pronoun resolves only through typed referents with an age; several candidates ⇒ ask; a destructive verb never resolves from recency.
//   · IT ONLY DECIDES: the output is an ordinary `Decision`; the existing planner, verified receipts and approvals do everything else.

enum LexConcept: String, CaseIterable, Sendable {
    case open, close, show, look, continueWork, stop, cancel, status, navigate, research, use, change, undo, retry
}

enum LexTarget: String, CaseIterable, Sendable {
    case application, project, jarvisPage, setting, media, task, provider, screen
}

// MARK: - Turkish morphology (closed)

enum TurkishMorphology {
    /// Case suffixes (folded; ı→i, ö→o, ü→u) that may follow a name, with or without the apostrophe (“Safari'yi”, “Safariyi”, “Systeme”, “Hamamda”).
    static let caseSuffixes: Set<String> = ["", "i", "u", "yi", "yu", "a", "e", "ya", "ye", "da", "de", "ta", "te", "dan", "den", "tan", "ten", "in", "un", "nin", "nun", "la", "le", "yla", "yle", "si", "su", "ni", "nu", "na", "ne", "nda", "nde", "ndan", "nden", "ki"]
    private static let plural = ["", "ler", "lar"]
    private static let possessive = ["", "i", "si", "u", "su", "im", "in", "imiz"]
    /// Every closed suffix CHAIN: [plural][possessive][case]. Built once; small (a few hundred strings).
    static let chains: Set<String> = {
        var s = Set<String>()
        for p in plural { for q in possessive { for c in caseSuffixes { s.insert(p + q + c) } } }
        return s
    }()

    static func isClosedChain(_ suffix: String) -> Bool { chains.contains(suffix) }

    /// `token` = a known stem plus a closed suffix chain → that stem. Longest stem first, so “sistemi” resolves to “sistem” (not a shorter accidental stem).
    static func stem(of token: String, in stems: Set<String>) -> String? {
        if stems.contains(token) { return token }
        var i = token.count - 1
        while i >= 2 {
            let stem = String(token.prefix(i))
            if stems.contains(stem), isClosedChain(String(token.dropFirst(i))) { return stem }
            i -= 1
        }
        return nil
    }

    /// The same, with an arbitrary predicate (e.g. “does the project registry know this name?”). The stem itself must satisfy it; the rest must be a closed chain. SHORTEST stem first (the predicate may itself tolerate suffixes).
    static func stem(of token: String, where isKnown: (String) -> Bool, minimum: Int = 3) -> String? {
        var i = minimum
        while i <= token.count {
            let stem = String(token.prefix(i))
            if isClosedChain(String(token.dropFirst(i))), isKnown(stem) { return stem }
            i += 1
        }
        return nil
    }
}

// MARK: - Verb morphology (closed)

enum VerbMorphology {
    /// Imperative stems of every command verb the lexicon knows (folded). Closed.
    static let stems: [String: LexConcept] = [
        "ac": .open, "baslat": .open, "calistir": .open, "open": .open, "launch": .open,
        "kapat": .close, "close": .close, "quit": .close, "exit": .close,
        "goster": .show, "show": .show,
        "bak": .look, "look": .look,
        "gec": .navigate, "git": .navigate, "don": .navigate, "switch": .navigate, "go": .navigate,
        "kes": .stop, "durdur": .stop, "birak": .stop, "sus": .stop,
        "iptal": .cancel,
        "arastir": .research, "ara": .research,
        "kullan": .use, "dene": .use, "sec": .use,
        "kis": .change, "arttir": .change, "azalt": .change, "yukselt": .change, "alcalt": .change, "hizlandir": .change, "yavaslat": .change, "degistir": .change, "ayarla": .change,
    ]

    /// Suffixes that make a polite or colloquial request out of a stem. `aorist` forms are only meaningful before a second-person question particle (“açar mısın”); the others stand alone.
    private static let standalone = ["", "sana", "sene", "iver", "uver", "alim", "elim", "in", "iniz", "abilir", "ebilir", "abilirsin", "ebilirsin", "sak", "sek", "sam", "abilirsen", "ebilirsen"]
    private static let aorist = ["ar", "er", "ir", "ur", "r", "abilir", "ebilir", "abilirsin", "ebilirsin"]
    static let questionParticles: Set<String> = ["misin", "musun", "misiniz", "musunuz", "miyiz", "muyuz", "miyim", "muyum"]

    /// token → (stem, concept) for forms that stand alone.
    static let standaloneForms: [String: (stem: String, concept: LexConcept)] = {
        var m: [String: (String, LexConcept)] = [:]
        for (s, c) in stems { for suf in standalone { m[s + suf] = (s, c) } }
        return m
    }()
    static let aoristForms: [String: (stem: String, concept: LexConcept)] = {
        var m: [String: (String, LexConcept)] = [:]
        for (s, c) in stems { for suf in aorist { m[s + suf] = (s, c) } }
        return m
    }()

    /// Negative / infinitive / past / participle forms of the same stems: a request NOT to do it, a wish not to, a report that it happened. Never an action.
    private static let negative = ["ma", "me", "mayin", "meyin", "masana", "mesene", "mak", "mek", "maz", "mez", "mamali", "memeli", "masin", "mesin", "mayalim", "meyelim", "mam", "mem", "madan", "meden", "tim", "tik", "tin", "ti", "mis", "mistim", "mistik", "ip", "arak", "erek", "inca", "ince", "ayim", "eyim", "iyor", "uyor", "iyorum", "uyorum", "mayacak", "meyecek", "acak", "ecek"]
    static func isNegatedOrReported(_ token: String) -> Bool {
        for s in stems.keys where token.hasPrefix(s) && token.count > s.count {
            let rest = String(token.dropFirst(s.count))
            if negative.contains(rest) { return true }
        }
        return false
    }
    /// A bare negative imperative of a stem (“açma”, “kapatma”, “yapma”, “silme”): a request NOT to do something.
    static func isNegativeImperative(_ token: String) -> Bool {
        // “araştırma” (research) and “arama” (search) are NOUNS that happen to look like a negative imperative of araştır / ara
        if token.hasPrefix("arastirma") || token == "arama" || token.hasPrefix("aramayi") || token.hasPrefix("aramalar") { return false }
        let bases = Array(stems.keys) + ["yap", "sil", "gonder", "ver", "et", "al", "dur"]
        for s in bases where token.hasPrefix(s) && token.count > s.count {
            let rest = String(token.dropFirst(s.count))
            if ["ma", "me", "mayin", "meyin", "masana", "mesene"].contains(rest) { return true }
        }
        return false
    }

    /// The concept of `token` when it is a command verb form (next = the following token, for the aorist-before-question-particle rule).
    static func concept(of token: String, next: String?) -> LexConcept? {
        if let f = standaloneForms[token] { return f.concept }
        if let n = next, questionParticles.contains(n), let f = aoristForms[token] { return f.concept }
        return nil
    }
}

// MARK: - Politeness canonicaliser

/// “Konuşma hızını arttırır mısın”, “Biraz yavaş konuşur musun”, “Sesini biraz kısar mısın”, “Görevi durdurabilir misin”, “ayarlara bakar mısın”: the existing typed parsers (settings, readiness, research,
/// continuity, actions) were written for the imperative. This rewrites a polite or colloquial request into the plain imperative — ONLY for the closed verb stems above — so every existing parser benefits,
/// and the result is parsed by the SAME grammar (same gates, same safety). Returns nil when nothing changed.
enum PoliteCanonicalizer {
    static func canonical(_ raw: String) -> String? {
        let words = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count >= 1, words.count <= 24 else { return nil }
        var out: [String] = []
        var changed = false
        var i = 0
        while i < words.count {
            let w = words[i]
            let core = DecisionText.fold(w).filter { $0.isLetter || $0.isNumber }
            let next = i + 1 < words.count ? DecisionText.fold(words[i + 1]).filter { $0.isLetter || $0.isNumber } : nil
            let trail = w.last.map { ",.;:!?".contains($0) ? String($0) : "" } ?? ""
            if let base = imperativeBase(core, next: next) {
                out.append(base + (trail == "?" ? "" : trail)); changed = true
                // drop the question particle that belonged to the polite form
                if let n = next, VerbMorphology.questionParticles.contains(n) { i += 1 }
                else if let n = next, n == "bir" || n == "lutfen" { /* keep: noise words are harmless */ }
            } else if VerbMorphology.questionParticles.contains(core), changed, out.last.map({ DecisionText.fold($0).filter { $0.isLetter } }).flatMap({ VerbMorphology.stems[$0] }) != nil {
                changed = true            // a glued particle form already consumed above
            } else {
                // glued particle: “açarmısın”, “kapatırmısın”
                if let (verb, particle) = splitGluedParticle(core), let base = imperativeBase(verb, next: particle) { out.append(base); changed = true }
                else { out.append(w) }
            }
            i += 1
        }
        return changed ? out.joined(separator: " ") : nil
    }

    /// A stem's imperative when `token` is one of its polite / colloquial forms.
    private static func imperativeBase(_ token: String, next: String?) -> String? {
        if VerbMorphology.stems[token] != nil { return nil }            // already an imperative
        if let n = next, VerbMorphology.questionParticles.contains(n), ["eder", "edebilir", "edersin", "edebilirsin"].contains(token) { return "et" }     // “tarif eder misin”
        if let f = VerbMorphology.standaloneForms[token] { return f.stem }
        if let n = next, VerbMorphology.questionParticles.contains(n), let f = VerbMorphology.aoristForms[token] { return f.stem }
        return nil
    }

    private static func splitGluedParticle(_ token: String) -> (String, String)? {
        for p in VerbMorphology.questionParticles where token.hasSuffix(p) && token.count > p.count + 2 {
            return (String(token.dropLast(p.count)), p)
        }
        return nil
    }
}

// MARK: - The lexicon

/// Names JARVIS knows by closed table (its own pages). Folded stems; every Turkish/English spelling people use.
enum LexiconVocabulary {
    static let pageStems: [String: String] = [
        "dashboard": "dashboard", "anasayfa": "dashboard", "anaekran": "dashboard",
        "gorev": "tasks", "task": "tasks", "tasks": "tasks",
        "ajan": "agents", "agent": "agents", "agents": "agents",
        "arastirma": "research", "research": "research",
        "rapor": "report", "report": "report", "reports": "report",
        "sistem": "system", "system": "system",
        "hafiza": "memory", "bellek": "memory", "memory": "memory",
        "bilgisayar": "computer", "computer": "computer",
        "ogrenme": "learning", "learning": "learning",
        "yetenek": "capabilities", "capabilities": "capabilities",
        "ayar": "settings", "settings": "settings", "setting": "settings",
    ]
    /// Pages whose name alone is ambiguous with an application or a generic word: they need a UI noun (“sayfa”, “panel”) or a navigation verb (“geç”, “git”).
    static let needsNounOrNavVerb: Set<String> = ["system", "computer"]
    static let uiNouns: Set<String> = ["sayfa", "panel", "ekran", "sekme", "bolum", "pencere", "page", "screen", "tab", "section", "view", "window", "gorunum"]
    static let projectNouns: Set<String> = ["proje", "oyun", "project", "game"]
    static let applicationNouns: Set<String> = ["uygulama", "program", "application", "app"]
    static let taskNouns: Set<String> = ["gorev", "task", "is"]
    /// Words that carry no request of their own.
    static let fillers: Set<String> = ["jarvis", "hey", "hi", "lutfen", "please", "pls", "bir", "bi", "ya", "yani", "acaba", "rica", "ederim", "olur", "tamam", "peki", "hadi", "efendim", "bana", "sen", "simdi", "hemen", "now", "can", "could", "you", "would", "for", "me", "the", "a", "an", "to", "mu", "mi", "misin", "musun", "misiniz", "musunuz", "miyiz", "muyuz", "miyim", "muyum", "once", "biraz", "bakalim", "da", "de", "sunu", "that", "this", "at", "up"]
    static let conjunctions: Set<String> = ["ve", "sonra", "ardindan", "and", "then", "ayrica", "after", "before", "ama", "ancak", "veya", "or", "but", "while"]
    static let whWords: Set<String> = ["nasil", "neden", "niye", "nicin", "how", "why", "when", "where", "nerede", "hangi", "which", "what", "kim", "ne", "zaman", "kac", "who", "whose", "whom"]
    /// Words that turn a request around or deny it (Turkish and English). A sentence with one of them is never an action.
    static let negationWords: Set<String> = ["dont", "not", "never", "without", "cant", "wont", "didnt", "istemiyorum", "istemem", "istemiyoruz", "olmaz", "degil", "hic", "asla", "sakin"]
    static let referentPronouns: [String: Bool] = ["onu": true, "bunu": true, "sunu": true, "onlari": true, "bunlari": true, "ayni": true, "aynisini": true, "aynisi": true]
    static let stateWords: Set<String> = ["acik", "calisiyor", "calisir", "calismakta", "open", "running", "opened", "ekranda", "gorunuyor", "gorunur", "gorunuyormu", "visible", "gorebiliyor", "goruyor"]
}

struct SemanticLexicon {
    var parsers: DecisionParsers
    init(parsers: DecisionParsers) { self.parsers = parsers }

    /// nil = not fully understood (abstain). Otherwise a Decision with provenance `.semanticLexicon` (confidence ≤ 0.93: a tolerant form, below the exact closed grammar).
    func decide(_ raw: String, tokens all: [String], context: DecisionContext) -> Decision? {
        guard !all.isEmpty, all.count <= 14 else { return nil }
        // 1. correction-shaped sentences that carry no action of their own (they contain negations and wh-words by nature)
        if let d = metaCorrection(all, context: context) { return d }
        // 2. status questions (“Sistemde sorun var mı”, “Her şey çalışıyor mu”, “Hamam'ın durumu nasıl”) — read-only, and “nasıl” is legitimate here
        if let d = statusLike(all) { return d }
        if let d = capabilityLike(all) { return d }
        // 3. things that are never a command: how-to / why questions, two actions, a stutter, a negation or a report that it happened
        if all.contains(where: { LexiconVocabulary.whWords.contains($0) }) { return nil }
        if all.contains(where: { LexiconVocabulary.conjunctions.contains($0) || LexiconVocabulary.negationWords.contains($0) }) { return nil }
        if hasStutter(all) { return nil }
        if all.contains(where: { VerbMorphology.isNegatedOrReported($0) || VerbMorphology.isNegativeImperative($0) }) { return nil }

        if let d = continueLike(all, context: context) { return d }
        if let d = researchLike(all) { return d }
        if let d = providerLike(all) { return d }

        // 4. verbs
        var verbs: [(i: Int, concept: LexConcept)] = []
        for (i, t) in all.enumerated() {
            let next = i + 1 < all.count ? all[i + 1] : nil
            if let c = VerbMorphology.concept(of: t, next: next) { verbs.append((i, c)) }
        }
        let foreground = hasForegroundPhrase(all)
        let question = all.contains { VerbMorphology.questionParticles.contains($0) || $0 == "mi" || $0 == "mu" }

        // 5. state questions about an application (“Safari ekranda mı”, “Safari açık mı”)
        if verbs.isEmpty || verbs.allSatisfy({ $0.concept == .look }), let d = applicationState(all, question: question) { return d }

        guard verbs.count <= 1 || foreground && verbs.count <= 2 else { return nil }
        let concept: LexConcept? = verbs.last?.concept
        if foreground, let app = appEntity(all) {
            guard coveredByApp(all, app: app, extra: ["one", "getir", "getirir", "getirebilir", "getirsene", "getirsen", "al", "alsana", "alsene", "alir", "alabilir", "front", "foreground", "bring", "to", "the"]) else { return nil }
            return launch(app)
        }
        guard let concept else { return nil }
        // a bare verb (“aç”, “kapat”): an elliptical request — resolved from typed referents or asked, never guessed
        if let d = bareVerb(all, concept: concept, context: context) { return d }
        if concept == .change, let d = changeLike(all) { return d }

        switch concept {
        case .open, .navigate, .show, .look:
            return openLike(all, concept: concept, context: context)
        case .close:
            return closeLike(all, context: context)
        case .stop:
            return stopLike(all)
        default:
            return nil
        }
    }

    // MARK: Pieces

    /// The same word three or more times in a row (“aç aç aç aç”) is a stutter or a recogniser loop, not a command.
    private func hasStutter(_ t: [String]) -> Bool {
        var run = 1
        for i in 1..<max(t.count, 1) where i < t.count { run = t[i] == t[i - 1] ? run + 1 : 1; if run >= 3 { return true } }
        return false
    }

    private func hasForegroundPhrase(_ t: [String]) -> Bool {
        (t.contains("one") && (t.contains("getir") || t.contains("al") || t.contains("alsana") || t.contains("alsene") || t.contains("alir") || t.contains("alabilir") || t.contains("getirir") || t.contains("getirebilir") || t.contains("getirsene"))) || (t.contains("front") && t.contains("bring")) || t.contains("foreground")
    }

    private func noiseOnly(_ rest: [String]) -> Bool { rest.allSatisfy { LexiconVocabulary.fillers.contains($0) } }

    // application entity -------------------------------------------------------------------------------------------------------

    private struct AppHit { var display: String; var range: Range<Int> }

    private func appEntity(_ t: [String]) -> AppHit? {
        guard let m = parsers.appMatch(t) else { return nil }
        // the matched (last) token may carry only a CLOSED suffix chain: “safariyi”, “unityyi”, “chrome”a”, never “safarixyz”
        return AppHit(display: m.display, range: m.range)
    }

    private func coveredByApp(_ t: [String], app: AppHit, extra: Set<String>) -> Bool {
        for (i, w) in t.enumerated() where !app.range.contains(i) {
            if LexiconVocabulary.fillers.contains(w) || extra.contains(w) || LexiconVocabulary.applicationNouns.contains(where: { w.hasPrefix($0) }) || LexiconVocabulary.uiNouns.contains(where: { w.hasPrefix($0) }) || VerbMorphology.concept(of: w, next: nil) != nil || VerbMorphology.concept(of: w, next: "misin") != nil { continue }
            return false
        }
        return true
    }

    private func launch(_ app: AppHit) -> Decision {
        Decision(intent: .macosApplicationAction, confidence: 0.93, normalized: "Open the application \(app.display)", target: app.display, action: "launch", execution: true, provenance: .semanticLexicon)
    }

    // page entity --------------------------------------------------------------------------------------------------------------

    private func pageEntity(_ t: [String]) -> (page: String, index: Int, needsNoun: Bool)? {
        let stems = Set(LexiconVocabulary.pageStems.keys)
        for (i, w) in t.enumerated() {
            if let s = TurkishMorphology.stem(of: w, in: stems), let page = LexiconVocabulary.pageStems[s] { return (page, i, LexiconVocabulary.needsNounOrNavVerb.contains(page)) }
        }
        return nil
    }

    private func uiNounPresent(_ t: [String]) -> Bool { t.contains { w in LexiconVocabulary.uiNouns.contains { w.hasPrefix($0) } } }

    // project entity -----------------------------------------------------------------------------------------------------------

    private func projectEntity(_ t: [String]) -> (name: String, range: Range<Int>)? {
        for len in stride(from: min(3, t.count), through: 1, by: -1) {
            for start in 0...(t.count - len) {
                let window = Array(t[start..<(start + len)])
                guard !window.contains(where: { LexiconVocabulary.fillers.contains($0) || VerbMorphology.concept(of: $0, next: nil) != nil }) else { continue }
                let joined = window.joined(separator: " ")
                if let stem = TurkishMorphology.stem(of: window[window.count - 1], where: { s in self.parsers.isKnownProjectName((window.dropLast() + [s]).joined(separator: " ")) }) {
                    let name = (window.dropLast() + [stem]).joined(separator: " ")
                    if stem.count >= 3 { return (name, start..<(start + len)) }
                }
                _ = joined
            }
        }
        return nil
    }

    private func projectNounPresent(_ t: [String]) -> Bool { t.contains { w in LexiconVocabulary.projectNouns.contains { w.hasPrefix($0) } } }

    // open / navigate / show / look --------------------------------------------------------------------------------------------

    private func openLike(_ t: [String], concept: LexConcept, context: DecisionContext) -> Decision? {
        // an application (“Chrome'a geç”, “Safariyi açsana”, “Safari'ye bak”)
        if let app = appEntity(t), coveredByApp(t, app: app, extra: []) {
            if concept == .look { return Decision(intent: .computerUse, confidence: 0.9, normalized: "Look at the \(app.display) window and describe what is on screen", target: app.display, action: "observe", execution: true, computerUse: true, provenance: .semanticLexicon) }
            return launch(app)
        }
        // JARVIS' own page (“Systeme geç”, “Ayarlara bakar mısın”, “Hafıza sayfasına geçsene”)
        let screenWord = t.contains { $0.hasPrefix("ekran") } && pageEntity(t) == nil
        if concept == .look, screenWord, coveredBy(t, words: { $0.hasPrefix("ekran") }) {
            return Decision(intent: .computerUse, confidence: 0.9, normalized: "Look at the front window and describe what is on screen", target: "screen", action: "observe", execution: true, computerUse: true, provenance: .semanticLexicon)
        }
        if let page = pageEntity(t) {
            let nav = concept == .navigate || concept == .show || concept == .look || concept == .open
            let ok = nav && (!page.needsNoun || uiNounPresent(t) || concept == .navigate)
            let covered = t.enumerated().allSatisfy { i, w in i == page.index || LexiconVocabulary.fillers.contains(w) || LexiconVocabulary.uiNouns.contains(where: { w.hasPrefix($0) }) || VerbMorphology.concept(of: w, next: "misin") != nil || w == "me" || w == "my" }
            if ok, covered { return Decision(intent: .jarvisNavigation, confidence: 0.93, normalized: "Open the \(page.page) page of JARVIS", target: page.page, action: "navigate", execution: true, provenance: .semanticLexicon) }
        }
        // a project (“Hamamı aç”, “Hamam projesine geç”, “Hamam'a dönelim”)
        if concept == .open || concept == .navigate, let p = projectEntity(t) {
            let covered = t.enumerated().allSatisfy { i, w in p.range.contains(i) || LexiconVocabulary.fillers.contains(w) || LexiconVocabulary.projectNouns.contains(where: { w.hasPrefix($0) }) || VerbMorphology.concept(of: w, next: "misin") != nil }
            if covered { return Decision(intent: .projectOpen, confidence: 0.88, normalized: "Open the \(p.name) project, if there is a project of that name", target: p.name, action: "open", execution: true, projectResolution: true, provenance: .semanticLexicon) }
        }
        // a pronoun (“onu aç”, “o projeyi aç”, “bunu tekrar aç”)
        if concept == .open || concept == .navigate { return pronounOpen(t, context: context) }
        return nil
    }

    private func coveredBy(_ t: [String], words keep: (String) -> Bool) -> Bool {
        t.allSatisfy { keep($0) || LexiconVocabulary.fillers.contains($0) || VerbMorphology.concept(of: $0, next: "misin") != nil || $0 == "my" || $0 == "me" || $0 == "at" }
    }

    // close / quit -------------------------------------------------------------------------------------------------------------

    private func closeLike(_ t: [String], context: DecisionContext) -> Decision? {
        if let app = appEntity(t), coveredByApp(t, app: app, extra: []) { return quit(app.display) }
        // a pronoun: closing something is state-ending, so it never resolves from recency
        guard let (nounKinds, pronounIndex) = pronounSlot(t) else { return nil }
        guard coveredByPronoun(t, pronounIndex: pronounIndex) else { return nil }
        let kinds = nounKinds ?? [.application, .jarvisPage]
        switch context.referents.resolve(among: kinds, allowRecency: false) {
        case .resolved(.application, let s): return quit(s.label)
        case .resolved(.jarvisPage, _): return Decision(intent: .jarvisNavigation, confidence: 0.85, normalized: "Close the JARVIS window", target: "hud", action: "close", execution: true, provenance: .semanticLexicon)
        case .resolved: return askReferent("close", kinds: kinds)
        case .ambiguous(let ks): return askReferent("close", kinds: ks)
        case .none: return askReferent("close", kinds: kinds)
        }
    }

    private func quit(_ app: String) -> Decision {
        Decision(intent: .macosApplicationAction, confidence: 0.9, normalized: "Quit the application \(app)", target: app, action: "quit", execution: true, risk: .high, gate: .askFirst, provenance: .semanticLexicon)
    }

    // stop speaking ------------------------------------------------------------------------------------------------------------

    private func stopLike(_ t: [String]) -> Decision? {
        let speaks = t.contains { $0.hasPrefix("ses") || $0.hasPrefix("konus") }
        let tasky = t.contains { w in LexiconVocabulary.taskNouns.contains { w.hasPrefix($0) } && w != "is" }
        guard speaks, !tasky else { return nil }
        let covered = t.allSatisfy { $0.hasPrefix("ses") || $0.hasPrefix("konus") || LexiconVocabulary.fillers.contains($0) || VerbMorphology.concept(of: $0, next: "misin") == .stop || $0 == "artik" || $0 == "biraz" || $0 == "my" }
        guard covered else { return nil }
        return Decision(intent: .stopSpeech, confidence: 0.9, normalized: "Stop speaking now", action: "stop", execution: true, provenance: .semanticLexicon)
    }

    // pronouns and referents ---------------------------------------------------------------------------------------------------

    /// (kinds the noun restricts the pronoun to, index of the pronoun token). “o uygulamayı” → [.application]; “onu” → nil (any acceptable kind).
    private func pronounSlot(_ t: [String]) -> ([DecisionReferentKind]?, Int)? {
        for (i, w) in t.enumerated() {
            if LexiconVocabulary.referentPronouns[w] != nil { return (nil, i) }
            if ["o", "bu", "su", "that", "this", "the"].contains(w), i + 1 < t.count {
                let n = t[i + 1]
                if LexiconVocabulary.applicationNouns.contains(where: { n.hasPrefix($0) }) { return ([.application], i) }
                if LexiconVocabulary.projectNouns.contains(where: { n.hasPrefix($0) }) { return ([.project], i) }
                if LexiconVocabulary.uiNouns.contains(where: { n.hasPrefix($0) }) { return ([.jarvisPage], i) }
                if LexiconVocabulary.taskNouns.contains(where: { n.hasPrefix($0) }) { return ([.task], i) }
            }
        }
        return nil
    }

    private func coveredByPronoun(_ t: [String], pronounIndex: Int) -> Bool {
        t.enumerated().allSatisfy { i, w in
            i == pronounIndex || i == pronounIndex + 1 && !LexiconVocabulary.referentPronouns.keys.contains(t[pronounIndex]) || LexiconVocabulary.fillers.contains(w) || w == "tekrar" || w == "yeniden" || VerbMorphology.concept(of: w, next: "misin") != nil
        }
    }

    private func pronounOpen(_ t: [String], context: DecisionContext) -> Decision? {
        guard let (nounKinds, pi) = pronounSlot(t), coveredByPronoun(t, pronounIndex: pi) else { return nil }
        let kinds = nounKinds ?? [.application, .project, .jarvisPage]
        switch context.referents.resolve(among: kinds, allowRecency: true) {
        case .resolved(.application, let s): return launch(AppHit(display: s.label, range: 0..<0))
        case .resolved(.project, let s):
            return Decision(intent: .projectOpen, confidence: 0.85, normalized: "Open the \(s.label) project", target: DecisionText.fold(s.label), action: "open", execution: true, projectResolution: true, provenance: .semanticLexicon)
        case .resolved(.jarvisPage, let s):
            guard DecisionVocabulary.hudSection(s.label) != nil else { return askReferent("open", kinds: kinds) }
            return Decision(intent: .jarvisNavigation, confidence: 0.85, normalized: "Open the \(s.label) page of JARVIS", target: s.label.lowercased(), action: "navigate", execution: true, provenance: .semanticLexicon)
        case .resolved: return askReferent("open", kinds: kinds)
        case .ambiguous(let ks): return askReferent("open", kinds: ks)
        case .none: return askReferent("open", kinds: kinds)
        }
    }

    /// An elliptical request that cannot be resolved: JARVIS ASKS (the planner words the question). Never executes, never guesses.
    private func askReferent(_ verb: String, kinds: [DecisionReferentKind]) -> Decision {
        Decision(intent: .unknown, confidence: 0.6, normalized: "Ambiguous reference for \(verb)", target: verb, action: "ask_referent", ambiguity: .ambiguous(question: "referent:" + kinds.map(\.rawValue).joined(separator: ",")), provenance: .semanticLexicon)
    }

    // application state --------------------------------------------------------------------------------------------------------

    private func applicationState(_ t: [String], question: Bool) -> Decision? {
        guard question, let app = appEntity(t) else { return nil }
        let rest = t.enumerated().filter { !app.range.contains($0.offset) }.map(\.element)
        let visible = rest.contains { ["ekranda", "gorunuyor", "gorunur", "visible", "gorunuyormu"].contains($0) } || (rest.contains("on") && rest.contains("screen"))
        let running = rest.contains { ["acik", "calisiyor", "calisir", "calismakta", "running", "open"].contains($0) }
        guard visible != running else { return nil }
        let allowed: Set<String> = ["ekranda", "gorunuyor", "gorunur", "visible", "gorunuyormu", "acik", "calisiyor", "calisir", "calismakta", "running", "open", "on", "screen", "is", "are", "su", "an", "sunda", "simdi", "right", "now"]
        guard rest.allSatisfy({ word in LexiconVocabulary.fillers.contains(word) || allowed.contains(word) || LexiconVocabulary.applicationNouns.contains(where: { word.hasPrefix($0) }) }) else { return nil }
        if visible {
            return Decision(intent: .computerUse, confidence: 0.9, normalized: "Is \(app.display) visible on screen right now?", target: app.display, action: "visibility_query", execution: false, computerUse: true, provenance: .semanticLexicon)
        }
        return Decision(intent: .computerUse, confidence: 0.9, normalized: "Is \(app.display) running right now?", target: app.display, action: "running_query", execution: false, computerUse: true, provenance: .semanticLexicon)
    }

    // corrections ----------------------------------------------------------------------------------------------------------------

    /// “hayır onu yapma”, “yok yapma”, “No, don't do that”, “hayır onu değil”, “öyle demedim”, “bunu demedim”, “aynısını yap”, “az önce söylediğimi yap”.
    func metaCorrection(_ t: [String], context: DecisionContext) -> Decision? {
        let neg = Set(["hayir", "yok", "no", "nope", "hayirhayir"])
        let politeOnly: Set<String> = ["jarvis", "lutfen", "please", "hey", "efendim", "ya", "yani", "tamam", "peki", "hadi"]
        let rest = t.filter { !politeOnly.contains($0) }
        // negation of the thing just proposed or done
        if let first = rest.first, neg.contains(first) {
            let tail = Array(rest.dropFirst())
            let pronouns: Set<String> = ["onu", "bunu", "sunu", "that", "it"]
            let stop: Set<String> = ["yapma", "degil", "yapmayin", "dont", "do", "not", "that", "it", "yapmasana", "olmaz"]
            if !tail.isEmpty, tail.allSatisfy({ pronouns.contains($0) || stop.contains($0) || VerbMorphology.isNegativeImperative($0) }), tail.contains(where: { stop.contains($0) || VerbMorphology.isNegativeImperative($0) }) {
                return Decision(intent: .correction, confidence: 0.9, normalized: "The user does not want that done", action: "negate_last", provenance: .semanticLexicon)
            }
        }
        let joined = rest.joined(separator: " ")
        if ["oyle demedim", "bunu demedim", "onu demedim", "bunu kastetmedim", "that is not what i said", "thats not what i said", "i didnt say that", "i did not say that"].contains(joined) {
            return Decision(intent: .correction, confidence: 0.9, normalized: "The user says that is not what they said", action: "ask_what_meant", provenance: .semanticLexicon)
        }
        if ["aynisini yap", "ayni sekilde yap", "ayni seyi yap", "tekrar yap", "az once soyledigimi yap", "biraz once soyledigimi yap", "demin soyledigimi yap", "do the same", "do that again", "do what i just said", "same again"].contains(joined) {
            // nothing to repeat → ask; otherwise the previous request is routed again through the NORMAL pipeline (never a bypass)
            if context.previousUserText.trimmingCharacters(in: .whitespaces).isEmpty || context.previousInterpretation == "conversation" {
                return askReferent("repeat", kinds: [])
            }
            return Decision(intent: .correction, confidence: 0.85, normalized: "Repeat the previous request", action: "repeat_previous", provenance: .semanticLexicon)
        }
        return nil
    }

    // MARK: Status and continuation

    /// The registry project named in the sentence (exact name + closed suffix chain), or nil. Used to keep the NAME on a project query (“Hamam'da en son ne yaptık”).
    func projectName(in tokens: [String]) -> String? { projectEntity(tokens)?.name }

    private static let etForms: Set<String> = ["et", "edelim", "edin", "ettir", "edebilir", "edebiliriz", "edebilirsin", "etsek", "eder", "edermisin", "edebilirmiyiz", "edelimmi", "etsene"]

    /// “Hamamda devam edelim”, “Hamam projesinde devam et”, “Hamam'a devam edelim”, “Hamamda devam edebilir miyiz”: continue the NAMED project. The name is never dropped; without a registry name this abstains
    /// (“Kaldığımız yerden devam et” belongs to the continuity grammar).
    private func continueLike(_ t: [String], context: DecisionContext) -> Decision? {
        guard t.contains("devam"), t.contains(where: { Self.etForms.contains($0) }) else { return nil }
        guard let p = projectEntity(t) else { return continueTask(t, context: context) }
        let allowed: Set<String> = ["devam", "kaldigimiz", "yerden", "tekrar", "miyiz", "miyim", "yeniden"]
        let covered = t.enumerated().allSatisfy { i, w in p.range.contains(i) || allowed.contains(w) || Self.etForms.contains(w) || LexiconVocabulary.fillers.contains(w) || LexiconVocabulary.projectNouns.contains(where: { w.hasPrefix($0) }) }
        guard covered else { return nil }
        return Decision(intent: .projectTask, confidence: 0.88, normalized: "Continue the work in \(p.name)", target: p.name, action: "continue", execution: true, projectResolution: true, provenance: .semanticLexicon)
    }

    private static let statusSubjects: Set<String> = ["sistem", "system"]
    private static let statusPredicates: Set<String> = ["sorun", "problem", "calisiyor", "yolunda", "iyi", "saglikli", "hazir", "ready", "ok", "okay", "fine", "healthy", "kontrol", "check", "running", "working", "hata", "issue", "issues", "problems", "calisir"]
    private static let statusExtra: Set<String> = ["var", "yok", "mi", "mu", "eder", "et", "edebilir", "is", "are", "there", "any", "everything", "all", "right", "her", "sey", "hersey", "olarak", "genel", "genelde", "everything"]

    /// Read-only questions: “Sistemde sorun var mı”, “Her şey çalışıyor mu”, “JARVIS iyi mi”, “Is everything running okay?”, “Hamam'ın durumu nasıl”. Never an action.
    private func statusLike(_ t: [String]) -> Decision? {
        // project status
        if let p = projectEntity(t), t.contains(where: { $0.hasPrefix("durum") || $0 == "status" || $0 == "state" }) {
            let covered = t.enumerated().allSatisfy { i, w in p.range.contains(i) || w.hasPrefix("durum") || ["status", "state", "nasil", "ne", "nedir", "nasildir", "what", "is", "the", "of", "how"].contains(w) || LexiconVocabulary.fillers.contains(w) || LexiconVocabulary.projectNouns.contains(where: { w.hasPrefix($0) }) }
            if covered { return Decision(intent: .projectQuery, confidence: 0.88, normalized: "Tell me the project status", target: p.name, action: "status", projectResolution: true, provenance: .semanticLexicon) }
        }
        // system status
        guard t.count <= 7 else { return nil }
        let stems = Self.statusSubjects
        let subject = t.contains("jarvis") || t.contains(where: { TurkishMorphology.stem(of: $0, in: stems) != nil }) || t.contains("hersey") || t.contains("everything") || zip(t, t.dropFirst()).contains(where: { $0 == "her" && $1 == "sey" })
        guard subject else { return nil }
        let predicate = t.contains(where: { Self.statusPredicates.contains($0) })
        guard predicate else { return nil }
        let question = t.contains { VerbMorphology.questionParticles.contains($0) || $0 == "mi" || $0 == "mu" } || t.contains(where: { ["is", "are", "var"].contains($0) })
        guard question || t.count <= 4 else { return nil }
        let covered = t.allSatisfy { w in
            LexiconVocabulary.fillers.contains(w) || Self.statusPredicates.contains(w) || Self.statusExtra.contains(w) || w == "jarvis" || TurkishMorphology.stem(of: w, in: stems) != nil || VerbMorphology.questionParticles.contains(w)
        }
        guard covered else { return nil }
        return Decision(intent: .systemStatus, confidence: 0.88, normalized: "Tell me the current system status", target: "all", action: "query", provenance: .semanticLexicon)
    }

    /// “Biraz önceki göreve devam et”: continue the task the user just handled — from the typed task referent; asks when there is none.
    private func continueTask(_ t: [String], context: DecisionContext) -> Decision? {
        guard t.contains(where: { w in LexiconVocabulary.taskNouns.contains { w.hasPrefix($0) } && w != "is" }) else { return nil }
        let allowed: Set<String> = ["devam", "onceki", "once", "son", "o", "bu", "su", "az", "biraz", "demin", "miyiz", "tekrar", "yeniden"]
        guard t.allSatisfy({ w in allowed.contains(w) || Self.etForms.contains(w) || LexiconVocabulary.fillers.contains(w) || LexiconVocabulary.taskNouns.contains(where: { w.hasPrefix($0) }) }) else { return nil }
        switch context.referents.resolve(among: [.task], allowRecency: true) {
        case .resolved(_, let s): return Decision(intent: .projectTask, confidence: 0.85, normalized: "Continue the task \(s.label)", target: nil, action: "continue", execution: true, projectResolution: true, provenance: .semanticLexicon)
        default: return askReferent("continue", kinds: [.task])
        }
    }

    /// A sentence that is only a verb (plus fillers): “aç”, “kapat”. Open resolves like “onu aç”; close never resolves from recency.
    private func bareVerb(_ t: [String], concept: LexConcept, context: DecisionContext) -> Decision? {
        let rest = t.filter { !LexiconVocabulary.fillers.contains($0) }
        guard rest.count == 1, concept == .open || concept == .close, VerbMorphology.concept(of: rest[0], next: t.contains("misin") || t.contains("musun") ? "misin" : nil) != nil else { return nil }
        if concept == .close { return closeLike(["onu"] + rest, context: context) }
        return pronounOpen(["onu"] + rest, context: context)
    }

    // MARK: Settings, capabilities, research, providers (read-only or classification only)

    /// “Sesini biraz kısar mısın”, “Konuşma hızını arttır”: a change to speech/voice presentation. Classification only — the settings assistant applies the registered ones and reads them back; an unregistered
    /// one (there is no output-volume setting) falls to the normal route unchanged.
    private func changeLike(_ t: [String]) -> Decision? {
        let subject = t.contains { $0.hasPrefix("ses") || $0.hasPrefix("konus") || $0.hasPrefix("hiz") || $0 == "speech" || $0 == "voice" || $0 == "speed" || $0 == "volume" }
        guard subject else { return nil }
        let allowed: Set<String> = ["biraz", "cok", "daha", "hizli", "yavas", "yuksek", "alcak", "kisik", "az", "bit", "little", "much", "more", "less", "faster", "slower", "my", "the", "speech", "voice", "speed", "volume", "rate"]
        guard t.allSatisfy({ w in w.hasPrefix("ses") || w.hasPrefix("konus") || w.hasPrefix("hiz") || allowed.contains(w) || LexiconVocabulary.fillers.contains(w) || VerbMorphology.concept(of: w, next: "misin") == .change }) else { return nil }
        return Decision(intent: .settingsChange, confidence: 0.85, normalized: "Change or revert a JARVIS setting", action: "change", execution: true, provenance: .semanticLexicon)
    }

    private static let providerNames = ["claude", "codex", "opencode", "qwen"]
    private func providerName(_ w: String) -> String? { Self.providerNames.first { w.hasPrefix($0) } }

    /// Read-only ability and availability questions answered from JARVIS' own state: models, local model, files, internet, a named engine.
    private func capabilityLike(_ t: [String]) -> Decision? {
        let question = t.contains { VerbMorphology.questionParticles.contains($0) || $0 == "mi" || $0 == "mu" } || t.contains(where: { $0.hasSuffix("musun") || $0.hasSuffix("misin") })
        guard question || t.contains("hangi") || t.contains("which") else { return nil }
        func has(_ prefixes: String...) -> Bool { t.contains { w in prefixes.contains { w.hasPrefix($0) } } }
        func decision(_ target: String, _ what: String) -> Decision { Decision(intent: .providerCapability, confidence: 0.85, normalized: what, target: target, action: "query", provenance: .semanticLexicon) }
        let allowedGeneric: Set<String> = ["hangi", "which", "kullaniyorsun", "kullanabiliyorsun", "calisiyor", "hazir", "ready", "available", "working", "musun", "misin", "mi", "mu", "yerel", "local", "model", "modeli", "modelle", "modeller", "modelleri", "is", "are", "your", "the", "you", "using", "use", "do", "can"]
        if has("model"), t.allSatisfy({ allowedGeneric.contains($0) || LexiconVocabulary.fillers.contains($0) || $0.hasPrefix("model") || $0.hasPrefix("kullan") || $0.hasPrefix("calis") }) {
            return decision(has("yerel") || t.contains("local") ? "local" : "providers", "Which models does JARVIS use?")
        }
        if has("dosya", "file"), has("erisebil", "okuyabil", "acabil", "access", "read"), t.count <= 5 { return decision("files", "Can JARVIS reach the user's files?") }
        if has("internet", "web", "online"), has("baglanabil", "erisebil", "kullanabil", "access", "connect", "use"), t.count <= 5 { return decision("web", "Can JARVIS use the internet?") }
        if let name = t.compactMap(providerName).first, has("hazir", "ready", "calisiyor", "available", "working", "kullanilabilir"), t.count <= 4 { return decision(name, "Is \(name) available?") }
        return nil
    }

    /// “Look this up online”, “internette ara”: a web research request in an English or Turkish form the research intake does not carry.
    private func researchLike(_ t: [String]) -> Decision? {
        let lookUp = t.contains("look") && t.contains("up")
        let searchWeb = (t.contains("search") && t.contains(where: { ["web", "online", "internet", "internette"].contains($0) }))
        let araInternet = t.contains("ara") && t.contains(where: { $0.hasPrefix("internet") })
        guard lookUp || searchWeb || araInternet else { return nil }
        guard t.count <= 14 else { return nil }
        return Decision(intent: .research, confidence: 0.85, normalized: "Research this topic on the web", action: "web_research", execution: true, provenance: .semanticLexicon)
    }

    /// “OpenCode ile yapalım”, “Codex ile devam edelim”: a request to use a named engine for what comes next. Selects nothing and runs nothing: the router asks what it is for.
    private func providerLike(_ t: [String]) -> Decision? {
        guard let name = t.compactMap(providerName).first, t.contains(where: { $0 == "ile" || $0 == "with" }), t.count <= 5 else { return nil }
        let allowed: Set<String> = ["ile", "with", "yapalim", "yapsak", "yap", "deneyelim", "gidelim", "devam", "edelim", "code", "ya", "lutfen"]
        guard t.allSatisfy({ allowed.contains($0) || providerName($0) != nil || LexiconVocabulary.fillers.contains($0) }) else { return nil }
        return Decision(intent: .providerCapability, confidence: 0.8, normalized: "Use \(name) as the engine for the next request", target: name, action: "prefer_provider", ambiguity: .ambiguous(question: "For which task?"), provenance: .semanticLexicon)
    }
}
