import Foundation

// MARK: - Benchmarking an MCP candidate for its intended role (V0.14, DEC-228)
//
// Runs INSIDE the bounded sandbox with no credentials and no project. Measures success, correctness, latency (cold and warm), resident memory, determinism, the permissions the used
// tools imply, whether the network was needed, failure quality and cleanup. A benchmark is evidence about THIS version in THIS sandbox — it is never a statement of safety.

struct MCPBenchmarkCase: Sendable {
    var name: String
    /// First tool name present on the server wins (so one case covers servers that name the same thing differently).
    var tools: [String]
    var arguments: [String: AnySendable] = [:]
    var expect: @Sendable (String) -> Bool
    var readOnly = true
    /// The PASS condition is a refusal (an error or an `isError` answer): used for confinement checks (“a path outside the root must be refused”).
    var expectsFailure = false
    /// `{{WORK}}` inside a text argument is replaced by the sandbox work directory.
    func args(work: String) -> [String: Any] { arguments.mapValues { v in (v.value as? String).map { $0.replacingOccurrences(of: "{{WORK}}", with: work) } ?? v.value } }
}

struct AnySendable: @unchecked Sendable { var value: Any; init(_ v: Any) { value = v } }

struct MCPBenchmarkSpec: Sendable {
    var domain: String
    var cases: [MCPBenchmarkCase]
    /// Cases that write something (a harmless object in the sandbox) are skipped for tools that need unknown arguments.
    static let fixture = MCPBenchmarkSpec(domain: "fixture", cases: [
        MCPBenchmarkCase(name: "echo returns its input", tools: ["echo"], arguments: ["text": AnySendable("jarvis-benchmark")], expect: { $0.contains("jarvis-benchmark") }),
        MCPBenchmarkCase(name: "inspect the scene (read-only)", tools: ["inspectFixture"], expect: { $0.contains("scene") }),
        MCPBenchmarkCase(name: "create an object", tools: ["createFixtureObject"], arguments: ["name": AnySendable("bench-cube")], expect: { $0.contains("created") }, readOnly: false),
        MCPBenchmarkCase(name: "read it back", tools: ["getFixtureState"], expect: { $0.contains("bench-cube") })
    ])

    /// Domain starting points for real candidates: read-only inspection with no required arguments. Write cases need arguments only a person who read the server's schema can choose.
    static func domain(_ name: String) -> MCPBenchmarkSpec {
        let reads: [String]
        switch MemoryText.fold(name) {
        case let d where d.contains("blender") || d.contains("3d"): reads = ["get_scene_info", "get_scene", "scene_info", "list_objects", "get_objects", "get_blender_version", "get_info"]
        case let d where d.contains("audio") || d.contains("sound") || d.contains("speech"): reads = ["list_voices", "get_voices", "list_models", "get_info", "list_sounds", "list_tools"]
        case let d where d.contains("anim") || d.contains("rig"): reads = ["list_animations", "get_animation_info", "get_rig_info", "list_clips", "get_info"]
        case let d where d.contains("design") || d.contains("figma") || d.contains("ui"): reads = ["get_design_context", "get_file", "list_components", "get_metadata", "get_info"]
        default: reads = ["get_info", "list_tools", "get_status", "status", "version"]
        }
        return MCPBenchmarkSpec(domain: name, cases: reads.map { r in MCPBenchmarkCase(name: "read-only: \(r)", tools: [r], expect: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) })
    }
}

