import Foundation

// MARK: - The gates every learning candidate passes (DEC-216) — pure functions: the same input gives the same verdict

enum AdmissionRefusal: String, Equatable, Sendable, CustomStringConvertible {
    case disabled, secret, authorityGrant, injection, trivial, noEvidence, unresolvableEvidence, invalidRule, overgeneralization, duplicate, coolingDown, levelTooLow, emptyScope
    var description: String {
        switch self {
        case .disabled: "adaptive learning is switched off"
        case .secret: "it contains something shaped like a credential"
        case .authorityGrant: "it tries to hand out authority (approval, capability, install, delete, send, purchase, sandbox or security changes) — learning is never authority"
        case .injection: "it contains instruction-shaped text aimed at an AI assistant"
        case .trivial: "it is too trivial to keep"
        case .noEvidence: "it has no evidence"
        case .unresolvableEvidence: "its evidence does not point at anything that exists"
        case .invalidRule: "the rule is outside the closed rule vocabulary"
        case .overgeneralization: "the evidence is too thin or too one-sided for so broad a conclusion"
        case .duplicate: "the same candidate already exists"
        case .coolingDown: "the user rejected it recently and the evidence has not materially changed"
        case .levelTooLow: "the self-improvement level does not allow this"
        case .emptyScope: "it has no scope"
        }
    }
}

enum LearningGate {
    // MARK: Authority and safety text

