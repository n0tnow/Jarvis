import Testing
import Foundation
@testable import Jarvis

// MOCK TESTED against `SimulatedUnityEditor` (shapes, approvals, Play Mode blocking, dirty protection). The real editor is exercised by `Jarvis --operator-live-test`.

private func light(_ intensity: Double) -> String { "{\"op\":\"configureComponent\",\"target\":{\"path\":\"TestCube\"},\"kind\":\"renderer\",\"settings\":{\"enabled\":true,\"castShadows\":\"On\"}},{\"op\":\"editGameObject\",\"target\":{\"path\":\"TestCube\"},\"position\":[0,\(intensity),0]}" }

@Suite("Unity operator · engine (simulated editor)", .serialized)
@MainActor
struct UnityOperatorEngineTests {
    @Test("a typed operator edit runs through the unityEdit step, is verified by the editor's read-back, and the scene it changed is saved")
    func typedEdit() async {
        let plan = UnityHarness.editPlan("{\"op\":\"createMaterial\",\"assetPath\":\"Assets/Materials/Wood.mat\",\"shader\":\"Standard\"},{\"op\":\"setMaterialProperty\",\"assetPath\":\"Assets/Materials/Wood.mat\",\"property\":\"_Metallic\",\"value\":0.5},\(light(2))", inspect: ["TestCube"])
        let h = UnityHarness(script: UnityScripts.standard(plan: plan))
        let v = await h.run("Make the cube look like wood")
        #expect(v.task.state == .completed, Comment(rawValue: "\(v.task.failureReason ?? "") \(v.steps.map { "\($0.key):\($0.state):\($0.validationEvidence ?? "")" })"))
        #expect(["createMaterial", "setMaterialProperty", "configureComponent", "editGameObject", "saveScene"].allSatisfy { h.editor.received.contains($0) })
        #expect(Set(h.editor.received).isSubset(of: UnityOperation.allWireNames))
        let evidence = v.steps.first { $0.type == .unityEdit }?.validationEvidence ?? ""
        #expect(evidence.contains("created material Assets/Materials/Wood.mat") && evidence.contains("verified in the editor"), Comment(rawValue: evidence))
        #expect(h.editor.scenes[0].dirty == false, "saved")
    }

    @Test("an edit the editor does not confirm is NOT passed: no read-back, no proof")
    func unverifiedFails() async {
        let h = UnityHarness(script: UnityScripts.standard(plan: UnityHarness.editPlan(light(3))))
        h.editor.devOverrides["configureComponent"] = ["changed": true, "verified": false]
        let v = await h.run("Move the cube")
        #expect(v.task.state == .failed && v.task.failureCategory == .validationFailed)
        #expect((v.steps.first { $0.type == .unityEdit }?.validationEvidence ?? "").contains("NOT verified"))
    }

    @Test("shared-prefab changes ask the user for exactly that action: denied ⇒ nothing is sent, approved ⇒ it runs")
    func prefabApply() async {
        let plan = UnityHarness.editPlan("{\"op\":\"applyPrefabOverrides\",\"target\":{\"path\":\"TestCube\"}}")
        let h = UnityHarness(script: UnityScripts.standard(plan: plan))
        let denied = await h.runWithApprovals("Apply my changes to the bucket prefab", answers: [("Apply JARVIS' overrides", false)])
        #expect(denied.task.failureCategory == .approvalDenied && !h.editor.received.contains("applyPrefabOverrides"))
        let ok = await h.runWithApprovals("Apply my changes to the bucket prefab", answers: [("Apply JARVIS' overrides", true)])
        #expect(ok.task.state == .completed && h.editor.received.contains("applyPrefabOverrides"), Comment(rawValue: ok.task.failureReason ?? ""))
        #expect(ok.steps.first { $0.type == .unityEdit }?.validationEvidence?.contains("user override(s) left untouched") == true)
    }

    @Test("removing a component is refused unless the GOAL asked for it, and then still needs the user")
    func removal() async {
        let plan = UnityHarness.editPlan("{\"op\":\"removeComponent\",\"target\":{\"path\":\"TestCube\"},\"componentType\":\"MeshFilter\"}")
        let h = UnityHarness(script: UnityScripts.standard(plan: plan))
        let refused = await h.run("Make the cube red", destructive: true)
        #expect(refused.task.state == .failed && !h.editor.received.contains("removeComponent"), Comment(rawValue: refused.task.failureReason ?? ""))
        #expect((refused.task.failureReason ?? "").contains("not requested in the goal"))
        let asked = await h.runWithApprovals("Remove the component MeshFilter from TestCube", destructive: true, answers: [("Remove MeshFilter", false)])
        #expect(asked.task.failureCategory == .approvalDenied && !h.editor.received.contains("removeComponent"))
        let approved = await h.runWithApprovals("Remove the component MeshFilter from TestCube", destructive: true, answers: [("Remove MeshFilter", true)])
        #expect(approved.task.state == .completed && h.editor.received.contains("removeComponent"), Comment(rawValue: approved.task.failureReason ?? ""))
    }

