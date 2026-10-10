import SwiftUI

/// Centre column: the JARVIS core, current task strip, and (when relevant) the approval card.
struct CenterStage: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        let store = app.store
        let task = store.activeTask

        ViewThatFits(in: .vertical) {
            stack(store, task, core: coreView(store, task).frame(maxWidth: 560, minHeight: 170, idealHeight: 240, maxHeight: .infinity))
            ScrollView(.vertical, showsIndicators: false) {
                stack(store, task, core: coreView(store, task).frame(maxWidth: 360).frame(height: store.pendingApproval == nil ? 180 : 130))
            }
        }
        .animation(.easeOut(duration: Theme.Duration.standard), value: store.pendingApproval)
    }
}

extension CenterStage {
    private func coreView(_ store: JarvisStore, _ task: JarvisTask?) -> some View {
        JarvisCoreView(
            state: store.state,
            stateEnteredAt: store.stateEnteredAt,
            steps: task?.steps.map(\.status) ?? [],
            isAnimating: app.hud.isFullHUDVisible && !app.preferences.effectiveReduceMotion
        )
        .padding(.horizontal, Theme.Spacing.l)
    }

    private func stack<Core: View>(_ store: JarvisStore, _ task: JarvisTask?, core: Core) -> some View {
        VStack(spacing: Theme.Spacing.m) {
            core
            // A pending approval sits directly under the core so it can never be pushed below the fold.
            if let request = store.pendingApproval, store.state == .waitingForApproval {
                ApprovalCard(request: request)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            ConversationPanel().frame(minHeight: 88, idealHeight: 150, maxHeight: store.pendingApproval == nil ? 176 : 112)
            TaskFocusStrip(task: task)
        }
    }
}

private struct TaskFocusStrip: View {
    @Environment(AppContext.self) private var app
    let task: JarvisTask?

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            if let task {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CURRENT TASK").jarvisLabel(Theme.Opacity.textTertiary)
                        Text(task.title).font(Theme.Typography.title).foregroundStyle(Color.jarvisPrimary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("ELAPSED").jarvisLabel(Theme.Opacity.textTertiary)
                        ElapsedText(task: task, isVisible: app.hud.isFullHUDVisible)
                            .font(Theme.Typography.metric)
                            .foregroundStyle(Color.jarvisPrimary)
                    }
                }
                if let step = task.currentStep, let number = task.currentStepNumber {
                    HStack(spacing: Theme.Spacing.s) {
                        Text("STEP \(number)/\(task.steps.count)").jarvisLabel(Theme.Opacity.textTertiary)
                        Text(step.title).font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
                        Spacer()
                        TaskStatusChip(status: task.status)
                    }
                }
                SegmentedProgress(steps: task.steps, height: 7)
            } else {
                VStack(spacing: 2) {
                    Text("NO ACTIVE TASK").jarvisLabel(Theme.Opacity.textTertiary)
                    Text("JARVIS is standing by.").font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(Theme.Spacing.m + 2)
        .background(HUDCardBackground(raised: true))
        .accessibilityElement(children: .contain)
    }
}

private struct ApprovalCard: View {
    @Environment(AppContext.self) private var app
    let request: ApprovalRequest

    var body: some View {
        // Side-by-side when wide enough; stacked (buttons under the text) when the centre column is narrow.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.m) { icon; text; Spacer(minLength: Theme.Spacing.m); buttons }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack(alignment: .top, spacing: Theme.Spacing.m) { icon; text }
                buttons.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(Theme.Spacing.m + 2)
        .background(HUDCardBackground(accent: Theme.Palette.amber, raised: true))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .strokeBorder(Theme.Palette.amber.opacity(0.55), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .onAppear {
            // Tell VoiceOver an approval is pending; the card otherwise appears silently.
            Announcer.announce("Approval required: \(request.title)", high: true)
        }
    }

    private var icon: some View {
        Image(systemName: "hand.raised.fill")
            .font(.system(size: 18))
            .foregroundStyle(Theme.Palette.amber)
            .accessibilityHidden(true)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("APPROVAL REQUIRED · DEMO")
                .font(Theme.Typography.label).tracking(1.1)
                .foregroundStyle(Theme.Palette.amber)
            Text(request.title).font(Theme.Typography.headline).foregroundStyle(Color.jarvisPrimary)
            Text(request.detail)
                .font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        HStack(spacing: Theme.Spacing.s) {
            Button("DENY") { app.store.resolveApproval(approved: false) }
                .buttonStyle(.hudDestructive).fixedSize()
                .accessibilityLabel("Deny request")
                .accessibilityHint(request.title)
                .accessibilityIdentifier("approval.deny")
            Button("APPROVE") { app.store.resolveApproval(approved: true) }
                .buttonStyle(.hudPrimary).fixedSize()
                .accessibilityLabel("Approve request")
                .accessibilityHint(request.title)
                .accessibilityIdentifier("approval.approve")
        }
    }
}
