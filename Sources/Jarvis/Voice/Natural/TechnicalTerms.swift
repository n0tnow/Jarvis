import Foundation

/// Bounded post-processing of a FINAL transcript for the product's own technical vocabulary (V0.8, mixed Turkish/English speech).
///
/// Recognisers write «play mode», «edit mode», «box collider», «unity'deki» in ways the rest of JARVIS (and the user, on screen) does not expect. This only
/// restores the canonical spelling/spacing/casing of a FIXED list of unambiguous terms. It never adds, removes or reorders words, never guesses a mis-heard
/// word (no fuzzy snapping: «Bucks color» stays «Bucks color»), keeps Turkish letters and suffixes («Unity'deki»), and is idempotent.
enum TechnicalTerms {
    /// Lower-cased token sequences → canonical text. Longest sequence first.
    private static let compounds: [(tokens: [String], canonical: String)] = [
        (["play", "mode"], "Play Mode"), (["playmode"], "PlayMode"), (["edit", "mode"], "EditMode"), (["editmode"], "EditMode"),
        (["game", "object"], "GameObject"), (["game", "objects"], "GameObjects"), (["gameobject"], "GameObject"), (["gameobjects"], "GameObjects"),
        (["box", "collider"], "BoxCollider"), (["box", "colliders"], "BoxColliders"), (["boxcollider"], "BoxCollider"),
        (["rigid", "body"], "Rigidbody"), (["rigidbody"], "Rigidbody"),
        (["opencode"], "OpenCode"),
        (["unity"], "Unity"), (["claude"], "Claude"), (["codex"], "Codex"), (["prefab"], "prefab"), (["prefabs"], "prefabs"),
    ]

    /// Splits «Unity'deki» into ("unity", "'deki"), «testleri,» into ("testleri", ","): the core word and whatever is glued to it.
    private static func split(_ raw: String) -> (lead: String, core: String, tail: String) {
        var chars = Array(raw)
        var lead = "", tail = ""
        while let f = chars.first, !(f.isLetter || f.isNumber) { lead.append(f); chars.removeFirst() }
        if let apostrophe = chars.firstIndex(where: { $0 == "'" || $0 == "’" }) { tail = String(chars[apostrophe...]); chars = Array(chars[..<apostrophe]) }
        while let l = chars.last, !(l.isLetter || l.isNumber) { tail = String(l) + tail; chars.removeLast() }
        return (lead, String(chars), tail)
    }

    static func normalize(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var out: [String] = []
        var i = 0
        while i < words.count {
            var matched = false
            for (tokens, canonical) in compounds.sorted(by: { $0.tokens.count > $1.tokens.count }) where i + tokens.count <= words.count {
                // all words but the last must be bare words (a comma between «play» and «mode» means two different things)
                let parts = words[i..<(i + tokens.count)].map(split)
                guard zip(parts, tokens).allSatisfy({ $0.core.lowercased(with: Locale(identifier: "en")) == $1 }) else { continue }
                if tokens.count > 1, parts.dropLast().contains(where: { !$0.tail.isEmpty || !$0.lead.isEmpty && $0.lead != parts.first?.lead }) { continue }
                let first = parts.first!, last = parts.last!
                // a single word that is already correct, or the common word «code»/«unity» used as a plain English noun, is left exactly as spoken only if it matches
                out.append(first.lead + canonical + last.tail)
                i += tokens.count
                matched = true
                break
            }
            if !matched { out.append(words[i]); i += 1 }
        }
        return out.joined(separator: " ")
    }
}
