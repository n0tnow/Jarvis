import Foundation

// MARK: - A minimal MCP client over stdio (V0.14, DEC-226)
//
// Newline-delimited JSON-RPC 2.0 to ONE server process JARVIS started (ManagedProcess: no shell, tree-killing cancel). Everything the server returns is untrusted data: sizes are
// bounded, tool metadata is sanitised, and nothing here can approve, grant or install. The client does not decide what may be called — the registry (envelope + wrappers) does.

enum MCPError: Error, Equatable, CustomStringConvertible {
    case startFailed(String), timeout(String), exited(String), protocolError(String), server(String), tooLarge
    var description: String {
        switch self {
        case .startFailed(let s): "could not start: \(s)"
        case .timeout(let m): "no answer to \(m) in time"
        case .exited(let s): "the server exited\(s.isEmpty ? "" : " (\(s))")"
        case .protocolError(let s): "protocol error: \(s)"
        case .server(let s): "the server reported an error: \(s)"
        case .tooLarge: "the answer was larger than the allowed size"
        }
    }
}

/// What the client needs from a server process. A real server is a `ManagedProcess` (no shell, tree-killing cancel); unit tests substitute an in-process fixture.
protocol MCPTransporting: AnyObject, Sendable {
    func start() throws -> AsyncStream<Data>
    func send(_ data: Data)
    var isRunning: Bool { get }
    var processIdentifier: pid_t { get }
    var stderrTail: String { get }
    func cancel() async
    func killNow()
}

final class ProcessTransport: MCPTransporting, @unchecked Sendable {
    let process: ManagedProcess
    init(_ p: ManagedProcess) { process = p }
    func start() throws -> AsyncStream<Data> { try process.start(stdin: nil, keepStdinOpen: true) }
    func send(_ data: Data) { process.send(data) }
    var isRunning: Bool { process.isRunning }
    var processIdentifier: pid_t { process.processIdentifier }
    var stderrTail: String { process.stderrTail }
    func cancel() async { await process.cancel() }
    func killNow() { process.killTreeNow() }
}

struct MCPRawTool: Equatable, Sendable { var name: String; var description: String; var parameters: [String: String]; var injectionNotes: Int }
struct MCPCallResult: Equatable, Sendable { var text: String; var isError: Bool; var truncated: Bool; var injectionNotes: Int }

final class MCPConnection: @unchecked Sendable {
    static let maxLine = 512 * 1024
    static let maxResultText = 64 * 1024

    private let process: any MCPTransporting
    private let lock = NSLock()
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextID = 0
    private var reader: Task<Void, Never>?
    private var closed = false
    private(set) var serverName = "", serverVersion = ""

    init(transport: any MCPTransporting) { self.process = transport }
    convenience init(process: ManagedProcess) { self.init(transport: ProcessTransport(process)) }
    var processIdentifier: pid_t { process.processIdentifier }
    var isRunning: Bool { process.isRunning }
    var stderrTail: String { OutputSanitizer.sanitize(String(process.stderrTail.suffix(400))) }

    func start() throws {
        let lines: AsyncStream<Data>
        do { lines = try process.start() } catch { throw MCPError.startFailed(String(describing: error)) }
        reader = Task.detached { [weak self] in
            for await line in lines {
                guard let self else { return }
                if line.count > Self.maxLine { continue }
                guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let id = obj["id"] as? Int else { continue }
                if let err = obj["error"] as? [String: Any] { self.finish(id, .failure(MCPError.server(OutputSanitizer.sanitize(String((err["message"] as? String ?? "error").prefix(200)))))) }
                else { self.finish(id, .success(obj["result"] as? [String: Any] ?? [:])) }
            }
            self?.failAll(MCPError.exited(self?.stderrTail ?? ""))
        }
    }

