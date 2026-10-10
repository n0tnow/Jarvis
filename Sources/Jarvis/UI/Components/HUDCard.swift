import SwiftUI

/// Thin L-shaped marks on the four corners — the signature "technical frame" detail.
struct CornerBrackets: Shape {
    var length: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let l = length
        // top-left
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + l)); p.addLine(to: CGPoint(x: rect.minX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))
        // top-right
        p.move(to: CGPoint(x: rect.maxX - l, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))
        // bottom-right
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - l)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.maxX - l, y: rect.maxY))
        // bottom-left
        p.move(to: CGPoint(x: rect.minX + l, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - l))
        return p
    }
}

/// Background + frame for any grouped content.
struct HUDCardBackground: View {
    var cornerRadius: CGFloat = Theme.Radius.m
    var accent: Color = Theme.Palette.accent
    var raised = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(Color.white.opacity(raised ? Theme.Opacity.surfaceRaised : Theme.Opacity.surface))
            .overlay(shape.strokeBorder(Color.white.opacity(Theme.Opacity.hairline), lineWidth: 0.8))
            .overlay(CornerBrackets().stroke(accent.opacity(0.55), lineWidth: 1).padding(-0.5))
    }
}

/// Titled panel used throughout the Full HUD.
struct HUDCard<Content: View, Trailing: View>: View {
    let title: String
    var trailing: Trailing
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                Text(title).jarvisLabel(Theme.Opacity.textSecondary)
                Spacer(minLength: Theme.Spacing.s)
                trailing
            }
            .accessibilityAddTraits(.isHeader)

            Rectangle().fill(Color.white.opacity(Theme.Opacity.hairline)).frame(height: 0.8)
            content
        }
        .padding(Theme.Spacing.m)
        .background(HUDCardBackground())
        .accessibilityElement(children: .contain)
    }
}

extension HUDCard where Trailing == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, trailing: { EmptyView() }, content: content)
    }
}

/// Small bordered tag, e.g. "DEMO".
struct Tag: View {
    let text: String
    var tint: Color = Color.white.opacity(Theme.Opacity.textSecondary)

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .tracking(0.8)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(tint.opacity(0.7), lineWidth: 0.8))
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var valueTint: Color = .jarvisPrimary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).jarvisLabel(Theme.Opacity.textTertiary)
            Spacer(minLength: Theme.Spacing.s)
            Text(value)
                .font(Theme.Typography.mono)
                .foregroundStyle(valueTint)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
