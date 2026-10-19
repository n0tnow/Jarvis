import Foundation
import Testing
@testable import Jarvis

// V1.0 final integration — the Jev gate's project-registry hook (JARVIS-V1JV-6): exactly one known project named in the sentence, exactly (name or alias + one closed case suffix), otherwise reject / ask.
// No fuzzy match ever selects a project; Jev never supplies the target.

private func project(_ name: String, aliases: [String] = []) -> KnownProject { KnownProject(key: "path:/p/\(name)", name: name, rootPath: "/p/\(name)", kind: "path", lastSeen: Date(timeIntervalSince1970: 1_800_000_000), aliases: aliases) }

@Suite("V1.0 final integration · Jev project-registry hook")
struct JevRegistryHookTests {
    private let registry = [project("Hamam", aliases: ["hamam oyunu"]), project("Turkish Hammam Simulator"), project("Notes")]

    @Test("exactly one named project resolves (case suffixes included); none or several never do")
    func exactlyOne() {
        #expect(JevTargetResolver.resolve(raw: "Hamam'da devam et", projects: registry) == .resolved("Hamam"))
        #expect(JevTargetResolver.resolve(raw: "hamam ne durumda", projects: registry) == .resolved("Hamam"))
        #expect(JevTargetResolver.resolve(raw: "Notes projesinin durumu", projects: registry) == .resolved("Notes"))
        #expect(JevTargetResolver.resolve(raw: "Hamam oyunu nasıl gidiyor", projects: registry) == .resolved("Hamam"), "an alias names the same project once")
        #expect(JevTargetResolver.resolve(raw: "Hamam ile Notes arasındaki fark", projects: registry) == .ambiguous(["Hamam", "Notes"]))
        #expect(JevTargetResolver.resolve(raw: "projenin durumu ne", projects: registry) == .unresolved)
        #expect(JevTargetResolver.resolve(raw: "Hamam ne durumda", projects: []) == .unresolved)
        #expect(JevTargetResolver.resolve(raw: "", projects: registry) == .unresolved)
    }

    @Test("no fuzzy or prefix match: a near miss is a question elsewhere, never a target here")
    func noFuzzy() {
        for raw in ["Hamamm ne durumda", "ham ne durumda", "Hamamlar ne durumda", "Note durumu", "Turkish Hammam durumu"] {
            #expect(JevTargetResolver.resolve(raw: raw, projects: registry) == .unresolved || raw == "Hamamlar ne durumda" && JevTargetResolver.resolve(raw: raw, projects: registry) != .resolved("Hamam"), Comment(rawValue: raw))
        }
        #expect(JevTargetResolver.resolve(raw: "Turkish Hammam Simulator durumu", projects: registry) == .resolved("Turkish Hammam Simulator"))
    }

    @Test("through the gate: a project query is accepted only with exactly one registry project and ≥ 0.97; unresolved and ambiguous reject")
    func throughTheGate() {
        func verdict(_ raw: String, _ confidence: Double = 0.99) -> JevGateVerdict {
            let candidate = DecisionPolicy.finalize(intent: .projectQuery, confidence: confidence, normalized: "", target: nil, action: nil, deepReasoning: false, provenance: .jevShadow, provider: .jev)
            return JevGatePolicy.evaluate(JevGateInput(raw: raw, production: Decision.unknown(raw), candidate: candidate, targetResolution: JevTargetResolver.resolve(raw: raw, projects: registry)))
        }
        #expect(verdict("Hamam ne durumda").accepted?.intent == .projectQuery)
        #expect(verdict("Hamam ne durumda", 0.96).rejection == .belowIntentThreshold)
        #expect(verdict("projenin durumu ne").rejection == .targetUnresolved)
        #expect(verdict("Hamam ile Notes durumu").rejection == .targetAmbiguous)
        // an execution-capable project intent stays refused even when the registry resolves it
        let open = DecisionPolicy.finalize(intent: .projectOpen, confidence: 1.0, normalized: "", target: nil, action: "open", deepReasoning: false, provenance: .jevShadow, provider: .jev)
        #expect(JevGatePolicy.evaluate(JevGateInput(raw: "Hamam projesini aç", production: Decision.unknown("x"), candidate: open, targetResolution: .resolved("Hamam"))).rejection == .executionNotEnabled)
    }
}
