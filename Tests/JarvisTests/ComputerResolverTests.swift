import Testing
import Foundation
import CoreGraphics
@testable import Jarvis

private func snap(_ elements: [UIElementSnapshot], windows: [WindowSnapshot]? = nil) -> AXSnapshot {
    let w = windows ?? [WindowSnapshot(index: 0, title: "Main", role: "AXWindow", subrole: nil, frame: CGRect(x: 0, y: 0, width: 600, height: 400), isMain: true, isFocused: true, isMinimized: false, isModal: false, isSheet: false, cgWindowID: 1, identifier: nil)]
    var els = elements
    for i in els.indices { els[i].id = i; els[i].handle = ElementHandle(pid: 1, generation: 1, index: i) }
    return AXSnapshot(app: ApplicationSnapshot(pid: 1, bundleID: "com.x", name: "X", isActive: true, isHidden: false), windows: w, windowIndex: 0, elements: els, generation: 1, truncated: false, capturedAt: Date(), durationMS: 1, focusedElement: nil)
}
private func el(_ role: String, _ title: String, ancestors: [String] = [], modal: Bool = false, focused: Bool = false, id: String? = nil) -> UIElementSnapshot {
    var e = FakeUI.element(role: role, title: title); e.ancestorTitles = ancestors; e.inModal = modal; e.focused = focused; e.identifier = id; return e
}

@Suite("Computer · semantic target resolution")
struct ComputerTargetResolverTests {
    @Test("exact label → EXACT; contained label → STRONG; nothing → NOT_FOUND")
    func states() {
        let s = snap([el("AXButton", "Run"), el("AXButton", "Render Properties tab"), el("AXButton", "Stop")])
        #expect(TargetResolver.resolve(ActionTarget(role: "button", title: "Run"), in: s).state == .exact)
        #expect(TargetResolver.resolve(ActionTarget(role: "button", title: "Render Properties"), in: s).state == .strong)
        let none = TargetResolver.resolve(ActionTarget(role: "button", title: "Archive"), in: s)
        #expect(none.state == .notFound && none.element == nil)
    }

    @Test("two identical buttons are AMBIGUOUS — never a silent first match")
    func ambiguity() {
        let s = snap([el("AXButton", "Apply", ancestors: ["Sidebar"]), el("AXButton", "Apply", ancestors: ["Inspector"])])
        let r = TargetResolver.resolve(ActionTarget(role: "button", title: "Apply"), in: s)
        #expect(r.state == .ambiguous && r.element == nil && r.candidates.count == 2)
    }

    @Test("context separates identical labels: within, occurrence (user words), modal, focus")
    func disambiguation() {
        let s = snap([el("AXButton", "Apply", ancestors: ["Sidebar"]), el("AXButton", "Apply", ancestors: ["Inspector"])])
        let within = TargetResolver.resolve(ActionTarget(role: "button", title: "Apply", within: "Inspector"), in: s)
        #expect(within.state == .exact && within.element?.ancestorTitles == ["Inspector"])
        var ordinal = ActionTarget(role: "button", title: "Apply"); ordinal.occurrence = 2
        #expect(TargetResolver.resolve(ordinal, in: s).state == .strong)
        let dialog = WindowSnapshot(index: 0, title: "Alert", role: "AXWindow", subrole: nil, frame: .zero, isMain: true, isFocused: true, isMinimized: false, isModal: true, isSheet: false, cgWindowID: nil, identifier: nil)
        let modal = snap([el("AXButton", "OK"), el("AXButton", "OK", modal: true)], windows: [dialog])
        let m = TargetResolver.resolve(ActionTarget(role: "button", title: "OK"), in: modal)
        #expect(m.state == .strong && m.element?.inModal == true)
        let foc = snap([el("AXTextField", "Name"), el("AXTextField", "Name", focused: true)])
        #expect(TargetResolver.resolve(ActionTarget(role: "textField", title: "Name"), in: foc).element?.focused == true)
    }

