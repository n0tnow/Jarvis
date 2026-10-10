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
    }

    /// One sampling step (also called directly by tests with a scripted sampler).
    func poll() {
        let sample = sampler()
        if let action = machine.update(sample) { perform(action) }
        let wantFast = sample.option || machine.isActive
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
        return ModifierSample(
            time: ProcessInfo.processInfo.systemUptime,
            option: flags.contains(.option),
            command: flags.contains(.command),
            other: flags.contains(.shift) || flags.contains(.control),
            secondsSinceOtherInput: since
        )
    }
}
