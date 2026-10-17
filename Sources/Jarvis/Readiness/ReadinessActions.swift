import AppKit
import Foundation

// MARK: - What a readiness button does (V0.15)
//
// Every button in the readiness UI maps to a `SetupAction`; this is the single place that performs one. Requests for permissions go through the existing, explicit, once-only code paths (the
// microphone request in `SystemMicrophonePermission`, the Accessibility / Screen Recording guides in `ComputerRuntime`); installs go through `SetupRunner`. Nothing grants anything to JARVIS.

@MainActor
enum ReadinessActions {
    /// Returns a one-line message for the UI, or nil when nothing needs saying.
    @discardableResult
    static func run(_ action: SetupAction, in app: AppContext) async -> String? {
        switch action {
        case .recheck:
            await recheck(app)
            return "Checked again."
        case .allowMicrophone:
            await app.voice.requestMicrophoneFromSettings()
            app.readiness.refresh()
            return app.voice.permission == .granted ? "Microphone allowed." : "Microphone: \(app.voice.permission.label.lowercased())."
        case .openMicrophoneSettings: PrivacySettingsPane.microphone.open(); return nil
        case .allowAccessibility: app.computer.guideToAccessibility(); return "macOS shows its own prompt; only you can allow it."
        case .openAccessibilitySettings: PrivacySettingsPane.accessibility.open(); return nil
        case .allowScreenRecording: app.computer.guideToScreenCapture(); return "macOS shows its own prompt; only you can allow it."
        case .openScreenRecordingSettings: PrivacySettingsPane.screenRecording.open(); return nil
        case .allowNotifications:
            let ok = await app.notifier.requestAuthorization()
            app.readiness.refresh()
            return ok ? "Notifications allowed." : "Notifications were not allowed."
        case .openNotificationSettings: PrivacySettingsPane.notifications.open(); return nil
        case .chooseLocalModelFolder: return chooseModelFolder(app)
        case .turnOnVoice:
            app.preferences.voiceEnabled = true; app.preferences.voicePushToTalk = true
            app.readiness.refresh()
            return "Voice is on. Hold the right ⌥ key for a moment, speak, and release."
        case .turnOnWake:
            // A switch is not a fact: turn it on, apply it, then report what the detector REALLY did.
            app.preferences.voiceEnabled = true
            app.preferences.voiceWakeEnabled = true
            await app.handsFree.applySettings()
            app.readiness.refresh()
            return Self.wakeOutcome(app)
        case .restartJarvis:
            AppRelauncher.relaunch()
            return "Restarting…"
        case .installLocalModelRuntime, .installSpeechRecognizer, .installNaturalVoice, .installVisionHelper, .installMemoryHelper:
            if let refusal = await app.setupRunner.start(action) { return refusal.description }
            return nil
        }
    }

    /// What the wake detector is doing now, in one sentence (used after the switch is flipped).
    static func wakeOutcome(_ app: AppContext) -> String {
        switch app.handsFree.wakeStatus {
        case .listening: return "Wake Word is ON and the detector is RUNNING. Say “Jarvis”."
        case .starting: return "Wake Word is ON — the detector is starting."
        case .paused: return "Wake Word is ON but paused (sleep mode)."
        case .off: return app.voice.permission == .granted ? "Wake Word is ON but the detector is not running." : "Wake Word is ON but the microphone permission is missing — allow it in System Settings, then press Recheck."
        case .unavailable(let why): return "Wake Word is ON but the detector could not start: \(why)."
        }
    }

    /// Re-reads EVERY permission from the OS (Accessibility, Screen Recording, Microphone, Notifications, Speech Recognition) and re-evaluates the wake detector, so coming back from System Settings
    /// shows the truth without restarting JARVIS (macOS itself requires a restart only for some permissions — the rows say so).
    static func recheck(_ app: AppContext) async {
        if !app.intelligenceIsStubbed { await app.refreshIntelligence(remoteCatalog: false, includeOpenCode: false) }        // safe status commands only; no model call, no catalog download
        app.voice.refreshPermission()
        await app.voice.refreshProviders()
        _ = app.computer.refreshPermissions()
        await app.notifier.refreshStatus()
        if !app.intelligenceIsStubbed, app.preferences.voiceEnabled, app.preferences.voiceWakeEnabled, app.handsFree.wakeStatus != .listening { await app.handsFree.applySettings() }
        app.readiness.refresh()
    }

    private static func chooseModelFolder(_ app: AppContext) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.title = "Select the folder of an existing local model"
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        switch ModelFolderValidator.validate(url) {
        case .ok(let path):
            app.preferences.localModelPath = path
            app.readiness.refresh()
            return "Using the model at \(path). It is loaded on demand, and the change applies the next time JARVIS starts."
        case .refused(let why):
            return "That folder was not used: \(why)"
        }
    }
}
