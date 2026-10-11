import Foundation
import Observation

/// Discovers providers, knows whether each is actually USABLE (installed ≠ authenticated ≠ ready), picks one,
/// tracks the running/rate-limited state and per-provider conversation sessions.
/// Never reads credentials: readiness comes from the vendors' own status commands (`claude auth status`, `codex login status`).
@MainActor
@Observable
final class ProviderManager: IntelligenceProviderResolving {
    /// Deterministic Auto rule (documented): first READY of this order. Claude Code first because it streams token by token.
    static let autoOrder: [ProviderID] = [.claudeCode, .codex]

    private(set) var statuses: [ProviderID: ProviderStatus] = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, ProviderStatus(id: $0)) })
    private(set) var isRefreshing = false
    private(set) var activeProvider: ProviderID?
    private(set) var lastRefresh: Date?

    @ObservationIgnored private let preferences: Preferences?
    @ObservationIgnored private let locator: ExecutableLocator
    @ObservationIgnored private let environmentBase: [String: String]
    @ObservationIgnored let workingDirectory: String
    @ObservationIgnored private var sessions: [ProviderID: String] = [:]
    @ObservationIgnored private var probeTimeout: TimeInterval
    /// Test hook: override how a status is computed (no real processes).
    @ObservationIgnored var probeOverride: (@Sendable (ProviderID, String?) async -> ProviderStatus)?

    init(preferences: Preferences?, locator: ExecutableLocator = .forThisMac(),
         environmentBase: [String: String] = ProcessInfo.processInfo.environment,
         workingDirectory: String? = nil, probeTimeout: TimeInterval = 15) {
        self.preferences = preferences
        self.locator = locator
        self.environmentBase = environmentBase
        self.probeTimeout = probeTimeout
        self.workingDirectory = workingDirectory ?? Self.defaultWorkingDirectory()
    }

    /// An empty private directory: providers never see the user's projects, CLAUDE.md or repositories.
    static func defaultWorkingDirectory() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("JARVIS/provider-workspace", isDirectory: true).path
    }

    var preference: ProviderPreference {
        get { preferences?.providerPreference ?? .auto }
        set { preferences?.providerPreference = newValue }
    }

    func status(_ id: ProviderID) -> ProviderStatus { statuses[id] ?? ProviderStatus(id: id) }

    /// The provider that WOULD serve a reasoning request right now (for UI), or nil.
    var selectedProvider: ProviderID? {
        let order = preference.providerID.map { [$0] } ?? Self.autoOrder
        return order.first { status($0).state.isUsable || status($0).state == .running }
    }

    // MARK: Discovery + readiness

    private func override(for id: ProviderID) -> String? {
        let v = id == .claudeCode ? preferences?.claudePathOverride : preferences?.codexPathOverride
        return (v?.isEmpty ?? true) ? nil : v
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false; lastRefresh = Date() }
        let locator = self.locator, env = ProviderEnvironment.make(base: environmentBase, extraPath: locator.extraPathDirectories())
        let timeout = probeTimeout
        let overrides = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, override(for: $0)) })
        let probe = probeOverride
        let results = await withTaskGroup(of: ProviderStatus.self) { group -> [ProviderStatus] in
            for id in ProviderID.allCases {
                let ov = overrides[id] ?? nil
                group.addTask {
                    if let probe { return await probe(id, ov) }
                    return await ProviderProbe.check(id, locator: locator, override: ov, environment: env, timeout: timeout)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        for fresh in results {
            let old = status(fresh.id)
            var merged = fresh
            // Don't clobber a live run, and keep a still-valid rate-limit.
            if old.state == .running { merged.state = .running }
            if case .rateLimited(let until) = old.state, fresh.state == .ready, let until, until > Date() { merged.state = old.state }
            statuses[fresh.id] = merged
        }
    }

    // MARK: IntelligenceProviderResolving

    var hasProviders: Bool { statuses.values.contains { $0.state.isUsable } }

    func resolve(_ kind: IntelligenceRequestKind) async -> ProviderResolution {
        guard kind == .reasoning else { return .unavailable(.noProviderReady(summary: "Autonomous work isn't enabled yet.")) }
        if lastRefresh == nil { await refresh() }                       // first use: find out what is actually ready
        let order = preference.providerID.map { [$0] } ?? Self.autoOrder
        for id in order {
            let st = status(id)
            if case .rateLimited(let until) = st.state, let until, until <= Date() { statuses[id]?.state = .ready }
            if status(id).state.isUsable, let path = st.executablePath { return .ready(ResolvedProvider(provider: makeProvider(id, path: path), id: id)) }
        }
        if let explicit = preference.providerID { return .unavailable(error(for: status(explicit))) }
        return .unavailable(.noProviderReady(summary: summary()))
    }

    func makeProvider(_ id: ProviderID, path: String) -> CLIProvider {
        CLIProvider(spec: id == .claudeCode ? ClaudeCodeSpec() : CodexSpec(), executablePath: path, workingDirectory: workingDirectory,
                    environment: ProviderEnvironment.make(base: environmentBase, extraPath: locator.extraPathDirectories()))
    }

    func error(for status: ProviderStatus) -> ProviderError {
        switch status.state {
        case .notInstalled: .notInstalled(status.id)
        case .authenticationRequired: .authenticationRequired(status.id)
        case .rateLimited(let until): .rateLimited(status.id, resetsAt: until)
        case .running: .busy
        case .unavailable(let why), .failed(let why): .unavailable(status.id, why)
        case .unknown, .ready: .unavailable(status.id, "not checked")
        }
    }

    private func summary() -> String {
        ProviderID.allCases.map { "\($0.displayName): \(status($0).state.label.lowercased())." }.joined(separator: " ")
    }

    func sessionID(for id: ProviderID?) -> String? { id.flatMap { sessions[$0] } }
    func recordSession(_ session: String, for id: ProviderID?) { if let id { sessions[id] = session } }
    func resetSessions() { sessions.removeAll() }

    func providerStarted(_ id: ProviderID?) {
        guard let id else { return }
        activeProvider = id
        statuses[id]?.state = .running
    }

    func providerFinished(_ id: ProviderID?, outcome: ProviderOutcome) {
        guard let id else { return }
        if activeProvider == id { activeProvider = nil }
        switch outcome {
        case .completed, .cancelled: statuses[id]?.state = .ready
        case .failed(let e):
            switch e {
            case .authenticationRequired: statuses[id]?.state = .authenticationRequired
            case .notInstalled: statuses[id]?.state = .notInstalled
            case .rateLimited(_, let reset): statuses[id]?.state = .rateLimited(until: reset ?? Date().addingTimeInterval(15 * 60))
            case .sessionLost: sessions[id] = nil; statuses[id]?.state = .ready
            default: statuses[id]?.state = .ready          // transient (network, crash, timeout): usable again next time
            }
        }
    }

    /// App termination: no provider process may outlive JARVIS.
    func shutdown() { ProcessRegistry.shared.killAll() }
}

/// Real discovery + auth probes (the only place that launches provider executables for status).
enum ProviderProbe {
    static func check(_ id: ProviderID, locator: ExecutableLocator, override: String?,
                      environment: [String: String], timeout: TimeInterval) async -> ProviderStatus {
        var status = ProviderStatus(id: id)
        let candidates = locator.candidates(for: id, override: override)
        guard !candidates.isEmpty else { status.state = .notInstalled; return status }

        // Several installs can coexist (e.g. native + Homebrew): use the highest version.
        var best: (path: String, display: String, parts: [Int])?
        for path in candidates {
            guard let r = await ManagedProcess.runOnce(executable: path, arguments: ["--version"], environment: environment, timeout: 8),
                  r.exitCode == 0, let v = ExecutableLocator.parseVersion(r.output) else { continue }
            if best == nil || ExecutableLocator.isNewer(v.parts, than: best!.parts) { best = (path, v.display, v.parts) }
        }
        guard let best else { status.state = .unavailable("version check failed"); status.executablePath = candidates.first; return status }
        status.executablePath = best.path
        status.version = best.display

        let args = id == .claudeCode ? ["auth", "status"] : ["login", "status"]
        guard let auth = await ManagedProcess.runOnce(executable: best.path, arguments: args, environment: environment, timeout: timeout) else {
            status.state = .unavailable("auth check failed to launch"); return status
        }
        if auth.timedOut { status.state = .unavailable("auth check timed out") }
        else if auth.exitCode == 0 { status.state = .ready }
        else if auth.exitCode == 1 { status.state = .authenticationRequired }
        else { status.state = .unavailable("auth check exit \(auth.exitCode)") }
        return status
    }
}
