import Foundation

// MARK: - Bounded pattern detection (V0.14, DEC-218)
//
// Thresholds and why (documented, not magic):
//  • 3 independent events — two events can be coincidence or one bad afternoon; three independent occurrences is the smallest count at which "it happens again" is a pattern.
//  • independence = distinct EPISODES (a task, a computer session, an experiment): everything inside one task — a retry loop, five failing steps — is ONE event for learning purposes.
//  • counter-evidence — a same-key success/failure pair is compared: a conclusion is only drawn when the opposite outcome is not common.
//  • a user correction is strong evidence, but only DURABLE when it says so ("always", "from now on", "never again") or repeats — otherwise it stays OBSERVED.
//  • blocking conclusions (avoid-rules) need more (LearningGate.narrowBlockMinimum / broadBlockMinimum) — an avoid is costlier than a warning.
// Evidence accumulates: re-running detection merges new independent events into the same candidate (fingerprint).

enum LearningThresholds {
    static let minimumEvents = 3
    static let workflowMinimumSuccesses = 3
    static let gapMinimumSessions = 3
    static let routingMinimumRuns = 4
    static let windowDays = 90
}

struct CandidateDraft: Equatable, Sendable {
    var kind: LearningKind
    var scope: LearningScope
    var projectKey: String?
    var situation: String
    var title: String
    var summary: String
    var evidence: [LearningEvidenceRef]
    var counterEvidence: Int
    var risk: RiskClass
    var proposedEffect: String
    var validationRequirement: String
    var promotionRequirement: String
    var payload: LearningPayload
    /// An explicit, durable user statement is already a candidate with one event.
    var durableUserStatement = false
    var newest: Date { evidence.map(\.at).max() ?? Date() }
}

enum PatternDetector {
    struct Group { var kind: SignalKind; var key: String; var project: String?; var failures: [LearningSignal]; var successes: [LearningSignal]; var events: [LearningSignal] }

    /// Independent = distinct episodes (the first signal of each episode represents it).
    static func independent(_ signals: [LearningSignal]) -> [LearningSignal] {
        var seen = Set<String>(), out: [LearningSignal] = []
        for s in signals.sorted(by: { $0.at < $1.at }) where seen.insert(s.episode).inserted { out.append(s) }
        return out
    }

    static func groups(_ signals: [LearningSignal]) -> [Group] {
        var map: [String: Group] = [:]
        for s in signals {
            let k = "\(s.kind.rawValue)|\(s.key)|\(s.projectKey ?? "*")"
            var g = map[k] ?? Group(kind: s.kind, key: s.key, project: s.projectKey, failures: [], successes: [], events: [])
            switch s.outcome { case .failure: g.failures.append(s); case .success: g.successes.append(s); case .event: g.events.append(s) }
            map[k] = g
        }
        return Array(map.values)
    }

    static func ref(_ s: LearningSignal) -> LearningEvidenceRef { LearningEvidenceRef(kind: s.sourceKind, sourceID: s.sourceID, at: s.at, note: String(s.detail.prefix(120))) }

