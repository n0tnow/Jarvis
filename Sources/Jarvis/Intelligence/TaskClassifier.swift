import Foundation

/// Deterministic, explainable text → `TaskProfile` (English + Turkish). Conservative by design: anything that smells
/// technical is NOT lightweight, so the local model can never be handed development work by a classification miss.
enum TaskClassifier {
    private static func has(_ t: String, _ words: [String]) -> Bool { words.contains { t.contains($0) } }
    private static func matches(_ t: String, _ pattern: String) -> Bool { t.range(of: pattern, options: .regularExpression) != nil }

    static func profile(for prompt: String) -> TaskProfile {
        let raw = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = raw.lowercased()
        var p = TaskProfile()
        p.estimatedContextTokens = max(1, raw.count / 4)

        // --- signals ---
        let codeFence = raw.contains("```")
        let codeishLines = raw.split(separator: "\n").filter { l in
            let s = l.trimmingCharacters(in: .whitespaces)
            return s.hasSuffix(";") || s.hasSuffix("{") || s.hasSuffix("}") || s.hasPrefix("func ") || s.hasPrefix("def ") || s.hasPrefix("class ")
                || s.hasPrefix("public ") || s.hasPrefix("private ") || s.hasPrefix("import ") || s.hasPrefix("#include") || s.contains("=> ")
        }.count
        let fileRef = matches(t, #"\b[\w./-]+\.(swift|cs|py|js|ts|tsx|jsx|cpp|c|h|hpp|rs|go|java|kt|rb|php|sh|json|yml|yaml|toml|md)\b"#)
        let codeWords = has(t, ["bug", "compile", "compiler", "refactor", "implement", "function", "stack trace", "exception", "segfault", "null reference",
                                "nullreference", "syntax error", "build error", "write code", "write a script", "snippet", "regex", "sql query", "algorithm",
                                "hata ", "derle", "kod yaz", "kodu ", "fonksiyon", "düzelt", "duzelt", "betik", "script"])
        let testWords = has(t, ["unit test", "failing test", "test fails", "tests fail", "test failure", "xctest", "pytest", "jest", "write tests", "add tests",
                                "run the tests", "run tests", "test suite", "test coverage", "testi çalıştır", "testleri", "test yaz"])
        let modifyWords = has(t, ["edit the file", "modify the file", "change the file", "update the file", "apply the patch", "apply this patch", "patch the",
                                  "commit ", "git ", "rename the", "delete the file", "create a file", "add a file", "dosyayı değiştir", "dosyayi degistir",
                                  "dosyayı düzenle", "implement it in the repo", "in the repo", "in my repo", "repository"])
        let reviewWords = has(t, ["code review", "review this code", "review my code", "review the pr", "pull request", "review the diff", "kodu incele", "kod incele"])
        let debugWords = has(t, ["debug", "why does this crash", "why is this crashing", "crash", "doesn't work", "does not work", "not working", "broken", "çöküyor", "calismiyor", "çalışmıyor"])
        let archWords = has(t, ["architecture", "system design", "design pattern", "scalab", "microservice", "mimari", "tasarım deseni", "trade-off", "tradeoff"])
        let secWords = has(t, ["security", "vulnerab", "exploit", "penetration", "encrypt", "authentication flow", "oauth", "csrf", "xss", "injection", "güvenlik", "guvenlik", "zafiyet", "şifreleme"])
        let unity = has(t, ["unity", "monobehaviour", "gameobject", "scriptableobject", "prefab", "unity3d"])
        let multiplayer = has(t, ["multiplayer", "netcode", "photon", "mirror networking", "networked", "çok oyunculu", "cok oyunculu", "lag compensation", "rollback"])
        let researchWords = has(t, ["research", "compare ", "comparison", "sources", "literature", "pros and cons", "araştır", "arastir", "karşılaştır", "karsilastir"])
        let classifyWords = has(t, ["classify", "categorize", "categorise", "which category", "sınıflandır", "siniflandir", "label this", "is this spam", "sentiment of"])
        let extractWords = has(t, ["extract", "pull out the", "list the names", "çıkar", "cikar"])
        let formatWords = has(t, ["format as", "reformat", "convert to json", "convert this to", "as json", "to uppercase", "to lowercase", "biçimlendir"])
        let summarizeWords = has(t, ["summarize", "summarise", "tl;dr", "tldr", "in one sentence", "özetle", "ozetle", "özet "])
        let explainWords = has(t, ["explain", "how does", "how do ", "what is", "what are", "why does", "why is", "nasıl çalış", "nasil calis", "açıkla", "acikla", "nedir"])
        let wide = has(t, ["entire repo", "whole repo", "whole project", "entire project", "all files", "end to end", "end-to-end", "tüm proje", "bütün proje"])
        let infra = has(t, ["keep working", "run it and", "until it passes", "fix my", "build and run", "deploy"])
        let secretish = Redactor.containsSecret(raw)
        let sensitiveWords = has(t, ["password", "passcode", "private key", "secret key", "api key", "credential", "confidential", "ssn", "social security",
                                     "iban", "credit card", "medical record", "salary", "şifre", "sifre", "gizli", "kimlik no", "tc kimlik"])

        p.containsProjectCode = codeFence || codeishLines >= 3 || fileRef
        if unity { p.domainTags.insert("unity") }
        if multiplayer { p.domainTags.insert("multiplayer") }
        if secWords { p.domainTags.insert("security") }
        if t.contains("swift") || t.contains("swiftui") { p.domainTags.insert("swift") }
        if t.contains("c#") || t.contains("csharp") || t.contains(".cs") { p.domainTags.insert("csharp") }
        p.wantsStructuredOutput = t.contains("json") || t.contains("yaml")

        // --- privacy ---
        if secretish || sensitiveWords { p.privacy = .sensitive }

        // --- category + requirements (technical first: a technical signal always wins over a lightweight one) ---
        let technical = codeFence || codeWords || testWords || modifyWords || reviewWords || debugWords || fileRef || unity || multiplayer || codeishLines >= 3
        p.requiresTesting = testWords
        p.requiresRepositoryModification = modifyWords || infra
        p.requiresTechnicalReview = reviewWords || archWords || secWords
        p.requiresCoding = codeWords || codeFence || (debugWords && technical) || unity || multiplayer || testWords || modifyWords
        p.requiresTools = infra || modifyWords || testWords && has(t, ["run"])

        if secWords { p.category = .security }
        else if archWords { p.category = .architecture }
        else if testWords { p.category = .testing }
        else if modifyWords || infra { p.category = .repositoryModification }
        else if reviewWords { p.category = .review }
        else if debugWords && technical { p.category = .debugging }
        else if codeWords || codeFence || unity || multiplayer || fileRef || codeishLines >= 3 { p.category = .coding }
        else if researchWords { p.category = .research }
        else if classifyWords { p.category = .classification }
        else if extractWords { p.category = .extraction }
        else if formatWords { p.category = .formatting }
        else if summarizeWords { p.category = .summarization }
        else if explainWords { p.category = .explanation }
        else { p.category = .conversation }

        // --- complexity ---
        var score = 0
        if raw.count > 1500 { score += 2 } else if raw.count > 500 { score += 1 }
        if technical { score += 2 }
        if p.requiresRepositoryModification || p.requiresTesting { score += 1 }
        if archWords || secWords { score += 2 }
        if unity && multiplayer { score += 2 }
        if wide || infra { score += 2 }
        if p.category == .explanation || p.category == .research { score += 2 }       // knowledge work is never "trivial"
        if p.category == .summarization && raw.count > 800 { score += 1 }
        p.complexity = score >= 6 ? .critical : score >= 4 ? .complex : score >= 2 ? .moderate : raw.count > 160 ? .simple : .trivial
        if (archWords || secWords || wide) && p.complexity < .complex { p.complexity = .complex }
        p.requiresComplexReasoning = p.complexity >= .complex
        return p
    }
}

// MARK: - Local-model policy (hard rule, enforced in code — not in a prompt)

/// The local LLM is a LIGHTWEIGHT-task model only (DEC-024). This is the single gate: `ModelRouter` consults it for every
/// candidate and refuses explicit "Local" requests that fail it. Tests pin every forbidden class.
enum LocalModelPolicy {
    struct Verdict: Equatable, Sendable {
        var eligible: Bool
        var violations: [String]
    }

