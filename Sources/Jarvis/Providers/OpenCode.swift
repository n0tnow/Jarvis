import Foundation

/// The private workspace OpenCode runs in. OpenCode is a coding agent whose defaults ALLOW tools, so JARVIS runs it in an
/// empty directory whose project config rejects/denies every tool (docs/OPENCODE_RESEARCH.md). Two generations, two formats:
///  - classic (1.18.x) `opencode.json`:   `"*":"ask"` (auto-rejected headless) + explicit denies,
///  - v2 (1.19+)       `opencode.jsonc`:  ordered `permissions` rules — `* ask`, then deny `execute` (Code Mode, which could
///    make network requests that the other rules did not cover), `edit`, `webfetch`, `websearch`.
/// In BOTH, `bash`/`shell` and `read` are deliberately NOT denied outright: denying them makes the Zen free tier answer 403
/// ("only usable from within OpenCode"); `ask` is rejected in non-interactive runs instead (REAL TESTED on both generations).
enum OpenCodeWorkspace {
    static let classicConfigJSON = """
    {"permission":{"*":"ask","edit":"deny","webfetch":"deny","websearch":"deny","external_directory":"deny","task":"deny","skill":"deny","doom_loop":"deny","question":"deny","lsp":"deny"},"share":"disabled","autoupdate":false}
    """
    static let v2ConfigJSONC = """
    {"permissions":[{"action":"*","resource":"*","effect":"ask"},{"action":"execute","resource":"*","effect":"deny"},{"action":"edit","resource":"*","effect":"deny"},{"action":"webfetch","resource":"*","effect":"deny"},{"action":"websearch","resource":"*","effect":"deny"}]}
    """
    /// Kept for callers that only know the classic name.
    static var configJSON: String { classicConfigJSON }

    static func fileName(for flavor: OpenCodeCapabilities.RunFlavor) -> String { flavor == .standalone ? "opencode.jsonc" : "opencode.json" }
    static func contents(for flavor: OpenCodeCapabilities.RunFlavor) -> String { flavor == .standalone ? v2ConfigJSONC : classicConfigJSON }

    /// Extra environment for OpenCode (on top of the standard allowlist): no self-update, no downloads, no foreign agent configs.
    static let environment: [String: String] = [
        "OPENCODE_DISABLE_AUTOUPDATE": "1", "OPENCODE_DISABLE_LSP_DOWNLOAD": "1",
        "OPENCODE_DISABLE_CLAUDE_CODE": "1", "OPENCODE_DISABLE_DEFAULT_PLUGINS": "1",
    ]

    /// Creates/refreshes `<providerWorkspace>/opencode` containing ONLY the restrictive config of the given generation
    /// (a config of the other generation is removed so nothing ambiguous remains). Returns its path.
    @discardableResult
    static func prepare(under providerWorkspace: String, flavor: OpenCodeCapabilities.RunFlavor = .classic) throws -> String {
        let dir = (providerWorkspace as NSString).appendingPathComponent("opencode")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let keep = fileName(for: flavor)
        for other in ["opencode.json", "opencode.jsonc"] where other != keep { try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(other)) }
        let file = (dir as NSString).appendingPathComponent(keep)
        let data = Data(contents(for: flavor).utf8)
        if FileManager.default.contents(atPath: file) != data { try data.write(to: URL(fileURLWithPath: file), options: .atomic) }
        return dir
    }
}

/// What the installed OpenCode CLI can do, read from its own `--help` output (the CLI changed between 1.18.x "classic" and
/// 1.19.x "v2"): classic = `models --verbose` (prices) + `run --pure`; v2 = documented `api model.list` (prices as `cost[]`)
/// + `run --standalone` (a private server, never the shared background service). JARVIS only runs a CLI generation it can
/// read prices from — otherwise free routing is disabled, never guessed.
struct OpenCodeCapabilities: Equatable, Sendable {
    enum RunFlavor: Equatable, Sendable { case classic, standalone, unsupported }
    enum CatalogSource: Equatable, Sendable { case modelsVerbose, apiModelList, none }
    var runFlavor: RunFlavor
    var catalogSource: CatalogSource
    var supportsJSONFormat: Bool
    var supportsModelFlag: Bool

    var canListPrices: Bool { catalogSource != .none }
    static let verifiedClassic = OpenCodeCapabilities(runFlavor: .classic, catalogSource: .modelsVerbose, supportsJSONFormat: true, supportsModelFlag: true)
    static let verifiedV2 = OpenCodeCapabilities(runFlavor: .standalone, catalogSource: .apiModelList, supportsJSONFormat: true, supportsModelFlag: true)

