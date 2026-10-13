import Testing
import Foundation
@testable import Jarvis

@Suite("Unity foundation: versions, discovery, detection, protocol, parsing")
struct UnityFoundationTests {
    // MARK: Versions & discovery

    @Test func versionsParseAndCompareStructurally() {
        #expect(UnityVersion("6000.5.1f1")?.description == "6000.5.1f1")
        #expect(UnityVersion("m_EditorVersion: 2022.3.12f1")?.major == 2022)
        #expect(UnityVersion("6000.5.1f1 (0d9463e84828)")?.patch == 1)
        #expect(UnityVersion("2022.3") == nil && UnityVersion("abc") == nil && UnityVersion("") == nil)
        #expect(UnityVersion("6000.5.1f1")! > UnityVersion("2022.3.62f1")!)
        #expect(UnityVersion("2022.3.9f1")! < UnityVersion("2022.3.12f1")!)
    }

    @Test func discoveryReadsOnlyTheGivenEditorFolders() throws {
        let root = NSTemporaryDirectory() + "unity-editors-\(UUID().uuidString.prefix(6))"
        defer { try? FileManager.default.removeItem(atPath: root) }
        for v in ["6000.5.1f1", "2022.3.12f1"] {
            let exe = "\(root)/\(v)/Unity.app/Contents/MacOS/Unity"
            try FileManager.default.createDirectory(atPath: (exe as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: exe, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        try FileManager.default.createDirectory(atPath: "\(root)/notaversion", withIntermediateDirectories: true)
        let found = UnityDiscovery.discover(roots: [root])
        #expect(found.map(\.version.description) == ["6000.5.1f1", "2022.3.12f1"])
        #expect(found.allSatisfy { $0.available })
        #expect(found.allSatisfy { $0.executablePath.hasSuffix("/Contents/MacOS/Unity") })
    }

    @Test func aVersionMismatchNeverSilentlyPicksAnotherEditor() {
        func install(_ v: String, available: Bool = true) -> UnityEditorInstall { UnityEditorInstall(version: UnityVersion(v)!, appPath: "/x/\(v)/Unity.app", executablePath: "/x/\(v)/Unity.app/Contents/MacOS/Unity", available: available, lastCheckedAt: Date()) }
        let installs = [install("6000.5.1f1"), install("2022.3.12f1")]
        #expect(UnityDiscovery.choose(for: UnityVersion("6000.5.1f1"), among: installs) == .exact(installs[0]))
        if case .needsUpgradeApproval(let declared, let candidate) = UnityDiscovery.choose(for: UnityVersion("2022.3.5f1"), among: installs) {
            #expect(declared.description == "2022.3.5f1" && candidate.version.description == "2022.3.12f1")     // same release line first
        } else { Issue.record("expected an upgrade question") }
        if case .needsUpgradeApproval = UnityDiscovery.choose(for: UnityVersion("2019.4.1f1"), among: installs) {} else { Issue.record("expected an upgrade question") }
        #expect(UnityDiscovery.choose(for: UnityVersion("6000.5.1f1"), among: [install("6000.5.1f1", available: false)]) == .noEditor)
        #expect(UnityDiscovery.choose(for: nil, among: installs) == .unknownDeclaredVersion)
    }

    // MARK: Project detection

    @Test func projectDetectionIsStructuralAndBounded() throws {
        let p = UnityFixture.make(bridgeInstalled: false)
        defer { try? FileManager.default.removeItem(atPath: p) }
        #expect(UnityProjectDetector.isUnityProject(root: p))
        #expect(!UnityProjectDetector.isUnityProject(root: NSTemporaryDirectory()))
        let d = try #require(UnityProjectDetector.describe(root: p))
        #expect(d.declaredVersion?.description == "6000.5.1f1" && d.declaredVersionRaw == "6000.5.1f1")
        #expect(d.scenes == ["Assets/Scenes/FixtureScene.unity"] && d.hasTestFramework && d.testFrameworkVersion == "1.7.0" && d.renderPipeline == "Built-in")
        #expect(!d.bridgeInstalled && !d.hasLibrary)
        try UnityBridgeInstaller.install(root: p).forEach { _ in }
        #expect(UnityProjectDetector.describe(root: p)?.bridgeInstalled == true && UnityBridgeInstaller.isCurrent(root: p))
        // Render pipeline from the manifest.
        try "{\"dependencies\":{\"com.unity.render-pipelines.universal\":\"17.0.0\"}}".write(toFile: p + "/Packages/manifest.json", atomically: true, encoding: .utf8)
        #expect(UnityProjectDetector.describe(root: p)?.renderPipeline == "Universal (URP)")
    }

    @Test func theBridgeInstallerWritesOnlyItsOwnPackageFolder() throws {
        let p = UnityFixture.make(bridgeInstalled: false)
        defer { try? FileManager.default.removeItem(atPath: p) }
        let before = try FileManager.default.subpathsOfDirectory(atPath: p).filter { !$0.hasPrefix("Packages/com.jarvis.bridge") }.sorted()
        let written = try UnityBridgeInstaller.install(root: p)
        #expect(written.allSatisfy { $0.hasPrefix("Packages/com.jarvis.bridge/") })
        let after = try FileManager.default.subpathsOfDirectory(atPath: p).filter { !$0.hasPrefix("Packages/com.jarvis.bridge") }.sorted()
        #expect(before == after)
        #expect(throws: UnityBridgeInstaller.InstallError.self) { try UnityBridgeInstaller.install(root: NSTemporaryDirectory()) }
    }

    @Test func theEmbeddedBridgePackageMatchesTheSourceFolder() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path + "/UnityBridge/com.jarvis.bridge"
        for f in UnityBridgePackage.files {
            let disk = try String(contentsOfFile: src + "/" + f.path, encoding: .utf8).trimmingCharacters(in: .newlines)
            #expect(disk == f.content.trimmingCharacters(in: .newlines), "\(f.path) is stale — run scripts/gen_unity_bridge.sh")
        }
        let onDisk = try FileManager.default.subpathsOfDirectory(atPath: src).filter { !$0.hasSuffix(".meta") && !$0.hasPrefix(".") && !$0.hasSuffix("/") }.filter { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: src + "/" + $0, isDirectory: &d) && !d.boolValue }
        #expect(Set(onDisk) == Set(UnityBridgePackage.files.map(\.path)))
    }

    @Test func theProtocolNamesMatchTheOperationsTheEditorBridgeRegisters() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path + "/UnityBridge/com.jarvis.bridge"
        let text = try String(contentsOfFile: src + "/Editor/Ops.cs", encoding: .utf8) + (try String(contentsOfFile: src + "/Editor/OperatorOps.cs", encoding: .utf8)) + (try String(contentsOfFile: src + "/TestRunner/TestOps.cs", encoding: .utf8))
        let re = try NSRegularExpression(pattern: #"(?:R|JarvisBridge\.Register)\(\s*"([A-Za-z]+)""#)
        var registered = Set<String>()
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) { registered.insert(String(text[Range(m.range(at: 1), in: text)!])) }
        #expect(registered == UnityOperation.allWireNames, "bridge-only: \(registered.subtracting(UnityOperation.allWireNames)) · swift-only: \(UnityOperation.allWireNames.subtracting(registered))")
    }

