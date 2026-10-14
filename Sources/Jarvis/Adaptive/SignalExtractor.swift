import Foundation

// MARK: - Learning signals (V0.14, DEC-218): small facts DERIVED from records that already exist. Deterministic, pure, idempotent per source — no model call.

/// What the extractor reads. Everything here is already persisted by the V0.4–V0.13 layers.
struct LearningSnapshot: Sendable {
    var tasks: [TaskRecord] = []
    var steps: [UUID: [TaskStepRecord]] = [:]
    var attempts: [UUID: [StepAttemptRecord]] = [:]
    var experiments: [ExperimentRecord] = []
    var assetEvaluations: [AssetEvaluationRecord] = []
    var computerActions: [UUID: [ComputerActionRecord]] = [:]          // by session (== task) id
    var computerSessions: [ComputerSessionRecord] = []
    var proposals: [ProposalRecord] = []
    var agentRuns: [AgentRunRecord] = []
    var mcpActivity: [MCPActivityRecord] = []
}

enum SignalExtractor {
    /// Failures that are the user's decision or an orderly stop, not something to learn a lesson from.
    static let notLessons: Set<FailureCategory> = [.cancelled, .interrupted, .approvalDenied]

    static func signals(from s: LearningSnapshot, projectKey: (TaskRecord) -> String?) -> [LearningSignal] {
        var out: [LearningSignal] = []
        let taskByID = Dictionary(uniqueKeysWithValues: s.tasks.map { ($0.id, $0) })
        func make(_ k: SignalKind, _ key: String, _ project: String?, _ sk: LearningEvidenceKind, _ id: String, _ at: Date, _ o: LearningSignal.Outcome, _ detail: String, episode: String? = nil) {
            out.append(LearningSignal(kind: k, key: key, projectKey: project, sourceKind: sk, sourceID: id, episode: episode ?? id, at: at, outcome: o, detail: detail))
        }

        for t in s.tasks where t.state.isTerminal && t.parentTaskID == nil {
            let project = projectKey(t), at = t.finishedAt ?? t.updatedAt, id = t.id.uuidString
            let steps = s.steps[t.id] ?? []
            switch t.state {
            case .failed:
                if let c = t.failureCategory, !notLessons.contains(c) {
                    make(.taskFailed, "\(c.rawValue)|\(t.kind.rawValue)", project, .task, id, at, .failure, c.label)
                    if c == .resourceUnavailable { make(.resourcePressure, t.kind.rawValue, project, .task, id, at, .failure, "resources unavailable") }
                    if [.unityUnavailable, .permissionRequired, .networkUnavailable, .blockedByNetworkPolicy].contains(c) { make(.capabilityUnavailable, c.rawValue, project, .task, id, at, .failure, c.label) }
                }
            case .cancelled: make(.taskCancelled, t.kind.rawValue, project, .task, id, at, .event, "stopped")
            default: break
            }
            // Graph shape of a finished multi-step task: successes AND failures of the same shape are both kept (counter-evidence).
            let required = steps.filter { !$0.optional }
            if required.count >= 3, t.state == .completed || t.state == .failed {
                make(.workflowSucceeded, signature(of: required), project, .task, id, at, t.state == .completed ? .success : .failure, encode(required))
            }
            for st in steps {
                let sid = st.id.uuidString
                if st.state == .failed, let c = st.failureCategory, !notLessons.contains(c) { make(.stepFailed, "\(st.type.rawValue)|\(c.rawValue)", project, .step, sid, at, .failure, st.title, episode: id) }
                if st.state == .passed, st.attempts > 1 { make(.taskRepaired, st.type.rawValue, project, .step, sid, at, .event, "needed \(st.attempts) attempts", episode: id) }
                if [.unityEdit, .unityValidate].contains(st.type), st.attempts > 1 || st.state == .failed { make(.unityCorrection, "\(st.type.rawValue)|\(st.failureCategory?.rawValue ?? "retried")", project, .step, sid, at, .failure, st.title, episode: id) }
                if (s.attempts[t.id] ?? []).contains(where: { $0.stepID == st.id && $0.kind == .escalation }) { make(.taskEscalated, st.type.rawValue, project, .step, sid, at, .event, "escalated", episode: id) }
            }
        }

        // Slow paths: a completed task far above the median of its own kind (needs ≥ 6 comparable tasks, so a single long task is never a pattern).
        let completed = s.tasks.filter { $0.state == .completed && $0.parentTaskID == nil && $0.accumulatedSeconds > 0 }
        for (kind, group) in Dictionary(grouping: completed, by: \.kind) where group.count >= 6 {
            let sorted = group.map(\.accumulatedSeconds).sorted(), median = sorted[sorted.count / 2], limit = max(300, median * 3)
            for t in group where t.accumulatedSeconds > limit {
                make(.slowPath, kind.rawValue, projectKey(t), .task, t.id.uuidString, t.finishedAt ?? t.updatedAt, .event, "took \(Int(t.accumulatedSeconds)) s (median \(Int(median)) s)")
            }
        }

        for e in s.experiments where e.status == "concluded" {
            let project = e.projectKey
            switch e.result?.verdict {
            case .refuted?: make(.experimentRefuted, "\(e.spec.kind.rawValue)|\(cleanKey(e.result?.failureHit.first ?? "refuted"))", project, .experiment, e.id.uuidString, e.finishedAt ?? e.createdAt, .failure, e.result?.summary ?? "")
            case .confirmed?: make(.experimentConfirmed, e.spec.kind.rawValue, project, .experiment, e.id.uuidString, e.finishedAt ?? e.createdAt, .success, e.result?.summary ?? "")
            default: break
            }
        }

        for a in s.assetEvaluations {
            let facts = a.evaluation.facts
            let host = facts.first { $0.statement.hasPrefix("Source: ") }.flatMap { URLComponents(string: String($0.statement.dropFirst(8)))?.host?.lowercased() } ?? "unknown"
            let format = facts.first { $0.statement.hasPrefix("File type: ") }.map { cleanKey(String($0.statement.dropFirst(11))) } ?? "unknown"
            let bad = facts.contains { $0.factClass == .incompatible } || a.evaluation.recommendation.hasPrefix("Do not use")
            let good = !bad && a.evaluation.recommendation.hasPrefix("Technically fine")
            if bad { make(.assetIncompatible, "\(host)|\(format)", a.projectKey, .assetEvaluation, a.id.uuidString, a.createdAt, .failure, String(a.evaluation.recommendation.prefix(160))) }
            else if good { make(.assetCompatible, "\(host)|\(format)", a.projectKey, .assetEvaluation, a.id.uuidString, a.createdAt, .success, "technically fine") }
        }

        for ses in s.computerSessions where ses.status != .running {
            let project = taskByID[ses.taskID].flatMap(projectKey)
            let actions = s.computerActions[ses.id] ?? []
            var perApp: [String: (ax: Int, fallback: Int)] = [:]
            for a in actions {
                guard let app = a.app, a.status != "blocked" else { continue }
                let m = a.mechanism.lowercased()
                var v = perApp[app] ?? (0, 0)
                if m.contains("vision") || m.contains("coordinate") { v.fallback += 1 } else if m.contains("accessibility") { v.ax += (a.status == "verified" || a.status == "done" ? 1 : 0) }
                perApp[app] = v
            }
            for (app, v) in perApp {
                if v.fallback > 0 { make(.computerVisionFallback, "app=\(app)", project, .computerResult, "\(ses.id.uuidString)|\(app)", ses.finishedAt ?? ses.startedAt, v.ax == 0 ? .failure : .event, "vision/coordinates used \(v.fallback)× (Accessibility \(v.ax)×)", episode: ses.id.uuidString) }
                else if v.ax > 0 { make(.computerAccessibilitySuccess, "app=\(app)", project, .computerResult, "\(ses.id.uuidString)|\(app)", ses.finishedAt ?? ses.startedAt, .success, "Accessibility \(v.ax)×", episode: ses.id.uuidString) }
            }
        }

        for p in s.proposals where p.status == .denied || p.status == .dismissed {
            make(.proposalRejected, cleanKey(p.title.split(separator: ":").first.map(String.init) ?? p.title), nil, .proposal, p.id.uuidString, p.decidedAt ?? p.createdAt, .event, "declined")
        }

        for r in s.agentRuns where r.taskID != nil && (r.status == .failed || r.status == .succeeded) {
            let key = "\(r.model ?? r.engine.rawValue)|\(r.agentType)"
            make(r.status == .failed ? .providerFailed : .providerSucceeded, key, r.taskID.flatMap { taskByID[$0] }.flatMap(projectKey), .run, r.id.uuidString, r.finishedAt ?? r.startedAt, r.status == .failed ? .failure : .success, r.errorCategory ?? "", episode: r.taskID?.uuidString)
        }

        for m in s.mcpActivity where m.status == "failed" || m.status == "ok" {
            make(m.status == "failed" ? .mcpFailed : .mcpSucceeded, "\(m.serverID)|\(m.capability)", m.projectKey, .mcpActivity, m.id.uuidString, m.endedAt ?? m.startedAt, m.status == "failed" ? .failure : .success, m.error ?? "", episode: m.taskID?.uuidString ?? m.id.uuidString)
        }
        return out
    }

