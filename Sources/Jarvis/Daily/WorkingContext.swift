import Foundation
import Observation

// MARK: - Conversational working context (V0.15, DEC-235)
//
// A SMALL, SHORT-LIVED set of typed references to things the user and JARVIS just talked about, so that “onu kullan”, “ikincisini dene”, “biraz sola al” can be understood.
//   • It is NOT Project Memory (nothing here is written to memory, the learning layer or the database) and NOT authority: no referent approves, grants a capability or changes a policy.
//   • Only validated, user-visible things enter: a research candidate record, a task the user started, a project the user named, an object a typed Unity result named, the user's own words.
//     Text produced by a model, an MCP server or a web page can never become a referent by itself, and a label that looks like an instruction is refused.
//   • It is bounded (16 items, 30 minutes, 30 turns) and it decays on a topic change. A restart forgets it (the persisted truth — Project Continuity — answers “where were we”).
//   • A resolved follow-up is REWRITTEN into an explicit sentence that goes through the normal pipeline (router → task intake → V0.12). Destructive follow-ups never resolve from recency.

enum ReferentKind: String, Sendable, CaseIterable {
    case project, task, asset, unityObject, application, document, completedAction
}

enum ReferentSource: Equatable, Sendable {
    /// The user named or chose it in their own words.
    case userStated
    /// A typed result record produced by a JARVIS subsystem (e.g. “research-report”, “unity-result”).
    case validatedResult(String)
    /// Current system state (the selected project, a task that is running).
    case systemState(String)
}

struct ContextReferent: Identifiable, Equatable, Sendable {
    let id = UUID()
    var kind: ReferentKind
    /// The stable identifier of the thing (task id, candidate id, project key, object global id / path). Structured, never free text.
    var refID: String
    /// A short, sanitised display name (≤ 80 characters, no control characters).
    var label: String
    var source: ReferentSource
    /// Where it came from, as a pointer (“research:<id>#2”). Never copied content.
    var evidence: String
    var confidence: Double
    var createdAt: Date
    var turn: Int
    /// Items noted together (a list of results) share a group; `ordinal` is the 1-based position in it.
    var group: UUID?
    var ordinal: Int?
    /// The user explicitly picked this one (“ikincisini dene”); it supersedes the rest of its list.
    var selected = false
    /// An optional URL the explicit goal can carry for precision (a validated candidate's page).
    var url: String?
    /// For a completed action: the user's OWN earlier request, verbatim (bounded), so “tekrar dene” re-submits exactly what they asked — through the normal pipeline again.
    var payload: String?

    /// nil when the label is unusable: empty, instruction-shaped or secret-shaped.
    static func sanitizedLabel(_ raw: String) -> String? {
        let cleaned = raw.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
            .split(separator: " ").joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }
        let label = String(cleaned.prefix(80))
        guard UntrustedContent.scan(label).isEmpty, !OutputSanitizer.containsSecret(label) else { return nil }
        // The label is later quoted inside an explicit goal: quotes and backticks could close that quotation.
        return label.replacingOccurrences(of: "“", with: "'").replacingOccurrences(of: "”", with: "'").replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "`", with: "'")
    }
}

@MainActor @Observable
final class ConversationWorkingContext {
    static let capacity = 16
    static let maxAge: TimeInterval = 30 * 60
    static let maxTurns = 30
    /// Settings → Daily JARVIS → Conversational follow-ups.
    var enabled = true
    @ObservationIgnored var clock: () -> Date = { Date() }
    private(set) var items: [ContextReferent] = []
    private(set) var turn = 0
    /// A question JARVIS asked to resolve an ambiguity; the next short answer may complete it.
    private(set) var clarification: Clarification?
    /// The last accepted turn (what the user said, how JARVIS read it, what it answered) and, after a correction, the turn that was corrected. Bounded; never an authority.
    private(set) var lastTurn: TurnMemory?
    private(set) var correction: CorrectionMarker?

