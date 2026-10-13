import Foundation

extension TaskEngine {
    // MARK: Step dispatch

    func executeStep(_ ctx: TaskContext, key: String) async -> StepOutcome {
        guard let step = ctx.step(key) else { return .failed(.toolFailed, "The step no longer exists.") }
        // Capability gate: the task must grant what this step type needs (destructive actions are gated per action by an approval).
        let needed = step.type.requiredCapabilities.subtracting([.destructiveFileOperation])
        guard ctx.record.capabilities.allows(all: needed) else {
            setStep(ctx, key, to: .failed, failure: (.capabilityDenied, "This task does not grant \(needed.map(\.rawValue).sorted().joined(separator: ", "))."))
            return .failed(.capabilityDenied, "capability not granted for \(step.type.rawValue) steps")
        }
        // V0.12: the role contract is re-checked right before the node starts — a plan, a handoff or an artifact can never widen what a role may do.
        if let (cat, why) = orchestrationRefusal(ctx, step) {
            if step.state == .pending { setStep(ctx, key, to: .ready) }
            setStep(ctx, key, to: .failed, failure: (cat, why))
            return .failed(cat, why)
        }
        if step.state == .pending { setStep(ctx, key, to: .ready) }
        guard setStep(ctx, key, to: .running) else { return .failed(.toolFailed, "The step could not be started.") }
        let position = (ctx.index(key) ?? 0) + 1
        mutate(ctx) { $0.activity = "Step \(position)/\(ctx.steps.count): \(step.title)" }

        let outcome: StepOutcome
        switch step.type {
        case .analysis: outcome = await runAnalysis(ctx, key)
        case .codeChange: outcome = await runCodeChange(ctx, key)
        case .build, .test: outcome = await runCommandStep(ctx, key)
        case .review: outcome = await runReview(ctx, key)
        case .delete: outcome = await runDelete(ctx, key)
        case .unityInspect: outcome = await runUnityInspect(ctx, key)
        case .unityEdit: outcome = await runUnityEdit(ctx, key)
        case .unityCompile: outcome = await runUnityCompile(ctx, key)
        case .unityTest: outcome = await runUnityTest(ctx, key)
        case .unityPlayMode: outcome = await runUnityPlayMode(ctx, key)
        case .unityValidate: outcome = await runUnityValidate(ctx, key)
        case .researchSearch: outcome = await runResearchSearch(ctx, key)
        case .researchRead: outcome = await runResearchRead(ctx, key)
        case .researchExtract: outcome = await runResearchExtract(ctx, key)
        case .researchVerify: outcome = await runResearchVerify(ctx, key)
        case .researchReport: outcome = await runResearchReport(ctx, key)
        case .acquire: outcome = await runAcquire(ctx, key)
        case .importAsset: outcome = await runImportAsset(ctx, key)
        case .computerAct: outcome = await runComputerAct(ctx, key)
        case .delegateResearch: outcome = await runDelegateResearch(ctx, key)
        case .delegateComputer: outcome = await runDelegateComputer(ctx, key)
        case .approvalGate: outcome = await runApprovalGate(ctx, key)
        }
        leases.release(owner: Self.leaseOwner(step))
        unity?.lock.release(owner: Self.leaseOwner(step))
        if ctx.terminating { return .cancelled }                              // quitting: the interrupted state is already recorded
        switch outcome {
        case .passed: break                                                    // runners already set `passed` with their evidence
        case .skipped: break
        case .cancelled: setStep(ctx, key, to: .cancelled)
        case .failed(let cat, let why): setStep(ctx, key, to: .failed, failure: (cat, why))
        }
        recordArtifact(ctx, key: key)
        await checkpoint(ctx, reason: "step \(step.key) \(ctx.step(key)?.state.rawValue ?? "")")
        return outcome
    }

    static func leaseOwner(_ s: TaskStepRecord) -> String { "step:\(s.id.uuidString)" }

    /// `running → verifying` (the step's result is now being checked).
    func verifying(_ ctx: TaskContext, _ key: String) { setStep(ctx, key, to: .verifying) }

    // MARK: Analysis (provider, read-only)

    private func priorResults(_ ctx: TaskContext, for step: TaskStepRecord) -> [String] {
        step.dependsOn.compactMap { ctx.results[$0] } + ctx.results.filter { !step.dependsOn.contains($0.key) }.sorted { $0.key < $1.key }.map(\.value)
    }

