import Foundation

// MARK: - Rule evaluation (pure, DEC-217)
//
// A rule is DATA. Evaluating it can only ADD a requirement (an experiment, an extra check, a review, a warning, a preference). It cannot approve anything, grant a
// capability, remove a check or weaken a policy — the consumers apply effects as "at least this much", on top of current truth and the security policy.

struct RuleContext: Equatable, Sendable {
    var facts: [RuleFactKey: String] = [:]
    var projectKey: String?
    var capability: String?
    var workflow: String?
    init(_ facts: [RuleFactKey: String] = [:], projectKey: String? = nil, capability: String? = nil, workflow: String? = nil) {
        self.facts = facts; self.projectKey = projectKey; self.capability = capability; self.workflow = workflow
    }
}

enum RuleEngine {
    static func matches(_ rule: RuleDefinition, _ context: RuleContext) -> Bool {
        rule.when.allSatisfy { c in
            let actual = context.facts[c.fact].map { $0.lowercased() }
            switch c.comparison {
            case .equals: return actual != nil && actual == c.value?.lowercased()
            case .notEquals: return actual != nil && actual != c.value?.lowercased()
            case .isUnknown: return actual == nil || actual == "unknown"
            }
        }
    }

    /// Active rules that apply to this situation, narrowest scope first (a project rule outranks a global one for the same project).
    static func applicable(_ rules: [LearnedRule], _ context: RuleContext) -> [LearnedRule] {
        rules.filter { $0.status == .active && $0.scope.applies(project: context.projectKey, capability: context.capability, workflow: context.workflow) && matches($0.definition, context) }
            .sorted { ($0.scope.level.specificity, $0.version) > ($1.scope.level.specificity, $1.version) }
    }

    static func evaluate(_ rules: [LearnedRule], _ context: RuleContext) -> RuleEffects {
        var e = RuleEffects()
        func add(_ list: inout [String], _ s: String?) { if let s, !list.contains(s) { list.append(s) } }
        for rule in applicable(rules, context) {
            e.firedRuleIDs.append(rule.id)
            for a in rule.definition.then {
                switch a.kind {
                case .requireExperiment: add(&e.requiredExperiments, a.argument)
                case .requireExtraValidation: add(&e.extraValidations, a.argument)
                case .requireIndependentReview: e.independentReviewRequired = true
                case .preferWorkflow: add(&e.preferredWorkflows, a.argument)       // narrowest scope first: the first preference wins the ordering
                case .avoidSource: add(&e.avoidedSources, a.argument)
                case .addWarning: add(&e.warnings, a.argument.map { OutputSanitizer.sanitize($0) })
                case .preferCapability: add(&e.preferredCapabilities, a.argument)
                }
            }
        }
        return e
    }

    /// A short, human line for a rule (UI and answers; never executed).
    static func describe(_ rule: RuleDefinition) -> String {
        let when = rule.when.map { c -> String in
            switch c.comparison { case .equals: "\(c.fact.rawValue) = \(c.value ?? "?")"; case .notEquals: "\(c.fact.rawValue) ≠ \(c.value ?? "?")"; case .isUnknown: "\(c.fact.rawValue) is unknown" }
        }.joined(separator: " and ")
        let then = rule.then.map { a -> String in
            switch a.kind {
            case .requireExperiment: "run a \(a.argument ?? "?") experiment first"
            case .requireExtraValidation: "add the check “\(a.argument ?? "?")”"
            case .requireIndependentReview: "require an independent review"
            case .preferWorkflow: "prefer the “\(a.argument ?? "?")” workflow"
            case .avoidSource: "avoid \(a.argument ?? "?")"
            case .addWarning: "warn: \(a.argument ?? "")"
            case .preferCapability: "prefer \(a.argument ?? "?")"
            }
        }.joined(separator: ", ")
        return "When \(when) → \(then)"
    }
}
