import Foundation

/// V0.6 — the Unity steps of the V0.4 engine. Same lifecycle as every step (capability gate, attempts, evidence, repair, cancellation,
/// checkpoints); the Unity specifics are: typed operations only, the mutation lock, user-owned unsaved work, Play Mode safety, and
/// deterministic validation from the EDITOR's own state (never from a model's opinion).
extension TaskEngine {
    struct UnityRun {
        let conn: UnityConnection
        let session: UnityToolSession
        let runID: UUID
        let attempt: StepAttemptRecord
    }

    // MARK: Planning context

    func unityPlanContext(_ ctx: TaskContext) -> UnityPlanContext? {
        guard unity != nil, ctx.unityProject, let d = UnityProjectDetector.describe(root: ctx.workspace.root) else { return nil }
        return UnityPlanContext(projectName: d.projectName, unityVersion: d.declaredVersionRaw, scenes: d.scenes, hasTestFramework: d.hasTestFramework, renderPipeline: d.renderPipeline)
    }

    // MARK: Gate for ordinary file edits in a Unity project

    /// A script edit in a Unity project takes its turn with other editor-affecting work and never happens during Play Mode.
    func unityGateForProjectEdit(_ ctx: TaskContext, _ step: TaskStepRecord) async -> StepOutcome? {
        guard let unity, ctx.unityProject else { return nil }
        if let conn = unity.existingConnection(for: ctx.workspace.root), case .deny(let cat, let why) = UnityPolicy.allowsProjectFileEdit(status: conn.transport.currentStatus()) {
            return .failed(cat, why)
        }
        guard await unity.lock.acquire(root: ctx.workspace.root, taskID: ctx.record.id, owner: Self.leaseOwner(step)) else { return .cancelled }
        if let conn = unity.existingConnection(for: ctx.workspace.root), case .deny(let cat, let why) = UnityPolicy.allowsProjectFileEdit(status: conn.transport.currentStatus()) {
            unity.lock.release(owner: Self.leaseOwner(step))
            return .failed(cat, why)
        }
        return nil
    }

    // MARK: Run lifecycle

    /// Connects (asking for approval where the project would change), takes an audit run and a tool session. `nil` ⇒ the outcome is in `failure`.
    func beginUnityRun(_ ctx: TaskContext, _ step: TaskStepRecord, takeLock: Bool) async -> (UnityRun?, StepOutcome?) {
        guard let unity else { return (nil, .failed(.unityUnavailable, "Unity support is not available in this build or configuration.")) }
        guard ctx.unityProject else { return (nil, .failed(.unityUnavailable, "This folder is not a Unity project.")) }
        if takeLock {
            mutate(ctx) { $0.activity = "Waiting for the Unity editor" }
            guard await unity.lock.acquire(root: ctx.workspace.root, taskID: ctx.record.id, owner: Self.leaseOwner(step)) else { return (nil, .cancelled) }
        }
        var outcome = await unity.prepare(root: ctx.workspace.root, approvedInstall: ctx.unityInstallApproved, approvedUpgrade: ctx.unityUpgradeApproved, rendering: unityNeedsRendering(ctx),
                                          progress: { [weak self] m in self?.mutate(ctx) { $0.activity = m } })
        if outcome == .needsBridgeInstall {
            let ok = await requestApproval(ctx, step, action: "Install the JARVIS Unity Editor bridge into Packages/com.jarvis.bridge",
                                           reason: "JARVIS talks to the Unity editor through a small local Editor package (no network, no arbitrary code execution). It is added to your project's Packages folder.", risk: .medium)
            if ctx.cancelRequested || Task.isCancelled { return (nil, .cancelled) }
            guard ok else { return (nil, .failed(.approvalDenied, "Installing the JARVIS Unity bridge was not approved.")) }
            ctx.unityInstallApproved = true
            outcome = await unity.prepare(root: ctx.workspace.root, approvedInstall: true, approvedUpgrade: ctx.unityUpgradeApproved, rendering: unityNeedsRendering(ctx), progress: { [weak self] m in self?.mutate(ctx) { $0.activity = m } })
        }
        if case .needsUpgradeApproval(let declared, let candidate) = outcome {
            let ok = await requestApproval(ctx, step, action: "Open this project with Unity \(candidate) (it declares \(declared))",
                                           reason: "Opening a project with a different editor version can migrate (upgrade) its files. JARVIS will not do that unless you approve.", risk: .high)
            if ctx.cancelRequested || Task.isCancelled { return (nil, .cancelled) }
            guard ok else { return (nil, .failed(.approvalDenied, "Opening the project with a different Unity version was not approved.")) }
            ctx.unityUpgradeApproved = true
            outcome = await unity.prepare(root: ctx.workspace.root, approvedInstall: ctx.unityInstallApproved, approvedUpgrade: true, rendering: unityNeedsRendering(ctx), progress: { [weak self] m in self?.mutate(ctx) { $0.activity = m } })
        }
        switch outcome {
        case .ready: break
        case .failed(let cat, let why): return (nil, ctx.cancelRequested ? .cancelled : .failed(cat, why))
        case .needsBridgeInstall, .needsUpgradeApproval: return (nil, .failed(.approvalDenied, "Unity could not be prepared without a decision that was not given."))
        }
        let conn = unity.connection(for: ctx.workspace.root)
        let attempt = beginAttempt(ctx, step, .primary)
        let runID = audit.begin(agentType: "UnityTool", taskID: ctx.record.id, engine: .tool, model: nil, decision: nil, prompt: step.title, privacy: ctx.record.privacy, label: step.title, owner: .task)
        hub?.setPhase(runID, .running, activity: step.type.label)
        hub?.emit(runID, .toolStarted, source: "JARVIS", summary: "\(step.type.label): \(step.title)", detail: "Unity \(conn.status?.unityVersion ?? "?") · \((conn.root as NSString).lastPathComponent)")
        let session = UnityToolSession(capabilities: ctx.record.capabilities, taskID: ctx.record.id, runID: runID, hub: hub, destructiveRequested: ctx.record.destructiveRequested)
        session.approvedDirtyScenes = ctx.unityApprovedDirty
        session.goalIntent = UnityGoalIntent(goal: ctx.record.goal)
        session.approvedActions = ctx.unityApprovedActions
        updateStep(ctx, step.key) { $0.agentRunID = runID }
        let run = UnityRun(conn: conn, session: session, runID: runID, attempt: attempt)
        if ctx.unityBaseline == nil { await captureUnityBaseline(ctx, run) }
        return (run, nil)
    }

    func finishUnityRun(_ run: UnityRun, passed: Bool, cancelled: Bool = false, evidence: String) {
        audit.recordTool(run.runID, tool: "UnityTool", summary: "\(run.session.operationCount) operation(s)", status: passed ? "ok" : (cancelled ? "cancelled" : "failed"))
        audit.update(run.runID) { $0.toolsUsed = ["UnityTool"] }
        audit.finish(run.runID, status: cancelled ? .cancelled : (passed ? .succeeded : .failed), resultText: String(evidence.prefix(200)), validation: passed ? .passed : .failed)
        endAttempt(run.attempt, outcome: passed ? "passed" : (cancelled ? "cancelled" : "failed"), evidence: String(evidence.prefix(1500)), runID: run.runID)
    }

    // MARK: Console baseline / delta

