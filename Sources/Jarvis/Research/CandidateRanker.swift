import Foundation

/// Explicit, explainable ranking (no opaque score): each factor has a weight, a 0…1 value and a reason; hard constraint violations
/// disqualify a candidate BEFORE any score matters. The report prints the factors so "why A above B" is answerable.
enum CandidateRanker {
    static let weights: [(name: String, weight: Double)] = [
        ("licence safety", 0.20), ("price certainty", 0.15), ("compatibility", 0.13), ("acquisition friction", 0.09), ("source trust", 0.08), ("style fit (model assessment)", 0.08), ("maintenance", 0.04), ("topical relevance", 0.23),
    ]

    static func licenseValue(_ l: LicenseAssessment) -> (Double, String) {
        switch l.state {
        case .permissive: return (l.needsReview ? 0.7 : 1.0, "\(l.identifier ?? "permissive licence")\(l.needsReview ? " (not from an official source — verify)" : "")")
        case .attributionRequired: return (l.needsReview ? 0.65 : 0.9, "\(l.identifier ?? "attribution licence") — credit required")
        case .marketplaceEULA: return (0.6, "marketplace EULA: usable in the game, raw redistribution not allowed")
        case .copyleft: return (0.35, "\(l.identifier ?? "copyleft") — may affect how the game is distributed")
        case .noDerivatives: return (0.2, "no-derivatives licence — modification is not allowed")
        case .nonCommercial: return (0.05, "non-commercial licence")
        case .customRestricted: return (0.15, "custom or restrictive terms")
        case .contradictory: return (0.1, "official sources disagree")
        case .unknown: return (0.1, "licence not found — unknown is not safe")
        }
    }

    static func priceValue(_ p: PriceAssessment, freeOnly: Bool) -> (Double, String) {
        switch p.state {
        case .freeVerified: return (1.0, "FREE_VERIFIED from a current official source")
        case .paidVerified: return (freeOnly ? 0.0 : 0.5, "paid" + (p.amount.map { String(format: " (%.2f %@)", $0, p.currency ?? "") } ?? ""))
        case .promotion: return (0.4, "free only during a promotion")
        case .subscriptionIncluded: return (0.1, "needs a subscription")
        case .requiresLoginToVerify: return (0.2, "price needs a login to verify")
        case .regionDependent: return (0.3, "region dependent")
        case .unavailable: return (0.0, "listing unavailable")
        case .other: return (0.15, p.note ?? "trial / other pricing")
        case .unknown: return (0.15, "price could not be verified")
        }
    }

    static func compatValue(_ c: CompatibilityAssessment) -> (Double, String) {
        switch c.overall {
        case .compatible: return (1.0, "COMPATIBLE with the project")
        case .likely: return (0.7, "LIKELY_COMPATIBLE")
        case .unknown: return (0.35, "compatibility UNKNOWN")
        case .incompatible: return (0.0, "INCOMPATIBLE")
        }
    }

    static func frictionValue(_ a: AcquisitionClass, account: Tri) -> (Double, String) {
        switch a {
        case .publicDirectDownload: return (1.0, "public direct download, no account")
        case .accountRequiredFree: return (0.4, "free but needs an account action (user approval)")
        case .marketplaceClaim: return (0.4, "marketplace claim (user approval)")
        case .paidPurchase: return (0.1, "paid — JARVIS never purchases")
        case .unknown: return (account == .no ? 0.5 : 0.2, "no verified download route")
        }
    }

