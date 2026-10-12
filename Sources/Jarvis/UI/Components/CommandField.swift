import SwiftUI

/// Command input. Submits to `ConversationService` (deterministic router; provider-backed answers in V0.3).
/// Built on the native `ComposerField` (NSTextView): real clipboard/undo/IME behaviour, multiline, bounded height.
struct CommandField: View {
    @Environment(AppContext.self) private var app
    @Binding var text: String
    var placeholder = "Type a command…"
    var origin: InputOrigin = .fullHUD
    /// Shown in place of the placeholder while the field is empty: the latest JARVIS reply, one line,
    /// tail-truncated with "…" (full text on hover). Never changes the field's size.
    var feedback: String? = nil
    /// V0.7: while Push-to-Talk is active, the (provisional) transcript or "Listening…" is shown here instead of the placeholder.
    var voiceLine: String? = nil
    /// Becomes true when the surface appears → focus the composer so typing/pasting works immediately.
    var focusTrigger = false
    /// 1 = fixed single line with internal scrolling (Compact HUD, which must never resize); more = grows to that many lines.
    var maxLines = 1
    /// Called when ESC is pressed with an empty field (dismiss the surface).
    var onCancel: () -> Void

    @State private var composerHeight: CGFloat = ComposerField.lineHeight

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.Palette.accent)
                .frame(height: ComposerField.lineHeight)
                .accessibilityHidden(true)

            ComposerField(text: $text, maxLines: maxLines, focusTrigger: focusTrigger,
                          onSubmit: submit, onEscape: onCancel, height: $composerHeight)
                .frame(height: maxLines == 1 ? ComposerField.lineHeight : composerHeight)
                .overlay(alignment: .topLeading) { overlayText }

            Button(action: submit) {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(text.isEmpty ? Color.jarvisTertiary : Theme.Palette.accent)
                    .frame(width: 24, height: ComposerField.lineHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Submit command")
            .accessibilityIdentifier("command.submit")
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s + 2)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .fill(Color.black.opacity(0.28))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .strokeBorder(Color.white.opacity(Theme.Opacity.stroke), lineWidth: 0.8)
        )
    }

    /// Placeholder, or the latest reply as one tail-truncated line, drawn over the empty composer (no hit testing).
    @ViewBuilder
    private var overlayText: some View {
        if text.isEmpty {
            if let voiceLine {
                HStack(spacing: 4) {
                    Image(systemName: "mic.fill").font(.system(size: 10)).foregroundStyle(Theme.Palette.coral).accessibilityHidden(true)
                    Text(voiceLine).font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary).lineLimit(1).truncationMode(.head)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false).accessibilityHidden(true)
            } else if let feedback {
                Text("Jarvis: \(feedback)")
                    .font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false).help(feedback).accessibilityHidden(true)
            } else {
                Text(placeholder)
                    .font(Theme.Typography.body).foregroundStyle(Color.jarvisTertiary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { text = ""; return }   // whitespace-only: clear it so ESC still dismisses
        app.conversationService.submit(trimmed, origin: origin)
        text = ""
    }
}
