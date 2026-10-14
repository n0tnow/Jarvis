import Foundation
import CryptoKit

// MARK: - The MCP registry (V0.14, DEC-224…236)
//
// JARVIS stays the orchestrator; a server only provides capabilities. A server is a row with a STATUS that moves along `MCPStatus.allowedNext`: nothing discovered becomes ACTIVE by
// itself — registration, update and removal are HUD-approved requests (`AdaptiveDecisionService`), and spoken/typed text can only create the REQUEST. Agents never see raw tools: they
// call typed WRAPPERS the user approved, inside the registered permission envelope, with arguments validated by JARVIS. Server output is data.

struct MCPCallContext: Equatable, Sendable {
    var taskID: UUID?
    var role: String?
    var projectKey: String?
    /// True only when a person is directly in the loop for THIS call (never set for agent-originated calls). Needed for never-automatic envelopes.
    var userPresent = false
}

enum MCPInvocation: Equatable, Sendable {
    case result(MCPCallResult, server: String)
    case refused(String)
    case failed(String)
    var text: String? { if case .result(let r, _) = self { return r.text }; return nil }
}

enum MCPDisableOutcome: Equatable, Sendable { case disabled, alreadyDisabled, notFound, inUse([UUID]) }
enum MCPEnableOutcome: Equatable, Sendable { case enabled, notFound, needsApproval(UUID), refused(String) }

struct MCPOwnership: Equatable, Sendable {
    var registryEntry: String
    var installDirectory: String?
    var ownedFiles: [String]
    var otherFilesInDirectory: [String]
    var activeTasks: [UUID]
    var credentialReference: String
}

@MainActor @Observable
final class MCPRegistry {
    let repository: JarvisRepository?
    private let decisions: AdaptiveDecisionService
    /// JARVIS-owned root for installed servers (`<root>/servers/<id>/…`) and sandboxes (`<root>/sandboxes`). Nothing outside it is ever created or deleted by the registry.
    let root: URL
    @ObservationIgnored var onEvent: ((String, ActivityKind) -> Void)?
    @ObservationIgnored var clock: () -> Date = { Date() }
    @ObservationIgnored var pressureNormal: () -> Bool = { true }
    /// Called before a server starts: unload resident helpers (vision model, local LLM…) so a heavy server never runs beside them on a 16 GB machine.
    @ObservationIgnored var makeRoom: () async -> Void = {}
    @ObservationIgnored var resolveExecutable: (MCPServerRecord) -> String = { $0.launch.executable }
    /// How a launch becomes a running server. The default starts the sandboxed process; unit tests substitute an in-process server.
    @ObservationIgnored var transportFactory: (MCPSandboxLaunch) -> any MCPTransporting = { l in
        ProcessTransport(ManagedProcess(executable: l.executable, arguments: l.arguments, environment: l.environment, workingDirectory: l.workingDirectory))
    }
    private(set) var revision = 0

    struct Live { var connection: MCPConnection; var launch: MCPSandboxLaunch?; var startedAt: Date; var idle: Task<Void, Never>?; var starts: Int }
    private var live: [String: Live] = [:]
    private var inFlight: [String: [UUID: Int]] = [:]
    private var reserved: [String: Set<UUID>] = [:]
    private var anonymousInFlight: [String: Int] = [:]
    private var restarts: [String: [Date]] = [:]
    private(set) var coldStartsMS: [Double] = []
    private(set) var warmCallsMS: [Double] = []

    static let maxConsecutiveFailures = 3, degradeAt = 3, restartBudget = 2, restartWindow: TimeInterval = 300

    init(repository: JarvisRepository?, decisions: AdaptiveDecisionService, root: URL) {
        self.repository = repository; self.decisions = decisions; self.root = root
        decisions.register(.installCapability, .init(fingerprint: { [weak self] id in self?.fingerprint(.installCapability, id) }, execute: { [weak self] q in await self?.executeInstall(q) ?? .failure(.init(message: "the registry is not available")) }))
        decisions.register(.updateCapability, .init(fingerprint: { [weak self] id in self?.fingerprint(.updateCapability, id) }, execute: { [weak self] q in await self?.executeUpdate(q) ?? .failure(.init(message: "the registry is not available")) }))
        decisions.register(.removeCapability, .init(fingerprint: { [weak self] id in self?.fingerprint(.removeCapability, id) }, execute: { [weak self] q in await self?.executeRemoval(q) ?? .failure(.init(message: "the registry is not available")) }))
        decisions.register(.enableCapability, .init(fingerprint: { [weak self] id in self?.fingerprint(.enableCapability, id) }, execute: { [weak self] q in await self?.executeEnable(q) ?? .failure(.init(message: "the registry is not available")) }))
    }

    private func bump() { revision += 1 }
    private func note(_ s: String, _ k: ActivityKind = .info) { onEvent?(s, k) }
    private func audit(_ kind: String, _ id: String, _ detail: String, by: String = "system") { try? repository?.addLearningAudit(LearningAuditEntry(at: clock(), kind: kind, subjectID: id, detail: detail, by: by)) }

