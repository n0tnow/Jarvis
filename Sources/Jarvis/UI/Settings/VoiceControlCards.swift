import SwiftUI

/// The first thing Settings → Voice shows: the three switches (Voice, Push-to-Talk, Wake Word) with the REAL state next to each, then the one-glance overview of everything the voice system is doing.
/// A switch is never a claim: the badge beside it is read from the detector / the key monitor / the microphone permission.
struct VoiceControlCards: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        @Bindable var prefs = app.preferences
        let hf = app.handsFree
        let d = app.hotkeyDiagnostics?() ?? GlobalHotkeyService.TalkDiagnostics()
        VStack(alignment: .leading, spacing: Theme.Grid.rowGap) {
            Card("Voice") {
                VStack(spacing: Theme.Spacing.l) {
                    ToggleRow(title: "Voice input", detail: "Master switch. Off: no microphone is used, and Push-to-Talk and the wake word do nothing.",
                              isOn: Binding(get: { prefs.voiceEnabled }, set: { on in prefs.voiceEnabled = on; Task { await app.handsFree.applySettings(); app.readiness.refresh() } }),
                              badge: prefs.voiceEnabled ? .running : .off, id: "settings.voiceEnabled")
                    Divider().opacity(0.3)
                    ToggleRow(title: "Push-to-Talk (hold the right ⌥ key)", detail: "The microphone opens only while the key is held and closes when you let go. Needs no macOS permission of its own; the microphone permission is asked once.",
                              isOn: $prefs.voicePushToTalk,
                              badge: !prefs.voicePushToTalk ? .off : (!prefs.voiceEnabled ? .attention : ((d.monitorRunning && d.handlerAttached) ? .ready : .error)),
                              badgeText: !prefs.voicePushToTalk ? "OFF" : (!prefs.voiceEnabled ? "VOICE IS OFF" : ((d.monitorRunning && d.handlerAttached) ? "KEY MONITOR ACTIVE" : "KEY MONITOR NOT RUNNING")), id: "settings.pushToTalk")
                    Divider().opacity(0.3)
                    ToggleRow(title: "Wake Word “Jarvis” (hands-free)",
                              detail: "Off by default. When on, a small detector on this Mac listens for the word; before it hears it nothing is transcribed, stored or sent anywhere. Then JARVIS says “Efendim?” and listens without any key. Wake is an activation, not a login: approvals still need the HUD buttons.",
                              isOn: Binding(get: { prefs.voiceWakeEnabled }, set: { on in
                                  prefs.voiceWakeEnabled = on
                                  if on, !prefs.voiceEnabled { prefs.voiceEnabled = true }          // turning the wake word on is an explicit request to use voice
                                  Task { await app.handsFree.applySettings(); app.readiness.refresh() }
                              }),
                              badge: Self.detectorKind(prefs.voiceWakeEnabled, hf.wakeStatus), badgeText: Self.detectorText(prefs.voiceWakeEnabled, hf.wakeStatus), id: "settings.wakeEnabled")
                    if prefs.voiceWakeEnabled, case .unavailable(let why) = hf.wakeStatus {
                        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                            Text("The detector could not start: \(why). Push-to-Talk still works.").font(Theme.Typography.meta).foregroundStyle(Theme.Palette.amber)
                            HStack {
                                if app.voice.permission == .notDetermined { Button("Allow microphone…") { Task { await app.voice.requestMicrophoneFromSettings(); await app.handsFree.applySettings(); app.readiness.refresh() } }.buttonStyle(.hudSecondary).fixedSize() }
                                if app.voice.permission == .denied || app.voice.permission == .restricted { Button("Open Microphone Settings") { PrivacySettingsPane.microphone.open() }.buttonStyle(.hudSecondary).fixedSize() }
                                Button("Recheck") { Task { await ReadinessActions.recheck(app) } }.buttonStyle(.hudSecondary).fixedSize()
                            }
                        }
                    }
                    if prefs.voiceWakeEnabled {
                        Divider().opacity(0.3)
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("When I say “Jarvis”").font(Theme.Typography.rowTitle).foregroundStyle(Color.jarvisPrimary)
                                Text("Voice says “Efendim?” / “Yes?” (a fixed phrase, no model). Sound is a short soft tone; Off acknowledges on screen only.").font(Theme.Typography.meta).foregroundStyle(Color.jarvisTertiary)
                            }
                            Spacer()
                            Picker("", selection: $prefs.voiceWakeAcknowledgement) { ForEach(WakeAcknowledgement.allCases, id: \.self) { Text($0.label).tag($0) } }
                                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                        }
                        ToggleRow(title: "Let me interrupt JARVIS by speaking", detail: "While JARVIS speaks, your voice stops the speech and starts a new turn. There is no echo canceller: a very quiet voice or a very loud speaker may not interrupt; Push-to-Talk and Stop Speaking always work.",
                                  isOn: $prefs.voiceBargeIn, badge: nil, id: "settings.bargeIn")
                    }
                }
            }
            Card("Hands-free overview", trailing: { Text("read from the system, not from the switches").font(Theme.Typography.meta).foregroundStyle(Color.jarvisTertiary) }) {
                let rows = VoiceStatusRows.rows(.init(
                    voiceEnabled: prefs.voiceEnabled, pushToTalkEnabled: prefs.voicePushToTalk, pttMonitorRunning: d.monitorRunning, pttHandlerAttached: d.handlerAttached,
                    wakeEnabled: prefs.voiceWakeEnabled, wakeStatus: hf.wakeStatus, sleeping: hf.isSleepingByUser,
                    microphone: app.voice.permission, sttReason: app.voice.sttChoice.reason, ttsReason: app.voice.ttsChoice.reason, sessionLabel: hf.state.label))
                VStack(spacing: Theme.Spacing.m) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.title).font(Theme.Typography.rowTitle).foregroundStyle(Color.jarvisPrimary)
                                Spacer(minLength: Theme.Spacing.m)
                                Text(row.value).font(Theme.Typography.meta).foregroundStyle(row.tone == .good ? Theme.Palette.mint : (row.tone == .warning ? Theme.Palette.amber : Color.jarvisSecondary)).multilineTextAlignment(.trailing).textSelection(.enabled)
                            }
                            if let detail = row.detail { Text(detail).font(Theme.Typography.meta).foregroundStyle(Color.jarvisTertiary).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("settings.voiceCards")
    }

    static func detectorKind(_ on: Bool, _ s: WakeStatus) -> StatusKind {
        guard on else { return .off }
        switch s { case .listening: return .running; case .starting: return .notChecked; case .paused: return .notRunning; case .off: return .error; case .unavailable: return .error }
    }
    static func detectorText(_ on: Bool, _ s: WakeStatus) -> String {
        guard on else { return "OFF" }
        switch s { case .listening: return "DETECTOR RUNNING"; case .starting: return "STARTING"; case .paused: return "PAUSED"; case .off: return "DETECTOR STOPPED"; case .unavailable: return "ERROR" }
    }

    private struct ToggleRow: View {
        let title: String
        let detail: String
        @Binding var isOn: Bool
        var badge: StatusKind?
        var badgeText: String?
        let id: String
        var body: some View {
            HStack(alignment: .top, spacing: Theme.Spacing.l) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.Typography.rowTitle).foregroundStyle(Color.jarvisPrimary)
                    Text(detail).font(Theme.Typography.meta).foregroundStyle(Color.jarvisTertiary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Spacing.m)
                if let badge { StatusBadge(kind: badge, text: badgeText) }
                Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().accessibilityLabel(title).accessibilityIdentifier(id)
            }
        }
    }
}
