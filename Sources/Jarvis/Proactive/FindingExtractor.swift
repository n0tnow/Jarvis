import Foundation

/// A follow-up idea written by the review model. It is a CLAIM: it enters the engine as a finding with `reviewClaim` evidence and
/// is assessed/decided like anything else. Unknown or authority-bearing fields in the model's JSON are never read.
struct ReviewSuggestion: Equatable, Sendable {
    var title: String
    var summary: String
    var files: [String]
    var category: OpportunityCategory?
    var designImpact: Bool

    static func parse(_ text: String) -> [ReviewSuggestion] {
        guard let json = PlanParser.extractJSONObject(text), let d = json.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let arr = o["suggestions"] as? [[String: Any]] else { return [] }
        return arr.prefix(2).compactMap { s in
            guard let title = (s["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
            return ReviewSuggestion(title: OutputSanitizer.sanitize(String(title.prefix(160))), summary: OutputSanitizer.sanitize(String(((s["summary"] as? String) ?? "").prefix(400))),
                                    files: ((s["files"] as? [Any]) ?? []).compactMap { $0 as? String }.prefix(4).map { String($0.prefix(200)) },
                                    category: (s["category"] as? String).flatMap(OpportunityCategory.init(rawValue:)), designImpact: (s["designImpact"] as? Bool) ?? false)
        }
    }
}

/// Derives bounded, structured findings from what JARVIS itself recorded about a finished task (no model call, no repository scan).
enum FindingExtractor {
    static func findings(task t: TaskRecord, steps: [TaskStepRecord], changes: [TaskFileChange], report: TaskReport?, knownFiles: [String]) -> [RawFinding] {
        guard let root = t.workspaceRoot else { return [] }
        var out: [RawFinding] = []

        // A. A completed development task changed application code but no test: a focused regression test is a strongly evidenced, direct follow-up.
        if t.kind == .development, t.state == .completed {
            let changed = changes.filter { $0.changeType != "deleted" }.map(\.path)
            let source = changed.filter { !TaskScope.isTestPath($0) }
            let testChanged = changed.contains(where: TaskScope.isTestPath)
            let testFiles = knownFiles.filter(TaskScope.isTestPath)
            let hasTests = !testFiles.isEmpty || steps.contains { $0.type == .test && $0.state == .passed }
            if !source.isEmpty, !testChanged, hasTests {
                let stem = (((source[0] as NSString).lastPathComponent as NSString).deletingPathExtension).lowercased()
                let counterparts = testFiles.filter { $0.lowercased().contains(stem) }
                let affected = Array((counterparts.isEmpty ? testFiles : counterparts).prefix(2))
                out.append(RawFinding(
                    origin: .taskFinding, title: "No regression test was added for the change to \(source[0])",
                    summary: "The task “\(t.title)” changed \(source.joined(separator: ", ")) but no test file was changed. A focused regression test would keep the fix from regressing.",
                    category: .testCoverage,
                    evidence: [EvidenceItem(kind: .taskResult, summary: "Task completed and changed \(source.joined(separator: ", ")); no test file was changed in the same task", reference: source[0])]
                        + affected.map { EvidenceItem(kind: .fileReference, summary: "Existing test file the new test would join", reference: $0) },
                    affectedPaths: affected, originTaskID: t.id, projectRoot: root, eventKey: "task:\(t.id.uuidString):regression-test"))
            }
        }

        // B. Failures worth remembering (never auto-fixed: no concrete action).
        if t.state == .failed, let cat = t.failureCategory {
            let failing = steps.first { $0.state == .failed }
            if cat == .toolFailed, (t.failureReason ?? "").contains("No test command") {
                out.append(RawFinding(origin: .testFinding, title: "The project has no detectable test command",
                                      summary: "The task could not establish that tests pass because no test command was found. Declaring one in .jarvis/project.json would let JARVIS validate changes.",
                                      category: .configuration, evidence: [EvidenceItem(kind: .validationOutput, summary: "Task failed: " + (t.failureReason ?? ""), reference: ".jarvis/project.json",
                                                                                         predicate: .fileMissing(path: ".jarvis/project.json"))],
                                      affectedPaths: [".jarvis/project.json"], originTaskID: t.id, projectRoot: root, eventKey: "task:\(t.id.uuidString):no-test-command"))
            } else if cat == .testFailed || cat == .buildFailed {
                out.append(RawFinding(origin: .validationFinding, title: "\(cat == .testFailed ? "Tests" : "The build") still failed after repair: \(failing?.title ?? t.title)",
                                      summary: "A task ended with a failing \(cat == .testFailed ? "test run" : "build") after the bounded repair and escalation: \(t.failureReason ?? "").",
                                      category: .bug, evidence: [EvidenceItem(kind: .validationOutput, summary: failing?.validationEvidence?.split(separator: "\n").first.map(String.init) ?? (t.failureReason ?? ""))],
                                      affectedPaths: [], originTaskID: t.id, originStepID: failing?.id, projectRoot: root, eventKey: "task:\(t.id.uuidString):failed-validation"))
            }
        }
        return out
    }
}
