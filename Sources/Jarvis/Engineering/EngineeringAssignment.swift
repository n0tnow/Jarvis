import Foundation

// MARK: - The engineering assignment contract (V1.0 autonomous engineering pipeline)
//
// A coding worker is an UNTRUSTED implementation contributor. What it is asked to do is a bounded, typed assignment — never "fix the project":
// an objective, the files it may change and the ones it may never touch, what "done" means (acceptance criteria that JARVIS can check itself), which approved
// verification profiles apply, the risk, the budget and the capabilities a worker needs. The assignment is data: it grants no authority (the TaskEngine's
// capabilities, leases, approvals and workspace guard still decide), it only makes the request precise enough to be CHECKED afterwards.
// Pure value logic: no process, no file access, no model, no timer.

enum EngineeringDomain: String, Codable, CaseIterable, Sendable {
    case runtime, tests, docs, build, ui, networking, unityScripts, config, other
}

/// What a worker must be good at. Selection is by capability metadata, never by brand name.
enum WorkerCapability: String, Codable, CaseIterable, Sendable {
    case codeGeneration, codeReview, testGeneration, repositoryAnalysis, debugging, research, longContext, architecture, unity, swift, typescript
}

enum PathGlob {
    /// Glob subset: `**` (any depth), `*` (within one segment), exact paths, `dir/` (prefix). Case-insensitive like the default macOS volume.
    static func matches(_ pattern: String, _ path: String) -> Bool {
        let p = normalize(pattern), s = normalize(path)
        if p.isEmpty { return false }
        if !p.contains("*") { return s == p || s.hasPrefix(p + "/") }
        return regex(for: p).map { $0.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil } ?? false
    }

    static func normalize(_ s: String) -> String {
        var t = s.precomposedStringWithCanonicalMapping.lowercased().trimmingCharacters(in: .whitespaces)
        while t.hasPrefix("./") { t.removeFirst(2) }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func regex(for p: String) -> NSRegularExpression? {
        var out = "^"
        var i = p.startIndex
        while i < p.endIndex {
            let c = p[i]
            if c == "*" {
                let next = p.index(after: i)
                if next < p.endIndex, p[next] == "*" {
                    let after = p.index(after: next)
                    if after < p.endIndex, p[after] == "/" { out += "(?:.*/)?"; i = p.index(after: after); continue }
                    out += ".*"; i = after; continue
                }
                out += "[^/]*"
            } else { out += NSRegularExpression.escapedPattern(for: String(c)) }
            i = p.index(after: i)
        }
        return try? NSRegularExpression(pattern: out + "(?:/.*)?$")
    }

    /// Could two patterns ever select the same path? Conservative: true when unsure (used for write reservations).
    static func mayOverlap(_ a: String, _ b: String) -> Bool {
        let x = normalize(a), y = normalize(b)
        if x == y { return true }
        let (xs, ys) = (x.contains("*"), y.contains("*"))
        if !xs, !ys { return x.hasPrefix(y + "/") || y.hasPrefix(x + "/") }
        if !xs { return matches(y, x) }
        if !ys { return matches(x, y) }
        // two globs: compare the literal prefixes before the first wildcard, then the extension tails
        func literalPrefix(_ s: String) -> String { String(s.prefix { $0 != "*" }) }
        let (px, py) = (literalPrefix(x), literalPrefix(y))
        guard px.hasPrefix(py) || py.hasPrefix(px) else { return false }
        func tail(_ s: String) -> String { String(s.reversed().prefix { $0 != "*" && $0 != "/" }.reversed()) }
        let (tx, ty) = (tail(x), tail(y))
        if !tx.isEmpty, !ty.isEmpty, !tx.hasSuffix(ty), !ty.hasSuffix(tx) { return false }
        return true
    }
}

struct WriteScope: Codable, Equatable, Sendable {
    /// Workspace-relative globs the worker may change. Empty = a read-only assignment.
    var allowed: [String] = []
    /// Globs that may NEVER change; a forbidden match always wins over `allowed`.
    var forbidden: [String] = []
    /// Extra project-specific protected globs (guards, signing, user data) — not Hamam-specific; supplied per project.
    var protectedPatterns: [String] = []
    var mayModifyTests = false
    var mayModifyBuildScripts = false
    var mayModifyGuards = false
    var mayAddDependencies = false
    var mayDelete = false
    /// How many files the task is EXPECTED to change (a magnitude to compare the real diff against, not a universal threshold).
    var expectedFileCount: ClosedRange<Int>?

    var isReadOnly: Bool { allowed.isEmpty }

