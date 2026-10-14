import Foundation

/// Developer launch arguments, used for deterministic verification and screenshots.
/// None of these change normal behaviour; with no arguments JARVIS just sits in the menu bar.
///
///   --open-compact          open the Compact HUD after launch
///   --open-full             open the Full HUD after launch
///   --section <name>        Full HUD section (dashboard|tasks|report|system|memory)
///   --state <name>          force a JarvisState (idle|listening|thinking|working|waitingForApproval|completed|error)
///   --live-dir <dir>        where the live test saves its own screenshots (never combine with --capture)
///   --provider-live-test    REAL requests through ConversationService→ProviderManager→provider (uses your subscriptions; opt-in), print results, exit
///   --intelligence-live-test  REAL tests of the V0.3.1 stack (SQLite, local Qwen, OpenCode free model, routing, lifecycle); opt-in
///   --task-live-test        REAL end-to-end test of the V0.4 task engine on isolated fixture projects (OpenCode free preferred); opt-in
///   --proactive-live-test   REAL test of the V0.5 proactive layer (opportunities, policy, proposals, auto action, denial, restart) on isolated fixtures; opt-in
///   --computer-live-test    REAL test of V0.11 General Computer Use: real Accessibility, a JARVIS-owned fixture app, window-scoped capture + on-device OCR, Finder/System Settings/Blender navigation, cancel/stop/restart; opt-in
///   --orchestration-live-test  REAL test of V0.12 multi-agent orchestration: role graphs on disposable fixtures, real providers where available (OpenCode free / Claude Code / Codex, no paid API), role benchmarks, routing reasons, handoffs, parallelism, review independence, QA truth, injection/approval/memory-authority attacks, cancel, hard-kill + resume, status, context efficiency, resource pressure, idle; opt-in
///   --orchestration-soak <min>  (with the above) also run a bounded multi-minute stability loop and report memory / DB / process growth
///   --voice-live-test       REAL test of the V0.7 voice stack with SYNTHETIC speech (system voices): recognisers, benchmark, TTS, stop, E2E through the typed pipeline, resources; opt-in
///   --voice-audible         (with the above) let JARVIS speak aloud during the TTS checks (default: real playback at volume 0)
///   --voice-no-whisper      (with the above) skip the local Whisper helper
///   --voice-combined        (with the above) also load the local Qwen model and sample combined memory (run next to --unity-live-test to include a real Unity editor)
///   --voice-real-mic        (with the above) also open the REAL microphone for ~1.5 s to prove capture plumbing (needs the permission to be granted already; level only, nothing kept)
///   --natural-voice-live-test  REAL test of the V0.8 natural voice stack with SYNTHETIC speech: wake word, VAD, endpointing, turn taking, barge-in, self-speech, neural voice (closed loop, no hardware); opt-in
///   --natural-audible       (with the above) the neural/Apple voices play through the real speakers for the TTS checks (default: silent)
///   --natural-acoustic      (with the above) also measure the REAL speaker→microphone loop for ~10 s (audible; needs the microphone permission already granted; levels only, nothing kept)
///   --natural-combined      (with the above) also load the local Qwen model and sample combined memory with the whole voice stack resident (run next to --unity-live-test to include a real Unity editor)
///   --natural-idle <min>    (with the above) also hold wake mode on a silent microphone for <min> minutes and measure CPU/memory (long idle test)
///   --benchmark-models      (with the above) also run the benchmark suite on verified-free OpenCode models and record results
///   --demo-agents           developer-only: simulate a few agent runs (never persisted, labelled SIMULATED)
///   --demo-stress           developer-only: simulate a high-rate console stream (performance measurement)
///   --demo-tasks <n>        developer-only (needs --no-providers): n scripted autonomous tasks parked on a blocked coding agent (performance measurement)
///   --demo-proposals        developer-only (needs --no-providers): one scripted task finishes and leaves a pending proposal + a critical one (performance measurement)
///   --no-providers          never contact Claude Code / Codex (providers report "not installed"); used by verify.sh
///   --smoke-test            run the automated window/state smoke test, print results, exit
///   --close-after <sec>     hide all HUD windows after <sec> seconds (to observe the closed/idle resource profile)
///   --capture <dir>         render JARVIS's own windows to PNGs in <dir>, exit (dev tool)
struct LaunchOptions {
    var openCompact = false
    var openFull = false
    var section: HUDSection?
    var state: JarvisState?
    var smokeTest = false
    var captureDirectory: String?
    var closeAfter: TimeInterval?
    var providerLiveTest = false
    var noProviders = false
    var demoAgents = false
    var demoStress = false
    var demoTasks = 0
    var demoProposals = false
    var intelligenceLiveTest = false
    var taskLiveTest = false
    var proactiveLiveTest = false
    var unityLiveTest = false
    var unityNoProvider = false
    var unityFixture: String?
    var researchLiveTest = false
    var memoryLiveTest = false
    var computerLiveTest = false
    var computerRepro = 0
    var stabilitySoak = 0
    var computerCycle = 0
    var computerRestartRepeat = 0
    var computerStopAfterContext = false
    var computerChild: String?           // internal: "start" | "check" (restart test)
    var computerFixtureState: String?    // internal: the fixture's state file (restart test children)
    var computerRepo: String?
    var orchestrationLiveTest = false
    var operatorLiveTest = false
    var adaptiveLiveTest = false
    var adaptiveSections = Set<String>()
    var adaptiveCycles = 15
    var dailyLiveTest = false
    var dailySections = Set<String>()
    var packagingLiveTest = false
    var setupLiveTest = false
    var mcpLiveTest = false
    var mcpSections = Set<String>()
    /// V0.15: which isolated data folder a daily / packaging / setup live test uses (nil = none of them was requested).
    var dailyLiveFolder: String? { dailyLiveTest ? "live-test-daily" : (packagingLiveTest ? "live-test-packaging" : (setupLiveTest ? "live-test-setup" : nil)) }
    var continuityLiveTest = false
    var continuitySections: Set<String> = []
    var visualBenchmark = false
    var visualCases: String?
    var operatorSections: Set<String> = []
    var orchestrationChild: String?      // internal: "start" | "check" (restart test)
    var orchestrationSoakMinutes = 0.0
    var memoryChild: String?             // internal: "quit" (helper cleanup test)
    var memoryRepo: String?              // the project whose own docs are bootstrapped (default: the JARVIS checkout this app was built from)
    var researchChild: String?           // internal: "start" | "check" (restart test)
    var voiceLiveTest = false
    var voiceAudible = false
    var voiceNoWhisper = false
    var voiceRealMic = false
    var voiceCombined = false
    var voiceQuitChild = false
    var naturalVoiceLiveTest = false
    var naturalAudible = false
    var naturalAcoustic = false
    var naturalCombined = false
    var naturalIdleMinutes = 0.0
    var naturalChild = false
    var benchmarkModels = false
    var liveDirectory: String?

