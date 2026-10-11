import Foundation

enum ConversationRole: String, Codable, Sendable { case user, jarvis, system }

/// Lifecycle of a message. `pending`/`streaming` exist so a future intelligence provider can stream into a
/// message; V0.2's deterministic replies are created directly as `complete`.
enum MessageStatus: String, Codable, Sendable { case pending, streaming, complete, failed }

/// Presentation hint only (a refused/impossible request is a `notice`, not a system failure).
enum MessageTone: String, Codable, Sendable { case normal, notice }

/// Which path produced a JARVIS reply (see `IntelligenceRouter`).
enum RouteKind: String, Codable, Sendable { case command, local, reasoning, worker, unsupported }

/// One entry in the conversation. Plain Codable value type so persistence can be added later without UI changes.
struct ConversationMessage: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var role: ConversationRole
    var content: String
    var timestamp: Date = .now
    var status: MessageStatus = .complete
    var tone: MessageTone = .normal
    var route: RouteKind?
    /// Display name of the provider that produced a reasoning reply ("Claude Code", "Codex"); nil for local replies.
    var provider: String?
}
