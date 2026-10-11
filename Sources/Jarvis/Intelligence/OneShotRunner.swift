import Foundation

struct OneShotResult: Sendable {
    var text = ""
    var firstOutputMS: Double?
    var durationMS: Double = 0
    var inputTokens: Int?
    var outputTokens: Int?
    var toolAttempts: [String] = []
    var error: ProviderError?
    var cancelled = false
    var timedOut = false
    var sessionID: String?

    var succeeded: Bool { error == nil && !cancelled && !timedOut }
}

/// Runs ONE request on ONE provider to completion with a hard time limit and guaranteed teardown
/// (waits until the provider's process is really gone). Used by benchmarks and background agents.
enum OneShotRunner {
    static func run(provider: any IntelligenceProvider, prompt: String, kind: IntelligenceRequestKind = .reasoning,
                    history: [ConversationMessage] = [], timeout: TimeInterval = 120, sessionID: String? = nil) async -> OneShotResult {
        let request = IntelligenceRequest(id: UUID(), kind: kind, prompt: prompt, history: history, language: .en, sessionID: sessionID)
        let started = Date()
        let timedOut = AtomicFlag()
        let consumer = Task { () -> OneShotResult in
            var r = OneShotResult()
            do {
                for try await event in provider.respond(to: request) {
                    switch event {
                    case .textDelta(let t):
                        if r.firstOutputMS == nil { r.firstOutputMS = Date().timeIntervalSince(started) * 1000 }
                        r.text += t
                    case .usage(let i, let o): r.inputTokens = i; r.outputTokens = o
                    case .toolAttempt(let t): r.toolAttempts.append(t)
                    case .session(let s): r.sessionID = s
                    case .finished: break
                    }
                }
            } catch is CancellationError { r.cancelled = true }
            catch let e as ProviderError { if e == .cancelled { r.cancelled = true } else { r.error = e } }
            catch { r.error = .generic }
            if Task.isCancelled && r.error == nil { r.cancelled = true }       // a cancelled stream may just end silently
            return r
        }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled { timedOut.set(); consumer.cancel() }
        }
        // The consumer is unstructured: forward the caller's cancellation (STOP / cancel agent) to it explicitly.
        var result = await withTaskCancellationHandler { await consumer.value } onCancel: { consumer.cancel() }
        watchdog.cancel()
        await provider.waitUntilStopped(request.id)
        result.durationMS = Date().timeIntervalSince(started) * 1000
        if timedOut.value { result.timedOut = true; result.cancelled = false }
        return result
    }
}
