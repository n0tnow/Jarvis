import Foundation

/// V0.13 — the bounded observe → act → inspect → correct loop inside a `unityEdit` step. Every action goes through the same typed operations, policy, approvals and verification as any other
/// edit; the loop only decides WHICH typed operation to try next from measured facts (geometry, contrast, light), and it stops at `maxRounds`.
extension TaskEngine {
    private func vec(_ any: Any?) -> [Double]? { (any as? [NSNumber])?.map(\.doubleValue).nilIfWrongCount(3) }

    func captureFacts(_ target: UnityTarget, _ run: UnityRun) async throws -> (UnityCaptureResult, FrameFacts) {
        let cap = try await unityCapture(UnityCaptureSpec(width: 480, height: 270), run, resolved: [target])
        let vis = cap.objects.first ?? UnityObjectVisibility(json: ["exists": false])!
        let light = try await run.conn.perform(.dev(.inspectLighting(scene: nil)), session: run.session).result
        let lights = (light["lights"] as? [[String: Any]] ?? []).map { LightFact(path: $0["path"] as? String ?? "", enabled: $0["enabled"] as? Bool ?? false, intensity: ($0["intensity"] as? NSNumber)?.doubleValue ?? 0, type: $0["type"] as? String ?? "") }
        let ambient = ((light["environment"] as? [String: Any])?["ambientIntensity"] as? NSNumber)?.doubleValue ?? 1
        let obj = try await run.conn.perform(.inspectGameObject(target, depth: 0, maxChildren: 0), session: run.session).result
        let cam = try await run.conn.perform(.inspectGameObject(UnityTarget(path: cap.camera), depth: 0, maxChildren: 0), session: run.session).result
        let facts = FrameFacts(visibility: vis, luminance: cap.luminance, lights: lights, ambientIntensity: ambient, cameraPath: cap.camera, cameraPosition: vec(cam["worldPosition"]) ?? [0, 0, 0],
                               objectPosition: vec(obj["boundsCenter"]) ?? vec(obj["worldPosition"]), objectRadius: (obj["boundsRadius"] as? NSNumber)?.doubleValue ?? 1)
        return (cap, facts)
    }

    /// Returns (objective met, evidence line). Throws only for tool errors; a correction that could not succeed is a normal `false` with its remaining uncertainty.
    func runVisibilityCorrection(_ ctx: TaskContext, _ step: TaskStepRecord, _ run: UnityRun, _ spec: UnityCorrectionSpec) async throws -> (Bool, String) {
        let bounded = min(spec.maxRounds, ctx.continuation?.maxCorrectionRounds ?? spec.maxRounds)
        let target = UnityTarget(try await resolveUnityTarget(spec.target.contains("/") || spec.target.contains("#") ? UnityTarget(path: spec.target) : UnityTarget(name: spec.target), run))
        var rounds: [String] = []
        var hashes: [String] = []
        for round in 0...bounded {
            if ctx.cancelRequested || Task.isCancelled { throw UnityToolError(category: .cancelled, message: "cancelled") }
            let (cap, facts) = try await captureFacts(target, run)
            hashes.append(cap.hash)
            recordVisual(ctx, step, provider: "unity-capture", hash: cap.hash, subject: spec.target, query: "is it clearly visible?", outcome: facts.visibility.visible ? "visible" : "not visible", detail: facts.visibility.summary)
            if facts.visibility.visible {
                let line = "Visibility (round \(round)): \(facts.visibility.summary) · picture \(cap.hash)" + (rounds.isEmpty ? "" : " — corrected by: " + rounds.joined(separator: "; "))
                ctx.unityFacts.append("OBJECTIVE: " + line)
                return (true, line)
            }
            if round == bounded {
                let line = "Visibility NOT achieved after \(bounded) correction round\(bounded == 1 ? "" : "s"): \(facts.visibility.summary) · picture \(cap.hash)" + (rounds.isEmpty ? "" : " — tried: " + rounds.joined(separator: "; ")) + ". Remaining uncertainty: JARVIS stopped; what else to change is your call."
                ctx.unityFacts.append("OBJECTIVE: " + line)
                return (false, line)
            }
            guard let (actions, why) = OperatorCorrection.plan(round: round + 1, facts) else {
                let line = "Visibility NOT achieved: \(facts.visibility.summary) · JARVIS has no objective correction left to try. Picture \(cap.hash)"
                ctx.unityFacts.append("OBJECTIVE: " + line)
                return (false, line)
            }
            mutate(ctx) { $0.activity = "Correcting (round \(round + 1)/\(bounded)): \(why)" }
            for a in actions { rounds.append("round \(round + 1): " + a.summary) ; try await applyCorrection(a, ctx, step, run, facts) }
        }
        return (false, "Visibility not achieved")
    }

    private func applyCorrection(_ a: CorrectionAction, _ ctx: TaskContext, _ step: TaskStepRecord, _ run: UnityRun, _ f: FrameFacts) async throws {
        func must(_ r: (String, Bool)) throws { if !r.1 { throw UnityToolError(category: .validationFailed, message: "A correction was not confirmed by the editor: \(r.0)") } }
        switch a {
        case .aimCamera(let path, let pos, let rot):
            try must(try await applyDevAction(.editGameObject(UnityTarget(path: path), GameObjectEdit(position: pos, rotation: rot, worldSpace: true)), ctx, step, run))
        case .addFillLight:
            _ = try await applyUnityAction(.createGameObject(name: OperatorCorrection.fillLightName, scene: nil, parent: nil, primitive: "None", position: nil, rotation: [50, -30, 0], scale: nil, ifAbsent: true), ctx, step, run)
            let t = UnityTarget(path: OperatorCorrection.fillLightName)
            _ = try await applyUnityAction(.addComponent(t, componentType: "Light", ifAbsent: true), ctx, step, run)
            try must(try await applyDevAction(try UnityDevOp.configure(t, kind: "light", settings: ["type": .string("Directional"), "intensity": .number(1.2), "shadows": .string("Soft")]), ctx, step, run))
        case .setLightIntensity(let path, let v):
            try must(try await applyDevAction(try UnityDevOp.configure(UnityTarget(path: path), kind: "light", settings: ["intensity": .number(v)]), ctx, step, run))
        case .setAmbient(let v):
            try must(try await applyDevAction(try UnityDevOp.environment(property: "ambientIntensity", value: .number(v)), ctx, step, run))
        }
    }

    /// Visual evidence: WHICH picture (hash), WHICH provider, WHAT it reported. Never the pixels.
    func recordVisual(_ ctx: TaskContext, _ step: TaskStepRecord, provider: String, hash: String, subject: String?, query: String?, outcome: String, detail: String?, injectionNotes: Int = 0) {
        try? repository?.insert(VisualObservationRecord(taskID: ctx.record.id, stepKey: step.key, provider: provider, pictureHash: hash, subject: subject, query: query, outcome: outcome, detail: detail, injectionNotes: injectionNotes))
    }
}

private extension Array where Element == Double {
    func nilIfWrongCount(_ n: Int) -> [Double]? { count == n ? self : nil }
}
