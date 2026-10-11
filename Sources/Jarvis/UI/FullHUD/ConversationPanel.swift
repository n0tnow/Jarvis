import SwiftUI

/// Command history / system dialogue — deliberately NOT a chat app: no bubbles, monospaced role markers,
/// thin rows, newest at the bottom. Rendering is bounded (last `visibleLimit` messages).
struct ConversationPanel: View {
    @Environment(AppContext.self) private var app
    static let visibleLimit = 60

    var body: some View {
        let messages = Array(app.conversation.messages.suffix(Self.visibleLimit))
        HUDCard("Conversation", trailing: { ProviderBadge() }) {
            if messages.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Type below. Try “open the report”, “what are you doing?” or “pause the task”.")
                        .font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary)
                        .fixedSize(horizontal: false, vertical: true)   // wrap instead of forcing a wide centre column
                    Text("Türkçe de olur: “raporu aç”, “görevleri göster”.")
                        .font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        // Plain VStack (bounded to `visibleLimit` rows): LazyVStack mis-estimates heights and
                        // scrolls short of the newest row after bursts of messages.
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(messages) { message in
                                ConversationRow(message: message)
                            }
                            Color.clear.frame(height: 1).id(Self.bottomID)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: app.conversation.messages.last?.id) { _, id in scrollToEnd(proxy, id) }
                    .onChange(of: app.conversation.messages.last?.content) { _, _ in scrollToEnd(proxy, app.conversation.messages.last?.id) }
                    .onAppear { scrollToEnd(proxy, messages.last?.id, animated: false) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation")
    }

    private static let bottomID = "conversation.bottom"

    private func scrollToEnd(_ proxy: ScrollViewProxy, _ id: UUID?, animated: Bool = true) {
        guard id != nil else { return }
        // Let the new row lay out first, then pin to the bottom anchor.
        DispatchQueue.main.async {
            if animated && !app.preferences.effectiveReduceMotion {
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            } else {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }
}

struct ConversationRow: View {
    let message: ConversationMessage

    private var roleLabel: String {
        switch message.role { case .user: "YOU"; case .jarvis: "JARVIS"; case .system: "SYSTEM" }
    }
    private var roleTint: Color {
        switch message.role { case .user: Theme.Palette.violet; case .jarvis: Theme.Palette.accent; case .system: Color.jarvisSecondary }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Text(message.timestamp, format: .dateTime.hour().minute().second())
                .font(Theme.Typography.mono).foregroundStyle(Color.jarvisTertiary).monospacedDigit()
            Text(roleLabel)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced)).tracking(0.6)
                .foregroundStyle(roleTint)
                .frame(width: 52, alignment: .leading)
            content
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(message.role == .user ? "You" : message.role == .jarvis ? "Jarvis" : "System"): \(message.content)")
        .accessibilityValue(message.status == .complete ? "" : message.status.rawValue)
    }

    @ViewBuilder
    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if message.tone == .notice || message.status == .failed {
                Image(systemName: message.status == .failed ? "xmark.octagon.fill" : "info.circle.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(message.status == .failed ? Theme.Palette.coral : Theme.Palette.amber)
            }
            if message.content.isEmpty && (message.status == .pending || message.status == .streaming) {
                Text("…").font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary)
            } else {
                Text(message.content)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(message.role == .user ? Color.jarvisPrimary : Color.jarvisPrimary.opacity(0.92))
                    .lineLimit(message.role == .user ? 6 : 12)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}