    func allows(_ path: String) -> Bool {
        if forbidden.contains(where: { PathGlob.matches($0, path) }) { return false }
        return allowed.contains { PathGlob.matches($0, path) }
    }
    func isForbidden(_ path: String) -> Bool { forbidden.contains { PathGlob.matches($0, path) } }
}

enum CriterionCheck: Codable, Equatable, Sendable {
    /// An approved verification profile (by label) must pass at the final revision.
    case profile(String)
    case fileExists(String)
    case fileContains(path: String, text: String)
    case fileDoesNotContain(path: String, text: String)
    /// A human has to look (real macOS, real Unity, a browser, hardware): never auto-verifiable.
    case manual(String)
}

struct AcceptanceCriterion: Codable, Equatable, Sendable {
    var id: String
    var text: String
    var check: CriterionCheck
}

struct ExpectedArtifact: Codable, Equatable, Sendable {
    var path: String
    var kind: String            // "file", "report", "patch"
    var mustBeNonEmpty = true
}

struct EngineeringBudget: Codable, Equatable, Sendable {
    var workerAttempts = 3
    var verificationRuns = 6
    var providerRequests = 12
    var wallClock: TimeInterval = 30 * 60

    /// Mapped onto the EXISTING task budget infrastructure (`TaskBudgetLedger`) — no second budget system.
    var taskBudget: TaskBudget {
        var b = TaskBudget()
        b.wallClock = wallClock; b.modelRequests = providerRequests; b.providerRetries = max(1, providerRequests / 3)
        b.consecutiveVerificationFailures = verificationRuns
        return b
    }
}

/// The revision an assignment was made against; used to detect stale results and repository drift.
struct RevisionStamp: Codable, Equatable, Sendable {
    var head: String?
    var branch: String?
    /// Digest of the file fingerprints of the workspace (see `WorkspaceSnapshot.digest`).
    var snapshotDigest: String
}

enum AssignmentIssue: Equatable, Sendable, CustomStringConvertible {
    case emptyObjective
    case tooVague
    case noAcceptanceCriteria
    case writesWithoutScope
    case absoluteOrTraversingPath(String)
    case unsafeProfileLabel(String)
    case criticalNeedsGate
    case forbiddenOverlapsAllowed(String)
    case readOnlyWithWriteCriteria

    var description: String {
        switch self {
        case .emptyObjective: "the objective is empty"
        case .tooVague: "the objective is too vague to check (name what must change and how success is observed)"
        case .noAcceptanceCriteria: "no acceptance criterion: nothing could ever verify the work"
        case .writesWithoutScope: "the assignment asks for changes but allows no path"
        case .absoluteOrTraversingPath(let p): "path \"\(p)\" is absolute or leaves the workspace"
        case .unsafeProfileLabel(let l): "verification profile \"\(l)\" is not a plain approved label"
        case .criticalNeedsGate: "a critical assignment cannot be delegated without its approval gate"
        case .forbiddenOverlapsAllowed(let p): "\"\(p)\" is both allowed and forbidden (forbidden wins)"
        case .readOnlyWithWriteCriteria: "a read-only assignment has acceptance criteria that need a change"
        }
    }
}

struct EngineeringAssignment: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var objective: String
    /// A label for the project (never a path outside the workspace): "game", "tool".
    var project: String
    var scope = WriteScope()
    var domains: Set<EngineeringDomain> = []
    var requirements: [String] = []
    var constraints: [String] = []
    var acceptance: [AcceptanceCriterion] = []
    /// Labels of APPROVED verification profiles (never free-form commands: those go through `ApprovedExecutables`).
    var verificationProfiles: [String] = []
    var risk: RiskClass = .low
    var dependsOn: [UUID] = []
    var expectedArtifacts: [ExpectedArtifact] = []
    var budget = EngineeringBudget()
    var requiredCapabilities: Set<WorkerCapability> = [.codeGeneration]
    /// "auto" or an explicit user choice (an explicit choice never falls back).
    var providerPreference: String = "auto"
    /// Project conventions the worker must follow (discovered per project; for JARVIS itself AGENTS.md is authoritative).
    var conventions: [String] = []
    var base: RevisionStamp?
    /// True only when the critical-action approval gate for this assignment was released by a HUD decision.
    var gateApproved = false
    /// Globs of "shared core" areas: a change there widens verification.
    var sharedCorePatterns: [String] = []

    static let maxObjective = 1_200

