import Foundation

/// What a provider's stdout means, independent of the CLI's wire format.
enum ProviderStreamEvent: Equatable, Sendable {
    case session(String)
    case text(String)
    case rateLimited(resetsAt: Date?)
    case failure(ProviderError)
    case usage(input: Int?, output: Int?)
    case toolAttempt(String)
    case finished
}

/// Pure, line-at-a-time parser for a provider's structured stdout (formats verified against the installed CLIs).
protocol ProviderLineParser: AnyObject {
    func parse(line: Data) -> [ProviderStreamEvent]
    /// Called when the process has exited; returns a failure if the run ended without a clean finish.
    func finalFailure(exitCode: Int32, stderrTail: String) -> ProviderError?
    var malformedLines: Int { get }
    /// Some CLIs (OpenCode v2) do not always emit a terminal event. True if a clean exit (code 0) with the output seen so
    /// far — and no error — is a complete answer. Default: no (a terminal event is required).
    func completedOnCleanExit(exitCode: Int32) -> Bool
}

extension ProviderLineParser {
    func completedOnCleanExit(exitCode: Int32) -> Bool { false }
}

enum ProviderErrorClassifier {
    private static func has(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { text.range(of: $0, options: [.regularExpression]) != nil }
    }

    /// Heuristics over free-text error messages (vendor wording varies; codes are used first when available).
    /// Status numbers are matched as standalone tokens (not inside UUIDs, `file.js:401:12`, versions): a UUID or a stack-trace `file.js:401:12` must not look like an auth error,
    /// and session-loss is checked first because its message contains a UUID.
    static func classify(_ text: String, provider id: ProviderID) -> ProviderError? {
        let t = text.lowercased()
        if has(t, ["no conversation found", "session not found", "thread not found", "no such session", "could not find session", "unknown session"]) { return .sessionLost(id) }
        if has(t, ["unrecognized flag", "unknown option", "unknown argument", "unrecognised"]) { return .unavailable(id, "unsupported CLI version") }
        if has(t, ["not logged in", "please run /login", "(?<![\\w:./-])401(?![\\w:-])", "unauthorized", "authentication", "invalid api key", "sign in", "log in again"]) { return .authenticationRequired(id) }
        if has(t, ["usage limit", "limit reached", "rate limit", "rate_limit", "(?<![\\w:./-])429(?![\\w:-])", "too many requests", "\\bquota\\b"]) { return .rateLimited(id, resetsAt: nil) }
        if has(t, ["network", "enotfound", "econnrefused", "offline", "unable to connect", "failed to lookup", "\\bdns\\b", "internet connection"]) { return .networkUnavailable(id) }
        if has(t, ["overloaded", "(?<![\\w:./-])50[023](?![\\w:-])", "server error", "service unavailable"]) { return .unavailable(id, "service") }
        return nil
    }

    /// Provider-reported session ids go into argv later (`--resume <id>`): accept only plain tokens, never anything that
    /// could parse as a flag or contain spaces.
    static func isSafeSessionID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
    }
}

private func json(_ line: Data) -> [String: Any]? {
    guard !line.isEmpty, line.first == UInt8(ascii: "{") else { return nil }
    return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
}

// MARK: - Claude Code: `claude -p --output-format stream-json --verbose --include-partial-messages`

final class ClaudeStreamParser: ProviderLineParser {
    private let id = ProviderID.claudeCode
    private var sawDeltas = false
    private var finished = false
    private var failureSent = false
    private(set) var malformedLines = 0
    private var validEvents = 0

