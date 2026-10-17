import Testing
import Foundation
@testable import Jarvis

/// Fix 4 — “Videoyu oynat / durdur” is a Computer Use goal: press the player's own Play / Pause control and verify the state change.
@MainActor
struct Fix4MediaTests {
    private func plan(_ s: String) -> ParsedGoal? {
        if case .computer(let p) = ComputerGoalParser.classify(s, context: GoalContext()) { return p }
        return nil
    }

    @Test("TR and EN media requests become one semantic press of Play or Pause")
    func parsing() {
        for s in ["Videoyu oynat", "Videoyu başlat", "Videoyu devam ettir", "Play the video", "Resume the video"] {
            let p = plan(s)
            let action = p?.steps.last?.actions.last
            #expect(action?.kind == .pressElement && action?.target.title == "Play" && action?.target.role == "button", "\(s)")
            #expect(action?.checks.contains(.stateChanged) == true, "\(s)")
        }
        for s in ["Videoyu durdur", "Videoyu duraklat", "Pause the video", "Stop the video"] {
            let p = plan(s)
            #expect(p?.steps.last?.actions.last?.target.title == "Pause", "\(s)")
        }
    }

    @Test("a bare stop word is not a media command, and a media noun alone is not either")
    func negatives() {
        for s in ["Durdur", "Sus", "Görevi durdur", "Videoyu göster"] {
            let p = plan(s)
            #expect(p?.steps.last?.actions.last?.target.title != "Pause" && p?.steps.last?.actions.last?.target.title != "Play", "\(s)")
        }
    }

    @Test("executed against a player: Play → Pause is verified by the state change, and the action does not repeat")
    func execution() async {
        let r = CURig()
        var win = FakeUI.Window(title: "Fixture Player")
        win.elements = [
            FakeUI.Element(role: "AXStaticText", title: "State: paused", actions: []),
            FakeUI.Element(role: "AXButton", title: "Play", onPress: { ui, pid in
                guard let wi = ui.apps[pid]?.windows.firstIndex(where: { $0.isFocused }) else { return }
                ui.apps[pid]!.windows[wi].elements[0].title = "State: playing"
                ui.apps[pid]!.windows[wi].elements[1].title = "Pause"
            }),
        ]
        r.ui.addApp("Player", bundle: "com.demo.player", windows: [win], front: true)
        let res = await r.act(.pressElement, app: "com.demo.player", role: "button", title: "Play", checks: [.stateChanged])
        #expect(res.status == .verified && res.attempts == 1)
        #expect(r.count("press") == 1)
        let again = await r.act(.pressElement, app: "com.demo.player", role: "button", title: "Play", checks: [.stateChanged])
        #expect(again.status != .verified, "after playing there is no Play button any more — it must not claim success")
    }
}
