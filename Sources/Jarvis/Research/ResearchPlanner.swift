import Foundation

/// Research plans are DETERMINISTIC (not asked from a model): a short, fixed, bounded sequence per research type. "Browse until satisfied" does
/// not exist — every step has a budget (ResearchBudget) and a validation. The model is called only inside steps, for validated JSON.
enum ResearchPlanner {
    static func plan(for r: ResearchRequest) -> TaskPlan {
        func step(_ id: String, _ title: String, _ desc: String, _ type: StepType, _ deps: [String], _ expected: String) -> PlanStep {
            PlanStep(id: id, title: title, description: desc, type: type, dependsOn: deps, expected: expected, validation: .default(for: type), risk: type.defaultRisk)
        }
        var steps: [PlanStep] = [
            step("s1", "Search the public web", "Run the planned queries through the search providers (budgeted).", .researchSearch, [], "Search results collected"),
            step("s2", "Read the most relevant sources", "Fetch and parse the highest-priority sources (HTTP first; rendered browser only for JavaScript shells).", .researchRead, ["s1"], "Sources read with provenance"),
            step("s3", "Extract candidates and claims", "Record candidates and evidence-backed claims; model output is accepted only when its quoted evidence is in the page.", .researchExtract, ["s2"], "Candidates and claims recorded"),
        ]
        switch r.type {
        case .assetDiscovery, .library, .comparison:
            steps.append(step("s4", "Verify price, licence and compatibility", "Re-fetch each candidate's own listing and verify the CURRENT price, licence, Unity/pipeline compatibility and download route.", .researchVerify, ["s3"], "Every candidate verified or marked UNKNOWN"))
            steps.append(step("s5", "Compare and write the report", "Rank with explicit factors and write the cited report (facts, assessments and recommendation kept apart).", .researchReport, ["s4"], "Report written"))
        default:
            steps.append(step("s4", "Write the report", "Write the cited report (official facts and community statements kept apart).", .researchReport, ["s3"], "Report written"))
        }
        return TaskPlan(summary: "Research: \(String(r.goal.prefix(120)))", steps: steps)
    }

    /// One download + inspection into the quarantine (the approval, if any, is requested INSIDE the step).
    static func acquisitionPlan(name: String) -> TaskPlan {
        TaskPlan(summary: "Acquire “\(name.prefix(80))” into the quarantine", steps: [
            PlanStep(id: "s1", title: "Download “\(name.prefix(60))” into the quarantine and inspect it", description: "Re-verify price and licence, download over https, hash, type-check, inspect archives; nothing is imported or executed.",
                     type: .acquire, dependsOn: [], expected: "Artifact quarantined and inspected", validation: .artifactAcquired, risk: .medium),
        ])
    }

    /// A project import (V0.4 development task): copy the inspected artifact into Assets/ThirdParty, then let Unity compile (V0.6 owns the editor).
    static func importPlan(name: String, unity: Bool) -> TaskPlan {
        var steps = [PlanStep(id: "s1", title: "Import “\(name.prefix(60))” into the project", description: "Copy the quarantined, inspected files under Assets/ThirdParty with provenance; approval required.",
                              type: .importAsset, dependsOn: [], expected: "Files copied with matching hashes", validation: .assetImported, risk: .high)]
        if unity { steps.append(PlanStep(id: "s2", title: "Compile in Unity", description: "Let the Unity Editor import and compile; the editor's own compiler state decides.", type: .unityCompile, dependsOn: ["s1"], expected: "No compiler errors", validation: .unityCompiled, risk: .low)) }
        return TaskPlan(summary: "Import “\(name.prefix(80))”", steps: steps)
    }
}
