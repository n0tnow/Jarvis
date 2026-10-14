import Testing
import Foundation
import CoreGraphics
@testable import Jarvis

// MARK: - Conversation / voice route

@MainActor
private final class FakeComputerSubmitter: ComputerSubmitting {
    var classify: (String) -> GoalClassification = { ComputerGoalParser.classify($0, context: GoalContext(projectRoot: nil)) }
    private(set) var submitted: [(goal: String, channel: InputSource)] = []
    func classifyComputer(_ text: String) -> GoalClassification { classify(text) }
    func submitComputer(goal: String, channel: InputSource) async -> TaskSubmission { submitted.append((goal, channel)); return .started(title: "Computer · \(goal)") }
}

@MainActor
@Suite("Computer · conversation and voice route")
struct ComputerRoutingTests {
    private func make() -> (ConversationService, ConversationStore, FakeComputerSubmitter) {
        let store = JarvisStore(), conv = ConversationStore(), windows = FakeWindows()
        DemoScenario.seed(store)
        let svc = ConversationService(store: store, conversation: conv, windows: windows)
        let sub = FakeComputerSubmitter()
        svc.computerSubmitter = sub
        return (svc, conv, sub)
    }

    @Test("“Open Xcode” becomes a computer task with a short acknowledgement that says what will happen")
    func openXcode() async throws {
        let (svc, conv, sub) = make()
        svc.submit("Open Xcode")
        try await Task.sleep(for: .milliseconds(120))
        #expect(sub.submitted.count == 1 && sub.submitted[0].channel == .typed)
        let ack = conv.last?.content ?? ""
        // V0.15: short by default, still says how to stop it
        #expect(ack.contains("stop") && ack.count < 80 && conv.last?.route == .worker)
    }

    @Test("a spoken Turkish request takes the same route; only the channel differs")
    func spoken() async throws {
        let (svc, conv, sub) = make()
        svc.submit("Jarvis, Xcode'u aç.", source: .voice)
        try await Task.sleep(for: .milliseconds(120))
        #expect(sub.submitted.count == 1 && sub.submitted[0].channel == .voice)
        #expect(conv.last?.content.contains("durdur") == true && (conv.last?.content.count ?? 999) < 80)
        let typed = make()
        typed.0.submit("Jarvis, Xcode'u aç.")
        try await Task.sleep(for: .milliseconds(120))
        #expect(typed.2.submitted.map(\.goal) == sub.submitted.map(\.goal) && typed.2.submitted.first?.channel == .typed)
    }

    @Test("the ladder: source edits, Unity operations, web research and Git never become computer tasks")
    func delegated() async throws {
        let (svc, _, sub) = make()
        for text in ["Change the Compact HUD layout through Xcode", "Add a Rigidbody component to the Player in the Unity scene", "Research free character animations online", "Fix the failing test in the project"] {
            svc.submit(text)
            try await Task.sleep(for: .milliseconds(60))
        }
        #expect(sub.submitted.isEmpty)
    }

    @Test("forbidden GUI requests are refused in words, create nothing, and need no model")
    func refused() async throws {
        let (svc, conv, sub) = make()
        for text in ["Click Buy Now", "Open Terminal and run rm -rf ~/Downloads", "Press the Send button"] {
            svc.submit(text)
            try await Task.sleep(for: .milliseconds(60))
            #expect(conv.last?.tone == .notice && conv.last?.route == .local, "\(text)")
        }
        #expect(sub.submitted.isEmpty)
    }

    @Test("ordinary conversation and HUD commands are untouched")
    func untouched() async throws {
        let (svc, conv, sub) = make()
        svc.submit("Open agents")
        svc.submit("how are you?")
        try await Task.sleep(for: .milliseconds(80))
        #expect(sub.submitted.isEmpty && !conv.messages.isEmpty)
    }

    @Test("with Computer Use switched off the request is not intercepted")
    func off() async throws {
        let (svc, _, sub) = make()
        sub.classify = { _ in .notComputer }
        svc.submit("Open Xcode")
        try await Task.sleep(for: .milliseconds(80))
        #expect(sub.submitted.isEmpty)
    }
}

