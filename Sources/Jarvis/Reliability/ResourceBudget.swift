import Foundation

// MARK: - Resource budgeting for a 16 GB machine (V1.0 reliability pass)
//
// JARVIS shares the Mac with Unity, a browser and Xcode. The existing `ConcurrencyLimits` caps how many workers run; this is the complementary rule about MEMORY: what is allowed to be RESIDENT at once.
// Estimates are DECLARED numbers (the measured peaks of this build on the target machine, see docs/V1_DECISION_INTELLIGENCE_PHASE_B.md), not probes: the planner is pure, takes the components currently
// running and answers "may X start?" with a reason and, when not, what would have to go first. Nothing here loads, unloads or measures anything — and nothing runs while idle.
//   · never two large local models resident (a second load would be an out-of-memory event waiting for the next Unity build);
//   · the total declared resident set stays under `budgetFraction` of physical memory;
//   · memory pressure (warning / critical) forbids starting anything large;
//   · a component that is only needed on demand (Computer Use screenshots, an embedding helper, a speech helper) is "transient": counted only while it runs.

enum ResidentComponent: String, Codable, CaseIterable, Sendable {
    case localModelSmall, localModelLarge, unityEditor, browser, xcode, speechHelper, embeddingHelper, visionHelper, cliProvider, computerUseCapture

    /// Declared peak resident memory in MB (rounded UP from measurements on the 16 GB target; helpers from their setup docs).
    var declaredMB: Int {
        switch self {
        case .localModelSmall: 3_700        // Qwen3.5-4B 4-bit: 3.6 GB measured peak
        case .localModelLarge: 6_500        // Qwen3.5-9B 4-bit: 6.4 GB measured peak (Gemma 4 E4B: 5.5 GB)
        case .unityEditor: 4_000
        case .browser: 2_000
        case .xcode: 3_000
        case .speechHelper: 600
        case .embeddingHelper: 700
        case .visionHelper: 3_000
        case .cliProvider: 300
        case .computerUseCapture: 150
        }
    }
    var isLargeModel: Bool { self == .localModelLarge || self == .visionHelper }
    var isLocalModel: Bool { self == .localModelSmall || self == .localModelLarge }
}

struct BudgetVerdict: Equatable, Sendable {
    var allowed: Bool
    var reason: String
    /// What would have to stop first (empty when allowed).
    var unloadFirst: [ResidentComponent]
}

struct ResourceBudget: Equatable, Sendable {
    var physicalMB = 16 * 1024
    /// The declared resident set may use at most this fraction of physical memory (the OS, JARVIS itself and Unity's own growth need the rest).
    var budgetFraction = 0.75
    /// The OS, JARVIS' own process and the always-on parts (≈ 0.9 GB measured idle ≈ 110 MB app + helpers off).
    var baselineMB = 900

    var limitMB: Int { Int(Double(physicalMB) * budgetFraction) }

    func residentMB(_ running: [ResidentComponent]) -> Int { baselineMB + running.reduce(0) { $0 + $1.declaredMB } }

    func mayStart(_ c: ResidentComponent, running: [ResidentComponent], pressure: MemoryPressureLevel = .normal) -> BudgetVerdict {
        if pressure != .normal, c.declaredMB >= 1_000 { return BudgetVerdict(allowed: false, reason: "memory pressure is \(pressure.rawValue): nothing large starts now", unloadFirst: []) }
        if c.isLocalModel, running.contains(where: \.isLocalModel) {
            let resident = running.filter(\.isLocalModel)
            return BudgetVerdict(allowed: false, reason: "a local model is already resident: only one at a time", unloadFirst: resident)
        }
        if c.isLargeModel, running.contains(where: { $0.isLargeModel && $0 != c }) {
            return BudgetVerdict(allowed: false, reason: "another large model is resident", unloadFirst: running.filter { $0.isLargeModel })
        }
        let total = residentMB(running) + c.declaredMB
        guard total > limitMB else { return BudgetVerdict(allowed: true, reason: "\(total) MB declared of \(limitMB) MB", unloadFirst: []) }
        // what could go: on-demand helpers and the local model first, never the user's own applications
        let candidates: [ResidentComponent] = [.visionHelper, .localModelLarge, .localModelSmall, .embeddingHelper, .speechHelper].filter { running.contains($0) && $0 != c }
        var freed = 0
        var plan: [ResidentComponent] = []
        for k in candidates where total - freed > limitMB { plan.append(k); freed += k.declaredMB }
        if total - freed <= limitMB { return BudgetVerdict(allowed: false, reason: "\(total) MB would exceed \(limitMB) MB; stop these first", unloadFirst: plan) }
        return BudgetVerdict(allowed: false, reason: "\(total) MB would exceed \(limitMB) MB and the rest are the user's own applications", unloadFirst: plan)
    }

    /// The conversational local model that fits next to what is running: the large one only when Unity (or Xcode) is not.
    func preferredLocalModel(running: [ResidentComponent]) -> ResidentComponent? {
        for m in [ResidentComponent.localModelLarge, .localModelSmall] where mayStart(m, running: running.filter { !$0.isLocalModel }).allowed {
            if m == .localModelLarge, running.contains(.unityEditor) || running.contains(.xcode) { continue }
            return m
        }
        return nil
    }
}
