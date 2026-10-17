import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var context: AppContext!
    private var statusItem: StatusItemController!
    private(set) var hotkeys: GlobalHotkeyService!
    private let options = LaunchOptions()
    private static var lastMonitorLine = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        // V0.15: opening JARVIS again (Finder, Spotlight, Dock, login) shows the running copy instead of starting a second menu-bar assistant. Developer / live-test launches (any --flag) are exempt.
        if SingleInstance.handOverToRunningInstance() { NSApp.terminate(nil); return }
        Self.installTerminationHandlers()
        AppMenu.install()   // Edit menu → native ⌘C/⌘V/⌘X/⌘A/⌘Z in every text input (accessory apps start with none)
        // Automated runs must NEVER touch real providers or the real database.
        let stubbed = options.noProviders || (!options.providerLiveTest && !options.intelligenceLiveTest && !options.taskLiveTest && !options.proactiveLiveTest && !options.unityLiveTest && !options.researchLiveTest && !options.memoryLiveTest && !options.computerLiveTest && !options.orchestrationLiveTest && !options.operatorLiveTest && !options.adaptiveLiveTest && !options.mcpLiveTest && !options.continuityLiveTest && options.stabilitySoak == 0 && !options.visualBenchmark && !options.voiceLiveTest && !options.naturalVoiceLiveTest && (options.smokeTest || options.captureDirectory != nil))
        let legacyLiveData = options.intelligenceLiveTest ? JarvisPaths.liveTestsRoot.appendingPathComponent("live-test", isDirectory: true)
            : (options.taskLiveTest ? JarvisPaths.liveTestsRoot.appendingPathComponent("live-test-tasks", isDirectory: true)
            : (options.proactiveLiveTest ? JarvisPaths.liveTestsRoot.appendingPathComponent("live-test-proactive", isDirectory: true)
            : (options.unityLiveTest ? JarvisPaths.liveTestsRoot.appendingPathComponent("live-test-unity", isDirectory: true)
            : (options.stabilitySoak > 0 ? JarvisPaths.liveTestsRoot.appendingPathComponent("live-test-soak", isDirectory: true) : options.continuityLiveTest ? JarvisPaths.liveTestsRoot.appendingPathComponent("live-test-continuity", isDirectory: true) : (options.operatorLiveTest || options.visualBenchmark) ? JarvisPaths.liveTestsRoot.appendingPathComponent("live-test-operator", isDirectory: true) : options.adaptiveLiveTest ? JarvisPaths.liveTestsRoot.appendingPathComponent("live-test-adaptive", isDirectory: true) : options.mcpLiveTest ? JarvisPaths.liveTestsRoot.appendingPathComponent("live-test-mcp", isDirectory: true)
            : (options.orchestrationLiveTest ? JarvisPaths.liveTestsRoot.appendingPathComponent(options.orchestrationChild != nil ? "live-test-orchestration-child" : "live-test-orchestration", isDirectory: true)
            : (options.computerLiveTest ? JarvisPaths.liveTestsRoot.appendingPathComponent(options.computerChild != nil ? "live-test-computer-child" : "live-test-computer", isDirectory: true)
            : (options.memoryLiveTest ? JarvisPaths.liveTestsRoot.appendingPathComponent(options.memoryChild != nil ? "live-test-memory-child" : "live-test-memory", isDirectory: true)
            : (options.researchLiveTest ? JarvisPaths.liveTestsRoot.appendingPathComponent(options.researchChild != nil ? "live-test-research-child" : "live-test-research", isDirectory: true)
            : (options.voiceLiveTest ? JarvisPaths.liveTestsRoot.appendingPathComponent(options.voiceQuitChild ? "live-test-voice-child" : "live-test-voice", isDirectory: true)
            : (options.naturalVoiceLiveTest ? JarvisPaths.liveTestsRoot.appendingPathComponent(options.naturalChild ? "live-test-natural-child" : "live-test-natural", isDirectory: true) : nil))))))))))
        var liveData = options.dailyLiveFolder.map { JarvisPaths.liveTestsRoot.appendingPathComponent($0, isDirectory: true) } ?? legacyLiveData
        // V1.0 fix 3: every developer / live-test / smoke / capture launch keeps its data OUTSIDE the production support folder and uses an isolated defaults suite
        // (StorageIsolation). `--use-production-data` is the explicit developer override; tests never pass it.
        if liveData == nil, StorageIsolation.isProtectedRun { liveData = JarvisPaths.liveTestsRoot.appendingPathComponent("dev-run", isDirectory: true) }
        // V0.14: the adaptive and MCP live tests judge what is learned from THEIR OWN generated history, so they start from an empty isolated directory every time
        // (a second run on top of the first would find a 24-run workflow and fail for the wrong reason). Only these two JARVIS-created test directories are ever removed.
        if let liveData, ["live-test-adaptive", "live-test-mcp", "live-test-daily", "live-test-packaging", "live-test-setup"].contains(liveData.lastPathComponent), liveData.deletingLastPathComponent().standardizedFileURL == JarvisPaths.liveTestsRoot.standardizedFileURL {
            StorageIsolation.wipe(tag: liveData.lastPathComponent)
            try? FileManager.default.removeItem(at: liveData)
        }
        // The natural-voice live test runs the real stack in a closed acoustic loop (scripted microphone + simulated speaker); nothing else ever gets a rig.
        let rig: VoiceTestRig? = options.naturalVoiceLiveTest ? VoiceTestRig() : nil
        context = AppContext(seedDemoData: options.isDemoEnvironment, stubIntelligence: stubbed, dataDirectory: liveData, voiceRig: rig)
        let ctx = context!
        Self.terminationHook = { MainActor.assumeIsolated { ctx.prepareForTermination() } }
        statusItem = StatusItemController(context: context)
        context.windowManager.anchorProvider = { [weak self] in self?.statusItem.buttonFrameOnScreen }

        let windows = context.windows
        hotkeys = GlobalHotkeyService { action in
            switch action {
            case .toggleCompact: windows.toggleCompactHUD()
            case .toggleFull: windows.toggleFullHUD()
            }
        }
        let prefs = context.preferences
        let service = hotkeys!
        // One sampling service for the HUD chords AND Push-to-Talk (V0.7): same permission-free modifier polling, no second hotkey system.
        // It runs when either feature is on; the microphone is only ever touched by an explicit, held Push-to-Talk.
        context.hotkeyDiagnostics = { [weak service] in service?.diagnostics ?? GlobalHotkeyService.TalkDiagnostics() }
        let voice = context.voice, stubbedRun = context.intelligenceIsStubbed, forceVoice = options.voiceLiveTest && !options.voiceQuitChild
        let applyShortcuts: @MainActor () -> Void = {
            // The handler is attached whenever Push-to-Talk is switched on in Settings, EVEN WHILE Voice itself is off: the hold is then recognised and answered with a visible
            // "Voice is off" hint instead of being silently ignored (V1.0 stabilisation: the installed app ships with Voice OFF). The microphone is only ever opened when Voice is ON.
            let attach = !stubbedRun && prefs.voicePushToTalk
            service.chordsEnabled = prefs.globalShortcutsEnabled
            let handler: @MainActor (PushToTalkMachine.Action) -> Void = { [weak self] action in
                let voiceOn = prefs.voiceEnabled || forceVoice
                // Bounded Push-to-Talk diagnostics (state transitions only: no other key, no text, no audio).
                switch action {
                case .press:
                    if voiceOn {
                        self?.context.store.log("Push-to-Talk: hold reached — voice input requested", kind: .info)
                        voice.pushToTalkPressed()
                        self?.context.store.log("Push-to-Talk: voice state is now \(voice.state.label.lowercased())", kind: .info)
                    } else { self?.context.pushToTalkWhileVoiceIsOff() }
                case .release(let interrupted):
                    if voiceOn { self?.context.store.log("Push-to-Talk: released\(interrupted ? " (interrupted — audio dropped)" : "")", kind: .info); voice.pushToTalkReleased(interrupted: interrupted) }
                }
            }
            service.performTalk = attach ? handler : nil
            let monitorLine = attach ? "Push-to-Talk key monitor active (Voice is \(prefs.voiceEnabled ? "on" : "OFF — a hold shows a hint only"))" : "Push-to-Talk key monitor off"
            if monitorLine != Self.lastMonitorLine { Self.lastMonitorLine = monitorLine; if !stubbedRun { ctx.store.log(monitorLine, kind: .info) } }
            if !prefs.voiceEnabled { voice.cancelAll(reason: "turned off") }
            if prefs.globalShortcutsEnabled || attach { service.start() } else { service.stop() }
        }
        observeContinuously(track: { _ = prefs.globalShortcutsEnabled; _ = prefs.voiceEnabled; _ = prefs.voicePushToTalk }, onChange: { applyShortcuts() })
        applyShortcuts()

        if options.demoAgents { context.observatory.demo?.startShowcase(); context.observatory.selectedRunID = context.hub.activeRuns.first { $0.agentType == "PlannerAgent" }?.id }
        if options.demoStress { context.observatory.selectedRunID = context.observatory.demo?.startStress(linesPerSecond: 400) }
        if options.demoTasks > 0, context.intelligenceIsStubbed { Task { await TaskDemo.park(context: context, count: options.demoTasks) } }
        if options.demoProposals, context.intelligenceIsStubbed { Task { await TaskDemo.leaveProposals(context: context) } }
        if let state = options.state { DemoScenario.apply(state, to: context.store) }
        let plainLaunch = SingleInstance.isPlainLaunch()
        DistributedNotificationCenter.default().addObserver(forName: SingleInstance.showNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.context.windows.showCompactHUD() }
        }
        if options.openCompact || (plainLaunch && context.preferences.openCompactOnLaunch && context.preferences.firstRunCompleted) { context.windows.showCompactHUD() }
        // First launch of the installed app: the readiness walk-through (skippable; nothing in it is required, and it never starts a model, a provider or a permission prompt by itself).
        if plainLaunch, AppInfo.isApplicationBundle, !context.intelligenceIsStubbed, !context.preferences.firstRunCompleted { context.windows.showFullHUD(section: .system) }
        if options.openFull { context.windows.showFullHUD(section: options.section) }

        if let seconds = options.closeAfter {
            let windows = context.windows
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                windows.hideFullHUD(); windows.hideCompactHUD()
            }
        }

        if options.intelligenceLiveTest {
            let context = context!, dir = options.liveDirectory ?? "captures"
            Task { await IntelligenceLiveTest.run(context: context, captureDirectory: dir, benchmark: options.benchmarkModels) }
        }
        if options.proactiveLiveTest {
            let context = context!, dir = options.liveDirectory ?? "captures"
            Task { await ProactiveLiveTest.run(context: context, captureDirectory: dir) }
        }
        if options.unityLiveTest {
            let context = context!, dir = options.liveDirectory ?? "captures", fixture = options.unityFixture, noProvider = options.unityNoProvider
            Task { await UnityLiveTest.run(context: context, captureDirectory: dir, fixtureTemplate: fixture, withProvider: !noProvider) }
        }
        if options.memoryLiveTest {
            let context = context!, dir = options.liveDirectory ?? "captures", repo = options.memoryRepo
            if options.memoryChild == "quit" { Task { await MemoryLiveTest.runQuitChild(context: context) } }
            else { Task { await MemoryLiveTest.run(context: context, captureDirectory: dir, repoRoot: repo) } }
        }
        if options.computerLiveTest {
            let context = context!, dir = options.liveDirectory ?? "captures", repo = options.computerRepo, child = options.computerChild, statePath = options.computerFixtureState ?? ""
            if child == "start" { Task { await ComputerLiveTest.runChildStart(context: context, statePath: statePath) } }
            else if child == "check" { Task { await ComputerLiveTest.runChildCheck(context: context, statePath: statePath) } }
            else if child == "start2" { let k = options.computerCycle; Task { await ComputerLiveTest.runChildStartSafe(context: context, cycle: k) } }
            else if child == "check2" { let k = options.computerCycle; Task { await ComputerLiveTest.runChildCheckSafe(context: context, statePath: statePath, cycle: k) } }
            else { ComputerLiveTest.reproIterations = options.computerRepro; ComputerLiveTest.restartRepeat = options.computerRestartRepeat; ComputerLiveTest.stopAfterContext = options.computerStopAfterContext; Task { await ComputerLiveTest.run(context: context, captureDirectory: dir, repoRoot: repo) } }
        }
        if options.visualBenchmark {
            let context = context!, dir = options.liveDirectory ?? "captures", cases = options.visualCases
            Task { await VisualBenchmark.run(context: context, captureDirectory: dir, casesDirectory: cases) }
        }
        if options.stabilitySoak > 0 {
            let context = context!, n = options.stabilitySoak
            Task { await StabilitySoak.run(context: context, cycles: n) }
        }
        if options.continuityLiveTest {
            let context = context!, sections = options.continuitySections
            Task { await ContinuityLiveTest.run(context: context, sections: sections) }
        }
        if options.adaptiveLiveTest {
            let context = context!, sections = options.adaptiveSections, cycles = options.adaptiveCycles
            Task { await AdaptiveLiveTest.run(context: context, sections: sections, cycles: cycles) }
        }
        if options.dailyLiveTest {
            let context = context!, sections = options.dailySections
            Task { await DailyLiveTest.run(context: context, sections: sections) }
        }
        if options.packagingLiveTest {
            let context = context!
            Task { await PackagingLiveTest.run(context: context) }
        }
        if options.setupLiveTest {
            let context = context!
            Task { await SetupLiveTest.run(context: context) }
        }
        if options.mcpLiveTest {
            let context = context!, sections = options.mcpSections
            Task { await McpLiveTest.run(context: context, sections: sections) }
        }
        if options.operatorLiveTest {
            let context = context!, dir = options.liveDirectory ?? "captures", sections = options.operatorSections
            Task { await OperatorLiveTest.run(context: context, captureDirectory: dir, sections: sections) }
        }
        if options.orchestrationLiveTest {
            let context = context!, dir = options.liveDirectory ?? "captures", child = options.orchestrationChild, soak = options.orchestrationSoakMinutes
            if child == "start" { Task { await OrchestrationLiveTest.runChildStart(context: context) } }
            else if child == "check" { Task { await OrchestrationLiveTest.runChildCheck(context: context) } }
            else { Task { await OrchestrationLiveTest.run(context: context, captureDirectory: dir, soakMinutes: soak) } }
        }
        if options.researchLiveTest {
            let context = context!, dir = options.liveDirectory ?? "captures", child = options.researchChild
            if child == "start" { Task { await ResearchLiveTest.runChildStart(context: context) } }
            else if child == "check" { Task { await ResearchLiveTest.runChildCheck(context: context) } }
            else { Task { await ResearchLiveTest.run(context: context, captureDirectory: dir) } }
        }
        if options.voiceLiveTest {
            let context = context!, dir = options.liveDirectory ?? "captures", audible = options.voiceAudible, noWhisper = options.voiceNoWhisper, realMic = options.voiceRealMic, combined = options.voiceCombined
            if options.voiceQuitChild { Task { await VoiceLiveTest.runQuitChild(context: context) } }
            else { Task { await VoiceLiveTest.run(context: context, captureDirectory: dir, audible: audible, skipWhisper: noWhisper, realMicrophone: realMic, combined: combined) } }
        }
        if options.naturalVoiceLiveTest, let rig {
            let context = context!, audible = options.naturalAudible, acoustic = options.naturalAcoustic, idle = options.naturalIdleMinutes, combined = options.naturalCombined
            if options.naturalChild { Task { await NaturalVoiceLiveTest.runQuitChild(context: context) } }
            else { Task { await NaturalVoiceLiveTest.run(context: context, rig: rig, audible: audible, acoustic: acoustic, idleMinutes: idle, combined: combined) } }
        }
        if options.taskLiveTest {
            let context = context!, dir = options.liveDirectory ?? "captures"
            Task { await TaskLiveTest.run(context: context, captureDirectory: dir) }
        }
        if options.providerLiveTest {
            let context = context!, dir = options.liveDirectory ?? "captures"
            Task { await ProviderLiveTest.run(context: context, captureDirectory: dir) }
        }

        if options.smokeTest {
            let context = context!
            let statusItem = statusItem!
            Task { await SmokeTest.run(context: context, statusItem: statusItem) }
        }
        if let directory = options.captureDirectory {
            let context = context!
            Task { await DevCapture.run(directory: directory, context: context) }
        }
        // Find out which engines are actually usable (event-driven, once; no polling). Stubbed runs never touch real providers.
        if options.dailyLiveFolder == nil && !options.intelligenceLiveTest && !options.taskLiveTest && !options.proactiveLiveTest && !options.unityLiveTest && !options.researchLiveTest && !options.computerLiveTest && !options.orchestrationLiveTest && !options.operatorLiveTest && !options.adaptiveLiveTest && !options.mcpLiveTest && !options.continuityLiveTest && options.stabilitySoak == 0 && !options.visualBenchmark && !options.voiceLiveTest && !options.naturalVoiceLiveTest {
            let context = context!
            Task { await context.refreshIntelligence(includeOpenCode: false) }     // OpenCode is read lazily (may start its background service)
        }
        Log.app.info("JARVIS launched")
    }

    /// SIGTERM / SIGINT / SIGHUP (kill, logout, terminal close) skip applicationWillTerminate: clean up provider processes anyway.
    /// (A crash or SIGKILL cannot be intercepted — documented in KNOWN_ISSUES.)
    private static var signalSources: [DispatchSourceSignal] = []
    /// Runs before provider processes are killed on SIGTERM/SIGINT/SIGHUP (persists interrupted tasks + checkpoints).
    nonisolated(unsafe) private static var terminationHook: (() -> Void)?
    private static func installTerminationHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { Self.terminationHook?(); ProcessRegistry.shared.killAll(); exit(128 + sig) }
            source.resume()
            signalSources.append(source)
        }
    }

    /// No provider process may outlive JARVIS.
    func applicationWillTerminate(_ notification: Notification) {
        context?.prepareForTermination()        // tasks: interrupted state + checkpoints, leases released
        context?.supervisor.shutdown()          // unload the local model worker (it also exits by itself when stdin closes)
        ProcessRegistry.shared.killAll()
    }

    @objc func showSettings(_ sender: Any?) { context.windows.showSettings() }

    /// Opening the running app again from Finder / Spotlight / the Dock shows it (a menu-bar app has no window to bring forward).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { context?.windows.showCompactHUD() }
        return true
    }

    /// Closing HUDs must never quit JARVIS: the menu bar item is the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
