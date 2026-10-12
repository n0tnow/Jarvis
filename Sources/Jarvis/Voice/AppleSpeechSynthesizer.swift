import AVFoundation
import Foundation

/// macOS system voices through `AVSpeechSynthesizer`: free, on-device, no network, no API key, no JARVIS runtime process.
/// Synthesis is per phrase (incremental sentence synthesis, NOT native streaming). The synthesizer is created on first use and released at shutdown.
@MainActor
final class AppleSpeechSynthesizerProvider: NSObject, TextToSpeechProvider, AVSpeechSynthesizerDelegate {
    let id = "apple-synthesizer"
    let displayName = "Apple Speech (system voices)"
    let capabilities = TTSCapabilities(languages: [.turkish, .english], streaming: .chunked, selectableVoices: true, costClass: .system,
                                       needsNetwork: false, runtime: "macOS speech service (in-process API)")
    private(set) var state: TTSState = .ready
    var onEvent: ((TTSPlaybackEvent) -> Void)?
    /// 1.0 normally. The live test sets 0 to exercise REAL playback timing (start/finish/stop) without making the Mac speak aloud.
    var outputVolume: Float = 1.0

    private var synthesizer: AVSpeechSynthesizer?
    private var pending: [ObjectIdentifier: Int] = [:]          // utterance → chunk id
    private var started: Set<Int> = []

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

    private func utterance(_ text: String, language: VoiceLanguage, voice: VoiceDescriptor?, rate: Double, volume: Float) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        let chosen = voice ?? VoiceSelection.resolve(language: language, chosenID: "", among: voices())
        if let chosen, let v = AVSpeechSynthesisVoice(identifier: chosen.id) { u.voice = v }
        else if let tag = language.tag { u.voice = AVSpeechSynthesisVoice(language: tag) }
        let clamped = max(0.5, min(rate, 1.6))
        u.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(clamped)))
        u.preUtteranceDelay = 0; u.postUtteranceDelay = 0; u.volume = volume
        return u
    }

    func speak(_ chunk: SpeechChunk, voice: VoiceDescriptor?, rate: Double) {
        let s: AVSpeechSynthesizer
        if let synthesizer { s = synthesizer } else { s = AVSpeechSynthesizer(); s.delegate = self; synthesizer = s }
        let u = utterance(chunk.text, language: chunk.language, voice: voice, rate: rate, volume: outputVolume)
        pending[ObjectIdentifier(u)] = chunk.id
        if state == .ready || state == .stopping { state = .synthesizing }
        s.speak(u)
    }

    func stop() {
        guard let synthesizer else { return }
        if !pending.isEmpty { state = .stopping }
        let dropped = pending
        pending.removeAll(); started.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        for (_, id) in dropped { onEvent?(.cancelled(chunkID: id)) }
        state = .ready
    }

    func shutdownNow() {
        stop()
        synthesizer?.delegate = nil
        synthesizer = nil
        onEvent = nil
    }

    // MARK: Rendering without playback

    func render(_ text: String, language: VoiceLanguage, voice: VoiceDescriptor?, rate: Double) async throws -> RenderedSpeech {
        let u = utterance(text, language: language, voice: voice, rate: rate, volume: 1.0)         // rendering is never muted
        let s = AVSpeechSynthesizer()
        let t0 = Date()
        final class Box: @unchecked Sendable { var first: Double?; var rate = 0.0; var samples: [Float] = []; var done = false }
        let box = Box()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            s.write(u) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { if !box.done { box.done = true; c.resume() }; return }
                if box.first == nil { box.first = Date().timeIntervalSince(t0) }
                box.rate = pcm.format.sampleRate
                if let ch = pcm.floatChannelData?[0] { box.samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(pcm.frameLength))) }
            }
        }
        withExtendedLifetime(s) {}
        guard !box.samples.isEmpty else { throw VoiceError.ttsUnavailable("the synthesizer produced no audio") }
        return RenderedSpeech(sampleRate: box.rate, frames: box.samples.count, firstBufferSeconds: box.first, totalSeconds: Date().timeIntervalSince(t0), samples: box.samples)
    }

    // MARK: AVSpeechSynthesizerDelegate (called on the main thread)

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        MainActor.assumeIsolated {
            guard let id = pending[key] else { return }
            state = .speaking
            started.insert(id)
            onEvent?(.started(chunkID: id))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        MainActor.assumeIsolated {
            guard let id = pending.removeValue(forKey: key) else { return }
            started.remove(id)
            if pending.isEmpty { state = .ready }
            onEvent?(.finished(chunkID: id))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        MainActor.assumeIsolated {
            guard let id = pending.removeValue(forKey: key) else { return }          // `stop()` already reported it
            started.remove(id)
            if pending.isEmpty { state = .ready }
            onEvent?(.cancelled(chunkID: id))
        }
    }
}
