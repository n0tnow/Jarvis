import AVFoundation
import Foundation

/// macOS system voices through `AVSpeechSynthesizer.write`: free, on-device, no network, no API key. The synthesiser only PRODUCES audio; JARVIS' own
/// `SpeechPlayer` plays it (so the output is known and self-speech can be suppressed). Synthesis is per phrase — incremental sentence synthesis, NOT native
/// streaming. The audio of a phrase arrives as the system produces it (first buffer ≈ 140–170 ms measured).
@MainActor
final class AppleSpeechEngine: PCMSynthesizing {
    private var active: [Int: AVSpeechSynthesizer] = [:]

    func availability() -> TTSAvailability {
        voices().isEmpty ? .unavailable("no Turkish or English system voice is installed") : .ready
    }

    /// Installed Turkish / English voices, premium first. The legacy "novelty" voices (Bells, Zarvox …) are not offered.
    func voices() -> [VoiceDescriptor] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.identifier.hasPrefix("com.apple.speech.synthesis.voice.") && ($0.language.hasPrefix("tr") || $0.language.hasPrefix("en")) }
            .map { VoiceDescriptor(id: $0.identifier, name: $0.name, language: $0.language, quality: $0.quality == .premium ? 3 : $0.quality == .enhanced ? 2 : 1) }
            .sorted { ($0.quality, $1.name) > ($1.quality, $0.name) }
    }

    private func utterance(_ text: String, language: VoiceLanguage, voice: VoiceDescriptor?, rate: Double) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        let chosen = voice ?? VoiceSelection.resolve(language: language, chosenID: "", among: voices())
        if let chosen, let v = AVSpeechSynthesisVoice(identifier: chosen.id) { u.voice = v }
        else if let tag = language.tag { u.voice = AVSpeechSynthesisVoice(language: tag) }
        let clamped = max(0.5, min(rate, 1.6))
        u.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(clamped)))
        u.preUtteranceDelay = 0; u.postUtteranceDelay = 0; u.volume = 1.0            // volume is applied by the player, never by muting synthesis
        return u
    }

    func synthesize(_ chunk: SpeechChunk, voice: VoiceDescriptor?, rate: Double) -> AsyncThrowingStream<PCMBlock, Error> {
        let u = utterance(chunk.text, language: chunk.language, voice: voice, rate: rate)
        let id = chunk.id
        return AsyncThrowingStream { continuation in
            let synthesizer = AVSpeechSynthesizer()
            active[id] = synthesizer
            final class Flag: @unchecked Sendable { var done = false }
            let flag = Flag()
            synthesizer.write(u) { buffer in
                guard !flag.done, let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { flag.done = true; continuation.finish(); return }
                let n = Int(pcm.frameLength)
                var samples = [Float](repeating: 0, count: n)
                if let ch = pcm.floatChannelData { samples = Array(UnsafeBufferPointer(start: ch[0], count: n)) }
                else if let ch = pcm.int16ChannelData { for i in 0..<n { samples[i] = Float(ch[0][i]) / 32768.0 } }
                else { return }
                continuation.yield(PCMBlock(samples: samples, sampleRate: pcm.format.sampleRate))
            }
            final class Box: @unchecked Sendable { let s: AVSpeechSynthesizer; init(_ s: AVSpeechSynthesizer) { self.s = s } }
            let box = Box(synthesizer)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    box.s.stopSpeaking(at: .immediate)
                    self?.active[id] = nil
                }
            }
        }
    }

    func cancelAll() {
        let all = active; active = [:]
        for (_, s) in all { s.stopSpeaking(at: .immediate) }
    }

    func shutdownNow() { cancelAll() }
}

/// The default JARVIS speech provider: Apple system voices behind the player. (V0.7's `speak`-based playback is replaced by `write` + `SpeechPlayer` so that
/// JARVIS knows exactly what it plays — the basis of barge-in without an echo canceller.)
@MainActor
final class AppleSpeechSynthesizerProvider: PlayerBackedTTSProvider {
    /// 1.0 normally; the live test sets 0 to exercise the REAL playback path (start/finish/stop timing, reference levels) without making the Mac speak aloud.
    var outputVolume: Float = 1.0 { didSet { (player as? SpeechPlayer)?.volume = outputVolume } }

    init(player: (any PCMPlayback)? = nil) {
        super.init(id: "apple-synthesizer", displayName: "Apple Speech (system voices)",
                   capabilities: TTSCapabilities(languages: [.turkish, .english], streaming: .chunked, selectableVoices: true, costClass: .system,
                                                 needsNetwork: false, runtime: "macOS speech service (in-process API) + JARVIS audio player"),
                   engine: AppleSpeechEngine(), player: player ?? SpeechPlayer())
    }
}