// MARK: - TaskIntake (real classification + settings)

@MainActor
@Suite("Computer · intake")
struct ComputerIntakeTests {
    @Test("intake classifies only when the runtime exists and the setting is on")
    func gating() {
        let h = TaskHarness()
        let prefs = Preferences()
        let intake = TaskIntake(engine: h.engine, preferences: prefs)
        #expect(intake.classifyComputer("Open Xcode") == .notComputer)                                // no runtime wired
        h.engine.computer = ComputerRuntime(backend: FakeUI(), repository: h.repo, workspacePath: h.paths.researchWorkspace.path)
        let saved = prefs.computerUseEnabled
        prefs.computerUseEnabled = true
        if case .computer = intake.classifyComputer("Open Xcode") {} else { Issue.record("must classify") }
        prefs.computerUseEnabled = false
        #expect(intake.classifyComputer("Open Xcode") == .notComputer)
        prefs.computerUseEnabled = saved
    }
}

// MARK: - Persistence (schema v9)

@MainActor
@Suite("Computer · persistence")
struct ComputerPersistenceTests {
    @Test("schema v9 holds sessions, actions and observation METADATA — no text, tree, clipboard or pixels")
    func schema() throws {
        let h = TaskHarness()
        #expect(h.database.schemaVersion >= 9)
        let cols = try h.repo.database.read("SELECT name FROM pragma_table_info('computer_actions')").compactMap { $0.string("name") }
        #expect(!cols.contains("text") && cols.contains("text_class") && cols.contains("text_length"))
        let obs = try h.repo.database.read("SELECT name FROM pragma_table_info('computer_observations')").compactMap { $0.string("name") }
        #expect(obs.contains("persisted") && !obs.contains { ["pixels", "image", "tree", "dump", "blob"].contains($0) })
    }

    @Test("sessions round-trip, actions are bounded, observations are marked not persisted, restart interrupts")
    func roundTrip() throws {
        let h = TaskHarness()
        let id = UUID()
        var s = ComputerSessionRecord(id: id, taskID: id, goal: "open Xcode", status: .running, targetApps: ["Xcode"], planSummary: "x", capability: "E · Accessibility", visionEnabled: false, startedAt: Date(), finishedAt: nil, failure: nil, resumeCount: 0, memoryIDs: [], origin: "userTask")
        try h.repo.upsert(s)
        s.status = .completed; s.finishedAt = Date(); s.memoryIDs = [UUID()]
        try h.repo.upsert(s)
        let back = try #require(try h.repo.computerSession(id))
        #expect(back.status == .completed && back.targetApps == ["Xcode"] && back.memoryIDs.count == 1)
        for i in 0..<450 {
            try h.repo.insert(ComputerActionRecord(id: UUID(), sessionID: id, seq: i, at: Date(), kind: "pressElement", mechanism: "E Accessibility", app: "X", window: "W", target: "button “Run”", risk: "low", status: "verified", resolution: "exact",
                                                   verification: "PASS", detail: "ok", approvalID: nil, textClass: nil, textLength: nil, durationMS: 1, attempts: 1, provider: nil))
        }
        #expect(try h.repo.computerActions(sessionID: id, limit: 1000).count <= 401)
        try h.repo.insert(ComputerObservationRecord(id: UUID(), sessionID: id, at: Date(), kind: "screenshot", app: "X", window: "W", nodes: nil, windows: nil, truncated: false, durationMS: 5, width: 100, height: 80, fingerprint: "ff", provider: "Apple Vision", persisted: true))
        #expect(try h.repo.computerObservations(sessionID: id).allSatisfy { !$0.persisted })                  // there is no way to store one as persisted
        // restart
        var running = s; running.id = UUID(); running.taskID = running.id; running.status = .running; running.finishedAt = nil
        try h.repo.upsert(running)
        #expect(try h.repo.reconcileComputerAfterRestart() == 1)
        #expect(try h.repo.computerSession(running.id)?.status == .interrupted)
        #expect(try h.repo.computerSession(id)?.status == .completed)
    }

