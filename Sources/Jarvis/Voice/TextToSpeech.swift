import Foundation

/// A speech synthesiser behind a clean boundary. It speaks complete, already-rendered phrases (`SpeechChunk`) in order and can stop at once.
/// `speak` only enqueues; events report what really happened (started = audio began, finished = audio ended, cancelled = dropped by `stop`).
@MainActor
protocol TextToSpeechProvider: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var capabilities: TTSCapabilities { get }
    var state: TTSState { get }
    func availability() -> TTSAvailability
    /// Installed voices that are really there (never a hard-coded list).
    func voices() -> [VoiceDescriptor]
    var onEvent: ((TTSPlaybackEvent) -> Void)? { get set }
    func speak(_ chunk: SpeechChunk, voice: VoiceDescriptor?, rate: Double)
    /// Immediately silences playback and drops everything queued or in flight. Idempotent.
    func stop()
    /// Synthesises WITHOUT playing (tests, benchmarks, output-boundary validation).
    func render(_ text: String, language: VoiceLanguage, voice: VoiceDescriptor?, rate: Double) async throws -> RenderedSpeech
    func shutdownNow()
}

/// Picks the voice that will actually be used: the user's choice when it is installed, otherwise the best installed voice for the language.
enum VoiceSelection {
    static func resolve(language: VoiceLanguage, chosenID: String, among voices: [VoiceDescriptor]) -> VoiceDescriptor? {
        let candidates = voices.filter { $0.voiceLanguage == language }
        if !chosenID.isEmpty, let chosen = voices.first(where: { $0.id == chosenID }) { return chosen }
        return candidates.sorted { ($0.quality, $0.language == (language == .english ? "en-US" : "tr-TR") ? 1 : 0) > ($1.quality, $1.language == (language == .english ? "en-US" : "tr-TR") ? 1 : 0) }.first
    }
}
