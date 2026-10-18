import Foundation

// MARK: - The gate between a remote classifier's guess and JARVIS' routing (V1.0 Jev gating pass)
//
// Jev answers ONE question — "what does the user intend?" — and nothing else. It is never the orchestrator, never executes, never approves, never produces a completion claim, and DETERMINISTIC POLICY ALWAYS WINS:
//
//   utterance → deterministic grammar ──decided──▶ USE IT (Jev is never asked)
//                                     └─abstained─▶ PREFLIGHT (short, command-shaped, not quoted / negated / critical)
//                                                      └▶ Jev → typed CANDIDATE → LOCAL GATE (this file) ──accept──▶ typed route (the EXISTING handler, with its own verification)
//                                                                                                       └─reject──▶ the existing router, exactly as if Jev did not exist
//
// What the gate checks, in this order, and why each is local and not Jev's to decide:
//   · the candidate's intent belongs to a SAFETY CLASS the current level allows (A read-only · B own-UI · C execution-capable — never accepted in production · none: conversation / correction / unknown are not routes);
//   · risk and gate are RE-DERIVED here from the intent, the action AND the words of the utterance (a classifier's "low risk" is not a thing that exists); a critical word (delete, push, purchase, credential …) rejects;
//   · an INTENT-specific confidence floor (never lower than the category floor, never lower than the user's own) — intent confidence is not target confidence;
//   · the TARGET must be resolved by JARVIS' own resolvers (page registry, project registry, applications, settings): Jev never names an executable identifier, and an ambiguous or unresolved target rejects;
//   · the required capability is actually available, the model that answered is the model that was calibrated, and a provider-SELECTION request is never read as a capability question.
// Every rejection has a code, so a day of use can say WHY Jev's answer was not used. Pure: no network, no clock, no state, no approval, no execution API.

/// What a remote classifier may ever influence.
enum JevIntentClass: String, Codable, Sendable, CaseIterable {
    /// A — answers from JARVIS' own state (status, voice, provider capability, project query).
    case readOnly
    /// B — changes only JARVIS' own screen (a page).
    case ownUI
    /// C — operates something (application, computer, project, setting, research, stop/cancel). NEVER accepted from a remote classifier in production; measured by `simulate` only.
    case executionCapable
    /// Not a route: conversation, correction, unknown. Nothing to accept — the router / correction engine own them.
    case notRoutable
    /// D — critical (delete, push, purchase, credentials, deploy …). Never an intent: it is DERIVED locally from policy / words and can never be accepted whatever the classifier said.
    case critical
}

enum JevIntentSafety {
    static func classify(_ intent: DecisionIntent) -> JevIntentClass {
        switch intent {
        case .systemStatus, .voiceStatus, .providerCapability, .projectQuery: .readOnly
        case .jarvisNavigation: .ownUI
        case .macosApplicationAction, .computerUse, .projectOpen, .projectTask, .settingsChange, .research, .stopSpeech, .cancelTask: .executionCapable
        case .conversation, .correction, .unknown: .notRoutable
        }
    }
}

/// How far a gated classifier may reach. `readOnly` is the DEFAULT and the recommendation; `ownUI` adds page changes; `execution` is a SIMULATION level (the benchmark measures what it would do) —
/// production code can never accept a class-C decision (`JevGatePolicy.executionIsEnabledInProduction` is a constant).
enum JevGateLevel: String, Codable, CaseIterable, Sendable, Comparable {
    case readOnly, ownUI, execution
    private var rank: Int { switch self { case .readOnly: 0; case .ownUI: 1; case .execution: 2 } }
    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

enum JevRejection: String, Codable, Sendable, CaseIterable {
    // preflight: Jev is not even asked
    case deterministicDecided, deterministicAmbiguity, policyBlock, notCommandShaped, quotedOrMeta, negated, criticalContent
    // after the answer
    case malformedConfidence, intentNotRoutable, levelDoesNotAllow, executionNotEnabled, localRiskHigher, ambiguousCandidate
    case belowIntentThreshold, noLexicalAnchor, possibleSelection, targetUnresolved, targetAmbiguous, capabilityUnavailable, modelChanged, notGatedMode, unavailable

