import Foundation
import Testing
@testable import Jarvis

/// Scripted modifier timelines for Push-to-Talk (hold the RIGHT Option key alone). No keyboard hardware involved.
@Suite("Push-to-Talk machine")
struct PushToTalkMachineTests {
    private struct Key { var right = false, left = false, cmd = false, shift = false, control = false }

    /// `timeline`: (start time, keys down). `keyDowns`: times of real key/mouse presses. Sampled every 16 ms.
    private func run(_ timeline: [(Double, Key)], until end: Double, keyDowns: [Double] = [], machine: inout PushToTalkMachine) -> [(Double, PushToTalkMachine.Action)] {
        var out: [(Double, PushToTalkMachine.Action)] = []
        var t = 0.0
        while t <= end {
            let k = timeline.last { $0.0 <= t }?.1 ?? Key()
            let age = keyDowns.filter { $0 <= t }.map { t - $0 }.min() ?? 1000
            let s = ModifierSample(time: t, option: k.right || k.left, command: k.cmd, other: k.shift || k.control, secondsSinceOtherInput: age,
                                   rightOption: k.right, leftOption: k.left, shift: k.shift, control: k.control)
            if let a = machine.update(s) { out.append((t, a)) }
            t += 0.016
        }
        return out
    }

    @Test func holdingRightOptionAloneStartsAfterTheThresholdAndReleasesOnce() {
        var m = PushToTalkMachine()
        let a = run([(1.0, Key(right: true)), (2.0, Key())], until: 3.0, machine: &m)
        #expect(a.map(\.1) == [.press, .release(interrupted: false)])
        #expect(a[0].0 >= 1.0 + PushToTalkMachine.holdThreshold && a[0].0 < 1.0 + PushToTalkMachine.holdThreshold + 0.05)
        #expect(a[1].0 >= 2.0 && a[1].0 < 2.05)
    }

    @Test func aShortTapNeverOpensTheMicrophone() {
        var m = PushToTalkMachine()
        #expect(run([(1.0, Key(right: true)), (1.15, Key())], until: 3.0, machine: &m).isEmpty)
    }

    @Test func keyRepeatCannotProduceASecondPress() {
        var m = PushToTalkMachine()
        var presses = 0
        for i in 0..<3000 { if m.update(ModifierSample(time: 1 + Double(i) * 0.005, option: true, command: false, other: false, secondsSinceOtherInput: 1000, rightOption: true)) == .press { presses += 1 } }
        #expect(presses == 1)
    }

    @Test func leftOptionAloneNeverTriggers() {
        var m = PushToTalkMachine()
        #expect(run([(1.0, Key(left: true))], until: 3.0, machine: &m).isEmpty)
    }

    @Test func bothOptionKeysOrAnyExtraModifierNeverTrigger() {
        for k in [Key(right: true, left: true), Key(right: true, cmd: true), Key(right: true, shift: true), Key(right: true, control: true)] {
            var m = PushToTalkMachine()
            #expect(run([(1.0, k)], until: 3.0, machine: &m).isEmpty)
        }
    }

    @Test func typingAnOptionCharacterDuringTheHoldCancelsBeforeThePress() {
        var m = PushToTalkMachine()          // AltGr + a key on a Turkish layout: the key arrives while the hold is still arming
        #expect(run([(1.0, Key(right: true))], until: 3.0, keyDowns: [1.1], machine: &m).isEmpty)
    }

    @Test func aKeyPressedJustBeforeTheOptionKeyBlocksTheAttempt() {
        var m = PushToTalkMachine()
        #expect(run([(1.0, Key(right: true))], until: 3.0, keyDowns: [0.99], machine: &m).isEmpty)
    }

    @Test func anExtraModifierJoiningWhileTalkingEndsItAsInterrupted() {
        var m = PushToTalkMachine()
        let a = run([(1.0, Key(right: true)), (2.0, Key(right: true, cmd: true)), (2.5, Key())], until: 3.0, machine: &m)
        #expect(a.map(\.1) == [.press, .release(interrupted: true)])
    }

    @Test func aKeyPressedWhileAlreadyTalkingDoesNotEndTheRecording() {
        var m = PushToTalkMachine()
        let a = run([(1.0, Key(right: true)), (3.0, Key())], until: 4.0, keyDowns: [2.0], machine: &m)
        #expect(a.map(\.1) == [.press, .release(interrupted: false)])
    }

