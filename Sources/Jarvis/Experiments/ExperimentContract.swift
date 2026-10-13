import Foundation

// MARK: - Experiments (V0.13, DEC-191…): "we do not know whether X works — can we test it safely?"
//
// An experiment is NOT self-improvement and NOT a way to touch the user's project. It declares a question and a hypothesis, runs typed steps in a DISPOSABLE environment that
// JARVIS created under its own temporary root, judges the declared criteria against evidence (compile state, Console, editor geometry, pixels), then deletes the environment and
// keeps only a small structured result. Promoting a result into the real project is a separate, ordinary, approval-gated task.

enum ExperimentKind: String, Codable, Sendable, CaseIterable {
    /// A quarantined asset: does it import, compile, instantiate and render in a clean project?
    case assetImport
    /// A material (or a shader property set): does it render under the project's pipeline (not pink, visible)?
    case materialRender
    /// A clip/controller on a rig: does the animation actually run?
    case animationPlayback

    var label: String { switch self { case .assetImport: "Asset import test"; case .materialRender: "Material render test"; case .animationPlayback: "Animation playback test" } }
    /// The steps JARVIS runs for this kind (fixed, typed, in order).
    var steps: [ExperimentStepKind] {
        switch self {
        case .assetImport: [.createEnvironment, .importAsset, .openEditor, .compileAndConsole, .discover, .instantiateAndCapture, .evaluate]
        case .materialRender: [.createEnvironment, .openEditor, .compileAndConsole, .instantiateAndCapture, .evaluate]
        case .animationPlayback: [.createEnvironment, .openEditor, .compileAndConsole, .playAndObserve, .evaluate]
        }
    }
}

enum ExperimentStepKind: String, Codable, Sendable {
    case createEnvironment, importAsset, openEditor, compileAndConsole, discover, instantiateAndCapture, playAndObserve, evaluate
    var label: String {
        switch self {
        case .createEnvironment: "Create the disposable project"; case .importAsset: "Import the quarantined copy"; case .openEditor: "Open the editor"
        case .compileAndConsole: "Compile and read the Console"; case .discover: "List what was imported"; case .instantiateAndCapture: "Instantiate and render"
        case .playAndObserve: "Play and observe"; case .evaluate: "Judge the criteria"
        }
    }
}

/// What the plan (or the orchestrator's template) declares. Every field is bounded; none can carry code, a path outside the experiment root, or a command.
struct ExperimentSpec: Codable, Equatable, Sendable {
    var question: String
    var hypothesis: String
    var kind: ExperimentKind
    /// The acquisition (quarantine record) an `assetImport` examines: already downloaded, hashed and inspected by the V0.9 acquisition task. Nothing is downloaded here.
    var acquisitionID: UUID?
    /// Assets of the disposable project the kind examines (relative, inside Assets/).
    var assetPaths: [String] = []
    var successCriteria: [String]
    var failureCriteria: [String]
    var minutes = 15
    var diskMegabytes = 1_024
    /// Always 0 in V0.13: an experiment never uses the network itself (Unity's own package resolution is Unity's traffic, not an experiment action).
    var networkRequests = 0
    var artifacts = 4
    /// What happens to the environment afterwards. `delete` is the only value; the field exists so the contract states it.
    var cleanup = "delete"

    static let maxMinutes = 20, maxDiskMegabytes = 2_048, maxArtifacts = 6, maxCriteria = 6

    var display: String { "\(kind.label): \(question.prefix(80))" }
}

enum ExperimentProblem: Equatable, CustomStringConvertible, Sendable {
    case missing(String), tooLarge(String), unsafe(String)
    var description: String { switch self { case .missing(let s): "the experiment is missing \(s)"; case .tooLarge(let s): "the experiment exceeds a bound: \(s)"; case .unsafe(let s): "the experiment is not safe: \(s)" } }
}

