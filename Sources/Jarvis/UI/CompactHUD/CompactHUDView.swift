import SwiftUI

/// Menu-bar HUD: identity, current state, active task, three actions, and a command line.
struct CompactHUDView: View {
    @Environment(AppContext.self) private var app
    @State private var command = ""

    var body: some View {
        let store = app.store

        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            header
            stateRow(store)
            taskCard(store)
            AgentsSummaryStrip()
            actions(store)
            CommandField(text: $command, placeholder: "Command", origin: .compactHUD,
                         feedback: app.conversation.feedbackLine, voiceLine: compactVoiceLine, focusTrigger: app.hud.isCompactVisible,
                         onCancel: { app.windows.hideCompactHUD() })
            if app.preferences.showDeveloperControls && AgentsSummaryStrip.shown(app.hub) == nil {      // the dev strip yields while agent activity is shown
                DevStateStrip(compact: true)
            }
            Spacer(minLength: 0)   // absorbs slack: the frame below is fixed, content never resizes the window
        }
        .padding(Theme.Spacing.l)
        .frame(width: CompactHUDLayout.size.width, height: CompactHUDLayout.size.height, alignment: .top)
        .background(HUDSurface(cornerRadius: Theme.Radius.xl, showsGrid: true))
        .environment(\.colorScheme, .dark)
        .animation(app.preferences.effectiveReduceMotion ? nil : .easeInOut(duration: CompactHUDLayout.transition),
                   value: app.store.state)
        .animation(app.preferences.effectiveReduceMotion ? nil : .easeInOut(duration: CompactHUDLayout.transition),
                   value: app.store.activeTask?.status)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("JARVIS compact HUD")
    }

    /// While listening: the provisional transcript replaces the placeholder (one tail-truncated line; the field never changes size).
    private var compactVoiceLine: String? {
        if app.handsFree.presence == .attentive { return "Listening for you…" }
        guard app.voice.state == .listening || app.voice.state == .transcribing else { return nil }
        let p = app.voice.partialTranscript
        return p.isEmpty ? (app.voice.state == .listening ? "Listening…" : "Transcribing…") : "“\(p)”"
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.s) {
            Circle()
                .strokeBorder(Theme.Palette.accent, lineWidth: 1.5)
                .overlay(Circle().fill(Theme.Palette.accent).frame(width: 4, height: 4))
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
            Text("JARVIS").font(Theme.Typography.wordmark).tracking(4).foregroundStyle(Color.jarvisPrimary).lineLimit(1).fixedSize()
            Tag(text: AppInfo.milestone)
            if app.preferences.showProposals, app.opportunities.pending.count > 0 {
                let n = app.opportunities.pending.count
                Tag(text: "\(n) SUGGESTION\(n == 1 ? "" : "S")").accessibilityLabel("\(n) pending suggestion\(n == 1 ? "" : "s") in the Tasks screen")
            }
            Spacer()
            Menu {
                Button("Settings…") { app.windows.showSettings() }
                Divider()
                Button("Quit JARVIS") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.jarvisSecondary)
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("JARVIS menu")
            .accessibilityIdentifier("compact.menu")
        }
    }

    // MARK: State

    private func stateRow(_ store: JarvisStore) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            JarvisCoreView(
                state: store.state,
                stateEnteredAt: store.stateEnteredAt,
                steps: store.activeTask?.steps.map(\.status) ?? [],
                isAnimating: app.hud.isCompactVisible && !app.preferences.effectiveReduceMotion,
                maxFPS: 20,
                showsCenterLabel: false
            )
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("SYSTEM STATE").jarvisLabel(Theme.Opacity.textTertiary)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(spacing: Theme.Spacing.xs) {
                        StateChip(state: store.state)
                        CompactVoiceIndicator()
                    }
                    Text(store.state.summary)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Color.jarvisSecondary)
                        .lineLimit(1)
                }
                .id(store.state)                       // crossfade on state change (content only)
                .transition(contentTransition)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("System state: \(store.state.label.capitalized). \(store.state.summary)")
    }

    // MARK: Task

    /// Fixed-height card: the *inside* changes with the task (crossfade), the card itself never resizes.
    private func taskCard(_ store: JarvisStore) -> some View {
        let task = store.activeTask
        return ZStack(alignment: .topLeading) {
            HUDCardBackground()
            Group {
                if let task { activeTaskContent(task) } else { emptyTaskContent }
            }
            .padding(Theme.Spacing.m)
            .id(task.map { "\($0.id)-\($0.status.rawValue)-\($0.completedStepCount)" } ?? "none")
            .transition(contentTransition)
        }
        .frame(maxWidth: .infinity)
        .frame(height: CompactHUDLayout.taskCardHeight, alignment: .top)
        .clipped()
        .accessibilityElement(children: .contain)
    }

    private func activeTaskContent(_ task: JarvisTask) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                Text("ACTIVE TASK").jarvisLabel(Theme.Opacity.textTertiary)
                Spacer()
                TaskStatusChip(status: task.status)
            }
            Text(task.title)
                .font(Theme.Typography.headline)
                .foregroundStyle(Color.jarvisPrimary)
                .lineLimit(2)

            if let step = task.currentStep, let number = task.currentStepNumber {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                    Text("STEP \(number)/\(task.steps.count)").jarvisLabel(Theme.Opacity.textTertiary)
                    Text(step.title).font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary).lineLimit(1)
                }
            }

            SegmentedProgress(steps: task.steps)

            HStack {
                Text(progressCaption(task))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Color.jarvisSecondary)
                    .lineLimit(1)
                Spacer()
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "timer").font(.system(size: 10)).accessibilityHidden(true)
                    ElapsedText(task: task, isVisible: app.hud.isCompactVisible)
                }
                .font(Theme.Typography.mono)
                .foregroundStyle(Color.jarvisSecondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// "3 of 6 steps complete" (demo) · "3 of 7 steps validated · 43 % · 2 agents" (autonomous: a percentage only from real validated steps).
    private func progressCaption(_ task: JarvisTask) -> String {
        guard let e = task.engine else { return "\(task.completedStepCount) of \(task.steps.count) steps complete" }
        guard !task.steps.isEmpty else { return e.activity.isEmpty ? "Planning" : e.activity }
        var s = "\(task.completedStepCount) of \(task.steps.count) validated"
        if let f = e.progressFraction { s += " · \(Int((f * 100).rounded())) %" }
        let agents = app.hub.activeRuns.filter { $0.taskID == task.id }.count          // live, not the projection's last snapshot
        if agents > 0 { s += " · \(agents) agent\(agents == 1 ? "" : "s")" }
        if let u = app.taskEngine.view(task.id)?.currentStep?.type.unityActivity { s += " · " + u }      // V0.6: "Unity · Compiling" (one short phrase; no Unity UI in Compact)
        return s
    }

    private var emptyTaskContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("ACTIVE TASK").jarvisLabel(Theme.Opacity.textTertiary)
            Text("No active task").font(Theme.Typography.headline).foregroundStyle(Color.jarvisSecondary)
            Text("Tasks started later will appear here.").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Subtle, short, internal-only transition; none under Reduce Motion.
    private var contentTransition: AnyTransition {
        app.preferences.effectiveReduceMotion ? .identity : .opacity.combined(with: .offset(y: 3))
    }

    // MARK: Actions

    private func actions(_ store: JarvisStore) -> some View {
        let task = store.activeTask
        let isInterrupted = task?.status == .interrupted
        let isPaused = task?.status == .paused || isInterrupted
        let isAutonomous = task?.engine != nil
        // Autonomous tasks cannot be paused (only stopped); an interrupted one can be resumed.
        let canTogglePause = task != nil && (isInterrupted || (!isAutonomous && (isPaused || task?.status == .running)))

        return HStack(spacing: Theme.Spacing.s) {
            Button { app.windows.showFullHUD(section: .dashboard) } label: {
                Text("OPEN JARVIS")
            }
            .buttonStyle(.hudPrimary)
            .accessibilityLabel("Open JARVIS full HUD")
            .accessibilityIdentifier("compact.open")

            Button {
                isPaused ? store.resumeActiveTask() : store.pauseActiveTask()
            } label: {
                Text(isPaused ? "RESUME" : "PAUSE")
            }
            .buttonStyle(.hudSecondary)
            .disabled(!canTogglePause)
            .accessibilityLabel(isPaused ? "Resume task" : "Pause task")
            .accessibilityIdentifier("compact.pause")

            Button { store.stopActiveTask() } label: {
                Text("STOP")
            }
            .buttonStyle(.hudDestructive)
            .disabled(task == nil)
            .accessibilityLabel("Stop task")
            .accessibilityIdentifier("compact.stop")
        }
    }
}
