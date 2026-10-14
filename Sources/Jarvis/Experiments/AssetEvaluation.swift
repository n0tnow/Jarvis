import Foundation

// MARK: - Asset suitability (V0.13): what is verified, tested, stated by the source, inferred, unknown or incompatible — kept apart. "Probably" is never "works".

/// A picture-based comparison of an asset with the project (rendered asset vs a representative capture of the project). Without it no style claim exists.
struct VisualFitEvidence: Codable, Equatable, Sendable {
    var assetPictureHash: String
    var projectPictureHash: String
    var provider: String
    /// The provider's own words about the two pictures (model-observed, subjective).
    var observation: String
}

struct AssetEvaluationInput: Sendable {
    var name: String
    var sourceURL: String
    var candidate: CandidateRecord?
    var acquisition: AcquisitionRecord?
    var project: ProjectFacts?
    /// Names of things the project is about (from its docs/memory): used ONLY to word suggestions; never to claim fit.
    var projectThemes: [String] = []
    var experiment: ExperimentResult?
    var visualFit: VisualFitEvidence?
    var existingAssetOverlap: [String] = []
    /// V0.14: an ACTIVE learned rule says assets like this need the disposable test before any recommendation, and the warnings it carries. A rule only makes the recommendation stricter.
    var ruleRequiresExperiment = false
    var ruleWarnings: [String] = []
}

struct AssetEvaluation: Codable, Equatable, Sendable {
    var name: String
    var facts: [ExperimentFact]
    /// Where it could technically be used: every line says whether it is a fact, an inference or a recommendation.
    var usage: [String]
    var recommendation: String

    func facts(_ c: FactClass) -> [ExperimentFact] { facts.filter { $0.factClass == c } }
    var hasAnyTested: Bool { !facts(.tested).isEmpty }
    var summaryLines: [String] {
        func line(_ f: ExperimentFact) -> String { "  · [" + f.factClass.rawValue + "] " + f.statement + " — " + f.evidence }
        var out: [String] = ["FACTS (verified or stated by the source):"]
        out += facts.filter { $0.factClass == .verified || $0.factClass == .supportedBySource }.map(line)
        out.append("TESTED:")
        let t = facts(.tested)
        out += t.isEmpty ? ["  · nothing was tested"] : t.map { "  · " + $0.statement + " — " + $0.evidence }
        out.append("INFERENCES / UNKNOWN:")
        out += facts.filter { $0.factClass == .inferred || $0.factClass == .unknown || $0.factClass == .incompatible }.map(line)
        out.append("WHERE IT COULD BE USED:")
        out += usage.map { "  · " + $0 }
        out.append("RECOMMENDATION: " + recommendation)
        return out
    }
}

