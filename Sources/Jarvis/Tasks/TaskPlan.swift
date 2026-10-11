import Foundation

// MARK: - Structured plan (machine-readable; prose is never execution truth)

struct PlanStep: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var description: String
    var type: StepType
    var dependsOn: [String]
    var expected: String
    var validation: ValidationKind
    var risk: RiskClass
    /// Only for `delete` steps: the workspace-relative paths to remove (each goes through the approval gate).
    var targets: [String] = []
}

struct TaskPlan: Codable, Equatable, Sendable {
    var summary: String
    var steps: [PlanStep]
    var version = 1
}

enum PlanIssue: Equatable, Sendable, CustomStringConvertible {
    case notJSON
    case noSteps
    case tooManySteps(Int)
    case missingField(step: String, field: String)
    case duplicateID(String)
    case missingDependency(step: String, dependsOn: String)
    case selfDependency(String)
    case cycle([String])
    case unknownStepType(step: String, type: String)
    case unknownValidation(step: String, validation: String)
    case validationMismatch(step: String, type: StepType, validation: ValidationKind)
    case capabilityNotGranted(step: String, type: StepType)
    case unsafeDestructiveStep(step: String, why: String)
    case prohibitedOperation(step: String, phrase: String)
    case recursiveAgentRequest(step: String)
    case paidProviderRequirement(step: String)
    case localModelForDevelopment(step: String)
    case textTooLong(step: String)

    var description: String {
        switch self {
        case .notJSON: "the answer is not a JSON plan"
        case .noSteps: "the plan has no steps"
        case .tooManySteps(let n): "the plan has \(n) steps (maximum \(PlanValidator.maxSteps))"
        case .missingField(let s, let f): "step \(s): missing \(f)"
        case .duplicateID(let id): "duplicate step id \(id)"
        case .missingDependency(let s, let d): "step \(s) depends on unknown step \(d)"
        case .selfDependency(let s): "step \(s) depends on itself"
        case .cycle(let ids): "dependency cycle: \(ids.joined(separator: " → "))"
        case .unknownStepType(let s, let t): "step \(s): unknown type \"\(t)\" (allowed: \(StepType.allCases.map(\.rawValue).joined(separator: ", ")))"
        case .unknownValidation(let s, let v): "step \(s): unknown validation \"\(v)\""
        case .validationMismatch(let s, let t, let v): "step \(s): validation \(v.rawValue) does not fit type \(t.rawValue)"
        case .capabilityNotGranted(let s, let t): "step \(s): \(t.rawValue) steps are not allowed for this task"
        case .unsafeDestructiveStep(let s, let why): "step \(s): destructive step rejected (\(why))"
        case .prohibitedOperation(let s, let p): "step \(s): prohibited operation (\(p))"
        case .recursiveAgentRequest(let s): "step \(s): agents may not create agents"
        case .paidProviderRequirement(let s): "step \(s): paid providers are never used"
        case .localModelForDevelopment(let s): "step \(s): the local model cannot do development work"
        case .textTooLong(let s): "step \(s): text too long"
        }
    }

    /// The plan can be repaired by re-asking the planner (as opposed to a policy block that no wording fixes).
    var isPolicyBlock: Bool {
        switch self {
        case .prohibitedOperation, .recursiveAgentRequest, .paidProviderRequirement, .localModelForDevelopment, .unsafeDestructiveStep: true
        default: false
        }
    }
}

// MARK: - Parsing

