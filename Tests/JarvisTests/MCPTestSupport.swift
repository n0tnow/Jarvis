import Foundation
@testable import Jarvis

/// An MCP server running inside the test process: the JARVIS fixture's protocol handler behind the same transport interface a real process uses.
final class InProcessMCPTransport: MCPTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var server: MCPFixtureServer
    private var continuation: AsyncStream<Data>.Continuation?
    private var running = false
    /// `silent`: never answers (timeout tests). `dieAfterCalls`: the "process" ends after N tool calls. `failStart`: start() throws.
    var silent = false, failStart = false
    var dieAfterCalls: Int?
    private(set) var toolCalls = 0
    private(set) var sent: [String] = []

    init(variant: MCPFixtureServer.Variant = .normal, version: String = "1.0.0") { server = MCPFixtureServer(variant: variant, serverVersion: version) }

    func start() throws -> AsyncStream<Data> {
        if failStart { throw MCPError.startFailed("fixture refused to start") }
        lock.lock(); running = true; lock.unlock()
        return AsyncStream<Data> { cont in self.lock.lock(); self.continuation = cont; self.lock.unlock() }
    }
    func send(_ data: Data) {
        guard let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines) else { return }
        lock.lock(); sent.append(line); let isCall = line.contains("tools/call") || line.contains("tools\\/call"); if isCall { toolCalls += 1 }
        let silent = self.silent, die = dieAfterCalls.map { toolCalls > $0 } ?? false
        var out: String? = nil
        if !silent, !die { out = server.handle(line) }
        let cont = continuation
        lock.unlock()
        if die { stopNow(); return }
        if let out { cont?.yield(Data(out.utf8)) }
    }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    var processIdentifier: pid_t { Int32.max }
    var stderrTail: String { "" }
    func cancel() async { stopNow() }
    func killNow() { stopNow() }
    private func stopNow() { lock.lock(); running = false; let c = continuation; continuation = nil; lock.unlock(); c?.finish() }
}

enum MCPTestSupport {
    static func tools(_ v: MCPFixtureServer.Variant) -> [MCPToolSchema] {
        MCPFixtureServer.toolList(v).map { t in
            let params = ((t["inputSchema"] as? [String: Any])?["properties"] as? [String: [String: String]] ?? [:]).mapValues { $0["type"] ?? "string" }
            let desc = (t["description"] as? String) ?? ""
            let name = t["name"] as! String
            return MCPToolSchema(name: name, description: String(desc.prefix(240)), parameters: params, risk: MCPToolClassifier.risk(name: name, description: desc, parameters: params), injectionNotes: UntrustedContent.scan(desc).count)
        }
    }

    static func wrappers() -> [MCPWrapper] {
        [MCPWrapper(capability: "echoText", tool: "echo", summary: "Echo text", parameters: ["text": "string"], envelope: .read),
         MCPWrapper(capability: "inspectFixture", tool: "inspectFixture", summary: "Inspect the fixture scene", parameters: [:], envelope: .read),
         MCPWrapper(capability: "createFixtureObject", tool: "createFixtureObject", summary: "Create an object", parameters: ["name": "string"], maxStringLength: 64, envelope: .projectWrite),
         MCPWrapper(capability: "getFixtureState", tool: "getFixtureState", summary: "Read the fixture state", parameters: [:], envelope: .read)]
    }

    static func record(id: String = "jarvis-fixture", variant: MCPFixtureServer.Variant = .normal, executable: String = "/usr/bin/true", status: MCPStatus = .discovered, fixture: Bool = true) -> MCPServerRecord {
        let t = tools(variant)
        var d = MCPDiscoveryRecord(name: id, domain: "fixture", sourceURL: "https://example.invalid/\(id)", repository: nil, publisher: "JARVIS", license: "MIT", version: "1.0.0", lastRelease: Date(), lastPush: Date(), stars: nil,
                                   installMethod: "built in", runtime: "swift", networkRequirement: "none", credentialRequirement: "none", filesystemRequirement: "none", processRequirement: "none", declaredTools: t.map(\.name), declaredResources: [], declaredPrompts: [],
                                   knownRisks: [], price: "free", apiRequirements: "none", macOS: "yes", appleSilicon: "yes", overlap: [], expectedBenefit: "test fixture", evidenceFetchedAt: Date(), sourceKind: "JARVIS fixture")
        d.findings = []
        return MCPServerRecord(id: id, name: id, domain: "fixture", status: status, version: "1.0.0", executableHash: nil, launch: MCPLaunch(executable: executable, arguments: ["--mcp-fixture-server", "--variant", variant.rawValue], idleSeconds: 30), tools: t, wrappers: wrappers().filter { w in t.contains { $0.name == w.tool } },
                               envelope: MCPToolClassifier.envelope(for: t), allowedProjects: [], network: "none", credentialRequirement: "none", health: .available, benchmark: nil, discovery: d, provenance: "test fixture", isFixture: fixture)
    }
}
