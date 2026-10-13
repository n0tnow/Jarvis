import Foundation
import CoreGraphics

/// V0.13 — the `experiment` step. A bounded question is tested in a DISPOSABLE Unity project JARVIS creates under its own experiments root, judged against evidence from the editor
/// (compile state, Console, geometry, pixels), and the environment is deleted again — also when the step fails, is stopped or the time budget runs out. The user's project is
/// only ever READ (its Unity version and a fingerprint, to prove it was not touched).
extension TaskEngine {
    func runExperiment(_ ctx: TaskContext, _ key: String) async -> StepOutcome {
        guard let step = ctx.step(key), let spec = step.unity?.experiment else { return .failed(.malformedPlan, "An experiment step needs an experiment contract.") }
        guard ctx.record.capabilities.allows(.runExperiment) else { return .failed(.capabilityDenied, "This task does not grant running experiments.") }
        guard let unity, let root = experimentsRoot else { return .failed(.unityUnavailable, "Experiments are not available in this configuration.") }
        let problems = ExperimentValidator.validate(spec, realProjectRoots: [ctx.workspace.root])
        if !problems.isEmpty { return .failed(problems.contains { if case .unsafe = $0 { true } else { false } } ? .securityBlocked : .malformedPlan, problems.map(\.description).joined(separator: "; ")) }

        let ws = ExperimentWorkspace(root: root)
        let taskID = ctx.record.id
        var record = ExperimentRecord(id: ws.id, taskID: ctx.record.id, stepKey: key, projectKey: nil, spec: spec, environmentPath: ws.path.path, status: "running", result: nil, cleanupState: "pending")
        do { try ws.create(taskID: ctx.record.id, kind: spec.kind) } catch { return .failed(.toolFailed, "The experiment environment could not be created: \(error.localizedDescription)") }
        try? repository?.save(record)
        let realFingerprintBefore = ProjectContinuity.treeFingerprint(root: ctx.workspace.root)
        let started = Date()
        let deadline = started.addingTimeInterval(TimeInterval(spec.minutes * 60))
        var facts: [ExperimentFact] = []
        var hashes: [String] = []
        var inconclusive: String?
        var seq = 0
        func fact(_ s: String, _ c: FactClass, _ e: String) { facts.append(ExperimentFact(statement: s, factClass: c, evidence: e)) }
        func stepLog(_ k: ExperimentStepKind, _ status: String, _ evidence: String?) { seq += 1; try? repository?.addExperimentStep(experimentID: ws.id, seq: seq, kind: k, status: status, evidence: evidence) }
        let project = ws.projectPath
        var editorOpened = false
        var cancelled = false

        stepLoop: for kind in spec.kind.steps {
            if ctx.cancelRequested || Task.isCancelled { cancelled = true; break }
            if Date() > deadline { inconclusive = "the time budget of \(spec.minutes) min ended"; break }
            if ws.sizeBytes() > spec.diskMegabytes * 1_048_576 { inconclusive = "the disk budget of \(spec.diskMegabytes) MB was exceeded"; break }
            mutate(ctx) { $0.activity = "Experiment · \(kind.label)" }
            do {
                switch kind {
                case .createEnvironment:
                    try Self.createDisposableProject(at: project, version: unity.editors.first(where: \.available)?.version.description ?? "6000.5.1f1")
                    stepLog(kind, "ok", "a clean Unity project under the JARVIS experiments root")
                case .importAsset:
                    guard let id = spec.acquisitionID, let rec = (try? repository?.acquisition(id)) ?? nil, let web else { inconclusive = "the quarantined asset is not available"; break stepLoop }
                    guard web.acquisition.verifyStored(rec) else { inconclusive = "the quarantined file no longer matches its recorded SHA-256"; break stepLoop }
                    let extracted = try await Task.detached { try web.acquisition.extractForImport(rec) }.value
                    let wsGuard = try WorkspaceGuard(rootPath: project)
                    let plan = try AssetImporter.prepare(record: rec, extractedRoot: extracted.root, files: extracted.files, workspace: wsGuard, unityProject: true, includeCode: false)
                    let report = try await Task.detached { try AssetImporter.apply(plan, record: rec, taskID: taskID, workspace: wsGuard) }.value
                    fact("\(report.copied) file(s) were copied into a clean project (\(report.skipped) left out: scripts/executables are never copied)", .tested, "hash-verified copy of the quarantined, inspected artifact")
                    stepLog(kind, "ok", "copied \(report.copied), skipped \(report.skipped)")
                case .openEditor:
                    _ = try UnityBridgeInstaller.install(root: project)
                    let outcome = await unity.prepare(root: project, approvedInstall: true, approvedUpgrade: true, rendering: true, progress: { [weak self] m in self?.mutate(ctx) { $0.activity = "Experiment · \(m)" } })
                    guard outcome == .ready else { inconclusive = "the disposable editor could not be started"; break stepLoop }
                    editorOpened = true
                    stepLog(kind, "ok", "editor connected (render-capable)")
                case .compileAndConsole:
                    let conn = unity.connection(for: project)
                    _ = await conn.transport.waitForStatus(timeout: 420, { $0.isIdleEdit && !$0.compileRunning })
                    let s = UnityToolSession(capabilities: CapabilitySet(granted: TaskCapability.unityDevelopment), taskID: ctx.record.id, runID: nil, hub: nil, destructiveRequested: false)
                    let comp = try await conn.perform(.getCompilationState, session: s).result
                    let errs = (comp["errors"] as? [Any])?.count ?? 0
                    let failed = comp["scriptCompilationFailed"] as? Bool ?? false
                    let con = try await conn.perform(.readConsole(afterSeq: 0, max: 200, types: ["Error", "Exception"]), session: s).result
                    let consoleErrors = (con["entries"] as? [[String: Any]] ?? []).compactMap { $0["message"] as? String }
                    fact(failed || errs > 0 ? "Unity reported \(errs) compile error(s)" : "Unity imported and compiled the project without compile errors", .tested, "the editor's own compiler state")
                    fact(consoleErrors.isEmpty ? "The Console shows no import errors" : "The Console shows \(consoleErrors.count) error(s): \(consoleErrors.prefix(2).map { String($0.prefix(80)) }.joined(separator: " | "))", .tested, "structured Console entries")
                    stepLog(kind, failed || errs > 0 || !consoleErrors.isEmpty ? "issues" : "ok", "compile errors \(errs), console errors \(consoleErrors.count)")
                case .discover:
                    let found = Self.listAssets(under: project + "/Assets/ThirdParty")
                    fact("Imported content: \(found.prefabs.count) prefab(s), \(found.models.count) model(s), \(found.materials.count) material(s), \(found.textures.count) texture(s), \(found.audio.count) audio, \(found.clips.count) animation(s)", .verified, "file listing of the disposable project")
                    ctx.results[key + ".assets"] = (found.prefabs + found.models).prefix(3).joined(separator: "\n")
                    stepLog(kind, "ok", "\(found.prefabs.count + found.models.count) instantiable")
                case .instantiateAndCapture:
                    let r = try await experimentRender(ctx, step, project: project, spec: spec, discovered: (ctx.results[key + ".assets"] ?? "").split(separator: "\n").map(String.init), fact: fact, hashes: &hashes)
                    stepLog(kind, r ? "ok" : "issues", nil)
                case .playAndObserve:
                    let r = try await experimentPlayback(ctx, step, project: project, spec: spec, fact: fact)
                    stepLog(kind, r ? "ok" : "issues", nil)
                case .evaluate:
                    stepLog(kind, "ok", nil)
                }
            } catch {
                if ctx.cancelRequested || Task.isCancelled { cancelled = true } else { inconclusive = "\(kind.label) failed: \(error)" }
                stepLog(kind, "failed", "\(error)")
                break stepLoop
            }
        }

        // Cleanup ALWAYS: close JARVIS' own editor for the disposable project, then delete the environment (marker-checked, inside the root only).
        await Task { @MainActor in
            if editorOpened { await unity.closeOwnedEditor(root: project) }
        }.value
        let deleted = ws.delete()

        let untouched = ProjectContinuity.treeFingerprint(root: ctx.workspace.root) == realFingerprintBefore
        if cancelled { record.status = "cancelled"; record.cleanupState = deleted ? "deleted" : "failed"; record.finishedAt = Date(); try? repository?.save(record); return .cancelled }
        let result = Self.judge(spec: spec, facts: facts, inconclusive: inconclusive, seconds: Date().timeIntervalSince(started), deleted: deleted, hashes: hashes, untouched: untouched)
        record.status = result.verdict == .inconclusive && inconclusive != nil ? "failed" : "concluded"
        record.result = result; record.cleanupState = deleted ? "deleted" : "failed"; record.finishedAt = Date()
        try? repository?.save(record)
        ctx.evidence.append("Experiment “\(spec.question.prefix(80))”: \(result.verdict.rawValue.uppercased()) — \(result.summary)")
        ctx.unityFacts.append("EXPERIMENT \(result.verdict.rawValue.uppercased()): \(result.summary)")
        ctx.results[key] = (result.facts.map { "[\($0.factClass.rawValue)] \($0.statement)" }).joined(separator: "\n")
        guard deleted else { return .failed(.toolFailed, "The experiment finished but its environment could not be deleted: \(ws.path.path)") }
        guard untouched else { return .failed(.securityBlocked, "The real project changed while an experiment ran (it must never be touched).") }
        if result.verdict == .inconclusive { return .failed(.validationFailed, "Inconclusive: \(result.summary)") }
        let evidence = "Experiment \(result.verdict.rawValue): \(result.summary)"
        setStep(ctx, key, to: .passed, evidence: evidence, result: result.summary)
        return .passed
    }

