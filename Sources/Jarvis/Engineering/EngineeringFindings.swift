import Foundation

// MARK: - Findings: typed, severity-ranked, evidence-carrying (V1.0 autonomous engineering pipeline)
//
// Every check in the pipeline reports `EngineeringFinding`s. Severity decides what may block:
//   BLOCKER — fails the work (a scope escape, a forbidden path, a deleted test, a weakened guard, a secret, a claim that contradicts the repository);
//   MAJOR   — needs a decision before the work can be called verified (a changed test, a suspicious suppression, an unexplained large diff);
//   MINOR / NOTE — recorded in the report, NEVER blocks (style-police loops are a failure mode of their own).
// A finding names its evidence (a path, a line, a command): a finding without evidence is only a NOTE.

enum FindingSeverity: Int, Codable, Comparable, Sendable {
    case note = 0, minor, major, blocker
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    var label: String { switch self { case .note: "NOTE"; case .minor: "MINOR"; case .major: "MAJOR"; case .blocker: "BLOCKER" } }
}

enum FindingCode: String, Codable, CaseIterable, Sendable {
    // scope and ownership
    case scopeEscape, forbiddenPath, protectedPath, userDirtyFileTouched, deletionNotAllowed, unexplainedChange, readOnlyAssignmentChanged
    // tampering
    case testDeleted, testSkipped, assertionWeakened, assertionChanged, testModifiedWithoutAuthority
    case guardWeakened, guardChanged, buildScriptChanged, buildFailureSuppressed
    // quality
    case placeholderCode, placeholderComment, silentErrorSuppression, secretIntroduced, unsafeCommand, shellInjectionRisk
    // dependencies and APIs
    case dependencyAdded, unverifiedDependency, unvalidatedAPI
    // magnitude and structure
    case largeDiff, binaryFileChanged, generatedFileChanged, architectureDrift, duplicateAbstraction
    // claims and evidence
    case noChange, claimedChangeNotInDiff, unclaimedChange, claimUnverified, testClaimContradicted, commitClaimContradicted, artifactMissing, artifactInvalid, criterionUnmet, staleEvidence
    // lifecycle
    case staleResult, regression, documentationOverclaim, malformedWorkerOutput, repeatedFailure
}

struct EngineeringFinding: Codable, Equatable, Sendable {
    var code: FindingCode
    var severity: FindingSeverity
    var path: String?
    var message: String
    var evidence: String

    init(_ code: FindingCode, _ severity: FindingSeverity, path: String? = nil, _ message: String, evidence: String = "") {
        self.code = code; self.severity = severity; self.path = path
        self.message = String(message.prefix(300)); self.evidence = String(evidence.prefix(240))
        // a claim without evidence is not allowed to block
        if evidence.trimmingCharacters(in: .whitespaces).isEmpty, path == nil, severity > .note, ![.noChange, .criterionUnmet, .staleResult, .malformedWorkerOutput, .repeatedFailure, .regression].contains(code) { self.severity = .note }
    }
}

extension Array where Element == EngineeringFinding {
    var blockers: [EngineeringFinding] { filter { $0.severity == .blocker } }
    var majors: [EngineeringFinding] { filter { $0.severity == .major } }
    var worst: FindingSeverity? { map(\.severity).max() }
    func contains(_ code: FindingCode) -> Bool { contains { $0.code == code } }
}

// MARK: - What a path IS (language- and project-agnostic classes; project-specific globs come from the assignment)

enum PathClass: String, Codable, CaseIterable, Sendable {
    case test, buildScript, securityGuard, dependencyManifest, documentation, generated, secretMaterial, binaryAsset, source, config
}

enum PathClassifier {
    private static let buildNames: Set<String> = ["verify.sh", "test.sh", "build.sh", "build_app.sh", "package-app.sh", "makefile", "dockerfile", "jenkinsfile", "run_tests.sh", "ci.sh", "tox.ini", "noxfile.py"]
    private static let manifestNames: Set<String> = ["package.swift", "package.resolved", "package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "podfile", "podfile.lock", "requirements.txt", "pipfile", "pipfile.lock", "pyproject.toml", "cargo.toml", "cargo.lock", "go.mod", "go.sum", "gemfile", "gemfile.lock", "manifest.json", "packages-lock.json", "build.gradle", "pom.xml"]
    private static let secretExtensions: Set<String> = ["pem", "p12", "pfx", "keystore", "jks", "mobileprovision", "cer", "key"]
    private static let binaryExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "psd", "fbx", "wav", "mp3", "ogg", "mp4", "mov", "zip", "a", "dylib", "so", "dll", "exe", "ttf", "otf", "pdf", "unitypackage"]
    private static let guardWords = ["guard", "approval", "credential", "secret", "sanitiz", "redact", "permission", "capabilit", "policy", "receipt", "firewall", "denylist", "allowlist"]

    static func classes(of path: String) -> Set<PathClass> {
        let p = PathGlob.normalize(path)
        let parts = p.split(separator: "/").map(String.init)
        let base = parts.last ?? p
        let ext = (base as NSString).pathExtension
        var out: Set<PathClass> = []
        if TaskScope.isTestPath(path) { out.insert(.test) }
        if buildNames.contains(base) || p.hasPrefix(".github/workflows/") || p.hasPrefix(".circleci/") || p == ".gitlab-ci.yml" || p == "azure-pipelines.yml" { out.insert(.buildScript) }
        if manifestNames.contains(base) || ext == "csproj" || ext == "podspec" || ext == "gemspec" || ext == "sln" { out.insert(.dependencyManifest) }
        if ["md", "markdown", "rst", "txt", "adoc"].contains(ext) || parts.first == "docs" { out.insert(.documentation) }
        if parts.contains(where: { [".build", "build", "dist", "deriveddata", "node_modules", "__pycache__", "obj", "temp", "library"].contains($0) }) { out.insert(.generated) }
        if base == ".env" || base.hasPrefix(".env.") || secretExtensions.contains(ext) || base.contains("credential") && !guardLike(base) || base == "id_rsa" || base.hasSuffix(".entitlements") { out.insert(.secretMaterial) }
        if binaryExtensions.contains(ext) { out.insert(.binaryAsset) }
        if guardLike(base) || (base.hasPrefix("guards") && ext == "sh") || parts.contains(where: { $0 == "guards" || $0 == "security" }) { out.insert(.securityGuard) }
        if ["json", "yaml", "yml", "toml", "ini", "plist", "xml", "cfg", "conf"].contains(ext) { out.insert(.config) }
        if out.isEmpty || out == [.test] { if !out.contains(.test) { out.insert(.source) } }
        return out
    }

    private static func guardLike(_ base: String) -> Bool {
        let stem = (base as NSString).deletingPathExtension
        return guardWords.contains { stem.contains($0) } && ["swift", "sh", "py", "ts", "js", "cs", "kt", "go", "rs", "java"].contains((base as NSString).pathExtension)
    }

    static func isGenerated(_ path: String) -> Bool { classes(of: path).contains(.generated) }
}