    @Test("role words map to AX roles; identifiers are exact")
    func rolesAndIdentifiers() {
        let s = snap([el("AXRadioButton", "Render Properties"), el("AXStaticText", "Render Properties"), el("AXButton", "x", id: "stop.button")])
        #expect(TargetResolver.resolve(ActionTarget(role: "tab", title: "Render Properties"), in: s).element?.role == "AXRadioButton")
        #expect(TargetResolver.resolve(ActionTarget(identifier: "stop.button"), in: s).state == .exact)
    }

    @Test("an actionable control wins over a label with the same text")
    func prefersActionable() {
        var label = el("AXStaticText", "Save"); label.actions = []
        let s = snap([label, el("AXButton", "Save")])
        #expect(TargetResolver.resolve(ActionTarget(title: "Save"), in: s).element?.role == "AXButton")
    }

    @Test("windows: exact, contained, ambiguous, modal first, focus as context")
    func windows() {
        func w(_ i: Int, _ t: String, focused: Bool = false, modal: Bool = false) -> WindowSnapshot { WindowSnapshot(index: i, title: t, role: "AXWindow", subrole: nil, frame: .zero, isMain: focused, isFocused: focused, isMinimized: false, isModal: modal, isSheet: false, cgWindowID: nil, identifier: nil) }
        #expect(TargetResolver.resolveWindow(title: "Preferences", in: [w(0, "Preferences"), w(1, "Main")]).state == .exact)
        #expect(TargetResolver.resolveWindow(title: "pref", in: [w(0, "My Preferences"), w(1, "Main")]).state == .strong)
        #expect(TargetResolver.resolveWindow(title: "Document", in: [w(0, "Document 1"), w(1, "Document 2")]).state == .ambiguous)
        #expect(TargetResolver.resolveWindow(title: "Document", in: [w(0, "Document 1", focused: true), w(1, "Document 2")]).window?.index == 0)
        #expect(TargetResolver.resolveWindow(title: nil, in: [w(0, "Main", focused: true), w(1, "Alert", modal: true)]).window?.index == 1)
        #expect(TargetResolver.resolveWindow(title: "nothing", in: [w(0, "Main")]).state == .notFound)
        #expect(TargetResolver.resolveWindow(title: nil, in: []).state == .notFound)
    }

    @Test("the same target in the same place is still valid; a changed control or window is STALE")
    func fingerprint() {
        let s = snap([el("AXButton", "Run")])
        let fp = ActionFingerprint.of(s.elements[0], in: s)
        #expect(fp.stillValid(in: s, element: s.elements[0]) == .fresh)
        var other = s.elements[0]; other.title = "Stop"
        #expect(fp.stillValid(in: s, element: other) != .fresh)
        var s2 = s; s2.windows[0].title = "Other"
        #expect(fp.stillValid(in: s2, element: s.elements[0]) != .fresh)
        var s3 = s; s3.windows[0].frame.size.width = 900
        #expect(fp.stillValid(in: s3, element: s.elements[0]) != .fresh)
    }
}

@Suite("Computer · goals and the capability ladder")
struct ComputerGoalTests {
    let ctx = GoalContext(projectRoot: NSTemporaryDirectory(), unityProjectOpen: false)

    private func parsed(_ s: String, context: GoalContext? = nil) -> ParsedGoal? {
        if case .computer(let p) = ComputerGoalParser.classify(s, context: context ?? ctx) { return p }
        return nil
    }
    private func classification(_ s: String) -> GoalClassification { ComputerGoalParser.classify(s, context: ctx) }

    @Test("open / launch / switch — English and Turkish, Turkish suffixes included")
    func openApps() {
        for (text, bundle) in [("Open Xcode.", "com.apple.dt.Xcode"), ("open finder", "com.apple.finder"), ("Please launch Blender", "org.blenderfoundation.blender"), ("Xcode'u aç", "com.apple.dt.Xcode"),
                               ("Blender'ı başlat", "org.blenderfoundation.blender"), ("Finder'ı aç", "com.apple.finder"), ("Open System Settings", "com.apple.systempreferences"), ("switch to Unity", "com.unity3d.UnityEditor5.x"),
                               ("Unity'ye geç", "com.unity3d.UnityEditor5.x"), ("Jarvis, Xcode'u aç.", "com.apple.dt.Xcode")] {
            let p = parsed(text)
            #expect(p?.apps.first?.bundleID == bundle, "“\(text)”")
            #expect(p?.steps.flatMap(\.actions).contains { $0.kind == .activateApplication } == true, "“\(text)” must activate")
            #expect(p?.capability.mechanism == .accessibility)
        }
    }

