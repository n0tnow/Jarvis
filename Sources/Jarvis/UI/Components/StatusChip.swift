import SwiftUI

/// Glyph + text pill. State is carried by shape and words, with colour as reinforcement only.
struct StatusChip: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .bold))
            Text(text).font(.system(size: 10.5, weight: .semibold, design: .monospaced)).tracking(0.8).lineLimit(1)
        }
        .fixedSize()
        .foregroundStyle(tint)
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.55), lineWidth: 0.8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.capitalized)
    }
}

struct StateChip: View {
    let state: JarvisState
    var body: some View { StatusChip(text: state.label, symbol: state.symbolName, tint: state.tint) }
}

struct TaskStatusChip: View {
    let status: TaskStatus
    var body: some View { StatusChip(text: status.label, symbol: status.symbolName, tint: status.tint) }
}