    var serversDirectory: URL { root.appendingPathComponent("servers", isDirectory: true) }
    var sandboxDirectory: URL { root.appendingPathComponent("sandboxes", isDirectory: true) }

    // MARK: - Launch reconciliation

    /// A server process never survives JARVIS, so every sandbox folder left behind belongs to a dead process: remove them (only `sbx-*` folders directly inside the sandbox root).
    @discardableResult
    func reconcileAfterLaunch() -> Int {
        guard let items = try? FileManager.default.contentsOfDirectory(at: sandboxDirectory, includingPropertiesForKeys: nil) else { return 0 }
        var n = 0
        for u in items where u.lastPathComponent.hasPrefix("sbx-") { if MCPSandbox.remove(u, under: sandboxDirectory) { n += 1 } }
        for var s in servers(statuses: [.active, .degraded]) where s.health == .starting { s.health = .available; try? repository?.save(s) }
        return n
    }

    // MARK: - Reading

    func servers(statuses: [MCPStatus]? = nil) -> [MCPServerRecord] { ((try? repository?.mcpServers(statuses: statuses)) ?? []) ?? [] }
    func server(_ id: String) -> MCPServerRecord? { ((try? repository?.mcpServer(id)) ?? nil) }
    /// Lookup by display name or id, tolerant of case, diacritics and a trailing “MCP” (“Blender MCP”, “blender”).
    func find(_ name: String) -> MCPServerRecord? {
        let n = Self.slug(name)
        guard !n.isEmpty else { return nil }
        let all = servers()
        return all.first { Self.slug($0.id) == n } ?? all.first { Self.slug($0.name) == n } ?? all.first { Self.slug($0.name).contains(n) || Self.slug($0.id).contains(n) || n.contains(Self.slug($0.id)) && Self.slug($0.id).count >= 4 }
    }
    static func slug(_ s: String) -> String {
        MemoryText.fold(s).replacingOccurrences(of: "mcp", with: "").split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
    }
    func activity(_ id: String? = nil, limit: Int = 100) -> [MCPActivityRecord] { ((try? repository?.mcpActivity(serverID: id, limit: limit)) ?? []) ?? [] }
    func benchmarks(_ id: String) -> [MCPBenchmarkResult] { ((try? repository?.mcpBenchmarks(serverID: id)) ?? []) ?? [] }
    var activeServers: [MCPServerRecord] { servers(statuses: [.active, .degraded]) }
    func isRunning(_ id: String) -> Bool { live[id]?.connection.isRunning == true }
    var runningServerIDs: [String] { live.filter { $0.value.connection.isRunning }.map(\.key).sorted() }

    /// Task ids that currently use the server: in-flight calls plus tasks that reserved it (a Skill that requires it, a running graph).
    func activeTaskIDs(_ id: String) -> [UUID] { Array(Set((inFlight[id] ?? [:]).keys).union(reserved[id] ?? [])) }
    func busy(_ id: String) -> Bool { !activeTaskIDs(id).isEmpty || (anonymousInFlight[id] ?? 0) > 0 }
    func reserve(_ id: String, task: UUID) { reserved[id, default: []].insert(task) }
    func release(task: UUID) { for k in reserved.keys { reserved[k]?.remove(task) } }

    // MARK: - Status machine

    @discardableResult
    func transition(_ id: String, to next: MCPStatus, reason: String? = nil, by: String = "system") -> Bool {
        guard var s = server(id), s.status.canMove(to: next) else { return false }
        s.status = next; s.statusChangedAt = clock()
        if next == .active || next == .disabled || next == .installed { s.health = next == .active ? .available : (next == .disabled ? .disabled : s.health) }
        try? repository?.save(s)
        audit("mcp-\(next.rawValue)", id, "\(s.name)\(reason.map { ": \($0)" } ?? "")", by: by)
        bump(); return true
    }

    /// Adds a candidate as DISCOVERED (never active). Re-adding the same id keeps the existing row.
    @discardableResult
    func addCandidate(_ record: MCPServerRecord) -> MCPServerRecord {
        if let existing = server(record.id) { return existing }
        var r = record; r.status = .discovered; r.statusChangedAt = clock(); r.registeredAt = clock(); r.health = .available
        try? repository?.save(r)
        audit("mcp-discovered", r.id, "\(r.name) (\(r.discovery?.sourceKind ?? "manual"))")
        note("MCP discovered: \(r.name)", .info)
        bump(); return r
    }

    // MARK: - Inspection (static) and tool classification

