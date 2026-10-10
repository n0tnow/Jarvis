import Foundation

/// Deterministic (no LLM) command recognition over `NormalizedInput`.
///
/// Aliases are explicit, folded-ASCII strings so they stay testable and cheap to extend (Turkish forms are
/// written without diacritics because the normalizer folds "Raporu Aç" → "raporu ac").
///
/// Two mechanisms:
///  • Navigation: at most one *target* word ("report", "gorevleri"…) plus optional navigation verbs / filler,
///    ≤ 5 tokens. "show me the report", "go to report", "raporu ac", "report" all resolve; "explain the system
///    architecture" does not (verb isn't navigational, too long), and two targets are ambiguous → no match.
///  • Phrases: exact normalized phrases for status / task control / HUD / conversation commands.
enum CommandRouter {
    struct Match: Equatable, Sendable {
        let intent: JarvisIntent
        let language: ReplyLanguage
    }

    // MARK: Navigation vocabulary

    private static let navVerbs: Set<String> = [
        "open", "show", "go", "goto", "display", "view", "switch", "navigate", "see", "bring", "take", "load", "give",
        "ac", "goster", "git", "gec", "getir", "ver", "gor",
    ]
    private static let tolerated: Set<String> = ["to", "tab", "page", "view", "screen", "section", "up", "on", "ekrani", "sayfasi", "bolumu"]

    private enum Target { case section(HUDSection), settings }

    /// Single-word and two-word targets (bigrams listed with a space).
    private static let targets: [String: (Target, ReplyLanguage)] = [
        "report": (.section(.report), .en), "reports": (.section(.report), .en),
        "rapor": (.section(.report), .tr), "raporu": (.section(.report), .tr), "raporlar": (.section(.report), .tr), "raporlari": (.section(.report), .tr),
        "tasks": (.section(.tasks), .en), "task": (.section(.tasks), .en), "task list": (.section(.tasks), .en), "tasklist": (.section(.tasks), .en),
        "gorevler": (.section(.tasks), .tr), "gorevleri": (.section(.tasks), .tr), "gorevlerim": (.section(.tasks), .tr), "gorev listesi": (.section(.tasks), .tr),
        "system": (.section(.system), .en), "sistem": (.section(.system), .tr), "sistemi": (.section(.system), .tr),
        "memory": (.section(.memory), .en), "memories": (.section(.memory), .en),
        "hafiza": (.section(.memory), .tr), "hafizayi": (.section(.memory), .tr), "bellek": (.section(.memory), .tr), "bellegi": (.section(.memory), .tr),
        "dashboard": (.section(.dashboard), .en), "home": (.section(.dashboard), .en), "overview": (.section(.dashboard), .en), "main": (.section(.dashboard), .en),
        "ana ekran": (.section(.dashboard), .tr), "ana sayfa": (.section(.dashboard), .tr), "kontrol paneli": (.section(.dashboard), .tr), "panel": (.section(.dashboard), .tr),
        "ana ekrani": (.section(.dashboard), .tr), "ana sayfayi": (.section(.dashboard), .tr), "kontrol panelini": (.section(.dashboard), .tr), "paneli": (.section(.dashboard), .tr),
        "settings": (.settings, .en), "setting": (.settings, .en), "preferences": (.settings, .en), "options": (.settings, .en),
        "ayarlar": (.settings, .tr), "ayarlari": (.settings, .tr), "ayar": (.settings, .tr),
    ]

    // MARK: Exact phrases

    private static func phrases(_ intent: JarvisIntent, en: [String], tr: [String] = []) -> [String: Match] {
        var out: [String: Match] = [:]
        for p in en { out[p] = Match(intent: intent, language: .en) }
        for p in tr { out[p] = Match(intent: intent, language: .tr) }
        return out
    }

