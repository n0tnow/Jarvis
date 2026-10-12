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

    var output: VoiceOutputSettings { VoiceOutputSettings(rate: speechRate, turkishVoiceID: turkishVoiceID, englishVoiceID: englishVoiceID) }
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
    static let ttsOrder = ["apple-synthesizer"]

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

    static func chooseTTS(preference: String, candidates: [(id: String, name: String, availability: TTSAvailability, cost: VoiceCostClass)]) -> VoiceProviderChoice {
        if preference != "auto" {
            guard let c = candidates.first(where: { $0.id == preference }) else { return VoiceProviderChoice(id: nil, reason: "The chosen voice engine is not available in this build.") }
            if case .unavailable(let why) = c.availability { return VoiceProviderChoice(id: nil, reason: "\(c.name): \(why).") }
            return VoiceProviderChoice(id: c.id, reason: "\(c.name) (your choice)")
        }
        let ranked = candidates.sorted { (ttsOrder.firstIndex(of: $0.id) ?? 99) < (ttsOrder.firstIndex(of: $1.id) ?? 99) }
        for c in ranked where c.cost.autoSelectable && c.availability.isReady { return VoiceProviderChoice(id: c.id, reason: "\(c.name) (best available)") }
        return VoiceProviderChoice(id: nil, reason: "No voice engine is available.")
    }
}
