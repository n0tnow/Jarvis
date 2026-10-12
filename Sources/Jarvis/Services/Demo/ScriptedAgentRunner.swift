import Foundation

/// DEVELOPER/LIVE-TEST ONLY (lives in Services/Demo: production code never depends on it). A `StepAgentRunner` that answers some job types
/// with canned text — so a live test can drive the REAL Unity editor with a deterministic planner — and hands every other job to the real
/// runner (real routing, real providers). Runs it answers are recorded as tool runs labelled "scripted", never as provider runs.
@MainActor
final class ScriptedAgentRunner: StepAgentRunner {
    var escalationAllowed: Bool { real?.escalationAllowed ?? false }
    private let audit: AuditRecorder
    private let real: (any StepAgentRunner)?
    private let scriptedTypes: Set<String>
    private let script: (AgentJob, Int) -> String?
    private var counts: [String: Int] = [:]
    private(set) var answered: [String] = []

    init(audit: AuditRecorder, real: (any StepAgentRunner)? = nil, scriptedTypes: Set<String>, script: @escaping (AgentJob, Int) -> String?) {
        self.audit = audit; self.real = real; self.scriptedTypes = scriptedTypes; self.script = script
    }

    func run(_ job: AgentJob) async -> AgentJobResult {
        guard scriptedTypes.contains(job.type) || real == nil else { return await real!.run(job) }
        let cand = RoutingCandidate(engine: .tool, model: "scripted")
        let runID = audit.begin(agentType: job.type, taskID: job.taskID, engine: .tool, model: "scripted", decision: nil, prompt: job.prompt, privacy: .normal, label: job.title + " (scripted)", owner: .task)
        let index = counts[job.type, default: 0]; counts[job.type] = index + 1
        answered.append(job.type)
        audit.hub?.setPhase(runID, .running, activity: "Scripted")
        guard let text = script(job, index) else { audit.finish(runID, status: .failed, error: .refused("no scripted answer")); return .failed(runID: runID, error: .generic, validationFailed: false, candidate: cand) }
        if let v = job.validator, !(await v(text)).passed {
            audit.finish(runID, status: .failed, validation: .failed)
            return .failed(runID: runID, error: nil, validationFailed: true, candidate: cand)
        }
        audit.finish(runID, status: .succeeded, resultText: text, validation: job.validator == nil ? .skipped : .passed)
        return .completed(text: text, runID: runID, candidate: cand, validated: job.validator != nil)
    }

    func waitForCapacityChange() async { if let real { await real.waitForCapacityChange() } else { try? await Task.sleep(for: .milliseconds(20)) } }
    func cancel(runID: UUID) { real?.cancel(runID: runID) }
}
