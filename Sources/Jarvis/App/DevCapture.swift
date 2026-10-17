import AppKit
import SwiftUI

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

        // Compact HUD, every state (also proves the fixed size visually)
        w.showCompactHUD(); await settle()
        for state in JarvisState.allCases {
            DemoScenario.apply(state, to: store)
            await settle(700)
            // The panel auto-hides if another app steals focus mid-capture; re-open it if so.
            if !w.isCompactHUDOpen { w.showCompactHUD(); await settle(500) }
            snapshot(of: NSApp.windows.first { $0 is HUDPanel }, name: "compact_\(state.rawValue)", in: directory)
            if state == .completed || state == .error { DemoScenario.resetDemoTask(store) }
        }
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
        if let repo = context.repository { _ = ResearchDemo.seed(repo, artifacts: context.artifacts); context.researchModel.refresh() }          // synthetic DEMO rows (V0.9)
        for section in [HUDSection.tasks, .agents, .research, .report, .system, .memory] {
            context.hud.section = section
            await settle(500)
            snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "full_section_\(section.rawValue)", in: directory)
        }
        // Agent Observatory (developer simulation: never persisted, labelled SIMULATED)
        if let demo = context.observatory.demo {
            demo.startShowcase(); await settle(2500)
            context.hud.section = .agents; context.windows.showFullHUD(section: .agents); await settle(600)
            snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "agents_live", in: directory)
            if let planner = context.hub.activeRuns.first(where: { $0.agentType == "PlannerAgent" }) {
                context.observatory.selectedRunID = planner.id; await settle(700)
                snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "agents_detail_planner", in: directory)
            }
            if let coder = context.hub.activeRuns.first(where: { $0.agentType == "CodingAgent" }) {
                context.observatory.selectedRunID = coder.id; await settle(700)
                snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "agents_detail_coder_indeterminate", in: directory)
            }
            w.showCompactHUD(); await settle(700)
            snapshot(of: NSApp.windows.first { $0 is HUDPanel }, name: "compact_agents_summary", in: directory)
            demo.stopAll(); context.observatory.selectedRunID = nil
            context.hud.section = .dashboard
        }
        // V0.4 autonomous task engine: scripted agents on a temporary project (stubbed/temporary-database runs only)
        if context.intelligenceIsStubbed {
            let engine = context.taskEngine
            let runner = DemoAgentRunner(audit: context.audit)
            engine.agents = runner
            var projects: [String] = []
            func submit(_ goal: String, withLegacy: Bool = false, destructive: Bool = false) async {
                let p = TaskDemo.makeProject(withLegacyFile: withLegacy); projects.append(p)
                _ = await engine.submit(goal: goal, kind: .development, workspacePath: p, destructiveRequested: destructive)
            }
            await submit("Fix the failing calculation test"); await engine.waitUntilIdle()
            await submit("Remove the legacy module old/legacy.py", withLegacy: true, destructive: true)
            for _ in 0..<60 where engine.pendingApprovals.isEmpty { await settle(100) }
            runner.blocking = ["CodingAgent"]
            await submit("Fix the failing test in the second calculator")
            for _ in 0..<80 where !runner.jobs.contains("CodingAgent") { await settle(100) }
            await settle(400)
            context.hud.section = .tasks; w.showFullHUD(section: .tasks); await settle(700)
            context.hud.selectedTaskID = engine.orderedViews.first { $0.task.state == .running }?.id
            await settle(600)
            snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "tasks_overview", in: directory)
            context.hud.selectedTaskID = engine.orderedViews.first { $0.task.state == .completed }?.id
            await settle(500)
            snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "tasks_completed_expanded", in: directory)
            context.hud.selectedTaskID = engine.orderedViews.first { $0.task.state == .waitingForApproval }?.id
            await settle(500)
            snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "tasks_waiting_approval", in: directory)
            context.hud.section = .agents; await settle(600)
            snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "agents_task_runs", in: directory)
            w.showCompactHUD(); await settle(800)
            snapshot(of: NSApp.windows.first { $0 is HUDPanel }, name: "compact_task_active", in: directory)
            w.hideCompactHUD()
            // V0.5: proposals (the completed demo task produced a "no regression test" finding; add a critical one for the visual contrast)
            context.opportunities.settings = { AutonomySettings(mode: .askBeforeActing) }
            for _ in 0..<80 where context.opportunities.pending.isEmpty { await settle(100) }
            if let done = engine.orderedViews.first(where: { $0.task.state == .completed }), let root = done.task.workspaceRoot {
                _ = await context.opportunities.ingest(RawFinding(origin: .systemMaintenance, title: "Push the branch to origin", summary: "The fix is committed locally only.", category: .maintenance,
                                                                   evidence: [EvidenceItem(kind: .taskResult, summary: "The task changed calc.py", reference: "calc.py")], affectedPaths: ["calc.py"],
                                                                   originTaskID: done.id, projectRoot: root, eventKey: "capture:critical"))
            }
            await settle(500)
            context.hud.section = .tasks; w.showFullHUD(section: .tasks); context.hud.selectedTaskID = nil; await settle(700)
            snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "tasks_proposals", in: directory)
            w.showCompactHUD(); await settle(700)
            snapshot(of: NSApp.windows.first { $0 is HUDPanel }, name: "compact_suggestion", in: directory)
            w.hideCompactHUD()
            engine.cancelAll(); await engine.waitUntilIdle()
            // V0.6: the Unity project line + a finished Unity task with its evidence (SIMULATED data in the throw-away database)
            let savedRoot = context.preferences.projectRoot
            for p in context.opportunities.pending { _ = context.proposalService.dismiss(p.id, source: .test) }       // keep the Unity card above the fold
            await settle(300)
            if let unityDir = TaskDemo.seedUnityTask(context: context) {
                projects.append(unityDir)
                context.hud.section = .tasks; w.showFullHUD(section: .tasks); await settle(500)
                context.hud.selectedTaskID = engine.orderedViews.first(where: { $0.task.title.contains("BoxCollider") })?.id; await settle(700)
                snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "tasks_unity", in: directory)
                // V0.13.1: the Project card's scene rows — a LIVE reading, then the same numbers as remembered history (SIMULATED data)
                context.hud.selectedTaskID = nil
                let demo = UnitySceneFacts(scene: "Assets/Scenes/Bathhouse.unity", objectCount: 42, cameras: 1, lights: 3, missingScripts: 2, missingReferences: 0, isPlaying: false, hasUnsavedChanges: true, live: true)
                context.continuity.unityScene = { _ in demo }
                await context.operatorModel.refresh(); await settle(500)
                snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "tasks_scene_live", in: directory)
                var old = demo.remembered; old.capturedAt = Date().addingTimeInterval(-7_200)
                context.continuity.unityScene = { _ in old }
                await context.operatorModel.refresh(); await settle(500)
                snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "tasks_scene_stale", in: directory)
            }
            // V0.13: the Project card and the Experiments card (SIMULATED data in the throw-away database)
            if let opDir = TaskDemo.seedOperatorDemo(context: context) {
                projects.append(opDir)
                print("operator demo: experiments in the throw-away database = \((try? context.repository?.recentExperiments(limit: 5).count) ?? -1)")
                context.preferences.projectRoot = opDir
                context.hud.section = .tasks; w.showFullHUD(section: .tasks); context.hud.selectedTaskID = nil; await settle(900)
                snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "tasks_operator", in: directory)
            }
            context.preferences.projectRoot = savedRoot
            // V0.14: the Learning and Capabilities screens and the one-line Compact state (SIMULATED data in the throw-away database)
            await AdaptiveDemo.seed(context)
            context.hud.section = .learning; w.showFullHUD(section: .learning); await settle(800)
            snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "learning_insights", in: directory)
            context.learningModel.tab = .candidates; context.learningModel.selected = context.learning.candidates(kinds: [.rule]).first?.id; context.learningModel.refresh(); await settle(600)
            snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "learning_candidate_detail", in: directory)
            context.learningModel.selected = nil; context.learningModel.tab = .rules; await settle(500)
            snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "learning_rules", in: directory)
            context.learningModel.tab = .proposals; await settle(500)
            snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "learning_self_improvement", in: directory)
            context.hud.section = .capabilities; await settle(800)
            snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "capabilities_list", in: directory)
            for q in context.adaptiveDecisions.pending() where q.kind == .removeCapability { _ = context.adaptiveDecisions.deny(q.id, source: .test) }       // keep the detail card above the fold
            context.capabilitiesModel.refresh()
            context.capabilitiesModel.selected = "blender-demo"; await settle(600)
            snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "capabilities_detail", in: directory)
            context.capabilitiesModel.selected = nil; context.capabilitiesModel.filter = .attention; await settle(500)
            snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "capabilities_attention", in: directory)
            context.capabilitiesModel.filter = .all
            w.hideFullHUD(); w.showCompactHUD(); await settle(800)
            snapshot(of: NSApp.windows.first { $0 is HUDPanel }, name: "compact_adaptive_line", in: directory)
            print("adaptive demo: compact line = \(context.adaptiveCompactLine ?? "none"); compact size = \(CompactHUDLayout.size)")
            w.hideCompactHUD()
            context.hud.selectedTaskID = nil; context.hud.section = .dashboard
            for p in projects { try? FileManager.default.removeItem(atPath: p) }
            DemoScenario.resetDemoTask(store)
        }
        // Conversation scenarios
        let svc = context.conversationService!
        DemoScenario.resetDemoTask(store)
        context.conversation.clear()
        context.hud.section = .dashboard
        w.showCompactHUD(); await settle(700)
        snapshot(of: NSApp.windows.first { $0 is HUDPanel }, name: "compact_cmd_before", in: directory)
        svc.submit("What are you doing?", origin: .compactHUD); await settle(500)
        snapshot(of: NSApp.windows.first { $0 is HUDPanel }, name: "compact_cmd_after", in: directory)
        svc.submit("Show tasks.", origin: .compactHUD); await settle(900)
        snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "full_cmd_nav_tasks", in: directory)
        svc.submit("Open the report."); await settle(500)
        snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "full_cmd_nav_report", in: directory)
        context.hud.section = .dashboard
        context.conversation.clear()
        svc.submit("hello"); svc.submit("What are you doing?"); await settle(600)
        snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "full_conv_short", in: directory)
        for cmd in ["Pause the current task.", "pause", "raporu aç", "Explain quantum mechanics.", "Fix my Unity multiplayer system.",
                    "Resume the task.", "thanks", "What state are you in?", "stop", "stop", "status"] { svc.submit(cmd) }
        context.hud.section = .dashboard
        await settle(800)
        snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "full_conv_many", in: directory)
        DemoScenario.resetDemoTask(store)
        context.conversation.clear()

        // Composer with pasted multiline code (Full) and a long paste (Compact)
        if let tv = (NSApp.windows.first { $0 is FullHUDWindow }?.firstResponder as? NSTextView) {
            tv.string = "func add(_ a: Int, _ b: Int) -> Int {\n    return a + b\n}\n\n// Türkçe: ğüşiöç ✓\nlet x = add(1, 2)\nprint(x)"
            tv.didChangeText()
            await settle(500)
            snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "full_composer_multiline", in: directory)
            tv.string = ""; tv.didChangeText()
        }
        w.showCompactHUD(); await settle(600)
        if let tv = (NSApp.windows.first { $0 is HUDPanel }?.firstResponder as? NSTextView) {
            tv.string = (1...40).map { "pasted log line \($0): something went wrong in module \($0)" }.joined(separator: "\n")
            tv.didChangeText()
            await settle(500)
            snapshot(of: NSApp.windows.first { $0 is HUDPanel }, name: "compact_composer_long_paste", in: directory)
            tv.string = ""; tv.didChangeText()
        }
        w.hideCompactHUD(); w.showFullHUD(section: .dashboard); await settle(500)

        // Settings window
        w.hideFullHUD(); w.showSettings(); await settle(700)
        snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "settings", in: directory)
        w.showFullHUD(section: .dashboard); await settle(500)

        // V0.7 voice states (simulated through the developer hook: no microphone, no recogniser, no speaker)
        do {
            let voice = context.voice
            w.hideFullHUD(); w.showCompactHUD(); await settle(600)
            DemoScenario.apply(.listening, to: store)
            voice.simulate(state: .listening, partial: "Jarvis, Unity'deki son task'ın durumunu gös", level: 0.55); await settle(500)
            snapshot(of: NSApp.windows.first { $0 is HUDPanel }, name: "voice_compact_listening", in: directory)
            DemoScenario.apply(.idle, to: store)
            voice.simulate(state: .speaking); await settle(500)
            snapshot(of: NSApp.windows.first { $0 is HUDPanel }, name: "voice_compact_speaking", in: directory)
            voice.simulate(state: .error("Microphone access was not allowed. You can allow it in System Settings; typing still works.")); await settle(500)
            snapshot(of: NSApp.windows.first { $0 is HUDPanel }, name: "voice_compact_denied", in: directory)
            voice.simulate(state: .idle)
            w.hideCompactHUD(); w.showFullHUD(section: .dashboard); await settle(600)
            context.conversation.clear()
            context.conversation.appendUser("Jarvis, görevler ekranını aç", source: .voice)
            context.conversation.appendJarvis("Görevleri açıyorum.", route: .command)
            DemoScenario.apply(.listening, to: store)
            voice.simulate(state: .listening, partial: "show me the latest task re", level: 0.6); await settle(500)
            snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "voice_full_listening", in: directory)
            DemoScenario.apply(.idle, to: store)
            voice.simulate(state: .speaking); await settle(500)
            snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: "voice_full_speaking", in: directory)
            voice.simulate(state: .idle); context.conversation.clear()

            let saved = context.preferences.voiceEnabled
            context.preferences.voiceEnabled = true
            await voice.refreshProviders()
            let host = NSHostingView(rootView: Form { VoiceSettingsSection() }.formStyle(.grouped).environment(context).frame(width: 480, height: 900))
            let win = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 480, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            win.contentView = host
            win.orderFrontRegardless(); await settle(900)
            snapshot(of: win, name: "settings_voice", in: directory)
            win.orderOut(nil)
            context.preferences.voiceEnabled = saved
            context.preferences.defaults.removeObject(forKey: "prefs.voice.enabled"); if saved { context.preferences.voiceEnabled = true }
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

    static func snapshot(of window: NSWindow?, name: String, in directory: String) {
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
