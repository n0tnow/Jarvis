import AppKit
import Observation

/// Minimal user settings, persisted in UserDefaults.
@MainActor
@Observable
final class Preferences {
    private enum Key {
        static let reduceMotion = "prefs.reduceMotion"
        static let showDeveloperControls = "prefs.showDeveloperControls"
        static let globalShortcuts = "prefs.globalShortcutsEnabled"
        static let providerPreference = "prefs.providerPreference"
        static let claudePath = "prefs.claudePathOverride"
        static let codexPath = "prefs.codexPathOverride"
        static let openCodePath = "prefs.openCodePathOverride"
        static let localModelPath = "prefs.localModelPath"
        static let allowLocal = "prefs.routing.allowLocal"
        static let allowFreeCloud = "prefs.routing.allowFreeCloud"
        static let localIdleUnload = "prefs.local.idleUnloadSeconds"
        static let projectRoot = "prefs.tasks.projectRoot"
        static let autonomyMode = "prefs.autonomy.mode"
        static let proactiveEnabled = "prefs.autonomy.proactiveEnabled"
        static let showProposals = "prefs.autonomy.showProposals"
        static let voiceEnabled = "prefs.voice.enabled"
        static let voicePTT = "prefs.voice.pushToTalk"
        static let voiceSpeak = "prefs.voice.speakResponses"
        static let voiceLanguage = "prefs.voice.language"
        static let voiceSTT = "prefs.voice.sttProvider"
        static let voiceTTS = "prefs.voice.ttsProvider"
        static let voiceRate = "prefs.voice.speechRate"
        static let voiceTrVoice = "prefs.voice.turkishVoice"
        static let voiceEnVoice = "prefs.voice.englishVoice"
        static let neuralModelPath = "prefs.voice.neuralModelPath"
        static let neuralIdle = "prefs.voice.neuralIdleUnloadSeconds"
        static let wakeEnabled = "prefs.voice.wake.enabled"
        static let wakeAck = "prefs.voice.wake.acknowledgement"
        static let bargeIn = "prefs.voice.bargeIn"
        static let voicePreset = "prefs.voice.preset"
        static let whisperModelPath = "prefs.voice.whisperModelPath"
        static let whisperIdle = "prefs.voice.whisperIdleUnloadSeconds"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var motionObserver: NSObjectProtocol?

    var reduceMotion: Bool {
        didSet { defaults.set(reduceMotion, forKey: Key.reduceMotion) }
    }

    /// Developer controls (state simulator) — ON by default in V0.1 because the demo state machine is the point.
    var showDeveloperControls: Bool {
        didSet { defaults.set(showDeveloperControls, forKey: Key.showDeveloperControls) }
    }

    /// Global ⌥⌘ / ⌥⌘⌘ shortcuts (permission-free modifier polling). On by default; this is the off switch.
    var globalShortcutsEnabled: Bool {
        didSet { defaults.set(globalShortcutsEnabled, forKey: Key.globalShortcuts) }
    }

