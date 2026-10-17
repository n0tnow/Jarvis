import Foundation

/// The short instruction every provider receives. It must be explicit that there are NO tools: without it Claude wrote
/// fake "I'll run that command" text even with tools disabled (verified, docs/PROVIDER_RESEARCH.md).
enum JarvisInstruction {
    /// The small trusted product context every conversation engine gets (V1.0 stabilisation fix 2): the engine is NOT the product. In this mode the ENGINE has no tools, but JARVIS does — and only JARVIS knows what is on, installed or stored.
    static let text = "You are the language engine inside JARVIS, a macOS assistant; JARVIS is the product, you are not. In this mode YOU have NO tools, so never claim or imply that you performed an action. JARVIS itself can work with files in the user's chosen project, use the screen, web, Unity, voice and memory, but only JARVIS knows what is currently enabled, installed or stored: never state what JARVIS can or cannot do, see, read or remember. For such questions say JARVIS answers them from its own state. Be concise, in the user's language."
}

/// Bounded conversation context for providers that start a fresh session (first turn, after a provider switch,
/// or when a resume fails). Only provider-answered exchanges are included — never deterministic-command chatter,
/// activity logs or credentials — and the total is capped.
enum ContextBuilder {
    static let maxMessages = 8
    static let maxCharacters = 6000

    static func preface(from history: [ConversationMessage], excluding currentPrompt: String) -> String? {
        // Pairs (user → jarvis reply produced by a provider), newest last.
        var pairs: [(String, String)] = []
        var i = 0
        let msgs = history
        while i + 1 < msgs.count {
            if msgs[i].role == .user, msgs[i + 1].role == .jarvis, msgs[i + 1].route == .reasoning,
               msgs[i + 1].status == .complete, !msgs[i + 1].content.isEmpty, msgs[i + 1].tone == .normal {
                pairs.append((msgs[i].content, msgs[i + 1].content)); i += 2
            } else { i += 1 }
        }
        var chosen: [(String, String)] = []
        var budget = maxCharacters
        for pair in pairs.reversed() {
            if chosen.count * 2 >= maxMessages { break }
            let cost = pair.0.count + pair.1.count
            if cost > budget {
                if chosen.isEmpty {   // keep at least a truncated last exchange
                    chosen.append((String(pair.0.prefix(budget / 2)), String(pair.1.prefix(budget / 2)))); break
                }
                break
            }
            budget -= cost
            chosen.append(pair)
        }
        guard !chosen.isEmpty else { return nil }
        let lines = chosen.reversed().map { "User: \($0.0)\nAssistant: \($0.1)" }.joined(separator: "\n\n")
        return "Conversation so far (for context):\n\n\(lines)"
    }
}

/// How one provider CLI is invoked (arguments, stdin prompt, parser). Pure → unit-tested; no process handling here.
protocol CLIProviderSpec: Sendable {
    var id: ProviderID { get }
    /// Argument array (never a shell string). `newSessionID` is used by providers that let the caller choose the id.
    func arguments(sessionID: String?, newSessionID: String, workingDirectory: String) -> [String]
    func stdinPrompt(for request: IntelligenceRequest) -> String
    func makeParser() -> ProviderLineParser
    /// A session id JARVIS chooses itself for a new conversation (Claude), or nil if the CLI assigns it (Codex).
    func chosenSessionID(newSessionID: String) -> String?
}

struct ClaudeCodeSpec: CLIProviderSpec {
    let id = ProviderID.claudeCode

    func arguments(sessionID: String?, newSessionID: String, workingDirectory: String) -> [String] {
        var args = [
            "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--tools", "",                     // conversation only: no built-in tools at all
            "--safe-mode",                     // ignore CLAUDE.md, hooks, MCP, plugins (auth still works)
            "--permission-prompts", "none",
            "--append-system-prompt", JarvisInstruction.text,
        ]
        args += sessionID.map { ["--resume", $0] } ?? ["--session-id", newSessionID]
        return args
    }

    func stdinPrompt(for request: IntelligenceRequest) -> String {
        if request.sessionID == nil, let pre = ContextBuilder.preface(from: request.history, excluding: request.prompt) {
            return pre + "\n\n---\n\n" + request.providerPrompt
        }
        return request.providerPrompt
    }

    func makeParser() -> ProviderLineParser { ClaudeStreamParser() }
    func chosenSessionID(newSessionID: String) -> String? { newSessionID }
}

struct CodexSpec: CLIProviderSpec {
    let id = ProviderID.codex

    /// Documented `--disable` switches that remove every tool Codex could run (verified: no command_execution).
    static let disabledFeatures = ["shell_tool", "browser_use", "browser_use_external", "computer_use", "plugins", "hooks", "apps", "memories"]

    func arguments(sessionID: String?, newSessionID: String, workingDirectory: String) -> [String] {
        var args: [String]
        if let sessionID {
            // `exec resume` has no -s/-C: restriction goes through -c, working dir through the process cwd.
            args = ["exec", "resume", sessionID, "--json", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules", "-c", "sandbox_mode=\"read-only\""]
        } else {
            args = ["exec", "--json", "--skip-git-repo-check", "-s", "read-only", "-C", workingDirectory, "--ignore-user-config", "--ignore-rules"]
        }
        for f in Self.disabledFeatures { args += ["--disable", f] }
        args.append("-")        // prompt from stdin
        return args
    }

    func stdinPrompt(for request: IntelligenceRequest) -> String {
        // Codex `exec` has no system-prompt flag: prepend the short instruction on the FIRST turn of a session.
        if request.sessionID == nil {
            var parts = ["[Instructions] " + JarvisInstruction.text]
            if let pre = ContextBuilder.preface(from: request.history, excluding: request.prompt) { parts.append(pre) }
            parts.append("[Request]\n" + request.providerPrompt)
            return parts.joined(separator: "\n\n")
        }
        return request.providerPrompt
    }

    func makeParser() -> ProviderLineParser { CodexEventParser() }
    func chosenSessionID(newSessionID: String) -> String? { nil }
}