    func runAnalysis(_ ctx: TaskContext, _ key: String) async -> StepOutcome {
        guard let step = ctx.step(key) else { return .failed(.toolFailed, "missing step") }
        let handoff = handoffFor(ctx, step)
        let prior = ctx.orchestrated ? [] : priorResults(ctx, for: step)         // V0.12: orchestrated nodes receive typed, fenced handoffs instead of raw earlier text
        let texts = [ctx.record.goal, step.title, step.details] + prior + (handoff.text.isEmpty ? [] : [handoff.text])
        let files = await ProjectContext.selectFiles(tools: ctx.tools, mentionedIn: texts, searchTerms: ProjectContext.terms(from: [ctx.record.goal, step.title, step.details]), max: 6)
        let snaps = await ProjectContext.snapshots(tools: ctx.tools, paths: files, perFileBytes: 9000, totalChars: 36_000)
        let tree = (try? ctx.tools.projectTree(maxEntries: 150)) ?? ""
        let failureNote = ctx.lastFailureTail.values.first.map { "\nLast failing command output:\n\($0.suffix(3000))" }
        let prompt = TaskPrompts.analysis(goal: ctx.record.goal, step: step, tree: tree, files: snaps, prior: prior + (handoff.text.isEmpty ? [] : [handoff.text]) + (failureNote.map { [$0] } ?? []))
        var excluded: Set<RoutingCandidate> = []
        for round in 0..<2 {
            if ctx.cancelRequested || Task.isCancelled { return .cancelled }
            let attempt = beginAttempt(ctx, step, round == 0 ? .primary : .escalation)
            var job = AgentJob(type: "AnalysisAgent", title: "\(step.title)", prompt: prompt, profile: jobProfile(ctx, .analysis, promptChars: prompt.count), taskID: ctx.record.id,
                               validator: { AnalysisResult.parse($0) != nil ? BenchmarkSuite.Verdict(passed: true, detail: "") : BenchmarkSuite.Verdict(passed: false, detail: "reply with the JSON object containing a non-empty \"summary\"") },
                               timeout: limits.providerTimeout, exclude: excluded)
            job.nodeKey = key; job.handoffChars = handoff.chars; job.artifactCount = handoff.artifactCount; job.fileCount = files.count
            let result = await runJob(ctx, job)
            if case .completed(let text, let runID, let cand, _) = result, let a = AnalysisResult.parse(text) {
                verifying(ctx, key)
                ctx.results[key] = a.rendered
                ctx.candidates[key, default: []].append(cand)
                endAttempt(attempt, outcome: "passed", evidence: "structured result accepted", runID: runID, candidate: cand)
                updateStep(ctx, key) { $0.agentRunID = runID }
                setStep(ctx, key, to: .passed, evidence: "Structured analysis accepted (\(a.findings.count) findings, \(a.relevantFiles.count) relevant files)", result: a.rendered)
                // A specialist may only REQUEST more knowledge; the orchestrator decides whether (and how often) the graph changes.
                if !a.needsResearch.isEmpty { ctx.revisionRequests[key] = a.needsResearch.joined(separator: "; "); considerResearchRevision(ctx, after: key, wants: a.needsResearch) }
                return .passed
            }
            if case .cancelled = result { endAttempt(attempt, outcome: "cancelled", evidence: nil); return .cancelled }
            let (cat, why) = failure(from: result)
            var cand: RoutingCandidate?
            if case .failed(_, _, _, let c) = result { cand = c; if let c { excluded.insert(c) } }
            endAttempt(attempt, outcome: "failed:\(cat.rawValue)", evidence: why, candidate: cand)
            if round == 0, canEscalate(ctx), cand != nil { noteEscalationNeeded(ctx, step, why); continue }
            return .failed(cat, why)
        }
        return .failed(.providerFailed, "analysis failed")
    }

    func noteEscalationNeeded(_ ctx: TaskContext, _ step: TaskStepRecord, _ why: String) {
        ctx.escalationCount += 1
        if ctx.orchestrated { ctx.escalationReasons[step.key] = inferEscalationReason(ctx, step, why: why) }
        note("\(step.title): escalating to another provider (\(why))", .warning, taskID: ctx.record.id)
    }

    // MARK: Code change (provider produces edit blocks; JARVIS applies them with leases and evidence)

    struct CodeAttempt {
        var changes: [TaskFileChange] = []
        var runID: UUID?
        var candidate: RoutingCandidate?
        var failure: (FailureCategory, String)?
        var cancelled = false
        var evidence = ""
    }

    func runCodeChange(_ ctx: TaskContext, _ key: String) async -> StepOutcome {
        guard let step = ctx.step(key) else { return .failed(.toolFailed, "missing step") }
        // Recovery after an interruption: the edits are already on disk and verified — do not ask the provider (or write) again.
        if ctx.recoveredApplied.contains(key) {
            let mine = ctx.changes.filter { $0.stepKey == key }
            verifying(ctx, key)
            setStep(ctx, key, to: .passed, evidence: "Recovered after restart: \(mine.count) file(s) verified on disk (" + mine.map(\.path).joined(separator: ", ") + ")", result: "Changed: " + mine.map(\.path).joined(separator: ", "))
            return .passed
        }
        // V0.6: in a Unity project a script edit waits for its turn with the other editor-affecting work, and never happens during Play Mode.
        if let refusal = await unityGateForProjectEdit(ctx, step) { return refusal }
        var kinds: [AttemptKind] = [.primary]
        if canEscalate(ctx) { kinds.append(.escalation) }
        var lastWhy: (FailureCategory, String) = (.providerFailed, "the coding agent failed")
        for kind in kinds {
            if ctx.cancelRequested || Task.isCancelled { return .cancelled }
            if (ctx.step(key)?.attempts ?? 0) >= Self.maxStepAttempts { break }
            let attempt = beginAttempt(ctx, step, kind)
            let used = Set(ctx.candidates[key] ?? [])
            let r = await codeAttempt(ctx, step, kind: kind, failure: nil, pin: nil, exclude: kind == .escalation ? used : [])
            if r.cancelled { endAttempt(attempt, outcome: "cancelled", evidence: nil, runID: r.runID, candidate: r.candidate); return .cancelled }
            if let f = r.failure {
                endAttempt(attempt, outcome: "failed:\(f.0.rawValue)", evidence: f.1, runID: r.runID, candidate: r.candidate)
                lastWhy = f
                if f.0 == .approvalDenied || f.0 == .capabilityDenied || f.0 == .workspaceViolation || f.0 == .securityBlocked || f.0 == .scopeExceeded { return .failed(f.0, f.1) }
                if kind == .primary, canEscalate(ctx) { noteEscalationNeeded(ctx, step, f.1) }
                continue
            }
            verifying(ctx, key)
            endAttempt(attempt, outcome: "passed", evidence: r.evidence, runID: r.runID, candidate: r.candidate)
            updateStep(ctx, key) { $0.agentRunID = r.runID }
            setStep(ctx, key, to: .passed, evidence: r.evidence, result: "Changed: " + r.changes.map(\.path).joined(separator: ", "))
            return .passed
        }
        return .failed(lastWhy.0, lastWhy.1)
    }

