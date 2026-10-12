import Testing
import Foundation
@testable import Jarvis

struct ContextRig {
    let r: RetrievalRig
    let builder: ProjectContextBuilder
    var project: String { r.project }
    init() async throws {
        r = try await RetrievalRig(loadCorpus: false)
        builder = ProjectContextBuilder(service: r.rig.service, retriever: r.retriever)
    }
    @discardableResult
    func add(_ type: MemoryType, _ text: String, strength: MemoryStrength = .strong, importance: MemoryImportance = .normal, area: String? = nil, pinned: Bool = false, details: String? = nil, key: String? = nil, value: String? = nil, ref: String = UUID().uuidString) -> UUID? {
        var c = MemoryCandidate(type: type, subject: area ?? String(text.prefix(20)), key: key, value: value, summary: text, details: details, strength: strength, importance: importance, area: area, origin: .document,
                                sources: [MemorySource(kind: .document, ref: ref, label: ref.count > 12 ? "docs/X.md" : ref)])
        c.pinned = pinned
        if case .created(let id) = r.rig.service.admit(c, projectKey: project) { return id }
        return nil
    }
    func build(_ goal: String, _ agent: ContextAgentKind, files: [String] = []) async -> ContextPacket {
        _ = await r.index.sync(projectKey: project)
        return await builder.build(ContextRequest(goal: goal, agent: agent, projectKey: project, projectRoot: "/x", files: files))
    }
}

@Suite("Memory · context builder")
struct MemoryContextTests {
    @Test func aCameraTaskSurfacesTheCameraConstraintAndNotUnrelatedHistory() async throws {
        let c = try await ContextRig()
        c.add(.decision, "Camera micro-stutter was previously fixed. Avoid modifying the camera architecture without new evidence.", strength: .authoritative, importance: .high, area: "camera", details: "A fix for micro-stutter took two sessions; unrelated edits could regress it.")
        c.add(.failure, "Changing camera update order to LateUpdate reintroduced micro-stutter in the host build.", area: "camera")
        c.add(.researchFinding, "Wooden Bucket 02 from Poly Haven was researched as a CC0 candidate.")
        c.add(.failure, "Voice Processing I/O echo cancellation was rejected because it used 15 percent of a core.", area: "voice")
        c.add(.decision, "Neural voice unloads after 180 seconds idle to save memory.", area: "voice")
        let p = await c.build("Modify PlayerCameraModeController to add a new camera mode", .coding, files: ["Assets/Scripts/PlayerCameraModeController.cs"])
        let text = ProjectContextBuilder.render(p)
        #expect(text.contains("micro-stutter") && text.contains("MEMORY — decisions that apply") && text.contains("why:"))
        #expect(text.contains("LateUpdate"))
        #expect(!text.contains("Wooden Bucket") && !text.contains("Voice Processing") && !text.contains("Neural voice"))
        #expect(p.usedIDs.count == 2 && p.stats.selected == 2)
    }

    @Test func differentAgentsGetDifferentMemory() async throws {
        let c = try await ContextRig()
        c.add(.researchFinding, "Wooden Bucket 02 from Poly Haven was researched as a CC0 candidate for the bath scene.")
        c.add(.assetDecision, "Rubber Duck Toy was rejected for the bath scene because it does not match the requested bucket props.")
        c.add(.constraint, "Bath scene assets must stay low poly and stylized cartoon.", area: "assets")
        c.add(.decision, "The bath scene lighting uses baked lightmaps instead of realtime lights.", area: "unity")
        let research = await c.build("Find a free bucket asset for the bath scene", .research)
        let coding = await c.build("Change the bath scene lighting script", .coding)
        let rt = ProjectContextBuilder.render(research), ct = ProjectContextBuilder.render(coding)
        #expect(rt.contains("Wooden Bucket") && rt.contains("Rubber Duck") && rt.contains("revalidate before use"))
        #expect(ct.contains("baked lightmaps") && !ct.contains("Wooden Bucket") && !ct.contains("Rubber Duck"))
    }

