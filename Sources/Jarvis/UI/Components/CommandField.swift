import SwiftUI

/// Single-line command input. In V0.1 it only talks to `LocalCommandHandler` (no AI).
struct CommandField: View {
    @Environment(AppContext.self) private var app
    @Binding var text: String
    var placeholder = "Type a command…"
    /// Called when ESC is pressed with an empty field (dismiss the surface).
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.Palette.accent)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .foregroundStyle(Color.jarvisPrimary)
                .onSubmit(submit)
                .onExitCommand {
                    if text.isEmpty { onCancel() } else { text = "" }
                }
                .accessibilityLabel("Command input")
                .accessibilityIdentifier("command.field")
                .accessibilityHint("Type a command and press Return. V0.1 stores it locally; no AI is connected.")

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

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        app.commands.submit(trimmed)
        text = ""
    }
}
