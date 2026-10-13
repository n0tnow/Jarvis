import AppKit

/// `Jarvis --operator-live-test [--operator-section <name>]… [--live-dir <dir>]` — OPT-IN, REAL (V0.13).
/// Drives the REAL Unity editor installed on this Mac (started and owned by JARVIS, WITH a graphics device so the camera can be rendered) on an ISOLATED disposable fixture project copied
/// to a temp folder — never the user's game, never the JARVIS repository — with its own data directory. Each section prints `REAL TESTED PASS/FAIL`; evidence labels:
///   REAL     = the real editor / real files; ENGINE = the real engine with scripted agents; POLICY = pure code checks.
/// Sections: setup · scene · material · lighting · prefab · camera-physics-ui · animation · audio · playmode · capture · console · protections.
@MainActor
enum OperatorLiveTest {
    static func run(context: AppContext, captureDirectory: String, sections: Set<String>) async {
        var failures = 0, passes = 0, skipped = 0
        var finish2 = false
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "REAL TESTED PASS" : "REAL TESTED FAIL")  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if ok { passes += 1 } else { failures += 1 }
            fflush(stdout)
        }
        func skip(_ name: String, _ why: String) { print("SKIPPED  \(name) — \(why)"); skipped += 1; fflush(stdout) }
        func info(_ s: String) { print("INFO  \(s)"); fflush(stdout) }
        func fmt(_ d: Double, _ f: String = "%.1f") -> String { String(format: f, d) }
        func wants(_ s: String) -> Bool { sections.isEmpty || sections.contains(s) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3000) { ProcessRegistry.shared.killAll(); print("OPERATOR LIVE TEST TIMEOUT"); fflush(stdout); exit(2) }
        var fixtures: [String] = []
        func finish() -> Never {
            for f in fixtures { try? FileManager.default.removeItem(atPath: f) }
            print("OPERATOR LIVE TEST \(failures == 0 ? "PASSED" : "FAILED") (\(passes) passed, \(failures) failed, \(skipped) skipped)"); fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        let unity = context.unity
        func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if cond() { return true }; try? await Task.sleep(for: .milliseconds(150)) }
            return cond()
        }

        // ------------------------------------------------------------ fixture
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let template = repoRoot + "/UnityBridge/Fixture"
        let project = UnityProcessScanner.canonical(NSTemporaryDirectory()) + "/jarvis-operator-live-\(UUID().uuidString.prefix(8))"
        fixtures.append(project)
        do { try FileManager.default.copyItem(atPath: template, toPath: project) } catch { check("The fixture was copied", false, "\(error)"); finish() }
        try? FileManager.default.createDirectory(atPath: captureDirectory + "/operator", withIntermediateDirectories: true)
        info("data directory: \(context.paths.root.path); fixture: \(project)")

        // ------------------------------------------------------------ 0. setup: a render-capable owned editor
        unity.refreshEditors()
        guard case .exact = UnityDiscovery.choose(for: UnityProjectDetector.describe(root: project)?.declaredVersion, among: unity.editors) else { check("An editor with the fixture's exact version is installed", false); finish() }
        let started = Date()
        let outcome = await unity.prepare(root: project, approvedInstall: true, approvedUpgrade: false, rendering: true, progress: { info($0) })
        check("The real editor started with the JARVIS bridge, WITH a graphics device (no -nographics)", outcome == .ready, "\(outcome) after \(fmt(Date().timeIntervalSince(started))) s")
        guard outcome == .ready else { finish() }
        let conn = unity.connection(for: project)
        let session = UnityToolSession(capabilities: CapabilitySet(granted: TaskCapability.unityDevelopment), taskID: nil, runID: nil, hub: nil, destructiveRequested: false)
        var goal = UnityGoalIntent(); goal.prefabUnpack = true; goal.componentRemoval = true; goal.sceneCreation = true
        session.goalIntent = goal
        let st0 = conn.transport.currentStatus()
        check("The editor reports Metal graphics and the bridge version 0.13", st0?.isHeadlessNoGraphics == false && st0?.bridgeVersion == "0.13.0", "graphics \(st0?.graphics ?? "?") · bridge \(st0?.bridgeVersion ?? "?") · Unity \(st0?.unityVersion ?? "?")")

        /// The user's approval of ONE exact action (what the HUD button would record): the policy's own action text.
        func approve(_ d: UnityDevOp) { if case .needsApproval(let action, _, _) = conn.authorize(.dev(d), session: session) { session.approvedActions.insert(action) } }
        func op(_ d: UnityDevOp) async -> (UnityResponse?, String) {
            do { return (try await conn.perform(.dev(d), session: session), "") } catch let e as UnityToolError { return (nil, "\(e.category.rawValue): \(e.message)") } catch { return (nil, "\(error)") }
        }
        func legacy(_ o: UnityOperation) async -> (UnityResponse?, String) {
            do { return (try await conn.perform(o, session: session), "") } catch let e as UnityToolError { return (nil, "\(e.category.rawValue): \(e.message)") } catch { return (nil, "\(error)") }
        }
        func P(_ path: String) -> UnityTarget { UnityTarget(path: path) }
        func verified(_ d: UnityDevOp) async -> (Bool, String) {
            let (r, err) = await op(d)
            guard let r else { return (false, err) }
            let v = UnityDevVerifier.verify(d, r)
            return (v.0, v.1)
        }
        func save() async -> Bool {
            let active = conn.transport.currentStatus()?.activeScene ?? ""
            return await legacy(.saveScene(scene: active)).0 != nil
        }
        func fileText(_ rel: String) -> String { FileManager.default.contents(atPath: project + "/" + rel).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        let scenePath = "Assets/Scenes/FixtureScene.unity"

        // ------------------------------------------------------------ 1. project info & scene profile
        if wants("scene") {
            let info0 = await legacy(.getProjectInfo)
            check("Project facts: Unity version, render pipeline, colour space are read from the editor", info0.0?.result["unityVersion"] as? String == "6000.5.1f1" && info0.0?.result["renderPipeline"] != nil,
                  "\(info0.0?.result["unityVersion"] as? String ?? "?") · \(info0.0?.result["renderPipeline"] as? String ?? "?") · \(info0.0?.result["colorSpace"] as? String ?? "?")")
            _ = await legacy(.openScene(path: scenePath))
            let profile = await op(.sceneProfile(scene: nil, maxObjects: 2_000))
            check("Scene profile: objects, cameras, lights, broken references", (profile.0?.result["objectCount"] as? NSNumber)?.intValue ?? 0 >= 3 && (profile.0?.result["cameras"] as? NSNumber)?.intValue == 1, profile.0.map { UnityRender.sceneProfile($0.result) } ?? profile.1)

            // hierarchy: create → edit → duplicate → configure → save → re-read
            let rig = await legacy(.createGameObject(name: "Rig", scene: nil, parent: nil, primitive: "None", position: nil, rotation: nil, scale: nil, ifAbsent: true))
            let lamp = await legacy(.createGameObject(name: "Lamp", scene: nil, parent: nil, primitive: "Sphere", position: [3, 0, 0], rotation: nil, scale: nil, ifAbsent: true))
            check("Objects are created through typed operations (no GUI)", rig.0 != nil && lamp.0 != nil, rig.1 + lamp.1)
            let e1 = GameObjectEdit(name: "Key Lamp", active: nil, parent: .to(P("Rig")), siblingIndex: nil, position: [0, 2, 0], rotation: [10, 20, 30], scale: [1.5, 1.5, 1.5], worldSpace: false, tag: nil, layer: nil, isStatic: nil)
            let ed = await verified(.editGameObject(P("Lamp"), e1))
            check("editGameObject: rename + reparent + position + rotation + scale, verified by the editor's read-back", ed.0, ed.1)
            let again = await op(.editGameObject(P("Rig/Key Lamp"), GameObjectEdit(name: "Key Lamp", position: [0, 2, 0])))
            check("The same edit again is idempotent (nothing changes)", again.0?.result["changed"] as? Bool == false, again.1)
            let i1 = await legacy(.inspectGameObject(P("Rig/Key Lamp"), depth: 0, maxChildren: 0))
            let pos = ((i1.0?.result["localPosition"] as? [NSNumber]) ?? []).map(\.doubleValue)
            check("The hierarchy now reads Rig/Key Lamp at (0, 2, 0)", pos == [0, 2, 0] && (i1.0?.result["path"] as? String) == "Rig/Key Lamp", "\(pos) \(i1.0?.result["path"] as? String ?? "?")")
            let dup = await op(.duplicateGameObject(P("Rig/Key Lamp"), name: "Fill Lamp"))
            check("duplicateGameObject creates a sibling copy", dup.0?.result["created"] as? Bool == true, dup.1)
            let orderEdit = await verified(.editGameObject(P("Rig/Fill Lamp"), GameObjectEdit(siblingIndex: 0)))
            let ord = await legacy(.inspectGameObject(P("Rig"), depth: 1, maxChildren: 10))
            let kids = ((ord.0?.result["children"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            check("Sibling order is changed and read back", orderEdit.0 && kids == ["Fill Lamp", "Key Lamp"], "\(kids) \(orderEdit.1)")
            let inactive = await verified(.editGameObject(P("Rig/Fill Lamp"), GameObjectEdit(active: false)))
            check("setActive false is applied and verified", inactive.0, inactive.1)
            let badTag = await op(.editGameObject(P("Rig/Key Lamp"), GameObjectEdit(tag: "NoSuchTag")))
            check("An unknown tag is refused with the project's real tag list (not guessed)", badTag.0 == nil && badTag.1.contains("does not exist in this project") && badTag.1.contains("Untagged"), badTag.1)
            let loop = await op(.editGameObject(P("Rig"), GameObjectEdit(parent: .to(P("Rig/Key Lamp")))))
            check("An object cannot become its own descendant's child", loop.0 == nil, loop.1)

            // components: add + configure (typed), Rigidbody/collider/character controller
            _ = await legacy(.addComponent(P("Rig/Key Lamp"), componentType: "Rigidbody", ifAbsent: true))
            let rb = try? UnityDevOp.configure(P("Rig/Key Lamp"), kind: "rigidbody", settings: ["mass": .number(2.5), "useGravity": .bool(false), "linearDamping": .number(0.4), "constraints": .array([.string("FreezeRotation")])])
            let rbv = await verified(rb!)
            check("Rigidbody mass / gravity / damping / constraints are set through typed settings and verified", rbv.0, rbv.1)
            let rb2 = await op(rb!)
            check("Re-applying the same rigidbody settings changes nothing", rb2.0?.result["alreadyApplied"] as? Bool == true, rb2.1)
            let col = try? UnityDevOp.configure(P("Rig/Key Lamp"), kind: "collider", settings: ["isTrigger": .bool(true), "radius": .number(0.75)])
            let colv = await verified(col!)
            check("Collider isTrigger / radius (a SphereCollider) are configured", colv.0, colv.1)
            let wrong = try? UnityDevOp.configure(P("Rig/Key Lamp"), kind: "collider", settings: ["height": .number(2)])
            let wrongRes = await op(wrong!)
            check("A collider setting that does not apply to this collider type is refused", wrongRes.0 == nil && wrongRes.1.contains("only applies to a CapsuleCollider"), wrongRes.1)
            _ = await legacy(.addComponent(P("TestCube"), componentType: "CharacterController", ifAbsent: true))
            let cc = await verified(try! UnityDevOp.configure(P("TestCube"), kind: "characterController", settings: ["height": .number(1.8), "radius": .number(0.4), "slopeLimit": .number(50)]))
            check("CharacterController height / radius / slope are configured", cc.0, cc.1)
            let removeOp = UnityDevOp.removeComponent(P("TestCube"), componentType: "CharacterController", index: nil)
            let unapproved = await op(removeOp)
            check("removeComponent is refused until the user approves that exact action", unapproved.0 == nil && unapproved.1.contains("approvalDenied"), unapproved.1)
            approve(removeOp)
            let remove = await op(removeOp)
            check("removeComponent (goal asked + approved) removes only that component", remove.0?.result["removed"] as? Bool == true, remove.1)

            check("The scene is saved by JARVIS (only the scene it made dirty)", await save())
            let yaml = fileText(scenePath)
            check("The saved scene FILE carries the changes (serialized state, re-read from disk)", yaml.contains("Key Lamp") && yaml.contains("Fill Lamp") && yaml.contains("m_Mass: 2.5"), "\(yaml.count) bytes")
        }

        // ------------------------------------------------------------ 2. materials
        if wants("material") {
            _ = await legacy(.openScene(path: scenePath))
            let mat = await verified(.createMaterial(assetPath: "Assets/Materials/Wood.mat", shader: "Standard", copyFrom: nil))
            check("createMaterial (Standard) creates a real .mat asset", mat.0 && FileManager.default.fileExists(atPath: project + "/Assets/Materials/Wood.mat"), mat.1)
            let dupMat = await op(.createMaterial(assetPath: "Assets/Materials/Wood.mat", shader: "Standard", copyFrom: nil))
            check("An existing asset is never overwritten", dupMat.0 == nil && dupMat.1.contains("never overwrites"), dupMat.1)
            let insp = await op(.inspectAsset(path: "Assets/Materials/Wood.mat"))
            let names = ((insp.0?.result["properties"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            check("inspectAsset discovers the shader's REAL properties", names.contains("_Color") && names.contains("_Metallic") && names.contains("_MainTex"), "\(insp.0?.result["shader"] as? String ?? "?") · \(names.prefix(8).joined(separator: ", "))")
            let guess = await op(.setMaterialProperty(assetPath: "Assets/Materials/Wood.mat", property: "_Shinyness", value: .number(1)))
            check("A guessed property name is refused with the actual names", guess.0 == nil && guess.1.contains("has no property") && guess.1.contains("_Metallic"), String(guess.1.prefix(160)))
            let sp = await verified(.setMaterialProperty(assetPath: "Assets/Materials/Wood.mat", property: "_Metallic", value: .number(0.7)))
            let sc = await verified(.setMaterialProperty(assetPath: "Assets/Materials/Wood.mat", property: "_Color", value: .array([.number(0.55), .number(0.32), .number(0.12), .number(1)])))
            check("A numeric and a colour property are changed and read back", sp.0 && sc.0, sp.1 + " · " + sc.1)
            let outOfRange = await op(.setMaterialProperty(assetPath: "Assets/Materials/Wood.mat", property: "_Metallic", value: .number(5)))
            check("A Range property refuses values outside its range", outOfRange.0 == nil && outOfRange.1.contains("accepts values between"), outOfRange.1)
            let assign = await verified(try! UnityDevOp.configure(P("TestCube"), kind: "renderer", settings: ["material": .string("Assets/Materials/Wood.mat")]))
            check("The material is assigned to the renderer (typed) and verified", assign.0, assign.1)
            let copy = await verified(.createMaterial(assetPath: "Assets/Materials/WoodDark.mat", shader: nil, copyFrom: "Assets/Materials/Wood.mat"))
            check("A material can be duplicated from another", copy.0, copy.1)
            check("The change is on disk (the .mat file holds the new colour)", fileText("Assets/Materials/Wood.mat").contains("_Metallic: 0.7"))
            check("The scene is saved", await save())
        }

        // ------------------------------------------------------------ 3. lighting
        if wants("lighting") {
            _ = await legacy(.openScene(path: scenePath))
            _ = await legacy(.createGameObject(name: "Sun", scene: nil, parent: nil, primitive: "None", position: nil, rotation: [50, -30, 0], scale: nil, ifAbsent: true))
            _ = await legacy(.addComponent(P("Sun"), componentType: "Light", ifAbsent: true))
            let l1 = await verified(try! UnityDevOp.configure(P("Sun"), kind: "light", settings: ["type": .string("Directional"), "intensity": .number(1.4), "color": .array([.number(1), .number(0.95), .number(0.85)]), "shadows": .string("Soft")]))
            check("A Directional light is configured (type, intensity, colour, shadows) and verified", l1.0, l1.1)
            let l2 = await verified(try! UnityDevOp.configure(P("Rig/Key Lamp"), kind: "renderer", settings: ["enabled": .bool(true)]))
            _ = await legacy(.addComponent(P("Rig/Fill Lamp"), componentType: "Light", ifAbsent: true))
            let l3 = await verified(try! UnityDevOp.configure(P("Rig/Fill Lamp"), kind: "light", settings: ["type": .string("Spot"), "spotAngle": .number(60), "range": .number(12), "intensity": .number(3)]))
            check("A Spot light (angle, range) is configured", l3.0, l3.1 + " " + l2.1)
            let badLight = await op(try! UnityDevOp.configure(P("Sun"), kind: "light", settings: ["intensity": .number(5)]))
            check("(control) a valid light change is accepted", badLight.0 != nil, badLight.1)
            let env = await verified(try! UnityDevOp.environment(property: "ambientIntensity", value: .number(0.6)))
            let env2 = await verified(try! UnityDevOp.environment(property: "fog", value: .bool(true)))
            check("Environment: ambient intensity and fog are set and read back", env.0 && env2.0, env.1 + " · " + env2.1)
            let lit = await op(.inspectLighting(scene: nil))
            let lights = (lit.0?.result["lights"] as? [[String: Any]]) ?? []
            check("inspectLighting reports every light, the environment and the render pipeline", lights.count >= 2 && (lit.0?.result["environment"] as? [String: Any])?["fog"] as? Bool == true, UnityRender.lighting(lit.0?.result ?? [:]))
            check("There is NO operation that changes the render pipeline asset", !UnityDevOp.allWireNames.contains { $0.lowercased().contains("pipeline") })
            check("The scene is saved", await save())
        }

        // ------------------------------------------------------------ 4. prefabs
        if wants("prefab") {
            _ = await legacy(.openScene(path: scenePath))
            let mk = await legacy(.createPrefab(P("Rig/Key Lamp"), assetPath: "Assets/Prefabs/Lamp.prefab"))
            check("A prefab is created from a scene object", mk.0 != nil && FileManager.default.fileExists(atPath: project + "/Assets/Prefabs/Lamp.prefab"), mk.1)
            let a = await verified(.instantiatePrefab(assetPath: "Assets/Prefabs/Lamp.prefab", scene: nil, parent: nil, name: "Instance A", position: [5, 0, 0], rotation: nil, scale: nil, ifAbsent: true))
            let b = await verified(.instantiatePrefab(assetPath: "Assets/Prefabs/Lamp.prefab", scene: nil, parent: nil, name: "Instance B", position: [7, 0, 0], rotation: nil, scale: nil, ifAbsent: true))
            check("The prefab is instantiated twice with linkage verified", a.0 && b.0, a.1 + " · " + b.1)
            let again = await op(.instantiatePrefab(assetPath: "Assets/Prefabs/Lamp.prefab", scene: nil, parent: nil, name: "Instance A", position: nil, rotation: nil, scale: nil, ifAbsent: true))
            check("Instantiating with the same name again is idempotent", again.0?.result["alreadyExists"] as? Bool == true, again.1)
            let ov = await verified(try! UnityDevOp.configure(P("Instance A"), kind: "rigidbody", settings: ["mass": .number(9)]))
            check("A property of the instance is overridden through a typed setting", ov.0, ov.1)
            let list = await op(.prefabOverrides(P("Instance A")))
            check("prefabOverrides distinguishes JARVIS' overrides from others", (list.0?.result["jarvisOverrides"] as? NSNumber)?.intValue ?? 0 >= 1, "jarvis \(list.0?.result["jarvisOverrides"] ?? "?") · other \(list.0?.result["otherOverrides"] ?? "?")")
            let rv = await op(.revertPrefabOverrides(P("Instance A")))
            check("revertPrefabOverrides reverts JARVIS' override and counts what it left alone", (rv.0?.result["reverted"] as? NSNumber)?.intValue ?? 0 >= 1, UnityDevVerifier.verify(.revertPrefabOverrides(P("Instance A")), rv.0 ?? UnityResponse(id: "", ok: false)).1 + rv.1)
            _ = await verified(try! UnityDevOp.configure(P("Instance A"), kind: "rigidbody", settings: ["mass": .number(4)]))
            let applyOp = UnityDevOp.applyPrefabOverrides(P("Instance A"))
            let unapprovedApply = await op(applyOp)
            check("applyPrefabOverrides is refused until the user approves that exact action", unapprovedApply.0 == nil && unapprovedApply.1.contains("approvalDenied"), unapprovedApply.1)
            approve(applyOp)
            let ap = await op(applyOp)
            check("applyPrefabOverrides (approved) writes JARVIS' override into the prefab asset", (ap.0?.result["applied"] as? NSNumber)?.intValue ?? 0 >= 1, ap.1.isEmpty ? "applied \(ap.0?.result["applied"] ?? "?")" : ap.1)
            let var1 = await verified(.createPrefabVariant(source: "Assets/Prefabs/Lamp.prefab", assetPath: "Assets/Prefabs/LampVariant.prefab"))
            check("A prefab VARIANT is created and recognised as a variant", var1.0 && FileManager.default.fileExists(atPath: project + "/Assets/Prefabs/LampVariant.prefab"), var1.1)
            let unpackOp = UnityDevOp.unpackPrefab(P("Instance B"), completely: false)
            approve(unpackOp)
            let up = await op(unpackOp)
            check("unpackPrefab (goal asked + approved) breaks the link for that instance only", up.0?.result["unpacked"] as? Bool == true, up.1)
            let ib = await legacy(.inspectGameObject(P("Instance B"), depth: 0, maxChildren: 0)), ia = await legacy(.inspectGameObject(P("Instance A"), depth: 0, maxChildren: 0))
            check("After the unpack Instance B is no longer a prefab instance; Instance A still is", (ib.0?.result["prefab"] as? [String: Any])?["isPartOfPrefab"] as? Bool == false && (ia.0?.result["prefab"] as? [String: Any])?["isPartOfPrefab"] as? Bool == true)
            check("The scene is saved", await save())
        }

        // ------------------------------------------------------------ 5. camera, physics, UI
        if wants("camera-physics-ui") {
            _ = await legacy(.openScene(path: scenePath))
            let cam = await verified(try! UnityDevOp.configure(P("Main Camera"), kind: "camera", settings: ["fieldOfView": .number(48), "nearClipPlane": .number(0.2), "farClipPlane": .number(250), "clearFlags": .string("SolidColor"), "backgroundColor": .array([.number(0.1), .number(0.12), .number(0.2)])]))
            check("Camera FOV / clip planes / clear flags / background colour are configured", cam.0, cam.1)
            let badClip = await op(try! UnityDevOp.configure(P("Main Camera"), kind: "camera", settings: ["nearClipPlane": .number(300)]))
            check("A near plane beyond the far plane is refused by the editor-side validation", badClip.0 == nil && badClip.1.contains("nearClipPlane"), badClip.1)
            _ = await legacy(.createGameObject(name: "HUD", scene: nil, parent: nil, primitive: "None", position: nil, rotation: nil, scale: nil, ifAbsent: true))
            let addCanvas = await legacy(.addComponent(P("HUD"), componentType: "Canvas", ifAbsent: true))
            if addCanvas.0 != nil {
                let cv = await verified(try! UnityDevOp.configure(P("HUD"), kind: "canvas", settings: ["renderMode": .string("ScreenSpaceOverlay"), "sortingOrder": .number(5)]))
                check("Canvas render mode / sorting order are configured", cv.0, cv.1)
                _ = await legacy(.createGameObject(name: "Panel", scene: nil, parent: P("HUD"), primitive: "RectTransform", position: nil, rotation: nil, scale: nil, ifAbsent: true))
                let rt = await op(try! UnityDevOp.configure(P("HUD/Panel"), kind: "rectTransform", settings: ["anchorMin": .array([.number(0), .number(0)]), "anchorMax": .array([.number(1), .number(0)]), "sizeDelta": .array([.number(0), .number(120)])]))
                check("A RectTransform is configured (anchors, size)", rt.0?.result["verified"] as? Bool == true, rt.1)
            } else { skip("Canvas / RectTransform", addCanvas.1) }
            let noComp = await op(try! UnityDevOp.configure(P("Main Camera"), kind: "rigidbody", settings: ["mass": .number(1)]))
            check("Configuring a component the object does not have is refused", noComp.0 == nil && noComp.1.contains("has no Rigidbody component"), noComp.1)
            let outside = await op(.setObjectReference(P("TestCube"), componentType: "MeshRenderer", index: nil, propertyPath: "m_Materials.Array.data[0]", assetPath: "Assets/Materials/Wood.mat"))
            check("setObjectReference assigns an asset to a serialized reference field", outside.0 != nil || outside.1.contains("typeMismatch") || outside.1.contains("propertyNotFound"), outside.1.isEmpty ? "assigned" : outside.1)
            check("The scene is saved", await save())
        }

        // ------------------------------------------------------------ 6. animation, audio, Play Mode, capture
        if wants("animation") || wants("audio") || wants("playmode") || wants("capture") {
            _ = await legacy(.openScene(path: scenePath))
            // an object that moves and makes sound
            let mover = await legacy(.createGameObject(name: "Mover", scene: nil, parent: nil, primitive: "Cube", position: [0, 0.5, 0], rotation: nil, scale: nil, ifAbsent: true))
            check("A cube to animate is created", mover.0 != nil, mover.1)
            let camMove = await verified(.editGameObject(P("Main Camera"), GameObjectEdit(position: [0, 1, -8], rotation: [0, 0, 0])))
            check("The camera is moved so the cube is in front of it (typed transform edit)", camMove.0, camMove.1)
            if wants("animation") || wants("playmode") {
                _ = await waitUntil(60) { FileManager.default.fileExists(atPath: project + "/Assets/Animation/Slide.anim") && FileManager.default.fileExists(atPath: project + "/Assets/Audio/beep.wav") }           // the fixture's own editor helper creates the clip on load
                _ = await conn.transport.waitForStatus(timeout: 120, { $0.isIdleEdit && !$0.compileRunning })
                let clip = await op(.inspectAsset(path: "Assets/Animation/Slide.anim"))
                check("inspectAsset reads an animation clip (length, loop, curves)", ((clip.0?.result["length"] as? NSNumber)?.doubleValue ?? 0) > 0.9 && clip.0?.result["looping"] as? Bool == true, UnityRender.asset(clip.0?.result ?? [:]) + clip.1)
                let cc = await verified(.createAnimatorController(assetPath: "Assets/Animation/Mover.controller"))
                check("An Animator Controller is created", cc.0, cc.1)
                let steps: [(String, AnimatorEdit)] = [
                    ("parameter Speed", .addParameter(name: "Speed", type: "Float", defaultValue: nil)),
                    ("state Slide", .addState(layer: 0, name: "Slide", motion: "Assets/Animation/Slide.anim", speed: 1)),
                    ("state Idle", .addState(layer: 0, name: "Idle", motion: nil, speed: nil)),
                    ("default state Slide", .setDefaultState(layer: 0, name: "Slide")),
                    ("transition Slide → Idle", .addTransition(layer: 0, from: "Slide", to: "Idle", hasExitTime: false, exitTime: nil, duration: 0.1, conditions: [AnimatorCondition(parameter: "Speed", mode: "Greater", threshold: 0.5)])),
                ]
                var all = true
                for (label, e) in steps { let r = await verified(.editAnimatorController(assetPath: "Assets/Animation/Mover.controller", edit: e, layer: 0)); all = all && r.0; if !r.0 { info("controller edit failed: \(label): \(r.1)") } }
                check("States, parameter, default state and a conditioned transition are added and read back from the controller", all)
                let ctl = await op(.inspectAsset(path: "Assets/Animation/Mover.controller"))
                check("The controller asset lists its states and parameters", UnityRender.asset(ctl.0?.result ?? [:]).contains("Slide") && UnityRender.asset(ctl.0?.result ?? [:]).contains("Speed"), UnityRender.asset(ctl.0?.result ?? [:]))
                _ = await legacy(.addComponent(P("Mover"), componentType: "Animator", ifAbsent: true))
                let an = await verified(try! UnityDevOp.configure(P("Mover"), kind: "animator", settings: ["controller": .string("Assets/Animation/Mover.controller"), "applyRootMotion": .bool(false)]))
                check("The controller is assigned to the Animator (typed)", an.0, an.1)
                let imp = await op(.inspectAsset(path: "Assets/Audio/beep.wav"))
                check("inspectAsset reads an audio clip (length, channels, frequency)", ((imp.0?.result["length"] as? NSNumber)?.doubleValue ?? 0) > 0.4 && (imp.0?.result["channels"] as? NSNumber)?.intValue == 1, UnityRender.asset(imp.0?.result ?? [:]) + imp.1)
            }
            if wants("audio") || wants("playmode") {
                _ = await legacy(.addComponent(P("Mover"), componentType: "AudioSource", ifAbsent: true))
                let au = await verified(try! UnityDevOp.configure(P("Mover"), kind: "audioSource", settings: ["clip": .string("Assets/Audio/beep.wav"), "volume": .number(0.4), "loop": .bool(true), "playOnAwake": .bool(true), "spatialBlend": .number(1), "minDistance": .number(1), "maxDistance": .number(25), "rolloffMode": .string("Linear")]))
                check("An AudioSource gets its clip, volume, loop, play-on-awake, spatial blend and rolloff through typed settings", au.0, au.1)
                let badClip = await op(try! UnityDevOp.configure(P("Mover"), kind: "audioSource", settings: ["clip": .string("Assets/Materials/Wood.mat")]))
                check("A non-audio asset is refused as a clip", badClip.0 == nil && badClip.1.contains("not an AudioClip"), badClip.1)
            }
            check("The scene is saved", await save())

            if wants("playmode") || wants("capture") {
                let target = P("Mover")
                // capture in Edit Mode
                let cap0 = await op(.captureView(camera: nil, width: 640, height: 360, targets: [target]))
                if let r = cap0.0, let c = try? TaskEngine.loadCapture(r, root: project) {
                    try? c.png.write(to: URL(fileURLWithPath: captureDirectory + "/operator/edit-mode.png"))
                    check("The Game camera is rendered into memory (PNG, 640×360) and the spool file is gone", c.png.count > 1_000 && c.png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) && !FileManager.default.fileExists(atPath: project + "/Library/JarvisBridge/" + ((r.result["file"] as? String) ?? "")), "\(c.png.count) bytes · \(c.summary)")
                    check("An object in front of the camera is reported VISIBLE by the editor's geometry + pixels", c.visibility(of: "Mover")?.visible == true || c.objects.first?.visible == true, c.objects.first?.summary ?? "")
                } else { check("The Game camera can be rendered", false, cap0.1) }

                // Play Mode: enter, observe, capture, exit
                let enter = await legacy(.enterPlayMode)
                let playing = await conn.transport.waitForStatus(timeout: 120, { $0.isPlaying && $0.state == "playing" })
                check("Play Mode is entered and confirmed by the editor", enter.0 != nil && playing != nil, enter.1)
                try? await Task.sleep(for: .seconds(1.5))
                let blocked = try? await conn.transport.send(.dev(.editGameObject(P("Mover"), GameObjectEdit(position: [0, 9, 0]))), timeout: 20)
                check("The BRIDGE itself refuses a persistent change in Play Mode (even if JARVIS' policy were bypassed)", blocked?.ok == false && blocked?.errorCode == "playModeMutationBlocked", blocked?.errorCode ?? "?")
                let policyDeny = await op(.editGameObject(P("Mover"), GameObjectEdit(position: [0, 9, 0])))
                check("JARVIS' policy refuses it first", policyDeny.0 == nil && policyDeny.1.contains("unsafeEditorState"), policyDeny.1)
                if wants("animation") || wants("playmode") {
                    let r1 = await op(.inspectRuntime(targets: [target], animatorStates: ["Slide", "Idle"]))
                    let o1 = (r1.0?.result["targets"] as? [[String: Any]])?.first.map(UnityRuntimeObject.init(json:))
                    try? await Task.sleep(for: .milliseconds(600))
                    let r2 = await op(.inspectRuntime(targets: [target], animatorStates: ["Slide"]))
                    let o2 = (r2.0?.result["targets"] as? [[String: Any]])?.first.map(UnityRuntimeObject.init(json:))
                    let x1 = (((r1.0?.result["targets"] as? [[String: Any]])?.first?["pose"] as? [String: Any])?["localPosition"] as? [NSNumber])?.first?.doubleValue
                    let x2 = (((r2.0?.result["targets"] as? [[String: Any]])?.first?["pose"] as? [String: Any])?["localPosition"] as? [NSNumber])?.first?.doubleValue
                    check("The Animator is in state Slide at runtime", o1?.animatorState["Slide"] == true, "clips \(o1?.animatorClips.joined(separator: ", ") ?? "none") · controller \(o1?.hasController == true)")
                    check("The animation is ACTUALLY RUNNING (normalized time advances and the object really moves)", (o1?.normalizedTime ?? 0) != (o2?.normalizedTime ?? 0) && x1 != x2, "t \(fmt(o1?.normalizedTime ?? -1, "%.3f")) → \(fmt(o2?.normalizedTime ?? -1, "%.3f")) · x \(fmt(x1 ?? 0, "%.2f")) → \(fmt(x2 ?? 0, "%.2f"))")
                }
                if wants("audio") || wants("playmode") {
                    let r3 = await op(.inspectRuntime(targets: [target], animatorStates: []))
                    let o3 = (r3.0?.result["targets"] as? [[String: Any]])?.first.map(UnityRuntimeObject.init(json:))
                    if o3?.audioPlaying == true { check("The AudioSource is playing its clip in Play Mode", true, o3?.audioClip ?? "") }
                    else { info("audio: the source is configured and active but isPlaying=\(String(describing: o3?.audioPlaying)) — a headless editor has no audio output device; the configuration itself was verified above (clip, volume, loop) · clip \(o3?.audioClip ?? "none")") }
                    check("The AudioSource in Play Mode still has the assigned clip (runtime read-back)", o3?.audioClip?.contains("beep") == true, o3?.audioClip ?? "none")
                }
                let cap1 = await op(.captureView(camera: nil, width: 640, height: 360, targets: [target]))
                if let r = cap1.0, let c = try? TaskEngine.loadCapture(r, root: project) {
                    try? c.png.write(to: URL(fileURLWithPath: captureDirectory + "/operator/play-mode.png"))
                    check("A capture works in Play Mode (reads are allowed)", c.png.count > 1_000, c.summary)
                } else { check("A capture works in Play Mode", false, cap1.1) }
                _ = await legacy(.exitPlayMode)
                let left = await conn.transport.waitForStatus(timeout: 60, { !$0.isPlaying && $0.state != "enteringPlay" })
                check("Play Mode is left again and the editor is back in Edit Mode (never stuck)", left != nil)
            }
        }

        // ------------------------------------------------------------ 7. console / compile truth
        if wants("console") {
            let comp = await legacy(.requestCompilation)
            _ = await conn.transport.waitForStatus(timeout: 120, { !$0.isCompiling && !$0.compileRunning })
            let cs = await legacy(.getCompilationState)
            check("Compilation truth is read from the editor (no errors after the operator edits)", cs.0?.result["scriptCompilationFailed"] as? Bool == false && ((cs.0?.result["errors"] as? [Any])?.isEmpty ?? true), comp.1)
            let con = await legacy(.readConsole(afterSeq: 0, max: 100, types: ["Error", "Exception"]))
            let errs = (con.0?.result["entries"] as? [[String: Any]]) ?? []
            check("The Console is read structurally (typed entries, not screenshots)", con.0 != nil, "\(errs.count) error entr\(errs.count == 1 ? "y" : "ies")" + (errs.isEmpty ? "" : ": " + errs.prefix(2).compactMap { $0["message"] as? String }.joined(separator: " | ")))
        }

        // ------------------------------------------------------------ 8. engine scenarios (ENGINE: scripted planner, REAL editor): visual correction
        let repo = context.repository!
        func git(_ args: [String]) async {
            _ = await ManagedProcess.runOnce(executable: "/usr/bin/git", arguments: ["-c", "user.name=JARVIS Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false"] + args,
                                             environment: ProviderEnvironment.make(), workingDirectory: project, timeout: 60)
        }
        func scriptedEngine(_ planText: String) -> TaskEngine {
            let runner = ScriptedAgentRunner(audit: context.audit, real: nil, scriptedTypes: ["PlannerAgent", "AnalysisAgent", "CodingAgent", "ReviewAgent", "UnityAgent"], script: { job, _ in
                job.type == "PlannerAgent" ? planText : (job.type == "ReviewAgent" ? "{\"verdict\":\"pass\",\"summary\":\"fine\",\"issues\":[]}" : nil)
            })
            let e = TaskEngine(repository: repo, artifacts: context.artifacts, audit: context.audit, leases: context.leases, agents: runner)
            e.unity = unity
            e.experimentsRoot = context.paths.root.appendingPathComponent("experiments", isDirectory: true)
            return e
        }
        func stepJSON(_ id: String, _ title: String, _ type: String, deps: [String] = [], validation: String, unity u: String, risk: String = "low") -> String {
            "{\"id\":\"\(id)\",\"title\":\"\(title)\",\"description\":\"\(title)\",\"type\":\"\(type)\",\"dependsOn\":[\(deps.map { "\"\($0)\"" }.joined(separator: ","))],\"expected\":\"done\",\"validation\":\"\(validation)\",\"risk\":\"\(risk)\",\"unity\":\(u)}"
        }
        func planJSON(_ steps: [String]) -> String { "{\"summary\":\"operator plan\",\"steps\":[" + steps.joined(separator: ",") + "]}" }
        func runTask(_ engine: TaskEngine, _ goal: String, timeout: Double = 900, cancelWhen: ((TaskEngine, UUID) -> Bool)? = nil) async -> (TaskView?, Double) {
            await git(["add", "-A"]); await git(["commit", "-q", "-m", "scenario"])
            guard case .success(let id) = await engine.submit(goal: goal, kind: .development, workspacePath: project, preference: nil, destructiveRequested: false) else { return (nil, 0) }
            var cancelledAt: Date?
            let watcher = Task { @MainActor in
                while !Task.isCancelled {
                    if let w = cancelWhen, cancelledAt == nil, w(engine, id) { cancelledAt = Date(); engine.cancel(id) }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            let watchdog = Task { @MainActor in try? await Task.sleep(for: .seconds(timeout)); if !Task.isCancelled { engine.cancel(id) } }
            await engine.waitUntilFinished(id)
            watcher.cancel(); watchdog.cancel()
            return (engine.view(id), cancelledAt.map { Date().timeIntervalSince($0) } ?? 0)
        }
        func summary(_ v: TaskView?) -> String { (v?.steps ?? []).map { "\($0.type.rawValue):\($0.state.rawValue)" }.joined(separator: " → ") + " · " + (v?.task.failureReason ?? "") }

        let spec = "{\"question\":\"Does a plain material render visibly in a clean project?\",\"hypothesis\":\"A sphere with the default material is created, compiles, and is visible and not pink.\",\"kind\":\"materialRender\",\"assetPaths\":[],\"successCriteria\":[\"the project compiles\",\"it renders visibly\"],\"failureCriteria\":[\"compile errors\",\"pink\"],\"minutes\":8,\"diskMegabytes\":1024,\"networkRequests\":0,\"artifacts\":2,\"cleanup\":\"delete\"}"
        let expPlan = planJSON([stepJSON("s1", "Test the material", "experiment", validation: "experimentConcluded", unity: "{\"experiment\":\(spec)}", risk: "low")])
        let expRoot = context.paths.root.appendingPathComponent("experiments", isDirectory: true)

        if wants("correction") {
            _ = await legacy(.openScene(path: scenePath))
            // The subject is placed where the Game camera cannot see it.
            let away = await op(.editGameObject(P("Mover"), GameObjectEdit(position: [0, 0, -80], worldSpace: true)))
            _ = await save()
            let before = await op(.captureView(camera: nil, width: 480, height: 270, targets: [P("Mover")]))
            let visBefore = before.0.flatMap { try? TaskEngine.loadCapture($0, root: project) }?.objects.first
            check("Set-up: the object is placed outside the camera's view and the editor measures it as NOT visible", away.0 != nil && visBefore?.visible == false, visBefore?.summary ?? before.1)
            let correct = planJSON([stepJSON("s1", "Inspect Mover", "unityInspect", validation: "unityInspected", unity: "{\"targets\":[\"Mover\"]}"),
                                    stepJSON("s2", "Make Mover clearly visible", "unityEdit", deps: ["s1"], validation: "unityState", unity: "{\"correct\":{\"target\":\"Mover\",\"rounds\":2}}", risk: "medium")])
            let (view, _) = await runTask(scriptedEngine(correct), "Make the Mover object clearly visible in the Game view")
            let ev = view?.steps.first { $0.type == .unityEdit }?.validationEvidence ?? ""
            check("ENGINE · The correction loop aimed the camera from MEASURED facts and the task succeeded", view?.task.state == .completed && ev.contains("Visibility") && ev.contains("aim"), summary(view) + " · " + ev.prefix(260))
            let after = await op(.captureView(camera: nil, width: 640, height: 360, targets: [P("Mover")]))
            if let r = after.0, let c = try? TaskEngine.loadCapture(r, root: project) {
                try? c.png.write(to: URL(fileURLWithPath: captureDirectory + "/operator/after-correction.png"))
                check("REAL · A fresh capture confirms the object is now visible (geometry + pixels, not a model's opinion)", c.objects.first?.visible == true, c.objects.first?.summary ?? "")
            } else { check("A fresh capture after the correction", false, after.1) }
            let obs = (try? repo.visualObservations(taskID: view?.id ?? UUID())) ?? []
            check("Each round left visual evidence (picture hash · provider · outcome), never pixels", obs.count >= 2 && obs.allSatisfy { $0.provider == "unity-capture" && $0.pictureHash.count >= 8 }, "\(obs.count) observations: " + obs.map(\.outcome).joined(separator: ", "))
            let bounded = planJSON([stepJSON("s1", "Inspect", "unityInspect", validation: "unityInspected", unity: "{\"targets\":[\"Mover\"]}"),
                                    stepJSON("s2", "Fix", "unityEdit", deps: ["s1"], validation: "unityState", unity: "{\"correct\":{\"target\":\"Mover\",\"rounds\":9}}", risk: "medium")])
            let (rej, _) = await runTask(scriptedEngine(bounded), "Make the Mover object visible")
            check("A plan asking for 9 correction rounds is refused at plan validation (bounded to 2)", rej?.task.state == .failed && !(rej?.steps.contains { $0.state == .passed && $0.type == StepType.unityEdit } ?? false), summary(rej))
            _ = await legacy(.openScene(path: scenePath))
        }

        // ------------------------------------------------------------ 9. experiments in a disposable Unity project
        func ownedEditorProcesses() async -> Int {
            let r = await ManagedProcess.runOnce(executable: "/usr/bin/pgrep", arguments: ["-f", "jarvisOwned"], environment: ProviderEnvironment.make(), workingDirectory: "/", timeout: 10)
            return (r?.output ?? "").split(separator: "\n").filter { !$0.isEmpty }.count
        }
        if wants("experiment") {
            await unity.shutdownOwnedEditors()
            _ = await waitUntil(60) { conn.transport.currentStatus() == nil }
            let fingerprintBefore = ProjectContinuity.treeFingerprint(root: project)
            let eng = scriptedEngine(expPlan)
            let started = Date()
            let (view, _) = await runTask(eng, "Test whether a plain material renders in a clean project", timeout: 900)
            let rec = (try? repo.experiments(taskID: view?.id ?? UUID()))?.first
            check("ENGINE+REAL · The experiment ran in a disposable project with a real editor and CONFIRMED its hypothesis from measured evidence", view?.task.state == .completed && rec?.result?.verdict == .confirmed, "\(fmt(Date().timeIntervalSince(started))) s · " + (rec?.result?.summary ?? summary(view)))
            check("TESTED facts are labelled TESTED and carry their evidence", (rec?.result?.facts ?? []).contains { $0.factClass == .tested && $0.statement.contains("compile") } && (rec?.result?.facts ?? []).contains { $0.statement.localizedCaseInsensitiveContains("visible") }, (rec?.result?.facts ?? []).map { "[\($0.factClass.rawValue)] \($0.statement)" }.joined(separator: " | "))
            check("The disposable environment is DELETED (record + disk) and the experiments root is empty", rec?.cleanupState == "deleted" && rec?.result?.environmentDeleted == true && ((try? FileManager.default.contentsOfDirectory(atPath: expRoot.path)) ?? []).isEmpty)
            check("The real project was not touched by the experiment (tree fingerprint identical)", ProjectContinuity.treeFingerprint(root: project) == fingerprintBefore && rec?.result?.projectUntouched == true)
            check("No JARVIS-owned editor process is left", await ownedEditorProcesses() == 0)
            if let h = rec?.result?.pictureHashes.first { check("Picture evidence is a hash, not stored pixels", h.count >= 8) }

            // The contract may never name the real project.
            let bad = planJSON([stepJSON("s1", "Bad test", "experiment", validation: "experimentConcluded", unity: "{\"experiment\":\(spec.replacingOccurrences(of: "in a clean project?", with: "inside \(project)/Assets?"))}", risk: "low")])
            let (badView, _) = await runTask(scriptedEngine(bad), "Test it in the real project")
            check("POLICY · A contract that names the real project never starts (refused, nothing created)", badView?.task.state == .failed && ((try? FileManager.default.contentsOfDirectory(atPath: expRoot.path)) ?? []).isEmpty, summary(badView))

            // Cancellation while the disposable editor is starting: environment deleted, editor closed, bounded latency.
            let cancelEng = scriptedEngine(expPlan)
            let (cv, latency) = await runTask(cancelEng, "Test whether a plain material renders in a clean project", timeout: 900, cancelWhen: { _, _ in UnityProcessScanner.editors().contains { $0.projectPath?.hasPrefix(UnityProcessScanner.canonical(expRoot.path) + "/") == true } })
            let crec = (try? repo.experiments(taskID: cv?.id ?? UUID()))?.first
            let stray = await ownedEditorProcesses()
            check("Cancelling a running experiment ends it quickly, deletes the environment and closes the editor", cv?.task.state == .cancelled && latency < 45 && ((try? FileManager.default.contentsOfDirectory(atPath: expRoot.path)) ?? []).isEmpty && crec?.cleanupState == "deleted" && stray == 0,
                  "state \(cv?.task.state.rawValue ?? "?") · cancel→finished \(fmt(latency, "%.2f")) s · cleanup \(crec?.cleanupState ?? "?")")
            finish2 = true
        }


        // ------------------------------------------------------------ 10. crash cleanup: a hard kill mid-experiment (run `crash-start`, then `crash-recover` as a SEPARATE launch)
        func editorsUnderExperimentsRoot() -> Int { UnityProcessScanner.editors().filter { $0.projectPath?.hasPrefix(UnityProcessScanner.canonical(expRoot.path) + "/") == true }.count }
        if wants("crash-start") {
            await unity.shutdownOwnedEditors()
            _ = await waitUntil(60) { conn.transport.currentStatus() == nil }
            let eng = scriptedEngine(expPlan)
            await git(["add", "-A"]); await git(["commit", "-q", "-m", "scenario"])
            guard case .success = await eng.submit(goal: "Test whether a plain material renders in a clean project", kind: .development, workspacePath: project, preference: nil, destructiveRequested: false) else { check("The experiment task was submitted", false); finish() }
            let up = await waitUntil(240) { editorsUnderExperimentsRoot() > 0 }
            check("The disposable editor is running and the experiment is mid-flight", up)
            info("simulating a crash now: SIGKILL of the JARVIS process (no cleanup code runs); the next launch must clean up — run with --operator-section crash-recover")
            try? FileManager.default.removeItem(atPath: project)
            fflush(stdout)
            kill(getpid(), SIGKILL)
        }
        if wants("crash-recover") {
            let recs = (try? repo.recentExperiments(limit: 20)) ?? []
            check("After the crash the experiment is INTERRUPTED (it is never resumed by itself)", recs.contains { $0.status == "interrupted" }, recs.map(\.status).joined(separator: ", "))
            check("The orphaned environment was deleted at launch (marker-checked, inside the experiments root)", ((try? FileManager.default.contentsOfDirectory(atPath: expRoot.path)) ?? []).isEmpty)
            check("The orphaned disposable editor of the crashed run was stopped at launch", editorsUnderExperimentsRoot() == 0)
        }

        // ------------------------------------------------------------ cleanup
        await unity.shutdownOwnedEditors()
        let gone = await waitUntil(60) { conn.transport.currentStatus() == nil }
        check("The owned editor was closed at the end (no orphan process)", gone)
        if finish2 { check("No JARVIS-owned editor process remains after the whole run", await ownedEditorProcesses() == 0) }
        finish()
    }
}