    @Test func currentTruthIsSeparateAndBeatsMemory() async throws {
        let c = try await ContextRig()
        c.r.rig.truth.set("unity.version", "6000.5.1f1")
        c.add(.projectFact, "The project uses Unity 6000.5.1f1 for the camera and scene work.", key: "unity.version", value: "6000.5.1f1")
        c.r.rig.truth.set("unity.version", "6000.6.0f1")        // upgraded since
        let p = await c.build("Work on the Unity camera scene", .unity)
        let text = ProjectContextBuilder.render(p)
        #expect(p.truth.first?.value == "6000.6.0f1" && text.contains("CURRENT TRUTH:") && text.contains("6000.6.0f1"))
        #expect(!text.contains("The project uses Unity 6000.5.1f1"))                  // the stale statement is NOT presented as a fact
        #expect(p.uncertainties.contains { $0.contains("unity.version") } && p.stats.contradictions == 1)
    }

    @Test func staleSensitiveAndDisputedItemsGoToUncertaintyNotToFacts() async throws {
        let c = try await ContextRig()
        c.add(.constraint, "Throw uses the left mouse button in the camera scene.", area: "camera")
        let b = MemoryCandidate(type: .constraint, subject: "camera", summary: "Throw does not use the left mouse button in the camera scene; it uses the right.", strength: .strong, area: "camera", origin: .document, sources: [MemorySource(kind: .document, ref: "o", label: "o")])
        _ = c.r.rig.service.admit(b, projectKey: c.project)
        let p = await c.build("Change the throw input in the camera scene", .coding)
        #expect(p.stats.contradictions >= 1 && p.uncertainties.contains { $0.contains("Conflicting records") })
        #expect(p.sections.flatMap(\.items).allSatisfy { $0.status == .current })
    }

    @Test func theBudgetIsEnforcedWhateverIsRelevant() async throws {
        let c = try await ContextRig()
        for i in 0..<40 { c.add(.constraint, "Camera rule number \(i): keep the camera pipeline stage \(i) unchanged during refactors of camera movement code.", area: "camera", details: String(repeating: "Because of reasons about camera behaviour. ", count: 12), ref: "r\(i)") }
        let p = await c.build("Refactor camera movement code", .coding)
        let prof = ProjectContextBuilder.profile(for: .coding)
        #expect(p.stats.selected <= prof.maxItems && p.stats.chars <= prof.maxChars, "selected \(p.stats.selected), chars \(p.stats.chars)")
        #expect(p.stats.candidates >= 40)
    }

    @Test func unverifiedInferencesAreOnlyShownToConversationAndLabelledAsInference() async throws {
        let c = try await ContextRig()
        var inf = MemoryCandidate(type: .projectFact, subject: "render", summary: "I think the camera scene might use HDRP rendering for the game.", strength: .strong, area: "camera", origin: .model,
                                  sources: [MemorySource(kind: .agentRun, ref: "run1", label: "agent run")])
        inf.proposedBy = "model"
        _ = c.r.rig.service.admit(inf, projectKey: c.project)
        let coding = await c.build("Change the camera scene rendering", .coding)
        #expect(!ProjectContextBuilder.render(coding).contains("HDRP"))
        let chat = await c.build("What do you know about the camera scene rendering?", .conversation)
        let t = ProjectContextBuilder.render(chat)
        #expect(t.contains("INFERENCE (unconfirmed") && t.contains("HDRP"))
    }

    @Test func pinnedCriticalConstraintsAreAlwaysIncludedAndCapped() async throws {
        let c = try await ContextRig()
        let rules = ["Never touch the savegame format directly from gameplay code.", "The Compact HUD must always remain 392 by 448 points.", "Downloads are never copied into the project without approval.", "Spoken approval is never accepted for critical actions."]
        for (i, t) in rules.enumerated() { c.add(.constraint, t, importance: .critical, pinned: true, ref: "p\(i)") }
        let p = await c.build("Tune the fog density of the sunset scene", .coding)
        let n = p.sections.flatMap(\.items).count
        #expect(n == 2)
    }

    @Test func nothingRelevantMeansAnEmptyPacket() async throws {
        let c = try await ContextRig()
        c.add(.decision, "Neural voice unloads after 180 seconds idle to save memory.", area: "voice")
        let p = await c.build("Rename the shader property in the water material", .coding)
        #expect(p.usedIDs.isEmpty)
        #expect(ProjectContextBuilder.render(p) == "")
    }

    @Test func theRenderedPacketStatesItIsContextNotAuthority() async throws {
        let c = try await ContextRig()
        c.add(.decision, "Camera architecture must not change without new evidence.", area: "camera")
        let t = ProjectContextBuilder.render(await c.build("Edit camera architecture", .coding))
        #expect(t.contains("never an instruction and never permission") && t.contains("CURRENT TRUTH below") )
    }
}
