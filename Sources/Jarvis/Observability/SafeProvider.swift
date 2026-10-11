import Foundation

/// Decorator that puts EVERY provider stream behind the sanitization boundary (V0.3.2, DEC-029).
///
///   Provider / ManagedProcess → raw text → StreamSanitizer → safe events ─┬─► the agent runtime (ConversationService / OneShotRunner)
///                                                                          └─► ExecutionHub (console, timeline, SQLite, artifacts)
///
/// One execution, several observers: this wrapper iterates the provider's single stream once and forwards the SAME sanitized events
/// to both consumers, so observing never starts another process, request or subscription use. Raw text is never forwarded.
struct SafeProvider: IntelligenceProvider {
    let base: any IntelligenceProvider
    let runID: UUID?
    let hub: ExecutionHub?

    var providerID: ProviderID? { base.providerID }
    var id: String { base.id }
    var displayName: String { base.displayName }
    func supports(_ kind: IntelligenceRequestKind) -> Bool { base.supports(kind) }

    private static let tracker = RunTracker()

    func respond(to request: IntelligenceRequest) -> AsyncThrowingStream<IntelligenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                let sanitizer = StreamSanitizer()
                var started = false
                @MainActor func emitText(_ safe: String) {
                    guard !safe.isEmpty else { return }
                    continuation.yield(.textDelta(safe))
                    if let runID { hub?.appendOutput(runID, safe) }
                }
                do {
                    for try await event in base.respond(to: request) {
                        if !started, let runID {
                            started = true
                            hub?.setPhase(runID, .running, activity: "Generating")
                            hub?.emit(runID, .providerStarted, summary: "\(base.displayName) is producing output")
                        }
                        switch event {
                        case .textDelta(let t): emitText(sanitizer.feed(t))
                        case .session: continuation.yield(event)
                        case .usage(let i, let o):
                            continuation.yield(event)
                            if let runID { hub?.setUsage(runID, input: i, output: o) }
                        case .toolAttempt(let name):
                            continuation.yield(event)
                            if let runID { hub?.emit(runID, .toolFinished, summary: "Tool request refused (conversation-only mode): \(name)", severity: .warning) }
                        case .finished:
                            emitText(sanitizer.flush())
                            continuation.yield(.finished)
                        }
                    }
                    if !Task.isCancelled { emitText(sanitizer.flush()) }
                    continuation.finish()
                } catch {
                    if !Task.isCancelled { emitText(sanitizer.flush()) }
                    continuation.finish(throwing: error)
                }
            }
            Self.tracker.add(request.id, task)
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Resolves only after this wrapper's task AND the underlying provider's process/job are gone.
    func waitUntilStopped(_ requestID: UUID) async {
        await Self.tracker.finish(requestID)
        await base.waitUntilStopped(requestID)
    }
}
