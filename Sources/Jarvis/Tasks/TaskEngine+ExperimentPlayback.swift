import Foundation

/// V0.13.1 — the animation and audio experiments. They are experiment KINDS of the one V0.13 engine (same contract, isolation, cleanup, verdicts) — not separate engines.
/// With no asset named the fixture is generated deterministically inside the disposable project (a clip that moves one axis; a short tone). With an asset named it is used as it is, and a
/// missing one REFUTES the hypothesis. What is proved is technical: the clip's normalized time advances and the pose changes in Play Mode; the AudioSource has its clip and enters playback.
/// What is NOT proved is stated as INFERRED: that it would work on a different rig / character, or that it sounds right.
extension TaskEngine {
    static let fixtureControllerPath = "Assets/JarvisExperiment/Fixture.controller"
    static let fixtureClipPath = "Assets/JarvisExperiment/Slide.anim"
    static let fixtureTonePath = "Assets/JarvisExperiment/tone.wav"

    /// A harmless 0.5 s, 440 Hz, 16-bit mono tone (22.05 kHz) generated here — the audio experiment's deterministic fixture. Written into the DISPOSABLE project only.
    nonisolated static func fixtureToneData() -> Data {
        let rate = 22_050, samples = rate / 2
        var pcm = Data(capacity: samples * 2)
        for i in 0..<samples {
            let envelope = min(1, Double(min(i, samples - i)) / 400)                       // short fade in / out: no click
            let v = Int16(sin(2 * .pi * 440 * Double(i) / Double(rate)) * envelope * 12_000)
            pcm.append(UInt8(truncatingIfNeeded: v)); pcm.append(UInt8(truncatingIfNeeded: v >> 8))
        }
        func le32(_ x: Int) -> Data { Data([UInt8(x & 255), UInt8((x >> 8) & 255), UInt8((x >> 16) & 255), UInt8((x >> 24) & 255)]) }
        func le16(_ x: Int) -> Data { Data([UInt8(x & 255), UInt8((x >> 8) & 255)]) }
        var d = Data("RIFF".utf8); d.append(le32(36 + pcm.count)); d.append(Data("WAVEfmt ".utf8)); d.append(le32(16)); d.append(le16(1)); d.append(le16(1))
        d.append(le32(rate)); d.append(le32(rate * 2)); d.append(le16(2)); d.append(le16(16)); d.append(Data("data".utf8)); d.append(le32(pcm.count)); d.append(pcm)
        return d
    }

