import AppKit

/// Owns the menu bar item. Left-click toggles the Compact HUD; right-click (or ctrl-click) shows a small menu.
/// The icon redraws on state change; a ~2 Hz timer runs ONLY for animated states and is stopped otherwise.
@MainActor
final class StatusItemController: NSObject {
    private let context: AppContext
    private let statusItem: NSStatusItem
    private var animationTimer: Timer?
    private var frame = 0

    init(context: AppContext) {
        self.context = context
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refresh()

        observeContinuously(
            track: { [context] in
                _ = context.store.state
                _ = context.preferences.effectiveReduceMotion
            },
            onChange: { [weak self] in self?.refresh() }
        )
    }

    // Inspection hooks for the smoke test.
    var button: NSStatusBarButton? { statusItem.button }
    var isAnimationTimerActive: Bool { animationTimer != nil }

    /// Screen-space frame of the status button, used to anchor the Compact HUD under it.
    var buttonFrameOnScreen: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    // MARK: Rendering

    private func refresh() {
        let state = context.store.state
        let shouldAnimate = state.isAnimated && !context.preferences.effectiveReduceMotion
        shouldAnimate ? startTimer() : stopTimer()
        render(state)
    }

    private func render(_ state: JarvisState) {
        guard let button = statusItem.button else { return }
        let image = MenuBarIconRenderer.image(for: state, frame: frame)
        if button.image !== image { button.image = image }
        button.toolTip = "JARVIS — \(state.label.capitalized)"
        button.setAccessibilityLabel("JARVIS")
        button.setAccessibilityValue(state.label.capitalized)
        button.setAccessibilityHelp("Opens the JARVIS compact HUD. Right-click for menu.")
    }

    private func startTimer() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.frame = (self.frame + 1) % MenuBarIconRenderer.frameCount
                self.render(self.context.store.state)
            }
        }
        timer.tolerance = 0.2   // lets the system coalesce wake-ups
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
        frame = 0
    }

    // MARK: Actions

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            showMenu()
        } else {
            context.windows.toggleCompactHUD()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open JARVIS", action: #selector(openFullHUD), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show Compact HUD", action: #selector(openCompactHUD), keyEquivalent: "").target = self
        // V0.15: a one-line truthful status (only when a task is really running) and the voice switch; no sub-menus, nothing that starts work.
        if context.taskEngine.activeCount > 0, let title = context.taskEngine.activeViews.first?.task.title {
            let n = context.taskEngine.activeCount
            let item = menu.addItem(withTitle: "Working: \(String(title.prefix(40)))" + (n > 1 ? " (+\(n - 1))" : ""), action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
        let voiceOn = context.preferences.voiceEnabled
        menu.addItem(withTitle: voiceOn ? "Turn Voice Off" : "Turn Voice On", action: #selector(toggleVoice), keyEquivalent: "").target = self
        // V0.7: with the HUDs closed this is the way to silence JARVIS (the other ways: hold Push-to-Talk, type "stop talking").
        if context.voice.speaker.isActive || context.voice.speaker.isSpeaking {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Stop Speaking", action: #selector(stopSpeaking), keyEquivalent: "").target = self
        }
        // V0.8: wake mode (opt-in) can be switched from here, even with no HUD open. Push-to-Talk is the right ⌥ key.
        if context.preferences.voiceEnabled {
            menu.addItem(.separator())
            let on = context.preferences.voiceWakeEnabled
            let item = menu.addItem(withTitle: on ? "Turn Wake Mode Off" : "Turn Wake Mode On", action: #selector(toggleWake), keyEquivalent: "")
            item.target = self
            // The microphone is in use for the local wake detector only while this says so — never silent.
            let state = menu.addItem(withTitle: "Wake: \(context.handsFree.wakeStatus.label.capitalized)", action: nil, keyEquivalent: "")
            state.isEnabled = false
            if context.handsFree.isSleepingByUser { menu.addItem(withTitle: "Resume Wake Listening", action: #selector(resumeWake), keyEquivalent: "").target = self }
            if case .unavailable(let why) = context.handsFree.wakeStatus {
                let note = menu.addItem(withTitle: "Wake mode unavailable: \(why)", action: nil, keyEquivalent: "")
                note.isEnabled = false
            }
            menu.addItem(withTitle: "Push-to-Talk: hold right ⌥", action: nil, keyEquivalent: "").isEnabled = false
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "System & Readiness", action: #selector(openReadiness), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit JARVIS", action: #selector(quit), keyEquivalent: "q").target = self

        // Temporarily attach the menu so AppKit positions it under the item, then detach so left-click keeps working.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openFullHUD() { context.windows.showFullHUD(section: .dashboard) }
    @objc private func openCompactHUD() { context.windows.showCompactHUD() }
    @objc private func openSettings() { context.windows.showSettings() }
    @objc private func stopSpeaking() { _ = context.voice.stopSpeaking() }
    @objc private func toggleVoice() { context.preferences.voiceEnabled.toggle() }
    @objc private func openReadiness() { context.windows.showFullHUD(section: .system) }
    @objc private func toggleWake() { context.preferences.voiceWakeEnabled.toggle() }
    @objc private func resumeWake() { Task { @MainActor in await context.handsFree.resumeFromSleepMode() } }
    @objc private func quit() { NSApp.terminate(nil) }
}
