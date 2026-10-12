import Foundation

/// WHAT the user wants (decided by the router). HOW it is done is `CommandExecutor`'s job.
/// Text, future voice and future LLM tool calls all produce these same values.
enum JarvisIntent: Equatable, Sendable {
    case openSection(HUDSection)      // dashboard · tasks · report · system · memory
    case openSettings
    case showStatus
    case pauseTask
    case resumeTask
    case stopTask
    case openCompactHUD
    case openFullHUD
    case closeHUD
    case clearConversation
    /// Stop an in-flight provider answer (also available as the STOP GENERATION button).
    case cancelGeneration

    /// Human-readable name (never show the enum case to users).
    var displayName: String {
        switch self {
        case .openSection(let s): "Open \(s.title.capitalized)"
        case .openSettings: "Open Settings"
        case .showStatus: "Show status"
        case .pauseTask: "Pause task"
        case .resumeTask: "Resume task"
        case .stopTask: "Stop task"
        case .openCompactHUD: "Open Compact HUD"
        case .openFullHUD: "Open Full HUD"
        case .closeHUD: "Close HUD"
        case .clearConversation: "Clear conversation"
        case .cancelGeneration: "Stop generation"
        }
    }
}

/// Tiny non-LLM social replies (architectural validation only — not a chatbot).
enum LocalReply: Equatable, Sendable { case greeting, thanks, approvalNeedsHUD, memory }

enum UnsupportedReason: Equatable, Sendable { case empty, noContent }

/// WHERE a request should go. The router answers only this; it executes nothing.
enum RouteDecision: Equatable, Sendable {
    case command(JarvisIntent, ReplyLanguage)
    case localResponse(LocalReply, ReplyLanguage)
    /// Needs a reasoning provider (not connected in V0.2).
    case reasoningRequired(prompt: String, ReplyLanguage)
    /// Needs a worker/agent provider (not connected in V0.2).
    case workerRequired(prompt: String, ReplyLanguage)
    case unsupported(UnsupportedReason, ReplyLanguage)

    var kind: RouteKind {
        switch self {
        case .command: .command
        case .localResponse: .local
        case .reasoningRequired: .reasoning
        case .workerRequired: .worker
        case .unsupported: .unsupported
        }
    }
}
