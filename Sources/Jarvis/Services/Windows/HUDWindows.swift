import AppKit

/// Borderless floating panel for the Compact HUD. Must be able to become key so the command field can type.
final class HUDPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// ESC (when no text field consumes it).
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Standard Settings window; an accessory app has no menu bar, so ESC and ⌘W must be handled here.
final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Borderless, resizable, transparent window for the Full HUD.
/// Rounded glass chrome is drawn by SwiftUI; the window itself is clear.
final class FullHUDWindow: NSWindow {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// ESC (when no text field consumes it).
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// ⌘W closes, like a normal macOS window (an accessory app has no menu bar to supply this).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            onCancel?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
