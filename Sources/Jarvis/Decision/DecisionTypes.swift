import Foundation

// MARK: - Decision Intelligence (V1.0 decision milestone, DEC-267…)
//
// A `Decision` says WHAT a user utterance is — a typed intent with flags — so the existing JARVIS pipeline can send it to the capability that already exists for it (a status answer,
// a JARVIS page, a native application, Computer Use, a project, the task engine, the router, plain conversation). It is ADVISORY and carries no authority:
//   · it has no approval, no capability, no execution API — the code that acts on it is the same code that acted on text before (verified, receipted, approval-gated);
//   · a confidence number is evidence about classification, never proof that anything happened (NO VERIFIED ACTION → NO COMPLETION CLAIM still holds);
//   · the optional remote classifier (Jev) can only ever produce a Decision, in shadow mode it is only compared, and in gated mode it is accepted only for the closed, read-only set in `GatedPolicy`.
// Three separate problems stay separate: command DECISION (this file family), conversational INTELLIGENCE (the local/remote language models), and VOICE reliability (`PathologicalTranscriptGuard`,
// which runs BEFORE any of this and whose rejected transcripts never get here).

enum DecisionIntent: String, Codable, CaseIterable, Sendable {
    case conversation
    case voiceStatus = "voice_status"
    case systemStatus = "system_status"
    case jarvisNavigation = "jarvis_navigation"
    case macosApplicationAction = "macos_application_action"
    case computerUse = "computer_use"
    case projectOpen = "project_open"
    case projectQuery = "project_query"
    case projectTask = "project_task"
    case settingsChange = "settings_change"
    case research
    case correction
    case stopSpeech = "stop_speech"
    case cancelTask = "cancel_task"
    case providerCapability = "provider_capability"
    case unknown
}

/// What a decision permits, independent of its confidence. `.askFirst` = an approval from a HUD button is needed before anything happens; `.blocked` = JARVIS has no path for it at all
/// (git push, purchase, credentials …). Policy outranks confidence: a decision with `.blocked` is never executed whatever any classifier believed.
enum DecisionGate: String, Codable, Sendable { case none, askFirst, blocked }

/// Who produced the decision (the audit trail says exactly this).
enum DecisionProviderID: String, Codable, Sendable { case deterministic, jev, router }

enum DecisionProvenance: String, Codable, Sendable {
    /// A closed grammar of this milestone (`DeterministicCommandRecognizer`).
    case deterministicGrammar
    /// An existing typed parser (ActionIntentParser, ReadinessIntentParser, ContinuityIntent, …) recognised it.
    case existingParser
    /// Nothing recognised it deterministically: it continues to the existing router (and, when enabled, a remote classifier may have an opinion).
    case routerFallback
    /// A remote classifier's answer in shadow mode (recorded, never used) or gated mode (accepted under `GatedPolicy`).
    case jevShadow, jevGated
    /// The bounded semantic lexicon (concept × target slots, closed Turkish morphology, referents) — Level 0b, after the closed grammar.
    case semanticLexicon
}

enum DecisionAmbiguity: Equatable, Codable, Sendable {
    case none
    /// Several readings are plausible; the system asks instead of guessing.
    case ambiguous(question: String)
}

struct DecisionCandidate: Equatable, Codable, Sendable {
    var intent: DecisionIntent
    var confidence: Double
}

struct Decision: Equatable, Codable, Sendable {
    var intent: DecisionIntent
    /// 0…1. Deterministic grammar: 1.0 for an exact closed form, lower for a tolerant form. Remote classifier: its own (uncalibrated until measured) number.
    var confidence: Double
    /// The request restated in one explicit, neutral sentence (never the raw transcript; bounded). What the user wants, not what to do.
    var normalizedUserIntent: String
    /// The object of the request: a page ("system"), an application ("Safari"), a project ("hamam"), a provider ("claude") …
    var target: String?
    /// A closed verb tag within the intent: "navigate", "open", "continue", "visibility_query", "observe", "media", "stop", "git_push" …
    var action: String?
    var requiresExecution: Bool
    var requiresComputerUse: Bool
    var requiresProjectResolution: Bool
    var requiresDeepReasoning: Bool
    var riskClass: RiskClass
    var gate: DecisionGate
    var provenance: DecisionProvenance
    var provider: DecisionProviderID
    var ambiguity: DecisionAmbiguity
    var alternatives: [DecisionCandidate]

