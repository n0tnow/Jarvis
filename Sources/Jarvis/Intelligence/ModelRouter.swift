import Foundation

/// Policy-first, deterministic model/engine selection (DEC-024). Pure: same snapshot + profile → same decision.
/// The LLM never chooses its own provider. Every decision carries a machine-readable reason that is persisted.
///
/// Auto tiers
///   lightweight (LocalModelPolicy passes)  → Local → OpenCode free → Claude Code → Codex
///   development / moderate knowledge work  → OpenCode free (verified + benchmarked) → Claude Code → Codex
///   heavy (complex/critical/architecture/security, or sensitive-only paths) → Claude Code → Codex
/// Explicit modes (Local / OpenCode Free / Claude Code / Codex) NEVER fall back to another engine.
enum ModelRouter {
    static func route(_ profile: TaskProfile, snapshot s: RouterSnapshot) -> RoutingDecision {
        var d = RoutingDecision(outcome: .refused(.noCandidate("")), profile: profile, mode: s.preference)
        d.reasons["category"] = profile.category.rawValue
        d.reasons["complexity"] = "\(profile.complexity)"
        d.reasons["privacy"] = profile.privacy.rawValue
        d.reasons["coding"] = String(profile.requiresCoding || profile.category == .coding)
        d.reasons["testing"] = String(profile.requiresTesting)
        d.reasons["repositoryModification"] = String(profile.requiresRepositoryModification)
        d.reasons["projectCode"] = String(profile.containsProjectCode)

        let verdict = LocalModelPolicy.evaluate(profile)
        d.reasons["localModelIneligible"] = String(!verdict.eligible)
        if !verdict.eligible { d.reasons["localViolations"] = verdict.violations.joined(separator: ",") }

        switch s.preference {
        case .local: return explicitLocal(&d, verdict, s)
        case .openCodeFree: return explicitFree(&d, s)
        case .claudeCode: return explicitPremium(&d, .claudeCode, s)
        case .codex: return explicitPremium(&d, .codex, s)
        case .auto: return auto(&d, verdict, s)
        }
    }

    /// Whether a free-cloud route could be chosen for this request — i.e. whether re-reading OpenCode's prices is worth it.
    /// Reading prices may start OpenCode's own background service (≈290 MB), so JARVIS does it lazily: never at launch, never
    /// for lightweight tasks (Local first) or heavy/sensitive ones (premium only).
    static func mayUseFreeCloud(_ p: TaskProfile, preference: ProviderPreference, settings: RoutingSettings) -> Bool {
        guard settings.allowFreeCloud else { return false }
        if p.privacy == .sensitive && !settings.allowSensitiveOnFreeCloud { return false }
        switch preference {
        case .openCodeFree: return true
        case .auto:
            let heavy = p.complexity >= .complex || p.category == .architecture || p.category == .security
            return !heavy && !LocalModelPolicy.evaluate(p).eligible
        default: return false
        }
    }

    // MARK: Explicit modes (no silent fallback)

    private static func explicitLocal(_ d: inout RoutingDecision, _ v: LocalModelPolicy.Verdict, _ s: RouterSnapshot) -> RoutingDecision {
        d.reasons["tier"] = "explicit"
        guard v.eligible else { d.outcome = .refused(.localForbiddenForTask(v.violations)); return d }
        if let why = localBlock(s) { d.outcome = .refused(.engineUnavailable(.local, why)); d.rejected["local"] = why; return d }
        d.outcome = .selected(RoutingCandidate(engine: .local, model: nil))
        d.reasons["selected"] = "local"; d.reasons["providerReady"] = "true"
        return d
    }

    private static func explicitPremium(_ d: inout RoutingDecision, _ e: ProviderID, _ s: RouterSnapshot) -> RoutingDecision {
        d.reasons["tier"] = "explicit"
        if let why = premiumBlock(e, s) { d.outcome = .refused(.engineUnavailable(e, why)); d.rejected[e.rawValue] = why; return d }
        d.outcome = .selected(RoutingCandidate(engine: e, model: nil))
        d.reasons["selected"] = e.rawValue; d.reasons["providerReady"] = "true"
        return d
    }

