import Foundation
import AppKit

/// The clipboard is treated as sensitive (DEC-140): it is never monitored, never polled, never persisted and never sent to a model.
/// The only use is a TEMPORARY write for a reliable paste of long text — the previous contents are held in memory for that moment only and put back
/// afterwards, unless the user copied something else in the meantime (then their newer copy is left alone).
@MainActor
enum ComputerClipboard {
    struct Saved {
        var items: [[NSPasteboard.PasteboardType: Data]]
        var changeCount: Int
    }

    static func save() -> Saved {
        let pb = NSPasteboard.general
        let items = (pb.pasteboardItems ?? []).map { item -> [NSPasteboard.PasteboardType: Data] in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
        return Saved(items: items, changeCount: pb.changeCount)
    }

    /// Returns true if the previous contents were restored (false: the user copied something in between, so theirs was kept).
    @discardableResult
    static func restore(_ saved: Saved, expectedChangeCount: Int) -> Bool {
        let pb = NSPasteboard.general
        guard pb.changeCount == expectedChangeCount else { return false }
        pb.clearContents()
        let restored: [NSPasteboardItem] = saved.items.map { d in
            let item = NSPasteboardItem()
            for (t, data) in d { item.setData(data, forType: t) }
            return item
        }
        if !restored.isEmpty { pb.writeObjects(restored) }
        return true
    }

    /// Puts `text` on the pasteboard, runs `body` (which pastes it), then restores the previous contents.
    static func withTemporaryText(_ text: String, _ body: () async throws -> Void) async rethrows -> Bool {
        let saved = save()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        let ours = pb.changeCount
        try await body()
        return restore(saved, expectedChangeCount: ours)
    }
}
