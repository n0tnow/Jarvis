import SwiftUI

// MARK: - Left column

struct SystemPanel: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        HUDCard("System") {
            VStack(spacing: Theme.Spacing.s) {
                KeyValueRow(key: "State", value: app.store.state.label, valueTint: app.store.state.tint)
                KeyValueRow(key: "Version", value: AppInfo.version)
                KeyValueRow(key: "Provider", value: providerSummary, valueTint: app.coordinator.statusBadge.usable ? Theme.Palette.mint : Theme.Palette.amber)
                KeyValueRow(key: "Local", value: app.localRuntime.state.label, valueTint: app.localRuntime.state.isUsableForRouting || app.localRuntime.state == .running ? Theme.Palette.mint : Color.jarvisSecondary)
                KeyValueRow(key: "OpenCode", value: openCodeSummary, valueTint: app.openCode.state == .ready ? Theme.Palette.mint : Color.jarvisSecondary)
                KeyValueRow(key: "Memory", value: app.resources.pressure.memory.rawValue.uppercased(),
                            valueTint: app.resources.pressure.memory == .normal ? Color.jarvisSecondary : Theme.Palette.amber)
                KeyValueRow(key: "Permissions", value: "NONE REQUESTED")
                KeyValueRow(key: "Motion", value: app.preferences.effectiveReduceMotion ? "REDUCED" : "FULL")
            }
        }
    }
}

extension SystemPanel {
    fileprivate var providerSummary: String {
        let mode = app.preferences.providerPreference
        if let d = app.coordinator.lastDecision, let c = d.selected { return "\(mode == .auto ? "AUTO → " : "")\(c.engine.shortName)" }
        return app.coordinator.statusBadge.usable ? mode.displayName.uppercased() : "NONE READY"
    }
    fileprivate var openCodeSummary: String {
        switch app.openCode.state {
        case .ready: "\(app.openCode.freePool.count) FREE"
        default: app.openCode.state.label
        }
    }
}

struct ProjectPanel: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        HUDCard("Project", trailing: { Tag(text: "DEMO") }) {
            if let project = app.store.project {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(project.name).font(Theme.Typography.headline).foregroundStyle(Color.jarvisPrimary)
                    HStack(spacing: Theme.Spacing.s) {
                        Text(project.kind).font(Theme.Typography.mono).foregroundStyle(Color.jarvisSecondary)
                        Text("·").foregroundStyle(Color.jarvisTertiary)
                        Label(project.branch, systemImage: "arrow.triangle.branch")
                            .font(Theme.Typography.mono).foregroundStyle(Color.jarvisSecondary)
                            .labelStyle(.titleAndIcon)
                    }
                }
                .accessibilityElement(children: .combine)
            } else {
                Text("No project loaded").font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
            }
        }
    }
}

struct TasksPanel: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        HUDCard("Tasks", trailing: { Tag(text: "\(app.store.tasks.count)") }) {
            VStack(spacing: Theme.Spacing.s) {
                ForEach(app.store.tasks) { task in
                    TaskRow(task: task)
                }
                if app.store.tasks.isEmpty {
                    Text("No tasks").font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
                }
            }
        }
    }
}

struct TaskRow: View {
    let task: JarvisTask

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs + 1) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Image(systemName: task.status.symbolName)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(task.status.tint)
                    .frame(width: 12)
                    .accessibilityHidden(true)
                Text(task.title).font(Theme.Typography.body).foregroundStyle(Color.jarvisPrimary).lineLimit(1)
                Spacer(minLength: 0)
                Text(task.status.shortLabel)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(task.status.tint)
            }
            SegmentedProgress(steps: task.steps, height: 4)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Right column

struct ActivityPanel: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        HUDCard("Activity", trailing: { Tag(text: "IN-MEMORY") }) {
            let events = Array(app.store.activity.suffix(60).reversed())
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Spacing.s + 1) {
                    ForEach(events) { event in
                        ActivityRow(event: event)
                    }
                    if events.isEmpty {
                        Text("No activity yet").font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Takes whatever height is left in the column; scrolls internally.
        .frame(minHeight: 150, idealHeight: 190, maxHeight: .infinity, alignment: .top)
    }
}

