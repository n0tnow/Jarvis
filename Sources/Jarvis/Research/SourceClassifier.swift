import Foundation

/// Source quality, deterministic. A source is "official" for a SUBJECT, not in general: docs.unity3d.com is official for a Unity question,
/// a random GitHub repository is not official for anything it does not own. The hierarchy is a guide, never absolute truth:
/// for community experience a forum thread is exactly the right source; for price/licence/API behaviour only an official source may decide.
struct SourceClassification: Equatable, Sendable {
    var type: SourceType
    var official: OfficialStatus
    var trust: Int                         // 0…5
    var reason: String
    var suspicious = false
}

enum SourceClassifier {
    private struct Rule { var suffix: String; var type: SourceType; var vendor: String?; var trust: Int }

    /// vendor = the subject keyword for which this host speaks with first-party authority.
    private static let rules: [Rule] = [
        Rule(suffix: "docs.unity3d.com", type: .officialDocs, vendor: "unity", trust: 5),
        Rule(suffix: "docs.unity.com", type: .officialDocs, vendor: "unity", trust: 5),
        Rule(suffix: "learn.unity.com", type: .officialDocs, vendor: "unity", trust: 4),
        Rule(suffix: "unity.com", type: .officialProduct, vendor: "unity", trust: 5),
        Rule(suffix: "unity3d.com", type: .officialProduct, vendor: "unity", trust: 5),
        Rule(suffix: "assetstore.unity.com", type: .assetStore, vendor: "unity", trust: 4),
        Rule(suffix: "discussions.unity.com", type: .forum, vendor: nil, trust: 2),
        Rule(suffix: "forum.unity.com", type: .forum, vendor: nil, trust: 2),
        Rule(suffix: "developer.apple.com", type: .officialDocs, vendor: "apple", trust: 5),
        Rule(suffix: "swift.org", type: .officialDocs, vendor: "swift", trust: 5),
        Rule(suffix: "docs.python.org", type: .officialDocs, vendor: "python", trust: 5),
        Rule(suffix: "python.org", type: .officialProduct, vendor: "python", trust: 5),
        Rule(suffix: "nodejs.org", type: .officialDocs, vendor: "node", trust: 5),
        Rule(suffix: "learn.microsoft.com", type: .officialDocs, vendor: "microsoft", trust: 5),
        Rule(suffix: "docs.github.com", type: .officialDocs, vendor: "github", trust: 5),
        Rule(suffix: "developer.mozilla.org", type: .officialDocs, vendor: "mdn", trust: 4),
        Rule(suffix: "playwright.dev", type: .officialDocs, vendor: "playwright", trust: 5),
        Rule(suffix: "pypi.org", type: .packageRegistry, vendor: nil, trust: 4),
        Rule(suffix: "npmjs.com", type: .packageRegistry, vendor: nil, trust: 4),
        Rule(suffix: "registry.npmjs.org", type: .packageRegistry, vendor: nil, trust: 4),
        Rule(suffix: "crates.io", type: .packageRegistry, vendor: nil, trust: 4),
        Rule(suffix: "nuget.org", type: .packageRegistry, vendor: nil, trust: 4),
        Rule(suffix: "openupm.com", type: .packageRegistry, vendor: nil, trust: 3),
        Rule(suffix: "github.com", type: .github, vendor: nil, trust: 3),
        Rule(suffix: "api.github.com", type: .github, vendor: nil, trust: 4),
        Rule(suffix: "raw.githubusercontent.com", type: .github, vendor: nil, trust: 3),
        // asset publishers and libraries that are themselves the publisher of what they list
        Rule(suffix: "polyhaven.com", type: .officialProduct, vendor: "polyhaven", trust: 5),
        Rule(suffix: "api.polyhaven.com", type: .officialProduct, vendor: "polyhaven", trust: 5),
        Rule(suffix: "kenney.nl", type: .officialProduct, vendor: "kenney", trust: 5),
        Rule(suffix: "opengameart.org", type: .marketplace, vendor: nil, trust: 3),
        Rule(suffix: "itch.io", type: .marketplace, vendor: nil, trust: 3),
        Rule(suffix: "sketchfab.com", type: .marketplace, vendor: nil, trust: 3),
        Rule(suffix: "mixamo.com", type: .marketplace, vendor: "adobe", trust: 4),
        Rule(suffix: "freesound.org", type: .marketplace, vendor: nil, trust: 3),
        Rule(suffix: "ambientcg.com", type: .officialProduct, vendor: "ambientcg", trust: 5),
        // community
        Rule(suffix: "stackoverflow.com", type: .forum, vendor: nil, trust: 3),
        Rule(suffix: "stackexchange.com", type: .forum, vendor: nil, trust: 3),
        Rule(suffix: "gamedev.stackexchange.com", type: .forum, vendor: nil, trust: 3),
        Rule(suffix: "reddit.com", type: .community, vendor: nil, trust: 2),
        Rule(suffix: "news.ycombinator.com", type: .community, vendor: nil, trust: 2),
        Rule(suffix: "hn.algolia.com", type: .community, vendor: nil, trust: 2),
        Rule(suffix: "medium.com", type: .blog, vendor: nil, trust: 2),
        Rule(suffix: "dev.to", type: .blog, vendor: nil, trust: 2),
        Rule(suffix: "blogspot.com", type: .blog, vendor: nil, trust: 1),
        Rule(suffix: "wordpress.com", type: .blog, vendor: nil, trust: 1),
        Rule(suffix: "wikipedia.org", type: .article, vendor: nil, trust: 3),
    ]

