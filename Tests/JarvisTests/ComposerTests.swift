import AppKit
import Testing
@testable import Jarvis

@Suite("Composer key policy")
struct ComposerKeyPolicyTests {
    @Test func returnSubmitsShiftOrOptionReturnInsertsNewline() {
        #expect(ComposerKeyPolicy.actionForReturn(shift: false, option: false, hasMarkedText: false) == .submit)
        #expect(ComposerKeyPolicy.actionForReturn(shift: true, option: false, hasMarkedText: false) == .newline)
        #expect(ComposerKeyPolicy.actionForReturn(shift: false, option: true, hasMarkedText: false) == .newline)
        #expect(ComposerKeyPolicy.actionForReturn(shift: true, option: true, hasMarkedText: false) == .newline)
    }

    @Test func returnDuringIMECompositionBelongsToTheIME() {
        #expect(ComposerKeyPolicy.actionForReturn(shift: false, option: false, hasMarkedText: true) == nil)
        #expect(ComposerKeyPolicy.actionForReturn(shift: true, option: false, hasMarkedText: true) == nil)
    }
}

@MainActor
@Suite("Composer text view")
struct ComposerTextViewTests {
    private func makeView() -> ComposerTextView { let v = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 50)); v.isRichText = false; return v }

    @Test func insertedMultilineTextStaysIntactAndNeverTriggersAnything() {
        let v = makeView()
        let code = "func f() {\n    print(\"héllo ✓ ğüşiöç İ ı\")\n}\n\n{\"json\": [1, 2, 3]}\r\nerror: cannot find 'x' in scope"
        v.insertText(code, replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(v.string == code)
        #expect(v.string.contains("\n") && v.string.contains("ğüşiöç İ ı"))
    }

    @Test func pasteIsPlainText() {
        let v = makeView()
        #expect(!v.isRichText)
        #expect(v.responds(to: #selector(NSTextView.pasteAsPlainText(_:))))
    }

    @Test func largeTextIsAccepted() {
        let v = makeView()
        let big = (1...5000).map { "line \($0) türkçe ✓" }.joined(separator: "\n")
        v.insertText(big, replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(v.string.count == big.count)
    }

    @Test func conversationStoreKeepsLongPastedPromptsBounded() {
        let store = ConversationStore()
        store.appendUser(String(repeating: "ğ", count: 50_000))
        #expect(store.messages.first?.content.count == ConversationStore.maxMessageLength)
    }
}

@Suite("Main menu")
@MainActor
struct MainMenuTests {
    @Test func editMenuProvidesStandardResponderChainActions() {
        let menu = NSMenu()
        let saved = NSApp.mainMenu
        AppMenu.install()
        defer { NSApp.mainMenu = saved; _ = menu }
        let edit = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "Edit" }
        let actions = Set((edit?.items ?? []).compactMap { $0.action })
        for sel in [#selector(NSText.cut(_:)), #selector(NSText.copy(_:)), #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:)),
                    Selector(("undo:")), Selector(("redo:"))] {
            #expect(actions.contains(sel), "\(sel)")
        }
        // target nil → first responder (the focused text view) handles it natively
        #expect((edit?.items ?? []).allSatisfy { $0.target == nil })
        let keys = Dictionary(uniqueKeysWithValues: (edit?.items ?? []).filter { !$0.keyEquivalent.isEmpty }.map { ($0.title, $0.keyEquivalent) })
        #expect(keys["Copy"] == "c" && keys["Paste"] == "v" && keys["Cut"] == "x" && keys["Select All"] == "a" && keys["Undo"] == "z")
    }
}