    private static let phraseTable: [String: Match] = {
        var t: [String: Match] = [:]
        let groups: [[String: Match]] = [
            phrases(.showStatus,
                    en: ["status", "state", "your status", "your state", "what are you doing", "what you doing", "what are you working on",
                         "what is your status", "what is your state", "whats your status", "whats your state", "what state are you in",
                         "what state", "current status", "show status", "status update", "what are you up to"],
                    tr: ["durum", "durumun ne", "durumun nedir", "durum nedir", "ne yapiyorsun", "su an ne yapiyorsun", "ne is yapiyorsun",
                         "hangi durumdasin", "durumunu goster"]),
            phrases(.pauseTask,
                    en: ["pause", "pause task", "pause current task", "pause it", "pause the task", "hold task", "hold current task"],
                    tr: ["duraklat", "gorevi duraklat", "duraklat gorevi", "gorevi beklet", "mevcut gorevi duraklat"]),
            phrases(.resumeTask,
                    en: ["resume", "resume task", "resume current task", "continue", "continue task", "continue current task", "unpause", "unpause task"],
                    tr: ["devam", "devam et", "gorevi surdur", "surdur", "gorevi devam ettir", "gorevi devam et", "mevcut gorevi surdur"]),
            phrases(.stopTask,
                    en: ["stop", "stop task", "stop current task", "stop the task", "cancel task", "cancel current task", "abort", "abort task", "kill task"],
                    tr: ["durdur", "gorevi durdur", "mevcut gorevi durdur", "gorevi iptal et", "iptal et", "iptal"]),
            phrases(.openCompactHUD,
                    en: ["compact", "compact hud", "open compact", "show compact", "open compact hud", "show compact hud", "compact view", "mini", "minimize"],
                    tr: ["kompakt", "kompakt hud", "kompakt gorunum", "kompakt hud ac", "kucult"]),
            phrases(.openFullHUD,
                    en: ["full", "full hud", "open full", "show full", "open full hud", "show full hud", "full view", "expand", "open", "show", "open hud", "show hud"],
                    tr: ["tam", "tam gorunum", "tam ekran", "buyut", "ac", "goster", "hud ac"]),
            phrases(.closeHUD,
                    en: ["close", "close hud", "close it", "hide", "hide hud", "dismiss", "go away", "minimize yourself", "hide yourself", "close all", "close window"],
                    tr: ["kapat", "gizle", "hud kapat", "kendini kucult", "kendini gizle", "pencereyi kapat"]),
            phrases(.clearConversation,
                    en: ["clear", "clear conversation", "clear chat", "clear history", "clear messages", "reset conversation", "new conversation"],
                    tr: ["temizle", "sohbeti temizle", "konusmayi temizle", "gecmisi temizle", "mesajlari temizle"]),
        ]
        for g in groups { t.merge(g) { a, _ in a } }
        return t
    }()

    // MARK: Matching

    static func match(_ input: NormalizedInput) -> Match? {
        let tokens = input.tokens
        guard !tokens.isEmpty, tokens.count <= 6 else { return nil }

        if let exact = phraseTable[input.text] { return exact }
        return matchNavigation(tokens)
    }

    private static func matchNavigation(_ tokens: [String]) -> Match? {
        guard tokens.count <= 5 else { return nil }
        var found: [(Target, ReplyLanguage)] = []
        var consumed = Set<Int>()

        // bigram targets first ("task list", "ana ekran")
        var i = 0
        while i < tokens.count {
            if i + 1 < tokens.count, let hit = targets[tokens[i] + " " + tokens[i + 1]] {
                found.append(hit); consumed.insert(i); consumed.insert(i + 1); i += 2; continue
            }
            if let hit = targets[tokens[i]] { found.append(hit); consumed.insert(i) }
            i += 1
        }
        guard found.count == 1 else { return nil }                       // none or ambiguous
        for (idx, tok) in tokens.enumerated() where !consumed.contains(idx) {
            guard navVerbs.contains(tok) || tolerated.contains(tok) else { return nil }   // e.g. "explain …" → no
        }
        let (target, lang) = found[0]
        switch target {
        case .section(let s): return Match(intent: .openSection(s), language: lang)
        case .settings: return Match(intent: .openSettings, language: lang)
        }
    }
}

/// Very small deterministic social replies.
enum LocalConversation {
    private static let greetings: Set<String> = [
        "hello", "hi", "hey", "yo", "hello there", "hi there", "hey there", "good morning", "good afternoon", "good evening",
        "selam", "merhaba", "gunaydin", "iyi aksamlar", "iyi gunler", "selamlar",
    ]
    private static let thanks: Set<String> = [
        "thanks", "thank you", "thx", "ty", "thanks a lot", "thank you very much", "many thanks",
        "tesekkurler", "tesekkur ederim", "cok tesekkurler", "sagol", "sag ol", "eyvallah",
    ]

    static func match(_ input: NormalizedInput) -> (LocalReply, ReplyLanguage)? {
        // Only "Jarvis" / "hey Jarvis" → greeting
        if input.text.isEmpty && input.addressedJarvis { return (.greeting, input.language) }
        if greetings.contains(input.text) { return (.greeting, input.language) }
        if thanks.contains(input.text) { return (.thanks, input.language) }
        return nil
    }
}