    struct Clarification: Equatable, Sendable {
        var verb: FollowUpVerb
        var candidateIDs: [UUID]
        var conditional: Bool
        var turn: Int
    }

    // MARK: Lifecycle

    /// One accepted user message. Expires old references and an outdated clarification.
    func beginTurn() {
        turn += 1
        prune()
        if let c = clarification, turn - c.turn > 2 { clarification = nil }
    }

    func prune() {
        let now = clock()
        items.removeAll { now.timeIntervalSince($0.createdAt) > Self.maxAge || turn - $0.turn > Self.maxTurns }
        if items.count > Self.capacity { items.removeFirst(items.count - Self.capacity) }
        if let c = clarification { let live = Set(items.map(\.id)); if !c.candidateIDs.allSatisfy(live.contains) { clarification = nil } }
    }

    /// “Clear current conversation context” (Settings) and a topic change. Project Memory is untouched.
    func clear() { items.removeAll(); clarification = nil; lastTurn = nil; correction = nil }

    func recordTurn(_ t: TurnMemory) { lastTurn = TurnMemory(userText: TurnMemory.clip(t.userText), interpretation: t.interpretation, answer: TurnMemory.clip(t.answer)) }
    func markCorrection(of previous: TurnMemory) { correction = CorrectionMarker(previous: previous, turn: turn) }

    /// A project transition drops everything that belonged to the old project (assets, objects, documents, completed actions).
    func projectChanged(to newKey: String?) {
        let current = items.first { $0.kind == .project }?.refID
        guard current != newKey else { return }
        items.removeAll { $0.kind != .application }
        clarification = nil
    }

    // MARK: Noting (validated sources only — see the type comment)

    @discardableResult
    func note(kind: ReferentKind, refID: String, label rawLabel: String, source: ReferentSource, evidence: String, confidence: Double = 0.9, url: String? = nil, selected: Bool = false, payload: String? = nil) -> ContextReferent? {
        guard enabled, let label = ContextReferent.sanitizedLabel(rawLabel), !refID.isEmpty, refID.count <= 400 else { return nil }
        var r = ContextReferent(kind: kind, refID: refID, label: label, source: source, evidence: String(evidence.prefix(120)), confidence: confidence, createdAt: clock(), turn: turn, url: url.map { String($0.prefix(300)) })
        r.selected = selected
        r.payload = payload.map { String($0.prefix(400)) }
        items.removeAll { $0.kind == kind && $0.refID == refID && $0.group == nil }       // the same thing noted again moves to the front
        items.append(r)
        if items.count > Self.capacity { items.removeFirst(items.count - Self.capacity) }
        return r
    }

    /// A ranked list (research candidates): the members share a group and an ordinal, newest list last. An older list of the same kind is replaced.
    @discardableResult
    func noteList(kind: ReferentKind, entries: [(refID: String, label: String, url: String?)], source: ReferentSource, evidence: String, limit: Int = 6) -> [ContextReferent] {
        guard enabled else { return [] }
        items.removeAll { $0.kind == kind && $0.group != nil }
        let group = UUID()
        var out: [ContextReferent] = []
        for e in entries.prefix(limit) {
            guard let label = ContextReferent.sanitizedLabel(e.label), !e.refID.isEmpty else { continue }
            var r = ContextReferent(kind: kind, refID: e.refID, label: label, source: source, evidence: String(evidence.prefix(100)) + "#\(out.count + 1)", confidence: 0.9, createdAt: clock(), turn: turn, url: e.url.map { String($0.prefix(300)) })
            r.group = group; r.ordinal = out.count + 1
            out.append(r)
        }
        items.append(contentsOf: out)
        if items.count > Self.capacity { items.removeFirst(items.count - Self.capacity) }
        return out
    }

    /// The user picked one: it supersedes its list for later “onu / it”.
    func select(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let kind = items[i].kind
        for j in items.indices where items[j].kind == kind { items[j].selected = false }
        items[i].selected = true
        items[i].turn = turn
        let picked = items.remove(at: i)
        items.append(picked)
    }

