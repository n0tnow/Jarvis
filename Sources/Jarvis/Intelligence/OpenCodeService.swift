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

    @ObservationIgnored private let repository: JarvisRepository?
    @ObservationIgnored private let locator: ExecutableLocator
    @ObservationIgnored private let environmentBase: [String: String]
    @ObservationIgnored private let preferences: Preferences?
    @ObservationIgnored let providerWorkspace: String
    /// Test hook: replaces running the real CLI. Returns (versionOutput, catalogOutput) or nil on failure.
    @ObservationIgnored var catalogOverride: (@Sendable (Bool) async -> (version: String, catalog: String)?)?
    @ObservationIgnored var testExecutablePath: String?
    @ObservationIgnored var onEvent: ((String) -> Void)?

    init(repository: JarvisRepository?, preferences: Preferences?, locator: ExecutableLocator = .forThisMac(),
         environmentBase: [String: String] = ProcessInfo.processInfo.environment, providerWorkspace: String) {
        self.repository = repository
        self.preferences = preferences
        self.locator = locator
        self.environmentBase = environmentBase
        self.providerWorkspace = providerWorkspace
        models = (try? repository?.models(engine: .openCode)) ?? []
    }

    var freePool: [ModelRecord] { models.filter { $0.isFreePoolMember && OpenCodeModelRegistry.isVerificationFresh($0) } }
    var verificationIsFresh: Bool { lastCatalogRefresh.map { Date().timeIntervalSince($0) < OpenCodeModelRegistry.verificationMaxAge } ?? false }

    func environment() -> [String: String] {
        var env = ProviderEnvironment.make(base: environmentBase, extraPath: locator.extraPathDirectories())
        for (k, v) in OpenCodeWorkspace.environment { env[k] = v }
        return env
    }

    /// Re-reads provider data. `remote: true` asks OpenCode to refresh its models.dev snapshot first (≈2 s).
    func refresh(remote: Bool = true) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let env = environment()
        let override = preferences?.openCodePathOverride
        let candidates = locator.candidates(for: .openCode, override: (override?.isEmpty ?? true) ? nil : override)

        var versionText = "", catalogText = ""
        if let hook = catalogOverride {
            guard let r = await hook(remote) else { state = .unavailable("catalog unavailable"); return }
            versionText = r.version; catalogText = r.catalog
            executablePath = testExecutablePath ?? executablePath ?? "/test/opencode"
        } else {
            guard let path = candidates.first else { state = .notInstalled; executablePath = nil; version = nil; return }
            executablePath = path
            guard let v = await ManagedProcess.runOnce(executable: path, arguments: ["--version"], environment: env, timeout: 10), v.exitCode == 0 else {
                state = .unavailable("version check failed"); return
            }
            versionText = v.output
            var args = ["models", "--pure", "--verbose"]
            if remote { args.append("--refresh") }
            guard let c = await ManagedProcess.runOnce(executable: path, arguments: args, environment: env, timeout: 45, maxOutput: 4 * 1024 * 1024),
                  c.exitCode == 0, !c.timedOut else { state = .unavailable("model catalog unavailable"); return }
            catalogText = c.output
        }
        version = ExecutableLocator.parseVersion(versionText)?.display

        let infos = OpenCodeCatalog.parse(catalogText)
        guard !infos.isEmpty else { state = .unavailable("model catalog was empty or unreadable"); return }
        let now = Date()
        let source = "opencode models --verbose\(remote ? " --refresh" : "") · opencode \(version ?? "?")"
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
        guard let spec = OpenCodeSpec.make(for: model), let path = executablePath,
              let dir = try? OpenCodeWorkspace.prepare(under: providerWorkspace) else { return nil }
        return CLIProvider(spec: spec, executablePath: path, workingDirectory: dir, environment: environment(), idleTimeout: 120, totalTimeout: 600)
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
