import Foundation

// MARK: - Level 0: deterministic command recognition (V1.0 decision milestone)
//
// Known, high-value commands never need a language model to be understood. This is a CLOSED, bounded grammar (Turkish, English and mixed, speech-recogniser spellings and polite forms included) that
// maps an utterance to a typed `Decision`, reusing the existing typed parsers wherever one already owns a family (actions, readiness, continuity, settings, research, corrections) and adding the
// families that had no owner (voice status, tolerant system status, stop speech / cancel task as sentences, project open and "continue where we left off", media and visibility questions, safety-sensitive
// requests). It is advisory: it decides nothing about permission, performs nothing, and returns nil for anything it does not fully understand — which keeps its normal route.
//
// Order matters and is part of the contract: safety-sensitive forms first (so "GitHub'a pushla" can never be read as conversation), then control (stop / cancel), questions about JARVIS itself
// (voice, system, capabilities), JARVIS' own pages and applications, projects, Computer Use, settings, research, corrections, small talk.

enum DecisionText {
    /// Lowercase, diacritics folded, Turkish dotless ı → i, apostrophes removed (the matching form used everywhere in JARVIS; never shown or spoken).
    static func fold(_ s: String) -> String {
        var f = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en")).lowercased().replacingOccurrences(of: "ı", with: "i")
        for q in ["'", "’", "‘", "ʼ", "`"] { f = f.replacingOccurrences(of: q, with: "") }
        return f
    }
    static func tokens(_ s: String) -> [String] {
        fold(s).split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) }).map(String.init)
    }
    /// Words that carry no request of their own (address, politeness, fillers). Removed only for matching.
    static let noise: Set<String> = ["jarvis", "hey", "hi", "hello", "lutfen", "please", "pls", "tamam", "peki", "ok", "okay", "hadi", "efendim", "bana", "simdi", "now", "bir", "the", "a", "an", "sen", "bi", "ya", "yani", "acaba", "rica", "ederim", "olur", "mu", "mi"]
    static func core(_ raw: String) -> [String] { tokens(raw).filter { !noise.contains($0) || $0 == "mu" || $0 == "mi" } }
    static func isQuestion(_ raw: String, _ t: [String]) -> Bool {
        if raw.contains("?") { return true }
        if t.contains(where: { ["mi", "mu", "musun", "misin", "miyim", "muyum", "miyiz", "muyuz", "midir", "nedir"].contains($0) || $0.hasSuffix("musun") || $0.hasSuffix("misin") || $0.hasSuffix("miyor") }) { return true }
        if let f = t.first, ["can", "could", "is", "are", "do", "does", "am", "what", "how", "which", "why", "who", "when", "where", "will", "would"].contains(f) { return true }
        return false
    }
}

/// A tiny view over a token list for readable grammar rules.
private struct W {
    let t: [String]
    let f: String
    init(_ raw: String) { t = DecisionText.tokens(raw); f = t.joined(separator: " ") }
    func has(_ w: String...) -> Bool { w.contains { t.contains($0) } }
    func pre(_ p: String...) -> Bool { t.contains { w in p.contains { w.hasPrefix($0) } } }
    func phrase(_ p: String...) -> Bool { p.contains { f.contains($0) } }
}

/// The existing typed parsers this grammar sits on top of. Injected so the grammar is testable in isolation and so the application-name lookups (installed apps) stay the ONE implementation in `ActionService`.
struct DecisionParsers {
    var action: (String) -> ActionIntent? = { ActionIntentParser.parse($0) }
    var readiness: (String) -> ReadinessIntent? = { ReadinessIntentParser.recognize($0) }
    var continuity: (String) -> ContinuityIntent? = { ContinuityIntent.recognize($0) }
    var settings: (String) -> SettingsIntent? = { SettingsIntentParser.recognize($0) }
    var research: (String) -> Bool = { ResearchIntake.isResearchRequest($0) }
    var correction: (String) -> Correction? = { CorrectionParser.parse($0) }
    var knownApp: ([String]) -> String? = { AppCatalog.match(tokens: $0)?.app.display }
    /// The application named in the tokens with the range it covers — only when the last token carries nothing but a CLOSED Turkish suffix chain (“safariyi”, “unityyi”, never “safarixyz”).
    var appMatch: ([String]) -> (display: String, range: Range<Int>)? = { tokens in
        guard let m = AppCatalog.match(tokens: tokens) else { return nil }
        let slice = Array(tokens[m.range])
        let exact = m.app.aliases.contains { alias in
            let a = alias.split(separator: " ").map(String.init)
            guard a.count == slice.count else { return false }
            for (k, w) in a.enumerated() {
                let tok = slice[k]
                if tok == w { continue }
                if k == a.count - 1, tok.hasPrefix(w), TurkishMorphology.isClosedChain(String(tok.dropFirst(w.count))) { continue }
                return false
            }
            return true
        }
        return exact ? (m.app.display, m.range) : nil
    }
    /// Does the project registry know a project (or alias) by this spoken name (closed case suffixes only)? Default: none — a bare “X'ı aç” is then NOT claimed as a project.
    var isKnownProjectName: (String) -> Bool = { _ in false }
}

struct DeterministicCommandRecognizer {
    var parsers = DecisionParsers()
    init(parsers: DecisionParsers = DecisionParsers()) { self.parsers = parsers }