    func setClarification(_ c: Clarification?) { clarification = c }

    // MARK: Reading

    /// Fresh referents of the kinds, newest first.
    func candidates(_ kinds: Set<ReferentKind>) -> [ContextReferent] {
        let now = clock()
        return items.filter { kinds.contains($0.kind) && now.timeIntervalSince($0.createdAt) <= Self.maxAge && turn - $0.turn <= Self.maxTurns }.reversed()
    }

    func referent(_ id: UUID) -> ContextReferent? { items.first { $0.id == id } }
}

// MARK: - Follow-up grammar

enum FollowUpVerb: String, Sendable, Equatable {
    case use        // dene / kullan / try / use / test
    case place      // koy / ekle / put / add / import
    case remove     // sil / kaldır / delete / remove
    case move       // sola al / move it left
    case retry      // tekrar dene / try again
    var destructive: Bool { self == .remove }
}

struct FollowUp: Equatable, Sendable {
    var verb: FollowUpVerb
    var ordinal: Int?                    // 1-based; -1 = the last one
    var usesPronoun: Bool
    var conditional: Bool                // “uygunsa …” / “if suitable …”
    var direction: String?               // “left” “right” “up” “down” “forward” “back”
    var small: Bool                      // “biraz” / “a bit”
    var namesLastFound: Bool             // “son bulduğun asset”, “önceki asset”
}

