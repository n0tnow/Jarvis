import AppKit
import SwiftUI

/// AppKit implementation of `JarvisWindowControlling`. All NSWindow/NSPanel logic lives here —
/// views never touch windows directly.
@MainActor
final class WindowManager: NSObject, JarvisWindowControlling, NSWindowDelegate {
    private enum Layout {
        static let compactGap: CGFloat = 6
        static let screenMargin: CGFloat = 8
        static let fullPreferred = NSSize(width: 1480, height: 920)
        static let fullMinimum = NSSize(width: 980, height: 620)
        static let fullScreenFraction: CGFloat = 0.9
    }

    private unowned let context: AppContext

    /// Screen-space frame of the menu bar item; set by the status item controller.
    var anchorProvider: (() -> NSRect?)?

    private var compactPanel: HUDPanel?
    private var compactController: NSHostingController<AnyView>?
    private var fullWindow: FullHUDWindow?
    private var settingsWindow: NSWindow?

    /// Enforced in `windowWillResize` (NSHostingView overwrites `contentMinSize`, so we don't rely on it).
    private(set) var fullMinimumSize = Layout.fullMinimum

    private var lastCompactResignHide = Date.distantPast

    var isCompactHUDOpen: Bool { compactPanel?.isVisible ?? false }
    var isFullHUDOpen: Bool { fullWindow?.isVisible ?? false }

    init(context: AppContext) {
        self.context = context
        super.init()
    }

    // MARK: Compact HUD

    // INVARIANT (V0.1.1): the Compact HUD and the Full HUD are never visible at the same time.
    // It lives here, in the only code that shows these windows — callers (menu bar, hotkeys, views, and any
    // future text/voice/LLM command) get it for free and must not try to "close the other one first".

    func showCompactHUD() {
        hideFullHUD()   // exclusivity: only one primary HUD surface
        let panel = compactPanel ?? makeCompactPanel()
        compactPanel = panel
        positionCompact(panel)
        context.hud.isCompactVisible = true
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        Log.windows.debug("compact HUD shown")
    }

    func hideCompactHUD() {
        guard let panel = compactPanel, panel.isVisible else { return }
        panel.orderOut(nil)
        context.hud.isCompactVisible = false
        Log.windows.debug("compact HUD hidden")
    }

    func toggleCompactHUD() {
        if isCompactHUDOpen {
            hideCompactHUD()
        } else if Date().timeIntervalSince(lastCompactResignHide) > 0.25 {
            // The 0.25s guard stops the click that dismissed the panel (via resign-key) from instantly re-opening it.
            showCompactHUD()
        }
    }

    private func makeCompactPanel() -> HUDPanel {
        let controller = NSHostingController(rootView: AnyView(CompactHUDView().environment(context)))
        controller.sizingOptions = []   // geometry is ours (CompactHUDLayout.size), never SwiftUI's intrinsic size
        compactController = controller

        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: CompactHUDLayout.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configureTransparentChrome(panel)
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.contentViewController = controller
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hideCompactHUD() }
        return panel
    }

    private func positionCompact(_ panel: HUDPanel) {
        panel.setContentSize(CompactHUDLayout.size)
        let size = panel.frame.size
        let anchor = anchorProvider?()
        let screen = screenContaining(anchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation)
        let visible = screen.visibleFrame

        let centerX = anchor?.midX ?? (visible.maxX - size.width / 2 - 12)
        let x = min(max(centerX - size.width / 2, visible.minX + Layout.screenMargin),
                    visible.maxX - size.width - Layout.screenMargin)
        let top = min(anchor?.minY ?? visible.maxY, visible.maxY) - Layout.compactGap
        panel.setFrameOrigin(NSPoint(x: x, y: top - size.height))
    }

    // MARK: Full HUD

    func showFullHUD(section: HUDSection?) {
        if let section { context.hud.section = section }
        hideCompactHUD()
        let window = fullWindow ?? makeFullWindow()
        fullWindow = window
        if !window.isVisible { sizeAndCenter(window) }
        context.hud.isFullHUDVisible = true
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        Log.windows.debug("full HUD shown")
    }

    func hideFullHUD() {
        guard let window = fullWindow, window.isVisible else { return }
        window.orderOut(nil)
        context.hud.isFullHUDVisible = false
        Log.windows.debug("full HUD hidden")
    }

    func toggleFullHUD() {
        guard let window = fullWindow, window.isVisible else { return showFullHUD(section: nil) }
        if window.isKeyWindow && NSApp.isActive { hideFullHUD() } else { bringFullHUDForward() }
    }

    func bringFullHUDForward() {
        hideCompactHUD()   // exclusivity (Full was visible but behind: Compact must not appear next to it)
        if let window = fullWindow, window.isVisible {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            showFullHUD(section: nil)
        }
    }

    private func makeFullWindow() -> FullHUDWindow {
        let host = NSHostingView(rootView: AnyView(FullHUDView().environment(context)))
        host.sizingOptions = []   // window size is ours, not SwiftUI's ideal size

        let window = FullHUDWindow(
            contentRect: NSRect(origin: .zero, size: Layout.fullPreferred),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configureTransparentChrome(window)
        window.level = .normal
        window.hidesOnDeactivate = false       // NSPanel default is true: the HUD must stay when another app is clicked
        window.isFloatingPanel = false
        window.isMovableByWindowBackground = true
        window.contentView = host
        window.delegate = self
        window.onCancel = { [weak self] in self?.hideFullHUD() }
        window.setAccessibilityLabel("JARVIS")
        return window
    }

    /// Large, centered, adapts to the screen under the pointer / menu bar item. Never exceeds the visible area.
    private func sizeAndCenter(_ window: NSWindow) {
        let anchor = anchorProvider?()
        let screen = screenContaining(anchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation)
        let visible = screen.visibleFrame
        let margin = Layout.screenMargin * 2

        let maxSize = NSSize(width: visible.width - margin, height: visible.height - margin)
        let width = min(max(visible.width * Layout.fullScreenFraction, Layout.fullMinimum.width), Layout.fullPreferred.width, maxSize.width)
        let height = min(max(visible.height * Layout.fullScreenFraction, Layout.fullMinimum.height), Layout.fullPreferred.height, maxSize.height)

        fullMinimumSize = NSSize(width: min(Layout.fullMinimum.width, maxSize.width),
                                 height: min(Layout.fullMinimum.height, maxSize.height))
        window.contentMinSize = fullMinimumSize
        window.setFrame(NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height), display: false)
    }

    // MARK: Settings

    func showSettings() {
        hideCompactHUD()
        if settingsWindow == nil {
            let window = SettingsWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 650),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "JARVIS Settings"
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: SettingsView().environment(context))
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Helpers

    private func configureTransparentChrome(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    private func screenContaining(_ point: NSPoint) -> NSScreen {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === compactPanel, window.isVisible else { return }
        lastCompactResignHide = Date()
        hideCompactHUD()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === fullWindow else { return frameSize }
        return NSSize(width: max(frameSize.width, fullMinimumSize.width), height: max(frameSize.height, fullMinimumSize.height))
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === fullWindow, window.isVisible else { return }
        context.hud.isFullHUDVisible = window.occlusionState.contains(.visible)
    }
}