    static let maxStepAttempts = 3

    /// One bounded coding attempt: ask the provider for edit blocks → validate → (dirty-file approval) → lease → apply → verify hashes.
    func codeAttempt(_ ctx: TaskContext, _ step: TaskStepRecord, kind: AttemptKind, failure: String?, pin: RoutingCandidate?, exclude: Set<RoutingCandidate>) async -> CodeAttempt {
        var out = CodeAttempt()
        let tools = ctx.tools
        // Context: files named by earlier analysis, files that failed, files already changed by this task.
        let handoff = handoffFor(ctx, step)
        let analysis = ctx.orchestrated ? (handoff.text.isEmpty ? [] : [handoff.text]) : ctx.steps.filter { $0.type == .analysis && $0.state == .passed }.compactMap { ctx.results[$0.key] }
        let texts = [ctx.record.goal, step.title, step.details] + analysis + [failure ?? ""] + Array(ctx.finals.keys)
        var paths = await ProjectContext.selectFiles(tools: tools, mentionedIn: texts, searchTerms: ProjectContext.terms(from: [ctx.record.goal, step.title, step.details]), max: 6)
        for p in ctx.finals.keys where !paths.contains(p) && ctx.finals[p]?.text != nil { paths.insert(p, at: 0) }
        let snaps = await ProjectContext.snapshots(tools: tools, paths: Array(paths.prefix(7)), perFileBytes: 14_000, totalChars: 50_000)
        let prompt = TaskPrompts.codeChange(goal: ctx.record.goal, step: step, analysis: analysis, files: snaps, failure: failure.map { String($0.suffix(5000)) },
                                            previousChange: ctx.finals.isEmpty ? nil : String(diffText(ctx).prefix(4000)), attempt: kind)
        let scope = ctx.record.scope
        let alreadyChanged = Set(ctx.changes.map(\.path)).count
        let verdictBox = ValidationBox<Bool>()                     // remembers WHY the last answer was rejected (policy blocks must not be "repaired")
        var job = AgentJob(type: "CodingAgent", title: kind == .primary ? step.title : "\(kind == .repair ? "Repair" : "Escalated fix") · \(step.title)", prompt: prompt,
                           profile: jobProfile(ctx, .codeChange, promptChars: prompt.count), taskID: ctx.record.id,
                           validator: { text in
                               let parsed = EditParser.parse(text)
                               if !parsed.problems.isEmpty { verdictBox.set(false, notes: [parsed.problems.joined(separator: "; ")]); return BenchmarkSuite.Verdict(passed: false, detail: parsed.problems.joined(separator: "; ")) }
                               do {
                                   let prepared = try tools.prepare(parsed.blocks)
                                   if let scope, !scope.editViolations(prepared.map(\.path), alreadyChanged: alreadyChanged).isEmpty {
                                       let why = scope.editViolations(prepared.map(\.path), alreadyChanged: alreadyChanged).joined(separator: "; ")
                                       verdictBox.set(false, notes: ["scopeExceeded|\(why)"]); return BenchmarkSuite.Verdict(passed: false, detail: why)
                                   }
                                   verdictBox.set(true); return BenchmarkSuite.Verdict(passed: true, detail: "")
                               }
                               catch let e as ToolError {
                                   verdictBox.set(false, notes: ["\(e.failureCategory.rawValue)|\(e.description)"])
                                   return BenchmarkSuite.Verdict(passed: false, detail: e.description)
                               } catch { verdictBox.set(false, notes: ["toolFailed|\(error)"]); return BenchmarkSuite.Verdict(passed: false, detail: "\(error)") }
                           }, timeout: limits.providerTimeout, exclude: exclude, pin: pin)
        job.nodeKey = step.key; job.handoffChars = handoff.chars; job.artifactCount = handoff.artifactCount; job.fileCount = paths.count
        if ctx.orchestrated, ReviewIndependence.looksSecurityRelevant(goal: ctx.record.goal, paths: paths) { job.requireRoleEvidence = "security" }
        let result = await runJob(ctx, job)
        switch result {
        case .cancelled(let rid): out.cancelled = true; out.runID = rid; return out
        case .completed(let text, let runID, let cand, _):
            out.runID = runID; out.candidate = cand
            ctx.candidates[step.key, default: []].append(cand)
            return await applyEdits(ctx, step, text: text, runID: runID, candidate: cand)
        case .failed(let rid, _, let validationFailed, let cand):
            out.runID = rid; out.candidate = cand; if let cand { ctx.candidates[step.key, default: []].append(cand) }
            out.failure = self.failure(from: result)
            // A rejected edit that violated the workspace/capability policy is a policy failure, not something to re-ask about.
            if validationFailed, let note = verdictBox.detail.last, let bar = note.firstIndex(of: "|"),
               let cat = FailureCategory(rawValue: String(note[..<bar])), cat == .workspaceViolation || cat == .capabilityDenied || cat == .scopeExceeded {
                out.failure = (cat, String(note[note.index(after: bar)...]))
            }
            return out
        case .rejected:
            out.failure = self.failure(from: result); return out
        }
    }

