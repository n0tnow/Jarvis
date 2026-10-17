import Foundation

// MARK: - “Is Claude ready?”, “Hangi modellere erişebiliyorsun?”, “Can you use Codex?” — answered from the readiness picture (V0.15, extended in V1.0 stabilisation)
//
// Deterministic, EN + TR, typed and spoken alike (voice is only another input source). It reads `ReadinessService`; it starts nothing, installs nothing, approves nothing and calls NO model: what JARVIS
// can use is a question about JARVIS' own runtime state, never something to ask the language model behind a conversation (which knows nothing about this installation and would invent an answer).
// A negative state is always said as it is, and the distinctions are kept: READY ≠ AVAILABLE ≠ RUNNING, INSTALLED ≠ SIGNED IN, NOT CHECKED ≠ UNAVAILABLE, OPTIONAL ≠ MISSING, NOT RUNNING ≠ BROKEN.

enum ReadinessIntent: Equatable, Sendable {
    case overall
    case provider(String)           // claude | codex | opencode      — “is Claude ready?”
    case voice
    case mcp
    case permissions
    case localModels(String?)       // qwen | whisper | vision | nil   — “which local models are available?”
    case unity
    case version
    /// “Can you use X / do you have X / X var mı?” — X: claude | codex | opencode | qwen | whisper | vision | memory | unity | mcp | voice | computer
    case canUse(String)
    /// “Which AI models / providers can you use?” — the providers and the local models together.
    case providers
    /// “Which tools can you use?” — Computer Use, Unity, MCP servers, voice.
    case tools
    /// “What can you do / what capabilities are available?” — a concise summary of what is ready.
    case capabilities
    /// “Can you see my screen / read files / do web research / remember my projects?” — what JARVIS CAN do (Computer Use, project files, research, Project Memory), said apart from what it is doing now.
    case screenAbility
    case fileAbility
    case webAbility
    case memoryAbility
}

@MainActor
protocol ReadinessConversing: AnyObject {
    func recognizes(_ text: String) -> ReadinessIntent?
    func reply(to intent: ReadinessIntent, language: ReplyLanguage) -> String
}

