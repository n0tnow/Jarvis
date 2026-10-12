import Foundation
import Observation

// MARK: - Errors that carry the task failure category

struct UnityToolError: Error, Equatable, CustomStringConvertible {
    var category: FailureCategory
    var message: String
    var candidates: [UnityObjectRef] = []
    var description: String { message }

    static func from(_ e: UnityBridgeError) -> UnityToolError {
        switch e {
        case .notConnected(let m): return UnityToolError(category: .unityUnavailable, message: m)
        case .timedOut(let m): return UnityToolError(category: .unityTimeout, message: "Unity did not answer in time (\(m)).")
        case .cancelled: return UnityToolError(category: .cancelled, message: "cancelled")
        case .editorExited: return UnityToolError(category: .unityUnavailable, message: "The Unity Editor exited.")
        case .sessionChanged: return UnityToolError(category: .workspaceChanged, message: e.description)
        case .policy(let m): return UnityToolError(category: .securityBlocked, message: m)
        case .malformed(let m): return UnityToolError(category: .toolFailed, message: "Unexpected data from the Unity bridge (\(m)).")
        case .ambiguous(_, let m): return UnityToolError(category: .ambiguousTarget, message: m)
        case .rejected(let code, let message):
            let cat: FailureCategory
            switch code {
            case "ambiguousTarget", "ambiguousComponent", "ambiguousComponentType", "identityMismatch": cat = .ambiguousTarget
            case "targetNotFound", "sceneNotFound", "componentNotFound", "propertyNotFound", "sceneNotLoaded": cat = .validationFailed
            case "playModeMutationBlocked", "editorBusy", "dirtySceneProtected", "dirtyScene", "playModeActive": cat = .unsafeEditorState
            case "compileErrors": cat = .compileFailed
            case "unknownOperation", "notOwned": cat = .securityBlocked
            default: cat = .toolFailed
            }
            return UnityToolError(category: cat, message: OutputSanitizer.sanitize(message))
        }
    }
}

// MARK: - Tool session (one per step: audit run, events, approvals, capabilities)

/// Everything a Unity step needs to talk to the editor in an audited, capability-checked way.
@MainActor
final class UnityToolSession {
    let capabilities: CapabilitySet
    let taskID: UUID?
    let runID: UUID?
    let hub: ExecutionHub?
    let destructiveRequested: Bool
    var approvedDirtyScenes: Set<String> = []
    private(set) var operationCount = 0
    private(set) var mutations: [String] = []

    init(capabilities: CapabilitySet, taskID: UUID?, runID: UUID?, hub: ExecutionHub?, destructiveRequested: Bool) {
        self.capabilities = capabilities; self.taskID = taskID; self.runID = runID; self.hub = hub; self.destructiveRequested = destructiveRequested
    }

    func note(_ kind: ConsoleEventKind, _ summary: String, detail: String? = nil, severity: EventSeverity = .info) {
        guard let runID else { return }
        hub?.emit(runID, kind, source: "JARVIS", summary: summary, detail: detail, severity: severity)
    }
    func countOperation(_ op: UnityOperation) {
        operationCount += 1
        if op.isPersistentMutation { mutations.append(op.summary) }
    }
}

// MARK: - Connection (one editor ↔ one project)

@MainActor
@Observable
final class UnityConnection {
    let root: String
    @ObservationIgnored let transport: UnityTransport
    private(set) var state: UnityConnectionState = .notConfigured
    private(set) var status: UnityStatusSnapshot?
    private(set) var message: String?
    var descriptor: UnityProjectDescriptor?
    @ObservationIgnored var owned: (any UnityOwnedEditor)?
    /// The editor session in which object identities were resolved; a different session invalidates them.
    @ObservationIgnored private(set) var handleSession: String?
    @ObservationIgnored var onChange: (() -> Void)?

    init(root: String, transport: UnityTransport) {
        self.root = root; self.transport = transport
        transport.onStatusChange = { [weak self] s in self?.apply(status: s) }
        apply(status: transport.currentStatus())
    }

    var isLive: Bool { status != nil }

    func setState(_ s: UnityConnectionState, _ m: String? = nil) { state = s; message = m; onChange?() }

    /// The truthful state: derived from what the editor published, never from discovery alone.
    func apply(status s: UnityStatusSnapshot?) {
        status = s
        if let s {
            if handleSession != nil, handleSession != s.session { handleSession = nil }
            if s.isPlaying || s.state == "playing" || s.state == "paused" { state = .playMode }
            else if s.isCompiling || s.state == "importing" || s.testRun.map({ !$0.isFinished }) == true || s.state == "enteringPlay" { state = .busy }
            else { state = .connected }
            message = nil
        } else if state == .connected || state == .busy || state == .playMode || state == .connecting {
            state = .disconnected; message = "The Unity editor is no longer running."
        }
        onChange?()
    }

