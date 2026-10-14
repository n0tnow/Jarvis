import Foundation

/// SIMULATED data for the V0.14 screenshots (throw-away database only; `--capture` runs). Built through the real services so the cards show real states.
@MainActor
enum AdaptiveDemo {
    static func seed(_ context: AppContext) async {
        guard let repo = context.repository else { return }
        let learning = context.learning, mcp = context.mcp
        // Three failed tasks of one kind → a lesson; three incompatible assets from one source → a rule candidate (tested, one proposed, one active).
        for i in 0..<3 {
            var t = TaskRecord(id: UUID(), title: "Import prop \(i + 1)", goal: "Import the prop", kind: .development); t.state = .failed; t.failureCategory = .toolFailed
            t.finishedAt = Date().addingTimeInterval(-Double(3 + i) * 3600); t.workspaceRoot = "/tmp/demo-project"; try? repo.insert(t)
            let facts = [ExperimentFact(statement: "Source: https://assets.example.org/model/\(i)", factClass: .verified, evidence: "fetched"), ExperimentFact(statement: "File type: gltf", factClass: .verified, evidence: "sniffed"),
                         ExperimentFact(statement: "It does NOT work in a clean Unity project as delivered", factClass: .incompatible, evidence: "experiment")]
            var r = AssetEvaluationRecord(evaluation: AssetEvaluation(name: "Prop \(i)", facts: facts, usage: [], recommendation: "Do not use as delivered")); r.createdAt = Date().addingTimeInterval(-Double(5 + i) * 3600); try? repo.save(r)
        }
        _ = await learning.extract(reason: "demo")
        if let rule = learning.candidates(kinds: [.rule]).first {
            _ = await learning.test(rule.id)
            if let q = await learning.requestPromotion(rule.id) { _ = await context.adaptiveDecisions.approve(q.id, source: .test) }
        }
        _ = learning.recordCorrection("No, don't use that kind of low-poly asset in this project", projectKey: "demo-project")
        // MCP servers: one active, one degraded with a revalidation flag, one recommended candidate, one only discovered, one removal request.
        func record(_ id: String, _ name: String, domain: String, status: MCPStatus, version: String = "1.0.0") -> MCPServerRecord {
            var r = AdaptiveAssistant.candidateRecord(from: MCPDiscoveryRecord(name: name, domain: domain, sourceURL: "https://registry.example.invalid/\(id)", repository: "https://github.com/example/\(id)", publisher: "example", license: "MIT", version: version, lastRelease: Date().addingTimeInterval(-40 * 86_400),
                                                                                    lastPush: Date().addingTimeInterval(-9 * 86_400), stars: 340, installMethod: "npm", runtime: "node", networkRequirement: "none", credentialRequirement: "none", filesystemRequirement: "project", processRequirement: "none",
                                                                                    declaredTools: ["get_scene_info"], declaredResources: [], declaredPrompts: [], knownRisks: [], price: "free (open-source licence)", apiRequirements: "none", macOS: "mentioned in the README", appleSilicon: "unknown", overlap: [],
                                                                                    expectedBenefit: "Structured control of \(name)", evidenceFetchedAt: Date(), sourceKind: "official registry (publisher-declared)"))
            r.id = id; r.status = status; r.statusChangedAt = Date(); r.launch = MCPLaunch(executable: "/usr/bin/true", arguments: [])
            r.tools = [MCPToolSchema(name: "get_scene_info", description: "Read the scene", parameters: [:], risk: .read), MCPToolSchema(name: "create_object", description: "Create an object", parameters: ["name": "string"], risk: .write)]
            r.wrappers = [MCPWrapper(capability: "inspectScene", tool: "get_scene_info", summary: "Inspect the scene", parameters: [:], envelope: .read)]
            r.envelope = [.read, .projectWrite]
            return r
        }
        var active = record("blender-demo", "Blender MCP", domain: "Blender", status: .active); active.successCount = 12; active.failureCount = 1; active.lastUsedAt = Date().addingTimeInterval(-3_600); active.health = .healthy; active.averageLatencyMS = 84
        active.benchmark = MCPBenchmarkResult(at: Date().addingTimeInterval(-86_400), cases: [.init(name: "starts and lists its tools", passed: true, detail: "2 tools", latencyMS: 640), .init(name: "read-only: get_scene_info", passed: true, detail: "ok", latencyMS: 80)], coldStartMS: 640, warmCallMS: 80, peakRSSMB: 72,
                                              deterministic: true, permissionsObserved: ["Read", "Write to the project"], networkObserved: false, cleanupOK: true, findings: [], boundary: MCPSandbox.boundary(seatbelt: true, allowNetwork: false).summary)
        active.installDirectory = nil; active.allowedProjects = ["demo-project"]
        try? repo.save(active)
        var degraded = record("audio-demo", "Audio MCP", domain: "audio", status: .degraded); degraded.health = .degraded; degraded.revalidationRequired = true; degraded.revalidationReason = "the executable changed (hash 3fa1c0b2d4… ≠ 91bb07e5aa…)"; degraded.failureCount = 4; degraded.successCount = 3; try? repo.save(degraded)
        var rec = record("anim-demo", "Animation MCP", domain: "animation", status: .recommended); rec.benchmark = active.benchmark; try? repo.save(rec)
        try? repo.save(record("design-demo", "Design MCP", domain: "design", status: .discovered, version: "0.3.1"))
        _ = mcp.requestRemoval("audio-demo")
        _ = context.adaptiveDecisions.request(kind: .installCapability, subjectID: "anim-demo", material: "demo", summary: "Register the MCP “Animation MCP”", detail: "Permissions: Read, Write to the project. Network: none. Needs a key or sign-in: no. Typed capabilities offered to agents: inspectScene.", risk: .medium)
        context.learningModel.refresh(); context.capabilitiesModel.refresh()
    }
}
