import Testing
import Foundation
@testable import Jarvis

// MOCK TESTED: these run against `SimulatedUnityEditor`. The real editor is exercised by `Jarvis --unity-live-test`.

@Suite("Unity task engine (simulated editor)", .serialized)
@MainActor
struct UnityEngineTests {
    @Test func addsAColliderWithTypedOperationsAndVerifiesItInTheEditor() async {
        let h = UnityHarness(script: UnityScripts.standard(plan: UnityScripts.addCollider))
        let v = await h.run("Add a BoxCollider to TestCube if it does not have one")
        #expect(v.task.state == .completed, "\(v.task.failureReason ?? "")")
        let cube = h.editor.objects.first { $0.name == "TestCube" }!
        #expect(cube.components.filter { $0 == "BoxCollider" }.count == 1)
        #expect(h.editor.scenes[0].dirty == false)                        // saved
        #expect(v.steps.allSatisfy { $0.state == .passed })
        #expect(h.editor.received.contains("addComponent") && h.editor.received.contains("saveScene"))
        // Nothing but typed wire operations was ever sent.
        #expect(Set(h.editor.received).isSubset(of: UnityOperation.allWireNames))
    }

    @Test func retryingDoesNotDuplicateTheComponent() async {
        let h = UnityHarness(script: UnityScripts.standard(plan: UnityScripts.addCollider))
        _ = await h.run("Add a BoxCollider to TestCube if it does not have one")
        let v2 = await h.run("Add a BoxCollider to TestCube if it does not have one")
        #expect(v2.task.state == .completed)
        #expect(h.editor.objects.first { $0.name == "TestCube" }!.components.filter { $0 == "BoxCollider" }.count == 1)
    }

    @Test func serializedPropertyChangeRequiresAndChecksTheExpectedOldValue() async {
        let h = UnityHarness(script: UnityScripts.standard(plan: UnityScripts.setProperty))
        let v = await h.run("Set CounterObject startValue from 1 to 5")
        #expect(v.task.state == .completed, "\(v.task.failureReason ?? "")")
        #expect(h.editor.objects.first { $0.name == "CounterObject" }!.props["Counter"]?["startValue"] == .number(5))
        // Repeat: already applied, still completes, nothing else changes.
        let v2 = await h.run("Set CounterObject startValue from 1 to 5")
        #expect(v2.task.state == .completed)
        // A stale expectation (the value is no longer 1 and not the target either) is refused, not forced.
        h.editor.objects[h.editor.objects.firstIndex { $0.name == "CounterObject" }!].props["Counter"]?["startValue"] = .number(9)
        let v3 = await h.run("Set CounterObject startValue from 1 to 5")
        #expect(v3.task.state == .failed)
    }
}

// MARK: - Scenarios D–N, connection, lock, recovery (all against the simulated editor)

@Suite("Unity scenarios (simulated editor)", .serialized)
@MainActor
struct UnityScenarioTests {
    static let fixBroken = "<<<<<<< SEARCH Assets/Scripts/Broken.cs\n@@SYNTAX_ERROR@@\n=======\n// fixed\n>>>>>>> REPLACE\n"
    static let noOpEdit = "<<<<<<< SEARCH Assets/Scripts/Counter.cs\npublic int startValue = 1;\n=======\npublic int startValue = 1; // touched\n>>>>>>> REPLACE\n"
    static let fixCalc = "<<<<<<< SEARCH Assets/Scripts/Calculator.cs\nreturn a - b;\n=======\nreturn a + b;\n>>>>>>> REPLACE\n"

    static let compilePlan = UnityScripts.plan([
        UnityScripts.step("s1", "Inspect", "unityInspect", validation: "unityInspected", unity: "{\"requireNoNewErrors\":false}"),
        UnityScripts.step("s2", "Analyse", "analysis", deps: ["s1"], validation: "structuredResult"),
        UnityScripts.step("s3", "Fix the script", "codeChange", deps: ["s2"], validation: "changedFiles", risk: "medium"),
        UnityScripts.step("s4", "Compile", "unityCompile", deps: ["s3"], validation: "unityCompiled", unity: "{\"requireNoNewErrors\":false}"),
    ])

    // MARK: D — compile error, E — failing test (provider proposes a code change; Unity's own compiler/tests decide)