    /// Which intelligence provider answers reasoning requests (Auto = first READY of Claude Code, Codex).
    var providerPreference: ProviderPreference {
        didSet { defaults.set(providerPreference.rawValue, forKey: Key.providerPreference) }
    }
    /// Optional user-chosen executable locations (the GUI app's PATH is not the Terminal's).
    var claudePathOverride: String { didSet { defaults.set(claudePathOverride, forKey: Key.claudePath) } }
    var codexPathOverride: String { didSet { defaults.set(codexPathOverride, forKey: Key.codexPath) } }
    var openCodePathOverride: String { didSet { defaults.set(openCodePathOverride, forKey: Key.openCodePath) } }
    /// Directory of the local MLX model (default `~/AI/models/Qwen3.5-4B-MLX-4bit`; never downloaded by JARVIS).
    var localModelPath: String { didSet { defaults.set(localModelPath, forKey: Key.localModelPath) } }
    /// Auto-routing switches (an explicit provider choice ignores them).
    var allowLocalInAuto: Bool { didSet { defaults.set(allowLocalInAuto, forKey: Key.allowLocal) } }
    var allowFreeCloudInAuto: Bool { didSet { defaults.set(allowFreeCloudInAuto, forKey: Key.allowFreeCloud) } }
    /// The project folder autonomous tasks may work in (V0.4). Empty = none chosen: development tasks are not started.
    var projectRoot: String { didSet { defaults.set(projectRoot, forKey: Key.projectRoot) } }
    /// V0.5 autonomy: how much initiative JARVIS may take. Conservative default: it asks before acting.
    var autonomyMode: AutonomyMode { didSet { defaults.set(autonomyMode.rawValue, forKey: Key.autonomyMode) } }
    /// Event-driven proactive reasoning (findings after tasks). Off = no opportunities, no extra provider calls.
    var proactiveReasoningEnabled: Bool { didSet { defaults.set(proactiveReasoningEnabled, forKey: Key.proactiveEnabled) } }
    var showProposals: Bool { didSet { defaults.set(showProposals, forKey: Key.showProposals) } }
    var autonomySettings: AutonomySettings { AutonomySettings(mode: autonomyMode, proactiveEnabled: proactiveReasoningEnabled, showProposals: showProposals) }
    // V0.7 voice. The microphone is OFF unless the user turns Voice on here AND holds the Push-to-Talk key.
    var voiceEnabled: Bool { didSet { defaults.set(voiceEnabled, forKey: Key.voiceEnabled) } }
    var voicePushToTalk: Bool { didSet { defaults.set(voicePushToTalk, forKey: Key.voicePTT) } }
    var voiceSpeakResponses: Bool { didSet { defaults.set(voiceSpeakResponses, forKey: Key.voiceSpeak) } }
    var voiceLanguage: VoiceLanguage { didSet { defaults.set(voiceLanguage.rawValue, forKey: Key.voiceLanguage) } }
    var voiceSTTProvider: String { didSet { defaults.set(voiceSTTProvider, forKey: Key.voiceSTT) } }
    var voiceTTSProvider: String { didSet { defaults.set(voiceTTSProvider, forKey: Key.voiceTTS) } }
    var voiceSpeechRate: Double { didSet { defaults.set(voiceSpeechRate, forKey: Key.voiceRate) } }
    var voiceTurkishVoice: String { didSet { defaults.set(voiceTurkishVoice, forKey: Key.voiceTrVoice) } }
    var voiceEnglishVoice: String { didSet { defaults.set(voiceEnglishVoice, forKey: Key.voiceEnVoice) } }
    // V0.8 natural voice. Wake mode is OPT-IN and OFF by default: the microphone is only ever open while the right Option key is held unless this is turned on.
    var voiceWakeEnabled: Bool { didSet { defaults.set(voiceWakeEnabled, forKey: Key.wakeEnabled) } }
    var voiceWakeAcknowledgement: WakeAcknowledgement { didSet { defaults.set(voiceWakeAcknowledgement.rawValue, forKey: Key.wakeAck) } }
    var voiceBargeIn: Bool { didSet { defaults.set(voiceBargeIn, forKey: Key.bargeIn) } }
    var voicePreset: JarvisVoicePreset { didSet { defaults.set(voicePreset.rawValue, forKey: Key.voicePreset) } }
    /// Directory of the optional neural voice model (created by `scripts/setup_voice_ai.sh --natural`; never downloaded by JARVIS).
    var neuralVoiceModelPath: String { didSet { defaults.set(neuralVoiceModelPath, forKey: Key.neuralModelPath) } }
    var neuralIdleUnloadSeconds: TimeInterval { didSet { defaults.set(neuralIdleUnloadSeconds, forKey: Key.neuralIdle) } }
    /// Directory of the optional Whisper model (created by `scripts/setup_voice_ai.sh`; never downloaded by JARVIS).
    var whisperModelPath: String { didSet { defaults.set(whisperModelPath, forKey: Key.whisperModelPath) } }
    var whisperIdleUnloadSeconds: Double { didSet { defaults.set(whisperIdleUnloadSeconds, forKey: Key.whisperIdle) } }
    var voiceSettings: VoiceSettings {
        VoiceSettings(enabled: voiceEnabled, pushToTalkEnabled: voicePushToTalk, speakResponses: voiceSpeakResponses, language: voiceLanguage, sttProvider: voiceSTTProvider,
                      ttsProvider: voiceTTSProvider, speechRate: voiceSpeechRate, turkishVoiceID: voiceTurkishVoice, englishVoiceID: voiceEnglishVoice,
                      wakeEnabled: voiceWakeEnabled, wakeAcknowledgement: voiceWakeAcknowledgement, bargeInEnabled: voiceBargeIn, voicePreset: voicePreset)
    }

