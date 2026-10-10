import Foundation

/// WHERE should this request go? Pure classification — it executes nothing and calls nothing.
///
///   1. deterministic command   (CommandRouter)
///   2. small local reply       (LocalConversation)
///   3. worker required         (coding/project/automation work — future workers, V0.3+)
///   4. reasoning required      (any other real request — future intelligence provider, V0.3)
///   5. unsupported             (nothing routable, e.g. punctuation only)
struct IntelligenceRouter: Sendable {
    /// Heuristic for "do real work on something": an action verb AND a technical/project noun.
    private static let workerVerbs: Set<String> = [
        "fix", "implement", "refactor", "build", "compile", "debug", "deploy", "install", "run", "create", "write",
        "update", "migrate", "optimize", "add", "remove", "rewrite", "patch", "test",
        "duzelt", "yaz", "olustur", "derle", "calistir", "ekle", "guncelle",
    ]
    private static let technicalNouns: Set<String> = [
        "code", "unity", "project", "bug", "bugs", "script", "scripts", "tests", "repo", "repository", "build", "multiplayer",
        "networking", "class", "function", "app", "error", "errors", "shader", "scene", "feature", "codebase", "kod", "proje", "hata",
    ]

    func route(_ raw: String) -> RouteDecision {
        let input = InputNormalizer.normalize(raw)
        let language = input.language

        if input.text.isEmpty && !input.addressedJarvis {
            return .unsupported(raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .noContent, language)
        }
        if let match = CommandRouter.match(input) { return .command(match.intent, match.language) }
        if let (reply, lang) = LocalConversation.match(input) { return .localResponse(reply, lang) }

        let words = Set(input.tokens)
        if !words.isDisjoint(with: Self.workerVerbs) && !words.isDisjoint(with: Self.technicalNouns) {
            return .workerRequired(prompt: raw, language)
        }
        return .reasoningRequired(prompt: raw, language)
    }
}