    /// Static scan of an on-disk source tree + the declared tool metadata. Never executes anything.
    @discardableResult
    func inspect(_ id: String, sourceDirectory: URL?) -> MCPInspection? {
        guard var s = server(id), s.status == .discovered || s.status == .inspected || s.status == .sandboxed || s.status == .blocked else { return nil }
        var inspection = sourceDirectory.map(MCPInspector.scan(directory:)) ?? MCPInspection(findings: [], filesScanned: 0, truncated: false, hosts: [], installScripts: [], dependencyCount: 0)
        inspection.findings += MCPInspector.toolFindings(s.tools)
        if var d = s.discovery { d.findings = inspection.findings; s.discovery = d }
        s.envelope = s.envelope.union(MCPToolClassifier.envelope(for: s.tools))
        try? repository?.save(s)
        if s.status == .discovered { transition(id, to: .inspected, reason: MCPInspector.verdict(inspection.findings)) }
        else { bump() }
        audit("mcp-inspected", id, MCPInspector.verdict(inspection.findings))
        // A server that carries a BROAD tool (arbitrary code / shell) is flagged; it is never auto-exposed (see `exposedWrappers`).
        if s.dangerous { note("MCP \(s.name): exposes a BROAD tool (arbitrary code/shell) — it will not be offered to agents automatically", .warning) }
        return inspection
    }

    // MARK: - Starting a server (sandboxed, on demand)

    func launch(for s: MCPServerRecord, allowNetwork: Bool, extraEnvironment: [String: String] = [:], extraArguments: [String] = [], readableRoots: [String] = [], useSeatbelt: Bool = true) throws -> MCPSandboxLaunch {
        try FileManager.default.createDirectory(at: sandboxDirectory, withIntermediateDirectories: true)
        let exe = resolveExecutable(s)
        var env = s.launch.environment; for (k, v) in extraEnvironment { env[k] = v }
        var roots = readableRoots
        if let d = s.installDirectory { roots.append(d) }
        return try MCPSandbox.prepare(root: sandboxDirectory, executable: exe, arguments: s.launch.arguments + extraArguments, allowNetwork: allowNetwork, readableRoots: roots, extraEnvironment: env, useSeatbelt: useSeatbelt)
    }

    func connect(_ s: MCPServerRecord, allowNetwork: Bool, extraArguments: [String] = [], timeout: TimeInterval = 20, useSeatbelt: Bool = true) async throws -> (MCPConnection, MCPSandboxLaunch, coldStartMS: Double) {
        let l = try launch(for: s, allowNetwork: allowNetwork, extraArguments: extraArguments, useSeatbelt: useSeatbelt)
        let conn = MCPConnection(transport: transportFactory(l))
        let t0 = Date()
        do { try conn.start(); try await conn.initialize(timeout: timeout) } catch { await conn.close(); MCPSandbox.remove(l.directory, under: sandboxDirectory); throw error }
        return (conn, l, Date().timeIntervalSince(t0) * 1000)
    }

    func stop(_ id: String) async {
        guard let l = live.removeValue(forKey: id) else { return }
        l.idle?.cancel()
        await l.connection.close()
        if let launch = l.launch { MCPSandbox.remove(launch.directory, under: sandboxDirectory) }
        bump()
    }
    func stopAll() async { for id in Array(live.keys) { await stop(id) } }

