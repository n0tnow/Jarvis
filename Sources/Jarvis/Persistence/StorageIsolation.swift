import Foundation

/// Test/production storage separation (V1.0 stabilisation fix 3 — release gate).
///
/// Incident: live tests changed the project selection in the PRODUCTION `UserDefaults` domain (they shared the app's bundle identifier) and one of them
/// (`--continuity-live-test`, whose crash scenario SIGKILLs itself) never restored it, so the installed app showed `jarvis-continuity-fixture` as the current project.
/// Rule: a unit-test process or any developer/live-test launch (an argument starting with `--`) NEVER touches the production defaults domain or the production data directory.
/// They get an isolated defaults suite and a data directory under `JARVIS-LiveTests`. A violation is a hard failure (`fatalError`), not a warning.
enum StorageIsolation {
    /// The explicit developer override to inspect production data from a developer launch. Tests never use it.
    static let overrideFlag = "--use-production-data"
    static let suitePrefix = "dev.jarvis.Jarvis.isolated."

    static var isTestProcess: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil || env["XCTestSessionIdentifier"] != nil || NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.processName.lowercased().contains("xctest") || ProcessInfo.processInfo.processName.contains("swiftpm-testing-helper") || CommandLine.arguments.contains("--test-bundle-path") || Bundle.main.bundlePath.hasSuffix(".xctest") || (Bundle.main.executablePath ?? "").contains("PackageTests")
    }

    /// A unit-test process, or a developer / live-test / smoke / capture launch (without the override). A plain Finder / Spotlight / login launch is the only unprotected run.
    static var isProtectedRun: Bool {
        isTestProcess || (!SingleInstance.isPlainLaunch() && !CommandLine.arguments.contains(overrideFlag))
    }

    nonisolated(unsafe) private static var created: [String] = []
    nonisolated(unsafe) private static var exitHookInstalled = false
    private static let lock = NSLock()

    /// An isolated defaults suite. `tag` nil → unique throw-away suite (removed at process exit); otherwise a stable per-test-kind suite that is wiped now and at exit.
    static func isolatedDefaults(tag: String? = nil) -> UserDefaults {
        let name = suitePrefix + (tag.map { $0.filter { $0.isLetter || $0.isNumber || $0 == "-" } } ?? UUID().uuidString)
        let d = UserDefaults(suiteName: name)!
        guard tag == nil else { return d }                         // a stable per-test-kind suite survives a restart child; `wipe(tag:)` clears it when a run must start fresh
        lock.lock(); created.append(name)
        if !exitHookInstalled { exitHookInstalled = true; atexit { StorageIsolation.cleanup() } }
        lock.unlock()
        return d
    }

    static func wipe(tag: String) {
        UserDefaults().removePersistentDomain(forName: suitePrefix + tag.filter { $0.isLetter || $0.isNumber || $0 == "-" })
    }

    static func cleanup() {
        lock.lock(); let names = created; created = []; lock.unlock()
        for n in names { UserDefaults().removePersistentDomain(forName: n) }
    }

    /// The defaults a run must use: production only for a plain launch; isolated for everything protected.
    static func defaultsForRun(tag: String?) -> UserDefaults {
        isProtectedRun ? isolatedDefaults(tag: tag) : .standard
    }

    /// Hard guard: a protected run handed the production defaults domain fails immediately.
    static func assertNotProduction(_ defaults: UserDefaults) {
        if isProtectedRun, defaults === UserDefaults.standard {
            fatalError("STORAGE ISOLATION VIOLATION: a test / developer launch tried to use the production UserDefaults domain (\(Bundle.main.bundleIdentifier ?? "?")).")
        }
    }

    /// True when `dataRoot` is the production data directory (or inside it). Pure, so the rule itself is unit-tested.
    static func isProductionDataRoot(_ dataRoot: URL) -> Bool {
        JarvisPaths.isInside(dataRoot, directory: JarvisPaths.standard().root) && !JarvisPaths.isInside(dataRoot, directory: JarvisPaths.liveTestsRoot)
    }

    /// Hard guard: a protected run handed the production data directory fails immediately. (The shared READ-ONLY runtime folder — models, venvs — is read from the production tree
    /// through a separate `JarvisPaths` and is never a data root.)
    static func assertNotProduction(dataRoot: URL) {
        if isProtectedRun, isProductionDataRoot(dataRoot) {
            fatalError("STORAGE ISOLATION VIOLATION: a test / developer launch tried to use the production data directory: \(dataRoot.path)")
        }
    }

    /// A project selection that is demonstrably a JARVIS test fixture: a `jarvis-…` folder inside the system temporary area. A genuine project is never there.
    static func isTestFixturePath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        let temp = ["/private/var/folders/", "/var/folders/", "/private/tmp/", "/tmp/"]
        return temp.contains { p.hasPrefix($0) } && URL(fileURLWithPath: p).lastPathComponent.hasPrefix("jarvis-")
    }
}
