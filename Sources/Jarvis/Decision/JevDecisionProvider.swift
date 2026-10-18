import Foundation

// MARK: - Jev: an OPTIONAL remote decision classifier (V1.0 decision milestone)
//
// Jev is a classifier, not the orchestrator and not a conversational model. It turns a minimised utterance into a typed `Decision` — nothing else:
//   · it never executes a tool, never approves, never creates a completion claim; its output is a `Decision` that the same policy table (`DecisionPolicy`) re-classifies for risk and gate, so
//     "Jev said low risk" is not a thing that can happen;
//   · DISABLED by default. SHADOW: JARVIS decides as always, Jev is asked in the background and only compared (agreement, confidence, latency). GATED: Jev's answer may select a route only when
//     the production grammar found nothing AND it is confident AND the intent belongs to the closed read-only set in `GatedPolicy`;
//   · it is a REMOTE, possibly paid provider and is represented as such: a minimised context only (no credentials, no audio, no screen contents, no source, no paths, no memory dump), a bounded hourly
//     request budget, a circuit breaker, usage counters, no automatic refill and no automatic enablement. When it is off, out of balance, offline, rate limited, slow or has changed its API,
//     JARVIS works exactly as before: the deterministic grammar and the existing router never depended on it.
// This file is the adapter boundary and has NO network or Keychain code. The real transport (`Providers/Jev/TypeSafeJevTransport`, the only network code of this layer) and the credential store
// (`Providers/Jev/JevCredentialStore`, the only reader of the key) live in their own two files, Phase B (DEC-275/276). Nothing in this file can reach the network.

enum JevMode: String, Codable, CaseIterable, Sendable { case disabled, shadow, gated }

/// What shadow mode asks about. DEFAULT `abstentionsOnly`: a request the grammar understands is never sent (cost, privacy, latency) — only the sentences it abstained on, where an opinion could matter.
/// `everything` exists for a deliberate agreement measurement (the offline benchmark does the same without a network).
enum JevShadowScope: String, Codable, CaseIterable, Sendable { case abstentionsOnly, everything }

struct JevConfig: Equatable, Sendable {
    var mode: JevMode = .disabled
    var shadowScope: JevShadowScope = .abstentionsOnly
    /// Gated mode only: below this the answer is ignored. A CONSERVATIVE default, uncalibrated until the Phase B benchmark measures it; configurable.
    var gatedMinimumConfidence = 0.92
    var timeoutSeconds = 4.0
    /// A configured model alias; empty = let the transport use its own discovery (Phase B). Never a hard-coded version.
    var modelAlias = ""
    /// Cost guard: at most this many requests per rolling hour, then JARVIS simply does not ask.
    var maxRequestsPerHour = 120
    /// Consecutive failures before the circuit opens, and for how long it stays open.
    var breakerFailures = 3
    var breakerSeconds: TimeInterval = 600
    var maxUtteranceCharacters = 300
    /// Extra attempts for a TRANSIENT transport failure only (`JevRetryPolicy`); each attempt counts against the hourly budget. 0 = never retry.
    var maxRetries = 1
    var retryBackoffSeconds: TimeInterval = 0.25
    /// Gated mode only (V1.0 Jev gating pass): how far an accepted answer may reach. DEFAULT `readOnly` — status / voice / provider-capability / project-query answers only. `ownUI` adds page changes;
    /// `execution` is a SIMULATION level that production never honours (`JevGatePolicy.executionIsEnabledInProduction`).
    var gateLevel: JevGateLevel = .readOnly
    /// Gated mode waits at most this long for the classifier, whatever `timeoutSeconds` says: a slow classifier must not slow a conversation (measured p95 ≈ 0.4 s; 1.5 s ≈ 3.5× that).
    var gatedTimeoutSeconds: TimeInterval = 1.5
    /// Cost guard per process lifetime on top of the hourly one (0 = no per-session cap). The service has no auto-refill; this only bounds what JARVIS itself may ask for.
    var maxRequestsPerSession = 1000
    /// The model version the confidence floors were calibrated on ("" = none recorded). When the service reports a DIFFERENT model, a gated answer is not accepted until calibration is repeated.
    var calibratedModel = ""
}

