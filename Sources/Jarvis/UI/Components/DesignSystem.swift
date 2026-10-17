import SwiftUI

// MARK: - JARVIS Full HUD design system (V1.0 stabilisation fix 3)
//
// Direction: a calm, precise AI workstation for macOS — dark technical glass, one restrained ice-cyan accent, thin structure, readable type. Hierarchy comes from spacing and type
// first, rectangles second. Every screen is the same three things: PageScaffold (header + margins + max width), cards on ONE grid (Theme.Grid), and honest empty states.
// Corner brackets (the signature "technical frame") are reserved for the hero core panel; ordinary cards are quiet.

/// A page: title + one-line subtitle + optional trailing controls, then scrollable content on the shared margins. `scrolls: false` for pages that manage their own scrolling (conversation).
struct PageScaffold<Trailing: View, Content: View>: View {
    let title: String
    var subtitle: String?
    var scrolls = true
    /// List-like pages read better in a bounded column (centered); dashboards and grids use the full width.
    var maxContentWidth: CGFloat = Theme.Grid.contentMaxWidth
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(_ title: String, subtitle: String? = nil, scrolls: Bool = true, maxContentWidth: CGFloat = Theme.Grid.contentMaxWidth, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.scrolls = scrolls; self.maxContentWidth = maxContentWidth; self.trailing = trailing(); self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Theme.Spacing.l) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.Typography.pageTitle).foregroundStyle(Color.jarvisPrimary).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle { Text(subtitle).font(Theme.Typography.pageSubtitle).foregroundStyle(Color.jarvisSecondary).lineLimit(2) }
                }
                Spacer(minLength: Theme.Spacing.l)
                trailing
            }
            .frame(minHeight: Theme.Grid.pageHeaderHeight)
            .padding(.horizontal, Theme.Grid.pageMargin)
            .frame(maxWidth: maxContentWidth + 2 * Theme.Grid.pageMargin)
            .frame(maxWidth: .infinity)

            if scrolls {
                ScrollView(.vertical, showsIndicators: true) {
                    content
                        .padding(.horizontal, Theme.Grid.pageMargin)
                        .padding(.bottom, Theme.Grid.pageMargin)
                        .frame(maxWidth: maxContentWidth + 2 * Theme.Grid.pageMargin, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            } else {
                content
                    .padding(.horizontal, Theme.Grid.pageMargin)
                    .padding(.bottom, Theme.Grid.rowGap)
                    .frame(maxWidth: maxContentWidth + 2 * Theme.Grid.pageMargin, maxHeight: .infinity, alignment: .top)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

extension PageScaffold where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, scrolls: Bool = true, maxContentWidth: CGFloat = Theme.Grid.contentMaxWidth, @ViewBuilder content: () -> Content) {
        self.init(title, subtitle: subtitle, scrolls: scrolls, maxContentWidth: maxContentWidth, trailing: { EmptyView() }, content: content)
    }
}

/// How prominent a card is. `hero` carries the corner-bracket frame; `standard` is the normal panel; `quiet` has no border (nested groups).
enum CardProminence { case hero, standard, quiet }

struct CardBackground: View {
    var prominence: CardProminence = .standard
    var accent: Color = Theme.Palette.accent

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Grid.cardRadius, style: .continuous)
        switch prominence {
        case .quiet:
            shape.fill(Color.white.opacity(0.03))
        case .standard:
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.065), Color.white.opacity(0.035)], startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: Theme.Grid.border))
        case .hero:
            shape.fill(LinearGradient(colors: [accent.opacity(0.07), Color.white.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: Theme.Grid.border))
                .overlay(CornerBrackets(length: 10).stroke(accent.opacity(0.6), lineWidth: 1).padding(-0.5))
        }
    }
}

/// Section title row used inside cards: title (readable, not shouting) + optional trailing badge/button.
struct CardHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(title.uppercased()).font(Theme.Typography.sectionTitle).tracking(0.9).foregroundStyle(Color.jarvisSecondary).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.Spacing.s)
            trailing
        }
        .frame(minHeight: Theme.Grid.badgeHeight)
    }
}

/// A card with a title row. The same container for every screen; `prominence` is the only variation.
struct Card<Trailing: View, Content: View>: View {
    let title: String?
    var prominence: CardProminence = .standard
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(_ title: String? = nil, prominence: CardProminence = .standard, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title; self.prominence = prominence; self.trailing = trailing(); self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            if let title { CardHeader(title: title) { trailing } }
            content
        }
        .padding(Theme.Grid.cardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(CardBackground(prominence: prominence))
        .accessibilityElement(children: .contain)
    }
}

