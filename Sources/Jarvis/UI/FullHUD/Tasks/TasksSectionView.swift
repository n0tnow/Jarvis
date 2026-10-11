import SwiftUI
import AppKit

// MARK: - Tasks screen (V0.4): durable autonomous tasks + the V0.1 demo task (developer controls only)

struct TasksSectionView: View {
    @Environment(AppContext.self) private var app
    var body: some View {
        let views = app.taskEngine.orderedViews
        let attention = views.filter { $0.task.state == .waitingForApproval || $0.task.state == .interrupted }
        let running = views.filter { [.created, .planning, .ready, .running].contains($0.task.state) }
        let recent = views.filter { $0.task.state.isTerminal }.prefix(15)

        ScrollView {
            VStack(spacing: Theme.Spacing.m) {
                ProjectBar()
                if views.isEmpty { emptyState }
                if !attention.isEmpty { group("NEEDS YOUR ATTENTION", attention) }
                if !running.isEmpty { group("ACTIVE", running) }
                if !recent.isEmpty { group("RECENT", Array(recent)) }
                if app.preferences.showDeveloperControls { demoTasks }
            }
            .frame(maxWidth: 780)
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("tasks.section")
    }

    private var emptyState: some View {
        HUDCard("Tasks") {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("No tasks yet.").font(Theme.Typography.headline).foregroundStyle(Color.jarvisSecondary)
                Text("Choose a project folder above, then type a goal in the command field — for example “Fix the failing calculation test”. JARVIS plans it, works through it, validates each step with real builds/tests and reports back.")
                    .font(Theme.Typography.body).foregroundStyle(Color.jarvisTertiary)
            }
        }
    }

    private func group(_ title: String, _ items: [TaskView]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(title).jarvisLabel(Theme.Opacity.textTertiary).accessibilityAddTraits(.isHeader)
            ForEach(items) { v in
                EngineTaskCard(view: v, expanded: app.hud.selectedTaskID == v.id, onToggle: { app.hud.selectedTaskID = app.hud.selectedTaskID == v.id ? nil : v.id })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var demoTasks: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("DEMO TASKS · NOT REAL WORK").jarvisLabel(Theme.Opacity.textTertiary)
            ForEach(app.store.tasks) { task in
                HUDCard(task.title, trailing: { TaskStatusChip(status: task.status) }) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Text(task.details).font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
                        ForEach(task.steps) { step in
                            HStack(spacing: Theme.Spacing.s) {
                                Image(systemName: step.status.symbolName).foregroundStyle(step.status.tint).frame(width: 14).accessibilityHidden(true)
                                Text(step.title).font(Theme.Typography.body).foregroundStyle(Color.jarvisPrimary)
                                Spacer()
                                Text(step.status.label.uppercased()).font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundStyle(Color.jarvisSecondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Project folder

struct ProjectBar: View {
    @Environment(AppContext.self) private var app
    @State private var problem: String?

    var body: some View {
        let root = app.preferences.projectRoot
        let guardOK = !root.isEmpty ? (try? WorkspaceGuard(rootPath: root)) : nil
        let profiles = guardOK.map(ProfileDiscovery.discover)
        HUDCard("Project", trailing: {
            HStack(spacing: Theme.Spacing.s) {
                Button("CHOOSE FOLDER…") { choose() }.buttonStyle(.hudSecondary).fixedSize().accessibilityIdentifier("tasks.chooseProject")
                if !root.isEmpty { Button("CLEAR") { app.preferences.projectRoot = ""; problem = nil }.buttonStyle(.hudSecondary).fixedSize() }
            }
        }) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                if root.isEmpty {
                    Text("No project chosen — development tasks need one.").font(Theme.Typography.body).foregroundStyle(Theme.Palette.amber)
                } else if guardOK == nil {
                    Text("\(root) can't be used as a project folder.").font(Theme.Typography.body).foregroundStyle(Theme.Palette.coral)
                } else {
                    Text((root as NSString).abbreviatingWithTildeInPath).font(Theme.Typography.mono).foregroundStyle(Color.jarvisPrimary).lineLimit(1).truncationMode(.middle)
                    if let p = profiles {
                        Text("Build: \(p.build?.display ?? "none found") · Test: \(p.test?.display ?? "none found") · \(p.source)")
                            .font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary).lineLimit(2)
                    }
                    Text("Tasks may edit files inside this folder only. JARVIS never commits, pushes or runs arbitrary commands.").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
                }
                if let problem { Text(problem).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.coral) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
        panel.prompt = "Choose project"; panel.message = "Autonomous tasks may read and edit files inside this folder."
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { _ = try WorkspaceGuard(rootPath: url.path); app.preferences.projectRoot = url.path; problem = nil }
            catch { problem = String(describing: error) }
        }
    }
}

// MARK: - Task card

struct EngineTaskCard: View {
    @Environment(AppContext.self) private var app
    let view: TaskView
    let expanded: Bool
    let onToggle: () -> Void

    private var projected: JarvisTask { JarvisTask(view: view, activeAgents: app.hub.activeRuns.filter { $0.taskID == view.id }.count) }

    var body: some View {
        let task = projected
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Button(action: onToggle) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.jarvisTertiary).frame(width: 10).accessibilityHidden(true)
                    Text(view.task.title).font(Theme.Typography.headline).foregroundStyle(Color.jarvisPrimary).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: Theme.Spacing.s)
                    Tag(text: view.task.kind == .development ? "DEV" : "READ-ONLY")
                    TaskStatusChip(status: task.status)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(view.task.title), \(task.status.label.lowercased()). \(progressSpoken)")
            .accessibilityHint(expanded ? "Collapse the plan" : "Show the plan and step states")

            statusLine
            if !task.steps.isEmpty {
                SegmentedProgress(steps: task.steps)
                HStack {
                    Text(progressText).font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary)
                    Spacer()
                    HStack(spacing: Theme.Spacing.xs) { Image(systemName: "timer").font(.system(size: 10)).accessibilityHidden(true); ElapsedText(task: task, isVisible: true) }
                        .font(Theme.Typography.mono).foregroundStyle(Color.jarvisSecondary)
                }
            }
            actions
            if let summary = view.task.summary, view.task.state.isTerminal {
                Text(summary).font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary).fixedSize(horizontal: false, vertical: true)
            }
            if expanded { details }
        }
        .padding(Theme.Spacing.m)
        .background(HUDCardBackground(accent: view.task.state == .waitingForApproval ? Theme.Palette.amber : Theme.Palette.accent, raised: expanded))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tasks.card.\(view.id.uuidString.prefix(8))")
    }