    func captureUnityBaseline(_ ctx: TaskContext, _ run: UnityRun) async {
        guard let r = try? await run.conn.perform(.readConsole(afterSeq: 0, max: 200, types: ["Error", "Exception", "Assert"]), session: run.session) else { return }
        let entries = (r.result["entries"] as? [[String: Any]] ?? []).compactMap(UnityConsoleEntry.init(json:))
        let last = (r.result["lastSeq"] as? NSNumber)?.int64Value ?? 0
        ctx.unityBaseline = UnityConsoleAnalysis.baseline(entries, lastSeq: last)
        run.session.note(.toolFinished, "Console baseline captured (\(entries.count) existing error\(entries.count == 1 ? "" : "s") are not attributed to this task)")
    }

    func unityConsoleDelta(_ ctx: TaskContext, _ run: UnityRun) async -> UnityConsoleDelta? {
        guard let base = ctx.unityBaseline, let r = try? await run.conn.perform(.readConsole(afterSeq: base.lastSeq, max: 200, types: []), session: run.session) else { return nil }
        return UnityConsoleAnalysis.delta((r.result["entries"] as? [[String: Any]] ?? []).compactMap(UnityConsoleEntry.init(json:)), since: base)
    }

    func deltaLine(_ d: UnityConsoleDelta) -> String {
        "new Console errors: \(d.newErrors.count)" + (d.repeatedPreExisting.isEmpty ? "" : " (+\(d.repeatedPreExisting.count) repeat of an error that existed before the task)") + (d.warnings > 0 ? ", \(d.warnings) warning\(d.warnings == 1 ? "" : "s")" : "")
    }

    // MARK: Target resolution (never "the first object named X")

    func resolveUnityTarget(_ t: UnityTarget, _ run: UnityRun) async throws -> UnityObjectRef {
        if t.isPrecise {
            let r = try await run.conn.perform(.inspectGameObject(t, depth: 0, maxChildren: 0), session: run.session)
            guard let ref = UnityObjectRef(json: r.result) else { throw UnityToolError(category: .toolFailed, message: "The editor returned no object identity.") }
            run.conn.markHandles()
            return ref
        }
        guard let name = t.name, !name.isEmpty else { throw UnityToolError(category: .ambiguousTarget, message: "The target needs a path, a global ID or a name.") }
        let r = try await run.conn.perform(.findGameObjects(name: name, componentType: nil, max: 20), session: run.session)
        let found = (r.result["objects"] as? [[String: Any]] ?? []).compactMap(UnityObjectRef.init(json:))
        switch UnityPolicy.resolve(found) {
        case .unique(let ref): run.conn.markHandles(); return ref
        case .none: throw UnityToolError(category: .validationFailed, message: "No GameObject is named “\(name)” in the loaded scenes.")
        case .ambiguous(let c): throw UnityToolError(category: .ambiguousTarget, message: UnityPolicy.ambiguityMessage(name: name, candidates: c), candidates: c)
        }
    }

    /// Evaluates one expectation against the editor. `(holds, description)`; an unresolvable target is a plain `false`, never a guess.
    func evaluateExpectation(_ e: UnityExpectation, _ run: UnityRun) async throws -> (Bool, String) {
        guard let target = e.target else { return (false, "\(e.display): no target") }
        let ref: UnityObjectRef
        do { ref = try await resolveUnityTarget(target, run) }
        catch let err as UnityToolError where err.category == .validationFailed || err.message.contains("does not exist") || err.message.contains("targetNotFound") || err.message.lowercased().contains("not exist") {
            return (e.kind == .objectAbsent, e.kind == .objectAbsent ? "\(e.display) ✓" : "\(e.display) ✗ (not found)")
        } catch let err as UnityToolError where err.category == .toolFailed {
            return (e.kind == .objectAbsent, "\(e.display) \(e.kind == .objectAbsent ? "✓" : "✗ (\(err.message.prefix(80)))")")
        }
        let t = UnityTarget(ref)
        switch e.kind {
        case .objectExists: return (true, "\(e.display) ✓")
        case .objectAbsent: return (false, "\(e.display) ✗ (it exists)")
        case .componentPresent, .componentAbsent, .componentCount:
            let r = try await run.conn.perform(.inspectGameObject(t, depth: 0, maxChildren: 0), session: run.session)
            let n = (r.result["components"] as? [[String: Any]] ?? []).filter { ($0["type"] as? String) == e.componentType || ($0["fullType"] as? String) == e.componentType }.count
            switch e.kind {
            case .componentPresent: return (n >= 1, "\(e.display) \(n >= 1 ? "✓" : "✗")")
            case .componentAbsent: return (n == 0, "\(e.display) \(n == 0 ? "✓" : "✗ (\(n) found)")")
            default: return (n == (e.count ?? 1), "\(e.display) \(n == (e.count ?? 1) ? "✓" : "✗ (found \(n))")")
            }
        case .propertyEquals:
            guard let c = e.componentType, let p = e.propertyPath, let expected = e.value else { return (false, "\(e.display): incomplete expectation") }
            let r = try await run.conn.perform(.inspectSerializedProperties(t, componentType: c, componentIndex: e.componentIndex, propertyPaths: [p]), session: run.session)
            guard let prop = (r.result["properties"] as? [[String: Any]])?.first, let v = UnityValue(any: prop["value"]) else { return (false, "\(e.display) ✗ (property unreadable)") }
            return (v.matches(expected), "\(e.display) \(v.matches(expected) ? "✓" : "✗ (is \(v))")")
        case .objectVisible, .animatorInState, .animatorAdvancing, .audioPlaying:
            return try await evaluateOperatorExpectation(e, t, run)
        }
    }

    // MARK: Inspect