enum FollowUpParser {
    private static func tokens(_ raw: String) -> [String] {
        let f = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en")).lowercased().replacingOccurrences(of: "ı", with: "i")
        return String(f.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "#") ? $0 : " " }).split(separator: " ").map(String.init)
    }

    private static let ordinals: [(String, Int)] = [("birinci", 1), ("ilk", 1), ("ikinci", 2), ("ucuncu", 3), ("dorduncu", 4), ("besinci", 5), ("altinci", 6), ("sonuncu", -1),
                                                    ("first", 1), ("second", 2), ("third", 3), ("fourth", 4), ("fifth", 5), ("sixth", 6), ("last", -1)]
    private static let pronouns: Set<String> = ["onu", "bunu", "sunu", "bu", "su", "o", "it", "that", "this", "onlari", "them", "ona", "buna"]
    private static let directions: [String: String] = ["sola": "left", "sol": "left", "saga": "right", "sag": "right", "yukari": "up", "asagi": "down", "ileri": "forward", "geri": "back",
                                                       "left": "left", "right": "right", "up": "up", "down": "down", "forward": "forward", "backward": "back", "back": "back"]

    /// A complete bare answer to a clarification (“ikincisi”, “the second one”, “2”, “#3”) – used only while JARVIS is waiting for one.
    static func bareOrdinal(_ raw: String) -> Int? {
        let t = tokens(raw).filter { !["one", "the", "olan", "olani", "olanini", "numara", "number", "no", "tane", "lutfen", "please", "i", "mean", "want", "istiyorum", "demek"].contains($0) }
        guard t.count == 1, let w = t.first else { return nil }
        if let n = Int(w.replacingOccurrences(of: "#", with: "")), n >= 1, n <= 9 { return n }
        for (p, n) in ordinals where w.hasPrefix(p) { return n }
        return nil
    }

    private static let useVerbs = ["dene", "kullan", "test", "bak", "try", "use", "check", "evaluate", "incele"]
    private static let placeVerbs = ["koy", "ekle", "yerlestir", "aktar", "put", "add", "place", "import", "insert"]
    private static let removeVerbs = ["sil", "kaldir", "cikar", "delete", "remove", "discard"]
    private static let moveVerbs = ["al", "tasi", "kaydir", "cek", "move", "shift", "nudge", "slide"]

    /// A follow-up is a SHORT imperative whose verb opens or closes it (“use it”, “onu kullan”, “uygunsa projeye koy”, “biraz sola al”). A verb in the middle of a longer sentence
    /// (“Remember that we use the free model for this task”, “Modify my Unity project and test it”) is an ordinary request, never a reference to a recent thing.
    static func parse(_ raw: String) -> FollowUp? {
        let t = tokens(raw)
        guard !t.isEmpty, t.count <= 7 else { return nil }
        let joined = t.joined(separator: " ")
        func edge(_ prefixes: [String]) -> Bool {
            guard let first = t.first, let last = t.last else { return false }
            return prefixes.contains { first.hasPrefix($0) } || prefixes.contains { last.hasPrefix($0) }
        }
        func phrase(_ ps: [String]) -> Bool { ps.contains { joined.contains($0) } }

        var ordinal: Int?
        for w in t { for (p, n) in ordinals where w.hasPrefix(p) && !(p == "last" && w != "last") { ordinal = n; break }; if ordinal != nil { break } }
        if ordinal == nil, let h = t.first(where: { $0.hasPrefix("#") }), let n = Int(h.dropFirst()) { ordinal = n }
        if ordinal == nil, let i = t.firstIndex(of: "number") ?? t.firstIndex(of: "numara"), i + 1 < t.count, let n = Int(t[i + 1]) { ordinal = n }
        let usesPronoun = t.contains { pronouns.contains($0) }
        let namesLast = phrase(["son buldugun", "onceki asset", "onceki model", "previous asset", "previous model", "last asset", "last model", "last one you found", "you found"]) || t.first == "onceki"
        let conditional = phrase(["uygunsa", "uygun ise", "if suitable", "if it fits", "if appropriate", "if its ok", "if it is ok", "if okay", "if ok", "if compatible", "uyumluysa"])
        let small = t.contains("biraz") || phrase(["a bit", "a little", "slightly", "hafifce", "azicik"])
        let direction = t.compactMap { directions[$0] }.first

        if phrase(["tekrar dene", "yeniden dene", "bir daha dene", "try again", "retry"]) { return FollowUp(verb: .retry, ordinal: nil, usesPronoun: usesPronoun, conditional: false, direction: nil, small: false, namesLastFound: false) }
        if let direction, edge(moveVerbs) || phrase(["sola al", "saga al", "yukari al", "asagi al"]) {
            return FollowUp(verb: .move, ordinal: nil, usesPronoun: usesPronoun, conditional: false, direction: direction, small: small, namesLastFound: false)
        }
        let referential = usesPronoun || ordinal != nil || namesLast || conditional
        guard referential else { return nil }
        if edge(removeVerbs) { return FollowUp(verb: .remove, ordinal: ordinal, usesPronoun: usesPronoun, conditional: conditional, direction: nil, small: false, namesLastFound: namesLast) }
        if edge(placeVerbs) { return FollowUp(verb: .place, ordinal: ordinal, usesPronoun: usesPronoun, conditional: conditional, direction: nil, small: false, namesLastFound: namesLast) }
        if edge(useVerbs) { return FollowUp(verb: .use, ordinal: ordinal, usesPronoun: usesPronoun, conditional: conditional, direction: nil, small: false, namesLastFound: namesLast) }
        return nil
    }
}

// MARK: - Resolver

enum ReferenceOutcome: Equatable {
    case notFollowUp
    /// An explicit sentence for the normal pipeline plus a one-line statement of what was chosen. `referent` becomes the selection.
    case resolved(goal: String, chosen: String, referent: UUID)
    /// JARVIS asks which one; nothing is started.
    case ask(String)
    /// Understood as a follow-up, but there is nothing (fresh) to refer to.
    case nothing(String)
}

enum ReferenceResolver {
    private static let eligible: [FollowUpVerb: Set<ReferentKind>] = [
        .use: [.asset], .place: [.asset], .remove: [.unityObject, .asset, .document], .move: [.unityObject], .retry: [.completedAction],
    ]
    private static func tr(_ l: ReplyLanguage, _ en: String, _ trk: String) -> String { l == .tr ? trk : en }

