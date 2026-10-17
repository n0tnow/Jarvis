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
        /// Fix 4 — envelope confirmation. JARVIS' own voice reaches the microphone with an output + room delay (up to ≈ 0.6 s with the neural player's buffering), which the
        /// short `referenceWindow` does not cover: the echo of a syllable arrives when the reference already shows the next gap and looks like "a louder-than-expected voice".
        /// Before a decision is confirmed, the microphone's speech-band envelope is compared with the REFERENCE envelope at every plausible delay; an echo follows the
        /// reference (high correlation), a person talking over it does not.
        var confirmEnvelope = true
        var echoCorrelation: Double = 0.62         // at or above this normalised correlation at some delay, the "speech" is JARVIS' own voice
        var echoLagRange: ClosedRange<TimeInterval> = 0.04 ... 0.70
        var confirmWindow: TimeInterval = 1.00     // how much of the recent past is compared (20 ms slices); long enough to contain the start of the phrase
        var couplingTolerance: Float = 10          // dB around the learned coupling within which a delayed copy of the reference counts as explaining the microphone
        var residualLimitDB: Float = 10            // even when the envelope matches, a microphone this far (90th percentile) ABOVE the delayed reference + coupling holds a second, louder voice: the user
        var slice: TimeInterval = 0.02
    }

    struct Decision: Equatable, Sendable {
        /// How long ago (seconds, relative to the deciding frame) the user's speech began — the capture pre-roll starts there.
        var onsetAgo: TimeInterval
        var excessDB: Float
        /// Highest envelope correlation with JARVIS' own output over the plausible delays (nil when there was not enough history to judge).
        var echoCorrelation: Double? = nil
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
    private var micHistory: [(t: TimeInterval, db: Float)] = []
    /// Candidates rejected because their envelope followed JARVIS' own output (diagnostics; bounded count, no audio).
    private(set) var rejectedAsEcho = 0
    private(set) var lastRejectedCorrelation: Double?

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
        micHistory.removeAll(keepingCapacity: true)
    }

    mutating func endPlayback() {
        playbackStart = nil
        reference.removeAll(keepingCapacity: true)
        micHistory.removeAll(keepingCapacity: true)
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
        micHistory.append((t, db))
        if let first = micHistory.firstIndex(where: { $0.t >= t - config.confirmWindow - 0.1 }), first > 0 { micHistory.removeFirst(first) }
        let lo = t - config.referenceWindow, hi = t - config.referenceMinDelay
        let recent = reference.filter { $0.t >= lo && $0.t <= hi }.map(\.db).max()
        let refDB = recent ?? -90
        let elapsed = t - start
        // Learn the coupling while the user is presumed silent.
        if elapsed < config.minimumPlayback { return nil }                     // the echo has not reached the microphone yet (output + room delay)
        if elapsed <= config.minimumPlayback + config.calibration, refDB > config.audibleReferenceDB, db > config.floorDB + 6 {          // a microphone at its noise floor is a DELAYED echo, not a weak coupling
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
            if run >= config.sustain, hot / run >= config.minimumDuty, let s = runStart {
                let match = config.confirmEnvelope ? echoMatch(until: t) : nil
                if let m = match, m.correlation >= config.echoCorrelation, m.residualDB < config.residualLimitDB {
                    // Not the user: the microphone follows JARVIS' own output at a plausible coupling. Learn from it (the echo is louder / later than predicted) and keep playing.
                    rejectedAsEcho += 1; lastRejectedCorrelation = m.correlation
                    coupling = min(config.couplingRange.upperBound, max(coupling, m.gainDB))
                    run = 0; hot = 0; gap = 0; runStart = nil
                    return nil
                }
                return Decision(onsetAgo: t - s, excessDB: excess, echoCorrelation: match?.correlation)
            }
        } else if runStart != nil {
            gap += duration
            if gap > config.gapTolerance { run = 0; hot = 0; gap = 0; runStart = nil }
        } else if excess < 3, refDB > config.audibleReferenceDB, db > config.floorDB + 6 {
            // slow tracking of a drifting coupling (volume change) while nothing unusual is happening
            coupling = min(config.couplingRange.upperBound, max(config.couplingRange.lowerBound, 0.98 * coupling + 0.02 * (db - refDB)))
        }
        return nil
    }
}

extension BargeInDetector {
    /// Highest Pearson correlation between the microphone's recent speech-band level series and JARVIS' own reference level series, over the plausible output delays.
    /// Both series are sampled on a 20 ms grid ending at `end`; levels are floored so silence does not dominate. nil: not enough history to judge (never a rejection).
    struct EchoMatch: Equatable, Sendable {
        var correlation: Double
        /// 90th percentile of (microphone − delayed reference) minus the learned coupling, in dB: ≈ 0 for pure echo, large when a second voice rides on it.
        var residualDB: Float
        /// Median level of the microphone relative to the delayed reference (the echo path's gain).
        var gainDB: Float
    }

