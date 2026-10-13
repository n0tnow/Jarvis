import Foundation
import CoreGraphics

// MARK: - The grounding layer: policy-chosen providers, validated output, and the adapter the Computer Use executor already knows (`VisionProposing`)

enum VisualGroundingMode: String, Codable, Sendable, CaseIterable {
    /// On-device providers only (Apple text recognition + the local model when installed and memory allows).
    case auto
    case off
    var label: String { self == .auto ? "On-device (automatic)" : "Off" }
}

@MainActor
final class VisualGrounder {
    var providers: [any VisualProvider]
    var mode: () -> VisualGroundingMode = { .auto }
    /// A subscription provider may only ever see the user's OWN project render, and only when this is true. No implementation is registered in V0.13 (see docs/VISUAL_GROUNDING.md).
    var cloudAllowed: () -> Bool = { false }
    var pressureNormal: () -> Bool = { true }
    var onEvent: ((String) -> Void)?

    struct Trace: Equatable, Sendable { var provider: String; var seconds: Double; var outcome: String }
    private(set) var lastTrace: [Trace] = []
    private(set) var lastAnswer: VisualAnswer?

    init(providers: [any VisualProvider]) { self.providers = providers }

    /// Providers that may serve this question right now (privacy, capability, availability, memory).
    func eligible(for query: VisualQuery, sensitivity: VisualSensitivity) -> [any VisualProvider] {
        guard mode() != .off else { return [] }
        var ps = VisualProviderSelection.choose(for: query, sensitivity: sensitivity, among: providers, cloudAllowed: cloudAllowed())
        if !pressureNormal() { ps = ps.filter { p in (p as? LocalVLMProvider).map { $0.runtime.isResident } ?? true } }          // never LOAD a multi-GB model under pressure
        return ps
    }

    func answer(image: CGImage, query: VisualQuery, sensitivity: VisualSensitivity) async -> VisualAnswer {
        lastTrace = []
        guard let png = VisualImageCoding.png(image) else { var a = VisualAnswer(); a.abstainReason = "the picture could not be encoded"; return a }
        let chain = eligible(for: query, sensitivity: sensitivity)
        guard !chain.isEmpty else {
            var a = VisualAnswer(); a.pictureHash = VisualImageCoding.hash(png)
            a.abstainReason = mode() == .off ? "visual grounding is off in Settings" : "no visual provider is available for this picture right now"
            lastAnswer = a; return a
        }
        var best: VisualAnswer?
        for p in chain {
            do {
                let a = try await p.analyze(png: png, image: image, query: query)
                lastTrace.append(Trace(provider: p.id, seconds: a.seconds, outcome: a.found ? (a.ambiguous ? "ambiguous" : "found") : "not found"))
                // A definite answer ends the chain; an abstention lets the next (stronger) provider try, and the first abstention is kept as the fallback.
                if a.found && !a.ambiguous { lastAnswer = a; return a }
                if best == nil || (a.found && !(best?.found ?? false)) { best = a }
                if case .describe = query, a.found { lastAnswer = a; return a }
            } catch {
                lastTrace.append(Trace(provider: p.id, seconds: 0, outcome: "unavailable: \(error)"))
                onEvent?("\(p.id): \(error)")
            }
        }
        var out = best ?? VisualAnswer()
        if best == nil { out.abstainReason = "every visual provider failed (" + lastTrace.map(\.outcome).joined(separator: "; ") + ")" }
        out.pictureHash = out.pictureHash.isEmpty ? VisualImageCoding.hash(png) : out.pictureHash
        lastAnswer = out
        return out
    }

    func unloadHeavyProviders() async { for p in providers { if let v = p as? LocalVLMProvider { await v.runtime.unloadNow() } } }
}

/// The adapter the V0.11 executor calls. A proposal is NOT an action: the executor still validates freshness, bounds, occlusion, user interference and policy on the label.
/// Several candidates (or a provider that says “ambiguous”) are returned as several proposals so the executor refuses to guess.
final class GroundedVisionProposer: VisionProposing, @unchecked Sendable {
    private let grounder: VisualGrounder
    let sensitivity: VisualSensitivity
    var name: String { "General visual grounding" }
    @MainActor init(grounder: VisualGrounder, sensitivity: VisualSensitivity = .desktop) { self.grounder = grounder; self.sensitivity = sensitivity }

    func propose(label: String, image: CGImage, scale: CGFloat) async -> [VisionProposal] {
        let answer = await grounder.answer(image: image, query: .locate(label), sensitivity: sensitivity)
        return Self.proposals(from: answer, windowSize: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }

    static func proposals(from a: VisualAnswer, windowSize: CGSize) -> [VisionProposal] {
        guard a.found else { return [] }
        var out = a.candidates.map { c -> VisionProposal in
            // The policy sees BOTH what the provider called the control and what is printed in it (the worse reading wins there).
            var parts: [String] = []
            for s in [c.label, c.printedText].compactMap({ $0 }) where !parts.contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) { parts.append(s) }
            return VisionProposal(label: parts.joined(separator: " · "), box: c.region.rect(inWindow: windowSize), reason: "\(a.provider) located it in the window picture (\(c.confidence.rawValue) confidence)", source: a.provider)
        }
        // A provider that doubts its own single answer (“ambiguous”) must not be clicked on: duplicate it so the executor reports AMBIGUOUS instead of guessing.
        if a.ambiguous && out.count == 1 { out.append(out[0]) }
        return out
    }
}
