import Foundation
import Observation

// MARK: - Descriptor / result

/// A bounded, one-shot unit of background work (V0.3.1 foundation — NOT the V0.4 autonomous task engine: no planning, no
/// tool use, no file writes, no open-ended loops). The result is text plus a validation verdict.
struct AgentDescriptor: Sendable {
    var type: String                                   // "ResearchAgent", "BenchmarkAgent", …
    var prompt: String
    var profile: TaskProfile
    var taskID: UUID?
    var parentRunID: UUID?
    var preference: ProviderPreference?                // nil = the user's current setting
    var validator: (@Sendable (String) async -> BenchmarkSuite.Verdict)?
    var timeout: TimeInterval = 180
    /// Prepend a small, bounded memory preface about `taskID` (ContextRetrieval). Never the full history.
    var includeTaskContext = true
    /// What the agent is working on (shown in the Observatory). Optional; sanitized.
    var title: String?
    /// Measurable structured steps (title, weight). The ONLY source of progress: none given ⇒ indeterminate.
    var steps: [(String, Double)] = []
    /// V0.4: who owns the run in the Observatory (a task step is owned by the task engine, so Stop cancels the task).
    var owner: RunOwner = .agent
    /// V0.4 task-level escalation: candidates that must NOT be used (they already failed this step).
    var exclude: Set<RoutingCandidate> = []
    /// V0.4 task-level repair: use exactly this candidate (it must still be an eligible routing result) — no substitution.
    var pin: RoutingCandidate?
    /// Per-descriptor override of the repair/escalation budget (the task engine owns the bigger loop).
    var policy: EscalationPolicy?
    /// V0.12: only candidates with qualifying recorded evidence for this ROLE benchmark may serve the job (Auto only; see `RoleEvidence`).
    var requireRoleEvidence: String?
}

/// Retry/escalation are bounded and configurable (DEC-026): never an open loop.
struct EscalationPolicy: Equatable, Sendable {
    var maxRepairAttempts = 1          // re-ask the SAME engine after a validation failure
    var maxEscalations = 1             // hand over to the next eligible engine
    var maxTotalAttempts = 3           // hard cap on provider invocations for one descriptor
}

enum AgentRejection: Equatable, Sendable {
    case tooManyBackgroundAgents(Int)
    case tooManyFreeCloudAgents(Int)
    case localInferenceBusy
    case tooManyHeavyAgents(Int)
    case recursionNotAllowed
    case tooManyChildren(Int)
    case noEligibleProvider(String)
}

enum AgentRunResult: Equatable, Sendable {
    case completed(text: String, runID: UUID, engine: ProviderID, model: String?, validation: ValidationStatus, escalations: Int)
    case failed(runID: UUID?, error: ProviderError?, validation: ValidationStatus)
    case cancelled(runID: UUID?)
    case rejected(AgentRejection)

    var isCompleted: Bool { if case .completed = self { return true }; return false }
}

struct ActiveAgent: Identifiable, Equatable, Sendable {
    let id: UUID                       // agent_run id
    var type: String
    var engine: ProviderID
    var model: String?
    var startedAt: Date
    var parent: UUID?
    var isHeavy: Bool
}

// MARK: - Manager

/// The engine slot currently held by one descriptor (moves when it escalates).
final class SlotBox { var candidate: RoutingCandidate? }

@MainActor
@Observable
final class AgentRunManager {
    let coordinator: IntelligenceCoordinator
    let resources: ResourceManager
    private(set) var active: [ActiveAgent] = []
    var policy = EscalationPolicy()
    @ObservationIgnored var onEvent: ((String) -> Void)?
    /// tracking id → the task executing a descriptor; `runTracking` maps each audit run id to its tracking id.
    @ObservationIgnored private var tasks: [UUID: Task<AgentRunResult, Never>] = [:]
    @ObservationIgnored private var runTracking: [UUID: UUID] = [:]
    @ObservationIgnored private var cancelRequested = Set<UUID>()
    /// Authoritative counters. Slots are CLAIMED synchronously at decision time (never inferred from `active`, which is only
    /// filled once a task starts) so concurrent spawns can never all pass the same limit check.
    @ObservationIgnored private var totalSlots = 0
    @ObservationIgnored private var engineSlots: [ProviderID: Int] = [:]
    @ObservationIgnored private var heavySlots = 0
    @ObservationIgnored private var reservedByParent: [UUID: Int] = [:]
    @ObservationIgnored private var capacityWaiters: [(id: UUID, cont: CheckedContinuation<Void, Never>)] = []