    /// Resolves one utterance against the working context. Pure with respect to the context except `setClarification`.
    @MainActor
    static func resolve(_ text: String, context: ConversationWorkingContext, language l: ReplyLanguage) -> ReferenceOutcome {
        guard context.enabled else { return .notFollowUp }

        // A pending question (“which one?”) is answered by a bare ordinal; a bare yes/no answers nothing.
        if let c = context.clarification {
            if let n = FollowUpParser.bareOrdinal(text) {
                let pool = c.candidateIDs.compactMap(context.referent)
                let pick: ContextReferent?
                if n == -1 { pick = pool.last } else { pick = pool.first { $0.ordinal == n } ?? (n >= 1 && n <= pool.count ? pool[n - 1] : nil) }
                context.setClarification(nil)
                guard let pick else { return .nothing(tr(l, "There is no such option. Nothing was started.", "Böyle bir seçenek yok. Hiçbir şey başlatılmadı.")) }
                return build(verb: c.verb, referent: pick, conditional: c.conditional, move: nil, language: l, viaOrdinal: true)
            }
            if ApprovalGuard.isApprovalUtterance(text) {
                return .ask(tr(l, "A yes or no cannot choose between them. Which one do you mean? Say the number.", "Evet ya da hayır seçim yapmaz. Hangisini kastediyorsunuz? Numarasını söyleyin."))
            }
        }

        guard let f = FollowUpParser.parse(text) else { return .notFollowUp }
        let kinds = eligible[f.verb] ?? []
        let pool = context.candidates(kinds)

        if f.verb == .move {
            guard let target = unique(pool) else {
                if pool.isEmpty { return .nothing(tr(l, "I have no object in mind to move. Tell me which one.", "Taşınacak bir nesne aklımda yok. Hangisi olduğunu söyleyin.")) }
                return ask(pool, verb: f.verb, conditional: false, context: context, language: l)
            }
            return build(verb: .move, referent: target, conditional: false, move: (f.direction ?? "left", f.small), language: l, viaOrdinal: false)
        }

        if f.verb == .retry {
            guard let last = pool.first else { return .nothing(tr(l, "I have nothing recent to retry.", "Tekrar deneyecek yakın tarihli bir işim yok.")) }
            return build(verb: .retry, referent: last, conditional: false, move: nil, language: l, viaOrdinal: false)
        }

        if pool.isEmpty { return .nothing(tr(l, "I have nothing recent that fits “\(text)”. Tell me which one you mean.", "“\(text)” ile eşleşen yakın bir şey yok. Hangisini kastettiğinizi söyleyin.")) }

        // Ordinal: positions inside the newest list.
        if let n = f.ordinal {
            let list = pool.filter { $0.group != nil }.sorted { ($0.ordinal ?? 0) < ($1.ordinal ?? 0) }
            guard let newestGroup = pool.first(where: { $0.group != nil })?.group else {
                return .nothing(tr(l, "I have no list in mind to choose from.", "Aklımda seçim yapılacak bir liste yok."))
            }
            let inGroup = list.filter { $0.group == newestGroup }
            let pick = n == -1 ? inGroup.last : inGroup.first { $0.ordinal == n }
            guard let pick else { return .nothing(tr(l, "The list has only \(inGroup.count) item(s). Nothing was started.", "Listede yalnızca \(inGroup.count) öğe var. Hiçbir şey başlatılmadı.")) }
            if f.verb.destructive { return ask([pick], verb: f.verb, conditional: f.conditional, context: context, language: l, confirmSingle: true) }
            return build(verb: f.verb, referent: pick, conditional: f.conditional, move: nil, language: l, viaOrdinal: true)
        }

        // Pronoun / “the last one you found”.
        if f.verb.destructive {
            // Never from recency: only something the user explicitly chose or named, and only when it is the single candidate.
            let explicit = pool.filter { $0.selected || $0.source == .userStated }
            if explicit.count == 1, pool.count == 1 || pool.first?.id == explicit.first?.id { return build(verb: f.verb, referent: explicit[0], conditional: f.conditional, move: nil, language: l, viaOrdinal: false) }
            return ask(pool, verb: f.verb, conditional: f.conditional, context: context, language: l, confirmSingle: true)
        }
        if let target = unique(pool) { return build(verb: f.verb, referent: target, conditional: f.conditional, move: nil, language: l, viaOrdinal: false) }
        return ask(pool, verb: f.verb, conditional: f.conditional, context: context, language: l)
    }

