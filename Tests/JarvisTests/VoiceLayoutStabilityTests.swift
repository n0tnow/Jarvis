import Testing
import SwiftUI
import AppKit
@testable import Jarvis

// V1.0 stabilisation fix 2 — the voice-state layout shift. Cause (found in the real app): `VoiceStrip` was inserted above the conversation while a voice session was active and removed afterwards,
// resizing the conversation viewport on every state change. Rule now: a fixed reserved status region; only its content changes.

@Suite("Stabilisation 2 · D · voice states do not move the conversation")
@MainActor
struct VoiceLayoutStabilityTests {
    private func makeApp() -> AppContext {
        AppContext(seedDemoData: false, stubIntelligence: true, dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-layout-\(UUID().uuidString)"))
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        var out: [NSScrollView] = []
        if let s = view as? NSScrollView { out.append(s) }
        for sub in view.subviews { out += scrollViews(in: sub) }
        return out
    }

    private func settle(_ host: NSView) {
        for _ in 0..<4 { RunLoop.current.run(until: Date().addingTimeInterval(0.04)); host.layoutSubtreeIfNeeded() }
    }

    @Test("the conversation viewport frame is identical in IDLE, LISTENING, TRANSCRIBING, THINKING, SPEAKING and ERROR (voice on)")
    func framesAreStable() {
        let app = makeApp()
        app.preferences.voiceEnabled = true
        for i in 0..<12 { app.conversation.appendJarvis("Satır \(i): bir şeyler söyleyen uzunca bir yanıt metni burada duruyor.", route: .local) }
        let root = ConversationPanel().environment(app).frame(width: 640, height: 420)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        settle(host)
        let baseline = scrollViews(in: host).first?.frame
        #expect(baseline != nil && baseline!.height > 100)

        let states: [(String, () -> Void)] = [
            ("idle", { app.voice.simulate(state: .idle); app.handsFree.simulate(state: .dormant, wake: .off) }),
            ("wake", { app.handsFree.simulate(state: .wakeListening, wake: .listening) }),
            ("attentive", { app.handsFree.simulate(state: .attentive, wake: .listening) }),
            ("listening", { app.voice.simulate(state: .listening, partial: "Jarvis, Unity'deki son task'ın durumunu gösterir misin lütfen çok uzun bir geçici transkript", level: 0.6) }),
            ("transcribing", { app.voice.simulate(state: .transcribing, partial: "") }),
            ("thinking", { app.voice.simulate(state: .thinking) }),
            ("speaking", { app.voice.simulate(state: .speaking) }),
            ("error", { app.voice.simulate(state: .error("Microphone access was not allowed. You can allow it in System Settings; typing still works. Typing still works, and this message is intentionally very long so that it would wrap.")) }),
            ("idle again", { app.voice.simulate(state: .idle); app.handsFree.simulate(state: .dormant, wake: .off) }),
        ]
        for (name, apply) in states {
            apply(); settle(host)
            let frame = scrollViews(in: host).first?.frame
            #expect(frame == baseline, "\(name): the conversation viewport moved (\(String(describing: frame)) vs \(String(describing: baseline)))")
            #expect(host.frame.size == NSSize(width: 640, height: 420), "\(name): the host frame changed")
        }
    }

    @Test("the reserved region is a fixed height and exists independently of the session state")
    func reservedRegion() {
        #expect(VoiceStrip.reservedHeight == 26)
        #expect(VoiceStrip.reservesSpace(voiceEnabled: true, presenceQuiet: true, hasPartial: false))        // idle with voice on: still reserved
        #expect(VoiceStrip.reservesSpace(voiceEnabled: true, presenceQuiet: false, hasPartial: true))
        #expect(!VoiceStrip.reservesSpace(voiceEnabled: false, presenceQuiet: true, hasPartial: false))      // voice off: no empty strip
    }

    @Test("the Compact HUD keeps its exact size")
    func compactSize() {
        #expect(CompactHUDLayout.size == CGSize(width: 392, height: 448))
    }
}
