import AVFoundation
import Foundation

/// DEVELOPER / LIVE-TEST ONLY (lives in Services/Demo: production code never depends on it).
/// Synthetic speech fixtures made with the macOS system voices, and an `AudioInput` that plays them like a microphone would.
/// SYNTHETIC AUDIO is a pipeline-regression tool — it says nothing about recognition quality for a real human voice (MANUAL TEST REQUIRED).
enum AudioFixtures {
    struct Segment { var text: String; var language: VoiceLanguage }

    /// Renders the segments with the installed system voices (in memory, nothing is written to disk) and joins them into one 16 kHz mono clip with
    /// natural lead-in/lead-out silence.
    @MainActor
    static func make(_ segments: [Segment], tts: AppleSpeechSynthesizerProvider, gap: Double = 0.12, lead: Double = 0.35, tail: Double = 0.3) async throws -> [Float] {
        var out = [Float](repeating: 0, count: Int(lead * AudioFrame.sampleRate))
        for (i, s) in segments.enumerated() {
            let r = try await tts.render(s.text, language: s.language, voice: nil, rate: 1.0)
            out += resample(r.samples, from: r.sampleRate)
            if i < segments.count - 1 { out += [Float](repeating: 0, count: Int(gap * AudioFrame.sampleRate)) }
        }
        return out + [Float](repeating: 0, count: Int(tail * AudioFrame.sampleRate))
    }

    static func resample(_ samples: [Float], from rate: Double) -> [Float] {
        guard rate != AudioFrame.sampleRate, !samples.isEmpty,
              let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioFrame.sampleRate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: src, to: dst),
              let input = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: AVAudioFrameCount(Double(samples.count) * AudioFrame.sampleRate / rate) + 256) else { return samples }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        var supplied = false
        conv.convert(to: output, error: nil) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}

/// Plays a prepared clip as if it were the microphone: 100 ms frames at 1× speed, then SILENCE until `stop()` (a held key keeps capturing).
@MainActor
final class FixtureAudioInput: AudioInput {
    private let clip: [Float]
    private let speed: Double
    private var feeder: Task<Void, Never>?
    private(set) var isCapturing = false
    private(set) var startCount = 0, stopCount = 0
    /// Seconds of the clip delivered so far.
    private(set) var deliveredSeconds = 0.0
    var clipSeconds: Double { Double(clip.count) / AudioFrame.sampleRate }

    init(clip: [Float], speed: Double = 1.0) { self.clip = clip; self.speed = max(0.1, speed) }

    func start(onFrame: @escaping @Sendable (AudioFrame) -> Void, onInterruption: @escaping @Sendable (String) -> Void) throws {
        guard !isCapturing else { throw VoiceError.microphoneUnavailable("already capturing") }
        isCapturing = true; startCount += 1; deliveredSeconds = 0
        let clip = self.clip, pace = 0.1 / speed
        feeder = Task { @MainActor [weak self] in
            var index = 0
            while !Task.isCancelled {
                let end = min(index + 1600, clip.count)
                let slice = index < clip.count ? Array(clip[index..<end]) : [Float](repeating: 0, count: 1600)
                onFrame(AudioFrame(samples: slice.count < 1600 ? slice + [Float](repeating: 0, count: 1600 - slice.count) : slice))
                index = end
                self?.deliveredSeconds = Double(index) / AudioFrame.sampleRate
                try? await Task.sleep(for: .seconds(pace))
            }
        }
    }

    func stop() { feeder?.cancel(); feeder = nil; isCapturing = false; stopCount += 1 }

    /// Waits until the whole clip has been delivered (the user has "finished speaking").
    func waitUntilDelivered() async { while deliveredSeconds < clipSeconds && isCapturing { try? await Task.sleep(for: .milliseconds(20)) } }
}

/// Word / character error rates for the STT benchmark. Normalisation keeps Turkish letters (ı İ ş ğ ü ö ç are NOT folded); case folding is
/// locale-aware (İ→i, I→ı) and punctuation is dropped.
enum SpeechMetrics {
    static func normalize(_ s: String) -> String {
        let lowered = s.lowercased(with: Locale(identifier: "tr_TR"))
        let kept = lowered.unicodeScalars.map { CharacterSet.letters.union(.decimalDigits).contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
    static func wer(reference: String, hypothesis: String) -> Double {
        let r = normalize(reference).split(separator: " ").map(String.init), h = normalize(hypothesis).split(separator: " ").map(String.init)
        return r.isEmpty ? (h.isEmpty ? 0 : 1) : Double(distance(r, h)) / Double(r.count)
    }
    static func cer(reference: String, hypothesis: String) -> Double {
        let r = Array(normalize(reference).replacingOccurrences(of: " ", with: "")), h = Array(normalize(hypothesis).replacingOccurrences(of: " ", with: ""))
        return r.isEmpty ? (h.isEmpty ? 0 : 1) : Double(distance(r, h)) / Double(r.count)
    }
    private static func distance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
            prev = cur
        }
        return prev[b.count]
    }
    /// Median of a sample (p50). Nil for an empty sample.
    static func p50(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
