import Foundation

/// V0.13 — the Unity development operator inside the V0.4 Unity steps (no new step type, no second engine): `unityEdit` applies the new typed operations, `unityInspect` can profile a
/// scene, read assets and capture the camera, and the new expectations are checked against the editor itself.
extension TaskEngine {
    /// A task whose plan captures the camera (or expects something to be VISIBLE) needs an editor with a graphics device.
    func unityNeedsRendering(_ ctx: TaskContext) -> Bool {
        ctx.steps.contains { s in
            guard let u = s.unity else { return false }
            return u.capture != nil || u.expectations.contains { $0.kind == .objectVisible }
        }
    }

    // MARK: Targets

    /// Replaces every named/imprecise target of an operation by the ONE object it resolves to (ambiguous or missing ⇒ the operation does not run).
    func resolveDevTargets(_ d: UnityDevOp, _ run: UnityRun) async throws -> UnityDevOp {
        func r(_ t: UnityTarget) async throws -> UnityTarget { UnityTarget(try await resolveUnityTarget(t, run)) }
        switch d {
        case .editGameObject(let t, var e):
            if case .to(let p) = e.parent { e.parent = .to(try await r(p)) }
            return .editGameObject(try await r(t), e)
        case .duplicateGameObject(let t, let n): return .duplicateGameObject(try await r(t), name: n)
        case .removeComponent(let t, let c, let i): return .removeComponent(try await r(t), componentType: c, index: i)
        case .setObjectReference(let t, let c, let i, let p, let a): return .setObjectReference(try await r(t), componentType: c, index: i, propertyPath: p, assetPath: a)
        case .configureComponent(let t, let k, let s): return .configureComponent(try await r(t), kind: k, settings: s)
        case .unpackPrefab(let t, let c): return .unpackPrefab(try await r(t), completely: c)
        case .revertPrefabOverrides(let t): return .revertPrefabOverrides(try await r(t))
        case .applyPrefabOverrides(let t): return .applyPrefabOverrides(try await r(t))
        case .prefabOverrides(let t): return .prefabOverrides(try await r(t))
        case .instantiatePrefab(let p, let sc, let par, let n, let pos, let rot, let scl, let ia):
            var parent: UnityTarget?
            if let par { parent = try await r(par) }
            return .instantiatePrefab(assetPath: p, scene: sc, parent: parent, name: n, position: pos, rotation: rot, scale: scl, ifAbsent: ia)
        default: return d
        }
    }

    // MARK: Apply (the unityEdit step)

    func applyDevAction(_ d: UnityDevOp, _ ctx: TaskContext, _ step: TaskStepRecord, _ run: UnityRun) async throws -> (String, Bool) {
        let op = try await resolveDevTargets(d, run)
        if case .needsApproval(let action, let reason, let risk) = run.conn.authorize(.dev(op), session: run.session) {
            // Unsaved user scene work is asked about once for the whole step (before this loop); everything else is asked per action, naming exactly what will happen.
            if !action.hasPrefix("Modify Unity scene with your unsaved changes") {
                let ok = await requestApproval(ctx, step, action: action, reason: reason, risk: risk)
                if ctx.cancelRequested || Task.isCancelled { throw UnityToolError(category: .cancelled, message: "cancelled") }
                guard ok else { throw UnityToolError(category: .approvalDenied, message: "“\(action)” was not approved.") }
                ctx.unityApprovedActions.insert(action); run.session.approvedActions.insert(action)
            }
        }
        let r = try await run.conn.perform(.dev(op), session: run.session)
        let (ok, line) = UnityDevVerifier.verify(op, r)
        if case .setModelImporter = op, let prev = r.result["previous"] as? [String: Any] {
            ctx.unityFacts.append("previous import settings of \(op.assetPaths.first ?? "?"): " + String(prev.map { "\($0.key)=\(UnityValue(any: $0.value).map(\.description) ?? "…")" }.sorted().joined(separator: ", ").prefix(240)))
        }
        return (line, ok)
    }

    // MARK: Read helpers

    /// Renders the Game camera into memory (the bridge writes a PNG to its spool; JARVIS reads it and deletes the file at once). Nothing is stored.
    func unityCapture(_ spec: UnityCaptureSpec, _ run: UnityRun, camera: UnityTarget? = nil, resolved: [UnityTarget]? = nil) async throws -> UnityCaptureResult {
        var targets: [UnityTarget] = resolved ?? []
        if resolved == nil {
            for n in spec.targets.prefix(8) { targets.append(UnityTarget(try await resolveUnityTarget(n.contains("/") || n.contains("#") ? UnityTarget(path: n) : (n.hasPrefix("GlobalObjectId") ? UnityTarget(globalId: n) : UnityTarget(name: n)), run))) }
        }
        let r = try await run.conn.perform(.dev(.captureView(camera: camera, width: spec.width, height: spec.height, targets: targets)), session: run.session, timeout: 90)
        return try Self.loadCapture(r, root: run.conn.root)
    }