    @Test func afterAnAttemptTheKeyMustBeReleasedBeforeItCanArmAgain() {
        var m = PushToTalkMachine()
        // joined by Shift (blocked), Shift released while Right Option stays down: still no press until a clean release and re-press
        let a = run([(1.0, Key(right: true, shift: true)), (1.5, Key(right: true)), (2.0, Key()), (2.2, Key(right: true)), (3.0, Key())], until: 4.0, machine: &m)
        #expect(a.map(\.1) == [.press, .release(interrupted: false)])
        #expect(a[0].0 > 2.2)
    }

    @Test func twoQuickPressesAreTwoIndependentSessions() {
        var m = PushToTalkMachine()
        let a = run([(1.0, Key(right: true)), (1.6, Key()), (2.0, Key(right: true)), (2.6, Key())], until: 4.0, machine: &m)
        #expect(a.map(\.1) == [.press, .release(interrupted: false), .press, .release(interrupted: false)])
    }

    @Test func optionCommandChordsStayIndependent() {
        // ⌥⌘ is the HUD chord: with Command involved Push-to-Talk never starts, and the chord machine still sees its own sample.
        var m = PushToTalkMachine(); var chord = ModifierChordMachine()
        var talk = 0, compact = 0
        var t = 0.0
        while t < 2 {
            let s = ModifierSample(time: t, option: true, command: t > 1.0, other: false, secondsSinceOtherInput: 1000, rightOption: true)
            if m.update(s) != nil { talk += 1 }
            if chord.update(s) == .toggleCompact { compact += 1 }
            t += 0.016
        }
        #expect(compact == 1)
        #expect(talk <= 2)           // it may have started during the first second (Option alone), and then ended as interrupted — never a second session
    }
}

@MainActor
@Suite("Hotkey service and Push-to-Talk")
struct PushToTalkServiceTests {
    final class Script { var right = false; var now = 0.0 }

    private func service(_ script: Script, chords: Bool = true, log: @escaping (String) -> Void) -> GlobalHotkeyService {
        let s = GlobalHotkeyService(sampler: { ModifierSample(time: script.now, option: script.right, command: false, other: false, secondsSinceOtherInput: 1000, rightOption: script.right) },
                                    perform: { _ in log("chord") })
        s.chordsEnabled = chords
        s.performTalk = { action in log(action == .press ? "press" : "release") }
        return s
    }
    private func tick(_ s: GlobalHotkeyService, _ script: Script, until t: Double) { while script.now < t { script.now += 0.02; s.poll() } }

    @Test func pressAndReleaseReachTheHandler() {
        let script = Script(); var log: [String] = []
        let s = service(script) { log.append($0) }
        s.start()
        script.right = true; tick(s, script, until: 1.0)
        script.right = false; tick(s, script, until: 1.2)
        #expect(log == ["press", "release"])
    }

    @Test func stoppingTheServiceWhileTalkingReleasesTheMicrophone() {
        let script = Script(); var log: [String] = []
        let s = service(script) { log.append($0) }
        s.start(); script.right = true; tick(s, script, until: 1.0)
        s.stop()
        #expect(log == ["press", "release"])
    }

    @Test func removingTheHandlerWhileTalkingReleasesTheMicrophone() {
        let script = Script(); var log: [String] = []
        let s = service(script) { log.append($0) }
        s.start(); script.right = true; tick(s, script, until: 1.0)
        s.performTalk = nil
        #expect(log == ["press", "release"])
    }

    @Test func withoutAHandlerNothingIsEverDetected() {
        let script = Script(); var log: [String] = []
        let s = service(script) { log.append($0) }
        s.performTalk = nil
        s.start(); script.right = true; tick(s, script, until: 2.0)
        #expect(log.isEmpty)
    }

    @Test func pollingRateStaysFastOnlyWhileAnOptionKeyIsDown() {
        let script = Script(); let s = service(script) { _ in }
        s.start()
        #expect(s.pollInterval == GlobalHotkeyService.restInterval)
        script.right = true; tick(s, script, until: 0.1)
        #expect(s.pollInterval == GlobalHotkeyService.activeInterval)
        script.right = false; tick(s, script, until: 0.3)
        #expect(s.pollInterval == GlobalHotkeyService.restInterval)
    }
}