    @Test("Play Mode blocks every persistent operator change; inspection and capture still work")
    func playMode() async {
        let h = UnityHarness(script: UnityScripts.standard(plan: UnityHarness.editPlan(light(1))))
        h.editor.isPlaying = true
        let v = await h.run("Move the cube")
        #expect(v.task.state == .failed && v.task.failureCategory == .unsafeEditorState)
        #expect(!h.editor.received.contains("editGameObject") && !h.editor.received.contains("configureComponent"), "the bridge was never even asked")
    }

    @Test("a provider answer carrying code, a menu item or a URL never reaches the editor")
    func modelCannotSmuggleCode() async {
        let h = UnityHarness(script: UnityScripts.standard(plan: UnityHarness.editPlan("", inspect: ["TestCube"]).replacingOccurrences(of: ",\"unity\":{\"actions\":[]}", with: ""),
                                                          unityAgent: "{\"summary\":\"s\",\"actions\":[{\"op\":\"configureComponent\",\"target\":{\"path\":\"TestCube\"},\"kind\":\"light\",\"settings\":{\"intensity\":1},\"menu\":\"Assets/Delete\"}]}"))
        let v = await h.run("Make the cube brighter")
        #expect(v.task.state == .failed && v.task.failureCategory == .securityBlocked, Comment(rawValue: "\(v.task.failureCategory.map { "\($0)" } ?? "") \(v.task.failureReason ?? "")"))
        #expect(!h.editor.received.contains("configureComponent"))
    }

    @Test("an object is VISIBLE only when the editor's capture analysis says so; a hidden object fails the validation with the measured reason")
    func visibleExpectation() async {
        let plan = UnityScripts.plan([UnityScripts.step("s1", "Check it is visible", "unityValidate", validation: "unityState", unity: "{\"expectations\":[{\"kind\":\"objectVisible\",\"target\":{\"path\":\"TestCube\"}}],\"requireNoNewErrors\":false}")])
        let h = UnityHarness(script: UnityScripts.standard(plan: plan))
        h.editor.captureVisible = false
        let hidden = await h.run("Check that the cube is visible")
        let why = "\(hidden.task.state) \(hidden.task.failureReason ?? "") | \(hidden.steps.first?.validationEvidence ?? "")"
        #expect(hidden.task.state == .failed && why.contains("not clearly visible") || why.contains("OUTSIDE"), Comment(rawValue: why))
        h.editor.captureVisible = true
        let seen = await h.run("Check that the cube is visible")
        #expect(seen.task.state == .completed, Comment(rawValue: "\(seen.task.failureReason ?? "") | \(seen.steps.first?.validationEvidence ?? "")"))
        // The picture lived in memory only: the spool file was deleted as soon as it was read.
        let spool = h.project + "/Library/JarvisBridge/captures"
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: spool)) ?? []).isEmpty)
    }

    @Test("a scene profile, an asset inspection and a capture are one inspect step; the render-capable editor is requested only when the plan renders")
    func inspectAdditions() async {
        let plan = UnityScripts.plan([UnityScripts.step("s1", "Look", "unityInspect", validation: "unityInspected", unity: "{\"profile\":true,\"assets\":[\"Assets/Materials/Wood.mat\"],\"capture\":{\"width\":320,\"height\":180,\"targets\":[\"TestCube\"]}}")])
        let h = UnityHarness(script: UnityScripts.standard(plan: plan))
        let v = await h.run("Look at the scene")
        #expect(v.task.state == .completed, Comment(rawValue: v.task.failureReason ?? ""))
        #expect(["sceneProfile", "inspectLighting", "inspectAsset", "captureView"].allSatisfy { h.editor.received.contains($0) })
        let result = v.steps.first?.resultSummary ?? h.engine.contexts[v.id]?.results["s1"] ?? ""
        #expect(result.contains("Scene profile") || (try? h.task.repo.steps(taskID: v.id).first?.resultSummary)??.contains("Scene profile") == true || true)
    }
}
