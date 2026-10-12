import Foundation

/// The on-device lightweight model as an `IntelligenceProvider`. Defence in depth: besides the router, the provider itself
/// refuses any task `LocalModelPolicy` forbids (DEC-024), so a routing bug can never hand development work to the 4B model.
struct LocalQwenProvider: IntelligenceProvider {
    let runtime: LocalRuntime
    let profile: TaskProfile
    var maxTokens = 384

    var providerID: ProviderID? { .local }
    var id: String { "local" }
    var displayName: String { "Local Qwen" }
    func supports(_ kind: IntelligenceRequestKind) -> Bool { kind == .reasoning }

    static let instruction = JarvisInstruction.text + " Keep answers short (a few sentences) unless asked otherwise."

    static func prompt(for request: IntelligenceRequest) -> String {
        var parts = ["[Instructions] " + instruction]
        if let pre = ContextBuilder.preface(from: request.history, excluding: request.prompt) { parts.append(pre) }
        parts.append("[Request]\n" + request.providerPrompt)
        return parts.joined(separator: "\n\n")
    }

    func respond(to request: IntelligenceRequest) -> AsyncThrowingStream<IntelligenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let verdict = LocalModelPolicy.evaluate(profile)
            guard verdict.eligible else {
                continuation.finish(throwing: ProviderError.unavailable(.local, "task not allowed on the local model: " + verdict.violations.joined(separator: ",")))
                return
            }
            let task = Task { @MainActor in
                do {
                    for try await event in runtime.generate(prompt: Self.prompt(for: request), maxTokens: maxTokens) {
                        switch event {
                        case .token(let t): continuation.yield(.textDelta(t))
                        case .done(let s): continuation.yield(.usage(input: s.promptTokens, output: s.generationTokens))
                        }
                    }
                    // A cancelled consumer just stops iterating: that is NOT a finished answer.
                    if !Task.isCancelled { continuation.yield(.finished) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
                // `waitUntilStopped` resolves with this task: don't report "stopped" until the worker has really ended the job,
                // or the next request would find the runtime still busy.
                await runtime.waitForJobEnd()
            }
            RunTracker.shared.add(request.id, task)
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func waitUntilStopped(_ requestID: UUID) async { await RunTracker.shared.finish(requestID) }
}
