import Testing
import Foundation
import CoreGraphics
@testable import Jarvis

private func vis(inFrustum: Bool = true, area: Double = 0.1, contrast: Double = 0.2, behind: Bool = false) -> UnityObjectVisibility {
    UnityObjectVisibility(json: ["exists": true, "object": "Bucket", "inFrustum": inFrustum, "partlyBehindCamera": behind, "areaFraction": area, "contrast": contrast, "visible": inFrustum && area >= 0.001 && contrast >= 0.03])!
}
private func frame(_ v: UnityObjectVisibility, lights: [LightFact] = [], ambient: Double = 1, dark: Double = 0.1) -> FrameFacts {
    FrameFacts(visibility: v, luminance: UnityLuminance(json: ["mean": 0.3, "stddev": 0.1, "darkFraction": dark]), lights: lights, ambientIntensity: ambient, cameraPath: "Main Camera", cameraPosition: [0, 1, 0], objectPosition: [4, 0, 10], objectRadius: 1)
}

// MARK: - The correction planner

@Suite("Operator · correction loop (pure)")
struct OperatorCorrectionTests {
    @Test("an object outside the frustum gets the camera aimed at it; the aim is exact")
    func geometry() throws {
        let p = try #require(OperatorCorrection.plan(round: 1, frame(vis(inFrustum: false, area: 0, contrast: 0))))
        guard case .aimCamera(let path, let pos, let rot) = p.actions[0] else { Issue.record("expected aimCamera"); return }
        #expect(path == "Main Camera" && p.reason.contains("outside"))
        // looking from pos at (4,0,10) the yaw/pitch recomputed must point back at the object
        let look = OperatorCorrection.lookAt(from: pos, to: [4, 0, 10])
        #expect(rot == look)
        let fwd = [sin(look[1] * .pi / 180) * cos(look[0] * .pi / 180), -sin(look[0] * .pi / 180), cos(look[1] * .pi / 180) * cos(look[0] * .pi / 180)]
        let to = [4 - pos[0], 0 - pos[1], 10 - pos[2]]; let len = (to[0] * to[0] + to[1] * to[1] + to[2] * to[2]).squareRoot()
        #expect(abs(fwd[0] - to[0] / len) < 0.02 && abs(fwd[1] - to[1] / len) < 0.02 && abs(fwd[2] - to[2] / len) < 0.02)
        #expect(OperatorCorrection.lookAt(from: [0, 0, 0], to: [0, 0, 5]) == [0, 0, 0] && OperatorCorrection.lookAt(from: [0, 0, 0], to: [5, 0, 0])[1] == 90)
    }

    @Test("in view but indistinguishable: add a light if there is none, else raise the brightest light and the ambient — bounded")
    func lighting() throws {
        let dark = vis(contrast: 0.005)
        #expect(OperatorCorrection.plan(round: 1, frame(dark))?.actions == [.addFillLight])
        let lit = frame(dark, lights: [LightFact(path: "Sun", enabled: true, intensity: 0.5, type: "Directional"), LightFact(path: "Off", enabled: false, intensity: 9, type: "Point")])
        let p = try #require(OperatorCorrection.plan(round: 1, lit))
        #expect(p.actions == [.setLightIntensity(path: "Sun", to: 1.1), .setAmbient(to: 1.4)])
        let maxed = frame(dark, lights: [LightFact(path: "Sun", enabled: true, intensity: OperatorCorrection.maxIntensity, type: "Directional")], ambient: OperatorCorrection.maxAmbient)
        #expect(OperatorCorrection.plan(round: 2, maxed) == nil, "nothing left to try ⇒ report, do not loop")
    }

    @Test("a visible object needs no correction; a missing object cannot be corrected")
    func nothing() {
        #expect(OperatorCorrection.plan(round: 1, frame(vis())) == nil)
        let missing = UnityObjectVisibility(json: ["exists": false])!
        #expect(OperatorCorrection.plan(round: 1, frame(missing)) == nil)
    }

