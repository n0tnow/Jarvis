import SwiftUI

/// The Settings destination of the Full HUD: a category list on the left, the real controls of the chosen category on the right. Every control is an implemented preference.
struct SettingsPageView: View {
    @Environment(AppContext.self) private var app
    @Environment(\.hudIsNarrow) private var isNarrow

    var body: some View {
        @Bindable var hud = app.hud
        PageScaffold("Settings", subtitle: "Preferences that are saved on this Mac. Nothing here can grant JARVIS a permission or turn a safety rule off.", scrolls: false) {
            HStack(alignment: .top, spacing: Theme.Grid.gutter) {
                categoryList(selection: $hud.settingsCategory)
                    .frame(width: isNarrow ? 210 : 270)
                VStack(alignment: .leading, spacing: Theme.Grid.rowGap) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(hud.settingsCategory.title).font(Theme.Typography.title).foregroundStyle(Color.jarvisPrimary)
                        Text(hud.settingsCategory.summary).font(Theme.Typography.meta).foregroundStyle(Color.jarvisTertiary)
                        Spacer()
                    }
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: Theme.Grid.rowGap) {
                            if hud.settingsCategory == .voice { VoiceControlCards() }
                            SettingsView(category: hud.settingsCategory)
                        }
                        .id(hud.settingsCategory)
                        .padding(.bottom, Theme.Grid.cardPadding)
                    }
                }
            }
        }
        .accessibilityIdentifier("settings.page")
    }

    private func categoryList(selection: Binding<SettingsCategory>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsCategory.allCases) { c in
                let selected = selection.wrappedValue == c
                Button { selection.wrappedValue = c } label: {
                    HStack(spacing: Theme.Spacing.m) {
                        Image(systemName: c.symbol).font(.system(size: 14, weight: .regular)).frame(width: 22).foregroundStyle(selected ? Theme.Palette.accent : Color.jarvisSecondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.title).font(Theme.Typography.rowTitle).foregroundStyle(selected ? Color.jarvisPrimary : Color.jarvisSecondary).lineLimit(1)
                            if !isNarrow { Text(c.summary).font(Theme.Typography.meta).foregroundStyle(Color.jarvisTertiary).lineLimit(1) }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Theme.Spacing.m).padding(.vertical, Theme.Spacing.s + 2)
                    .background(RoundedRectangle(cornerRadius: Theme.Grid.innerRadius, style: .continuous).fill(selected ? Theme.Palette.accent.opacity(0.13) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(c.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("settings.category.\(c.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.s)
        .background(CardBackground(prominence: .quiet))
    }
}