    @Test func aCompileErrorIsFixedThroughTheNormalCodePathAndValidatedByUnityItself() async {
        let p = UnityFixture.make(scripts: ["Assets/Scripts/Broken.cs": "// x\n\(SimulatedUnityEditor.syntaxErrorToken)\n"])
        let h = UnityHarness(script: UnityScripts.standard(plan: Self.compilePlan, coding: Self.fixBroken), project: p)
        let v = await h.run("Fix the Unity compile error")
        #expect(v.task.state == .completed, "\(v.task.failureReason ?? "")")
        #expect(h.editor.compileErrors.isEmpty && h.editor.compileGeneration >= 1)
        #expect(v.steps.first { $0.type == .unityCompile }?.validationEvidence?.contains("Unity compile: PASS") == true)
        // The script edit used the V0.4 file path (a recorded file change with hashes), not a Unity operation.
        #expect(h.task.fileChanges(v.id).map(\.path) == ["Assets/Scripts/Broken.cs"])
        #expect(!h.editor.received.contains("addComponent") && !h.editor.received.contains("setSerializedProperty"))
        #expect(h.task.runner.jobs("CodingAgent").allSatisfy { $0.candidate.engine != .local })
    }

    @Test func aFailedCompileTriggersTheBoundedRepairWithUnitysRealErrorText() async {
        let p = UnityFixture.make(scripts: ["Assets/Scripts/Broken.cs": "// x\n\(SimulatedUnityEditor.syntaxErrorToken)\n"])
        let h = UnityHarness(script: UnityScripts.standard(plan: Self.compilePlan, coding: ""), project: p)
        h.task.runner.script = { job, index in
            switch job.type {
            case "PlannerAgent": return .text(Self.compilePlan)
            case "AnalysisAgent": return .text(Scripts.analysis)
            case "CodingAgent": return .text(index == 0 ? Self.noOpEdit : Self.fixBroken)         // the first fix misses the error
            case "ReviewAgent": return .text(UnityScripts.reviewPass)
            default: return .fail(.generic)
            }
        }
        let v = await h.run("Fix the Unity compile error")
        #expect(v.task.state == .completed, "\(v.task.failureReason ?? "")")
        let repairPrompt = h.task.runner.jobs("CodingAgent").dropFirst().first?.job.prompt ?? ""
        #expect(repairPrompt.contains("CS1002") && repairPrompt.contains("Broken.cs"))             // the real compiler error was handed to the coder
        #expect(h.task.runner.jobs("CodingAgent").count == 2)
    }

    @Test func aStillBrokenProjectFailsHonestlyAfterTheBoundedAttempts() async {
        let p = UnityFixture.make(scripts: ["Assets/Scripts/Broken.cs": "// x\n\(SimulatedUnityEditor.syntaxErrorToken)\n"])
        let h = UnityHarness(script: UnityScripts.standard(plan: Self.compilePlan, coding: Self.noOpEdit), project: p)
        let v = await h.run("Fix the Unity compile error")
        #expect(v.task.state == .failed && v.task.failureCategory == .compileFailed)
        #expect(h.task.runner.jobs("CodingAgent").count <= TaskEngine.maxStepAttempts)
    }

    static let testPlan = UnityScripts.plan([
        UnityScripts.step("s1", "Fix the code", "codeChange", validation: "changedFiles", risk: "medium"),
        UnityScripts.step("s2", "Compile", "unityCompile", deps: ["s1"], validation: "unityCompiled"),
        UnityScripts.step("s3", "Run the test", "unityTest", deps: ["s2"], validation: "unityTestsPass", unity: "{\"testMode\":\"editMode\",\"testNames\":[\"CalculatorTests.Add_ReturnsSum\"]}"),
        UnityScripts.step("s4", "Review", "review", deps: ["s3"], validation: "reviewPass"),
    ])

    @Test func aFailingUnityTestIsFixedAndTheExactTestIsRerun() async {
        let h = UnityHarness(script: UnityScripts.standard(plan: Self.testPlan, coding: Self.fixCalc))
        h.editor.testOracle = { files, _, names in
            let ok = files["Assets/Scripts/Calculator.cs"]?.contains("a + b") == true
            return [UnityTestCase(name: names.first ?? "CalculatorTests.Add_ReturnsSum", status: ok ? "Passed" : "Failed", message: ok ? "" : "Expected: 5 But was: -1")]
        }
        let v = await h.run("Fix the failing Unity test")
        #expect(v.task.state == .completed, "\(v.task.failureReason ?? "")")
        let t = v.steps.first { $0.type == .unityTest }
        #expect(t?.validationEvidence?.contains("1/1 passed") == true && t?.validationEvidence?.contains("CalculatorTests.Add_ReturnsSum") == true)
        #expect(h.editor.receivedOps.contains { if case .runTests(.editMode, let n, _, _) = $0 { n == ["CalculatorTests.Add_ReturnsSum"] } else { false } })      // smallest scope, exactly what was planned
    }

    @Test func aSubjectiveReviewerCannotTurnPassingUnityTestsIntoAFailure() async {
        let dislike = #"{"verdict":"fail","summary":"I dislike the naming","issues":["The variable naming is unidiomatic","Consider using LINQ"]}"#
        let h = UnityHarness(script: UnityScripts.standard(plan: Self.testPlan, coding: Self.fixCalc, review: dislike))
        h.editor.testOracle = { files, _, _ in [UnityTestCase(name: "T", status: files["Assets/Scripts/Calculator.cs"]?.contains("a + b") == true ? "Passed" : "Failed", message: "")] }
        let v = await h.run("Fix the failing Unity test")
        #expect(v.task.state == .completed, "\(v.task.failureReason ?? "")")
        let report = h.engine.report(for: v.id)
        #expect(report?.advisories?.first?.contains("not blocking") == true)             // kept as advice
        #expect(report?.unity?.contains { $0.contains("Visual validation: NOT PERFORMED") } == true)
    }