    init(arguments: [String] = CommandLine.arguments) {
        var it = arguments.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--open-compact": openCompact = true
            case "--open-full": openFull = true
            case "--smoke-test": smokeTest = true
            case "--provider-live-test": providerLiveTest = true
            case "--no-providers": noProviders = true
            case "--demo-agents": demoAgents = true
            case "--demo-stress": demoStress = true
            case "--demo-proposals": demoProposals = true
            case "--demo-tasks": demoTasks = it.next().flatMap(Int.init) ?? 1
            case "--intelligence-live-test": intelligenceLiveTest = true
            case "--task-live-test": taskLiveTest = true
            case "--proactive-live-test": proactiveLiveTest = true
            case "--unity-live-test": unityLiveTest = true
            case "--unity-no-provider": unityNoProvider = true
            case "--unity-fixture": unityFixture = it.next()
            case "--research-live-test": researchLiveTest = true
            case "--memory-live-test": memoryLiveTest = true
            case "--computer-live-test": computerLiveTest = true
            case "--computer-stop-after-context": computerStopAfterContext = true; computerLiveTest = true
            case "--computer-cycle": if let v = it.next(), let n = Int(v) { computerCycle = n }
            case "--computer-restart-repeat": if let v = it.next(), let n = Int(v) { computerRestartRepeat = n; computerLiveTest = true }
            case "--stability-soak": if let v = it.next(), let n = Int(v) { stabilitySoak = n }
            case "--computer-repro": if let v = it.next(), let n = Int(v) { computerRepro = n; computerLiveTest = true }
            case "--computer-child": computerChild = it.next()
            case "--computer-fixture-state": computerFixtureState = it.next()
            case "--computer-repo": computerRepo = it.next()
            case "--orchestration-live-test": orchestrationLiveTest = true
            case "--operator-live-test": operatorLiveTest = true
            case "--adaptive-live-test": adaptiveLiveTest = true
            case "--adaptive-section": if let v = it.next() { adaptiveSections.insert(v) }
            case "--adaptive-cycles": adaptiveCycles = it.next().flatMap(Int.init) ?? 15
            case "--daily-jarvis-live-test": dailyLiveTest = true
            case "--daily-section": if let v = it.next() { dailySections.insert(v) }
            case "--packaging-live-test": packagingLiveTest = true
            case "--setup-live-test": setupLiveTest = true
            case "--mcp-live-test": mcpLiveTest = true
            case "--mcp-section": if let v = it.next() { mcpSections.insert(v) }
            case "--continuity-live-test": continuityLiveTest = true
            case "--continuity-section": if let v = it.next() { continuitySections.insert(v) }
            case "--visual-benchmark": visualBenchmark = true
            case "--visual-cases": visualCases = it.next()
            case "--operator-section": if let v = it.next() { operatorSections.insert(v) }
            case "--orchestration-child": orchestrationChild = it.next()
            case "--orchestration-soak": orchestrationSoakMinutes = it.next().flatMap(Double.init) ?? 2
            case "--memory-child": memoryChild = it.next()
            case "--memory-repo": memoryRepo = it.next()
            case "--research-child": researchChild = it.next()
            case "--voice-live-test": voiceLiveTest = true
            case "--voice-audible": voiceAudible = true
            case "--voice-no-whisper": voiceNoWhisper = true
            case "--voice-real-mic": voiceRealMic = true
            case "--voice-combined": voiceCombined = true
            case "--voice-quit-child": voiceQuitChild = true
            case "--natural-voice-live-test": naturalVoiceLiveTest = true
            case "--natural-audible": naturalAudible = true
            case "--natural-acoustic": naturalAcoustic = true
            case "--natural-combined": naturalCombined = true
            case "--natural-idle": naturalIdleMinutes = it.next().flatMap(Double.init) ?? 1
            case "--natural-child": naturalChild = true
            case "--benchmark-models": benchmarkModels = true
            case "--live-dir": liveDirectory = it.next()
            case "--capture": captureDirectory = it.next()
            case "--close-after": closeAfter = it.next().flatMap { TimeInterval($0) }
            case "--section": section = it.next().flatMap { HUDSection(rawValue: $0) }
            case "--state": state = it.next().flatMap { JarvisState(rawValue: $0) }
            default: break
            }
        }
    }
}
