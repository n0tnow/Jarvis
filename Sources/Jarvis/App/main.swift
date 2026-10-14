import AppKit

// The JARVIS-owned MCP fixture server (V0.14) is a headless mode of this same binary: it must answer before any UI object exists.
MCPFixtureServer.runIfRequested()
LiveUIChild.runIfRequested()          // V0.14 live tests: a child that clicks JARVIS' own HUD through Accessibility (inert without its launch argument)

// Menu bar agent: no Dock icon (also enforced by LSUIElement in Info.plist).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
