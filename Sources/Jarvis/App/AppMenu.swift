import AppKit

/// The standard main menu.
///
/// ROOT CAUSE of the "can't paste" bug: JARVIS is an accessory (LSUIElement) app, which starts with NO main menu.
/// AppKit routes ⌘C/⌘V/⌘X/⌘A/⌘Z through main-menu key equivalents into the responder chain, so with no Edit menu
/// those shortcuts silently did nothing in every text field. The menu bar is never shown for an accessory app,
/// but the menu still provides the key equivalents. All items have `target = nil`, i.e. the first responder
/// (the focused text view) handles them natively — no per-shortcut key handling anywhere in JARVIS.
@MainActor
enum AppMenu {
    static func install() {
        let main = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        let app = NSMenu(title: "JARVIS")
        app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        appItem.submenu = app
        main.addItem(appItem)

        // Edit menu
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let plain = edit.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        plain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