    @Test func aFailingTestIsNotRescuedByAnOptimisticReview() async {
        let h = UnityHarness(script: UnityScripts.standard(plan: Self.testPlan, coding: Self.noOpEdit, review: UnityScripts.reviewPass))
        h.editor.testOracle = { _, _, _ in [UnityTestCase(name: "T", status: "Failed", message: "boom")] }
        let v = await h.run("Fix the failing Unity test")
        #expect(v.task.state == .failed && v.task.failureCategory == .testFailed)
        #expect(v.steps.first { $0.type == .review }?.state != .passed)
    }

    @Test func zeroMatchingTestsIsNotASuccess() async {
        let h = UnityHarness(script: UnityScripts.standard(plan: Self.testPlan, coding: Self.fixCalc))
        h.editor.testOracle = { _, _, _ in [] }
        let v = await h.run("Fix the failing Unity test")
        #expect(v.task.state == .failed)
        #expect(v.steps.first { $0.type == .unityTest }?.validationEvidence?.contains("No test matched") == true || v.task.failureReason?.contains("0/0") == true || v.task.failureReason?.contains("FAIL") == true)
    }

    // MARK: F — Play Mode

    static let playPlan = UnityScripts.plan([
        UnityScripts.step("s1", "Compile", "unityCompile", validation: "unityCompiled"),
        UnityScripts.step("s2", "Play", "unityPlayMode", deps: ["s1"], validation: "unityPlayObserved",
                          unity: "{\"observeSeconds\":1,\"expectations\":[{\"kind\":\"propertyEquals\",\"target\":{\"path\":\"CounterObject\"},\"componentType\":\"Counter\",\"propertyPath\":\"startValue\",\"value\":1}]}"),
    ])

    @Test func playModeIsEnteredObservedLeftAndEachTransitionIsConfirmedByTheEditor() async {
        let h = UnityHarness(script: UnityScripts.standard(plan: Self.playPlan))
        let v = await h.run("Enter Play Mode and verify CounterObject")
        #expect(v.task.state == .completed, "\(v.task.failureReason ?? "")")
        let e = v.steps.first { $0.type == .unityPlayMode }?.validationEvidence ?? ""
        #expect(e.contains("entered Play Mode (confirmed by the editor)") && e.contains("left Play Mode (confirmed)") && e.contains("✓"))
        #expect(h.editor.isPlaying == false)
        let order = h.editor.received.filter { $0 == "enterPlayMode" || $0 == "exitPlayMode" }
        #expect(order == ["enterPlayMode", "exitPlayMode"])
    }

    @Test func playModeIsAlwaysLeftEvenWhenAnExpectationFails() async {
        let plan = UnityScripts.plan([UnityScripts.step("s1", "Play", "unityPlayMode", validation: "unityPlayObserved",
                                                        unity: "{\"observeSeconds\":1,\"expectations\":[{\"kind\":\"propertyEquals\",\"target\":{\"path\":\"CounterObject\"},\"componentType\":\"Counter\",\"propertyPath\":\"startValue\",\"value\":99}]}")])
        let h = UnityHarness(script: UnityScripts.standard(plan: plan))
        let v = await h.run("Play")
        #expect(v.task.state == .failed && h.editor.isPlaying == false)
        #expect(v.steps[0].validationEvidence?.contains("✗") == true)
    }

    @Test func playModeCannotBeEnteredWhileCompileErrorsExist() async {
        let p = UnityFixture.make(scripts: ["Assets/Scripts/Broken.cs": SimulatedUnityEditor.syntaxErrorToken])
        let plan = UnityScripts.plan([UnityScripts.step("s1", "Compile", "unityCompile", validation: "unityCompiled"), UnityScripts.step("s2", "Play", "unityPlayMode", deps: ["s1"], validation: "unityPlayObserved")])
        let h = UnityHarness(script: UnityScripts.standard(plan: plan), project: p)
        let v = await h.run("Play")
        #expect(v.task.state == .failed)
        #expect(!h.editor.received.contains("enterPlayMode"))
    }

    // MARK: G — Console delta + sanitization