    private static let extraAuthorityPatterns: [NSRegularExpression] = [
        "\\bvoice\\s+(approval|consent|confirmation)\\s+(is|are)\\s+(enough|sufficient|fine|ok)", "\\b(spoken|voice)\\s+(yes|approval|confirmation)\\b[^.]{0,40}\\b(approve|authori[sz]e|confirm|delete|install)",
        "\\b(yes|evet|ok|okay|tamam)\\b[^.]{0,20}\\b(counts?\\s+as|is|means|equals)\\b[^.]{0,20}\\b(approval|approve|consent)",
        "\\b(user|owner|he|she)\\s+always\\s+(approves?|accepts?|allows?|says\\s+yes)",
        "\\balways\\s+(approves?|accepts?|allows?)\\s+(deletes?|deletions?|installs?|downloads?|purchases?|pushes?|commits?)",
        "\\b(install|download|register|enable)\\b[^.]{0,30}\\b(automatically|by\\s+itself|on\\s+its\\s+own|without\\s+asking)",
        "\\b(auto-?)(install|approve|delete|update)\\b[^.]{0,30}\\b(mcp|server|plugin|capabilit\\w+)",
        "\\b(weaken|relax|loosen|lower|remove|drop|turn\\s+off|disable|ignore)\\b[^.]{0,30}\\b(sandbox|isolation|quarantine|approval|safety|security|guard|policy|policies|permission|envelope)",
        "\\bgrant\\w*\\b[^.]{0,30}\\b(capabilit\\w+|permission|access|authority)", "\\bhas\\s+(full|unrestricted)\\s+(access|authority|trust)",
        "\\bmay\\s+(modify|edit|change|rewrite)\\s+(its|jarvis(?:'s)?)\\s+own\\s+(source|code)\\b[^.]{0,30}\\bwithout",
        "ses(?:li)?\\s+onay\\w*\\s+(yeterli|geçerli|gecerli)", "(her\\s*zaman|otomatik)\\s+(sil|kur|yükle|yukle)\\w*"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func grantsAuthority(_ text: String) -> Bool {
        if MemoryGate.grantsAuthority(text) { return true }
        let r = NSRange(text.startIndex..., in: text)
        return extraAuthorityPatterns.contains { $0.firstMatch(in: text, range: r) != nil }
    }

    /// The first gate that refuses this free text (nil = acceptable). Every text field of a candidate passes here.
    static func refuseText(_ text: String) -> AdmissionRefusal? {
        if MemoryGate.containsSecret(text) || text.contains(OutputSanitizer.mask) { return .secret }
        if grantsAuthority(text) { return .authorityGrant }
        if MemoryGate.looksInjected(text) { return .injection }
        return nil
    }

    // MARK: Rule vocabulary

    static let experimentKinds = Set(ExperimentKind.allCases.map(\.rawValue))
    static let validationHints: Set<String> = ["rerunTests", "readBack", "compile", "captureCheck"]
    static let capabilityRungs: Set<String> = ["typed", "structured", "cli", "browserDOM", "accessibility", "vision", "typedWrapper"]
    private static let token = try! NSRegularExpression(pattern: "^[A-Za-z0-9_.:\\- ]{1,60}$")
    private static let host = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9.\\-]{2,79}$")
    static func isToken(_ s: String) -> Bool { token.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
    static func isHost(_ s: String) -> Bool { host.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    /// Problems with a rule definition (empty = it uses only the closed vocabulary with valid arguments).
    static func problems(in rule: RuleDefinition) -> [String] {
        var out: [String] = []
        if rule.when.isEmpty { out.append("a rule needs at least one condition") }
        if rule.when.count > 4 { out.append("at most 4 conditions") }
        if rule.then.isEmpty { out.append("a rule needs at least one action") }
        if rule.then.count > 3 { out.append("at most 3 actions") }
        for c in rule.when {
            switch c.comparison {
            case .isUnknown: if c.value != nil { out.append("“is unknown” takes no value") }
            case .equals, .notEquals: if let v = c.value, isToken(v) {} else { out.append("condition value for \(c.fact.rawValue) is not a short token") }
            }
        }
        for a in rule.then {
            switch a.kind {
            case .requireExperiment: if !(a.argument.map(experimentKinds.contains) ?? false) { out.append("requireExperiment needs one of \(experimentKinds.sorted().joined(separator: "/"))") }
            case .requireExtraValidation: if !(a.argument.map(validationHints.contains) ?? false) { out.append("requireExtraValidation needs one of \(validationHints.sorted().joined(separator: "/"))") }
            case .requireIndependentReview: if a.argument != nil { out.append("requireIndependentReview takes no argument") }
            case .preferWorkflow: if !(a.argument.map(isToken) ?? false) { out.append("preferWorkflow needs a skill name") }
            case .avoidSource: if !(a.argument.map(isHost) ?? false) { out.append("avoidSource needs one host name") }
            case .addWarning:
                if let t = a.argument, !t.isEmpty, t.count <= 160 { if let why = refuseText(t) { out.append("warning text refused: \(why)") } } else { out.append("addWarning needs a short text (≤ 160 characters)") }
            case .preferCapability: if !(a.argument.map(capabilityRungs.contains) ?? false) { out.append("preferCapability needs one of \(capabilityRungs.sorted().joined(separator: "/"))") }
            }
        }
        return out
    }

    // MARK: Overgeneralisation

    /// A conclusion that BLOCKS or AVOIDS something needs more, and more one-sided, evidence the broader it is. One failed asset never becomes “never use glTF”.
    static let narrowBlockMinimum = 3, broadBlockMinimum = 6
    static let maxCounterRatio = 0.25

    /// Is the rule's condition broad (a single generic fact: a whole format, a whole application, a whole project kind)?
    static func isBroad(_ rule: RuleDefinition) -> Bool {
        let specific = Set(rule.when.filter { $0.comparison != .isUnknown }.map(\.fact))
        let broadAlone: Set<RuleFactKey> = [.assetFormat, .projectKind, .application, .taskKind, .agentRole, .stepType]
        return rule.when.count == 1 && broadAlone.contains(rule.when[0].fact) && specific.count == 1
    }

    static func blocks(_ rule: RuleDefinition) -> Bool { rule.then.contains { $0.kind == .avoidSource } }

    /// nil = fine. `distinctEvidence` = independent sources; `counterEvidence` = same-key events with the opposite outcome.
    static func overgeneralization(rule: RuleDefinition?, kind: LearningKind, distinctEvidence: Int, counterEvidence: Int) -> String? {
        guard let rule, blocks(rule) else { return nil }
        let need = isBroad(rule) ? broadBlockMinimum : narrowBlockMinimum
        if distinctEvidence < need { return "needs at least \(need) independent events for a \(isBroad(rule) ? "broad" : "narrow") avoid-rule, has \(distinctEvidence)" }
        let total = distinctEvidence + counterEvidence
        if total > 0, Double(counterEvidence) / Double(total) > maxCounterRatio { return "\(counterEvidence) of \(total) comparable events went fine — too mixed to avoid" }
        return nil
    }

    // MARK: Fingerprints

    /// The dedupe key of a candidate: kind + scope + the normalised situation. Two candidates with the same fingerprint are the same candidate.
    static func fingerprint(kind: LearningKind, scope: LearningScope, situation: String) -> String {
        let folded = MemoryText.fold(situation).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
        return "\(kind.rawValue)|\(scope.level.rawValue):\(scope.key ?? "*")|\(folded.prefix(120))"
    }

    // MARK: Confidence

    /// Evidence accumulates: n independent events give n / (n + 2) (a pair of events is not yet a pattern), decayed with a 30-day half-life of the NEWEST event,
    /// and reduced by contradicting events. Model confidence is never an input.
    static func confidence(distinctEvidence n: Int, counter: Int, newest: Date, now: Date = Date()) -> Double {
        guard n > 0 else { return 0 }
        let base = Double(n) / Double(n + 2)
        let ageDays = max(0, now.timeIntervalSince(newest) / 86_400)
        let decay = pow(0.5, ageDays / 30)
        let contradiction = counter == 0 ? 1 : max(0.1, 1 - Double(counter) / Double(n + counter))
        return max(0, min(0.99, base * decay * contradiction))
    }
}
