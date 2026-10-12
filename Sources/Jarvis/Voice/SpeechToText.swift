import Foundation

/// Words JARVIS' users say that general-purpose recognisers get wrong. A hint, never an instruction: providers that can bias
/// recognition use it (Whisper prompt, Apple contextual strings); the others ignore it. It contains product vocabulary only — no user data.
enum VoiceVocabulary {
    static let terms = ["Jarvis", "Unity", "Play Mode", "EditMode", "PlayMode", "Console", "BoxCollider", "GameObject", "prefab", "task", "compile", "test"]
    static var prompt: String { terms.joined(separator: ", ") + "." }
}

/// One push-to-talk utterance as seen by a recogniser. Created at the press, ended by `finish()` (release) or `cancel()`.
@MainActor
protocol STTSession: AnyObject {
    /// Provisional and final transcripts in order. Partials may change; ends when the session ends.
    var events: AsyncStream<SpeechTranscriptEvent> { get }
    /// Feeds one frame (called in capture order, on the main actor).
    func append(_ frame: AudioFrame)
    /// No more audio (Push-to-Talk was released): finalises and returns the FINAL transcript, or nil when nothing was recognised.
    func finish() async throws -> SpeechTranscriptEvent?
    /// Abandons the utterance at once; nothing further is produced.
    func cancel()
}

/// A speech recogniser behind a clean boundary. Providers report truthful availability, never download anything on their own,
/// and clean up everything they own on `shutdownNow()`.
@MainActor
protocol SpeechToTextProvider: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var capabilities: STTCapabilities { get }
    var state: STTState { get }
    func availability(for language: VoiceLanguage) async -> STTAvailability
    func makeSession(language: VoiceLanguage) async throws -> STTSession
    /// Releases warm resources (idle timer, memory pressure). The provider starts them again on demand.
    func unload() async
    /// Synchronous cleanup for application termination.
    func shutdownNow()
}

/// Text coming out of a recogniser is untrusted helper output and user speech at the same time: collapse whitespace and pass it through
/// the central sanitizer before it reaches any UI state, log or conversation.
enum TranscriptText {
    static func clean(_ raw: String) -> String {
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return OutputSanitizer.sanitize(collapsed)
    }
}