    @Test("sensitive text in details is redacted before it is stored")
    func redaction() throws {
        let h = TaskHarness()
        let id = UUID()
        try h.repo.upsert(ComputerSessionRecord(id: id, taskID: id, goal: "g", status: .running, targetApps: [], planSummary: nil, capability: nil, visionEnabled: false, startedAt: Date(), finishedAt: nil, failure: nil, resumeCount: 0, memoryIDs: [], origin: nil))
        let fake = "sk-" + String(repeating: "Zq9x", count: 8)
        try h.repo.insert(ComputerActionRecord(id: UUID(), sessionID: id, seq: 1, at: Date(), kind: "setText", mechanism: "E", app: "X", window: "W", target: "field", risk: "medium", status: "blocked", resolution: nil, verification: nil, detail: "tried \(fake)", approvalID: nil, textClass: "sensitive", textLength: 35, durationMS: 1, attempts: 1, provider: nil))
        let stored = try #require(try h.repo.computerActions(sessionID: id).first)
        #expect(!(stored.detail ?? "").contains(fake) && stored.textClass == "sensitive")
    }
}

// MARK: - Vision refinements

@MainActor
@Suite("Computer · coordinate click preconditions", .serialized)
struct ComputerClickPreconditionTests {
    @Test("a window that is covered by another window at the click point is STALE: no click")
    func occluded() async {
        let r = CURig(vision: ScriptedVision(boxes: ["launch": [CGRect(x: 100, y: 100, width: 80, height: 30)]])); r.visionOn = true
        r.ui.addApp("Canvas", bundle: "com.canvas", windows: [.init(title: "Canvas", frame: CGRect(x: 200, y: 150, width: 500, height: 300), elements: [])], front: true)
        r.ui.topWindowOverride = .some(99999)                     // something else is on top there
        let res = await r.ex.perform(ComputerAction(kind: .visionPress, target: ActionTarget(app: AppRef(bundleID: "com.canvas"), title: "Launch"), checks: [.stateChanged], summary: "vision press"))
        #expect(res.status == .stale && !r.did("click"))
    }

    @Test("a pointer in use delays the click and then steps back")
    func pointerInUse() async {
        struct Mouse: UserActivityProbe { func secondsSinceKeyOrClick() -> TimeInterval { .infinity }; func secondsSinceAnyPointerOrKeyInput() -> TimeInterval { 0.02 } }
        let r = CURig(vision: ScriptedVision(boxes: ["launch": [CGRect(x: 100, y: 100, width: 80, height: 30)]])); r.visionOn = true
        r.ui.addApp("Canvas", bundle: "com.canvas", windows: [.init(title: "Canvas", frame: CGRect(x: 200, y: 150, width: 500, height: 300), elements: [])], front: true)
        r.ex.activity = Mouse()
        let res = await r.ex.perform(ComputerAction(kind: .visionPress, target: ActionTarget(app: AppRef(bundleID: "com.canvas"), title: "Launch"), checks: [.stateChanged], summary: "vision press"))
        #expect(res.status == .userInterference && !r.did("click"))
    }
}

// MARK: - Human-facing wording stays honest and short

@Suite("Computer · wording")
struct ComputerWordingTests {
    @Test("acknowledgements are short, bilingual and name the stop controls")
    func ack() {
        let en = Phrasebook.computerStarted("Computer · Open Xcode", .en), tr = Phrasebook.computerStarted("Computer · Xcode'u aç", .tr)
        #expect(en.count < 260 && tr.count < 260 && en.contains("stop") && tr.contains("durdur") && en.contains("⌃⌥⌘"))
        #expect(!en.contains("click") && !en.localizedCaseInsensitiveContains("password"))
    }

    @Test("failure suggestions tell the user how to give permission, never to bypass it")
    func suggestions() {
        let s = TaskReport.suggestion(.permissionRequired)
        #expect(s.contains("System Settings") && s.contains("Accessibility") && s.contains("Screen Recording"))
        #expect(TaskReport.suggestion(.computerTimeout).contains("never force-quits"))
    }
}
