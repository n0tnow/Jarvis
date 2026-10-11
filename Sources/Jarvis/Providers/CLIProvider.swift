import Foundation

/// Subscription-backed provider that drives the user's own, unmodified CLI (Claude Code / Codex) as a child process.
/// Conversation-only: tools disabled / read-only (see `CLIProviderSpec`). JARVIS never reads or stores credentials.
struct CLIProvider: IntelligenceProvider {
    let spec: CLIProviderSpec
    let executablePath: String
    let workingDirectory: String
    var environment: [String: String]
    var idleTimeout: TimeInterval = 120
    var totalTimeout: TimeInterval = 900

    var providerID: ProviderID? { spec.id }
    var id: String { spec.id.rawValue }
    var displayName: String { spec.id.displayName }

    /// V0.3 is conversational only: `.worker` requests are never sent to a provider (autonomous work is V0.4).
    func supports(_ kind: IntelligenceRequestKind) -> Bool { kind == .reasoning }

    func respond(to request: IntelligenceRequest) -> AsyncThrowingStream<IntelligenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.run(request, continuation) }
            RunTracker.shared.add(request.id, task)
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Resolves only when the run for `requestID` — including killing and reaping its process — has fully finished.
    func waitUntilStopped(_ requestID: UUID) async {
        await RunTracker.shared.finish(requestID)
    }

    // MARK: Run

    private final class Activity: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date()
        func touch() { lock.lock(); last = Date(); lock.unlock() }
        var idleFor: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
    }

    private func run(_ request: IntelligenceRequest, _ out: AsyncThrowingStream<IntelligenceEvent, Error>.Continuation) async {
        var sessionID = request.sessionID
        for attempt in 0..<2 {
            let outcome = await runOnce(request, sessionID: sessionID, out: out)
            switch outcome {
            case .done:
                out.finish(); return
            case .failed(let error):
                // A stale session (provider restarted, history pruned): retry ONCE as a fresh session with bounded context.
                if case .sessionLost = error, attempt == 0, sessionID != nil { sessionID = nil; continue }
                out.finish(throwing: error); return
            case .cancelled:
                out.finish(throwing: CancellationError()); return
            }
        }
    }

    private enum Outcome { case done, failed(ProviderError), cancelled }

    private func runOnce(_ request: IntelligenceRequest, sessionID: String?,
                         out: AsyncThrowingStream<IntelligenceEvent, Error>.Continuation) async -> Outcome {
        let newID = UUID().uuidString.lowercased()
        var effective = request
        effective.sessionID = sessionID
        let args = spec.arguments(sessionID: sessionID, newSessionID: newID, workingDirectory: workingDirectory)
        let prompt = Data(spec.stdinPrompt(for: effective).utf8)

        // Cancelled while still resolving/queued (STOP pressed before launch): never start the CLI or spend quota.
        if Task.isCancelled { return .cancelled }
        try? FileManager.default.createDirectory(atPath: workingDirectory, withIntermediateDirectories: true)
        let proc = ManagedProcess(executable: executablePath, arguments: args, environment: environment, workingDirectory: workingDirectory)
        let stream: AsyncStream<Data>
        do { stream = try proc.start(stdin: prompt) } catch {
            Log.providers.error("\(spec.id.rawValue, privacy: .public): launch failed")
            return .failed(.notInstalled(spec.id))
        }
        if sessionID == nil, let chosen = spec.chosenSessionID(newSessionID: newID) { out.yield(.session(chosen)) }

        let parser = spec.makeParser()
        let activity = Activity()
        let started = Date()
        let timedOut = AtomicFlag()

        // Watchdog: idle + total time limits (never a busy loop: 1 s granularity).
        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                if activity.idleFor > idleTimeout || Date().timeIntervalSince(started) > totalTimeout {
                    timedOut.set()
                    await proc.cancel()
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        var finished = false, emitted = false
        var failure: ProviderError?
        let userCancelled = AtomicFlag()    // ONLY a consumer cancel (STOP GENERATION) — not our own cleanup of a lingering process

        await withTaskCancellationHandler {
            for await line in stream {
                activity.touch()
                for event in parser.parse(line: line) {
                    switch event {
                    case .session(let s): out.yield(.session(s))
                    case .text(let t): emitted = true; out.yield(.textDelta(t))
                    case .rateLimited(let reset): failure = failure ?? .rateLimited(spec.id, resetsAt: reset)
                    case .failure(let e): failure = e
                    case .usage(let i, let o): out.yield(.usage(input: i, output: o))
                    case .toolAttempt(let t): out.yield(.toolAttempt(t))
                    case .finished: finished = true
                    }
                }
            }
        } onCancel: {
            userCancelled.set()
            Task.detached { await proc.cancel() }          // not a child of the cancelled task
        }

        // stdout is closed; the process normally exits within milliseconds. Give it a moment, then make sure it is
        // really gone before reporting anything (no zombies / orphans).
        // Teardown runs SHIELDED: in a cancelled task `Task.sleep` returns immediately, which would turn these waits into a
        // busy loop and collapse the SIGINT→SIGTERM→SIGKILL grace periods.
        let natural = finished ? 5.0 : 3.0
        await Task.detached {
            if !(await Self.waitForExit(proc, timeout: natural)) { await proc.cancel() }
        }.value
        let code = await proc.waitForExit()
        let stderr = proc.stderrTail

        if userCancelled.value || Task.isCancelled { return .cancelled }
        if timedOut.value { return .failed(.timedOut(spec.id)) }
        if let failure, !(finished && emitted && !isHard(failure)) {
            Log.providers.error("\(spec.id.rawValue, privacy: .public): failed (\(String(describing: failure), privacy: .public)) exit=\(code)")
            return .failed(failure)
        }
        if !finished && finalFailureIsNil(parser, code, stderr) && parser.completedOnCleanExit(exitCode: code) {
            out.yield(.finished)                                     // a clean exit with a complete answer stands in for the missing terminal event
            return .done
        }
        if !finished {
            let err = parser.finalFailure(exitCode: code, stderrTail: stderr)
                ?? (parser.malformedLines > 0 && !emitted ? .malformedOutput(spec.id) : .processFailed(spec.id, exitCode: code))
            Log.providers.error("\(spec.id.rawValue, privacy: .public): ended without a result, exit=\(code), stderr bytes=\(stderr.utf8.count)")
            return .failed(err)
        }
        return .done
    }

    private func finalFailureIsNil(_ parser: ProviderLineParser, _ code: Int32, _ stderr: String) -> Bool { parser.finalFailure(exitCode: code, stderrTail: stderr) == nil }

    /// A rate-limit *warning* seen mid-stream must not discard a completed answer.
    private func isHard(_ e: ProviderError) -> Bool {
        if case .rateLimited = e { return false }
        return true
    }

    private static func waitForExit(_ p: ManagedProcess, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if !p.isRunning { return true }; try? await Task.sleep(for: .milliseconds(25)) }
        return !p.isRunning
    }
}

final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Tracks the Task behind each in-flight provider run so a cancel can be awaited to completion.
final class RunTracker: @unchecked Sendable {
    static let shared = RunTracker()
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func add(_ id: UUID, _ task: Task<Void, Never>) { lock.lock(); tasks[id] = task; lock.unlock() }

    private func take(_ id: UUID) -> Task<Void, Never>? { lock.lock(); defer { lock.unlock() }; return tasks[id] }
    private func remove(_ id: UUID) { lock.lock(); tasks[id] = nil; lock.unlock() }

    func finish(_ id: UUID) async {
        await take(id)?.value
        remove(id)
    }
}
