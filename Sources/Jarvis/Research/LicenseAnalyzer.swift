import Foundation

/// Licence verification (V0.9). Deterministic and conservative: this is NOT a lawyer. It recognises a fixed set of well-known licences
/// from a structured identifier or from the licence's own text, maps them to what a game project cares about (commercial use, modification,
/// redistribution, attribution), and sends everything ambiguous, restrictive or unrecognised to the user as NEEDS REVIEW.
/// Unknown licence ⇒ UNKNOWN, never "safe".
struct LicenseInput: Sendable {
    var sourceID: UUID
    var text: String
    var structuredID: String?           // e.g. GitHub's license.spdx_id
    var official: Bool                  // the licence comes from the maintainer / marketplace / publisher itself
    var retrievedAt: Date
    var field: String?
}

enum LicenseAnalyzer {
    struct Profile: Sendable {
        var id: String
        var state: LicenseState
        var commercial: Tri
        var modification: Tri
        var redistribution: Tri
        var attribution: Tri
        var review: Bool
        var note: String?
    }

    private static func p(_ id: String, _ state: LicenseState, c: Tri = .yes, m: Tri = .yes, r: Tri = .yes, a: Tri = .no, review: Bool = false, note: String? = nil) -> Profile {
        Profile(id: id, state: state, commercial: c, modification: m, redistribution: r, attribution: a, review: review, note: note)
    }

    static let profiles: [String: Profile] = {
        var d: [String: Profile] = [:]
        for x in [
            p("CC0-1.0", .permissive, note: "public-domain dedication"),
            p("Unlicense", .permissive), p("0BSD", .permissive), p("WTFPL", .permissive),
            p("MIT", .permissive, a: .yes, note: "copyright notice must be kept"), p("MIT-0", .permissive), p("ISC", .permissive, a: .yes),
            p("BSD-2-Clause", .permissive, a: .yes), p("BSD-3-Clause", .permissive, a: .yes), p("Apache-2.0", .permissive, a: .yes, note: "notice and NOTICE file must be kept"),
            p("Zlib", .permissive), p("BSL-1.0", .permissive), p("Python-2.0", .permissive, a: .yes), p("OFL-1.1", .permissive, a: .yes, note: "font licence: the font itself may not be sold alone"),
            p("CC-BY-4.0", .attributionRequired, a: .yes), p("CC-BY-3.0", .attributionRequired, a: .yes), p("CC-BY-2.0", .attributionRequired, a: .yes),
            p("CC-BY-SA-4.0", .copyleft, a: .yes, review: true, note: "share-alike: derivative works must use the same licence"),
            p("CC-BY-SA-3.0", .copyleft, a: .yes, review: true, note: "share-alike: derivative works must use the same licence"),
            p("CC-BY-NC-4.0", .nonCommercial, c: .no, a: .yes, review: true), p("CC-BY-NC-3.0", .nonCommercial, c: .no, a: .yes, review: true),
            p("CC-BY-NC-SA-4.0", .nonCommercial, c: .no, a: .yes, review: true), p("CC-BY-NC-SA-3.0", .nonCommercial, c: .no, a: .yes, review: true),
            p("CC-BY-ND-4.0", .noDerivatives, m: .no, a: .yes, review: true), p("CC-BY-NC-ND-4.0", .noDerivatives, c: .no, m: .no, a: .yes, review: true),
            p("GPL-2.0", .copyleft, review: true, note: "strong copyleft: affects how the game may be distributed"), p("GPL-3.0", .copyleft, review: true, note: "strong copyleft: affects how the game may be distributed"),
            p("AGPL-3.0", .copyleft, review: true, note: "network copyleft"), p("LGPL-3.0", .copyleft, review: true, note: "weak copyleft"), p("LGPL-2.1", .copyleft, review: true, note: "weak copyleft"),
            p("MPL-2.0", .copyleft, a: .yes, review: true, note: "file-level copyleft"), p("EPL-2.0", .copyleft, review: true),
            p("UNITY-ASSET-STORE-EULA", .marketplaceEULA, c: .yes, m: .yes, r: .no, a: .no, review: true, note: "may be used in end products; the raw asset may not be redistributed or resold; the listing may carry its own terms"),
            p("CUSTOM-NONCOMMERCIAL", .nonCommercial, c: .no, review: true, note: "the text restricts commercial use"),
            p("CUSTOM-RESTRICTED", .customRestricted, c: .unknown, m: .unknown, r: .unknown, a: .unknown, review: true, note: "custom or all-rights-reserved terms"),
        ] { d[x.id.lowercased()] = x }
        return d
    }()

