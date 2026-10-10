import Foundation
import Testing
@testable import Jarvis

/// Scripted modifier timelines for the chord state machine. No keyboard hardware involved.
@Suite("Modifier chord state machine")
struct ChordMachineTests {
    typealias Key = (opt: Bool, cmd: Bool)

    /// Feeds `timeline` (list of (start time, state)) sampled every 16 ms until `end`; returns (time, action) pairs.
    private func run(_ timeline: [(t: Double, opt: Bool, cmd: Bool)], until end: Double, other: ((Double) -> Bool)? = nil,
                     inputAgo: ((Double) -> Double)? = nil, machine: inout ModifierChordMachine) -> [(Double, ModifierChordMachine.Action)] {
        var out: [(Double, ModifierChordMachine.Action)] = []
        var t = 0.0
        while t <= end {
            let state = timeline.last { $0.t <= t } ?? (0, false, false)
            let sample = ModifierSample(time: t, option: state.opt, command: state.cmd,
                                        other: other?(t) ?? false, secondsSinceOtherInput: inputAgo?(t) ?? 1000)
            if let a = machine.update(sample) { out.append((t, a)) }
            t += 0.016
        }
        return out
    }

    @Test func holdingOptionCommandTogglesCompactOnceAfterTheWindow() {
        var m = ModifierChordMachine()
        let actions = run([(1.0, true, true)], until: 3.0, machine: &m)
        #expect(actions.map(\.1) == [.toggleCompact])
        #expect(actions[0].0 >= 1.0 + ModifierChordMachine.window && actions[0].0 < 1.0 + ModifierChordMachine.window + 0.05)
    }

    @Test func doubleCommandTogglesFullAndNeverCompact() {
        var m = ModifierChordMachine()
        // ⌥ held from 1.0; ⌘ down 1.0–1.10, up, down again at 1.18 and held
        let actions = run([(1.0, true, true), (1.10, true, false), (1.18, true, true)], until: 3.0, machine: &m)
        #expect(actions.map(\.1) == [.toggleFull])           // no Compact flash first, no repeats while held
        #expect(actions[0].0 < 1.0 + ModifierChordMachine.window)
    }

    @Test func slowSecondPressIsTwoSeparateCompactToggles() {
        var m = ModifierChordMachine()
        // first press 1.0–1.10, second press only at 1.50 (outside the 0.3 s window)
        let actions = run([(1.0, true, true), (1.10, true, false), (1.50, true, true)], until: 3.0, machine: &m)
        #expect(actions.map(\.1) == [.toggleCompact, .toggleCompact])
    }

    @Test func releasingOptionEarlyFiresCompactImmediately() {
        var m = ModifierChordMachine()
        let actions = run([(1.0, true, true), (1.12, false, false)], until: 2.0, machine: &m)
        #expect(actions.map(\.1) == [.toggleCompact])
        #expect(actions[0].0 < 1.0 + ModifierChordMachine.window)   // before the timeout
    }

    @Test func repeatedIdenticalSamplesNeverDuplicateActions() {
        var m = ModifierChordMachine()
        var count = 0
        for i in 0..<2000 where m.update(ModifierSample(time: 1 + Double(i) * 0.005, option: true, command: true, other: false, secondsSinceOtherInput: 1000)) != nil { count += 1 }
        #expect(count == 1)
    }

    @Test func modifierReleaseResetsAndChordWorksAgain() {
        var m = ModifierChordMachine()
        let first = run([(1.0, true, true), (2.0, false, false)], until: 2.2, machine: &m)
        #expect(first.map(\.1) == [.toggleCompact])
        #expect(m.phase == .idle)
        var m2 = ModifierChordMachine()
        let both = run([(1.0, true, true), (1.1, true, false), (1.18, true, true), (1.6, false, false),
                        (3.0, true, true), (3.1, true, false), (3.18, true, true)], until: 4.5, machine: &m2)
        #expect(both.map(\.1) == [.toggleFull, .toggleFull])
    }