    func runUnityInspect(_ ctx: TaskContext, _ key: String) async -> StepOutcome {
        guard let step = ctx.step(key) else { return .failed(.toolFailed, "missing step") }
        let (maybe, early) = await beginUnityRun(ctx, step, takeLock: false)
        guard let run = maybe else { return early ?? .failed(.unityUnavailable, "Unity is not available.") }
        let params = step.unity ?? UnityStepParams()
        var lines: [String] = []
        var failures: [String] = []
        do {
            let info = try await run.conn.perform(.getProjectInfo, session: run.session)
            lines.append("Unity \(info.result["unityVersion"] as? String ?? "?") · \(info.result["renderPipeline"] as? String ?? "?") · project \(info.result["projectName"] as? String ?? "?")")
            // Make sure a project scene is open (opening is refused by the editor when anything unsaved would be lost).
            let scenes = try await run.conn.perform(.listScenes, session: run.session)
            let loaded = (scenes.result["loaded"] as? [[String: Any]] ?? []).compactMap(UnitySceneInfo.init(json:))
            let inProject = scenes.result["inProject"] as? [String] ?? []
            let want = params.scene ?? (loaded.contains(where: { !$0.path.isEmpty }) ? nil : (inProject.count == 1 ? inProject[0] : nil))
            if let want, !loaded.contains(where: { $0.path == want }) { _ = try await run.conn.perform(.openScene(path: want), session: run.session) }
            let active = try await run.conn.perform(.getActiveScene, session: run.session)
            let sc = UnitySceneInfo(json: active.result)
            lines.append("Scenes in project: \(inProject.prefix(8).joined(separator: ", ")) · active: \(sc?.path.isEmpty == false ? sc!.path : "(unsaved)")\(sc?.dirty == true ? " · has UNSAVED changes\(sc?.jarvisDirty == true ? " (by JARVIS)" : " (not by JARVIS)")" : "")")

            var names = params.targets
            if names.isEmpty { names = UnityNameGuess.names(from: [ctx.record.goal, step.title, step.details]) }
            for name in names.prefix(UnityStepParams.maxTargets) {
                let target = name.contains("/") || name.hasPrefix("GlobalObjectId") ? (name.hasPrefix("GlobalObjectId") ? UnityTarget(globalId: name) : UnityTarget(path: name)) : UnityTarget(name: name)
                if target.isPrecise {
                    do {
                        let o = try await run.conn.perform(.inspectGameObject(target, depth: 1, maxChildren: 20), session: run.session)
                        let c = try await run.conn.perform(.inspectComponents(target, types: [], maxProperties: 12), session: run.session)
                        lines.append(UnityRender.object(o.result) + "\n  components: " + UnityRender.components(of: o.result) + "\n" + UnityRender.properties(c.result))
                    } catch let e as UnityToolError { failures.append("\(name): \(e.message)") }
                } else {
                    let f = try await run.conn.perform(.findGameObjects(name: name, componentType: nil, max: 10), session: run.session)
                    let found = (f.result["objects"] as? [[String: Any]] ?? []).compactMap(UnityObjectRef.init(json:))
                    switch UnityPolicy.resolve(found) {
                    case .none: if params.targets.contains(name) { failures.append("“\(name)”: no such GameObject") }
                    case .unique(let ref):
                        let t = UnityTarget(ref)
                        let o = try await run.conn.perform(.inspectGameObject(t, depth: 1, maxChildren: 20), session: run.session)
                        let c = try await run.conn.perform(.inspectComponents(t, types: [], maxProperties: 12), session: run.session)
                        lines.append(UnityRender.object(o.result) + "\n  components: " + UnityRender.components(of: o.result) + "\n" + UnityRender.properties(c.result))
                    case .ambiguous(let c):
                        lines.append("AMBIGUOUS “\(name)”: " + c.prefix(6).map { "\($0.indexedPath ?? $0.path) (\($0.globalId ?? "no id"))" }.joined(separator: "; ") + " — a change must name one of these by path or global ID.")
                    }
                }
            }
            try await unityOperatorInspection(params, run, &lines, &failures)
            let comp = try await run.conn.perform(.getCompilationState, session: run.session)
            let cs = compilationState(comp)
            lines.append(UnityRender.compilation(cs))
            if let d = ctx.unityBaseline { lines.append("Console baseline: \(d.errorFingerprints.count) pre-existing error kind(s) (not attributed to this task)") }
            let play = try await run.conn.perform(.getPlayModeState, session: run.session)
            lines.append("Play Mode: \(play.result["state"] as? String ?? "?")")
        } catch let e as UnityToolError {
            finishUnityRun(run, passed: false, cancelled: e.category == .cancelled, evidence: e.message)
            return ctx.cancelRequested || e.category == .cancelled ? .cancelled : .failed(e.category, e.message)
        } catch { finishUnityRun(run, passed: false, evidence: "\(error)"); return .failed(.toolFailed, "\(error)") }

        if ctx.cancelRequested || Task.isCancelled { finishUnityRun(run, passed: false, cancelled: true, evidence: "cancelled"); return .cancelled }
        let rendered = String(lines.joined(separator: "\n").prefix(params.profile || !params.assets.isEmpty || params.capture != nil ? 6000 : 3500))
        verifying(ctx, key)
        ctx.results[key] = "Unity inspection:\n" + rendered
        if !failures.isEmpty {
            let why = "Requested object(s) not found: " + failures.joined(separator: "; ")
            finishUnityRun(run, passed: false, evidence: why)
            return .failed(.validationFailed, why)
        }
        let evidence = "Inspected the editor (\(lines.first.map { String($0.prefix(80)) } ?? "Unity"))"
        ctx.evidence.append(evidence)
        finishUnityRun(run, passed: true, evidence: evidence)
        setStep(ctx, key, to: .passed, evidence: evidence, result: ctx.results[key])
        return .passed
    }

    func compilationState(_ r: UnityResponse) -> UnityCompilationState {
        let errs = (r.result["errors"] as? [[String: Any]] ?? []).map { UnityCompilerError(file: $0["file"] as? String ?? "", line: ($0["line"] as? NSNumber)?.intValue ?? 0, rawMessage: $0["message"] as? String ?? "") }
        return UnityCompilationState(isCompiling: r.result["isCompiling"] as? Bool ?? false, generation: (r.result["generation"] as? NSNumber)?.intValue ?? 0,
                                     failed: r.result["scriptCompilationFailed"] as? Bool ?? false, errors: errs, warnings: (r.result["warnings"] as? NSNumber)?.intValue ?? 0,
                                     reloads: (r.result["reloads"] as? NSNumber)?.intValue ?? 0)
    }

    // MARK: Validate

    func runUnityValidate(_ ctx: TaskContext, _ key: String) async -> StepOutcome {
        guard let step = ctx.step(key) else { return .failed(.toolFailed, "missing step") }
        let (maybe, early) = await beginUnityRun(ctx, step, takeLock: false)
        guard let run = maybe else { return early ?? .failed(.unityUnavailable, "Unity is not available.") }
        let params = step.unity ?? UnityStepParams()
        var results: [(Bool, String)] = []
        do {
            for e in params.expectations { results.append(try await evaluateExpectation(e, run)) }
            let comp = compilationState(try await run.conn.perform(.getCompilationState, session: run.session))
            results.append((!comp.failed && comp.errors.isEmpty, UnityRender.compilation(comp)))
            if params.requireNoNewErrors, let d = await unityConsoleDelta(ctx, run) { results.append((!d.hasNewErrors, deltaLine(d) + (d.hasNewErrors ? ": " + d.newErrors.prefix(2).map(\.message).joined(separator: " | ") : ""))) }
        } catch let e as UnityToolError {
            finishUnityRun(run, passed: false, cancelled: e.category == .cancelled, evidence: e.message)
            return ctx.cancelRequested || e.category == .cancelled ? .cancelled : .failed(e.category, e.message)
        } catch { finishUnityRun(run, passed: false, evidence: "\(error)"); return .failed(.toolFailed, "\(error)") }
        if ctx.cancelRequested || Task.isCancelled { finishUnityRun(run, passed: false, cancelled: true, evidence: "cancelled"); return .cancelled }
        verifying(ctx, key)
        let ok = results.allSatisfy(\.0)
        let evidence = "Unity validation (structural): " + results.map(\.1).joined(separator: " · ")
        ctx.evidence.append(evidence)
        finishUnityRun(run, passed: ok, evidence: evidence)
        if ok { setStep(ctx, key, to: .passed, evidence: evidence, result: "validated"); return .passed }
        updateStep(ctx, key) { $0.validationEvidence = evidence }
        return .failed(.validationFailed, evidence)
    }

    // MARK: Compile

    struct UnityCompileResult { var state: UnityCompilationState; var recompiled: Bool; var reloaded: Bool }