    func recognize(_ raw: String, context: DecisionContext = DecisionContext()) -> Decision? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 400 else { return nil }
        let w = W(text)
        guard !w.t.isEmpty, w.t.count <= 24 else { return nil }
        // Narrow, exact correction forms (“hayır onu yapma”, “No, don't do that”, “aynısını yap”) come before the general correction parser, which would read “No, <rest>” as a sentence to route again.
        if let d = SemanticLexicon(parsers: parsers).metaCorrection(w.t, context: context) { return d }
        // Level 0: the closed grammar. A decision it produces for an EXECUTING intent is first checked for a stutter / a how-to question (“Görevi nasıl iptal ederim”, “aç aç aç aç”).
        if let d = recognizeClosed(text, context: context) { return Self.guarded(d, w) }
        // Level 0b: the typed semantic lexicon (closed morphology, concept × target slots, referents) …
        if let d = SemanticLexicon(parsers: parsers).decide(text, tokens: w.t, context: context) { return d }
        // … and the polite / colloquial verb forms rewritten to the imperative the existing typed parsers were written for (the same parsers, the same gates).
        if let canon = PoliteCanonicalizer.canonical(text), canon != text, !canon.isEmpty, var d = recognizeClosed(canon, context: context) {
            d.provenance = .semanticLexicon
            d.confidence = min(d.confidence, 0.9)
            return Self.guarded(d, W(canon))
        }
        return nil
    }

    /// Executing decisions are dropped (the sentence keeps its normal route) when the transcript is a stutter or a how-to / why question. Blocked requests, stop commands and read-only answers are untouched.
    private static func guarded(_ d: Decision, _ w: W) -> Decision? {
        guard d.requiresExecution, d.gate != .blocked, d.intent != .correction else { return d }
        // a request NOT to do it (“Görevi iptal etme”, “Don't open Notes”) or a stutter / how-to question is never an action
        if w.t.contains(where: { VerbMorphology.isNegativeImperative($0) || LexiconVocabulary.negationWords.contains($0) }) { return nil }
        guard d.intent != .stopSpeech else { return d }
        var run = 1
        for i in 1..<max(w.t.count, 1) where i < w.t.count { run = w.t[i] == w.t[i - 1] ? run + 1 : 1; if run >= 3, d.intent != .cancelTask { return nil } }
        if w.has("nasil", "how", "neden", "why", "niye", "nicin", "zaman", "when") { return nil }
        return d
    }

    private func recognizeClosed(_ text: String, context: DecisionContext) -> Decision? {
        let w = W(text)
        guard !w.t.isEmpty, w.t.count <= 24 else { return nil }
        let question = DecisionText.isQuestion(text, w.t)
        let core = DecisionText.core(text)

        if let d = safetySensitive(w) { return d }
        if let d = stopSpeech(core, w) { return d }
        if let d = cancelTask(core, w) { return d }
        if let d = restatement(text, w, context: context) { return d }
        if let d = correctionForm(text, w, context: context) { return d }
        if let d = voiceStatus(w, question: question) { return d }
        if let d = systemStatus(text, w, question: question) { return d }
        if let d = visibilityQuestion(w, question: question) { return d }
        if let d = appRunningQuestion(w, question: question) { return d }
        if let d = projectOpen(w) { return d }
        if let d = continuation(text, w) { return d }
        if let d = projectStatus(w) { return d }
        if let d = settingsChange(text) { return d }
        if let d = mediaOrObserve(w, question: question) { return d }
        if let d = selfAndApplications(text) { return d }
        if let d = bareProjectOpen(w) { return d }
        if let d = bareContinuation(w) { return d }
        if let d = providerChoice(w, question: question) { return d }
        if let d = capabilityQuestion(text, w) { return d }
        // “Araştırma sayfasına geçelim” names JARVIS' own Research PAGE: a page noun means navigation territory, never a web research request
        if parsers.research(text), !w.pre("sayfa", "ekran", "panel", "sekme", "page", "screen", "tab ") { return Decision(intent: .research, confidence: 0.95, normalized: "Research this topic on the web", action: "web_research", execution: true, provenance: .existingParser) }
        if let d = projectQuery(text, w) { return d }
        if let d = smallTalk(w) { return d }
        return nil
    }

    // MARK: Safety-sensitive requests (recognised first; never executed by the decision layer)

    private func safetySensitive(_ w: W) -> Decision? {
        let fileObject = w.pre("dosya", "klasor", "file", "folder", "proje", "project", "repo", "branch", "commit", "kod", "code", "script") || w.has("it", "this", "bunu", "bu", "onu", "hepsini", "all", "everything", "hersey", "her", "tum")
        let deleteVerb = w.t.contains { ["sil", "silin", "silebilir", "silsene", "delete", "remove", "erase", "wipe", "rm", "kaldir", "yoket"].contains($0) } || w.pre("silebil", "silsen", "deleteit")
        if deleteVerb, fileObject, w.t.count <= 8, !w.has("nasil", "neden") {
            return Decision(intent: .projectTask, confidence: 0.9, normalized: "Delete a file or folder", action: "delete", execution: true, projectResolution: true, risk: .high, gate: .askFirst)
        }
        let pushForm = w.pre("push") || w.phrase("git push", "force push") || w.has("pushla", "pushlar", "pushlayin", "pushlasana") || (w.pre("github") && w.pre("gonder", "send", "yukle", "upload"))
        if pushForm, !w.has("notification", "bildirim", "notifications") {
            return Decision(intent: .projectTask, confidence: 0.95, normalized: "Push commits to a remote repository", target: w.has("github") || w.pre("github") ? "github" : nil, action: "git_push", execution: true, projectResolution: true, risk: .critical, gate: .blocked)
        }
        if w.has("commit", "commitle", "commitler", "kaydet") && w.pre("git", "commit"), !w.has("neden", "ne", "what", "why") {
            return Decision(intent: .projectTask, confidence: 0.9, normalized: "Create a Git commit", action: "git_commit", execution: true, projectResolution: true, risk: .critical, gate: .blocked)
        }
        let buyVerb = w.phrase("satin al", "satin alsana", "purchase", "buy ", "subscribe", "abone ol", "odeme yap", "checkout", "sepete ekle", "add to cart", "pay for") || w.has("buy", "subscribe")
        if buyVerb, !w.phrase("what is", "ne kadar", "how much", "fiyat", "price", "where can", "where to", "nereden", "nerede") {
            return Decision(intent: .unknown, confidence: 0.9, normalized: "Buy, pay for or subscribe to something", action: "purchase", execution: true, risk: .critical, gate: .blocked)
        }
        let secret = w.pre("sifre", "password", "parola", "credential", "keychain", "anahtar") || w.phrase("api key", "secret key", "private key", "access token")
        if secret, w.pre("goster", "show", "oku", "read", "ver", "give", "yaz", "type", "kopyala", "copy", "gonder", "send", "paylas", "reveal", "tell", "soyle") {
            return Decision(intent: .unknown, confidence: 0.9, normalized: "Reveal or use a password or credential", action: "credential", execution: true, risk: .critical, gate: .blocked)
        }
        return nil
    }

    // MARK: Stop speech / cancel task (two different things — kept apart)

    private func stopSpeech(_ core: [String], _ w: W) -> Decision? {
        guard core.count <= 5, !w.pre("gorev", "task", "job") else { return nil }
        let exact: [[String]] = [["sus"], ["dur"], ["stop"], ["yeter"], ["kes"], ["quiet"], ["enough"], ["sessiz", "ol"], ["be", "quiet"], ["shut", "up"], ["sus", "artik"], ["yeter", "artik"], ["dur", "dur"], ["sus", "sus"], ["dur", "artik"], ["sus", "biraz"]]
        let speaks = w.pre("konus", "talk", "speak", "reading", "oku", "anlat")
        let stopWord = w.has("kes", "kesin", "kesebilir", "birak", "birakir", "durdur", "durdurur", "dur", "stop", "quit", "cut", "yeter", "artik", "pause") || w.pre("durdurab", "kesebil", "birakab")
        // “dur dur dur”, “biraz sus”, “artık yeter”: only stop words and softeners, in any order
        let stopWords: Set<String> = ["sus", "dur", "stop", "yeter", "kes", "quiet", "enough"]
        let softeners: Set<String> = ["biraz", "artik", "simdi", "lutfen", "please", "now", "bir", "dakika", "saniye", "ya", "hadi"]
        let setRule = core.count <= 5 && core.contains(where: { stopWords.contains($0) }) && core.allSatisfy { stopWords.contains($0) || softeners.contains($0) } && !core.contains("dakika") && !core.contains("saniye")
        if exact.contains(where: { $0 == core }) || setRule || (speaks && stopWord) || w.pre("susar", "susab", "susalim", "susun") {
            return Decision(intent: .stopSpeech, confidence: 1.0, normalized: "Stop speaking now", action: "stop", execution: true, provenance: .deterministicGrammar)
        }
        return nil
    }

    private func cancelTask(_ core: [String], _ w: W) -> Decision? {
        guard core.count <= 8, w.pre("gorev", "task", "job") else { return nil }
        let cancelVerb = w.pre("durdur", "iptal", "cancel", "abort", "stop", "kes", "sonlandir", "terminate", "vazgec", "kill")
        let questionAboutStatus = w.pre("durum", "status", "ilerle", "progress") || w.has("ne", "what", "which", "hangi")
        guard cancelVerb, !questionAboutStatus || w.pre("durdur", "iptal") else { return nil }
        return Decision(intent: .cancelTask, confidence: 1.0, normalized: "Stop the running task", action: "stop", execution: true, provenance: .deterministicGrammar)
    }

    // MARK: Spoken restatement (“Sofany değil, Safari dedim.”, “Hayır Safari dedim.”)

    private func restatement(_ text: String, _ w: W, context: DecisionContext) -> Decision? {
        guard let r = SpokenRestatement.parse(text) else { return nil }
        // a bare fragment (“Hayır Safari.”) is a correction only when the previous turn was an action, or the fragment names a known application; “Hayır istemiyorum” is an answer
        if !r.explicit {
            guard !context.hasPendingDecision, context.previousInterpretation.hasPrefix("action") || parsers.knownApp(DecisionText.tokens(r.right)) != nil else { return nil }
        }
        return Decision(intent: .correction, confidence: r.wrong != nil ? 0.95 : 0.85, normalized: "The user restates what they said: \(r.right)", target: r.right, action: r.wrong != nil ? "restate_replacing" : "restate",
                        provenance: .deterministicGrammar)
    }

    // MARK: Voice status (“Sesim geliyor mu?”, “Beni duyuyor musun?”, “Mikrofon çalışıyor mu?”, “Voice input açık mı?”)

    private func voiceStatus(_ w: W, question: Bool) -> Decision? {
        guard question, w.t.count <= 9 else { return nil }
        let subject = w.pre("mikrofon", "microphone", "sesim", "sesimi", "sesimiz", "sesin", "konusmam", "konusmami") || w.has("mic", "ses", "voice", "audio", "sound", "beni", "me", "mikrofonum", "mikrofonumu")
        let aboutVoice = w.pre("mikrofon", "microphone") || w.has("mic", "ses", "sesim", "sesimi", "voice", "audio", "sound") || ((w.has("beni") || w.has("me") || w.pre("konusmam")) && w.pre("duy", "hear", "dinl", "listen", "anl"))
        guard subject, aboutVoice else { return nil }
        let state = w.pre("duy", "hear", "geli", "gelm", "calis", "work", "acik", "aktif", "dinl", "listen", "alg", "aliyor", "alabil", "yakal", "capture", "ulas", "hazir", "ready", "saglikli", "ok", "okay", "active", "picking", "alin", "gidiyor", "gitmiy") || w.has("on", "off", "kapali", "var", "yok")
        guard state else { return nil }
        // “Ses seviyesini aç”, “mikrofonu aç/kapat” are settings or controls, not status questions.
        if w.t.contains(where: { ["ac", "kapat", "ayarla", "arttir", "azalt", "yukselt", "alcalt", "enable", "disable"].contains($0) }) { return nil }
        // “Ses AI modeli kurulu mu?” and similar readiness items of the SYSTEM keep the system/readiness route
        if w.pre("model", "kurulu", "install", "whisper", "stt", "tts") { return nil }
        return Decision(intent: .voiceStatus, confidence: 0.95, normalized: "Is voice input working and is JARVIS hearing me?", action: "query", provenance: .deterministicGrammar)
    }

    // MARK: System status (one source of truth: the same snapshot the System page shows)

    private func systemStatus(_ raw: String, _ w: W, question: Bool) -> Decision? {
        if case .systemStatus(let scope)? = parsers.readiness(raw) {
            return Decision(intent: .systemStatus, confidence: 1.0, normalized: "Tell me the current system status", target: Self.scopeName(scope), action: "query", provenance: .existingParser)
        }
        guard w.t.count <= 9 else { return nil }
        // “Is the wake word on?” / “Wake word açık mı?”: the wake detector's state, from the same snapshot
        if question, w.has("wake") || w.pre("uyandirma"), w.pre("calis", "acik", "aktif", "work", "run", "activ") || w.has("on", "off", "listening"), !w.t.contains(where: { ["ac", "kapat", "open", "close"].contains($0) }) {
            return Decision(intent: .systemStatus, confidence: 0.9, normalized: "Tell me whether the wake word is running", target: "wake", action: "query", provenance: .deterministicGrammar)
        }
        let system = w.has("jarvis") || w.pre("sistem", "system")
        let status = w.pre("durum", "status", "state", "health", "saglik", "saglig") || w.has("hal", "halde") || ((question || w.t.count <= 4) && (w.has("ok", "okay", "healthy", "fine", "hazir", "ready", "iyi", "doing", "going", "gidiyor", "nasil", "how")))
        let uiNoun = w.pre("panel", "sayfa", "page", "ekran", "screen", "sekme", "tab", "pencere", "window", "hud", "gorunum", "view")
        let openVerb = w.t.contains { ["ac", "acar", "acabilir", "acin", "open", "launch", "git", "gec", "don", "back", "goto"].contains($0) } || w.pre("acab", "acar")
        let projectish = w.pre("gorev", "task", "proje", "project", "unity", "hamam", "agent", "ajan") || w.has("acarim", "acayim", "acabilirim", "acilir", "acilmiyor", "acmak", "open", "opens")
        guard system, status, !projectish, !(uiNoun && openVerb), !(w.has("jarvis") && !w.pre("sistem", "system") && !question && w.t.count > 4) else { return nil }
        let scope: StatusScope = (w.has("wake") || w.pre("uyandirma")) ? .wake : .all
        return Decision(intent: .systemStatus, confidence: 0.9, normalized: "Tell me the current system status", target: Self.scopeName(scope), action: "query", provenance: .deterministicGrammar)
    }

    private static func scopeName(_ s: StatusScope) -> String { switch s { case .all: "all"; case .running: "running"; case .features: "features"; case .wake: "wake" } }

    // MARK: Can you see <thing> right now? — never answered from imagination (needs a FRESH observation)

    private func visibilityQuestion(_ w: W, question: Bool) -> Decision? {
        guard question, w.t.count <= 10 else { return nil }
        let seeVerb = w.pre("gorebil", "goruyor", "gorunuyor", "gorunur", "gorur", "gorun", "ekranda") || w.phrase("can you see", "do you see", "is it visible", "is visible", "visible", "can you tell if", "see the", "on screen", "on the screen")
        guard seeVerb else { return nil }
        let appName = parsers.knownApp(w.t)
        let object: String? = appName ?? (w.pre("tarayici", "browser") ? "browser" : (w.pre("pencere", "window") ? "window" : (w.pre("video") ? "video" : nil)))
        guard let object else { return nil }               // “Ekranımı görebiliyor musun?” is a CAPABILITY question (below), not a visibility query about a thing
        return Decision(intent: .computerUse, confidence: 0.92, normalized: "Is \(object) visible on screen right now?", target: object, action: "visibility_query", execution: false, computerUse: true, provenance: .deterministicGrammar)
    }


    // MARK: Bare names (Phase B): “Hamam'ı aç”, “Hamam'da devam et”, “Chrome açık mı?”

    /// Words that are never a project or application NAME in a bare sentence.
    private static let bareStop: Set<String> = ["bunu", "sunu", "onu", "it", "this", "that", "hepsini", "all", "everything", "hersey", "yeni", "new", "tekrar", "again", "pencereyi", "window", "ekrani", "screen"]

    /// “Chrome açık mı?” / “Is Safari open?”: a question about the application LIST (is it running). Answered as exactly that — never as visibility.
    private func appRunningQuestion(_ w: W, question: Bool) -> Decision? {
        guard question, w.t.count <= 6, !["can", "could", "would", "will", "shall", "may", "do", "does", "did", "dont"].contains(w.t.first ?? "") else { return nil }       // “Can you open Safari?” is a request, “Is Safari open?” a state question
        let runWord = w.t.contains { ["acik", "calisiyor", "calisir", "running", "open", "opened", "calismakta"].contains($0) } || w.pre("calisiy")
        guard runWord, let app = parsers.knownApp(w.t) else { return nil }
        return Decision(intent: .computerUse, confidence: 0.9, normalized: "Is \(app) running right now?", target: app, action: "running_query", execution: false, computerUse: true, provenance: .deterministicGrammar)
    }

    /// An open verb plus ONE or TWO unknown words (no project word, no application, no page): the name of a project — if the registry knows it. Resolved by `ProjectOpenResolver` (closed case suffixes only);
    /// when nothing matches, the planner passes the sentence on unchanged, so “Sofany'yi aç” still reaches the application grammar and its phonetic fallback.
    private func bareProjectOpen(_ w: W) -> Decision? {
        guard w.t.count <= 4, w.t.contains(where: { ["ac", "acar", "acin", "acsana", "open", "launch", "load"].contains($0) }) else { return nil }
        let rest = w.t.filter { !["ac", "acar", "acin", "acsana", "open", "launch", "load", "misin", "musun", "mi", "mu", "lutfen", "please", "can", "could", "you", "acabilir", "acabilirmisin"].contains($0) && !DecisionText.noise.contains($0) && !Self.bareStop.contains($0) }
        guard (1...2).contains(rest.count), !rest.contains(where: { Self.projectWords.contains($0) || DecisionVocabulary.pages.contains($0) }), parsers.knownApp(w.t) == nil else { return nil }
        let name = rest.joined(separator: " ")
        guard parsers.isKnownProjectName(name) else { return nil }          // an unknown bare name may be an application (“Spotify'ı aç”): the application grammar owns it
        let stem = canonicalName(name)
        return Decision(intent: .projectOpen, confidence: 0.6, normalized: "Open the \(stem) project, if there is a project of that name", target: stem, action: "open_bare", execution: true, projectResolution: true, provenance: .deterministicGrammar)
    }

    /// “Hamam'da devam et” / “Hamam'a devam edelim”: continue the NAMED project (the name is never dropped).
    private func bareContinuation(_ w: W) -> Decision? {
        guard w.t.count <= 5, w.t.contains(where: { ["devam", "continue", "resume"].contains($0) }), w.t.contains(where: { ["et", "edelim", "ettir", "edin", "edebilir", "edebilirmisin"].contains($0) }) || w.has("continue", "resume") else { return nil }
        let rest = w.t.filter { !["devam", "et", "edelim", "ettir", "edin", "edebilir", "edebilirmisin", "misin", "musun", "mi", "mu", "continue", "resume", "on", "with", "lutfen", "please"].contains($0) && !DecisionText.noise.contains($0) && !Self.bareStop.contains($0) }
        guard rest.count == 1, !Self.projectWords.contains(where: { rest[0].hasPrefix($0) }), !DecisionVocabulary.pages.contains(rest[0]), parsers.knownApp(w.t) == nil, rest[0].count >= 3, parsers.isKnownProjectName(rest[0]) else { return nil }
        let stem = canonicalName(rest[0])
        return Decision(intent: .projectTask, confidence: 0.7, normalized: "Continue the work in \(stem)", target: stem, action: "continue", execution: true, projectResolution: true, provenance: .deterministicGrammar)
    }

    /// The registry name without its case suffix (“hamami” → “hamam”): the shortest suffix chain that leaves a name the registry still knows. A name with no such stem is returned unchanged.
    private func canonicalName(_ spoken: String) -> String {
        let parts = spoken.split(separator: " ").map(String.init)
        guard let last = parts.last else { return spoken }
        if let stem = TurkishMorphology.stem(of: last, where: { parsers.isKnownProjectName((parts.dropLast() + [$0]).joined(separator: " ")) }) { return (parts.dropLast() + [stem]).joined(separator: " ") }
        return spoken
    }

    // MARK: Projects

    private static let projectWords = ["proje", "project", "oyun", "game"]
    private static let nameStop: Set<String> = ["bu", "bizim", "the", "our", "my", "this", "that", "su", "benim", "son", "en", "last", "latest", "recent", "bir", "onceki", "previous", "calistigimiz", "yaptigimiz", "working", "worked", "we", "ben", "biz", "ac", "open", "projeyi", "projesini", "oyunu", "oyunumuzu", "on", "ilk", "yeni", "new", "o", "onu", "bunu", "sunu", "that"]

    private func projectOpen(_ w: W) -> Decision? {
        guard w.t.count <= 10 else { return nil }
        let openVerb = w.t.contains { ["ac", "acar", "acin", "acsana", "open", "launch", "load", "baslat", "start"].contains($0) } || w.pre("acab", "acar", "baslatab")
        let hasProjectWord = w.t.contains { t in Self.projectWords.contains { t.hasPrefix($0) } }
        guard openVerb, hasProjectWord, !w.has("yeni", "new", "olustur", "create", "kur", "baslatma") else { return nil }
        // “… projesine devam / dön” is the project continuation / switch, “… projesinin durumu” a question: not an open request
        if w.pre("devam", "continue", "resume", "don", "gec", "durum", "status", "neredey", "rapor", "report") && !w.has("ac") { return nil }
        let wantsLast = w.has("son", "last", "latest", "recent", "onceki", "previous") || w.phrase("en son", "calistigimiz", "worked on")
        // name: the word before the project word (“Hamam projesini aç”), or after it (“open project Hamam”)
        var name: String?
        for (i, tok) in w.t.enumerated() where Self.projectWords.contains(where: { tok.hasPrefix($0) }) {
            if i > 0, !Self.nameStop.contains(w.t[i - 1]), !DecisionText.noise.contains(w.t[i - 1]) { name = w.t[i - 1]; break }
            if i + 1 < w.t.count, tok == "project" || tok == "game", !Self.nameStop.contains(w.t[i + 1]), !DecisionText.noise.contains(w.t[i + 1]) { name = w.t[i + 1]; break }
        }
        if wantsLast { name = nil }
        // “o projeyi aç” / “onu aç”: a reference to something just handled — the lexicon resolves it from typed referents (or asks)
        if name == nil, !wantsLast, w.has("o", "onu", "bunu", "sunu", "that") { return nil }
        let amb: DecisionAmbiguity = (name == nil && !wantsLast) ? .ambiguous(question: "Which project?") : .none
        return Decision(intent: .projectOpen, confidence: name != nil || wantsLast ? 0.95 : 0.6, normalized: wantsLast ? "Open the project we worked on most recently" : "Open the \(name ?? "current") project",
                        target: name, action: wantsLast ? "open_last" : "open", execution: true, projectResolution: true, ambiguity: amb, provenance: .deterministicGrammar)
    }

    /// “Hamam projesinin durumu ne?” — a status question about a named project (the continuity grammar covers “proje durumu”, not this inflection).
    private func projectStatus(_ w: W) -> Decision? {
        guard w.t.count <= 8, w.pre("durum", "status", "state", "progress", "ilerle") else { return nil }
        guard let i = w.t.firstIndex(where: { t in Self.projectWords.contains { t.hasPrefix($0) } }) else { return nil }
        if w.t.contains(where: { ["ac", "open", "baslat", "start", "devam", "continue"].contains($0) }) { return nil }
        var name: String?
        if i > 0, !Self.nameStop.contains(w.t[i - 1]), !DecisionText.noise.contains(w.t[i - 1]) { name = w.t[i - 1] }
        return Decision(intent: .projectQuery, confidence: 0.9, normalized: "Tell me the project status", target: name, action: "status", projectResolution: true, provenance: .deterministicGrammar)
    }

    /// “Hamam'da kaldığımız yerden devam et.” — a continuation of work, with the project NAMED in the locative (“Hamam'da”): the name must not be dropped, or the wrong project continues.
    private func continuation(_ raw: String, _ w: W) -> Decision? {
        guard let intent = parsers.continuity(raw) else { return nil }
        switch intent {
        case .continueProject(let project):
            let name = project ?? Self.locativeProjectName(raw, w)
            return Decision(intent: .projectTask, confidence: 0.95, normalized: "Continue the work from where we left off" + (name.map { " in \($0)" } ?? ""), target: name, action: "continue", execution: true, projectResolution: true, provenance: .existingParser)
        case .queueNext(let project, _):
            return Decision(intent: .projectTask, confidence: 0.9, normalized: "Queue the next step for the project", target: project, action: "queue_next", projectResolution: true, provenance: .existingParser)
        case .choose:
            return nil
        case .status, .lastDone, .lastReport, .next:
            return nil          // answered below as a project QUERY (kept apart from the continuation)
        }
    }

    /// The word immediately before “kaldığımız”/“left off” when it carries a locative/dative suffix after an apostrophe or glued (“Hamam'da”, “hamamda”).
    fileprivate static func locativeProjectName(_ raw: String, _ w: W) -> String? {
        let anchors = ["kaldigimiz", "kaldik", "kalmistik", "birakmistik", "left", "where"]
        guard let i = w.t.firstIndex(where: { anchors.contains($0) }), i > 0 else { return nil }
        var cand = w.t[i - 1]
        if Self.nameStop.contains(cand) || DecisionText.noise.contains(cand) || ["yerden", "nerede", "de", "da", "projede", "projesinde", "projeye"].contains(cand) { return nil }
        // an apostrophe in the ORIGINAL text marks the suffix reliably (“Hamam'da”): split there
        for piece in raw.split(whereSeparator: { $0.isWhitespace }) {
            let p = String(piece)
            if let a = p.firstIndex(where: { "'’ʼ".contains($0) }) {
                let stem = DecisionText.fold(String(p[..<a]))
                if cand.hasPrefix(stem), cand.count - stem.count <= 4, stem.count >= 3 { return stem }
            }
        }
        for suffix in ["nda", "nde", "da", "de", "ta", "te"] where cand.hasSuffix(suffix) && cand.count - suffix.count >= 4 { cand = String(cand.dropLast(suffix.count)); break }
        return cand.count >= 3 ? cand : nil
    }

    private func projectQuery(_ raw: String, _ w: W) -> Decision? {
        guard let intent = parsers.continuity(raw) else { return nil }
        // the registry NAME in the sentence (“Hamam'da en son ne yaptık”) is kept even when the continuity grammar did not extract it
        let named = SemanticLexicon(parsers: parsers).projectName(in: w.t)
        switch intent {
        case .status(let p, _): return Decision(intent: .projectQuery, confidence: 0.9, normalized: "Tell me the project status", target: (p ?? named).map(canonicalName), action: "status", projectResolution: true, provenance: .existingParser)
        case .lastDone(let p): return Decision(intent: .projectQuery, confidence: 0.9, normalized: "What did we do last in the project?", target: (p ?? named).map(canonicalName), action: "last_done", projectResolution: true, provenance: .existingParser)
        case .lastReport(let p, _): return Decision(intent: .projectQuery, confidence: 0.9, normalized: "Show the last task report", target: (p ?? named).map(canonicalName), action: "last_report", projectResolution: true, provenance: .existingParser)
        case .next(let p): return Decision(intent: .projectQuery, confidence: 0.9, normalized: "What is next in the project?", target: (p ?? named).map(canonicalName), action: "next", projectResolution: true, provenance: .existingParser)
        default: return nil
        }
    }

    // MARK: Computer Use: media and “look at my screen”

    private func mediaOrObserve(_ w: W, question: Bool) -> Decision? {
        let mediaObject = w.pre("video", "film", "muzik", "muzig", "sarki", "music", "song", "podcast", "oynatici", "player", "youtube", "netflix", "dizi", "episode", "bolum", "clip")
        let mediaVerb = w.t.contains { t in ["devam", "devamet", "oynat", "oynatir", "baslat", "baslatir", "durdur", "durdurur", "duraklat", "duraklatir", "cal", "calar", "resume", "play", "pause", "continue", "unpause", "stop", "start", "surdur", "surdurur"].contains(t) || t.hasPrefix("devam") || t.hasPrefix("oynat") || t.hasPrefix("durdur") || t.hasPrefix("duraklat") || t.hasPrefix("baslat") || t.hasPrefix("surdur") }
        if mediaObject, mediaVerb, !w.pre("calis"), w.t.count <= 12 {
            return Decision(intent: .computerUse, confidence: 0.92, normalized: "Control the media player in the open application (play, pause or resume)", target: "media", action: "media", execution: true, computerUse: true, provenance: .deterministicGrammar)
        }
        let screen = w.pre("ekran") || w.has("screen", "display", "monitor")
        let lookImperative = (w.pre("bak") && !w.pre("bakabil")) || w.phrase("look at", "take a look", "have a look", "ne var", "what s on", "whats on", "what is on", "describe", "tarif et", "anlat bana ekran")
        if screen, lookImperative, !(question && w.pre("gorebil", "bakabil")) {
            return Decision(intent: .computerUse, confidence: 0.92, normalized: "Look at the front window and describe what is on screen", target: "screen", action: "observe", execution: true, computerUse: true, provenance: .deterministicGrammar)
        }
        return nil
    }

    /// “Claude Code'u kullan.” — a request to use a named engine. Without a task it selects nothing and runs nothing; it is a classification so the router can ask what the engine is for.
    private func providerChoice(_ w: W, question: Bool) -> Decision? {
        guard !question, w.t.count <= 5 else { return nil }
        let engineNames = ["claude", "codex", "opencode", "qwen"]
        func engineOf(_ t: String) -> String? { engineNames.first { t.hasPrefix($0) } }
        guard let engine = w.t.compactMap(engineOf).first ?? (w.phrase("open code") ? "opencode" : nil) else { return nil }
        let allowed: Set<String> = ["kullan", "kullanir", "kullanalim", "use", "using", "with", "dene", "try", "sec", "choose", "switch", "gec", "ile", "yap", "code", "open", "ya", "gecelim", "lutfen"]
        let onlyKnownWords = w.t.allSatisfy { allowed.contains($0) || engineOf($0) != nil || $0.hasPrefix("code") }
        guard onlyKnownWords, w.pre("kullan", "use", "dene", "try", "sec", "choose", "switch", "gec") else { return nil }
        return Decision(intent: .providerCapability, confidence: 0.85, normalized: "Use \(engine) as the engine for the next request", target: engine, action: "prefer_provider", ambiguity: .ambiguous(question: "For which task?"), provenance: .deterministicGrammar)
    }

    // MARK: Questions about JARVIS' own abilities and models (answered from state, never from a model's identity)

    private func capabilityQuestion(_ raw: String, _ w: W) -> Decision? {
        guard let r = parsers.readiness(raw) else { return nil }
        let target: String?
        switch r {
        case .systemStatus: return nil
        case .voice: return Decision(intent: .voiceStatus, confidence: 0.9, normalized: "Is the voice system ready?", action: "query", provenance: .existingParser)
        case .provider(let p): target = p
        case .canUse(let x): target = x
        case .localModels(let m): target = m ?? "local"
        case .overall: target = "overall"
        case .mcp: target = "mcp"
        case .permissions: target = "permissions"
        case .unity: target = "unity"
        case .version: target = "version"
        case .providers: target = "providers"
        case .tools: target = "tools"
        case .capabilities: target = "capabilities"
        case .screenAbility: target = "screen"
        case .fileAbility: target = "files"
        case .webAbility: target = "web"
        case .memoryAbility: target = "memory"
        }
        return Decision(intent: .providerCapability, confidence: 0.95, normalized: "What can JARVIS use or do (\(target ?? "overview"))?", target: target, action: "query", provenance: .existingParser)
    }

    // MARK: JARVIS' own pages, HUD and applications (the typed action grammar)

    private func selfAndApplications(_ raw: String) -> Decision? {
        guard let a = parsers.action(raw) else { return nil }
        switch a {
        case .navigate(let s): return Decision(intent: .jarvisNavigation, confidence: 0.97, normalized: "Open the \(s.rawValue) page of JARVIS", target: s.rawValue, action: "navigate", execution: true, provenance: .existingParser)
        case .showFullHUD: return Decision(intent: .jarvisNavigation, confidence: 0.97, normalized: "Show the full JARVIS screen", target: "full_hud", action: "show_full", execution: true, provenance: .existingParser)
        case .showCompactHUD: return Decision(intent: .jarvisNavigation, confidence: 0.97, normalized: "Show the compact JARVIS view", target: "compact_hud", action: "show_compact", execution: true, provenance: .existingParser)
        case .closeHUD: return Decision(intent: .jarvisNavigation, confidence: 0.97, normalized: "Close the JARVIS window", target: "hud", action: "close", execution: true, provenance: .existingParser)
        case .launchApp(let app): return Decision(intent: .macosApplicationAction, confidence: app.heardAs == nil ? 0.97 : 0.8, normalized: "Open the application \(app.display)", target: app.display, action: "launch", execution: true, provenance: .existingParser)
        case .openProject(let name, _): return Decision(intent: .projectOpen, confidence: 0.95, normalized: "Open the \(name) project", target: name, action: "open", execution: true, projectResolution: true, provenance: .existingParser)
        case .openFolder(let f): return Decision(intent: .macosApplicationAction, confidence: 0.95, normalized: "Open the \(f.display) folder", target: f.display, action: "open_folder", execution: true, provenance: .existingParser)
        }
    }

    // MARK: Settings (“Biraz daha hızlı konuş”, “Az önceki ayarı geri al”)

    private func settingsChange(_ raw: String) -> Decision? {
        guard let s = parsers.settings(raw) else { return nil }
        let action: String
        switch s {
        case .restore: action = "revert"
        case .lastChange, .listSettings: action = "query"
        case .stopListening, .sleepMode: action = "voice_session"
        default: action = "change"
        }
        return Decision(intent: .settingsChange, confidence: 0.95, normalized: "Change or revert a JARVIS setting", target: nil, action: action, execution: action != "query", provenance: .existingParser)
    }

    // MARK: A correction sentence the existing parser owns (“Hayır, demek istediğim …”)

    private func correctionForm(_ raw: String, _ w: W, context: DecisionContext) -> Decision? {
        if let c = parsers.correction(raw) {
            var remainder = c.remainder
            for lead in ["ben ", "yani ", "aslinda ", "i "] where DecisionText.fold(remainder).hasPrefix(lead) && remainder.split(separator: " ").count > 1 { remainder = remainder.split(separator: " ", maxSplits: 1).map(String.init).last ?? remainder }
            return Decision(intent: .correction, confidence: c.strength == .strong ? 0.95 : 0.7, normalized: remainder.isEmpty ? "The user says the last answer was wrong" : "The user corrects the request: \(remainder)", target: remainder.isEmpty ? nil : remainder,
                            action: remainder.isEmpty ? "ask_what_meant" : "reroute", provenance: .existingParser)
        }
        return nil
    }

    // MARK: Small talk

    private func smallTalk(_ w: W) -> Decision? {
        let social: Set<String> = ["merhaba", "selam", "hello", "hi", "hey", "gunaydin", "iyi", "aksamlar", "geceler", "gunler", "nasilsin", "naber", "tesekkurler", "tesekkur", "sagol", "sag", "ol", "thanks", "thank", "you", "good", "morning", "evening", "night", "how", "are", "jarvis", "nasil", "gidiyor", "ne", "haber", "gule", "gule", "gorusuruz", "bye", "goodbye", "hosca", "kal", "eyvallah", "cok", "ederim", "rica", "nbr"]
        guard w.t.count <= 5, w.t.allSatisfy({ social.contains($0) }) else { return nil }
        return Decision(intent: .conversation, confidence: 0.9, normalized: "Social greeting or thanks", action: "smalltalk", provenance: .deterministicGrammar)
    }
}

