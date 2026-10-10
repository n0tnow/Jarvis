import AppKit

// Menu bar agent: no Dock icon (also enforced by LSUIElement in Info.plist).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