    func markHandles() { handleSession = status?.session }

    /// Were identities resolved earlier still valid in the editor that is running now?
    var handlesAreFresh: Bool { handleSession != nil && handleSession == status?.session }

    // MARK: Operations

    func authorize(_ op: UnityOperation, session: UnityToolSession) -> UnityPolicy.Decision {
        UnityPolicy.authorize(op, capabilities: session.capabilities, status: transport.currentStatus() ?? status, destructiveRequested: session.destructiveRequested,
                              approvedDirtyScenes: session.approvedDirtyScenes)
    }

    /// Test hook: shortens every operation timeout. Product code never sets it.
    nonisolated(unsafe) static var timeoutOverride: TimeInterval?

    static func timeout(for op: UnityOperation) -> TimeInterval {
        if let o = timeoutOverride { return o }
        switch op {
        case .requestCompilation: return 60
        case .enterPlayMode, .exitPlayMode, .runTests, .saveScene, .createPrefab: return 60
        case .openScene: return 90
        default: return 30
        }
    }

    /// Policy → bridge → sanitized result. Approval-needing operations must be approved by the caller first (`session.approvedDirtyScenes`, or the
    /// per-action approval for deletion, signalled with `approvedDestructive`).
    func perform(_ op: UnityOperation, session: UnityToolSession, approvedDestructive: Bool = false, timeout: TimeInterval? = nil) async throws -> UnityResponse {
        switch authorize(op, session: session) {
        case .allow: break
        case .deny(let cat, let why): session.note(.warning, "Refused: \(op.summary)", detail: why, severity: .warning); throw UnityToolError(category: cat, message: why)
        case .needsApproval(_, let reason, _):
            if !(approvedDestructive && op.isDestructive) { throw UnityToolError(category: .approvalDenied, message: "Approval is required first: \(reason)") }
        }
        guard transport.currentStatus() != nil else { throw UnityToolError(category: .unityUnavailable, message: "No Unity editor with the JARVIS bridge is running for this project.") }
        session.countOperation(op)
        let started = Date()
        let response: UnityResponse
        do { response = try await transport.send(op, timeout: timeout ?? Self.timeout(for: op)) }
        catch let e as UnityBridgeError {
            session.note(.warning, "Failed: \(op.summary)", detail: e.description, severity: .warning)
            throw UnityToolError.from(e)
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let safe = UnityResponseSanitizer.sanitize(response)
        if let s = transport.currentStatus() { apply(status: s) }
        guard safe.ok else {
            let err = UnityToolError.from(.rejected(code: safe.errorCode ?? "error", message: safe.errorMessage ?? "rejected"))
            var e = err; e.candidates = safe.candidates
            session.note(.warning, "Rejected: \(op.summary)", detail: "\(safe.errorCode ?? "error"): \(safe.errorMessage ?? "")", severity: .warning)
            throw e
        }
        session.note(op.isPersistentMutation ? .fileChanged : .toolFinished, "\(op.isPersistentMutation ? "Applied" : "Done"): \(op.summary) (\(ms) ms)", severity: .success)
        return safe
    }
}

/// Everything that comes back from the editor is untrusted text: sanitized at this single choke point before any other code sees it.
enum UnityResponseSanitizer {
    static let globalIDPattern = try! NSRegularExpression(pattern: #"^GlobalObjectId_V1-\d-[0-9a-f]{32}-\d+-\d+$"#)

    static func sanitize(_ r: UnityResponse) -> UnityResponse {
        var out = r
        out.result = (walk(r.result, key: nil) as? [String: Any]) ?? [:]
        out.errorMessage = r.errorMessage.map { OutputSanitizer.sanitize(String($0.prefix(600))) }
        if let d = r.errorDetails { out.errorDetails = walk(d, key: nil) }
        return out
    }

    private static func walk(_ v: Any, key: String?) -> Any {
        switch v {
        case let d as [String: Any]: return Dictionary(uniqueKeysWithValues: d.map { ($0.key, walk($0.value, key: $0.key)) })
        case let a as [Any]: return a.map { walk($0, key: key) }
        case let s as String:
            // Structural identifiers are validated by shape instead of text-sanitized (a long hex GUID would otherwise look like a secret).
            if key == "globalId", globalIDPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil { return s }
            return OutputSanitizer.sanitize(s)
        default: return v
        }
    }
}

// MARK: - Service

enum UnityPrepareOutcome: Equatable {
    case ready
    case needsBridgeInstall
    case needsUpgradeApproval(declared: UnityVersion, candidate: UnityVersion)
    case failed(FailureCategory, String)
}

@MainActor
@Observable
final class UnityService {
    private(set) var editors: [UnityEditorInstall] = []
    private(set) var hubInstalled = false
    private(set) var connections: [String: UnityConnection] = [:]
    @ObservationIgnored let lock = UnityMutationLock()