    /// The single unambiguous referent: a selection newer than (or as new as) everything else, or the only distinct candidate, or a lone newest item outside any list.
    @MainActor
    private static func unique(_ pool: [ContextReferent]) -> ContextReferent? {
        guard let newest = pool.first else { return nil }
        if let sel = pool.first(where: { $0.selected }), sel.turn >= newest.turn { return sel }
        let distinct = Dictionary(grouping: pool, by: { "\($0.kind.rawValue)|\($0.refID)" })
        if distinct.count == 1 { return newest }
        if let g = newest.group, pool.filter({ $0.group == g }).count > 1 { return nil }          // a list with no choice made
        // Two different things: the newest wins only when nothing else was noted in the last two turns.
        let rivals = pool.dropFirst().filter { $0.refID != newest.refID && newest.turn - $0.turn <= 2 }
        return rivals.isEmpty ? newest : nil
    }

    @MainActor
    private static func ask(_ pool: [ContextReferent], verb: FollowUpVerb, conditional: Bool, context: ConversationWorkingContext, language l: ReplyLanguage, confirmSingle: Bool = false) -> ReferenceOutcome {
        let listed = Array(pool.prefix(6))
        context.setClarification(.init(verb: verb, candidateIDs: listed.map(\.id), conditional: conditional, turn: context.turn))
        let lines = listed.enumerated().map { "\($0.offset + 1)) \($0.element.label)" }.joined(separator: "  ")
        let q: String
        if verb.destructive {
            q = tr(l, "Which one should I remove? \(lines). I will not guess a target to delete.", "Hangisini kaldırmamı istersiniz? \(lines). Silinecek hedefi tahmin etmem.")
        } else {
            q = tr(l, "Which one do you mean? \(lines)", "Hangisini kastediyorsunuz? \(lines)")
        }
        return .ask(q)
    }

    @MainActor
    private static func build(verb: FollowUpVerb, referent r: ContextReferent, conditional: Bool, move: (String, Bool)?, language l: ReplyLanguage, viaOrdinal: Bool) -> ReferenceOutcome {
        let name = r.label
        let chosen = tr(l, "Chosen: “\(name)”.", "Seçildi: “\(name)”.")
        switch verb {
        case .use, .place:
            let url = r.url.map { " (\($0))" } ?? ""
            // The explicit sentence is an ASSET SUITABILITY question: research the candidate, compare licence / price / Unity compatibility, recommend. It must not contain import / download wording
            // (the planner would read that as a request to import); import is a separate, approval-gated step the user asks for in words of their own.
            // Worded as an imperative analysis ("Analyze whether … is suitable …"), which task intake turns into a read-only task whose planner recognises an asset-suitability question.
            let goal = tr(l, "Analyze whether the asset “\(name)”\(url) is suitable and compatible for this project: check its license, price and Unity compatibility, then recommend.",
                          "“\(name)” asset’inin\(url) bu proje için uygun ve uyumlu olup olmadığını incele: lisansını, fiyatını ve Unity uyumunu kontrol edip öner.")
            let note = verb == .place || conditional
                ? tr(l, " I will check suitability first; importing is a separate step that needs your approval.", " Önce uygunluğa bakacağım; projeye aktarma ayrı bir adım ve onayınızı gerektirir.")
                : ""
            return .resolved(goal: goal, chosen: chosen + note, referent: r.id)
        case .remove:
            let goal = tr(l, "Delete “\(name)”.", "“\(name)” öğesini sil.")
            return .resolved(goal: goal, chosen: chosen + tr(l, " Deleting still needs your approval.", " Silme işlemi yine de onayınızı gerektirir."), referent: r.id)
        case .move:
            let dir = move?.0 ?? "left", small = move?.1 ?? false
            let trDir = ["left": "sola", "right": "sağa", "up": "yukarı", "down": "aşağı", "forward": "ileri", "back": "geri"][dir] ?? dir
            let goal = tr(l, "Move the object “\(name)” \(small ? "a little " : "")to the \(dir == "up" || dir == "down" ? (dir == "up" ? "up" : "down") : dir) in the open scene.",
                          "Açık sahnedeki “\(name)” nesnesini\(small ? " biraz" : "") \(trDir) al.")
            return .resolved(goal: goal, chosen: chosen, referent: r.id)
        case .retry:
            return .resolved(goal: r.payload ?? name, chosen: tr(l, "Trying “\(name)” again.", "“\(name)” yeniden deneniyor."), referent: r.id)
        }
    }
}