/// What may be sent. Built by `JevContextBuilder`; everything else is, by construction, never sent.
struct JevDecisionContext: Codable, Equatable, Sendable {
    var utterance: String
    var language: String
    var source: String
    /// The previous turn's interpretation as one short tag ("action", "settings", "conversation"); never its text.
    var previousInterpretation: String
    /// Closed vocabularies so the answer can only name things JARVIS has: intents and its own page names.
    var intents: [String]
    var pages: [String]
    /// Names (not paths) of known projects and of a few well-known applications, bounded.
    var projectNames: [String]
    /// Minimal TYPED conversational context (names only, ≤ 10 minutes old): {"lastApplication": "Safari", "lastProject": "Hamam"} — never a transcript. Sent only when the sentence is a pronoun / ellipsis ("onu", "bunu", "devam et").
    var referents: [String: String] = [:]
}

enum JevContextBuilder {
    /// nil = nothing is sent (credential-shaped text is refused outright: an utterance that carries a secret is not a classification job).
    static func build(utterance raw: String, language: String, source: UtteranceChannel, previousInterpretation: String, projectNames: [String], referents: DecisionReferents = DecisionReferents(), config: JevConfig = JevConfig()) -> JevDecisionContext? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !SecretGate.containsSecret(trimmed), !JevPrivacyFilter.looksSecret(trimmed) else { return nil }
        return JevDecisionContext(utterance: redact(trimmed, limit: config.maxUtteranceCharacters), language: language, source: source.rawValue,
                                  previousInterpretation: String(previousInterpretation.split(separator: ":").first.map(String.init) ?? "conversation").prefix(24).description,
                                  intents: DecisionIntent.allCases.map(\.rawValue), pages: DecisionVocabulary.pages,
                                  projectNames: mentionsProject(trimmed) ? Array(projectNames.map { String($0.prefix(40)) }.prefix(8)) : [], referents: typedReferents(trimmed, referents))
    }

    /// The typed slots a pronoun / ellipsis could mean — and only then: "Sistem durumunu söyle" needs none of them.
    static func typedReferents(_ text: String, _ r: DecisionReferents) -> [String: String] {
        let t = DecisionText.tokens(text)
        let elliptical = t.contains { w in ["onu", "bunu", "sunu", "o", "bu", "su", "devam", "ayni", "aynisini", "it", "that", "this", "same", "continue", "again"].contains(w) || w.hasPrefix("onu") || w.hasPrefix("bunu") }
        guard elliptical else { return [:] }
        var out: [String: String] = [:]
        if let a = r.fresh(.application) { out["lastApplication"] = a.label }
        if let p = r.fresh(.project) { out["lastProject"] = p.label }
        if let g = r.fresh(.jarvisPage) { out["lastPage"] = g.label }
        return out.mapValues { String($0.prefix(40)) }
    }

    /// Request minimisation: the project names (bounded, names only) are sent ONLY when the sentence is about a project. A status question or a page switch has no use for them.
    static func mentionsProject(_ text: String) -> Bool {
        let t = DecisionText.tokens(text)
        return t.contains { w in ["proje", "project", "oyun", "game", "devam", "continue", "open", "ac"].contains { w.hasPrefix($0) } }
    }

    /// File paths, e-mail addresses, network addresses and long digit/hex runs never leave the machine, even inside a sentence.
    static func redact(_ s: String, limit: Int) -> String {
        let words = s.split(whereSeparator: { $0.isWhitespace }).map { w -> String in
            let t = String(w)
            if t.hasPrefix("/") || t.hasPrefix("~/") || t.contains("://") || t.hasPrefix("file:") || t.contains("\\") || (t.count > 2 && t.dropFirst().hasPrefix(":\\")) { return "<path>" }
            if t.filter({ $0 == "/" }).count >= 2 || JevPrivacyFilter.looksLikeFileName(t) { return "<path>" }      // Assets/Scripts/Player.cs, notes.txt: a file name is not a classification input either
            if JevPrivacyFilter.isEmail(t) { return "<email>" }
            if JevPrivacyFilter.isNetworkAddress(t) { return "<address>" }
            let digits = t.filter { $0.isNumber || ($0.isHexDigit && t.count >= 16) }
            if digits.count >= 9 { return "<number>" }
            return t
        }
        return String(words.joined(separator: " ").prefix(limit))
    }
}

// MARK: Transport boundary (implemented by Providers/Jev/TypeSafeJevTransport)

enum JevFailure: String, Error, Codable, Sendable, Equatable {
    case notConfigured, credentialMissing, offline, timeout, rateLimited, outOfBalance, malformedResponse, apiChanged, unavailable
}

protocol JevTransport: Sendable {
    /// One bounded classification. Implementations must throw `JevFailure` (never hang past `timeout`), never log the credential and never retry on their own.
    func complete(_ request: JevClassifyRequest, modelAlias: String, timeout: TimeInterval) async throws -> JevClassification
}

