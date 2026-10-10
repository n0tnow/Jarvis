import Foundation

/// The single high-level state JARVIS is in. Every surface (menu bar icon,
/// Compact HUD, Full HUD, core visualization) renders from this one value.
/// Future STT / LLM / agent / task-engine code drives it via `JarvisStore.setState`.
enum JarvisState: String, CaseIterable, Identifiable, Codable, Sendable {
    case idle
    case listening
    case thinking
    case working
    case waitingForApproval
    case completed
    case error

    var id: String { rawValue }

    /// Short uppercase label (never rely on colour alone — this and `symbolName` carry meaning too).
    var label: String {
        switch self {
        case .idle: "IDLE"
        case .listening: "LISTENING"
        case .thinking: "THINKING"
        case .working: "WORKING"
        case .waitingForApproval: "AWAITING APPROVAL"
        case .completed: "COMPLETE"
        case .error: "ERROR"
        }
    }

    /// Compact label for tight chips.
    var shortLabel: String {
        switch self {
        case .waitingForApproval: "APPROVAL"
        default: label
        }
    }

    var summary: String {
        switch self {
        case .idle: "Standing by"
        case .listening: "Listening for input"
        case .thinking: "Processing"
        case .working: "Executing task"
        case .waitingForApproval: "Needs your decision"
        case .completed: "Task finished"
        case .error: "Attention required"
        }
    }

    var symbolName: String {
        switch self {
        case .idle: "circle.dotted"
        case .listening: "waveform"
        case .thinking: "ellipsis.circle"
        case .working: "gearshape.2"
        case .waitingForApproval: "hand.raised"
        case .completed: "checkmark.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    /// States whose visuals keep moving. Used to decide whether any animation timer is needed.
    var isAnimated: Bool {
        switch self {
        case .listening, .thinking, .working: true
        default: false
        }
    }
}