    nonisolated static func writeFixtureTone(into project: String) throws {
        let url = URL(fileURLWithPath: project + "/" + fixtureTonePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fixtureToneData().write(to: url, options: .atomic)          // the disposable fixture sound: only ever written into a disposable experiment project
    }

    private func experimentSession(_ ctx: TaskContext) -> UnityToolSession {
        var goal = UnityGoalIntent(); goal.sceneCreation = true
        let s = UnityToolSession(capabilities: CapabilitySet(granted: TaskCapability.unityDevelopment), taskID: ctx.record.id, runID: nil, hub: nil, destructiveRequested: false)
        s.goalIntent = goal
        return s
    }

    /// The fixed asset (named by the contract) or the generated one. A named asset that does not exist in the disposable project is a TESTED fact and the hypothesis fails.
    func experimentFixture(_ ctx: TaskContext, project: String, spec: ExperimentSpec, fact: (String, FactClass, String) -> Void) async throws -> Bool {
        guard let unity else { return false }
        let conn = unity.connection(for: project)
        let session = experimentSession(ctx)
        func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: project + "/" + rel) }
        func ok(_ d: UnityDevOp) async throws -> Bool {
            let r = try await conn.perform(.dev(d), session: session)
            return UnityDevVerifier.verify(d, r).0
        }
        switch spec.kind {
        case .animationPlayback:
            if let named = spec.assetPaths.first(where: { $0.hasSuffix(".controller") }) {
                if exists(named) { fact("The controller \(named) exists in the disposable project", .tested, "file listing"); ctx.results["fixture.controller"] = named; return true }
                fact("The controller \(named) does not exist in the disposable project: nothing can be played", .tested, "file listing of the disposable project")
                return false
            }
            guard try await ok(.createAnimationClip(assetPath: Self.fixtureClipPath, property: "position", axis: "x", from: 0, to: 2, duration: 1, loop: true)),
                  try await ok(.createAnimatorController(assetPath: Self.fixtureControllerPath)),
                  try await ok(.editAnimatorController(assetPath: Self.fixtureControllerPath, edit: .addState(layer: 0, name: "Slide", motion: Self.fixtureClipPath, speed: nil), layer: 0)),
                  try await ok(.editAnimatorController(assetPath: Self.fixtureControllerPath, edit: .setDefaultState(layer: 0, name: "Slide"), layer: 0)) else {
                fact("The deterministic animation fixture could not be built", .tested, "typed operations were not confirmed by the editor")
                return false
            }
            ctx.results["fixture.controller"] = Self.fixtureControllerPath
            fact("A deterministic fixture was generated: a looping clip moving position.x from 0 to 2 over 1 s, in a one-state controller whose default state plays it", .tested, "typed operations, each confirmed by the editor's read-back")
            return true
        case .audioPlayback:
            if let named = spec.assetPaths.first(where: { path in [".wav", ".ogg", ".mp3", ".aif", ".aiff"].contains { path.lowercased().hasSuffix($0) } }) {
                if exists(named) { ctx.results["fixture.clip"] = named; fact("The audio file \(named) exists in the disposable project", .tested, "file listing"); return true }
                fact("The audio file \(named) does not exist in the disposable project: no clip can be assigned", .tested, "file listing of the disposable project")
                return false
            }
            guard exists(Self.fixtureTonePath) else { fact("The generated tone is missing from the disposable project", .tested, "file listing"); return false }
            let r = try await conn.perform(.dev(.inspectAsset(path: Self.fixtureTonePath)), session: session).result
            let length = (r["length"] as? NSNumber)?.doubleValue ?? 0, channels = (r["channels"] as? NSNumber)?.intValue ?? 0
            guard length > 0.3, channels >= 1 else { fact("Unity imported the generated tone but it has no usable audio (\(length) s, \(channels) channel(s))", .tested, "inspectAsset"); return false }
            ctx.results["fixture.clip"] = Self.fixtureTonePath
            fact("A generated 440 Hz tone was imported as an AudioClip (\(String(format: "%.2f", length)) s, \(channels) channel)", .tested, "the editor's own AudioClip inspection")
            return true
        default: return true
        }
    }

    func experimentAnimation(_ ctx: TaskContext, project: String, spec: ExperimentSpec, fact: (String, FactClass, String) -> Void) async throws -> Bool {
        guard let unity else { return false }
        let conn = unity.connection(for: project)
        let session = experimentSession(ctx)
        guard let controller = ctx.results["fixture.controller"] else { fact("The animation did not run: no controller was available", .tested, "the fixture step could not provide one"); return false }
        let subject = UnityTarget(path: "ExperimentSubject")
        _ = try await conn.perform(.dev(.createScene(path: "Assets/ExperimentScene.unity", empty: false)), session: session)
        _ = try await conn.perform(.createGameObject(name: "ExperimentSubject", scene: nil, parent: nil, primitive: "Cube", position: [0, 0.5, 5], rotation: nil, scale: nil, ifAbsent: true), session: session)
        _ = try await conn.perform(.addComponent(subject, componentType: "Animator", ifAbsent: true), session: session)
        let assign = try UnityDevOp.configure(subject, kind: "animator", settings: ["controller": .string(controller), "applyRootMotion": .bool(false)])
        guard UnityDevVerifier.verify(assign, try await conn.perform(.dev(assign), session: session)).0 else { fact("The controller could not be assigned to an Animator", .tested, "typed configuration was not confirmed by the editor"); return false }
        _ = try await conn.perform(.enterPlayMode, session: session)
        defer { Task { @MainActor in _ = try? await conn.perform(.exitPlayMode, session: session); _ = await conn.transport.waitForStatus(timeout: 60, { !$0.isPlaying }) } }
        guard await conn.transport.waitForStatus(timeout: 120, { $0.isPlaying && $0.state == "playing" }) != nil else { fact("Play Mode could not be entered", .tested, "the editor did not report playing"); return false }
        func sample() async throws -> (t: Double?, x: Double?, hasController: Bool) {
            let r = try await conn.perform(.dev(.inspectRuntime(targets: [subject], animatorStates: [])), session: session).result
            let t = (r["targets"] as? [[String: Any]])?.first
            let o = t.map(UnityRuntimeObject.init(json:))
            let x = (((t?["pose"] as? [String: Any])?["localPosition"] as? [NSNumber])?.first)?.doubleValue
            return (o?.normalizedTime, x, o?.hasController == true)
        }
        let a = try await sample()
        _ = await conn.transport.waitForStatus(timeout: 0.7, { _ in false })
        let b = try await sample()
        let advanced = a.hasController && a.t != nil && b.t != nil && a.t != b.t
        let moved = a.x != nil && b.x != nil && abs((a.x ?? 0) - (b.x ?? 0)) > 0.01
        let generated = spec.assetPaths.isEmpty
        let fmt: (Double?) -> String = { $0.map { String(format: "%.3f", $0) } ?? "?" }
        if advanced && (moved || !generated) {
            fact("The animation is running in this fixture (normalized time \(fmt(a.t)) → \(fmt(b.t))\(moved ? "; the object's position.x moved \(fmt(a.x)) → \(fmt(b.x))" : ""))", .tested, "two runtime samples 0.7 s apart in Play Mode")
            fact("It would play the same way on a different rig or character", .inferred, "NOT tested: this fixture is a plain cube with a generated clip")
            return true
        }
        fact("The animation did not run" + (a.hasController ? " (normalized time \(fmt(a.t)) → \(fmt(b.t)); position.x \(fmt(a.x)) → \(fmt(b.x)))" : " (the Animator has no controller at runtime)"), .tested, "two runtime samples 0.7 s apart in Play Mode")
        return false
    }

    func experimentAudio(_ ctx: TaskContext, project: String, spec: ExperimentSpec, fact: (String, FactClass, String) -> Void) async throws -> Bool {
        guard let unity else { return false }
        let conn = unity.connection(for: project)
        let session = experimentSession(ctx)
        guard let clip = ctx.results["fixture.clip"] else { fact("The audio source did not enter playback: no clip was available", .tested, "the fixture step could not provide one"); return false }
        let subject = UnityTarget(path: "ExperimentSource")
        _ = try await conn.perform(.dev(.createScene(path: "Assets/ExperimentScene.unity", empty: false)), session: session)
        _ = try await conn.perform(.createGameObject(name: "ExperimentSource", scene: nil, parent: nil, primitive: "None", position: [0, 0, 0], rotation: nil, scale: nil, ifAbsent: true), session: session)
        _ = try await conn.perform(.addComponent(subject, componentType: "AudioSource", ifAbsent: true), session: session)
        let cfg = try UnityDevOp.configure(subject, kind: "audioSource", settings: ["clip": .string(clip), "volume": .number(0.2), "loop": .bool(true), "playOnAwake": .bool(true), "spatialBlend": .number(0)])
        guard UnityDevVerifier.verify(cfg, try await conn.perform(.dev(cfg), session: session)).0 else { fact("The clip could not be assigned to an AudioSource", .tested, "typed configuration was not confirmed by the editor"); return false }
        fact("An AudioSource was configured with the clip \(clip) (volume 0.2, loop, play on awake) and the editor confirmed it by reading it back", .tested, "typed configuration, verified")
        _ = try await conn.perform(.enterPlayMode, session: session)
        defer { Task { @MainActor in _ = try? await conn.perform(.exitPlayMode, session: session); _ = await conn.transport.waitForStatus(timeout: 60, { !$0.isPlaying }) } }
        guard await conn.transport.waitForStatus(timeout: 120, { $0.isPlaying && $0.state == "playing" }) != nil else { fact("Play Mode could not be entered", .tested, "the editor did not report playing"); return false }
        var playing: Bool?
        var runtimeClip: String?
        for _ in 0..<10 {                                                  // bounded wait (≤ 5 s) for the source to start; no unbounded loop
            let r = try await conn.perform(.dev(.inspectRuntime(targets: [subject], animatorStates: [])), session: session).result
            let o = (r["targets"] as? [[String: Any]])?.first.map(UnityRuntimeObject.init(json:))
            playing = o?.audioPlaying; runtimeClip = o?.audioClip
            if playing == true { break }
            if ctx.cancelRequested || Task.isCancelled { throw UnityToolError(category: .cancelled, message: "cancelled") }
            _ = await conn.transport.waitForStatus(timeout: 0.5, { _ in false })
        }
        if playing == true {
            fact("The audio source is playing in Play Mode (isPlaying = true, clip \(runtimeClip ?? clip))", .tested, "runtime read-back from the editor")
            fact("It sounds right (loudness, mix, spatial placement, output device)", .unknown, "NOT measured: JARVIS does not listen; only configuration and playback state are proved")
            return true
        }
        fact("The audio source did not enter playback in Play Mode (isPlaying = \(playing.map { $0 ? "true" : "false" } ?? "unknown"), clip \(runtimeClip ?? "none"))", .tested, "runtime read-back from the editor, sampled for 5 s")
        return false
    }
}
