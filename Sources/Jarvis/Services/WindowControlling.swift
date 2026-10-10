import Foundation

/// The only surface other code (menu bar, views, and — later — the voice/intent layer)
/// uses to control JARVIS's own windows. No caller needs to know about NSWindow/NSPanel.
///
/// Future examples:
///   "Jarvis, show report."      → windows.showFullHUD(section: .report)
///   "Jarvis, close report."     → windows.hideFullHUD()
///   "Jarvis, minimize yourself" → windows.hideFullHUD(); windows.hideCompactHUD()
@MainActor
protocol JarvisWindowControlling: AnyObject {
    var isCompactHUDOpen: Bool { get }
    var isFullHUDOpen: Bool { get }

    func showCompactHUD()
    func hideCompactHUD()
    func toggleCompactHUD()

    /// Opens the Full HUD (or brings it forward) and optionally navigates to a section.
    func showFullHUD(section: HUDSection?)
    func hideFullHUD()
    /// Hidden → show; visible and frontmost → hide; visible but behind other windows → bring forward.
    func toggleFullHUD()
    func bringFullHUDForward()

    func showSettings()
}

extension JarvisWindowControlling {
    func showFullHUD() { showFullHUD(section: nil) }
}