    private static func explicitFree(_ d: inout RoutingDecision, _ s: RouterSnapshot) -> RoutingDecision {
        d.reasons["tier"] = "explicit"
        if d.profile.privacy == .sensitive && !s.settings.allowSensitiveOnFreeCloud {
            d.outcome = .refused(.sensitiveBlockedFromFreeCloud); d.rejected["openCode"] = "privacy:sensitive"; return d
        }
        let (models, rejected) = freeCandidates(d.profile, s, requireBenchmark: false)
        d.rejected.merge(rejected) { $1 }
        guard let best = models.first else {
            d.outcome = .refused(.noEligibleFreeModel(rejected.values.sorted().first ?? "none discovered")); return d
        }
        select(&d, best, s)
        return d
    }

    // MARK: Auto

    private static func auto(_ d: inout RoutingDecision, _ v: LocalModelPolicy.Verdict, _ s: RouterSnapshot) -> RoutingDecision {
        let p = d.profile
        let heavy = p.complexity >= .complex || p.category == .architecture || p.category == .security
        var chain: [RoutingCandidate] = []
        var freeInfo: [String: (ModelRecord, BenchmarkSummary?)] = [:]

        func addLocal() {
            if !v.eligible { d.rejected["local"] = "policy:" + v.violations.joined(separator: ",") }
            else if let why = localBlock(s) { d.rejected["local"] = why }
            else { chain.append(RoutingCandidate(engine: .local, model: nil)) }
        }
        func addFree() {
            if p.privacy == .sensitive && !s.settings.allowSensitiveOnFreeCloud { d.rejected["openCode"] = "privacy:sensitive"; return }
            let (models, rejected) = freeCandidates(p, s, requireBenchmark: s.settings.requireBenchmarkForAuto)
            for (k, r) in rejected where d.rejected.count < 8 { d.rejected[k] = r }
            for m in models { chain.append(RoutingCandidate(engine: .openCode, model: m.0.id)); freeInfo[m.0.id] = m }
        }
        func addPremium() {
            // Equal-footing engines are ordered by the (bounded) learned nudge; the stable sort keeps the default order when there is none.
            let ordered = ProviderID.subscription.enumerated().sorted { (s.bias($0.element.rawValue), -$0.offset) > (s.bias($1.element.rawValue), -$1.offset) }.map(\.element)
            for e in ordered {
                if let why = premiumBlock(e, s) { d.rejected[e.rawValue] = why } else { chain.append(RoutingCandidate(engine: e, model: nil)) }
            }
        }

        if v.eligible {
            d.reasons["tier"] = "lightweight-local-first"; addLocal(); addFree(); addPremium()
        } else if heavy {
            d.reasons["tier"] = "heavy-premium-only"
            d.rejected["openCode"] = "tier:heavy"
            if d.rejected["local"] == nil { d.rejected["local"] = "policy:" + v.violations.joined(separator: ",") }
            addPremium()
        } else {
            d.reasons["tier"] = "development-free-first"; addFree(); addPremium()
            d.rejected["local"] = "policy:" + v.violations.joined(separator: ",")
        }

        guard let first = chain.first else {
            d.outcome = .refused(.noCandidate("no eligible provider")); return d
        }
        d.fallbacks = Array(chain.dropFirst())
        if first.engine == .openCode, let info = freeInfo[first.model ?? ""] { select(&d, info, s) }
        else {
            d.outcome = .selected(first)
            d.reasons["selected"] = first.model ?? first.engine.rawValue
            d.reasons["providerReady"] = "true"
            if first.engine == .local { d.reasons["localEligible"] = "true" }
            if first.engine == .claudeCode || first.engine == .codex {
                // Why a premium (subscription) engine and not a free/local one — recorded for the audit trail.
                if heavy { d.reasons["escalationReason"] = "heavy:" + (p.category == .architecture || p.category == .security ? p.category.rawValue : "complexity") }
                else if let why = d.rejected["openCode"] { d.reasons["escalationReason"] = "noFreeModel:" + why }
                else if p.isDevelopment { d.reasons["escalationReason"] = "noFreeModel" }
            }
        }
        return d
    }

    // MARK: Gates

    private static func localBlock(_ s: RouterSnapshot) -> String? {
        if !s.settings.allowLocal { return "disabled" }
        guard let e = s.engines[.local] else { return "unavailable:notConfigured" }
        if let c = e.cooldownUntil, c > s.now { return "cooldown" }
        if e.state != .ready { return "unavailable:\(e.state.label.lowercased())" }
        if !s.resources.localInferenceAdvisable { return "resource:memory=\(s.resources.memory.rawValue)" }
        if s.resources.localJobsRunning > 0 { return "resource:localJobBusy" }
        return nil
    }

