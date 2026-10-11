import Foundation

/// The private workspace OpenCode runs in. OpenCode is a coding agent whose defaults ALLOW bash/edit, so JARVIS runs it
/// in an empty directory with a project `opencode.json` that rejects/denies every tool (docs/OPENCODE_RESEARCH.md):
///  - `"*": "ask"` — in headless `run` a permission request is auto-rejected (observed; undocumented → canary-tested),
///  - explicit `deny` for edit / web / outside-directory / sub-agents / skills / questions / lsp / doom-loop.
/// `bash` is deliberately NOT denied outright: denying it makes the Zen free tier answer 403 ("only usable from within OpenCode").
enum OpenCodeWorkspace {
    static let configJSON = """
    {"permission":{"*":"ask","edit":"deny","webfetch":"deny","websearch":"deny","external_directory":"deny","task":"deny","skill":"deny","doom_loop":"deny","question":"deny","lsp":"deny"},"share":"disabled","autoupdate":false}
    """

    /// Extra environment for OpenCode (on top of the standard allowlist): no self-update, no downloads, no foreign agent configs.
    static let environment: [String: String] = [
        "OPENCODE_DISABLE_AUTOUPDATE": "1", "OPENCODE_DISABLE_LSP_DOWNLOAD": "1",
        "OPENCODE_DISABLE_CLAUDE_CODE": "1", "OPENCODE_DISABLE_DEFAULT_PLUGINS": "1",
    ]

    /// Creates/refreshes `<providerWorkspace>/opencode` containing only the restrictive config. Returns its path.
    @discardableResult
    static func prepare(under providerWorkspace: String) throws -> String {
        let dir = (providerWorkspace as NSString).appendingPathComponent("opencode")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = (dir as NSString).appendingPathComponent("opencode.json")
        let data = Data(configJSON.utf8)
        if (try? Data(contentsOf: URL(fileURLWithPath: file))) != data { try data.write(to: URL(fileURLWithPath: file), options: .atomic) }
        return dir
    }
}

/// `opencode run --pure --format json -m <model> [-s <session>]`, prompt on stdin. Only a verified FREE-pool model can be
/// turned into a spec (`make`), so nothing priced or unverified can ever be launched through this path (DEC-022).
struct OpenCodeSpec: CLIProviderSpec {
    let id = ProviderID.openCode
    let modelID: String                   // "opencode/<id>"

    /// The ONLY way to obtain a spec: refuses anything that is not a current member of the verified free pool.
    static func make(for model: ModelRecord, now: Date = Date()) -> OpenCodeSpec? {
        guard model.engine == .openCode, model.provider == "opencode",
              model.isFreePoolMember, OpenCodeModelRegistry.isVerificationFresh(model, now: now) else { return nil }
        return OpenCodeSpec(modelID: model.id)
    }

    func arguments(sessionID: String?, newSessionID: String, workingDirectory: String) -> [String] {
        var args = ["run", "--pure", "--format", "json", "-m", modelID]
        if let sessionID { args += ["-s", sessionID] }
        return args
    }

    func stdinPrompt(for request: IntelligenceRequest) -> String {
        guard request.sessionID == nil else { return request.prompt }
        var parts = ["[Instructions] " + JarvisInstruction.text]
        if let pre = ContextBuilder.preface(from: request.history, excluding: request.prompt) { parts.append(pre) }
        parts.append("[Request]\n" + request.prompt)
        return parts.joined(separator: "\n\n")
    }

    func makeParser() -> ProviderLineParser { OpenCodeEventParser() }
    func chosenSessionID(newSessionID: String) -> String? { nil }
}

// MARK: - Parser

/// `opencode run --format json` (schema from observation — docs/OPENCODE_RESEARCH.md): `step_start`, `text`, `tool_use`,
/// `step_finish{reason,tokens}`, `error`. Text arrives per part (message-level, like Codex).
final class OpenCodeEventParser: ProviderLineParser {
    private let id = ProviderID.openCode
    private var sessionSent = false
    private var texts = 0
    private var finished = false
    private var failureSent = false
    private var inputTokens = 0, outputTokens = 0, sawTokens = false
    private(set) var malformedLines = 0
    private var validEvents = 0
    private(set) var toolAttempts: [String] = []

    private func object(_ line: Data) -> [String: Any]? {
        guard line.first == UInt8(ascii: "{") else { return nil }
        return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    func parse(line: Data) -> [ProviderStreamEvent] {
        guard let o = object(line) else {
            if !line.isEmpty { malformedLines += 1 }
            return []
        }
        validEvents += 1
        var out: [ProviderStreamEvent] = []
        if !sessionSent, let sid = o["sessionID"] as? String, ProviderErrorClassifier.isSafeSessionID(sid) {
            sessionSent = true; out.append(.session(sid))
        }
        let part = o["part"] as? [String: Any]
        switch o["type"] as? String {
        case "text":
            if let text = part?["text"] as? String, !text.isEmpty { out.append(.text(texts == 0 ? text : "\n\n" + text)); texts += 1 }

        case "tool_use":
            let tool = (part?["tool"] as? String) ?? "unknown"
            toolAttempts.append(tool)
            out.append(.toolAttempt(tool))

        case "step_finish":
            if let t = part?["tokens"] as? [String: Any] {
                inputTokens += (t["input"] as? NSNumber)?.intValue ?? 0
                outputTokens += (t["output"] as? NSNumber)?.intValue ?? 0
                sawTokens = true
            }
            let reason = part?["reason"] as? String
            if reason == "stop" || reason == "length" {
                if sawTokens { out.append(.usage(input: inputTokens, output: outputTokens)) }
                finished = true
                out.append(.finished)
            }

        case "error":
            if !failureSent {
                failureSent = true
                out.append(.failure(Self.map(error: o["error"] as? [String: Any], id: id)))
            }

        default: break
        }
        return out
    }

    func finalFailure(exitCode: Int32, stderrTail: String) -> ProviderError? {
        if finished || failureSent { return nil }
        if validEvents == 0 && exitCode == 0 { return .malformedOutput(id) }
        if !toolAttempts.isEmpty && texts == 0 { return .unavailable(id, "the model asked for tools instead of answering") }
        if texts > 0 && exitCode == 0 { return .malformedOutput(id) }
        if let c = ProviderErrorClassifier.classify(stderrTail, provider: id) { return c }
        return .processFailed(id, exitCode: exitCode)
    }

    static func map(error: [String: Any]?, id: ProviderID) -> ProviderError {
        let data = error?["data"] as? [String: Any]
        let status = (data?["statusCode"] as? NSNumber)?.intValue
        let message = (data?["message"] as? String) ?? (error?["name"] as? String) ?? ""
        let lower = message.lowercased()
        if lower.contains("only be used from within opencode") { return .unavailable(id, "free tier refused the request") }
        switch status {
        case 401: return .authenticationRequired(id)
        case 403: return .unavailable(id, "access refused")
        case 429: return .rateLimited(id, resetsAt: nil)
        case .some(let s) where s >= 500: return .unavailable(id, "service error")
        default: break
        }
        return ProviderErrorClassifier.classify(message, provider: id) ?? .processFailed(id, exitCode: 1)
    }
}