enum PlanParser {
    /// First balanced top-level JSON object in `text` (tolerates ``` fences and prose around it). Strings are respected.
    static func extractJSONObject(_ text: String) -> String? {
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "{" {
                var depth = 0, inString = false, escaped = false
                var j = i
                while j < chars.count {
                    let c = chars[j]
                    if inString {
                        if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                    } else if c == "\"" { inString = true }
                    else if c == "{" { depth += 1 }
                    else if c == "}" { depth -= 1; if depth == 0 { return String(chars[i...j]) } }
                    j += 1
                }
                return nil                                   // unbalanced from this brace on
            }
            i += 1
        }
        return nil
    }

    /// Lenient decode (the model's field names/values are matched, not trusted). Unknown types/validations are reported, never guessed.
    static func parse(_ text: String) -> (plan: TaskPlan?, issues: [PlanIssue], rawKeys: Set<String>) {
        guard let json = extractJSONObject(text), let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, [.notJSON], []) }
        var keys = Set(root.keys)
        guard let rawSteps = root["steps"] as? [[String: Any]] else { return (nil, [.noSteps], keys) }
        var issues: [PlanIssue] = []
        var steps: [PlanStep] = []
        for (i, raw) in rawSteps.enumerated() {
            keys.formUnion(raw.keys)
            let id = (raw["id"] as? String ?? (raw["id"] as? Int).map { "s\($0)" } ?? "s\(i + 1)").trimmingCharacters(in: .whitespaces)
            let title = (raw["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty { issues.append(.missingField(step: id, field: "title")); continue }
            let typeRaw = (raw["type"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard let type = StepType(rawValue: typeRaw) ?? StepType.allCases.first(where: { $0.rawValue.lowercased() == typeRaw.lowercased() }) ?? alias(typeRaw) else {
                issues.append(.unknownStepType(step: id, type: typeRaw)); continue
            }
            let valRaw = raw["validation"] as? String
            guard var validation = ValidationKind.parse(valRaw, for: type) else { issues.append(.unknownValidation(step: id, validation: valRaw ?? "")); continue }
            // Validation is deterministic BY STEP TYPE: a real planner (found by the live test) may label a delete step "structuredResult".
            // A known-but-misplaced label is replaced by the type's own validation instead of discarding an otherwise good plan.
            if !ValidationKind.allowed(for: type).contains(validation) { validation = .default(for: type) }
            let deps = (raw["dependsOn"] as? [Any] ?? raw["depends_on"] as? [Any] ?? []).compactMap { ($0 as? String) ?? ($0 as? Int).map { "s\($0)" } }
            let risk = (raw["risk"] as? String).flatMap { RiskClass(rawValue: $0.lowercased()) } ?? type.defaultRisk
            let targets = (raw["targets"] as? [String] ?? (raw["target"] as? String).map { [$0] } ?? [])
            steps.append(PlanStep(id: id, title: title, description: (raw["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                  type: type, dependsOn: deps, expected: (raw["expected"] as? String ?? raw["expectedOutcome"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                  validation: validation, risk: risk, targets: targets))
        }
        guard issues.isEmpty else { return (nil, issues, keys) }
        return (TaskPlan(summary: (root["summary"] as? String ?? root["goal"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines), steps: steps), [], keys)
    }

    private static func alias(_ raw: String) -> StepType? {
        switch raw.lowercased() {
        case "inspect", "research", "investigate", "reproduce": .analysis
        case "code", "implement", "fix", "edit", "change", "modify": .codeChange
        case "compile": .build
        case "tests", "verify": .test
        case "diffreview", "codereview": .review
        case "remove", "deletion": .delete
        default: nil
        }
    }
}

// MARK: - Validation

/// Runs BEFORE anything is scheduled. A plan that fails any rule is repaired (re-asked) or rejected — never executed.
enum PlanValidator {
    static let maxSteps = 12
    static let maxTitle = 120
    static let maxDescription = 600

    private static let prohibitedPhrases = [
        "git push", "force push", "push --force", "push -f", "reset --hard", "git clean", "clean -fd", "rm -rf", "sudo ", "chmod 777",
        "curl ", "wget ", "npm publish", "deploy to production", "production deploy", "api key", "api_key", "access token", "credential", "password",
        "keychain", "purchase", "buy ", "subscription", "git commit", "rewrite history", "filter-branch", "drop database", "format disk",
    ]
    private static let recursiveKeys: Set<String> = ["subagents", "sub_agents", "spawn", "spawnagents", "children", "agents", "delegate", "delegates", "workers"]
    private static let paidPhrases = ["openai api", "anthropic api", "paid api", "paid model", "paid plan", "gpt-4 api", "billing", "metered"]
    private static let localPhrases = ["local model", "qwen", "local llm", "on-device model"]

    static func validate(_ plan: TaskPlan, kind: TaskKind, capabilities: CapabilitySet, allowDestructive: Bool = true, rawKeys: Set<String> = []) -> [PlanIssue] {
        var issues: [PlanIssue] = []
        if plan.steps.isEmpty { return [.noSteps] }
        if plan.steps.count > maxSteps { issues.append(.tooManySteps(plan.steps.count)) }

        let ids = plan.steps.map(\.id)
        var seen = Set<String>()
        for id in ids where !seen.insert(id).inserted { issues.append(.duplicateID(id)) }
        let known = Set(ids)

        for s in plan.steps {
            if s.title.count > maxTitle || s.description.count > maxDescription { issues.append(.textTooLong(step: s.id)) }
            if s.dependsOn.contains(s.id) { issues.append(.selfDependency(s.id)) }
            for d in s.dependsOn where !known.contains(d) && d != s.id { issues.append(.missingDependency(step: s.id, dependsOn: d)) }
            if !ValidationKind.allowed(for: s.type).contains(s.validation) { issues.append(.validationMismatch(step: s.id, type: s.type, validation: s.validation)) }
            // Capability: the task must grant what the step needs (destructive actions are gated per action by an approval instead).
            let needed = s.type.requiredCapabilities.subtracting([.destructiveFileOperation])
            if !capabilities.allows(all: needed) || (s.type == .delete && kind == .readOnlyAnalysis) { issues.append(.capabilityNotGranted(step: s.id, type: s.type)) }
            if s.type == .delete {
                if !allowDestructive { issues.append(.unsafeDestructiveStep(step: s.id, why: "the goal did not ask for anything to be deleted")) }
                if s.targets.isEmpty || s.targets.count > 5 { issues.append(.unsafeDestructiveStep(step: s.id, why: "needs 1–5 explicit target paths")) }
                for t in s.targets where t.isEmpty || t == "." || t == "/" || t.contains("*") || t.hasPrefix("..") || t.hasPrefix(".git") || t.hasPrefix("/") {
                    issues.append(.unsafeDestructiveStep(step: s.id, why: "target \"\(t)\" is not an explicit workspace-relative path"))
                }
                if s.risk < .high { issues.append(.unsafeDestructiveStep(step: s.id, why: "must be declared high risk")) }
            }
            let text = (s.title + " " + s.description + " " + s.expected).lowercased()
            for p in prohibitedPhrases where text.contains(p) { issues.append(.prohibitedOperation(step: s.id, phrase: p.trimmingCharacters(in: .whitespaces))); break }
            if paidPhrases.contains(where: text.contains) { issues.append(.paidProviderRequirement(step: s.id)) }
            if s.type.usesProvider, localPhrases.contains(where: text.contains) { issues.append(.localModelForDevelopment(step: s.id)) }
        }
        if !rawKeys.isDisjoint(with: recursiveKeys) { issues.append(.recursiveAgentRequest(step: plan.steps.first?.id ?? "?")) }
        if let cyc = findCycle(plan.steps) { issues.append(.cycle(cyc)) }
        return issues
    }

    /// Kahn-style detection; returns one cycle path when the graph is not a DAG.
    static func findCycle(_ steps: [PlanStep]) -> [String]? {
        let graph = Dictionary(steps.map { ($0.id, $0.dependsOn) }, uniquingKeysWith: { a, _ in a })
        var state: [String: Int] = [:]             // 0 new, 1 visiting, 2 done
        var stack: [String] = []
        func visit(_ n: String) -> [String]? {
            if state[n] == 2 { return nil }
            if state[n] == 1 { return Array(stack.drop(while: { $0 != n })) + [n] }
            state[n] = 1; stack.append(n)
            for d in graph[n] ?? [] where graph[d] != nil { if let c = visit(d) { return c } }
            stack.removeLast(); state[n] = 2
            return nil
        }
        for s in steps { if let c = visit(s.id) { return c } }
        return nil
    }

    /// Parse + validate in one go. `plan` is non-nil only when there are NO issues.
    static func check(_ text: String, kind: TaskKind, capabilities: CapabilitySet, allowDestructive: Bool = true) -> (plan: TaskPlan?, issues: [PlanIssue]) {
        let parsed = PlanParser.parse(text)
        guard let plan = parsed.plan else { return (nil, parsed.issues) }
        let issues = validate(plan, kind: kind, capabilities: capabilities, allowDestructive: allowDestructive, rawKeys: parsed.rawKeys)
        return (issues.isEmpty ? plan : nil, issues)
    }
}

// MARK: - Planner prompt

enum PlannerPrompt {
    static func build(goal: String, kind: TaskKind, projectTree: String, buildCommand: String?, testCommand: String?, constraints: [String], allowDelete: Bool = false, scopeNotes: String? = nil) -> String {
        var allowedTypes = ["analysis", "build", "test", "review"]
        if kind == .development { allowedTypes.insert("codeChange", at: 1) }
        if kind == .development && allowDelete { allowedTypes.append("delete") }
        let cons = (constraints.isEmpty ? "" : "\nUser constraints:\n" + constraints.map { "- \($0)" }.joined(separator: "\n")) + (scopeNotes.map { "\n" + $0 } ?? "")
        return """
        You are the planning component of JARVIS, a task engine. Produce an execution plan for ONE user goal. Reply with a single JSON object and nothing else.

        Goal: \(goal)
        Task kind: \(kind == .development ? "development (may change project files)" : "read-only analysis (must NOT change files)")\(cons)

        Project files (relative paths, truncated):
        \(projectTree)

        Available deterministic commands: build = \(buildCommand ?? "none"), test = \(testCommand ?? "none").

        JSON schema:
        {"summary": "one sentence",
         "steps": [{"id": "s1", "title": "short imperative title", "description": "what to do and why",
                    "type": "\(allowedTypes.joined(separator: " | "))",
                    "dependsOn": ["ids of steps that must pass first"],
                    "expected": "the observable outcome",
                    "validation": "structuredResult | changedFiles | buildPass | testPass | testEvidence | reviewPass",
                    "risk": "low | medium"}]}

        Rules:
        - At most \(PlanValidator.maxSteps) steps, normally 4–7. Use the smallest plan that achieves the goal.
        - Step types: analysis = read and reason about files; codeChange = edit project files; build = run the build command; test = run the test command; review = review the final diff.
        - A typical development plan: analysis (inspect) → test (reproduce, validation testEvidence) → analysis (root cause) → codeChange → build → test (validation testPass) → review. Omit steps that do not apply.
        - Use type "test" with validation "testEvidence" to reproduce a failure before fixing; use "testPass" to prove a fix.
        - Every step needs dependencies that are earlier step ids. No cycles.
        - Do NOT plan: git operations, installing software, network access, credentials, deployments, \(allowDelete ? "deleting anything the goal did not explicitly ask to remove" : "deleting files"), creating agents or sub-agents, or using any paid service.
        \(allowDelete ? "- A \"delete\" step needs \"risk\": \"high\" and \"targets\": [explicit project-relative file paths, no wildcards]; the user must approve it before it runs." : "")
        - Do not invent files or commands that are not shown above.
        """
    }

    /// Re-ask text after an invalid plan.
    static func repair(original: String, issues: [PlanIssue]) -> String {
        "Your previous plan was rejected: " + issues.map(\.description).joined(separator: "; ") + ".\nReply again with ONE corrected JSON object only.\n\n" + original
    }
}