    // MARK: Process arguments (editor ↔ project identity)

    @Test func processArgumentsAreParsedForTheProjectPath() {
        var d = Data(); var argc: Int32 = 5
        withUnsafeBytes(of: &argc) { d.append(contentsOf: $0) }
        d.append(Data("/Applications/Unity/Hub/Editor/6000.5.1f1/Unity.app/Contents/MacOS/Unity".utf8)); d.append(contentsOf: [0, 0, 0])
        for a in ["Unity", "-projectpath", "/Users/me/My Game", "-batchmode", "-x"] { d.append(Data(a.utf8)); d.append(0) }
        d.append(Data("HOME=/Users/me".utf8)); d.append(0)
        let parsed = UnityProcessScanner.parseProcArgs(d)
        #expect(parsed?.args.count == 5)
        #expect(UnityProcessScanner.projectPath(from: parsed?.args ?? []) == "/Users/me/My Game")
        #expect(UnityProcessScanner.isUnityEditorExecutable(parsed?.executable ?? ""))
        #expect(UnityProcessScanner.parseProcArgs(Data([1, 2, 3])) == nil)
    }

    @Test func anEditorIsMatchedToItsProjectNeverToTheFirstProcess() {
        let a = UnityProcessScanner.Editor(pid: 10, executable: "/x/Unity.app/Contents/MacOS/Unity", projectPath: "/tmp/A")
        let b = UnityProcessScanner.Editor(pid: 11, executable: "/x/Unity.app/Contents/MacOS/Unity", projectPath: "/tmp/B")
        #expect(UnityProcessScanner.editor(for: "/tmp/B", among: [a, b])?.pid == 11)
        #expect(UnityProcessScanner.editor(for: "/tmp/C", among: [a, b]) == nil)
    }