    /// Asks Unity to compile and waits for ITS compiler state (not for a file command to finish).
    func unityCompileNow(_ run: UnityRun) async throws -> UnityCompileResult {
        let before = run.conn.transport.currentStatus()
        let genBefore = before?.compileGeneration ?? 0, reloadsBefore = before?.reloads ?? 0
        let r = try await run.conn.perform(.requestCompilation, session: run.session)
        var started = r.result["isCompiling"] as? Bool ?? false
        if !started { started = await run.conn.transport.waitForStatus(timeout: 3, { $0.isCompiling || $0.compileRunning || $0.compileGeneration > genBefore }) != nil }
        if started {
            let done = await run.conn.transport.waitForStatus(timeout: 420, { $0.compileGeneration > genBefore && !$0.isCompiling && !$0.compileRunning })
            if done == nil { throw UnityToolError(category: .unityTimeout, message: "Unity did not finish compiling within 7 minutes.") }
            // A successful compile reloads the domain; the next request is answered after the reload, so this also waits for it.
        }
        let st = compilationState(try await run.conn.perform(.getCompilationState, session: run.session, timeout: 180))
        let now = run.conn.transport.currentStatus()
        return UnityCompileResult(state: st, recompiled: started, reloaded: (now?.reloads ?? st.reloads) > reloadsBefore)
    }

    func compileCommandResult(_ r: UnityCompileResult, _ delta: UnityConsoleDelta?, duration: TimeInterval, requireNoNewErrors: Bool) -> CommandResult {
        let failed = r.state.failed || !r.state.errors.isEmpty
        var tail = UnityRender.compilation(r.state)
        var ok = !failed
        if requireNoNewErrors, let d = delta, d.hasNewErrors, !failed { ok = false; tail += "\nNew Console errors after compilation: " + d.newErrors.prefix(3).map(\.message).joined(separator: " | ") }
        return CommandResult(exitCode: ok ? 0 : 1, timedOut: false, cancelled: false, durationSeconds: duration, tail: tail, testCounts: nil)
    }

    func runUnityCompile(_ ctx: TaskContext, _ key: String) async -> StepOutcome {
        guard let step = ctx.step(key) else { return .failed(.toolFailed, "missing step") }
        let (maybe, early) = await beginUnityRun(ctx, step, takeLock: true)
        guard let run = maybe else { return early ?? .failed(.unityUnavailable, "Unity is not available.") }
        let params = step.unity ?? UnityStepParams()
        if let st = run.conn.transport.currentStatus(), st.isPlaying || st.state == "paused" {
            finishUnityRun(run, passed: false, evidence: "Play Mode is active")
            return .failed(.unsafeEditorState, "Unity is in Play Mode; scripts are not recompiled until it is back in Edit Mode.")
        }
        let started = Date()
        var result: CommandResult
        var last: UnityCompileResult?
        do {
            let r = try await unityCompileNow(run)
            last = r
            let delta = await unityConsoleDelta(ctx, run)
            result = compileCommandResult(r, delta, duration: Date().timeIntervalSince(started), requireNoNewErrors: params.requireNoNewErrors)
        } catch let e as UnityToolError {
            finishUnityRun(run, passed: false, cancelled: e.category == .cancelled, evidence: e.message)
            return ctx.cancelRequested || e.category == .cancelled ? .cancelled : .failed(e.category, e.message)
        } catch { finishUnityRun(run, passed: false, evidence: "\(error)"); return .failed(.toolFailed, "\(error)") }
        if ctx.cancelRequested || Task.isCancelled { finishUnityRun(run, passed: false, cancelled: true, evidence: "cancelled"); return .cancelled }
        verifying(ctx, key)
        if !result.succeeded {
            ctx.lastFailureTail[key] = result.tail
            if let fixed = await repairLoop(ctx, failing: step, first: result, rerun: { [self] _, _ in
                do {
                    let again = try await unityCompileNow(run)
                    last = again
                    let delta = await unityConsoleDelta(ctx, run)
                    return compileCommandResult(again, delta, duration: 0, requireNoNewErrors: params.requireNoNewErrors)
                } catch { return CommandResult(exitCode: 1, timedOut: false, cancelled: Task.isCancelled, durationSeconds: 0, tail: "\(error)", testCounts: nil) }
            }) { result = fixed }
            if ctx.cancelRequested || Task.isCancelled { finishUnityRun(run, passed: false, cancelled: true, evidence: "cancelled"); return .cancelled }
        }
        let st = last?.state
        let evidence = "Unity compile: " + (result.succeeded ? "PASS" : "FAIL") + " — " + (st.map { UnityRender.compilation($0) } ?? result.tail)
            + (last?.reloaded == true ? " · domain reloaded" : "") + (last?.recompiled == false ? " · no script changes needed recompiling" : "")
        ctx.evidence.append(evidence)
        finishUnityRun(run, passed: result.succeeded, evidence: evidence)
        if result.succeeded { ctx.lastFailureTail[key] = nil; setStep(ctx, key, to: .passed, evidence: evidence, result: "compiled"); return .passed }
        updateStep(ctx, key) { $0.validationEvidence = evidence + "\n" + String(result.tail.suffix(1200)) }
        return .failed(.compileFailed, evidence)
    }

    // MARK: Tests

    func unityRunTestsNow(_ run: UnityRun, mode: UnityTestMode, names: [String], groups: [String], assemblies: [String]) async throws -> UnityTestResult {
        let scope = (names + groups + assemblies).isEmpty ? "all \(mode.label) tests" : (names + groups + assemblies).prefix(4).joined(separator: ", ")
        let accepted = try await run.conn.perform(.runTests(mode: mode, testNames: names, groupNames: groups, assemblyNames: assemblies), session: run.session)
        guard let runId = accepted.result["runId"] as? String else { throw UnityToolError(category: .toolFailed, message: "Unity did not accept the test run.") }
        let timeout: TimeInterval = mode == .playMode ? 600 : 300
        let finished = await run.conn.transport.waitForStatus(timeout: timeout, { $0.testRun?.runId == runId && ($0.testRun?.isFinished ?? false) })
        if finished == nil {
            _ = try? await run.conn.perform(.cancelTests, session: run.session)
            throw UnityToolError(category: .unityTimeout, message: "The Unity test run did not finish within \(Int(timeout / 60)) minutes.")
        }
        // A PlayMode run leaves Play Mode again on its own AFTER it reports its result: wait for the editor to be idle before anything else uses it.
        _ = await run.conn.transport.waitForStatus(timeout: 120, { $0.isIdleEdit || $0.compileFailed })
        let r = try await run.conn.perform(.getTestRun, session: run.session, timeout: 120)
        func n(_ k: String) -> Int { (r.result[k] as? NSNumber)?.intValue ?? 0 }
        let cases = (r.result["cases"] as? [[String: Any]] ?? []).prefix(200).map { c in
            UnityTestCase(name: c["name"] as? String ?? "?", status: c["status"] as? String ?? "?", message: String((c["message"] as? String ?? "").prefix(300)))
        }
        return UnityTestResult(mode: mode.rawValue, requestedScope: scope, actualTotal: n("total"), passed: n("passed"), failed: n("failed"), skipped: n("skipped"), inconclusive: n("inconclusive"),
                               durationSeconds: (r.result["durationSeconds"] as? NSNumber)?.doubleValue ?? 0, cases: Array(cases), state: r.result["state"] as? String ?? "?")
    }

