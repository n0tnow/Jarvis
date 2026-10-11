import Foundation

/// Targeted, token-frugal memory access (V0.3.1 §12). Providers never receive "the database": only a small, bounded
/// preface about the ACTIVE task — its status, the last few successful results (already redacted excerpts) and recent
/// failures. Nothing about other tasks, nothing sensitive beyond what the audit trail already minimised.
struct ContextRetrieval {
    let repository: JarvisRepository?
    var maxCharacters = 1200
    var maxRuns = 3

    func preface(taskID: UUID?, excludingRun: UUID? = nil) -> String? {
        guard let repository, let taskID, let info = try? repository.taskInfo(taskID) else { return nil }
        var lines = ["Task context (from JARVIS memory): \"\(info.title)\" — status: \(info.status)."]
        if let s = info.summary, !s.isEmpty { lines.append("Summary so far: \(s)") }
        let runs = ((try? repository.agentRuns(taskID: taskID)) ?? []).filter { $0.id != excludingRun }.sorted { $0.startedAt > $1.startedAt }
        let done = runs.filter { $0.status == .succeeded }.prefix(maxRuns)
        if !done.isEmpty {
            lines.append("Earlier results:")
            for r in done { lines.append("- \(r.agentType) (\(r.engine.displayName)): \(r.resultSummary ?? "completed")") }
        }
        let failed = runs.filter { $0.status == .failed || $0.status == .escalated }.prefix(2)
        if !failed.isEmpty {
            lines.append("Earlier problems (avoid repeating):")
            for r in failed { lines.append("- \(r.agentType) on \(r.engine.displayName) did not succeed (\(r.errorCategory ?? r.validationStatus.rawValue))") }
        }
        let text = lines.joined(separator: "\n")
        return text.count <= maxCharacters ? text : String(text.prefix(maxCharacters - 1)) + "…"
    }
}
