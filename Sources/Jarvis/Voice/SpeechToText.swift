import Foundation

/// Words JARVIS' users say that general-purpose recognisers get wrong. A hint, never an instruction: providers that can bias
/// recognition use it (Whisper prompt, Apple contextual strings); the others ignore it. It contains product vocabulary only — no user data.
enum VoiceVocabulary {
    static let terms = ["Jarvis", "Unity", "Play Mode", "EditMode", "PlayMode", "Console", "BoxCollider", "GameObject", "prefab", "task", "compile", "test"]

    /// Contextual terms (Fix 4): names that exist on THIS Mac right now — installed applications, JARVIS' own pages, providers, the open project, the foreground app. They come
    /// from structured sources only, never from the user's speech, are bounded (≤ 40 terms of ≤ 32 plain characters) and are a hint for recognisers that support biasing.
    /// In memory only; never stored, never a command.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var contextual: [String] = []
    static let maximumContextual = 40

    static func setContextual(_ names: [String]) {
        let clean = sanitize(names)
        lock.lock(); contextual = clean; lock.unlock()
    }
    static var contextualTerms: [String] { lock.lock(); defer { lock.unlock() }; return contextual }
    static var allTerms: [String] { terms + contextualTerms }
    static var prompt: String { allTerms.joined(separator: ", ") + "." }

    /// Structured sources in priority order: the foreground app and the open project first (what the user is most likely to name next), then JARVIS' pages, providers, apps.
    static func build(foreground: String?, project: String?, destinations: [String], providers: [String], apps: [String]) -> [String] {
        sanitize([foreground, project].compactMap { $0 } + destinations + providers + apps)
    }

    /// Letters, digits, spaces and . - + only; 2…32 characters; unique (case-insensitive); not already a fixed term; bounded.
    static func sanitize(_ names: [String]) -> [String] {
        var seen = Set(terms.map { $0.lowercased() }), out: [String] = []
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " .-+"))
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (2...32).contains(name.count), name.unicodeScalars.allSatisfy({ allowed.contains($0) }), seen.insert(name.lowercased()).inserted else { continue }
            out.append(name)
            if out.count >= maximumContextual { break }
        }
        return out
    }
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
    /// Hands-free turn taking asks for a fresh provisional transcript right after the user went quiet, so the endpoint policy can tell a finished sentence from a
    /// hesitation without waiting for the next periodic preview. Recognisers that stream natively already have one: the default does nothing.
    func requestPreview()
}

extension STTSession { func requestPreview() {} }

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
