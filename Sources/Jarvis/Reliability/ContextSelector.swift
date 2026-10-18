import Foundation

// MARK: - Context selection and deterministic compaction (V1.0 background pass)
//
// What a model is shown for a long task must be SMALL and must never lose what keeps the task safe. Two layers, kept apart on purpose:
//   INVARIANTS — the objective, the project identity, a pending approval, a failed verification, a critical constraint, a user prohibition. They are structured items, rendered VERBATIM at the top, never
//                dropped, never summarised, never truncated, and never delegated to a language model's summary. If the invariants alone exceed the budget the selection says so (`overBudget`) and keeps them anyway:
//                safety outranks the budget.
//   EVERYTHING ELSE — ranked: the latest tool result, typed referents, project state, the most recent turns, a few memory snippets, then history. Older history is compacted into ONE deterministic line of counts
//                ("11 earlier turns omitted: 4 tool results, 1 correction") — no prose, no model.
// Pure and bounded: the selection is a single sort plus a linear fill (measured by a scaling test).

enum ContextKind: String, Equatable, Sendable, CaseIterable {
    // invariants
    case objective, projectIdentity, pendingApproval, failedVerification, constraint, prohibition
    // ranked
    case toolResult, typedReferent, projectState, recentTurn, memorySnippet, history

    var isInvariant: Bool {
        switch self { case .objective, .projectIdentity, .pendingApproval, .failedVerification, .constraint, .prohibition: true; default: false }
    }
    /// Lower = included first among the non-invariants.
    var rank: Int {
        switch self { case .toolResult: 0; case .typedReferent: 1; case .projectState: 2; case .recentTurn: 3; case .memorySnippet: 4; case .history: 5; default: -1 }
    }
}

struct ContextItem: Equatable, Sendable {
    var kind: ContextKind
    var text: String
    /// Larger = newer / more relevant within its kind (turn index, recency, retrieval score).
    var weight: Double = 0
    var id: String = UUID().uuidString
}

struct ContextSelection: Equatable, Sendable {
    var invariants: [ContextItem]
    var included: [ContextItem]
    var droppedCounts: [ContextKind: Int]
    /// ONE line of counts standing in for omitted history; nil when nothing was omitted.
    var compactionLine: String?
    var usedCharacters: Int
    var budget: Int
    /// The invariants alone exceed the budget: they are kept regardless.
    var overBudget: Bool
}

enum ContextSelector {
    static let maxMemorySnippets = 4
    static let maxRecentTurns = 6
    static let maxToolResultCharacters = 2_000
    static let maxItemCharacters = 600
    static let compactionReserve = 120

    static func select(_ items: [ContextItem], budget: Int) -> ContextSelection {
        let invariants = items.filter { $0.kind.isInvariant }
        let invariantCharacters = invariants.reduce(0) { $0 + $1.text.count + 1 }
        var used = invariantCharacters
        // the one compaction line is part of the budget: room is reserved for it before anything ranked is admitted
        let reserve = items.contains { !$0.kind.isInvariant } ? compactionReserve : 0
        var included: [ContextItem] = []
        var dropped: [ContextKind: Int] = [:]
        // ranked items: by kind rank, then newest / most relevant first; per-kind caps first
        var perKind: [ContextKind: Int] = [:]
        let ranked = items.filter { !$0.kind.isInvariant }.sorted { ($0.kind.rank, -$0.weight) < ($1.kind.rank, -$1.weight) }
        for var item in ranked {
            let cap: Int? = item.kind == .memorySnippet ? maxMemorySnippets : (item.kind == .recentTurn ? maxRecentTurns : nil)
            if let cap, perKind[item.kind, default: 0] >= cap { dropped[item.kind, default: 0] += 1; continue }
            let limit = item.kind == .toolResult ? maxToolResultCharacters : maxItemCharacters
            if item.text.count > limit { item.text = String(item.text.prefix(limit)) + "…" }
            if used + item.text.count + 1 > budget - reserve { dropped[item.kind, default: 0] += 1; continue }
            used += item.text.count + 1; perKind[item.kind, default: 0] += 1
            included.append(item)
        }
        var line: String?
        if !dropped.isEmpty {
            let parts = dropped.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.value) \($0.key.rawValue)" }.joined(separator: ", ")
            line = "[omitted: \(parts)]"
            used += line!.count + 1
        }
        return ContextSelection(invariants: invariants, included: included, droppedCounts: dropped, compactionLine: line, usedCharacters: used, budget: budget, overBudget: invariantCharacters > budget)
    }

    /// The text a model sees: invariants first, verbatim, labelled; then the ranked items; then the one compaction line. Deterministic.
    static func render(_ s: ContextSelection) -> String {
        var out: [String] = []
        if !s.invariants.isEmpty { out.append("[MUST KEEP]"); out += s.invariants.map { "\($0.kind.rawValue): \($0.text)" } }
        if !s.included.isEmpty { out.append("[CONTEXT]"); out += s.included.map { "\($0.kind.rawValue): \($0.text)" } }
        if let l = s.compactionLine { out.append(l) }
        return out.joined(separator: "\n")
    }
}
