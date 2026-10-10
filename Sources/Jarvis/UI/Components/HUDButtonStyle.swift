import SwiftUI

struct HUDButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }

    var kind: Kind = .secondary
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    private var tint: Color {
        switch kind {
        case .primary: Theme.Palette.accent
        case .secondary: Color.white
        case .destructive: Theme.Palette.coral
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
        configuration.label
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .tracking(1)
            .foregroundStyle(kind == .primary ? Theme.Palette.ink : tint.opacity(kind == .secondary ? 0.92 : 1))
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                shape.fill(kind == .primary
                    ? tint.opacity(configuration.isPressed ? 0.75 : (isHovering ? 1 : 0.92))
                    : tint.opacity(configuration.isPressed ? 0.20 : (isHovering ? 0.14 : 0.07)))
            )
            .overlay(shape.strokeBorder(tint.opacity(kind == .primary ? 0 : 0.40), lineWidth: 0.8))
            .opacity(isEnabled ? 1 : 0.38)
            .contentShape(shape)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: Theme.Duration.fast), value: isHovering)
    }
}

extension ButtonStyle where Self == HUDButtonStyle {
    static var hudPrimary: HUDButtonStyle { HUDButtonStyle(kind: .primary) }
    static var hudSecondary: HUDButtonStyle { HUDButtonStyle(kind: .secondary) }
    static var hudDestructive: HUDButtonStyle { HUDButtonStyle(kind: .destructive) }
}
