import Foundation

/// WHERE should this request go? Pure classification — it executes nothing and calls nothing.
///
///   1. deterministic command   (CommandRouter)
///   2. small local reply       (LocalConversation)
///   3. worker required         (coding/project/automation work — future workers, V0.3+)
///   4. reasoning required      (any other real request — future intelligence provider, V0.3)
///   5. unsupported             (nothing routable, e.g. punctuation only)
struct IntelligenceRouter: Sendable {
    /// Heuristic for "do real work on something": an action verb AND a technical/project noun, with no
    /// everyday-writing noun ("write an email about the project" is NOT a coding job).
    private static let workerVerbs: Set<String> = [
        "fix", "implement", "refactor", "build", "compile", "debug", "deploy", "install", "run", "create", "write",
        "update", "migrate", "optimize", "add", "remove", "rewrite", "patch", "test",
    ]
    private static let technicalNouns: Set<String> = [
        "code", "unity", "project", "bug", "bugs", "script", "scripts", "test", "tests", "repo", "repository", "multiplayer",
        "networking", "class", "function", "app", "error", "errors", "shader", "scene", "feature", "codebase", "compiler",
    ]
    private static let everydayNouns: Set<String> = ["email", "mail", "story", "poem", "essay", "letter", "calendar", "meeting", "song", "speech", "joke", "message"]
    /// Turkish is heavily suffixed ("hatayı düzelt", "projeyi derle"): match by folded prefix.
    private static let turkishVerbPrefixes = ["duzelt", "derle", "calistir", "olustur", "guncelle", "ekle", "yazdir"]
    private static let turkishNounPrefixes = ["kod", "proje", "hata", "script", "oyun", "uygulama"]

    private static func isWorkerRequest(_ tokens: [String]) -> Bool {
        let words = Set(tokens)
        guard words.isDisjoint(with: everydayNouns) else { return false }
        let verb = !words.isDisjoint(with: workerVerbs) || tokens.contains { t in turkishVerbPrefixes.contains { t.hasPrefix($0) } }
        let noun = !words.isDisjoint(with: technicalNouns) || tokens.contains { t in turkishNounPrefixes.contains { t.hasPrefix($0) } }
        return verb && noun
    }

    func route(_ raw: String) -> RouteDecision {
        let input = InputNormalizer.normalize(raw)
        let language = input.language

        if input.text.isEmpty && !input.addressedJarvis {
            return .unsupported(raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .noContent, language)
        }
        if let match = CommandRouter.match(input) { return .command(match.intent, match.language) }
        if let (reply, lang) = LocalConversation.match(input) { return .localResponse(reply, lang) }

        if Self.isWorkerRequest(input.tokens) { return .workerRequired(prompt: raw, language) }
        return .reasoningRequired(prompt: raw, language)
    }
}
