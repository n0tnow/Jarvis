import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var context: AppContext!
    private var statusItem: StatusItemController!
    private(set) var hotkeys: GlobalHotkeyService!
    private let options = LaunchOptions()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppMenu.install()   // Edit menu → native ⌘C/⌘V/⌘X/⌘A/⌘Z in every text input (accessory apps start with none)
        context = AppContext()
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

        if options.smokeTest {
            let context = context!
            let statusItem = statusItem!
            Task { await SmokeTest.run(context: context, statusItem: statusItem) }
        }
        if let directory = options.captureDirectory {
            let context = context!
            Task { await DevCapture.run(directory: directory, context: context) }
        }
        // Find out which providers are actually usable (event-driven, once; no polling).
        let providers = context.providers
        // Automated runs must NEVER spend subscription quota: providers are stubbed to "not installed" unless the run is
        // the explicit, opt-in live test (or a normal interactive launch).
        if options.smokeTest || options.captureDirectory != nil {
            providers.probeOverride = { id, _ in ProviderStatus(id: id, state: .notInstalled) }
        }
        Task { await providers.refresh() }
        Log.app.info("JARVIS launched")
    }

    /// No provider process may outlive JARVIS.
    func applicationWillTerminate(_ notification: Notification) {
        ProcessRegistry.shared.killAll()
    }

    @objc func showSettings(_ sender: Any?) { context.windows.showSettings() }

    /// Closing HUDs must never quit JARVIS: the menu bar item is the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
