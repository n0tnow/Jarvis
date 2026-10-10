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

        // --- Close / reopen, state preserved (HUD-only and app state)
        hud.section = .tasks
        store.log("smoke marker", kind: .system)
        let activityBefore = store.activity.count
        let stepsBefore = store.activeTask?.steps.map(\.status)
        let elapsedBefore = store.activeTask?.elapsed(at: .now) ?? 0
        w.hideFullHUD()
        check("Full HUD closes", await waitUntil { !w.isFullHUDOpen && !hud.isFullHUDVisible })
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