    func applyEdits(_ ctx: TaskContext, _ step: TaskStepRecord, text: String, runID: UUID, candidate: RoutingCandidate) async -> CodeAttempt {
        var out = CodeAttempt(); out.runID = runID; out.candidate = candidate
        let tools = ctx.tools
        let blocks = EditParser.parse(text).blocks
        var prepared: [ProjectTools.PreparedFile]
        do { prepared = try tools.prepare(blocks) } catch let e as ToolError { out.failure = (e.failureCategory, e.description); return out } catch { out.failure = (.toolFailed, "\(error)"); return out }

        // V0.5: a proactive task may only change what its approval/authorisation covers (paths, test-only, number of files).
        if let scope = ctx.record.scope {
            let over = scope.editViolations(prepared.map(\.path), alreadyChanged: Set(ctx.changes.map(\.path)).count)
            if !over.isEmpty { out.failure = (.scopeExceeded, over.joined(separator: "; ")); return out }
        }

        // User's own uncommitted work is never overwritten silently: touching such a file needs an explicit approval.
        let dirty = Set((ctx.record.gitBaseline?.dirtyPaths ?? []) + (ctx.record.gitBaseline?.untrackedPaths ?? []))
        let touchingUserWork = prepared.filter { dirty.contains($0.path) && !ctx.approvedDirty.contains($0.path) }.map(\.path)
        if !touchingUserWork.isEmpty {
            let ok = await requestApproval(ctx, step, action: "Modify file(s) with your uncommitted changes: \(touchingUserWork.joined(separator: ", "))",
                                           reason: "These files already differ from the last commit. JARVIS recorded their baseline hash and will only change them if you approve.", risk: .high)
            if ctx.cancelRequested || Task.isCancelled { out.cancelled = true; return out }
            guard ok else { out.failure = (.approvalDenied, "Modifying files with uncommitted changes was not approved."); return out }
            ctx.approvedDirty.formUnion(touchingUserWork)
        }

        // Write lease: only one writer per file. A second writer waits here until the first step ends.
        let owner = Self.leaseOwner(step)
        if let conflict = await leases.acquireWaiting(paths: prepared.map(\.path), taskID: ctx.record.id, stepID: step.id, owner: owner) {
            if ctx.cancelRequested || Task.isCancelled { out.cancelled = true } else { out.failure = (.resourceUnavailable, "\(conflict.path) is being edited by another task") }
            return out
        }
        // The file may have changed while we waited for the lease: prepare again from the CURRENT content.
        do { prepared = try tools.prepare(blocks) } catch let e as ToolError { out.failure = (.workspaceChanged, "The file changed before it could be edited: \(e.description)"); return out } catch { out.failure = (.toolFailed, "\(error)"); return out }

        do {
            let changes = try tools.apply(prepared, stepKey: step.key, preexisting: dirty)
            for f in prepared {
                if ctx.originals[f.path] == nil { ctx.originals[f.path] = FileContent(text: f.before) }
                ctx.finals[f.path] = FileContent(text: f.after)
            }
            for c in changes {
                try? repository?.insertTaskFileChange(c, taskID: ctx.record.id, agentRunID: runID)
                hub?.emit(runID, .fileChanged, source: "JARVIS", summary: "\(c.changeType) \(c.path)")
            }
            audit.update(runID) { $0.filesChanged = changes.map(\.path); $0.toolsUsed = Array(Set($0.toolsUsed + ["ApplyEdits"])).sorted() }
            ctx.changes.append(contentsOf: changes)
            // Verify what is on disk (the `changedFiles` validation): content hash must equal what we wrote.
            for c in changes {
                let onDisk = try? tools.fileHash(c.path)
                guard onDisk == c.afterHash else { out.failure = (.toolFailed, "\(c.path) does not match the written content"); return out }
            }
            out.changes = changes
            let diff = changes.map { c in UnifiedDiff.make(path: c.path, before: ctx.originals[c.path]?.text, after: ctx.finals[c.path]?.text) }.joined(separator: "\n")
            let plus = diff.split(separator: "\n").filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
            let minus = diff.split(separator: "\n").filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
            out.evidence = "Changed \(changes.count) file(s): " + changes.map(\.path).joined(separator: ", ") + " (+\(plus) −\(minus))"
            ctx.evidence.append(out.evidence)
        } catch let e as ToolError {
            out.failure = (e.failureCategory, e.description)
        } catch { out.failure = (.toolFailed, "\(error)") }
        return out
    }

    /// Unified diff of everything the task changed (sanitized; bounded). What the reviewer and the report see.
    func diffText(_ ctx: TaskContext, limit: Int = 20_000) -> String {
        if ctx.finals.isEmpty, let restored = ctx.restoredDiff { return String(restored.prefix(limit)) }
        let all = ctx.finals.keys.sorted().map { UnifiedDiff.make(path: $0, before: ctx.originals[$0]?.text, after: ctx.finals[$0]?.text) }.joined(separator: "\n")
        return String(OutputSanitizer.sanitize(all).prefix(limit))
    }

