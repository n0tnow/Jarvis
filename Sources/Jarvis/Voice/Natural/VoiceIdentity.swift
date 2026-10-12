import Foundation

/// JARVIS Voice Identity v1 (V0.8): WHAT the voice should be like, independent of any synthesiser. It is an original character — it does not copy, clone or
/// imitate any actor, performer or identifiable person — and it is mapped to provider-specific settings by `VoiceIdentityMapper`.
///
/// Target: mature male, calm, composed, precise, understated, warm but restrained, medium-low pitch, natural conversational pace, short deliberate pauses,
/// clear diction, no theatrical/announcer/cartoon/robotic delivery; natural Turkish pronunciation when speaking Turkish and a neutral international
/// (British-leaning only where the voice naturally has it) English; the same personality in both languages as far as the technology allows.
/// Whether a given voice SOUNDS like this is a human judgement (MANUAL TEST REQUIRED) — numbers below are targets, not verified qualities.
struct JarvisVoiceIdentity: Equatable, Sendable {
    let version = 1
    /// Target fundamental-frequency range for the speaking voice in Hz (an engineering proxy for "medium-low male"; measured on candidates, not on people).
    let pitchTargetHz: ClosedRange<Double> = 85 ... 130
    /// Relative pace: 1.0 = the voice's natural conversational pace.
    let pace = 1.0
    /// Pause character between phrases (seconds): short and intentional.
    let phraseGap: ClosedRange<Double> = 0.12 ... 0.35
    static let v1 = JarvisVoiceIdentity()
}

/// What the user picks in Settings → Voice. Only presets that correspond to a REAL installed voice are offered.
enum JarvisVoicePreset: String, CaseIterable, Codable, Sendable {
    case jarvisDefault = "default"
    case jarvisCalm = "calm"
    case systemFallback = "system"

    var label: String {
        switch self { case .jarvisDefault: "JARVIS Default"; case .jarvisCalm: "JARVIS Calm"; case .systemFallback: "System Fallback" }
    }
    var summary: String {
        switch self {
        case .jarvisDefault: "Neural voice, lowest and most even pitch of the built-in male styles."
        case .jarvisCalm: "Neural voice, slightly slower and warmer."
        case .systemFallback: "macOS system voices (works without any download)."
        }
    }
}

/// What a neural synthesiser needs to render the identity (Supertonic 3 vocabulary: a built-in voice style, a speed factor, a number of denoising steps).
struct NeuralVoiceParameters: Equatable, Sendable {
    var style: String
    var speed: Double
    var steps: Int
    var wordGap: Double = 0.18        // seconds of silence between sentences inside ONE synthesis call
}

enum VoiceIdentityMapper {
    /// Supertonic 3 styles M1…M5 are male. Chosen on measured median F0 of the same phrase (≈ 94–107 Hz for M2/M3/M5, ≥ 126 Hz for M1/M4); the final
    /// choice between them is a LISTENING decision left to the user (manual A/B in Settings → Voice).
    static func neural(preset: JarvisVoicePreset, rate: Double) -> NeuralVoiceParameters? {
        let r = max(0.7, min(rate, 1.4))
        switch preset {
        case .jarvisDefault: return NeuralVoiceParameters(style: "M5", speed: 1.0 * r, steps: 6)
        case .jarvisCalm: return NeuralVoiceParameters(style: "M3", speed: 0.94 * r, steps: 6, wordGap: 0.22)
        case .systemFallback: return nil
        }
    }

    /// For the Apple system voices: prefer an installed MALE voice that fits the identity when the user has not chosen one (English: Daniel, en-GB).
    /// Turkish has no installed male Apple voice on this Mac (only Yelda) — a documented compromise, not a silent substitution.
    static let preferredMaleEnglish = ["Daniel", "Oliver", "Arthur", "Rishi", "Aaron", "Gordon", "Evan", "Reed"]
    static func appleVoiceID(language: VoiceLanguage, among voices: [VoiceDescriptor]) -> String? {
        guard language == .english else { return nil }
        for name in preferredMaleEnglish {
            if let v = voices.filter({ $0.voiceLanguage == .english && $0.name == name }).max(by: { $0.quality < $1.quality }) { return v.id }
        }
        return nil
    }
}