    // MARK: Judging (pure)

    nonisolated static func judge(spec: ExperimentSpec, facts: [ExperimentFact], inconclusive: String?, seconds: Double, deleted: Bool, hashes: [String], untouched: Bool) -> ExperimentResult {
        let tested = facts.filter { $0.factClass == .tested }
        func has(_ needle: String) -> Bool { tested.contains { $0.statement.localizedCaseInsensitiveContains(needle) } }
        var met: [String] = [], hit: [String] = []
        if inconclusive == nil, tested.isEmpty {
            return ExperimentResult(verdict: .inconclusive, summary: "no verdict: nothing was tested (only unverified facts exist)", facts: facts, successMet: [], failureHit: [], seconds: seconds, environmentDeleted: deleted, pictureHashes: hashes, projectUntouched: untouched)
        }
        if let why = inconclusive {
            return ExperimentResult(verdict: .inconclusive, summary: "no verdict: \(why)", facts: facts, successMet: [], failureHit: [], seconds: seconds, environmentDeleted: deleted, pictureHashes: hashes, projectUntouched: untouched)
        }
        if has("without compile errors") { met.append("the project compiles") } else if has("compile error") { hit.append("the project does not compile") }
        if has("no import errors") { met.append("no Console errors after the import") } else if has("error(s)") && tested.contains(where: { $0.statement.hasPrefix("The Console shows") }) { hit.append("the Console shows errors") }
        if spec.kind != .animationPlayback {
            if has("instantiated") { met.append("an object can be instantiated") } else if spec.kind == .assetImport { hit.append("nothing could be instantiated") }
            if has("visible") && !has("not clearly visible") { met.append("it renders visibly") } else if has("not clearly visible") || has("outside the camera") { hit.append("it does not render visibly") }
            if has("does not render pink") { met.append("it does not render pink") } else if has("renders magenta") { hit.append("it renders pink (a missing shader or an unsupported material under this pipeline)") }
        } else {
            if has("animation is running") { met.append("the animation runs") } else { hit.append("the animation did not run") }
        }
        let verdict: ExperimentResult.Verdict = hit.isEmpty && !met.isEmpty ? .confirmed : (hit.isEmpty ? .inconclusive : .refuted)
        let summary = verdict == .confirmed ? "the hypothesis held: " + met.joined(separator: ", ") : (verdict == .refuted ? "the hypothesis failed: " + hit.joined(separator: ", ") + (met.isEmpty ? "" : " (held: " + met.joined(separator: ", ") + ")") : "no check could be made")
        return ExperimentResult(verdict: verdict, summary: summary, facts: facts, successMet: met, failureHit: hit, seconds: seconds, environmentDeleted: deleted, pictureHashes: hashes, projectUntouched: untouched)
    }

