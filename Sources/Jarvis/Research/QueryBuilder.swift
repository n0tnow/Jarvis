import Foundation

/// Turns a free-text research goal (English or Turkish) into a typed `ResearchRequest` and into deterministic search queries.
/// Deterministic on purpose: a model may REFINE the queries later (one budgeted call), but research never depends on one.
enum ResearchText {
    /// Lower-cases Turkish text and removes diacritics, including the dotless ı (which diacritic folding leaves alone): «Fırlatma» → «firlatma».
    static func fold(_ s: String) -> String {
        s.lowercased(with: Locale(identifier: "tr_TR")).replacingOccurrences(of: "ı", with: "i").folding(options: [.diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
    }
}

enum ResearchIntake {
    private static func fold(_ s: String) -> String { ResearchText.fold(s) }
    private static func words(_ s: String) -> [String] { fold(s).split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "#" && $0 != "+" }).map(String.init) }

    // MARK: Is this a web-research request at all?

    /// Phrases that clearly ask for outside-world information (kept conservative: "analyze the multiplayer issue" stays a project task).
    static func isResearchRequest(_ raw: String) -> Bool {
        let t = fold(raw)
        let w = Set(words(raw))
        let cues = ["research", "arastir", "look up", "lookup", "search the web", "search online", "search for", "find the official", "official documentation", "official docs",
                    "find documentation", "find the documentation", "find a free", "find free", "find me a free", "find me free", "free asset", "free animation", "free model", "free sound", "find an open-source",
                    "find an open source", "open-source library", "open source library", "compare these", "compare the best", "find people who", "who experienced", "internette ara", "webde ara", "dokumantasyon", "belgeleri bul", "belgelerini bul"]
        if cues.contains(where: { t.contains($0) }) { return true }
        // «ücretsiz bir animasyon bul» — a free asset ask needs a free word AND an asset word AND a find verb (a bare «ücretsiz mi?» is just a question)
        if (t.contains("ucretsiz") || t.contains("bedava")) && assetKind(w, t) != nil && (w.contains(where: { $0.hasPrefix("bul") || $0 == "ara" || $0.hasPrefix("aray") })) { return true }
        // Turkish suffixed forms: "araştır", "araştırır mısın", "araştırma"
        if w.contains(where: { $0.hasPrefix("arastir") }) { return true }
        if w.contains("compare") && (w.contains("libraries") || w.contains("technologies") || w.contains("approaches") || w.contains("options") || w.contains("engines")) { return true }
        return false
    }