/// The transport of a build/test with nothing configured: honest about not being connected.
struct UnconfiguredJevTransport: JevTransport {
    func complete(_ request: JevClassifyRequest, modelAlias: String, timeout: TimeInterval) async throws -> JevClassification { throw JevFailure.notConfigured }
}

// MARK: The question asked of the classifier

enum JevRequestBuilder {
    /// What each intent means, in the words the classifier reads. Written to separate the options from each other (TypeSafe: "criteria are descriptions the model reads").
    static let intentDescriptions: [(name: String, description: String)] = [
        ("conversation", "General talk, a question to answer, an explanation or an opinion. Nothing for the assistant to operate or look up in its own state."),
        ("voice_status", "Asks whether the assistant can hear the user: microphone, voice input, listening, 'can you hear me', 'is my voice coming through'."),
        ("system_status", "Asks for the assistant's own status or readiness: system state, what is running, health, whether the wake word or a feature is on."),
        ("jarvis_navigation", "Asks to open, switch to or go back to one of the assistant's OWN screens or pages (dashboard, system, tasks, agents, memory, settings ...) or to show or hide its own window."),
        ("macos_application_action", "Asks to open, launch or switch to a macOS application (Safari, Finder, Chrome, Unity ...)."),
        ("computer_use", "Asks to look at the screen, check what is visible, or operate something on the screen: press a button, play or pause a video, read a window."),
        ("project_open", "Asks to open a named software or game project."),
        ("project_query", "Asks about a project's status, contents or progress without changing anything."),
        ("project_task", "Asks to continue, develop, change, build, delete or commit work in a project."),
        ("settings_change", "Asks to change an assistant setting (speaking speed, volume, language, wake word, voice) or to undo such a change."),
        ("research", "Asks to research or look up information on the web."),
        ("correction", "The person corrects a word the assistant misheard or restates what they meant ('I said Safari, not Sofany')."),
        ("stop_speech", "Asks the assistant to stop talking, be quiet or stop reading aloud."),
        ("cancel_task", "Asks to stop, abort or cancel the task that is running."),
        ("provider_capability", "Asks which AI models or abilities the assistant has, or whether a specific model or ability is available or ready."),
        ("unknown", "None of the above fits, it is unintelligible, or it is too ambiguous to tell."),
    ]

    static func request(for c: JevDecisionContext) -> JevClassifyRequest {
        let known = Set(c.intents)
        var state = "Utterance: \(c.utterance)\nLanguage: \(c.language)\nHeard by: \(c.source)\nPrevious turn: \(c.previousInterpretation)"
        for (k, v) in c.referents.sorted(by: { $0.key < $1.key }) { state += "\n\(k): \(v)" }
        return JevClassifyRequest(state: state, intents: intentDescriptions.filter { known.contains($0.name) }, pages: c.pages)
    }
}

// MARK: Response → typed Decision

enum JevClassificationMapper {
    /// A typed Decision from the classifier's answer, or nil when the intent is not one of ours. Risk and gate are NOT taken from the answer: `DecisionPolicy` decides.
    static func decision(from c: JevClassification) -> Decision? {
        guard let intent = DecisionIntent(rawValue: c.intent), c.confidence.isFinite, c.confidence >= 0, c.confidence <= 1.000_001 else { return nil }
        var target: String?
        var action: String?
        if intent == .jarvisNavigation, let page = c.page, let known = DecisionVocabulary.hudSection(page) { target = known; action = "navigate" }
        return DecisionPolicy.finalize(intent: intent, confidence: c.confidence, normalized: "", target: target, action: action, deepReasoning: false, provenance: .jevShadow, provider: .jev)
    }
}

// MARK: Prompt and response contract for JSON-text classifiers (kept for model-style providers; the TypeSafe transport does not use it)

