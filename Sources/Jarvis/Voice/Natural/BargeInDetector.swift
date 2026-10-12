import Foundation

/// Self-speech suppression + barge-in decision (V0.8). Pure: every input carries its own timestamp, nothing here reads a clock or touches audio hardware.
///
/// While JARVIS speaks, its own voice reaches the microphone. We know exactly what we play (`SpeechPlayer` reports a level for every output slice), so the
/// detector predicts the echo level — "recent reference level + coupling" — and only a microphone level that clearly EXCEEDS that prediction, while the
/// local VAD says "speech", for a sustained time, counts as the user. No acoustic echo canceller is involved (measured alternative: Voice Processing I/O,
/// see docs/NATURAL_VOICE.md §Echo).
///
///  • coupling (mic dB − reference dB) is learned during the first moments of each playback, when the user is assumed silent, and clamped to a sane range;
///  • the prediction takes the LOUDEST reference level of the last `referenceWindow` seconds, so output/input latency and room delay need no alignment;
///  • a keyboard click or a chair is short (never sustained) and has no VAD speech; a long constant fan is below the predicted echo or not speech;
///  • the user's own speech louder than the echo by `margin` dB for `sustain` seconds fires; a quiet whisper below the echo cannot (documented limit).
struct BargeInDetector: Sendable {
    struct Config: Equatable, Sendable {
        var margin: Float = 8                      // dB above the predicted echo
        var sustain: TimeInterval = 0.30           // seconds of excess + VAD speech
        var gapTolerance: TimeInterval = 0.06      // a short dip inside speech does not reset the run
        var minimumDuty: Double = 0.65             // share of the run that must be "hot": speech is mostly voiced, a train of clicks or a fan's gusts is not
        var calibration: TimeInterval = 0.8        // seconds at the start of a playback used to learn the coupling
        var priorCoupling: Float = -24             // dB, conservative start (measured on this Mac: −26 … −30)
        var calibrationHeadroom: Float = 8         // dB the learned coupling may exceed the prior by (a louder speaker is learned; a loud user is not)
        var couplingRange: ClosedRange<Float> = -34 ... -10        // never learn a coupling weaker than −34 dB: a quiet start (the echo has not arrived yet) must not make JARVIS' own voice look loud
        var floorDB: Float = -62                   // never predict an echo quieter than this
        var referenceWindow: TimeInterval = 0.30
        var referenceMinDelay: TimeInterval = 0.04
        var audibleReferenceDB: Float = -55
        var minimumPlayback: TimeInterval = 0.25   // nothing fires in the very first instants of a playback
    }

    struct Decision: Equatable, Sendable {
        /// How long ago (seconds, relative to the deciding frame) the user's speech began — the capture pre-roll starts there.
        var onsetAgo: TimeInterval
        var excessDB: Float
    }

    var config: Config
    private(set) var coupling: Float
    private(set) var playbackStart: TimeInterval?
    private var reference: [(t: TimeInterval, db: Float)] = []
    private var vadSpeech = false
    private var run: TimeInterval = 0              // length of the current candidate run
    private var hot: TimeInterval = 0              // hot time inside it
    private var gap: TimeInterval = 0
    private var runStart: TimeInterval?
    private var calibrated = false

    init(config: Config = Config()) {
        self.config = config
        coupling = config.priorCoupling
    }

    var isPlaying: Bool { playbackStart != nil }

    /// Output began at `t`. Resets the run and starts a calibration window (the learned coupling is kept as the new prior, clamped).
    mutating func beginPlayback(at t: TimeInterval) {
        playbackStart = t
        reference.removeAll(keepingCapacity: true)
        run = 0; hot = 0; gap = 0; runStart = nil; calibrated = false
    }

    mutating func endPlayback() {
        playbackStart = nil
        reference.removeAll(keepingCapacity: true)
        run = 0; hot = 0; gap = 0; runStart = nil
    }

    /// The level (dB FS, RMS) of the audio being played during the slice that started at `t`.
    mutating func pushReference(db: Float, at t: TimeInterval) {
        reference.append((t, db))
        let cutoff = t - 2.0
        if let first = reference.firstIndex(where: { $0.t >= cutoff }), first > 0 { reference.removeFirst(first) }
    }

    /// Latest VAD verdict (from the local VAD helper). Sticky until the next verdict.
    mutating func pushVAD(isSpeech: Bool) { vadSpeech = isSpeech }

    /// One microphone slice of `duration` seconds that ENDS at `t`. Returns a decision when the user has clearly started to speak.
    mutating func pushMic(db: Float, duration: TimeInterval, at t: TimeInterval) -> Decision? {
        guard let start = playbackStart else { return nil }
        let lo = t - config.referenceWindow, hi = t - config.referenceMinDelay
        let recent = reference.filter { $0.t >= lo && $0.t <= hi }.map(\.db).max()
        let refDB = recent ?? -90
        let elapsed = t - start
        // Learn the coupling while the user is presumed silent.
        if elapsed < config.minimumPlayback { return nil }                     // the echo has not reached the microphone yet (output + room delay)
        if elapsed <= config.minimumPlayback + config.calibration, refDB > config.audibleReferenceDB {
            // A user who interrupts straight away must not corrupt the estimate: what is learned can exceed the conservative prior by `calibrationHeadroom` at most.
            let observed = min(db - refDB, config.priorCoupling + config.calibrationHeadroom)
            coupling = min(config.couplingRange.upperBound, max(config.couplingRange.lowerBound, 0.8 * coupling + 0.2 * observed))
            calibrated = true
            return nil
        }
        let expected = max(refDB + coupling, config.floorDB)
        let excess = db - expected
        let isHot = excess > config.margin && vadSpeech
        if isHot {
            if runStart == nil { runStart = t - duration }
            run += duration + gap; hot += duration
            gap = 0
            if run >= config.sustain, hot / run >= config.minimumDuty, let s = runStart { return Decision(onsetAgo: t - s, excessDB: excess) }
        } else if runStart != nil {
            gap += duration
            if gap > config.gapTolerance { run = 0; hot = 0; gap = 0; runStart = nil }
        } else if excess < 3, refDB > config.audibleReferenceDB {
            // slow tracking of a drifting coupling (volume change) while nothing unusual is happening
            coupling = min(config.couplingRange.upperBound, max(config.couplingRange.lowerBound, 0.98 * coupling + 0.02 * (db - refDB)))
        }
        return nil
    }
}

/// Second-order (12 dB/octave) high-pass at 250 Hz for the barge-in level only. A door thud or a table knock is mostly below it, a human voice is mostly above it;
/// JARVIS' own echo goes through the same filter, so the learned coupling stays consistent. Stateful across frames; touches nothing but the level measurement.
struct SpeechBandFilter: Sendable {
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
    private let b0: Float, b1: Float, b2: Float, a1: Float, a2: Float

    init(cutoff: Double = 250, sampleRate: Double = AudioFrame.sampleRate) {
        let w = 2 * Double.pi * cutoff / sampleRate, q = 0.7071
        let alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha
        b0 = Float((1 + c) / 2 / a0); b1 = Float(-(1 + c) / a0); b2 = Float((1 + c) / 2 / a0)
        a1 = Float(-2 * c / a0); a2 = Float((1 - alpha) / a0)
    }

    mutating func process(_ input: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: input.count)
        for (i, x) in input.enumerated() {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            out[i] = y
        }
        return out
    }
}

/// RMS level in dB FS of a block of samples (floored at −120).
enum AudioLevel {
    static func db(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -120 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        return max(-120, 20 * log10(max(rms, 1e-9)))
    }
}
