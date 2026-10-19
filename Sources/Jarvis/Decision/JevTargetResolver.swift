import Foundation

// MARK: - The project registry hook of the Jev gate (V1.0 final integration; resolves JARVIS-V1JV-6)
//
// A remote classifier never names a project; JARVIS does. The sentence is looked at through the project registry the app already has (`KnownProject`: names and aliases): a project counts as named
// only when its name (or alias) appears in the sentence EXACTLY, optionally with one closed Turkish case suffix (`ProjectOpenResolver.nameMatches`) — never a prefix, never a fuzzy match.
// Exactly one project → `resolved`; several → `ambiguous` (the gate rejects; JARVIS asks); none → `unresolved` (the gate rejects). A near miss ("Hamamm") is a QUESTION elsewhere, never a target here.

enum JevTargetResolver {
    static func resolve(raw: String, projects: [KnownProject]) -> JevTargetResolution {
        let tokens = DecisionText.tokens(raw)
        guard !tokens.isEmpty, !projects.isEmpty else { return .unresolved }
        var hits: [String] = []
        for p in projects {
            let names = [p.name] + p.aliases
            let named = names.contains { name in
                let nameTokens = DecisionText.tokens(name)
                guard !nameTokens.isEmpty, nameTokens.count <= 4, tokens.count >= nameTokens.count else { return false }
                for start in 0...(tokens.count - nameTokens.count) {
                    let window = Array(tokens[start..<(start + nameTokens.count)])
                    if window == nameTokens || ProjectOpenResolver.nameMatches(spoken: window.joined(separator: " "), name: nameTokens.joined(separator: " ")) { return true }
                }
                return false
            }
            if named, !hits.contains(p.name) { hits.append(p.name) }
        }
        switch hits.count {
        case 0: return .unresolved
        case 1: return .resolved(hits[0])
        default: return .ambiguous(hits.sorted())
        }
    }
}
