import SwiftUI

extension VoiceSessionState {
    var symbolName: String {
        switch self {
        case .idle: "mic.slash"
        case .requestingPermission: "lock.shield"
        case .listening: "mic.fill"
        case .transcribing: "text.bubble"
        case .thinking: "ellipsis.circle"
        case .speaking: "speaker.wave.2.fill"
        case .error: "exclamationmark.triangle"
        }
    }
    var tint: Color {
        switch self {
        case .idle: Color.jarvisSecondary
        case .listening: Theme.Palette.coral
        case .speaking: Theme.Palette.mint
        case .error: Theme.Palette.amber
        default: Theme.Palette.accent
        }
    }
    /// VoiceOver wording (states, never partial transcripts).
    var spokenLabel: String {
        switch self {
        case .idle: "Voice idle"
        case .requestingPermission: "Waiting for microphone permission"
        case .listening: "Listening"
        case .transcribing: "Transcribing"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .error(let m): "Voice problem. \(m)"
        }
    }
}

extension VoicePresence {
    var symbolName: String {
        switch self {
        case .off: "mic.slash"
        case .wake: "ear"
        case .attentive: "waveform.badge.mic"
        case .listening: "mic.fill"
        case .transcribing: "text.bubble"
        case .thinking: "ellipsis.circle"
        case .speaking: "speaker.wave.2.fill"
        case .interrupted: "hand.raised.fill"
        case .error: "exclamationmark.triangle"
        }
    }
    var tint: Color {
        switch self {
        case .off: Color.jarvisSecondary
        case .wake: Theme.Palette.accent.opacity(0.8)
        case .listening, .attentive: Theme.Palette.coral
        case .speaking: Theme.Palette.mint
        case .interrupted, .error: Theme.Palette.amber
        default: Theme.Palette.accent
        }
    }
    /// VoiceOver wording: states only (never VAD transitions, never partial transcripts).
    var spokenLabel: String {
        switch self {
        case .off: "Voice off"
        case .wake: "Wake mode on, listening for Jarvis"
        case .attentive: "Jarvis is listening for you"
        case .listening: "Listening"
        case .transcribing: "Transcribing"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .interrupted: "Interrupted"
        case .error(let m): "Voice problem. \(m)"
        }
    }
    var isQuiet: Bool { self == .off }
}

/// A restrained state pill — icon + words, never colour alone. Shown only while a voice session is doing something.
struct VoiceStateChip: View {
    let state: VoiceSessionState
    var body: some View { StatusChip(text: state.label, symbol: state.symbolName, tint: state.tint) }
}

struct VoicePresenceChip: View {
    let presence: VoicePresence
    var body: some View { StatusChip(text: presence.label, symbol: presence.symbolName, tint: presence.tint) }
}

/// Compact HUD: voice presence + Stop Speaking, placed inside the existing state row (no size change). Wake mode shows a small WAKE chip so the
/// "microphone is being watched by the local wake detector" state is never invisible; it does not look like LISTENING (which means a conversation turn).
struct CompactVoiceIndicator: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        let voice = app.voice
        let presence = app.handsFree.presence
        // The core/state chip already says LISTENING while the microphone is open: do not repeat it.
        if !presence.isQuiet && !(presence == .listening && app.store.state == .listening) {
            HStack(spacing: Theme.Spacing.xs) {
                VoicePresenceChip(presence: presence)
                if voice.state == .speaking || voice.speaker.isActive {
                    Button { voice.stopSpeaking() } label: { Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Palette.coral)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Stop speaking")
                        .accessibilityIdentifier("voice.stopSpeaking")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(presence.spokenLabel)
        }
    }
}

/// Full HUD: a single quiet row above the conversation — state, the provisional transcript while listening, a level bar, Stop Speaking.
struct VoiceStrip: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        let voice = app.voice
        let presence = app.handsFree.presence
        if !presence.isQuiet || !voice.partialTranscript.isEmpty {
            HStack(spacing: Theme.Spacing.s) {
                VoicePresenceChip(presence: presence)
                if voice.state == .listening {
                    // A plain level bar: no animation, nothing to reduce; it updates at most 10 times per second.
                    GeometryReader { g in
                        Capsule().fill(Color.white.opacity(0.10))
                            .overlay(alignment: .leading) { Capsule().fill(Theme.Palette.coral).frame(width: max(3, g.size.width * CGFloat(voice.level))) }
                    }
                    .frame(width: 64, height: 5)
                    .accessibilityHidden(true)
                }
                if !voice.partialTranscript.isEmpty {
                    Text("“\(voice.partialTranscript)”")
                        .font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary)
                        .lineLimit(1).truncationMode(.head)
                        .accessibilityHidden(true)                       // partials change constantly: not announced
                } else if case .error(let m) = voice.state {
                    Text(m).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.amber).lineLimit(2)
                } else if presence == .wake {
                    Text("Say “Jarvis” — wake word detected locally; nothing is transcribed or kept until then.")
                        .font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary).lineLimit(1)
                } else if presence == .attentive {
                    Text("Go ahead — I’m listening.").font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let line = app.handsFree.latencySummary, presence == .wake || presence == .attentive {
                    Text(line).font(.system(.caption2, design: .monospaced)).foregroundStyle(Color.jarvisSecondary).lineLimit(1).accessibilityHidden(true)
                }
                if voice.state == .speaking || voice.speaker.isActive {
                    Button("STOP SPEAKING") { voice.stopSpeaking() }
                        .buttonStyle(.hudSecondary)
                        .accessibilityIdentifier("voice.stopSpeaking")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(presence.spokenLabel)
        }
    }
}
