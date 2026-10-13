import SwiftUI

/// The large "JARVIS is present" surface. Navigation is driven by `HUDState.section`, so any code
/// (including a future voice/intent layer) can switch views via `windows.showFullHUD(section:)`.
struct FullHUDView: View {
    var body: some View {
        GeometryReader { geo in
            // The injected value is only visible to CHILDREN — hence the separate FullHUDBody that reads it.
            FullHUDBody().environment(\.hudIsNarrow, geo.size.width < 1200)
        }
    }
}

private struct FullHUDBody: View {
    @Environment(AppContext.self) private var app
    @State private var command = ""
    @Environment(\.hudIsNarrow) private var isNarrow

    var body: some View { content }

    private var content: some View {
        ZStack {
            HUDSurface(cornerRadius: Theme.Radius.xl + 4, showsGrid: true)

            // Ambient neural network: behind all content, decorative, paused when hidden / Reduce Motion.
            NeuralBackground(state: app.store.state,
                             isAnimating: app.hud.isFullHUDVisible && !app.preferences.effectiveReduceMotion)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl + 4, style: .continuous))
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                topBar
                Rectangle().fill(Color.white.opacity(Theme.Opacity.hairline)).frame(height: 0.8)
                sectionContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomBar
            }
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("JARVIS")
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: Theme.Spacing.l) {
            HStack(spacing: Theme.Spacing.s) {
                Circle()
                    .strokeBorder(Theme.Palette.accent, lineWidth: 1.5)
                    .overlay(Circle().fill(Theme.Palette.accent).frame(width: 5, height: 5))
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text("JARVIS").font(Theme.Typography.wordmark).tracking(isNarrow ? 3 : 5).foregroundStyle(Color.jarvisPrimary)
                    .lineLimit(1).fixedSize()
                if !isNarrow { Tag(text: AppInfo.milestone) }
            }

            sectionTabs

            Spacer(minLength: Theme.Spacing.l)

            // The longest label ("AWAITING APPROVAL") would make the bar wider than a 980 pt window and drag the whole layout with it.
            StatusChip(text: isNarrow ? app.store.state.shortLabel : app.store.state.label,
                       symbol: app.store.state.symbolName, tint: app.store.state.tint)

            Button {
                app.windows.hideFullHUD()
            } label: {
                HStack(spacing: Theme.Spacing.xs + 2) {
                    Text("CLOSE")
                    Text("ESC").font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.4), lineWidth: 0.8))
                }
                .fixedSize()
            }
            .buttonStyle(.hudSecondary)
            .fixedSize()
            .accessibilityLabel("Close JARVIS HUD")
            .accessibilityIdentifier("full.close")
            .accessibilityHint("Closes this window. JARVIS keeps running in the menu bar.")
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.m + 2)
    }

    private var sectionTabs: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(HUDSection.allCases) { section in
                let isSelected = app.hud.section == section
                Button {
                    withAnimation(.easeOut(duration: Theme.Duration.fast)) { app.hud.section = section }
                } label: {
                    HStack(spacing: 5) {
                        if !isNarrow { Image(systemName: section.symbolName).font(.system(size: 10.5, weight: .medium)) }
                        Text(section.title).font(.system(size: 10.5, weight: .semibold, design: .monospaced)).tracking(0.9)
                            .lineLimit(1)
                    }
                    .fixedSize()
                    .foregroundStyle(isSelected ? Theme.Palette.accent : Color.jarvisSecondary)
                    .padding(.horizontal, Theme.Spacing.m)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                            .fill(isSelected ? Theme.Palette.accent.opacity(0.14) : .clear)
                    )
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(isSelected ? Theme.Palette.accent : .clear).frame(height: 1.5).padding(.horizontal, 6)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section.title.capitalized)
                .accessibilityIdentifier("full.tab.\(section.rawValue)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var sectionContent: some View {
        switch app.hud.section {
        case .dashboard: DashboardView()
        case .tasks: TasksSectionView()
        case .agents: AgentsSectionView()
        case .research: ResearchSectionView()
        case .report: PlaceholderSectionView(
            section: .report, plannedFor: "V0.8",
            blurb: "Reports and visual explanations will appear here. Nothing is generated yet — this view only reserves the place."
        )
        case .system: SystemSectionView()
        case .memory: MemorySectionView()
        case .computer: ComputerSectionView()
        }
    }

    // MARK: Bottom

    private var bottomBar: some View {
        VStack(spacing: Theme.Spacing.s + 2) {
            if app.preferences.showDeveloperControls {
                DevStateStrip()
            }
            CommandField(text: $command, placeholder: "Command JARVIS — e.g. “open the report”, “what are you doing?”", origin: .fullHUD,
                         feedback: app.conversation.feedbackLine, focusTrigger: app.hud.isFullHUDVisible, maxLines: 6, onCancel: { app.windows.hideFullHUD() })
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.s)
        .padding(.bottom, Theme.Spacing.l)
    }
}

// MARK: - Dashboard

private struct DashboardView: View {
    @Environment(\.hudIsNarrow) private var isNarrow

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.l) {
            column { SystemPanel(); ProjectPanel(); TasksPanel() }
                .frame(width: isNarrow ? 236 : 290)

            CenterStage()
                .frame(maxWidth: .infinity)

            column { ActivityPanel(); AgentsPanel(); ToolsPanel() }
                .frame(width: isNarrow ? 252 : 320)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.l)
    }

    /// Fills the available height when the panels fit; falls back to scrolling on short windows.
    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let panels = content()
        return ViewThatFits(in: .vertical) {
            VStack(spacing: Theme.Spacing.m) { panels }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Theme.Spacing.m) { panels }
            }
        }
    }
}

private struct PlaceholderSectionView: View {
    let section: HUDSection
    let plannedFor: String
    let blurb: String

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: section.symbolName)
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(Theme.Palette.accent.opacity(0.8))
                .accessibilityHidden(true)
            Text(section.title).font(.system(size: 18, weight: .medium, design: .monospaced)).tracking(6).foregroundStyle(Color.jarvisPrimary)
            Tag(text: "PLANNED · \(plannedFor)", tint: Theme.Palette.amber)
            Text(blurb)
                .font(Theme.Typography.body)
                .foregroundStyle(Color.jarvisSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .padding(Theme.Spacing.xl)
        .accessibilityElement(children: .combine)
    }
}
