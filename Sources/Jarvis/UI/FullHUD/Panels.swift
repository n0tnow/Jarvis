import SwiftUI

// MARK: - Left column

struct SystemPanel: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        HUDCard("System") {
            VStack(spacing: Theme.Spacing.s) {
                KeyValueRow(key: "State", value: app.store.state.label, valueTint: app.store.state.tint)
                KeyValueRow(key: "Version", value: AppInfo.versionLine)
                KeyValueRow(key: "Provider", value: providerSummary, valueTint: app.coordinator.statusBadge.usable ? Theme.Palette.mint : Theme.Palette.amber)
                KeyValueRow(key: "Local", value: app.localRuntime.state.label, valueTint: app.localRuntime.state.isUsableForRouting || app.localRuntime.state == .running ? Theme.Palette.mint : Color.jarvisSecondary)
                KeyValueRow(key: "OpenCode", value: openCodeSummary, valueTint: app.openCode.state == .ready ? Theme.Palette.mint : Color.jarvisSecondary)
                KeyValueRow(key: "Memory", value: app.resources.pressure.memory.rawValue.uppercased(),
                            valueTint: app.resources.pressure.memory == .normal ? Color.jarvisSecondary : Theme.Palette.amber)
                KeyValueRow(key: "Motion", value: app.preferences.effectiveReduceMotion ? "REDUCED" : "FULL")
            }
        }
    }
}

/// Voice, Push-to-Talk and Wake Word at a glance — and the way to change them (the Wake Word switch lives in Settings → Voice; this card only says what is true).
struct VoicePanel: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        let hf = app.handsFree
        let prefs = app.preferences
        let mic = app.voice.permission
        HUDCard("Voice", trailing: { Button("Settings") { app.hud.settingsCategory = .voice; app.hud.section = .settings }.buttonStyle(.hudSecondary).fixedSize() }) {
            VStack(spacing: Theme.Spacing.s) {
                row("Voice input", prefs.voiceEnabled ? .running : .off, prefs.voiceEnabled ? "ON" : "OFF")
                row("Push-to-Talk", prefs.voicePushToTalk && prefs.voiceEnabled ? .ready : .off, prefs.voicePushToTalk && prefs.voiceEnabled ? "HOLD RIGHT ⌥" : "OFF")
                row("Wake Word", !prefs.voiceWakeEnabled ? .off : (hf.wakeStatus == .listening ? .running : (hf.wakeStatus == .starting ? .notChecked : (hf.wakeStatus == .paused ? .notRunning : .error))),
                    !prefs.voiceWakeEnabled ? "OFF" : (hf.wakeStatus == .listening ? "RUNNING" : (hf.wakeStatus == .starting ? "STARTING" : (hf.wakeStatus == .paused ? "PAUSED" : (hf.wakeStatus == .off ? "STOPPED" : "ERROR")))))
                row("Microphone", mic == .granted ? .ready : (mic == .notDetermined ? .notChecked : .permissionNeeded), mic == .granted ? "ALLOWED" : (mic == .notDetermined ? "NOT ASKED" : "PERMISSION NEEDED"))
                if case .unavailable(let why) = hf.wakeStatus, prefs.voiceWakeEnabled {
                    Text(why).font(Theme.Typography.meta).foregroundStyle(Theme.Palette.amber).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func row(_ title: String, _ kind: StatusKind, _ text: String) -> some View {
        HStack { Text(title).font(Theme.Typography.meta).foregroundStyle(Color.jarvisTertiary); Spacer(); StatusBadge(kind: kind, text: text) }
    }
}

extension SystemPanel {
    fileprivate var voiceSummary: String {
        guard app.preferences.voiceEnabled else { return "OFF" }
        let presence = app.handsFree.presence
        if presence != .off && presence != .wake { return presence.label }
        if presence == .wake { return "WAKE · LOCAL DETECTOR" }
        if case .unavailable = app.handsFree.wakeStatus, app.preferences.voiceWakeEnabled { return "WAKE UNAVAILABLE · PUSH-TO-TALK" }
        return "READY · PUSH-TO-TALK"
    }
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
        let root = app.preferences.projectRoot
        HUDCard("Project", trailing: { if app.demoMode, app.store.project != nil { Tag(text: "SIMULATED", tint: Theme.Palette.amber) } }) {
            if app.demoMode, let project = app.store.project {                       // developer / capture runs only
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(project.name).font(Theme.Typography.headline).foregroundStyle(Color.jarvisPrimary)
                    HStack(spacing: Theme.Spacing.s) {
                        Text(project.kind).font(Theme.Typography.mono).foregroundStyle(Color.jarvisSecondary)
                        Text("·").foregroundStyle(Color.jarvisTertiary)
                        Label(project.branch, systemImage: "arrow.triangle.branch").font(Theme.Typography.mono).foregroundStyle(Color.jarvisSecondary).labelStyle(.titleAndIcon)
                    }
                }
                .accessibilityElement(children: .combine)
            } else if !root.isEmpty {
                // The folder the user chose in Tasks — a fact, not a guess. (Branch, Unity state and history are on the Tasks screen's Project card.)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text((root as NSString).lastPathComponent).font(Theme.Typography.headline).foregroundStyle(Color.jarvisPrimary).lineLimit(1)
                    Text(root.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(Theme.Typography.mono).foregroundStyle(Color.jarvisTertiary).lineLimit(1).truncationMode(.middle)
                    if let unity = app.unity.existingConnection(for: root) { Text("Unity: \(unity.state.label)").font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary) }
                }
                .accessibilityElement(children: .combine)
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("No project selected").font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
                    Text("Choose a folder on the Tasks screen.").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
                }
            }
        }
    }
}

