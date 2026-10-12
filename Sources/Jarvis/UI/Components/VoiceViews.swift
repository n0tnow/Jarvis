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

/// A restrained state pill — icon + words, never colour alone. Shown only while a voice session is doing something.
struct VoiceStateChip: View {
    let state: VoiceSessionState
    var body: some View { StatusChip(text: state.label, symbol: state.symbolName, tint: state.tint) }
}

/// Compact HUD: voice state + Stop Speaking, placed inside the existing state row (no size change).
struct CompactVoiceIndicator: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        let voice = app.voice
        // The core/state chip already says LISTENING while the microphone is open: do not repeat it.
        if voice.state != .idle && !(voice.state == .listening && app.store.state == .listening) {
            HStack(spacing: Theme.Spacing.xs) {
                VoiceStateChip(state: voice.state.isError ? .error("") : voice.state)
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
            .accessibilityLabel(voice.state.spokenLabel)
        }
    }
}

/// Full HUD: a single quiet row above the conversation — state, the provisional transcript while listening, a level bar, Stop Speaking.
struct VoiceStrip: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        let voice = app.voice
        if voice.state != .idle || !voice.partialTranscript.isEmpty {
            HStack(spacing: Theme.Spacing.s) {
                VoiceStateChip(state: voice.state.isError ? .error("") : voice.state)
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
                }
                Spacer(minLength: 0)
                if voice.state == .speaking || voice.speaker.isActive {
                    Button("STOP SPEAKING") { voice.stopSpeaking() }
                        .buttonStyle(.hudSecondary)
                        .accessibilityIdentifier("voice.stopSpeaking")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(voice.state.spokenLabel)
        }
    }
}
