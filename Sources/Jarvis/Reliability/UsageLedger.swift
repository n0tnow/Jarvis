import Foundation

// MARK: - Honest usage accounting (V1.0 background pass)
//
// Records what a provider run actually reported: provider, model, request count, input / output tokens WHEN the provider reported them, latency, failure, retry and the task it belonged to. Nothing is
// estimated: a missing token count stays missing (`nil`) and a sum says how many runs had no count. Money is never invented — `estimatedCost` exists only when the CALLER supplies a unit price; otherwise it is
// nil (cost UNKNOWN). Bounded: the newest `capacity` runs are kept, per-provider totals are kept for ever (small). Memory only.

struct UsageRecord: Equatable, Sendable {
    var taskID: UUID?
    var provider: String
    var model: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var latency: TimeInterval?
    var failed: Bool
    var isRetry: Bool
    var at: Date
}

struct UsageTotals: Equatable, Sendable {
    var requests = 0
    var failures = 0
    var retries = 0
    var inputTokens = 0
    var outputTokens = 0
    /// Runs that reported no token count (so a total is a lower bound, never a guess).
    var runsWithoutTokens = 0
    var latencySum: TimeInterval = 0
    var latencyCount = 0
    var meanLatency: TimeInterval? { latencyCount == 0 ? nil : latencySum / Double(latencyCount) }
    /// nil unless the caller supplies a price per 1 000 tokens; never invented.
    func estimatedCost(pricePer1kTokens: Double?) -> Double? { pricePer1kTokens.map { Double(inputTokens + outputTokens) / 1000 * $0 } }
}

struct UsageLedger: Equatable, Sendable {
    private(set) var recent: [UsageRecord] = []
    private(set) var byProvider: [String: UsageTotals] = [:]
    private(set) var byTask: [UUID: UsageTotals] = [:]
    let capacity: Int

    init(capacity: Int = 2_000) { self.capacity = max(10, capacity) }

    mutating func record(_ r: UsageRecord) {
        recent.append(r)
        if recent.count > capacity { recent.removeFirst(recent.count - capacity) }
        func fold(_ t: inout UsageTotals) {
            t.requests += 1
            if r.failed { t.failures += 1 }
            if r.isRetry { t.retries += 1 }
            if r.inputTokens == nil && r.outputTokens == nil { t.runsWithoutTokens += 1 }
            t.inputTokens += r.inputTokens ?? 0; t.outputTokens += r.outputTokens ?? 0
            if let l = r.latency { t.latencySum += l; t.latencyCount += 1 }
        }
        var p = byProvider[r.provider] ?? UsageTotals(); fold(&p); byProvider[r.provider] = p
        if let id = r.taskID { var t = byTask[id] ?? UsageTotals(); fold(&t); byTask[id] = t }
    }

    mutating func forget(task: UUID) { byTask[task] = nil }
}