    @Test("taste is never corrected nor reported as a passed check; the footnote says so")
    func subjective() {
        #expect(OperatorJudgement.subjectiveWords(in: "Make the lighting beautiful and cinematic").count == 2)
        #expect(OperatorJudgement.subjectiveWords(in: "Işıklandırmayı güzel yap").contains("güzel"))
        #expect(OperatorJudgement.subjectiveWords(in: "Make the object clearly visible").isEmpty)
        #expect(OperatorJudgement.footnote(for: "make it perfect")?.contains("your call") == true && OperatorJudgement.footnote(for: "fix the camera") == nil)
        #expect(OperatorFindingClass.objective.rawValue == "OBJECTIVE" && OperatorFindingClass.subjective.rawValue == "SUBJECTIVE")
    }

    @Test("the correction step is bounded in its parameters")
    func bounds() {
        let p = UnityStepParams.parse(["correct": ["target": "Bucket", "rounds": 2]])
        #expect(p?.correction == UnityCorrectionSpec(target: "Bucket", maxRounds: 2) && p?.problems().isEmpty == true)
        #expect(UnityStepParams.parse(["correct": ["target": "Bucket", "rounds": 9]])?.problems().isEmpty == false, "no unbounded visual tweaking")
        #expect(UnityStepParams.parse(["correct": ["target": "../x", "rounds": 1]])?.problems().isEmpty == false)
        #expect(ContinuationBounds.standard.maxCorrectionRounds == 2 && UnityCorrectionSpec.defaultRounds == 2)
    }
}

// MARK: - Experiments

@Suite("Operator · experiment contract and workspace")
struct ExperimentContractTests {
    private func spec(_ mod: (inout ExperimentSpec) -> Void = { _ in }) -> ExperimentSpec {
        var s = ExperimentSpec(question: "Does the bucket pack import?", hypothesis: "It imports and renders in a clean Unity project.", kind: .assetImport, acquisitionID: UUID(), successCriteria: ["compiles", "renders"], failureCriteria: ["errors"])
        mod(&s); return s
    }

    @Test("a valid contract passes; every missing or unbounded part is named")
    func validation() {
        #expect(ExperimentValidator.validate(spec()).isEmpty)
        #expect(ExperimentValidator.validate(spec { $0.question = "" }).contains(.missing("a question")))
        #expect(ExperimentValidator.validate(spec { $0.successCriteria = [] }).contains(.missing("success criteria")))
        #expect(ExperimentValidator.validate(spec { $0.failureCriteria = ["  "] }).contains(.missing("failure criteria")))
        #expect(!ExperimentValidator.validate(spec { $0.minutes = 120 }).isEmpty && !ExperimentValidator.validate(spec { $0.diskMegabytes = 99_999 }).isEmpty && !ExperimentValidator.validate(spec { $0.artifacts = 50 }).isEmpty)
        #expect(!ExperimentValidator.validate(spec { $0.networkRequests = 3 }).isEmpty, "an experiment never spends a network budget")
        #expect(!ExperimentValidator.validate(spec { $0.cleanup = "keep" }).isEmpty)
        #expect(ExperimentValidator.validate(spec { $0.acquisitionID = nil }).contains(.missing("the quarantined acquisition it examines")))
    }

