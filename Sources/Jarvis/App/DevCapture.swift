import AppKit

/// `Jarvis --capture <dir>`: renders JARVIS's OWN windows to PNG files for visual inspection, then exits.
/// Uses the window server's per-window image of this process's windows — no Screen Recording permission involved.
/// Development tool only; never runs unless the launch argument is present.
@MainActor
enum DevCapture {
    private typealias WindowImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    static func run(directory: String, context: AppContext) async {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let w = context.windows
        let store = context.store
        func settle(_ ms: Int = 900) async { try? await Task.sleep(for: .milliseconds(ms)) }

        await settle()

        // Compact HUD (default dev state: working task)
        DemoScenario.apply(.working, to: store)
        w.showCompactHUD(); await settle()
        snapshot(of: NSApp.windows.first { $0 is HUDPanel }, name: "compact_working", in: directory)
        DemoScenario.apply(.idle, to: store); await settle(300)
        snapshot(of: NSApp.windows.first { $0 is HUDPanel }, name: "compact_idle", in: directory)
        w.hideCompactHUD()

        // Full HUD, every state
        w.showFullHUD(section: .dashboard); await settle()
        for state in JarvisState.allCases {
            DemoScenario.apply(state, to: store)
            await settle(state == .completed ? 700 : 900)
            snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "full_\(state.rawValue)", in: directory)
        }

        // Other sections
        DemoScenario.apply(.working, to: store)
        for section in [HUDSection.tasks, .report, .system, .memory] {
            context.hud.section = section
            await settle(500)
            snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "full_section_\(section.rawValue)", in: directory)
        }
        // Minimum window size (layout stress test)
        context.hud.section = .dashboard
        DemoScenario.apply(.waitingForApproval, to: store)
        if let window = NSApp.windows.first(where: { $0 is FullHUDWindow }) {
            let min = context.windowManager.fullMinimumSize
            print("min size \(min) frame before \(window.frame)")
            window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - min.height, width: min.width, height: min.height), display: true)
            window.makeKeyAndOrderFront(nil)
            await settle(1200)
            print("frame after \(window.frame) visible=\(window.isVisible) num=\(window.windowNumber)")
            snapshot(of: window, name: "full_minsize_waiting", in: directory)
        }
        print("CAPTURE DONE → \(directory)")
        fflush(stdout)
        exit(0)
    }

    private static func snapshot(of window: NSWindow?, name: String, in directory: String) {
        guard let window,
              let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {   // RTLD_DEFAULT
            print("skip \(name): no window / API unavailable"); return
        }
        let create = unsafeBitCast(sym, to: WindowImageFn.self)
        // kCGWindowListOptionIncludingWindow = 1<<3; kCGWindowImageBoundsIgnoreFraming = 1<<0 | kCGWindowImageBestResolution = 1<<3
        guard let cg = create(.null, 1 << 3, CGWindowID(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() else {
            print("skip \(name): capture returned nil"); return
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
            print("captured \(name).png \(cg.width)x\(cg.height)")
        }
    }
}