    /// Seconds of inactivity before the local model is unloaded from memory.
    var localIdleUnloadSeconds: Double { didSet { defaults.set(localIdleUnloadSeconds, forKey: Key.localIdleUnload) } }

    /// Mirrors System Settings ▸ Accessibility ▸ Display ▸ Reduce motion.
    private(set) var systemReduceMotion: Bool

    /// Launch at Login is intentionally NOT implemented in V0.1 (see docs/ROADMAP.md).
    let launchAtLoginIsAvailable = false

    var effectiveReduceMotion: Bool { reduceMotion || systemReduceMotion }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reduceMotion = defaults.bool(forKey: Key.reduceMotion)
        showDeveloperControls = defaults.object(forKey: Key.showDeveloperControls) as? Bool ?? true
        globalShortcutsEnabled = defaults.object(forKey: Key.globalShortcuts) as? Bool ?? true
        providerPreference = ProviderPreference(rawValue: defaults.string(forKey: Key.providerPreference) ?? "") ?? .auto
        claudePathOverride = defaults.string(forKey: Key.claudePath) ?? ""
        codexPathOverride = defaults.string(forKey: Key.codexPath) ?? ""
        openCodePathOverride = defaults.string(forKey: Key.openCodePath) ?? ""
        localModelPath = defaults.string(forKey: Key.localModelPath) ?? LocalRuntimeConfig.defaultModelPath
        allowLocalInAuto = defaults.object(forKey: Key.allowLocal) as? Bool ?? true
        allowFreeCloudInAuto = defaults.object(forKey: Key.allowFreeCloud) as? Bool ?? true
        localIdleUnloadSeconds = defaults.object(forKey: Key.localIdleUnload) as? Double ?? 300
        projectRoot = defaults.string(forKey: Key.projectRoot) ?? ""
        autonomyMode = defaults.string(forKey: Key.autonomyMode).flatMap(AutonomyMode.init(rawValue:)) ?? .askBeforeActing
        proactiveReasoningEnabled = defaults.object(forKey: Key.proactiveEnabled) as? Bool ?? true
        showProposals = defaults.object(forKey: Key.showProposals) as? Bool ?? true
        voiceEnabled = defaults.object(forKey: Key.voiceEnabled) as? Bool ?? false
        voicePushToTalk = defaults.object(forKey: Key.voicePTT) as? Bool ?? true
        voiceSpeakResponses = defaults.object(forKey: Key.voiceSpeak) as? Bool ?? true
        voiceLanguage = defaults.string(forKey: Key.voiceLanguage).flatMap(VoiceLanguage.init(rawValue:)) ?? .auto
        voiceSTTProvider = defaults.string(forKey: Key.voiceSTT) ?? "auto"
        voiceTTSProvider = defaults.string(forKey: Key.voiceTTS) ?? "auto"
        voiceSpeechRate = defaults.object(forKey: Key.voiceRate) as? Double ?? 1.0
        voiceTurkishVoice = defaults.string(forKey: Key.voiceTrVoice) ?? ""
        voiceEnglishVoice = defaults.string(forKey: Key.voiceEnVoice) ?? ""
        voiceWakeEnabled = defaults.object(forKey: Key.wakeEnabled) as? Bool ?? false
        voiceWakeAcknowledgement = defaults.string(forKey: Key.wakeAck).flatMap(WakeAcknowledgement.init(rawValue:)) ?? .sound
        voiceBargeIn = defaults.object(forKey: Key.bargeIn) as? Bool ?? true
        neuralVoiceModelPath = defaults.string(forKey: Key.neuralModelPath) ?? NeuralVoiceRuntime.Config.defaultModelDirectory
        neuralIdleUnloadSeconds = defaults.object(forKey: Key.neuralIdle) as? Double ?? 180
        voicePreset = defaults.string(forKey: Key.voicePreset).flatMap(JarvisVoicePreset.init(rawValue:)) ?? .jarvisDefault
        whisperModelPath = defaults.string(forKey: Key.whisperModelPath) ?? WhisperRuntimeConfig.defaultModelPath
        whisperIdleUnloadSeconds = defaults.object(forKey: Key.whisperIdle) as? Double ?? 120
        systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
    }
}
