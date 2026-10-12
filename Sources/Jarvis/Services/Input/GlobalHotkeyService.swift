import AppKit

/// Global modifier-chord shortcuts (⌥⌘ and ⌥⌘⌘) WITHOUT any macOS permission.
///
/// Why polling: the supported ways to *listen* to global keyboard events (`NSEvent` global monitor,
/// `CGEventTap`, Carbon hotkeys) either need Accessibility / Input Monitoring or don't support modifier-only
/// combinations. Reading the current modifier state (`NSEvent.modifierFlags`, ~0.1 µs) and the time since the
/// last key/mouse input (`CGEventSource.secondsSinceLastEventType`) needs no permission, so we sample it:
///   • 12 Hz while nothing is happening (a negligible wake-up rate),
///   • 60 Hz only while Option is held / a chord is in progress,
/// feeding the pure `ModifierChordMachine`. This file only *detects*; what an action does is decided by the
/// caller (`AppDelegate` maps actions to `JarvisWindowControlling`).
@MainActor
final class GlobalHotkeyService {
    typealias Sampler = @MainActor () -> ModifierSample

    static let restInterval: TimeInterval = 1.0 / 12
    static let activeInterval: TimeInterval = 1.0 / 60

    private var machine = ModifierChordMachine()
    /// Push-to-Talk (V0.7): hold the right Option key alone. Same sampling, same zero-permission posture; off unless a handler is set.
    private var talk = PushToTalkMachine()
    var performTalk: (@MainActor (PushToTalkMachine.Action) -> Void)? {
        willSet {
            // Removing the handler while the key is held must still release the microphone.
            if newValue == nil, talk.isHolding { performTalk?(.release(interrupted: true)) }
            if newValue == nil { talk.reset() }
        }
    }
    /// The ⌥⌘ / ⌥⌘⌘ HUD chords can be switched off (Settings) while Push-to-Talk keeps working, and the other way round.
    var chordsEnabled = true
    private let sampler: Sampler
    private let perform: @MainActor (ModifierChordMachine.Action) -> Void
    private var timer: Timer?
    private var fast = false

    var isRunning: Bool { timer != nil }
    var pollInterval: TimeInterval { fast ? Self.activeInterval : Self.restInterval }
    var phase: ModifierChordMachine.Phase { machine.phase }

    init(sampler: @escaping Sampler = GlobalHotkeyService.systemSample,
         perform: @escaping @MainActor (ModifierChordMachine.Action) -> Void) {
        self.sampler = sampler
        self.perform = perform
    }

    deinit { timer?.invalidate() }

    func start() {
        guard timer == nil else { return }
        machine.reset()
        schedule(fast: false)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        machine.reset()
        // The microphone must never stay open because the shortcut service went away.
        if talk.isHolding { performTalk?(.release(interrupted: true)) }
        talk.reset()
    }

    /// One sampling step (also called directly by tests with a scripted sampler).
    func poll() {
        let sample = sampler()
        if let action = machine.update(sample), chordsEnabled { perform(action) }
        if performTalk != nil, let action = talk.update(sample) { performTalk?(action) }
        let wantFast = sample.option || machine.isActive || talk.isActive
        if timer != nil, wantFast != fast { schedule(fast: wantFast) }
    }

    private func schedule(fast: Bool) {
        self.fast = fast
        timer?.invalidate()
        let t = Timer(timeInterval: fast ? Self.activeInterval : Self.restInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = fast ? 0.004 : 0.03
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Real system reading. Permission-free.
    static func systemSample() -> ModifierSample {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let state = CGEventSourceStateID.combinedSessionState
        let since = [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            .map { CGEventSource.secondsSinceLastEventType(state, eventType: $0) }
            .min() ?? .infinity
        // Device-dependent bits (NX_DEVICELALTKEYMASK 0x20 / NX_DEVICERALTKEYMASK 0x40): which Option key is down. `NSEvent.modifierFlags` hides them
        // (verified on macOS 26); the session's combined flag state exposes them — permission-free, like the idle-time reading below.
        let raw = CGEventSource.flagsState(state).rawValue
        let left = raw & 0x20 != 0, right = raw & 0x40 != 0
        return ModifierSample(
            time: ProcessInfo.processInfo.systemUptime,
            option: flags.contains(.option),
            command: flags.contains(.command),
            other: flags.contains(.shift) || flags.contains(.control),
            secondsSinceOtherInput: since,
            rightOption: right, leftOption: left, shift: flags.contains(.shift), control: flags.contains(.control)
        )
    }
}
