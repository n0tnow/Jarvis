import Foundation

// MARK: - Structured agent answers

struct AnalysisResult: Equatable, Sendable {
    var summary: String
    var findings: [String]
    var relevantFiles: [String]
    var rootCause: String

    static func parse(_ text: String) -> AnalysisResult? {
        guard let json = PlanParser.extractJSONObject(text), let d = json.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let summary = (o["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else { return nil }
        func strings(_ k: String) -> [String] { (o[k] as? [Any] ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        return AnalysisResult(summary: summary, findings: strings("findings"), relevantFiles: strings("relevantFiles") + strings("relevant_files"),
                              rootCause: (o["rootCause"] as? String ?? o["root_cause"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Compact one-block rendering that later steps receive as context (bounded).
    var rendered: String {
        var s = "Summary: \(summary)"
        if !rootCause.isEmpty { s += "\nRoot cause: \(rootCause)" }
        if !findings.isEmpty { s += "\nFindings:\n" + findings.prefix(8).map { "- \($0)" }.joined(separator: "\n") }
        if !relevantFiles.isEmpty { s += "\nRelevant files: " + relevantFiles.prefix(10).joined(separator: ", ") }
        return String(s.prefix(3500))
    }
}

struct ReviewResult: Equatable, Sendable {
    var passed: Bool
    var summary: String
    var issues: [String]
    /// Structured issues (severity + evidence). A plain string issue is advice: it names nothing JARVIS can verify.
    var detailed: [ReviewIssue] = []

    static func parse(_ text: String) -> ReviewResult? {
        guard let json = PlanParser.extractJSONObject(text), let d = json.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let verdict = (o["verdict"] as? String)?.lowercased() else { return nil }
        let passed: Bool
        switch verdict { case "pass", "approve", "approved", "ok": passed = true; case "fail", "reject", "rejected", "changes_requested": passed = false; default: return nil }
        var texts: [String] = [], detailed: [ReviewIssue] = []
        for raw in (o["issues"] as? [Any] ?? []) {
            if let s = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                texts.append(s); detailed.append(ReviewIssue(text: s, severity: .advice, evidence: ""))
            } else if let m = raw as? [String: Any], let t = (m["text"] as? String ?? m["issue"] as? String ?? m["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                let sev = IssueSeverity(rawValue: (m["severity"] as? String ?? "").lowercased()) ?? .advice
                texts.append(t); detailed.append(ReviewIssue(text: t, severity: sev, evidence: (m["evidence"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        return ReviewResult(passed: passed, summary: (o["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines), issues: texts, detailed: detailed)
    }
}

// MARK: - Context selection (targeted; never the whole repository)

enum ProjectContext {
    private static let stopwords: Set<String> = ["fix", "the", "and", "for", "with", "that", "this", "from", "into", "make", "test", "tests", "failing", "fails", "failed",
                                                 "issue", "problem", "bug", "please", "should", "would", "could", "run", "running", "when", "then", "than", "task", "project",
                                                 "code", "file", "files", "step", "analysis", "inspect", "review", "check", "using", "use", "all", "any", "not", "are", "was", "you"]

    static func terms(from texts: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for t in texts {
            let re = try! NSRegularExpression(pattern: "[A-Za-z_][A-Za-z0-9_]{3,}")
            for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
                guard let r = Range(m.range, in: t) else { continue }
                let w = String(t[r])
                let l = w.lowercased()
                if stopwords.contains(l) || !seen.insert(l).inserted { continue }
                out.append(w)
            }
        }
        return Array(out.prefix(14))
    }

    /// Project files mentioned (by path or basename) in `texts`.
    static func mentioned(in texts: [String], known: [String]) -> [String] {
        var out: [String] = []
        let blob = texts.joined(separator: "\n")
        for f in known where !out.contains(f) {
            let base = (f as NSString).lastPathComponent
            if blob.contains(f) || (base.count >= 4 && blob.contains(base)) { out.append(f) }
        }
        return out
    }

    /// Mentioned files first, then search hits ranked by hit count, then test files — deterministic and bounded.
    static func selectFiles(tools: ProjectTools, mentionedIn texts: [String], searchTerms: [String], max: Int) async -> [String] {
        let sel: [String]? = try? await Task.detached(priority: .utility) { () throws -> [String] in
            let known = try tools.listFiles(maxFiles: 400)
            var chosen = mentioned(in: texts, known: known)
            let hits = try tools.search(terms: searchTerms, maxHits: 80)
            var score: [String: Int] = [:]
            for h in hits { score[h.path, default: 0] += 1 }
            for (p, _) in score.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) where !chosen.contains(p) { chosen.append(p) }
            for f in known where chosen.count < max && !chosen.contains(f) && (f.contains("test") || f.contains("Test")) { chosen.append(f) }
            return Array(chosen.prefix(max))
        }.value
        return sel ?? []
    }

    static func snapshots(tools: ProjectTools, paths: [String], perFileBytes: Int, totalChars: Int) async -> [FileSnapshot] {
        await Task.detached(priority: .utility) { () -> [FileSnapshot] in
            var out: [FileSnapshot] = [], used = 0
            for p in paths {
                guard let s = try? tools.readFile(p, maxBytes: perFileBytes), used + s.text.count <= totalChars else { continue }
                // Files that look like they contain a credential are never sent to a provider (inputs are scrubbed like outputs).
                if OutputSanitizer.containsSecret(s.text) { continue }
                out.append(s); used += s.text.count
            }
            return out
        }.value
    }

    static func render(_ files: [FileSnapshot]) -> String {
        files.map { f in "=== FILE: \(f.path)\(f.truncated ? " (truncated)" : "") ===\n\(f.text)\n=== END FILE ===" }.joined(separator: "\n\n")
    }
}

// MARK: - Prompts

enum TaskPrompts {
    static func analysis(goal: String, step: TaskStepRecord, tree: String, files: [FileSnapshot], prior: [String]) -> String {
        """
        You are the analysis component of JARVIS, an autonomous task engine. Analyse the project to serve ONE step of a plan. You cannot run commands or change files; you only read what is shown here.

        Overall goal: \(goal)
        Current step: \(step.title)
        Step details: \(step.details)
        Expected outcome: \(step.expected)
        \(prior.isEmpty ? "" : "\nResults of earlier steps:\n" + prior.joined(separator: "\n---\n") + "\n")
        Project files:
        \(tree)

        File contents:
        \(ProjectContext.render(files))

        Reply with ONE JSON object and nothing else:
        {"summary": "2-4 sentences answering the step", "findings": ["concrete, evidence-based observations"], "relevantFiles": ["project-relative paths that matter for the goal"], "rootCause": "the root cause if this step identifies one, otherwise empty"}
        Only state what the shown files and results support. Do not invent files.
        """
    }

    static func codeChange(goal: String, step: TaskStepRecord, analysis: [String], files: [FileSnapshot], failure: String?, previousChange: String?, attempt: AttemptKind) -> String {
        var s = """
        You are the coding component of JARVIS, an autonomous task engine. Implement ONE step by editing project files. You cannot run commands; JARVIS applies your edits and then builds/tests them.

        Overall goal: \(goal)
        Current step: \(step.title)
        Step details: \(step.details)
        \(analysis.isEmpty ? "" : "\nAnalysis so far:\n" + analysis.joined(separator: "\n---\n") + "\n")
        Current file contents (copy text EXACTLY from here):
        \(ProjectContext.render(files))
        """
        if let previousChange, !previousChange.isEmpty {
            s += "\n\nA previous attempt already changed the files like this (current files above already include it):\n\(previousChange)"
        }
        if let failure, !failure.isEmpty {
            s += "\n\nThe project was then built/tested and FAILED (\(attempt == .escalation ? "a different assistant's earlier fix did not work" : "your earlier fix did not work")). Output of the failing command:\n\(failure)\nFix the cause of this failure."
        }
        s += """


        Reply with edit blocks ONLY (no prose before or after, no markdown fences). Use exactly this format.

        To change an existing file — the SEARCH text must appear EXACTLY ONCE in the file (include enough surrounding lines):
        <<<<<<< SEARCH path/to/file.ext
        exact existing text
        =======
        replacement text
        >>>>>>> REPLACE

        To create a new file:
        <<<<<<< CREATE path/to/new_file.ext
        full file content
        >>>>>>> END

        Rules: make the smallest change that achieves the step; do not edit tests unless the goal says the tests are wrong; do not add dependencies; do not touch files that are not shown; never mention shell commands.
        """
        return s
    }

    static func review(goal: String, diff: String, evidence: [String], analysis: [String]) -> String {
        """
        You are the review component of JARVIS, an autonomous task engine. Review the final change for correctness against the goal. You cannot run anything.

        Goal: \(goal)
        \(analysis.isEmpty ? "" : "Analysis: " + analysis.joined(separator: "\n---\n") + "\n")
        Validation evidence collected by JARVIS (real command results):
        \(evidence.isEmpty ? "(none)" : evidence.map { "- \($0)" }.joined(separator: "\n"))

        Change (unified diff):
        \(diff.isEmpty ? "(no files were changed)" : diff)

        Reply with ONE JSON object and nothing else:
        {"verdict": "pass" or "fail", "summary": "one or two sentences",
         "issues": [{"text": "a defect or an improvement", "severity": "blocking" or "advice", "evidence": "an exact quote from the diff or a changed file path that proves it"}],
         "suggestions": [{"title": "optional follow-up that is NOT part of this goal", "summary": "why", "files": ["project-relative paths shown above"], "category": "testCoverage|bug|maintenance|documentation|refactor|performance|design", "designImpact": false}]}
        "suggestions" is optional and at most 2 entries; leave it out unless you noticed something concrete.
        Use "fail" only for a concrete defect that means the goal is not achieved or something is broken, mark it "blocking" and quote the evidence from the diff. Style, naming, test wording and possible improvements are "advice": they never fail the task. JARVIS' own checks (build, tests, Unity compilation/state) are facts you cannot overrule.
        """
    }
}