    func testCommandResult(_ t: UnityTestResult, duration: TimeInterval) -> CommandResult {
        var tail = "\(t.summary) [scope: \(t.requestedScope)]"
        if t.actualTotal == 0 { tail += "\nNo test matched the requested scope." }
        for c in t.cases where c.status != "Passed" { tail += "\n✗ \(c.name) (\(c.status))" + (c.message.isEmpty ? "" : ": \(c.message)") }
        return CommandResult(exitCode: t.succeeded ? 0 : 1, timedOut: false, cancelled: false, durationSeconds: duration, tail: String(tail.prefix(4000)),
                             testCounts: TestCounts(total: t.actualTotal, passed: t.passed, failed: t.failed))
    }

    func runUnityTest(_ ctx: TaskContext, _ key: String) async -> StepOutcome {
        guard let step = ctx.step(key) else { return .failed(.toolFailed, "missing step") }
        let params = step.unity ?? UnityStepParams()
        guard let mode = params.testMode else { return .failed(.malformedPlan, "A Unity test step needs a testMode (editMode or playMode).") }
        let (maybe, early) = await beginUnityRun(ctx, step, takeLock: true)
        guard let run = maybe else { return early ?? .failed(.unityUnavailable, "Unity is not available.") }
        let started = Date()
        var last: UnityTestResult?
        var result: CommandResult
        do {
            let t = try await unityRunTestsNow(run, mode: mode, names: params.testNames, groups: params.groupNames, assemblies: params.assemblyNames)
            last = t
            result = testCommandResult(t, duration: Date().timeIntervalSince(started))
        } catch let e as UnityToolError {
            await unityCleanup(run, cancelTests: true)
            finishUnityRun(run, passed: false, cancelled: e.category == .cancelled, evidence: e.message)
            return ctx.cancelRequested || e.category == .cancelled ? .cancelled : .failed(e.category, e.message)
        } catch { finishUnityRun(run, passed: false, evidence: "\(error)"); return .failed(.toolFailed, "\(error)") }
        if ctx.cancelRequested || Task.isCancelled { await unityCleanup(run, cancelTests: true); finishUnityRun(run, passed: false, cancelled: true, evidence: "cancelled"); return .cancelled }
        verifying(ctx, key)
        if !result.succeeded {
            ctx.lastFailureTail[key] = result.tail
            if let fixed = await repairLoop(ctx, failing: step, first: result, rerun: { [self] _, _ in
                do {
                    let c = try await unityCompileNow(run)
                    if c.state.failed || !c.state.errors.isEmpty { return compileCommandResult(c, nil, duration: 0, requireNoNewErrors: false) }
                    let t = try await unityRunTestsNow(run, mode: mode, names: params.testNames, groups: params.groupNames, assemblies: params.assemblyNames)
                    last = t
                    return testCommandResult(t, duration: 0)
                } catch { return CommandResult(exitCode: 1, timedOut: false, cancelled: Task.isCancelled, durationSeconds: 0, tail: "\(error)", testCounts: nil) }
            }) { result = fixed }
            if ctx.cancelRequested || Task.isCancelled { finishUnityRun(run, passed: false, cancelled: true, evidence: "cancelled"); return .cancelled }
        }
        let evidence = "Unity tests: " + (result.succeeded ? "PASS" : "FAIL") + " — " + (last.map { "\($0.summary) · scope: \($0.requestedScope) · \(String(format: "%.1f", $0.durationSeconds)) s" } ?? result.tail)
        ctx.evidence.append(evidence)
        finishUnityRun(run, passed: result.succeeded, evidence: evidence)
        if result.succeeded { ctx.lastFailureTail[key] = nil; setStep(ctx, key, to: .passed, evidence: evidence, result: last?.summary); return .passed }
        updateStep(ctx, key) { $0.validationEvidence = evidence + "\n" + String(result.tail.suffix(1500)) }
        return .failed(.testFailed, evidence)
    }

    // MARK: Play Mode

    func runUnityPlayMode(_ ctx: TaskContext, _ key: String) async -> StepOutcome {
        guard let step = ctx.step(key) else { return .failed(.toolFailed, "missing step") }
        let params = step.unity ?? UnityStepParams()
        let (maybe, early) = await beginUnityRun(ctx, step, takeLock: true)
        guard let run = maybe else { return early ?? .failed(.unityUnavailable, "Unity is not available.") }
        var entered = false
        var startedPlay = false          // THIS step asked for Play Mode (or took over an owned editor's leftover one): only then does it leave it again
        var notes: [String] = []
        var checks: [(Bool, String)] = []
        var failure: UnityToolError?
        do {
            if let st = run.conn.transport.currentStatus() {
                if st.isPlaying && st.owned {
                    // An editor JARVIS started itself, left in Play Mode by an earlier (interrupted) run: it is JARVIS' to reset.
                    run.session.note(.warning, "Leaving a Play Mode left over by an interrupted run (the editor is owned by JARVIS)", severity: .warning)
                    await unityCleanup(run, exitPlay: true)
                } else if st.isPlaying { throw UnityToolError(category: .unsafeEditorState, message: "Unity is already in Play Mode (not started by this task); JARVIS does not take it over.") }
                if st.compileFailed || st.isCompiling { throw UnityToolError(category: .compileFailed, message: st.isCompiling ? "Unity is still compiling." : "The project has script compile errors; Play Mode cannot be entered.") }
            }
            _ = try await run.conn.perform(.enterPlayMode, session: run.session)
            startedPlay = true
            let playing = await run.conn.transport.waitForStatus(timeout: 120, { $0.isPlaying && $0.state == "playing" })
            guard playing != nil else { throw UnityToolError(category: .unityTimeout, message: "Unity did not report Play Mode within 2 minutes.") }
            entered = true
            notes.append("entered Play Mode (confirmed by the editor)")
            // Bounded observation: ends early if the editor leaves Play Mode on its own (crash, exit).
            let seconds = min(max(params.observeSeconds ?? 3, 1), UnityStepParams.maxObserve)
            let left = await run.conn.transport.waitForStatus(timeout: TimeInterval(seconds), { !$0.isPlaying })
            if left != nil { checks.append((false, "Play Mode ended by itself during observation")); entered = false }
            else {
                for e in params.expectations { checks.append(try await evaluateExpectation(e, run)) }
            }
        } catch let e as UnityToolError { failure = e }
        catch { failure = UnityToolError(category: .toolFailed, message: "\(error)") }

        // Always leave Play Mode again (even after a failure or a cancellation) and wait for the editor to confirm.
        var exited = !entered
        if startedPlay, entered || (run.conn.transport.currentStatus()?.isPlaying ?? false) || run.conn.transport.currentStatus()?.state == "enteringPlay" {
            await unityCleanup(run, exitPlay: true)
            exited = run.conn.transport.currentStatus().map { !$0.isPlaying } ?? true
            notes.append(exited ? "left Play Mode (confirmed)" : "COULD NOT confirm leaving Play Mode")
        }
        if ctx.cancelRequested || Task.isCancelled { finishUnityRun(run, passed: false, cancelled: true, evidence: "cancelled; Play Mode \(exited ? "left" : "still active")"); return .cancelled }
        if let failure { finishUnityRun(run, passed: false, evidence: failure.message); return .failed(failure.category, failure.message) }
        if params.requireNoNewErrors, let d = await unityConsoleDelta(ctx, run) {
            checks.append((!d.hasNewErrors, deltaLine(d) + (d.hasNewErrors ? ": " + d.newErrors.prefix(2).map(\.message).joined(separator: " | ") : "")))
        }
        verifying(ctx, key)
        let ok = entered || notes.contains("left Play Mode (confirmed)")
        let all = ok && exited && checks.allSatisfy(\.0)
        let evidence = "Unity Play Mode: " + (all ? "PASS" : "FAIL") + " — " + (notes + checks.map(\.1)).joined(separator: " · ")
        ctx.evidence.append(evidence)
        finishUnityRun(run, passed: all, evidence: evidence)
        if all { setStep(ctx, key, to: .passed, evidence: evidence, result: "observed"); return .passed }
        updateStep(ctx, key) { $0.validationEvidence = evidence }
        return .failed(.validationFailed, evidence)
    }