    // MARK: Build / test (deterministic tools)

    func runCommandStep(_ ctx: TaskContext, _ key: String) async -> StepOutcome {
        guard let step = ctx.step(key) else { return .failed(.toolFailed, "missing step") }
        let isBuild = step.type == .build
        guard let profile = isBuild ? ctx.profiles.build : ctx.profiles.test else {
            if isBuild || step.validation == .testEvidence {
                setStep(ctx, key, to: .skipped, evidence: "No \(isBuild ? "build" : "test") command is configured for this project (\(ctx.profiles.source)).")
                return .skipped
            }
            return .failed(.toolFailed, "No test command was found for this project, so \"tests pass\" cannot be established. Add .jarvis/project.json with a test command.")
        }
        var result = await runCommand(ctx, step, profile, label: step.title, attemptKind: .primary)
        if ctx.cancelRequested || Task.isCancelled || result.cancelled { return .cancelled }
        if step.validation == .testEvidence {
            verifying(ctx, key)
            ctx.lastFailureTail[key] = result.succeeded ? nil : result.tail
            let line = evidenceLine(step, profile, result)
            ctx.evidence.append(line)
            setStep(ctx, key, to: .passed, evidence: line, result: result.succeeded ? "The command passed — no failure to reproduce." : "Failure reproduced (exit \(result.exitCode)).")
            return .passed
        }
        verifying(ctx, key)
        if !result.succeeded {
            ctx.lastFailureTail[key] = result.tail
            if !result.timedOut, let fixed = await repairLoop(ctx, failing: step, profile: profile, first: result) { result = fixed }
            if ctx.cancelRequested || Task.isCancelled { return .cancelled }
        }
        let line = evidenceLine(step, profile, result)
        ctx.evidence.append(line)
        if result.succeeded {
            ctx.lastFailureTail[key] = nil
            setStep(ctx, key, to: .passed, evidence: line, result: result.testCounts?.summary)
            return .passed
        }
        updateStep(ctx, key) { $0.validationEvidence = line + "\n" + String(result.tail.suffix(1500)) }
        return .failed(result.timedOut ? .toolFailed : (isBuild ? .buildFailed : .testFailed), line)
    }

    func evidenceLine(_ step: TaskStepRecord, _ profile: CommandProfile, _ r: CommandResult) -> String {
        var s = "\(step.type == .build ? "Build" : "Tests"): \(profile.display) → "
        s += r.timedOut ? "timed out" : "exit \(r.exitCode)"
        if let c = r.testCounts, !c.summary.isEmpty { s += " · \(c.summary)" }
        s += " (\(String(format: "%.1f", r.durationSeconds)) s)"
        return s
    }

    /// One real command run as an observable tool run (console, audit row, tool record).
    func runCommand(_ ctx: TaskContext, _ step: TaskStepRecord, _ profile: CommandProfile, label: String, attemptKind: AttemptKind) async -> CommandResult {
        let attempt = beginAttempt(ctx, step, attemptKind)
        let runID = audit.begin(agentType: step.type.agentType, taskID: ctx.record.id, engine: .tool, model: nil, decision: nil, prompt: profile.display,
                                privacy: ctx.record.privacy, label: label, owner: .task)
        hub?.setPhase(runID, .running, activity: "Running \(profile.label)")
        hub?.emit(runID, .toolStarted, source: "JARVIS", summary: "Started \(profile.display)", detail: "in \(ctx.workspace.root)")
        let sink = SafeToolOutput(runID: runID, hub: hub)
        let result: CommandResult
        do { result = try await CommandRunner.run(profile, workspace: ctx.workspace, sink: sink) }
        catch {
            sink.finish()
            let why = "\(error)"
            hub?.emit(runID, .error, source: "JARVIS", summary: why, severity: .error)
            audit.finish(runID, status: .failed, error: .refused(why))
            endAttempt(attempt, outcome: "failed:\(FailureCategory.securityBlocked.rawValue)", evidence: why, runID: runID)
            updateStep(ctx, step.key) { $0.agentRunID = runID }
            return CommandResult(exitCode: -1, timedOut: false, cancelled: false, durationSeconds: 0, tail: why, testCounts: nil)
        }
        hub?.emit(runID, .toolFinished, source: "JARVIS", summary: result.timedOut ? "Timed out after \(profile.timeoutSeconds) s" : "Finished with exit code \(result.exitCode)",
                  severity: result.succeeded ? .success : .warning)
        audit.recordTool(runID, tool: profile.label, summary: profile.display, status: result.succeeded ? "ok" : (result.cancelled ? "cancelled" : "failed"), exitCode: Int(result.exitCode))
        audit.update(runID) { $0.toolsUsed = [profile.label] }
        audit.finish(runID, status: result.cancelled ? .cancelled : (result.succeeded ? .succeeded : .failed), resultText: result.tail.isEmpty ? nil : String(result.tail.suffix(200)),
                     validation: result.succeeded ? .passed : .failed)
        endAttempt(attempt, outcome: result.succeeded ? "passed" : (result.cancelled ? "cancelled" : "failed:\(step.type == .build ? "buildFailed" : "testFailed")"),
                   evidence: String(result.tail.suffix(1500)), runID: runID)
        updateStep(ctx, step.key) { $0.agentRunID = runID }
        return result
    }

