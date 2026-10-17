import Testing
import Foundation
import CoreGraphics
@testable import Jarvis

// V1.0 decision milestone — semantic media targeting (Computer Use stays the one GUI system) and the single system-status source. macOS-only suites: written in Cloud, run by scripts/verify.sh.

private func snap(_ elements: [UIElementSnapshot]) -> AXSnapshot {
    let w = [WindowSnapshot(index: 0, title: "Main", role: "AXWindow", subrole: nil, frame: CGRect(x: 0, y: 0, width: 600, height: 400), isMain: true, isFocused: true, isMinimized: false, isModal: false, isSheet: false, cgWindowID: 1, identifier: nil)]
    var els = elements
    for i in els.indices { els[i].id = i; els[i].handle = ElementHandle(pid: 1, generation: 1, index: i) }
    return AXSnapshot(app: ApplicationSnapshot(pid: 1, bundleID: "com.x", name: "X", isActive: true, isHidden: false), windows: w, windowIndex: 0, elements: els, generation: 1, truncated: false, capturedAt: Date(), durationMS: 1, focusedElement: nil)
}
private func button(_ title: String) -> UIElementSnapshot { FakeUI.element(role: "AXButton", title: title) }

@Suite("V1.0 decision · media targeting looks at the controls that are there — and still never guesses")
struct MediaTargetingTests {
    private func goal(_ text: String) -> ParsedGoal? {
        if case .computer(let g) = ComputerGoalParser.classify(text, context: GoalContext()) { return g }
        return nil
    }

    @Test("‘Tarayıcıda açık olan videoyu devam ettirir misin?’ is a Computer Use press with semantic alternatives — not “Stop”, not a Play/Pause toggle")
    func goalCarriesAlternatives() {
        let g = goal("Tarayıcıda açık olan videoyu devam ettirir misin?")
        let target = g?.steps.last?.actions.first?.target
        #expect(target?.title == "Play" && target?.role == "button")
        #expect(target?.titleAlternatives?.contains("Resume") == true && target?.titleAlternatives?.contains("Oynat") == true)
        let all = (target?.titleAlternatives ?? []) + (goal("Videoyu durdur")?.steps.last?.actions.first?.target.titleAlternatives ?? [])
        #expect(!all.contains("Stop") && !all.contains { $0.contains("/") }, "a browser's Stop-loading button and a toggle would do the wrong thing")
        #expect(goal("Videoyu durdur")?.steps.last?.actions.first?.target.title == "Pause")
    }

    @Test("a player whose button is called ‘Resume’ is found; a page with no media control is an honest NOT_FOUND that says what was tried")
    func resolution() {
        let target = goal("Videoyu devam ettir")!.steps.last!.actions.first!.target
        let withResume = TargetResolver.resolve(target, in: snap([button("Resume"), button("Share")]))
        #expect(withResume.state == .exact && withResume.element?.title == "Resume")
        let literal = TargetResolver.resolve(target, in: snap([button("Play"), button("Resume")]))
        #expect(literal.element?.title == "Play", "the literal label still wins")
        let none = TargetResolver.resolve(target, in: snap([button("Share"), button("Stop")]))
        #expect(none.state == .notFound && none.element == nil && none.reason.contains("also looked for"), Comment(rawValue: none.reason))
    }

    @Test("two controls that could be it are AMBIGUOUS — JARVIS asks, never picks")
    func ambiguousStaysAmbiguous() {
        let target = goal("Videoyu devam ettir")!.steps.last!.actions.first!.target
        let two = TargetResolver.resolve(target, in: snap([button("Resume"), button("Resume")]))
        #expect(two.state == .ambiguous && two.element == nil)
    }

    @Test("tasks stored before the field existed still decode")
    func oldRecordsDecode() throws {
        let old = #"{"app":{},"role":"button","title":"Play","menuPath":[]}"#.data(using: .utf8)!
        let t = try JSONDecoder().decode(ActionTarget.self, from: old)
        #expect(t.title == "Play" && t.titleAlternatives == nil)
    }
}

@MainActor
@Suite("V1.0 decision · one source of truth for system status")
struct SystemStatusSourceTests {
    @Test("the System page's tiles and the spoken detailed status read the SAME snapshot (refresh returns the snapshot the page reads)")
    func sameSnapshot() {
        let service = ReadinessService(probes: probes2())
        let returned = service.refresh()
        #expect(returned == service.snapshot, "the conversation reads refresh(), the page reads snapshot: one value")
        let status = SystemStatusSnapshot(state: .idle, versionLine: "0.15.0 · build 1", readiness: returned, project: nil, activeTasks: 0, activeAgents: 0, voiceOn: true, pushToTalkOn: true, wakeEnabled: false, wakeDetector: .stopped, providerPreference: "Auto")
        let tiles = returned.tiles
        let detailed = SystemStatusComposer.compose(status, language: .tr, detailed: true)
        #expect(detailed.contains("Hazır: \(tiles.ready) · dikkat gerektiren: \(tiles.attention) · isteğe bağlı: \(tiles.optional)"), Comment(rawValue: detailed))
        let english = SystemStatusComposer.compose(status, language: .en, detailed: true)
        #expect(english.contains("Ready: \(tiles.ready) · needs attention: \(tiles.attention) · optional: \(tiles.optional)"))
    }

    @Test("a state that is not known is said as not known — nothing is invented for a missing field")
    func honestUnknown() {
        let service = ReadinessService(probes: probes2 { $0.appleSTT = { nil } })
        let snapshot = service.refresh()
        let status = SystemStatusSnapshot(state: .idle, versionLine: "x", readiness: snapshot, project: nil, activeTasks: 0, activeAgents: 0, voiceOn: true, pushToTalkOn: true, wakeEnabled: false, wakeDetector: .stopped, providerPreference: "Auto")
        let detailed = SystemStatusComposer.compose(status, language: .en, detailed: true)
        #expect(detailed.contains("not checked yet"), Comment(rawValue: detailed))
    }
}