    @Test("a contract can never name the real project, a path outside Assets/, or a command")
    func isolation() {
        let real = "/Users/me/Hamam"
        #expect(!ExperimentValidator.validate(spec { $0.question = "Test inside \(real)/Assets" }, realProjectRoots: [real]).isEmpty)
        #expect(!ExperimentValidator.validate(spec { $0.assetPaths = ["../../etc/passwd"] }).isEmpty && !ExperimentValidator.validate(spec { $0.assetPaths = ["/abs/x.prefab"] }).isEmpty)
        for bad in ["rm -rf ~", "run sudo make", "curl http://x", "git push origin main", "osascript -e"] { #expect(!ExperimentValidator.validate(spec { $0.successCriteria = [bad] }).isEmpty, Comment(rawValue: bad)) }
        #expect(ExperimentKind.allCases.allSatisfy { $0.steps.first == .createEnvironment && $0.steps.last == .evaluate })
    }

    @Test("the workspace deletes only a marked folder inside its own root — never a user's file, a symlink or a foreign folder")
    func safeDeletion() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory() + "exp-root-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ws = ExperimentWorkspace(root: root)
        try ws.create(taskID: nil, kind: .assetImport)
        let assets = ws.path.appendingPathComponent("project/Assets"); try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: assets.appendingPathComponent("blob.bin"), options: .atomic)
        #expect(ws.sizeBytes() > 4000)
        // a user's folder next to it, one inside it without a marker, a symlink to the user's folder, and a marked folder with a wrong name
        let outside = URL(fileURLWithPath: NSTemporaryDirectory() + "user-\(UUID().uuidString.prefix(6))"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "precious".write(to: outside.appendingPathComponent("important.txt"), atomically: true, encoding: .utf8)
        let unmarked = root.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: unmarked, withIntermediateDirectories: true)
        let link = root.appendingPathComponent(UUID().uuidString); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(!ExperimentWorkspace.remove(outside, under: root) && !ExperimentWorkspace.remove(unmarked, under: root) && !ExperimentWorkspace.remove(link, under: root))
        #expect(!ExperimentWorkspace.remove(ws.path, under: root, expectedID: UUID()), "the marker must belong to the expected experiment")
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("important.txt").path) && FileManager.default.fileExists(atPath: unmarked.path))
        #expect(ws.delete() && !FileManager.default.fileExists(atPath: ws.path.path))
        #expect(!ExperimentWorkspace.remove(root, under: root), "the root itself is never removed")
    }

    @Test("the experiments root is outside the JARVIS data folder — and the workspace guard accepts a disposable project there (found by the real asset test: inside the data folder, importing was refused)")
    func rootAcceptedByTheGuard() throws {
        let data = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/JARVIS/live-test-unit-\(UUID().uuidString.prefix(6))")
        let root = ExperimentWorkspace.defaultRoot(dataRoot: data)
        #expect(!root.path.contains("/Library/Application Support/JARVIS") && root.path.contains("/Library/Caches/JARVIS/experiments-live-test-unit"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ws = ExperimentWorkspace(root: root)
        try ws.create(taskID: nil, kind: .assetImport)
        _ = try WorkspaceGuard(rootPath: ws.projectPath)
        // the same project inside the data folder is refused, which is exactly why the root moved
        let inside = data.appendingPathComponent("experiments/x/project")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: data) }
        #expect(throws: (any Error).self) { _ = try WorkspaceGuard(rootPath: inside.path) }
    }

    @Test("after a crash the orphan environment is found and removed — only ours, only when its owner is gone")
    func orphans() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory() + "exp-orph-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dead = ExperimentWorkspace(root: root), live = ExperimentWorkspace(root: root), finished = ExperimentWorkspace(root: root)
        for w in [dead, live, finished] { try w.create(taskID: nil, kind: .assetImport) }
        // rewrite markers with other owners
        func owner(_ w: ExperimentWorkspace, pid: Int32) throws {
            let m = ExperimentWorkspace.Marker(id: w.id, createdAt: Date(), taskID: nil, kind: "assetImport", pid: pid)
            try JSONEncoder().encode(m).write(to: w.path.appendingPathComponent(ExperimentWorkspace.markerName))
        }
        try owner(dead, pid: 999_991); try owner(live, pid: 999_992); try owner(finished, pid: 999_993)
        let stranger = root.appendingPathComponent("not-ours"); try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)
        let found = ExperimentWorkspace.orphans(under: root, isAlive: { $0 == 999_992 }, finishedIDs: [finished.id])
        #expect(Set(found.map(\.marker.id)) == [dead.id, finished.id])
        let removed = ExperimentWorkspace.reconcile(under: root, isAlive: { $0 == 999_992 }, finishedIDs: [finished.id])
        #expect(removed.count == 2 && FileManager.default.fileExists(atPath: live.path.path) && FileManager.default.fileExists(atPath: stranger.path))
    }
}