    // MARK: Repair loop (bounded: one repair on the same engine, then one escalation)

    /// Called when a build/test step with a required pass failed. Re-asks the coding agent with the REAL failure output; after each
    /// applied fix the same command runs again. Returns the passing result, or nil when the budget is spent.
    func repairLoop(_ ctx: TaskContext, failing: TaskStepRecord, profile: CommandProfile, first: CommandResult) async -> CommandResult? {
        await repairLoop(ctx, failing: failing, first: first) { [self] label, kind in
            await runCommand(ctx, ctx.step(failing.key) ?? failing, profile, label: label, attemptKind: kind)
        }
    }

    /// The same bounded repair/escalation loop for any deterministic check: `rerun` runs the check again after a fix was applied.
    func repairLoop(_ ctx: TaskContext, failing: TaskStepRecord, first: CommandResult, rerun: (String, AttemptKind) async -> CommandResult) async -> CommandResult? {
        guard let code = nearestCodeStep(ctx, before: failing) else { return nil }
        var kinds: [AttemptKind] = [.repair]
        if canEscalate(ctx) { kinds.append(.escalation) }
        var last = first
        for kind in kinds {
            if ctx.cancelRequested || Task.isCancelled { return nil }
            if (ctx.step(code.key)?.attempts ?? 0) >= Self.maxStepAttempts { return nil }
            ctx.repairCount += 1
            if kind == .escalation { ctx.escalationCount += 1 }
            mutate(ctx) { $0.activity = kind == .repair ? "Repairing: \(code.title)" : "Escalating the fix to another provider" }
            note(kind == .repair ? "Repairing after a failed \(failing.type.rawValue): \(failing.title)" : "Escalating the repair for: \(failing.title)", .warning, taskID: ctx.record.id)
            let attempt = beginAttempt(ctx, code, kind)
            let used = ctx.candidates[code.key] ?? []
            let pin = kind == .repair ? used.last : nil
            let r = await codeAttempt(ctx, code, kind: kind, failure: last.tail, pin: pin, exclude: kind == .escalation ? Set(used) : [])
            if r.cancelled { endAttempt(attempt, outcome: "cancelled", evidence: nil, runID: r.runID, candidate: r.candidate); return nil }
            if let f = r.failure {
                endAttempt(attempt, outcome: "failed:\(f.0.rawValue)", evidence: f.1, runID: r.runID, candidate: r.candidate)
                if f.0 == .approvalDenied || f.0 == .scopeExceeded { return nil }
                continue
            }
            endAttempt(attempt, outcome: "applied", evidence: r.evidence, runID: r.runID, candidate: r.candidate)
            if kind == .escalation, let from = used.last, let to = r.candidate, let prev = ctx.step(code.key)?.agentRunID {
                hub?.noteEscalation(prev, from: from.label, to: to.label)
            }
            updateStep(ctx, code.key) { $0.agentRunID = r.runID; $0.resultSummary = "Changed: " + ctx.finals.keys.sorted().joined(separator: ", ") }
            setStep(ctx, failing.key, to: .running)                              // verifying → running (repair applied) → verifying again
            let again = await rerun("\(failing.title) · after \(kind == .repair ? "repair" : "escalation")", .recheck)
            verifying(ctx, failing.key)
            last = again
            if again.cancelled { return nil }
            if again.succeeded { return again }
            ctx.lastFailureTail[failing.key] = again.tail
        }
        return nil
    }

    /// The closest preceding `codeChange` step among the failing step's (transitive) dependencies.
    func nearestCodeStep(_ ctx: TaskContext, before failing: TaskStepRecord) -> TaskStepRecord? {
        var seen = Set<String>(), stack = failing.dependsOn
        var found: [TaskStepRecord] = []
        while let k = stack.popLast() {
            guard seen.insert(k).inserted, let s = ctx.step(k) else { continue }
            if s.type == .codeChange { found.append(s) }
            stack.append(contentsOf: s.dependsOn)
        }
        return found.max { $0.index < $1.index }
    }

    // MARK: Review (provider, read-only)

