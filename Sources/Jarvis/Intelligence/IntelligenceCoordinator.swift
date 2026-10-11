import Foundation
import Observation

/// The V0.3.1 resolver behind `ConversationService`: classify → route (policy) → build the provider → audit.
/// It composes, never replaces, the V0.3 layers: Claude Code / Codex still run through `ProviderManager`'s `CLIProvider`s.
@MainActor
@Observable
final class IntelligenceCoordinator: IntelligenceProviderResolving {
    let providers: ProviderManager
    let supervisor: ProviderSupervisor
    let audit: AuditRecorder
    @ObservationIgnored private let preferences: Preferences?

    /// Most recent routing decision (Settings/System panel shows the reason).
    private(set) var lastDecision: RoutingDecision?
    private(set) var activeEngine: ProviderID?
    /// Escalations allowed per request (bounded; DEC-026).
    var maxEscalations = 1
    var settingsOverride: RoutingSettings?
    @ObservationIgnored private var openCodeSession: String?
    @ObservationIgnored var onEvent: ((String) -> Void)?

    init(providers: ProviderManager, supervisor: ProviderSupervisor, audit: AuditRecorder, preferences: Preferences?) {
        self.providers = providers; self.supervisor = supervisor; self.audit = audit; self.preferences = preferences
    }

    var preference: ProviderPreference { preferences?.providerPreference ?? .auto }

    var routingSettings: RoutingSettings {
        if let o = settingsOverride { return o }
        var s = RoutingSettings()
        s.allowLocal = preferences?.allowLocalInAuto ?? true
        s.allowFreeCloud = preferences?.allowFreeCloudInAuto ?? true
        return s
    }

    var hasProviders: Bool { ProviderID.allCases.contains { supervisor.availability()[$0]?.state == .ready } }

    /// Compact status for the Conversation badge / System panel.
    var statusBadge: (text: String, usable: Bool) {
        if supervisor.lastRefresh == nil && providers.lastRefresh == nil { return ("CHECKING PROVIDERS", false) }
        let a = supervisor.availability()
        let now = Date()
        if let e = preference.providerID {
            let st = a[e]
            return ("\(e.shortName) · \(st?.state.label ?? "—")", st?.isUsable(at: now) == true)
        }
        let usable = ProviderID.allCases.filter { a[$0]?.isUsable(at: now) == true }
        return usable.isEmpty ? ("NO PROVIDER READY", false) : ("AUTO · \(usable.count) READY", true)
    }

    // MARK: Routing

    func route(_ profile: TaskProfile, preference override: ProviderPreference? = nil) async -> RoutingDecision {
        // First use: find out which subscription CLIs / the local model are ready. OpenCode is NOT touched here (lazy, see below).
        if supervisor.lastRefresh == nil { await supervisor.refreshAll(remoteCatalog: false, includeOpenCode: false) }
        let pref = override ?? preference
        if ModelRouter.mayUseFreeCloud(profile, preference: pref, settings: routingSettings) { await supervisor.ensureFreshCatalog() }
        let decision = ModelRouter.route(profile, snapshot: supervisor.snapshot(preference: pref, settings: routingSettings))
        lastDecision = decision
        return decision
    }

    // MARK: IntelligenceProviderResolving

    func resolve(_ kind: IntelligenceRequestKind) async -> ProviderResolution { await resolve(kind, prompt: "") }

    func resolve(_ kind: IntelligenceRequestKind, prompt: String) async -> ProviderResolution {
        guard kind == .reasoning else { return .unavailable(.noProviderReady(summary: "Autonomous work isn't enabled yet.")) }
        let profile = TaskClassifier.profile(for: prompt)
        let decision = await route(profile)
        guard let candidate = decision.selected else {
            let msg = decision.refusalMessage() ?? ProviderError.noProviderReady(summary: summary()).userMessage()
            let id = audit.begin(agentType: "Conversation", engine: decision.mode.providerID ?? .claudeCode, model: nil, decision: decision, prompt: prompt, privacy: profile.privacy)
            audit.finish(id, status: .failed, error: .refused(msg))
            if case .refused(.noCandidate) = decision.outcome, decision.mode == .auto { return .unavailable(.noProviderReady(summary: summary())) }
            return .unavailable(.refused(msg))
        }
        if let resolved = makeResolved(candidate, decision: decision, profile: profile, prompt: prompt, depth: 0) { return .ready(resolved) }
        // The chosen engine could not be instantiated (e.g. executable vanished): in Auto try the next candidate once.
        if decision.mode == .auto {
            for next in decision.fallbacks {
                if let r = makeResolved(next, decision: decision, profile: profile, prompt: prompt, depth: 1) { return .ready(r) }
            }
        }
        return .unavailable(.unavailable(candidate.engine, "could not start"))
    }