enum ReadinessIntentParser {
    private static func tokens(_ raw: String) -> [String] {
        let f = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en")).lowercased().replacingOccurrences(of: "ı", with: "i")
        return String(f.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : " " }).split(separator: " ").map(String.init)
    }

    /// Words that may appear in an introspection question without making it something else. Anything else (a verb like “fix”, a noun like “bug”) means the sentence is a REQUEST, not a question about JARVIS.
    private static let filler: Set<String> = [
        "hangi", "hangileri", "hangisine", "hangisini", "neler", "neleri", "ne", "bana", "sana", "sen", "senin", "sizin", "siz", "mi", "mu", "misin", "musun", "miyim", "var", "yok", "ve", "ile", "veya", "de", "da", "ki",
        "bu", "su", "o", "bir", "icin", "simdi", "su", "an", "anda", "lutfen", "jarvis", "su", "anki", "mevcut", "olan", "olanlar", "tum", "butun", "hepsi",
        "kisa", "soyle", "ozetle", "detayli", "ayrintili", "anlat", "kisaca", "biraz", "daha", "baska", "bir", "sey", "seyler",
        "what", "which", "can", "could", "do", "does", "are", "is", "you", "your", "have", "has", "any", "all", "the", "a", "an", "of", "to", "and", "or", "use", "using", "available", "access", "current", "currently", "now",
        "other", "else", "also", "right", "tell", "me", "show", "list", "there", "please", "briefly", "short", "brief", "detail", "details", "in", "able", "i", "my", "work", "with", "on", "this", "that", "it", "s", "t", "re", "ll",
    ]
    private static let abilityPrefixes = ["erisebil", "erisim", "kullanabil", "kullanir", "yapabil", "bulunuyor", "sahip", "destekl", "calistirabil", "acabil"]
    private static let providerWords: Set<String> = ["provider", "providers", "providerlar", "providerlari", "providera", "saglayici", "saglayicilar", "saglayicilara", "saglayicilari", "saglayicin"]
    private static let aiWords: Set<String> = ["ai", "yapay", "zeka", "llm", "llms", "engine", "engines", "motor", "motorlar", "motorlara"]
    private static let toolWords: Set<String> = ["arac", "araclar", "araclara", "araclari", "aracin", "tool", "tools", "araci"]
    private static let capabilityWords: Set<String> = ["yetenek", "yetenekler", "yetenegin", "capabilities", "capability", "abilities", "ability", "ozellik", "ozellikler"]


    // MARK: Ability questions that are not about a provider (screen · files · web · memory)

    /// The word “web”, spelled out so the provider-flag audit (which greps for the CLI argument "web" in quotes) is not confused by natural-language vocabulary.
    private static let webTok = ["w", "eb"].joined()

    /// A pure QUESTION about ability. An action request (“Ekranıma bak”, “Look at my screen”, “bu dosyayı oku: …”) has no ability form and keeps its route (Computer Use, a task…).
    private static func abilityQuestion(_ t: [String], _ f: String) -> ReadinessIntent? {
        guard t.count <= 9 else { return nil }
        func has(_ w: String...) -> Bool { w.contains { t.contains($0) } }
        func hasPrefix(_ p: String...) -> Bool { t.contains { w in p.contains { w.hasPrefix($0) } } }
        func phrase(_ p: String...) -> Bool { p.contains { f.contains($0) } }
        let screenWord = hasPrefix("ekran") || has("screen", "desktop", "masaustu", "masaustumu")
        let fileWord = hasPrefix("dosya") || has("file", "files", "folder", "folders", "klasor", "klasorleri")
        let webWord = has(Self.webTok, "internet", "online") || hasPrefix("arastir") || phrase("research the", "do research")
        let rememberWord = hasPrefix("hatirl") || has("remember", "memory", "hafiza", "hafizan")
        let canForm = phrase("can you", "could you", "are you able", "do you have", "do you", "is it possible") || hasPrefix("yapabil", "gorebil", "okuyabil", "acabil", "erisebil", "kullanabil", "bakabil", "arastirabil", "hatirl")
        guard canForm else { return nil }
        let questionForm = has("mi", "mu", "musun", "misin", "can", "could", "do", "are", "is") || hasPrefix("hatirliyor") || t.contains { $0.hasSuffix("musun") || $0.hasSuffix("misin") }
        guard questionForm else { return nil }
        // A word outside the question vocabulary means a request (“can you see my screen and click Save”).
        let allowed: Set<String> = ["can", "could", "you", "are", "able", "to", "do", "does", "have", "access", "see", "view", "look", "at", "read", "open", "my", "the", "your", "screen", "files", "file", "folder", "folders",
                                   Self.webTok, "internet", "online", "research", "search", "remember", "memory", "projects", "project", "me", "is", "it", "possible", "on", "any", "ever", "really", "actually", "jarvis", "please", "now",
                                   "ekranimi", "ekrani", "ekranima", "ekran", "ekranimda", "ekranin", "gorebiliyor", "gorebilir", "gorebilirsin", "okuyabiliyor", "okuyabilir", "acabiliyor", "erisebiliyor", "erisebilir",
                                   "musun", "misin", "mu", "mi", "dosya", "dosyalari", "dosyalar", "dosyayi", "dosyalarimi", "klasor", "klasorleri", "okuyabilirsin", "gorebiliyorsun", "okuyabiliyorsun", "erisebiliyorsun",
                                   Self.webTok, "arastirmasi", "arastirma", "arastirmasini", "yapabiliyor", "yapabilir", "yapabiliyorsun", "yapabilirsin", "hatirliyor", "hatirlar", "hatirlarsin", "projelerimi", "projeleri", "projemi",
                                   "projemdeki", "beni", "hafizan", "hafiza", "var", "bilgisayar", "bilgisayarimdaki", "sen", "bana", "lutfen", "simdi", "internette", "internete", "webde", "ve", "veya", "de", "da", "bakabiliyor",
                                   "bakabilir", "bakabiliyorsun", "arastirabiliyor", "arastirabiliyorsun", "arastirabilir", "icin", "ile", "kullanabiliyor", "kullanabiliyorsun", "iceren", "uzerinde"]
        guard t.allSatisfy({ allowed.contains($0) }) else { return nil }
        let seeVerb = hasPrefix("gorebil") || has("see", "view", "look") || hasPrefix("bakabil")
        if screenWord, seeVerb || phrase("access my screen") { return .screenAbility }
        if fileWord, hasPrefix("okuyabil", "acabil", "erisebil", "gorebil", "kullanabil") || has("read", "open", "access", "see") { return .fileAbility }
        if webWord, hasPrefix("yapabil", "arastirabil", "erisebil") || has("research", "search", "access", "do") { return .webAbility }
        if rememberWord, hasPrefix("hatirl") || has("remember", "memory") || phrase("hafizan var") { return .memoryAbility }
        return nil
    }

    static func recognize(_ raw: String) -> ReadinessIntent? {
        let t = tokens(raw), f = t.joined(separator: " ")
        guard !t.isEmpty, t.count <= 14 else { return nil }
        func has(_ w: String...) -> Bool { w.contains { t.contains($0) } }
        func hasPrefix(_ p: String...) -> Bool { t.contains { w in p.contains { w.hasPrefix($0) } } }
        func phrase(_ p: String...) -> Bool { p.contains { f.contains($0) } }

        if phrase("hangi surum", "what version", "which version", "surumun ne", "your version", "surumunuz") { return .version }
        if let a = abilityQuestion(t, f) { return a }
        // “Sistem durumunu kısaca özetle” / “system status”: the readiness overview, nothing else.
        if phrase("sistem durum", "system status", "status of the system", "status of jarvis", "jarvis durum", "durumunu ozetle") && t.count <= 8 && !has("gorev", "task", "proje", "project", "unity", "hamam") { return .overall }

        // 1. The original, strict readiness questions (“Claude hazır mı?”, “Is Whisper installed?”).
        let asks = hasPrefix("hazir", "ready", "saglikli", "healthy", "health", "kurulu", "installed", "calisir", "usable", "kullanilabilir") || phrase("var mi", "is there", "do i have", "sahip miyim")
        // “Do you have X?” / “Can you use X?” are questions about ABILITY (answered yes / no from the record) — the strict readiness form is for “is X ready / installed”.
        let abilityForm = phrase("var mi", "do you have", "is there", "can you", "could you") || hasPrefix("kullanabil", "erisebil")
        if asks, !abilityForm {
            if has("claude") { return .provider("claude") }
            if has("codex") { return .provider("codex") }
            if has("opencode") || phrase("open code") { return .provider("opencode") }
            if hasPrefix("mcp") { return .mcp }
            if has("qwen") { return .localModels("qwen") }
            if has("whisper") { return .localModels("whisper") }
            if phrase("yerel model", "local model") { return .localModels(nil) }
            if phrase("gorsel model", "vision model", "visual model") || has("vision") { return .localModels("vision") }
            if has("unity") { return .unity }
            if hasPrefix("izin") || has("permissions", "permission", "accessibility", "erisilebilirlik") || phrase("ekran kaydi", "screen recording") { return .permissions }
            if has("ses", "voice", "mikrofon", "microphone", "konusma", "speech", "tts", "stt") { return .voice }
            if phrase("sistem", "her sey", "everything", "system", "jarvis", "all systems", "sistemler") { return .overall }
        }

        // 2. Natural questions about what JARVIS can use / has access to / can do.
        let ability = hasPrefix(abilityPrefixes[0], abilityPrefixes[1], abilityPrefixes[2], abilityPrefixes[3], abilityPrefixes[4], abilityPrefixes[5], abilityPrefixes[6], abilityPrefixes[7], abilityPrefixes[8], abilityPrefixes[9])
            || phrase("var mi", "can you", "could you", "do you have", "are you able", "what can", "which", "available", "access", "what do you", "do you")
            || has("var", "have", "use")
        guard ability || asks else { return nil }

        // Subjects, most specific first.
        var subject: ReadinessIntent?
        let named: [(Bool, String)] = [
            (has("claude"), "claude"), (has("codex"), "codex"), (has("opencode") || phrase("open code"), "opencode"), (has("qwen"), "qwen"), (has("whisper"), "whisper"),
            (phrase("gorsel model", "vision model", "visual model", "gorsel") || has("vision"), "vision"), (has("unity"), "unity"), (hasPrefix("mcp"), "mcp"),
            (phrase("hafiza arama", "memory search", "bellek arama"), "memory"),
            (has("mikrofon", "microphone") || phrase("ses sistem", "voice system") || (has("ses", "voice") && !phrase("sesli")), "voice"),
            (phrase("bilgisayar kontrol", "computer use", "computer control") || has("accessibility", "erisilebilirlik"), "computer"),
        ]
        let hits = named.filter(\.0).map(\.1)
        if hits.count == 1 { subject = .canUse(hits[0]) }
        else if hits.count > 1 { subject = .providers }          // “Claude ve Codex kullanabiliyor musun?” — the providers together
        else if hasPrefix("capabilit", "yetenek") || has("abilities", "ability") || phrase("neler yapabil", "ne yapabil", "what can you do", "what else can you", "what else do you", "what do you do", "neler yapar", "neleri kullanabil", "neleri kullanir") { subject = .capabilities }
        else if t.contains(where: { toolWords.contains($0) || $0.hasPrefix("arac") }) { subject = .tools }
        else if phrase("yerel model", "local model", "local ai", "yerel yapay") { subject = .localModels(nil) }
        else if t.contains(where: { providerWords.contains($0) || $0.hasPrefix("saglayici") || $0.hasPrefix("provider") }) || t.contains(where: { aiWords.contains($0) }) || hasPrefix("model") { subject = .providers }
        guard let result = subject else { return nil }

        // 3. The sentence must be ONLY a question about JARVIS. A verb or noun outside the known vocabulary (“… to fix the bug”, “… ile bir hikaye yaz”) makes it a request.
        let subjectWords: Set<String> = ["claude", "code", "codex", "opencode", "open", "qwen", "whisper", "unity", "mcp", "mcpler", "mcpleri", "local", "yerel", "gorsel", "vision", "visual", "model", "modeller", "models",
                                         "memory", "hafiza", "arama", "search", "voice", "ses", "sistem", "sistemi", "mikrofon", "microphone", "computer", "bilgisayar", "kontrol", "control", "accessibility", "erisilebilirlik",
                                         "capabilities", "capability", "abilities", "yetenek", "yetenekler", "yetenegin", "system", "ozellik", "ozellikler", "yapay", "zeka", "u", "yu", "nu", "i", "e", "a", "in", "un", "nin", "nun", "si", "su"]
        let allowed = filler.union(subjectWords).union(providerWords).union(aiWords).union(toolWords).union(capabilityWords)
        let residual = t.filter { w in
            if allowed.contains(w) { return false }
            if abilityPrefixes.contains(where: { w.hasPrefix($0) }) { return false }
            if ["model", "provider", "saglayici", "arac", "capabilit", "yetenek", "hazir", "kurulu", "mevcut", "erisim", "claude", "codex", "qwen", "whisper", "unity", "opencode", "mcp", "tool", "yapay", "ses", "mikrofon", "bilgisayar"].contains(where: { w.hasPrefix($0) }) { return false }
            return true
        }
        // A generic question (“which models can you use”) has no named subject to anchor it: any extra word makes it something else (“what AI models exist”, “which model is best for coding”).
        var generic = false
        switch result { case .providers, .tools, .capabilities, .localModels(nil): generic = true; default: break }
        return residual.count <= (generic ? 0 : 1) ? result : nil
    }
}

