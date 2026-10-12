import Foundation

/// One reading of the global modifier state. Pure data so the state machine is testable without a keyboard.
struct ModifierSample: Equatable {
    var time: TimeInterval
    var option: Bool
    var command: Bool
    /// Shift or Control held (⌥⌘⇧ / ⌥⌘⌃ are other people's shortcuts — never ours).
    var other: Bool
    /// Seconds since the last real keyDown / mouse-down anywhere in the session. Lets us tell a pure
    /// modifier chord from ⌥⌘+<key> or ⌥⌘+click without any Accessibility / Input Monitoring permission.
    var secondsSinceOtherInput: TimeInterval
    /// Which Option key(s) are down (device-dependent flag bits). `option` stays "either"; Push-to-Talk needs the RIGHT one alone.
    var rightOption = false
    var leftOption = false
    /// Control or Shift individually (`other` is their union); Push-to-Talk treats any extra modifier as "not me".
    var shift = false
    var control = false
}

/// Modifier-only chord recogniser.
///
///   ⌥⌘            hold Option, press Command (either Command key)            → toggle Compact HUD
///   ⌥⌘⌘           hold Option, press Command, release, press Command again    → toggle Full HUD
///                 (second press within `window` of the first)
///
/// Disambiguation: Compact fires when the first Command press is NOT followed by a second within `window`
/// (or when Option is released, whichever comes first); Full fires immediately on the second press and
/// cancels the pending Compact, so Compact never flashes before Full.
///
/// The machine is level-based (it reads states, not events), so key repeat / repeated flagsChanged can't
/// produce duplicate actions. After any action it waits for Command to be released before re-arming.
struct ModifierChordMachine {
    static let window: TimeInterval = 0.30
    static let fullCooldown: TimeInterval = 0.40
    /// Other input this close to (or after) the chord start means it's a real shortcut → ignore the chord.
    static let inputTolerance: TimeInterval = 0.10

    enum Action: Equatable { case toggleCompact, toggleFull }

    enum Phase: Equatable {
        case idle
        case pending(start: TimeInterval, commandReleased: Bool)   // ⌥⌘ down, deciding Compact vs Full
        case done(until: TimeInterval)                              // action fired; wait for Command release
        case blocked                                                // invalid chord; wait for modifiers to clear
    }

    private(set) var phase: Phase = .idle

    /// True when the chord could be in progress or Option is down — callers poll faster then.
    var isActive: Bool { phase != .idle }

    mutating func update(_ s: ModifierSample) -> Action? {
        switch phase {
        case .idle:
            guard s.option && s.command else { return nil }
            if s.other || s.secondsSinceOtherInput < Self.inputTolerance {
                phase = .blocked
            } else {
                phase = .pending(start: s.time, commandReleased: false)
            }
            return nil

        case .pending(let start, var commandReleased):
            let inputTime = s.time - s.secondsSinceOtherInput
            if s.other || inputTime > start - Self.inputTolerance {
                phase = .blocked                       // a letter/click/extra modifier joined: not our chord
                return nil
            }
            if !s.option {                              // Option released first → this was a plain ⌥⌘ tap
                phase = .done(until: s.time)
                return .toggleCompact
            }
            if s.time - start >= Self.window {          // no second press in time
                phase = .done(until: s.time)
                return .toggleCompact
            }
            if !s.command { commandReleased = true }
            if s.command && commandReleased {           // second Command activation
                phase = .done(until: s.time + Self.fullCooldown)
                return .toggleFull
            }
            phase = .pending(start: start, commandReleased: commandReleased)
            return nil

        case .done(let until):
            if (!s.command && s.time >= until) || (!s.option && !s.command) { phase = .idle }
            return nil

        case .blocked:
            if !s.option && !s.command && !s.other { phase = .idle }
            return nil
        }
    }

    mutating func reset() { phase = .idle }
}