    static func parse(goal raw: String, id: UUID = UUID(), project: ProjectFacts? = nil, now: Date = Date()) -> ResearchRequest {
        let t = fold(raw)
        let w = Set(words(raw))
        var c = ResearchConstraints()
        c.freeOnly = t.contains("free") || t.contains("ucretsiz") || t.contains("bedava") || t.contains("cc0") || t.contains("no cost")
        c.commercialUse = t.contains("commercial") || t.contains("ticari") || t.contains("sell") || t.contains("shipping game")
        c.officialOnly = t.contains("official") || t.contains("resmi") || t.contains("first-party") || t.contains("first party")
        c.openSourceOnly = t.contains("open-source") || t.contains("open source") || t.contains("opensource") || t.contains("acik kaynak")
        c.noAccount = t.contains("no login") || t.contains("without login") || t.contains("no account") || t.contains("hesapsiz") || t.contains("giris yapmadan")
        c.recentOnly = t.contains("latest") || t.contains("recent") || t.contains("current") || t.contains("up to date") || t.contains("guncel") || t.contains("2025") || t.contains("2026")
        c.assetKind = assetKind(w, t)
        if t.contains("urp") || t.contains("universal render") { c.renderPipeline = "URP" } else if t.contains("hdrp") { c.renderPipeline = "HDRP" } else if t.contains("built-in") || t.contains("builtin") { c.renderPipeline = "Built-in" }
        if let m = t.range(of: "unity\\s*(6000(?:\\.\\d+)?|6|20\\d\\d(?:\\.\\d+)?)", options: .regularExpression) { c.unityVersion = String(t[m]).replacingOccurrences(of: "unity", with: "").trimmingCharacters(in: .whitespaces) }
        if let p = project {
            c.unityVersion = c.unityVersion ?? p.unityVersion
            c.renderPipeline = c.renderPipeline ?? p.renderPipeline
        }
        let type = researchType(w, t, assetKind: c.assetKind)
        let freshness: Freshness = (c.freeOnly && type == .assetDiscovery) || t.contains("price") || t.contains("fiyat") || t.contains("current") || t.contains("guncel") || t.contains("latest") ? .current : (c.recentOnly ? .recent : .timeless)
        var req = ResearchRequest(id: id, goal: String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1500)), type: type, constraints: c, freshness: freshness, createdAt: now, project: project)
        req.deep = t.contains("deep") || t.contains("thorough") || t.contains("detayli") || t.contains("kapsamli") || t.contains("in depth")
        return req
    }

    private static func assetKind(_ w: Set<String>, _ t: String) -> AssetKind? {
        if w.contains("animation") || w.contains("animations") || w.contains("animasyon") || w.contains("animasyonu") || t.contains("animasyon") || w.contains("mocap") || w.contains("anim") { return .animation }
        if t.contains("sound effect") || w.contains("sfx") || w.contains("ses") || w.contains("sesi") || t.contains("audio") { return .audio }
        if w.contains("music") || w.contains("muzik") || w.contains("soundtrack") { return .music }
        if w.contains("texture") || w.contains("textures") || w.contains("doku") || w.contains("hdri") { return .texture }
        if w.contains("shader") || w.contains("shaders") { return .shader }
        if w.contains("font") || w.contains("fonts") { return .font }
        if w.contains("model") || w.contains("models") || w.contains("prop") || w.contains("props") || w.contains("mesh") || w.contains("asset") || w.contains("assets") || w.contains("environment") || w.contains("furniture") || w.contains("ortam") || w.contains("obje") { return .model3D }
        return nil
    }

    private static func researchType(_ w: Set<String>, _ t: String, assetKind: AssetKind?) -> ResearchType {
        let assetCue = assetKind != nil && (t.contains("free") || t.contains("ucretsiz") || t.contains("find") || t.contains("bul") || t.contains("arastir") || t.contains("asset") || t.contains("suitable") || t.contains("uygun"))
        if assetCue && !(t.contains("documentation") || t.contains("docs ")) { return .assetDiscovery }
        if t.contains("documentation") || t.contains("official docs") || t.contains("dokumantasyon") || t.contains("api reference") || t.contains("scriptreference") || t.contains("manual") { return .documentation }
        if t.contains("error") || t.contains("exception") || t.contains("hata") || t.contains("crash") || t.contains("bug") || t.contains("not working") || t.contains("fails") || t.contains("warning cs") || t.range(of: "\\bcs\\d{4}\\b", options: .regularExpression) != nil { return .troubleshooting }
        if t.contains("people who") || t.contains("experienced") || t.contains("reddit") || t.contains("forum") || t.contains("community") || t.contains("workaround") { return .community }
        if t.contains("compare") || t.contains("comparison") || t.contains("versus") || t.contains(" vs ") || t.contains("karsilastir") { return .comparison }
        if t.contains("library") || t.contains("package") || t.contains("open-source") || t.contains("open source") || t.contains("kutuphane") || t.contains("framework") { return .library }
        if t.contains("latest") || t.contains("current") || t.contains("guncel") || t.contains("news") || t.contains("recent") { return .currentInfo }
        return .general
    }
}

/// Deterministic queries. Turkish domain words are translated through a small glossary so the first results are useful even without a model.
enum QueryBuilder {
    static let glossary: [String: String] = [
        "terlik": "slipper", "terligi": "slipper", "terlikler": "slippers", "hamam": "turkish bath hammam", "hamami": "hammam", "sabun": "soap", "havlu": "towel", "pestemal": "pestemal towel",
        "kova": "bucket", "tas": "bowl", "kese": "scrub mitt", "firlatma": "throwing", "firlat": "throw", "firlatmak": "throw", "animasyon": "animation", "animasyonu": "animation", "animasyonlari": "animations",
        "ucretsiz": "free", "ticari": "commercial", "kullanima": "", "kullanim": "", "kullanimi": "", "oyunum": "", "oyunu": "", "oyunumuz": "", "varlik": "asset", "varliklari": "assets", "varliklar": "assets", "poligonlu": "poly", "dusuk poligonlu": "low poly", "bedava": "free", "ses": "sound effect", "sesi": "sound effect", "muzik": "music", "oyun": "game", "karakter": "character", "ortam": "environment", "obje": "prop", "modeli": "model", "model": "model",
        "mobilya": "furniture", "ahsap": "wooden", "tas ": "stone", "mermer": "marble", "havuz": "pool", "lavabo": "sink basin", "kurna": "basin", "pencere": "window", "kapi": "door", "agac": "tree", "lamba": "lamp", "bank": "bench", "sandalye": "chair", "masa": "table", "tahta": "wooden plank", "buhar": "steam", "kutuphane": "library", "dokumantasyon": "documentation", "hata": "error",
        "yakalama": "catching", "carpma": "hit", "tepki": "reaction", "vurus": "hit", "yurume": "walking", "kosma": "running", "ziplama": "jump", "dans": "dance", "arastir": "", "bul": "", "bir": "", "icin": "", "uygun": "suitable",
        "stilize": "stylized", "cizgi": "cartoon", "dusuk": "low", "poligon": "poly", "cok": "", "ve": "", "ile": "", "bana": "", "bu": "", "su": "", "gibi": "like",
    ]
    private static let stop: Set<String> = ["a", "an", "the", "of", "for", "to", "in", "on", "and", "or", "is", "are", "that", "this", "with", "me", "my", "our", "please", "can", "you", "i", "we", "jarvis", "find", "search", "research", "look", "up", "about",
                                           "some", "any", "good", "best", "suitable", "game", "games", "that", "it", "be", "do", "does", "should", "would", "could", "get", "give", "show", "what", "which", "how", "there", "has", "have"]