    // MARK: Environment

    nonisolated static func createDisposableProject(at root: String, version: String) throws {
        let fm = FileManager.default
        for d in ["Assets", "ProjectSettings", "Packages"] { try fm.createDirectory(atPath: root + "/" + d, withIntermediateDirectories: true) }
        try "m_EditorVersion: \(version)\n".write(toFile: root + "/ProjectSettings/ProjectVersion.txt", atomically: true, encoding: .utf8)
        let modules = ["physics", "animation", "audio", "ui", "imageconversion", "jsonserialize", "particlesystem"].map { "\"com.unity.modules.\($0)\": \"1.0.0\"" }.joined(separator: ",\n    ")
        try "{\n  \"dependencies\": {\n    \(modules)\n  }\n}\n".write(toFile: root + "/Packages/manifest.json", atomically: true, encoding: .utf8)
    }

    struct ListedAssets { var prefabs: [String] = [], models: [String] = [], materials: [String] = [], textures: [String] = [], audio: [String] = [], clips: [String] = [] }

    nonisolated static func listAssets(under dir: String, limit: Int = 400) -> ListedAssets {
        var out = ListedAssets()
        guard let en = FileManager.default.enumerator(atPath: dir) else { return out }
        var n = 0
        let base = dir.components(separatedBy: "/Assets/").last.map { "Assets/" + $0 } ?? dir
        for case let rel as String in en {
            n += 1; if n > limit { break }
            let ext = (rel as NSString).pathExtension.lowercased()
            let asset = base + "/" + rel
            switch ext {
            case "prefab": out.prefabs.append(asset)
            case "fbx", "obj", "dae", "blend", "gltf", "glb": out.models.append(asset)
            case "mat": out.materials.append(asset)
            case "png", "jpg", "jpeg", "tga", "psd", "exr": out.textures.append(asset)
            case "wav", "mp3", "ogg", "aif", "aiff": out.audio.append(asset)
            case "anim": out.clips.append(asset)
            default: break
            }
        }
        return out
    }