    static func drafts(from signals: [LearningSignal]) -> [CandidateDraft] {
        let all = groups(signals)
        var out: [CandidateDraft] = []
        let scopeFor: (String?) -> LearningScope = { $0.map(LearningScope.project) ?? .global }

        // Counter-evidence lookup for sibling kinds sharing a key.
        func counter(_ kind: SignalKind, _ key: String, _ project: String?) -> [LearningSignal] {
            all.filter { $0.kind == kind && $0.key == key && $0.project == project }.flatMap { $0.successes + $0.failures }
        }

        for g in all {
            let fails = independent(g.failures)
            switch g.kind {
            // Repeated failures → a lesson (informational, never applied).
            case .taskFailed, .stepFailed, .experimentRefuted, .resourcePressure, .unityCorrection, .capabilityUnavailable, .mcpFailed:
                guard fails.count >= LearningThresholds.minimumEvents else { continue }
                let successes = g.kind == .mcpFailed ? counter(.mcpSucceeded, g.key, g.project).filter { $0.outcome == .success }.count : 0
                out.append(CandidateDraft(kind: .lesson, scope: scopeFor(g.project), projectKey: g.project, situation: "\(g.kind.rawValue) \(g.key)",
                                          title: lessonTitle(g), summary: "The same situation (\(readable(g.key))) ended badly \(fails.count) times, in separate tasks.",
                                          evidence: fails.map(ref), counterEvidence: successes, risk: .low, proposedEffect: "Shown to you and to the planner as a lesson. It changes no behaviour.",
                                          validationRequirement: "None (informational).", promotionRequirement: "Shown as a lesson once the evidence is solid; never applied.", payload: .lesson(lessonText(g, fails.count))))

            // Repeated incompatible assets from one source+format → a rule: test before recommending.
            case .assetIncompatible:
                guard fails.count >= LearningThresholds.minimumEvents else { continue }
                let parts = g.key.split(separator: "|").map(String.init)
                guard parts.count == 2, LearningGate.isHost(parts[0]) || parts[0] == "unknown" else { continue }
                let ok = independent(counter(.assetCompatible, g.key, g.project)).count
                var conditions = [RuleCondition(fact: .assetSource, comparison: .equals, value: parts[0])]
                if parts[1] != "unknown", LearningGate.isToken(parts[1]) { conditions.append(RuleCondition(fact: .assetFormat, comparison: .equals, value: parts[1])) }
                guard parts[0] != "unknown" else { continue }
                let rule = RuleDefinition(when: conditions, then: [RuleAction(kind: .requireExperiment, argument: ExperimentKind.assetImport.rawValue),
                                                                  RuleAction(kind: .addWarning, argument: "Earlier assets of this kind from \(parts[0]) were incompatible; test it first.")])
                out.append(CandidateDraft(kind: .rule, scope: scopeFor(g.project), projectKey: g.project, situation: "asset \(g.key)",
                                          title: "Test \(parts[1] == "unknown" ? "" : parts[1] + " ")assets from \(parts[0]) before recommending them",
                                          summary: "\(fails.count) assets from \(parts[0]) (\(parts[1])) were found incompatible; \(ok) of the same kind were fine.", evidence: fails.map(ref), counterEvidence: ok,
                                          risk: .low, proposedEffect: "Before JARVIS recommends such an asset it must run the disposable asset test. It never blocks the asset.",
                                          validationRequirement: "Rule passes the closed-vocabulary check and the fixture test.", promotionRequirement: "Approval in the Learning screen (or auto-promotion if you enabled it for low-risk rules).",
                                          payload: .rule(rule)))

            // Repeated vision/coordinate fallback for one application → a capability gap (and a routing rule candidate).
            case .computerVisionFallback:
                let sessions = independent(g.failures + g.events)
                guard sessions.count >= LearningThresholds.gapMinimumSessions else { continue }
                let app = g.key.replacingOccurrences(of: "app=", with: "")
                let axOK = independent(counter(.computerAccessibilitySuccess, g.key, g.project)).count
                let detail = CapabilityGapDetail(domain: app, observation: "Accessibility was not enough in \(sessions.count) sessions; window vision was used instead.",
                                                 currentMechanism: "window-scoped vision / Accessibility", occurrences: sessions.count,
                                                 options: [GapOption(architecture: "approved MCP or typed wrapper", rationale: "A structured interface would avoid the GUI altogether if a trustworthy one exists.", rank: 1),
                                                           GapOption(architecture: "controlled CLI", rationale: "If the application has a scripting CLI, a typed, bounded wrapper could replace clicking.", rank: 2),
                                                           GapOption(architecture: "native JARVIS adapter", rationale: "An application adapter under the V0.11 ladder, if the application is used often.", rank: 3),
                                                           GapOption(architecture: "learned Skill", rationale: "If the GUI sequence repeats, a validated workflow could encode it.", rank: 4)])
                out.append(CandidateDraft(kind: .capabilityGap, scope: scopeFor(g.project), projectKey: g.project, situation: "gui-fallback \(g.key)",
                                          title: "No structured control for \(app) — the GUI is used repeatedly", summary: detail.observation, evidence: sessions.map(ref), counterEvidence: axOK, risk: .low,
                                          proposedEffect: "May start a bounded search for structured integrations (never an installation).", validationRequirement: "None (a gap is evidence, not permission).",
                                          promotionRequirement: "Discovery runs only on your request.", payload: LearningPayload(gap: detail)))
                if axOK == 0, sessions.count >= LearningThresholds.gapMinimumSessions, LearningGate.isToken(app) {
                    let rule = RuleDefinition(when: [RuleCondition(fact: .application, comparison: .equals, value: app)], then: [RuleAction(kind: .preferCapability, argument: "vision")])
                    out.append(CandidateDraft(kind: .rule, scope: scopeFor(g.project), projectKey: g.project, situation: "rung \(g.key)", title: "Go straight to window vision for \(app)",
                                              summary: "Accessibility never sufficed for \(app) in \(sessions.count) sessions.", evidence: sessions.map(ref), counterEvidence: 0, risk: .low,
                                              proposedEffect: "Skips a wasted Accessibility attempt. Every V0.11 validation still applies.", validationRequirement: "Closed-vocabulary check.",
                                              promotionRequirement: "Approval in the Learning screen.", payload: .rule(rule)))
                }

            // Successful, repeated graph shapes → a workflow candidate.
            case .workflowSucceeded:
                let wins = independent(g.successes)
                guard wins.count >= LearningThresholds.workflowMinimumSuccesses else { continue }
                guard let template = wins.compactMap({ SignalExtractor.decodeTemplate($0.detail) }).first, template.signature == g.key else { continue }
                let lost = independent(g.failures).count
                out.append(CandidateDraft(kind: .workflow, scope: scopeFor(g.project), projectKey: g.project, situation: "workflow \(g.key)", title: "Reusable workflow: \(workflowName(template))",
                                          summary: "The same graph shape (\(template.signature.replacingOccurrences(of: ">", with: " → "))) completed \(wins.count) times; \(lost) comparable run(s) failed.",
                                          evidence: wins.map(ref), counterEvidence: lost, risk: .low, proposedEffect: "Becomes a Skill: a validated graph template the planner may prefer for matching goals. It still runs through the normal engine and approvals.",
                                          validationRequirement: "Graph validation + a disposable-fixture run.", promotionRequirement: "Approval, or auto-promotion for low-risk workflows when you enabled it.",
                                          payload: LearningPayload(workflow: template)))

            // Tasks of one kind repeatedly far slower than their own median → an improvement proposal for JARVIS itself (written, never applied by itself).
            case .slowPath:
                let slow = independent(g.events)
                guard slow.count >= LearningThresholds.minimumEvents else { continue }
                let draft = ImprovementDraft(problem: "Completed \(g.key) tasks repeatedly take far longer than the usual \(g.key) task (\(slow.count) of them above 3× the median).",
                                             evidenceSummary: "\(slow.count) separate tasks; each is recorded with its duration.", proposedChange: "Measure where the time goes in \(g.key) tasks (step durations are already recorded) and remove the largest avoidable wait.",
                                             expectedBenefit: "Shorter \(g.key) tasks.", risk: "Low: measurement first; any code change is an ordinary task that still needs approval.", validationPlan: "Compare step durations on the same fixture before and after; run scripts/verify.sh.",
                                             rollback: "git revert the commit that introduced the change.", affectedArea: "Tasks / orchestration")
                out.append(CandidateDraft(kind: .sourceCodeImprovement, scope: .global, projectKey: nil, situation: "slow \(g.key)", title: "Speed up \(g.key) tasks", summary: draft.problem, evidence: slow.map(ref), counterEvidence: 0, risk: .medium,
                                          proposedEffect: "A written proposal. JARVIS does not change its own source unless you raise the level to 4 AND approve this exact change.", validationRequirement: "Benchmark before/after on a fixture.",
                                          promotionRequirement: "Level 3 to write the proposal; level 4 and your approval to apply it.", payload: LearningPayload(improvement: draft)))

            // Repeated rejection of one suggestion kind → a lesson about the user's taste (informational).
            case .proposalRejected:
                let rej = independent(g.events)
                guard rej.count >= LearningThresholds.minimumEvents else { continue }
                out.append(CandidateDraft(kind: .lesson, scope: .global, projectKey: nil, situation: "declined \(g.key)", title: "You usually decline “\(readable(g.key))” suggestions",
                                          summary: "\(rej.count) suggestions of this kind were declined.", evidence: rej.map(ref), counterEvidence: 0, risk: .low, proposedEffect: "Shown only; suggestions already have a cooldown.",
                                          validationRequirement: "None.", promotionRequirement: "None.", payload: .lesson("Suggestions like “\(readable(g.key))” were declined \(rej.count) times.")))

            default: break
            }
        }

        // Provider evidence per (engine, role): a bounded routing nudge, never a replacement for policy.
        let providerKeys = Set(all.filter { $0.kind == .providerFailed || $0.kind == .providerSucceeded }.map { "\($0.key)|\($0.project ?? "*")" })
        for k in providerKeys {
            let parts = k.split(separator: "|").map(String.init); guard parts.count >= 2 else { continue }
            let key = "\(parts[0])|\(parts[1])"
            let failed = independent(all.filter { $0.kind == .providerFailed && $0.key == key }.flatMap(\.failures))
            let ok = independent(all.filter { $0.kind == .providerSucceeded && $0.key == key }.flatMap(\.successes))
            let total = failed.count + ok.count
            guard total >= LearningThresholds.routingMinimumRuns, failed.count >= 2 else { continue }
            let rate = Double(failed.count) / Double(total)
            guard rate >= 0.5 else { continue }
            let adj = RoutingAdjustment(role: parts[1], provider: parts[0], delta: -min(RoutingAdjustment.limit, rate * 0.3))
            if out.contains(where: { $0.situation == "routing \(key)" }) { continue }
            out.append(CandidateDraft(kind: .routingAdjustment, scope: .global, projectKey: nil, situation: "routing \(key)", title: "\(parts[0]) is unreliable for \(parts[1]) work",
                                      summary: "\(failed.count) of \(total) recent \(parts[1]) runs on \(parts[0]) failed.", evidence: (failed + ok).map(ref), counterEvidence: ok.count, risk: .medium,
                                      proposedEffect: "A small preference nudge (\(String(format: "%.2f", adj.clamped))) in routing. Price, privacy, local-only and your explicit provider choice always win.",
                                      validationRequirement: "Bounded to ±\(RoutingAdjustment.limit).", promotionRequirement: "Approval in the Learning screen.", payload: LearningPayload(routing: adj)))
        }
        return out
    }

    // MARK: Wording

    static func readable(_ key: String) -> String { key.replacingOccurrences(of: "|", with: " · ").replacingOccurrences(of: "-", with: " ") }
    static func lessonTitle(_ g: Group) -> String {
        switch g.kind {
        case .taskFailed: "Tasks keep failing the same way: \(readable(g.key))"
        case .stepFailed: "Steps keep failing: \(readable(g.key))"
        case .experimentRefuted: "Experiments keep being refuted: \(readable(g.key))"
        case .resourcePressure: "\(g.key.capitalized) tasks run out of resources"
        case .unityCorrection: "Unity work keeps needing correction: \(readable(g.key))"
        case .capabilityUnavailable: "A needed capability is repeatedly unavailable: \(readable(g.key))"
        case .mcpFailed: "An integration keeps failing: \(readable(g.key))"
        default: readable(g.key)
        }
    }
    static func lessonText(_ g: Group, _ n: Int) -> String { "\(lessonTitle(g)) (seen \(n) times in separate tasks)." }
    static func workflowName(_ t: WorkflowTemplate) -> String {
        let types = t.nodes.map(\.type.rawValue)
        return types.prefix(4).joined(separator: " → ") + (types.count > 4 ? " → …" : "")
    }
}
