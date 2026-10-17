import Foundation

// MARK: - Natural language → typed action (V1.0 stabilisation fix 4)
//
// "Safari'yi aç", "Safari'yi açar mısın?", "Safari'yi açabilir misin lütfen?", "Can you open Safari?", "System panelini aç", "Dashboard'a dön", "Tam JARVIS ekranını aç",
// "Downloads klasörünü aç". A polite question about ability that names something JARVIS can open is, pragmatically, a request: it is an ACTION, never a conversation.
// Deterministic grammar, no model. Anything it does not fully understand (extra words, several actions, an unknown object) is NOT an action and keeps its normal route.

struct AppTarget: Equatable, Sendable {
    var display: String
    var bundleID: String
    /// Set when the name was NOT heard exactly: what the recogniser produced ("Sofany"), so the reply can say what was understood.
    var heardAs: String? = nil
}

enum KnownFolder: String, CaseIterable, Sendable {
    case downloads, documents, desktop, home
    var display: String { switch self { case .downloads: "Downloads"; case .documents: "Documents"; case .desktop: "Desktop"; case .home: "Home" } }
    var url: URL {
        let h = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        switch self { case .downloads: return h.appendingPathComponent("Downloads", isDirectory: true); case .documents: return h.appendingPathComponent("Documents", isDirectory: true)
                      case .desktop: return h.appendingPathComponent("Desktop", isDirectory: true); case .home: return h }
    }
}

enum ActionIntent: Equatable, Sendable {
    case launchApp(AppTarget)
    case openFolder(KnownFolder)
    case navigate(HUDSection)
    case showFullHUD
    case showCompactHUD
    case closeHUD
    /// A known project's folder (path already resolved from the project registry and checked on disk): revealed in Finder. Opening a project never writes to it.
    case openProject(name: String, path: String)

    var kind: ActionKind {
        switch self { case .launchApp: .launchApp; case .openFolder: .openFolder; case .navigate: .navigate; case .showFullHUD: .showFullHUD; case .showCompactHUD: .showCompactHUD; case .closeHUD: .closeHUD; case .openProject: .openProject }
    }
    var targetName: String {
        switch self {
        case .launchApp(let a): a.display; case .openFolder(let f): f.display; case .navigate(let s): s.rawValue.capitalized
        case .showFullHUD: "JARVIS"; case .showCompactHUD: "Compact JARVIS"; case .closeHUD: "JARVIS"; case .openProject(let name, _): name
        }
    }
}

enum ActionIntentParser {
    /// Resolves a spoken/typed name that is not in the built-in catalog to an installed application (directory listing only). Injected so the grammar stays pure.
    typealias InstalledAppLookup = (String) -> AppTarget?
    /// Sound-shape fallback for a name that matches no installed application (action context only). Injected; nil = off.
    typealias PhoneticAppLookup = (String) -> AppTarget?

    private static let openVerbs: Set<String> = ["ac", "acar", "acabilir", "acin", "acsana", "baslat", "baslatir", "baslatabilir", "calistir", "calistirir", "calistirabilir", "open", "launch", "start", "opens"]
    private static let selfVerbs: Set<String> = ["ac", "acar", "acabilir", "goster", "gosterir", "gosterebilir", "git", "gec", "don", "donebilir", "geri", "open", "show", "go", "switch", "back", "return", "gotoa", "bring", "take", "gecelim", "gidelim", "gecsek", "gitsek", "gecebilir", "gidebilir"]
    private static let closeVerbs: Set<String> = ["kapat", "kapatir", "kapatabilir", "gizle", "gizler", "close", "hide", "dismiss"]
    private static let noise: Set<String> = [
        "misin", "musun", "mi", "mu", "miyim", "lutfen", "please", "can", "could", "would", "you", "jarvis", "hey", "sen", "bana", "benim", "icin", "hemen", "simdi", "bir", "the", "for", "me", "to", "now",
        "uygulamasini", "uygulamasi", "uygulama", "application", "app", "programi", "programini", "program", "ve", "tamam", "ok", "okay", "peki", "ama", "olur", "mu", "mi", "if", "possible", "rica", "ederim",
    ]

