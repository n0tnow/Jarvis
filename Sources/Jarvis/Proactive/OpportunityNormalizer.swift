import Foundation

/// Deterministic normalisation, similarity, deduplication and coalescing of opportunities. No model is needed for correctness:
/// "NetworkPlayer lacks null guard." and "Missing nil protection in NetworkPlayer" normalise to the same token set.
enum OpportunityNormalizer {
    private static let synonyms: [String: String] = [
        "nil": "null", "none": "null", "null": "null", "nullable": "null", "nullptr": "null", "optional": "null",
        "guard": "guard", "protection": "guard", "protect": "guard", "check": "guard", "checks": "guard", "safety": "guard", "validation": "guard", "validate": "guard", "handling": "guard",
        "lacks": "missing", "lack": "missing", "lacking": "missing", "missing": "missing", "without": "missing", "absent": "missing", "no": "missing", "not": "missing",
        "unprotected": "missing", "unguarded": "missing", "unchecked": "missing",
        "test": "test", "tests": "test", "testing": "test", "coverage": "test", "spec": "test", "specs": "test", "regression": "test", "unittest": "test",
        "bug": "defect", "defect": "defect", "issue": "defect", "problem": "defect", "error": "defect", "fault": "defect",
        "duplicate": "duplicate", "duplicated": "duplicate", "duplication": "duplicate", "repeated": "duplicate",
    ]
    private static let stop: Set<String> = ["the", "a", "an", "in", "of", "for", "to", "is", "are", "was", "were", "be", "there", "has", "have", "had", "add", "adds", "adding", "needs",
                                           "need", "should", "would", "could", "this", "that", "it", "its", "on", "at", "by", "with", "and", "or", "new", "some", "any", "when", "which",
                                           "from", "into", "after", "before", "also", "still", "more", "one", "case", "cases", "task", "code"]

    /// Identifier-aware tokens: camelCase/snake_case/path pieces split, lowercase, synonyms folded, stop words dropped.
    static func tokens(_ text: String) -> Set<String> {
        var out = Set<String>()
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            let w = word.lowercased(); word = ""
            guard w.count > 1, !stop.contains(w) else { return }
            if let s = synonyms[w] { out.insert(s); return }
            var stem = w
            for suffix in ["ing", "ed", "es", "s"] where stem.count > suffix.count + 3 && stem.hasSuffix(suffix) { stem.removeLast(suffix.count); break }
            out.insert(synonyms[stem] ?? stem)
        }
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            if ch.isLetter || ch.isNumber {
                // camelCase boundary: lower→Upper
                if ch.isUppercase, i > 0, chars[i - 1].isLowercase { flush() }
                word.append(ch)
            } else { flush() }
        }
        flush()
        return out
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        let inter = a.intersection(b).count, uni = a.union(b).count
        return uni == 0 ? 0 : Double(inter) / Double(uni)
    }

    static func normalizedScope(_ paths: [String]) -> [String] {
        Array(Set(paths.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased() }.filter { !$0.isEmpty })).sorted()
    }

    /// Findings that are "the same kind of thing" are compared with each other; unrelated groups never merge.
    static func group(_ c: OpportunityCategory) -> String {
        switch c {
        case .bug, .maintenance, .refactor, .configuration: "code"
        case .testCoverage: "test"
        case .documentation: "docs"
        case .security: "security"
        case .performance: "performance"
        case .design, .gameplay, .asset: "design"
        case .dependency: "dependency"
        }
    }

    /// Stable key: project + group + scope + finding tokens. Equal keys ⇒ the same opportunity.
    static func dedupKey(project: String, category: OpportunityCategory, scope: [String], title: String, summary: String = "") -> String {
        let toks = tokens(title).sorted().joined(separator: ",")
        let raw = "\(project.lowercased())|\(group(category))|\(normalizedScope(scope).joined(separator: ","))|\(toks)"
        return String(Redactor.sha256(Data(raw.utf8)).prefix(32))
    }

    /// Same project, same group, overlapping (or both-empty) scope, and equal key or token similarity ≥ 0.6.
    static func isDuplicate(project: String, category: OpportunityCategory, scope: [String], title: String,
                            of existing: OpportunityRecord) -> Bool {
        guard existing.projectRoot == project, group(existing.category) == group(category) else { return false }
        let a = Set(normalizedScope(scope)), b = Set(normalizedScope(existing.affectedScope))
        let scopesCompatible = (a.isEmpty && b.isEmpty) || !a.intersection(b).isEmpty
        guard scopesCompatible else { return false }
        if existing.dedupKey == dedupKey(project: project, category: category, scope: scope, title: title) { return true }
        return jaccard(tokens(title), tokens(existing.title)) >= 0.6
    }

    /// A finding of an easy-to-merge kind about the same file as a proposal the user already denied/dismissed (still in cooldown) is the
    /// same ask in different words: it is suppressed, not proposed again.
    static func shouldSuppress(project: String, category: OpportunityCategory, scope: [String], whileCoolingDown existing: OpportunityRecord) -> Bool {
        guard existing.projectRoot == project, existing.status.isClosedByUser, category == existing.category, [.testCoverage, .documentation, .maintenance].contains(category) else { return false }
        let a = Set(normalizedScope(scope)), b = Set(normalizedScope(existing.affectedScope))
        return !a.isEmpty && !a.intersection(b).isEmpty
    }

    /// Several findings of the same easy-to-merge kind about the same primary file are ONE proposal (one approval card),
    /// e.g. three missing tests around the same fix. Unrelated issues are never merged.
    static func shouldCoalesce(project: String, category: OpportunityCategory, scope: [String], into existing: OpportunityRecord, originTaskID: UUID? = nil) -> Bool {
        // an opportunity whose task already exists absorbs further findings of the SAME originating task (they describe the work in progress)
        let sameWork = existing.status == .taskCreated && originTaskID != nil && existing.originTaskID == originTaskID
        guard existing.projectRoot == project, existing.status.isOpen || sameWork, category == existing.category,
              [.testCoverage, .documentation, .maintenance].contains(category) else { return false }
        let a = Set(normalizedScope(scope)), b = Set(normalizedScope(existing.affectedScope))
        return !a.isEmpty && !a.intersection(b).isEmpty
    }
}