enum MCPBenchmarkRunner {
    @MainActor
    static func run(registry: MCPRegistry, serverID: String, spec: MCPBenchmarkSpec, allowNetwork: Bool = false, useSeatbelt: Bool = true, extraArguments: [String] = [], timeout: TimeInterval = 25) async -> MCPBenchmarkResult? {
        guard var s = registry.server(serverID) else { return nil }
        var cases: [MCPBenchmarkResult.Case] = [], findings: [MCPSecurityFinding] = []
        var cold = 0.0, warm: [Double] = [], peak = 0.0, cleanup = true
        var boundary = MCPSandbox.boundary(seatbelt: useSeatbelt && MCPSandbox.seatbeltPresent, allowNetwork: allowNetwork).summary
        var connection: MCPConnection?, launchDir: URL?
        do {
            let (conn, launch, ms) = try await registry.connect(s, allowNetwork: allowNetwork, extraArguments: extraArguments, timeout: timeout, useSeatbelt: useSeatbelt)
            connection = conn; launchDir = launch.directory; cold = ms; boundary = launch.boundary.summary
            let tools = try await conn.listTools()
            let schemas = tools.map { MCPToolSchema(name: $0.name, description: $0.description, parameters: $0.parameters, risk: MCPToolClassifier.risk(name: $0.name, description: $0.description, parameters: $0.parameters), injectionNotes: $0.injectionNotes) }
            findings += MCPInspector.toolFindings(schemas)
            if s.tools.isEmpty { s.tools = schemas; s.envelope = s.envelope.union(MCPToolClassifier.envelope(for: schemas)); try? registry.repository?.save(s) }
            cases.append(.init(name: "starts and lists its tools", passed: !tools.isEmpty, detail: "\(tools.count) tool(s) in \(Int(ms)) ms", latencyMS: ms))
            var deterministic = true
            let work = ProcessInfoPath.canonical(launch.directory.appendingPathComponent("work").path)
            for c in spec.cases {
                guard let tool = c.tools.first(where: { name in tools.contains { $0.name == name } }), let schema = schemas.first(where: { $0.name == tool }) else {
                    cases.append(.init(name: c.name, passed: false, detail: "not offered by this server (looked for \(c.tools.prefix(3).joined(separator: ", ")))", latencyMS: 0)); continue
                }
                guard schema.risk != .broad else { cases.append(.init(name: c.name, passed: false, detail: "skipped: “\(tool)” is a broad tool", latencyMS: 0)); continue }
                let t0 = Date()
                do {
                    let r1 = try await conn.call(tool, c.args(work: work), timeout: timeout)
                    if c.expectsFailure {
                        let refused = r1.isError
                        cases.append(.init(name: c.name, passed: refused, detail: refused ? "refused as it should be" : "it answered instead of refusing", latencyMS: Date().timeIntervalSince(t0) * 1000)); continue
                    }
                    let ms = Date().timeIntervalSince(t0) * 1000
                    if let rss = ProcessTree.residentBytes(of: conn.processIdentifier) { peak = max(peak, Double(rss) / 1_048_576) }
                    let ok = !r1.isError && c.expect(r1.text)
                    if r1.injectionNotes > 0 { findings.append(MCPSecurityFinding(severity: .warning, category: "result-injection", detail: "the result of “\(tool)” contained instruction-shaped text (kept as data)", location: tool)) }
                    var detail = ok ? "ok" : (r1.isError ? "the tool reported an error" : "the answer did not match what was expected")
                    if ok, c.readOnly {
                        let t1 = Date(); let r2 = try await conn.call(tool, c.args(work: work), timeout: timeout)
                        warm.append(Date().timeIntervalSince(t1) * 1000)
                        if r2.text != r1.text { deterministic = false; detail = "ok, but two identical calls gave different answers" }
                    }
                    cases.append(.init(name: c.name, passed: ok, detail: detail, latencyMS: ms))
                } catch {
                    if c.expectsFailure, case MCPError.server = error { cases.append(.init(name: c.name, passed: true, detail: "refused with a protocol error, as it should be", latencyMS: Date().timeIntervalSince(t0) * 1000)) }
                    else { cases.append(.init(name: c.name, passed: false, detail: "\(error)", latencyMS: Date().timeIntervalSince(t0) * 1000)) }
                }
            }
            // Failure quality: an unknown tool must produce a clean error, not a crash or a hang.
            if let r = try? await conn.request("tools/call", ["name": "jarvis-no-such-tool", "arguments": [String: Any]()], timeout: 8) { _ = r; cases.append(.init(name: "an unknown tool is rejected cleanly", passed: false, detail: "it answered instead of refusing", latencyMS: 0)) }
            else if conn.isRunning { cases.append(.init(name: "an unknown tool is rejected cleanly", passed: true, detail: "refused with an error and kept running", latencyMS: 0)) }
            else { cases.append(.init(name: "an unknown tool is rejected cleanly", passed: false, detail: "the server died on an unknown tool", latencyMS: 0)) }
            let pid = conn.processIdentifier
            await conn.close(); connection = nil
            if let d = launchDir { cleanup = MCPSandbox.remove(d, under: registry.sandboxDirectory) && !ProcessTree.isAlive(pid) }
            let used = schemas.filter { t in cases.contains { $0.passed } && spec.cases.contains { $0.tools.contains(t.name) } }
            let envs = Set(used.map { $0.risk.envelope }).union([.read])
            let result = MCPBenchmarkResult(at: registry.clock(), cases: cases, coldStartMS: cold, warmCallMS: warm.isEmpty ? 0 : warm.sorted()[warm.count / 2], peakRSSMB: peak == 0 ? nil : peak, deterministic: deterministic,
                                            permissionsObserved: envs.sorted().map(\.label), networkObserved: allowNetwork, cleanupOK: cleanup, findings: findings, boundary: boundary)
            s = registry.server(serverID) ?? s
            s.benchmark = result
            try? registry.repository?.save(s)
            try? registry.repository?.save(benchmark: result, serverID: serverID)
            if s.status == .inspected { registry.transition(serverID, to: .sandboxed, reason: "ran in the sandbox") }
            if registry.server(serverID)?.status == .sandboxed { registry.transition(serverID, to: .benchmarked, reason: "\(result.passedCount)/\(result.cases.count) cases passed") }
            registry.onEvent?("MCP benchmarked: \(s.name) — \(result.passedCount)/\(result.cases.count) passed, cold \(Int(cold)) ms", .info)
            return result
        } catch {
            if let c = connection { let pid = c.processIdentifier; await c.close(); if let d = launchDir { cleanup = MCPSandbox.remove(d, under: registry.sandboxDirectory) && !ProcessTree.isAlive(pid) } }
            cases.append(.init(name: "starts and lists its tools", passed: false, detail: "\(error)", latencyMS: 0))
            let result = MCPBenchmarkResult(at: registry.clock(), cases: cases, coldStartMS: cold, warmCallMS: 0, peakRSSMB: nil, deterministic: false, permissionsObserved: [], networkObserved: allowNetwork, cleanupOK: cleanup, findings: findings, boundary: boundary)
            s = registry.server(serverID) ?? s; s.benchmark = result; try? registry.repository?.save(s); try? registry.repository?.save(benchmark: result, serverID: serverID)
            return result
        }
    }