/// Pure validation of an experiment contract (bounds, isolation, cleanup, no real-project path).
enum ExperimentValidator {
    static func validate(_ s: ExperimentSpec, realProjectRoots: [String] = []) -> [ExperimentProblem] {
        var out: [ExperimentProblem] = []
        func blank(_ x: String) -> Bool { x.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if blank(s.question) { out.append(.missing("a question")) }
        if blank(s.hypothesis) { out.append(.missing("a hypothesis")) }
        if s.successCriteria.isEmpty || s.successCriteria.allSatisfy(blank) { out.append(.missing("success criteria")) }
        if s.failureCriteria.isEmpty || s.failureCriteria.allSatisfy(blank) { out.append(.missing("failure criteria")) }
        if s.question.count > 300 || s.hypothesis.count > 300 || s.successCriteria.count > ExperimentSpec.maxCriteria || s.failureCriteria.count > ExperimentSpec.maxCriteria || (s.successCriteria + s.failureCriteria).contains(where: { $0.count > 200 }) { out.append(.tooLarge("question, hypothesis or criteria")) }
        if !(1...ExperimentSpec.maxMinutes).contains(s.minutes) { out.append(.tooLarge("time budget \(s.minutes) min (1–\(ExperimentSpec.maxMinutes))")) }
        if !(16...ExperimentSpec.maxDiskMegabytes).contains(s.diskMegabytes) { out.append(.tooLarge("disk budget \(s.diskMegabytes) MB (16–\(ExperimentSpec.maxDiskMegabytes))")) }
        if s.artifacts < 0 || s.artifacts > ExperimentSpec.maxArtifacts { out.append(.tooLarge("artifact budget")) }
        if s.networkRequests != 0 { out.append(.unsafe("an experiment never spends a network budget")) }
        if s.cleanup != "delete" { out.append(.unsafe("cleanup must delete the disposable environment")) }
        if s.kind == .assetImport, s.acquisitionID == nil { out.append(.missing("the quarantined acquisition it examines")) }
        for p in s.assetPaths where !UnityPolicy.isSafeProjectPath(p) { out.append(.unsafe("“\(p.prefix(40))” is not a path inside Assets/")) }
        // No part of the contract may name a real project folder: the environment is created by JARVIS, never chosen by the plan.
        let text = ([s.question, s.hypothesis] + s.successCriteria + s.failureCriteria + s.assetPaths).joined(separator: "\n")
        for root in realProjectRoots where !root.isEmpty && text.contains(root) { out.append(.unsafe("it names a real project folder")) }
        for bad in ["rm -rf", "sudo", "curl ", "wget ", "osascript", "executeMenuItem", "git push", "~/"] where text.lowercased().contains(bad) { out.append(.unsafe("it contains “\(bad.trimmingCharacters(in: .whitespaces))”")) }
        return out
    }
}

/// What an experiment concluded, with the six fact classes of the brief kept apart: nothing inferred is ever reported as tested.
enum FactClass: String, Codable, Sendable, CaseIterable {
    case verified = "VERIFIED", tested = "TESTED", supportedBySource = "SUPPORTED BY SOURCE", inferred = "INFERRED", unknown = "UNKNOWN", incompatible = "INCOMPATIBLE"
}

struct ExperimentFact: Codable, Equatable, Sendable {
    var statement: String
    var factClass: FactClass
    /// What the statement rests on (“Unity compiled with 0 errors”, “licence page of the source”, “not tested”).
    var evidence: String
}

struct ExperimentResult: Codable, Equatable, Sendable {
    enum Verdict: String, Codable, Sendable { case confirmed, refuted, inconclusive }
    var verdict: Verdict
    var summary: String
    var facts: [ExperimentFact]
    var successMet: [String]
    var failureHit: [String]
    var seconds: Double
    var environmentDeleted: Bool
    /// Hashes of the pictures the verdict depended on (never the pixels).
    var pictureHashes: [String] = []
    var projectUntouched = true
}