    /// SPDX-ish identifier → canonical key (handles `GPL-3.0-only`, `GPL-3.0+`, `Apache 2.0`, `cc-by-4.0` …).
    static func canonical(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "_", with: "-")
        for suf in ["-only", "-or-later", "+"] where s.hasSuffix(suf) { s = String(s.dropLast(suf.count)) }
        let aliases: [String: String] = ["apache-2": "apache-2.0", "apache2": "apache-2.0", "apache-license-2.0": "apache-2.0", "mit-license": "mit", "bsd": "bsd-3-clause", "gpl-3": "gpl-3.0", "gpl-2": "gpl-2.0", "gplv3": "gpl-3.0", "gplv2": "gpl-2.0",
                                         "cc0": "cc0-1.0", "cc-0": "cc0-1.0", "cc0-1": "cc0-1.0", "cc-by-4": "cc-by-4.0", "cc-by": "cc-by-4.0", "cc-by-sa": "cc-by-sa-4.0", "cc-by-nc": "cc-by-nc-4.0", "lgpl-3": "lgpl-3.0", "agpl-3": "agpl-3.0",
                                         "mpl-2": "mpl-2.0", "ofl": "ofl-1.1", "sil-ofl-1.1": "ofl-1.1", "public-domain": "cc0-1.0", "the-unlicense": "unlicense"]
        s = aliases[s] ?? s
        return profiles[s] != nil ? s : nil
    }

    // MARK: Detection in text

    private static let textRules: [(pattern: String, id: String)] = [
        ("Attribution[- ]NonCommercial[- ]NoDerivs|CC[- ]BY[- ]NC[- ]ND", "cc-by-nc-nd-4.0"),
        ("Attribution[- ]NonCommercial[- ]ShareAlike|CC[- ]BY[- ]NC[- ]SA", "cc-by-nc-sa-4.0"),
        ("Attribution[- ]NonCommercial|CC[- ]BY[- ]NC", "cc-by-nc-4.0"),
        ("Attribution[- ]NoDerivs|CC[- ]BY[- ]ND", "cc-by-nd-4.0"),
        ("Attribution[- ]ShareAlike|CC[- ]BY[- ]SA", "cc-by-sa-4.0"),
        ("Creative Commons Zero|CC0|CC-0|Public Domain Dedication", "cc0-1.0"),
        ("Creative Commons Attribution 4\\.0|CC[- ]BY[- ]4\\.0|licensed under (?:a )?Creative Commons Attribution", "cc-by-4.0"),
        ("Creative Commons Attribution 3\\.0|CC[- ]BY[- ]3\\.0", "cc-by-3.0"),
        ("Standard Unity Asset Store EULA|Unity Asset Store End User License Agreement|Asset Store EULA", "unity-asset-store-eula"),
        ("GNU Affero General Public License", "agpl-3.0"),
        ("GNU Lesser General Public License", "lgpl-3.0"),
        ("GNU General Public License,? (?:Version )?3|GPL-?v?3", "gpl-3.0"),
        ("GNU General Public License,? (?:Version )?2|GPL-?v?2", "gpl-2.0"),
        ("Mozilla Public License,? (?:Version |v)?2", "mpl-2.0"),
        ("Apache License,? Version 2\\.0|Licensed under the Apache License", "apache-2.0"),
        ("Permission is hereby granted, free of charge, to any person obtaining a copy|\\bMIT License\\b", "mit"),
        ("Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following (?:two|three) conditions", "bsd-3-clause"),
        ("\\bBSD[- ]3[- ]Clause\\b", "bsd-3-clause"), ("\\bBSD[- ]2[- ]Clause\\b", "bsd-2-clause"),
        ("This is free and unencumbered software released into the public domain|The Unlicense", "unlicense"),
        ("SIL Open Font License", "ofl-1.1"),
    ]
    private static let restrictive: [String] = ["personal use only", "non-commercial use only", "noncommercial use only", "not for commercial", "no commercial use", "for educational purposes only", "not allowed for commercial", "cannot be used commercially", "non commercial"]
    private static let allRights = ["all rights reserved"]

    /// (canonical id, excerpt) pairs found in `text`, strongest-first and without duplicates.
    static func detect(in text: String) -> [(id: String, excerpt: String)] {
        var found: [(String, String)] = []
        var consumed = Set<String>()
        for (pattern, id) in textRules where !consumed.contains(id) {
            if let ex = Grounding.excerpt(in: text, matching: pattern) {
                // a more specific CC variant already matched → ignore the generic one that occurs inside it
                if id.hasPrefix("cc-by-4.0") && consumed.contains(where: { $0.hasPrefix("cc-by-") && $0 != "cc-by-4.0" }) { continue }
                found.append((id, ex)); consumed.insert(id)
            }
        }
        let lower = text.lowercased()
        if found.isEmpty || !found.contains(where: { profiles[$0.0]?.commercial == .no }) {
            if let r = restrictive.first(where: { lower.contains($0) }), let ex = Grounding.excerpt(in: text, matching: NSRegularExpression.escapedPattern(for: r)) { found.append(("custom-noncommercial", ex)) }
        }
        if found.isEmpty, let r = allRights.first(where: { lower.contains($0) }), let ex = Grounding.excerpt(in: text, matching: NSRegularExpression.escapedPattern(for: r)) { found.append(("custom-restricted", ex)) }
        return found
    }

    // MARK: Assessment

    static func assess(_ inputs: [LicenseInput]) -> LicenseAssessment {
        guard !inputs.isEmpty else { return .unknown }
        struct Hit { var id: String; var evidence: EvidenceRef; var official: Bool; var structured: Bool }
        var hits: [Hit] = []
        for input in inputs {
            if let raw = input.structuredID, let id = canonical(raw) {
                hits.append(Hit(id: id, evidence: EvidenceRef(sourceID: input.sourceID, excerpt: String(raw.prefix(80)), field: input.field ?? "license.id", retrievedAt: input.retrievedAt), official: input.official, structured: true))
            } else if let raw = input.structuredID, !raw.isEmpty, raw.uppercased() != "NOASSERTION", raw.lowercased() != "other" {
                // an identifier we do not recognise is a custom licence — never "safe"
                hits.append(Hit(id: "custom-restricted", evidence: EvidenceRef(sourceID: input.sourceID, excerpt: String(raw.prefix(80)), field: input.field ?? "license.id", retrievedAt: input.retrievedAt), official: input.official, structured: true))
            }
            for d in detect(in: input.text).prefix(3) {
                hits.append(Hit(id: d.id, evidence: EvidenceRef(sourceID: input.sourceID, excerpt: d.excerpt, field: input.field ?? "text", retrievedAt: input.retrievedAt), official: input.official, structured: false))
            }
        }
        guard !hits.isEmpty else {
            var u = LicenseAssessment.unknown
            u.note = "the sources read do not state a licence — unknown is NOT safe"
            return u
        }
        // Official evidence outranks the rest; structured outranks free text.
        let ranked = hits.sorted { ($0.official ? 2 : 0) + ($0.structured ? 1 : 0) > ($1.official ? 2 : 0) + ($1.structured ? 1 : 0) }
        let top = ranked[0]
        guard let prof = profiles[top.id] else { return .unknown }
        // Contradiction: two OFFICIAL hits whose consequences differ (commercial use or state).
        let officialHits = ranked.filter { $0.official }
        let distinct = Dictionary(grouping: officialHits, by: { $0.id })
        if distinct.count > 1 {
            let states = Set(distinct.keys.compactMap { profiles[$0]?.state })
            let commercial = Set(distinct.keys.compactMap { profiles[$0]?.commercial })
            if states.count > 1 || commercial.count > 1 {
                return LicenseAssessment(state: .contradictory, identifier: distinct.keys.sorted().joined(separator: " vs "), commercialUse: .unknown, modification: .unknown, redistribution: .unknown, attribution: .unknown,
                                         evidence: officialHits.map(\.evidence), needsReview: true, note: "official sources name different licences — read them before using the asset")
            }
        }
        var review = prof.review
        var note = prof.note
        if !top.official {
            review = true
            note = ((note.map { $0 + "; " }) ?? "") + "not stated by an official source (maintainer, marketplace or publisher) — verify before relying on it"
        }
        let ev = ranked.filter { $0.id == top.id }.prefix(3).map(\.evidence)
        let spdx = profiles[top.id]?.id
        return LicenseAssessment(state: prof.state, identifier: spdx, commercialUse: prof.commercial, modification: prof.modification, redistribution: prof.redistribution, attribution: prof.attribution,
                                 evidence: Array(ev), needsReview: review, note: note)
    }
}