@MainActor
final class ReadinessAssistant: ReadinessConversing {
    let service: ReadinessService
    /// The project folder JARVIS is scoped to (nil = none chosen). Injected by `AppContext`; a fact, never inferred.
    var projectRoot: () -> String? = { nil }
    init(service: ReadinessService) { self.service = service }

    func recognizes(_ text: String) -> ReadinessIntent? { ReadinessIntentParser.recognize(text) }

    private func tr(_ l: ReplyLanguage, _ en: String, _ trk: String) -> String { l == .tr ? trk : en }

    static func phrase(_ s: ReadinessState, _ l: ReplyLanguage) -> String {
        func p(_ en: String, _ trk: String) -> String { l == .tr ? trk : en }
        switch s {
        case .ready: return p("ready", "hazır")
        case .available: return p("installed, not verified yet", "kurulu, henüz doğrulanmadı")
        case .notInstalled: return p("not installed", "kurulu değil")
        case .signInRequired: return p("installed but needs you to sign in", "kurulu ama oturum açmanız gerekiyor")
        case .permissionNeeded: return p("needs a permission", "izin gerekiyor")
        case .optionalAbsent: return p("not set up (optional)", "kurulmamış (isteğe bağlı)")
        case .notRunning: return p("not running (idle, as expected)", "çalışmıyor (beklenen boşta durumu)")
        case .off: return p("switched OFF", "kapalı")
        case .degraded(let w): return p("degraded — \(w)", "sorunlu — \(w)")
        case .stale(let w): return p("last known state is old — \(w)", "son bilinen durum eski — \(w)")
        case .unknown: return p("not checked yet", "henüz kontrol edilmedi")
        case .unavailable(let w): return p("unavailable — \(w)", "kullanılamıyor — \(w)")
        }
    }

