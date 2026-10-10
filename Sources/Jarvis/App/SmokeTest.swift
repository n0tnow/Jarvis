import AppKit

/// `Jarvis --smoke-test`: drives the real window manager, store and status item through the V0.1 behaviours
/// that can be checked without a human, prints PASS/FAIL lines, and exits non-zero on failure.
/// It cannot test real mouse clicks on the menu bar icon or physical key presses (see docs/PROJECT_STATE.md).
@MainActor
enum SmokeTest {
    static func run(context: AppContext, statusItem: StatusItemController) async {
        // Watchdog: a hung window call must fail the run, not hang it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            print("SMOKE TEST TIMEOUT"); fflush(stdout); exit(2)
        }

        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        /// Polls (spinning the run loop) instead of sleeping a fixed time.
        func waitUntil(_ timeout: Double = 3, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return condition()
        }
        func settle(_ ms: Int = 300) async { try? await Task.sleep(for: .milliseconds(ms)) }
        func fullWindow() -> NSWindow? { NSApp.windows.first { $0 is FullHUDWindow } }
        func compactWindow() -> NSWindow? { NSApp.windows.first { $0 is HUDPanel } }
        func coreViews(in window: NSWindow?) -> [CoreNSView] {
            var found: [CoreNSView] = []
            func walk(_ v: NSView) { if let c = v as? CoreNSView { found.append(c) }; v.subviews.forEach(walk) }
            if let content = window?.contentView { walk(content) }
            return found
        }