    private var progressText: String {
        let p = view.passedCount, n = view.measurableCount
        guard n > 0 else { return "" }
        if let f = view.task.progressFraction { return "\(p) of \(n) steps validated · \(Int((f * 100).rounded())) %" }
        return "\(p) of \(n) steps validated"
    }
    private var progressSpoken: String { progressText.isEmpty ? "No plan yet" : progressText }

    @ViewBuilder private var statusLine: some View {
        switch view.task.state {
        case .waitingForApproval:
            if let a = view.pendingApproval {
                VStack(alignment: .leading, spacing: 3) {
                    Label(a.action, systemImage: "hand.raised.fill").font(Theme.Typography.body).foregroundStyle(Theme.Palette.amber)
                    Text(a.reason).font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary)
                }
            } else { Text("Waiting for your approval").font(Theme.Typography.body).foregroundStyle(Theme.Palette.amber) }
        case .interrupted:
            Text(view.task.recovery ?? "Interrupted — resume to continue from the saved state.").font(Theme.Typography.body).foregroundStyle(Theme.Palette.amber)
        case .failed:
            Text("\(view.task.failureCategory?.label.capitalized ?? "Failed"): \(view.task.failureReason ?? "")").font(Theme.Typography.body).foregroundStyle(Theme.Palette.coral).lineLimit(3)
        case .created, .planning, .ready, .running:
            Text(view.task.activity).font(Theme.Typography.body).foregroundStyle(Theme.Palette.accent).lineLimit(2)
        default: EmptyView()
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Spacing.s) {
            if view.task.state == .waitingForApproval, let a = view.pendingApproval {
                Button("APPROVE") { app.taskEngine.decide(a.id, approved: true) }.buttonStyle(.hudPrimary).accessibilityLabel("Approve: \(a.action)")
                Button("DENY") { app.taskEngine.decide(a.id, approved: false) }.buttonStyle(.hudSecondary).accessibilityLabel("Deny: \(a.action)")
            }
            if view.task.state == .interrupted {
                Button("RESUME") { app.taskEngine.resume(view.id) }.buttonStyle(.hudPrimary).accessibilityLabel("Resume \(view.task.title)")
            }
            if view.task.state.isStoppable {
                Button("STOP") { app.taskEngine.cancel(view.id) }.buttonStyle(.hudSecondary).accessibilityLabel("Stop \(view.task.title)")
                    .accessibilityIdentifier("tasks.stop.\(view.id.uuidString.prefix(8))")
            }
            if view.steps.contains(where: { $0.agentRunID != nil }) {
                Button("SHOW IN AGENTS") { openAgents() }.buttonStyle(.hudSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func openAgents() {
        let run = view.steps.reversed().compactMap(\.agentRunID).first { app.hub.run($0) != nil } ?? view.steps.reversed().compactMap(\.agentRunID).first
        app.observatory.selectedRunID = run
        withAnimation(app.preferences.effectiveReduceMotion ? nil : .easeOut(duration: Theme.Duration.fast)) { app.hud.section = .agents }
    }

    // MARK: Plan details

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Rectangle().fill(Color.white.opacity(Theme.Opacity.hairline)).frame(height: 0.8)
            if let plan = view.task.summary, view.task.state.isActive { Text("Plan: \(plan)").font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary) }
            Text("PLAN · \(view.steps.count) STEPS").jarvisLabel(Theme.Opacity.textTertiary)
            if view.steps.isEmpty { Text("No plan yet.").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary) }
            ForEach(view.steps) { s in StepRow(step: s, all: view.steps) }
            if let ws = view.task.workspaceRoot { Text("Workspace: \((ws as NSString).abbreviatingWithTildeInPath)").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary).lineLimit(1).truncationMode(.middle) }
            if let g = view.task.gitBaseline, g.isRepository {
                Text("Git: \(g.branch ?? "detached") @ \(g.head.map { String($0.prefix(7)) } ?? "—") · \(g.dirtyPaths.count + g.untrackedPaths.count) uncommitted path(s) preserved")
                    .font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
            }
        }
    }
}

