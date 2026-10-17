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

/// Borderless, resizable, transparent window for the Full HUD.
/// Rounded glass chrome is drawn by SwiftUI; the window itself is clear.
///
/// It is a NON-ACTIVATING panel on purpose: when JARVIS is opened from another app (global shortcut), macOS does
/// not honour `NSApp.activate()` for an accessory app, so a regular window would stay non-key and could not
/// receive typing or ⌘V until clicked. A non-activating panel can become key without app activation.
final class FullHUDWindow: NSPanel {
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
