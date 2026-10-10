import AppKit
import SwiftUI

/// What a key press in the composer should do. Pure, so it is unit-tested without a keyboard.
enum ComposerKeyPolicy {
    enum Action: Equatable { case submit, newline }

    /// Return submits. Shift/Option+Return insert a newline. ⌘Return submits too. While an input method has
    /// marked (uncommitted) text, Return belongs to the IME and must neither submit nor insert a newline.
    static func actionForReturn(shift: Bool, option: Bool, hasMarkedText: Bool) -> Action? {
        if hasMarkedText { return nil }
        return (shift || option) ? .newline : .submit
    }
}

/// `NSTextView` that always pastes PLAIN text (code/logs often come from rich sources) and keeps typing
/// substitutions off, because the input is for prompts, code, JSON and logs.
final class ComposerTextView: NSTextView {
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    /// Standard editing commands keep working even if a menu item is momentarily unavailable.
    override var acceptsFirstResponder: Bool { true }
}

/// Reusable native-backed multiline composer.
///
///  • Native editing (⌘C/⌘V/⌘X/⌘A/⌘Z/⇧⌘Z, context menu, Services, IME, spell-free) comes from NSTextView + the main menu.
///  • Return → submit · Shift/Option+Return → newline · pasted newlines are just text (they never submit).
///  • Height follows content between 1 and `maxLines` lines, then scrolls INSIDE; `maxLines == 1` is a fixed
///    single line with internal scrolling (the Compact HUD must never change size).
///  • Reads the pasteboard only when the user pastes (native paste). No clipboard monitoring, no logging.
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    var maxLines: Int
    var focusTrigger: Bool
    var onSubmit: () -> Void
    var onEscape: () -> Void
    @Binding var height: CGFloat

    static let font = NSFont.systemFont(ofSize: 13)
    static var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) + 2 }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let tv = ComposerTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = Self.font
        tv.textColor = NSColor.white.withAlphaComponent(Theme.Opacity.textPrimary)
        tv.insertionPointColor = NSColor(Theme.Palette.accent)
        tv.selectedTextAttributes = [.backgroundColor: NSColor(Theme.Palette.accent).withAlphaComponent(0.35)]
        tv.textContainerInset = NSSize(width: 0, height: 1)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        // Prompts, code, JSON and logs: no smart substitutions or autocorrect.
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.setAccessibilityLabel("Command input")
        tv.setAccessibilityIdentifier("command.field")
        tv.setAccessibilityHelp("Type a command and press Return. Shift Return adds a new line. Replies are announced.")

        scroll.documentView = tv
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = context.coordinator.textView else { return }
        if tv.string != text {                      // programmatic change (e.g. cleared after submit)
            tv.string = text
            tv.undoManager?.removeAllActions()
            context.coordinator.reportHeight()
        }
        if focusTrigger != context.coordinator.lastFocusTrigger {
            context.coordinator.lastFocusTrigger = focusTrigger
            if focusTrigger { DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) } }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        weak var textView: ComposerTextView?
        var lastFocusTrigger = false

        init(_ parent: ComposerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            if parent.text != tv.string { parent.text = tv.string }
            reportHeight()
        }

        /// Content height → SwiftUI (async: never mutate state during a view update).
        func reportHeight() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let line = ComposerField.lineHeight
            let content = ceil(lm.usedRect(for: tc).height) + tv.textContainerInset.height * 2
            let target = min(max(content, line), line * CGFloat(max(1, parent.maxLines)))
            DispatchQueue.main.async { [weak self] in
                guard let self, abs(self.parent.height - target) > 0.5 else { return }
                self.parent.height = target
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                switch ComposerKeyPolicy.actionForReturn(shift: flags.contains(.shift), option: flags.contains(.option),
                                                         hasMarkedText: textView.hasMarkedText()) {
                case .submit?: parent.onSubmit(); return true
                case .newline?: textView.insertNewlineIgnoringFieldEditor(nil); return true
                case nil: return false
                }
            case #selector(NSResponder.cancelOperation(_:)):
                if textView.string.isEmpty { parent.onEscape() } else { textView.string = ""; textDidChange(Notification(name: NSText.didChangeNotification)) }
                return true
            default:
                return false
            }
        }
    }
}