    /// Cleanup that must run even when the task was cancelled: an unstructured task is not cancelled with its parent.
    func unityCleanup(_ run: UnityRun, exitPlay: Bool = false, cancelTests: Bool = false) async {
        await Task { @MainActor in
            if cancelTests { _ = try? await run.conn.perform(.cancelTests, session: run.session, timeout: 10) }
            if exitPlay {
                _ = try? await run.conn.perform(.exitPlayMode, session: run.session, timeout: 30)
                _ = await run.conn.transport.waitForStatus(timeout: 60, { !$0.isPlaying && $0.state != "enteringPlay" })
            }
        }.value
    }

    // MARK: Edit

    func runUnityEdit(_ ctx: TaskContext, _ key: String) async -> StepOutcome {
        guard let step = ctx.step(key) else { return .failed(.toolFailed, "missing step") }
        let params = step.unity ?? UnityStepParams()
        let (maybe, early) = await beginUnityRun(ctx, step, takeLock: true)
        guard let run = maybe else { return early ?? .failed(.unityUnavailable, "Unity is not available.") }

        // 1. The actions: explicit typed ones from the plan, or proposed by the Unity agent (a provider) from the inspection.
        var actions: [UnityEditAction] = []
        var agentRun: UUID?
        if let json = params.actionsJSON { actions = UnityActionParser.parse(json).actions }
        if actions.isEmpty && params.correction == nil {
            let proposed = await proposeUnityActions(ctx, step, run)
            switch proposed {
            case .cancelled: finishUnityRun(run, passed: false, cancelled: true, evidence: "cancelled"); return .cancelled
            case .failed(let cat, let why): finishUnityRun(run, passed: false, evidence: why); return .failed(cat, why)
            case .passed: actions = ctx.unityProposed[key] ?? []; agentRun = ctx.unityProposalRuns[key]
            case .skipped: break
            }
        }
        guard !actions.isEmpty || params.correction != nil else { finishUnityRun(run, passed: false, evidence: "no actions"); return .failed(.validationFailed, "The Unity agent proposed no usable action.") }
        if actions.contains(where: { $0.operation.isDestructive }) && !ctx.record.destructiveRequested {
            finishUnityRun(run, passed: false, evidence: "deletion not requested")
            return .failed(.securityBlocked, "The goal did not ask for anything to be deleted, so a Unity deletion was refused.")
        }
        _ = agentRun

        // 2. Unsaved work that is not JARVIS' own is never overwritten silently.
        if let st = run.conn.transport.currentStatus(), !st.userDirtyScenes.isEmpty, !st.userDirtyScenes.allSatisfy({ ctx.unityApprovedDirty.contains($0.path) }) {
            let names = st.userDirtyScenes.map { $0.path.isEmpty ? "(untitled scene)" : $0.path }.joined(separator: ", ")
            let ok = await requestApproval(ctx, step, action: "Modify Unity scene with your unsaved changes: \(names)",
                                           reason: "The scene has unsaved changes JARVIS did not make. JARVIS records their baseline and only continues (and saves the scene, including those changes) if you approve.", risk: .high)
            if ctx.cancelRequested || Task.isCancelled { finishUnityRun(run, passed: false, cancelled: true, evidence: "cancelled"); return .cancelled }
            guard ok else { finishUnityRun(run, passed: false, evidence: "approval denied"); return .failed(.approvalDenied, "Modifying a scene that has your unsaved changes was not approved.") }
            ctx.unityApprovedDirty.formUnion(st.userDirtyScenes.map(\.path)); run.session.approvedDirtyScenes = ctx.unityApprovedDirty
        }

        // 2b. Git-dirty scene FILES (the V0.4 protection of the user's uncommitted work applies to Unity assets too: unsaved editor state and
        //     uncommitted file state are different things, and both matter).
        if let st = run.conn.transport.currentStatus() {
            let gitDirty = Set((ctx.record.gitBaseline?.dirtyPaths ?? []) + (ctx.record.gitBaseline?.untrackedPaths ?? []))
            let touching = st.scenes.map(\.path).filter { !$0.isEmpty && gitDirty.contains($0) && !ctx.approvedDirty.contains($0) }
            if !touching.isEmpty {
                let ok = await requestApproval(ctx, step, action: "Modify Unity scene file(s) with your uncommitted changes: \(touching.joined(separator: ", "))",
                                               reason: "These scene files already differ from the last commit. JARVIS recorded that baseline and only changes and saves them if you approve.", risk: .high)
                if ctx.cancelRequested || Task.isCancelled { finishUnityRun(run, passed: false, cancelled: true, evidence: "cancelled"); return .cancelled }
                guard ok else { finishUnityRun(run, passed: false, evidence: "approval denied"); return .failed(.approvalDenied, "Modifying a scene file with your uncommitted changes was not approved.") }
                ctx.approvedDirty.formUnion(touching)
            }
        }

        // 3. Apply each action: resolve exactly one target, run the typed operation, verify in the editor.
        var done: [String] = [], verified = true
        do {
            for action in actions {
                if ctx.cancelRequested || Task.isCancelled { finishUnityRun(run, passed: false, cancelled: true, evidence: "cancelled"); return .cancelled }
                let (line, ok) = try await applyUnityAction(action.operation, ctx, step, run)
                done.append(line); verified = verified && ok
            }
            // V0.13: bounded observe → act → inspect → correct for an objective the plan names (an object clearly visible to the camera).
            if let corr = params.correction {
                let (met, line) = try await runVisibilityCorrection(ctx, step, run, corr)
                done.append(line); verified = verified && met
            }
            // Save exactly the scenes this step (or an approved user edit) made dirty — nothing else.
            if params.save, let st = run.conn.transport.currentStatus() {
                let toSave = st.scenes.filter { $0.dirty && ($0.jarvisDirty || ctx.unityApprovedDirty.contains($0.path)) }
                for s in toSave {
                    guard !s.path.isEmpty else { throw UnityToolError(category: .unsafeEditorState, message: "The changed scene has never been saved (no asset path); save it once in Unity, then run the task again.") }
                    _ = try await run.conn.perform(.saveScene(scene: s.path), session: run.session)
                    done.append("saved \(s.path)")
                }
            }
            for e in params.expectations { let (ok, line) = try await evaluateExpectation(e, run); verified = verified && ok; done.append(line) }
        } catch let e as UnityToolError {
            let msg = e.message + (e.candidates.isEmpty ? "" : " Candidates: " + e.candidates.prefix(4).map { $0.indexedPath ?? $0.path }.joined(separator: ", "))
            finishUnityRun(run, passed: false, cancelled: e.category == .cancelled, evidence: msg)
            return ctx.cancelRequested || e.category == .cancelled ? .cancelled : .failed(e.category, msg)
        } catch { finishUnityRun(run, passed: false, evidence: "\(error)"); return .failed(.toolFailed, "\(error)") }

        verifying(ctx, key)
        let evidence = "Unity edit: " + done.joined(separator: "; ") + (verified ? " — verified in the editor" : " — NOT verified")
        ctx.evidence.append(evidence)
        finishUnityRun(run, passed: verified, evidence: evidence)
        if verified { setStep(ctx, key, to: .passed, evidence: evidence, result: done.joined(separator: "; ")); return .passed }
        updateStep(ctx, key) { $0.validationEvidence = evidence }
        return .failed(.validationFailed, evidence)
    }

