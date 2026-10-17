import Foundation

/// What Settings → Voice stores. A plain value so the coordinator and the selection logic are testable without UserDefaults.
struct VoiceSettings: Equatable, Sendable {
    var enabled = false
    var pushToTalkEnabled = true
    var speakResponses = true
    var language: VoiceLanguage = .auto
    /// "auto" or a provider id.
    var sttProvider = "auto"
    var ttsProvider = "auto"
    var speechRate = 1.0
    var turkishVoiceID = ""
    var englishVoiceID = ""
    // V0.8 — natural voice. Wake mode is OPT-IN (off by default): nothing listens continuously unless the user turns it on.
    var wakeEnabled = false
    var wakeAcknowledgement: WakeAcknowledgement = .voice
    var bargeInEnabled = true
    var voicePreset: JarvisVoicePreset = .jarvisDefault

    var output: VoiceOutputSettings { VoiceOutputSettings(rate: speechRate, turkishVoiceID: turkishVoiceID, englishVoiceID: englishVoiceID) }
}

/// How JARVIS acknowledges the wake word. A short sound is the default: speaking would add latency and put JARVIS' own voice into the microphone.
enum WakeAcknowledgement: String, CaseIterable, Codable, Sendable {
    case sound, voice, off
    var label: String { switch self { case .sound: "Sound"; case .voice: "Voice"; case .off: "Off" } }
}

/// The outcome of provider selection, with the reason (shown in Settings → Voice and recorded in diagnostics).
struct VoiceProviderChoice: Equatable, Sendable {
    var id: String?
    var reason: String
    var fellBack = false
}

/// Pure provider selection. Cost policy first: a provider whose cost class may incur spend (PAID / UNKNOWN) is never chosen automatically.
/// An explicit provider choice never falls back (a refusal is explained instead), exactly like the intelligence router (DEC-026).
enum VoiceProviderSelection {
    struct STTCandidate: Sendable {
        var id: String
        var name: String
        var availability: STTAvailability
        var capabilities: STTCapabilities
        /// Loads a model into memory (heavier than an OS service); skipped in Auto under memory pressure.
        var loadsModel: Bool
    }

    /// Preferred order in Auto: measured accuracy first (docs/VOICE_IO.md), the zero-setup system recogniser last.
    static let sttOrder = ["whisper-local", "apple-speech"]
    static let ttsOrder = ["neural-supertonic", "apple-synthesizer"]
    /// Voices that load a model into memory (skipped in Auto under memory pressure; Apple system voices are the fallback).
    static let heavyTTS: Set<String> = ["neural-supertonic"]

    static func chooseSTT(preference: String, candidates: [STTCandidate], memoryPressureNormal: Bool) -> VoiceProviderChoice {
        if preference != "auto" {
            guard let c = candidates.first(where: { $0.id == preference }) else { return VoiceProviderChoice(id: nil, reason: "The chosen recogniser is not available in this build.") }
            guard c.availability.isReady else { return VoiceProviderChoice(id: nil, reason: "\(c.name): \(c.availability.detail ?? "not ready").") }
            return VoiceProviderChoice(id: c.id, reason: "\(c.name) (your choice)")
        }
        let ranked = candidates.sorted { (sttOrder.firstIndex(of: $0.id) ?? 99) < (sttOrder.firstIndex(of: $1.id) ?? 99) }
        var skipped: [String] = []
        for c in ranked {
            guard c.capabilities.costClass.autoSelectable else { skipped.append("\(c.name): cost \(c.capabilities.costClass.label)"); continue }
            guard c.availability.isReady else { skipped.append("\(c.name): \(c.availability.detail ?? "not ready")"); continue }
            if c.loadsModel && !memoryPressureNormal { skipped.append("\(c.name): memory pressure"); continue }
            let fell = c.id != ranked.first?.id
            return VoiceProviderChoice(id: c.id, reason: fell ? "\(c.name) (fallback — \(skipped.joined(separator: "; ")))" : "\(c.name) (best available)", fellBack: fell)
        }
        return VoiceProviderChoice(id: nil, reason: skipped.isEmpty ? "No speech recogniser is installed." : skipped.joined(separator: "; "))
    }

    static func chooseTTS(preference: String, candidates: [(id: String, name: String, availability: TTSAvailability, cost: VoiceCostClass)],
                          memoryPressureNormal: Bool = true, preset: JarvisVoicePreset = .jarvisDefault) -> VoiceProviderChoice {
        if preference != "auto" {
            guard let c = candidates.first(where: { $0.id == preference }) else { return VoiceProviderChoice(id: nil, reason: "The chosen voice engine is not available in this build.") }
            if case .unavailable(let why) = c.availability { return VoiceProviderChoice(id: nil, reason: "\(c.name): \(why).") }
            return VoiceProviderChoice(id: c.id, reason: "\(c.name) (your choice)")
        }
        let ranked = candidates.sorted { (ttsOrder.firstIndex(of: $0.id) ?? 99) < (ttsOrder.firstIndex(of: $1.id) ?? 99) }
        var skipped: [String] = []
        for c in ranked {
            guard c.cost.autoSelectable else { skipped.append("\(c.name): cost \(c.cost.label)"); continue }
            if heavyTTS.contains(c.id) {
                if preset == .systemFallback { skipped.append("\(c.name): System Fallback is selected"); continue }
                if !memoryPressureNormal { skipped.append("\(c.name): memory pressure"); continue }
            }
            if case .unavailable(let why) = c.availability { skipped.append("\(c.name): \(why)"); continue }
            let fell = c.id != ranked.first?.id && !skipped.isEmpty
            return VoiceProviderChoice(id: c.id, reason: fell ? "\(c.name) (fallback — \(skipped.joined(separator: "; ")))" : "\(c.name) (best available)", fellBack: fell)
        }
        return VoiceProviderChoice(id: nil, reason: skipped.isEmpty ? "No voice engine is available." : skipped.joined(separator: "; "))
    }
}