// MARK: - Verdicts, asset facts, persistence

@Suite("Operator · verdicts, asset facts and persistence")
struct ExperimentJudgementTests {
    private func spec() -> ExperimentSpec { ExperimentSpec(question: "q", hypothesis: "h", kind: .assetImport, acquisitionID: UUID(), successCriteria: ["a"], failureCriteria: ["b"]) }
    private func f(_ s: String, _ c: FactClass = .tested) -> ExperimentFact { ExperimentFact(statement: s, factClass: c, evidence: "e") }

    @Test("confirmed only when every check held; one failure refutes; a missing environment is INCONCLUSIVE — not a verdict")
    func verdicts() {
        let ok = [f("Unity imported and compiled the project without compile errors"), f("The Console shows no import errors"), f("Assets/x.prefab was instantiated in a new scene"), f("The subject is visible in the render"), f("The render does not render pink")]
        #expect(TaskEngine.judge(spec: spec(), facts: ok, inconclusive: nil, seconds: 5, deleted: true, hashes: ["h1"], untouched: true).verdict == .confirmed)
        let pink = Array(ok.dropLast()) + [f("The render shows magenta (60 % of the picture): renders magenta")]
        let r = TaskEngine.judge(spec: spec(), facts: pink, inconclusive: nil, seconds: 5, deleted: true, hashes: [], untouched: true)
        #expect(r.verdict == .refuted && r.failureHit.contains { $0.contains("pink") } && r.successMet.contains("the project compiles"))
        let err = TaskEngine.judge(spec: spec(), facts: [f("Unity reported 3 compile error(s)")], inconclusive: nil, seconds: 1, deleted: true, hashes: [], untouched: true)
        #expect(err.verdict == .refuted)
        let none = TaskEngine.judge(spec: spec(), facts: [], inconclusive: "the disposable editor could not be started", seconds: 1, deleted: true, hashes: [], untouched: true)
        #expect(none.verdict == .inconclusive && none.summary.contains("no verdict") && none.environmentDeleted)
        // a check that was never made is not a pass: compile held, but nothing was ever rendered
        let partial = TaskEngine.judge(spec: spec(), facts: [f("Unity imported and compiled the project without compile errors")], inconclusive: nil, seconds: 1, deleted: true, hashes: [], untouched: true)
        #expect(partial.verdict == .refuted || partial.verdict == .inconclusive)
        var mat = spec(); mat.kind = .materialRender
        let noRender = TaskEngine.judge(spec: mat, facts: [f("Unity imported and compiled the project without compile errors"), f("The Console shows no import errors")], inconclusive: nil, seconds: 1, deleted: true, hashes: [], untouched: true)
        #expect(noRender.verdict == .inconclusive && noRender.summary.contains("it renders visibly"), "compile alone never confirms a render hypothesis")
        #expect(TaskEngine.judge(spec: spec(), facts: [f("Imported 3 prefabs", .verified)], inconclusive: nil, seconds: 1, deleted: true, hashes: [], untouched: true).verdict == .inconclusive, "untested facts never confirm a hypothesis")
    }

