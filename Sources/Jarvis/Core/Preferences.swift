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
        static let webResearch = "prefs.web.research"
        static let projectContinuation = "prefs.operator.continuation"
        static let experiments = "prefs.operator.experiments"
        static let adaptiveEnabled = "prefs.adaptive.enabled", learnTasks = "prefs.adaptive.tasks", learnCorrections = "prefs.adaptive.corrections", gapDetection = "prefs.adaptive.gaps"
        static let safeExperiments = "prefs.adaptive.experiments", autoPromoteWorkflows = "prefs.adaptive.autopromote", selfLevel = "prefs.adaptive.level"
        // V1.0 decision milestone: the OPTIONAL remote decision classifier (Jev). Off unless the user sets it; the app never sets it.
        static let decisionJevMode = "prefs.decision.jev.mode", decisionJevMinConfidence = "prefs.decision.jev.minConfidence", decisionJevModel = "prefs.decision.jev.model"
        // V0.15 daily JARVIS
        static let responseStyle = "prefs.daily.responseStyle", addressStyle = "prefs.daily.addressStyle", followUps = "prefs.daily.followUps", notifyTasks = "prefs.daily.notifyTasks"
        static let speakAcks = "prefs.daily.speakAcks", speakCompletions = "prefs.daily.speakCompletions", openCompactOnLaunch = "prefs.daily.openCompact", firstRunDone = "prefs.daily.firstRunDone"
        static let mcpDiscovery = "prefs.adaptive.mcpdiscovery", mcpUpdateAdvice = "prefs.adaptive.mcpupdates"
        static let visualMode = "prefs.operator.visualMode"
        static let visualModel = "prefs.operator.visualModel"
        static let webBrowser = "prefs.web.browser"
        static let memoryEnabled = "prefs.memory.enabled"
        static let memorySemantic = "prefs.memory.semantic"
        static let memoryAutoLearn = "prefs.memory.autolearn"
        static let memoryModelLearn = "prefs.memory.modellearn"
        static let computerEnabled = "prefs.computer.enabled"
        static let computerVision = "prefs.computer.vision"
        static let computerDiagnostics = "prefs.computer.diagnostics"
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

    @ObservationIgnored let defaults: UserDefaults
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
    /// V0.9: web research on request (searching and reading public pages, downloads into the quarantine). Never runs by itself; off = no research task can start.
    var webResearchEnabled: Bool { didSet { defaults.set(webResearchEnabled, forKey: Key.webResearch) } }
    /// V0.13: project status questions and “continue” (bounded sessions). Off = those phrases are ordinary chat again.
    var projectContinuationEnabled: Bool { didSet { defaults.set(projectContinuationEnabled, forKey: Key.projectContinuation) } }
    /// V1.0 decision milestone — "disabled" | "shadow" | "gated". DEFAULT "disabled": a remote classifier is never asked unless the user turned it on (and none is connected in this build).
    var decisionJevMode: String { didSet { defaults.set(decisionJevMode, forKey: Key.decisionJevMode) } }
    /// Gated mode only; conservative until the Phase B benchmark calibrates it.
    var decisionJevMinConfidence: Double { didSet { defaults.set(decisionJevMinConfidence, forKey: Key.decisionJevMinConfidence) } }
    /// A configured model alias for the classifier ("" = the transport's own discovery). Never a hard-coded version.
    var decisionJevModel: String { didSet { defaults.set(decisionJevModel, forKey: Key.decisionJevModel) } }
    /// V0.13: whether the `experiment` step may run at all (disposable-environment tests). On by default; off ⇒ the step fails with a clear reason and nothing is created.
    var experimentsEnabled: Bool { didSet { defaults.set(experimentsEnabled, forKey: Key.experiments) } }
    /// V0.14 adaptive learning (all conservative): learning from finished work and from corrections, gap detection, safe disposable experiments. Learning is never authority.
    var adaptiveLearningEnabled: Bool { didSet { defaults.set(adaptiveLearningEnabled, forKey: Key.adaptiveEnabled) } }
    var learnFromTasks: Bool { didSet { defaults.set(learnFromTasks, forKey: Key.learnTasks) } }
    var learnFromCorrections: Bool { didSet { defaults.set(learnFromCorrections, forKey: Key.learnCorrections) } }
    var capabilityGapDetection: Bool { didSet { defaults.set(capabilityGapDetection, forKey: Key.gapDetection) } }
    var safeLearningExperiments: Bool { didSet { defaults.set(safeLearningExperiments, forKey: Key.safeExperiments) } }
    /// OFF by default. Even when ON only LOW-risk workflow rules can be promoted without a click, and only after deterministic validation.
    var autoPromoteLowRiskWorkflows: Bool { didSet { defaults.set(autoPromoteLowRiskWorkflows, forKey: Key.autoPromoteWorkflows) } }
    var selfImprovementLevel: SelfImprovementLevel { didSet { defaults.set(selfImprovementLevel.rawValue, forKey: Key.selfLevel) } }
    /// V0.15 Daily JARVIS (presentation only — none of these can change what JARVIS is allowed to do).
    var responseStyle: ResponseStyle { didSet { defaults.set(responseStyle.rawValue, forKey: Key.responseStyle) } }
    var addressStyle: AddressStyle { didSet { defaults.set(addressStyle.rawValue, forKey: Key.addressStyle) } }
    var conversationFollowUps: Bool { didSet { defaults.set(conversationFollowUps, forKey: Key.followUps) } }
    /// OFF by default: macOS is asked for notification permission only when the user turns this on.
    var notifyOnTaskEvents: Bool { didSet { defaults.set(notifyOnTaskEvents, forKey: Key.notifyTasks) } }
    var voiceSpeakTaskAcks: Bool { didSet { defaults.set(voiceSpeakTaskAcks, forKey: Key.speakAcks) } }
    var voiceSpeakCompletions: Bool { didSet { defaults.set(voiceSpeakCompletions, forKey: Key.speakCompletions) } }
    var openCompactOnLaunch: Bool { didSet { defaults.set(openCompactOnLaunch, forKey: Key.openCompactOnLaunch) } }
    var firstRunCompleted: Bool { didSet { defaults.set(firstRunCompleted, forKey: Key.firstRunDone) } }
    var mcpDiscoveryEnabled: Bool { didSet { defaults.set(mcpDiscoveryEnabled, forKey: Key.mcpDiscovery) } }
    var mcpUpdateRecommendations: Bool { didSet { defaults.set(mcpUpdateRecommendations, forKey: Key.mcpUpdateAdvice) } }
    /// V0.13 general visual grounding: on-device only (Apple text recognition + the local vision model when installed), or off.
    var visualGroundingMode: VisualGroundingMode { didSet { defaults.set(visualGroundingMode.rawValue, forKey: Key.visualMode) } }
    var visualModel: LocalVLMModel { didSet { defaults.set(visualModel.rawValue, forKey: Key.visualModel) } }
    /// V0.9: allow the rendered-page (browser) tier for pages that need JavaScript. Off = plain HTTP only.
    var webBrowserTierEnabled: Bool { didSet { defaults.set(webBrowserTierEnabled, forKey: Key.webBrowser) } }
    /// V0.10: Project Memory (derived, provenance-backed knowledge about a project). Off = no memory is read, written or injected; everything else works unchanged.
    var projectMemoryEnabled: Bool { didSet { defaults.set(projectMemoryEnabled, forKey: Key.memoryEnabled) } }
    /// V0.10: use the local embedding helper for meaning-based search (needs scripts/setup_memory_ai.sh). Off or missing = keyword + structured search.
    var memorySemanticEnabled: Bool { didSet { defaults.set(memorySemanticEnabled, forKey: Key.memorySemantic) } }
    /// V0.10: remember meaningful finished tasks / research automatically (deterministic; no model).
    var memoryAutoLearnEnabled: Bool { didSet { defaults.set(memoryAutoLearnEnabled, forKey: Key.memoryAutoLearn) } }
    /// V0.10: after a meaningful task, ask ONE small model for proposed lessons (grounded in the report; never authoritative). Off by default: it spends a model request.
    var memoryModelLearningEnabled: Bool { didSet { defaults.set(memoryModelLearningEnabled, forKey: Key.memoryModelLearn) } }
    /// V0.11: Computer Use master switch (ON by default, but it only ever acts inside a task you started, and only if macOS Accessibility permission exists).
    var computerUseEnabled: Bool { didSet { defaults.set(computerUseEnabled, forKey: Key.computerEnabled) } }
    /// V0.11: the window-scoped vision fallback (needs the screen-capture permission). OFF until you turn it on.
    var computerVisionEnabled: Bool { didSet { defaults.set(computerVisionEnabled, forKey: Key.computerVision) } }
    /// V0.11: show counts/durations of the last observation on the Computer screen (never the tree itself, never persisted).
    var computerDiagnosticsEnabled: Bool { didSet { defaults.set(computerDiagnosticsEnabled, forKey: Key.computerDiagnostics) } }
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

    /// The production domain is the default only for an unprotected (plain) launch; a test process or developer launch gets a throw-away isolated suite, and passing
    /// `UserDefaults.standard` explicitly from one is a hard failure (`StorageIsolation`).
    init(defaults given: UserDefaults? = nil) {
        let defaults = given ?? (StorageIsolation.isProtectedRun ? StorageIsolation.isolatedDefaults() : .standard)
        StorageIsolation.assertNotProduction(defaults)
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
        webResearchEnabled = defaults.object(forKey: Key.webResearch) as? Bool ?? true
        projectContinuationEnabled = defaults.object(forKey: Key.projectContinuation) as? Bool ?? true
        decisionJevMode = defaults.string(forKey: Key.decisionJevMode).flatMap { JevMode(rawValue: $0) }?.rawValue ?? JevMode.disabled.rawValue
        decisionJevMinConfidence = min(max(defaults.object(forKey: Key.decisionJevMinConfidence) as? Double ?? 0.92, 0.5), 0.999)
        decisionJevModel = String((defaults.string(forKey: Key.decisionJevModel) ?? "").prefix(80))
        experimentsEnabled = defaults.object(forKey: Key.experiments) as? Bool ?? true
        adaptiveLearningEnabled = defaults.object(forKey: Key.adaptiveEnabled) as? Bool ?? true
        learnFromTasks = defaults.object(forKey: Key.learnTasks) as? Bool ?? true
        learnFromCorrections = defaults.object(forKey: Key.learnCorrections) as? Bool ?? true
        capabilityGapDetection = defaults.object(forKey: Key.gapDetection) as? Bool ?? true
        safeLearningExperiments = defaults.object(forKey: Key.safeExperiments) as? Bool ?? true
        autoPromoteLowRiskWorkflows = defaults.object(forKey: Key.autoPromoteWorkflows) as? Bool ?? false
        selfImprovementLevel = (defaults.object(forKey: Key.selfLevel) as? Int).flatMap(SelfImprovementLevel.init(rawValue:)) ?? .experiment
        responseStyle = defaults.string(forKey: Key.responseStyle).flatMap(ResponseStyle.init(rawValue:)) ?? .concise
        addressStyle = defaults.string(forKey: Key.addressStyle).flatMap(AddressStyle.init(rawValue:)) ?? .natural
        conversationFollowUps = defaults.object(forKey: Key.followUps) as? Bool ?? true
        notifyOnTaskEvents = defaults.object(forKey: Key.notifyTasks) as? Bool ?? false
        voiceSpeakTaskAcks = defaults.object(forKey: Key.speakAcks) as? Bool ?? true
        voiceSpeakCompletions = defaults.object(forKey: Key.speakCompletions) as? Bool ?? true
        openCompactOnLaunch = defaults.object(forKey: Key.openCompactOnLaunch) as? Bool ?? false
        firstRunCompleted = defaults.object(forKey: Key.firstRunDone) as? Bool ?? false
        mcpDiscoveryEnabled = defaults.object(forKey: Key.mcpDiscovery) as? Bool ?? true
        mcpUpdateRecommendations = defaults.object(forKey: Key.mcpUpdateAdvice) as? Bool ?? true
        visualGroundingMode = (defaults.string(forKey: Key.visualMode)).flatMap(VisualGroundingMode.init(rawValue:)) ?? .auto
        visualModel = (defaults.string(forKey: Key.visualModel)).flatMap(LocalVLMModel.init(rawValue:)) ?? .qwen3VL4B
        webBrowserTierEnabled = defaults.object(forKey: Key.webBrowser) as? Bool ?? true
        projectMemoryEnabled = defaults.object(forKey: Key.memoryEnabled) as? Bool ?? true
        memorySemanticEnabled = defaults.object(forKey: Key.memorySemantic) as? Bool ?? true
        memoryAutoLearnEnabled = defaults.object(forKey: Key.memoryAutoLearn) as? Bool ?? true
        memoryModelLearningEnabled = defaults.object(forKey: Key.memoryModelLearn) as? Bool ?? false
        computerUseEnabled = defaults.object(forKey: Key.computerEnabled) as? Bool ?? true
        computerVisionEnabled = defaults.object(forKey: Key.computerVision) as? Bool ?? false
        computerDiagnosticsEnabled = defaults.object(forKey: Key.computerDiagnostics) as? Bool ?? false
        voicePushToTalk = defaults.object(forKey: Key.voicePTT) as? Bool ?? true
        voiceSpeakResponses = defaults.object(forKey: Key.voiceSpeak) as? Bool ?? true
        voiceLanguage = defaults.string(forKey: Key.voiceLanguage).flatMap(VoiceLanguage.init(rawValue:)) ?? .auto
        voiceSTTProvider = defaults.string(forKey: Key.voiceSTT) ?? "auto"
        voiceTTSProvider = defaults.string(forKey: Key.voiceTTS) ?? "auto"
        voiceSpeechRate = defaults.object(forKey: Key.voiceRate) as? Double ?? 1.0
        voiceTurkishVoice = defaults.string(forKey: Key.voiceTrVoice) ?? ""
        voiceEnglishVoice = defaults.string(forKey: Key.voiceEnVoice) ?? ""
        voiceWakeEnabled = defaults.object(forKey: Key.wakeEnabled) as? Bool ?? false
        voiceWakeAcknowledgement = defaults.string(forKey: Key.wakeAck).flatMap(WakeAcknowledgement.init(rawValue:)) ?? .voice
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