    private func finish(_ id: Int, _ r: Result<[String: Any], Error>) {
        lock.lock(); let c = pending.removeValue(forKey: id); lock.unlock()
        c?.resume(with: r)
    }
    private func failAll(_ e: Error) {
        lock.lock(); let all = pending; pending = [:]; closed = true; lock.unlock()
        for (_, c) in all { c.resume(throwing: e) }
    }

    func request(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 15) async throws -> [String: Any] {
        lock.lock(); if closed { lock.unlock(); throw MCPError.exited(stderrTail) }
        nextID += 1; let id = nextID; lock.unlock()
        let body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { throw MCPError.protocolError("unencodable request") }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
            lock.lock(); pending[id] = cont; lock.unlock()
            process.send(data + Data("\n".utf8))
            Task.detached { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.finish(id, .failure(MCPError.timeout(method)))
            }
        }
    }

    func notify(_ method: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method]) else { return }
        process.send(data + Data("\n".utf8))
    }

    func initialize(timeout: TimeInterval = 20) async throws {
        let r = try await request("initialize", ["protocolVersion": "2024-11-05", "capabilities": [String: Any](), "clientInfo": ["name": "JARVIS", "version": "0.14"]], timeout: timeout)
        let info = r["serverInfo"] as? [String: Any]
        serverName = OutputSanitizer.sanitize(String((info?["name"] as? String ?? "").prefix(80)))
        serverVersion = OutputSanitizer.sanitize(String((info?["version"] as? String ?? "").prefix(40)))
        notify("notifications/initialized")
    }

    /// Tool metadata is UNTRUSTED: names are validated, descriptions sanitised and bounded, instruction-shaped text is counted (never forwarded as an instruction).
    func listTools(timeout: TimeInterval = 15) async throws -> [MCPRawTool] {
        let r = try await request("tools/list", timeout: timeout)
        guard let arr = r["tools"] as? [[String: Any]] else { throw MCPError.protocolError("tools/list had no tools array") }
        return arr.prefix(64).compactMap { t in
            guard let name = t["name"] as? String, name.range(of: "^[A-Za-z0-9_.\\-]{1,64}$", options: .regularExpression) != nil else { return nil }
            let desc = (t["description"] as? String) ?? ""
            var params: [String: String] = [:]
            if let schema = t["inputSchema"] as? [String: Any], let props = schema["properties"] as? [String: Any] {
                for (k, v) in props.prefix(16) where k.range(of: "^[A-Za-z0-9_.\\-]{1,40}$", options: .regularExpression) != nil { params[k] = ((v as? [String: Any])?["type"] as? String) ?? "any" }
            }
            return MCPRawTool(name: name, description: Self.clean(desc, 240), parameters: params, injectionNotes: UntrustedContent.scan(desc).count)
        }
    }

    func listNames(_ method: String, key: String, timeout: TimeInterval = 8) async -> [String] {
        guard let r = try? await request(method, timeout: timeout), let arr = r[key] as? [[String: Any]] else { return [] }
        return arr.prefix(32).compactMap { ($0["name"] as? String).map { Self.clean($0, 60) } }
    }

    func call(_ tool: String, _ arguments: [String: Any], timeout: TimeInterval = 20) async throws -> MCPCallResult {
        let r = try await request("tools/call", ["name": tool, "arguments": arguments], timeout: timeout)
        let parts = (r["content"] as? [[String: Any]]) ?? []
        var text = parts.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        let truncated = text.utf8.count > Self.maxResultText
        if truncated { text = String(text.prefix(Self.maxResultText)) }
        return MCPCallResult(text: Self.clean(text, Self.maxResultText), isError: (r["isError"] as? Bool) ?? false, truncated: truncated, injectionNotes: UntrustedContent.scan(text).count)
    }

    func close() async {
        reader?.cancel()
        failAll(MCPError.exited("closed"))
        await process.cancel()
    }
    func killNow() { process.killNow() }

    static func clean(_ s: String, _ n: Int) -> String { OutputSanitizer.sanitize(String(s.prefix(n))).replacingOccurrences(of: "\u{0}", with: "") }
}