enum JevResponseParser {
    /// A typed Decision from the model's text, or nil when it is not exactly the contract (an unknown intent, a missing field, non-JSON). Risk and gate are NOT taken from the answer: `DecisionPolicy` decides.
    static func parse(_ text: String) -> Decision? {
        guard let object = jsonObject(text) else { return nil }
        guard let intentRaw = object["intent"] as? String, let intent = DecisionIntent(rawValue: intentRaw.trimmingCharacters(in: .whitespaces).lowercased()) else { return nil }
        guard let confNumber = object["confidence"] as? NSNumber, confNumber.doubleValue.isFinite, confNumber.doubleValue >= 0, confNumber.doubleValue <= 1.000_001 else { return nil }     // out of range = malformed, never clamped
        let confidence = min(confNumber.doubleValue, 1)
        func clean(_ v: Any?, _ limit: Int) -> String? {
            guard let s = v as? String else { return nil }
            let t = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init)).trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : String(t.prefix(limit))
        }
        let target = clean(object["target"], 80)
        let action = clean(object["action"], 40)?.lowercased()
        let deep = (object["needs_deep_reasoning"] as? Bool) ?? false
        return DecisionPolicy.finalize(intent: intent, confidence: confidence, normalized: clean(object["normalized"], 240) ?? "", target: target, action: action, deepReasoning: deep,
                                       provenance: .jevShadow, provider: .jev)
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
            if let end = s.range(of: "```", options: .backwards) { s = String(s[..<end.lowerBound]) }
        }
        guard let open = s.firstIndex(of: "{"), let close = s.lastIndex(of: "}"), open < close else { return nil }
        guard let data = String(s[open...close]).data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: data), let dict = any as? [String: Any] else { return nil }
        return dict
    }
}

// MARK: The policy table (risk and gate come from here, never from a classifier)

enum DecisionPolicy {
    /// Re-derives the flags, risk class and gate for (intent, action). Used for EVERY decision that did not come from the deterministic grammar.
    static func finalize(intent: DecisionIntent, confidence: Double, normalized: String, target: String?, action: String?, deepReasoning: Bool,
                         provenance: DecisionProvenance, provider: DecisionProviderID) -> Decision {
        let (risk, gate) = classify(intent: intent, action: action)
        let executing: Set<DecisionIntent> = [.jarvisNavigation, .macosApplicationAction, .projectOpen, .projectTask, .settingsChange, .stopSpeech, .cancelTask, .research]
        var execution = executing.contains(intent)
        if intent == .computerUse { execution = !["visibility_query", "query"].contains(action ?? "") }
        if intent == .settingsChange, action == "query" { execution = false }
        return Decision(intent: intent, confidence: confidence, normalized: normalized, target: target, action: action,
                        execution: execution, computerUse: intent == .computerUse, projectResolution: [.projectOpen, .projectTask, .projectQuery].contains(intent), deepReasoning: deepReasoning,
                        risk: risk, gate: gate, provenance: provenance, provider: provider)
    }

    static func classify(intent: DecisionIntent, action: String?) -> (RiskClass, DecisionGate) {
        let a = action ?? ""
        switch intent {
        case .projectTask:
            if ["git_push", "git_commit", "push", "commit"].contains(a) { return (.critical, .blocked) }
            if ["delete", "remove", "wipe"].contains(a) { return (.high, .askFirst) }
            if ["continue", "queue_next"].contains(a) { return (.low, .none) }
            return (.medium, .none)
        case .unknown:
            if ["purchase", "credential", "payment"].contains(a) { return (.critical, .blocked) }
            return (.low, .none)
        case .computerUse:
            return ["observe", "visibility_query", "media", "query"].contains(a) ? (.low, .none) : (.medium, .none)
        case .research: return (.low, .none)
        default: return (.low, .none)
        }
    }
}

// MARK: Provider protocol, results, usage

enum DecisionProviderResult: Equatable, Sendable {
    case decision(Decision, latency: TimeInterval)
    case unavailable(JevFailure)
}

protocol DecisionProviding: AnyObject, Sendable {
    func decide(_ context: JevDecisionContext, config: JevConfig) async -> DecisionProviderResult
    /// The model version the service reported on its latest answer (nil = unknown / not applicable). Used to invalidate a calibration when the service changes the model behind an alias.
    var reportedModel: String? { get }
}

extension DecisionProviding { var reportedModel: String? { nil } }

/// Counters for the remote classifier (memory only). Cost is reported as UNKNOWN unless a price is configured; nothing is ever refilled or enabled by this.
struct JevUsage: Equatable, Sendable {
    var requests = 0
    var inputTokens = 0
    var outputTokens = 0
    var failures: [String: Int] = [:]
    var skippedByBudget = 0
    var skippedByBreaker = 0
    var skippedNotConfigured = 0
    /// Transient failures that were retried (each retry also counts in `requests`).
    var retries = 0
    /// The model the service reported answering with (e.g. a versioned id behind an alias).
    var lastModel: String?
    /// Approximate cost in the account currency when a unit price was configured; nil = not estimated.
    func estimatedCost(pricePer1kTokens: Double?) -> Double? { pricePer1kTokens.map { Double(inputTokens + outputTokens) / 1000 * $0 } }
}