    // MARK: Render (assetImport / materialRender)

    private func experimentRender(_ ctx: TaskContext, _ step: TaskStepRecord, project: String, spec: ExperimentSpec, discovered: [String], fact: (String, FactClass, String) -> Void, hashes: inout [String]) async throws -> Bool {
        guard let unity else { return false }
        let conn = unity.connection(for: project)
        var goal = UnityGoalIntent(); goal.sceneCreation = true
        let session = UnityToolSession(capabilities: CapabilitySet(granted: TaskCapability.unityDevelopment), taskID: ctx.record.id, runID: nil, hub: nil, destructiveRequested: false)
        session.goalIntent = goal
        let run = UnityRun(conn: conn, session: session, runID: UUID(), attempt: StepAttemptRecord(stepID: step.id, taskID: ctx.record.id, number: 1, kind: .primary, outcome: "running"))
        _ = try await conn.perform(.dev(.createScene(path: "Assets/ExperimentScene.unity", empty: false)), session: session)
        var instance: String?
        let candidates = spec.assetPaths.isEmpty ? discovered : spec.assetPaths
        if spec.kind == .materialRender, let m = candidates.first(where: { $0.hasSuffix(".mat") }) {
            _ = try await conn.perform(.createGameObject(name: "ExperimentSubject", scene: nil, parent: nil, primitive: "Sphere", position: [0, 0, 0], rotation: nil, scale: nil, ifAbsent: true), session: session)
            _ = try await conn.perform(.dev(try UnityDevOp.configure(UnityTarget(path: "ExperimentSubject"), kind: "renderer", settings: ["material": .string(m)])), session: session)
            instance = "ExperimentSubject"
            fact("The material was assigned to a test sphere", .tested, "typed renderer assignment, verified")
        } else {
            for path in candidates.prefix(3) where !path.hasSuffix(".mat") {
                if let r = try? await conn.perform(.dev(.instantiatePrefab(assetPath: path, scene: nil, parent: nil, name: "ExperimentSubject", position: [0, 0, 0], rotation: nil, scale: nil, ifAbsent: true)), session: session), r.result["object"] != nil {
                    instance = "ExperimentSubject"
                    fact("\(path) was instantiated in a new scene", .tested, "typed instantiation, verified in the editor"); break
                }
            }
        }
        guard let subject = instance else { return false }
        // Observe → act → inspect → correct, bounded (aim the camera / add light until it is clearly visible, or report why not)
        let corr = UnityCorrectionSpec(target: subject, maxRounds: min(ctx.continuation?.maxCorrectionRounds ?? 2, 2))
        let (visible, line) = try await runVisibilityCorrection(ctx, step, run, corr)
        let cap = try await unityCapture(UnityCaptureSpec(width: 640, height: 360), run, resolved: [UnityTarget(path: subject)])
        hashes.append(cap.hash)
        let pink = PictureAnalysis.magentaFraction(png: cap.png)
        fact(visible ? "The subject is visible in the render" : "The subject is not clearly visible in the render", .tested, line)
        fact(pink > 0.15 ? "The render shows magenta (\(Int(pink * 100)) % of the picture): a missing shader or an unsupported material under this pipeline" : "The render does not render pink", .tested, "pixel check of picture \(cap.hash)")
        if let grounder = visual, grounder.mode() != .off {
            let a = await grounder.answer(image: VisualImageCoding.cgImage(png: cap.png) ?? CGImage.placeholder, query: .describe("In one short sentence: what object is in the centre of this 3D render, and what colour is it?"), sensitivity: .project)
            if a.found, let t = a.text { fact("Model-observed: \(t.prefix(160))", .inferred, "\(a.provider) looked at picture \(cap.hash) (a reading of the picture, not a measurement)"); recordVisual(ctx, step, provider: a.provider, hash: cap.hash, subject: subject, query: "describe the subject", outcome: "described", detail: t, injectionNotes: a.injectionNotes.count) }
        }
        return visible && pink <= 0.15
    }

