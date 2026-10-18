import Foundation

// MARK: - What a worker SAYS it did (claims), kept apart from what JARVIS OBSERVED
//
// `WorkerClaims` is the structured form of a worker's answer. Every field is a CLAIM: claimed files changed != the actual diff, claimed tests != a test run,
// claimed success != verified success. Nothing in this type can become `VerificationEvidence` — evidence is only produced from observed processes and repository
// state (`EngineeringVerifier`). A worker answer that cannot be parsed is a typed failure, never a guess.

enum ClaimedStatus: String, Codable, Equatable, Sendable { case done, partial, blocked, failed }

struct ClaimedCommand: Codable, Equatable, Sendable {
    var command: String
    var exitCode: Int?
}

struct ClaimedTests: Codable, Equatable, Sendable {
    var passed: Int?
    var failed: Int?
    var allGreen: Bool?
}

struct WorkerClaims: Codable, Equatable, Sendable {
    var status: ClaimedStatus
    var filesInspected: [String] = []
    var filesChanged: [String] = []
    var changeSummary: [String] = []
    var commandsRun: [ClaimedCommand] = []
    var tests: ClaimedTests?
    var artifacts: [String] = []
    var warnings: [String] = []
    var blockedReason: String?
    var remainingWork: [String] = []
    var claimedCommit: String?
    /// APIs / packages the worker says it relied on (to be validated, never trusted).
    var apiAssumptions: [String] = []
    var addedDependencies: [String] = []
}

enum WorkerReportIssue: Error, Equatable, Sendable, CustomStringConvertible {
    case notJSON
    case missingStatus
    case unknownStatus(String)
    case tooLarge(Int)

    var description: String {
        switch self {
        case .notJSON: "the worker's answer is not a structured report"
        case .missingStatus: "the report has no status"
        case .unknownStatus(let s): "unknown status \"\(s)\""
        case .tooLarge(let n): "the report is too large (\(n) characters)"
        }
    }
}

enum WorkerReportParser {
    static let maxCharacters = 60_000
    static let maxListItems = 200

    static func parse(_ text: String) -> Result<WorkerClaims, WorkerReportIssue> {
        guard text.count <= maxCharacters else { return .failure(.tooLarge(text.count)) }
        guard let json = PlanParser.extractJSONObject(text), let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(.notJSON) }
        guard let rawStatus = (root["status"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces), !rawStatus.isEmpty else { return .failure(.missingStatus) }
        let aliases: [String: ClaimedStatus] = ["done": .done, "complete": .done, "completed": .done, "success": .done, "ok": .done, "partial": .partial, "incomplete": .partial,
                                                 "blocked": .blocked, "failed": .failed, "failure": .failed, "error": .failed]
        guard let status = aliases[rawStatus] else { return .failure(.unknownStatus(String(rawStatus.prefix(30)))) }
        func strings(_ key: String) -> [String] {
            ((root[key] as? [Any]) ?? []).prefix(maxListItems).compactMap { ($0 as? String).map { String($0.prefix(300)) } }
        }
        var claims = WorkerClaims(status: status)
        claims.filesInspected = strings("filesInspected")
        claims.filesChanged = strings("filesChanged")
        claims.changeSummary = strings("changes")
        claims.artifacts = strings("artifacts")
        claims.warnings = strings("warnings")
        claims.remainingWork = strings("remainingWork")
        claims.apiAssumptions = strings("apiAssumptions")
        claims.addedDependencies = strings("addedDependencies")
        claims.blockedReason = (root["blockedReason"] as? String).map { String($0.prefix(400)) }
        claims.claimedCommit = (root["commit"] as? String).map { String($0.prefix(64)) }
        claims.commandsRun = ((root["commandsRun"] as? [Any]) ?? []).prefix(maxListItems).compactMap { item in
            if let s = item as? String { return ClaimedCommand(command: String(s.prefix(300)), exitCode: nil) }
            if let d = item as? [String: Any], let c = d["command"] as? String { return ClaimedCommand(command: String(c.prefix(300)), exitCode: d["exitCode"] as? Int) }
            return nil
        }
        if let t = root["tests"] as? [String: Any] {
            claims.tests = ClaimedTests(passed: t["passed"] as? Int, failed: t["failed"] as? Int, allGreen: (t["allGreen"] as? Bool) ?? (t["allPassed"] as? Bool))
        } else if let b = root["testsPass"] as? Bool { claims.tests = ClaimedTests(passed: nil, failed: nil, allGreen: b) }
        return .success(claims)
    }
}