extension Card where Trailing == EmptyView {
    init(_ title: String? = nil, prominence: CardProminence = .standard, @ViewBuilder content: () -> Content) {
        self.init(title, prominence: prominence, trailing: { EmptyView() }, content: content)
    }
}

/// Normalised status vocabulary. One shape for every screen: icon + words, fixed height; colour only reinforces.
enum StatusKind: Equatable {
    case ready, available, running, idle, notRunning, permissionNeeded, notChecked, error, optional, off, attention

    var label: String {
        switch self {
        case .ready: "READY"; case .available: "AVAILABLE"; case .running: "RUNNING"; case .idle: "IDLE"; case .notRunning: "NOT RUNNING"
        case .permissionNeeded: "PERMISSION NEEDED"; case .notChecked: "NOT CHECKED"; case .error: "ERROR"; case .optional: "OPTIONAL"; case .off: "OFF"; case .attention: "NEEDS ATTENTION"
        }
    }
    var symbol: String {
        switch self {
        case .ready: "checkmark.circle.fill"; case .available: "circle.dotted"; case .running: "waveform"; case .idle: "moon.zzz"; case .notRunning: "pause.circle"
        case .permissionNeeded: "lock.shield"; case .notChecked: "questionmark.circle"; case .error: "exclamationmark.triangle.fill"; case .optional: "circle.dashed"; case .off: "power"; case .attention: "exclamationmark.circle"
        }
    }
    var tint: Color {
        switch self {
        case .ready, .running: Theme.Palette.mint
        case .available: Theme.Palette.accent
        case .idle, .notRunning, .notChecked, .optional, .off: Color.white.opacity(Theme.Opacity.textSecondary)
        case .permissionNeeded, .attention: Theme.Palette.amber
        case .error: Theme.Palette.coral
        }
    }
}

extension ReadinessState {
    var statusKind: StatusKind {
        switch self {
        case .ready: .ready; case .available: .available; case .notInstalled: .optional; case .signInRequired: .attention; case .permissionNeeded: .permissionNeeded
        case .optionalAbsent: .optional; case .notRunning: .notRunning; case .off: .off; case .degraded: .error; case .stale: .notChecked; case .unknown: .notChecked; case .unavailable: .error
        }
    }
}

struct StatusBadge: View {
    let kind: StatusKind
    var text: String?
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: kind.symbol).font(.system(size: 10.5, weight: .semibold))
            Text(text ?? kind.label).font(.system(size: 10.5, weight: .semibold, design: .default)).tracking(0.5).lineLimit(1)
        }
        .fixedSize()
        .foregroundStyle(kind.tint)
        .padding(.horizontal, 9)
        .frame(height: Theme.Grid.badgeHeight)
        .background(Capsule().fill(kind.tint.opacity(0.13)))
        .overlay(Capsule().strokeBorder(kind.tint.opacity(0.45), lineWidth: Theme.Grid.border))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((text ?? kind.label).capitalized)
    }
}

/// An intentional empty state: symbol, one honest sentence, an optional next step. Never decoration pretending to be content.
struct EmptyState: View {
    let symbol: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(Color.jarvisTertiary).accessibilityHidden(true)
            Text(title).font(Theme.Typography.rowTitle).foregroundStyle(Color.jarvisSecondary)
            if let message { Text(message).font(Theme.Typography.meta).foregroundStyle(Color.jarvisTertiary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true) }
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.hudSecondary).padding(.top, 4) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.l)
        .accessibilityElement(children: .combine)
    }
}

/// Key → value line with room to breathe: meta key left, readable value right, both selectable.
struct InfoRow: View {
    let key: String
    let value: String
    var tint: Color = .jarvisPrimary
    var mono = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            Text(key).font(Theme.Typography.meta).foregroundStyle(Color.jarvisTertiary)
            Spacer(minLength: Theme.Spacing.m)
            Text(value).font(mono ? Theme.Typography.mono : Theme.Typography.meta).foregroundStyle(tint).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Columns for a page body: 1 column when narrow, 2 when medium, 3 when wide — every column the same width, every card top-aligned on the same gutter.
struct ResponsiveColumns<Content: View>: View {
    var minColumn: CGFloat = 420
    @ViewBuilder var content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minColumn), spacing: Theme.Grid.gutter, alignment: .top)], alignment: .leading, spacing: Theme.Grid.gutter) { content }
    }
}