    @Test("every parsed plan is short and made only of typed actions")
    func shortPlans() {
        for text in ["Open Xcode", "Show me the microphone permission page", "Click the Render Properties tab in Blender", "Open Xcode Settings", "Reveal \(NSTemporaryDirectory()) in Finder"] {
            guard let p = parsed(text) else { Issue.record("not parsed: \(text)"); continue }
            #expect(p.steps.flatMap(\.actions).count <= ComputerLimits.maxActionsPerBatch * 2)
            for a in p.steps.flatMap(\.actions) { #expect(ComputerActionKind.allCases.contains(a.kind)); #expect(a.origin == .userWords) }
        }
    }

    @Test("system settings pane, finder reveal, settings of an app, click on a labelled control")
    func shapes() {
        #expect(parsed("Show me the microphone permission page")?.steps.first?.actions.first?.pane == .microphone)
        #expect(parsed("Open the Accessibility permission page")?.steps.first?.actions.first?.pane == .accessibility)
        #expect(parsed("Mikrofon izin sayfasını göster")?.steps.first?.actions.first?.pane == .microphone)
        let reveal = parsed("Open Finder and show the project folder")
        #expect(reveal?.steps.first?.actions.first?.kind == .revealFile)
        #expect(reveal?.steps.first?.actions.first?.path == ctx.projectRoot)
        let settings = parsed("Open Xcode Settings")
        #expect(settings?.steps.last?.actions.first?.target.menuPath == ["@app", "Settings"])
        let click = parsed("Click the \"Render Properties\" tab in Blender")
        let press = click?.steps.flatMap(\.actions).first { $0.kind == .pressElement }
        #expect(press?.target.title == "Render Properties" && press?.target.role == "tab" && press?.target.app.bundleID == "org.blenderfoundation.blender")
        #expect(parsed("Click Run in Xcode")?.steps.flatMap(\.actions).first { $0.kind == .pressElement }?.target.title == "Run")
    }

    @Test("typing quoted text into a named field becomes a setText action with the user's own words")
    func typeText() {
        let p = parsed("type \"Weekly notes\" into the Name field in JARVIS Fixture")
        let a = p?.steps.flatMap(\.actions).first { $0.kind == .setText }
        #expect(a?.text == "Weekly notes" && a?.target.title == "Name" && a?.target.role == "textField" && a?.target.app.bundleID == "com.jarvis.fixture" && a?.origin == .userWords)
        #expect(parsed("type hello") == nil)                                         // no quoted text / no field → not a computer plan
    }

    @Test("a stronger mechanism owns the goal — Computer Use does NOT take it")
    func ladder() {
        func delegated(_ s: String) -> ComputerMechanism? { if case .delegate(let c) = classification(s) { return c.mechanism }; return nil }
        // Unity work → the V0.6 bridge
        #expect(delegated("Create a cube GameObject in the Unity scene") == .typedCapability)
        #expect(delegated("Add a Rigidbody component to the player in Unity") == .typedCapability)
        #expect(delegated("Compile the Unity project and run the play mode tests") == .typedCapability)
        #expect(delegated("Read the Unity Console errors") == .typedCapability)
        // code and file work → V0.4 project tools
        #expect(delegated("Change the Compact HUD size constant in the source") == .typedCapability)
        #expect(delegated("Fix the bug in the networking script") == .typedCapability)
        #expect(delegated("Create a new file called notes.md") == .typedCapability)
        #expect(delegated("Rename the file to Player.cs") == .typedCapability)
        // web → V0.9 research
        #expect(delegated("Research the best free character animations online") == .browserDOM)
        #expect(delegated("Search the web for URP shader docs") == .browserDOM)
        // git → Git tool
        #expect(delegated("Commit the changes with git") == .controlledCLI)
        // …but merely bringing Unity forward IS a GUI job
        #expect(parsed("Switch to Unity") != nil)
        #expect(parsed("Open Unity") != nil)
    }

    @Test("memory + capability selection together: 'Change Compact HUD through Xcode' is a SOURCE edit, not GUI")
    func compactHUDThroughXcode() {
        if case .delegate(let c) = classification("Change the Compact HUD layout through Xcode") { #expect(c.mechanism == .typedCapability && c.engine.contains("V0.4")) } else { Issue.record("must be delegated to the V0.4 tools") }
    }

    @Test("requests Computer Use must never carry out are refused, not planned")
    func refusals() {
        func refused(_ s: String) -> Bool { if case .refused = classification(s) { return true }; return false }
        #expect(refused("Open Terminal and run rm -rf ~/Downloads"))
        #expect(refused("Type sudo make me a sandwich in the terminal"))
        #expect(refused("Open the shell and execute this command"))
        #expect(refused("Click Buy Now"))
        #expect(refused("Press the Send button"))
        #expect(refused("Click Install"))
        #expect(refused("Click Allow in the dialog"))
        #expect(refused("Click Sign in"))
        #expect(refused("Terminal'de komut çalıştır"))
        // ordinary things are not refused
        #expect(!refused("Click the Run button in Xcode"))
        #expect(!refused("Open Terminal"))
    }

    @Test("ordinary chat is not a computer task")
    func notComputer() {
        for s in ["How are you?", "Explain NetworkPlayer", "What is a prefab?", "tell me a joke", "Open Agents", "Show me the report", "Raporu aç", "what did we decide about the camera"] {
            if case .computer = classification(s) { Issue.record("“\(s)” must not become a computer task") }
        }
    }

    @Test("a terminal bypass is recognised in English and Turkish")
    func terminalPhrases() {
        for s in ["open terminal and run ls", "type this command into the terminal", "iTerm'de komut calistir", "execute the script in the shell"] { #expect(CapabilityResolver.isTerminalBypass(s), "“\(s)”") }
        for s in ["open Terminal", "what is a shell", "switch to Xcode"] { #expect(!CapabilityResolver.isTerminalBypass(s), "“\(s)”") }
    }

    @Test("app aliases and unknown names")
    func apps() {
        #expect(AppCatalog.match(tokens: ComputerText.tokens("blender'ı aç"))?.app.display == "Blender")
        #expect(AppCatalog.match(tokens: ComputerText.tokens("open the project in xcode"))?.app.display == "Xcode")
        #expect(AppCatalog.match(tokens: ComputerText.tokens("what is a prefab")) == nil)
        #expect(AppRef(bundleID: "com.unity3d.UnityEditor5.x").matches(ApplicationSnapshot(pid: 1, bundleID: "com.unity3d.UnityEditor5.x", name: "Unity", isActive: false, isHidden: false)))
        #expect(AppRef(bundleID: "com.unity3d.UnityEditor5.x").matches(ApplicationSnapshot(pid: 1, bundleID: "com.unity3d.UnityEditor6.x", name: "Unity", isActive: false, isHidden: false)))
        #expect(!AppRef(bundleID: "com.apple.dt.Xcode").matches(ApplicationSnapshot(pid: 1, bundleID: "com.apple.finder", name: "Xcode Helper", isActive: false, isHidden: false)))
    }

    @Test("mechanism ladder ordering and which rungs Computer Use may execute itself")
    func ladderOrder() {
        #expect(ComputerMechanism.typedCapability < .accessibility && ComputerMechanism.accessibility < .vision && ComputerMechanism.vision < .rawCoordinates)
        #expect(ComputerMechanism.allCases.filter(\.isComputerUse) == [.accessibility, .vision, .rawCoordinates])
        #expect(CapabilityResolver.guiMechanism(axFound: true, visionEnabled: true, visionFound: true).0 == .accessibility)
        #expect(CapabilityResolver.guiMechanism(axFound: false, visionEnabled: true, visionFound: true).0 == .vision)
        #expect(CapabilityResolver.guiMechanism(axFound: false, visionEnabled: false, visionFound: true).0 == .accessibility)
    }
}