    func runReview(_ ctx: TaskContext, _ key: String) async -> StepOutcome {
        guard let step = ctx.step(key) else { return .failed(.toolFailed, "missing step") }
        let handoff = handoffFor(ctx, step)
        let analysis = ctx.orchestrated ? (handoff.text.isEmpty ? [] : [handoff.text]) : ctx.steps.filter { $0.type == .analysis && $0.state == .passed }.compactMap { ctx.results[$0.key] }
        let prompt = TaskPrompts.review(goal: ctx.record.goal, diff: diffText(ctx, limit: 14_000), evidence: ctx.evidence, analysis: analysis)
        var excluded: Set<RoutingCandidate> = []
        // V0.12 review independence (risk-based, never forced for trivial work): a nontrivial change is reviewed by a candidate that is NOT the writer when another eligible one exists.
        var independenceExclusion: Set<RoutingCandidate> = []
        var securityRelevant = false
        if ctx.orchestrated {
            let diff = diffText(ctx, limit: 14_000)
            let lines = diff.split(separator: "\n").filter { ($0.hasPrefix("+") && !$0.hasPrefix("+++")) || ($0.hasPrefix("-") && !$0.hasPrefix("---")) }.count
            let facts = ReviewIndependence.Facts(changedFiles: Set(ctx.changes.map(\.path)).count, changedLines: lines, taskRisk: ctx.record.risk,
                                                 securityRelevant: ReviewIndependence.looksSecurityRelevant(goal: ctx.record.goal, paths: ctx.changes.map(\.path)), escalated: ctx.escalationCount > 0)
            securityRelevant = facts.securityRelevant
            if ReviewIndependence.isRequired(facts) {
                let writers = ctx.steps.filter { $0.type == .codeChange }.flatMap { ctx.candidates[$0.key] ?? [] }
                ctx.reviewWriters[key] = writers
                if canEscalate(ctx) { independenceExclusion = Set(writers) }
            }
        }
        excluded = independenceExclusion
        for round in 0..<2 {
            if ctx.cancelRequested || Task.isCancelled { return .cancelled }
            let attempt = beginAttempt(ctx, step, round == 0 ? .primary : .escalation)
            var job = AgentJob(type: "ReviewAgent", title: step.title, prompt: prompt, profile: jobProfile(ctx, .review, promptChars: prompt.count), taskID: ctx.record.id,
                               validator: { ReviewResult.parse($0) != nil ? BenchmarkSuite.Verdict(passed: true, detail: "") : BenchmarkSuite.Verdict(passed: false, detail: "reply with the JSON object {\"verdict\": \"pass\" or \"fail\", …}") },
                               timeout: limits.providerTimeout, exclude: excluded)
            job.nodeKey = key; job.handoffChars = handoff.chars; job.artifactCount = handoff.artifactCount
            if securityRelevant { job.requireRoleEvidence = "security" }
            var result = await runJob(ctx, job)
            // No other eligible provider: the writer also reviews (stated in the routing record), the review is not skipped.
            if case .rejected(.noEligibleProvider) = result, !excluded.isEmpty, round == 0 {
                excluded = excluded.subtracting(independenceExclusion); job.exclude = excluded
                result = await runJob(ctx, job)
            }
            if case .completed(let text, let runID, let cand, _) = result, let review = ReviewResult.parse(text) {
                verifying(ctx, key)
                ctx.candidates[key, default: []].append(cand)
                updateStep(ctx, key) { $0.agentRunID = runID }
                let suggestions = ReviewSuggestion.parse(text)
                if !suggestions.isEmpty { onReviewSuggestions?(ctx.record, step.id, runID, suggestions) }
                let line = "Review: \(review.passed ? "pass" : "fail") — \(review.summary.isEmpty ? (review.issues.first ?? "no summary") : review.summary)"
                ctx.evidence.append(line)
                // V0.6 (DEC-050): the reviewer's verdict is weighed against the deterministic validation record.
                let decision = ReviewAuthority.decide(review: review, hardPassed: ReviewAuthority.hardValidationPassed(steps: ctx.steps), gate: ReviewAuthority.isGate(constraints: ctx.record.constraints),
                                                      diff: diffText(ctx, limit: 14_000), evidence: ctx.evidence, changedPaths: Array(Set(ctx.changes.map(\.path))))
                switch decision {
                case .pass:
                    endAttempt(attempt, outcome: "passed", evidence: line, runID: runID, candidate: cand)
                    setStep(ctx, key, to: .passed, evidence: line, result: review.summary)
                    return .passed
                case .advisory(let advice):
                    endAttempt(attempt, outcome: "passed", evidence: advice, runID: runID, candidate: cand)
                    note("Reviewer advice recorded (build/tests passed, so it did not fail the task): \(advice.prefix(160))", .warning, taskID: ctx.record.id)
                    setStep(ctx, key, to: .passed, evidence: advice, result: review.summary)
                    return .passed
                case .fail(let why):
                    endAttempt(attempt, outcome: "failed:\(FailureCategory.validationFailed.rawValue)", evidence: line + "\n" + review.issues.joined(separator: "\n"), runID: runID, candidate: cand)
                    // V0.12: ONE writer → critic → writer cycle (never an endless loop): the coding agent repairs with the reviewer's evidence-backed findings, JARVIS re-runs the
                    // build/tests, and the change is reviewed once more. A second failed review ends the task.
                    if ctx.orchestrated, ctx.reviewCycles < OrchestrationLimits.maxReviewCycles, await reviewRepairCycle(ctx, review: step, result: review) {
                        return await runReview(ctx, key)
                    }
                    return .failed(.validationFailed, why)
                }
            }
            if case .cancelled = result { endAttempt(attempt, outcome: "cancelled", evidence: nil); return .cancelled }
            let (cat, why) = failure(from: result)
            var cand: RoutingCandidate?
            if case .failed(_, _, _, let c) = result { cand = c; if let c { excluded.insert(c) } }
            endAttempt(attempt, outcome: "failed:\(cat.rawValue)", evidence: why, candidate: cand)
            if round == 0, canEscalate(ctx), cand != nil { noteEscalationNeeded(ctx, step, why); continue }
            return .failed(cat, why)
        }
        return .failed(.providerFailed, "review failed")
    }

    // MARK: Delete (destructive: ALWAYS waits for approval)

