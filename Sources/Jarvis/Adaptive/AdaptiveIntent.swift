import Foundation

// MARK: - Adaptive intents (V0.14, DEC-230): typed and spoken text alike go through the SAME recogniser and the SAME handler — voice has no authority of its own.
//
// Reading and status questions answer from persisted records. Management requests act within their authority: show/status are safe; disable/enable follow the envelope; benchmark
// follows the sandbox rules; install / update / remove only CREATE a request that a HUD button decides. A spoken or typed “yes” is never a decision (ApprovalGuard).

enum AdaptiveIntent: Equatable, Sendable {
    // learning
    case learnedRecently, learnedAboutProject, listRules, whyRule(String?), workflowOrigin(String?), wantToImprove, missingCapabilities, listSkills, learningStatus
    // capabilities
    case listMCPs, activeMCPs, mcpRunning(String?), whatIsMCP(String?), unusedMCPs(days: Int), findMCP(domain: MCPDomain?, words: String), recommendMCPs, whyMCP(String?), isMCPSafe(String?)
    case disableMCP(String?), enableMCP(String?), benchmarkMCP(String?), removeMCP(String?), installMCP(String?), updateMCP(String?)

    /// Intents that can change something (they act only inside their authority, never through a spoken approval).
    var changesState: Bool {
        switch self {
        case .disableMCP, .enableMCP, .benchmarkMCP, .removeMCP, .installMCP, .updateMCP, .findMCP: true
        default: false
        }
    }
}

