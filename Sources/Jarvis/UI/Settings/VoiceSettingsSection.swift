import AppKit
import SwiftUI

/// Settings → Voice. Restrained on purpose: on/off, language, recogniser, voices, rate. Developer diagnostics appear only with developer controls.
struct VoiceSettingsSection: View {
    @Environment(AppContext.self) private var app
    @State private var installing: String?

    private func mono(_ t: String, _ tint: Color = .secondary) -> some View { Text(t).font(.system(.caption, design: .monospaced)).foregroundStyle(tint) }

    private var voices: [VoiceDescriptor] { app.voice.ttsProviders.first?.voices() ?? [] }

    var body: some View {
        @Bindable var prefs = app.preferences
        let voice = app.voice
        Section("Voice") {
            Toggle("Enable voice (Push-to-Talk)", isOn: $prefs.voiceEnabled).accessibilityIdentifier("settings.voiceEnabled")
            Text("The microphone is off until you HOLD the Push-to-Talk key, and it stops the moment you let go. Nothing is recorded to disk or kept; only the final transcript becomes a normal message.")
                .font(.caption).foregroundStyle(.secondary)
            if prefs.voiceEnabled {
                Toggle("Push-to-Talk shortcut", isOn: $prefs.voicePushToTalk)
                LabeledContent("Shortcut") { Text("hold right ⌥").font(.system(size: 14, weight: .medium, design: .rounded)) }
                Text("Hold the RIGHT Option key by itself for a moment, speak, release. Typing Option characters, ⌥⌘ shortcuts, Shift or Control combinations never start it. Needs no macOS permission of its own.")
                    .font(.caption).foregroundStyle(.secondary)

                LabeledContent("Microphone") { mono(voice.permission.label, voice.permission.allowsCapture ? .green : (voice.permission == .notDetermined ? .secondary : .orange)) }
                switch voice.permission {
                case .notDetermined: Text("macOS will ask the first time you use Push-to-Talk.").font(.caption).foregroundStyle(.secondary)
                case .denied, .restricted:
                    Text("Microphone access is not allowed, so voice input is unavailable (typing is unaffected). You can allow JARVIS in System Settings → Privacy & Security → Microphone.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open System Settings") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) }
                case .granted: EmptyView()
                }

                Picker("Recognition language", selection: $prefs.voiceLanguage) {
                    ForEach(VoiceLanguage.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                let autoNote = voice.sttChoice.id.flatMap { id in voice.sttProviders.first { $0.id == id } }?.capabilities.autoDetectsLanguage == true
                Text(prefs.voiceLanguage != .auto ? "Recognition is fixed to \(prefs.voiceLanguage.label)."
                     : (autoNote ? "Auto detects Turkish or English from your speech." : "This recogniser cannot detect the language, so Auto uses your system language (\(VoiceLanguage.systemDefault.label)). Choose Turkish or English to be explicit."))
                    .font(.caption).foregroundStyle(.secondary)

                Picker("Speech recogniser", selection: $prefs.voiceSTTProvider) {
                    Text("Auto").tag("auto")
                    ForEach(voice.sttProviders, id: \.id) { Text($0.displayName).tag($0.id) }
                }
                ForEach(voice.sttProviders, id: \.id) { p in
                    HStack {
                        Text(p.displayName).font(.caption)
                        Spacer()
                        switch voice.sttAvailability[p.id] {
                        case .some(.ready): mono("READY", .green)
                        case .some(.needsSetup(let why)): mono("SETUP NEEDED", .orange).help(why)
                        case .some(.unavailable(let why)): mono("UNAVAILABLE", .orange).help(why)
                        case .none: mono("…")
                        }
                        mono(p.capabilities.costClass.label)
                    }
                    if case .some(.needsSetup(let why)) = voice.sttAvailability[p.id] {
                        Text(why).font(.caption2).foregroundStyle(.secondary)
                        if let apple = p as? AppleSpeechSTTProvider {
                            HStack {
                                Button(installing == p.id ? "Installing…" : "Install speech model") {
                                    installing = p.id
                                    Task { try? await apple.install(language: prefs.voiceLanguage); installing = nil; await voice.refreshProviders() }
                                }.disabled(installing != nil)
                                if installing == p.id { ProgressView().controlSize(.small) }
                            }
                        }
                    }
                }
                Text("Using: \(voice.sttChoice.reason)").font(.caption).foregroundStyle(.secondary)
                Text("Both recognisers run on this Mac: no network, no API key, no cost. Whisper is more accurate (especially Turkish and technical words) but needs a one-time ≈460 MB download (scripts/setup_voice_ai.sh) and about 0.9 GB of memory while loaded (it unloads itself when idle or when memory is tight). Apple Speech needs no setup beyond its own language model.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Speak responses to voice requests", isOn: $prefs.voiceSpeakResponses)
                Picker("Turkish voice", selection: $prefs.voiceTurkishVoice) {
                    Text("Automatic").tag("")
                    ForEach(voices.filter { $0.voiceLanguage == .turkish }) { Text("\($0.name) (\($0.qualityLabel))").tag($0.id) }
                }
                Picker("English voice", selection: $prefs.voiceEnglishVoice) {
                    Text("Automatic").tag("")
                    ForEach(voices.filter { $0.voiceLanguage == .english }) { Text("\($0.name) (\($0.qualityLabel))").tag($0.id) }
                }
                HStack {
                    Text("Speech rate")
                    Slider(value: $prefs.voiceSpeechRate, in: 0.7...1.4, step: 0.05)
                    Text(String(format: "%.2f×", prefs.voiceSpeechRate)).font(.system(.caption, design: .monospaced))
                }
                HStack {
                    Button("Test Turkish") { voice.speakSample(.turkish) }
                    Button("Test English") { voice.speakSample(.english) }
                    Button("Stop") { voice.stopSpeaking() }
                }
                Text("Voices are the ones installed on this Mac (System Settings → Accessibility → Spoken Content can add higher-quality ones). Long answers are summarised by speaking only the first few sentences; code and tables are never read out. Spoken replies come from the same answer shown on screen.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Saying “approve” or “yes” never approves anything: approvals are HUD buttons only.").font(.caption).foregroundStyle(.secondary)

                if prefs.showDeveloperControls {
                    DisclosureGroup("Voice diagnostics") {
                        mono("state \(voice.state.label) · turns \(voice.turns) · helper \(app.whisper.state.label)")
                        if let rss = app.whisper.workerResidentBytes { mono("helper memory \(rss / 1_048_576) MB (not part of JARVIS' own memory)") }
                        if let m = voice.lastMetrics { mono(Self.describe(m)) }
                    }
                }
            }
        }
        .task { await voice.refreshProviders() }
    }

    static func describe(_ m: VoiceTurnMetrics) -> String {
        func ms(_ v: Double?) -> String { v.map { "\(Int($0 * 1000)) ms" } ?? "–" }
        return "stt \(m.sttProvider ?? "–") (\(m.language ?? "–")) · audio \(m.audioSeconds.map { String(format: "%.1f s", $0) } ?? "–") · start \(ms(m.sttStartup)) · first partial \(ms(m.firstPartial)) · final \(ms(m.sttFinalization)) · text→TTS \(ms(m.firstTextToSynthesis)) · TTS→audio \(ms(m.synthesisToFirstAudio)) · release→audio \(ms(m.releaseToFirstAudio)) · \(m.outcome ?? "–")"
    }
}
