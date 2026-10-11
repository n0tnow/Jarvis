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