enum AdaptiveIntentParser {
    private static func tokens(_ raw: String) -> [String] {
        ResearchText.fold(raw).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
    private static let nameStops: Set<String> = ["bu", "su", "o", "the", "this", "that", "our", "an", "a", "bir", "her", "tum", "all", "hangi", "which", "what", "my", "your", "these", "those", "any", "jarvis", "ve", "and", "sunu", "bunu", "ayni", "same", "one", "bi"]

    /// The name written before the word “MCP” (“Blender MCP'yi kapat” → “blender”). nil = no name (“bu MCP'yi …” → the one talked about last).
    static func mcpName(_ t: [String]) -> String? {
        guard let i = t.firstIndex(where: { $0 == "mcp" || $0 == "mcps" }) else { return nil }
        var words: [String] = []
        var j = i - 1
        while j >= 0, words.count < 2, !nameStops.contains(t[j]), t[j].count > 1 { words.insert(t[j], at: 0); j -= 1 }
        // two words only when the first is not a verb/particle we know
        if words.count == 2, ["icin", "for", "yeni", "new", "bir", "is", "was", "da", "de", "ki", "mi", "on", "off", "up", "down", "to", "in", "at", "of", "with", "all"].contains(words[0]) { words.removeFirst() }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    static func recognize(_ raw: String) -> AdaptiveIntent? {
        let t = tokens(raw), f = t.joined(separator: " ")
        guard !t.isEmpty else { return nil }
        func has(_ words: String...) -> Bool { words.contains { w in t.contains(w) } }
        func hasPrefix(_ p: String...) -> Bool { t.contains { w in p.contains { w.hasPrefix($0) } } }
        func phrase(_ p: String...) -> Bool { p.contains { f.contains($0) } }
        let isMCP = has("mcp", "mcps"), isSkill = hasPrefix("skill") || has("beceri", "becerileri") || phrase("is akisi")
        let question = raw.contains("?") || has("mi", "mu", "ne", "neden", "hangi", "what", "which", "why", "is", "are", "does", "do", "how", "nasil", "var")

        // ---- MCP management and questions
        if isMCP {
            let name = mcpName(t)
            if hasPrefix("benchmark") || phrase("performans ol", "olcum") { return .benchmarkMCP(name) }
            if hasPrefix("sil", "kaldir") || has("delete", "remove", "uninstall", "unregister") || phrase("kaldir") { return .removeMCP(name) }
            if has("kapat", "disable") || phrase("turn off", "switch off", "shut down", "deactivate", "devre disi") { return .disableMCP(name) }
            if has("ac", "enable", "etkinlestir", "baslat") || phrase("turn on", "switch on", "activate") { return .enableMCP(name) }
            if hasPrefix("kur") || has("install", "yukle", "register", "kaydet") { return .installMCP(name) }
            if hasPrefix("guncelle") || has("update", "upgrade") { return .updateMCP(name) }
            if phrase("guvenli", "safe", "guvenlik", "security", "trustworthy", "risk") { return .isMCPSafe(name) }
            if has("neden") && hasPrefix("oner") || phrase("why do you recommend", "why recommend", "why are you recommending") { return .whyMCP(name) }
            if phrase("hangi mcp") && hasPrefix("oner") || phrase("which mcp") && hasPrefix("recommend") || phrase("mcp") && phrase("oneriyorsun", "do you recommend", "would you recommend", "recommendations", "oneri") { return .recommendMCPs }
            if phrase("kullanmadigimiz", "kullanilmayan", "unused", "not used", "havent used", "haven t used", "kullanmadik") {
                let days = t.compactMap { Int($0) }.first ?? 30
                return .unusedMCPs(days: min(max(days, 1), 365))
            }
            if phrase("calisiyor", "running", "alive", "aktif mi", "is it on", "is active", "calisiyormu") && name != nil { return .mcpRunning(name) }
            if phrase("hangi mcp") && hasPrefix("aktif") || phrase("which mcp") && has("active", "running", "enabled") || phrase("aktif mcp", "active mcp") { return .activeMCPs }
            if phrase("ne ise yariyor", "ne yapiyor", "what does", "what is", "what s the point", "ne icin") { return .whatIsMCP(name) }
            if hasPrefix("goster") || has("show", "list", "listele", "list") || phrase("hangi mcp", "which mcp") { return .listMCPs }
            if hasPrefix("bul", "arastir") || has("find", "research", "search", "look", "discover", "kesfet") || phrase("var mi", "is there", "are there", "bir mcp", "daha iyi") {
                let domain = MCPDomain.parse(raw)
                let words = t.filter { !nameStops.contains($0) && $0 != "mcp" && $0 != "mcps" }.joined(separator: " ")
                return .findMCP(domain: domain, words: String(words.prefix(60)))
            }
            if question { return .listMCPs }
            return nil
        }

        // ---- Learning questions (never an MCP word)
        // “you learned” — a question to JARVIS, not a statement about the user ("I learned a lot today" is not for us)
        let learned = has("ogrendin", "ogrendiniz", "ogrendigin", "ogrendiklerin", "ogrendiklerini") || phrase("have you learned", "did you learn", "what you learned", "you learned", "you ve learned", "what did you learn", "you learnt")
        if learned {
            if phrase("proje", "project") { return .learnedAboutProject }
            if (isSkill || phrase("workflow")) && phrase("nereden", "where", "how did you learn") { return .workflowOrigin(nil) }
            if phrase("son zaman", "yakin zaman", "lately", "recent", "last week", "this week", "gecen hafta", "bugun", "today") || question { return .learnedRecently }
            return .learnedRecently
        }
        if (isSkill || has("workflow")) && phrase("nereden", "where did", "where do", "where from") { return .workflowOrigin(nil) }
        if hasPrefix("kural") || has("rule", "rules") {
            if has("neden", "why") { return .whyRule(nil) }
            if question || phrase("kendin", "olustur", "created", "learned", "ekledin") { return .listRules }
        }
        if phrase("kendinde neyi", "kendini nasil gelistir", "what would you improve", "what do you want to improve", "how would you improve yourself", "what do you want to change about yourself", "neyi gelistirmek") { return .wantToImprove }
        if phrase("yetenek") && has("eksik", "yok", "lack", "missing") || phrase("hangi yetenek") || phrase("what capabilities", "what can you not", "what are you missing", "which capabilities", "what capability") && has("missing", "lack", "gap", "eksik") { return .missingCapabilities }
        if isSkill && (hasPrefix("goster") || has("show", "list", "listele", "hangi", "which", "what")) { return .listSkills }
        if phrase("ogrenme durumu", "learning status", "learning summary", "ogrenme ozeti") { return .learningStatus }
        return nil
    }
}
