import Foundation

// Display-only models for the Full HUD side panels.
// In V0.1 none of these are backed by real systems; the data comes from `Services/Demo`.

enum AgentSlotStatus: String, Sendable {
    case idle, active, standby

    var label: String {
        switch self {
        case .idle: "IDLE"
        case .active: "ACTIVE"
        case .standby: "STANDBY"
        }
    }
}

struct AgentSlot: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var role: String
    var status: AgentSlotStatus
}

enum ToolAvailability: String, Sendable {
    case notConnected

    var label: String { "NOT CONNECTED" }
}

struct ToolSlot: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var availability: ToolAvailability
    /// Roadmap milestone where this tool is expected, e.g. "V0.9".
    var plannedFor: String
}

struct ProjectSummary: Hashable, Sendable {
    var name: String
    var kind: String
    var branch: String
}

/// A request that needs a human decision before work continues.
struct ApprovalRequest: Identifiable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var detail: String
    /// True only for the developer simulator's request: the card then says so. A real request never carries it.
    var simulated = false
}