    private func experimentPlayback(_ ctx: TaskContext, _ step: TaskStepRecord, project: String, spec: ExperimentSpec, fact: (String, FactClass, String) -> Void) async throws -> Bool {
        guard let unity else { return false }
        let conn = unity.connection(for: project)
        var goal = UnityGoalIntent(); goal.sceneCreation = true
        let session = UnityToolSession(capabilities: CapabilitySet(granted: TaskCapability.unityDevelopment), taskID: ctx.record.id, runID: nil, hub: nil, destructiveRequested: false)
        session.goalIntent = goal
        guard let controller = spec.assetPaths.first(where: { $0.hasSuffix(".controller") }) else { fact("The animation did not run: no controller was given", .tested, "contract"); return false }
        _ = try await conn.perform(.dev(.createScene(path: "Assets/ExperimentScene.unity", empty: false)), session: session)
        _ = try await conn.perform(.createGameObject(name: "ExperimentSubject", scene: nil, parent: nil, primitive: "Cube", position: [0, 0.5, 0], rotation: nil, scale: nil, ifAbsent: true), session: session)
        _ = try await conn.perform(.addComponent(UnityTarget(path: "ExperimentSubject"), componentType: "Animator", ifAbsent: true), session: session)
        _ = try await conn.perform(.dev(try UnityDevOp.configure(UnityTarget(path: "ExperimentSubject"), kind: "animator", settings: ["controller": .string(controller)])), session: session)
        _ = try await conn.perform(.enterPlayMode, session: session)
        defer { Task { @MainActor in _ = try? await conn.perform(.exitPlayMode, session: session); _ = await conn.transport.waitForStatus(timeout: 60, { !$0.isPlaying }) } }
        guard await conn.transport.waitForStatus(timeout: 120, { $0.isPlaying && $0.state == "playing" }) != nil else { return false }
        let t = UnityTarget(path: "ExperimentSubject")
        func sample() async throws -> UnityRuntimeObject? { (try await conn.perform(.dev(.inspectRuntime(targets: [t], animatorStates: [])), session: session).result["targets"] as? [[String: Any]])?.first.map(UnityRuntimeObject.init(json:)) }
        let a = try await sample()
        _ = await conn.transport.waitForStatus(timeout: 0.7, { _ in false })
        let b = try await sample()
        let moved = a?.hasController == true && (a?.normalizedTime ?? 0) != (b?.normalizedTime ?? 0)
        fact(moved ? "The animation is running (normalized time advances)" : "The animation did not run", .tested, "two runtime samples in Play Mode")
        return moved
    }
}

private extension CGImage {
    /// Only used when a PNG could not be decoded (the provider then abstains).
    static var placeholder: CGImage {
        CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
}
