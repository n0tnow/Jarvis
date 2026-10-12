import Testing
import Foundation
@testable import Jarvis

@Suite("Unity policy (pure rules)")
struct UnityPolicyTests {
    let dev = CapabilitySet.for(.development, unityProject: true)
    let ro = CapabilitySet.for(.readOnlyAnalysis, unityProject: true)
    func status(playing: Bool = false, compiling: Bool = false, failed: Bool = false, owned: Bool = true, scenes: [UnitySceneInfo] = [UnitySceneInfo(path: "Assets/Scenes/A.unity", name: "A", dirty: false)]) -> UnityStatusSnapshot {
        UnityStatusSnapshot(owned: owned, state: playing ? "playing" : (compiling ? "compiling" : "edit"), isCompiling: compiling, isPlaying: playing, compileFailed: failed, scenes: scenes)
    }
    let add = UnityOperation.addComponent(UnityTarget(path: "A"), componentType: "BoxCollider", ifAbsent: true)

    @Test func capabilitiesGateEveryOperation() {
        #expect(UnityPolicy.authorize(add, capabilities: dev, status: status(), destructiveRequested: false) == .allow)
        if case .deny(let c, _) = UnityPolicy.authorize(add, capabilities: ro, status: status(), destructiveRequested: false) { #expect(c == .capabilityDenied) } else { Issue.record("read-only task may not edit") }
        if case .deny(let c, _) = UnityPolicy.authorize(.runTests(mode: .editMode, testNames: [], groupNames: [], assemblyNames: []), capabilities: ro, status: status(), destructiveRequested: false) { #expect(c == .capabilityDenied) } else { Issue.record() }
        #expect(UnityPolicy.authorize(.inspectGameObject(UnityTarget(name: "A"), depth: 1, maxChildren: 5), capabilities: ro, status: status(), destructiveRequested: false) == .allow)
        #expect(UnityPolicy.authorize(.readConsole(afterSeq: 0, max: 10, types: []), capabilities: ro, status: status(), destructiveRequested: false) == .allow)
    }

    @Test func persistentMutationIsBlockedInPlayModeAndWhileCompiling() {
        for (playing, compiling) in [(true, false), (false, true)] {
            if case .deny(let c, _) = UnityPolicy.authorize(add, capabilities: dev, status: status(playing: playing, compiling: compiling), destructiveRequested: false) { #expect(c == .unsafeEditorState) } else { Issue.record("not blocked") }
        }
        // Inspection stays allowed during Play Mode.
        #expect(UnityPolicy.authorize(.inspectGameObject(UnityTarget(path: "A"), depth: 0, maxChildren: 0), capabilities: dev, status: status(playing: true), destructiveRequested: false) == .allow)
        // Even a deletion approval cannot override Play Mode.
        if case .deny = UnityPolicy.authorize(.deleteGameObject(UnityTarget(path: "A")), capabilities: dev, status: status(playing: true), destructiveRequested: true) {} else { Issue.record("delete in Play Mode") }
        if case .deny(let c, _) = UnityPolicy.allowsProjectFileEdit(status: status(playing: true)) { #expect(c == .unsafeEditorState) } else { Issue.record("script edit in Play Mode") }
        #expect(UnityPolicy.allowsProjectFileEdit(status: status()) == .allow && UnityPolicy.allowsProjectFileEdit(status: nil) == .allow)
    }

    @Test func playModeCannotBeEnteredWithCompileErrorsAndTestsNeedACleanEditor() {
        if case .deny(let c, _) = UnityPolicy.authorize(.enterPlayMode, capabilities: dev, status: status(failed: true), destructiveRequested: false) { #expect(c == .compileFailed) } else { Issue.record() }
        let run = UnityOperation.runTests(mode: .editMode, testNames: [], groupNames: [], assemblyNames: [])
        if case .deny = UnityPolicy.authorize(run, capabilities: dev, status: status(playing: true), destructiveRequested: false) {} else { Issue.record() }
        let dirty = [UnitySceneInfo(path: "Assets/Scenes/A.unity", name: "A", dirty: true)]
        if case .deny = UnityPolicy.authorize(run, capabilities: dev, status: status(scenes: dirty), destructiveRequested: false) {} else { Issue.record("tests with unsaved scenes") }
        if case .deny = UnityPolicy.authorize(.openScene(path: "Assets/Scenes/B.unity"), capabilities: dev, status: status(scenes: dirty), destructiveRequested: false) {} else { Issue.record("open scene would discard") }
    }

    @Test func aSceneWithUnsavedUserWorkNeedsApprovalAndOnlyThatApprovalUnlocksIt() {
        let user = [UnitySceneInfo(path: "Assets/Scenes/A.unity", name: "A", dirty: true, jarvisDirty: false)]
        let mine = [UnitySceneInfo(path: "Assets/Scenes/A.unity", name: "A", dirty: true, jarvisDirty: true)]
        if case .needsApproval(let action, _, let risk) = UnityPolicy.authorize(add, capabilities: dev, status: status(scenes: user), destructiveRequested: false) {
            #expect(action.contains("unsaved") && risk == .high)
        } else { Issue.record("expected an approval question") }
        #expect(UnityPolicy.authorize(add, capabilities: dev, status: status(scenes: user), destructiveRequested: false, approvedDirtyScenes: ["Assets/Scenes/A.unity"]) == .allow)
        #expect(UnityPolicy.authorize(add, capabilities: dev, status: status(scenes: mine), destructiveRequested: false) == .allow)       // JARVIS' own pending change
        #expect(UnityPolicy.authorize(.saveScene(scene: "Assets/Scenes/A.unity"), capabilities: dev, status: status(scenes: user), destructiveRequested: false) != .allow)
    }

    @Test func mutationsNeedOnePreciseTargetNeverAName() {
        for op in [UnityOperation.addComponent(UnityTarget(name: "Player"), componentType: "X", ifAbsent: true),
                   .setSerializedProperty(UnityTarget(name: "Player"), componentType: "X", componentIndex: nil, propertyPath: "p", expectedOld: nil, newValue: .number(1)),
                   .createPrefab(UnityTarget(name: "Player"), assetPath: "Assets/P.prefab"),
                   .createGameObject(name: "N", scene: nil, parent: UnityTarget(name: "Parent"), primitive: "None", position: nil, rotation: nil, scale: nil, ifAbsent: true)] {
            if case .deny(let c, _) = UnityPolicy.authorize(op, capabilities: dev, status: status(), destructiveRequested: false) { #expect(c == .ambiguousTarget) } else { Issue.record("name-only accepted: \(op.summary)") }
        }
        #expect(UnityPolicy.authorize(.addComponent(UnityTarget(globalId: "GlobalObjectId_V1-2-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-1-0"), componentType: "X", ifAbsent: true), capabilities: dev, status: status(), destructiveRequested: false) == .allow)
        // Name-only is fine for lookups.
        #expect(UnityPolicy.authorize(.findGameObjects(name: "Player", componentType: nil, max: 5), capabilities: ro, status: status(), destructiveRequested: false) == .allow)
    }

    @Test func deletionNeedsTheGoalToAskForItAndThenAnApprovalForEachAction() {
        let del = UnityOperation.deleteGameObject(UnityTarget(path: "A"))
        if case .deny(let c, _) = UnityPolicy.authorize(del, capabilities: dev, status: status(), destructiveRequested: false) { #expect(c == .securityBlocked) } else { Issue.record() }
        if case .needsApproval(_, _, let risk) = UnityPolicy.authorize(del, capabilities: dev, status: status(), destructiveRequested: true) { #expect(risk == .high) } else { Issue.record("expected approval") }
        if case .deny(let c, _) = UnityPolicy.authorize(.deleteGameObject(UnityTarget(name: "A")), capabilities: dev, status: status(), destructiveRequested: true) { #expect(c == .ambiguousTarget) } else { Issue.record() }
        #expect(!dev.allows(.deleteUnityObject))
    }

    @Test func pathsStayInsideAssets() {
        for p in ["../x.unity", "/etc/passwd", "Assets/../../x.unity", "Packages/x.unity", "Assets//x.unity", ""] { #expect(!UnityPolicy.isSafeProjectPath(p), "accepted \(p)") }
        #expect(UnityPolicy.isSafeProjectPath("Assets/Scenes/A.unity"))
        for op in [UnityOperation.openScene(path: "../x.unity"), .saveScene(scene: "/etc/x"), .createPrefab(UnityTarget(path: "A"), assetPath: "Assets/../x.prefab")] {
            if case .deny(let c, _) = UnityPolicy.authorize(op, capabilities: dev, status: status(), destructiveRequested: false) { #expect(c == .workspaceViolation) } else { Issue.record("\(op.summary)") }
        }
    }

    @Test func onlyAnOwnedEditorMayBeClosed() {
        if case .deny = UnityPolicy.authorize(.shutdown, capabilities: ro, status: status(owned: false), destructiveRequested: false) {} else { Issue.record("closed a user's editor") }
        #expect(UnityPolicy.authorize(.shutdown, capabilities: ro, status: status(owned: true), destructiveRequested: false) == .allow)
    }

    @Test func identityResolutionNeverPicksAmongSeveral() {
        func ref(_ i: Int) -> UnityObjectRef { UnityObjectRef(name: "Twin", scene: "Assets/S.unity", path: "Twin", indexedPath: "Twin#\(i)", globalId: nil) }
        #expect(UnityPolicy.resolve([]) == .none)
        #expect(UnityPolicy.resolve([ref(0)]) == .unique(ref(0)))
        #expect(UnityPolicy.resolve([ref(0), ref(1)]) == .ambiguous([ref(0), ref(1)]))
        #expect(UnityPolicy.ambiguityMessage(name: "Twin", candidates: [ref(0), ref(1)]).contains("Twin#1"))
    }
}