    @Test("asset facts keep verified, tested, stated, inferred, unknown and incompatible apart — probably is not works")
    func assetFacts() {
        var cand = CandidateRecord(researchID: UUID(), name: "Bucket pack", url: "https://example.org/bucket")
        cand.kind = .model3D; cand.publisher = "Kenney"
        cand.compatibility = CompatibilityAssessment(overall: .likely, unityVersion: .likely, renderPipeline: .unknown, reasons: ["FBX is version independent"])
        var rec = AcquisitionRecord(id: UUID(), researchID: nil, candidateID: nil, taskID: nil, state: .readyForImport, acquisitionClass: .publicDirectDownload, name: "Bucket pack", sourceURL: "https://example.org/bucket")
        rec.licenseID = "CC0-1.0"; rec.licenseSourceURL = "https://example.org/license"; rec.priceState = .freeVerified; rec.priceVerifiedAt = Date(); rec.sha256 = String(repeating: "a", count: 64); rec.size = 40_000
        let untested = AssetEvaluator.evaluate(AssetEvaluationInput(name: "Bucket pack", sourceURL: "https://example.org/bucket", candidate: cand, acquisition: rec, project: ProjectFacts(name: "Hamam", unityVersion: "6000.5.1f1", renderPipeline: "URP")))
        #expect(untested.facts(.verified).contains { $0.statement == "Price: free" } && untested.facts(.supportedBySource).contains { $0.statement.hasPrefix("Licence: CC0-1.0") })
        #expect(untested.facts(.inferred).contains { $0.statement.hasPrefix("Probably compatible") } && !untested.hasAnyTested)
        #expect(untested.facts(.unknown).contains { $0.statement == "Style fit with the project" } && untested.recommendation.contains("Not tested"))
        #expect(untested.usage.contains { $0.hasPrefix("FACT:") } && untested.usage.contains { $0.hasPrefix("INFERENCE:") } && untested.usage.contains { $0.hasPrefix("RECOMMENDATION:") && $0.contains("URP") })
        // after an experiment that imported and compiled it, compatibility becomes TESTED
        let exp = ExperimentResult(verdict: .confirmed, summary: "ok", facts: [ExperimentFact(statement: "Unity imported and compiled the project without compile errors", factClass: .tested, evidence: "compiler"), ExperimentFact(statement: "3 file(s) were copied into a clean project", factClass: .tested, evidence: "import")], successMet: [], failureHit: [], seconds: 9, environmentDeleted: true)
        let tested = AssetEvaluator.evaluate(AssetEvaluationInput(name: "Bucket pack", sourceURL: "https://example.org/bucket", candidate: cand, acquisition: rec, project: ProjectFacts(name: "Hamam", unityVersion: "6000.5.1f1", renderPipeline: "URP"), experiment: exp))
        #expect(tested.hasAnyTested && tested.facts(.tested).contains { $0.statement.hasPrefix("Probably compatible") } && tested.recommendation.contains("Technically fine to try"))
        #expect(tested.summaryLines.joined().contains("TESTED:") && tested.summaryLines.joined().contains("INFERENCES / UNKNOWN:"))
    }

    @Test("a REFUTED experiment makes the asset INCOMPATIBLE as delivered: no TESTED compatibility, no 'it rendered', and the recommendation says not to use it (found by the real asset run)")
    func refutedAsset() {
        let cand = CandidateRecord(researchID: UUID(), name: "Bucket", url: "https://example.org/bucket")
        var rec = AcquisitionRecord(id: UUID(), researchID: nil, candidateID: nil, taskID: nil, state: .readyForImport, acquisitionClass: .publicDirectDownload, name: "Bucket", sourceURL: "https://example.org/bucket")
        rec.licenseID = "CC0-1.0"; rec.licenseSourceURL = "https://example.org/l"; rec.priceState = .freeVerified; rec.priceVerifiedAt = Date()
        let facts = [ExperimentFact(statement: "Unity imported and compiled the project without compile errors", factClass: .tested, evidence: "compiler"), ExperimentFact(statement: "The Console shows no import errors", factClass: .tested, evidence: "console")]
        let refuted = ExperimentResult(verdict: .refuted, summary: "the hypothesis failed: nothing could be instantiated", facts: facts, successMet: ["the project compiles"], failureHit: ["nothing could be instantiated"], seconds: 7, environmentDeleted: true)
        let ev = AssetEvaluator.evaluate(AssetEvaluationInput(name: "Bucket", sourceURL: "https://example.org/bucket", candidate: cand, acquisition: rec, project: nil, experiment: refuted))
        #expect(ev.recommendation.hasPrefix("Do not use as delivered") && ev.recommendation.contains("nothing could be instantiated"))
        #expect(ev.facts(.incompatible).count == 1 && !ev.facts.contains { $0.factClass == .tested && $0.statement.hasPrefix("Compatibility") })
        #expect(!ev.usage.joined().contains("imported and rendered"), "never claims a render that did not happen")
    }