struct ActivityRow: View {
    let event: ActivityEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Text(event.timestamp, format: .dateTime.hour().minute().second())
                .font(Theme.Typography.mono)
                .foregroundStyle(Color.jarvisTertiary)
                .monospacedDigit()
            Image(systemName: event.kind.symbolName)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(event.kind.tint)
                .frame(width: 10)
                .accessibilityHidden(true)
            Text(event.message)
                .font(Theme.Typography.caption)
                .foregroundStyle(event.kind == .command ? Theme.Palette.violet : Color.jarvisPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(event.kind.label): \(event.message)")
    }
}

struct AgentsPanel: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        let live = app.agents.active
        HUDCard("Agents", trailing: {
            if live.isEmpty { Tag(text: "DEMO · NOT CONNECTED", tint: Theme.Palette.amber) }
            else { Tag(text: "ACTIVE · \(live.count)", tint: Theme.Palette.mint) }
        }) {
            VStack(spacing: Theme.Spacing.s) {
                if !live.isEmpty {
                    // Real background agent runs (V0.3.1 foundation): agent · engine/model · elapsed · cancel.
                    ForEach(live) { run in
                        HStack(spacing: Theme.Spacing.s) {
                            Image(systemName: "circle.inset.filled").font(.system(size: 8)).foregroundStyle(Theme.Palette.accent).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(run.type).font(Theme.Typography.body).foregroundStyle(Color.jarvisPrimary)
                                Text("\(run.engine.displayName)\(run.model.map { " · " + ($0.split(separator: "/").last.map(String.init) ?? $0) } ?? "")")
                                    .font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary).lineLimit(1)
                            }
                            Spacer()
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                Text(ElapsedText.format(ctx.date.timeIntervalSince(run.startedAt))).font(Theme.Typography.mono).foregroundStyle(Color.jarvisSecondary).monospacedDigit()
                            }
                            Button { app.agents.cancel(run.id) } label: { Image(systemName: "stop.fill").font(.system(size: 9)) }
                                .buttonStyle(.plain).foregroundStyle(Theme.Palette.coral).accessibilityLabel("Cancel \(run.type)")
                        }
                        .accessibilityElement(children: .combine)
                    }
                } else {
                    ForEach(app.store.agents) { agent in
                        HStack(spacing: Theme.Spacing.s) {
                            Image(systemName: agent.status == .active ? "circle.inset.filled" : "circle")
                                .font(.system(size: 8))
                                .foregroundStyle(agent.status == .active ? Theme.Palette.accent : Color.jarvisTertiary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(agent.name).font(Theme.Typography.body).foregroundStyle(Color.jarvisPrimary)
                                Text(agent.role).font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
                            }
                            Spacer()
                            Text(agent.status.label)
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(agent.status == .active ? Theme.Palette.accent : Color.jarvisSecondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

struct ToolsPanel: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        HUDCard("Tools") {
            VStack(spacing: Theme.Spacing.s) {
                ForEach(app.store.tools) { tool in
                    HStack(spacing: Theme.Spacing.s) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.jarvisTertiary)
                            .accessibilityHidden(true)
                        Text(tool.name).font(Theme.Typography.body).foregroundStyle(Color.jarvisPrimary)
                        Spacer()
                        Text("\(tool.availability.label) · \(tool.plannedFor)")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.jarvisTertiary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

// MARK: - Sections

struct TasksSectionView: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.m) {
                ForEach(app.store.tasks) { task in
                    HUDCard(task.title, trailing: { TaskStatusChip(status: task.status) }) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                            Text(task.details).font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
                            ForEach(task.steps) { step in
                                HStack(spacing: Theme.Spacing.s) {
                                    Image(systemName: step.status.symbolName)
                                        .foregroundStyle(step.status.tint)
                                        .frame(width: 14)
                                        .accessibilityHidden(true)
                                    Text(step.title).font(Theme.Typography.body).foregroundStyle(Color.jarvisPrimary)
                                    Spacer()
                                    Text(step.status.label.uppercased())
                                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color.jarvisSecondary)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 760)
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: .infinity)
        }
    }
}

struct SystemSectionView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.m) {
                SystemPanel()
                ProjectPanel()
                ToolsPanel()
                AgentsPanel()
            }
            .frame(maxWidth: 560)
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: .infinity)
        }
    }
}