    nonisolated static func loadCapture(_ r: UnityResponse, root: String) throws -> UnityCaptureResult {
        guard let rel = r.result["file"] as? String, rel.hasPrefix("captures/"), !rel.contains(".."), rel.hasSuffix(".png") else { throw UnityToolError(category: .toolFailed, message: "The editor returned no capture file.") }
        let url = URL(fileURLWithPath: root).appendingPathComponent("Library/JarvisBridge").appendingPathComponent(rel)
        defer { try? FileManager.default.removeItem(at: url) }                     // the picture lives in memory only
        guard let data = try? Data(contentsOf: url), data.count > 100, data.count < 8_000_000 else { throw UnityToolError(category: .toolFailed, message: "The capture could not be read.") }
        func n(_ k: String) -> Int { (r.result[k] as? NSNumber)?.intValue ?? 0 }
        return UnityCaptureResult(png: data, width: n("width"), height: n("height"), camera: r.result["camera"] as? String ?? "?", luminance: UnityLuminance(json: r.result["luminance"] as? [String: Any] ?? [:]),
                                  objects: (r.result["targets"] as? [[String: Any]] ?? []).compactMap(UnityObjectVisibility.init(json:)))
    }

    func unityRuntime(_ targets: [UnityTarget], states: [String] = [], _ run: UnityRun) async throws -> [UnityRuntimeObject] {
        let r = try await run.conn.perform(.dev(.inspectRuntime(targets: targets, animatorStates: states)), session: run.session)
        return (r.result["targets"] as? [[String: Any]] ?? []).map(UnityRuntimeObject.init(json:))
    }

    // MARK: New expectations

    func evaluateOperatorExpectation(_ e: UnityExpectation, _ target: UnityTarget, _ run: UnityRun) async throws -> (Bool, String) {
        switch e.kind {
        case .objectVisible:
            let c = try await unityCapture(UnityCaptureSpec(width: 480, height: 270), run, resolved: [target])
            guard let v = c.objects.first else { return (false, "\(e.display) ✗ (no analysis)") }
            return (v.visible, "\(e.display) \(v.visible ? "✓" : "✗") — \(v.summary)")
        case .animatorInState:
            guard let name = e.value?.string else { return (false, "\(e.display): no state name") }
            let o = try await unityRuntime([target], states: [name], run).first
            let ok = o?.animatorState[name] == true
            return (ok, "\(e.display) \(ok ? "✓" : "✗")\(ok ? "" : " (clips: \(o?.animatorClips.joined(separator: ", ") ?? "none"))")")
        case .animatorAdvancing:
            let a = try await unityRuntime([target], run).first
            _ = await run.conn.transport.waitForStatus(timeout: 0.7, { _ in false })           // a bounded, event-based wait between two samples (no sleeping poll)
            let b = try await unityRuntime([target], run).first
            guard let t0 = a?.normalizedTime, let t1 = b?.normalizedTime, a?.hasController == true else { return (false, "\(e.display) ✗ (no running animator)") }
            let moved = abs(t1 - t0) > 0.001
            return (moved, "\(e.display) \(moved ? "✓" : "✗") (normalized time \(String(format: "%.3f", t0)) → \(String(format: "%.3f", t1)))")
        case .audioPlaying:
            let o = try await unityRuntime([target], run).first
            return (o?.audioPlaying == true, "\(e.display) \(o?.audioPlaying == true ? "✓" : "✗")")
        default: return (false, "\(e.display): not an operator expectation")
        }
    }

    // MARK: Inspection additions (profile, assets, capture)

    func unityOperatorInspection(_ params: UnityStepParams, _ run: UnityRun, _ lines: inout [String], _ failures: inout [String]) async throws {
        if params.profile {
            let p = try await run.conn.perform(.dev(.sceneProfile(scene: params.scene, maxObjects: 2_000)), session: run.session)
            lines.append(UnityRender.sceneProfile(p.result))
            let l = try await run.conn.perform(.dev(.inspectLighting(scene: params.scene)), session: run.session)
            lines.append(UnityRender.lighting(l.result))
        }
        for a in params.assets.prefix(UnityStepParams.maxAssets) {
            do { lines.append(UnityRender.asset(try await run.conn.perform(.dev(.inspectAsset(path: a)), session: run.session).result)) }
            catch let e as UnityToolError { failures.append("\(a): \(e.message)") }
        }
        if let cap = params.capture {
            do {
                let c = try await unityCapture(cap, run)
                lines.append("Camera " + c.summary + " · picture " + c.hash)
            } catch let e as UnityToolError { failures.append("capture: \(e.message)") }
        }
    }
}
