import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var context: AppContext!
    private var statusItem: StatusItemController!
    private let options = LaunchOptions()

    func applicationDidFinishLaunching(_ notification: Notification) {
        context = AppContext()
        statusItem = StatusItemController(context: context)
        context.windowManager.anchorProvider = { [weak self] in self?.statusItem.buttonFrameOnScreen }

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
        Log.app.info("JARVIS launched")
    }

    /// Closing HUDs must never quit JARVIS: the menu bar item is the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
