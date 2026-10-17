import Foundation

/// Speech recognisers mishear unfamiliar proper nouns ("Safari" → "Sofany", "Saffar", "So funny"). Inside an ACTION context (an explicit open/launch verb, a name that is
/// not an installed application) this maps the heard word to the one installed application it could be — by sound shape, from the STRUCTURED list of applications that
/// exist on this Mac, never from a list of known mis-hearings. It is deliberately conservative: any ambiguity (two candidates) or a weak match returns nil, and the
/// reply says what was understood so a wrong guess is visible and correctable. Opening an application is reversible and low-risk; nothing else uses this.
enum PhoneticAppResolver {
    /// Consonant skeleton: letters only, folded; the first letter always stays, later vowels (and y/h/w) are dropped, runs collapse. "safari" → "sfr", "sofunny" → "sfn".
    static func skeleton(_ raw: String) -> String {
        let folded = ComputerText.fold(raw).filter { $0.isLetter }
        var out = ""
        let weak: Set<Character> = ["a", "e", "i", "o", "u", "y", "h", "w"]
        for (i, c) in folded.enumerated() {
            if i > 0, weak.contains(c) { continue }
            if out.last == c { continue }
            out.append(c)
        }
        return out
    }

    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
            prev = cur
        }
        return prev[b.count]
    }

    /// The single candidate whose sound shape matches `heard`, or nil. Requires: same first letter, a skeleton of at least 3 consonants on both sides, and a skeleton
    /// distance of at most 1 (≤ 2 for skeletons of 6+). Two candidates within range ⇒ nil (never guesses).
    static func resolve(heard: String, candidates: [AppTarget]) -> AppTarget? {
        let hs = skeleton(heard)
        guard hs.count >= 3, ComputerText.fold(heard).filter({ $0.isLetter }).count >= 4 else { return nil }
        var hits: [AppTarget] = []
        for c in candidates {
            let cs = skeleton(c.display)
            guard cs.count >= 3, cs.first == hs.first else { continue }
            let d = distance(Array(hs), Array(cs))
            let allowed = max(hs.count, cs.count) >= 6 ? 2 : 1
            // the ending of the name carries the identity: "sfn" vs "sfr" differ only in the last consonant, which a Turkish case suffix or a mumbled vowel can cause
            guard d <= allowed, hs.prefix(2) == cs.prefix(2) else { continue }
            if !hits.contains(where: { $0.bundleID == c.bundleID }) { hits.append(c) }
        }
        guard hits.count == 1 else { return nil }
        var found = hits[0]
        found.heardAs = heard
        return found
    }
}