    var limits: ConcurrencyLimits { resources.limits }

    init(coordinator: IntelligenceCoordinator, resources: ResourceManager) { self.coordinator = coordinator; self.resources = resources }

    var audit: AuditRecorder { coordinator.audit }

    private func isHeavy(_ c: RoutingCandidate, _ p: TaskProfile) -> Bool { (c.engine == .claudeCode || c.engine == .codex) && p.isDevelopment }

    private func block(for c: RoutingCandidate, profile: TaskProfile) -> AgentRejection? {
        switch c.engine {
        case .openCode where engineSlots[.openCode, default: 0] >= limits.maxConcurrentFreeCloudAgents: return .tooManyFreeCloudAgents(limits.maxConcurrentFreeCloudAgents)
        case .local where engineSlots[.local, default: 0] >= limits.maxLocalInferenceJobs: return .localInferenceBusy
        default: break
        }
        if isHeavy(c, profile) && heavySlots >= limits.maxHeavyCodingAgents { return .tooManyHeavyAgents(limits.maxHeavyCodingAgents) }
        return nil
    }
    private func claim(_ c: RoutingCandidate, _ p: TaskProfile) { engineSlots[c.engine, default: 0] += 1; if isHeavy(c, p) { heavySlots += 1 }; publishActivity() }
    private func release(_ c: RoutingCandidate, _ p: TaskProfile) { engineSlots[c.engine, default: 1] -= 1; if isHeavy(c, p) { heavySlots -= 1 }; publishActivity() }
    private func publishActivity() {
        resources.setActivity(localJobs: engineSlots[.local, default: 0], heavyAgents: heavySlots, backgroundAgents: totalSlots)
    }

    // MARK: Spawn

    func spawn(_ d: AgentDescriptor) async -> AgentRunResult {
        // --- structural limits (synchronous, before any await) ---
        if let parent = d.parentRunID {
            let parentRecord = audit.record(parent) ?? ((try? audit.repository?.agentRun(parent)) ?? nil)
            let parentDepth = parentRecord?.parentAgentRunID == nil ? 0 : 1
            if parentDepth + 1 > limits.maxDepth { return .rejected(.recursionNotAllowed) }
            let existing = ((try? audit.repository?.children(of: parent)) ?? []).count
            if existing + (reservedByParent[parent] ?? 0) >= limits.maxChildrenPerParent { return .rejected(.tooManyChildren(limits.maxChildrenPerParent)) }
        }
        if totalSlots >= limits.maxBackgroundAgents { return .rejected(.tooManyBackgroundAgents(limits.maxBackgroundAgents)) }
        totalSlots += 1; publishActivity()
        if let p = d.parentRunID { reservedByParent[p, default: 0] += 1 }
        let slot = SlotBox()
        defer {
            if let c = slot.candidate { release(c, d.profile) }
            totalSlots -= 1; publishActivity()
            if let p = d.parentRunID { reservedByParent[p, default: 1] -= 1 }
            wakeCapacityWaiters()
        }

        // --- route ---
        let decision = await coordinator.route(d.profile, preference: d.preference)
        guard let selected = decision.selected else {
            return .rejected(.noEligibleProvider(decision.refusalMessage() ?? "no provider"))
        }
        // Task-level escalation/repair: drop the candidates that already failed this step / keep only the pinned one. In an explicit
        // (non-Auto) mode there is nothing to escalate to: the exclusion simply leaves no candidate.
        var ordered = [selected] + decision.fallbacks
        if let pin = d.pin { ordered = ordered.filter { $0 == pin } }
        if !d.exclude.isEmpty { ordered = ordered.filter { !d.exclude.contains($0) } }
        guard !ordered.isEmpty else { return .rejected(.noEligibleProvider("no further provider is eligible for this step")) }
        if let role = d.requireRoleEvidence, decision.mode == .auto {
            let repo = audit.repository
            ordered = ordered.filter { RoleEvidence.qualifies($0, role: role, results: (try? repo?.benchmarks(modelID: RoleEvidence.benchmarkKey($0))) ?? []) }
            guard !ordered.isEmpty else { return .rejected(.noEligibleProvider("no eligible provider has passed the \(role) role benchmark for this security-relevant work")) }
        }
        // Capacity-aware, policy-ordered: the first candidate that has a free slot is CLAIMED immediately.
        var candidates: [RoutingCandidate] = []
        var firstRejection: AgentRejection?
        for c in ordered {
            if let why = block(for: c, profile: d.profile) {
                firstRejection = firstRejection ?? why
            } else if slot.candidate == nil {
                claim(c, d.profile); slot.candidate = c; candidates.append(c)
            } else { candidates.append(c) }
            if decision.mode != .auto { break }                 // explicit modes: exactly one engine, no substitution
        }
        guard slot.candidate != nil else { return .rejected(firstRejection ?? .noEligibleProvider("no capacity")) }

        let tracking = UUID()
        let task = Task { @MainActor in await self.execute(d, decision: decision, candidates: candidates, slot: slot, trackingID: tracking) }
        tasks[tracking] = task
        // The execution Task is unstructured: forward the caller's cancellation (task STOP) so the provider process really dies.
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        tasks[tracking] = nil
        cancelRequested.remove(tracking)
        return result
    }