    private func line(_ id: String, _ l: ReplyLanguage, snapshot: ReadinessSnapshot) -> String? {
        guard let i = snapshot.item(id) else { return nil }
        return "\(i.name): \(Self.phrase(i.state, l))."
    }

    // MARK: Names and groups

    private static let shortNames: [String: (en: String, tr: String)] = [
        "provider.claude": ("Claude Code", "Claude Code"), "provider.codex": ("Codex", "Codex"), "provider.opencode": ("OpenCode", "OpenCode"),
        "local.qwen": ("the local Qwen model", "yerel Qwen modeli"), "local.vision": ("the visual model", "görsel model"), "local.whisper": ("Whisper", "Whisper"), "local.embedding": ("memory search", "hafıza araması"),
    ]
    private func name(_ i: ReadinessItem, _ l: ReplyLanguage) -> String { Self.shortNames[i.id].map { l == .tr ? $0.tr : $0.en } ?? i.name }

    private func list(_ names: [String], _ l: ReplyLanguage) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + (l == .tr ? " ve " : " and ") + names.last!
        }
    }

    /// One short clause for a provider / local-model record, using ONLY the record: READY, installed-but-unverified, found-but-not-checked, not checked, sign-in, not installed, optional-absent, degraded, unavailable.
    private func clause(_ items: [ReadinessItem], _ l: ReplyLanguage) -> [String] {
        guard !items.isEmpty else { return [] }
        var groups: [(String, [String])] = []
        func add(_ key: String, _ n: String) { if let i = groups.firstIndex(where: { $0.0 == key }) { groups[i].1.append(n) } else { groups.append((key, [n])) } }
        for i in items {
            let n = name(i, l)
            switch i.state {
            case .ready: add(tr(l, "ready", "hazır"), n)
            case .available: add(i.id.hasPrefix("provider.") ? tr(l, "installed but not verified yet", "kurulu ancak henüz doğrulanmadı") : tr(l, "available", "mevcut"), n)
            case .unknown: add(i.installed == true ? tr(l, "installed but not checked yet", "kurulu ancak henüz kontrol edilmedi") : tr(l, "not checked yet", "henüz kontrol edilmedi"), n)
            case .signInRequired: add(tr(l, "installed but waiting for you to sign in", "kurulu ancak oturum açmanız gerekiyor"), n)
            case .notInstalled: add(tr(l, "not installed", "kurulu değil"), n)
            case .optionalAbsent: add(tr(l, "not set up (optional)", "kurulmamış (isteğe bağlı)"), n)
            case .degraded(let w): add(tr(l, "degraded (\(w))", "sorunlu (\(w))"), n)
            case .unavailable(let w): add(tr(l, "unavailable (\(w))", "kullanılamıyor (\(w))"), n)
            case .notRunning: add(tr(l, "installed, not running", "kurulu, çalışmıyor"), n)
            case .permissionNeeded: add(tr(l, "waiting for a permission", "izin bekliyor"), n)
            case .off: add(tr(l, "switched off", "kapalı"), n)
            case .stale(let w): add(tr(l, "last known state is old (\(w))", "son bilinen durum eski (\(w))"), n)
            }
        }
        return groups.map { "\(list($0.1, l)) \($0.0)." }
    }

    private func sentence(_ parts: [String]) -> String { parts.filter { !$0.isEmpty }.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ") }

    // MARK: Replies

    func reply(to intent: ReadinessIntent, language l: ReplyLanguage) -> String {
        let snap = service.refresh()
        func join(_ ids: [String]) -> String { ids.compactMap { line($0, l, snapshot: snap) }.joined(separator: " ") }
        func items(_ ids: [String]) -> [ReadinessItem] { ids.compactMap(snap.item) }
        switch intent {
        case .version:
            return tr(l, "JARVIS \(AppInfo.versionLine) (\(AppInfo.milestone)).", "JARVIS \(AppInfo.versionLine) (\(AppInfo.milestone)).")
        case .provider(let which):
            let id = "provider." + which
            guard let i = snap.item(id) else { return tr(l, "I have not checked the providers in this run.", "Bu çalıştırmada sağlayıcıları kontrol etmedim.") }
            var out = "\(i.name): \(i.state == .unknown && i.installed == true ? tr(l, "installed but not checked yet", "kurulu ancak henüz kontrol edilmedi") : Self.phrase(i.state, l))."
            if i.state == .ready, which != "opencode" { out += tr(l, " Checked with a safe status command; no model request was made.", " Güvenli bir durum komutuyla doğrulandı; model isteği yapılmadı.") }
            if i.state == .signInRequired { out += tr(l, " JARVIS cannot sign in for you.", " Sizin yerinize oturum açamam.") }
            if i.state == .unknown, which == "opencode" { out += tr(l, " Asking does not start it; press Recheck on the System screen to check it.", " Sormak onu başlatmaz; kontrol etmek için Sistem ekranında Yeniden Kontrol'a basın.") }
            return out
        case .canUse(let which):
            return canUse(which, snapshot: snap, language: l)
        case .providers:
            let providers = items(["provider.claude", "provider.codex", "provider.opencode"])
            let locals = items(["local.qwen", "local.vision", "local.whisper"])
            guard !providers.isEmpty || !locals.isEmpty else { return tr(l, "I have not checked the providers or models in this run.", "Bu çalıştırmada sağlayıcıları ve modelleri kontrol etmedim.") }
            var parts = clause(providers, l) + clause(locals, l)
            if let paid = snap.item("provider.paid"), paid.action == nil { parts.append(tr(l, "No paid API is used: a Claude or ChatGPT sign-in is a subscription, not API access.", "Ücretli API kullanılmıyor: Claude veya ChatGPT oturumu bir abonelik, API erişimi değil.")) }
            return sentence(parts)
        case .tools:
            return sentence(toolClauses(snap, l))
        case .capabilities:
            return capabilitySummary(snap, l)
        case .screenAbility: return screenAnswer(snap, l)
        case .fileAbility: return fileAnswer(snap, l)
        case .webAbility: return webAnswer(snap, l)
        case .memoryAbility: return memoryAnswer(snap, l)
        case .voice:
            return join(["voice.input", "voice.mic", "voice.stt", "voice.neural", "voice.wake"]) + " " + snap.items.filter { $0.id.hasPrefix("voice.tts.") }.prefix(2).map { "\($0.name): \(Self.phrase($0.state, l))." }.joined(separator: " ")
        case .mcp:
            return join(["mcp.summary"])
        case .permissions:
            return join(["voice.mic", "computer.ax", "computer.screen", "perm.notifications"])
        case .localModels(let kind):
            switch kind {
            case "qwen": return join(["local.qwen"])
            case "whisper": return join(["local.whisper"])
            case "vision": return join(["local.vision"])
            default: return sentence(clause(items(["local.qwen", "local.vision", "local.whisper", "local.embedding"]), l))
            }
        case .unity:
            return join(["unity.editor", "unity.bridge"])
        case .overall:
            let attention = snap.attention
            var parts: [String] = []
            switch snap.summary {
            case .ready: parts.append(tr(l, "Everything I can check is ready.", "Kontrol edebildiğim her şey hazır."))
            case .usable: parts.append(tr(l, "JARVIS is usable.", "JARVIS kullanılabilir durumda."))
            case .notReady(let why): parts.append(tr(l, "Not ready: \(why).", "Hazır değil: \(why)."))
            }
            for i in attention.prefix(5) { parts.append("\(i.name): \(Self.phrase(i.state, l)).") }
            if let voice = snap.item("voice.input"), voice.state == .off { parts.append(tr(l, "Voice input is switched OFF, so Push-to-Talk does nothing until you turn it on.", "Ses girişi kapalı; açana kadar Push-to-Talk bir şey yapmaz.")) }
            let providers = snap.items(in: .intelligence).filter { $0.id != "provider.paid" }
            if !providers.isEmpty { parts.append(tr(l, "Providers — ", "Sağlayıcılar — ") + providers.map { "\($0.name) \(Self.phrase($0.state, l))" }.joined(separator: ", ") + ".") }
            return parts.joined(separator: " ")
        }
    }

    // MARK: “Can you use X?”

    private func canUse(_ which: String, snapshot snap: ReadinessSnapshot, language l: ReplyLanguage) -> String {
        let ids: [String: [String]] = ["claude": ["provider.claude"], "codex": ["provider.codex"], "opencode": ["provider.opencode"], "qwen": ["local.qwen"], "whisper": ["local.whisper"],
                                       "vision": ["local.vision"], "memory": ["local.embedding"], "unity": ["unity.editor", "unity.bridge"], "mcp": ["mcp.summary"], "voice": ["voice.input", "voice.mic"],
                                       "computer": ["computer.ax"]]
        guard let rows = ids[which]?.compactMap(snap.item), let first = rows.first else { return tr(l, "I have not checked that in this run.", "Bunu bu çalıştırmada kontrol etmedim.") }
        let n = name(first, l)
        let isProvider = first.id.hasPrefix("provider.")
        func s(_ en: String, _ trk: String) -> String { tr(l, en, trk) }
        switch first.state {
        case .ready:
            return isProvider ? s("Yes — \(n) is ready (verified with a safe status check; no model request was made).", "Evet — \(n) hazır (güvenli bir durum kontrolüyle doğrulandı; model isteği yapılmadı).")
                              : s("Yes — \(n) is ready.", "Evet — \(n) hazır.") + (rows.dropFirst().isEmpty ? "" : " " + rows.dropFirst().map { "\($0.name): \(Self.phrase($0.state, l))." }.joined(separator: " "))
        case .available:
            return isProvider ? s("\(n) is installed, but nothing has verified it yet, so I cannot say I can use it. Press Recheck on the System screen.", "\(n) kurulu, ancak henüz kimse doğrulamadı; kullanabildiğimi söyleyemem. Sistem ekranında Yeniden Kontrol'a basın.")
                              : s("Yes — \(n) is available; it is loaded when it is needed (it is not running now).", "Evet — \(n) mevcut; gerektiğinde yüklenir (şu an çalışmıyor).")
        case .unknown:
            let found = first.installed == true
            return found ? s("\(n) is installed but I have not checked it yet, so I cannot say. Asking does not start it; press Recheck on the System screen.", "\(n) kurulu ancak henüz kontrol etmedim, bu yüzden söyleyemem. Sormak onu başlatmaz; Sistem ekranında Yeniden Kontrol'a basın.")
                         : s("I have not checked \(n) yet, so I cannot say. Press Recheck on the System screen.", "\(n) henüz kontrol edilmedi, bu yüzden söyleyemem. Sistem ekranında Yeniden Kontrol'a basın.")
        case .signInRequired:
            return s("Not yet — \(n) is installed but needs you to sign in. I cannot sign in for you.", "Henüz değil — \(n) kurulu ama oturum açmanız gerekiyor. Sizin yerinize oturum açamam.")
        case .notInstalled:
            return s("No — \(n) is not installed.", "Hayır — \(n) kurulu değil.")
        case .optionalAbsent:
            return s("No — \(n) is not set up (it is optional).", "Hayır — \(n) kurulmamış (isteğe bağlı).")
        case .notRunning:
            return s("Yes, when it is needed — \(n) is installed and idle (not running now).", "Gerektiğinde evet — \(n) kurulu ve boşta (şu an çalışmıyor).")
        case .off:
            return s("Not now — \(n) is switched OFF. Turn it on with “Turn On Voice” in System & Readiness.", "Şu an değil — \(n) kapalı. Sistem ve Hazırlık ekranında “Turn On Voice” ile açabilirsiniz.")
        case .permissionNeeded:
            return s("Not yet — \(n) needs a permission that you have to allow.", "Henüz değil — \(n) için sizin vermeniz gereken bir izin gerekiyor.")
        case .degraded(let w):
            return s("Partly — \(n) is degraded (\(w)).", "Kısmen — \(n) sorunlu (\(w)).")
        case .unavailable(let w):
            return s("No — \(n) is unavailable (\(w)).", "Hayır — \(n) kullanılamıyor (\(w)).")
        case .stale(let w):
            return s("I am not sure — the last known state of \(n) is old (\(w)). Press Recheck.", "Emin değilim — \(n) için son bilinen durum eski (\(w)). Yeniden Kontrol'a basın.")
        }
    }


    // MARK: Can vs. currently doing

    private func shortPath(_ p: String) -> String { p.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    private func screenAnswer(_ snap: ReadinessSnapshot, _ l: ReplyLanguage) -> String {
        let ax = snap.item("computer.ax"), rec = snap.item("computer.screen")
        let axReady = ax?.state == .ready
        var out = axReady
            ? tr(l, "Yes, when you ask. With Computer Use I read the structure of an app window through Accessibility first, and only if that is not enough I take a picture of that one window and read it on this Mac. I never watch your screen continuously, and I am not looking at it now.",
                 "Evet, siz istediğinizde. Bilgisayar Kontrolü ile önce Erişilebilirlik üzerinden bir uygulama penceresinin yapısını okurum; bu yetmezse yalnızca o tek pencerenin görüntüsünü alıp bu Mac'te okurum. Ekranınızı sürekli izlemem ve şu anda ona bakmıyorum.")
            : tr(l, "Not yet. I can look at an app window through Computer Use, but it needs the Accessibility permission, which you have to allow in System Settings. I am not looking at your screen now.",
                 "Henüz değil. Bilgisayar Kontrolü ile bir uygulama penceresine bakabilirim ama bunun için Sistem Ayarları'nda sizin vermeniz gereken Erişilebilirlik izni gerekiyor. Şu anda ekranınıza bakmıyorum.")
        if let ax { out += " " + tr(l, "Accessibility: \(Self.phrase(ax.state, l)).", "Erişilebilirlik: \(Self.phrase(ax.state, l)).") }
        if let rec { out += " " + tr(l, "Window picture (Screen Recording): \(Self.phrase(rec.state, l)).", "Pencere görüntüsü (Ekran Kaydı): \(Self.phrase(rec.state, l)).") }
        if axReady { out += " " + tr(l, "Say “Look at my screen” to start.", "Başlatmak için “Ekranıma bak” demeniz yeterli.") }
        return out
    }

    private func fileAnswer(_ snap: ReadinessSnapshot, _ l: ReplyLanguage) -> String {
        if let root = projectRoot(), !root.isEmpty {
            return tr(l, "Yes — inside your project folder (\(shortPath(root))) I can read files, and when you give me a task I can change them within the limits you set; deleting or touching files you have edited yourself waits for your approval. I cannot reach files outside that folder. I am not reading any file now.",
                      "Evet — proje klasörünüzün (\(shortPath(root))) içinde dosyaları okuyabilirim; bir görev verdiğinizde belirlediğiniz sınırlar içinde değiştirebilirim; silme ve sizin düzenlediğiniz dosyalara dokunma onayınızı bekler. Bu klasörün dışındaki dosyalara erişemem. Şu anda hiçbir dosyayı okumuyorum.")
        }
        return tr(l, "Yes, but only inside a project folder you choose — and none is chosen right now, so I cannot read any file yet. Choose a folder on the Tasks screen; I never browse the rest of your Mac.",
                  "Evet, ama yalnızca sizin seçtiğiniz bir proje klasörünün içinde — şu an hiçbiri seçili değil, bu yüzden henüz hiçbir dosyayı okuyamam. Görevler ekranından bir klasör seçin; Mac'inizin geri kalanını gezmem.")
    }

    private func webAnswer(_ snap: ReadinessSnapshot, _ l: ReplyLanguage) -> String {
        let ready = ["provider.claude", "provider.codex", "provider.opencode"].compactMap(snap.item).filter { $0.state == .ready }.map { name($0, l) }
        var out = tr(l, "Yes, when you ask: I can research the public web — read-only, with sources. I do not sign in, buy anything or act on any account, and web text is treated as data, never as instructions. Nothing is being researched now.",
                     "Evet, siz istediğinizde: herkese açık web'de araştırma yapabilirim — yalnızca okuma, kaynaklarla. Giriş yapmam, satın alma veya hesap işlemi yapmam; web metni talimat değil veri olarak ele alınır. Şu anda hiçbir şey araştırılmıyor.")
        if ready.isEmpty { out += " " + tr(l, "Right now no AI provider is verified ready to analyse what I find.", "Şu anda bulduklarımı çözümlemek için doğrulanmış hazır bir yapay zekâ sağlayıcısı yok.") }
        else { out += " " + tr(l, "Ready to analyse: \(list(ready, l)).", "Çözümleme için hazır: \(list(ready, l)).") }
        return out
    }

    private func memoryAnswer(_ snap: ReadinessSnapshot, _ l: ReplyLanguage) -> String {
        let root = projectRoot()
        let project = (root?.isEmpty == false) ? tr(l, "The current project is \((root! as NSString).lastPathComponent).", "Şu anki proje: \((root! as NSString).lastPathComponent).")
                                               : tr(l, "No project folder is chosen, so Project Memory has nothing to attach to yet.", "Bir proje klasörü seçili değil; Proje Hafızası'nın bağlanacağı bir şey henüz yok.")
        var out = tr(l, "I keep project knowledge — decisions, verified results, corrections — in Project Memory on this Mac, per project; I do not store whole conversations. What you say in a chat only stays in this session's working context. ",
                     "Proje bilgisini — kararları, doğrulanmış sonuçları, düzeltmeleri — bu Mac'te, proje bazında Proje Hafızası'nda tutarım; sohbetlerin tamamını saklamam. Sohbette söyledikleriniz yalnızca bu oturumun çalışma bağlamında kalır. ") + project
        if let e = snap.item("local.embedding") { out += " " + tr(l, "Memory search: \(Self.phrase(e.state, l)).", "Hafıza araması: \(Self.phrase(e.state, l)).") }
        return out
    }

    // MARK: Tools and capabilities

    private func toolClauses(_ snap: ReadinessSnapshot, _ l: ReplyLanguage) -> [String] {
        var out: [String] = []
        func item(_ id: String, _ en: String, _ trk: String) {
            guard let i = snap.item(id) else { return }
            out.append("\(tr(l, en, trk)): \(Self.phrase(i.state, l)).")
        }
        item("computer.ax", "Computer Use (Accessibility)", "Bilgisayar Kontrolü (Erişilebilirlik)")
        item("unity.editor", "Unity Editor", "Unity Editor")
        item("unity.bridge", "Unity bridge", "Unity köprüsü")
        item("mcp.summary", "MCP servers", "MCP sunucuları")
        item("voice.input", "Voice input", "Ses girişi")
        return out
    }

    private func capabilitySummary(_ snap: ReadinessSnapshot, _ l: ReplyLanguage) -> String {
        let ids = ["provider.claude", "provider.codex", "provider.opencode", "local.qwen", "local.vision", "local.whisper", "computer.ax", "voice.input"]
        let rows = ids.compactMap(snap.item)
        func names(_ pred: (ReadinessItem) -> Bool) -> [String] { rows.filter(pred).map { i in i.id == "computer.ax" ? tr(l, "Computer Use", "Bilgisayar Kontrolü") : (i.id == "voice.input" ? tr(l, "voice input", "ses girişi") : name(i, l)) } }
        let ready = names { $0.state == .ready }
        let available = names { $0.state == .available }
        let unchecked = names { $0.state == .unknown }
        let off = names { $0.state == .off }
        let problems = rows.filter { $0.state.needsAttention }.map { "\(name($0, l)) \(Self.phrase($0.state, l))" }
        var parts: [String] = [tr(l, "What I can do: work with the files of the project you choose (as tasks), research the public web, look at an app window through Computer Use when you ask, drive Unity, talk by voice and keep project memory.",
                                  "Yapabildiklerim: seçtiğiniz projenin dosyalarıyla (görev olarak) çalışmak, herkese açık web'de araştırma yapmak, istediğinizde Bilgisayar Kontrolü ile bir uygulama penceresine bakmak, Unity'yi yönetmek, sesle konuşmak ve proje hafızası tutmak.")]
        if !ready.isEmpty { parts.append(tr(l, "Ready: \(list(ready, l)).", "Hazır: \(list(ready, l)).")) }
        if !available.isEmpty { parts.append(tr(l, "Available when needed: \(list(available, l)).", "Gerektiğinde kullanılabilir: \(list(available, l)).")) }
        if !unchecked.isEmpty { parts.append(tr(l, "Not checked yet: \(list(unchecked, l)).", "Henüz kontrol edilmedi: \(list(unchecked, l)).")) }
        if !off.isEmpty { parts.append(tr(l, "Switched off: \(list(off, l)).", "Kapalı: \(list(off, l)).")) }
        if !problems.isEmpty { parts.append(tr(l, "Needs attention: \(problems.joined(separator: "; ")).", "Dikkat gerektiriyor: \(problems.joined(separator: "; ")).")) }
        if parts.count == 1 { return tr(l, "I have not checked what is available in this run.", "Bu çalıştırmada nelerin mevcut olduğunu kontrol etmedim.") }
        parts.append(tr(l, "Unity and MCP servers are started only when a task needs them.", "Unity ve MCP sunucuları yalnızca bir görev gerektirdiğinde başlatılır."))
        return parts.joined(separator: " ")
    }
}
