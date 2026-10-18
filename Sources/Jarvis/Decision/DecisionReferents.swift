import Foundation

// MARK: - Typed, bounded referents for “onu aç”, “o projeyi kapat”, “devam et” (V1.0 reliability pass)
//
// A pronoun or an elliptical request (“onu”, “bunu”, “o uygulama”, “o proje”, “devam et”) names something the user and JARVIS JUST handled. Five typed slots hold exactly one thing each — the last
// application, project, JARVIS page, setting and task — with the AGE of that thing at the moment of the utterance. That is all: no free-form model memory, no text, no path, no authority. A slot is only
// ever filled from a validated record (an executed receipt, a registry project the user named, a task the user started), never from model text.
//
// Resolution is deterministic and conservative:
//   · a slot older than `ttl` does not exist;
//   · among the kinds a verb can act on, exactly ONE fresh slot resolves;
//   · several fresh slots resolve to the most recent only for NON-destructive verbs, and only when it is clearly more recent (`recencyMargin`) — otherwise JARVIS asks;
//   · a destructive or state-ending verb (close, quit, delete) never resolves from recency: it needs exactly one candidate, otherwise it asks.

enum DecisionReferentKind: String, Codable, CaseIterable, Sendable { case application, project, jarvisPage, setting, task }

struct ReferentSlot: Equatable, Codable, Sendable {
    /// Display name (an application name, a project name, a page raw value, a setting name, a task title). Bounded.
    var label: String
    /// Seconds since the thing was last handled, measured when the utterance arrived.
    var ageSeconds: Double
    init(label: String, ageSeconds: Double) { self.label = String(label.prefix(80)); self.ageSeconds = max(0, ageSeconds) }
}

struct DecisionReferents: Equatable, Codable, Sendable {
    /// A referent is forgotten after ten minutes (the working context itself keeps 30 minutes / 30 turns; a spoken pronoun is a short-range reference).
    static let ttl: TimeInterval = 600
    /// For a non-destructive verb, the most recent of several fresh slots wins only when it is at least this much newer than the runner-up (the project resolver uses the same margin).
    static let recencyMargin: TimeInterval = 60

    var application: ReferentSlot?
    var project: ReferentSlot?
    var jarvisPage: ReferentSlot?
    var setting: ReferentSlot?
    var task: ReferentSlot?

    init(application: ReferentSlot? = nil, project: ReferentSlot? = nil, jarvisPage: ReferentSlot? = nil, setting: ReferentSlot? = nil, task: ReferentSlot? = nil) {
        self.application = application; self.project = project; self.jarvisPage = jarvisPage; self.setting = setting; self.task = task
    }

    var isEmpty: Bool { application == nil && project == nil && jarvisPage == nil && setting == nil && task == nil }

    func slot(_ k: DecisionReferentKind) -> ReferentSlot? {
        switch k { case .application: application; case .project: project; case .jarvisPage: jarvisPage; case .setting: setting; case .task: task }
    }

    /// The slot only when it is still within the time-to-live.
    func fresh(_ k: DecisionReferentKind) -> ReferentSlot? {
        guard let s = slot(k), s.ageSeconds <= Self.ttl else { return nil }
        return s
    }

    enum Resolution: Equatable, Sendable {
        case resolved(DecisionReferentKind, ReferentSlot)
        /// More than one plausible thing (the kinds, most recent first): ask.
        case ambiguous([DecisionReferentKind])
        /// Nothing fresh of an acceptable kind: ask what is meant.
        case none
    }

    /// Resolves a pronoun against the acceptable kinds. `allowRecency` is false for destructive / state-ending verbs.
    func resolve(among kinds: [DecisionReferentKind], allowRecency: Bool) -> Resolution {
        let candidates = kinds.compactMap { k in fresh(k).map { (k, $0) } }.sorted { $0.1.ageSeconds < $1.1.ageSeconds }
        switch candidates.count {
        case 0: return .none
        case 1: return .resolved(candidates[0].0, candidates[0].1)
        default:
            if allowRecency, candidates[1].1.ageSeconds - candidates[0].1.ageSeconds >= Self.recencyMargin { return .resolved(candidates[0].0, candidates[0].1) }
            return .ambiguous(candidates.map(\.0))
        }
    }

    /// Builds the slots from (kind, label, age) triples of the existing conversation working context (newest of each kind wins). Unknown kinds are ignored.
    static func build(from entries: [(kind: String, label: String, ageSeconds: Double)]) -> DecisionReferents {
        var r = DecisionReferents()
        for e in entries.sorted(by: { $0.ageSeconds > $1.ageSeconds }) {          // oldest first, so the newest assignment wins
            let slot = ReferentSlot(label: e.label, ageSeconds: e.ageSeconds)
            switch e.kind {
            case "application": r.application = slot
            case "project": r.project = slot
            case "jarvisPage": r.jarvisPage = slot
            case "setting": r.setting = slot
            case "task": r.task = slot
            default: continue
            }
        }
        return r
    }
}

/// Remembers WHEN each kind of thing was last handled — from validated records only (a verified receipt, a project the user named, a task the user started). Memory only; a restart forgets it.
struct RecentReferentTracker: Equatable, Sendable {
    private var entries: [DecisionReferentKind: (label: String, at: Date)] = [:]
    static func == (a: RecentReferentTracker, b: RecentReferentTracker) -> Bool {
        a.entries.count == b.entries.count && a.entries.allSatisfy { k, v in b.entries[k].map { $0.label == v.label && $0.at == v.at } ?? false }
    }

    mutating func note(_ kind: DecisionReferentKind, label: String, at: Date = Date()) {
        let clean = label.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined().split(separator: " ").joined(separator: " ")
        guard !clean.isEmpty else { return }
        entries[kind] = (String(clean.prefix(80)), at)
    }
    mutating func forget(_ kind: DecisionReferentKind) { entries[kind] = nil }
    mutating func clear() { entries.removeAll() }

    func snapshot(now: Date = Date()) -> DecisionReferents {
        func slot(_ k: DecisionReferentKind) -> ReferentSlot? { entries[k].map { ReferentSlot(label: $0.label, ageSeconds: now.timeIntervalSince($0.at)) } }
        return DecisionReferents(application: slot(.application), project: slot(.project), jarvisPage: slot(.jarvisPage), setting: slot(.setting), task: slot(.task))
    }
}
