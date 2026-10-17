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

/// Background for an inner item (a row, a proposal, a selectable record). V1.0 fix 3: quiet — the corner-bracket frame is reserved for the hero core panel (`CardBackground(.hero)`).
/// `accent` only tints the border when it is NOT the default accent (an amber attention item, a selected record).
struct HUDCardBackground: View {
    var cornerRadius: CGFloat = Theme.Grid.innerRadius + 1
    var accent: Color = Theme.Palette.accent
    var raised = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(Color.white.opacity(raised ? 0.07 : 0.04))
            .overlay(shape.strokeBorder(accent == Theme.Palette.accent && !raised ? Color.white.opacity(0.10) : accent.opacity(0.5), lineWidth: Theme.Grid.border))
    }
}

/// Titled panel used throughout the Full HUD (V1.0 fix 3: now the shared `Card` look — quiet border, readable title, one grid).
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
        Card(title, trailing: { trailing }, content: { content })
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
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .frame(height: Theme.Grid.badgeHeight - 2)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(tint.opacity(0.55), lineWidth: 0.8))
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var valueTint: Color = .jarvisPrimary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            Text(key).font(Theme.Typography.meta).foregroundStyle(Color.jarvisTertiary)
            Spacer(minLength: Theme.Spacing.s)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(valueTint)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}