    // MARK: Execution (bounded attempts)

    private func execute(_ d: AgentDescriptor, decision: RoutingDecision, candidates: [RoutingCandidate], slot: SlotBox, trackingID: UUID) async -> AgentRunResult {
        let policy = d.policy ?? self.policy
        var index = 0
        var attempts = 0
        var escalations = 0
        var repairsLeft = policy.maxRepairAttempts
        var basePrompt = d.prompt
        if d.includeTaskContext, let pre = ContextRetrieval(repository: audit.repository).preface(taskID: d.taskID) { basePrompt = pre + "\n\n---\n\n" + d.prompt }
        var prompt = basePrompt
        var previousEngine: ProviderID?
        var lastRunID: UUID?
        var lastError: ProviderError?
        var lastValidation = ValidationStatus.notRun

        while index < candidates.count, attempts < policy.maxTotalAttempts {
            let candidate = candidates[index]
            // The first candidate's slot was claimed by `spawn`; escalation targets claim theirs here (skipped if full).
            if slot.candidate != candidate {
                if let why = block(for: candidate, profile: d.profile) { lastError = .unavailable(candidate.engine, "\(why)"); index += 1; continue }
                if let old = slot.candidate { release(old, d.profile) }
                claim(candidate, d.profile); slot.candidate = candidate
            }
            guard let resolved = coordinator.makeResolved(candidate, decision: decision, profile: d.profile, prompt: d.prompt, depth: escalations,
                                                          agentType: d.type, taskID: d.taskID, parent: d.parentRunID, escalatedFrom: previousEngine,
                                                          label: d.title, owner: d.owner),
                  let runID = resolved.runID else { index += 1; continue }
            lastRunID = runID
            active.append(ActiveAgent(id: runID, type: d.type, engine: candidate.engine, model: candidate.model, startedAt: Date(), parent: d.parentRunID,
                                      isHeavy: isHeavy(candidate, d.profile)))
            runTracking[runID] = trackingID
            if !d.steps.isEmpty { audit.hub?.setSteps(runID, d.steps) }
            onEvent?("\(d.type) started using \(resolved.name)")
            audit.activity("agent", "\(d.type) started using \(resolved.name)", runID: runID, taskID: d.taskID)

            // The same engine may be asked again after a failed validation (bounded repair).
            var lastResult = OneShotResult()
            var closed = false                                              // the audit row of this run has been finalised
            repairLoop: while attempts < policy.maxTotalAttempts {
                attempts += 1
                coordinator.providerStarted(resolved.id)
                let result = await OneShotRunner.run(provider: resolved.provider, prompt: prompt, timeout: d.timeout)
                lastResult = result
                coordinator.providerFinished(resolved.id, outcome: result.cancelled ? .cancelled : (result.error.map { .failed($0) } ?? .completed))

                if result.cancelled || cancelRequested.contains(trackingID) || Task.isCancelled {
                    finish(runID, resolved, .cancelled, result); closed = true
                    return .cancelled(runID: runID)
                }
                lastError = result.timedOut ? .timedOut(candidate.engine) : result.error
                guard result.succeeded else {
                    finish(runID, resolved, .failed(lastError ?? .generic), result); closed = true
                    break repairLoop                                       // engine failed → escalate to the next candidate
                }
                if let validator = d.validator {
                    audit.hub?.setPhase(runID, .verifying, activity: "Validating output")
                    audit.hub?.emit(runID, .validationStarted, source: "JARVIS", summary: "Validating the answer")
                    let v = await validator(result.text)
                    audit.hub?.emit(runID, .validationFinished, source: "JARVIS", summary: v.passed ? "Validation passed" : "Validation failed: \(v.detail)", severity: v.passed ? .success : .warning)
                    lastValidation = v.passed ? .passed : .failed
                    if !v.passed {
                        audit.update(runID) { $0.validationStatus = .failed; $0.retryCount += 1 }
                        if repairsLeft > 0 {
                            repairsLeft -= 1
                            audit.hub?.noteRetry(runID, count: audit.record(runID)?.retryCount ?? 1)
                            audit.hub?.setPhase(runID, .running, activity: "Repair attempt")
                            prompt = "Your previous answer did not pass validation (\(v.detail)). Answer again, following the original instructions exactly.\n\nOriginal task:\n\(basePrompt)"
                            continue repairLoop
                        }
                        finish(runID, resolved, .completed, result, validation: .failed, overrideStatus: .failed); closed = true
                        lastError = nil
                        break repairLoop                                   // validation failed for good → escalate
                    }
                }
                let validation: ValidationStatus = d.validator == nil ? .skipped : .passed
                finish(runID, resolved, .completed, result, validation: validation); closed = true
                return .completed(text: result.text, runID: runID, engine: candidate.engine, model: candidate.model, validation: validation, escalations: escalations)
            }
            // The attempt budget ran out while a repair was still pending: finalise the run honestly as failed validation.
            if !closed { finish(runID, resolved, .completed, lastResult, validation: .failed, overrideStatus: .failed); lastError = nil }
            // --- escalate (bounded; Auto only) ---
            previousEngine = candidate.engine
            guard escalations < policy.maxEscalations, decision.mode == .auto else { break }
            escalations += 1
            index += 1
            repairsLeft = policy.maxRepairAttempts
            prompt = basePrompt
            if index < candidates.count {
                audit.update(runID) { $0.escalatedTo = candidates[index].engine.rawValue; $0.status = .escalated }
                audit.hub?.noteEscalation(runID, from: candidate.engine.displayName, to: candidates[index].engine.displayName)
                onEvent?("Escalated to \(candidates[index].engine.displayName)")
                audit.activity("escalation", "\(d.type) escalated from \(candidate.engine.displayName) to \(candidates[index].engine.displayName)", runID: runID, taskID: d.taskID)
            }
        }
        return .failed(runID: lastRunID, error: lastError, validation: lastValidation)
    }