    /// Runs one typed action and checks the editor's state afterwards. Returns a one-line description and whether the post-state holds.
    func applyUnityAction(_ op: UnityOperation, _ ctx: TaskContext, _ step: TaskStepRecord, _ run: UnityRun) async throws -> (String, Bool) {
        switch op {
        case .addComponent(let t, let type, let ifAbsent):
            let ref = try await resolveUnityTarget(t, run)
            let r = try await run.conn.perform(.addComponent(UnityTarget(ref), componentType: type, ifAbsent: ifAbsent), session: run.session)
            let present = try await componentCount(UnityTarget(ref), type, run)
            let already = r.result["alreadyPresent"] as? Bool == true
            return ("\(already ? "\(type) already present on" : "added \(type) to") \(ref.indexedPath ?? ref.path)", present >= 1)
        case .setSerializedProperty(let t, let type, let idx, let path, let old, let new):
            let ref = try await resolveUnityTarget(t, run)
            let target = UnityTarget(ref)
            let r = try await run.conn.perform(.setSerializedProperty(target, componentType: type, componentIndex: idx, propertyPath: path, expectedOld: old, newValue: new), session: run.session)
            let back = try await run.conn.perform(.inspectSerializedProperties(target, componentType: type, componentIndex: idx, propertyPaths: [path]), session: run.session)
            let now = (back.result["properties"] as? [[String: Any]])?.first.flatMap { UnityValue(any: $0["value"]) }
            let already = r.result["alreadyApplied"] as? Bool == true
            return ("\(already ? "\(type).\(path) was already \(new)" : "set \(type).\(path) = \(new)") on \(ref.indexedPath ?? ref.path)", now?.matches(new) == true)
        case .createGameObject(let name, let scene, let parent, let prim, let pos, let rot, let sc, let ifAbsent):
            var parentTarget: UnityTarget?
            if let parent { parentTarget = UnityTarget(try await resolveUnityTarget(parent, run)) }
            let r = try await run.conn.perform(.createGameObject(name: name, scene: scene, parent: parentTarget, primitive: prim, position: pos, rotation: rot, scale: sc, ifAbsent: ifAbsent), session: run.session)
            guard let obj = (r.result["object"] as? [String: Any]).flatMap(UnityObjectRef.init(json:)) else { return ("create \(name)", false) }
            let again = try? await run.conn.perform(.inspectGameObject(UnityTarget(obj), depth: 0, maxChildren: 0), session: run.session)
            return ("\(r.result["alreadyExists"] as? Bool == true ? "\(name) already existed" : "created \(name)") at \(obj.indexedPath ?? obj.path)", again != nil)
        case .deleteGameObject(let t):
            let ref: UnityObjectRef
            do { ref = try await resolveUnityTarget(t, run) }
            catch let e as UnityToolError where e.category == .validationFailed { return ("\(t.display) was already gone", true) }
            let ok = await requestApproval(ctx, step, action: "Delete Unity object \(ref.indexedPath ?? ref.path) in \(ref.scene.isEmpty ? "the unsaved scene" : ref.scene)",
                                           reason: "The task asked for it explicitly. JARVIS records an Undo step, but the deletion is permanent once the scene is saved.", risk: .high)
            if ctx.cancelRequested || Task.isCancelled { throw UnityToolError(category: .cancelled, message: "cancelled") }
            guard ok else { throw UnityToolError(category: .approvalDenied, message: "Deleting \(ref.indexedPath ?? ref.path) was not approved.") }
            _ = try await run.conn.perform(.deleteGameObject(UnityTarget(ref)), session: run.session, approvedDestructive: true)
            let gone: Bool
            do { _ = try await run.conn.perform(.inspectGameObject(UnityTarget(ref), depth: 0, maxChildren: 0), session: run.session); gone = false } catch { gone = true }
            return ("deleted \(ref.indexedPath ?? ref.path) after approval", gone)
        case .createPrefab(let t, let assetPath):
            let ref = try await resolveUnityTarget(t, run)
            _ = try await run.conn.perform(.createPrefab(UnityTarget(ref), assetPath: assetPath), session: run.session)
            return ("created prefab \(assetPath) from \(ref.indexedPath ?? ref.path)", FileManager.default.fileExists(atPath: ctx.workspace.root + "/" + assetPath))
        case .dev(let d):
            guard d.isPersistentMutation else { throw UnityToolError(category: .securityBlocked, message: "\(op.wireName) is not an edit operation.") }
            return try await applyDevAction(d, ctx, step, run)
        default:
            throw UnityToolError(category: .securityBlocked, message: "\(op.wireName) is not an edit operation.")
        }
    }

    func componentCount(_ target: UnityTarget, _ type: String, _ run: UnityRun) async throws -> Int {
        let r = try await run.conn.perform(.inspectGameObject(target, depth: 0, maxChildren: 0), session: run.session)
        return (r.result["components"] as? [[String: Any]] ?? []).filter { ($0["type"] as? String) == type || ($0["fullType"] as? String) == type }.count
    }

    // MARK: Unity agent (a provider proposes typed actions; JARVIS validates and executes them)