    private static func premiumBlock(_ e: ProviderID, _ s: RouterSnapshot) -> String? {
        guard let a = s.engines[e] else { return "unavailable:unknown" }
        if let c = a.cooldownUntil, c > s.now { return "cooldown" }
        return a.state == .ready ? nil : "unavailable:\(a.state.label.lowercased())"
    }

    /// Eligible free-pool models (best first) + rejection codes for the others.
    private static func freeCandidates(_ p: TaskProfile, _ s: RouterSnapshot, requireBenchmark: Bool) -> ([(ModelRecord, BenchmarkSummary?)], [String: String]) {
        var ok: [(ModelRecord, BenchmarkSummary?)] = []
        var rejected: [String: String] = [:]
        guard s.settings.allowFreeCloud else { return ([], ["openCode": "disabled"]) }
        guard let engine = s.engines[.openCode] else { return ([], ["openCode": "unavailable:notInstalled"]) }
        if let c = engine.cooldownUntil, c > s.now { return ([], ["openCode": "cooldown"]) }
        if engine.state != .ready { return ([], ["openCode": "unavailable:\(engine.state.label.lowercased())"]) }
        let group = p.benchmarkGroup
        for m in s.models where m.engine == .openCode {
            let key = m.id
            if !m.isFreePoolMember { rejected[key] = m.blockedReason ?? (m.enabled ? "not free-verified" : "disabled"); continue }
            if !OpenCodeModelRegistry.isVerificationFresh(m, now: s.now) { rejected[key] = "freeVerification:stale"; continue }
            if let until = s.modelCooldowns[key], until > s.now { rejected[key] = "cooldown"; continue }
            if p.containsProjectCode, s.settings.projectCodeNeedsZeroRetention, m.dataPolicy != .zeroRetention { rejected[key] = "dataPolicy:\(m.dataPolicy.rawValue)"; continue }
            if let limit = m.contextLimit, p.estimatedContextTokens * 2 > limit { rejected[key] = "context"; continue }
            let summary = s.benchmarks[key]?[group]
            if requireBenchmark, !s.settings.benchmark.isEligible(summary, group: group, now: s.now) {
                rejected[key] = "benchmark:\(group.rawValue) \(summary?.label ?? "none")"; continue
            }
            ok.append((m, summary))
        }
        ok.sort { a, b in
            let ra = (a.1?.passRate ?? -1) + s.bias(a.0.id), rb = (b.1?.passRate ?? -1) + s.bias(b.0.id)
            if ra != rb { return ra > rb }
            // Privacy-preserving tie-break: documented zero-retention models first, then everything else.
            let za = a.0.dataPolicy == .zeroRetention, zb = b.0.dataPolicy == .zeroRetention
            if za != zb { return za }
            let la = a.1?.medianLatencyMS ?? .infinity, lb = b.1?.medianLatencyMS ?? .infinity
            if la != lb { return la < lb }
            return a.0.id < b.0.id
        }
        return (ok, rejected)
    }

    private static func select(_ d: inout RoutingDecision, _ pick: (ModelRecord, BenchmarkSummary?), _ s: RouterSnapshot) {
        let (m, summary) = pick
        d.outcome = .selected(RoutingCandidate(engine: .openCode, model: m.id))
        d.reasons["selected"] = m.id
        d.reasons["freeVerified"] = "true"
        if let at = m.freeVerifiedAt { d.reasons["freeVerifiedAt"] = ISO8601DateFormatter().string(from: at) }
        d.reasons["pricing"] = "input=\(m.inputPrice ?? -1),output=\(m.outputPrice ?? -1)"
        d.reasons["dataPolicy"] = m.dataPolicy.rawValue
        d.reasons["providerReady"] = "true"
        let group = d.profile.benchmarkGroup
        d.reasons["benchmark.\(group.rawValue)"] = summary.map { $0.label } ?? "none"
        d.reasons["\(group.rawValue)BenchmarkPassed"] = String(s.settings.benchmark.isEligible(summary, group: group, now: s.now))
    }
}