private struct StepRow: View {
    let step: TaskStepRecord
    let all: [TaskStepRecord]

    private var tint: Color {
        switch step.state {
        case .passed: Theme.Palette.mint
        case .failed: Theme.Palette.coral
        case .running, .verifying: Theme.Palette.accent
        case .waitingForApproval, .interrupted: Theme.Palette.amber
        default: Color.jarvisTertiary
        }
    }
    private var symbol: String {
        switch step.state {
        case .passed: "checkmark.circle.fill"; case .failed: "xmark.circle.fill"; case .running: "circle.dotted.circle"; case .verifying: "checkmark.seal"
        case .waitingForApproval: "hand.raised.fill"; case .interrupted: "bolt.slash"; case .cancelled: "stop.circle"; case .skipped: "minus.circle"; default: "circle"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 14).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(step.index + 1). \(step.title)").font(Theme.Typography.body).foregroundStyle(Color.jarvisPrimary).lineLimit(2)
                Text("\(step.type.label) · validates: \(step.validation.rawValue)\(step.dependsOn.isEmpty ? "" : " · after \(step.dependsOn.joined(separator: ", "))")\(step.attempts > 1 ? " · \(step.attempts) attempts" : "")")
                    .font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary).lineLimit(2)
                if let e = step.validationEvidence, !e.isEmpty, step.state.isTerminal {
                    Text(e.split(separator: "\n").first.map(String.init) ?? e).font(Theme.Typography.caption).foregroundStyle(step.state == .failed ? Theme.Palette.coral : Color.jarvisSecondary).lineLimit(2)
                } else if let why = step.failureReason, step.state == .failed {
                    Text(why).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.coral).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Text(step.state.label).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(step.index + 1): \(step.title), \(step.state.label.lowercased())")
    }
}