    func makeResolved(_ c: RoutingCandidate, decision: RoutingDecision, profile: TaskProfile, prompt: String, depth: Int,
                      agentType: String = "Conversation", taskID: UUID? = nil, parent: UUID? = nil, escalatedFrom: ProviderID? = nil,
                      label: String? = nil, owner: RunOwner = .conversation) -> ResolvedProvider? {
        let provider: any IntelligenceProvider
        switch c.engine {
        case .claudeCode, .codex:
            guard let path = providers.status(c.engine).executablePath else { return nil }
            provider = providers.makeProvider(c.engine, path: path)
        case .openCode:
            guard let id = c.model, let model = supervisor.openCode.model(id), let p = supervisor.openCode.provider(for: model) else { return nil }
            provider = p
        case .local:
            guard let runtime = supervisor.local, LocalModelPolicy.evaluate(profile).eligible else { return nil }
            provider = LocalQwenProvider(runtime: runtime, profile: profile)
        }
        var d = decision
        if depth > 0, let from = escalatedFrom { d.reasons["escalatedFrom"] = from.rawValue; d.reasons["selected"] = c.model ?? c.engine.rawValue }
        let runID = audit.begin(agentType: agentType, taskID: taskID, parent: parent, engine: c.engine, model: c.model, decision: d, prompt: prompt,
                                privacy: profile.privacy, label: label, owner: owner)
        if let from = escalatedFrom { audit.update(runID) { $0.escalatedFrom = from.rawValue } }
        // EVERY engine is observed through the sanitization boundary: raw output never reaches the runtime, console or database.
        let observed = SafeProvider(base: provider, runID: runID, hub: audit.hub)
        return ResolvedProvider(provider: observed, id: c.engine, model: c.model, runID: runID, decision: d, profile: profile, escalationDepth: depth)
    }

    func escalate(from failed: ResolvedProvider, error: ProviderError, prompt: String) async -> ResolvedProvider? {
        guard let decision = failed.decision, decision.mode == .auto, failed.escalationDepth < maxEscalations, let profile = failed.profile else { return nil }
        switch error { case .cancelled, .busy, .refused: return nil; default: break }
        let now = supervisor.clock()
        let failedKey = RoutingCandidate(engine: failed.id ?? .claudeCode, model: failed.model)
        for next in decision.fallbacks where next != failedKey {
            // Re-check the gates that may have changed since routing (cooldown/engine state).
            if supervisor.cooldownUntil(next.engine, nil, now: now) != nil { continue }
            if let m = next.model, supervisor.cooldownUntil(next.engine, m, now: now) != nil { continue }
            guard supervisor.availability()[next.engine]?.state == .ready else { continue }
            if let r = makeResolved(next, decision: decision, profile: profile, prompt: prompt, depth: failed.escalationDepth + 1, escalatedFrom: failed.id) {
                if let runID = failed.runID {
                    audit.update(runID) { $0.escalatedTo = next.engine.rawValue; $0.status = .escalated }
                    audit.hub?.noteEscalation(runID, from: failed.name, to: r.name)
                }
                audit.activity("escalation", "Escalated from \(failed.name) to \(r.name)", runID: r.runID)
                onEvent?("Escalated to \(r.name)")
                return r
            }
        }
        return nil
    }

    func runFinished(_ resolved: ResolvedProvider, outcome: ProviderOutcome, report: RunReport) {
        guard let engine = resolved.id else { return }
        switch outcome {
        case .completed:
            supervisor.recordSuccess(engine, subject: resolved.model)
            if let id = resolved.runID { audit.finish(id, status: .succeeded, resultText: report.resultText, usage: (report.inputTokens, report.outputTokens), toolAttempts: report.toolAttempts) }
        case .cancelled:
            if let id = resolved.runID { audit.finish(id, status: .cancelled, resultText: report.resultText.isEmpty ? nil : report.resultText, toolAttempts: report.toolAttempts) }
        case .failed(let error):
            if case .unavailable(.openCode, OpenCodeModelRegistry.removedErrorText) = error, let m = resolved.model { supervisor.openCode.markModelGone(m) }
            supervisor.recordFailure(engine, subject: resolved.model, error: error)
            if let id = resolved.runID {
                // An already-escalated run keeps its `.escalated` status.
                let status: AgentRunStatus = audit.record(id)?.status == .escalated ? .escalated : .failed
                audit.finish(id, status: status, resultText: report.resultText.isEmpty ? nil : report.resultText, error: error, toolAttempts: report.toolAttempts)
            }
        }
    }

    // MARK: Sessions (Claude/Codex via ProviderManager; OpenCode here; Local is stateless)

    func sessionID(for id: ProviderID?) -> String? {
        guard let id else { return nil }
        return id == .openCode ? openCodeSession : providers.sessionID(for: id)
    }

    func recordSession(_ session: String, for id: ProviderID?) {
        guard let id else { return }
        if id == .openCode { openCodeSession = session } else { providers.recordSession(session, for: id) }
    }

    func providerStarted(_ id: ProviderID?) {
        guard let id else { return }
        activeEngine = id
        if ProviderID.subscription.contains(id) { providers.providerStarted(id); openCodeSession = nil }
        else { providers.resetSessions(); if id != .openCode { openCodeSession = nil } }      // A→B→A would resume without B's exchanges
    }

    func providerFinished(_ id: ProviderID?, outcome: ProviderOutcome) {
        defer { activeEngine = nil }
        guard let id else { return }
        if ProviderID.subscription.contains(id) { providers.providerFinished(id, outcome: outcome) }
        else if case .failed = outcome, id == .openCode { openCodeSession = nil }
    }

    func resetSessions() { providers.resetSessions(); openCodeSession = nil }

    private func summary() -> String {
        ProviderID.allCases.map { "\($0.displayName): \((supervisor.availability()[$0]?.state.label ?? "?").lowercased())." }.joined(separator: " ")
    }
}