    // Seams (production defaults; tests inject simulated pieces).
    @ObservationIgnored var transportFactory: (String) -> UnityTransport = { UnityFileSpoolTransport(root: $0) }
    @ObservationIgnored var launcher: UnityLaunching = UnityProcessLauncher()
    @ObservationIgnored var discoverEditors: () -> [UnityEditorInstall] = { UnityDiscovery.discover() }
    @ObservationIgnored var scanProcesses: () -> [UnityProcessScanner.Editor] = { UnityProcessScanner.editors() }
    @ObservationIgnored var installBridge: (String) throws -> Void = { _ = try UnityBridgeInstaller.install(root: $0) }
    @ObservationIgnored var connectTimeout: TimeInterval = 600
    @ObservationIgnored var onChange: (() -> Void)?
    /// An editor JARVIS started is closed again when no Unity task has used it for this long (one-shot timer; never polling).
    @ObservationIgnored var idleShutdownDelay: TimeInterval = 600
    @ObservationIgnored private var idleShutdown: Task<Void, Never>?

    init() {}

    /// Called when a Unity task ends: if nothing else uses the editors, owned ones are closed after the idle delay.
    func taskFinished(activeUnityTasks: Int) {
        idleShutdown?.cancel(); idleShutdown = nil
        guard activeUnityTasks == 0, connections.values.contains(where: { $0.owned != nil }), idleShutdownDelay > 0 else { return }
        let delay = idleShutdownDelay
        idleShutdown = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            await self.shutdownOwnedEditors()
        }
    }

    // MARK: Discovery (on demand — never a background scan)

    func refreshEditors() {
        editors = discoverEditors()
        hubInstalled = UnityDiscovery.hubInstalled()
        onChange?()
    }

    func connection(for root: String) -> UnityConnection {
        let key = UnityProcessScanner.canonical(root)
        if let c = connections[key] { return c }
        let c = UnityConnection(root: key, transport: transportFactory(key))
        c.onChange = { [weak self] in self?.onChange?() }
        connections[key] = c
        return c
    }

    func existingConnection(for root: String) -> UnityConnection? { connections[UnityProcessScanner.canonical(root)] }

    /// What the HUD shows: the busiest/most connected known connection, or discovery-only states.
    var summary: UnitySummary {
        if let live = connections.values.filter({ $0.state != .notConfigured }).sorted(by: { $0.state.priority > $1.state.priority }).first {
            return UnitySummary(state: live.state, project: (live.root as NSString).lastPathComponent, version: live.status?.unityVersion, message: live.message, compiling: live.status?.isCompiling ?? false)
        }
        return UnitySummary(state: editors.contains(where: \.available) ? .available : .notConfigured, project: nil, version: nil, message: nil, compiling: false)
    }

    // MARK: Preparing a project for a task