    @Test("an unknown licence or a price that is not verified free blocks the recommendation; a style claim needs pictures of BOTH sides")
    func claims() {
        var cand = CandidateRecord(researchID: UUID(), name: "X", url: "https://e.org/x")
        cand.price = PriceAssessment(state: .paidVerified, amount: 9, currency: "USD", evidence: [], verifiedAt: Date(), note: nil)
        let paid = AssetEvaluator.evaluate(AssetEvaluationInput(name: "X", sourceURL: "https://e.org/x", candidate: cand, acquisition: nil, project: nil))
        #expect(paid.facts(.unknown).contains { $0.statement == "Licence" } && paid.recommendation.contains("licence is unknown"))
        #expect(!AssetEvaluator.styleClaimAllowed(nil) && !AssetEvaluator.styleClaimAllowed(VisualFitEvidence(assetPictureHash: "a", projectPictureHash: "", provider: "p", observation: "o")) && !AssetEvaluator.styleClaimAllowed(VisualFitEvidence(assetPictureHash: "a", projectPictureHash: "a", provider: "p", observation: "o")))
        let ev = VisualFitEvidence(assetPictureHash: "aaaa", projectPictureHash: "bbbb", provider: "local-vlm", observation: "similar low-poly style")
        #expect(AssetEvaluator.styleClaimAllowed(ev))
        let withFit = AssetEvaluator.evaluate(AssetEvaluationInput(name: "X", sourceURL: "https://e.org/x", candidate: cand, acquisition: nil, project: nil, visualFit: ev))
        #expect(withFit.facts(.inferred).contains { $0.statement.contains("Visual comparison") && $0.evidence.contains("subjective") })
    }

