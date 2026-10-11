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
///   --benchmark-models      (with the above) also run the benchmark suite on verified-free OpenCode models and record results
///   --demo-agents           developer-only: simulate a few agent runs (never persisted, labelled SIMULATED)
///   --demo-stress           developer-only: simulate a high-rate console stream (performance measurement)
///   --demo-tasks <n>        developer-only (needs --no-providers): n scripted autonomous tasks parked on a blocked coding agent (performance measurement)
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
    var intelligenceLiveTest = false
    var taskLiveTest = false
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
            case "--demo-tasks": demoTasks = it.next().flatMap(Int.init) ?? 1
            case "--intelligence-live-test": intelligenceLiveTest = true
            case "--task-live-test": taskLiveTest = true
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