enum AssetEvaluator {
    static func evaluate(_ i: AssetEvaluationInput, now: Date = Date()) -> AssetEvaluation {
        var facts: [ExperimentFact] = []
        let c = i.candidate, a = i.acquisition
        func add(_ s: String, _ k: FactClass, _ e: String) { facts.append(ExperimentFact(statement: s, factClass: k, evidence: e)) }

        // Source and price
        add("Source: \(i.sourceURL)", .verified, "the address JARVIS actually fetched")
        if let p = a?.priceState ?? c?.price.state {
            let at: Date? = a?.priceVerifiedAt ?? c?.price.verifiedAt
            if p.isFree, let at {
                add("Price: free", .verified, "verified from the source on " + DateFormatter.localizedString(from: at, dateStyle: .medium, timeStyle: .none))
            } else {
                let word = p.rawValue.lowercased().replacingOccurrences(of: "_", with: " ")
                add("Price: " + word, p == .unknown ? .unknown : .supportedBySource, p.isFree ? "no verification date recorded" : "NOT free as far as verified — unknown price is never free")
            }
        } else { add("Price", .unknown, "never verified") }

        // Licence: a verified licence needs evidence; unknown is never safe
        let lic = c?.license
        let licenseID: String? = a?.licenseID ?? lic?.identifier
        let licenseWhere: String? = a?.licenseSourceURL ?? (lic?.evidence.isEmpty == false ? "the source's licence text" : nil)
        if let id = licenseID, let url = licenseWhere, !id.isEmpty {
            var commercial = ""
            if let l = lic { commercial = l.commercialUse == .yes ? ", commercial use allowed" : (l.commercialUse == .no ? ", commercial use NOT allowed" : "") }
            add("Licence: " + id + commercial, .supportedBySource, "stated at " + url)
            if let l = lic, l.attribution == .yes { add("Attribution is required", .supportedBySource, "licence text") }
        } else { add("Licence", .unknown, "no licence evidence was found — an unknown licence is NOT safe to use") }

        // Hash and archive facts
        if let a {
            if a.hashMatchesPublished == .yes { add("The download matches the checksum the publisher states", .verified, "SHA-256 compared after download") }
            else if a.sha256 != nil { add("The download is hashed (SHA-256 \(a.sha256!.prefix(12))…)", .verified, "computed by JARVIS; the publisher states no checksum to compare") }
            if let t = a.detectedType { add("File type: \(t)", .verified, "content sniffed, not the extension") }
            if let s = a.size { add("Size: \(s / 1024) KB", .verified, "measured") }
        }

        // Compatibility: stated, then tested
        let compat = c?.compatibility
        let tested = i.experiment?.facts.filter { $0.factClass == .tested } ?? []
        facts += tested
        // “Imported and compiled” counts as a TESTED compatibility ONLY when the experiment as a whole held (an object came out of the asset and rendered); a refuted or inconclusive run proves nothing about compatibility.
        let importedAndCompiled = i.experiment?.verdict == .confirmed && tested.contains { $0.statement.localizedCaseInsensitiveContains("compil") } && tested.contains { $0.statement.localizedCaseInsensitiveContains("import") }
        let refutedBy: String? = i.experiment?.verdict == .refuted ? (i.experiment?.failureHit.first ?? "a check failed") : nil
        if let why = refutedBy { add("It does NOT work in a clean Unity project as delivered: \(why)", .incompatible, "experiment result: " + (i.experiment?.summary ?? "refuted")) }
        if let compat {
            switch compat.overall {
            case .incompatible: add("Compatibility with this project", .incompatible, compat.reasons.first ?? "the source states a conflict")
            case .compatible: add("Compatibility with Unity \(i.project?.unityVersion ?? "?") / \(i.project?.renderPipeline ?? "?")", importedAndCompiled ? .tested : .supportedBySource, importedAndCompiled ? "it imported and compiled in a clean project" : "the source states it; not tested here")
            case .likely: add("Probably compatible with Unity \(i.project?.unityVersion ?? "?") / \(i.project?.renderPipeline ?? "?")", importedAndCompiled ? .tested : .inferred, importedAndCompiled ? "it imported and compiled in a clean project" : (compat.reasons.first ?? "inferred from the stated formats; NOT tested"))
            case .unknown: add("Compatibility with this project", importedAndCompiled ? .tested : .unknown, importedAndCompiled ? "it imported and compiled in a clean project" : "not stated and not tested")
            }
        } else if importedAndCompiled { add("It imports and compiles in a clean Unity project", .tested, "experiment") }
        if let m = c?.meta {
            if !m.pipelines.isEmpty { add("Render pipelines stated: \(m.pipelines.joined(separator: ", "))", .supportedBySource, "the listing") }
            if let r = m.animationType { add("Animation type stated: \(r)", .supportedBySource, "the listing") }
            if !m.dependencies.isEmpty { add("Dependencies stated: \(m.dependencies.prefix(4).joined(separator: ", "))", .supportedBySource, "the listing") }
            if let p = m.polycount { add("Polygon count stated: \(p)", .supportedBySource, "the listing") }
        }
        if !i.existingAssetOverlap.isEmpty { add("Overlaps with what the project already has: \(i.existingAssetOverlap.prefix(3).joined(separator: ", "))", .verified, "project file listing") }

        // Style fit: only with visual evidence, and then only as a labelled model observation
        if let v = i.visualFit { add("Visual comparison with the project: \(v.observation.prefix(160))", .inferred, "model-observed by \(v.provider) from pictures \(v.assetPictureHash)/\(v.projectPictureHash) — subjective, not measured") }
        else { add("Style fit with the project", .unknown, "not assessed: a style claim needs a rendered picture of the asset next to a capture of the project (none exists)") }

        // Recommendation
        let blockers = facts.filter { $0.factClass == .incompatible && !$0.statement.hasPrefix("It does NOT work") }
        let unknownLicense = facts.contains { $0.statement == "Licence" && $0.factClass == .unknown }
        let notFree = facts.contains { $0.statement.hasPrefix("Price:") && !$0.statement.contains("free") }
        var rec: String
        if i.ruleRequiresExperiment { add("A learned rule applies to assets like this one", .verified, "earlier assets of this kind failed; the rule asks for the disposable test first") }
        if !blockers.isEmpty { rec = "Do not use: \(blockers[0].statement) (\(blockers[0].evidence))." }
        else if unknownLicense { rec = "Do not import yet: the licence is unknown. Read the source's licence page, then decide." }
        else if notFree { rec = "Not free as far as verified; JARVIS never buys anything. Decide yourself." }
        else if let why = refutedBy { rec = "Do not use as delivered: the experiment refuted it (\(why)). A different format or a conversion would have to be tested first." }
        else if i.ruleRequiresExperiment, !importedAndCompiled { rec = "A learned rule requires the asset test first (earlier assets of this kind were incompatible): run it before you decide. " + (i.ruleWarnings.first ?? "") }
        else if importedAndCompiled { rec = "Technically fine to try: it imported and compiled in a clean project. Import it into the real project only through its own approved task." }
        else { rec = "Not tested: the facts above come from the source. Run the asset test before importing." }
        // A learned rule only ever makes the recommendation STRICTER: whatever else applies, the asset test comes first.
        if i.ruleRequiresExperiment, !importedAndCompiled, !rec.contains("A learned rule requires the asset test first") { rec += " A learned rule also requires the asset test first (earlier assets of this kind were incompatible)." }
        return AssetEvaluation(name: i.name, facts: facts, usage: usage(i, tested: importedAndCompiled), recommendation: rec)
    }