    /// Approximate input budget a 4B local model is trusted with (tokens).
    static let maxContextTokens = 3000
    static let forbiddenCategories: Set<TaskCategory> = [.coding, .testing, .review, .debugging, .repositoryModification, .architecture, .security]
    static let forbiddenDomains: Set<String> = ["unity", "multiplayer", "security", "csharp"]

    static func evaluate(_ p: TaskProfile) -> Verdict {
        var v: [String] = []
        if p.requiresCoding { v.append("requiresCoding") }
        if p.requiresTesting { v.append("requiresTesting") }
        if p.requiresRepositoryModification { v.append("requiresRepositoryModification") }
        if p.requiresTechnicalReview { v.append("requiresTechnicalReview") }
        if p.requiresComplexReasoning { v.append("requiresComplexReasoning") }
        if p.requiresTools { v.append("requiresTools") }
        if forbiddenCategories.contains(p.category) { v.append("category:\(p.category.rawValue)") }
        for d in p.domainTags.intersection(forbiddenDomains).sorted() { v.append("domain:\(d)") }
        if p.complexity > .simple { v.append("complexity:\(p.complexity)") }
        if p.estimatedContextTokens > maxContextTokens { v.append("context>\(maxContextTokens)") }
        if p.containsProjectCode { v.append("containsProjectCode") }
        if p.isDevelopment && !v.contains(where: { $0.hasPrefix("category:") || $0.hasPrefix("requires") }) { v.append("development") }
        return Verdict(eligible: v.isEmpty, violations: v)
    }
}