    static func parse(modelsHelp: String, runHelp: String, apiHelp: String = "") -> OpenCodeCapabilities {
        let flavor: RunFlavor = runHelp.contains("--pure") ? .classic : runHelp.contains("--standalone") ? .standalone : .unsupported
        let source: CatalogSource = modelsHelp.contains("--verbose") ? .modelsVerbose
            : (flavor == .standalone && apiHelp.contains("operation") ? .apiModelList : .none)
        return OpenCodeCapabilities(runFlavor: flavor, catalogSource: source, supportsJSONFormat: runHelp.contains("--format"),
                                    supportsModelFlag: runHelp.contains("--model") || runHelp.contains("-m,"))
    }

    var isSupported: Bool { canListPrices && runFlavor != .unsupported && supportsJSONFormat && supportsModelFlag }

    func unsupportedReason(version: String?) -> String? {
        if isSupported { return nil }
        if !canListPrices { return "OpenCode \(version ?? "?") exposes no readable model prices — free routing disabled" }
        return "OpenCode \(version ?? "?") has an unsupported `run` interface — free routing disabled"
    }
}

/// `opencode run --pure --format json -m <model> [-s <session>]`, prompt on stdin. Only a verified FREE-pool model can be
/// turned into a spec (`make`), so nothing priced or unverified can ever be launched through this path (DEC-022).
struct OpenCodeSpec: CLIProviderSpec {
    let id = ProviderID.openCode
    let modelID: String                   // "opencode/<id>"
    var flavor: OpenCodeCapabilities.RunFlavor = .classic

    /// The ONLY way to obtain a spec: refuses anything that is not a current member of the verified free pool.
    static func make(for model: ModelRecord, flavor: OpenCodeCapabilities.RunFlavor = .classic, now: Date = Date()) -> OpenCodeSpec? {
        guard model.engine == .openCode, model.provider == "opencode", flavor != .unsupported,
              model.isFreePoolMember, OpenCodeModelRegistry.isVerificationFresh(model, now: now) else { return nil }
        return OpenCodeSpec(modelID: model.id, flavor: flavor)
    }

    func arguments(sessionID: String?, newSessionID: String, workingDirectory: String) -> [String] {
        // `--standalone` = a private in-process server (never the shared background service of the 1.19 CLI generation).
        var args = ["run", flavor == .standalone ? "--standalone" : "--pure", "--format", "json", "-m", modelID]
        if let sessionID { args += ["-s", sessionID] }
        return args
    }

    func stdinPrompt(for request: IntelligenceRequest) -> String {
        guard request.sessionID == nil else { return request.providerPrompt }
        var parts = ["[Instructions] " + JarvisInstruction.text]
        if let pre = ContextBuilder.preface(from: request.history, excluding: request.prompt) { parts.append(pre) }
        parts.append("[Request]\n" + request.providerPrompt)
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

    /// OpenCode 1.19 (v2) sometimes ends the JSON stream after the text part without a `step_finish` (observed, non-deterministic):
    /// exit code 0 + at least one text part + no error event is a complete answer.
    func completedOnCleanExit(exitCode: Int32) -> Bool { exitCode == 0 && texts > 0 && !failureSent }

    func finalFailure(exitCode: Int32, stderrTail: String) -> ProviderError? {
        if finished || failureSent { return nil }
        if validEvents == 0 && exitCode == 0 { return .malformedOutput(id) }
        if !toolAttempts.isEmpty && texts == 0 { return .unavailable(id, "the model asked for tools instead of answering") }
        if completedOnCleanExit(exitCode: exitCode) { return nil }
        if let c = ProviderErrorClassifier.classify(stderrTail, provider: id) { return c }
        return .processFailed(id, exitCode: exitCode)
    }

    /// Error events: classic = `{"error":{"name":…,"data":{"statusCode":N,"message":…}}}`; v2 = `{"error":{"type":"provider.…","status":N,"message":…}}`.
    static func map(error: [String: Any]?, id: ProviderID) -> ProviderError {
        let data = error?["data"] as? [String: Any]
        let status = (data?["statusCode"] as? NSNumber)?.intValue ?? (error?["status"] as? NSNumber)?.intValue
        let message = (data?["message"] as? String) ?? (error?["message"] as? String) ?? (error?["name"] as? String) ?? ""
        let lower = message.lowercased()
        if lower.contains("only be used from within opencode") { return .unavailable(id, "free tier refused the request") }
        if lower.contains("has been deprecated") || lower.contains("model not found") { return .unavailable(id, OpenCodeModelRegistry.removedErrorText) }
        switch status {
        case 401: return .authenticationRequired(id)
        case 403: return .unavailable(id, "access refused")
        case 404, 410: return .unavailable(id, OpenCodeModelRegistry.removedErrorText)       // "Model x has been deprecated" while still listed
        case 429: return .rateLimited(id, resetsAt: nil)
        case .some(let s) where s >= 500: return .unavailable(id, "service error")
        case 400 where lower.contains("unavailable"): return .unavailable(id, "model unavailable")
        default: break
        }
        return ProviderErrorClassifier.classify(message, provider: id) ?? .processFailed(id, exitCode: 1)
    }
}