    @Test func onlyNewConsoleErrorsAreAttributedAndTheyAreSanitized() async {
        let plan = UnityScripts.plan([UnityScripts.step("s1", "Play", "unityPlayMode", validation: "unityPlayObserved", unity: "{\"observeSeconds\":1}")])
        let h = UnityHarness(script: UnityScripts.standard(plan: plan))
        h.editor.logError("Pre-existing error before the task at Old.cs:7")
        h.editor.playConsole = [(.error, "Pre-existing error before the task at Old.cs:99"), (.exception, "Boom api_key=sk-proj-FAKE0123456789abcdefghijkl password=hunter2-fake")]
        let v = await h.run("Play and check the Console")
        let e = v.steps[0].validationEvidence ?? ""
        #expect(v.task.state == .failed)
        #expect(e.contains("new Console errors: 1") && e.contains("+1 repeat of an error that existed before"))
        #expect(!e.contains("FAKE0123") && !e.contains("hunter2"))
        // Nothing raw reached the database or the artifacts.
        let dump = ((try? FileManager.default.subpathsOfDirectory(atPath: h.task.paths.root.path)) ?? []).compactMap { try? Data(contentsOf: h.task.paths.root.appendingPathComponent($0)) }.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(!dump.contains("FAKE0123456789") && !dump.contains("hunter2-fake"))
    }

    // MARK: H — user's unsaved scene

    @Test func unsavedUserSceneChangesAreNeverSavedOverWithoutApproval() async {
        let h = UnityHarness(script: UnityScripts.standard(plan: UnityHarness.editPlan("{\"op\":\"addComponent\",\"target\":{\"path\":\"TestCube\"},\"componentType\":\"BoxCollider\"}")))
        h.editor.userEditsScene()
        let denied = await h.runWithApprovals("Add a collider", answers: [("unsaved changes", false)])
        #expect(denied.task.state == .failed && denied.task.failureCategory == .approvalDenied)
        #expect(!h.editor.received.contains("addComponent") && !h.editor.received.contains("saveScene"))
        #expect(h.editor.scenes[0].dirty && !h.editor.scenes[0].jarvisDirty)             // the user's change is still there, unsaved
        #expect(h.task.approvalStates(denied.id) == [.denied])
        let approved = await h.runWithApprovals("Add a collider", answers: [("unsaved changes", true)])
        #expect(approved.task.state == .completed, "\(approved.task.failureReason ?? "")")
        #expect(h.editor.objects.first { $0.name == "TestCube" }!.components.contains("BoxCollider"))
    }

    // MARK: I — Play Mode mutation block

    @Test func aMutationDuringPlayModeIsRefusedAndWorksAfterwards() async {
        let h = UnityHarness(script: UnityScripts.standard(plan: UnityHarness.editPlan("{\"op\":\"addComponent\",\"target\":{\"path\":\"TestCube\"},\"componentType\":\"Rigidbody\"}"), coding: Self.noOpEdit))
        h.editor.isPlaying = true
        let blocked = await h.run("Add a Rigidbody")
        #expect(blocked.task.failureCategory == .unsafeEditorState && !h.editor.received.contains("addComponent"))
        let codePlan = UnityScripts.plan([UnityScripts.step("s1", "Edit script", "codeChange", validation: "changedFiles", risk: "medium")])
        h.task.runner.script = UnityScripts.standard(plan: codePlan, coding: Self.noOpEdit)
        let scriptBlocked = await h.run("Change a script")
        #expect(scriptBlocked.task.failureCategory == .unsafeEditorState)
        #expect((try? String(contentsOfFile: h.project + "/Assets/Scripts/Counter.cs", encoding: .utf8))?.contains("touched") == false)
        h.editor.isPlaying = false
        h.task.runner.script = UnityScripts.standard(plan: UnityHarness.editPlan("{\"op\":\"addComponent\",\"target\":{\"path\":\"TestCube\"},\"componentType\":\"Rigidbody\"}"))
        let ok = await h.run("Add a Rigidbody")
        #expect(ok.task.state == .completed)
    }

    // MARK: J — ambiguity

    @Test func twoObjectsWithTheSameNameAreNeverResolvedByPickingOne() async {
        let h = UnityHarness(script: UnityScripts.standard(plan: UnityHarness.editPlan("{\"op\":\"addComponent\",\"target\":{\"name\":\"Twin\"},\"componentType\":\"Rigidbody\"}")))
        h.editor.add("Twin"); h.editor.add("Twin")
        let v = await h.run("Add a Rigidbody to Twin")
        #expect(v.task.state == .failed && v.task.failureCategory == .ambiguousTarget)
        #expect(v.task.failureReason?.contains("Twin#1") == true)                       // the candidates are named so the user can choose
        #expect(h.editor.objects.filter { $0.name == "Twin" }.allSatisfy { !$0.components.contains("Rigidbody") })
        h.task.runner.script = UnityScripts.standard(plan: UnityHarness.editPlan("{\"op\":\"addComponent\",\"target\":{\"path\":\"Twin#1\"},\"componentType\":\"Rigidbody\"}"))
        let ok = await h.run("Add a Rigidbody to the second Twin")
        #expect(ok.task.state == .completed)
        let twins = h.editor.objects.filter { $0.name == "Twin" }
        #expect(twins[0].components.contains("Rigidbody") == false && twins[1].components.contains("Rigidbody"))
    }