final class JevDecisionProvider: DecisionProviding, @unchecked Sendable {
    private let transport: any JevTransport
    private let credentialAvailable: @Sendable () -> Bool
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var _usage = JevUsage()
    private var recentRequests: [Date] = []
    private var consecutiveFailures = 0
    private var openUntil: Date?

    var usage: JevUsage { lock.lock(); defer { lock.unlock() }; return _usage }
    var reportedModel: String? { usage.lastModel }

    init(transport: any JevTransport = UnconfiguredJevTransport(), credentialAvailable: @escaping @Sendable () -> Bool = { false }, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport; self.credentialAvailable = credentialAvailable; self.clock = clock
    }

    func decide(_ context: JevDecisionContext, config: JevConfig) async -> DecisionProviderResult {
        guard config.mode != .disabled else { return .unavailable(.notConfigured) }
        guard credentialAvailable() else { bump(\.skippedNotConfigured); return .unavailable(.credentialMissing) }
        var attempt = 0
        while true {
            if let why = admit(now: clock(), config: config) { return .unavailable(why) }
            let started = clock()
            do {
                let answer = try await withTimeout(config.timeoutSeconds) { [transport] in
                    try await transport.complete(JevRequestBuilder.request(for: context), modelAlias: config.modelAlias, timeout: config.timeoutSeconds)
                }
                let latency = clock().timeIntervalSince(started)
                record(answer)
                guard let decision = JevClassificationMapper.decision(from: answer) else { fail(.malformedResponse, config); return .unavailable(.malformedResponse) }
                lock.lock(); consecutiveFailures = 0; lock.unlock()
                return .decision(decision, latency: latency)
            } catch let failure as JevFailure {
                fail(failure, config)
                guard JevRetryPolicy.shouldRetry(failure, attempt: attempt, maxRetries: config.maxRetries) else { return .unavailable(failure) }
                bump(\.retries)
                try? await Task.sleep(for: .seconds(JevRetryPolicy.backoff(attempt: attempt, base: config.retryBackoffSeconds)))
                attempt += 1
            } catch {
                fail(.unavailable, config)
                guard JevRetryPolicy.shouldRetry(.unavailable, attempt: attempt, maxRetries: config.maxRetries) else { return .unavailable(.unavailable) }
                bump(\.retries)
                try? await Task.sleep(for: .seconds(JevRetryPolicy.backoff(attempt: attempt, base: config.retryBackoffSeconds)))
                attempt += 1
            }
        }
    }

    // MARK: Budget, breaker, accounting

    private func admit(now: Date, config: JevConfig) -> JevFailure? {
        lock.lock(); defer { lock.unlock() }
        if let until = openUntil {
            if now < until { _usage.skippedByBreaker += 1; return .unavailable }
            openUntil = nil; consecutiveFailures = 0
        }
        recentRequests.removeAll { now.timeIntervalSince($0) > 3600 }
        if recentRequests.count >= config.maxRequestsPerHour { _usage.skippedByBudget += 1; return .rateLimited }
        if config.maxRequestsPerSession > 0, _usage.requests >= config.maxRequestsPerSession { _usage.skippedByBudget += 1; return .rateLimited }
        recentRequests.append(now)
        _usage.requests += 1
        return nil
    }

    private func record(_ r: JevClassification) {
        lock.lock(); defer { lock.unlock() }
        _usage.inputTokens += r.inputTokens ?? 0; _usage.outputTokens += r.outputTokens ?? 0
        if let m = r.model { _usage.lastModel = m }
    }

    private func fail(_ f: JevFailure, _ config: JevConfig) {
        lock.lock(); defer { lock.unlock() }
        _usage.failures[f.rawValue, default: 0] += 1
        consecutiveFailures += 1
        // "out of balance", a changed API or a missing credential do not heal by themselves quickly: open the circuit at once for those, after N for the transient ones
        let immediate: Set<JevFailure> = [.outOfBalance, .apiChanged, .credentialMissing]
        if immediate.contains(f) || consecutiveFailures >= config.breakerFailures { openUntil = clock().addingTimeInterval(config.breakerSeconds) }
    }

    private func bump(_ keyPath: WritableKeyPath<JevUsage, Int>) { lock.lock(); _usage[keyPath: keyPath] += 1; lock.unlock() }

    private func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask { try await Task.sleep(for: .seconds(max(0.05, seconds))); throw JevFailure.timeout }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw JevFailure.unavailable }
            return first
        }
    }
}