    private func finish(_ runID: UUID, _ resolved: ResolvedProvider, _ outcome: ProviderOutcome, _ result: OneShotResult,
                        validation: ValidationStatus? = nil, overrideStatus: AgentRunStatus? = nil) {
        active.removeAll { $0.id == runID }
        runTracking[runID] = nil
        publishActivity()
        let report = RunReport(resultText: result.text, inputTokens: result.inputTokens, outputTokens: result.outputTokens, toolAttempts: result.toolAttempts)
        coordinator.runFinished(resolved, outcome: outcome, report: report)
        if let validation { audit.update(runID) { $0.validationStatus = validation } }
        if let overrideStatus { audit.update(runID) { $0.status = overrideStatus } }
        switch outcome {
        case .completed: onEvent?("\(audit.record(runID)?.agentType ?? "Agent") completed")
        case .failed: onEvent?("\(resolved.name) failed validation or errored")
        case .cancelled: onEvent?("\(audit.record(runID)?.agentType ?? "Agent") cancelled")
        }
    }

    // MARK: Capacity (event-driven; the task engine waits here instead of polling when every slot is taken)

    /// Resolves when a slot has been released by any agent (or the caller is cancelled). Never a timer.
    func waitForCapacityChange() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                if Task.isCancelled { cont.resume() } else { capacityWaiters.append((id, cont)) }
            }
        } onCancel: {
            Task { @MainActor in
                if let i = self.capacityWaiters.firstIndex(where: { $0.id == id }) { self.capacityWaiters.remove(at: i).cont.resume() }
            }
        }
    }

    private func wakeCapacityWaiters() {
        let all = capacityWaiters; capacityWaiters = []
        for w in all { w.cont.resume() }
    }

    // MARK: Cancellation

    func cancel(_ runID: UUID) {
        guard let tracking = runTracking[runID], let task = tasks[tracking] else { return }
        cancelRequested.insert(tracking)
        task.cancel()
    }

    func cancelAll() {
        for (key, task) in tasks { cancelRequested.insert(key); task.cancel() }
    }

    /// Waits until no agent is running (tests, shutdown).
    func waitUntilIdle() async {
        while !active.isEmpty || totalSlots > 0 || !tasks.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
    }
}