    /// Where it could be used — each line labelled FACT / INFERENCE / RECOMMENDATION. Conservative: only what the asset kind and the project facts support.
    static func usage(_ i: AssetEvaluationInput, tested: Bool) -> [String] {
        var out: [String] = []
        let kind = i.candidate?.kind ?? .any
        let themes = i.projectThemes.prefix(3).joined(separator: ", ")
        out.append("FACT: it is a \(kind == .any ? "game asset" : kind.label) from \(i.candidate?.publisher ?? "the listed publisher")\(tested ? " and it imported and rendered in a clean project" : "").")
        switch kind {
        case .model3D: out.append("INFERENCE: as a static prop it could dress scenes that already contain props of a similar scale\(themes.isEmpty ? "" : " (the project is about \(themes))").")
        case .animation: out.append("INFERENCE: it could drive a character only if its rig (\(i.candidate?.meta.animationType ?? "type unstated")) matches the character's avatar — that has NOT been tested on your character.")
        case .audio, .music: out.append("INFERENCE: it could be attached to an AudioSource on an interaction object or the scene ambience.")
        case .texture: out.append("INFERENCE: it could be used on a material for surfaces that need that look.")
        default: out.append("INFERENCE: its use depends on what it contains; nothing more specific can be claimed without opening it.")
        }
        if i.visualFit == nil { out.append("RECOMMENDATION: before using it for looks, render it next to a capture of your scene — whether it matches your art direction is not known.") }
        if i.project?.renderPipeline == "URP", i.candidate?.meta.pipelines.contains(where: { $0.lowercased().contains("urp") }) != true { out.append("RECOMMENDATION: check its materials under URP (the project uses URP; the source does not state URP support).") }
        return out
    }

    /// A style claim is allowed only with picture evidence from BOTH sides. Anything else is UNKNOWN. (Used by the report/answer layer.)
    static func styleClaimAllowed(_ e: VisualFitEvidence?) -> Bool { e.map { !$0.assetPictureHash.isEmpty && !$0.projectPictureHash.isEmpty && $0.assetPictureHash != $0.projectPictureHash } ?? false }
}