    func parse(line: Data) -> [ProviderStreamEvent] {
        guard let o = json(line) else {
            if !line.isEmpty { malformedLines += 1 }
            return []
        }
        validEvents += 1
        switch o["type"] as? String {
        case "system":
            if o["subtype"] as? String == "init", let sid = o["session_id"] as? String, ProviderErrorClassifier.isSafeSessionID(sid) { return [.session(sid)] }
            return []

        case "stream_event":
            guard let ev = o["event"] as? [String: Any], ev["type"] as? String == "content_block_delta",
                  let delta = ev["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, !text.isEmpty else { return [] }
            sawDeltas = true
            return [.text(text)]

        case "assistant":
            // Carries an `error` code when the request itself failed (e.g. "authentication_failed").
            if let code = o["error"] as? String, !failureSent {
                failureSent = true
                return [.failure(Self.map(code: code, text: nil, id: id))]
            }
            return []

        case "rate_limit_event":
            if let info = o["rate_limit_info"] as? [String: Any], let status = info["status"] as? String,
               !status.hasPrefix("allowed") {
                let reset = (info["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
                return [.rateLimited(resetsAt: reset)]
            }
            return []

        case "result":
            if o["is_error"] as? Bool == true {
                guard !failureSent else { return [] }
                failureSent = true
                return [.failure(Self.map(code: nil, text: o["result"] as? String, id: id))]
            }
            var out: [ProviderStreamEvent] = []
            if !sawDeltas, let text = o["result"] as? String, !text.isEmpty { out.append(.text(text)) }   // no partials → use the final text
            finished = true
            out.append(.finished)
            return out

        default:
            return []
        }
    }

    func finalFailure(exitCode: Int32, stderrTail: String) -> ProviderError? {
        if finished || failureSent { return nil }
        if validEvents == 0 && exitCode == 0 { return .malformedOutput(id) }
        if let c = ProviderErrorClassifier.classify(stderrTail, provider: id) { return c }
        return .processFailed(id, exitCode: exitCode)
    }

    static func map(code: String?, text: String?, id: ProviderID) -> ProviderError {
        switch code {
        case "authentication_failed", "oauth_org_not_allowed", "cloud_credential_error": return .authenticationRequired(id)
        case "rate_limit": return .rateLimited(id, resetsAt: nil)
        case "overloaded", "server_error", "billing_error", "account_on_hold", "model_not_found": return .unavailable(id, code ?? "")
        default: break
        }
        if let text, let c = ProviderErrorClassifier.classify(text, provider: id) { return c }
        return .processFailed(id, exitCode: 1)
    }
}

// MARK: - Codex: `codex exec --json`

final class CodexEventParser: ProviderLineParser {
    private let id = ProviderID.codex
    private var messages = 0
    private var finished = false
    private var failureSent = false
    private var lastError: String?
    private(set) var malformedLines = 0
    private var validEvents = 0

    func parse(line: Data) -> [ProviderStreamEvent] {
        guard let o = json(line) else {
            if !line.isEmpty { malformedLines += 1 }
            return []
        }
        validEvents += 1
        switch o["type"] as? String {
        case "thread.started":
            if let tid = o["thread_id"] as? String, ProviderErrorClassifier.isSafeSessionID(tid) { return [.session(tid)] }
            return []

        case "item.completed", "item.updated":
            // `exec --json` delivers each agent message COMPLETE (no token deltas — see docs/PROVIDER_RESEARCH.md).
            guard (o["type"] as? String) == "item.completed", let item = o["item"] as? [String: Any],
                  item["type"] as? String == "agent_message", let text = item["text"] as? String, !text.isEmpty else { return [] }
            defer { messages += 1 }
            return [.text(messages == 0 ? text : "\n\n" + text)]

        case "turn.completed":
            finished = true
            return [.finished]

        case "turn.failed":
            guard !failureSent else { return [] }
            failureSent = true
            let msg = ((o["error"] as? [String: Any])?["message"] as? String) ?? lastError ?? ""
            return [.failure(ProviderErrorClassifier.classify(msg, provider: id) ?? .processFailed(id, exitCode: 1))]

        case "error":
            // Codex emits transient "Reconnecting… n/5" errors before giving up; only the last one matters.
            if let m = o["message"] as? String { lastError = m }
            return []

        default:
            return []   // reasoning, command_execution, turn.started, … are not conversation content
        }
    }

    func finalFailure(exitCode: Int32, stderrTail: String) -> ProviderError? {
        if finished || failureSent { return nil }
        if validEvents == 0 && exitCode == 0 { return .malformedOutput(id) }
        for text in [lastError, stderrTail] {
            if let text, let c = ProviderErrorClassifier.classify(text, provider: id) { return c }
        }
        return .processFailed(id, exitCode: exitCode)
    }
}