    /// Preflight reasons: no request is made, so nothing is sent and nothing is paid.
    var isPreflight: Bool { [.deterministicDecided, .deterministicAmbiguity, .policyBlock, .notCommandShaped, .quotedOrMeta, .negated, .criticalContent].contains(self) }
}

enum JevTargetResolution: Equatable, Sendable {
    case notNeeded
    case resolved(String)
    case ambiguous([String])
    case unresolved
}

// MARK: Utterance guards (local, deterministic, independent of the classifier)

/// Word lists are written as one space-separated string so that a list of words ABOUT dangerous actions is not mistaken (by the source guards) for code that performs them.
private func wordList(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }

enum JevUtteranceGuards {
    private static let doubleQuoted = try! NSRegularExpression(pattern: #"["“”«»`][^"“”«»`]{3,}["“”«»`]"#)
    private static let singleQuoted = try! NSRegularExpression(pattern: #"(^|\s)['‘][^'’]{3,}['’](\s|[.,!?:;]|$)"#)
    private static let metaWords: Set<String> = ["demek", "derse", "dese", "diyorsa", "diyen", "cevir", "ceviri", "translate", "translation", "anlami", "anlamina", "anlama", "meaning", "means", "mean", "ornek", "example", "cumlesini", "cumle", "sentence", "ifadesi", "ifade", "komutu", "komut", "command"]
    private static let negationWords: Set<String> = ["demedim", "istemiyorum", "istemem", "istemiyoruz", "dont", "never", "cannot", "olsaydi", "olsa", "keske", "asla", "degil", "nor", "no"]
    private static let negationPairs: [(String, String)] = [("do", "not"), ("does", "not"), ("did", "not"), ("will", "not"), ("would", "not"), ("should", "not"), ("is", "not")]
    private static let selectionWords: [String] = ["kullan", "yaptir", "yaptirsana", "ver", "sec", "gec", "use", "switch", "prefer", "assign", "delegate", "route"]
    private static let nounLookalikes = ["arastirma", "arama", "aramayi", "aramalar"]
    /// Critical concepts (closed list, folded, token PREFIXES): delete / destroy, publish / push, purchase / payment, credentials, deployment, formatting.
    private static let criticalStems: [String] = wordList("sil silme silin delete remove wipe erase destroy format uninstall push pushla commit deploy publish yayinla yayinlar purchase satin odeme odemeyi pay buy checkout credential sifre sifremi parola password passwd token force")
    private static let criticalPrefixOnly: Set<String> = Set(wordList("sil delete remove wipe erase destroy push pushla commit deploy publish yayinla purchase pay buy format"))

    private static func has(_ re: NSRegularExpression, _ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    /// A command that is MENTIONED, quoted, translated or explained rather than given: quotation marks, or the words that make a sentence about a sentence.
    static func isQuotedOrMeta(_ raw: String) -> Bool {
        if has(doubleQuoted, raw) || has(singleQuoted, raw) { return true }
        let t = DecisionText.tokens(raw)
        return t.contains { metaWords.contains($0) } && t.count >= 3 && (t.contains("demek") || t.contains("derse") || t.contains("dese") || t.contains("diyorsa") || t.contains("cevir") || t.contains("translate")
                                                                          || t.contains("cumlesini") || t.contains("cumle") || t.contains("sentence") || t.contains("meaning") || t.contains("means") || t.contains("anlami") || t.contains("anlamina") || t.contains("ifadesi") || t.contains("komutu"))
    }

    /// A request NOT to do something, a wish, a counterfactual, "I did not say …": never a request to act. Local morphology (the same closed verb stems the lexicon uses) — not Jev's judgement.
    static func isNegated(_ raw: String) -> Bool {
        let t = DecisionText.tokens(raw)
        for (i, w) in t.enumerated() {
            if negationWords.contains(w) { return true }
            if nounLookalikes.contains(where: { w.hasPrefix($0) }) { continue }
            if isTrueNegation(w) || VerbMorphology.isNegativeImperative(w) { return true }
            if i + 1 < t.count, negationPairs.contains(where: { $0.0 == w && $0.1 == t[i + 1] }) { return true }
        }
        return false
    }

    /// The negative / infinitive forms of the lexicon's verb stems (“açma”, “silmeyin”, “kapatmak”). Tense-only forms (“gidiyor”, “açtım”) are NOT negation: “Sistem nasıl gidiyor?” is a status question, and a report of
    /// something done is not a request anyway (an executing answer is refused whatever the sentence).
    private static let negativeSuffixes: Set<String> = ["ma", "me", "mayin", "meyin", "masana", "mesene", "mak", "mek", "maz", "mez", "mamali", "memeli", "masin", "mesin", "mayalim", "meyelim", "mam", "mem", "madan", "meden"]
    private static func isTrueNegation(_ token: String) -> Bool {
        for s in VerbMorphology.stems.keys where token.hasPrefix(s) && token.count > s.count && negativeSuffixes.contains(String(token.dropFirst(s.count))) { return true }
        return false
    }

    /// The words of the utterance that make the request critical (empty = none).
    static func criticalWords(_ raw: String) -> [String] {
        var hits: [String] = []
        for w in DecisionText.tokens(raw) {
            for s in criticalStems where w == s || (criticalPrefixOnly.contains(s) && w.hasPrefix(s) && w.count <= s.count + 6 && !w.hasPrefix("silah") && !w.hasPrefix("siler") ) { hits.append(s); break }
        }
        return Array(Set(hits)).sorted()
    }

    /// "Bunu Claude'a yaptır", "Claude Code'u kullan": a request to CHOOSE a provider, which is a different intent than asking what is available.
    static func looksLikeSelection(_ raw: String) -> Bool {
        let t = DecisionText.tokens(raw)
        guard !DecisionText.isQuestion(raw, t) else { return t.contains { w in selectionWords.contains { w.hasPrefix($0) && !["gecici"].contains(w) } } && !t.contains(where: { $0.hasSuffix("mi") || $0.hasSuffix("mu") || $0 == "available" || $0 == "ready" }) }
        return t.contains { w in selectionWords.contains { w == $0 || w.hasPrefix($0) } }
    }
}

enum LocalRiskDerivation {
    /// Risk and gate for a candidate, derived from (intent, action) by the policy table AND from the words of the utterance. A classifier's own risk claim is never an input.
    static func derive(raw: String, candidate d: Decision) -> (risk: RiskClass, gate: DecisionGate) {
        var (risk, gate) = DecisionPolicy.classify(intent: d.intent, action: d.action)
        let words = JevUtteranceGuards.criticalWords(raw)
        guard !words.isEmpty else { return (max(risk, d.riskClass), gate == .none ? d.gate : gate) }
        let blockedWords: Set<String> = Set(wordList("push pushla commit deploy publish yayinla purchase satin odeme pay buy checkout credential sifre sifremi parola password passwd token force"))
        if !blockedWords.isDisjoint(with: words) { return (.critical, .blocked) }
        risk = max(risk, .high)
        if gate == .none { gate = .askFirst }
        return (risk, gate)
    }
}

// MARK: Preflight

enum JevPreflight {
    /// nil = Jev may be asked. A reason = no request is made. `gated` applies the stricter filters (quoted / negated / critical sentences are never worth a paid remote opinion that could not be accepted anyway).
    static func skipReason(raw: String, production: Decision, gated: Bool = true) -> JevRejection? {
        if production.gate != .none { return .policyBlock }
        if production.ambiguity != .none { return .deterministicAmbiguity }
        if production.intent != .unknown { return .deterministicDecided }
        guard JevRoutingPolicy.isCommandShaped(raw) else { return .notCommandShaped }
        guard gated else { return nil }
        if JevUtteranceGuards.isQuotedOrMeta(raw) { return .quotedOrMeta }
        if JevUtteranceGuards.isNegated(raw) { return .negated }
        if !JevUtteranceGuards.criticalWords(raw).isEmpty { return .criticalContent }
        return nil
    }
}

// MARK: The gate

struct JevGateInput: Sendable {
    var raw: String
    var production: Decision
    var candidate: Decision
    var level: JevGateLevel = .readOnly
    /// The user's own minimum (it can only raise the bar).
    var configuredFloor: Double = 0
    var targetResolution: JevTargetResolution = .notNeeded
    var capabilityAvailable = true
    /// A read-only / page answer must be CORROBORATED by a word of the utterance that belongs to its topic (a model that is confidently wrong about an unrelated sentence cannot route it). On by default; the
    /// evaluation measures what turning it off would cost.
    var requireAnchor = true
    /// The model the service reported answering with, and the model the calibration was measured on ("" = no calibration recorded).
    var reportedModel: String?
    var calibratedModel = ""
}

enum JevGateVerdict: Equatable, Sendable {
    case accept(Decision)
    case reject(JevRejection)
    var accepted: Decision? { if case .accept(let d) = self { return d }; return nil }
    var rejection: JevRejection? { if case .reject(let r) = self { return r }; return nil }
}

enum JevGatePolicy {
    /// A constant, not a setting: nothing in production accepts an execution-capable decision from a remote classifier. The benchmark measures what it WOULD do (`simulate`) so a future decision rests on evidence.
    static let executionIsEnabledInProduction = false

    /// Per-INTENT confidence floors for a REMOTE answer. RULES with a stated rationale, not numbers fitted to a benchmark (docs/JEV_DECISION_POLICY.md): the Phase B shadow measurement (aggregate, local Mac) found
    /// confidence ≥ 0.97 → 100 % correct on the main corpus (n 182) and 97.8 % held-out, ≥ 0.92 → 48/48 where the grammar abstains, 0.9–0.97 → 86 %, below 0.9 → 36–64 %. A read-only answer that is wrong costs a
    /// sentence, so its floor sits where the abstention evidence is clean (0.95); an answer that needs a TARGET (a project) or changes the screen sits at 0.97; anything that operates something needs 0.99 even in the simulation.
    /// An intent absent from both tables is never accepted.
    static let floors: [DecisionIntent: Double] = [.systemStatus: 0.95, .voiceStatus: 0.95, .providerCapability: 0.95, .projectQuery: 0.97, .jarvisNavigation: 0.97]
    static let simulationFloors: [DecisionIntent: Double] = [.macosApplicationAction: 0.99, .projectOpen: 0.99, .projectTask: 0.99, .settingsChange: 0.99, .research: 0.99]

    static func floor(for intent: DecisionIntent, simulating: Bool = false) -> Double? { floors[intent] ?? (simulating ? simulationFloors[intent] : nil) }

    static func evaluate(_ i: JevGateInput) -> JevGateVerdict { run(i, simulating: false) }

    /// What the gate WOULD do at level `.execution` — for measurement only. A production caller never uses this.
    static func simulate(_ i: JevGateInput) -> JevGateVerdict { var s = i; s.level = .execution; return run(s, simulating: true) }

    private static func run(_ i: JevGateInput, simulating: Bool) -> JevGateVerdict {
        let d = i.candidate
        // 1 · the grammar owns everything it understood or asked about, and policy blocks are final (defence in depth: the preflight already refused these)
        if let r = JevPreflight.skipReason(raw: i.raw, production: i.production, gated: true), r != .notCommandShaped { return .reject(r) }
        // 2 · a number that is not a number is a malformed answer (NaN, ±∞)
        guard d.confidence.isFinite else { return .reject(.malformedConfidence) }
        // 3 · safety class
        let cls = JevIntentSafety.classify(d.intent)
        switch cls {
        case .notRoutable, .critical: return .reject(.intentNotRoutable)
        case .executionCapable:
            guard simulating else { return .reject(.executionNotEnabled) }
            if d.intent == .computerUse || d.intent == .stopSpeech || d.intent == .cancelTask { return .reject(.levelDoesNotAllow) }     // never even in the simulation: no spoken / typed stop-vs-cancel guess, no screen guess
        case .ownUI: if i.level < .ownUI { return .reject(.levelDoesNotAllow) }
        case .readOnly: break
        }
        // 4 · risk and gate are RE-DERIVED locally; critical words reject whatever the classifier believed
        let local = LocalRiskDerivation.derive(raw: i.raw, candidate: d)
        if !JevUtteranceGuards.criticalWords(i.raw).isEmpty { return .reject(.criticalContent) }
        if local.risk != .low || local.gate != .none { return .reject(.localRiskHigher) }
        // 5 · ambiguity
        if d.ambiguity != .none { return .reject(.ambiguousCandidate) }
        // 6 · intent-specific floor (never below the category floor, never below the user's own)
        guard let intentFloor = floor(for: d.intent, simulating: simulating) else { return .reject(.intentNotRoutable) }
        let categoryFloor = ConfidencePolicy.standard.remote[ConfidencePolicy.category(of: d)] ?? intentFloor
        if d.confidence < max(intentFloor, categoryFloor, i.configuredFloor) { return .reject(.belowIntentThreshold) }
        // 6b · the utterance itself must mention the topic of the answer (local corroboration: Jev proposes, JARVIS' own vocabulary confirms)
        if i.requireAnchor, !JevCorroboration.anchored(intent: d.intent, page: d.target, raw: i.raw) { return .reject(.noLexicalAnchor) }
        // 7 · a request to CHOOSE a provider is not a question about availability
        if d.intent == .providerCapability, JevUtteranceGuards.looksLikeSelection(i.raw) { return .reject(.possibleSelection) }
        // 8 · the target comes from JARVIS' own resolvers; intent confidence is not target confidence
        switch (d.intent, i.targetResolution) {
        case (.jarvisNavigation, _):
            guard let page = d.target, DecisionVocabulary.hudSection(page) != nil else { return .reject(.targetUnresolved) }
        case (.projectQuery, .resolved), (.projectOpen, .resolved), (.projectTask, .resolved), (.macosApplicationAction, .resolved), (.settingsChange, .resolved), (.research, .resolved): break
        case (.projectQuery, .ambiguous), (.projectOpen, .ambiguous), (.projectTask, .ambiguous), (.macosApplicationAction, .ambiguous), (.settingsChange, .ambiguous), (.research, .ambiguous): return .reject(.targetAmbiguous)
        case (.projectQuery, _), (.projectOpen, _), (.projectTask, _), (.macosApplicationAction, _), (.settingsChange, _), (.research, _): return .reject(.targetUnresolved)
        default: break
        }
        // the older, narrower policy still applies on top (closed acceptable set, low risk, no gate, a page from the vocabulary)
        if !simulating, !GatedPolicy.accepts(d, minimumConfidence: i.configuredFloor) { return .reject(.levelDoesNotAllow) }
        // 9 · the capability the handler needs exists right now
        if !i.capabilityAvailable { return .reject(.capabilityUnavailable) }
        // 10 · calibration belongs to ONE model version
        if !i.calibratedModel.isEmpty, i.reportedModel != i.calibratedModel { return .reject(.modelChanged) }
        var accepted = d
        accepted.provenance = .jevGated
        return .accept(accepted)
    }
}

// MARK: Corroboration (the sentence must be about what the answer says)

enum JevCorroboration {
    /// Folded token PREFIXES that tie a sentence to a topic. Closed lists, hand-written, Turkish + English; a sentence without any of them is not about that topic, whatever a classifier believed.
    private static let anchors: [DecisionIntent: [String]] = [
        .systemStatus: ["sistem", "system", "durum", "status", "saglik", "health", "cpu", "bellek", "memory", "ram", "disk", "performans", "performance", "calisiy", "running", "hazir", "ready", "battery", "pil", "yolunda"],
        .voiceStatus: ["ses", "voice", "mikrofon", "microphone", "mic", "duy", "hear", "dinl", "listen", "audio", "wake", "konus", "speak", "speech", "talk", "gelir", "geliyor", "coming", "sound"],
        .providerCapability: ["claude", "codex", "opencode", "qwen", "gemma", "jev", "model", "provider", "saglayici", "motor", "engine", "yetenek", "capab", "kullanabil", "available", "mevcut", "hazir", "ready", "mcp", "tool", "arac", "yapabil", "capable"],
        .projectQuery: ["proje", "project", "durum", "status", "unity", "repo", "branch", "git", "hamam", "scene", "sahne", "kaldigimiz", "progress", "ilerle"],
    ]
    private static let pageStems: [String: [String]] = [
        "dashboard": ["dashboard", "anasayfa", "ana", "home"], "tasks": ["gorev", "task"], "agents": ["ajan", "agent"], "research": ["arastir", "research"], "report": ["rapor", "report"], "system": ["sistem", "system"],
        "memory": ["hafiza", "bellek", "memory"], "computer": ["bilgisayar", "computer"], "learning": ["ogren", "learning"], "capabilities": ["yetenek", "capabilit"], "settings": ["ayar", "setting", "preferences", "tercih"],
    ]

    static func anchored(intent: DecisionIntent, page: String?, raw: String) -> Bool {
        let tokens = DecisionText.tokens(raw)
        func hit(_ stems: [String]) -> Bool { tokens.contains { t in stems.contains { t.hasPrefix($0) } } }
        if intent == .jarvisNavigation { return page.flatMap { pageStems[$0] }.map(hit) ?? false }
        guard let list = anchors[intent] else { return true }        // intents without a list are decided by other gates (target resolution, floors)
        return hit(list)
    }
}
