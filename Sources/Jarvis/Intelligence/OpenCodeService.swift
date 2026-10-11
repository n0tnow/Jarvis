import Foundation
import Observation

/// Discovers OpenCode, reads its model catalog + prices, and keeps the verified-free registry current.
/// CLI-per-task (docs/OPENCODE_RESEARCH.md): no daemon is kept alive. JARVIS makes no network request itself —
/// `opencode models --refresh` is OpenCode's own refresh of its models.dev snapshot.
@MainActor
@Observable
final class OpenCodeService {
    private(set) var state: ProviderState = .unknown
    private(set) var version: String?
    private(set) var executablePath: String?
    private(set) var models: [ModelRecord] = []
    private(set) var lastCatalogRefresh: Date?
    private(set) var isRefreshing = false
    private(set) var capabilities: OpenCodeCapabilities?

    @ObservationIgnored private let repository: JarvisRepository?
    @ObservationIgnored private let locator: ExecutableLocator
    @ObservationIgnored private let environmentBase: [String: String]
    @ObservationIgnored private let preferences: Preferences?
    @ObservationIgnored let providerWorkspace: String
    /// Test hook: replaces running the real CLI. Returns (versionOutput, catalogOutput) or nil on failure.
    @ObservationIgnored var catalogOverride: (@Sendable (Bool) async -> (version: String, catalog: String)?)?
    /// Automated runs (smoke/capture/--no-providers): behave as "not installed", never touch the real binary or its service.
    @ObservationIgnored var isStubbed = false
    @ObservationIgnored var testExecutablePath: String?
    @ObservationIgnored var capabilityOverride: OpenCodeCapabilities?
    @ObservationIgnored var onEvent: ((String) -> Void)?
    /// The ONLY `opencode api` operation JARVIS ever invokes (documented; returns model metadata, never credentials).
    static let modelListArguments = ["api", "model.list"]
    static let catalogPollAttempts = 8
    static var catalogPollInterval = 2.5

    init(repository: JarvisRepository?, preferences: Preferences?, locator: ExecutableLocator = .forThisMac(),
         environmentBase: [String: String] = ProcessInfo.processInfo.environment, providerWorkspace: String) {
        self.repository = repository
        self.preferences = preferences
        self.locator = locator
        self.environmentBase = environmentBase
        self.providerWorkspace = providerWorkspace
        models = (try? repository?.models(engine: .openCode)) ?? []
    }

    /// Empty unless OpenCode is currently READY (supported CLI generation, catalog read) — stale persisted data never counts.
    var freePool: [ModelRecord] { state == .ready ? models.filter { $0.isFreePoolMember && OpenCodeModelRegistry.isVerificationFresh($0) } : [] }
    var verificationIsFresh: Bool { lastCatalogRefresh.map { Date().timeIntervalSince($0) < OpenCodeModelRegistry.verificationMaxAge } ?? false }

    func environment() -> [String: String] {
        var env = ProviderEnvironment.make(base: environmentBase, extraPath: locator.extraPathDirectories())
        for (k, v) in OpenCodeWorkspace.environment { env[k] = v }
        return env
    }