    private var anyCoupling: ClosedRange<Float> { (config.couplingRange.lowerBound - 12) ... (config.couplingRange.upperBound + 8) }

    func echoMatch(until end: TimeInterval) -> EchoMatch? {
        let n = Int(config.confirmWindow / config.slice + 0.5)
        guard n >= 12, micHistory.count >= n / 2, reference.count >= 4 else { return nil }
        func value(of series: [(t: TimeInterval, db: Float)], at t: TimeInterval) -> Float? {
            // the loudest sample within ± one slice of `t` (series are sparse or denser than the grid; max is robust to both)
            var best: Float?
            for e in series where abs(e.t - t) <= config.slice * 1.01 { best = max(best ?? -120, e.db) }
            return best
        }
        let floorDB: Float = -80
        var mic: [Float] = []
        for i in 0..<n {
            let t = end - Double(n - 1 - i) * config.slice
            mic.append(max(floorDB, value(of: micHistory, at: t) ?? floorDB))
        }
        let micStd = Self.std(mic)
        let micFlat = micStd <= 1.0
        // The level the echo must have relative to the reference: the learned speaker-to-microphone coupling, with some tolerance for the band filter and the room.
        // A person talking over the answer is 12–30 dB hotter than the echo, so a candidate far above the coupling is never explained away.
        let plausible = (coupling - config.couplingTolerance) ... (coupling + config.couplingTolerance)
        var best: EchoMatch?
        var lag = config.echoLagRange.lowerBound
        while lag <= config.echoLagRange.upperBound + 1e-9 {
            var ref: [Float] = []
            var present = 0
            for i in 0..<n {
                let t = end - Double(n - 1 - i) * config.slice - lag
                if let v = value(of: reference, at: t) { ref.append(max(floorDB, v)); present += 1 } else { ref.append(floorDB) }
            }
            lag += config.slice
            guard present >= n / 2 else { continue }
            // The gain of the echo path at this delay: the MEDIAN of (microphone − reference) where JARVIS is audible (robust to a few misaligned slices and to a second voice
            // that covers less than half of the window).
            var diffs: [Float] = []
            for i in 0..<n where ref[i] > config.audibleReferenceDB { diffs.append(mic[i] - ref[i]) }
            guard diffs.count >= n / 4 else { continue }
            diffs.sort()
            let gain = diffs[diffs.count / 2]
            // how far the loudest tenth of the audible samples sits above "this delayed reference + the coupling learned for this playback" (a second voice makes this large)
            let p90 = diffs[min(diffs.count - 1, Int(Float(diffs.count) * 0.9))] - coupling
            if micFlat {
                // A sustained, steady microphone level has no shape to correlate. It is JARVIS' own voice when, at this delay, the reference is audible for (nearly) the whole
                // window and the gain is what the speaker-to-microphone coupling LEARNED at the start of this playback predicts: a person's voice is never this steady.
                guard plausible.contains(gain), diffs.count >= n * 8 / 10 else { continue }
                if best == nil || best!.correlation < 0.99 { best = EchoMatch(correlation: 0.99, residualDB: p90, gainDB: gain) }
            } else {
                // Shape follows shape: the microphone envelope tracks the delayed reference at a gain that any speaker/room/microphone could have (never a voice far hotter than the
                // output could ever couple).
                guard gain >= anyCoupling.lowerBound, gain <= anyCoupling.upperBound, Self.std(ref) > 1.0, let c = Self.pearson(mic, ref) else { continue }
                if best == nil || c > best!.correlation { best = EchoMatch(correlation: c, residualDB: p90, gainDB: gain) }
            }
        }
        return best
    }

    static func std(_ x: [Float]) -> Float {
        guard x.count > 1 else { return 0 }
        let m = x.reduce(0, +) / Float(x.count)
        return (x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Float(x.count)).squareRoot()
    }

    static func pearson(_ a: [Float], _ b: [Float]) -> Double? {
        guard a.count == b.count, a.count > 1 else { return nil }
        let ma = a.reduce(0, +) / Float(a.count), mb = b.reduce(0, +) / Float(b.count)
        var num: Float = 0, da: Float = 0, db: Float = 0
        for i in 0..<a.count { let x = a[i] - ma, y = b[i] - mb; num += x * y; da += x * x; db += y * y }
        guard da > 1e-6, db > 1e-6 else { return nil }
        return Double(num / (da * db).squareRoot())
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