    @Test func singleModifiersAlone() {
        var m = ModifierChordMachine()
        #expect(run([(1.0, true, false)], until: 3, machine: &m).isEmpty)
        #expect(run([(1.0, false, true)], until: 3, machine: &m).isEmpty)
        #expect(m.phase == .idle)
    }

    @Test func extraModifierOrOtherInputInvalidatesTheChord() {
        // Shift joins the chord
        var a = ModifierChordMachine()
        #expect(run([(1.0, true, true)], until: 2.5, other: { $0 >= 1.1 }, machine: &a).isEmpty)
        // A letter key (e.g. ⌥⌘D) is pressed after the chord started: last input at t = 1.2
        var b = ModifierChordMachine()
        #expect(run([(1.0, true, true)], until: 2.5, inputAgo: { $0 >= 1.2 ? $0 - 1.2 : 1000 }, machine: &b).isEmpty)
        // A click (⌥⌘+click) right as the chord starts
        var c = ModifierChordMachine()
        #expect(run([(1.0, true, true)], until: 2.5, inputAgo: { $0 >= 1.0 ? $0 - 0.98 : 1000 }, machine: &c).isEmpty)
        // …and a blocked chord recovers once modifiers are released
        _ = run([(1.0, true, true), (2.0, false, false)], until: 2.2, other: { _ in true }, machine: &c)
        var d = ModifierChordMachine()
        #expect(run([(1.0, true, true)], until: 2.0, machine: &d).map(\.1) == [.toggleCompact])
    }

    @Test func fullCooldownPreventsAccidentalImmediateRetrigger() {
        var m = ModifierChordMachine()
        // Full fires on the 2nd press; a rapid 3rd press 0.1 s later must not trigger anything extra before the cooldown ends
        let actions = run([(1.0, true, true), (1.1, true, false), (1.18, true, true), (1.25, true, false), (1.30, true, true)], until: 1.55, machine: &m)
        #expect(actions.map(\.1) == [.toggleFull])
    }
}

@MainActor
@Suite("Global hotkey service")
struct HotkeyServiceTests {
    @Test func scriptedSamplesDriveWindowActions() {
        var now = 0.0
        var script: (opt: Bool, cmd: Bool) = (false, false)
        var received: [ModifierChordMachine.Action] = []
        let service = GlobalHotkeyService(
            sampler: { ModifierSample(time: now, option: script.opt, command: script.cmd, other: false, secondsSinceOtherInput: 1000) },
            perform: { received.append($0) })

        func advance(to t: Double, _ opt: Bool, _ cmd: Bool) { script = (opt, cmd); while now < t { now += 0.016; service.poll() } }
        advance(to: 1.0, false, false)    // idle first
        advance(to: 1.1, true, true)
        advance(to: 1.2, true, false)
        advance(to: 1.3, true, true)      // second press inside the window → Full
        #expect(received == [.toggleFull])
        advance(to: 2.0, false, false)
        #expect(service.phase == .idle)
        advance(to: 3.0, false, false)
        advance(to: 3.6, true, true)      // plain hold → Compact after the window
        #expect(received == [.toggleFull, .toggleCompact])
    }

    @Test func pollRatesAreRestingLowAndActiveHigh() {
        #expect(GlobalHotkeyService.restInterval >= 1.0 / 15)       // ≤ 15 wake-ups/s at rest
        #expect(GlobalHotkeyService.activeInterval <= 1.0 / 30)     // fine enough to catch a quick ⌘ tap
        #expect(ModifierChordMachine.window >= 0.25 && ModifierChordMachine.window <= 0.35)
    }

    @Test func systemSampleIsPermissionFreeAndWellFormed() {
        let s = GlobalHotkeyService.systemSample()
        #expect(s.time > 0 && s.secondsSinceOtherInput >= 0)
    }
}
