import SwiftUI

/// Single-line command input. Submits to `ConversationService` (deterministic router in V0.2; no AI, no network).
struct CommandField: View {
    @Environment(AppContext.self) private var app
    @Binding var text: String
    var placeholder = "Type a command…"
    var origin: InputOrigin = .fullHUD
    /// Shown in place of the placeholder while the field is empty: the latest JARVIS reply, one line,
    /// tail-truncated with "…" (full text on hover). Never changes the field's size.
    var feedback: String? = nil
    /// Becomes true when the surface appears → focus the field so typing works immediately.
    var focusTrigger = false
    @FocusState private var focused: Bool
    /// Called when ESC is pressed with an empty field (dismiss the surface).
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.Palette.accent)
                .accessibilityHidden(true)

            TextField(text: $text, prompt: promptText) { Text("Command") }
                .textFieldStyle(.plain)
                .overlay(alignment: .leading) { feedbackOverlay }
                .focused($focused)
                .onChange(of: focusTrigger) { _, now in if now { DispatchQueue.main.async { focused = true } } }
                .font(Theme.Typography.body)
                .foregroundStyle(Color.jarvisPrimary)
                .onSubmit(submit)
                .onExitCommand {
                    if text.isEmpty { onCancel() } else { text = "" }
                }
                .accessibilityLabel("Command input")
                .accessibilityIdentifier("command.field")
                .accessibilityHint("Type a command and press Return. Replies appear in the conversation and are announced.")

            Button(action: submit) {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(text.isEmpty ? Color.jarvisTertiary : Theme.Palette.accent)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
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

    private var showsFeedback: Bool { feedback != nil && text.isEmpty }

    /// With feedback showing, the native prompt is blank and this overlay draws the line (tail ellipsis, no hit testing).
    private var promptText: Text {
        showsFeedback ? Text("") : Text(placeholder).foregroundColor(Color.white.opacity(Theme.Opacity.textTertiary))
    }

    @ViewBuilder
    private var feedbackOverlay: some View {
        if showsFeedback, let feedback {
            Text("Jarvis: \(feedback)")
                .font(Theme.Typography.body)
                .foregroundStyle(Color.jarvisSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
                .help(feedback)
                .accessibilityHidden(true)   // announced via VoiceOver when it arrives
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { text = ""; return }   // whitespace-only: clear it so ESC still dismisses
        app.conversationService.submit(trimmed, origin: origin)
        text = ""
        focused = true
    }
}
