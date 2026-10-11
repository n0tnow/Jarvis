import Foundation

/// DEVELOPER-ONLY simulation of agent activity for UI work and performance measurement (V0.3.2 §39).
///  - Every simulated run is flagged `isSimulated` (labelled SIMULATED in the UI) and uses `RunOwner.simulated`.
///  - Nothing is ever written to SQLite or artifacts (the hub skips persistence for simulated consoles), so production history
///    cannot be polluted.
///  - Progress comes from fake but STRUCTURED steps (the same `ProgressCalculator` as real runs); runs without steps stay indeterminate.
///  - The "secret" below is an obviously synthetic fixture, never a real credential; it demonstrates the sanitization boundary.
@MainActor
final class ObservatoryDemo {
    static let syntheticSecretLine = "Authorization: Bearer FAKE-DEMO-TOKEN-0123456789abcdef-NOT-A-REAL-CREDENTIAL"

    private let hub: ExecutionHub
    private var tasks: [UUID: Task<Void, Never>] = [:]
    var activeCount: Int { tasks.count }

    init(hub: ExecutionHub) { self.hub = hub }

    private func register(label: String, agent: String, engine: ProviderID, model: String?, activity: String, steps: [(String, Double)] = []) -> UUID {
        let id = UUID()
        hub.begin(AgentRunView(id: id, label: label, agentType: agent, engine: engine, model: model, parent: nil, phase: .running, startedAt: Date(),
                               activity: activity, owner: .simulated, isSimulated: true))
        hub.emit(id, .warning, source: "SIMULATED", summary: "Developer simulation — not real activity", severity: .warning)
        if !steps.isEmpty { hub.setSteps(id, steps) }
        return id
    }

    /// Claude planner (structured steps ⇒ measurable progress), OpenCode coder (no steps ⇒ indeterminate), Codex reviewer (finished).
    func startShowcase() {
        let planner = register(label: "Multiplayer architecture review", agent: "PlannerAgent", engine: .claudeCode, model: nil, activity: "Inspecting architecture",
                               steps: [("Inspect architecture", 1), ("Reproduce issue", 1), ("Identify root cause", 1), ("Implement fix", 1), ("Review", 1)])
        let coder = register(label: "Fix NetworkThrowable tests", agent: "CodingAgent", engine: .openCode, model: "opencode/space-bunny-free", activity: "Running tests")
        let reviewer = register(label: "NetworkPlayer review", agent: "ReviewAgent", engine: .codex, model: nil, activity: "Reviewing")
        hub.appendOutput(reviewer, "Reviewed 3 files. No blocking issues.\n")
        hub.finish(reviewer, phase: .completed, summary: "Review completed")

        tasks[planner] = Task { @MainActor in
            for step in 0..<5 {
                hub.setStep(planner, index: step, .active)
                for n in 1...6 {
                    guard !Task.isCancelled else { return }
                    hub.appendOutput(planner, "step \(step + 1): analysing ownership model (\(n)/6)\n")
                    if step == 1 && n == 3 { hub.appendOutput(planner, Self.syntheticSecretLine + "\n") }       // must appear redacted
                    try? await Task.sleep(for: .milliseconds(700))
                }
                hub.setStep(planner, index: step, .done)
            }
            hub.finish(planner, phase: .completed)
            self.tasks[planner] = nil
        }
        tasks[coder] = Task { @MainActor in
            var n = 0
            while !Task.isCancelled {
                n += 1
                hub.appendOutput(coder, "test NetworkThrowableTests.case\(n % 12): " + (n % 7 == 0 ? "FAILED expected 4 got 5\n" : "passed\n"))
                if n % 20 == 0 { hub.setActivity(coder, n % 40 == 0 ? "Running tests" : "Applying fix") }
                try? await Task.sleep(for: .milliseconds(450))
            }
        }
    }

    /// One simulated run emitting `linesPerSecond` lines (in 50 ms batches) — for CPU/memory measurement of the console.
    @discardableResult
    func startStress(linesPerSecond: Int = 400, seconds: Double? = nil) -> UUID {
        let id = register(label: "Console stress stream", agent: "StressAgent", engine: .openCode, model: "opencode/simulated", activity: "Streaming")
        tasks[id] = Task { @MainActor in
            var n = 0
            let started = Date()
            let perTick = max(1, linesPerSecond / 20)
            while !Task.isCancelled {
                if let s = seconds, Date().timeIntervalSince(started) > s { break }
                var batch = ""
                for _ in 0..<perTick { n += 1; batch += "stream line \(n): " + String(repeating: "lorem ipsum ", count: 6) + "\n" }
                hub.appendOutput(id, batch)
                try? await Task.sleep(for: .milliseconds(50))
            }
            hub.finish(id, phase: Task.isCancelled ? .cancelled : .completed)
            self.tasks[id] = nil
        }
        return id
    }

    @discardableResult
    func stop(_ runID: UUID) -> Bool {
        guard let t = tasks[runID] else { return false }
        t.cancel(); tasks[runID] = nil
        hub.finish(runID, phase: .cancelled)
        return true
    }

    func stopAll() { for id in Array(tasks.keys) { stop(id) } }
}