    // MARK: N — destructive

    @Test func deletionNeedsTheGoalAndAnApprovalAndIsScoped() async {
        let del = "{\"op\":\"deleteGameObject\",\"target\":{\"path\":\"TestCube\"}}"
        let h = UnityHarness(script: UnityScripts.standard(plan: UnityHarness.editPlan(del)))
        let notAsked = await h.run("Tidy the scene", destructive: false)
        #expect(notAsked.task.state == .failed && h.editor.objects.contains { $0.name == "TestCube" })
        let denied = await h.runWithApprovals("Delete TestCube", destructive: true, answers: [("Delete Unity object", false)])
        #expect(denied.task.failureCategory == .approvalDenied && h.editor.objects.contains { $0.name == "TestCube" })
        let before = h.editor.objects.map(\.name).sorted()
        let approved = await h.runWithApprovals("Delete TestCube", destructive: true, answers: [("Delete Unity object", true)])
        #expect(approved.task.state == .completed, "\(approved.task.failureReason ?? "")")
        #expect(h.editor.objects.map(\.name).sorted() == before.filter { $0 != "TestCube" })      // exactly that object
        let again = await h.runWithApprovals("Delete TestCube", destructive: true, answers: [("Delete Unity object", true)])
        #expect(again.task.state == .completed)                                                    // already gone: no replay of a delete
    }

    // MARK: Connection, install, upgrade

    @Test func theBridgeIsInstalledOnlyAfterApprovalAndTheEditorIsStartedByJarvis() async {
        let p = UnityFixture.make(bridgeInstalled: false)
        let h = UnityHarness(script: UnityScripts.standard(plan: UnityScripts.addCollider), project: p, editorAlive: false)
        let denied = await h.runWithApprovals("Add a collider", answers: [("Install the JARVIS Unity Editor bridge", false)])
        #expect(denied.task.failureCategory == .approvalDenied && !UnityBridgeInstaller.isCurrent(root: p) && h.launcher.launched.isEmpty)
        let ok = await h.runWithApprovals("Add a collider", answers: [("Install the JARVIS Unity Editor bridge", true)])
        #expect(ok.task.state == .completed, "\(ok.task.failureReason ?? "")")
        #expect(UnityBridgeInstaller.isCurrent(root: p) && h.launcher.launched.count == 1)
        #expect(h.service.connection(for: p).state == .connected)
    }

    @Test func aProjectDeclaringAnotherUnityVersionIsNeverOpenedSilently() async {
        let p = UnityFixture.make(version: "2022.3.5f1")
        let h = UnityHarness(script: UnityScripts.standard(plan: UnityScripts.addCollider), project: p, editorAlive: false)
        h.service.discoverEditors = { [UnityEditorInstall(version: UnityVersion("6000.5.1f1")!, appPath: "/x/Unity.app", executablePath: "/x/Unity.app/Contents/MacOS/Unity", available: true, lastCheckedAt: Date())] }
        let denied = await h.runWithApprovals("Add a collider", answers: [("Open this project with Unity", false)])
        #expect(denied.task.failureCategory == .approvalDenied && h.launcher.launched.isEmpty)
        #expect(denied.task.failureReason?.contains("different Unity version") == true)
        let ok = await h.runWithApprovals("Add a collider", answers: [("Open this project with Unity", true)])
        #expect(ok.task.state == .completed && h.launcher.launched.count == 1)
    }

    @Test func connectionStateNeverClaimsConnectedFromDiscoveryAlone() async {
        let h = UnityHarness(script: UnityScripts.standard(plan: UnityScripts.addCollider), editorAlive: false)
        h.service.refreshEditors()
        #expect(h.service.summary.state == .available)
        let conn = h.service.connection(for: h.project)
        #expect(conn.state == .notConfigured && conn.status == nil)
        h.editor.alive = true; conn.apply(status: h.editor.currentStatus())
        #expect(conn.state == .connected)
        h.editor.isPlaying = true; conn.apply(status: h.editor.currentStatus())
        #expect(conn.state == .playMode)
        h.editor.isPlaying = false; h.editor.isCompiling = true; conn.apply(status: h.editor.currentStatus())
        #expect(conn.state == .busy)
        h.editor.crash(); conn.apply(status: nil)
        #expect(conn.state == .disconnected)
    }

    @Test func aTaskWithoutAnEditorFailsAsUnavailableAndTouchesNothing() async {
        let h = UnityHarness(script: UnityScripts.standard(plan: UnityScripts.addCollider), editorAlive: false)
        h.launcher.failure = UnityBridgeError.notConnected("no license")
        let v = await h.run("Add a collider")
        #expect(v.task.state == .failed && v.task.failureCategory == .unityUnavailable)
        #expect(h.editor.received.isEmpty)
        let service = h.engine.unity
        h.engine.unity = nil
        let v2 = await h.run("Add a collider")
        #expect(v2.task.failureCategory == .unityUnavailable)
        h.engine.unity = service
    }

