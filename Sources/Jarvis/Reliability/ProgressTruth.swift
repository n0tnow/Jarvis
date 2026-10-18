import Foundation

// MARK: - Progress is structure, never a number a model made up (V1.0 reliability pass)
//
// "Step 3/8 · running", "waiting for your approval", "blocked: …", "verifying". A percentage is shown only when it is DERIVED: validated (passed) steps over measurable steps — the same definition the Tasks
// screen uses ("progress = validated steps only"). A percentage in a model's reply about a task is never evidence: `ResponseClaimFirewall` treats it as an unbacked task claim.

struct ProgressStep: Equatable, Sendable {
    enum State: String, Sendable { case pending, ready, running, verifying, waitingForApproval, passed, failed, skipped, cancelled, interrupted }
    var title: String
    var state: State
}

struct ProgressReport: Equatable, Sendable {
    var total: Int
    var measurable: Int
    var passed: Int
    var currentIndex: Int?
    var currentTitle: String?
    var currentState: ProgressStep.State?
    var blockedReason: String?

    /// nil when nothing is measurable. Derived, never estimated.
    var derivedPercent: Int? { measurable == 0 ? nil : Int((Double(passed) / Double(measurable) * 100).rounded(.down)) }

    static func build(_ steps: [ProgressStep]) -> ProgressReport {
        let measurable = steps.filter { $0.state != .skipped }
        let passed = steps.filter { $0.state == .passed }.count
        let current = steps.firstIndex { [.running, .verifying, .waitingForApproval].contains($0.state) } ?? steps.firstIndex { [.ready, .pending].contains($0.state) }
        var blocked: String?
        if let failed = steps.first(where: { $0.state == .failed }) { blocked = "step failed: \(failed.title)" }
        else if steps.contains(where: { $0.state == .interrupted }) { blocked = "interrupted: resume is an explicit action" }
        return ProgressReport(total: steps.count, measurable: measurable.count, passed: passed, currentIndex: current, currentTitle: current.map { steps[$0].title }, currentState: current.map { steps[$0].state }, blockedReason: blocked)
    }

    func line(language l: ReplyLanguage) -> String {
        guard total > 0 else { return l == .tr ? "Henüz bir plan yok." : "There is no plan yet." }
        if passed == measurable, measurable > 0 { return l == .tr ? "Tüm \(measurable) adım doğrulandı." : "All \(measurable) steps are verified." }
        let index = (currentIndex ?? 0) + 1
        let head = l == .tr ? "Adım \(index)/\(total)" : "Step \(index)/\(total)"
        let state: String
        switch currentState {
        case .running?: state = l == .tr ? "çalışıyor" : "running"
        case .verifying?: state = l == .tr ? "doğrulanıyor" : "verifying"
        case .waitingForApproval?: state = l == .tr ? "onayınızı bekliyor" : "waiting for your approval"
        case .ready?, .pending?: state = l == .tr ? "sırada" : "queued"
        case .failed?: state = l == .tr ? "başarısız" : "failed"
        default: state = l == .tr ? "durdu" : "stopped"
        }
        var s = "\(head) · \(state)"
        if let t = currentTitle { s += " — \(t)" }
        if let b = blockedReason { s += l == .tr ? " (engel: \(b))" : " (blocked: \(b))" }
        s += l == .tr ? " · doğrulanan \(passed)/\(measurable)" : " · verified \(passed)/\(measurable)"
        return s
    }
}
