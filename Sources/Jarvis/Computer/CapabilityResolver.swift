import Foundation

// MARK: - The capability ladder (DEC-128)
//
// Before ANY GUI automation the resolver asks: is there a stronger, structured mechanism for this goal? Source edits are V0.4 tools, Unity scene work is the
// V0.6 bridge, web reading is V0.9, Git is the Git tool. Computer Use gets only what is left: opening/activating apps, navigating native UI, reading UI state.

struct CapabilityChoice: Equatable, Sendable {
    var mechanism: ComputerMechanism
    /// Which existing JARVIS layer owns it ("V0.4 project tools", "V0.6 Unity bridge", "V0.9 research"…).
    var engine: String
    /// The plain-language explanation the user can ask for ("I used Accessibility instead of vision because …").
    var reason: String
}

struct GoalContext: Sendable {
    var projectRoot: String?
    var unityProjectOpen = false
    var visionEnabled = false
    var homeDirectory = NSHomeDirectory()
}

enum CapabilityResolver {
    // Source/code editing, file creation, refactors: the V0.4 tools do this directly and verifiably. Never through a GUI.
    private static let editVerbs: Set<String> = ["edit", "change", "modify", "refactor", "rewrite", "fix", "implement", "update", "write", "create", "add", "rename", "delete", "remove", "move", "duplicate", "degistir", "duzelt", "yaz", "ekle", "olustur", "sil"]
    private static let codeNouns: Set<String> = ["code", "source", "script", "scripts", "function", "class", "file", "files", "bug", "test", "tests", "layout", "hud", "view", "kod", "dosya", "betik", "sinif", "size", "constant", "constants"]
    private static let unityVerbs: Set<String> = ["create", "add", "set", "compile", "play", "run", "test", "inspect", "validate", "olustur", "ekle", "derle", "calistir"]
    private static let unityNouns: Set<String> = ["gameobject", "gameobjects", "prefab", "prefabs", "scene", "scenes", "component", "components", "collider", "rigidbody", "console", "playmode", "editmode", "hierarchy", "inspector", "sahne", "bilesen", "konsol"]
    private static let webWords: Set<String> = ["research", "search", "google", "lookup", "browse", "website", "webpage", "web", "download", "arastir", "ara"]
    private static let gitWords: Set<String> = ["git", "commit", "push", "branch", "merge", "rebase", "diff", "stash"]
    private static let shellWords: Set<String> = ["terminal", "shell", "bash", "zsh", "command", "cmd", "console", "iterm", "komut"]
    private static let runWords: Set<String> = ["run", "execute", "type", "enter", "paste", "calistir", "yaz"]

    /// The ladder for a goal expressed in words. `nil` = nothing stronger exists, so Computer Use may handle it.
    static func strongerMechanism(for raw: String, context: GoalContext) -> CapabilityChoice? {
        let t = ComputerText.tokens(raw)
        let words = Set(t)
        let mentionsUnity = words.contains("unity") || words.contains("unityeditor")
        let activationOnly = isPureActivation(t)

        if !words.isDisjoint(with: gitWords), words.contains("git") || !words.isDisjoint(with: ["commit", "push"]) {
            return CapabilityChoice(mechanism: .controlledCLI, engine: "Git tool (read-only) and V0.4 steps", reason: "Git has a typed tool; Git commit/push are never done by JARVIS, and never through a GUI either.")
        }
        if mentionsUnity, !activationOnly, !words.isDisjoint(with: unityNouns) || !words.isDisjoint(with: unityVerbs.intersection(["compile", "create", "add", "set", "derle", "olustur", "ekle"])) {
            return CapabilityChoice(mechanism: .typedCapability, engine: "V0.6 Unity bridge", reason: "Unity scene, component, compile, test and Console work goes through the typed Unity bridge — it is verifiable and safer than clicking the editor.")
        }
        if !words.isDisjoint(with: editVerbs), !words.isDisjoint(with: codeNouns) {
            return CapabilityChoice(mechanism: .typedCapability, engine: "V0.4 project tools", reason: "Changing project files is done by the typed, leased, validated project tools — never by driving an editor's GUI.")
        }
        if ResearchIntake.isResearchRequest(raw) || (!words.isDisjoint(with: webWords) && !activationOnly) {
            return CapabilityChoice(mechanism: .browserDOM, engine: "V0.9 web research", reason: "Reading the web uses the audited, read-only research path (DOM/HTTP), not desktop clicks in a browser.")
        }
        return nil
    }

    /// "open"/"switch to"/"activate" + an application name, nothing else — the one thing Unity GUI automation may do.
    static func isPureActivation(_ tokens: [String]) -> Bool {
        let verbs: Set<String> = ["open", "switch", "activate", "focus", "launch", "start", "ac", "gec", "baslat", "to", "show", "bring", "front", "go"]
        return !tokens.isEmpty && tokens.allSatisfy { verbs.contains($0) || $0 == "unity" || $0 == "the" || $0.hasPrefix("unity") || $0 == "editor" }
    }

    /// Typing/running commands through another application is the same as running them: refused (DEC-141).
    static func isTerminalBypass(_ raw: String) -> Bool {
        let t = Set(ComputerText.tokens(raw))
        let f = ComputerText.fold(raw)
        if !t.isDisjoint(with: shellWords), !t.isDisjoint(with: runWords) { return true }
        if f.contains("in terminal") || f.contains("in the terminal") || f.contains("terminal de") || f.contains("terminale") { return !t.isDisjoint(with: runWords) }
        return false
    }

    /// GUI mechanism for ONE action: the strongest that applies. Accessibility first; vision only when AX cannot find the target and vision is enabled.
    static func guiMechanism(axFound: Bool, visionEnabled: Bool, visionFound: Bool) -> (ComputerMechanism, String) {
        if axFound { return (.accessibility, "the target was exposed through Accessibility, so no screenshot was needed") }
        if visionEnabled && visionFound { return (.vision, "the control is not exposed through Accessibility; it was located in a window-scoped screenshot and validated before acting") }
        if visionEnabled { return (.accessibility, "the control is neither exposed through Accessibility nor visible to the window-scoped vision fallback") }
        return (.accessibility, "the control is not exposed through Accessibility and the vision fallback is off")
    }
}