    @Test("an editor that DIES while starting (a compile error in a batch-mode start) is noticed within seconds and its output is reported — not after the full connect timeout (found by the Input System live test)")
    func aDeadEditorFailsFast() async {
        let h = UnityHarness(script: UnityScripts.standard(plan: UnityScripts.addCollider), editorAlive: false)
        h.service.connectTimeout = 120
        final class Dying: UnityOwnedEditor {
            var pid: pid_t = 4242; var isRunning = false
            var outputTail = "Packages/com.jarvis.bridge/Editor/X.cs(28,24): error CS0104: 'PackageInfo' is an ambiguous reference"
            var onExit: (() -> Void)?
            func terminate() async {}
        }
        h.launcher.next = Dying()
        let t0 = Date()
        let outcome = await h.service.prepare(root: h.project, approvedInstall: true, approvedUpgrade: false)
        guard case .failed(_, let why) = outcome else { Issue.record("expected a failure, got \(outcome)"); return }
        #expect(Date().timeIntervalSince(t0) < 15, "it must not wait for the 120 s connect timeout")
        #expect(why.contains("exited before") && why.contains("CS0104"), Comment(rawValue: why))
    }

    @Test func anUnresponsiveEditorTimesOutTruthfully() async {
        UnityConnection.timeoutOverride = 0.2
        defer { UnityConnection.timeoutOverride = nil }
        let h = UnityHarness(script: UnityScripts.standard(plan: UnityScripts.addCollider))
        h.editor.unresponsive = true
        let v = await h.run("Add a collider")
        #expect(v.task.state == .failed && v.task.failureCategory == .unityTimeout)
    }

    // MARK: K — session change / reload

    @Test func anEditorRestartInvalidatesHandlesAndTheNextTaskReResolves() async {
        let h = UnityHarness(script: UnityScripts.standard(plan: UnityScripts.addCollider))
        _ = await h.run("Add a collider")
        let conn = h.service.connection(for: h.project)
        conn.markHandles()
        #expect(conn.handlesAreFresh)
        h.editor.restartEditor(); conn.apply(status: h.editor.currentStatus())
        #expect(!conn.handlesAreFresh)                                      // stale handles are never reused blindly
        let v = await h.run("Add a collider")
        #expect(v.task.state == .completed)
    }

    // MARK: Lock

    @Test func twoTasksThatMutateTheSameEditorTakeTurns() async {
        let h = UnityHarness(script: UnityScripts.standard(plan: UnityHarness.editPlan("{\"op\":\"createGameObject\",\"name\":\"A\"},{\"op\":\"createGameObject\",\"name\":\"B\"},{\"op\":\"createGameObject\",\"name\":\"C\"}")))
        h.editor.delay = .milliseconds(30)
        let a = await h.task.submit("First", project: h.project)
        let b = await h.task.submit("Second", project: h.project)
        await h.engine.waitUntilFinished(a); await h.engine.waitUntilFinished(b)
        #expect(h.editor.maxConcurrentMutations == 1)
        #expect(h.service.lock.heldCount == 0)
        #expect(h.engine.view(a)?.task.state == .completed && h.engine.view(b)?.task.state == .completed)
    }

    @Test func theLockIsReleasedWhenATaskIsCancelled() async {
        let plan = UnityScripts.plan([UnityScripts.step("s1", "Play", "unityPlayMode", validation: "unityPlayObserved", unity: "{\"observeSeconds\":30,\"requireNoNewErrors\":false}")])
        let h = UnityHarness(script: UnityScripts.standard(plan: plan))
        let id = await h.task.submit("Play for a long time", project: h.project)
        #expect(await h.task.waitUntil(10) { h.editor.isPlaying })
        let started = Date()
        h.engine.cancel(id)
        await h.engine.waitUntilFinished(id)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(h.engine.view(id)?.task.state == .cancelled && h.editor.isPlaying == false)       // the Play Mode it started is left
        #expect(h.service.lock.heldCount == 0)
        #expect(h.engine.view(id)?.task.reportArtifactID != nil)
    }

    // MARK: Restart / idempotency