    // MARK: Console

    @Test func consoleBaselineAndDeltaSeparateOldErrorsFromNewOnes() {
        func e(_ seq: Int64, _ type: UnityLogType, _ m: String) -> UnityConsoleEntry { UnityConsoleEntry(seq: seq, type: type, rawMessage: m) }
        let before = [e(1, .error, "NullReferenceException at Player.cs:41"), e(2, .log, "hello"), e(3, .warning, "w")]
        let base = UnityConsoleAnalysis.baseline(before, lastSeq: 3)
        let after = before + [e(4, .error, "NullReferenceException at Player.cs:57"), e(5, .exception, "IndexOutOfRange in Inventory.cs:9"), e(6, .warning, "x"), e(7, .log, "y")]
        let d = UnityConsoleAnalysis.delta(after, since: base)
        #expect(d.newErrors.map(\.seq) == [5])                       // genuinely new
        #expect(d.repeatedPreExisting.map(\.seq) == [4])             // same kind of error as before (line numbers collapsed)
        #expect(d.warnings == 1 && d.logs == 1 && d.hasNewErrors && d.lastSeq == 7)
        #expect(!UnityConsoleAnalysis.delta(before, since: base).hasNewErrors)
    }

    @Test func consoleTextIsSanitizedWhenTheEntryIsCreated() {
        let secret = "sk-proj-FAKE0123456789abcdefghijkl"
        let entry = UnityConsoleEntry(seq: 1, type: .error, rawMessage: "boom api_key=\(secret) password=hunter2-fake", rawStack: "at A.B (\(secret))\nat C\nat D\nat E")
        #expect(!entry.message.contains("FAKE0123") && !entry.message.contains("hunter2"))
        #expect(!entry.stackSummary.contains("FAKE0123") && entry.stackSummary.split(separator: "⏎").count <= 3)
        #expect(UnityCompilerError(file: "A.cs", line: 3, rawMessage: "bad \(secret)").message.contains("FAKE0123") == false)
    }

    @Test func bridgeAnswersAreSanitizedButObjectIdentitiesSurvive() {
        let gid = "GlobalObjectId_V1-2-4319735414d274d1e8cb4bceb60d4f02-234361049-0"
        let raw = UnityResponse(id: "1", ok: true, result: ["object": ["globalId": gid, "name": "Player password=hunter2-fake"], "msg": "token sk-proj-FAKE0123456789abcdefghijkl"], session: "s")
        let safe = UnityResponseSanitizer.sanitize(raw)
        let obj = safe.result["object"] as? [String: Any]
        #expect(obj?["globalId"] as? String == gid)
        #expect(!(obj?["name"] as? String ?? "").contains("hunter2") && !(safe.result["msg"] as? String ?? "").contains("FAKE0123"))
        // A forged "globalId" that is really a secret is not waved through.
        let forged = UnityResponseSanitizer.sanitize(UnityResponse(id: "2", ok: true, result: ["globalId": "sk-proj-FAKE0123456789abcdefghijkl"]))
        #expect(!(forged.result["globalId"] as? String ?? "").contains("FAKE0123"))
    }

    // MARK: Values

