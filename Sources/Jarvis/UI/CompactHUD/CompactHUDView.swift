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
            actions(store)
            CommandField(text: $command, placeholder: "Command", onCancel: { app.windows.hideCompactHUD() })
            if app.preferences.showDeveloperControls {
                DevStateStrip(compact: true)
            }
        }
        .padding(Theme.Spacing.l)
        .frame(width: 392)
        .background(HUDSurface(cornerRadius: Theme.Radius.xl, showsGrid: true))
        .environment(\.colorScheme, .dark)
        // Leave room for the window shadow without clipping the rounded surface.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("JARVIS compact HUD")
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
                StateChip(state: store.state)
                Text(store.state.summary)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Color.jarvisSecondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("System state: \(store.state.label.capitalized). \(store.state.summary)")
    }

    // MARK: Task

    @ViewBuilder
    private func taskCard(_ store: JarvisStore) -> some View {
        if let task = store.activeTask {
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
                    Text("\(task.completedStepCount) of \(task.steps.count) steps complete")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Color.jarvisSecondary)
                    Spacer()
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "timer").font(.system(size: 10)).accessibilityHidden(true)
                        ElapsedText(task: task, isVisible: app.hud.isCompactVisible)
                    }
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Color.jarvisSecondary)
                }
            }
            .padding(Theme.Spacing.m)
            .background(HUDCardBackground())
            .accessibilityElement(children: .contain)
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("ACTIVE TASK").jarvisLabel(Theme.Opacity.textTertiary)
                Text("No active task").font(Theme.Typography.headline).foregroundStyle(Color.jarvisSecondary)
                Text("Tasks started later will appear here.").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.m)
            .background(HUDCardBackground())
        }
    }

    // MARK: Actions

    private func actions(_ store: JarvisStore) -> some View {
        let task = store.activeTask
        let isPaused = task?.status == .paused
        let canTogglePause = task != nil && (isPaused || task?.status == .running)

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