    func validate() -> [AssignmentIssue] {
        var out: [AssignmentIssue] = []
        let trimmed = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { out.append(.emptyObjective) }
        else if Self.isVague(trimmed, hasScope: !scope.allowed.isEmpty, hasAcceptance: !acceptance.isEmpty) { out.append(.tooVague) }
        for p in scope.allowed + scope.forbidden + scope.protectedPatterns + expectedArtifacts.map(\.path) where p.hasPrefix("/") || p.hasPrefix("~") || p.split(separator: "/").contains("..") {
            out.append(.absoluteOrTraversingPath(p))
        }
        for l in verificationProfiles where l.range(of: #"^[A-Za-z0-9 _.:+-]{1,60}$"#, options: .regularExpression) == nil { out.append(.unsafeProfileLabel(l)) }
        if acceptance.isEmpty, !scope.isReadOnly { out.append(.noAcceptanceCriteria) }
        if scope.isReadOnly, acceptance.contains(where: { if case .fileContains = $0.check { return true }; if case .fileExists = $0.check { return true }; return false }) { out.append(.readOnlyWithWriteCriteria) }
        if risk >= .critical, !gateApproved { out.append(.criticalNeedsGate) }
        for a in scope.allowed where scope.forbidden.contains(where: { PathGlob.normalize($0) == PathGlob.normalize(a) }) { out.append(.forbiddenOverlapsAllowed(a)) }
        return out
    }

    /// "fix the project", "make it better": short, no named target, and nothing else that makes it checkable.
    static func isVague(_ objective: String, hasScope: Bool, hasAcceptance: Bool) -> Bool {
        if hasScope && hasAcceptance { return false }
        let words = objective.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        let hasTarget = objective.contains("/") || objective.contains(".") && objective.range(of: #"\b\w+\.\w{1,6}\b"#, options: .regularExpression) != nil
            || objective.range(of: #"\b[A-Z][a-z]+[A-Z]\w*\b"#, options: .regularExpression) != nil || objective.contains("`")
        return words < 5 && !hasTarget && !hasAcceptance
    }

    /// The bounded text a worker is given: objective, scope, constraints, criteria — never a repository dump. Conventions are data, not instructions that widen scope.
    func promptBlock(maxCharacters: Int = 3_500) -> String {
        var lines = ["OBJECTIVE: \(String(objective.prefix(Self.maxObjective)))"]
        if !requirements.isEmpty { lines.append("REQUIREMENTS:\n" + requirements.prefix(12).map { "- \($0)" }.joined(separator: "\n")) }
        lines.append(scope.isReadOnly ? "SCOPE: read-only — change nothing." : "MAY CHANGE ONLY: " + scope.allowed.prefix(20).joined(separator: ", "))
        if !scope.forbidden.isEmpty { lines.append("NEVER TOUCH: " + scope.forbidden.prefix(20).joined(separator: ", ")) }
        var rules: [String] = []
        if !scope.mayModifyTests { rules.append("do not edit, delete, skip or weaken tests") }
        if !scope.mayModifyBuildScripts { rules.append("do not edit build, test-runner or CI scripts") }
        if !scope.mayModifyGuards { rules.append("do not weaken security guards, approval logic or credential checks") }
        if !scope.mayAddDependencies { rules.append("add no dependency") }
        if !scope.mayDelete { rules.append("delete no file") }
        rules.append("report only what you did; JARVIS verifies the real repository state itself")
        lines.append("RULES: " + rules.joined(separator: "; "))
        if !constraints.isEmpty { lines.append("CONSTRAINTS:\n" + constraints.prefix(10).map { "- \($0)" }.joined(separator: "\n")) }
        if !acceptance.isEmpty { lines.append("ACCEPTANCE:\n" + acceptance.prefix(12).map { "- [\($0.id)] \($0.text)" }.joined(separator: "\n")) }
        if !conventions.isEmpty { lines.append("PROJECT CONVENTIONS:\n" + conventions.prefix(8).map { "- \($0)" }.joined(separator: "\n")) }
        let text = lines.joined(separator: "\n")
        return text.count <= maxCharacters ? text : String(text.prefix(maxCharacters - 1)) + "…"
    }

    /// The `TaskProfile` the existing router understands (development, coding / testing, complexity from risk and breadth) — the router stays the routing authority.
    func routingProfile(estimatedContextTokens: Int = 0) -> TaskProfile {
        var p = TaskProfile()
        p.category = requiredCapabilities.contains(.architecture) ? .architecture : (requiredCapabilities.contains(.debugging) ? .debugging : (requiredCapabilities.contains(.codeReview) && !requiredCapabilities.contains(.codeGeneration) ? .review : (requiredCapabilities.contains(.testGeneration) && !requiredCapabilities.contains(.codeGeneration) ? .testing : .coding)))
        p.requiresCoding = requiredCapabilities.contains(.codeGeneration) || requiredCapabilities.contains(.debugging)
        p.requiresTesting = requiredCapabilities.contains(.testGeneration)
        p.requiresRepositoryModification = !scope.isReadOnly
        p.requiresTechnicalReview = requiredCapabilities.contains(.codeReview)
        p.requiresComplexReasoning = requiredCapabilities.contains(.architecture) || risk >= .high
        p.containsProjectCode = true
        p.wantsStructuredOutput = true
        p.estimatedContextTokens = estimatedContextTokens
        p.complexity = risk >= .critical ? .critical : (risk == .high || requiredCapabilities.contains(.architecture) ? .complex : (scope.allowed.count > 3 || requiredCapabilities.contains(.debugging) ? .moderate : .simple))
        if requiredCapabilities.contains(.unity) { p.domainTags.insert("unity") }
        if requiredCapabilities.contains(.swift) { p.domainTags.insert("swift") }
        if requiredCapabilities.contains(.typescript) { p.domainTags.insert("typescript") }
        if risk >= .high { p.domainTags.insert("security") }
        return p
    }
}