    @Test func valuesMatchWithFloatToleranceAndDistinguishBoolsFromNumbers() {
        #expect(UnityValue.number(1.000001).matches(.number(1)))
        #expect(!UnityValue.number(1.1).matches(.number(1)))
        #expect(UnityValue.array([.number(1), .number(2)]).matches(.array([.number(1), .number(2.0000001)])))
        #expect(UnityValue(any: true as NSNumber) == .bool(true) && UnityValue(any: 1 as NSNumber) == .number(1))
        #expect(UnityValue(any: ["x": 1]) == nil)
    }

    // MARK: Protocol surface

    @Test func everyOperationEncodesToBoundedTypedJSON() throws {
        let long = String(repeating: "x", count: 5000)
        let op = UnityOperation.inspectComponents(UnityTarget(path: long), types: Array(repeating: long, count: 100), maxProperties: 9999)
        let data = try UnityRequest(id: "a", operation: op).data()
        #expect(data.count < 20_000)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["op"] as? String == "inspectComponents")
        #expect((obj["params"] as? [String: Any])?["maxProperties"] as? Int == 60)
        #expect(UnityOperation.allWireNames.contains(op.wireName))
    }

    @Test func capabilitiesAndKindsOfOperationsAreClassifiedByTheirEffect() {
        #expect(UnityOperation.addComponent(UnityTarget(path: "A"), componentType: "X", ifAbsent: true).isPersistentMutation)
        #expect(!UnityOperation.inspectGameObject(UnityTarget(path: "A"), depth: 1, maxChildren: 1).isPersistentMutation)
        #expect(UnityOperation.deleteGameObject(UnityTarget(path: "A")).isDestructive)
        #expect(UnityOperation.readConsole(afterSeq: 0, max: 1, types: []).capability == .readUnityConsole)
        #expect(UnityOperation.runTests(mode: .editMode, testNames: [], groupNames: [], assemblyNames: []).capability == .runUnityTests)
        #expect(UnityOperation.enterPlayMode.capability == .controlUnityPlayMode)
        #expect(!UnityOperation.createGameObject(name: "A", scene: nil, parent: nil, primitive: "None", position: nil, rotation: nil, scale: nil, ifAbsent: true).isRetryable)
    }

    @Test func unityCapabilitiesAreGrantedByKindAndNeverIncludeDeletionOrNeverGrantedOnes() {
        let analysis = CapabilitySet.for(.readOnlyAnalysis, unityProject: true)
        let dev = CapabilitySet.for(.development, unityProject: true)
        #expect(analysis.allows(.inspectUnity) && analysis.allows(.readUnityConsole) && !analysis.allows(.modifyUnityScene) && !analysis.allows(.runUnityTests) && !analysis.allows(.writeProject))
        #expect(dev.allows(.modifyUnityScene) && dev.allows(.runUnityCompile) && dev.allows(.runUnityTests) && dev.allows(.controlUnityPlayMode) && dev.allows(.saveUnityScene))
        #expect(!dev.allows(.deleteUnityObject) && !dev.allows(.gitPush) && !dev.allows(.purchase) && !dev.allows(.useNetwork))
        #expect(!CapabilitySet.for(.development, unityProject: false).allows(.inspectUnity))
        #expect(CapabilitySet(granted: [.gitPush, .modifyUnityScene]).granted == [.modifyUnityScene])
    }

    // MARK: Provider-supplied actions