    /// Download mirrors / aggregators that wrap other people's software: never preferred over the origin, reported as higher risk.
    static let suspiciousMirrors = ["softonic.com", "download.cnet.com", "filehippo.com", "uptodown.com", "malavida.com", "apkpure.com", "getintopc.com", "zippyshare.com",
                                    "4shared.com", "cracked", "crackwatch", "freedownloadmanager", "sourceforge.net/projects/*/files", "downloadly", "filecr.com", "softpedia.com"]

    /// `subject` = lower-cased words of the research goal (vendor keywords decide who is first-party for THIS question).
    static func classify(_ url: URL, subject: Set<String>, ownerOrRepoMatchesSubject: Bool = false) -> SourceClassification {
        let host = (url.host ?? "").lowercased()
        if suspiciousMirrors.contains(where: { host.contains($0.replacingOccurrences(of: "*", with: "")) && !$0.contains("/") }) {
            return SourceClassification(type: .unknown, official: .unknown, trust: 0, reason: "third-party download mirror / aggregator", suspicious: true)
        }
        // most specific suffix first
        let match = rules.filter { host == $0.suffix || host.hasSuffix("." + $0.suffix) }.max { $0.suffix.count < $1.suffix.count }
        guard let rule = match else {
            let seoish = ["best-", "top10", "-review", "vs-", "alternatives", "coupon", "free-download", "crack"].contains { host.contains($0) }
            return SourceClassification(type: .unknown, official: .unknown, trust: seoish ? 0 : 1, reason: seoish ? "looks like an affiliate / SEO site" : "unclassified site", suspicious: seoish)
        }
        var type = rule.type, trust = rule.trust
        var official: OfficialStatus = rule.type.isOfficial ? .official : .community
        if let vendor = rule.vendor {
            // First-party only for questions about that vendor; otherwise it is simply a reputable page.
            if subject.contains(vendor) || rule.type == .assetStore || rule.type == .officialProduct && ["polyhaven", "kenney", "ambientcg"].contains(vendor) { official = .official }
            else { official = .unknown; trust = min(trust, 3); if type.isOfficial { type = .article } }
        }
        if rule.type == .github {
            if ownerOrRepoMatchesSubject { type = .officialRepository; official = .official; trust = max(trust, 4) }
            else { official = .community }
        }
        if rule.type == .packageRegistry { official = .official }
        if rule.type == .assetStore || rule.type == .marketplace { official = rule.type == .assetStore ? .official : .community }
        return SourceClassification(type: type, official: official, trust: trust, reason: "\(rule.suffix) → \(type.label)")
    }

    /// Which source types may decide which kind of claim. Search snippets never decide price/licence/compatibility/security/availability.
    static func mayDecide(_ kind: ClaimKind, source: SourceType, official: OfficialStatus, method: RetrievalMethod) -> Bool {
        if method == .searchSnippet { return false }
        switch kind {
        case .price, .license, .availability, .accountRequirement, .downloadMethod, .compatibility:
            return official == .official || [.assetStore, .officialProduct, .officialPricing, .officialLicense, .officialRepository, .packageRegistry, .officialDocs].contains(source)
        case .apiBehavior, .deprecation:
            return [.officialDocs, .officialRepository, .packageRegistry, .officialProduct].contains(source)
        case .workaround, .maintenance, .style, .other:
            return true
        }
    }

    /// Words of the goal that name a vendor/product — used to decide who is first-party.
    static func subjectTerms(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 })
    }
}
