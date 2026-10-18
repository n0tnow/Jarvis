import Foundation

// MARK: - Dependencies, API assumptions, documentation truth, architectural drift, diff statistics
//
// Small deterministic checks that turn "the worker said so" into "the repository shows so":
//   · a NEW dependency is surfaced (name, version, manifest) and needs EVIDENCE for the package and version — project metadata, a lockfile, research evidence — otherwise it is a
//     hallucination risk; nothing is added automatically;
//   · an API the worker relied on needs a reference or a passing compile / test at the final revision;
//   · documentation may not claim a state the evidence does not support (a doc saying MANUALLY VERIFIED without a person's record is a lie);
//   · a new type that duplicates a core system (a second orchestrator, approval system, state store, router) is surfaced for review;
//   · diff statistics are computed deterministically so an expensive reviewer never receives a huge irrelevant diff.

private func rx(_ p: String, _ o: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
private extension NSRegularExpression {
    func firstGroup(_ s: String, _ g: Int = 1) -> String? {
        guard let m = firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), g < m.numberOfRanges, let r = Range(m.range(at: g), in: s) else { return nil }
        return String(s[r])
    }
    func hits(_ s: String) -> Bool { firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
}

// MARK: Dependencies

struct DependencyAddition: Codable, Equatable, Sendable {
    var name: String
    var version: String?
    var manifest: String
}

struct DependencyEvidence: Codable, Equatable, Sendable {
    var name: String
    var version: String?
    /// "lockfile", "project metadata", "official docs", "registry (fixture)" — where it came from.
    var source: String
}

enum DependencyScanner {
    private static let swiftPM = rx(#"\.package\(\s*(?:name:\s*"[^"]*",\s*)?url:\s*"[^"]*?/([A-Za-z0-9_.-]+?)(?:\.git)?"\s*,\s*(?:from:\s*|\.upToNextMajor\(from:\s*|exact:\s*|\.exact\()?"?([0-9][0-9A-Za-z.+-]*)"#)
    private static let npm = rx(#"^\s*"(@?[A-Za-z0-9_./-]+)"\s*:\s*"([~^<>=]*[0-9][^"]*|latest|\*)""#)
    private static let pip = rx(#"^\s*([A-Za-z0-9_.-]+)\s*(?:[=<>~!]=?\s*([0-9][A-Za-z0-9.*+-]*))?\s*$"#)
    private static let cargo = rx(#"^\s*([A-Za-z0-9_-]+)\s*=\s*(?:"([^"]+)"|\{[^}]*version\s*=\s*"([^"]+)")"#)
    private static let csproj = rx(#"<PackageReference\s+Include="([^"]+)"(?:\s+Version="([^"]+)")?"#)
    private static let goMod = rx(#"^\s*(?:require\s+)?([a-z0-9.-]+\.[a-z]{2,}/[A-Za-z0-9_./-]+)\s+(v[0-9][A-Za-z0-9.+-]*)"#)
    private static let unityManifest = rx(#""([a-z0-9.-]+\.[a-z0-9.-]+)"\s*:\s*"([0-9][^"]*)""#)

    static func additions(path: String, before: String?, after: String?) -> [DependencyAddition] {
        guard PathClassifier.classes(of: path).contains(.dependencyManifest) else { return [] }
        let delta = LineDiffer.diff(before, after)
        let base = (path as NSString).lastPathComponent.lowercased(), ext = (path as NSString).pathExtension.lowercased()
        var out: [DependencyAddition] = []
        for line in delta.added {
            var hit: (String, String?)?
            if base == "package.swift", let n = swiftPM.firstGroup(line) { hit = (n, swiftPM.firstGroup(line, 2)) }
            else if base == "package.json", let n = npm.firstGroup(line), !["name", "version", "description", "main", "scripts", "license", "type"].contains(n) { hit = (n, npm.firstGroup(line, 2)) }
            else if base == "requirements.txt" || base == "pipfile", !line.hasPrefix("#"), !line.hasPrefix("-"), let n = pip.firstGroup(line) { hit = (n, pip.firstGroup(line, 2)) }
            else if base == "cargo.toml", let n = cargo.firstGroup(line), !["name", "version", "edition", "authors", "description", "license"].contains(n) { hit = (n, cargo.firstGroup(line, 2) ?? cargo.firstGroup(line, 3)) }
            else if ext == "csproj", let n = csproj.firstGroup(line) { hit = (n, csproj.firstGroup(line, 2)) }
            else if base == "go.mod", let n = goMod.firstGroup(line) { hit = (n, goMod.firstGroup(line, 2)) }
            else if base == "manifest.json", let n = unityManifest.firstGroup(line) { hit = (n, unityManifest.firstGroup(line, 2)) }
            if let h = hit { out.append(DependencyAddition(name: h.0, version: h.1, manifest: path)) }
        }
        return out
    }
}

enum DependencyCheck {
    /// A new dependency is always reported (it is more consequential than local code); it is only UNVERIFIED when no evidence names this package AND version.
    static func evaluate(_ additions: [DependencyAddition], evidence: [DependencyEvidence], scope: WriteScope) -> [EngineeringFinding] {
        var out: [EngineeringFinding] = []
        for a in additions {
            let known = evidence.contains { $0.name.lowercased() == a.name.lowercased() && ($0.version == nil || a.version == nil || $0.version == a.version) }
            let versionKnown = evidence.contains { $0.name.lowercased() == a.name.lowercased() && $0.version == a.version && a.version != nil }
            let label = "\(a.name)\(a.version.map { " \($0)" } ?? "") in \(a.manifest)"
            if !scope.mayAddDependencies { out.append(EngineeringFinding(.dependencyAdded, .blocker, path: a.manifest, "a dependency was added without authority", evidence: label)) }
            else { out.append(EngineeringFinding(.dependencyAdded, .note, path: a.manifest, "dependency added: surfaced for the report (name, version, reason, source, impact)", evidence: label)) }
            if !known || (a.version != nil && !versionKnown) {
                out.append(EngineeringFinding(.unverifiedDependency, .major, path: a.manifest, "no evidence that this package (and version) exists: a model can invent both", evidence: label))
            }
        }
        return out
    }
}

// MARK: API assumptions

struct APIAssumption: Codable, Equatable, Sendable {
    var symbol: String
    /// A reference that backs it (official docs excerpt id, a source file in the project that declares it, …). nil = none.
    var reference: String?
}

enum APIAssumptionCheck {
    /// An unfamiliar API is accepted on EVIDENCE: a reference, a declaration that exists in the project, or a build / test that passed at the final revision. "Looks plausible" is not evidence.
    static func evaluate(_ assumptions: [APIAssumption], declaredInProject: Set<String>, buildPassedAtFinalRevision: Bool) -> [EngineeringFinding] {
        assumptions.compactMap { a in
            if a.reference?.isEmpty == false || declaredInProject.contains(a.symbol) || buildPassedAtFinalRevision { return nil }
            return EngineeringFinding(.unvalidatedAPI, .major, path: ".", "an API the worker relied on has no reference and no passing build", evidence: a.symbol)
        }
    }
}

// MARK: Documentation truth

struct EvidenceSummary: Codable, Equatable, Sendable {
    var testsPassedAtCurrentRevision = false
    var buildPassedAtCurrentRevision = false
    var liveTestEvidence = false
    /// A HUMAN recorded a manual verification (never produced by a worker or by JARVIS).
    var manualVerificationRecorded = false
}

enum DocumentationTruth {
    private static let manual = rx(#"(?:manually\s+verified|elle\s+do[gğ]rulan\w*|human[- ]verified)"#)
    private static let automated = rx(#"(?:automated\s+tested|all\s+tests\s+pass(?:ed|ing)?|tests?\s+pass(?:ed|ing)?\b|verified\s+by\s+tests)"#)
    private static let real = rx(#"(?:real\s+tested|tested\s+on\s+(?:a\s+)?real|live[- ]tested)"#)

    /// A documentation change may not claim a state the recorded evidence does not support.
    static func check(path: String, delta: LineDelta, evidence: EvidenceSummary) -> [EngineeringFinding] {
        guard PathClassifier.classes(of: path).contains(.documentation) else { return [] }
        var out: [EngineeringFinding] = []
        for line in delta.added {
            if manual.hits(line), !evidence.manualVerificationRecorded { out.append(EngineeringFinding(.documentationOverclaim, .blocker, path: path, "the documentation says MANUALLY VERIFIED but no person recorded it", evidence: line)) }
            else if real.hits(line), !evidence.liveTestEvidence { out.append(EngineeringFinding(.documentationOverclaim, .major, path: path, "the documentation says REAL TESTED without a live-test record", evidence: line)) }
            else if automated.hits(line), !evidence.testsPassedAtCurrentRevision { out.append(EngineeringFinding(.documentationOverclaim, .major, path: path, "the documentation claims tests pass but none passed at the final revision", evidence: line)) }
        }
        return out
    }
}

// MARK: Architectural drift and duplicate abstractions

struct ProtectedConcept: Equatable, Sendable {
    /// Case-insensitive pattern on a NEW declared type name.
    var namePattern: String
    var ownedBy: String
}

enum ArchitectureDriftDetector {
    /// What this repository already solves — a new type that re-solves it is surfaced (project-specific lists come from the project; these are JARVIS's own).
    static let jarvisConcepts: [ProtectedConcept] = [
        ProtectedConcept(namePattern: #"(?:\w*orchestrator\w*|taskengine\d+|taskrunner\d*|autonomyengine\w*|\w*overnightengine|\w*superagent|\w*masteragent)"#, ownedBy: "TaskEngine"),
        ProtectedConcept(namePattern: #"\w*approval(?:manager|system|service|engine|store)\w*"#, ownedBy: "the HUD approval decision (ApprovalRecord)"),
        ProtectedConcept(namePattern: #"\w*(?:model|provider|engine)router\w*"#, ownedBy: "ModelRouter / the Intelligence Router"),
        ProtectedConcept(namePattern: #"\w*(?:statestore|taskstore|sessionstore|taskdatabase)\w*"#, ownedBy: "JarvisDatabase / the repositories"),
        ProtectedConcept(namePattern: #"\w*provider(?:manager|abstraction)\d*|\w*providerfactory\w*"#, ownedBy: "ProviderSupervisor / the provider layer"),
        ProtectedConcept(namePattern: #"\w*memory(?:manager|store|database)\w*"#, ownedBy: "MemoryService / ProjectContextBuilder"),
    ]
private static let declaration = rx(#"^\s*(?:public\s+|internal\s+|private\s+|final\s+|open\s+)*(?:class|struct|enum|actor|protocol)\s+([A-Z][A-Za-z0-9_]*)"#, [])

    static func declaredTypes(in delta: LineDelta) -> [String] { delta.added.compactMap { declaration.firstGroup($0) } }

    static func scan(deltas: [FileDelta], concepts: [ProtectedConcept] = jarvisConcepts, existingTypes: Set<String> = []) -> [EngineeringFinding] {
        var out: [EngineeringFinding] = []
        for d in deltas where !PathClassifier.classes(of: d.path).contains(.documentation) {
            let delta = LineDiffer.diff(d.before, d.after)
            for name in declaredTypes(in: delta) where !existingTypes.contains(name) {
                for c in concepts where rx("^\(c.namePattern)$").hits(name) {
                    out.append(EngineeringFinding(.architectureDrift, .major, path: d.path, "a new type duplicates a core system owned by \(c.ownedBy)", evidence: "type \(name)"))
                }
                if let twin = existingTypes.first(where: { similar($0, name) }), !out.contains(where: { $0.evidence == "type \(name)" }) {
                    out.append(EngineeringFinding(.duplicateAbstraction, .minor, path: d.path, "the new type looks like \(twin): confirm it is not a duplicate abstraction", evidence: "type \(name)"))
                }
            }
        }
        return out
    }

    static func tokens(_ name: String) -> Set<String> {
        var out: [String] = [], word = ""
        for ch in name {
            if ch.isUppercase, !word.isEmpty, word.last?.isLowercase == true { out.append(word.lowercased()); word = "" }
            word.append(ch)
        }
        if !word.isEmpty { out.append(word.lowercased()) }
        return Set(out)
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        guard a != b else { return false }
        let (x, y) = (tokens(a), tokens(b))
        guard x.count >= 2, y.count >= 2 else { return false }
        let inter = Double(x.intersection(y).count), union = Double(x.union(y).count)
        return inter >= 2 && inter / union >= 0.5
    }
}

// MARK: Diff statistics and deterministic condensation

struct DiffStats: Codable, Equatable, Sendable {
    var files = 0
    var linesAdded = 0
    var linesRemoved = 0
    var binaryFiles: [String] = []
    var generatedFiles: [String] = []
    var perFile: [String: [Int]] = [:]       // path → [added, removed]
}

enum DiffInspector {
    static func stats(changes: [FileChange], deltas: [FileDelta]) -> DiffStats {
        var s = DiffStats(files: changes.count)
        for c in changes {
            if c.isBinary { s.binaryFiles.append(c.path) }
            if PathClassifier.isGenerated(c.path) { s.generatedFiles.append(c.path) }
        }
        for d in deltas {
            let l = LineDiffer.diff(d.before, d.after)
            s.linesAdded += l.added.count; s.linesRemoved += l.removed.count
            s.perFile[d.path] = [l.added.count, l.removed.count]
        }
        return s
    }

    /// What an expensive reviewer is given: a deterministic summary, then hunks for non-generated, non-binary, non-lock files in order of importance, within a character budget.
    static func condensed(deltas: [FileDelta], changes: [FileChange], budget: Int = 6_000) -> String {
        let stats = stats(changes: changes, deltas: deltas)
        var lines = ["CHANGE SUMMARY: \(stats.files) file(s), +\(stats.linesAdded) −\(stats.linesRemoved)"]
        if !stats.binaryFiles.isEmpty { lines.append("binary (content omitted): " + stats.binaryFiles.prefix(10).joined(separator: ", ")) }
        if !stats.generatedFiles.isEmpty { lines.append("generated (content omitted): " + stats.generatedFiles.prefix(10).joined(separator: ", ")) }
        let important = deltas.filter { d in
            let c = PathClassifier.classes(of: d.path)
            return !c.contains(.generated) && !c.contains(.binaryAsset) && !(d.path.lowercased().hasSuffix(".lock") || d.path.lowercased().hasSuffix(".resolved"))
        }.sorted { a, b in
            func weight(_ p: String) -> Int { let c = PathClassifier.classes(of: p); return c.contains(.securityGuard) ? 0 : (c.contains(.buildScript) ? 1 : (c.contains(.test) ? 2 : (c.contains(.dependencyManifest) ? 3 : 4))) }
            return (weight(a.path), a.path) < (weight(b.path), b.path)
        }
        var used = lines.joined(separator: "\n").count
        for d in important {
            let l = LineDiffer.diff(d.before, d.after)
            var block = ["--- \(d.path)\(d.isDeleted ? " (deleted)" : d.isCreated ? " (new)" : "")"]
            block += l.removed.prefix(40).map { "- \($0.prefix(160))" } + l.added.prefix(40).map { "+ \($0.prefix(160))" }
            let text = block.joined(separator: "\n")
            if used + text.count + 1 > budget { lines.append("[\(important.count - lines.filter { $0.hasPrefix("---") }.count) more file(s) omitted: budget]"); break }
            lines.append(text); used += text.count + 1
        }
        return lines.joined(separator: "\n")
    }
}
