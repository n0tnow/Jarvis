import Foundation

/// Builds the environment for provider child processes — an ALLOWLIST, so credentials/billing switches can never leak in.
///
/// SUBSCRIPTION-FIRST (DEC-017): the user's shell may export API keys or cloud-provider switches. If a provider CLI
/// saw them it could silently switch to metered billing. They are never forwarded: only the variables below are.
enum ProviderEnvironment {
    /// Forwarded when present (identity, locale, config locations the user chose, proxy/CA settings for networking).
    static let allowed: Set<String> = [
        "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES",
        "CLAUDE_CONFIG_DIR", "CODEX_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME",
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy",
        "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS",
    ]

    private static let pathVariables: Set<String> = ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS"]

    /// Names that must NEVER reach a provider (kept here only so tests/verification can assert the scrub).
    static let forbidden: Set<String> = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
        "OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_ORG_ID", "OPENAI_PROJECT", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN",
        "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_PROFILE", "GOOGLE_APPLICATION_CREDENTIALS",
        // V0.3.1: OpenCode can pick up many provider keys / its server password from the environment — none may reach it.
        "OPENCODE_API_KEY", "OPENCODE_SERVER_PASSWORD", "OPENCODE_SERVER_USERNAME", "OPENROUTER_API_KEY", "GROQ_API_KEY", "MISTRAL_API_KEY",
        "GEMINI_API_KEY", "GOOGLE_API_KEY", "XAI_API_KEY", "DEEPSEEK_API_KEY", "HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "GITHUB_TOKEN",
    ]

    static func make(base: [String: String] = ProcessInfo.processInfo.environment, extraPath: [String] = []) -> [String: String] {
        var env: [String: String] = [:]
        for (key, value) in base where allowed.contains(key) && !forbidden.contains(key) {
            // A stray relative/nonexistent config location could redirect where the vendor CLI looks for its auth files.
            if pathVariables.contains(key) {
                var isDir: ObjCBool = false
                guard value.hasPrefix("/"), FileManager.default.fileExists(atPath: value, isDirectory: &isDir), isDir.boolValue else { continue }
            }
            env[key] = value
        }
        let defaultPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = (base["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>(), path: [String] = []
        for dir in extraPath + existing + defaultPath where !dir.isEmpty && seen.insert(dir).inserted { path.append(dir) }
        env["PATH"] = path.joined(separator: ":")
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        return env
    }
}
