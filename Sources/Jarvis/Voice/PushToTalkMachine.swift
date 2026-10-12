import Foundation

/// Push-to-Talk recogniser: hold the RIGHT Option key ALONE.
///
/// Why this key: it needs no macOS permission (it is read from the same modifier-state sampling as the ⌥⌘ shortcuts — no event tap, no
/// global monitor), it never types a character on its own, it is not part of the ⌥⌘ / ⌥⌘⌘ HUD chords (those need Command), and a hold
/// is a natural "talk" gesture. A hold shorter than `holdThreshold` does nothing, and ANY other key or click while the key is
/// being pressed cancels the attempt — so typing Option-characters (AltGr) on a Turkish layout can never open the microphone.
///
/// Level-based (it reads states, not events): key repeat cannot produce a second `press`, and after every attempt the key must be
/// released before it can arm again.
struct PushToTalkMachine {
    /// How long the key must be held, with nothing else happening, before the microphone starts. Deliberate, not accidental.
    static let holdThreshold: TimeInterval = 0.25
    /// Other input within this many seconds of the press means the key is part of a typing/shortcut sequence.
    static let inputTolerance: TimeInterval = 0.05

    enum Action: Equatable {
        case press
        /// `interrupted`: another modifier joined (a chord, not talking) — the audio must be discarded, not transcribed.
        case release(interrupted: Bool)
    }

    enum Phase: Equatable {
        case idle
        case arming(since: TimeInterval)
        case active(since: TimeInterval)
        case blocked                 // wait for the key to be released before arming again
    }

    private(set) var phase: Phase = .idle

    /// Callers sample faster while this is true.
    var isActive: Bool { phase != .idle }

    private static func isTrigger(_ s: ModifierSample) -> Bool {
        s.rightOption && !s.leftOption && !s.command && !s.shift && !s.control && !s.other
    }

    mutating func update(_ s: ModifierSample) -> Action? {
        let trigger = Self.isTrigger(s)
        switch phase {
        case .idle:
            guard s.rightOption else { return nil }
            // The key came down together with something else, or right after a real key/click: not a talk gesture.
            if !trigger || s.secondsSinceOtherInput < Self.inputTolerance { phase = .blocked; return nil }
            phase = .arming(since: s.time)
            return nil

        case .arming(let since):
            guard trigger else {
                phase = s.rightOption ? .blocked : .idle                // chord forming (blocked) or released early (nothing happens)
                return nil
            }
            // A key/click after the press (typing AltGr characters, ⌥-click) cancels the attempt.
            if s.time - s.secondsSinceOtherInput > since - Self.inputTolerance { phase = .blocked; return nil }
            if s.time - since >= Self.holdThreshold { phase = .active(since: s.time); return .press }
            return nil

        case .active:
            if trigger { return nil }
            let interrupted = s.rightOption                              // still down but joined by another modifier
            phase = interrupted ? .blocked : .idle
            return .release(interrupted: interrupted)

        case .blocked:
            if !s.rightOption { phase = .idle }
            return nil
        }
    }

    /// Forget everything (service stopped, app lost its input state).
    mutating func reset() { phase = .idle }

    /// `release` while active, forced by the coordinator (e.g. settings turned PTT off): returns to idle without an action.
    var isHolding: Bool { if case .active = phase { true } else { false } }
}
