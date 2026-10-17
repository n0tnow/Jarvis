import SwiftUI

/// Settings → Voice → “Hands-free overview” (V1.0 stabilisation fix 2): ONE place that says, truthfully and at a glance, what the voice system is doing now — including that the microphone is in use
/// locally while the wake detector runs. Pure data: the view only renders it, so the wording and the state mapping are unit-tested.
struct VoiceStatusRow: Identifiable, Equatable {
    enum Tone: Equatable { case good, neutral, warning }
    var id: String
    var title: String
    var value: String
    var tone: Tone
    var detail: String? = nil
}

enum VoiceStatusRows {
    struct Input {
        var voiceEnabled: Bool
        var pushToTalkEnabled: Bool
        var pttMonitorRunning: Bool
        var pttHandlerAttached: Bool
        var wakeEnabled: Bool
        var wakeStatus: WakeStatus
        var sleeping: Bool
        var microphone: MicrophonePermission
        var sttReason: String
        var ttsReason: String
        var sessionLabel: String
    }

    static func detectorLabel(_ status: WakeStatus, wakeEnabled: Bool) -> (String, VoiceStatusRow.Tone, String?) {
        switch status {
        case .listening: return ("RUNNING", .good, nil)
        case .starting: return ("STARTING", .neutral, nil)
        case .paused: return ("PAUSED · SLEEP MODE", .neutral, "Paused by “Uyku moduna geç”. The Wake Word setting is unchanged.")
        case .unavailable(let why): return ("ERROR", .warning, why)
        case .off: return ("STOPPED", wakeEnabled ? .warning : .neutral, wakeEnabled ? "Wake Word is on but the detector is not running." : nil)
        }
    }

    static func rows(_ i: Input) -> [VoiceStatusRow] {
        var out: [VoiceStatusRow] = []
        out.append(.init(id: "voice", title: "Voice", value: i.voiceEnabled ? "ON" : "OFF", tone: i.voiceEnabled ? .good : .neutral,
                         detail: i.voiceEnabled ? nil : "Voice is OFF: no microphone is used and Push-to-Talk and the wake word do nothing."))
        let ptt: (String, VoiceStatusRow.Tone) = !i.pushToTalkEnabled ? ("OFF", .neutral)
            : (!i.voiceEnabled ? ("ON · VOICE IS OFF", .warning) : (i.pttMonitorRunning && i.pttHandlerAttached ? ("ON · HOLD RIGHT ⌥", .good) : ("ON · KEY MONITOR NOT RUNNING", .warning)))
        out.append(.init(id: "ptt", title: "Push-to-Talk", value: ptt.0, tone: ptt.1))
        out.append(.init(id: "wake", title: "Wake Word “Jarvis”", value: i.wakeEnabled ? "ON" : "OFF", tone: i.wakeEnabled ? .good : .neutral,
                         detail: i.wakeEnabled ? nil : "OFF by default. You switch it on here, in the menu bar, or by saying “wake word'ü aç”."))
        let d = detectorLabel(i.sleeping && i.wakeStatus != .listening ? .paused : i.wakeStatus, wakeEnabled: i.wakeEnabled && i.voiceEnabled)
        out.append(.init(id: "detector", title: "Wake detector", value: d.0, tone: d.1, detail: d.2))
        let micTone: VoiceStatusRow.Tone = i.microphone == .granted ? .good : (i.microphone == .notDetermined ? .neutral : .warning)
        let micDetail: String?
        if i.wakeStatus == .listening { micDetail = "In use now by the local wake detector. Audio stays in memory for a second or two and is overwritten; nothing is transcribed, saved or sent before you say “Jarvis”." }
        else if i.voiceEnabled && i.pushToTalkEnabled { micDetail = "Closed. It opens only while you hold the Push-to-Talk key." }
        else { micDetail = "Closed." }
        out.append(.init(id: "mic", title: "Microphone", value: i.microphone.label, tone: micTone, detail: micDetail))
        out.append(.init(id: "stt", title: "Speech recognition", value: shortProvider(i.sttReason), tone: .neutral, detail: nil))
        out.append(.init(id: "tts", title: "Speech output", value: shortProvider(i.ttsReason), tone: .neutral, detail: nil))
        out.append(.init(id: "session", title: "Hands-free session", value: i.sessionLabel, tone: .neutral, detail: nil))
        return out
    }

    private static func shortProvider(_ reason: String) -> String { reason.count > 60 ? String(reason.prefix(58)) + "…" : reason }
}

struct VoiceStatusBlock: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        let d = app.hotkeyDiagnostics?() ?? GlobalHotkeyService.TalkDiagnostics()
        let rows = VoiceStatusRows.rows(.init(
            voiceEnabled: app.preferences.voiceEnabled, pushToTalkEnabled: app.preferences.voicePushToTalk, pttMonitorRunning: d.monitorRunning, pttHandlerAttached: d.handlerAttached,
            wakeEnabled: app.preferences.voiceWakeEnabled, wakeStatus: app.handsFree.wakeStatus, sleeping: app.handsFree.isSleepingByUser,
            microphone: app.voice.permission, sttReason: app.voice.sttChoice.reason, ttsReason: app.voice.ttsChoice.reason, sessionLabel: app.handsFree.state.label))
        DisclosureGroup("Hands-free overview", isExpanded: .constant(true)) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 1) {
                    LabeledContent(row.title) {
                        Text(row.value).font(.system(.caption, design: .monospaced))
                            .foregroundStyle(row.tone == .good ? Color.green : (row.tone == .warning ? Color.orange : Color.secondary))
                    }
                    if let detail = row.detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
        .accessibilityIdentifier("settings.voiceOverview")
    }
}
