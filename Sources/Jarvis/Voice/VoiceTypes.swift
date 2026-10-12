import Foundation

// MARK: - Language

/// What the user wants recognised. `auto` is only honest when the provider really detects the language
/// (`STTCapabilities.autoDetectsLanguage`); otherwise it resolves to the user's primary system language and the UI says so.
enum VoiceLanguage: String, CaseIterable, Codable, Sendable {
    case auto, turkish = "tr", english = "en"

    var label: String { switch self { case .auto: "Auto"; case .turkish: "Turkish"; case .english: "English" } }
    /// BCP-47 tag for a concrete language (nil for `auto`).
    var tag: String? { switch self { case .auto: nil; case .turkish: "tr-TR"; case .english: "en-US" } }
    var replyLanguage: ReplyLanguage? { switch self { case .auto: nil; case .turkish: .tr; case .english: .en } }

    init(reply: ReplyLanguage) { self = reply == .tr ? .turkish : .english }

    /// The user's primary system language, restricted to what V0.7 supports (Turkish or English).
    static var systemDefault: VoiceLanguage {
        (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("tr") ? .turkish : .english
    }
}

// MARK: - Cost

/// What using a voice provider costs. UNKNOWN is never selected automatically (V0.3.1 rule, unchanged).
enum VoiceCostClass: String, Codable, Sendable {
    case local          // runs on this Mac in JARVIS' own runtime (model files on disk), no network
    case system         // built into macOS (on-device), no network, no JARVIS runtime
    case subscription   // only if an official subscription mechanism exists (none is used by V0.7)
    case freeCloud
    case paid
    case unknown

    var label: String { rawValue.uppercased() }
    var mayIncurCost: Bool { self == .paid || self == .unknown }
    var autoSelectable: Bool { !mayIncurCost }
}

// MARK: - Truthful provider states

enum STTState: Equatable, Sendable {
    case unavailable(String), ready, starting, listening, transcribing, finalizing, error(String)
    var label: String {
        switch self {
        case .unavailable: "UNAVAILABLE"; case .ready: "READY"; case .starting: "STARTING"; case .listening: "LISTENING"
        case .transcribing: "TRANSCRIBING"; case .finalizing: "FINALIZING"; case .error: "ERROR"
        }
    }
}

enum TTSState: Equatable, Sendable {
    case unavailable(String), ready, starting, synthesizing, speaking, stopping, error(String)
    var label: String {
        switch self {
        case .unavailable: "UNAVAILABLE"; case .ready: "READY"; case .starting: "STARTING"; case .synthesizing: "SYNTHESIZING"
        case .speaking: "SPEAKING"; case .stopping: "STOPPING"; case .error: "ERROR"
        }
    }
}

/// The session as the user sees it. `listening` only while microphone capture is really running; `speaking` only once audio has started.
enum VoiceSessionState: Equatable, Sendable {
    case idle, requestingPermission, listening, transcribing, thinking, speaking, error(String)
    var label: String {
        switch self {
        case .idle: "IDLE"; case .requestingPermission: "REQUESTING PERMISSION"; case .listening: "LISTENING"
        case .transcribing: "TRANSCRIBING"; case .thinking: "THINKING"; case .speaking: "SPEAKING"; case .error: "ERROR"
        }
    }
    var isBusy: Bool { self != .idle && !isError }
    var isError: Bool { if case .error = self { true } else { false } }
}

enum MicrophonePermission: String, Equatable, Sendable {
    case notDetermined, granted, denied, restricted
    var label: String {
        switch self {
        case .notDetermined: "NOT ASKED YET"; case .granted: "ALLOWED"; case .denied: "DENIED"; case .restricted: "RESTRICTED"
        }
    }
    var allowsCapture: Bool { self == .granted }
}

// MARK: - Audio

/// One bounded slice of captured audio in the single format every STT provider receives: mono, 16 kHz, Float32.
/// Raw audio exists only in memory for the duration of one push-to-talk session; nothing here is ever persisted.
struct AudioFrame: Sendable {
    static let sampleRate: Double = 16_000
    var samples: [Float]
    var seconds: Double { Double(samples.count) / Self.sampleRate }
}

// MARK: - Transcripts

/// A partial transcript is provisional (it may change and is never a message); only `isFinal` enters the conversation.
/// `confidence` is nil unless the provider really exposes one — it is never invented.
struct SpeechTranscriptEvent: Equatable, Sendable {
    var text: String
    var isFinal: Bool
    var language: String?
    var confidence: Double?
    var timestamp: Date = .now
}

// MARK: - Provider capabilities

enum PartialMode: String, Sendable, Equatable {
    case none
    case nativeStreaming        // the recogniser itself emits revisable hypotheses while audio arrives
    case incrementalRedecode    // JARVIS periodically re-decodes the audio so far (a preview, not native streaming)
    var label: String {
        switch self { case .none: "none"; case .nativeStreaming: "native streaming"; case .incrementalRedecode: "preview by re-decoding" }
    }
}

struct STTCapabilities: Equatable, Sendable {
    var languages: [VoiceLanguage]            // concrete languages only (tr / en)
    var partials: PartialMode
    var autoDetectsLanguage: Bool
    var exposesConfidence: Bool
    var costClass: VoiceCostClass
    var needsNetwork: Bool
    /// Where the work happens, for the diagnostics line (e.g. "macOS speech service" / "JARVIS helper process").
    var runtime: String
}

enum STTAvailability: Equatable, Sendable {
    case ready
    /// Usable after an explicit, user-triggered setup step (model/asset download). Nothing is downloaded silently.
    case needsSetup(String)
    case unavailable(String)
    var isReady: Bool { self == .ready }
    var detail: String? {
        switch self { case .ready: nil; case .needsSetup(let s), .unavailable(let s): s }
    }
}

enum TTSStreaming: String, Sendable, Equatable {
    case nativeStreaming        // audio is produced while text is still arriving
    case chunked                // JARVIS synthesises complete sentences/phrases one after another
    var label: String { self == .nativeStreaming ? "native streaming" : "incremental sentence synthesis" }
}

struct TTSCapabilities: Equatable, Sendable {
    var languages: [VoiceLanguage]
    var streaming: TTSStreaming
    var selectableVoices: Bool
    var costClass: VoiceCostClass
    var needsNetwork: Bool
    var runtime: String
}

enum TTSAvailability: Equatable, Sendable {
    case ready, unavailable(String)
    var isReady: Bool { self == .ready }
}

struct VoiceDescriptor: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var language: String        // BCP-47, e.g. "tr-TR"
    var quality: Int            // 1 default · 2 enhanced · 3 premium
    var voiceLanguage: VoiceLanguage? {
        let l = language.lowercased()
        return l.hasPrefix("tr") ? .turkish : l.hasPrefix("en") ? .english : nil
    }
    var qualityLabel: String { quality >= 3 ? "premium" : quality == 2 ? "enhanced" : "standard" }
}