    /// How many of the request's SUBJECT words (generic request words removed) the candidate's own name/description/link mention. Zero of several = it is simply not what was asked for.
    static func relevanceValue(_ c: CandidateRecord, terms: [String]) -> (Double, String, matched: Int) {
        guard !terms.isEmpty else { return (0.5, "no subject words to compare", 0) }
        let hay = [c.name, c.summary ?? "", (URL(string: c.url)?.path ?? "").replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")].joined(separator: " ")
        let hit = terms.filter { SearchTerms.mentions(hay, term: $0) }
        if hit.isEmpty { return (0, "matches none of: " + terms.prefix(5).joined(separator: ", "), 0) }
        let need = Double(max(1, min(terms.count, 3)))
        return (min(1, Double(hit.count) / need), "matches: " + hit.prefix(4).joined(separator: ", "), hit.count)
    }

    static func styleValue(_ fit: String?) -> (Double, String) {
        switch (fit ?? "").lowercased() {
        case let s where s.hasPrefix("high"): return (0.9, "model assessment: high fit")
        case let s where s.hasPrefix("medium"): return (0.6, "model assessment: medium fit")
        case let s where s.hasPrefix("low"): return (0.3, "model assessment: low fit")
        default: return (0.5, "style fit not assessed (neutral)")
        }
    }

    static func maintenanceValue(_ meta: AssetMetadata, now: Date = Date()) -> (Double, String) {
        guard let s = meta.lastUpdate, let d = ResearchPipelineDate.parse(s) else { return (0.5, "update date unknown") }
        let years = now.timeIntervalSince(d) / (365 * 86_400)
        return years < 1 ? (1.0, "updated within a year") : years < 3 ? (0.6, "updated within three years") : (0.3, "not updated for \(Int(years)) years")
    }

    /// Hard constraints. Each violation is a reason the candidate is NOT recommended, whatever its score.
    static func violations(_ c: CandidateRecord, request r: ResearchRequest, terms: [String] = []) -> [String] {
        var v: [String] = []
        if !terms.isEmpty, relevanceValue(c, terms: terms).matched == 0 { v.append("it does not match what was asked for (none of: " + terms.prefix(4).joined(separator: ", ") + ")") }
        let k = r.constraints
        if k.freeOnly, c.price.state != .freeVerified { v.append(c.price.state == .paidVerified ? "it is paid (free only was requested)" : "price is not verified free (\(c.price.state.rawValue))") }
        if k.commercialUse, c.license.commercialUse != .yes { v.append(c.license.commercialUse == .no ? "the licence forbids commercial use" : "commercial use is not confirmed by the licence") }
        if k.noAccount, c.accountRequired == .yes || [.accountRequiredFree, .marketplaceClaim].contains(c.acquisition) { v.append("it needs an account / login") }
        if k.openSourceOnly, ![LicenseState.permissive, .copyleft, .attributionRequired].contains(c.license.state) { v.append("not clearly open source") }
        if c.compatibility.overall == .incompatible { v.append("incompatible with the project (\(c.compatibility.reasons.first ?? "see details"))") }
        if c.license.state == .nonCommercial { v.append("non-commercial licence") }
        if c.license.state == .noDerivatives, r.constraints.assetKind == .animation || r.constraints.assetKind == .model3D { v.append("no-derivatives licence blocks adapting the asset") }
        if k.officialOnly, c.sourceTrust < 4 { v.append("not from an official source") }
        return v
    }

    static func rank(_ list: [CandidateRecord], request r: ResearchRequest, terms: [String] = [], sourceTrust: (CandidateRecord) -> Int = { $0.sourceTrust }, now: Date = Date()) -> [CandidateRecord] {
        var scored: [CandidateRecord] = list.map { c in
            var c = c
            let lic = licenseValue(c.license), price = priceValue(c.price, freeOnly: r.constraints.freeOnly), compat = compatValue(c.compatibility)
            let fr = frictionValue(c.acquisition, account: c.accountRequired), style = styleValue(c.styleFit), maint = maintenanceValue(c.meta, now: now)
            let trust = Double(max(0, min(5, sourceTrust(c)))) / 5
            let rel = relevanceValue(c, terms: terms)
            let values: [(Double, String)] = [lic, price, compat, fr, (trust, "source trust \(sourceTrust(c))/5"), style, maint, (rel.0, rel.1)]
            c.factors = zip(weights, values).map { RankFactor(name: $0.0.name, weight: $0.0.weight, value: $0.1.0, reason: $0.1.1) }
            c.score = c.factors.reduce(0) { $0 + $1.weight * $1.value }
            return c
        }
        scored.sort { $0.score > $1.score }
        var preferredTaken = false, alternatives = 0
        for i in scored.indices {
            let bad = violations(scored[i], request: r, terms: terms)
            scored[i].rank = i + 1
            if !bad.isEmpty { scored[i].verdict = .notRecommended; scored[i].verdictReasons = bad; continue }
            if !preferredTaken {
                scored[i].verdict = .preferred; preferredTaken = true
                scored[i].verdictReasons = ["highest score \(String(format: "%.2f", scored[i].score)) among candidates that meet every constraint"]
            } else if alternatives < 2 {
                scored[i].verdict = .alternative; alternatives += 1
                let top = scored.first { $0.verdict == .preferred }
                scored[i].verdictReasons = top.map { t in
                    let worse = zip(t.factors, scored[i].factors).filter { $0.0.value - $0.1.value > 0.15 }.map { "\($0.1.name): \($0.1.reason)" }
                    return worse.isEmpty ? ["close behind the preferred candidate"] : ["below the preferred candidate on " + worse.prefix(2).joined(separator: "; ")]
                } ?? []
            } else { scored[i].verdict = .notRecommended; scored[i].verdictReasons = ["ranked lower (\(String(format: "%.2f", scored[i].score)))"] }
        }
        return scored
    }
}

enum ResearchPipelineDate {
    static func parse(_ s: String) -> Date? {
        if let d = ResearchPipeline.date(s) { return d }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["MMM d, yyyy", "MMMM d, yyyy", "MMM d yyyy", "d MMM yyyy", "yyyy/MM/dd"] { f.dateFormat = fmt; if let d = f.date(from: s) { return d } }
        return nil
    }
}