    /// Brings the project's editor to a connected state, or says exactly what is missing. Installation of the bridge and opening the project in
    /// a different editor version change the user's project: they need `approvedInstall` / `approvedUpgrade` (decided by the user through the
    /// normal approval gate before this is called again).
    func prepare(root: String, approvedInstall: Bool, approvedUpgrade: Bool, allowLaunch: Bool = true, progress: ((String) -> Void)? = nil) async -> UnityPrepareOutcome {
        idleShutdown?.cancel(); idleShutdown = nil
        let canonical = UnityProcessScanner.canonical(root)
        guard let descriptor = UnityProjectDetector.describe(root: canonical) else { return .failed(.unityUnavailable, "This folder is not a Unity project (no Assets/, ProjectSettings/ProjectVersion.txt).") }
        let conn = connection(for: canonical)
        conn.descriptor = descriptor
        if conn.transport.currentStatus() != nil { conn.apply(status: conn.transport.currentStatus()); return .ready }

        conn.setState(.discovering)
        refreshEditors()
        let running = UnityProcessScanner.editor(for: canonical, among: scanProcesses())

        if !descriptor.bridgeInstalled || !UnityBridgeInstaller.isCurrent(root: canonical) {
            if !approvedInstall { conn.setState(.available, "The JARVIS bridge package is not installed in this project."); return .needsBridgeInstall }
            do { try installBridge(canonical); conn.descriptor = UnityProjectDetector.describe(root: canonical); progress?("Installed the JARVIS Editor bridge package") }
            catch { conn.setState(.error, "\(error)"); return .failed(.toolFailed, "The bridge package could not be installed: \(error)") }
        }

        if running != nil {
            // The user's own editor has the project open: connect to it, never start or stop one.
            progress?("Waiting for the open Unity editor to load the bridge")
            conn.setState(.connecting)
            if await conn.transport.waitForStatus(timeout: 180, { _ in true }) != nil { conn.apply(status: conn.transport.currentStatus()); return .ready }
            conn.setState(.disconnected, "The Unity editor that has this project open did not start the JARVIS bridge.")
            return .failed(.unityUnavailable, "The Unity editor that has this project open did not start the JARVIS bridge. Focus the editor so it imports the package, then try again.")
        }

        guard allowLaunch else { conn.setState(.available, "No Unity editor has this project open."); return .failed(.unityUnavailable, "No Unity editor has this project open.") }
        let editor: UnityEditorInstall
        switch UnityDiscovery.choose(for: descriptor.declaredVersion, among: editors) {
        case .exact(let e): editor = e
        case .needsUpgradeApproval(let declared, let candidate):
            if !approvedUpgrade { conn.setState(.available, "The project needs Unity \(declared); only \(candidate.version) is installed."); return .needsUpgradeApproval(declared: declared, candidate: candidate.version) }
            editor = candidate
        case .noEditor: conn.setState(.notConfigured, "No Unity editor is installed."); return .failed(.unityUnavailable, "No Unity editor is installed (looked in the Unity Hub folders).")
        case .unknownDeclaredVersion: conn.setState(.error, "ProjectVersion.txt is unreadable"); return .failed(.unityUnavailable, "The project's Unity version could not be read from ProjectSettings/ProjectVersion.txt.")
        }

        progress?("Starting Unity \(editor.version) (first open of a project can take a few minutes)")
        conn.setState(.connecting)
        let owned: any UnityOwnedEditor
        do { owned = try launcher.launch(editor: editor, projectRoot: canonical) }
        catch { conn.setState(.error, "\(error)"); return .failed(.unityUnavailable, "Unity could not be started: \(error)") }
        conn.owned = owned
        var exited = false
        owned.onExit = { exited = true }
        let status = await conn.transport.waitForStatus(timeout: connectTimeout, { _ in true })
        if let status {
            conn.apply(status: status)
            _ = status
            return .ready
        }
        let tail = owned.outputTail
        await owned.terminate()
        conn.owned = nil
        conn.setState(.error, exited ? "Unity exited before the bridge started." : "Unity did not start the bridge in time.")
        return .failed(.unityUnavailable, (exited ? "Unity exited before the JARVIS bridge started. " : "Unity did not start the JARVIS bridge in time. ") + String(tail.suffix(400)))
    }

    // MARK: Ownership & cleanup

    /// Closes the editors JARVIS started (graceful `shutdown` first, then the process tree). A user's editor is never touched.
    func shutdownOwnedEditors() async {
        for conn in connections.values {
            guard let owned = conn.owned else { continue }
            if conn.transport.currentStatus()?.owned == true {
                let session = UnityToolSession(capabilities: CapabilitySet(granted: TaskCapability.unityInspection), taskID: nil, runID: nil, hub: nil, destructiveRequested: false)
                _ = try? await conn.perform(.shutdown, session: session, timeout: 5)
                for _ in 0..<30 where owned.isRunning { try? await Task.sleep(for: .milliseconds(500)) }
            }
            if owned.isRunning { await owned.terminate() }
            conn.owned = nil
            conn.apply(status: conn.transport.currentStatus())
        }
    }

    /// Synchronous kill for application termination (the ProcessRegistry also reaps them; this releases bookkeeping).
    func forgetOwnedEditors() { for c in connections.values { c.owned = nil } }

    func cancelPendingRequests(for root: String) { existingConnection(for: root)?.transport.cancelPending() }
}

struct UnitySummary: Equatable {
    var state: UnityConnectionState
    var project: String?
    var version: String?
    var message: String?
    var compiling: Bool

    var label: String {
        switch state {
        case .connected: compiling ? "Unity · Compiling" : "Unity · Connected"
        case .busy: compiling ? "Unity · Compiling" : "Unity · Busy"
        case .playMode: "Unity · Play Mode"
        case .disconnected: "Unity · Disconnected"
        case .available: "Unity · Available"
        case .connecting: "Unity · Connecting"
        case .discovering: "Unity · Looking"
        case .error: "Unity · Error"
        case .notConfigured: "Unity · Not configured"
        }
    }
}

extension UnityConnectionState {
    var priority: Int {
        switch self { case .playMode: 6; case .busy: 5; case .connected: 4; case .connecting: 3; case .error: 2; case .disconnected: 1; default: 0 }
    }
}