    @Test func quittingMidTaskInterruptsItAndAResumedPlayStepTakesBackAnOwnedEditor() async {
        let plan = UnityScripts.plan([UnityScripts.step("s1", "Play", "unityPlayMode", validation: "unityPlayObserved", unity: "{\"observeSeconds\":30,\"requireNoNewErrors\":false}")])
        let h = UnityHarness(script: UnityScripts.standard(plan: plan))
        let id = await h.task.submit("Play", project: h.project)
        #expect(await h.task.waitUntil(10) { h.editor.isPlaying })
        h.engine.prepareForTermination()
        await h.engine.waitUntilIdle()
        #expect(h.task.task(id).state == .interrupted)
        h.editor.isPlaying = true                                           // what an unintercepted crash would leave behind
        h.relaunch(script: UnityScripts.standard(plan: UnityScripts.plan([UnityScripts.step("s1", "Play", "unityPlayMode", validation: "unityPlayObserved", unity: "{\"observeSeconds\":1,\"requireNoNewErrors\":false}")])))
        #expect(h.engine.view(id)?.task.state == .interrupted)
        #expect(h.engine.resume(id))
        await h.engine.waitUntilFinished(id)
        #expect(h.engine.view(id)?.task.state == .completed && h.editor.isPlaying == false)
    }

    @Test func aUsersEditorThatIsAlreadyPlayingIsNotTakenOver() async {
        let plan = UnityScripts.plan([UnityScripts.step("s1", "Play", "unityPlayMode", validation: "unityPlayObserved", unity: "{\"observeSeconds\":1}")])
        let h = UnityHarness(script: UnityScripts.standard(plan: plan), editorOwned: false)
        h.editor.isPlaying = true
        let v = await h.run("Play")
        #expect(v.task.failureCategory == .unsafeEditorState && h.editor.isPlaying)
        #expect(!h.editor.received.contains("exitPlayMode"))
    }

    @Test func aUsersEditorIsNeverShutDownByJarvis() async {
        let h = UnityHarness(script: UnityScripts.standard(plan: UnityScripts.addCollider), editorOwned: false)
        _ = await h.run("Add a collider")
        await h.service.shutdownOwnedEditors()
        #expect(h.editor.alive && !h.editor.received.contains("shutdown"))
        let session = UnityToolSession(capabilities: .for(.readOnlyAnalysis, unityProject: true), taskID: nil, runID: nil, hub: nil, destructiveRequested: false)
        await #expect(throws: UnityToolError.self) { _ = try await h.service.connection(for: h.project).perform(.shutdown, session: session) }
    }

    @Test func anOwnedEditorIsClosedWhenJarvisShutsItDown() async {
        let h = UnityHarness(script: UnityScripts.standard(plan: UnityScripts.addCollider), editorAlive: false)
        _ = await h.run("Add a collider")
        #expect(h.launcher.launched.count == 1 && h.editor.alive)
        h.service.connection(for: h.project).owned = FakeLauncher.Owned()
        await h.service.shutdownOwnedEditors()
        #expect(!h.editor.alive)
    }

    // MARK: Security and reporting

