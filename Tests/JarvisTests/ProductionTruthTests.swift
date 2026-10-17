import Testing
import Foundation
@testable import Jarvis

// V1.0 stabilisation fix 2 — Section C: the installed app shows only real data. A production launch seeds nothing, and the demo / simulator
// machinery is unreachable from production code paths.

@Suite("Production · no demo or mock state")
@MainActor
struct ProductionTruthTests {
    private func freshContext(demo: Bool = false) -> AppContext {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-prod-\(UUID().uuidString)")
        return AppContext(seedDemoData: demo, stubIntelligence: true, dataDirectory: dir)
    }

    @Test("a fresh production context has zero demo records in every read model")
    func freshIsEmpty() {
        let app = freshContext()
        #expect(app.demoMode == false)
        #expect(app.store.tasks.isEmpty && app.store.engineTasks.isEmpty && app.store.allTasks.isEmpty)
        #expect(app.store.project == nil && app.store.agents.isEmpty && app.store.tools.isEmpty)
        #expect(app.store.pendingApproval == nil && app.store.activeTask == nil)
        #expect(app.observatory.demo == nil)
        #expect(app.hub.activeRuns.isEmpty)
        #expect(app.store.state == .idle)
        let text = app.store.activity.map(\.message).joined(separator: "\n").lowercased()
        #expect(!text.contains("demo") && !text.contains("simulated") && !text.contains("mock"))
    }

    @Test("the state simulator is never visible in production, even with Show Developer Controls on")
    func simulatorHidden() {
        let app = freshContext()
        app.preferences.showDeveloperControls = true
        #expect(app.simulatorControlsVisible == false)
        let demo = freshContext(demo: true)
        demo.preferences.showDeveloperControls = true
        #expect(demo.simulatorControlsVisible == true && demo.demoMode)
        demo.preferences.showDeveloperControls = false
        #expect(demo.simulatorControlsVisible == false)
    }

    @Test("a demo environment is only reachable through explicit developer launch options")
    func launchOptions() {
        #expect(LaunchOptions(arguments: ["Jarvis"]).isDemoEnvironment == false)
        var o = LaunchOptions(arguments: ["Jarvis"]); o.devDemo = true
        #expect(o.isDemoEnvironment)
        var s = LaunchOptions(arguments: ["Jarvis"]); s.smokeTest = true
        #expect(s.isDemoEnvironment)
    }

    @Test("an approval is labelled SIMULATED only when it really is")
    func approvalLabel() {
        #expect(ApprovalRequest(title: "t", detail: "d").simulated == false)
    }

    @Test("source guard: demo and fixture types are referenced only from developer, test and capture code")
    func sourceGuard() throws {
        let root = repoRoot().appendingPathComponent("Sources/Jarvis")
        let allowedDirs = ["Services/Demo/", "App/SmokeTest.swift", "App/DevCapture.swift", "Observability/ObservatoryDemo.swift"]
        let allowedByName: (String) -> Bool = { $0.hasSuffix("LiveTest.swift") || $0.hasSuffix("LiveTests.swift") || $0.contains("/App/AppDelegate.swift") || $0.contains("/App/AppContext.swift") || $0.contains("/App/LaunchOptions.swift") }
        let names = ["DemoScenario", "TaskDemo", "ResearchDemo", "AdaptiveDemo", "OrchestrationDemo", "ObservatoryDemo", "DemoAgentRunner", "DemoData", "DemoCatalog"]
        var offenders: [String] = []
        for path in swiftFiles(under: root) {
            let rel = path.path.replacingOccurrences(of: root.path + "/", with: "")
            if allowedDirs.contains(where: { rel.hasPrefix($0) || rel == $0 }) || allowedByName(path.path) { continue }
            let text = try String(contentsOf: path, encoding: .utf8)
            for n in names where text.contains(n) {
                // The only production files allowed to mention them: the dev strip (itself gated by `simulatorControlsVisible`) and the observatory field.
                if rel == "UI/Components/DevStateStrip.swift" || rel == "Observability/AgentObservatory.swift" || rel == "Observability/ExecutionHub.swift" { continue }
                offenders.append("\(rel): \(n)")
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    @Test("source guard: the simulator strip, demo tasks and simulate menu are gated by simulatorControlsVisible, not by the developer switch alone")
    func gatedViews() throws {
        let ui = repoRoot().appendingPathComponent("Sources/Jarvis/UI")
        for path in swiftFiles(under: ui) {
            let text = try String(contentsOf: path, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (i, line) in lines.enumerated() where line.contains("DevStateStrip(") || line.contains("{ demoTasks }") || line.contains("{ simulateMenu }") {
                if path.lastPathComponent == "DevStateStrip.swift" { continue }
                let window = lines[max(0, i - 1)...i].joined(separator: " ")           // the `if` is on the same or the previous line
                #expect(window.contains("simulatorControlsVisible"), "\(path.lastPathComponent):\(i + 1) must be gated on simulatorControlsVisible")
            }
        }
    }

    @Test("source guard: production strings never ship placeholder statuses")
    func noPlaceholderStrings() throws {
        let ui = repoRoot().appendingPathComponent("Sources/Jarvis/UI")
        for path in swiftFiles(under: ui) {
            let text = try String(contentsOf: path, encoding: .utf8)
            for bad in ["DEMO · NOT CONNECTED", "PLANNED · V0.8", "Lorem ipsum", "\"IN-MEMORY\""] { #expect(!text.contains(bad), "\(path.lastPathComponent): \(bad)") }
        }
    }

    @Test("source guard: the voice-state simulation hooks are called only by smoke and capture code")
    func simulateHooks() throws {
        let root = repoRoot().appendingPathComponent("Sources/Jarvis")
        for path in swiftFiles(under: root) {
            let name = path.lastPathComponent
            if name == "SmokeTest.swift" || name == "DevCapture.swift" || name == "VoiceCoordinator.swift" || name == "HandsFreeCoordinator.swift" { continue }
            let text = try String(contentsOf: path, encoding: .utf8)
            #expect(!text.contains("voice.simulate(") && !text.contains("hf.simulate(") && !text.contains("handsFree.simulate("), "\(name)")
        }
    }

    // MARK: helpers
    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" { url.deleteLastPathComponent(); if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { return url } }
        return url
    }
    private func swiftFiles(under dir: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