    /// Significant English-ish terms of a goal (Turkish words are glossed).
    static func terms(_ goal: String) -> [String] {
        let folded = ResearchText.fold(goal)
        var out: [String] = []
        for token in folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "#" && $0 != "+" && $0 != "." }).map(String.init) {
            var t = token.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if t.isEmpty { continue }
            if let g = glossary[t] ?? glossary[stripTurkishSuffix(t)] { t = g }
            for piece in t.split(separator: " ").map(String.init) where !piece.isEmpty && !stop.contains(piece) && !out.contains(piece) { out.append(piece) }
        }
        return out
    }

    private static func stripTurkishSuffix(_ t: String) -> String {
        for suf in ["lari", "leri", "lar", "ler", "yi", "yu", "i", "u", "si", "su", "in", "un", "nin", "nun", "da", "de", "ta", "te", "dan", "den"] where t.hasSuffix(suf) && t.count - suf.count >= 4 { return String(t.dropLast(suf.count)) }
        return t
    }

    struct Planned: Equatable, Sendable { var text: String; var providers: [String] }

    /// Initial plan: a handful of queries, each bound to the providers that suit the research type. Fully deterministic.
    static func plan(for r: ResearchRequest, maxQueries: Int) -> [Planned] {
        let core = terms(r.goal)
        // For assets the NOUNS carry the question ("bucket", "sink", "hammam"); "free / commercial / low poly" are added back by the template, so they must not eat the first slots.
        let subjectWords = core.filter { !SearchTerms.generic.contains($0) }
        let base = (r.type == .assetDiscovery && !subjectWords.isEmpty ? subjectWords.prefix(6) : core.prefix(7)).joined(separator: " ")
        guard !base.isEmpty else { return [] }
        var out: [Planned] = []
        func add(_ q: String, _ providers: [String]) { let t = q.trimmingCharacters(in: .whitespaces); if !t.isEmpty, !out.contains(where: { $0.text == t }) { out.append(Planned(text: String(t.prefix(140)), providers: providers)) } }
        let unity = r.goal.lowercased().contains("unity") || r.project != nil
        let ddg = "duckduckgo-html"
        switch r.type {
        case .documentation:
            if unity { for id in UnityDocsProvider.identifiers(in: r.goal).prefix(2) { add(id, ["unity-docs-direct"]) } }
            if unity { add("\(base) site:docs.unity3d.com", [ddg]) }
            add("\(base) official documentation", [ddg]); add(base, ["github-repositories"])
        case .troubleshooting:
            add(base, [ddg, "stack-exchange"]); add("\(base) fix", [ddg]); add(base, ["hacker-news"])
        case .community:
            add(base, ["stack-exchange", "hacker-news"]); add("\(base) reddit OR forum", [ddg])
        case .comparison, .library:
            add("\(base) library open source", ["github-repositories"]); add("\(base) comparison", [ddg]); add("\(base) vs alternatives", [ddg])
        case .currentInfo, .general:
            add(base, [ddg]); add("\(base) \(Calendar.current.component(.year, from: Date()))", [ddg])
        case .assetDiscovery:
            let kind = r.constraints.assetKind.map { $0 == .model3D ? "3d model" : $0.label } ?? "asset"
            let free = r.constraints.freeOnly ? "free cc0" : "free"
            add(base, ["polyhaven", "kenney"])
            add("\(base) \(free) \(kind) unity", [ddg])
            add("\(base) \(kind) kenney OR opengameart OR itch.io \(free)", [ddg])
            if r.constraints.assetKind == .animation { add("\(base) animation fbx humanoid \(free)", [ddg]); add("\(base) animation mixamo OR assetstore.unity.com", [ddg]) }
            add("\(base) unity asset store \(free)", [ddg])
            // GitHub repositories are a source for tools, shaders, UI kits and libraries — not for props, textures, sounds or animation clips.
            if r.constraints.assetKind.map({ [.tool, .library, .shader, .ui].contains($0) }) ?? true { add("\(base) open source \(kind) github", ["github-repositories"]) }
        }
        return Array(out.prefix(maxQueries))
    }

    /// A model may suggest better English queries; they are validated here before they replace anything.
    static func validateModelQueries(_ text: String, max: Int) -> [String]? {
        guard let json = PlanParser.extractJSONObject(text), let v = JSONValue.parse(json), let arr = v["queries"]?.array else { return nil }
        let qs = arr.compactMap(\.string).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 && $0.count <= 120 && !$0.lowercased().contains("http") && !$0.contains("\n") && UntrustedContent.scan($0).isEmpty }
        return qs.isEmpty ? nil : Array(qs.prefix(max))
    }
}