    @Test func validTypedActionsAreAccepted() {
        let r = UnityActionParser.parse("""
        Sure! {"summary":"s","actions":[{"op":"addComponent","target":{"path":"TestCube"},"componentType":"BoxCollider"},
        {"op":"setSerializedProperty","target":{"globalId":"GlobalObjectId_V1-2-4319735414d274d1e8cb4bceb60d4f02-1-0"},"componentType":"Counter","propertyPath":"startValue","expectedOld":1,"newValue":5},
        {"op":"createGameObject","name":"Twin","primitive":"Cube","position":[0,1,0]}]}
        """)
        #expect(r.problems.isEmpty && r.actions.count == 3 && !r.policyBlock)
        if case .setSerializedProperty(_, _, _, let p, let old, let new) = r.actions[1].operation { #expect(p == "startValue" && old == .number(1) && new == .number(5)) } else { Issue.record("wrong operation") }
    }

    @Test func providerAnswersThatAskForCodeMenusShellOrScriptingAreRejected() {
        let payloads = [
            #"{"actions":[{"op":"runCSharp","code":"System.IO.File.Delete(\"x\")"}]}"#,
            #"{"actions":[{"op":"executeMenuItem","menuItem":"Assets/Reimport All"}]}"#,
            #"{"actions":[{"op":"addComponent","target":{"path":"A"},"componentType":"BoxCollider","command":"rm -rf /"}]}"#,
            #"{"actions":[{"op":"addComponent","target":{"path":"A"},"componentType":"BoxCollider","script":"print(1)"}]}"#,
            #"{"actions":[{"op":"createGameObject","name":"A","primitive":"None","url":"https://example.invalid/payload"}]}"#,
            #"{"actions":[{"op":"setSerializedProperty","target":{"path":"A"},"componentType":"C","propertyPath":"p","newValue":"AssetDatabase.DeleteAsset(\"Assets\")"}]}"#,
            #"{"actions":[{"op":"osascript","target":{"path":"A"}}]}"#,
        ]
        for p in payloads {
            let r = UnityActionParser.parse(p)
            #expect(r.actions.isEmpty && !r.problems.isEmpty, "accepted: \(p)")
        }
        #expect(UnityActionParser.parse(payloads[0]).policyBlock && UnityActionParser.parse(payloads[1]).policyBlock && UnityActionParser.parse(payloads[2]).policyBlock)
    }

    @Test func malformedActionsAreProblemsNotGuesses() {
        func problems(_ json: String) -> [String] { UnityActionParser.parse(json).problems }
        #expect(!problems("not json").isEmpty && !problems(#"{"actions":[]}"#).isEmpty && !problems(#"{"nope":1}"#).isEmpty)
        #expect(!problems(#"{"actions":[{"op":"addComponent","target":{"path":"A"},"componentType":"Bad Type!"}]}"#).isEmpty)
        #expect(!problems(#"{"actions":[{"op":"createGameObject","name":"a/b"}]}"#).isEmpty)
        #expect(!problems(#"{"actions":[{"op":"createPrefab","target":{"path":"A"},"assetPath":"../x.prefab"}]}"#).isEmpty)
        #expect(!problems(#"{"actions":[{"op":"setSerializedProperty","target":{"path":"A"},"componentType":"C","propertyPath":"p"}]}"#).isEmpty)
        let nine = (0..<9).map { _ in #"{"op":"deleteGameObject","target":{"path":"A"}}"# }.joined(separator: ",")
        #expect(!problems("{\"actions\":[\(nine)]}").isEmpty)
    }

    // MARK: Plan validation

    private func check(_ plan: String, kind: TaskKind = .development, unity: Bool = true) -> (plan: TaskPlan?, issues: [PlanIssue]) {
        PlanValidator.check(plan, kind: kind, capabilities: .for(kind, unityProject: unity), allowDestructive: false)
    }

    @Test func aWellFormedUnityPlanValidates() {
        let r = check(UnityScripts.addCollider)
        #expect(r.plan != nil && r.issues.isEmpty, "\(r.issues)")
        #expect(r.plan?.steps.first { $0.id == "s2" }?.unity?.actionsJSON != nil)
    }

    @Test func unityStepsNeedUnityCapabilities() {
        #expect(check(UnityScripts.addCollider, unity: false).issues.contains { if case .capabilityNotGranted = $0 { true } else { false } })
        // A read-only analysis task may inspect/validate but not edit, compile, test or play.
        let edit = check(UnityScripts.addCollider, kind: .readOnlyAnalysis)
        #expect(edit.plan == nil && edit.issues.filter { if case .capabilityNotGranted = $0 { true } else { false } }.count >= 2)
        let inspectOnly = UnityScripts.plan([UnityScripts.step("s1", "Look", "unityInspect", validation: "unityInspected", unity: "{\"targets\":[\"A\"]}"),
                                             UnityScripts.step("s2", "Check", "unityValidate", deps: ["s1"], validation: "unityState", unity: "{\"expectations\":[{\"kind\":\"objectExists\",\"target\":{\"path\":\"A\"}}]}")])
        #expect(check(inspectOnly, kind: .readOnlyAnalysis).plan != nil)
    }

    @Test func unityStepParametersAreBounded() {
        func plan(_ unity: String, type: String = "unityTest", validation: String = "unityTestsPass") -> String { UnityScripts.plan([UnityScripts.step("s1", "T", type, validation: validation, unity: unity)]) }
        #expect(check(plan("{\"testMode\":\"editMode\"}")).plan != nil)
        #expect(check(plan("{}")).plan == nil)                                                                   // test mode required
        #expect(check(plan("{\"testMode\":\"editMode\",\"testNames\":[\"a;rm -rf\"]}")).plan == nil)
        #expect(check(plan("{\"observeSeconds\":600}", type: "unityPlayMode", validation: "unityPlayObserved")).plan == nil)
        #expect(check(plan("{\"scene\":\"../x.unity\"}", type: "unityInspect", validation: "unityInspected")).plan == nil)
        #expect(check(plan("{\"expectations\":[{\"kind\":\"componentPresent\",\"componentType\":\"X\"}]}", type: "unityValidate", validation: "unityState")).plan == nil)   // no target
    }

    @Test func unityPlansCannotSmuggleCodeMenusOrAcquisition() {
        func plan(_ title: String, actions: String? = nil) -> String {
            UnityScripts.plan([UnityScripts.step("s1", title, "unityEdit", validation: "unityState", unity: actions ?? "{}", risk: "medium")])
        }
        for t in ["Execute C# to rename everything", "Run the menu item Assets/Reimport All", "Install package com.example.x", "Buy it on the Asset Store", "Upgrade the project to 6000.6"] {
            #expect(check(plan(t)).plan == nil, "accepted: \(t)")
        }
        let bad = check(plan("Add a component", actions: #"{"actions":[{"op":"runCSharp","code":"x"}]}"#))
        #expect(bad.plan == nil)
    }

    @Test func playModeAndTestsMustFollowACompileAfterChanges() {
        let bad = UnityScripts.plan([UnityScripts.step("s1", "Change", "codeChange", validation: "changedFiles", risk: "medium"),
                                     UnityScripts.step("s2", "Play", "unityPlayMode", deps: ["s1"], validation: "unityPlayObserved")])
        #expect(check(bad).issues.contains { if case .unityOrderViolation = $0 { true } else { false } })
        let good = UnityScripts.plan([UnityScripts.step("s1", "Change", "codeChange", validation: "changedFiles", risk: "medium"),
                                      UnityScripts.step("s2", "Compile", "unityCompile", deps: ["s1"], validation: "unityCompiled"),
                                      UnityScripts.step("s3", "Play", "unityPlayMode", deps: ["s2"], validation: "unityPlayObserved")])
        #expect(check(good).plan != nil)
    }

    @Test func theUnitySectionOfThePlannerPromptIsFactual() {
        let ctx = UnityPlanContext(projectName: "Bath", unityVersion: "6000.5.1f1", scenes: ["Assets/Scenes/A.unity"], hasTestFramework: true, renderPipeline: "Universal (URP)")
        let dev = PlannerPrompt.build(goal: "fix", kind: .development, projectTree: "", buildCommand: nil, testCommand: nil, constraints: [], unity: ctx)
        #expect(dev.contains("unityEdit") && dev.contains("never write C#") && dev.contains("Universal (URP)"))
        let ro = PlannerPrompt.build(goal: "look", kind: .readOnlyAnalysis, projectTree: "", buildCommand: nil, testCommand: nil, constraints: [], unity: ctx)
        #expect(ro.contains("unityInspect") && !ro.contains("- unityEdit:"))
        #expect(!PlannerPrompt.build(goal: "x", kind: .development, projectTree: "", buildCommand: nil, testCommand: nil, constraints: []).contains("unityInspect"))
    }

    @Test func unityNameGuessesNeverDecideAnything() {
        let names = UnityNameGuess.names(from: ["Add a BoxCollider to TestCube and check \"Player One\" in CounterObject.cs"])
        #expect(names.contains("TestCube") && names.contains("Player One") && !names.contains("BoxCollider") && !names.contains("CounterObject.cs"))
    }
}
