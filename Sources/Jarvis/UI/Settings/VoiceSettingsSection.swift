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
            VoiceStatusBlock()
            if prefs.voiceEnabled {
                Toggle("Push-to-Talk shortcut", isOn: $prefs.voicePushToTalk)
                LabeledContent("Shortcut") { Text("hold right ⌥").font(.system(size: 14, weight: .medium, design: .rounded)) }
                Text("Hold the RIGHT Option key by itself for a moment, speak, release. Typing Option characters, ⌥⌘ shortcuts, Shift or Control combinations never start it. Needs no macOS permission of its own.")
                    .font(.caption).foregroundStyle(.secondary)

                pushToTalkMonitorRow()
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
                Text("Both recognisers run on this Mac: no network, no API key, no cost. Whisper is more accurate (especially Turkish and technical words) but needs a one-time ≈460 MB download (Set Up in System & Readiness) and about 0.9 GB of memory while loaded (it unloads itself when idle or when memory is tight). Apple Speech needs no setup beyond its own language model.")
                    .font(.caption).foregroundStyle(.secondary)

                wakeSection(prefs: prefs)
                jarvisVoiceSection(prefs: prefs)

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

                if prefs.showDeveloperControls { diagnostics(prefs: prefs) }
            }
        }
        .task { await voice.refreshProviders() }
    }

    // MARK: Push-to-Talk key monitor (V1.0 stabilisation)

    @ViewBuilder
    private func pushToTalkMonitorRow() -> some View {
        let d = app.hotkeyDiagnostics?() ?? GlobalHotkeyService.TalkDiagnostics()
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent("Push-to-Talk key monitor") { mono(d.monitorRunning && d.handlerAttached ? "ACTIVE" : (d.monitorRunning ? "RUNNING · NO HANDLER" : "NOT RUNNING"), d.monitorRunning && d.handlerAttached ? .green : .orange) }
            mono("last key event: \(d.lastEvent)\(d.lastEventAt.map { " · " + $0.formatted(date: .omitted, time: .standard) } ?? "") · right ⌥ seen \(d.rightOptionPresses)×")
            Text("Reopen Settings to refresh this line. It records only whether the right ⌥ key went down or up — never other keys, typed text or audio.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Wake word (V0.8)

    @ViewBuilder
    private func wakeSection(prefs: Preferences) -> some View {
        @Bindable var prefs = prefs
        let hf = app.handsFree
        Divider()
        Toggle("Wake word “Jarvis” (hands-free)", isOn: $prefs.voiceWakeEnabled).accessibilityIdentifier("settings.wakeEnabled")
        Text("OFF by default. When on, a small detector on this Mac listens for the word “Jarvis”; before it hears it nothing is transcribed, stored, or sent anywhere (audio stays in memory for a second or two and is overwritten). After the word JARVIS listens for you, then returns to wake-only listening. Wake detection is only an activation: it does not know who is speaking and gives voice no extra authority — approvals still need the HUD buttons. Push-to-Talk keeps working either way.")
            .font(.caption).foregroundStyle(.secondary)
        if prefs.voiceWakeEnabled {
            LabeledContent("Wake mode") { mono(hf.wakeStatus.label, hf.wakeStatus == .listening ? .green : (hf.wakeStatus == .starting ? .secondary : .orange)) }
            if case .unavailable(let why) = hf.wakeStatus {
                Text("Wake mode is unavailable: \(why). Push-to-Talk still works.").font(.caption).foregroundStyle(.orange)
                if app.voice.permission == .notDetermined {
                    Button("Allow microphone…") { Task { await app.voice.requestMicrophoneFromSettings(); await app.handsFree.applySettings() } }
                }
                if case .notInstalled = app.sentinel.state {
                    Text("Install the local wake-word helper once: press Set Up Natural Voice in System & Readiness (≈ 0.2 GB runtime, models from pinned releases; JARVIS never downloads anything itself).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Picker("When I say “Jarvis”", selection: $prefs.voiceWakeAcknowledgement) {
                ForEach(WakeAcknowledgement.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Text("Voice is the default: JARVIS says “Efendim?” / “Yes?” (a fixed phrase — no model is involved), then listens without any key. Sound is a short soft tone with no speech and no delay; Off acknowledges only on screen. JARVIS’ own acknowledgement reaching the microphone is handled (the detector ignores it).")
                .font(.caption2).foregroundStyle(.secondary)
            Toggle("Let me interrupt JARVIS by speaking", isOn: $prefs.voiceBargeIn)
            Text("While JARVIS speaks, your voice (clearly louder than JARVIS’ own voice reaching the microphone) stops the speech and starts a new turn. There is no echo canceller: a very quiet voice or a very loud speaker volume may not interrupt; Push-to-Talk and Stop Speaking always work.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: JARVIS voice (V0.8)

    @ViewBuilder
    private func jarvisVoiceSection(prefs: Preferences) -> some View {
        @Bindable var prefs = prefs
        let voice = app.voice
        let neural = app.neuralVoice
        Divider()
        Picker("JARVIS voice", selection: $prefs.voicePreset) {
            ForEach(JarvisVoicePreset.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Text(prefs.voicePreset.summary).font(.caption2).foregroundStyle(.secondary)
        LabeledContent("Neural voice") { mono(neural.state.label, neural.state == .running || neural.state == .idle ? .green : .orange) }
        if case .notInstalled = neural.state {
            Text("Not installed — JARVIS speaks with the Apple system voice until you install it: press Set Up Natural Voice in System & Readiness (≈ 0.4 GB model, local, no account, no API key, no cost).")
                .font(.caption2).foregroundStyle(.secondary)
        }
        Text("Using: \(voice.ttsChoice.reason)").font(.caption).foregroundStyle(.secondary)
        HStack {
            Text("Hear it").font(.caption)
            ForEach(JarvisVoicePreset.allCases, id: \.self) { preset in
                Menu(preset.label) {
                    Button("Turkish — “Efendim? Sistemler hazır.”") { voice.previewVoice(preset, language: .turkish) }
                    Button("English — “Yes? All systems are ready.”") { voice.previewVoice(preset, language: .english) }
                }.menuStyle(.borderlessButton).fixedSize()
            }
            Button("Stop") { voice.stopSpeaking() }
        }
        Text("The JARVIS voice is an original voice identity (calm, composed, medium-low, restrained) rendered by a local neural model — it does not imitate any actor, performer or person. How natural it sounds is your call: compare it with System Fallback and tell the project. The preview speaks a fixed phrase and starts no conversation.")
            .font(.caption2).foregroundStyle(.secondary)
    }

    // MARK: Diagnostics / voice lab (developer controls only)

    @ViewBuilder
    private func diagnostics(prefs: Preferences) -> some View {
        let voice = app.voice
        let hf = app.handsFree
        DisclosureGroup("Voice diagnostics · voice lab") {
            mono("state \(voice.state.label) · turn manager \(hf.state.label) · wake \(hf.wakeStatus.label) · turns \(voice.turns) · wakes \(hf.wakeCount) · barge-ins \(hf.bargeInCount)")
            mono("mic level \(String(format: "%.2f", hf.level)) · VAD \(app.sentinel.vadSpeech ? "SPEECH" : "quiet") · hub subscribers \(app.micHub.subscriberLabels.joined(separator: ","))")
            mono("STT helper \(app.whisper.state.label)\(app.whisper.workerResidentBytes.map { " · \($0 / 1_048_576) MB" } ?? "") · wake helper \(app.sentinel.state.label)\(app.sentinel.host.residentBytes.map { " · \($0 / 1_048_576) MB" } ?? "") · neural \(app.neuralVoice.state.label)\(app.neuralVoice.host.residentBytes.map { " · \($0 / 1_048_576) MB" } ?? "")")
            mono("(helper memory is not part of JARVIS' own memory)")
            let sm = app.sentinel.metrics
            mono("sentinel: \(String(format: "%.0f", sm.secondsSent)) s of audio sent · wake events \(sm.wakeEvents) · last score \(sm.lastWakeScore.map { String(format: "%.2f", $0) } ?? "–") · VAD transitions \(sm.vadTransitions)")
            if let line = hf.latencySummary { mono("last natural turn: \(line)") }
            let nm = app.neuralVoice.metrics
            mono("neural: \(nm.phrases) phrases · first block \(nm.lastFirstBlockSeconds.map { "\(Int($0 * 1000)) ms" } ?? "–") · RTF \(nm.realTimeFactor.map { String(format: "%.2f", $0) } ?? "–") · load \(nm.loadSeconds.map { String(format: "%.1f s", $0) } ?? "–")")
            if let m = voice.lastMetrics { mono(Self.describe(m)) }
            if !voice.partialTranscript.isEmpty { mono("partial (provisional): “\(voice.partialTranscript)”") }
        }
    }

    static func describe(_ m: VoiceTurnMetrics) -> String {
        func ms(_ v: Double?) -> String { v.map { "\(Int($0 * 1000)) ms" } ?? "–" }
        return "stt \(m.sttProvider ?? "–") (\(m.language ?? "–")) · audio \(m.audioSeconds.map { String(format: "%.1f s", $0) } ?? "–") · start \(ms(m.sttStartup)) · first partial \(ms(m.firstPartial)) · final \(ms(m.sttFinalization)) · text→TTS \(ms(m.firstTextToSynthesis)) · TTS→audio \(ms(m.synthesisToFirstAudio)) · release→audio \(ms(m.releaseToFirstAudio)) · \(m.outcome ?? "–")"
    }
}
