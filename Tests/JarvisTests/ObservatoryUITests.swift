import Testing
import Foundation
import AppKit
@testable import Jarvis

@MainActor
@Suite("Observatory presentation")
struct ObservatoryPresentationTests {
    @Test func theCommandRouterOpensTheAgentsSectionInEnglishAndTurkish() {
        let router = IntelligenceRouter()
        for phrase in ["show agents", "open the agents", "agents", "ajanlar", "ajanları göster", "workers"] {
            guard case .command(let intent, _) = router.route(phrase), case .openSection(let s) = intent else { Issue.record("not routed: \(phrase)"); continue }
            #expect(s == .agents, Comment(rawValue: phrase))
        }
        // A sentence that merely mentions a worker is still a request for an engine, not navigation.
        if case .command = router.route("Fix my worker thread bug in the Unity project") { Issue.record("must not be navigation") }
    }

    @Test func severityIsConveyedByTextMarkersNotOnlyColour() {
        let id = UUID()
        let events = [AgentConsoleEvent(id: 1, runID: id, kind: .completed, source: "JARVIS", summary: "done", severity: .success),
                      AgentConsoleEvent(id: 2, runID: id, kind: .warning, source: "JARVIS", summary: "careful", severity: .warning),
                      AgentConsoleEvent(id: 3, runID: id, kind: .error, source: "JARVIS", summary: "broke", severity: .error)]
        let text = ConsoleRenderer.render(events: events, tail: "live tail", dropped: 5).string
        #expect(text.contains("✓ done") && text.contains("! careful") && text.contains("✕ broke") && text.contains("live tail") && text.contains("5 earlier events"))
    }

    @Test func theRenderedConsoleContainsOnlySanitizedText() {
        let e = AgentConsoleEvent(id: 1, runID: UUID(), kind: .providerOutput, source: "x", summary: "key \(FakeSecrets.skKey)", detail: "token \(FakeSecrets.bearer)")
        let rendered = ConsoleRenderer.render(events: [e], tail: "", dropped: 0).string
        #expect(FakeSecrets.leaks(rendered).isEmpty)
    }

    @Test func theConsoleViewIsReadOnlySelectableAndNativelyCopyable() {
        let proxy = ConsoleCopyProxy()
        let scroll = AgentConsoleTextView.makeScroll(proxy: proxy, coordinator: AgentConsoleTextView.Coordinator())
        let tv = scroll.documentView as? NSTextView
        #expect(tv?.isEditable == false && tv?.isSelectable == true && proxy.textView === tv)
    }

    @Test func compactStripOnlyReportsRealOrRecentRuns() {
        let hub = ExecutionHub(repository: nil, artifacts: nil)
        #expect(AgentsSummaryStrip.shown(hub) == nil)
        let v = AgentRunView(id: UUID(), label: "t", agentType: "A", engine: .openCode, model: nil, parent: nil, phase: .running, startedAt: Date(), activity: "x", owner: .agent)
        hub.begin(v)
        #expect(AgentsSummaryStrip.shown(hub)?.id == v.id)
        hub.finish(v.id, phase: .completed)
        #expect(AgentsSummaryStrip.shown(hub)?.phase == .completed)                                    // recent result stays briefly visible
        #expect(CompactHUDLayout.size == CGSize(width: 392, height: 448))
    }

    @Test func voiceOverSentencesNameProviderAgentStateAndProgress() {
        var v = AgentRunView(id: UUID(), label: "t", agentType: "CodingAgent", engine: .openCode, model: "opencode/x", parent: nil, phase: .running, startedAt: Date(), activity: "x", owner: .agent)
        v.steps = (0..<6).map { AgentStep(index: $0, title: "s", state: $0 < 3 ? .done : .pending) }
        v.progress = ProgressCalculator.compute(v.steps)
        #expect(v.spoken == "OpenCode, CodingAgent, running, step 3 of 6")
        #expect(!HUDSection.allCases.isEmpty && HUDSection.allCases.contains(.agents) && HUDSection.agents.title == "AGENTS")
    }
}