    init(intent: DecisionIntent, confidence: Double = 1.0, normalized: String = "", target: String? = nil, action: String? = nil,
         execution: Bool = false, computerUse: Bool = false, projectResolution: Bool = false, deepReasoning: Bool = false,
         risk: RiskClass = .low, gate: DecisionGate = .none, ambiguity: DecisionAmbiguity = .none, provenance: DecisionProvenance = .deterministicGrammar, provider: DecisionProviderID = .deterministic,
         alternatives: [DecisionCandidate] = []) {
        self.intent = intent; self.confidence = min(max(confidence, 0), 1); self.normalizedUserIntent = String(normalized.prefix(240)); self.target = target.map { String($0.prefix(80)) }; self.action = action
        requiresExecution = execution; requiresComputerUse = computerUse; requiresProjectResolution = projectResolution; requiresDeepReasoning = deepReasoning
        riskClass = risk; self.gate = gate; self.provenance = provenance; self.provider = provider; self.ambiguity = ambiguity; self.alternatives = alternatives
    }

    static func unknown(_ normalized: String = "") -> Decision {
        Decision(intent: .unknown, confidence: 0, normalized: normalized, provenance: .routerFallback, provider: .router)
    }

    /// True when this decision came from a closed deterministic source and may be acted on without any model.
    var isDeterministic: Bool { provider == .deterministic && intent != .unknown }
}

/// The context a decision may use — facts, not authority. Everything here is already known to JARVIS; nothing is probed.
struct DecisionContext: Equatable, Sendable {
    var source: UtteranceChannel = .typed
    /// The interpretation the PREVIOUS turn was given ("action", "settings: …", "conversation" …) — used only to resolve a spoken correction.
    var previousInterpretation: String = "conversation"
    /// The previous user sentence (bounded), used only to apply a correction ("Sofany değil, Safari dedim") to it.
    var previousUserText: String = ""
    var hasPendingDecision: Bool = false
    /// The five typed slots (last application / project / page / setting / task) with their ages — facts for resolving “onu”, “o proje”, “devam et”; never authority.
    var referents = DecisionReferents()
}

enum UtteranceChannel: String, Codable, Sendable { case typed, voice }

/// What JARVIS may accept from a remote classifier in GATED mode: only intents whose handlers are read-only or change JARVIS' own UI, with a low risk class and no gate. An executing,
/// computer, project-writing or settings-changing decision from a remote classifier is NEVER accepted — those still need the deterministic grammar or the user's explicit typed request.
enum GatedPolicy {
    static let acceptableIntents: Set<DecisionIntent> = [.conversation, .voiceStatus, .systemStatus, .jarvisNavigation, .projectQuery, .providerCapability]

    static func accepts(_ d: Decision, minimumConfidence: Double) -> Bool {
        guard d.confidence >= minimumConfidence, d.ambiguity == .none, d.gate == .none, d.riskClass == .low, !d.requiresComputerUse, !d.requiresProjectResolution || d.intent == .projectQuery else { return false }
        guard acceptableIntents.contains(d.intent) else { return false }
        if d.intent == .jarvisNavigation { return d.target.map { DecisionVocabulary.hudSection($0) != nil } ?? false }
        return true
    }
}

enum DecisionVocabulary {
    /// The names of JARVIS' own pages, exactly the `HUDSection` raw values (a remote classifier's target must be one of these).
    static let pages: [String] = ["dashboard", "tasks", "agents", "research", "report", "system", "memory", "computer", "learning", "capabilities", "settings"]
    static func hudSection(_ name: String) -> String? { pages.contains(name.lowercased()) ? name.lowercased() : nil }
}
