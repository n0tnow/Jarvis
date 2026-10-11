import SwiftUI

/// Restrained provider status in the Conversation header: which provider answers, or THINKING + STOP GENERATION.
struct ProviderBadge: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        let service = app.conversationService!
        let providers = app.providers
        HStack(spacing: Theme.Spacing.s) {
            if service.isResponding {
                Tag(text: "THINKING · \(service.respondingProviderName?.uppercased() ?? "PROVIDER")", tint: Theme.Palette.violet)
                Button { service.cancelCurrentResponse() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill").font(.system(size: 8.5, weight: .bold))
                        Text("STOP GENERATION").font(.system(size: 10.5, weight: .semibold, design: .monospaced)).tracking(0.6)
                    }
                    .foregroundStyle(Theme.Palette.coral)
                    .padding(.horizontal, 7).padding(.vertical, 2.5)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.Palette.coral.opacity(0.7), lineWidth: 0.8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(".", modifiers: .command)
                .accessibilityLabel("Stop generation")
                .accessibilityHint("Stops the current answer and ends the provider process")
                .accessibilityIdentifier("conversation.stop")
            } else if let selected = providers.selectedProvider {
                Tag(text: "\(selected.shortName) · \(providers.status(selected).state.label)", tint: Theme.Palette.mint)
            } else {
                Tag(text: providers.lastRefresh == nil ? "CHECKING PROVIDERS" : "NO PROVIDER READY", tint: Theme.Palette.amber)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