    @Test("experiments, visual evidence and asset evaluations persist (schema v12) — and an unfinished experiment becomes INTERRUPTED at the next launch")
    func persistence() throws {
        let p = JarvisPaths.temporary("exp-db"); try p.ensureDirectories()
        let db = try JarvisDatabase(url: p.database)
        #expect(db.schemaVersion == Migration.latestVersion && Migration.latestVersion >= 12)
        let repo = JarvisRepository(database: db)
        let sp = ExperimentSpec(question: "Does it import?", hypothesis: "yes", kind: .assetImport, acquisitionID: UUID(), successCriteria: ["a"], failureCriteria: ["b"])
        let rec = ExperimentRecord(id: UUID(), taskID: UUID(), stepKey: "s1", projectKey: "git:abc", spec: sp, environmentPath: "/tmp/x", status: "running", result: nil, cleanupState: "pending")
        try repo.save(rec)
        try repo.addExperimentStep(experimentID: rec.id, seq: 1, kind: .createEnvironment, status: "ok", evidence: "clean project")
        #expect(try repo.unfinishedExperiments().map(\.id) == [rec.id])
        let interrupted = try repo.reconcileExperimentsAfterRestart()
        let afterStatus = try repo.experiment(rec.id)?.status
        let stillOpen = try repo.unfinishedExperiments()
        #expect(interrupted.map(\.id) == [rec.id] && afterStatus == "interrupted" && stillOpen.isEmpty)
        #expect(try repo.experimentSteps(rec.id).first?.kind == "createEnvironment")
        let task = UUID()
        try repo.insert(VisualObservationRecord(taskID: task, stepKey: "s1", provider: "unity-capture", pictureHash: "abcd1234abcd1234", subject: "Bucket", query: "visible?", outcome: "visible", detail: "area 10 %"))
        let obs = try repo.visualObservations(taskID: task)
        #expect(obs.count == 1 && obs[0].pictureHash == "abcd1234abcd1234")
        #expect(try repo.recentVisualObservations(limit: 5).first?.provider == "unity-capture")
        let acq = UUID()
        let ev = AssetEvaluation(name: "Bucket", facts: [ExperimentFact(statement: "s", factClass: .tested, evidence: "e")], usage: ["FACT: x"], recommendation: "ok")
        try repo.save(AssetEvaluationRecord(taskID: task, acquisitionID: acq, projectKey: "git:abc", evaluation: ev, source: "https://e.org"))
        #expect(try repo.assetEvaluations(acquisitionID: acq).first?.evaluation == ev)
        // no pixels anywhere in the schema
        let cols = try db.read("SELECT sql FROM sqlite_master WHERE name IN ('visual_observations','experiments','asset_evaluations')").compactMap { $0.string("sql")?.lowercased() }.joined()
        #expect(!cols.contains("blob") && !cols.contains("png") && !cols.contains("image") && !cols.contains("pixel"))
    }

    @Test("pixel facts: a magenta picture is detected, a normal one is not")
    func magenta() throws {
        func img(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Data {
            let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            return VisualImageCoding.png(ctx.makeImage()!)!
        }
        #expect(PictureAnalysis.magentaFraction(png: img(255, 0, 255)) > 0.95 && PictureAnalysis.magentaFraction(png: img(30, 80, 160)) < 0.01)
    }
}

// MARK: - The experiment step on the engine

@MainActor
@Suite("Operator · experiment step (engine)", .serialized)
struct ExperimentEngineTests {
    private func plan(_ spec: String) -> String {
        UnityScripts.plan([UnityScripts.step("s1", "Test the asset", "experiment", validation: "experimentConcluded", unity: "{\"experiment\":\(spec)}", risk: "low")])
    }
    private let spec = "{\"question\":\"Does it import?\",\"hypothesis\":\"It imports and renders.\",\"kind\":\"materialRender\",\"assetPaths\":[],\"successCriteria\":[\"compiles\"],\"failureCriteria\":[\"errors\"],\"minutes\":2,\"diskMegabytes\":64,\"networkRequests\":0,\"artifacts\":2,\"cleanup\":\"delete\"}"