struct TasksPanel: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        HUDCard("Tasks", trailing: { Tag(text: "\(app.store.allTasks.count)") }) {
            VStack(spacing: Theme.Spacing.s) {
                if app.preferences.showProposals, app.opportunities.summary != (0, 0) {
                    let sm = app.opportunities.summary
                    HStack {
                        Image(systemName: "lightbulb").foregroundStyle(Theme.Palette.violet).accessibilityHidden(true)
                        Text("\(sm.proposals) pending proposal\(sm.proposals == 1 ? "" : "s") · \(sm.findings) recorded finding\(sm.findings == 1 ? "" : "s")")
                            .font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary)
                        Spacer()
                        Button("OPEN") { app.hud.section = .tasks }.buttonStyle(.hudSecondary).fixedSize()
                    }
                    .accessibilityElement(children: .combine)
                }
                ForEach(app.store.allTasks) { task in
                    TaskRow(task: task)
                }
                if app.store.allTasks.isEmpty {
                    Text("No active tasks.").font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
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
        HUDCard("Activity", trailing: { Tag(text: "THIS SESSION") }) {
            let events = Array(app.store.activity.suffix(60).reversed())
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Spacing.s + 1) {
                    ForEach(events) { event in
                        ActivityRow(event: event)
                    }
                    if events.isEmpty {
                        Text("No recent activity.").font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
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
            HStack(spacing: Theme.Spacing.s) {
                if live.isEmpty { Tag(text: app.demoMode && !app.store.agents.isEmpty ? "SIMULATED" : "NONE", tint: app.demoMode && !app.store.agents.isEmpty ? Theme.Palette.amber : Color.jarvisTertiary) }
                else { Tag(text: "ACTIVE · \(live.count)", tint: Theme.Palette.mint) }
                Button("OPEN") { app.hud.section = .agents }.buttonStyle(.plain).font(Theme.Typography.label).foregroundStyle(Theme.Palette.accent)
                    .accessibilityLabel("Open the Agents view")
            }
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
                } else if !(app.demoMode && !app.store.agents.isEmpty) {
                    Text("No agents are running.").font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
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

struct SystemSectionView: View {
    @Environment(AppContext.self) private var app
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        PageScaffold("System", subtitle: app.readiness.snapshot.summary.headline, trailing: { headerControls }) {
            VStack(alignment: .leading, spacing: Theme.Grid.gutter) {
                ReadinessPanel(message: $message, busy: $busy)
                ResponsiveColumns(minColumn: 470) {
                    SystemPanel()
                    ProjectPanel()
                    AgentsPanel()
                    if app.demoMode { ToolsPanel() }
                }
            }
        }
        .accessibilityIdentifier("system.page")
    }

    /// Recheck re-reads every permission and the wake detector from macOS; Restart applies permissions that macOS only applies to a process started after they were allowed.
    private var headerControls: some View {
        HStack(spacing: Theme.Spacing.s) {
            Button("Restart JARVIS") { Task { _ = await ReadinessActions.run(.restartJarvis, in: app) } }
                .buttonStyle(.hudSecondary).fixedSize().accessibilityIdentifier("readiness.restart")
                .accessibilityHint("Quits and starts JARVIS again. Some macOS permissions, Screen Recording first of all, apply only to a process started after they were allowed.")
            Button("Recheck") { Task { busy = true; await ReadinessActions.recheck(app); busy = false; message = "Checked again — permissions and the wake detector were re-read from macOS." } }
                .buttonStyle(.hudPrimary).fixedSize().disabled(busy || app.setupRunner.isRunning)
                .accessibilityHint("Reads the current state again. Starts nothing and installs nothing.").accessibilityIdentifier("readiness.recheck")
        }
    }
}
