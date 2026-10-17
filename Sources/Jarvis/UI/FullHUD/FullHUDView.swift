import SwiftUI

/// The large "JARVIS is present" surface. Navigation is driven by `HUDState.section`, so any code
/// (including a future voice/intent layer) can switch views via `windows.showFullHUD(section:)`.
struct FullHUDView: View {
    var body: some View {
        GeometryReader { geo in
            // The injected value is only visible to CHILDREN — hence the separate FullHUDBody that reads it.
            FullHUDBody().environment(\.hudIsNarrow, geo.size.width < Theme.Grid.narrowBreakpoint)
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

    /// The header is the window's drag handle (and ONLY the header: see `WindowDragRegion`). Navigation is grouped — Dashboard · Work · Knowledge & system — with Settings set apart on the right.
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
            }

            navigation

            Spacer(minLength: Theme.Spacing.m)

            navTab(.settings, compact: true)

            StatusChip(text: isNarrow ? app.store.state.shortLabel : app.store.state.label,
                       symbol: app.store.state.symbolName, tint: app.store.state.tint)

            Button {
                app.windows.hideFullHUD()
            } label: {
                HStack(spacing: Theme.Spacing.xs + 2) {
                    Text("Close")
                    Text("esc").font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.4), lineWidth: 0.8))
                }
                .fixedSize()
            }
            .buttonStyle(.hudSecondary)
            .fixedSize()
            .accessibilityLabel("Close JARVIS HUD")
            .accessibilityIdentifier("full.close")
            .accessibilityHint("Closes this window. JARVIS keeps running in the menu bar.")
        }
        .padding(.horizontal, Theme.Grid.pageMargin)
        .frame(height: Theme.Grid.headerHeight)
        .windowDragHandle()
    }

    private static let groups: [[HUDSection]] = [
        [.dashboard],
        [.tasks, .agents, .research, .report],
        [.system, .memory, .computer, .learning, .capabilities],
    ]

    private var navigation: some View {
        HStack(spacing: Theme.Spacing.m) {
            ForEach(Array(Self.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Rectangle().fill(Color.white.opacity(0.14)).frame(width: 0.8, height: 18).accessibilityHidden(true) }
                HStack(spacing: 2) { ForEach(group) { navTab($0, compact: false) } }
            }
        }
    }

    /// One destination. Wide window: icon + title. Narrow: icon only (the selected one keeps its title); the full name is always the tooltip and the accessibility label.
    private func navTab(_ section: HUDSection, compact settingsStyle: Bool) -> some View {
        let isSelected = app.hud.section == section
        let showsTitle = settingsStyle ? false : (!isNarrow || isSelected)
        return Button {
            withAnimation(.easeOut(duration: Theme.Duration.fast)) { app.hud.section = section }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: section.symbolName).font(.system(size: 13, weight: .regular)).frame(width: 16)
                if showsTitle { Text(section.title.capitalized).font(.system(size: 12.5, weight: isSelected ? .semibold : .medium)).lineLimit(1) }
            }
            .fixedSize()
            .foregroundStyle(isSelected ? Theme.Palette.accent : Color.jarvisSecondary)
            .padding(.horizontal, showsTitle ? Theme.Spacing.m : Theme.Spacing.s + 2)
            .frame(height: Theme.Grid.controlHeight)
            .background(RoundedRectangle(cornerRadius: Theme.Grid.innerRadius, style: .continuous).fill(isSelected ? Theme.Palette.accent.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(section.title.capitalized)
        .accessibilityLabel(section.title.capitalized)
        .accessibilityIdentifier("full.tab.\(section.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Content

    @ViewBuilder
    private var sectionContent: some View {
        switch app.hud.section {
        case .dashboard: DashboardView()
        case .tasks: TasksSectionView()
        case .agents: AgentsSectionView()
        case .research: ResearchSectionView()
        case .report: ReportPage()
        case .system: SystemSectionView()
        case .memory: MemorySectionView()
        case .computer: ComputerSectionView()
        case .learning: LearningSectionView()
        case .capabilities: CapabilitiesSectionView()
        case .settings: SettingsPageView()
        }
    }

    // MARK: Bottom

    private var bottomBar: some View {
        VStack(spacing: Theme.Spacing.s + 2) {
            if app.simulatorControlsVisible {
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
    @Environment(AppContext.self) private var app
    @Environment(\.hudIsNarrow) private var isNarrow

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= Theme.Grid.wideBreakpoint
            let left: CGFloat = isNarrow ? 250 : (wide ? Theme.Grid.leftRailWidth + 40 : Theme.Grid.leftRailWidth)
            let right: CGFloat = isNarrow ? 270 : (wide ? Theme.Grid.railWidth + 40 : Theme.Grid.railWidth)
            HStack(alignment: .top, spacing: Theme.Grid.gutter) {
                column { SystemPanel(); VoicePanel(); ProjectPanel(); TasksPanel() }
                    .frame(width: left)

                CenterStage()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                column { ActivityPanel(); AgentsPanel(); if app.demoMode { ToolsPanel() } }
                    .frame(width: right)
            }
            .padding(.horizontal, Theme.Grid.pageMargin)
            .padding(.vertical, Theme.Grid.rowGap)
        }
    }

    /// Natural-height cards on the grid; a column that does not fit scrolls instead of squeezing the cards.
    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: Theme.Grid.rowGap) { content() }
        }
    }
}

/// Reports live with their task. This page says so, honestly, and takes you there.
private struct ReportPage: View {
    @Environment(AppContext.self) private var app
    var body: some View {
        PageScaffold("Report", subtitle: "A finished task's report, with its evidence.", maxContentWidth: 1100) {
            Card {
                EmptyState(symbol: "doc.text", title: "No report to show here.",
                           message: "A finished task's report is on the Tasks screen — open the task to read it. This page shows nothing of its own and invents nothing.",
                           actionTitle: "Open Tasks", action: { app.hud.section = .tasks })
            }
        }
        .accessibilityIdentifier("report.page")
    }
}
