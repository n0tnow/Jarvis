import SwiftUI
import AppKit

/// Renders sanitized console events as ONE attributed string (monospaced, severity markers + colour). Input events can only
/// contain sanitized text (`AgentConsoleEvent` sanitizes in its initializer), so nothing unsafe can be drawn.
enum ConsoleRenderer {
    private static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
    private static let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let monoBold = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)

    static func render(events: [AgentConsoleEvent], tail: String, dropped: Int) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ s: String, color: NSColor, font: NSFont = mono) { out.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])) }
        if dropped > 0 { add("… \(dropped) earlier events are not shown (kept in history)\n", color: NSColor(white: 1, alpha: 0.45)) }
        for e in events {
            let color: NSColor
            switch e.severity {
            case .info: color = e.kind == .providerOutput ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 1, alpha: 0.62)
            case .success: color = NSColor(red: 0.47, green: 0.92, blue: 0.70, alpha: 1)
            case .warning: color = NSColor(red: 1.0, green: 0.77, blue: 0.36, alpha: 1)
            case .error: color = NSColor(red: 1.0, green: 0.43, blue: 0.43, alpha: 1)
            }
            add("\(time.string(from: e.timestamp)) \(e.severity.marker) ", color: NSColor(white: 1, alpha: 0.42))
            add(e.summary + "\n", color: color, font: e.kind == .providerOutput ? mono : monoBold)
            if e.kind != .providerOutput, let d = e.detail, !d.isEmpty { add("           \(d)\n", color: NSColor(white: 1, alpha: 0.5)) }
        }
        if !tail.isEmpty { add("               \(tail)", color: NSColor(white: 1, alpha: 0.92)) }
        return out
    }
}

/// Lets a "Copy" button use the NATIVE text-view copy (responder chain) instead of any custom clipboard code.
final class ConsoleCopyProxy {
    weak var textView: NSTextView?
    func copyAll() { guard let tv = textView else { return }; tv.window?.makeFirstResponder(tv); tv.selectAll(nil); tv.copy(nil) }
}

/// Read-only, selectable text view: ⌘C / ⌘A work natively (V0.2.1 main menu), text stays selectable, and a console of hundreds
/// of lines scrolls smoothly (unlike thousands of SwiftUI `Text` views).
struct AgentConsoleTextView: NSViewRepresentable {
    let content: NSAttributedString
    let key: String
    let proxy: ConsoleCopyProxy

    final class Coordinator { var lastKey = ""; var pinnedToBottom = true }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView { Self.makeScroll(proxy: proxy, coordinator: context.coordinator) }

    static func makeScroll(proxy: ConsoleCopyProxy, coordinator: Coordinator) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        let tv = NSTextView()
        tv.isEditable = false; tv.isSelectable = true; tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.isAutomaticSpellingCorrectionEnabled = false; tv.isRichText = true; tv.usesFindBar = false
        tv.isVerticallyResizable = true; tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.setAccessibilityLabel("Agent console output, read only")
        scroll.documentView = tv
        proxy.textView = tv
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak scroll] _ in
            guard let scroll, let doc = scroll.documentView else { return }
            coordinator.pinnedToBottom = scroll.contentView.bounds.maxY >= doc.frame.height - 24
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.lastKey != key, let tv = scroll.documentView as? NSTextView else { return }
        context.coordinator.lastKey = key
        let selection = tv.selectedRange()
        tv.textStorage?.setAttributedString(content)
        if selection.length > 0, selection.upperBound <= content.length { tv.setSelectedRange(selection) }       // keep a user's selection while text grows
        if context.coordinator.pinnedToBottom && selection.length == 0 { tv.scrollToEndOfDocument(nil) }
    }
}