    @Test func aProviderCannotSmuggleCodeThroughTheUnityAgent() async {
        let plan = UnityScripts.plan([UnityScripts.step("s1", "Edit", "unityEdit", validation: "unityState", unity: "{}", risk: "medium")])
        let h = UnityHarness(script: UnityScripts.standard(plan: plan, unityAgent: #"{"actions":[{"op":"executeMenuItem","menuItem":"File/Quit"}]}"#))
        let v = await h.run("Edit the scene")
        #expect(v.task.state == .failed && v.task.failureCategory == .securityBlocked)
        #expect(h.editor.received.isEmpty || h.editor.received.allSatisfy { !$0.hasPrefix("execute") })
        #expect(Set(h.editor.received).isSubset(of: UnityOperation.allWireNames))
    }

    @Test func theUnityAgentProposesAndJarvisAppliesTypedActions() async {
        let plan = UnityScripts.plan([UnityScripts.step("s1", "Inspect", "unityInspect", validation: "unityInspected", unity: "{\"targets\":[\"TestCube\"]}"),
                                      UnityScripts.step("s2", "Edit", "unityEdit", deps: ["s1"], validation: "unityState", unity: "{}", risk: "medium")])
        let h = UnityHarness(script: UnityScripts.standard(plan: plan, unityAgent: #"{"summary":"collider","actions":[{"op":"addComponent","target":{"path":"TestCube"},"componentType":"BoxCollider"}]}"#))
        let v = await h.run("Add a BoxCollider to TestCube")
        #expect(v.task.state == .completed, "\(v.task.failureReason ?? "")")
        #expect(h.editor.objects.first { $0.name == "TestCube" }!.components.contains("BoxCollider"))
        let job = h.task.runner.jobs("UnityAgent").first
        #expect(job?.job.prompt.contains("TestCube") == true && job?.job.prompt.contains("What JARVIS read from the editor") == true)
        // Unity coding/reasoning is development work: the local model is excluded by the routing profile.
        #expect(job?.job.profile.requiresCoding == true && job?.job.profile.containsProjectCode == true)
        #expect(LocalModelPolicy.evaluate(job!.job.profile).eligible == false)
    }

    @Test func theReportStatesUnityFactsAndNeverClaimsVisualValidation() async {
        let h = UnityHarness(script: UnityScripts.standard(plan: UnityScripts.addCollider))
        let v = await h.run("Add a BoxCollider to TestCube if it does not have one")
        let r = h.engine.report(for: v.id)
        let text = r?.markdown() ?? ""
        #expect(text.contains("## Unity") && text.contains("Unity compile: PASS") && text.contains("Visual validation: NOT PERFORMED"))
        #expect(text.contains("Unity edit: added BoxCollider"))
        #expect(!text.lowercased().contains("looks correct") && !text.lowercased().contains("visual validation passed"))
    }

    @Test func unityToolRunsAreObservableAndSanitized() async {
        let h = UnityHarness(script: UnityScripts.standard(plan: UnityScripts.addCollider))
        let v = await h.run("Add a BoxCollider to TestCube if it does not have one")
        let runs = ((try? h.task.repo.agentRuns(taskID: v.id)) ?? []).filter { $0.agentType == "UnityTool" }
        #expect(runs.count == 4 && runs.allSatisfy { $0.engine == .tool && $0.status == .succeeded })
        let events = runs.flatMap { (try? h.task.repo.events(runID: $0.id)) ?? [] }.map(\.summary)
        #expect(events.contains { $0.contains("add BoxCollider") } && events.contains { $0.contains("save scene") })
    }

    @Test func aCheckpointCarriesBoundedUnityEvidence() async {
        let h = UnityHarness(script: UnityScripts.standard(plan: UnityScripts.addCollider))
        let v = await h.run("Add a BoxCollider to TestCube if it does not have one")
        guard let aid = v.task.checkpointArtifactID ?? h.task.task(v.id).checkpointArtifactID, let art = try? h.task.artifacts.artifact(aid), let data = try? h.task.artifacts.read(art),
              let cp = try? JSONDecoder.iso.decode(TaskEngine.Checkpoint.self, from: data) else { Issue.record("no checkpoint"); return }
        #expect(cp.unity?.baseline != nil && cp.unity?.editorVersion == "6000.5.1f1" && !(cp.unity?.facts.isEmpty ?? true))
        #expect(data.count < 60_000)
    }

    @Test func nonUnityProjectsAreUnaffected() async {
        let h = TaskHarness(script: Scripts.standard())
        let project = TaskFixtures.calculatorProject()
        let v = await h.run(project: project)
        #expect(v.task.state == .completed && !v.task.capabilities.allows(.inspectUnity))
    }
}

@Suite("Unity × Git baseline", .serialized)
@MainActor
struct UnityGitTests {
    @Test func aSceneFileWithUncommittedChangesNeedsApprovalBeforeJarvisSavesIt() async {
        let project = UnityFixture.make()
        _ = TaskFixtures.git(["init", "-q", "-b", "main"], in: project)
        try! "*.tmp\n".write(toFile: project + "/.gitignore", atomically: true, encoding: .utf8)
        _ = TaskFixtures.git(["add", "-A"], in: project); _ = TaskFixtures.git(["-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "init"], in: project)
        try! "scene edited by the user in a text editor".write(toFile: project + "/Assets/Scenes/FixtureScene.unity", atomically: true, encoding: .utf8)        // uncommitted
        let h = UnityHarness(script: UnityScripts.standard(plan: UnityHarness.editPlan("{\"op\":\"addComponent\",\"target\":{\"path\":\"TestCube\"},\"componentType\":\"BoxCollider\"}")), project: project)
        let denied = await h.runWithApprovals("Add a collider", answers: [("uncommitted changes", false)])
        #expect(denied.task.failureCategory == .approvalDenied && !h.editor.received.contains("addComponent"))
        let approved = await h.runWithApprovals("Add a collider", answers: [("uncommitted changes", true)])
        #expect(approved.task.state == .completed, "\(approved.task.failureReason ?? "")")
    }

    @Test func twoProjectsGetTwoIndependentConnectionsAndNothingCrosses() async {
        let a = UnityFixture.make(), b = UnityFixture.make()
        let simA = SimulatedUnityEditor(root: a), simB = SimulatedUnityEditor(root: b)
        let service = UnityService()
        service.transportFactory = { root in root == UnityProcessScanner.canonical(a) ? simA : simB }
        let ca = service.connection(for: a), cb = service.connection(for: b)
        #expect(ca !== cb && ca.transport === simA && cb.transport === simB)
        let session = UnityToolSession(capabilities: .for(.development, unityProject: true), taskID: nil, runID: nil, hub: nil, destructiveRequested: false)
        _ = try? await ca.perform(.addComponent(UnityTarget(path: "TestCube"), componentType: "BoxCollider", ifAbsent: true), session: session)
        #expect(simA.received == ["addComponent"] && simB.received.isEmpty)                      // the other editor never saw it
        #expect(simB.objects.first { $0.name == "TestCube" }!.components.contains("BoxCollider") == false)
    }
}
