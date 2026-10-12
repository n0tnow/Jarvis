import Foundation

/// ONE microphone engine for every consumer (V0.8). Wake listening, hands-free utterances and Push-to-Talk all subscribe here, so there is never a second
/// capture engine and PTT cannot fight the wake detector for the device. The engine exists only while at least one subscriber exists: wake mode OFF and
/// no key held ⇒ no engine, no microphone (exactly as in V0.7). Frames are fanned out in memory; nothing is recorded anywhere.
@MainActor
final class MicrophoneHub {
    private final class Fanout: @unchecked Sendable {
        private let lock = NSLock()
        private var handlers: [UUID: @Sendable (AudioFrame) -> Void] = [:]
        private var interruptions: [UUID: @Sendable (String) -> Void] = [:]
        func add(_ id: UUID, frame: @escaping @Sendable (AudioFrame) -> Void, interruption: @escaping @Sendable (String) -> Void) {
            lock.lock(); handlers[id] = frame; interruptions[id] = interruption; lock.unlock()
        }
        func remove(_ id: UUID) { lock.lock(); handlers[id] = nil; interruptions[id] = nil; lock.unlock() }
        var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return handlers.isEmpty }
        var count: Int { lock.lock(); defer { lock.unlock() }; return handlers.count }
        func deliver(_ frame: AudioFrame) {
            lock.lock(); let all = Array(handlers.values); lock.unlock()
            for h in all { h(frame) }
        }
        func interrupt(_ why: String) -> [@Sendable (String) -> Void] {
            lock.lock(); let all = Array(interruptions.values); handlers = [:]; interruptions = [:]; lock.unlock()
            return all
        }
    }

    private let makeSource: @MainActor () -> any AudioInput
    private var source: (any AudioInput)?
    private let fanout = Fanout()
    private var labels: [UUID: String] = [:]
    private(set) var startCount = 0

    init(makeSource: @escaping @MainActor () -> any AudioInput = { MicrophoneInput() }) { self.makeSource = makeSource }

    var isCapturing: Bool { source?.isCapturing ?? false }
    var subscriberLabels: [String] { labels.values.sorted() }
    var subscriberCount: Int { labels.count }

    /// Starts the engine if this is the first subscriber. Throws (and registers nothing) when the device cannot start.
    func subscribe(_ label: String, onFrame: @escaping @Sendable (AudioFrame) -> Void, onInterruption: @escaping @Sendable (String) -> Void) throws -> UUID {
        let id = UUID()
        if source == nil {
            let src = makeSource()
            let fan = fanout
            try src.start(onFrame: { fan.deliver($0) },
                          onInterruption: { [weak self] why in Task { @MainActor in self?.sourceInterrupted(why) } })
            source = src
            startCount += 1
        }
        fanout.add(id, frame: onFrame, interruption: onInterruption)
        labels[id] = label
        return id
    }

    func unsubscribe(_ id: UUID) {
        guard labels[id] != nil else { return }
        fanout.remove(id)
        labels[id] = nil
        if labels.isEmpty { stopSource() }
    }

    /// Application quit / wake mode disabled with nobody else listening: everything stops.
    func shutdown() {
        _ = fanout.interrupt("shutdown")
        labels.removeAll()
        stopSource()
    }

    private func stopSource() {
        source?.stop()
        source = nil
    }

    private func sourceInterrupted(_ why: String) {
        let reports = fanout.interrupt(why)
        labels.removeAll()
        stopSource()
        for r in reports { r(why) }
    }
}

/// PTT's view of the shared microphone: the V0.7 `AudioInput` contract on top of the hub.
@MainActor
final class HubAudioInput: AudioInput {
    private let hub: MicrophoneHub
    private let label: String
    private var subscription: UUID?
    init(hub: MicrophoneHub, label: String = "push-to-talk") { self.hub = hub; self.label = label }
    var isCapturing: Bool { subscription != nil && hub.isCapturing }
    func start(onFrame: @escaping @Sendable (AudioFrame) -> Void, onInterruption: @escaping @Sendable (String) -> Void) throws {
        guard subscription == nil else { throw VoiceError.microphoneUnavailable("a capture is already running") }
        subscription = try hub.subscribe(label, onFrame: onFrame, onInterruption: onInterruption)
    }
    func stop() {
        if let subscription { hub.unsubscribe(subscription) }
        subscription = nil
    }
}

/// A bounded, memory-only window of the most recent audio (wake pre-roll, utterance pre-roll). It is overwritten continuously and never persisted.
struct AudioRing: Sendable {
    let maxSeconds: Double
    private var frames: [AudioFrame] = []
    private(set) var seconds: Double = 0

    init(maxSeconds: Double) { self.maxSeconds = maxSeconds }

    mutating func append(_ frame: AudioFrame) {
        frames.append(frame)
        seconds += frame.seconds
        while seconds > maxSeconds, frames.count > 1 {
            seconds -= frames.removeFirst().seconds
        }
    }

    /// The most recent `duration` seconds (whole frames, so possibly slightly more).
    func tail(seconds duration: Double) -> [AudioFrame] {
        var out: [AudioFrame] = []
        var total = 0.0
        for f in frames.reversed() {
            out.append(f); total += f.seconds
            if total >= duration { break }
        }
        return out.reversed()
    }

    mutating func clear() { frames.removeAll(keepingCapacity: true); seconds = 0 }
    var frameCount: Int { frames.count }
}

/// Decides whether the audio is worth sending to the local sentinel at all. In a quiet room the sentinel receives NOTHING (and costs nothing); when
/// the level rises above the room's noise floor it gets the pre-roll first, then the live stream until the room is quiet again.
/// Pure: the floor is the 15th percentile of the last ~40 s of 100 ms levels; the gate opens 10 dB above it (and never below an absolute minimum).
struct EnergyGate: Sendable {
    var margin: Float = 10
    var absoluteMinimumDB: Float = -58
    var hangover: TimeInterval = 1.5
    var historySeconds: TimeInterval = 40
    private var levels: [Float] = []
    private var lastLoud: TimeInterval = -.infinity
    private(set) var isOpen = false
    private(set) var floorDB: Float = -70

    /// Feed a slice of `duration` seconds at level `db` ending at `t`; returns whether audio should flow now.
    mutating func push(db: Float, duration: TimeInterval, at t: TimeInterval) -> Bool {
        levels.append(db)
        let cap = Int(historySeconds / max(duration, 0.01))
        if levels.count > cap { levels.removeFirst(levels.count - cap) }
        if levels.count >= 20 {
            let sorted = levels.sorted()
            floorDB = sorted[Int(Float(sorted.count) * 0.15)]
        }
        let threshold = max(absoluteMinimumDB, floorDB + margin)
        if db > threshold { lastLoud = t }
        isOpen = t - lastLoud <= hangover
        return isOpen
    }

    mutating func reset() { levels.removeAll(); lastLoud = -.infinity; isOpen = false; floorDB = -70 }
}