    private func scheduleIdleStop(_ id: String, after seconds: Double) {
        live[id]?.idle?.cancel()
        live[id]?.idle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            if self.busy(id) { self.scheduleIdleStop(id, after: seconds); return }
            await self.stop(id)
        }
    }

    // MARK: - Invocation (the ONLY path agents take: typed wrappers, validated arguments, registered envelope)

    /// Wrappers that may be offered to agents: only ACTIVE/DEGRADED servers, never a BROAD tool, never a never-automatic envelope.
    func exposedWrappers() -> [(server: MCPServerRecord, wrapper: MCPWrapper)] {
        activeServers.filter { !$0.revalidationRequired }.flatMap { s in
            s.wrappers.filter { w in
                guard let tool = s.tools.first(where: { $0.name == w.tool }) else { return false }
                return tool.risk != .broad && !w.envelope.isNeverAutomatic && s.envelope.contains(w.envelope)
            }.map { (s, $0) }
        }
    }

    /// Servers that expose a capability, best first: healthy before degraded, then by benchmark success and latency (not by existence).
    func candidates(for capability: String) -> [MCPServerRecord] {
        exposedWrappers().filter { $0.wrapper.capability == capability }.map(\.server).sorted {
            let ha = $0.health == .healthy || $0.health == .available ? 0 : 1, hb = $1.health == .healthy || $1.health == .available ? 0 : 1
            if ha != hb { return ha < hb }
            let ra = $0.benchmark?.successRate ?? 0, rb = $1.benchmark?.successRate ?? 0
            if ra != rb { return ra > rb }
            return ($0.averageLatencyMS ?? .infinity) < ($1.averageLatencyMS ?? .infinity)
        }
    }

    static func validate(_ args: [String: Any], against w: MCPWrapper) -> String? {
        for k in args.keys where w.parameters[k] == nil { return "unknown argument “\(k)”" }
        for (k, type) in w.parameters {
            guard let v = args[k] else { if w.optionalParameters.contains(k) { continue }; return "missing argument “\(k)”" }
            switch type {
            case "string":
                guard let s = v as? String else { return "“\(k)” must be text" }
                if s.count > w.maxStringLength { return "“\(k)” is longer than \(w.maxStringLength) characters" }
                if s.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" && $0 != "\t" }) { return "“\(k)” contains control characters" }
            case "number": guard v is NSNumber, !(v is Bool) else { return "“\(k)” must be a number" }
            case "boolean": guard v is Bool else { return "“\(k)” must be true or false" }
            default: return "“\(k)” has an unsupported type"
            }
        }
        return nil
    }

    @discardableResult
    func invoke(_ capability: String, _ args: [String: Any], context: MCPCallContext = MCPCallContext(), serverID: String? = nil) async -> MCPInvocation {
        let pool = serverID.flatMap { server($0) }.map { [$0] } ?? candidates(for: capability)
        guard !pool.isEmpty else {
            if let held = servers(statuses: [.active, .degraded]).first(where: { $0.revalidationRequired && $0.wrappers.contains { $0.capability == capability } }) { return .refused("refused: \(held.name) changed and must be revalidated first") }
            return .refused("no approved integration offers “\(capability)”")
        }
        var lastFailure = "no integration could be used"
        for s in pool {
            guard let w = s.wrappers.first(where: { $0.capability == capability }) else { continue }
            let r = await invoke(on: s, wrapper: w, args, context: context)
            switch r {
            case .result: return r
            case .refused(let why): lastFailure = why
            case .failed(let why): lastFailure = why; continue        // degraded or failing → the next equivalent capability, if any
            }
        }
        return pool.count > 1 ? .failed("every equivalent integration failed (\(lastFailure))") : (lastFailure.contains("refused") || lastFailure.hasPrefix("not ") ? .refused(lastFailure) : .failed(lastFailure))
    }

    private func invoke(on s: MCPServerRecord, wrapper w: MCPWrapper, _ args: [String: Any], context: MCPCallContext) async -> MCPInvocation {
        func log(_ status: String, _ start: Date, _ error: String?, validated: Bool = false) {
            try? repository?.insert(MCPActivityRecord(serverID: s.id, capability: w.capability, taskID: context.taskID, role: context.role, projectKey: context.projectKey, startedAt: start, endedAt: clock(), status: status,
                                                       latencyMS: clock().timeIntervalSince(start) * 1000, envelope: w.envelope.rawValue, error: error, validated: validated))
        }
        let start = clock()
        guard s.status.isLive else { log("refused", start, "not active"); return .refused("not active: \(s.name) is \(s.status.label.lowercased())") }
        if s.revalidationRequired { log("refused", start, "revalidation required"); return .refused("refused: \(s.name) changed and must be revalidated first") }
        guard let tool = s.tools.first(where: { $0.name == w.tool }) else { log("refused", start, "tool missing"); return .refused("refused: the registered tool “\(w.tool)” is no longer offered") }
        if tool.risk == .broad { log("refused", start, "broad tool"); return .refused("refused: “\(w.tool)” runs arbitrary code and is never available to agents") }
        guard s.envelope.contains(w.envelope) else { log("refused", start, "outside envelope"); return .refused("refused: \(w.envelope.label) is outside the registered permission envelope of \(s.name)") }
        if w.envelope.isNeverAutomatic, !context.userPresent { log("refused", start, "needs the user"); return .refused("refused: \(w.envelope.label) needs you in the loop for every use") }
        if w.envelope == .projectWrite || w.envelope == .destructive {
            guard let p = context.projectKey, s.allowedProjects.contains(p) else { log("refused", start, "project not allowed"); return .refused("refused: \(s.name) may not change project “\(context.projectKey ?? "?")”") }
        }
        if let bad = Self.validate(args, against: w) { log("refused", start, bad); return .refused("refused: \(bad)") }
        if !pressureNormal(), s.launch.executable.isEmpty == false, s.isHeavy { log("refused", start, "memory pressure"); return .refused("refused: the machine is under memory pressure and \(s.name) is heavy — the native capability remains available") }
        // start or reuse
        var cold = 0.0
        if live[s.id]?.connection.isRunning != true {
            let recent = (restarts[s.id] ?? []).filter { clock().timeIntervalSince($0) < Self.restartWindow }
            guard recent.count < Self.restartBudget + 1 else { markFailed(s.id, "restart budget used up"); log("failed", start, "restart budget"); return .failed("\(s.name) kept failing to start — not restarted again (re-enable it after checking)") }
            restarts[s.id] = recent + [clock()]
            await makeRoom()
            do {
                let (conn, launch, ms) = try await connect(s, allowNetwork: s.envelope.contains(.network))
                live[s.id] = Live(connection: conn, launch: launch, startedAt: clock(), idle: nil, starts: (live[s.id]?.starts ?? 0) + 1)
                cold = ms; coldStartsMS.append(ms)
            } catch { recordFailure(s.id, "\(error)"); log("failed", start, "start: \(error)"); return .failed("\(s.name) could not be started (\(error))") }
        }
        guard let conn = live[s.id]?.connection else { return .failed("\(s.name) is not running") }
        let task = context.taskID
        if let task { inFlight[s.id, default: [:]][task, default: 0] += 1 } else { anonymousInFlight[s.id, default: 0] += 1 }
        defer {
            if let task { inFlight[s.id]?[task, default: 1] -= 1; if (inFlight[s.id]?[task] ?? 0) <= 0 { inFlight[s.id]?[task] = nil } } else { anonymousInFlight[s.id, default: 1] -= 1 }
        }
        let t0 = Date()
        do {
            let r = try await conn.call(w.tool, args)
            let ms = Date().timeIntervalSince(t0) * 1000
            if cold == 0 { warmCallsMS.append(ms) }
            if r.isError { recordFailure(s.id, "tool reported an error"); log("failed", start, "tool error", validated: true); return .failed("\(s.name) reported an error: \(String(r.text.prefix(160)))") }
            recordSuccess(s.id, latency: ms)
            log("ok", start, nil, validated: true)
            scheduleIdleStop(s.id, after: s.launch.persistent ? 3600 : s.launch.idleSeconds)
            return .result(r, server: s.id)
        } catch {
            recordFailure(s.id, "\(error)")
            await stop(s.id)
            log("failed", start, "\(error)")
            return .failed("\(s.name): \(error)")
        }
    }

    // MARK: - Health, degradation

    func recordSuccess(_ id: String, latency: Double) {
        guard var s = server(id) else { return }
        s.successCount += 1; s.consecutiveFailures = 0; s.lastSuccessAt = clock(); s.lastUsedAt = clock()
        s.averageLatencyMS = s.averageLatencyMS.map { $0 * 0.8 + latency * 0.2 } ?? latency
        s.health = .healthy
        if s.status == .degraded { s.status = .active; s.statusChangedAt = clock() }
        try? repository?.save(s); bump()
    }
    func recordFailure(_ id: String, _ why: String) {
        guard var s = server(id) else { return }
        s.failureCount += 1; s.consecutiveFailures += 1; s.lastFailureAt = clock(); s.lastUsedAt = clock()
        if s.consecutiveFailures >= Self.degradeAt, s.status == .active { s.status = .degraded; s.statusChangedAt = clock(); s.health = .degraded; note("\(s.name) is DEGRADED after \(s.consecutiveFailures) failures in a row", .warning); audit("mcp-degraded", id, why) }
        else if s.consecutiveFailures >= Self.degradeAt { s.health = .degraded }
        try? repository?.save(s); bump()
    }
    private func markFailed(_ id: String, _ why: String) {
        guard var s = server(id) else { return }
        s.health = .failed; if s.status == .active { s.status = .degraded }
        s.statusChangedAt = clock(); try? repository?.save(s)
        audit("mcp-failed", id, why); bump()
    }

    /// On-demand health check (no timer): start, initialise, list tools, stop. Updates health and the tool list.
    @discardableResult
    func checkHealth(_ id: String) async -> MCPHealth {
        guard let s = server(id), s.status != .removed else { return .failed }
        do {
            let (conn, launch, ms) = try await connect(s, allowNetwork: s.envelope.contains(.network))
            let tools = try await conn.listTools()
            await conn.close(); MCPSandbox.remove(launch.directory, under: sandboxDirectory)
            var u = server(id) ?? s; u.health = .healthy; u.consecutiveFailures = 0; u.averageLatencyMS = u.averageLatencyMS ?? ms
            _ = tools; try? repository?.save(u); bump()
            return .healthy
        } catch {
            recordFailure(id, "\(error)")
            return server(id)?.health ?? .failed
        }
    }

    // MARK: - Version / hash drift

    static func fileHash(_ path: String) -> String? {
        guard let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Compares what would launch now with what was approved. A different version or hash ⇒ REVALIDATION REQUIRED; it does not stay trusted across unknown code.
    @discardableResult
    func checkDrift(_ id: String, observedVersion: String? = nil) -> Bool {
        guard var s = server(id), s.status != .removed else { return false }
        var reasons: [String] = []
        if let h = s.executableHash, let now = Self.fileHash(resolveExecutable(s)), now != h { reasons.append("the executable changed (hash \(String(now.prefix(10)))… ≠ \(String(h.prefix(10)))…)") }
        if let v = observedVersion, !s.version.isEmpty, v != s.version { reasons.append("the version is now \(v), approved was \(s.version)") }
        guard !reasons.isEmpty else { return false }
        s.revalidationRequired = true; s.revalidationReason = reasons.joined(separator: "; ")
        if s.status == .active { s.status = .degraded }
        s.health = .degraded; s.statusChangedAt = clock()
        try? repository?.save(s)
        audit("mcp-drift", id, s.revalidationReason ?? "")
        note("\(s.name): REVALIDATION REQUIRED — \(s.revalidationReason ?? "")", .warning)
        bump(); return true
    }

    /// After a successful benchmark of the CHANGED server the user may clear the flag (the request goes through the same approval as an update).
    func clearRevalidation(_ id: String, by: String) {
        guard var s = server(id), s.revalidationRequired else { return }
        s.revalidationRequired = false; s.revalidationReason = nil
        if let h = Self.fileHash(resolveExecutable(s)) { s.executableHash = h }
        if s.status == .degraded { s.status = .active }
        s.health = .available; s.statusChangedAt = clock()
        try? repository?.save(s); audit("mcp-revalidated", id, s.name, by: by); bump()
    }

    // MARK: - Disable / enable

    func disable(_ id: String, force: Bool = false) async -> MCPDisableOutcome {
        guard let s = server(id) else { return .notFound }
        if s.status == .disabled { return .alreadyDisabled }
        guard s.status.canMove(to: .disabled) else { return .notFound }
        let using = activeTaskIDs(id)
        if !using.isEmpty, !force { return .inUse(using) }
        await stop(id)
        transition(id, to: .disabled, by: "user")
        return .disabled
    }

    func enable(_ id: String) -> MCPEnableOutcome {
        guard let s = server(id) else { return .notFound }
        guard s.status == .disabled || s.status == .installed else { return .refused("it is \(s.status.label.lowercased())") }
        if s.revalidationRequired { return .refused("it changed and must be revalidated first") }
        // Anything that touches the network, the project or worse needs a person's click; a read-only local server can simply be switched on.
        let needsClick = !s.envelope.subtracting([.read]).isEmpty
        if needsClick {
            guard let q = decisions.request(kind: .enableCapability, subjectID: id, material: fingerprintMaterial(s), summary: "Switch on \(s.name)", detail: "Permissions: \(s.envelopeLabels.joined(separator: ", ")). \(s.network == "none" ? "No network." : "Network: \(s.network).")", risk: s.envelope.contains(where: \.isNeverAutomatic) ? .high : .medium) else { return .refused("could not create the request") }
            return .needsApproval(q.id)
        }
        transition(id, to: .active, by: "user")
        return .enabled
    }

    // MARK: - Requests (the approval boundary)

    private func fingerprintMaterial(_ s: MCPServerRecord) -> String {
        "\(s.id)|\(s.status.rawValue)|\(s.version)|\(s.executableHash ?? "-")|\(s.envelopeLabels.joined(separator: ","))|\(s.wrappers.map(\.capability).sorted().joined(separator: ","))|\(s.allowedProjects.sorted().joined(separator: ","))|\(s.revalidationRequired)|\(s.pendingVersion ?? "-")"
    }
    private func fingerprint(_ kind: AdaptiveRequestKind, _ id: String) -> String? {
        guard let s = server(id) else { return nil }
        return AdaptiveDecisionService.scopeHash(kind: kind, subjectID: id, material: fingerprintMaterial(s))
    }

    /// Asks to register a RECOMMENDED server. The request shows exactly what it would be allowed to do.
    @discardableResult
    func requestInstall(_ id: String, allowedProjects: [String] = []) -> AdaptiveRequest? {
        guard var s = server(id), s.status == .recommended else { return nil }
        s.allowedProjects = allowedProjects; try? repository?.save(s)
        let tools = s.tools.map { "\($0.name) [\($0.risk.label)]" }.joined(separator: ", ")
        return decisions.request(kind: .installCapability, subjectID: id, material: fingerprintMaterial(s), summary: "Register the MCP “\(s.name)”",
                                 detail: "Permissions: \(s.envelopeLabels.joined(separator: ", ")). Network: \(s.network). Needs a key or sign-in: \(s.credentialRequirement). Typed capabilities offered to agents: \(s.wrappers.map(\.capability).joined(separator: ", ")). Tools: \(tools). Source: \(s.provenance). Projects: \(allowedProjects.isEmpty ? "none" : allowedProjects.joined(separator: ", ")).",
                                 risk: s.envelope.contains(where: \.isNeverAutomatic) || s.dangerous ? .high : .medium)
    }

    @discardableResult
    func requestUpdate(_ id: String, toVersion: String, note changelog: String = "") -> AdaptiveRequest? {
        guard let s = server(id), s.status.isLive || s.status == .disabled else { return nil }
        var u = s; u.pendingVersion = toVersion; try? repository?.save(u)
        return decisions.request(kind: .updateCapability, subjectID: id, material: fingerprintMaterial(u), summary: "Update \(s.name) \(s.version) → \(toVersion)", detail: "An update changes code JARVIS runs. After it, the benchmark is run again and the previous version stays available for rollback. \(changelog)", risk: .high)
    }

    func ownership(_ id: String) -> MCPOwnership? {
        guard let s = server(id) else { return nil }
        let dir = s.installDirectory
        let listing: [String] = dir.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0) } ?? []
        let owned = Set(s.ownedFiles.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }.map { ($0 as NSString).pathComponents.first ?? $0 })
        return MCPOwnership(registryEntry: s.id, installDirectory: dir, ownedFiles: s.ownedFiles, otherFilesInDirectory: listing.filter { !owned.contains($0) }.sorted(), activeTasks: activeTaskIDs(id),
                            credentialReference: s.credentialRequirement == "none" ? "none" : "a reference only (\(s.credentialRequirement)) — JARVIS never stores or reads the credential")
    }

    /// Creates the removal REQUEST. Refuses at once while the server is used by an active task. Nothing is deleted here.
    enum RemovalRequest: Equatable { case requested(UUID), inUse([UUID]), notFound }
    func requestRemoval(_ id: String) -> RemovalRequest {
        guard let s = server(id), s.status != .removed else { return .notFound }
        let using = activeTaskIDs(id)
        if !using.isEmpty { return .inUse(using) }
        let o = ownership(id)
        let detail = "Will remove: the registry entry; \(o?.ownedFiles.count ?? 0) JARVIS-owned file(s) in \(o?.installDirectory ?? "no install directory"); its cache and any process it owns. Will NOT touch: \((o?.otherFilesInDirectory.isEmpty ?? true) ? "anything else" : "\(o!.otherFilesInDirectory.count) other file(s) in that folder (" + o!.otherFilesInDirectory.prefix(3).joined(separator: ", ") + ")"), your projects, shared package managers, other configuration or credentials."
        guard let q = decisions.request(kind: .removeCapability, subjectID: id, material: fingerprintMaterial(s), summary: "Remove the MCP “\(s.name)”", detail: detail, risk: .high) else { return .notFound }
        return .requested(q.id)
    }

    // MARK: - Execution of approved requests

    private typealias Failure = AdaptiveDecisionService.AdaptiveExecutionError

    private func executeInstall(_ q: AdaptiveRequest) async -> Result<String, Failure> {
        guard var s = server(q.subjectID), s.status == .recommended else { return .failure(Failure(message: "the server is no longer recommended")) }
        guard transition(s.id, to: .approved, by: q.decidedBy ?? "hud") else { return .failure(Failure(message: "the server cannot be approved from \(s.status.label)")) }
        s = server(s.id) ?? s
        // JARVIS-owned install directory + an ownership manifest (the exact files it owns).
        let dir = serversDirectory.appendingPathComponent(s.id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let manifest: [String: Any] = ["id": s.id, "name": s.name, "version": s.version, "registeredAt": ISO8601DateFormatter().string(from: clock()), "owner": "JARVIS"]
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("jarvis-owned.json"))
            s.installDirectory = dir.path
            if !s.ownedFiles.contains("jarvis-owned.json") { s.ownedFiles.append("jarvis-owned.json") }
        } catch { return .failure(Failure(message: "could not create the install folder (\(error.localizedDescription))")) }
        s.executableHash = Self.fileHash(resolveExecutable(s)); s.approvalID = q.id.uuidString
        s.provenance = s.provenance.isEmpty ? "registered after your approval" : s.provenance + " · registered after your approval"
        try? repository?.save(s)
        transition(s.id, to: .installed, by: q.decidedBy ?? "hud")
        transition(s.id, to: .active, by: q.decidedBy ?? "hud")
        return .success("Registered “\(s.name)”: \(s.envelopeLabels.joined(separator: ", ")). It is on, runs only when a task needs it, and is stopped after \(Int(s.launch.idleSeconds)) s idle.")
    }

    private func executeEnable(_ q: AdaptiveRequest) async -> Result<String, Failure> {
        guard let s = server(q.subjectID), transition(s.id, to: .active, by: q.decidedBy ?? "hud") else { return .failure(Failure(message: "it cannot be switched on from its current state")) }
        return .success("Switched on “\(s.name)”.")
    }

    private func executeUpdate(_ q: AdaptiveRequest) async -> Result<String, Failure> {
        guard var s = server(q.subjectID) else { return .failure(Failure(message: "the server no longer exists")) }
        await stop(s.id)
        if let v = s.pendingVersion { s.version = v; s.pendingVersion = nil }
        s.revalidationRequired = true; s.revalidationReason = "updated after your approval — benchmark it again before it is used"
        s.status = s.status.isLive ? .degraded : s.status; s.health = .degraded; s.statusChangedAt = clock()
        try? repository?.save(s)
        audit("mcp-update-approved", s.id, s.name, by: q.decidedBy ?? "hud"); bump()
        return .success("Update approved for “\(s.name)”. It must pass the benchmark again before it is used.")
    }

    /// Removal deletes EXACTLY the JARVIS-owned files recorded at registration, inside the install directory; directories it created are removed only if empty.
    private func executeRemoval(_ q: AdaptiveRequest) async -> Result<String, Failure> {
        guard let s = server(q.subjectID) else { return .failure(Failure(message: "the server no longer exists")) }
        let using = activeTaskIDs(s.id)
        guard using.isEmpty else { return .failure(Failure(message: "“\(s.name)” is being used by an active task — stop or finish it first", refused: true)) }
        await stop(s.id)
        var removed = 0, kept: [String] = []
        if let dir = s.installDirectory {
            let base = ProcessInfoPath.canonical(dir)
            guard base.hasPrefix(ProcessInfoPath.canonical(serversDirectory.path) + "/") else { return .failure(Failure(message: "the install folder is outside JARVIS' own server folder — nothing was deleted", refused: true)) }
            for rel in s.ownedFiles.sorted(by: { $0.count > $1.count }) {
                let isDir = rel.hasSuffix("/"); let clean = isDir ? String(rel.dropLast()) : rel
                guard !clean.isEmpty, !clean.contains(".."), !clean.hasPrefix("/") else { continue }
                let path = (dir as NSString).appendingPathComponent(clean)
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                if (st.st_mode & S_IFMT) == S_IFLNK { try? FileManager.default.removeItem(atPath: path); removed += 1; continue }       // a symlink is removed itself, never followed
                guard ProcessInfoPath.canonical(path).hasPrefix(base + "/") else { continue }
                if isDir { if ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).isEmpty { try? FileManager.default.removeItem(atPath: path); removed += 1 } else { kept.append(clean) } }
                else { try? FileManager.default.removeItem(atPath: path); removed += 1 }
            }
            // the install folder itself is removed only when nothing else is left in it
            if ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).isEmpty { try? FileManager.default.removeItem(atPath: dir) }
            else { kept += ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []) }
        }
        var u = s; u.status = .removed; u.statusChangedAt = clock(); u.health = .disabled; u.installDirectory = nil; u.ownedFiles = []
        try? repository?.save(u)
        audit("mcp-removed", s.id, "\(s.name): \(removed) owned file(s) removed; left in place: \(kept.isEmpty ? "nothing" : kept.joined(separator: ", "))", by: q.decidedBy ?? "hud")
        bump()
        return .success("Removed “\(s.name)”: \(removed) JARVIS-owned file(s) deleted\(kept.isEmpty ? "" : "; left untouched: " + kept.prefix(4).joined(separator: ", ")).")
    }

    /// Drops the registry row of a REMOVED server (history stays in the audit trail).
    func forget(_ id: String) { if server(id)?.status == .removed { try? repository?.deleteMCPServer(id); bump() } }

    // MARK: - Recommendations and obsolescence (never destructive)

    struct Advice: Equatable { var serverID: String; var kind: String; var detail: String }
    func advice(now: Date = Date(), unusedDays: Int = 30) -> [Advice] {
        var out: [Advice] = []
        let all = servers(statuses: [.active, .degraded, .disabled, .installed])
        for s in all {
            let last = s.lastUsedAt ?? s.registeredAt
            if now.timeIntervalSince(last) > Double(unusedDays) * 86_400 { out.append(Advice(serverID: s.id, kind: "unused", detail: "\(s.name) has not been used for \(Int(now.timeIntervalSince(last) / 86_400)) days (unused — not a statement that it is safe to delete).")) }
            if s.failureCount >= 5, Double(s.failureCount) / Double(max(1, s.failureCount + s.successCount)) > 0.5 { out.append(Advice(serverID: s.id, kind: "failing", detail: "\(s.name) failed \(s.failureCount) of \(s.failureCount + s.successCount) calls.")) }
            if let d = s.discovery?.lastRelease, now.timeIntervalSince(d) > 540 * 86_400 { out.append(Advice(serverID: s.id, kind: "unmaintained", detail: "\(s.name): no release for \(Int(now.timeIntervalSince(d) / 86_400)) days.")) }
            if s.revalidationRequired { out.append(Advice(serverID: s.id, kind: "revalidate", detail: "\(s.name): \(s.revalidationReason ?? "changed")")) }
        }
        // duplicates: two ACTIVE servers offering the same capability
        var byCap: [String: [MCPServerRecord]] = [:]
        for s in all where s.status.isLive { for w in s.wrappers { byCap[w.capability, default: []].append(s) } }
        for (cap, list) in byCap where list.count > 1 { out.append(Advice(serverID: list[0].id, kind: "duplicate", detail: "“\(cap)” is offered by \(list.map(\.name).joined(separator: ", ")) — benchmark them and keep one; fallbacks need an explicit reason.")) }
        return out
    }
}

extension MCPServerRecord {
    /// A server is heavy when it declares itself so, or runs a large runtime. Heavy servers are refused under memory pressure.
    var isHeavy: Bool { launch.environment["JARVIS_HEAVY"] == "1" || (discovery?.runtime?.lowercased().contains("blender") ?? false) || (discovery?.runtime?.lowercased().contains("unity") ?? false) }
}
