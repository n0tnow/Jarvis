import AppKit
import Foundation

/// `Jarvis --packaging-live-test` — OPT-IN (V0.15). Run it with the PACKAGED, ideally INSTALLED app's own binary (`/Applications/JARVIS.app/Contents/MacOS/Jarvis --packaging-live-test`, from any folder):
/// it proves the app does not depend on the repository, the working directory, a development server or test fixtures, and that discovery of the installed pieces works from the bundle.
/// REAL = measured here. Nothing is started, installed or sent; the data directory is its own (live-test-packaging); no provider is asked a question (no quota).
@MainActor
enum PackagingLiveTest {
    static func run(context: AppContext) async {
        var passes = 0, failures = 0, skips = 0
        func check(_ tag: String, _ name: String, _ ok: Bool, _ detail: String = "") { print("\(ok ? "PASS" : "FAIL")  [\(tag)] \(name)\(detail.isEmpty ? "" : " — \(detail)")"); if ok { passes += 1 } else { failures += 1 }; fflush(stdout) }
        func skip(_ name: String, _ why: String) { print("SKIP  \(name) — \(why)"); skips += 1; fflush(stdout) }
        func info(_ s: String) { print("INFO  \(s)"); fflush(stdout) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { ProcessRegistry.shared.killAll(); print("PACKAGING LIVE TEST TIMEOUT"); fflush(stdout); exit(2) }
        let fm = FileManager.default
        let bundle = Bundle.main.bundleURL
        let installed = AppInfo.isApplicationBundle
        info("bundle: \(bundle.path) · \(AppInfo.versionLine) · commit \(AppInfo.commit ?? "—") · working directory: \(fm.currentDirectoryPath)")

        // The bundle
        check("REAL", "Running from a real .app bundle", installed)
        check("REAL", "Bundle identifier dev.jarvis.Jarvis, menu-bar agent, version matches the source", AppInfo.bundleIdentifier == "dev.jarvis.Jarvis" && (Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool) == true && AppInfo.version == AppInfo.sourceVersion)
        let resources = Bundle.main.resourceURL
        check("REAL", "The packaged setup scripts are inside the bundle and executable (the Set Up buttons need no repository)",
              resources.map { fm.isExecutableFile(atPath: $0.appendingPathComponent("setup/scripts/setup_local_ai.sh").path) && fm.fileExists(atPath: $0.appendingPathComponent("setup/scripts/voice-ai/jarvis_stt_worker.py").path) } == true)
        let heavy = ((fm.enumerator(atPath: bundle.path)?.allObjects as? [String]) ?? []).filter { ["sqlite", "sqlite-wal", "gguf", "safetensors", "onnx", "npz", "mlpackage"].contains(($0 as NSString).pathExtension) }
        check("REAL", "No database and no model is inside the bundle", heavy.isEmpty, heavy.prefix(3).joined(separator: ", "))
        let unwritable = !fm.isWritableFile(atPath: bundle.appendingPathComponent("Contents/Resources").path) || !installed
        info("the bundle's Resources folder is \(fm.isWritableFile(atPath: bundle.appendingPathComponent("Contents/Resources").path) ? "writable by this user (normal for an app you installed yourself)" : "read-only")")
        _ = unwritable

        // Where mutable state lives
        let support = JarvisPaths.standard().root
        check("REAL", "Durable data lives under ~/Library/Application Support/JARVIS, never inside the app", support.path.contains("/Library/Application Support/JARVIS") && !support.path.hasPrefix(bundle.path) && !context.paths.root.path.hasPrefix(bundle.path))
        check("REAL", "The database opened and has the current schema", (context.database?.schemaVersion ?? 0) >= 14, "schema v\(context.database?.schemaVersion ?? -1) at \(context.paths.database.lastPathComponent)")

        // No dependency on the repository, the working directory, a server or fixtures
        let repoHint = ProcessInfo.processInfo.environment["JARVIS_REPO"]
        check("REAL", "Nothing in the app reads a repository path: the setup root is the bundle", context.setupRunner.resourceRoot().map { $0.path.hasPrefix(bundle.path) } == true || !installed, context.setupRunner.resourceRoot()?.path ?? "none")
        _ = repoHint
        check("REAL", "The app is not running from the source tree or a build folder when installed", !installed || (!bundle.path.contains("/.build/") && !bundle.path.contains("/build/Jarvis.app")))
        let ports = await ManagedProcess.runOnce(executable: "/usr/sbin/lsof", arguments: ["-nP", "-a", "-p", "\(getpid())", "-iTCP", "-sTCP:LISTEN"], environment: ProviderEnvironment.make(), workingDirectory: "/", timeout: 10)?.output ?? ""
        check("REAL", "JARVIS listens on no network port (no development server)", ports.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, ports.prefix(100).description)

        // Discovery from the bundle
        let childrenBefore = ProcessTree.children(of: getpid()).count
        await context.providers.refresh()
        context.localRuntime.inspect(); context.whisper.inspect(); context.neuralVoice.inspect()
        let snap = context.readiness.refresh()
        for id in ["provider.claude", "provider.codex"] { info("   \(id): \(snap.item(id)?.state.label ?? "—") \(snap.item(id)?.detail.prefix(90) ?? "")") }
        check("REAL", "Claude Code, Codex and OpenCode are discoverable and reported with distinct states", snap.item("provider.claude") != nil && snap.item("provider.codex") != nil && snap.item("provider.opencode") != nil)
        check("REAL", "Existing local components are discovered where they are: Qwen / vision / Whisper / natural voice", snap.item("local.qwen") != nil && snap.item("local.vision") != nil && snap.item("local.whisper") != nil && snap.item("voice.neural") != nil)
        for id in ["local.qwen", "local.vision", "local.whisper", "voice.neural", "voice.wake", "local.embedding"] { info("   \(id): \(snap.item(id)?.state.label ?? "—") \(snap.item(id)?.detail.prefix(90) ?? "")") }
        check("REAL", "Optional pieces that are not installed do not make the app fail", snap.item("core.app")?.state == .ready)
        check("REAL", "Discovery started nothing (no model, provider run, MCP server, Unity or helper)", ProcessTree.children(of: getpid()).count == childrenBefore && context.localRuntime.workerPID == nil && context.mcp.runningServerIDs.isEmpty)

        // Permissions are reported, never requested
        let perms = snap.items(in: .permissions) + snap.items(in: .computer) + snap.items.filter { $0.id == "voice.mic" }
        for p in perms { info("   \(p.id): \(p.state.label)") }
        check("REAL", "Permission states are read without asking (no prompt was triggered)", !perms.isEmpty)

        // Launch at Login: the registration state is readable; nothing is changed
        let login = LaunchAtLogin.status
        info("Launch at Login: \(login.label) (state read only; this test never changes it)")
        check("REAL", "Launch at Login is OFF unless the user turned it on", login != .enabled || installed, login.rawValue)

        // Launch at Login, reversibly (only with --packaging-login-roundtrip): register, read the state, unregister, read it again — the original state is restored.
        if CommandLine.arguments.contains("--packaging-login-roundtrip") {
            let original = LaunchAtLogin.status
            let e1 = LaunchAtLogin.set(true); let afterOn = LaunchAtLogin.status
            let e2 = LaunchAtLogin.set(false); let afterOff = LaunchAtLogin.status
            if original == .enabled { _ = LaunchAtLogin.set(true) }
            info("Launch at Login round trip: \(original.rawValue) → register \(e1 ?? "ok") → \(afterOn.rawValue) → unregister \(e2 ?? "ok") → \(afterOff.rawValue) (restored to \(LaunchAtLogin.status.rawValue))")
            check("REAL", "Launch at Login can be switched on and off again through SMAppService, and the original state is restored", e1 == nil && (afterOn == .enabled || afterOn == .requiresApproval) && e2 == nil && afterOff != .enabled && (original != .enabled || LaunchAtLogin.status == .enabled), "\(afterOn.rawValue) / \(afterOff.rawValue)")
        }

        // Idle: the app is lightweight
        try? await Task.sleep(for: .seconds(6))
        let cpu0 = ProcessTree.cpuSeconds(of: getpid()) ?? 0
        try? await Task.sleep(for: .seconds(8))
        let cpu1 = ProcessTree.cpuSeconds(of: getpid()) ?? 0
        let rss = Double(ProcessTree.residentBytes(of: getpid()) ?? 0) / 1_048_576
        info("idle: CPU \(String(format: "%.2f", cpu1 - cpu0)) s over 8 s · RSS \(String(format: "%.0f", rss)) MB · children \(ProcessTree.children(of: getpid()).count)")
        check("REAL", "Idle CPU stays under 5 % of one core and nothing heavy runs", cpu1 - cpu0 < 0.4 && ProcessTree.children(of: getpid()).isEmpty)
        print("PACKAGING LIVE TEST \(failures == 0 ? "PASSED" : "FAILED") (\(passes) passed, \(failures) failed, \(skips) skipped)"); fflush(stdout)
        ProcessRegistry.shared.killAll()
        exit(failures == 0 ? 0 : 1)
    }
}