// MARK: - Speech output

/// One unit handed to a TTS provider: a complete, already-rendered phrase in a single language.
struct SpeechChunk: Equatable, Sendable {
    var id: Int
    var text: String
    var language: VoiceLanguage     // concrete (never `auto`)
}

enum TTSPlaybackEvent: Equatable, Sendable {
    case started(chunkID: Int)
    case finished(chunkID: Int)
    case cancelled(chunkID: Int)
    case failed(chunkID: Int?, String)
}

/// PCM produced WITHOUT playing it (tests, benchmarks, and validation at the output boundary).
struct RenderedSpeech: Sendable {
    var sampleRate: Double
    var frames: Int
    var firstBufferSeconds: Double?
    var totalSeconds: Double
    var samples: [Float]            // mono, kept only for the lifetime of the test
    var duration: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }
}

// MARK: - Errors

enum VoiceError: Error, Equatable, Sendable {
    case voiceDisabled
    case microphoneDenied(MicrophonePermission)
    case microphoneUnavailable(String)
    case sttUnavailable(String)
    case sttFailed(String)
    case noSpeech
    case tooShort
    case ttsUnavailable(String)
    case cancelled

    func message(_ l: ReplyLanguage = .en) -> String {
        switch self {
        case .voiceDisabled: return l == .tr ? "Ses kapalı. Ayarlar → Voice bölümünden açabilirsiniz." : "Voice is turned off. You can enable it in Settings → Voice."
        case .microphoneDenied(let p):
            return p == .restricted
                ? (l == .tr ? "Mikrofon erişimi bu Mac'te kısıtlanmış. Yazarak devam edebilirsiniz." : "Microphone access is restricted on this Mac. You can keep typing.")
                : (l == .tr ? "Mikrofon izni verilmedi. Sistem Ayarları → Gizlilik ve Güvenlik → Mikrofon bölümünden izin verebilirsiniz; yazarak devam edebilirsiniz."
                            : "Microphone access was not allowed. You can allow it in System Settings → Privacy & Security → Microphone; typing still works.")
        case .microphoneUnavailable(let s): return (l == .tr ? "Mikrofon kullanılamıyor: " : "The microphone is unavailable: ") + s
        case .sttUnavailable(let s): return (l == .tr ? "Konuşma tanıma kullanılamıyor: " : "Speech recognition is unavailable: ") + s
        case .sttFailed(let s): return (l == .tr ? "Konuşma tanıma başarısız oldu: " : "Speech recognition failed: ") + s
        case .noSpeech: return l == .tr ? "Konuşma duyulmadı." : "I didn't hear anything."
        case .tooShort: return l == .tr ? "Kayıt çok kısaydı." : "That was too short."
        case .ttsUnavailable(let s): return (l == .tr ? "Sesli yanıt kullanılamıyor: " : "Spoken replies are unavailable: ") + s
        case .cancelled: return l == .tr ? "İptal edildi." : "Cancelled."
        }
    }
}

// MARK: - Metrics (bounded, local diagnostics only)

/// Latency breakdown of one voice turn. Every field is a measured interval in seconds (nil = not reached). No transcript text, no audio.
struct VoiceTurnMetrics: Equatable, Sendable {
    var sttProvider: String?
    var language: String?
    var audioSeconds: Double?
    var sttStartup: Double?             // PTT press → first audio fed (provider ready)
    var firstPartial: Double?           // first audio → first partial transcript
    var sttFinalization: Double?        // PTT release → final transcript
    var transcriptLength: Int?
    var routingToFirstText: Double?     // final transcript submitted → first response text
    var firstTextToSynthesis: Double?   // first stable chunk ready → chunk handed to TTS
    var synthesisToFirstAudio: Double?  // chunk handed to TTS → audio started
    var releaseToFirstAudio: Double?    // PTT release → first audible JARVIS audio
    var ttsProvider: String?
    var spokenSeconds: Double?
    var stopLatency: Double?
    var outcome: String?                // "ok" or a short error category
}
