import Foundation

// MARK: - The ActionReceipt invariant (V1.0 stabilisation fix 4)
//
// NO VERIFIED ACTION → NO COMPLETION CLAIM.
//
// Every action JARVIS performs for the user (launching an application, opening a folder, navigating its own HUD, a Computer Use goal) is described by ONE typed value, `ActionReceipt`.
// The sentence the user hears or reads about an action is produced from the receipt (`ActionPhrasebook.render`) — there is no other path from "I did it" to the screen:
//   PLANNED / RUNNING         → an intention is announced ("Safari'yi açıyorum.")
//   SUCCEEDED + verification  → a completion may be claimed ("Safari açık.")
//   FAILED                    → what failed, truthfully ("Safari'yi açamadım: …")
//   UNVERIFIED                → the request was sent but the result could not be confirmed
//   NEEDS_APPROVAL/CANCELLED  → said as such
// A conversation-only engine (a language model) has no execution path, so a first-person action claim in its text is by construction not backed by a receipt (`ActionClaimGuard`).

enum ActionKind: String, Sendable, Equatable {
    case launchApp, openFolder, navigate, showFullHUD, showCompactHUD, closeHUD, computerGoal, openProject
}

enum ReceiptStatus: String, Sendable, Equatable {
    case planned, running, succeeded, failed, cancelled, needsApproval, unverified
    var isTerminal: Bool { switch self { case .planned, .running: false; default: true } }
}

/// How a result was (or could not be) confirmed. `passed == nil` means "no way to check".
struct ActionVerification: Equatable, Sendable {
    var method: String
    var passed: Bool?
    var detail: String
}

struct ActionReceipt: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: ActionKind
    /// What the action is about, user-facing ("Safari", "System", "Downloads").
    let target: String
    let requestedAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    /// Which code path did it: "NSWorkspace", "JARVIS HUD", "Computer Use".
    let executor: String
    var status: ReceiptStatus
    var verification: ActionVerification?
    /// Bounded error text (never a stack trace, a path outside the user's request or a secret).
    var error: String?
    /// A reference to a result (task id, window id …), if any.
    var resultRef: String?

    init(kind: ActionKind, target: String, executor: String, now: Date = Date()) {
        id = UUID(); self.kind = kind; self.target = target; requestedAt = now; self.executor = executor; status = .planned
    }

    /// Success may be CLAIMED only with a passing verification.
    var successIsClaimable: Bool { status == .succeeded && verification?.passed == true }

    mutating func start(now: Date = Date()) { startedAt = now; status = .running }
    mutating func succeed(_ v: ActionVerification, now: Date = Date()) {
        finishedAt = now; verification = v
        status = v.passed == true ? .succeeded : .unverified           // a success without a passing check is never "succeeded"
    }
    mutating func fail(_ why: String, now: Date = Date()) { finishedAt = now; status = .failed; error = String(why.prefix(200)) }
    mutating func markUnverified(_ v: ActionVerification, now: Date = Date()) { finishedAt = now; verification = v; status = .unverified }
}

/// The user's recent actions (memory only, bounded). Used by diagnostics and by "what did you just do?".
@MainActor
final class ActionLedger {
    static let capacity = 50
    private(set) var receipts: [ActionReceipt] = []
    func record(_ r: ActionReceipt) {
        if let i = receipts.firstIndex(where: { $0.id == r.id }) { receipts[i] = r } else { receipts.append(r) }
        if receipts.count > Self.capacity { receipts.removeFirst(receipts.count - Self.capacity) }
    }
    var last: ActionReceipt? { receipts.last }
}