    static func parse(_ raw: String, installed: InstalledAppLookup = { _ in nil }, phonetic: PhoneticAppLookup = { _ in nil }) -> ActionIntent? {
        let t = ComputerText.tokens(raw)
        guard !t.isEmpty, t.count <= 12 else { return nil }
        let words = Set(t)
        func has(_ w: String...) -> Bool { w.contains { words.contains($0) } }
        func hasPrefix(_ p: String...) -> Bool { t.contains { w in p.contains { w.hasPrefix($0) } } }
        let openVerb = !words.isDisjoint(with: openVerbs) || hasPrefix("acab", "acar")
        let selfVerb = !words.isDisjoint(with: selfVerbs) || hasPrefix("acab", "acar", "goster", "donebil")
        let closeVerb = !words.isDisjoint(with: closeVerbs) || hasPrefix("kapatab", "kapatir")

        // 1. JARVIS' own HUD ------------------------------------------------------------------------------------------------------------------
        let uiNoun = hasPrefix("panel", "ekran", "sayfa", "bolum", "page", "screen", "sekme", "tab", "section", "view", "pencere", "window", "hud", "gorunum")
        // “System Settings” / “Sistem ayarları” is an APPLICATION, not JARVIS' System page.
        let systemSettingsApp = (has("system", "sistem") && hasPrefix("settings", "ayar", "preferences", "tercih"))
        if !systemSettingsApp, selfVerb || closeVerb {
            if closeVerb, has("jarvis", "hud") || hasPrefix("jarvis") { return .closeHUD }
            // compact / full
            if hasPrefix("kompakt", "compact") { return selfVerb ? .showCompactHUD : nil }
            if (has("tam") && hasPrefix("ekran")) || (has("full") && (has("hud", "screen", "jarvis") || hasPrefix("view"))) || (hasPrefix("jarvis") && (has("ac") || hasPrefix("acar", "acab", "open")) && residual(t, removing: ["jarvisi", "jarvisin"]).isEmpty && !uiNoun) { return .showFullHUD }
            if let section = destination(in: t, uiNoun: uiNoun) {
                // a destination needs either a UI noun (“System panelini aç”) or an unambiguous name (“Dashboard'a dön”, “open the agents”)
                return .navigate(section)
            }
        }

        // 2. a folder ---------------------------------------------------------------------------------------------------------------------
        if openVerb || selfVerb {
            let folder: KnownFolder? = hasPrefix("indirilen", "download") ? .downloads : (hasPrefix("belge", "document") ? .documents : (hasPrefix("masaustu", "desktop") ? .desktop : ((has("ev") && hasPrefix("klasor")) || has("home") ? .home : nil)))
            if let folder, residual(t, removing: ["klasor", "klasoru", "klasorunu", "klasorumu", "folder", "dosyalar", "dosyalarim", "indirilenler", "indirilenleri", "belgeler", "belgelerim", "documents", "downloads", "desktop", "masaustu", "masaustunu", "home", "ev", "evi"]).isEmpty { return .openFolder(folder) }
        }

        // 2b. a spoken correction of an application name: “Sofany değil, Safari dedim.” / “I said Safari, not Sofany.”
        if let corr = nameCorrection(t, installed: installed) { return .launchApp(corr) }

        // 3. an application ---------------------------------------------------------------------------------------------------------------
        guard openVerb else { return nil }
        if let m = AppCatalog.match(tokens: t) {
            let rest = residual(t, removing: [], dropping: m.range)
            guard rest.isEmpty else { return nil }
            return .launchApp(AppTarget(display: m.app.display, bundleID: m.app.bundleID))
        }
        // an installed application JARVIS has no alias for: the words that are left must be exactly its name
        let leftover = residual(t, removing: [])
        guard !leftover.isEmpty, leftover.count <= 4 else { return nil }
        // Turkish case suffixes are glued on once the apostrophe is folded away (“Sketchbook'u” → sketchbooku): try the name with up to 3 trailing letters removed, longest first.
        let head = leftover.dropLast().joined(separator: " ")
        let last = leftover[leftover.count - 1]
        for cut in 0...3 where last.count - cut >= 3 {
            let name = (head.isEmpty ? "" : head + " ") + String(last.dropLast(cut))
            if let app = installed(name) { return .launchApp(app) }
        }
        // a name that is not installed: the sound-shape fallback, in this explicit open-verb context only
        // (short words are kept here: a mis-heard name may well be split into short words — “so funny”)
        let spoken = t.filter { w in !openVerbs.contains(w) && !noise.contains(w) && !w.hasPrefix("acab") && !w.hasPrefix("acar") }
        if !spoken.isEmpty, spoken.count <= 3 {
            let pHead = spoken.dropLast().joined(separator: " "), pLast = spoken[spoken.count - 1]
            // every way of cutting a glued Turkish case suffix off the last word; they must agree on ONE application, and the shortest spelling is what is reported as "heard" (“sofany”, not “sofanyyi”)
            var found: [AppTarget] = []
            for cut in 0...3 where pLast.count - cut >= 2 {
                let name = (pHead.isEmpty ? "" : pHead + " ") + String(pLast.dropLast(cut))
                if let app = phonetic(name) { found.append(app) }
            }
            if let first = found.first, found.allSatisfy({ $0.bundleID == first.bundleID }) {
                return .launchApp(found.min { ($0.heardAs?.count ?? 99) < ($1.heardAs?.count ?? 99) } ?? first)
            }
        }
        return nil
    }