    func runDelete(_ ctx: TaskContext, _ key: String) async -> StepOutcome {
        guard let step = ctx.step(key) else { return .failed(.toolFailed, "missing step") }
        let targets = deleteTargets(step)
        guard !targets.isEmpty else { return .failed(.securityBlocked, "A delete step must list explicit target paths.") }
        // Already gone (e.g. recovery after an interruption): nothing to do, nothing to approve.
        if (try? targets.allSatisfy { !(try ctx.tools.exists($0)) }) == true {
            verifying(ctx, key)
            setStep(ctx, key, to: .passed, evidence: "Already removed: " + targets.joined(separator: ", "))
            return .passed
        }
        let ok = await requestApproval(ctx, step, action: "Delete \(targets.joined(separator: ", "))", reason: "Deleting files cannot be undone by JARVIS. The task asked for it explicitly.", risk: .high)
        if ctx.cancelRequested || Task.isCancelled { return .cancelled }
        guard ok else { return .failed(.approvalDenied, "Deleting \(targets.joined(separator: ", ")) was not approved.") }
        let runID = audit.begin(agentType: step.type.agentType, taskID: ctx.record.id, engine: .tool, model: nil, decision: nil, prompt: "delete \(targets.joined(separator: ", "))", privacy: ctx.record.privacy, label: step.title, owner: .task)
        let attempt = beginAttempt(ctx, step, .primary)
        let tools = ProjectTools(workspace: ctx.workspace, capabilities: CapabilitySet(granted: ctx.record.capabilities.granted.union([.destructiveFileOperation])))   // granted per approved action only
        if let c = await leases.acquireWaiting(paths: targets, taskID: ctx.record.id, stepID: step.id, owner: Self.leaseOwner(step)) {
            audit.finish(runID, status: .failed, error: .refused("lease"))
            endAttempt(attempt, outcome: "failed:\(FailureCategory.resourceUnavailable.rawValue)", evidence: "\(c.path) is leased", runID: runID)
            return ctx.cancelRequested ? .cancelled : .failed(.resourceUnavailable, "\(c.path) is being edited by another task")
        }
        do {
            for t in targets {
                var change = try tools.delete(t)
                change.stepKey = step.key
                try? repository?.insertTaskFileChange(change, taskID: ctx.record.id, agentRunID: runID)
                ctx.changes.append(change)
                if ctx.originals[change.path] == nil { ctx.originals[change.path] = FileContent(text: nil) }
                ctx.finals[change.path] = FileContent(text: nil)
                hub?.emit(runID, .fileChanged, source: "JARVIS", summary: "deleted \(change.path)", severity: .warning)
            }
            verifying(ctx, key)
            let gone = (try? targets.allSatisfy { !(try tools.exists($0)) }) ?? false
            guard gone else { throw ToolError.ioFailed("a target still exists") }
            audit.finish(runID, status: .succeeded, validation: .passed)
            endAttempt(attempt, outcome: "passed", evidence: "deleted \(targets.joined(separator: ", "))", runID: runID)
            updateStep(ctx, key) { $0.agentRunID = runID }
            ctx.evidence.append("Deleted: " + targets.joined(separator: ", "))
            setStep(ctx, key, to: .passed, evidence: "Removed \(targets.joined(separator: ", ")) after approval", result: "Deleted: " + targets.joined(separator: ", "))
            return .passed
        } catch let e as ToolError {
            audit.finish(runID, status: .failed, error: .refused(e.description))
            endAttempt(attempt, outcome: "failed:\(e.failureCategory.rawValue)", evidence: e.description, runID: runID)
            return .failed(e.failureCategory, e.description)
        } catch { return .failed(.toolFailed, "\(error)") }
    }

    func deleteTargets(_ step: TaskStepRecord) -> [String] {
        guard let line = step.details.split(separator: "\n").last(where: { $0.hasPrefix("targets: ") }) else { return [] }
        return line.dropFirst("targets: ".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: Approval gate (durable; survives a restart)

    func requestApproval(_ ctx: TaskContext, _ step: TaskStepRecord, action: String, reason: String, risk: RiskClass) async -> Bool {
        // A decision already persisted for this exact action (restart recovery) is reused instead of asking twice.
        if let existing = (try? repository?.approvals(taskID: ctx.record.id))?.last(where: { $0.stepID == step.id && $0.action == OutputSanitizer.sanitize(String(action.prefix(300))) }) {
            if existing.state == .approved { return true }
            if existing.state == .denied { return false }
            if existing.state == .pending { return await awaitDecision(ctx, step, existing) }
        }
        let a = ApprovalRecord(id: UUID(), taskID: ctx.record.id, stepID: step.id, action: action, reason: reason, risk: risk)
        try? repository?.insert(a)
        return await awaitDecision(ctx, step, a)
    }

    private func awaitDecision(_ ctx: TaskContext, _ step: TaskStepRecord, _ a: ApprovalRecord) async -> Bool {
        setStep(ctx, step.key, to: .waitingForApproval)
        transition(ctx, to: .waitingForApproval, activity: "Waiting for your approval: \(a.action)")
        note("Approval needed: \(a.action)", .warning, taskID: ctx.record.id)
        await checkpoint(ctx, reason: "awaiting approval")
        publish(ctx)
        onApprovalChanged?()
        let approved: Bool = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                if ctx.cancelRequested || Task.isCancelled { cont.resume(returning: false) } else { decisions[a.id] = cont }
            }
        } onCancel: {
            Task { @MainActor in self.decisions.removeValue(forKey: a.id)?.resume(returning: false) }
        }
        if ctx.terminating { return false }
        if !ctx.cancelRequested {
            transition(ctx, to: .running, activity: approved ? "Approved — continuing" : "Not approved")
            if ctx.step(step.key)?.state == .waitingForApproval { setStep(ctx, step.key, to: .running) }
        }
        onApprovalChanged?()
        return approved
    }
}