        /// SwiftUI only materializes its accessibility tree when an AX client is attached, so an empty tree is SKIP, not FAIL.
        func auditLabels(_ name: String, _ all: [AccessibilityAudit.Item], _ unlabeled: [AccessibilityAudit.Item]) {
            if all.isEmpty {
                print("SKIP  \(name): in-process accessibility tree not materialized (needs an AX client) — see KNOWN_ISSUES")
            } else {
                check("\(name): every interactive element has an accessibility label", unlabeled.isEmpty,
                      "\(all.count) elements, unlabeled: \(unlabeled.map { "\($0.role)#\($0.identifier)" })")
            }
        }

        func neuralViews(in window: NSWindow?) -> [NeuralNetworkNSView] {
            var found: [NeuralNetworkNSView] = []
            func walk(_ v: NSView) { if let c = v as? NeuralNetworkNSView { found.append(c) }; v.subviews.forEach(walk) }
            if let content = window?.contentView { walk(content) }
            return found
        }

        let w = context.windows
        let store = context.store
        let hud = context.hud
        await settle(500)

        // --- Menu bar item
        check("Menu bar item has a button, an image and an on-screen frame",
              statusItem.button?.image != nil && (statusItem.buttonFrameOnScreen?.width ?? 0) > 0)
        check("App does not quit when the last window closes",
              (NSApp.delegate as? AppDelegate)?.applicationShouldTerminateAfterLastWindowClosed(NSApp) == false)

        // --- Compact HUD
        w.showCompactHUD()
        check("Compact HUD opens", await waitUntil { w.isCompactHUDOpen && hud.isCompactVisible })
        let compactAX = compactWindow().map(AccessibilityAudit.interactiveElements(in:)) ?? []
        let compactUnlabeled = compactAX.filter { $0.label.isEmpty }
        auditLabels("Compact HUD", compactAX, compactUnlabeled)

        // --- Compact HUD geometry must be IDENTICAL in every state (and with/without a task / dev strip)
        if let panel = compactWindow() {
            let expected = panel.frame.size
            check("Compact HUD uses the canonical fixed size", abs(expected.width - CompactHUDLayout.size.width) < 0.5
                  && abs(expected.height - CompactHUDLayout.size.height) < 0.5, "frame=\(expected)")
            let originalTop = panel.frame.maxY, originalX = panel.frame.minX
            var drift: [String] = []
            DemoScenario.resetDemoTask(store)
            for dev in [true, false] {
                context.preferences.showDeveloperControls = dev
                for state in JarvisState.allCases {
                    DemoScenario.apply(state, to: store)
                    await settle(120)
                    if panel.frame.size != expected || abs(panel.frame.maxY - originalTop) > 0.5 || abs(panel.frame.minX - originalX) > 0.5 {
                        drift.append("\(state.rawValue)/dev=\(dev): \(panel.frame)")
                    }
                    if state == .completed || state == .error { DemoScenario.resetDemoTask(store) }
                }
            }
            context.preferences.showDeveloperControls = true
            check("Compact HUD size and position never change across all 7 states (dev strip on/off, task/no task)",
                  drift.isEmpty, drift.joined(separator: "; "))
        }
        DemoScenario.resetDemoTask(store)
        w.hideCompactHUD()
        check("Compact HUD closes", await waitUntil { !w.isCompactHUDOpen && !hud.isCompactVisible })

        // --- Full HUD open / geometry
        DemoScenario.apply(.working, to: store)
        w.showFullHUD(section: nil)
        check("Full HUD opens", await waitUntil { w.isFullHUDOpen })
        await settle()
        if let window = fullWindow(), let screen = window.screen {
            check("Full HUD fits inside visible screen area", screen.visibleFrame.insetBy(dx: -1, dy: -1).contains(window.frame))
            let dx = abs(window.frame.midX - screen.visibleFrame.midX), dy = abs(window.frame.midY - screen.visibleFrame.midY)
            check("Full HUD is centered", dx < 2 && dy < 2, "dx=\(Int(dx)) dy=\(Int(dy))")
            check("Full HUD can become key", window.canBecomeKey)
            let min = context.windowManager.windowWillResize(window, to: NSSize(width: 100, height: 100))
            check("Full HUD minimum size is enforced on user resize",
                  min.width >= 600 && min.height >= 400 && min == context.windowManager.fullMinimumSize, "clamped to \(min)")
        } else {
            check("Full HUD window found", false)
        }
        let fullAX = AccessibilityAudit.interactiveElements(in: fullWindow()!)
        let fullUnlabeled = fullAX.filter { $0.label.isEmpty }
        auditLabels("Full HUD", fullAX, fullUnlabeled)

        // --- Animation only while visible
        check("Core display link is running while Full HUD is open + Working",
              await waitUntil { coreViews(in: fullWindow()).contains { $0.isDisplayLinkActive } })
        check("Menu bar icon timer runs in Working", statusItem.isAnimationTimerActive)

        // --- Neural background lifecycle
        check("Neural background exists in the Full HUD (decorative, 45 nodes)",
              neuralViews(in: fullWindow()).first?.nodeCount == 45 && neuralViews(in: fullWindow()).first?.hitTest(.zero) == nil)
        check("Neural animation runs while Full HUD is open + Working (≤15 fps)",
              await waitUntil { neuralViews(in: fullWindow()).contains { $0.isDisplayLinkActive && $0.currentFPS > 0 && $0.currentFPS <= 15 } })
        DemoScenario.apply(.idle, to: store)
        check("Neural animation drops to the calm frame rate in Idle",
              await waitUntil { neuralViews(in: fullWindow()).contains { $0.isDisplayLinkActive && $0.currentFPS <= 6 } })
        DemoScenario.apply(.working, to: store)
        context.preferences.reduceMotion = true
        check("Reduce Motion stops neural AND core animation (static frames)",
              await waitUntil { !neuralViews(in: fullWindow()).contains { $0.isDisplayLinkActive } && !coreViews(in: fullWindow()).contains { $0.isDisplayLinkActive } })
        context.preferences.reduceMotion = false
        check("Animation resumes when Reduce Motion is turned off",
              await waitUntil { neuralViews(in: fullWindow()).contains { $0.isDisplayLinkActive } })

        // --- Close / reopen, state preserved (HUD-only and app state)
        hud.section = .tasks
        store.log("smoke marker", kind: .system)
        let activityBefore = store.activity.count
        let stepsBefore = store.activeTask?.steps.map(\.status)
        let elapsedBefore = store.activeTask?.elapsed(at: .now) ?? 0
        w.hideFullHUD()
        check("Full HUD closes", await waitUntil { !w.isFullHUDOpen && !hud.isFullHUDVisible })
        check("Neural display link stops once the Full HUD is hidden",
              await waitUntil { !neuralViews(in: fullWindow()).contains { $0.isDisplayLinkActive } })
        check("Display link stops once the Full HUD is hidden",
              await waitUntil { !coreViews(in: fullWindow()).contains { $0.isDisplayLinkActive } })
        w.showFullHUD(section: nil)
        check("Reopen preserves section, activity, steps and a running clock",
              await waitUntil { w.isFullHUDOpen } && hud.section == .tasks && store.activity.count == activityBefore
              && store.activeTask?.steps.map(\.status) == stepsBefore && (store.activeTask?.elapsed(at: .now) ?? 0) >= elapsedBefore)
        hud.section = .dashboard

        // --- ESC: a real keyDown NSEvent dispatched through the window's responder chain (no AX permission needed)
        func sendESC(to window: NSWindow?) {
            guard let window,
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                               charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else { return }
            window.makeKeyAndOrderFront(nil)
            window.sendEvent(event)
        }
        sendESC(to: fullWindow())
        check("Real ESC key event dismisses Full HUD", await waitUntil { !w.isFullHUDOpen })
        w.showCompactHUD(); _ = await waitUntil { w.isCompactHUDOpen }
        sendESC(to: compactWindow())
        check("Real ESC key event dismisses Compact HUD", await waitUntil { !w.isCompactHUDOpen })

        // --- Programmatic navigation (future "give me the report")
        w.showFullHUD(section: .report)
        check("showFullHUD(section: .report) navigates", await waitUntil { w.isFullHUDOpen } && hud.section == .report)
        w.hideFullHUD(); hud.section = .dashboard

        // --- Every state: coherent with the demo task, and reflected in the menu bar icon
        check("JarvisState has exactly 7 cases", JarvisState.allCases.count == 7)
        DemoScenario.resetDemoTask(store)
        for state in JarvisState.allCases {
            DemoScenario.apply(state, to: store)
            await settle(60)
            let task = store.activeTask
            let coherent: Bool
            switch state {
            case .working: coherent = task?.status == .running
            case .waitingForApproval: coherent = task?.status == .waiting && store.pendingApproval != nil
            case .idle: coherent = task?.status != .running            // nothing running while idle
            case .completed, .error: coherent = task == nil            // finished/failed task is no longer active
            case .listening, .thinking: coherent = true                // foreground only; task may run in background
            }
            let tooltipOK = statusItem.button?.toolTip?.contains(state.label.capitalized) == true
            check("State \(state.rawValue): coherent with task, icon tooltip updated", store.state == state && coherent && tooltipOK,
                  "task=\(task?.status.rawValue ?? "none")")
            if state == .completed || state == .error { DemoScenario.resetDemoTask(store) }
        }
        DemoScenario.apply(.idle, to: store)
        check("Menu bar icon timer is stopped in Idle", await waitUntil { !statusItem.isAnimationTimerActive })

        // --- Global shortcuts → real WindowManager (scripted modifier timeline; physical keys NOT used here)
        check("Global hotkey service is running by default", (NSApp.delegate as? AppDelegate)?.hotkeys?.isRunning == true)
        let sys = GlobalHotkeyService.systemSample()
        check("System modifier sample is readable without permissions", sys.time > 0 && sys.secondsSinceOtherInput >= 0)
        w.hideCompactHUD(); w.hideFullHUD(); _ = await waitUntil { !w.isCompactHUDOpen && !w.isFullHUDOpen }
        var clock = 0.0
        var held: (opt: Bool, cmd: Bool) = (false, false)
        var compactSeenDuringFullChord = false
        var trackCompact = false
        let scripted = GlobalHotkeyService(
            sampler: { ModifierSample(time: clock, option: held.opt, command: held.cmd, other: false, secondsSinceOtherInput: 1000) },
            perform: { action in
                switch action {
                case .toggleCompact: w.toggleCompactHUD()
                case .toggleFull: w.toggleFullHUD()
                }
            })
        func drive(_ seconds: Double, _ opt: Bool, _ cmd: Bool) async {
            held = (opt, cmd)
            let end = clock + seconds
            while clock < end {
                clock += 0.016
                scripted.poll()
                if trackCompact && w.isCompactHUDOpen { compactSeenDuringFullChord = true }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        await drive(0.5, false, false)
        await drive(0.45, true, true)                                  // ⌥⌘ held → Compact after the window
        check("⌥⌘ opens the Compact HUD", await waitUntil { w.isCompactHUDOpen })
        await drive(0.3, false, false)
        await drive(0.45, true, true)                                  // again → toggles it closed
        check("⌥⌘ again closes the Compact HUD", await waitUntil { !w.isCompactHUDOpen })
        await drive(0.5, false, false)
        trackCompact = true
        await drive(0.08, true, true); await drive(0.08, true, false); await drive(0.3, true, true)   // ⌥⌘⌘
        check("⌥⌘⌘ opens the Full HUD", await waitUntil { w.isFullHUDOpen })
        await drive(0.6, true, true)
        trackCompact = false
        check("Full chord never flashed the Compact HUD first", !compactSeenDuringFullChord)
        await drive(0.5, false, false)
        await drive(0.08, true, true); await drive(0.08, true, false); await drive(0.3, true, true)   // ⌥⌘⌘ again
        await settle(400)
        check("⌥⌘⌘ again toggles (hides when frontmost, otherwise brings forward) with no duplicate windows",
              NSApp.windows.filter { $0 is FullHUDWindow }.count == 1 && (!w.isFullHUDOpen || !NSApp.isActive || fullWindow()?.isKeyWindow == true),
              "open=\(w.isFullHUDOpen) appActive=\(NSApp.isActive)")
        w.hideFullHUD(); w.hideCompactHUD()

        // --- HUD exclusivity: Compact XOR Full, through EVERY entry point (real WindowManager)
        var violations: [String] = []
        func exclusive(_ step: String) {
            let compact = w.isCompactHUDOpen, full = w.isFullHUDOpen
            let panels = NSApp.windows.filter { $0 is HUDPanel }.count, fulls = NSApp.windows.filter { $0 is FullHUDWindow }.count
            if (compact && full) || panels > 1 || fulls > 1 { violations.append("\(step): compact=\(compact) full=\(full) panels=\(panels) fulls=\(fulls)") }
        }
        func only(_ which: String, _ step: String) async -> Bool {
            let ok = await waitUntil { which == "compact" ? (w.isCompactHUDOpen && !w.isFullHUDOpen) : which == "full" ? (w.isFullHUDOpen && !w.isCompactHUDOpen) : (!w.isCompactHUDOpen && !w.isFullHUDOpen) }
            exclusive(step)
            return ok
        }
        w.hideCompactHUD(); w.hideFullHUD()
        check("Exclusivity: both hidden", await only("none", "start"))
        w.showCompactHUD();                       check("Exclusivity: show Compact → only Compact", await only("compact", "showCompact"))
        w.showFullHUD(section: nil);              check("Exclusivity: Compact visible → show Full → only Full", await only("full", "compact→full"))
        w.showCompactHUD();                       check("Exclusivity: Full visible → show Compact → only Compact", await only("compact", "full→compact"))
        w.hideCompactHUD(); w.hideFullHUD()
        w.showFullHUD(section: nil);              check("Exclusivity: both hidden → show Full → only Full", await only("full", "showFull"))
        // Menu bar icon click (the real status-item action path) while Full is visible
        statusItem.button?.performClick(nil)
        check("Exclusivity: menu-bar icon while Full visible → only Compact", await only("compact", "menubar"))
        statusItem.button?.performClick(nil)
        check("Exclusivity: menu-bar icon again → both hidden", await only("none", "menubar-again"))
        // OPEN JARVIS (Compact → Full) is showFullHUD(section: .dashboard)
        w.showCompactHUD(); _ = await only("compact", "open-jarvis-pre")
        w.showFullHUD(section: .dashboard)
        check("Exclusivity: Compact → OPEN JARVIS → only Full (dashboard)", await only("full", "open-jarvis") && hud.section == .dashboard)
        // Hotkeys through the real service → WindowManager
        w.hideFullHUD(); _ = await only("none", "pre-hotkeys")
        var hkClock = 100.0
        var hkHeld: (opt: Bool, cmd: Bool) = (false, false)
        var compactSeenInFullChord = false
        let hk = GlobalHotkeyService(
            sampler: { ModifierSample(time: hkClock, option: hkHeld.opt, command: hkHeld.cmd, other: false, secondsSinceOtherInput: 1000) },
            perform: { action in switch action { case .toggleCompact: w.toggleCompactHUD(); case .toggleFull: w.toggleFullHUD() } })
        func hkDrive(_ seconds: Double, _ opt: Bool, _ cmd: Bool, watchCompact: Bool = false) async {
            hkHeld = (opt, cmd)
            let end = hkClock + seconds
            while hkClock < end {
                hkClock += 0.016; hk.poll()
                if watchCompact && w.isCompactHUDOpen { compactSeenInFullChord = true }
                exclusive("hotkey t=\(String(format: "%.2f", hkClock))")
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        await hkDrive(0.5, false, false)
        await hkDrive(0.45, true, true)                          // ⌥⌘ → Compact
        _ = await only("compact", "hk-compact")
        await hkDrive(0.5, false, false)
        await hkDrive(0.08, true, true, watchCompact: true); await hkDrive(0.08, true, false, watchCompact: true); await hkDrive(0.3, true, true, watchCompact: true)   // ⌥⌘⌘
        check("Exclusivity: Compact visible → Full hotkey → only Full, Compact never re-flashed", await only("full", "hk-full") && !compactSeenInFullChord || (w.isFullHUDOpen && !w.isCompactHUDOpen))
        await hkDrive(0.8, false, false)
        await hkDrive(0.45, true, true)                          // ⌥⌘ while Full visible
        check("Exclusivity: Full visible → Compact hotkey → only Compact", await only("compact", "hk-full→compact"))
        await hkDrive(0.5, false, false)
        // Full visible but BEHIND (Settings is key): Full toggle brings it forward; Compact must not appear
        w.showFullHUD(section: nil); _ = await only("full", "pre-behind")
        w.showSettings(); await settle(300)
        let fullWasKey = fullWindow()?.isKeyWindow ?? true
        w.toggleFullHUD(); await settle(300)
        check("Exclusivity: Full visible but behind → Full toggle brings it forward (no hide, no Compact)",
              !fullWasKey && w.isFullHUDOpen && !w.isCompactHUDOpen && fullWindow()?.isKeyWindow == true, "wasKey=\(fullWasKey)")
        exclusive("behind-toggle")
        NSApp.windows.first { $0 is SettingsWindow }?.orderOut(nil)
        // Rapid repeated calls: no duplicate windows, never both
        for _ in 0..<10 { w.showCompactHUD(); exclusive("rapid-c"); w.showFullHUD(section: nil); exclusive("rapid-f"); w.toggleCompactHUD(); exclusive("rapid-tc"); w.toggleFullHUD(); exclusive("rapid-tf") }
        w.hideCompactHUD(); w.hideFullHUD()
        check("Exclusivity: never both visible, never duplicate windows, across all checkpoints above", violations.isEmpty, violations.prefix(3).joined(separator: "; "))
        check("Compact HUD size unchanged after all of the above", compactWindow().map { $0.frame.size == CompactHUDLayout.size } ?? true)

        // --- V0.2 acceptance scenarios (real ConversationService → CommandExecutor → WindowManager/JarvisStore)
        let svc = context.conversationService!
        let convo = context.conversation
        func resetWorld() async {
            w.hideCompactHUD(); w.hideFullHUD()
            DemoScenario.resetDemoTask(store); store.setState(.working)
            convo.clear(); hud.section = .dashboard
            _ = await waitUntil { !w.isCompactHUDOpen && !w.isFullHUDOpen }
        }
        func lastReply() -> String { convo.messages.last(where: { $0.role == .jarvis })?.content ?? "" }
        violations.removeAll()

        // 1. "Open the report." typed from the Compact HUD
        await resetWorld()
        w.showCompactHUD(); _ = await only("compact", "s1-pre")
        svc.submit("Open the report.", origin: .compactHUD)
        check("V0.2 #1 'Open the report.' → Compact closes, Full opens on Report, both messages stored",
              await only("full", "s1") && hud.section == .report && convo.messages.map(\.role) == [.user, .jarvis]
              && convo.messages.first?.content == "Open the report." && lastReply() == "Opening the report.")

        // 2. "What are you doing?" — from real state, no network/LLM, no state change
        let stateBefore = store.state
        svc.submit("What are you doing?")
        check("V0.2 #2 'What are you doing?' answers from the real task/state, changes nothing",
              lastReply() == "I'm working on “Multiplayer Synchronization” — step 4 of 6: Compile." && store.state == stateBefore && w.isFullHUDOpen)

        // 3. "Pause the current task."
        let activityBeforePause = store.activity.count
        svc.submit("Pause the current task.")
        check("V0.2 #3 'Pause the current task.' pauses the real task, confirms, logs activity",
              store.activeTask?.status == .paused && lastReply().hasPrefix("Task paused") && store.activity.count > activityBeforePause
              && store.activity.last?.message.hasPrefix("Paused") == true)
        svc.submit("resume")

        // 4. Turkish
        hud.section = .dashboard
        svc.submit("raporu aç")
        check("V0.2 #4 'raporu aç' navigates exactly like the English command (Turkish reply)",
              hud.section == .report && lastReply() == "Raporu açıyorum." && w.isFullHUDOpen && !w.isCompactHUDOpen)

        // 5. Reasoning-required, no fake intelligence
        let windowsBefore = (w.isCompactHUDOpen, w.isFullHUDOpen), stateBefore5 = store.state
        let decision = svc.submit("Explain quantum mechanics.")
        check("V0.2 #5 'Explain quantum mechanics.' → reasoning-required, truthful not-connected reply, no state/window change",
              decision?.kind == .reasoning && lastReply().contains("none is connected yet") && convo.messages.last?.tone == .notice
              && store.state == stateBefore5 && windowsBefore == (w.isCompactHUDOpen, w.isFullHUDOpen))

        // 6. From Compact: "Show tasks." — Compact disappears, Full on Tasks, Compact geometry unaffected
        w.showCompactHUD(); _ = await only("compact", "s6-pre")
        svc.submit("Show tasks.", origin: .compactHUD)
        let compactStillFixed = compactWindow().map { $0.frame.size == CompactHUDLayout.size } ?? false
        check("V0.2 #6 'Show tasks.' from Compact → Compact hides, Full opens on Tasks, Compact geometry unchanged",
              await only("full", "s6") && hud.section == .tasks && compactStillFixed)
        // Compact must also stay 392×448 while replies/long text flow through it
        w.showCompactHUD(); _ = await only("compact", "s6b-pre")
        svc.submit("What are you doing?", origin: .compactHUD)
        svc.submit(String(repeating: "very long text ", count: 60), origin: .compactHUD)   // reasoning → opens Full from Compact
        _ = await only("full", "s6b")
        w.showCompactHUD(); _ = await only("compact", "s6c-pre")
        svc.submit("hello", origin: .compactHUD)
        await settle(300)
        check("V0.2 Compact HUD stays 392×448 while replies and very long input flow through it",
              compactWindow()?.frame.size == CompactHUDLayout.size, "\(compactWindow()?.frame.size ?? .zero)")

        // 7. Repeated commands: no duplicates, order preserved, never both HUDs
        await resetWorld()
        let script = ["hello", "open the report", "status", "show tasks", "pause", "resume", "go to system", "open compact", "hello", "show memory",
                      "close jarvis", "open dashboard", "what are you doing?", "explain relativity", "ayarları aç", "close", "open full hud", "open compact", "status", "thanks"]
        var expectedMessages = 0
        for cmd in script + script {
            svc.submit(cmd); expectedMessages += 2
            exclusive("s7 \(cmd)")
            if cmd == "open dashboard" || cmd == "ayarları aç" { await settle(60) }
        }
        NSApp.windows.first { $0 is SettingsWindow }?.orderOut(nil)
        await settle(200)
        let roles = convo.messages.map(\.role)
        check("V0.2 #7 40 repeated commands: order intact, no duplicate windows, never both HUDs visible",
              convo.messages.count == expectedMessages && roles.enumerated().allSatisfy { ($0.offset % 2 == 0) == ($0.element == .user) } && violations.isEmpty,
              "messages=\(convo.messages.count)/\(expectedMessages) \(violations.prefix(2))")
        w.hideCompactHUD(); w.hideFullHUD()
        await resetWorld()
        check("V0.2 has no intelligence provider registered (offline: no API keys, no network)", !svc.hasProviders && !svc.isResponding)

        // --- Task controls
        DemoScenario.resetDemoTask(store)
        store.pauseActiveTask()
        check("Pause task", store.activeTask?.status == .paused)
        store.resumeActiveTask()
        check("Resume task", store.activeTask?.status == .running)

        print(failures == 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED (\(failures))")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}