    /// Re-reads provider data. `remote: true` asks OpenCode to refresh its models.dev snapshot first (≈2 s).
    func refresh(remote: Bool = true) async {
        guard !isRefreshing else { return }
        if isStubbed { state = .notInstalled; return }
        isRefreshing = true
        defer { isRefreshing = false }
        let env = environment()
        let override = preferences?.openCodePathOverride
        let candidates = locator.candidates(for: .openCode, override: (override?.isEmpty ?? true) ? nil : override)

        var versionText = "", catalogText = ""
        var caps = OpenCodeCapabilities.verifiedClassic
        if let hook = catalogOverride {
            guard let r = await hook(remote) else { state = .unavailable("catalog unavailable"); return }
            versionText = r.version; catalogText = r.catalog
            caps = capabilityOverride ?? .verifiedClassic
            capabilities = caps
            executablePath = testExecutablePath ?? executablePath ?? "/test/opencode"
        } else {
            guard let path = candidates.first else { state = .notInstalled; executablePath = nil; version = nil; return }
            executablePath = path
            guard let v = await ManagedProcess.runOnce(executable: path, arguments: ["--version"], environment: env, timeout: 10), v.exitCode == 0 else {
                state = .unavailable("version check failed"); return
            }
            versionText = v.output
            version = ExecutableLocator.parseVersion(versionText)?.display
            // The CLI changed between generations: read its own help to learn what it supports BEFORE relying on any flag.
            async let mh = ManagedProcess.runOnce(executable: path, arguments: ["models", "--help"], environment: env, timeout: 15)
            async let rh = ManagedProcess.runOnce(executable: path, arguments: ["run", "--help"], environment: env, timeout: 15)
            async let ah = ManagedProcess.runOnce(executable: path, arguments: ["api", "--help"], environment: env, timeout: 15)
            let (modelsHelp, runHelp, apiHelp) = await (mh, rh, ah)
            func text(_ r: ManagedProcess.RunResult?) -> String { (r?.output ?? "") + (r?.errorOutput ?? "") }
            caps = OpenCodeCapabilities.parse(modelsHelp: text(modelsHelp), runHelp: text(runHelp), apiHelp: text(apiHelp))
            capabilities = caps
            if let why = caps.unsupportedReason(version: version) {
                state = .unavailable(why)
                onEvent?("OpenCode \(version ?? "?") isn't supported — free pool disabled")
                return
            }
            switch caps.catalogSource {
            case .modelsVerbose:
                var args = ["models", "--pure", "--verbose"]
                if remote { args.append("--refresh") }
                guard let c = await ManagedProcess.runOnce(executable: path, arguments: args, environment: env, timeout: 45, maxOutput: 4 * 1024 * 1024),
                      c.exitCode == 0, !c.timedOut else { state = .unavailable("model catalog unavailable"); return }
                catalogText = c.output
            case .apiModelList:
                // The documented operation `model.list` (OpenCode's own client talking to OpenCode's own server). Only this ONE
                // fixed operation id is ever passed — never credential/integration operations. The server's snapshot "may precede
                // initial plugin settlement", so an empty answer is retried a bounded number of times.
                var got = ""
                for attempt in 0..<Self.catalogPollAttempts {
                    if attempt > 0 { try? await Task.sleep(for: .seconds(Self.catalogPollInterval)) }
                    guard let c = await ManagedProcess.runOnce(executable: path, arguments: Self.modelListArguments, environment: env, timeout: 30, maxOutput: 8 * 1024 * 1024),
                          c.exitCode == 0, !c.timedOut else { continue }
                    if !OpenCodeCatalog.parseModelList(c.output).isEmpty { got = c.output; break }
                }
                guard !got.isEmpty else { state = .unavailable("model list not ready (the OpenCode service returned no models)"); return }
                catalogText = got
            case .none:
                state = .unavailable("no catalog source"); return
            }
        }
        version = ExecutableLocator.parseVersion(versionText)?.display

        let infos = caps.catalogSource == .apiModelList ? OpenCodeCatalog.parseModelList(catalogText) : OpenCodeCatalog.parse(catalogText)
        guard !infos.isEmpty else { state = .unavailable("model catalog was empty or unreadable"); return }
        let now = Date()
        let source = caps.catalogSource == .apiModelList ? "opencode api model.list · opencode \(version ?? "?")"
                                                         : "opencode models --verbose\(remote ? " --refresh" : "") · opencode \(version ?? "?")"
        var records: [ModelRecord] = []
        let existing = Dictionary(uniqueKeysWithValues: ((try? repository?.models(engine: .openCode)) ?? models).map { ($0.id, $0) })
        for info in infos {
            let rec = OpenCodeModelRegistry.record(from: info, verifiedAt: now, source: source, existing: existing[info.fullID])
            records.append(rec)
            try? repository?.upsert(rec)
        }
        // Models that disappeared from the catalog are no longer available (and therefore not free-pool members).
        for old in existing.values where !infos.contains(where: { $0.fullID == old.id }) {
            var gone = old; gone.availability = .unavailable; gone.freeVerified = false; gone.blockedReason = "provider data: no longer listed"
            try? repository?.upsert(gone); records.append(gone)
        }
        models = records.sorted { $0.id < $1.id }
        lastCatalogRefresh = now
        state = .ready
        let n = freePool.count
        onEvent?("Free model registry refreshed (\(n) verified free)")
    }

    func model(_ id: String) -> ModelRecord? { models.first { $0.id == id } }

    /// Builds the launchable provider for ONE verified-free model; nil for anything else (DEC-022).
    func provider(for model: ModelRecord) -> CLIProvider? {
        guard state == .ready, let caps = capabilities, caps.isSupported, let spec = OpenCodeSpec.make(for: model, flavor: caps.runFlavor), let path = executablePath,
              let dir = try? OpenCodeWorkspace.prepare(under: providerWorkspace, flavor: caps.runFlavor) else { return nil }
        return CLIProvider(spec: spec, executablePath: path, workingDirectory: dir, environment: environment(), idleTimeout: 120, totalTimeout: 600)
    }

    /// The API said the model is gone (404/410) although the catalog still lists it: block it now (persisted, sticky for 24 h).
    func markModelGone(_ id: String, at now: Date = Date()) {
        guard var m = models.first(where: { $0.id == id }) else { return }
        m.availability = .unavailable; m.freeVerified = false; m.blockedReason = OpenCodeModelRegistry.removedMarker; m.lastHealthCheck = now
        try? repository?.upsert(m)
        if let i = models.firstIndex(where: { $0.id == id }) { models[i] = m }
        onEvent?("\(m.displayName) was removed by the provider — blocked")
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        try? repository?.setModelEnabled(id, enabled, reason: "disabled by user")
        if let i = models.firstIndex(where: { $0.id == id }) {
            models[i].enabled = enabled; models[i].blockedReason = enabled ? nil : "disabled by user"
        }
    }

    /// Reload benchmark status etc. after the benchmark runner wrote results.
    func reloadFromStore() { models = (try? repository?.models(engine: .openCode)) ?? models }
}
