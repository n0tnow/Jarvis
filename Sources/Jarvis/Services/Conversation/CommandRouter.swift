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
        "get", "check", "list", "pull", "return", "back", "all",
    ]
    private static let tolerated: Set<String> = ["to", "tab", "page", "view", "screen", "section", "up", "on", "for", "ekrani", "sayfasi", "bolumu", "ekranini", "sayfasini", "bolumunu"]
    /// Ambiguous single words that only count as a target together with a navigation verb ("go home", never bare "home").
    private static let needsVerb: Set<String> = ["home", "panel", "paneli", "task", "options", "setting", "ayar", "overview", "dashboardu"]

    private enum Target { case section(HUDSection), settings }

    /// Single-word and two-word targets (bigrams listed with a space).
    private static let targets: [String: (Target, ReplyLanguage)] = [
        "report": (.section(.report), .en), "reports": (.section(.report), .en),
        "rapor": (.section(.report), .tr), "raporu": (.section(.report), .tr), "raporlar": (.section(.report), .tr), "raporlari": (.section(.report), .tr), "rapora": (.section(.report), .tr),
        "tasks": (.section(.tasks), .en), "task": (.section(.tasks), .en), "task list": (.section(.tasks), .en), "tasklist": (.section(.tasks), .en),
        "proposals": (.section(.tasks), .en), "proposal": (.section(.tasks), .en), "suggestions": (.section(.tasks), .en), "suggestion": (.section(.tasks), .en), "oneriler": (.section(.tasks), .tr),
        "gorevler": (.section(.tasks), .tr), "gorevleri": (.section(.tasks), .tr), "gorevlerim": (.section(.tasks), .tr), "gorev listesi": (.section(.tasks), .tr),
        "gorevlere": (.section(.tasks), .tr), "gorevi": (.section(.tasks), .tr),
        "agents": (.section(.agents), .en), "agent": (.section(.agents), .en), "workers": (.section(.agents), .en), "worker": (.section(.agents), .en), "observatory": (.section(.agents), .en),
        "ajanlar": (.section(.agents), .tr), "ajanlari": (.section(.agents), .tr), "ajan": (.section(.agents), .tr), "ajanlara": (.section(.agents), .tr), "isciler": (.section(.agents), .tr), "iscileri": (.section(.agents), .tr),
        "research": (.section(.research), .en), "researches": (.section(.research), .en), "sources": (.section(.research), .en), "downloads": (.section(.research), .en), "quarantine": (.section(.research), .en),
        "arastirma": (.section(.research), .tr), "arastirmayi": (.section(.research), .tr), "arastirmalar": (.section(.research), .tr), "arastirmalari": (.section(.research), .tr), "arastirmaya": (.section(.research), .tr), "kaynaklar": (.section(.research), .tr), "kaynaklari": (.section(.research), .tr),
        "system": (.section(.system), .en), "sistem": (.section(.system), .tr), "sistemi": (.section(.system), .tr), "sisteme": (.section(.system), .tr),
        "memory": (.section(.memory), .en), "memories": (.section(.memory), .en),
        "hafiza": (.section(.memory), .tr), "hafizayi": (.section(.memory), .tr), "hafizaya": (.section(.memory), .tr), "bellek": (.section(.memory), .tr), "bellegi": (.section(.memory), .tr), "bellege": (.section(.memory), .tr),
        "learning": (.section(.learning), .en), "what you learned": (.section(.learning), .en), "ogrenme": (.section(.learning), .tr), "ogrendiklerim": (.section(.learning), .tr), "ogrendiklerini": (.section(.learning), .tr),
        "capabilities": (.section(.capabilities), .en), "capability": (.section(.capabilities), .en), "skills": (.section(.capabilities), .en), "yetenekler": (.section(.capabilities), .tr), "yetenekleri": (.section(.capabilities), .tr), "yeteneklere": (.section(.capabilities), .tr),
        "computer use": (.section(.computer), .en), "computer control": (.section(.computer), .en), "bilgisayar kontrolu": (.section(.computer), .tr),
        "dashboard": (.section(.dashboard), .en), "dashboardu": (.section(.dashboard), .tr), "home": (.section(.dashboard), .en), "overview": (.section(.dashboard), .en),
        "ana ekran": (.section(.dashboard), .tr), "ana ekrana": (.section(.dashboard), .tr), "ana sayfa": (.section(.dashboard), .tr), "kontrol paneli": (.section(.dashboard), .tr), "panel": (.section(.dashboard), .tr),
        "ana ekrani": (.section(.dashboard), .tr), "ana sayfayi": (.section(.dashboard), .tr), "kontrol panelini": (.section(.dashboard), .tr), "paneli": (.section(.dashboard), .tr),
        "settings": (.settings, .en), "setting": (.settings, .en), "preferences": (.settings, .en), "options": (.settings, .en),
        "ayarlar": (.settings, .tr), "ayarlari": (.settings, .tr), "ayarlara": (.settings, .tr), "ayar": (.settings, .tr),
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
                         "what state", "current status", "show status", "status update", "what are you up to",
                         "whats status", "what is status", "what is current status", "whats current status", "task status", "status report",
                         "what are you doing right", "hows task going", "how is task going", "what is going on", "whats going on"],
                    tr: ["durum", "durum ne", "durumu ne", "durumun ne", "durumun nedir", "durum nedir", "ne yapiyorsun", "su an ne yapiyorsun", "ne is yapiyorsun",
                         "hangi durumdasin", "durumunu goster", "su anda ne yapiyorsun", "durumun nasil", "su an durumun nasil", "durum nasil"]),
            phrases(.showAgentStatus,
                    en: ["which agent is running", "which agents are running", "what agents are running", "which agent is working", "who is working", "what agent is running", "running agents", "which agent"],
                    tr: ["hangi agent calisiyor", "hangi ajan calisiyor", "hangi ajanlar calisiyor", "hangi agentlar calisiyor", "kim calisiyor", "ajanlar ne yapiyor", "ajan durumu"]),
            phrases(.showTestStatus,
                    en: ["did the tests pass", "have the tests passed", "do the tests pass", "did tests pass", "are the tests passing", "test status", "tests status", "how are the tests"],
                    tr: ["testler gecti mi", "testler gecti", "testler nasil", "test durumu", "testleri gecti mi", "testler basarili mi"]),
            phrases(.pauseTask,
                    en: ["pause", "pause task", "pause current task", "pause it", "pause that", "hold task", "hold current task"],
                    tr: ["duraklat", "gorevi duraklat", "duraklat gorevi", "gorevi beklet", "mevcut gorevi duraklat"]),
            phrases(.resumeTask,
                    en: ["resume", "resume task", "resume current task", "continue task", "continue current task", "resume it", "unpause", "unpause task"],
                    tr: ["gorevi surdur", "gorevi devam ettir", "gorevi devam et", "mevcut gorevi surdur", "devam et gorevi"]),
            phrases(.stopTask,
                    en: ["stop", "stop task", "stop current task", "stop it", "stop that", "cancel task", "cancel current task", "abort", "abort task", "kill task"],
                    tr: ["durdur", "dur", "gorevi durdur", "mevcut gorevi durdur", "gorevi iptal et"]),
            phrases(.openCompactHUD,
                    en: ["compact", "compact hud", "open compact", "show compact", "open compact hud", "show compact hud", "compact view", "mini", "minimize",
                         "go compact", "switch compact", "switch to compact"],
                    tr: ["kompakt", "kompakt hud", "kompakt gorunum", "kompakt hud ac", "kucult"]),
            phrases(.openFullHUD,
                    en: ["full", "full hud", "open full", "show full", "open full hud", "show full hud", "full view", "expand", "maximize", "open hud", "show hud", "go full", "switch to full"],
                    tr: ["tam gorunum", "tam ekran", "buyut", "hud ac"]),
            phrases(.closeHUD,
                    en: ["close", "close hud", "close it", "hide", "hide hud", "dismiss", "go away", "minimize yourself", "hide yourself", "close all", "close window"],
                    tr: ["kapat", "gizle", "hud kapat", "kendini kucult", "kendini gizle", "pencereyi kapat"]),
            phrases(.cancelGeneration,
                    en: ["stop generating", "stop generation", "cancel generation", "cancel response", "stop response", "stop answering", "stop talking", "stop the answer", "cancel answer"],
                    tr: ["yaniti durdur", "cevabi durdur", "uretimi durdur", "yaniti iptal et", "cevabi iptal et", "konusmayi kes"]),
            phrases(.clearConversation,
                    en: ["clear conversation", "clear chat", "clear history", "clear messages", "reset conversation", "new conversation"],
                    tr: ["sohbeti temizle", "konusmayi temizle", "gecmisi temizle", "mesajlari temizle"]),
        ]
        for g in groups { t.merge(g) { a, _ in a } }
        return t
    }()

    /// Bare, easily-ambiguous words ("open", "continue", "clear", "iptal", "ac"…) count as commands ONLY when the user
    /// addressed JARVIS ("Jarvis, continue"). Otherwise they are ordinary chat and fall through to the provider.
    private static let addressedOnly: [String: Match] = {
        var t: [String: Match] = [:]
        for p in ["open", "show"] { t[p] = Match(intent: .openFullHUD, language: .en) }
        for p in ["ac", "goster", "tam"] { t[p] = Match(intent: .openFullHUD, language: .tr) }
        t["continue"] = Match(intent: .resumeTask, language: .en)
        for p in ["devam", "devam et"] { t[p] = Match(intent: .resumeTask, language: .tr) }
        t["clear"] = Match(intent: .clearConversation, language: .en)
        t["temizle"] = Match(intent: .clearConversation, language: .tr)
        for p in ["iptal", "iptal et"] { t[p] = Match(intent: .stopTask, language: .tr) }
        t["cancel"] = Match(intent: .stopTask, language: .en)
        t["kucult"] = Match(intent: .openCompactHUD, language: .tr)
        return t
    }()

    // MARK: Matching

    static func match(_ input: NormalizedInput) -> Match? {
        let tokens = input.tokens
        guard !tokens.isEmpty, tokens.count <= 6 else { return nil }

        if let exact = phraseTable[input.text] { return exact }
        if input.addressedJarvis, let bare = addressedOnly[input.text] { return bare }
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
        if tokens.count == 1, needsVerb.contains(tokens[0]) { return nil }   // bare "home"/"panel"/"task" is just a word
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
    private static let greetingsEN: Set<String> = [
        "hello", "hi", "hey", "yo", "hello there", "hi there", "hey there", "good morning", "good afternoon", "good evening",
    ]
    private static let greetingsTR: Set<String> = ["selam", "merhaba", "gunaydin", "iyi aksamlar", "iyi gunler", "selamlar"]
    private static let thanksEN: Set<String> = ["thanks", "thank you", "thx", "ty", "thanks a lot", "thank you very much", "many thanks"]
    private static let thanksTR: Set<String> = ["tesekkurler", "tesekkur ederim", "cok tesekkurler", "sagol", "sag ol", "eyvallah"]

    static func match(_ input: NormalizedInput) -> (LocalReply, ReplyLanguage)? {
        // Only "Jarvis" / "hey Jarvis" → greeting
        if input.text.isEmpty && input.addressedJarvis { return (.greeting, input.language) }
        if greetingsEN.contains(input.text) { return (.greeting, .en) }
        if greetingsTR.contains(input.text) { return (.greeting, .tr) }
        if thanksEN.contains(input.text) { return (.thanks, .en) }
        if thanksTR.contains(input.text) { return (.thanks, .tr) }
        return nil
    }
}