// MARK: - “Hamam’a dön” (project focus by name)

enum ProjectSwitchParser {
    struct Request: Equatable, Sendable {
        var name: String
        /// The sentence is clearly about a project (“Hamam’a dön”, “… projesine dön”, “switch to the Hamam project”). A loose English “back to work” is not, so an unknown name is then left to the normal pipeline.
        var explicit: Bool
    }

    /// The project name in “Hamam’a dön”, “Hamam projesine dön/geç”, “back to Hamam”, “switch to the Hamam project”. nil = not a switch request.
    /// Navigation commands (“go to system”, “switch to compact”) are the command router's: the caller asks the router first.
    static func parse(_ raw: String) -> Request? {
        let f = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en")).lowercased().replacingOccurrences(of: "ı", with: "i")
        let cleaned = f.replacingOccurrences(of: "'", with: " ").replacingOccurrences(of: "’", with: " ")
        let t = String(cleaned.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : " " }).split(separator: " ").map(String.init)
        guard t.count >= 2, t.count <= 7 else { return nil }
        let projectWords: Set<String> = ["project", "projesine", "projeye", "projesi", "proje", "projesinde"]
        let drop: Set<String> = Set(["lutfen", "please", "the"]).union(projectWords)
        let notNames: Set<String> = ["geri", "ileri", "bana", "buraya", "oraya", "ana", "eski", "onceki", "son", "back", "here", "there", "work", "it", "that", "this", "later", "now"]
        let mentionsProject = t.contains { projectWords.contains($0) }
        func clean(_ words: [String]) -> [String] {
            var w = words.filter { !drop.contains($0) }
            if w.count >= 2, w.first == "jarvis" { w.removeFirst() }          // “Jarvis, Hamam'a dön” (the address) — but “JARVIS projesine dön” names the project
            return w
        }
        // Turkish: <name> [a|e|ya|ye|na|ne] don|gec
        if let last = t.last, ["don", "gec", "donelim", "geceriz", "gecelim"].contains(last) {
            var name = clean(Array(t.dropLast()))
            if name.count == 2, ["a", "e", "ya", "ye", "na", "ne"].contains(name[1]) { name.removeLast() }
            if name.count == 1, name[0].count >= 2, !notNames.contains(name[0]) { return Request(name: name[0], explicit: true) }
            return nil
        }
        // English: back to <name> / switch to <name> / go back to <name> / return to <name>
        for lead in [["back", "to"], ["switch", "to"], ["return", "to"], ["go", "back", "to"]] where t.count > lead.count && Array(t.prefix(lead.count)) == lead {
            let name = clean(Array(t.dropFirst(lead.count)))
            if name.count == 1, !notNames.contains(name[0]) { return Request(name: name[0], explicit: mentionsProject) }
        }
        return nil
    }
}