    /// “X değil, Y dedim” / “Y dedim, X değil” / “I said Y”: the user restates the name. Y must resolve to a known or installed application; X is returned as `heardAs`.
    private static func nameCorrection(_ t: [String], installed: InstalledAppLookup) -> AppTarget? {
        let said = t.contains { $0 == "dedim" || $0 == "demistim" || $0 == "dedimki" } || (t.first == "i" && t.dropFirst().first == "said")
        guard said else { return nil }
        let negation = t.firstIndex { $0 == "degil" || $0 == "not" }
        var wrong: String?
        var rightTokens = t
        if let n = negation {
            if n > 0, t[0] != "i" { wrong = t[0..<n].joined(separator: " "); rightTokens = Array(t[(n + 1)...]) }
            else { wrong = t[(n + 1)...].joined(separator: " "); rightTokens = Array(t[..<n]) }
        }
        rightTokens = rightTokens.filter { $0 != "dedim" && $0 != "demistim" && $0 != "dedimki" && $0 != "i" && $0 != "said" && $0 != "degil" && $0 != "not" && $0 != "hayir" && $0 != "no" }
        guard !rightTokens.isEmpty, rightTokens.count <= 3 else { return nil }
        var target: AppTarget?
        if let m = AppCatalog.match(tokens: rightTokens), residual(rightTokens, removing: [], dropping: m.range).isEmpty { target = AppTarget(display: m.app.display, bundleID: m.app.bundleID) }
        else {
            let head = rightTokens.dropLast().joined(separator: " "), last = rightTokens[rightTokens.count - 1]
            for cut in 0...3 where last.count - cut >= 3 {
                if let app = installed((head.isEmpty ? "" : head + " ") + String(last.dropLast(cut))) { target = app; break }
            }
        }
        guard var found = target else { return nil }
        found.heardAs = wrong
        return found
    }

    // MARK: Helpers

    /// Tokens that are not the verb, politeness or noise (and, optionally, not part of the matched object).
    private static func residual(_ t: [String], removing extra: Set<String>, dropping range: Range<Int>? = nil) -> [String] {
        var out: [String] = []
        for (i, w) in t.enumerated() {
            if let range, range.contains(i) { continue }
            if openVerbs.contains(w) || selfVerbs.contains(w) || noise.contains(w) || extra.contains(w) { continue }
            if w.hasPrefix("acab") || w.hasPrefix("acar") { continue }
            if w.count <= 2 { continue }                     // case suffixes split off by an apostrophe (Safari'yi → safari + yi)
            out.append(w)
        }
        return out
    }

    private static func destination(in t: [String], uiNoun: Bool) -> HUDSection? {
        let table: [(HUDSection, [String], Bool)] = [      // (section, name prefixes, needs a UI noun)
            (.dashboard, ["dashboard", "anasayfa", "anaekran"], false),
            (.tasks, ["gorev", "task"], false),
            (.agents, ["ajan", "agent"], false),
            (.research, ["arastirma", "research"], false),
            (.report, ["rapor", "report"], false),
            (.system, ["sistem", "system"], true),
            (.memory, ["hafiza", "bellek", "memory"], false),
            (.computer, ["bilgisayar", "computer"], true),
            (.learning, ["ogren", "learning"], false),
            (.capabilities, ["yetenek", "capabilit"], false),
            (.settings, ["ayar", "setting"], false),
        ]
        // “ana ekran” (two tokens) is the dashboard
        if let i = t.firstIndex(of: "ana"), i + 1 < t.count, t[i + 1].hasPrefix("ekran") || t[i + 1].hasPrefix("sayfa") || t[i + 1].hasPrefix("panel") { return .dashboard }
        for (section, names, needsNoun) in table {
            if t.contains(where: { w in names.contains { w.hasPrefix($0) } }) {
                if needsNoun && !uiNoun { continue }
                return section
            }
        }
        return nil
    }
}