// MARK: - Spoken restatement

/// “Sofany değil, Safari dedim.” / “Hayır Safari dedim.” / “Wisp değil, sesim geliyor mu dedim sana.” / “I said Safari, not Sofany.” — the user repeats what they said. Pure grammar: it extracts what was
/// (mis)heard and what was meant; applying it to the previous sentence is done by `apply`, bounded to that one sentence and never stored beyond the conversation.
struct SpokenRestatement: Equatable, Sendable {
    var wrong: String?
    var right: String
    /// True when the sentence said so outright (“… dedim”, “X değil, Y”, “I said …”); a bare fragment (“Hayır Safari.”) is not trusted by itself.
    var explicit: Bool

    static func parse(_ raw: String) -> SpokenRestatement? {
        let words = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count >= 2, words.count <= 16 else { return nil }
        let folded = words.map { DecisionText.fold($0).filter { $0.isLetter || $0.isNumber } }
        let saidTokens: Set<String> = ["dedim", "demistim", "dedimki", "dedimya", "demistimki"]
        let hasSaid = folded.contains(where: { saidTokens.contains($0) }) || (folded.first == "i" && folded.dropFirst().first == "said")
        let negIdx = folded.firstIndex(where: { $0 == "degil" || $0 == "not" })
        let hayirLead = folded.first == "hayir" || folded.first == "no" || folded.first == "yok"
        var wrong: String?
        var rightWords: [String] = words
        var rightFolded = folded
        if let n = negIdx, hasSaid, let sIdx = folded.firstIndex(where: { saidTokens.contains($0) }), sIdx > 0, sIdx + 1 < n {
            // “Safari dedim, Sofany değil”: the restated word comes FIRST, the mis-heard one between “dedim” and “değil”
            wrong = words[(sIdx + 1)..<n].joined(separator: " "); rightWords = Array(words[..<sIdx]); rightFolded = Array(folded[..<sIdx])
        } else if let n = negIdx, hasSaid || hayirLead {
            if n > 0, folded[0] != "i" {
                wrong = words[0..<n].joined(separator: " "); rightWords = Array(words[(n + 1)...]); rightFolded = Array(folded[(n + 1)...])
            } else if n > 0 || folded.first == "i" {
                // “I said Safari, not Sofany”
                wrong = words[(n + 1)...].joined(separator: " "); rightWords = Array(words[..<n]); rightFolded = Array(folded[..<n])
            }
        } else if hasSaid {
            // “Hayır Safari dedim.” / “Safari dedim.” / “I said Safari.”
        } else if hayirLead, words.count <= 4, !folded.contains(where: { ["tesekkurler", "tesekkur", "thanks", "thank", "sagol", "evet", "yes"].contains($0) }) {
            // “Hayır Safari.” (no comma needed when it is just a fragment)
        } else { return nil }
        // strip the framing words from the restated part
        let framing: Set<String> = ["hayir", "no", "yok", "dedim", "demistim", "dedimki", "dedimya", "demistimki", "i", "said", "degil", "not", "sana", "sen", "ya", "yani", "ben", "aslinda", "actually", "to", "you", "bana", "dedim.", "lutfen", "please", "hayirhayir"]
        while let f = rightFolded.first, framing.contains(f), rightWords.count > 1 { rightWords.removeFirst(); rightFolded.removeFirst() }
        while let l = rightFolded.last, framing.contains(l), rightWords.count > 1 { rightWords.removeLast(); rightFolded.removeLast() }
        if let f = rightFolded.first, framing.contains(f) { return nil }
        let right = rightWords.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:!?-–—\"“”"))
        guard !right.isEmpty, right.count <= 120 else { return nil }
        let cleanWrong = wrong?.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:!?-–—\"“”")).nilIfEmpty
        // a restatement that is a bare “Hayır.” is not one
        if rightFolded.isEmpty { return nil }
        return SpokenRestatement(wrong: cleanWrong, right: right, explicit: hasSaid || negIdx != nil)
    }

    /// Replaces the mis-heard word in the previous sentence by the restated one (whole words only, case suffixes after an apostrophe kept). nil = the wrong word does not occur there.
    static func apply(wrong: String, right: String, to previous: String) -> String? {
        let wrongFolded = DecisionText.fold(wrong).filter { $0.isLetter || $0.isNumber }
        guard wrongFolded.count >= 2 else { return nil }
        var changed = false
        let out = previous.split(separator: " ", omittingEmptySubsequences: false).map { piece -> String in
            let p = String(piece)
            let stemEnd = p.firstIndex(where: { "'’ʼ".contains($0) })
            let stem = stemEnd.map { String(p[..<$0]) } ?? p
            let tail = stemEnd.map { String(p[$0...]) } ?? ""
            let trimmedStem = stem.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?\"“”"))
            let f = DecisionText.fold(trimmedStem).filter { $0.isLetter || $0.isNumber }
            guard !f.isEmpty, f == wrongFolded || (f.hasPrefix(wrongFolded) && f.count - wrongFolded.count <= 3 && stemEnd == nil) else { return p }
            changed = true
            let leading = stem.prefix(while: { ",.;:!?\"“”".contains($0) })
            let trailing = String(stem.reversed().prefix(while: { ",.;:!?\"“”".contains($0) }).reversed())
            return String(leading) + right + tail + trailing
        }.joined(separator: " ")
        return changed ? out : nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