    func proposeUnityActions(_ ctx: TaskContext, _ step: TaskStepRecord, _ run: UnityRun) async -> StepOutcome {
        let inspection = ctx.steps.filter { $0.type == .unityInspect && $0.state == .passed }.compactMap { ctx.results[$0.key] }
        let analysis = ctx.steps.filter { $0.type == .analysis && $0.state == .passed }.compactMap { ctx.results[$0.key] }
        let prompt = UnityPrompts.edit(goal: ctx.record.goal, step: step, inspection: inspection, analysis: analysis, allowDelete: ctx.record.destructiveRequested)
        let box = ValidationBox<Bool>()
        var excluded: Set<RoutingCandidate> = []
        var problems: [String] = []
        for round in 0..<2 {
            if ctx.cancelRequested || Task.isCancelled { return .cancelled }
            let attempt = beginAttempt(ctx, step, round == 0 ? .primary : .escalation)
            let job = AgentJob(type: "UnityAgent", title: "Unity actions · \(step.title)", prompt: prompt + (problems.isEmpty ? "" : "\n\nYour previous answer was rejected: " + problems.joined(separator: "; ") + ". Reply again with ONE corrected JSON object."),
                               profile: jobProfile(ctx, nil, promptChars: prompt.count), taskID: ctx.record.id,
                               validator: { text in
                                   let r = UnityActionParser.parse(text)
                                   box.set(r.problems.isEmpty, notes: r.problems + (r.policyBlock ? ["policy"] : []))
                                   return BenchmarkSuite.Verdict(passed: r.problems.isEmpty, detail: r.problems.joined(separator: "; "))
                               }, timeout: limits.providerTimeout, exclude: excluded)
            let result = await runJob(ctx, job)
            switch result {
            case .completed(let text, let runID, let cand, _):
                let parsed = UnityActionParser.parse(text)
                ctx.candidates[step.key, default: []].append(cand)
                endAttempt(attempt, outcome: parsed.problems.isEmpty ? "passed" : "failed:\(FailureCategory.validationFailed.rawValue)", evidence: parsed.problems.isEmpty ? "\(parsed.actions.count) typed action(s)" : parsed.problems.joined(separator: "; "), runID: runID, candidate: cand)
                if parsed.problems.isEmpty { ctx.unityProposed[step.key] = parsed.actions; ctx.unityProposalRuns[step.key] = runID; return .passed }
                if parsed.policyBlock { return .failed(.securityBlocked, "The Unity agent asked for something JARVIS never does (code, menu items or shell): " + parsed.problems.joined(separator: "; ")) }
                problems = parsed.problems
            case .cancelled: endAttempt(attempt, outcome: "cancelled", evidence: nil); return .cancelled
            default:
                let (cat, why) = failure(from: result)
                var cand: RoutingCandidate?
                if case .failed(_, _, _, let c) = result { cand = c; if let c { excluded.insert(c) } }
                endAttempt(attempt, outcome: "failed:\(cat.rawValue)", evidence: why, candidate: cand)
                if box.detail.contains("policy") { return .failed(.securityBlocked, "The Unity agent asked for something JARVIS never does (code, menu items or shell).") }
                if round == 0, canEscalate(ctx), cand != nil { noteEscalationNeeded(ctx, step, why); continue }
                return .failed(cat, why)
            }
        }
        return .failed(.validationFailed, "The Unity agent did not produce valid typed actions: " + problems.joined(separator: "; "))
    }
}

enum UnityPrompts {
    /// The operator operations, as the provider is told about them. Settings keys come from the same whitelist the bridge enforces.
    static var operatorOperations: String {
        let kinds = UnityComponentSchema.table.keys.sorted().map { "\($0): " + (UnityComponentSchema.table[$0] ?? [:]).keys.sorted().joined(separator: ", ") }.joined(separator: "\n          ")
        return """
        - {"op": "editGameObject", "target": {...}, "name": "...", "active": true, "parent": {...} or null (= scene root), "siblingIndex": 0, "position": [x,y,z], "rotation": [x,y,z], "scale": [x,y,z], "space": "local|world", "tag": "...", "layer": "..."}  (any subset)
        - {"op": "duplicateGameObject", "target": {...}, "name": "Copy"}
        - {"op": "configureComponent", "target": {...}, "kind": "light|camera|renderer|rigidbody|collider|characterController|audioSource|animator|canvas|rectTransform", "settings": {...}}
          settings per kind (a colour is [r,g,b] or [r,g,b,a] in 0–1; a reference is an "Assets/…" path):
          \(kinds)
        - {"op": "setObjectReference", "target": {...}, "componentType": "MeshRenderer", "propertyPath": "...", "assetPath": "Assets/…" or null}
        - {"op": "instantiatePrefab", "assetPath": "Assets/…prefab", "parent": {...}, "name": "...", "position": [x,y,z]}   {"op": "createPrefabVariant", "sourceAssetPath": "…prefab", "assetPath": "…prefab"}
        - {"op": "revertPrefabOverrides", "target": {...}} (only overrides JARVIS made)   {"op": "applyPrefabOverrides", "target": {...}} (only overrides JARVIS made; the user must approve)
        - {"op": "createMaterial", "assetPath": "Assets/…mat", "shader": "Universal Render Pipeline/Lit" or "copyFrom": "Assets/…mat"}   {"op": "setMaterialProperty", "assetPath": "Assets/…mat", "property": "_BaseColor", "value": [r,g,b,a]}  (use property names shown by an asset inspection)
        - {"op": "setEnvironment", "property": "ambientLight|ambientIntensity|ambientMode|fog|fogColor|fogDensity|…", "value": ...}
        - {"op": "createAnimatorController", "assetPath": "Assets/…controller"}   {"op": "editAnimatorController", "assetPath": "…controller", "action": "addParameter|addState|setDefaultState|setStateSpeed|setStateMotion|addTransition|addBlendTreeState", "layer": 0, "name": "...", "motion": "Assets/…anim" or "Assets/…fbx::ClipName", "from": "…", "to": "…", "conditions": [{"parameter": "…", "mode": "If|IfNot|Greater|Less|Equals|NotEqual", "threshold": 0}]}
        - {"op": "setModelImporter", "assetPath": "Assets/…fbx", "settings": {"animationType": "Humanoid", "importAnimation": true, "clipLoop": ["ClipName", true]}} (the user must approve; JARVIS records the previous values)
        """
    }

    static func edit(goal: String, step: TaskStepRecord, inspection: [String], analysis: [String], allowDelete: Bool) -> String {
        """
        You are the Unity component of JARVIS, an autonomous task engine. Propose the typed Unity Editor operations that achieve ONE step. You cannot run code: JARVIS validates each operation, applies it through a fixed list of editor operations, and verifies the result in the editor.

        Overall goal: \(goal)
        Current step: \(step.title)
        Step details: \(step.details)
        Expected outcome: \(step.expected)
        \(inspection.isEmpty ? "" : "\nWhat JARVIS read from the editor:\n" + inspection.joined(separator: "\n---\n") + "\n")\(analysis.isEmpty ? "" : "\nAnalysis so far:\n" + analysis.joined(separator: "\n---\n") + "\n")
        Reply with ONE JSON object and nothing else:
        {"summary": "one sentence", "actions": [ ... at most 8 ... ]}
        Each action is one of:
        - {"op": "addComponent", "target": {"path": "Hierarchy/Path"} or {"globalId": "..."}, "componentType": "BoxCollider"}
        - {"op": "setSerializedProperty", "target": {...}, "componentType": "Counter", "propertyPath": "startValue", "expectedOld": 1, "newValue": 5}
        - {"op": "createGameObject", "name": "Name", "parent": {"path": "..."} (optional), "primitive": "None|Cube|Sphere|Capsule|Cylinder|Plane|Quad", "position": [0,0,0] (optional)}
        - {"op": "createPrefab", "target": {...}, "assetPath": "Assets/Prefabs/Name.prefab"}\(allowDelete ? "\n- {\"op\": \"deleteGameObject\", \"target\": {...}} (the user must approve it)\n- {\"op\": \"removeComponent\", \"target\": {...}, \"componentType\": \"BoxCollider\"} and {\"op\": \"unpackPrefab\", \"target\": {...}} (the user must approve each)" : "")
        \(UnityPrompts.operatorOperations)
        Rules: identify objects by "path" (use the indexed form like "Twin#1" when several share a name) or "globalId" taken from the text above — never by name alone when the text shows more than one object with that name. Use only component types and property paths shown above or standard Unity components. Always give "expectedOld" when you change a property. Never include code, scripts, menu items, commands, URLs or anything that is not one of these operations. If the step cannot be done with these operations, reply with an empty "actions" array and explain in "summary".
        """
    }
}