    // MARK: Helpers

    static func signature(of steps: [TaskStepRecord]) -> String { steps.sorted { $0.index < $1.index }.map { $0.type.rawValue }.joined(separator: ">") }
    /// Compact, bounded, parseable: "type<dep,dep|type<dep" where deps are 0-based indexes.
    static func encode(_ steps: [TaskStepRecord]) -> String {
        let sorted = steps.sorted { $0.index < $1.index }
        let index = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($0.element.key, $0.offset) })
        return sorted.map { st in
            let v = st.validation == ValidationKind.default(for: st.type) ? "" : "/" + st.validation.rawValue
            return st.type.rawValue + v + "<" + st.dependsOn.compactMap { index[$0] }.map(String.init).joined(separator: ",")
        }.joined(separator: "|")
    }
    static func decodeTemplate(_ detail: String) -> WorkflowTemplate? {
        let parts = detail.split(separator: "|", omittingEmptySubsequences: false)
        guard (3...OrchestrationLimits.maxNodes).contains(parts.count) else { return nil }
        var nodes: [WorkflowNode] = []
        for (i, p) in parts.enumerated() {
            let pieces = p.split(separator: "<", maxSplits: 1, omittingEmptySubsequences: false)
            let head = pieces.first?.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false) ?? []
            guard pieces.count == 2, let first = head.first, let type = StepType(rawValue: String(first)) else { return nil }
            let validation = head.count == 2 ? String(head[1]) : nil
            if let validation, ValidationKind(rawValue: validation) == nil { return nil }
            let deps = pieces[1].split(separator: ",").compactMap { Int($0) }
            guard deps.allSatisfy({ $0 >= 0 && $0 < i }) else { return nil }
            nodes.append(WorkflowNode(key: "w\(i + 1)", title: type.rawValue, type: type, dependsOn: deps.map { "w\($0 + 1)" }, optional: false, validation: validation))
        }
        return WorkflowTemplate(nodes: nodes)
    }
    static func cleanKey(_ s: String) -> String {
        MemoryText.fold(s).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(8).joined(separator: "-")
    }
}
