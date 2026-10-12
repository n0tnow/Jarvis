import Testing
import Foundation
@testable import Jarvis

private func finding(_ title: String, in root: String, task: UUID?, paths: [String], summary: String = "", key: String) -> RawFinding {
    RawFinding(origin: .reviewFinding, title: title, summary: summary, category: nil,
               evidence: [EvidenceItem(kind: .modelClaim, summary: "reviewer suggestion", reference: nil)],
               affectedPaths: paths, originTaskID: task, projectRoot: root, claimedDesignImpact: false, claimedConfidence: 1.0, needsModelAssessment: false, eventKey: key)
}

@Suite("V0.6 × V0.5: Unity findings stay under the decision layer's policy", .serialized)
@MainActor
struct UnityProactiveTests {
    @Test func unityDesignChangesArePropositionsInEveryModeNeverAutomaticActions() async throws {
        let project = UnityFixture.make()
        for mode in [AutonomyMode.askBeforeActing, .lowRiskAutonomous] {
            let h = ProactiveHarness(mode: mode)
            let tid = await h.base.submit("Fix the failing calculation test", project: TaskFixtures.calculatorProject())
            await h.engine.waitUntilFinished(tid)
            await h.settle(1)
            let before = h.allTasks().count
            let sceneBefore = try String(contentsOfFile: project + "/Assets/Scenes/FixtureScene.unity", encoding: .utf8)
            for (i, title) in ["Redesign the fixture scene with a new lighting setup", "The scene layout could be rearranged around a new skybox", "Change the UI flow of the main menu", "Switch the art direction to a painted look"].enumerated() {
                let r = await h.opportunities.ingest(finding(title, in: project, task: tid, paths: ["Assets/Scenes/FixtureScene.unity"], key: "unity-d\(mode.rawValue)\(i)"))
                guard case .proposed(let oid, let pid) = r else { Issue.record("not a proposal in \(mode): \(title) → \(r)"); continue }
                #expect(h.opportunity(oid)?.assessment?.designImpact == .meaningful, Comment(rawValue: title))
                #expect(h.proposal(pid)?.status == .pending)
            }
            #expect(h.allTasks().count == before)                                                   // no task, no scene mutation before approval
            #expect(try String(contentsOfFile: project + "/Assets/Scenes/FixtureScene.unity", encoding: .utf8) == sceneBefore)
        }
    }

    @Test func purchasesAndDeletionsInUnityAreCriticalOrDestructiveAndNeverAutomatic() async throws {
        let project = UnityFixture.make()
        let h = ProactiveHarness(mode: .lowRiskAutonomous)
        let tid = await h.base.submit("Fix the failing calculation test", project: TaskFixtures.calculatorProject())
        await h.engine.waitUntilFinished(tid)
        await h.settle(1)
        let before = h.allTasks().count
        for (i, title) in ["Purchase this Unity asset from the Asset Store", "Delete these unused prefabs", "Buy the paid asset pack for the bath scene"].enumerated() {
            let r = await h.opportunities.ingest(finding(title, in: project, task: tid, paths: ["Assets/Prefabs"], key: "unity-c\(i)"))
            guard case .proposed(let oid, let pid) = r else { Issue.record("not proposed: \(title) → \(r)"); continue }
            #expect(h.opportunity(oid)?.policyDecision == .requireApproval && h.proposal(pid)?.critical == true, Comment(rawValue: title))
            let out = await h.proposals.approve(pid, source: .test)
            if case .unsupported(let missing) = out { #expect(!missing.isEmpty) } else { Issue.record("approval must not make it possible: \(out)") }
        }
        #expect(h.allTasks().count == before)
    }

    @Test func unityCapabilitiesAreNeverPartOfWhatAnAutomaticActionMayUse() {
        let allowed: Set<TaskCapability> = [.readProject, .writeProject, .runBuild, .runTests]
        #expect(TaskCapability.unityDevelopment.isDisjoint(with: allowed))
        #expect(!TaskCapability.unityDevelopment.isSubset(of: allowed))
        // The policy's auto-action capability rule is a subset test against exactly this read/write/build/test set.
        let src = (try? String(contentsOfFile: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path + "/Sources/Jarvis/Proactive/OpportunityPolicy.swift", encoding: .utf8)) ?? ""
        #expect(src.contains("isSubset") && src.contains(".readProject") && !src.contains("modifyUnityScene"))
    }
}