    /// Recommendation rule (deterministic): a benchmarked server is RECOMMENDED only with ≥ 75 % of the applicable cases passing, a clean cleanup, a known licence and a price that is verified free
    /// (unknown is never free), and no HIGH finding that the sandbox could not contain. Otherwise it stays BENCHMARKED with the reasons listed.
    static func recommendation(for s: MCPServerRecord) -> (recommend: Bool, reasons: [String]) {
        var why: [String] = []
        guard let b = s.benchmark else { return (false, ["not benchmarked"]) }
        let applicable = b.cases.filter { !$0.detail.hasPrefix("not offered") && !$0.detail.hasPrefix("skipped") }
        if applicable.isEmpty || Double(applicable.filter(\.passed).count) / Double(applicable.count) < 0.75 { why.append("fewer than 75 % of the applicable benchmark cases passed") }
        if !b.cleanupOK { why.append("cleanup was incomplete") }
        if let d = s.discovery {
            if !d.licenseKnown && !s.isFixture { why.append("the licence is unknown (an unknown licence is never safe)") }
            if !d.isVerifiablyFree && !s.isFixture { why.append("the price is \(d.price) (unknown is never free)") }
        } else if !s.isFixture { why.append("no discovery evidence") }
        let high = (s.discovery?.findings ?? []) + b.findings
        if high.contains(where: { $0.severity == .high && $0.category != "broad-tool" }) { why.append("the static scan or the benchmark found high-risk behaviour") }
        if s.credentialRequirement != "none" && s.credentialRequirement != "unknown" { why.append("it needs \(s.credentialRequirement) — you would have to authorise it yourself") }
        return (why.isEmpty, why)
    }
}