    @Test("when the disposable editor cannot start the experiment is INCONCLUSIVE, its environment is deleted, the real project is untouched — and nothing was spent in the real project")
    func cleanupOnFailure() async throws {
        let h = UnityHarness(script: UnityScripts.standard(plan: plan(spec)), editorAlive: false)
        let root = URL(fileURLWithPath: NSTemporaryDirectory() + "exp-eng-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        h.engine.experimentsRoot = root
        h.launcher.failure = UnityBridgeError.notConnected("no editor in this test")
        let before = ProjectContinuity.treeFingerprint(root: h.project)
        let v = await h.run("Test whether the material renders in a clean project")
        #expect(v.task.state == .failed, Comment(rawValue: "\(v.task.state) \(v.task.failureReason ?? "")"))
        #expect((v.task.failureReason ?? "").contains("Inconclusive"))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).isEmpty, "the environment is gone")
        let rec = try #require(try h.task.repo.experiments(taskID: v.id).first)
        #expect(rec.cleanupState == "deleted" && rec.result?.verdict == .inconclusive && rec.status == "failed")
        #expect(ProjectContinuity.treeFingerprint(root: h.project) == before)
        #expect(h.editor.received.isEmpty, "the real project's editor was never asked anything")
    }

    @Test("an invalid contract (it names the real project) never starts: nothing is created")
    func invalid() async throws {
        let proj = UnityFixture.make()
        let h = UnityHarness(script: UnityScripts.standard(plan: plan(spec.replacingOccurrences(of: "Does it import?", with: "Test inside \(proj)/Assets"))), project: proj, editorAlive: false)
        let root = URL(fileURLWithPath: NSTemporaryDirectory() + "exp-inv-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        h.engine.experimentsRoot = root
        let v = await h.run("Test it")
        #expect(v.task.state == .failed)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).isEmpty)
    }

    @Test("an asset experiment that cannot start still leaves an honest asset EVALUATION: nothing tested, the source's statements stay SUPPORTED BY SOURCE, the recommendation says 'not tested'")
    func evaluationWithoutAnExperiment() async throws {
        let acqID = UUID()
        let assetSpec = spec.replacingOccurrences(of: "\"kind\":\"materialRender\"", with: "\"kind\":\"assetImport\",\"acquisitionID\":\"\(acqID.uuidString)\"")
        let h = UnityHarness(script: UnityScripts.standard(plan: plan(assetSpec)), editorAlive: false)
        let root = URL(fileURLWithPath: NSTemporaryDirectory() + "exp-eval-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        h.engine.experimentsRoot = root
        h.launcher.failure = UnityBridgeError.notConnected("no editor in this test")
        var rec = AcquisitionRecord(id: acqID, researchID: nil, candidateID: nil, taskID: nil, state: .readyForImport, acquisitionClass: .publicDirectDownload, name: "Bucket pack", sourceURL: "https://example.org/bucket")
        rec.licenseID = "CC0-1.0"; rec.licenseSourceURL = "https://example.org/license"; rec.priceState = .freeVerified; rec.priceVerifiedAt = Date()
        try h.task.repo.upsert(rec)
        let v = await h.run("Test whether the bucket pack imports and renders")
        #expect(v.task.state == .failed, Comment(rawValue: "\(v.task.state) \(v.task.failureReason ?? "")"))
        let saved = try #require(try h.task.repo.assetEvaluations(acquisitionID: acqID).first)
        #expect(!saved.evaluation.hasAnyTested && saved.evaluation.recommendation.contains("Not tested"))
        #expect(saved.evaluation.facts(.supportedBySource).contains { $0.statement.hasPrefix("Licence: CC0-1.0") })
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).isEmpty, "the environment is gone")
    }

    @Test("with experiments turned off in Settings the step fails with that reason and creates nothing")
    func switchedOff() async throws {
        let h = UnityHarness(script: UnityScripts.standard(plan: plan(spec)), editorAlive: false)
        let root = URL(fileURLWithPath: NSTemporaryDirectory() + "exp-off-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        h.engine.experimentsRoot = root
        h.engine.experimentsEnabled = { false }
        let v = await h.run("Test it")
        #expect(v.task.state == .failed && (v.task.failureReason ?? "").contains("turned off"))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).isEmpty)
        #expect(Preferences(defaults: UserDefaults(suiteName: "exp-pref-\(UUID().uuidString)")!).experimentsEnabled, "on by default")
    }

    @Test("without the experiments root (a stubbed run) or the capability the step is refused")
    func refused() async throws {
        let h = UnityHarness(script: UnityScripts.standard(plan: plan(spec)), editorAlive: false)
        h.engine.experimentsRoot = nil
        let v = await h.run("Test it")
        #expect(v.task.state == .failed && (v.task.failureReason ?? "").contains("not available"))
        let ro = UnityHarness(script: UnityScripts.standard(plan: plan(spec)), editorAlive: false)
        let r = await ro.run("Test it", kind: .readOnlyAnalysis)
        #expect(r.task.state == .failed)
    }
}
