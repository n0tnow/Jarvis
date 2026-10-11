import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var context: AppContext!
    private var statusItem: StatusItemController!
    private(set) var hotkeys: GlobalHotkeyService!
    private let options = LaunchOptions()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.installTerminationHandlers()
        AppMenu.install()   // Edit menu → native ⌘C/⌘V/⌘X/⌘A/⌘Z in every text input (accessory apps start with none)
        // Automated runs must NEVER touch real providers or the real database.
        let stubbed = options.noProviders || (!options.providerLiveTest && !options.intelligenceLiveTest && (options.smokeTest || options.captureDirectory != nil))
        let liveData = options.intelligenceLiveTest ? JarvisPaths.standard().root.appendingPathComponent("live-test", isDirectory: true) : nil
        context = AppContext(stubIntelligence: stubbed, dataDirectory: liveData)
        statusItem = StatusItemController(context: context)
        context.windowManager.anchorProvider = { [weak self] in self?.statusItem.buttonFrameOnScreen }

        let windows = context.windows
        hotkeys = GlobalHotkeyService { action in
            switch action {
            case .toggleCompact: windows.toggleCompactHUD()
            case .toggleFull: windows.toggleFullHUD()
            }
        }
        let prefs = context.preferences
        let service = hotkeys!
        observeContinuously(track: { _ = prefs.globalShortcutsEnabled },
                            onChange: { prefs.globalShortcutsEnabled ? service.start() : service.stop() })
        if prefs.globalShortcutsEnabled { service.start() }

        if options.demoAgents { context.observatory.demo?.startShowcase(); context.observatory.selectedRunID = context.hub.activeRuns.first { $0.agentType == "PlannerAgent" }?.id }
        if options.demoStress { context.observatory.selectedRunID = context.observatory.demo?.startStress(linesPerSecond: 400) }
        if let state = options.state { DemoScenario.apply(state, to: context.store) }
        if options.openCompact { context.windows.showCompactHUD() }
        if options.openFull { context.windows.showFullHUD(section: options.section) }

        if let seconds = options.closeAfter {
            let windows = context.windows
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                windows.hideFullHUD(); windows.hideCompactHUD()
            }
        }

        if options.intelligenceLiveTest {
            let context = context!, dir = options.liveDirectory ?? "captures"
            Task { await IntelligenceLiveTest.run(context: context, captureDirectory: dir, benchmark: options.benchmarkModels) }
        }
        if options.providerLiveTest {
            let context = context!, dir = options.liveDirectory ?? "captures"
            Task { await ProviderLiveTest.run(context: context, captureDirectory: dir) }
        }

        if options.smokeTest {
            let context = context!
            let statusItem = statusItem!
            Task { await SmokeTest.run(context: context, statusItem: statusItem) }
        }
        if let directory = options.captureDirectory {
            let context = context!
            Task { await DevCapture.run(directory: directory, context: context) }
        }
        // Find out which engines are actually usable (event-driven, once; no polling). Stubbed runs never touch real providers.
        if !options.intelligenceLiveTest {
            let context = context!
            Task { await context.refreshIntelligence(includeOpenCode: false) }     // OpenCode is read lazily (may start its background service)
        }
        Log.app.info("JARVIS launched")
    }

    /// SIGTERM / SIGINT / SIGHUP (kill, logout, terminal close) skip applicationWillTerminate: clean up provider processes anyway.
    /// (A crash or SIGKILL cannot be intercepted — documented in KNOWN_ISSUES.)
    private static var signalSources: [DispatchSourceSignal] = []
    private static func installTerminationHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { ProcessRegistry.shared.killAll(); exit(128 + sig) }
            source.resume()
            signalSources.append(source)
        }
    }

    /// No provider process may outlive JARVIS.
    func applicationWillTerminate(_ notification: Notification) {
        context?.supervisor.shutdown()          // unload the local model worker (it also exits by itself when stdin closes)
        ProcessRegistry.shared.killAll()
    }

    @objc func showSettings(_ sender: Any?) { context.windows.showSettings() }

    /// Closing HUDs must never quit JARVIS: the menu bar item is the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
