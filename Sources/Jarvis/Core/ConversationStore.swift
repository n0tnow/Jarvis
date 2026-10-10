import Foundation
import Observation

/// Current-session conversation (in-memory in V0.2; the messages are Codable so persistence can be added later).
/// Separate from the activity feed: this is dialogue, that is system events.
@MainActor
@Observable
final class ConversationStore {
    static let capacity = 500
    /// Longest user message kept (longer input is truncated, not rejected).
    static let maxMessageLength = 4000

    private(set) var messages: [ConversationMessage] = []

    init() {}

    @discardableResult
    func appendUser(_ text: String) -> ConversationMessage {
        append(ConversationMessage(role: .user, content: String(text.prefix(Self.maxMessageLength))))
    }

    @discardableResult
    func appendJarvis(_ text: String, tone: MessageTone = .normal, route: RouteKind? = nil,
                      status: MessageStatus = .complete) -> ConversationMessage {
        append(ConversationMessage(role: .jarvis, content: text, status: status, tone: tone, route: route))
    }

    // MARK: Streaming-ready API (used by intelligence providers; no fake streaming in V0.2)

    /// Starts an empty JARVIS message in `.pending`; returns its id for later updates.
    func beginJarvisResponse(route: RouteKind) -> UUID {
        append(ConversationMessage(role: .jarvis, content: "", status: .pending, route: route)).id
    }

    func appendDelta(_ id: UUID, _ text: String) {
        update(id) { $0.content += text; $0.status = .streaming }
    }

    func finish(_ id: UUID) {
        update(id) { $0.status = .complete }
    }

    func fail(_ id: UUID, reason: String) {
        update(id) {
            if $0.content.isEmpty { $0.content = reason }
            $0.status = .failed
            $0.tone = .notice
        }
    }

    /// A cancelled response keeps whatever streamed so far and is marked complete-with-notice.
    func markCancelled(_ id: UUID) {
        update(id) {
            if $0.content.isEmpty { $0.content = "Cancelled." }
            $0.status = .complete
            $0.tone = .notice
        }
    }

    func clear() { messages.removeAll() }

    var last: ConversationMessage? { messages.last }

    // MARK: Internals

    private func append(_ message: ConversationMessage) -> ConversationMessage {
        messages.append(message)
        if messages.count > Self.capacity { messages.removeFirst(messages.count - Self.capacity) }
        return message
    }

    private func update(_ id: UUID, _ body: (inout ConversationMessage) -> Void) {
        guard let idx = messages.lastIndex(where: { $0.id == id }) else { return }
        body(&messages[idx])
    }
}
